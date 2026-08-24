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
	batches = { },      -- batchId -> batch, while it is live
	nextBatchId = 1,
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

-- Batch callbacks run consumer code on the main thread; an error swallowed here
-- surfaces only as an unsorted list or an uncoloured tree
local function fireCallback(what, fn, ...)
	local errMsg = PCall(fn, ...)
	if errMsg then
		ConPrintf("WorkerPool: batch %s callback error: %s", what, errMsg)
	end
end

-- Pool activity trace: sync/patch round trips and batch timings, on the dev console
local function plog(fmt, ...)
	if launch.devMode then
		ConPrintf("[%7d] %s", GetTime(), string.format(fmt, ...))
	end
end

-- Batch lifecycle. Every submission is a task with an id and a state, so one can
-- be followed from submit to terminal state in the log, and so a consumer can ask
-- what became of the task it is waiting on instead of inferring it from an empty
-- result table. Terminal states are final:
--   queued     submitted; no shard has gone out yet
--   active     at least one shard is with a worker
--   complete   every shard returned
--   cancelled  the consumer superseded it; results are dropped and no callbacks fire
--   abandoned  nothing is left to finish it (the fleet died, failed to start or was
--              switched off); consumers are released with whatever arrived
local BATCH_TERMINAL = { complete = true, cancelled = true, abandoned = true }

-- How a batch appears in the log: "#7 gemDps(dps=CombinedDPS,group=1,...)". The
-- request descriptor is what the task was asked to compute, so a log line says
-- which task it belongs to without needing the submitting code open next to it.
function pool:DescribeBatch(batch)
	local request = ""
	if batch.request then
		local parts = { }
		for key in pairs(batch.request) do
			t_insert(parts, key)
		end
		table.sort(parts)
		for i, key in ipairs(parts) do
			parts[i] = key .. "=" .. tostring(batch.request[key])
		end
		request = "(" .. table.concat(parts, ",") .. ")"
	end
	return string.format("#%d %s%s", batch.id, batch.kind, request)
end

-- Two submissions are the same task when their descriptors agree on every field.
-- A batch submitted without a descriptor is never reusable.
local function sameRequest(a, b)
	if not a or not b then
		return false
	end
	for key, value in pairs(a) do
		if b[key] ~= value then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- The live task computing this exact request, if there is one. A consumer whose
-- state was rebuilt without anything the calculation depends on actually changing
-- keeps waiting on the work already in flight, instead of cancelling and
-- resubmitting it every time (which would keep it from ever finishing). Because
-- the match is on the full descriptor, a task computed against a different build
-- or a different slot can never be mistaken for this one.
function pool:FindBatch(kind, request)
	for _, batch in pairs(self.batches) do
		if batch.kind == kind and sameRequest(batch.request, request) then
			return batch
		end
	end
end

-- The one place a batch reaches a terminal state: records it, logs the outcome,
-- and releases the consumers waiting on it. Cancelled batches release nobody --
-- whoever cancelled has already moved on.
function pool:FinishBatch(batch, state)
	if BATCH_TERMINAL[batch.state] then
		return
	end
	batch.state = state
	batch.endAt = GetTime()
	self.batches[batch.id] = nil
	local summary = string.format("batch %s: %s after %dms, %d of %d shards returned, %d results",
		self:DescribeBatch(batch), state, batch.endAt - batch.submitAt,
		batch.total - batch.pending, batch.total, batch.resultCount)
	if batch.errorCount > 0 then
		-- Worker errors are the reason a sort comes back unsorted or a node keeps
		-- its baseline value, so they are never left to devMode alone
		ConPrintf("WorkerPool: %s, %d worker errors, first: %s", summary, batch.errorCount, tostring(batch.firstError))
	else
		plog("WorkerPool: %s", summary)
	end
	if state == "cancelled" then
		return
	end
	if batch.pending > 0 then
		-- Abandoned: the rest is never coming, so report the batch as done or the
		-- consumers waiting on it (the tree and item sorts yield until it
		-- completes) would wait forever instead of falling back to this thread
		batch.pending = 0
		if batch.onProgress then
			fireCallback("progress", batch.onProgress, batch.total, batch.total)
		end
	end
	if batch.onComplete then
		fireCallback("completion", batch.onComplete, batch.results)
	end
