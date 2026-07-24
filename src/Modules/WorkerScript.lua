-- Path of Building
--
-- Module: Worker Script
-- Program run inside calculation worker subscripts (see Modules/WorkerPool.lua).
-- This file is read as text and passed to LaunchSubScript; it is not LoadModule'd.
-- The worker builds a full headless copy of the program, then loops requesting
-- work from the main thread; the PoBWorkerPoolRPC call blocks (cheaply, inside
-- the host) until the main thread's frame pump answers it.
--
local workerId, srcPath = ...

-- Prevents the worker's own Launch.lua from behaving like the main application
POB_IS_WORKER = true
-- Main.lua reads the interpreter's command-line args table, which subscript
-- states do not have
arg = { }

-- The process working directory belongs to the main script (it points at the user
-- folder after startup), so anchor all relative paths to the src directory
local rawLoadfile = loadfile
local function resolve(name)
	if name:match("^%a:[/\\]") or name:match("^[/\\]") then
		return name
	end
	return srcPath .. "/" .. name
end
function loadfile(name)
	return rawLoadfile(resolve(name))
end
local rawDofile = dofile
function dofile(name)
	return rawDofile(resolve(name))
end
-- Data files are also read with relative io.open (e.g. Data/ModFoulbornMap.jsonc)
local rawOpen = io.open
function io.open(name, mode)
	return rawOpen(resolve(name), mode)
end

local ok, err = pcall(dofile, "HeadlessWrapper.lua")
if not ok then
	PoBWorkerPoolRPC(workerId, "fatal", 0, nil, "environment load failed: " .. tostring(err))
	return "failed"
end
if not loadBuildFromXML then
	PoBWorkerPoolRPC(workerId, "fatal", 0, nil, "environment incomplete: " .. tostring(mainObject and mainObject.promptMsg))
	return "failed"
end
-- The headless stub returns "", which breaks TimelessJewelData loading
function GetScriptPath()
	return srcPath
end

local dkjson = require("dkjson")

local jobHandlers = { }

-- DPS values of candidate gems placed into a specific gem slot; mirrors
-- GemSelectControl:CalcOutputWithThisGem and the extraction in BuildSortCache
function jobHandlers.gemDps(payload)
	local skillsTab = build.skillsTab
	local group = skillsTab.socketGroupList[payload.groupIndex]
	if not group then
		return { }
	end
	skillsTab.defaultGemLevel = payload.defaultLevel
	skillsTab.defaultGemQuality = payload.defaultQuality
	local gemList = group.gemList
	local index = payload.gemIndex
	local oldGem = gemList[index] and copyTable(gemList[index], true)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local dpsField = payload.dpsField
	local useFullDPS = dpsField == "FullDPS"
	local results = { }
	for _, gemId in ipairs(payload.gemIds) do
		-- Dropdown gem keys carry a variant prefix ("Default:<id>") that the data
		-- table does not use
		local gemData = build.data.gems[gemId]
		if not gemData then
			local rawId = gemId:match("^[^:]+:(.+)")
			gemData = rawId and build.data.gems[rawId]
		end
		if gemData then
			gemList[index] = {
				level = gemData.naturalMaxLevel,
				quality = skillsTab.defaultGemQuality or 0,
				count = 1,
				enabled = true,
				enableGlobal1 = true,
				enableGlobal2 = true,
				gemId = gemData.id,
				nameSpec = gemData.name,
				skillId = gemData.grantedEffectId,
			}
			local gemInstance = gemList[index]
			gemInstance.level = skillsTab:ProcessGemLevel(gemData)
			gemInstance.gemData = gemData
			local okCalc, output = pcall(calcFunc, nil, useFullDPS)
			if okCalc and output then
				results[gemId] = (dpsField == "FullDPS" and output[dpsField] ~= nil and output[dpsField]) or (output.Minion and output.Minion.CombinedDPS) or (output[dpsField] ~= nil and output[dpsField]) or 0
			elseif not results.workerError then
				results.workerError = "gemDps: " .. tostring(output)
			end
		end
	end
	gemList[index] = oldGem
	return results
end

-- Measured power of candidate items (each given as raw item text) tried in a
-- slot; mirrors the stat-sort loop in ItemDBControl:ListBuilder
function jobHandlers.itemPower(payload)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local useFullDPS = payload.stat == "FullDPS"
	local statEntry
	for _, entry in ipairs(data.powerStatList) do
		if entry.stat == payload.stat and entry.label == payload.statLabel then
			statEntry = entry
			break
		end
	end
	local results = { }
	for key, raw in pairs(payload.items) do
		local item = new("Item", raw)
		if item.base then
			local best
			for _, slotName in ipairs(payload.slots) do
				if build.itemsTab:IsItemValidForSlot(item, slotName) then
					local override = item.base.flask and { toggleFlask = item } or item.base.tincture and { toggleTincture = item } or { repSlotName = slotName, repItem = item }
					local okCalc, output = pcall(calcFunc, override, useFullDPS)
					if okCalc and output and statEntry then
						local power = data.powerStatList.GetFromOutput(output, statEntry)
						if not best or power > best then
							best = power
						end
					end
				end
			end
			results[key] = best
		end
	end
	return results
end

