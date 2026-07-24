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

-- Sections whose tab Load functions fully replace prior state, making them safe
-- to re-load into a live worker build (see WorkerScript patch handler); a change
-- in any other section forces a full build reload
local PATCHABLE_SECTIONS = { Skills = true, Items = true, Config = true }

local function plog(fmt, ...)
	local line = string.format("[%7d] ", GetTime()) .. string.format(fmt, ...)
	if launch.devMode then
		ConPrintf("%s", line)
	end
	-- Also append to a timing log next to the repo so post-hoc analysis does not
	-- depend on a console being open; truncated on every pool start
	if not pool.logPath then
		pool.logPath = GetScriptPath() .. "/../workerpool-timing.log"
	end
	local lf = io.open(pool.logPath, "a")
	if lf then
		lf:write(line, "\n")
		lf:close()
	end
end

-- Worker count from the Options setting (0 disables the pool)
function pool:DesiredCount()
	local count = tonumber(main and main.workerPoolCount) or 16
	return math.max(0, math.min(32, math.floor(count)))
end

function pool:Start()
	if self.started then
		return
	end
	local count = self:DesiredCount()
	if count == 0 then
		return
	end
	self.started = true
	self.launchedCount = count
	self.logPath = GetScriptPath() .. "/../workerpool-timing.log"
	local lf = io.open(self.logPath, "w")
	if lf then
		lf:close()
	end
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
	for i = 1, count do
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
	return self.aliveCount > 0 and self:DesiredCount() > 0
end

