-- Path of Building
--
-- Module: MCP Commands
-- The command surface exposed over the MCP bridge (see Modules/McpServer.lua):
-- every operation an external client can perform on the build that is currently
-- open. Handlers run on the main thread, mutate the same objects the UI does, and
-- push an undo state for anything they change, so edits made from outside are
-- indistinguishable from edits made by hand and can be reverted with Ctrl+Z.
--
-- This module deliberately holds no transport or threading logic: it is a plain
-- table of functions over `main.modes.BUILD`, which lets the spec suite drive it
-- against a headless build.
--
local t_insert = table.insert
local t_sort = table.sort
local m_floor = math.floor
local m_huge = math.huge
local s_format = string.format

local mcp = { }
local commands = { }
mcp.commands = commands

-- Records which tab a mutation touched so `build.undo` knows what to revert when
-- the caller does not name a target
mcp.lastMutated = nil

--------------------
-- Shared helpers --
--------------------

-- Every handler starts here: the bridge is only meaningful while a build is open,
-- and reporting that clearly beats a nil index error deep inside a handler
local function getBuild()
	if not main or main.mode ~= "BUILD" or not main.modes.BUILD then
		error("no build is currently open in Path of Building", 0)
	end
	return main.modes.BUILD
end
mcp.getBuild = getBuild

local function stripColor(text)
	if type(text) ~= "string" then
		return text
	end
	if StripEscapes then
		-- Parenthesised: the headless implementation is a gsub chain and would
		-- otherwise leak its replacement count as a second return value
		return (StripEscapes(text))
	end
	return (text:gsub("%^%d", ""):gsub("%^x%x%x%x%x%x%x", ""))
end

local function req(params, name)
	local value = params and params[name]
	if value == nil then
		error("missing required parameter '" .. name .. "'", 0)
	end
	return value
end

-- Numeric parameters arrive as JSON numbers but are frequently produced by
-- clients as strings; accept both rather than failing on a quoted node id
local function reqNumber(params, name)
	local value = tonumber(req(params, name))
	if not value then
		error("parameter '" .. name .. "' must be a number", 0)
	end
	return value
end

-- Node ids may be given singly or as a list; normalise to a list of numbers
local function nodeIdList(params, name)
	local raw = req(params, name)
	if type(raw) ~= "table" then
		raw = { raw }
	end
	local ids = { }
	for _, id in ipairs(raw) do
		local num = tonumber(id)
		if not num then
			error("'" .. name .. "' contains a non-numeric node id: " .. tostring(id), 0)
		end
		t_insert(ids, num)
	end
	if not ids[1] then
		error("'" .. name .. "' is empty", 0)
	end
	return ids
end

local function getNode(build, id)
	local node = build.spec.nodes[id]
	if not node then
		error("no passive node with id " .. tostring(id) .. " on tree version " .. tostring(build.spec.treeVersion), 0)
	end
	return node
end

-- Marks the build dirty and recalculates immediately, so a mutating command can
-- answer with the stats that resulted from it instead of the stats from before.
-- Callers pass recalc=false when they are about to make further edits.
local function applyChange(build, params, tab)
	mcp.lastMutated = tab or mcp.lastMutated
	build.buildFlag = true
	build.modFlag = true
	if params and params.recalc == false then
		return { recalculated = false }
	end
	build:PerformRecalc()
	return { recalculated = true }
end

local function nodeSummary(node, spec)
	local summary = {
		id = node.id,
		name = node.dn,
		type = node.type,
		allocated = node.alloc and true or false,
	}
	if node.ascendancyName then
		summary.ascendancy = node.ascendancyName
	end
	if node.isBlighted then
		summary.blighted = true
	end
	if node.sd and node.sd[1] then
		local stats = { }
		for _, line in ipairs(node.sd) do
			t_insert(stats, stripColor(line))
		end
		summary.stats = stats
	end
	if spec and not node.alloc and node.pathDist and node.pathDist < 1000 then
		summary.pointsToReach = node.pathDist
	end
	return summary
end
mcp.nodeSummary = nodeSummary

-- The sidebar stat list is the authoritative view of "what this build does": it
-- already applies every flag, condition and formatting rule. Reading it back is
-- both cheaper and more faithful than re-deriving the same list here.
local function sidebarStats(build)
	local stats = { }
	for _, entry in ipairs(build.controls.statBox.list) do
		local label, value = entry[1], entry[2]
		if label and value then
			label = stripColor(label):gsub(":%s*$", "")
			t_insert(stats, { label = label, value = stripColor(value) })
		end
	end
	return stats
end

local function buildWarnings(build)
	local warnings = { }
	for _, line in ipairs(build.controls.warnings.lines or { }) do
		t_insert(warnings, stripColor(line))
	end
	return warnings
end

-----------------------
-- Build-level state --
-----------------------

commands["build.info"] = function(params)
	local build = getBuild()
	local spec = build.spec
	local usedPoints, ascUsedPoints, secondaryAscUsedPoints = spec:CountAllocNodes()
	local info = {
		name = build.buildName,
		unsaved = build.unsaved and true or false,
		characterLevel = build.characterLevel,
		className = spec.curClassName,
		ascendancyName = spec.curAscendClassName,
		treeVersion = spec.treeVersion,
		-- 99 from levelling plus 23 from quests, matching the point counter in the
		-- title bar; ExtraPoints covers sources like the Forbidden Sanctum
		passivePoints = {
			used = usedPoints,
			max = 99 + 23 + ((build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints) or 0),
		},
		ascendancyPoints = { used = ascUsedPoints, max = 8 },
		mainSocketGroup = build.mainSocketGroup,
		activeSpecIndex = build.activeSpecIndex,
		activeItemSetId = build.itemsTab.activeItemSetId,
		activeSkillSetId = build.skillsTab.activeSkillSetId,
		activeConfigSetId = build.configTab.activeConfigSetId,
	}
	if spec.curSecondaryAscendClassName and spec.curSecondaryAscendClassName ~= "None" then
		info.secondaryAscendancyName = spec.curSecondaryAscendClassName
		info.secondaryAscendancyPoints = { used = secondaryAscUsedPoints }
	end
	local mainSkill = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player.mainSkill
	if mainSkill and mainSkill.activeEffect then
		info.mainSkill = mainSkill.activeEffect.grantedEffect.name
	end
	return info
