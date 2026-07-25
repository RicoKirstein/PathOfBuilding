-- Path of Building
--
-- Module: Worker Jobs
-- Job handlers and incremental-sync patch application for calculation pool
-- workers. Loaded by Modules/WorkerScript.lua inside worker subscripts, and by
-- the test suite, which verifies each handler against the interactive
-- calculation it mirrors: keep them in sync with their UI counterparts
-- (gemDps: GemSelectControl, itemPower: ItemDBControl, nodePower:
-- CalcsTab.PowerBuilder). All handlers read the global `build`.

local workerJobs = { }
local jobHandlers = { }
workerJobs.handlers = jobHandlers

-- DPS values of candidate gems placed into a specific gem slot; the staging
-- and extraction are the same code the gem dropdown runs
-- (SkillsTab:CalcGemSwapOutput / SkillsTab.ExtractGemDps)
function jobHandlers.gemDps(payload)
	local skillsTab = build.skillsTab
	local group = skillsTab.socketGroupList[payload.groupIndex]
	if not group then
		return { }
	end
	skillsTab.defaultGemLevel = payload.defaultLevel
	skillsTab.defaultGemQuality = payload.defaultQuality
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local dpsField = payload.dpsField
	local useFullDPS = dpsField == "FullDPS"
	-- Ranking by the group's own skill rather than by the build's main skill
	local ownGroupIndex = payload.ownGroup and payload.groupIndex or nil
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
			local okCalc, output = pcall(skillsTab.CalcGemSwapOutput, skillsTab, group, payload.gemIndex, gemData, calcFunc, useFullDPS, nil, ownGroupIndex)
			if okCalc and output then
				results[gemId] = skillsTab.ExtractGemDps(output, dpsField)
			elseif not results.workerError then
				results.workerError = "gemDps: " .. tostring(output)
			end
		end
	end
	return results
end

-- Measured power of candidate items (each given as raw item text) tried in a
-- slot; the measuring is the same code the item DB sort runs
-- (ItemsTab:MeasureItemPower)
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
	if not statEntry then
		-- Returning an empty table here would leave every candidate on its -inf
		-- placeholder and silently produce an unsorted list, so say so instead
		return { workerError = string.format("itemPower: no stat in data.powerStatList matches stat=%q label=%q",
			tostring(payload.stat), tostring(payload.statLabel)) }
	end
	for key, raw in pairs(payload.items) do
		local item = new("Item", raw)
		if item.base then
			results[key] = build.itemsTab:MeasureItemPower(item, statEntry, calcFunc, useFullDPS, payload.slots)
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
	-- Key formats are defined by CalcsTab.BuildNodePowerOverride, next to the
	-- PowerBuilder code that generates them
	local buildOverride = build.calcsTab.BuildNodePowerOverride
	for _, entry in ipairs(payload.nodeIds) do
		local key = tostring(entry)
		local override = buildOverride(build.spec, key)
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

-- Incremental sync: re-loads only the changed build sections (a
-- <PathOfBuilding> document containing them) into the live build, then
-- refreshes the caches and calculators jobs read. Far cheaper than a full
-- build reload. Raises on any failure; the caller falls back to a full sync.
function workerJobs.ApplyPatch(patchXml)
	local ok, errMsg = pcall(function()
		local doc, parseErr = common.xml.ParseXML(patchXml)
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
	if not ok then
		build.deferSpecRebuild = nil
		error(errMsg, 0)
	end
end

return workerJobs
