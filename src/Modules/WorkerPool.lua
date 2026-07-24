-- Path of Building
--
-- Module: Worker Pool
-- Pool of background calculation workers: subscript threads each holding a full
-- headless copy of the program and the current build. Batch jobs (many independent
-- full-calculation candidates) are sharded across the workers, keeping the UI
-- responsive. Workers pull work through the blocking PoBWorkerPoolRPC round-trip,
-- which the host services once per frame per worker; idle workers sleep inside
-- the host, so an idle pool costs nothing.
--
-- The module can get loaded more than once; every user must share one pool, or
-- two pools' identically-numbered workers get confused through the global RPC
if mainWorkerPool then
	return mainWorkerPool
end

local t_insert = table.insert
local t_remove = table.remove

local dkjson = require("dkjson")

local pool = {
	workers = { },      -- workerId -> { subId, alive, currentJob }
	jobQueue = { },     -- shards waiting for a worker
	jobs = { },         -- jobId -> shard
	nextJobId = 1,
	nextWorkerId = 1,
	started = false,
	aliveCount = 0,
	buildXmlCache = { revision = nil, text = nil },
	frameCounter = 0,
}

local WORKER_COUNT = 16

local function plog(fmt, ...)
	if launch.devMode then
		ConPrintf(fmt, ...)
	end
end

function pool:Start()
	if self.started then
		return
	end
	self.started = true
	-- Worker ids must be unique across script restarts (F5): workers from a previous
	-- state survive in the host, and colliding ids would let them impersonate the
	-- new fleet; unknown ids are told to quit on their first call
	self.nextWorkerId = (os.time() % 1000000) * 1000 + math.floor(GetTime() % 1000)
	local scriptFile = io.open(GetScriptPath() .. "/Modules/WorkerScript.lua", "r")
	if not scriptFile then
		ConPrintf("WorkerPool: cannot read worker script")
		return
	end
	local script = scriptFile:read("*a")
	scriptFile:close()
	for i = 1, WORKER_COUNT do
		local workerId = self.nextWorkerId
		self.nextWorkerId = workerId + 1
		local subId = LaunchSubScript(script, "PoBWorkerPoolRPC", "ConPrintf", workerId, GetScriptPath())
		if subId then
			self.workers[workerId] = { subId = subId, alive = true }
			self.aliveCount = self.aliveCount + 1
			launch:RegisterSubScript(subId, function()
				self:WorkerDied(workerId)
			end)
		end
	end
	plog("WorkerPool: launched %d workers", self.aliveCount)
end

function pool:IsAvailable()
	if not self.started then
		-- LaunchSubScript reads its arguments from the main thread's Lua state, so
		-- calling it from a coroutine crashes the host; defer startup to OnFrame
		-- (always on the main state) when requested from inside a coroutine
		if coroutine.running() then
			self.startRequested = true
		else
			self:Start()
		end
	end
	return self.aliveCount > 0
end

function pool:WorkerDied(workerId)
	local w = self.workers[workerId]
	if not w or not w.alive then
		return
	end
	w.alive = false
	self.aliveCount = self.aliveCount - 1
	if w.currentJob then
		-- Give the interrupted shard back to the queue
		local job = self.jobs[w.currentJob]
		if job then
			t_insert(self.jobQueue, 1, job)
		end
		w.currentJob = nil
	end
end

-- Called every frame from Main; detects workers that died without reporting
function pool:OnFrame()
	if self.startRequested and not self.started then
		self:Start()
	end
	if not self.started then
		return
	end
	self.frameCounter = self.frameCounter + 1
	if self.frameCounter % 120 == 0 then
		for workerId, w in pairs(self.workers) do
			if w.alive and not IsSubScriptRunning(w.subId) then
				self:WorkerDied(workerId)
			end
		end
	end
end

function pool:GetBuildXml(build)
	if self.buildXmlCache.revision ~= build.outputRevision then
		self.buildXmlCache.revision = build.outputRevision
		self.buildXmlCache.text = build:SaveDB("worker sync")
	end
	return self.buildXmlCache.text
end

-- Drop a batch's queued jobs and ignore its in-flight results; used when the
-- request that submitted it has been superseded
function pool:CancelBatch(batch)
	if not batch or batch.cancelled then
		return
	end
	batch.cancelled = true
	for i = #self.jobQueue, 1, -1 do
		if self.jobQueue[i].batch == batch then
			self.jobs[self.jobQueue[i].id] = nil
			t_remove(self.jobQueue, i)
		end
	end
end