end

-- Worker count from the Options setting (0 disables the pool)
function pool:DesiredCount()
	local count = tonumber(main and main.workerPoolCount) or 0
	return math.max(0, math.min(32, math.floor(count)))
end

function pool:Start()
	self.startRequested = nil
	if self.started then
		return
	end
	local count = self:DesiredCount()
	if count == 0 then
		return
	end
	self.started = true
	self.launchedCount = count
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
		-- Both lists name main-state functions the worker can call; they differ in
		-- how. A funcList (2nd) call blocks the worker until the host's frame pump
		-- answers it and hands back return values -- which is exactly the RPC round
		-- trip, and why an idle worker costs no CPU. A subList (3rd) call is queued
		-- and returns nothing, which is all logging needs.
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
	if not self.started then
		-- Never started, or the last fleet was switched off; bring one up from the
		-- frame hook so the workers are warm before the first sort rather than
		-- adding their spin-up to it
		self.startRequested = count > 0 or nil
		return
	end
	if count == self.launchedCount then
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
		-- Nothing will finish these; consumers are waiting on them
		self:AbandonOutstanding()
	end
end

-- Completes every outstanding batch with whatever results arrived, because
-- nothing is left to finish them: the fleet died, failed to start, or was
-- switched off.
function pool:AbandonOutstanding()
	local batches = { }
	for _, job in pairs(self.jobs) do
		batches[job.batch] = true
	end
	self.jobs = { }
	self.jobQueue = { }
	for _, w in pairs(self.workers) do
		w.currentJob = nil
	end
	for batch in pairs(batches) do
		self:FinishBatch(batch, "abandoned")
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
			job.state = "queued"
			job.workerId = nil
			plog("WorkerPool: batch %s shard %d: worker %d died mid-shard, requeued (attempt %d)",
				self:DescribeBatch(job.batch), job.shard, workerId, job.attempts + 1)
			t_insert(self.jobQueue, 1, job)
		end
		w.currentJob = nil
	end
	-- Drop it from the roster, or a resized fleet accumulates one dead entry per
	-- resize; an id that calls in without one is told to quit, which is what a
	-- worker from a previous fleet should hear anyway
	self.workers[workerId] = nil
end

-- Called every frame from Main; detects workers that died without reporting
function pool:OnFrame()
	if self.startRequested and not self.started then
		self:Start()
	end
	if self.aliveCount == 0 and not self.startRequested and next(self.jobs) then
		-- Every worker died (or the fleet never started) while batches were in
		-- flight; release the consumers waiting on them
		self:AbandonOutstanding()
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
		local text = self:StripSyncText(build:SaveDB("worker sync"))
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

-- The Build section embeds display stats from the last calculation
-- (PlayerStat/MinionStat/FullDPSSkill). They are output, not input: the
-- pre-recalc and post-recalc serializations of the same edit differ only
-- there, and leaving them in would resync every worker twice per edit.
-- Workers recalculate everything anyway and never read these.
function pool:StripSyncText(text)
	if not text then
		return nil
	end
	return (text:gsub("%s*<PlayerStat[^>]*/>", ""):gsub("%s*<MinionStat[^>]*/>", ""):gsub("%s*<FullDPSSkill[^>]*/>", ""))
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

-- Drop a batch's queued shards and ignore its in-flight results; used when the
-- request that submitted it has been superseded
function pool:CancelBatch(batch)
	if not batch or BATCH_TERMINAL[batch.state] then
		return
	end
	for i = #self.jobQueue, 1, -1 do
		if self.jobQueue[i].batch == batch then
			self.jobs[self.jobQueue[i].id] = nil
			t_remove(self.jobQueue, i)
		end
	end
	self:FinishBatch(batch, "cancelled")
end