end

commands["build.stats"] = function(params)
	local build = getBuild()
	build:PerformRecalc()
	local result = {
		stats = sidebarStats(build),
		warnings = buildWarnings(build),
	}
	-- The raw output table carries every derived number the calculations produce,
	-- including the many that never reach the sidebar; useful for questions the
	-- sidebar cannot answer, but far too large to return by default
	if params and params.full then
		local output = { }
		for key, value in pairs(build.calcsTab.mainOutput) do
			if type(value) == "number" and value == value and value ~= m_huge and value ~= -m_huge then
				output[key] = value
			elseif type(value) == "boolean" then
				output[key] = value
			end
		end
		result.output = output
	end
	return result
end

commands["build.recalculate"] = function(params)
	local build = getBuild()
	local didWork = build:PerformRecalc()
	return { recalculated = didWork, stats = sidebarStats(build) }
end

commands["build.export_code"] = function(params)
	local build = getBuild()
	build:PerformRecalc()
	local xmlText = build:SaveDB("code")
	if not xmlText then
		error("failed to serialize the build", 0)
	end
	local deflated = Deflate(xmlText)
	if not deflated or deflated == "" then
		error("Deflate is unavailable in this environment; export requires the full application", 0)
	end
	return { code = common.base64.encode(deflated):gsub("+", "-"):gsub("/", "_") }
end

commands["build.import_code"] = function(params)
	local build = getBuild()
	local code = req(params, "code")
	-- Importing overwrites every part of the open build, so make the caller say so
	if params.confirm ~= true then
		error("build.import_code replaces the entire open build; pass confirm=true to proceed", 0)
	end
	local xmlText = Inflate(common.base64.decode(code:gsub("%s", ""):gsub("%-", "+"):gsub("_", "/")))
	if not xmlText or xmlText == "" then
		error("could not decode the build code", 0)
	end
	build:LoadDB(xmlText, "MCP import")
	build.modFlag = true
	build.buildFlag = true
	build:PerformRecalc()
	return { imported = true, stats = sidebarStats(build) }
end

commands["build.save"] = function(params)
	local build = getBuild()
	if not build.dbFileName then
		error("this build has never been saved; save it once from the UI to give it a file name", 0)
	end
	build:SaveDBFile()
	return { saved = true, fileName = build.dbFileName }
end

-- Undo/redo are per-tab in Path of Building, matching where Ctrl+Z was pressed.
-- Without an explicit target, revert the tab this bridge last touched.
local undoTargets = {
	tree = function(build) return build.spec end,
	items = function(build) return build.itemsTab end,
	skills = function(build) return build.skillsTab end,
	config = function(build) return build.configTab end,
}

local function undoRedo(params, method)
	local build = getBuild()
	local target = (params and params.target) or mcp.lastMutated
	if not target then
		error("no target given and nothing has been changed through the bridge yet; pass target=tree|items|skills|config", 0)
	end
	local resolve = undoTargets[target]
	if not resolve then
		error("unknown undo target '" .. tostring(target) .. "'; expected tree, items, skills or config", 0)
	end
	local handler = resolve(build)
	handler[method](handler)
	if target == "tree" then
		build.spec:BuildAllDependsAndPaths()
	elseif target == "items" then
		build.itemsTab:PopulateSlots()
	elseif target == "config" then
		build.configTab:BuildModList()
	end
	build.buildFlag = true
	build:PerformRecalc()
	return { target = target, stats = sidebarStats(build) }
end

commands["build.undo"] = function(params) return undoRedo(params, "Undo") end
commands["build.redo"] = function(params) return undoRedo(params, "Redo") end

------------------
-- Passive tree --
------------------

commands["tree.get"] = function(params)
	local build = getBuild()
	local spec = build.spec
	local usedPoints, ascUsedPoints = spec:CountAllocNodes()
	local allocated, keystones, masteries, sockets = { }, { }, { }, { }
	for id, node in pairs(spec.allocNodes) do
		if node.type == "Keystone" then
			t_insert(keystones, node.dn)
		elseif node.type == "Socket" then
			local jewelId = spec.jewels[id]
			local jewel = jewelId and jewelId ~= 0 and build.itemsTab.items[jewelId]
			t_insert(sockets, { nodeId = id, jewel = jewel and jewel.name or nil, itemId = jewel and jewel.id or nil })
		elseif node.type == "Mastery" then
			local effectId = spec.masterySelections[id]
			local effect = effectId and spec.tree.masteryEffects[effectId]
			t_insert(masteries, {
				nodeId = id,
				name = node.dn,
				effect = effect and stripColor(effect.sd and effect.sd[1] or "") or nil,
			})
		end
		-- ClassStart nodes are structural, not choices the user made
		if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			t_insert(allocated, { id = id, name = node.dn, type = node.type, ascendancy = node.ascendancyName })
		end
	end
	t_sort(allocated, function(a, b) return a.id < b.id end)
	t_sort(keystones)
	return {
		className = spec.curClassName,
		ascendancyName = spec.curAscendClassName,
		treeVersion = spec.treeVersion,
		pointsUsed = usedPoints,
		ascendancyPointsUsed = ascUsedPoints,
		allocatedCount = #allocated,
		allocated = allocated,
		keystones = keystones,
		masteries = masteries,
		jewelSockets = sockets,
		url = spec:EncodeURL("https://www.pathofexile.com/passive-skill-tree/"),
	}
end