function pool:CompleteJob(jobId, resultJson)
	local job = self.jobs[jobId]
	if not job then
		return
	end
	self.jobs[jobId] = nil
	if job.batch.cancelled then
		return
	end
	local batch = job.batch
	local result = resultJson and dkjson.decode(resultJson) or { }
	if result.workerError then
		plog("WorkerPool: %s", result.workerError)
	else
		for k, v in pairs(result) do
			batch.results[k] = v
		end
	end
	batch.pending = batch.pending - 1
	if batch.onProgress then
		PCall(batch.onProgress, batch.total - batch.pending, batch.total)
	end
	if batch.pending == 0 and batch.onComplete then
		local errMsg = PCall(batch.onComplete, batch.results)
		if errMsg then
			ConPrintf("WorkerPool: batch callback error: %s", errMsg)
		end
	end
end

-- The single RPC entry point workers block on; must return quickly
function pool:HandleRPC(workerId, msg, revision, jobId, resultJson)
	local w = self.workers[workerId]
	if not w then
		return "quit"
	end
	if msg == "fatal" then
		ConPrintf("WorkerPool: worker %d failed: %s", workerId, tostring(resultJson))
		self:WorkerDied(workerId)
		return "quit"
	end
	if jobId then
		w.currentJob = nil
		self:CompleteJob(jobId, resultJson)
	end
	local build = main and main.modes and main.modes["BUILD"]
	if not build or not build.outputRevision then
		return "wait"
	end
	-- Sync on content, not revision: many recalculation triggers (e.g. changing the
	-- heat map stat) bump the revision without changing the build at all
	local xmlText = self:GetBuildXml(build)
	if not xmlText then
		-- Serialization failed; without it workers would calculate an empty build
		if not self.warnedNoXml then
			self.warnedNoXml = true
			plog("WorkerPool: build serialization returned nil; jobs held back")
		end
		return "wait"
	end
	if w.syncedText ~= xmlText then
		-- Proactive: idle workers resync as soon as the build content changes, so
		-- batches submitted later start on warm workers
		w.syncedText = xmlText
		plog("WorkerPool: sync -> worker %d (%d bytes)", workerId, #xmlText)
		return "sync", build.outputRevision, xmlText
	end
	if not self.jobQueue[1] then
		return "wait"
	end
	local job = t_remove(self.jobQueue, 1)
	w.currentJob = job.id
	return "job", job.id, job.kind, job.payloadJson
end

function PoBWorkerPoolRPC(workerId, msg, revision, jobId, resultJson)
	return pool:HandleRPC(workerId, msg, revision, jobId, resultJson)
end

-- Splits `list` into per-worker shards, each sharing the fields of `common`
-- with the shard's slice stored under `listField`
function pool:ShardList(list, listField, common)
	-- Several small shards per worker: smoother result streaming and better load
	-- balancing than one big shard each, without drowning in per-shard overhead
	-- Shards must stay small: a queued priority job can only start once a worker
	-- finishes its current shard, so shard size bounds interactive latency
	local shardCount = math.max(1, math.min(self.aliveCount * 8, math.ceil(#list / 8)))
	local shards = { }
	local per = math.ceil(#list / shardCount)
	for s = 1, shardCount do
		local payload = { }
		for k, v in pairs(common) do
			payload[k] = v
		end
		local slice = { }
		for i = (s - 1) * per + 1, math.min(s * per, #list) do
			t_insert(slice, list[i])
		end
		if slice[1] then
			payload[listField] = slice
			t_insert(shards, payload)
		end
	end
	return shards
end

-- Submit a batch of shards; onComplete(results) runs on the main thread once all
-- shards have returned, with all shard results merged into one table (note that
-- numeric keys come back as strings after the JSON round-trip)
-- priority: interactive batches (dropdown sorts) go to the queue front, ahead of
-- bulk background work like heat map rebuilds
function pool:SubmitBatch(kind, shards, onComplete, onProgress, priority)
	if not self:IsAvailable() then
		return false
	end
	local batch = { pending = 0, total = #shards, results = { }, onComplete = onComplete, onProgress = onProgress }
	for _, payload in ipairs(shards) do
		local job = {
			id = self.nextJobId,
			kind = kind,
			payloadJson = dkjson.encode(payload),
			batch = batch,
		}
		self.nextJobId = self.nextJobId + 1
		self.jobs[job.id] = job
		if priority then
			t_insert(self.jobQueue, batch.pending + 1, job)
		else
			t_insert(self.jobQueue, job)
		end
		batch.pending = batch.pending + 1
	end
	-- The batch table is live: results merge in and pending decrements as shards
	-- return, so callers may stream from it instead of waiting for onComplete
	return batch.pending > 0 and batch
end

mainWorkerPool = pool
return pool