-- Applies a changed worker-count option: the current fleet is told to quit
-- (each worker on its next call-in) and the next availability check starts a
-- new one with the desired count. Queued jobs survive a resize and are served
-- by the new fleet; disabling cancels all pending batches so their consumers
-- fall back to synchronous calculation.
function pool:ApplySettings()
	local count = self:DesiredCount()
	if not self.started or count == self.launchedCount then
		return
	end
	plog("WorkerPool: worker count %d -> %d; restarting fleet", self.launchedCount or 0, count)
	for _, w in pairs(self.workers) do
		if w.alive then
			w.quit = true
		end
	end
	self.started = false
	if count > 0 then
		-- Prestart the resized fleet from the frame hook rather than waiting for
		-- the next consumer
		self.startRequested = true
	end
	if count == 0 then
		local batches = { }
		for _, job in pairs(self.jobs) do
			batches[job.batch] = true
		end
		for batch in pairs(batches) do
			self:CancelBatch(batch)
		end
		self.jobs = { }
		self.jobQueue = { }
	end
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
	local cache = self.buildXmlCache
	local fresh
	if build.buildFlag then
		-- An edit is pending recalculation. Serialize the new input state NOW:
		-- the host answers worker RPCs (SubScriptFrame) before OnFrame runs the
		-- potentially long main-thread recalculation, so workers can resync and
		-- reload in parallel with it instead of serially after it. SaveDB only
		-- reads input state, which is already final when buildFlag is set.
		if cache.dirtyFrame ~= self.frameCounter then
			cache.dirtyFrame = self.frameCounter
			cache.revision = nil -- re-key once the recalc assigns the new revision
			fresh = true
		end
	elseif cache.revision ~= build.outputRevision then
		cache.revision = build.outputRevision
		fresh = true
	end
	if fresh then
		local t0 = GetTime()
		local text = build:SaveDB("worker sync")
		if text then
			-- The Build section embeds display stats from the last calculation
			-- (PlayerStat/MinionStat/FullDPSSkill). They are output, not input: the
			-- pre-recalc and post-recalc serializations of the same edit differ only
			-- here, and leaving them in would resync every worker twice per edit.
			-- Workers recalculate everything anyway and never read these.
			text = text:gsub("%s*<PlayerStat[^>]*/>", ""):gsub("%s*<MinionStat[^>]*/>", ""):gsub("%s*<FullDPSSkill[^>]*/>", "")
		end
		if text and text ~= cache.text then
			self.lastContentChange = GetTime()
			cache.sections = self:SplitSections(text)
			cache.patchCache = { }
			plog("WorkerPool: build content changed (%d bytes, SaveDB %dms)", #text, GetTime() - t0)
		end
		cache.text = text
	end
	return cache.text
end

-- Splits a serialized build into its top-level sections, each with its composed
-- text as a change fingerprint; returns nil if the document can't be keyed by
-- section name (which just disables patching, not syncing)
function pool:SplitSections(text)
	local ok, doc = pcall(common.xml.ParseXML, text)
	local root = ok and doc and doc[1]
	if not root or root.elem ~= "PathOfBuilding" then
		return nil
	end
	local sections = { }
	for _, node in ipairs(root) do
		if type(node) == "table" and node.elem then
			if sections[node.elem] then
				return nil
			end
			sections[node.elem] = { node = node, text = common.xml.ComposeXML(node) }
		end
	end
	return sections
end

-- Builds the minimal patch that takes a worker from its synced state to the
-- current build: the changed sections only. Returns nil when a full sync is
-- needed (unknown prior state, non-patchable section changed, sections
-- added/removed). Cached per prior state; false marks "not patchable".
function pool:BuildPatch(w, xmlText)
	local cache = self.buildXmlCache
	if not cache.sections or not w.syncedSections or not w.syncedText then
		return nil
	end
	local cached = cache.patchCache[w.syncedText]
	if cached ~= nil then
		return cached or nil
	end
	local root = { elem = "PathOfBuilding" }
	local names = { }
	local patchable = true
	for name, sec in pairs(cache.sections) do
		local prev = w.syncedSections[name]
		if not prev then
			patchable = false
			break
		elseif prev.text ~= sec.text then
			if not PATCHABLE_SECTIONS[name] then
				patchable = false
				break
			end
			t_insert(root, sec.node)
			t_insert(names, name)
		end
	end
	if patchable then
		for name in pairs(w.syncedSections) do
			if not cache.sections[name] then
				patchable = false
				break
			end
		end
	end
	local patch = false
	if patchable and names[1] then
		local text = common.xml.ComposeXML(root)
		if text then
			patch = { text = text, names = table.concat(names, ",") }
		end
	end
	cache.patchCache[w.syncedText] = patch
	return patch or nil
end

-- Called from Build:OnFrame around the main-thread recalculation so the stall
-- shows up in the timing log next to the sync/batch events
function pool:LogMainRecalc(ms)
	if self.started then
		plog("WorkerPool: main-thread recalc took %dms", ms)
	end
end

-- Drop a batch's queued jobs and ignore its in-flight results; used when the
-- request that submitted it has been superseded
function pool:CancelBatch(batch)
	if not batch or batch.cancelled then
		return
	end
	batch.cancelled = true
	plog("WorkerPool: batch %s: cancelled %dms after submit (%d of %d shards pending)",
		tostring(batch.kind), GetTime() - (batch.submitAt or GetTime()), batch.pending, batch.total)
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
	if not batch.firstResultAt then
		batch.firstResultAt = GetTime()
		plog("WorkerPool: batch %s: first result +%dms after submit", tostring(batch.kind), batch.firstResultAt - batch.submitAt)
	end
	local result = resultJson and dkjson.decode(resultJson) or { }
	if result.workerError then
		plog("WorkerPool: %s", result.workerError)
	else
		for k, v in pairs(result) do
			batch.results[k] = v
		end
	end
	batch.pending = batch.pending - 1
	if batch.pending == 0 then
		plog("WorkerPool: batch %s: complete in %dms (%d shards)", tostring(batch.kind), GetTime() - batch.submitAt, batch.total)
	end
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
	if not w or w.quit then
		return "quit"
	end
	if msg == "fatal" then
		ConPrintf("WorkerPool: worker %d failed: %s", workerId, tostring(resultJson))
		self:WorkerDied(workerId)
		return "quit"
	end
	if msg == "patchfail" then
		-- Incremental patch didn't apply; forget the worker's state so the next
		-- round trip falls back to a full sync
		plog("WorkerPool: worker %d patch failed (%s); falling back to full sync", workerId, tostring(resultJson))
		w.syncedText = nil
		w.syncedSections = nil
		w.syncSentAt = nil
		return "wait"
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
		-- batches submitted later start on warm workers. Workers on a known state
		-- get just the changed sections; anything else gets the full build.
		local patch = self:BuildPatch(w, xmlText)
		w.syncedText = xmlText
		w.syncedSections = self.buildXmlCache.sections
		w.syncSentAt = GetTime()
		if patch then
			plog("WorkerPool: patch -> worker %d (%d bytes: %s%s)", workerId, #patch.text, patch.names,
				self.lastContentChange and string.format(", +%dms after change", GetTime() - self.lastContentChange) or "")
			return "patch", build.outputRevision, patch.text
		end
		plog("WorkerPool: sync -> worker %d (%d bytes%s)", workerId, #xmlText,
			self.lastContentChange and string.format(", +%dms after change", GetTime() - self.lastContentChange) or "")
		return "sync", build.outputRevision, xmlText
	end
	if w.syncSentAt then
		-- This is the worker's first call-in after reloading the synced build
		plog("WorkerPool: worker %d resynced in %dms%s", workerId, GetTime() - w.syncSentAt,
			self.lastContentChange and string.format(" (+%dms after change)", GetTime() - self.lastContentChange) or "")
		w.syncSentAt = nil
	end
	if not self.jobQueue[1] then
		return "wait"
	end
	local job = t_remove(self.jobQueue, 1)
	if not job.batch.firstDispatchAt then
		job.batch.firstDispatchAt = GetTime()
		plog("WorkerPool: batch %s: first job dispatched +%dms after submit (worker %d)",
			tostring(job.batch.kind), job.batch.firstDispatchAt - job.batch.submitAt, workerId)
	end
	w.currentJob = job.id
	return "job", job.id, job.kind, job.payloadJson
end

function PoBWorkerPoolRPC(workerId, msg, revision, jobId, resultJson)
	return pool:HandleRPC(workerId, msg, revision, jobId, resultJson)
end

-- Splits `list` into per-worker shards, each sharing the fields of `common`
-- with the shard's slice stored under `listField`
-- shardSize (optional) fixes the per-shard item count: interactive batches with
-- expensive items (FullDPS gem swaps) want tiny shards so first results arrive
-- fast; each shard costs ~a frame of RPC latency, so don't go below ~2
function pool:ShardList(list, listField, common, shardSize)
	-- Several small shards per worker: smoother result streaming and better load
	-- balancing than one big shard each, without drowning in per-shard overhead
	-- Shards must stay small: a queued priority job can only start once a worker
	-- finishes its current shard, so shard size bounds interactive latency
	local shardCount
	if shardSize then
		shardCount = math.max(1, math.ceil(#list / shardSize))
	else
		shardCount = math.max(1, math.min(self.aliveCount * 8, math.ceil(#list / 8)))
	end
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
	local batch = { pending = 0, total = #shards, results = { }, onComplete = onComplete, onProgress = onProgress,
		kind = kind, submitAt = GetTime() }
	plog("WorkerPool: batch %s: %d shards submitted%s%s", kind, #shards,
		priority and " (priority)" or "",
		self.lastContentChange and string.format(", +%dms after change", GetTime() - self.lastContentChange) or "")
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