commands["tree.search"] = function(params)
	local build = getBuild()
	local query = tostring(req(params, "query")):lower()
	local limit = tonumber(params.limit) or 40
	local wantTypes
	if params.type then
		wantTypes = { }
		local list = type(params.type) == "table" and params.type or { params.type }
		for _, entry in ipairs(list) do
			wantTypes[tostring(entry)] = true
		end
	end
	local matches = { }
	for id, node in pairs(build.spec.nodes) do
		local include = not wantTypes or wantTypes[node.type]
		if include and params.allocatedOnly and not node.alloc then
			include = false
		end
		if include and node.ascendancyName and params.excludeAscendancy then
			include = false
		end
		if include then
			-- Name matches rank above stat-text matches: someone searching
			-- "Blood Magic" wants the keystone, not the twenty nodes mentioning it
			local score
			if node.dn and node.dn:lower():find(query, 1, true) then
				score = node.dn:lower() == query and 0 or 1
			elseif node.sd then
				for _, line in ipairs(node.sd) do
					if stripColor(line):lower():find(query, 1, true) then
						score = 2
						break
					end
				end
			end
			if score then
				local summary = nodeSummary(node, build.spec)
				summary.score = score
				t_insert(matches, summary)
			end
		end
	end
	t_sort(matches, function(a, b)
		if a.score ~= b.score then return a.score < b.score end
		if (a.pointsToReach or 999) ~= (b.pointsToReach or 999) then
			return (a.pointsToReach or 999) < (b.pointsToReach or 999)
		end
		return a.id < b.id
	end)
	local total = #matches
	for i = #matches, limit + 1, -1 do
		matches[i] = nil
	end
	for _, match in ipairs(matches) do
		match.score = nil
	end
	return { total = total, returned = #matches, truncated = total > #matches, nodes = matches }
end

commands["tree.node"] = function(params)
	local build = getBuild()
	local node = getNode(build, reqNumber(params, "id"))
	local info = nodeSummary(node, build.spec)
	if node.path and #node.path > 0 and not node.alloc then
		local path = { }
		for _, pathNode in ipairs(node.path) do
			t_insert(path, { id = pathNode.id, name = pathNode.dn, type = pathNode.type })
		end
		info.path = path
	end
	if node.alloc and node.depends and #node.depends > 1 then
		-- Nodes that would come off the tree with this one
		local depends = { }
		for _, depNode in ipairs(node.depends) do
			if depNode ~= node then
				t_insert(depends, { id = depNode.id, name = depNode.dn })
			end
		end
		info.dependents = depends
	end
	return info
end

-- Shared by tree.preview and tree.power: measures a hypothetical tree change
-- through the misc calculator without touching the live build
local function measureNodes(build, addIds, removeIds)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local override = { }
	if addIds and addIds[1] then
		override.addNodes = { }
		for _, id in ipairs(addIds) do
			override.addNodes[getNode(build, id)] = true
		end
	end
	if removeIds and removeIds[1] then
		override.removeNodes = { }
		for _, id in ipairs(removeIds) do
			override.removeNodes[getNode(build, id)] = true
		end
	end
	return calcFunc(override, true)
end

-- The stats worth reporting for a hypothetical change. Kept short on purpose:
-- a diff of the full output table is noise, and these are the numbers a build
-- decision actually turns on.
local COMPARE_STATS = {
	{ key = "FullDPS", label = "Full DPS" },
	{ key = "TotalDPS", label = "Hit DPS" },
	{ key = "CombinedDPS", label = "Combined DPS" },
	{ key = "AverageDamage", label = "Average Damage" },
	{ key = "Life", label = "Life" },
	{ key = "LifeUnreserved", label = "Unreserved Life" },
	{ key = "EnergyShield", label = "Energy Shield" },
	{ key = "Mana", label = "Mana" },
	{ key = "Armour", label = "Armour" },
	{ key = "Evasion", label = "Evasion" },
	{ key = "TotalEHP", label = "Effective Hit Pool" },
	{ key = "FireResist", label = "Fire Resistance" },
	{ key = "ColdResist", label = "Cold Resistance" },
	{ key = "LightningResist", label = "Lightning Resistance" },
	{ key = "ChaosResist", label = "Chaos Resistance" },
	{ key = "Str", label = "Strength" },
	{ key = "Dex", label = "Dexterity" },
	{ key = "Int", label = "Intelligence" },
}

local function compareOutputs(baseOutput, newOutput)
	local changes = { }
	for _, statData in ipairs(COMPARE_STATS) do
		local before, after = baseOutput[statData.key], newOutput[statData.key]
		if type(before) == "number" and type(after) == "number" and before ~= after
			and before == before and after == after and before ~= m_huge and after ~= m_huge then
			t_insert(changes, {
				stat = statData.key,
				label = statData.label,
				before = before,
				after = after,
				delta = after - before,
				percent = before ~= 0 and ((after - before) / math.abs(before) * 100) or nil,
			})
		end
	end
	return changes
end
mcp.compareOutputs = compareOutputs

commands["tree.preview"] = function(params)
	local build = getBuild()
	build:PerformRecalc()
	local addIds = params.allocate and nodeIdList(params, "allocate") or nil
	local removeIds = params.deallocate and nodeIdList(params, "deallocate") or nil
	if not addIds and not removeIds then
		error("pass 'allocate' and/or 'deallocate' with node ids to preview", 0)
	end
	local newOutput = measureNodes(build, addIds, removeIds)
	return { changes = compareOutputs(build.calcsTab.mainOutput, newOutput) }
end

-- Builds that do not aggregate Full DPS leave FullDPS at zero, which would make
-- every candidate score zero. Fall back through the damage stats until one is
-- actually populated, so the default works for any build.
local DEFAULT_POWER_STATS = { "FullDPS", "CombinedDPS", "TotalDPS", "AverageDamage", "TotalEHP" }

commands["tree.power"] = function(params)
	local build = getBuild()
	build:PerformRecalc()
	local baseOutput = build.calcsTab.mainOutput
	local stat = params.stat
	if not stat then
		for _, candidate in ipairs(DEFAULT_POWER_STATS) do
			local value = baseOutput[candidate]
			if type(value) == "number" and value > 0 then
				stat = candidate
				break
			end
		end
		if not stat then
			error("this build has no non-zero damage or defence stat to rank nodes by; pass 'stat' explicitly", 0)
		end
	end
	local limit = tonumber(params.limit) or 20
	local maxPointsAway = tonumber(params.maxPointsAway) or 3
	local base = baseOutput[stat]
	if type(base) ~= "number" then
		error("'" .. tostring(stat) .. "' is not a numeric stat in the current output", 0)
	end
	-- Only unallocated nodes that are actually reachable within a few points are
	-- interesting; scoring the whole tree costs a full calculation per node
	local candidates = { }
	for id, node in pairs(build.spec.nodes) do
		if not node.alloc and node.path and #node.path > 0 and #node.path <= maxPointsAway
			and (node.type == "Notable" or node.type == "Keystone" or node.type == "Normal")
			and node.modKey and node.modKey ~= "" then
			t_insert(candidates, node)
		end
	end
	t_sort(candidates, function(a, b) return a.id < b.id end)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local scored = { }
	for _, node in ipairs(candidates) do
		-- Score the whole path, since that is what allocating the node costs
		local addNodes = { }
		for _, pathNode in ipairs(node.path) do
			addNodes[pathNode] = true
		end
		local output = calcFunc({ addNodes = addNodes }, true)
		local value = output[stat]
		if type(value) == "number" and value == value and value ~= m_huge and value ~= base then
			t_insert(scored, {
				id = node.id,
				name = node.dn,
				type = node.type,
				pointsToReach = #node.path,
				before = base,
				after = value,
				delta = value - base,
				percent = base ~= 0 and ((value - base) / math.abs(base) * 100) or nil,
				perPoint = (value - base) / #node.path,
			})
		end
	end
	t_sort(scored, function(a, b) return a.perPoint > b.perPoint end)
	local evaluated = #scored
	for i = #scored, limit + 1, -1 do
		scored[i] = nil
	end
	return { stat = stat, base = base, evaluated = evaluated, nodes = scored }
end

commands["tree.allocate"] = function(params)
	local build = getBuild()
	local ids = nodeIdList(params, "ids")
	local allocated, skipped = { }, { }
	for _, id in ipairs(ids) do
		local node = getNode(build, id)
		if node.alloc then
			t_insert(skipped, { id = id, name = node.dn, reason = "already allocated" })
		elseif not node.path or #node.path == 0 then
			t_insert(skipped, { id = id, name = node.dn, reason = "no path to this node from the allocated tree" })
		else
			local pathLength = #node.path
			build.spec:AllocNode(node)
			t_insert(allocated, { id = id, name = node.dn, pointsSpent = pathLength })
		end
	end
	if allocated[1] then
		build.spec:AddUndoState()
		build.spec:SetWindowTitleWithBuildClass()
	end
	local usedPoints, ascUsedPoints = build.spec:CountAllocNodes()
	local result = applyChange(build, params, "tree")
	result.allocated = allocated
	result.skipped = skipped
	result.pointsUsed = usedPoints
	result.ascendancyPointsUsed = ascUsedPoints
	result.stats = sidebarStats(build)
	return result
end

commands["tree.deallocate"] = function(params)
	local build = getBuild()
	local ids = nodeIdList(params, "ids")
	local removed, skipped = { }, { }
	for _, id in ipairs(ids) do
		local node = getNode(build, id)
		if not node.alloc then
			t_insert(skipped, { id = id, name = node.dn, reason = "not allocated" })
		elseif node.type == "ClassStart" or node.type == "AscendClassStart" then
			t_insert(skipped, { id = id, name = node.dn, reason = "class start nodes cannot be deallocated" })
		else
			-- Deallocating takes every node that only reaches the tree through this
			-- one with it; report them so the caller is not surprised by the count
			local alsoRemoved = { }
			for _, depNode in ipairs(node.depends) do
				if depNode ~= node then
					t_insert(alsoRemoved, { id = depNode.id, name = depNode.dn })
				end
			end
			build.spec:DeallocNode(node)
			t_insert(removed, { id = id, name = node.dn, dependents = alsoRemoved })
		end
	end
	if removed[1] then
		build.spec:AddUndoState()
		build.spec:SetWindowTitleWithBuildClass()
	end
	local usedPoints, ascUsedPoints = build.spec:CountAllocNodes()
	local result = applyChange(build, params, "tree")
	result.removed = removed
	result.skipped = skipped
	result.pointsUsed = usedPoints
	result.ascendancyPointsUsed = ascUsedPoints
	result.stats = sidebarStats(build)
	return result
end

commands["tree.set_class"] = function(params)
	local build = getBuild()
	local spec = build.spec
	local classId, ascendId
	if params.className then
		local wanted = tostring(params.className):lower()
		for id, class in pairs(spec.tree.classes) do
			if class.name:lower() == wanted then
				classId = id
				break
			end
		end
		if not classId then
			error("unknown class '" .. tostring(params.className) .. "'", 0)
		end
	end
	-- Changing class wipes the tree, so resolve the ascendancy against the class
	-- that will be active once the change lands, not the one active now
	local targetClass = spec.tree.classes[classId or spec.curClassId]
	if params.ascendancyName then
		local wanted = tostring(params.ascendancyName):lower()
		for id, ascend in pairs(targetClass.classes) do
			if ascend.name:lower() == wanted then
				ascendId = id
				break
			end
		end
		if not ascendId then
			error("unknown ascendancy '" .. tostring(params.ascendancyName) .. "' for class " .. targetClass.name, 0)
		end
	end
	if classId and classId ~= spec.curClassId then
		if params.confirm ~= true then
			error("changing class resets the whole passive tree; pass confirm=true to proceed", 0)
		end
		spec:SelectClass(classId)
	end
	if ascendId then
		spec:SelectAscendClass(ascendId)
	end
	spec:AddUndoState()
	spec:SetWindowTitleWithBuildClass()
	build:SyncLoadouts()
	local result = applyChange(build, params, "tree")
	result.className = spec.curClassName
	result.ascendancyName = spec.curAscendClassName
	result.stats = sidebarStats(build)
	return result
end

commands["tree.import_url"] = function(params)
	local build = getBuild()
	local url = tostring(req(params, "url"))
	local errMsg = build.spec:DecodeURL(url)
	if errMsg then
		error(errMsg, 0)
	end
	build.spec:AddUndoState()
	build.spec:SetWindowTitleWithBuildClass()
	build:SyncLoadouts()
	local usedPoints = build.spec:CountAllocNodes()
	local result = applyChange(build, params, "tree")
	result.className = build.spec.curClassName
	result.ascendancyName = build.spec.curAscendClassName
	result.pointsUsed = usedPoints
	result.stats = sidebarStats(build)
	return result
end

commands["tree.export_url"] = function(params)
	local build = getBuild()
	return { url = build.spec:EncodeURL("https://www.pathofexile.com/passive-skill-tree/") }
end

-----------
-- Items --
-----------

local function itemSummary(item, slotName)
	local summary = {
		id = item.id,
		name = item.name,
		rarity = item.rarity,
		baseName = item.baseName,
		itemLevel = item.itemLevel,
		quality = item.quality,
		corrupted = item.corrupted and true or nil,
		slot = slotName,
	}
	if item.title then
		summary.title = item.title
	end
	return summary
end

commands["items.list"] = function(params)
	local build = getBuild()
	local itemsTab = build.itemsTab
	local slots = { }
	for _, slot in ipairs(itemsTab.orderedSlots) do
		if not slot.inactive and slot:IsShown() then
			local item = slot.selItemId ~= 0 and itemsTab.items[slot.selItemId]
			t_insert(slots, {
				slot = slot.slotName,
				label = slot.label,
				item = item and itemSummary(item, slot.slotName) or nil,
			})
		end
	end
	local result = { slots = slots, activeItemSetId = itemsTab.activeItemSetId }
	-- The build's item pool holds unequipped items too; they are what the caller
	-- swaps between, so list them unless asked not to
	if params and params.includeUnequipped ~= false then
		local equipped = { }
		for _, slot in pairs(itemsTab.slots) do
			if slot.selItemId and slot.selItemId ~= 0 then
				equipped[slot.selItemId] = true
			end
		end
		local unequipped = { }
		for _, itemId in ipairs(itemsTab.itemOrderList) do
			local item = itemsTab.items[itemId]
			if item and not equipped[itemId] then
				t_insert(unequipped, itemSummary(item))
			end
		end
		result.unequipped = unequipped
	end
	return result
end

local function resolveItem(build, params)
	local itemsTab = build.itemsTab
	if params.itemId then
		local item = itemsTab.items[tonumber(params.itemId)]
		if not item then
			error("no item with id " .. tostring(params.itemId) .. " in this build", 0)
		end
		return item
	end
	local slotName = req(params, "slot")
	local slot = itemsTab.slots[slotName]
	if not slot then
		error("unknown slot '" .. tostring(slotName) .. "'", 0)
	end
	if slot.selItemId == 0 then
		error("slot '" .. slotName .. "' is empty", 0)
	end
	return itemsTab.items[slot.selItemId], slot
end

commands["items.get"] = function(params)
	local build = getBuild()
	local item, slot = resolveItem(build, params)
	local summary = itemSummary(item, slot and slot.slotName)
	summary.raw = item.raw
	local mods = { }
	for _, modList in ipairs({ item.implicitModLines or { }, item.explicitModLines or { } }) do
		for _, modLine in ipairs(modList) do
			t_insert(mods, { line = stripColor(modLine.line), unsupported = modLine.mods and #modLine.mods == 0 or nil })
		end
	end
	summary.mods = mods
	return summary
end

commands["items.set"] = function(params)
	local build = getBuild()
	local itemsTab = build.itemsTab
	local slotName = tostring(req(params, "slot"))
	local raw = tostring(req(params, "text"))
	local slot = itemsTab.slots[slotName]
	if not slot then
		error("unknown slot '" .. slotName .. "'", 0)
	end
	local newItem = new("Item"):Item(raw)
	if not newItem.base then
		error("could not parse that item text; make sure it is a full in-game item copy including the Item Class and Rarity header", 0)
	end
	if not itemsTab:IsItemValidForSlot(newItem, slotName) then
		error("a " .. tostring(newItem.baseName) .. " cannot go in slot '" .. slotName .. "'", 0)
	end
	newItem:NormaliseQuality()
	newItem:BuildModList()
	itemsTab:AddItem(newItem, true)
	slot:SetSelItemId(newItem.id)
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	local result = applyChange(build, params, "items")
	result.item = itemSummary(newItem, slotName)
	result.stats = sidebarStats(build)
	return result
end

commands["items.equip"] = function(params)
	local build = getBuild()
	local itemsTab = build.itemsTab
	local slotName = tostring(req(params, "slot"))
	local slot = itemsTab.slots[slotName]
	if not slot then
		error("unknown slot '" .. slotName .. "'", 0)
	end
	local itemId = reqNumber(params, "itemId")
	if itemId ~= 0 then
		local item = itemsTab.items[itemId]
		if not item then
			error("no item with id " .. itemId .. " in this build", 0)
		end
		if not itemsTab:IsItemValidForSlot(item, slotName) then
			error("'" .. item.name .. "' cannot go in slot '" .. slotName .. "'", 0)
		end
	end
	slot:SetSelItemId(itemId)
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	local result = applyChange(build, params, "items")
	result.stats = sidebarStats(build)
	return result
end

commands["items.remove"] = function(params)
	local build = getBuild()
	local item = resolveItem(build, params)
	build.itemsTab:DeleteItem(item)
	local result = applyChange(build, params, "items")
	result.removed = itemSummary(item)
	result.stats = sidebarStats(build)
	return result
end

commands["items.preview"] = function(params)
	local build = getBuild()
	build:PerformRecalc()
	local slotName = tostring(req(params, "slot"))
	if not build.itemsTab.slots[slotName] then
		error("unknown slot '" .. slotName .. "'", 0)
	end
	local repItem
	if params.text then
		repItem = new("Item"):Item(tostring(params.text))
		if not repItem.base then
			error("could not parse that item text", 0)
		end
		repItem:NormaliseQuality()
		repItem:BuildModList()
	elseif params.itemId then
		repItem = build.itemsTab.items[tonumber(params.itemId)]
		if not repItem then
			error("no item with id " .. tostring(params.itemId) .. " in this build", 0)
		end
	else
		error("pass 'text' with an item's copied text, or 'itemId' for an item already in the build", 0)
	end
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local newOutput = calcFunc({ repSlotName = slotName, repItem = repItem }, true)
	return {
		slot = slotName,
		item = itemSummary(repItem, slotName),
		changes = compareOutputs(build.calcsTab.mainOutput, newOutput),
	}
end

-- Stats worth having on every set comparison without asking. The Req* values
-- travel with their attribute because "reduced Attribute Requirements" on a
-- candidate lowers the requirement rather than raising the attribute, so the
-- pair has to be read together to know whether a set is actually wearable.
local SET_STATS = {
	"EnergyShield", "TotalEHP", "Life", "Mana", "ManaUnreserved",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist",
	"FireResistTotal", "ColdResistTotal", "LightningResistTotal",
	"Str", "Dex", "Int", "ReqStr", "ReqDex", "ReqInt",
	"EffectiveMovementSpeedMod", "TotalDot", "CombinedDPS", "FullDPS",
	"Armour", "Evasion",
}

-- Try out whole gear sets without touching the build.
--
-- The obvious way to compare a set is to equip it, read the stats and put the
-- original back, which costs a round trip per item and pushes undo states
-- through the UI. This runs every set through the calculator instead: one
-- request, no mutation, and identical items shared between sets are parsed once.
commands["items.evaluate_sets"] = function(params)
	local build = getBuild()
	local sets = req(params, "sets")
	if type(sets) ~= "table" or not sets[1] then
		error("'sets' must be a non-empty list of { label = ..., items = { { slot = ..., text = ... } } }", 0)
	end
	local statNames = params.stats
	if type(statNames) ~= "table" or not statNames[1] then
		statNames = SET_STATS
	end

	build:PerformRecalc()
	local baseOutput = build.calcsTab.mainOutput
	local calcFunc = build.calcsTab:GetMiscCalculator()

	local function collect(output)
		local stats = { }
		for _, name in ipairs(statNames) do
			local value = output[name]
			if type(value) == "number" then
				stats[name] = value
			end
		end
		return stats
	end

	-- The same candidate item shows up in most sets when a solver sweeps
	-- combinations, and parsing is the expensive part
	local parsed = { }
	local function itemFor(text)
		local item = parsed[text]
		if not item then
			item = new("Item"):Item(tostring(text))
			if not item.base then
				error("could not parse an item; make sure it is a full item copy including the Item Class and Rarity header", 0)
			end
			item:NormaliseQuality()
			item:BuildModList()
			parsed[text] = item
		end
		return item
	end

	local results = { }
	for index, set in ipairs(sets) do
		local entries = set.items or set
		local repItems = { }
		local slots = { }
		for _, entry in ipairs(entries) do
			local slotName = tostring(req(entry, "slot"))
			if not build.itemsTab.slots[slotName] then
				error("unknown slot '" .. slotName .. "' in set " .. index, 0)
			end
			if entry.text == false then
				repItems[slotName] = false
			else
				repItems[slotName] = itemFor(req(entry, "text"))
			end
			t_insert(slots, slotName)
		end
		local output = calcFunc({ repItems = repItems }, true)
		t_insert(results, {
			index = index,
			label = set.label,
			slots = slots,
			stats = collect(output),
		})
	end

	return {
		base = collect(baseOutput),
		itemsParsed = (function()
			local count = 0
			for _ in pairs(parsed) do count = count + 1 end
			return count
		end)(),
		sets = results,
	}
end

commands["items.search_uniques"] = function(params)
	local build = getBuild()
	local query = tostring(req(params, "query")):lower()
	local limit = tonumber(params.limit) or 20
	local matches = { }
	for _, item in pairs(build.data.uniques) do
		for _, raw in ipairs(item) do
			local name = raw:match("^([^\n]+)")
			if name and name:lower():find(query, 1, true) then
				t_insert(matches, { name = name, raw = raw })
				break
			end
		end
		if #matches >= limit * 4 then
			break
		end
	end
	t_sort(matches, function(a, b) return a.name < b.name end)
	local total = #matches
	for i = #matches, limit + 1, -1 do
		matches[i] = nil
	end
	return { total = total, returned = #matches, items = matches }
end

------------
-- Skills --
------------

local function gemSummary(gemInstance)
	return {
		name = gemInstance.gemData and gemInstance.gemData.name or gemInstance.nameSpec,
		nameSpec = gemInstance.nameSpec,
		level = gemInstance.level,
		quality = gemInstance.quality,
		qualityId = gemInstance.qualityId,
		enabled = gemInstance.enabled and true or false,
		count = gemInstance.count,
		support = gemInstance.gemData and gemInstance.gemData.grantedEffect
			and gemInstance.gemData.grantedEffect.support or nil,
	}
end

commands["skills.list"] = function(params)
	local build = getBuild()
	local groups = { }
	for index, socketGroup in ipairs(build.skillsTab.socketGroupList) do
		local gems = { }
		for gemIndex, gemInstance in ipairs(socketGroup.gemList) do
			local gem = gemSummary(gemInstance)
			gem.index = gemIndex
			t_insert(gems, gem)
		end
		t_insert(groups, {
			index = index,
			label = socketGroup.label,
			displayLabel = stripColor(socketGroup.displayLabel or socketGroup.label or ""),
			slot = socketGroup.slot,
			source = socketGroup.source,
			enabled = socketGroup.enabled and true or false,
			includeInFullDPS = socketGroup.includeInFullDPS and true or false,
			isMainGroup = index == build.mainSocketGroup,
			mainActiveSkill = socketGroup.mainActiveSkill,
			gems = gems,
		})
	end
	return { mainSocketGroup = build.mainSocketGroup, activeSkillSetId = build.skillsTab.activeSkillSetId, groups = groups }
end

local function getSocketGroup(build, params)
	local index = reqNumber(params, "group")
	local socketGroup = build.skillsTab.socketGroupList[index]
	if not socketGroup then
		error("no skill group at index " .. index .. "; the build has " .. #build.skillsTab.socketGroupList, 0)
	end
	if socketGroup.source then
		error("skill group " .. index .. " is granted by an item and cannot be edited directly", 0)
	end
	return socketGroup, index
end

commands["skills.add_group"] = function(params)
	local build = getBuild()
	local skillsTab = build.skillsTab
	local socketGroup = {
		label = params.label and tostring(params.label) or "",
		enabled = params.enabled ~= false,
		gemList = { },
		includeInFullDPS = params.includeInFullDPS and true or false,
		mainActiveSkill = 1,
	}
	if params.slot then
		if not build.itemsTab.slots[tostring(params.slot)] then
			error("unknown slot '" .. tostring(params.slot) .. "'", 0)
		end
		socketGroup.slot = tostring(params.slot)
	end
	for _, gemParams in ipairs(params.gems or { }) do
		local errMsg, gemData = skillsTab:FindSkillGem(tostring(gemParams.name or ""))
		if errMsg then
			error(errMsg, 0)
		end
		t_insert(socketGroup.gemList, {
			nameSpec = gemData.name,
			gemData = gemData,
			gemId = gemData.id,
			skillId = gemData.grantedEffectId,
			level = tonumber(gemParams.level) or skillsTab:ProcessGemLevel(gemData),
			quality = tonumber(gemParams.quality) or 0,
			qualityId = "Default",
			enabled = gemParams.enabled ~= false,
			enableGlobal1 = true,
			count = tonumber(gemParams.count) or 1,
		})
	end
	t_insert(skillsTab.socketGroupList, socketGroup)
	skillsTab:ProcessSocketGroup(socketGroup)
	if params.setAsMain then
		build.mainSocketGroup = #skillsTab.socketGroupList
	end
	skillsTab:AddUndoState()
	local result = applyChange(build, params, "skills")
	result.group = #skillsTab.socketGroupList
	result.stats = sidebarStats(build)
	return result
end

commands["skills.remove_group"] = function(params)
	local build = getBuild()
	local socketGroup, index = getSocketGroup(build, params)
	table.remove(build.skillsTab.socketGroupList, index)
	if build.mainSocketGroup > #build.skillsTab.socketGroupList then
		build.mainSocketGroup = math.max(1, #build.skillsTab.socketGroupList)
	end
	build.skillsTab:AddUndoState()
	local result = applyChange(build, params, "skills")
	result.removed = { index = index, label = socketGroup.label }
	result.stats = sidebarStats(build)
	return result
end

commands["skills.set_group"] = function(params)
	local build = getBuild()
	local socketGroup = getSocketGroup(build, params)
	if params.label ~= nil then
		socketGroup.label = tostring(params.label)
	end
	if params.enabled ~= nil then
		socketGroup.enabled = params.enabled and true or false
	end
	if params.includeInFullDPS ~= nil then
		socketGroup.includeInFullDPS = params.includeInFullDPS and true or false
	end
	if params.slot ~= nil then
		if params.slot == false or params.slot == "" then
			socketGroup.slot = nil
		elseif not build.itemsTab.slots[tostring(params.slot)] then
			error("unknown slot '" .. tostring(params.slot) .. "'", 0)
		else
			socketGroup.slot = tostring(params.slot)
		end
	end
	if params.mainActiveSkill ~= nil then
		socketGroup.mainActiveSkill = tonumber(params.mainActiveSkill)
	end
	build.skillsTab:ProcessSocketGroup(socketGroup)
	build.skillsTab:AddUndoState()
	local result = applyChange(build, params, "skills")
	result.stats = sidebarStats(build)
	return result
end

commands["skills.set_main_group"] = function(params)
	local build = getBuild()
	local index = reqNumber(params, "group")
	if not build.skillsTab.socketGroupList[index] then
		error("no skill group at index " .. index, 0)
	end
	build.mainSocketGroup = index
	local result = applyChange(build, params, "skills")
	result.mainSocketGroup = index
	result.stats = sidebarStats(build)
	return result
end

commands["skills.add_gem"] = function(params)
	local build = getBuild()
	local skillsTab = build.skillsTab
	local socketGroup = getSocketGroup(build, params)
	local errMsg, gemData = skillsTab:FindSkillGem(tostring(req(params, "name")))
	if errMsg then
		error(errMsg, 0)
	end
	local gemInstance = {
		nameSpec = gemData.name,
		gemData = gemData,
		gemId = gemData.id,
		skillId = gemData.grantedEffectId,
		level = tonumber(params.level) or skillsTab:ProcessGemLevel(gemData),
		quality = tonumber(params.quality) or 0,
		qualityId = "Default",
		enabled = params.enabled ~= false,
		enableGlobal1 = true,
		count = tonumber(params.count) or 1,
	}
	local position = tonumber(params.index)
	if position then
		t_insert(socketGroup.gemList, position, gemInstance)
	else
		t_insert(socketGroup.gemList, gemInstance)
	end
	skillsTab:ProcessSocketGroup(socketGroup)
	skillsTab:AddUndoState()
	local result = applyChange(build, params, "skills")
	result.gem = gemSummary(gemInstance)
	result.stats = sidebarStats(build)
	return result
end

commands["skills.set_gem"] = function(params)
	local build = getBuild()
	local skillsTab = build.skillsTab
	local socketGroup = getSocketGroup(build, params)
	local gemIndex = reqNumber(params, "index")
	local gemInstance = socketGroup.gemList[gemIndex]
	if not gemInstance then
		error("no gem at index " .. gemIndex .. " in that group; it has " .. #socketGroup.gemList, 0)
	end
	if params.name then
		local errMsg, gemData = skillsTab:FindSkillGem(tostring(params.name))
		if errMsg then
			error(errMsg, 0)
		end
		gemInstance.nameSpec = gemData.name
		gemInstance.gemData = gemData
		gemInstance.gemId = gemData.id
		gemInstance.skillId = gemData.grantedEffectId
		-- A level valid for the old gem may be out of range for the new one
		gemInstance.level = tonumber(params.level) or skillsTab:ProcessGemLevel(gemData)
	elseif params.level then
		gemInstance.level = tonumber(params.level)
	end
	if params.quality ~= nil then
		gemInstance.quality = tonumber(params.quality) or 0
	end
	if params.enabled ~= nil then
		gemInstance.enabled = params.enabled and true or false
	end
	if params.count ~= nil then
		gemInstance.count = tonumber(params.count) or 1
	end
	skillsTab:ProcessSocketGroup(socketGroup)
	skillsTab:AddUndoState()
	local result = applyChange(build, params, "skills")
	result.gem = gemSummary(gemInstance)
	result.stats = sidebarStats(build)
	return result
end

commands["skills.remove_gem"] = function(params)
	local build = getBuild()
	local socketGroup = getSocketGroup(build, params)
	local gemIndex = reqNumber(params, "index")
	local gemInstance = socketGroup.gemList[gemIndex]
	if not gemInstance then
		error("no gem at index " .. gemIndex .. " in that group; it has " .. #socketGroup.gemList, 0)
	end
	table.remove(socketGroup.gemList, gemIndex)
	build.skillsTab:ProcessSocketGroup(socketGroup)
	build.skillsTab:AddUndoState()
	local result = applyChange(build, params, "skills")
	result.removed = gemSummary(gemInstance)
	result.stats = sidebarStats(build)
	return result
end

commands["skills.search_gems"] = function(params)
	local build = getBuild()
	local query = tostring(req(params, "query")):lower()
	local limit = tonumber(params.limit) or 25
	local matches = { }
	for gemId, gemData in pairs(build.data.gems) do
		if gemData.name and gemData.name:lower():find(query, 1, true) then
			local isSupport = gemData.grantedEffect and gemData.grantedEffect.support or false
			if params.support == nil or (params.support and isSupport) or (params.support == false and not isSupport) then
				t_insert(matches, {
					name = gemData.name,
					support = isSupport,
					tags = gemData.tags and gemData.tagString or nil,
					maxLevel = gemData.naturalMaxLevel,
				})
			end
		end
	end
	t_sort(matches, function(a, b) return a.name < b.name end)
	local total = #matches
	for i = #matches, limit + 1, -1 do
		matches[i] = nil
	end
	return { total = total, returned = #matches, gems = matches }
end

-------------------
-- Configuration --
-------------------

local configVarList

local function getConfigVarList()
	if not configVarList then
		configVarList = LoadModule("Modules/ConfigOptions")
	end
	return configVarList
end

commands["config.list"] = function(params)
	local build = getBuild()
	local configTab = build.configTab
	local input = configTab.configSets[configTab.activeConfigSetId].input
	local query = params and params.query and tostring(params.query):lower() or nil
	local options, section = { }, nil
	for _, varData in ipairs(getConfigVarList()) do
		if varData.section then
			section = varData.section
		elseif varData.var then
			local control = configTab.varControls[varData.var]
			local value = input[varData.var]
			-- The tab hides options that do not apply to this build. Report those
			-- only when they carry a non-default value or the caller searched for
			-- them, so the common case stays a readable list rather than 1000 rows.
			local shown = control and control:IsShown()
			local matchesQuery = query and (varData.var:lower():find(query, 1, true)
				or (varData.label and stripColor(varData.label):lower():find(query, 1, true)))
			if shown or value ~= nil or matchesQuery then
				if not query or matchesQuery then
					local option = {
						var = varData.var,
						label = varData.label and stripColor(varData.label):gsub(":%s*$", "") or varData.var,
						type = varData.type,
						section = section,
						value = value,
						applies = shown and true or false,
					}
					if varData.type == "list" and varData.list then
						local choices = { }
						for _, entry in ipairs(varData.list) do
							t_insert(choices, { value = entry.val, label = stripColor(entry.label or tostring(entry.val)) })
						end
						option.choices = choices
					end
					t_insert(options, option)
				end
			end
		end
	end
	return { activeConfigSetId = configTab.activeConfigSetId, count = #options, options = options }
end

commands["config.set"] = function(params)
	local build = getBuild()
	local configTab = build.configTab
	local var = tostring(req(params, "var"))
	local varData
	for _, entry in ipairs(getConfigVarList()) do
		if entry.var == var then
			varData = entry
			break
		end
	end
	if not varData then
		error("unknown config option '" .. var .. "'; use config.list to find the right name", 0)
	end
	local value = params.value
	if value == nil or value == false and varData.type ~= "check" then
		-- Clearing an option returns it to its default, which is how the UI models
		-- an empty field rather than storing an explicit zero
		configTab.configSets[configTab.activeConfigSetId].input[var] = nil
	elseif varData.type == "check" then
		configTab.configSets[configTab.activeConfigSetId].input[var] = value and true or false
	elseif varData.type == "count" or varData.type == "integer" or varData.type == "countAllowZero" or varData.type == "float" then
		local num = tonumber(value)
		if not num then
			error("config option '" .. var .. "' takes a number", 0)
		end
		if varData.type ~= "float" then
			num = m_floor(num)
		end
		configTab.configSets[configTab.activeConfigSetId].input[var] = num
	elseif varData.type == "list" then
		local valid
		for _, entry in ipairs(varData.list or { }) do
			if entry.val == value or tostring(entry.val) == tostring(value)
				or (entry.label and stripColor(entry.label):lower() == tostring(value):lower()) then
				valid = entry.val
				break
			end
		end
		if valid == nil then
			local choices = { }
			for _, entry in ipairs(varData.list or { }) do
				t_insert(choices, tostring(entry.val))
			end
			error("'" .. tostring(value) .. "' is not a valid value for '" .. var .. "'; expected one of: " .. table.concat(choices, ", "), 0)
		end
		configTab.configSets[configTab.activeConfigSetId].input[var] = valid
	else
		configTab.configSets[configTab.activeConfigSetId].input[var] = tostring(value)
	end
	configTab:AddUndoState()
	configTab:BuildModList()
	configTab:UpdateControls()
	local result = applyChange(build, params, "config")
	result.var = var
	result.value = configTab.configSets[configTab.activeConfigSetId].input[var]
	result.stats = sidebarStats(build)
	return result
end

-------------------
-- Introspection --
-------------------

commands["help"] = function(params)
	local names = { }
	for name in pairs(commands) do
		t_insert(names, name)
	end
	t_sort(names)
	return { commands = names, version = mcp.VERSION }
end

mcp.VERSION = "1.0.0"

return mcp