-- Per-node outputs for the tree heat map: each candidate node is added to the
-- build and the listed output stats extracted (plus minion DPS for the combined
-- offence metric)
function jobHandlers.nodePower(payload)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local results = { }
	local function extract(output)
		local vec = { }
		for _, stat in ipairs(payload.stats) do
			if type(output[stat]) == "number" then
				vec[stat] = output[stat]
			end
		end
		if output.Minion and type(output.Minion.CombinedDPS) == "number" then
			vec.Minion = { CombinedDPS = output.Minion.CombinedDPS }
		end
		return vec
	end
	-- Entries are typed: "123" adds node 123, "r123" removes allocated node 123,
	-- "m123/456" tries mastery effect 456 on mastery node 123
	for _, entry in ipairs(payload.nodeIds) do
		local override
		local key = tostring(entry)
		local removeId = key:match("^r(%d+)$")
		local masteryId, effectId = key:match("^m(%d+)/(%d+)$")
		if removeId then
			local node = build.spec.nodes[tonumber(removeId)]
			if node then
				override = { removeNodes = { [node] = true } }
			end
		elseif masteryId then
			local node = build.spec.nodes[tonumber(masteryId)]
			local effect = build.spec.tree.masteryEffects[tonumber(effectId)]
			if node and effect then
				local effectNode = { id = node.id, type = node.type, name = node.name, sd = { } }
				for i, sd in ipairs(effect.sd or { }) do
					effectNode.sd[i] = sd
				end
				build.spec.tree:ProcessStats(effectNode)
				override = { addNodes = { [effectNode] = true } }
			end
		elseif key:byte(1) == 99 then -- "c<name>": cluster notable by name
			local node = build.spec.tree.clusterNodeMap[key:sub(2)]
			if node then
				override = { addNodes = { [node] = true } }
			end
		elseif key:byte(1) == 112 then -- "p<id>": allocated node plus its dependents removed
			local node = build.spec.nodes[tonumber(key:sub(2))]
			if node and node.depends then
				local pathNodes = { }
				for _, depNode in ipairs(node.depends) do
					pathNodes[depNode] = true
				end
				override = { removeNodes = pathNodes }
			end
		else
			local node = build.spec.nodes[tonumber(key)]
			if node then
				override = { addNodes = { [node] = true } }
			end
		end
		if override then
			local okCalc, output = pcall(calcFunc, override, payload.useFullDPS)
			if okCalc and output then
				results[key] = extract(output)
			end
		end
	end
	return results
end

-- Generic per-node stat evaluation, used for validation and benchmarks
function jobHandlers.nodeAddStat(payload)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local results = { }
	for _, nodeId in ipairs(payload.nodeIds) do
		local node = build.spec.nodes[nodeId]
		if node then
			local output = calcFunc({ addNodes = { [node] = true } }, false)
			results[nodeId] = output[payload.stat] or 0
		end
	end
	return results
end

local revision = -1
local lastJobId, lastResultJson
while true do
	local cmd, a, b, c = PoBWorkerPoolRPC(workerId, "ready", revision, lastJobId, lastResultJson)
	lastJobId, lastResultJson = nil, nil
	if cmd == nil or cmd == "quit" then
		return "quit"
	elseif cmd == "sync" then
		local okLoad, errLoad = pcall(loadBuildFromXML, b, "worker")
		if okLoad then
			revision = a
		else
			PoBWorkerPoolRPC(workerId, "fatal", revision, nil, "build sync failed: " .. tostring(errLoad))
			return "failed"
		end
	elseif cmd == "patch" then
		-- Incremental sync: re-load only the changed build sections into the live
		-- build, then refresh the caches and calculators that jobs read. Far
		-- cheaper than a full build reload; any failure falls back to one.
		local okPatch, errPatch = pcall(function()
			-- The patch document arrives in the same argument slot as the full
			-- build XML of a "sync" command
			local doc, parseErr = common.xml.ParseXML(b)
			local root = doc and doc[1]
			if not root then
				error("patch parse failed: " .. tostring(parseErr))
			end
			-- Collapse any depends/paths rebuilds the section loads trigger into one
			build.deferSpecRebuild = true
			local loaded = { }
			for _, node in ipairs(root) do
				if type(node) == "table" and node.elem then
					local saver = build.savers[node.elem]
					if not saver then
						error("no saver for section " .. node.elem)
					end
					if saver:Load(node, build.dbFileName) then
						error("saver rejected section " .. node.elem)
					end
					loaded[#loaded + 1] = saver
				end
			end
			for _, saver in ipairs(loaded) do
				if saver.PostLoad then
					saver:PostLoad()
				end
			end
			build.deferSpecRebuild = nil
			if build.spec and build.spec.rebuildPending then
				build.spec:BuildAllDependsAndPaths()
			end
			wipeGlobalCache()
			build.outputRevision = (build.outputRevision or 1) + 1
			build.buildFlag = false
			-- Job handlers only use the misc calculator; refresh it (one base pass)
			-- instead of the several passes a full BuildOutput would run. The node
			-- calculator is emptied rather than refreshed so accidental use by a
			-- future handler fails loudly instead of computing on stale state.
			local calcs = build.calcsTab.calcs
			build.calcsTab.miscCalculator = { calcs.getMiscCalculator(build) }
			build.calcsTab.nodeCalculator = { }
		end)
		if okPatch then
			revision = a
		else
			build.deferSpecRebuild = nil
			-- Response intentionally ignored; the next "ready" round trip will be
			-- answered with a full sync
			PoBWorkerPoolRPC(workerId, "patchfail", revision, nil, tostring(errPatch))
		end
	elseif cmd == "job" then
		local okJob, result = pcall(function()
			local payload = dkjson.decode(c)
			local handler = jobHandlers[b]
			return handler and handler(payload) or { workerError = "unknown job kind: " .. tostring(b) }
		end)
		lastJobId = a
		lastResultJson = dkjson.encode(okJob and result or { workerError = tostring(result) })
		-- Keep the state's share of the process memory arena bounded, but a full
		-- collection is far too slow to run per shard
		if collectgarbage("count") > 300000 then
			collectgarbage("collect")
		end
	end
	-- cmd == "wait": loop immediately; the next call blocks until the main thread
	-- has something new for this worker
end