function pool:CompleteJob(jobId, resultJson)
	local job = self.jobs[jobId]
	if not job then
		return
	end
	self.jobs[jobId] = nil
	job.state = "done"
	local batch = job.batch
	if BATCH_TERMINAL[batch.state] then
		-- Superseded or already released: the work is real, but nobody wants it
		return
	end
	if not batch.firstResultAt then
		batch.firstResultAt = GetTime()
		plog("WorkerPool: batch %s: first result +%dms after submit", self:DescribeBatch(batch), batch.firstResultAt - batch.submitAt)
	end
	local result = resultJson and dkjson.decode(resultJson)
	if type(result) ~= "table" then
		result = { workerError = "undecodable result from worker " .. tostring(job.workerId) }
	end
	if result.workerError then
		-- Record the failure against the batch, but keep whatever else the shard
		-- produced: one candidate that throws must not discard its shard-mates
		batch.errorCount = batch.errorCount + 1
		batch.firstError = batch.firstError or tostring(result.workerError)
		plog("WorkerPool: batch %s shard %d (worker %s): %s", self:DescribeBatch(batch), job.shard,
			tostring(job.workerId), tostring(result.workerError))
		result.workerError = nil
	end
	for k, v in pairs(result) do
		if batch.results[k] == nil then
			batch.resultCount = batch.resultCount + 1
		end
		batch.results[k] = v
	end
	batch.pending = batch.pending - 1
	if batch.onProgress then
		fireCallback("progress", batch.onProgress, batch.total - batch.pending, batch.total)
	end
	if batch.pending == 0 then
		self:FinishBatch(batch, "complete")
	end
end

-- The single RPC entry point workers block on; must return quickly
function pool:HandleRPC(workerId, msg, jobId, resultJson)
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
			return "patch", patch.text
		end
		plog("WorkerPool: sync -> worker %d (%d bytes%s)", workerId, #xmlText,
			self.lastContentChange and string.format(", +%dms after change", GetTime() - self.lastContentChange) or "")
		return "sync", xmlText
	end
	if w.syncSentAt then
		-- This is the worker's first call-in after reloading the synced build
		plog("WorkerPool: worker %d resynced in %dms%s", workerId, GetTime() - w.syncSentAt,
			self.lastContentChange and string.format(" (+%dms after change)", GetTime() - self.lastContentChange) or "")
		w.syncSentAt = nil
	end
	return self:DispatchNext(workerId)
end

-- Hands the next queued shard to a worker, or tells it to wait when there is
-- none. Separated from the RPC so the queue-to-worker step can be driven
-- without a subscript host.
function pool:DispatchNext(workerId)
	local job = t_remove(self.jobQueue, 1)
	if not job then
		return "wait"
	end
	local batch = job.batch
	if not batch.firstDispatchAt then
		batch.firstDispatchAt = GetTime()
		batch.state = "active"
		plog("WorkerPool: batch %s: first shard dispatched +%dms after submit (worker %d)",
			self:DescribeBatch(batch), batch.firstDispatchAt - batch.submitAt, workerId)
	end
	job.state = "dispatched"
	job.workerId = workerId
	job.attempts = job.attempts + 1
	local w = self.workers[workerId]
	if w then
		w.currentJob = job.id
	end
	return "job", job.id, job.kind, job.payloadJson
end

function PoBWorkerPoolRPC(workerId, msg, jobId, resultJson)
	return pool:HandleRPC(workerId, msg, jobId, resultJson)
end

-- Shard boundaries for `count` work units, as { first, last } pairs. Several
-- small shards per worker: smoother result streaming and better load balancing
-- than one big shard each, without drowning in per-shard overhead. Shards must
-- stay small either way, since a queued priority job can only start once a
-- worker finishes its current shard, so shard size bounds interactive latency.
-- shardSize (optional) fixes the per-shard unit count: interactive batches with
-- expensive units (FullDPS gem swaps) want tiny shards so first results arrive
-- fast; each shard costs ~a frame of RPC latency, so don't go below ~2
local function shardRanges(aliveCount, count, shardSize)
	local shardCount
	if shardSize then
		shardCount = math.max(1, math.ceil(count / shardSize))
	else
		shardCount = math.max(1, math.min(aliveCount * 8, math.ceil(count / 8)))
	end
	local per = math.ceil(count / shardCount)
	local ranges = { }
	for s = 1, shardCount do
		local first = (s - 1) * per + 1
		if first > count then
			break
		end
		t_insert(ranges, { first, math.min(s * per, count) })
	end
	return ranges
end

-- One shard's payload: the fields every shard of the batch shares, plus this
-- shard's slice of the work
local function shardPayload(common, sliceField, slice)
	local payload = { }
	for k, v in pairs(common) do
		payload[k] = v
	end
	payload[sliceField] = slice
	return payload
end

-- Splits `units` into shards, each carrying the fields of `common` plus its own
-- slice under `field`. How a unit joins a slice is all that differs between the
-- two shapes of job, so the sharding policy itself lives here only.
local function shardUnits(pool, units, field, common, shardSize, addUnit)
	local shards = { }
	for _, range in ipairs(shardRanges(pool.aliveCount, #units, shardSize)) do
		local slice = { }
		for i = range[1], range[2] do
			addUnit(slice, units[i])
		end
		t_insert(shards, shardPayload(common, field, slice))
	end
	return shards
end

-- Jobs whose work units are a plain list (nodePower: evaluation keys, gemDps:
-- gem ids); each shard carries its slice as an array under `listField`
function pool:ShardList(list, listField, common, shardSize)
	return shardUnits(self, list, listField, common, shardSize, function(slice, unit)
		t_insert(slice, unit)
	end)
end

-- Jobs whose work units are identified rather than listed: units are
-- { key = ..., value = ... } pairs and each shard carries its slice as a keyed
-- table under `mapField` (itemPower: item index -> raw item text)
function pool:ShardMap(units, mapField, common, shardSize)
	return shardUnits(self, units, mapField, common, shardSize, function(slice, unit)
		slice[unit.key] = unit.value
	end)
end

-- Submits a batch of shards as one traceable task. opts:
--   request    what this task computes, as a flat table of the inputs the result
--              depends on. Two submissions with equal descriptors are the same
--              task (see FindBatch), and it is what names the batch in the log.
--              Omit it and the batch is never reused.
--   onComplete(results)     once every shard has returned, or the batch was
--              abandoned, with all shard results merged into one table (note that
--              numeric keys come back as strings after the JSON round trip)
--   onProgress(done, total) after each shard returns
--   priority   interactive batches (dropdown sorts) go to the queue front, ahead
--              of bulk background work like heat map rebuilds
-- Returns the batch, or false when there is no usable pool. The batch table is
-- live: results merge in, pending decrements and state advances as shards return,
-- so callers may stream from it instead of waiting for onComplete.
function pool:SubmitBatch(kind, shards, opts)
	if not self:IsAvailable() then
		return false
	end
	opts = opts or { }
	local batch = {
		id = self.nextBatchId,
		kind = kind,
		request = opts.request,
		state = "queued",
		pending = 0,
		total = #shards,
		results = { },
		resultCount = 0,
		errorCount = 0,
		onComplete = opts.onComplete,
		onProgress = opts.onProgress,
		submitAt = GetTime(),
	}
	self.nextBatchId = self.nextBatchId + 1
	for i, payload in ipairs(shards) do
		local job = {
			id = self.nextJobId,
			shard = i,
			kind = kind,
			state = "queued",
			attempts = 0,
			payloadJson = dkjson.encode(payload),
			batch = batch,
		}
		self.nextJobId = self.nextJobId + 1
		self.jobs[job.id] = job
		if opts.priority then
			t_insert(self.jobQueue, batch.pending + 1, job)
		else
			t_insert(self.jobQueue, job)
		end
		batch.pending = batch.pending + 1
	end
	if batch.pending == 0 then
		return false
	end
	self.batches[batch.id] = batch
	plog("WorkerPool: batch %s: %d shards submitted%s%s", self:DescribeBatch(batch), #shards,
		opts.priority and " (priority)" or "",
		self.lastContentChange and string.format(", +%dms after change", GetTime() - self.lastContentChange) or "")
	return batch
end

mainWorkerPool = pool
return pool
