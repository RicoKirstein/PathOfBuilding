-- Path of Building
--
-- Module: Calcs Tab
-- Calculations breakdown tab for the current build.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local m_max = math.max
local m_floor = math.floor

local buffModeDropList = {
	{ label = "Unbuffed", buffMode = "UNBUFFED" },
	{ label = "Buffed", buffMode = "BUFFED" },
	{ label = "In Combat", buffMode = "COMBAT" },
	{ label = "Effective DPS", buffMode = "EFFECTIVE" } 
}

local CalcsTabClass = newClass("CalcsTab", "UndoHandler", "ControlHost", "Control", function(self, build)
	self.UndoHandler()
	self.ControlHost()
	self.Control()

	self.build = build

	self.calcs = LoadModule("Modules/Calcs")

	self.input = { }
	self.input.skill_number = 1
	self.input.misc_buffMode = "EFFECTIVE"

	self.colWidth = 230
	self.sectionList = { }

	self.controls.search = new("EditControl", {"TOPLEFT",self,"TOPLEFT"}, {4, 5, 260, 20}, "", "Search", "%c", 100, nil, nil, nil, true)
	t_insert(self.controls, self.controls.search)

	-- Special section for skill/mode selection
	self:NewSection(3, "SkillSelect", 1, colorCodes.NORMAL, {{ defaultCollapsed = false, label = "View Skill Details", data = {
		{ label = "Socket Group", { controlName = "mainSocketGroup", 
			control = new("DropDownControl", nil, {0, 0, 300, 16}, nil, function(index, value) 
				self.input.skill_number = index
				self:AddUndoState()
				self.build.buildFlag = true
			end) {
				tooltipFunc = function(tooltip, mode, index, value)
					local socketGroup = self.build.skillsTab.socketGroupList[index]
					if socketGroup and tooltip:CheckForUpdate(socketGroup, self.build.outputRevision) then
						self.build.skillsTab:AddSocketGroupTooltip(tooltip, socketGroup)
					end
				end
			}
		}, },
		{ label = "Active Skill", { controlName = "mainSkill", 
			control = new("DropDownControl", nil, {0, 0, 300, 16}, nil, function(index, value)
				local mainSocketGroup = self.build.skillsTab.socketGroupList[self.input.skill_number]
				mainSocketGroup.mainActiveSkillCalcs = index
				self.build.buildFlag = true
			end)
		}, },
		{ label = "Skill Part", playerFlag = "multiPart", { controlName = "mainSkillPart", 
			control = new("DropDownControl", nil, {0, 0, 250, 16}, nil, function(index, value)
				local mainSocketGroup = self.build.skillsTab.socketGroupList[self.input.skill_number]
				local srcInstance = mainSocketGroup.displaySkillListCalcs[mainSocketGroup.mainActiveSkillCalcs].activeEffect.srcInstance
				srcInstance.skillPartCalcs = index
				self:AddUndoState()
				self.build.buildFlag = true
			end)
		}, },{ label = "Skill Stages", playerFlag = "multiStage", { controlName = "mainSkillStageCount",
			control = new("EditControl", nil, {0, 0, 52, 16}, nil, nil, "%D", nil, function(buf)
				local mainSocketGroup = self.build.skillsTab.socketGroupList[self.input.skill_number]
				local srcInstance = mainSocketGroup.displaySkillListCalcs[mainSocketGroup.mainActiveSkillCalcs].activeEffect.srcInstance
				srcInstance.skillStageCountCalcs = tonumber(buf)
				self:AddUndoState()
				self.build.buildFlag = true
			end)
		}, },
		{ label = "Active Mines", playerFlag = "mine", { controlName = "mainSkillMineCount",
			control = new("EditControl", nil, {0, 0, 52, 16}, nil, nil, "%D", nil, function(buf)
				local mainSocketGroup = self.build.skillsTab.socketGroupList[self.input.skill_number]
				local srcInstance = mainSocketGroup.displaySkillListCalcs[mainSocketGroup.mainActiveSkillCalcs].activeEffect.srcInstance
				srcInstance.skillMineCountCalcs = tonumber(buf)
				self:AddUndoState()
				self.build.buildFlag = true
			end)
		}, },
		{ label = "Show Minion Stats", flag = "haveMinion", { controlName = "showMinion", 
			control = new("CheckBoxControl", nil, {0, 0, 18}, nil, function(state)
				self.input.showMinion = state
				self:AddUndoState()
			end, "Show stats for the minion instead of the player.")
		}, },
		{ label = "Minion", flag = "minion", { controlName = "mainSkillMinion",
			control = new("DropDownControl", nil, {0, 0, 160, 16}, nil, function(index, value)
				local mainSocketGroup = self.build.skillsTab.socketGroupList[self.input.skill_number]
				local srcInstance = mainSocketGroup.displaySkillListCalcs[mainSocketGroup.mainActiveSkillCalcs].activeEffect.srcInstance
				if value.itemSetId then
					srcInstance.skillMinionItemSetCalcs = value.itemSetId
				else
					srcInstance.skillMinionCalcs = value.minionId
				end
				self:AddUndoState()
				self.build.buildFlag = true
			end)
		} },
		{ label = "Spectre Library", flag = "spectre", { controlName = "mainSkillMinionLibrary",
			control = new("ButtonControl", nil, {0, 0, 100, 16}, "Manage Spectres...", function()
				self.build:OpenSpectreLibrary()
			end)
		} },
		{ label = "Minion Skill", flag = "haveMinion", { controlName = "mainSkillMinionSkill",
			control = new("DropDownControl", nil, {0, 0, 200, 16}, nil, function(index, value)
				local mainSocketGroup = self.build.skillsTab.socketGroupList[self.input.skill_number]
				local srcInstance = mainSocketGroup.displaySkillListCalcs[mainSocketGroup.mainActiveSkillCalcs].activeEffect.srcInstance
				srcInstance.skillMinionSkillCalcs = index
				self:AddUndoState()
				self.build.buildFlag = true
			end)
		} },
		{ label = "Calculation Mode", { 
			controlName = "mode", 
			control = new("DropDownControl", nil, {0, 0, 100, 16}, buffModeDropList, function(index, value) 
				self.input.misc_buffMode = value.buffMode 
				self:AddUndoState()
				self.build.buildFlag = true
			end, [[
This controls the calculation of the stats shown in this tab.
The stats in the sidebar are always shown in Effective DPS mode, regardless of this setting.

Unbuffed: No auras, buffs, or other support skills or effects will apply. This is equivalent to standing in town.
Buffed: Aura and buff skills apply. This is equivalent to standing in your hideout with auras and buffs turned on.
In Combat: Charges and combat buffs such as Onslaught will also apply. This will show your character sheet stats in combat.
Effective DPS: Curses and enemy properties (such as resistances and status conditions) will also apply. This estimates your true DPS.]]) 
		}, },
		{ label = "Aura and Buff Skills", flag = "buffs", textSize = 12, { format = "{output:BuffList}", { breakdown = "SkillBuffs" } }, },
		{ label = "Combat Buffs", flag = "combat", textSize = 12, { format = "{output:CombatList}" }, },
		{ label = "Curses and Debuffs", flag = "effective", textSize = 12, { format = "{output:CurseList}", { breakdown = "SkillDebuffs" } }, },
	}}}, function(section)
		self.build:RefreshSkillSelectControls(section.controls, self.input.skill_number, "Calcs")
		section.controls.showMinion.state = self.input.showMinion
		section.controls.mode:SelByValue(self.input.misc_buffMode, "buffMode")
	end)

	-- Add sections from the CalcSections module
	local sectionData = LoadModule("Modules/CalcSections")
	for _, section in ipairs(sectionData) do
		self:NewSection(unpack(section))
	end

	self.controls.breakdown = new("CalcBreakdownControl", self)

	self.controls.scrollBar = new("ScrollBarControl", {"TOPRIGHT",self,"TOPRIGHT"}, {0, 0, 18, 0}, 50, "VERTICAL", true)
	self.powerBuilderInitialized = nil
end)

function CalcsTabClass:Load(xml, dbFileName)
	for _, node in ipairs(xml) do
		if type(node) == "table" then
			if node.elem == "Input" then
				if not node.attrib.name then
					launch:ShowErrMsg("^1Error parsing '%s': 'Input' element missing name attribute", fileName)
					return true
				end
				if node.attrib.number then
					self.input[node.attrib.name] = tonumber(node.attrib.number)
				elseif node.attrib.string then
					self.input[node.attrib.name] = node.attrib.string
				elseif node.attrib.boolean then
					self.input[node.attrib.name] = node.attrib.boolean == "true"
				else
					launch:ShowErrMsg("^1Error parsing '%s': 'Input' element missing number, string or boolean attribute", fileName)
					return true
				end
			elseif node.elem == "Section" then
				if not node.attrib.id then
					launch:ShowErrMsg("^1Error parsing '%s': 'Section' element missing id attribute", fileName)
					return true
				end
				for _, section in ipairs(self.sectionList) do
					if section.id == node.attrib.id and node.attrib.subsection then
						for _, subsection in ipairs(section.subSection) do
							if subsection.id == node.attrib.subsection then
								subsection.collapsed = node.attrib.collapsed == "true"
								break
							end
						end
						break
					end
				end
			end
		end
	end
	self:ResetUndo()
end

function CalcsTabClass:Save(xml)
	for k, v in pairs(self.input) do
		local child = { elem = "Input", attrib = {name = k} }
		if type(v) == "number" then
			child.attrib.number = tostring(v)
		elseif type(v) == "boolean" then
			child.attrib.boolean = tostring(v)
		else
			child.attrib.string = tostring(v)
		end
		t_insert(xml, child)
	end
	for _, section in ipairs(self.sectionList) do
		for _, subSection in ipairs(section.subSection) do
			t_insert(xml, { elem = "Section", attrib = {
				id = section.id,
				subsection = subSection.id,
				collapsed = tostring(subSection.collapsed),
			} })
		end
	end
end

function CalcsTabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	-- Arrange the sections
	local baseX = viewPort.x + 4
	local baseY = viewPort.y + 30
	local maxCol = m_floor(viewPort.width / (self.colWidth + 8))
	if main.portraitMode then maxCol = 3 end
	local colY = { }
	local maxY = 0
	for _, section in ipairs(self.sectionList) do
		section:UpdateSize()
		if section.enabled and not section.isOverlay then
			local col
			if section.group == 1 then
				-- Group 1: Offense or 3 wide sections
				-- This group is put into the first 3 columns, with each section placed into the highest available location
				col = 1
				if section.width == self.colWidth then -- if 1 col wide
					local minY = colY[col] or baseY
					for c = 2, 3 do
						if (colY[c] or baseY) < minY then
							col = c
							minY = colY[c] or baseY
						end
					end
				else
					for c = 2, 3 do
						colY[col] = m_max(colY[col] or baseY, colY[c] or baseY)
					end
				end
			elseif section.group == 2 then
				-- Group 2: Defense (the first 4 sections)
				-- This group is put entirely into the 4th column
				if maxCol >= 4 then
					col = 4
				end
			elseif section.group == 3 then
				-- Group 3: Defense (the remaining sections)
				-- This group is put into a 5th column if there's room for one, otherwise they are handled separately
				if maxCol >= 5 then
					col = 5
				end
			end
			if col then
				section.x = baseX + (self.colWidth + 8) * (col - 1)
				section.y = colY[col] or baseY
				for c = col, col + section.widthCols - 1 do
					colY[c] = section.y + section.height + 8
				end
				maxY = m_max(maxY, colY[col])
			end
		end
	end
	if maxCol < 5 then
		-- There's no room for a 5th column
		-- Each section from group 3 will instead be placed into column 4 if there's room, otherwise they'll be put in columns 1-3
		for c = 1, 3 do
			colY[c] = m_max(colY[1], colY[2], colY[3])
		end
		for _, section in ipairs(self.sectionList) do
			if section.enabled and not section.isOverlay and (main.portraitMode and section.group == 2 or section.group == 3) then
				local col = 3
				if colY[col] + section.height + 4 >= m_max(viewPort.y + viewPort.height, maxY) then
					-- No room in the 4th column, find the highest available location in columns 1-4
					local minY = colY[col]
					for c = 3, 1, -1 do
						if colY[c] < minY then
							col = c
							minY = colY[c]
						end
					end
				end
				section.x = baseX + (self.colWidth + 8) * (col - 1)
				section.y = colY[col]
				colY[col] = section.y + section.height + 8
				maxY = m_max(maxY, colY[col])
			end
		end
	end
	self.controls.scrollBar.height = viewPort.height
	self.controls.scrollBar:SetContentDimension(maxY - (baseY - 26), viewPort.height)
	for _, section in ipairs(self.sectionList) do
		if not section.isOverlay then
			-- Give sections their actual Y position and let them update
			section.y = section.y - self.controls.scrollBar.offset
			section:UpdatePos()
		end
	end
	
	self.controls.search.y = 4 - self.controls.scrollBar.offset

	for _, event in ipairs(inputEvents) do
		if event.type == "KeyDown" then
			if event.key == "z" and IsKeyDown("CTRL") then
				self:Undo()
				self.build.buildFlag = true
			elseif event.key == "y" and IsKeyDown("CTRL") then
				self:Redo()
				self.build.buildFlag = true
			elseif event.key == "f" and IsKeyDown("CTRL") then
				self:SelectControl(self.controls.search)
			end
		end
	end
	self:ProcessControlsInput(inputEvents, viewPort)
	for _, event in ipairs(inputEvents) do
		if event.type == "KeyUp" then
			if self.controls.scrollBar:IsScrollDownKey(event.key) then
				self.controls.scrollBar:Scroll(1)
			elseif self.controls.scrollBar:IsScrollUpKey(event.key) then
				self.controls.scrollBar:Scroll(-1)
			end
		end
	end

	main:DrawBackground(viewPort)

	if not self.displayPinned then
		self.displayData = nil
	end

	local breakdown = self.controls.breakdown
	local overlayBreakdown = breakdown.sourceData and breakdown.sourceData.calcSection and breakdown.sourceData.calcSection.isOverlay
	if overlayBreakdown then
		breakdown.shown = false
	end
	self:DrawControls(viewPort, self.selControl)
	if overlayBreakdown then
		breakdown.shown = true
	end

	if self.displayData then
		if self.displayPinned and not self.selControl then
			self:SelectControl(self.controls.breakdown)
		end
	else
		self.controls.breakdown:SetBreakdownData()
	end
end

function CalcsTabClass:NewSection(width, ...)
	local section = new("CalcSectionControl", self, width * self.colWidth + 8 * (width - 1), ...)
	section.widthCols = width
	t_insert(self.controls, section)
	t_insert(self.sectionList, section)
end

function CalcsTabClass:ClearDisplayStat()
	self.displayData = nil
	self.displayPinned = nil
	self.controls.breakdown:SetBreakdownData()
end

function CalcsTabClass:SetDisplayStat(displayData, pin)
	if not displayData or (not pin and self.displayPinned) then
		return
	end
	if pin and self.displayPinned and self.displayData == displayData then
		self:ClearDisplayStat()
		return
	end
	self.displayData = displayData
	self.displayPinned = pin
	self.controls.breakdown:SetBreakdownData(displayData, pin)
end

function CalcsTabClass:CheckFlag(obj, actor)
	actor = actor or (self.input.showMinion and self.calcsEnv.minion or self.calcsEnv.player)
	local skillFlags = actor.mainSkill.skillFlags
	if obj.flag and not skillFlags[obj.flag] then
		return
	end
	if obj.flagList then
		for _, flag in ipairs(obj.flagList) do
			if not skillFlags[flag] then
				return
			end
		end
	end
	if obj.playerFlag and not self.calcsEnv.player.mainSkill.skillFlags[obj.playerFlag] then
		return
	end
	if obj.notFlag and skillFlags[obj.notFlag] then
		return
	end
	if obj.notFlagList then
		for _, flag in ipairs(obj.notFlagList) do
			if skillFlags[flag] then
				return
			end
		end
	end
	if obj.haveOutput then
		local ns, var = obj.haveOutput:match("^(%a+)%.(%a+)$")
		if ns then
			if not actor.output[ns] or not actor.output[ns][var] or actor.output[ns][var] == 0 then
				return
			end
		elseif not actor.output[obj.haveOutput] or actor.output[obj.haveOutput] == 0 then
			return
		end
	end
	return true
end

function CalcsTabClass:SearchMatch(txt)
	local searchStr = self.controls.search.buf:lower()
	return string.len(searchStr) > 0 and txt:lower():find(searchStr)
end

-- Build the calculation output tables
function CalcsTabClass:BuildOutput()
	self.powerBuildFlag = true

	-- Invalidate the cross-pass node modifier list cache (see calcs.buildModListForNode);
	-- anything about the build may have changed since the last output build
	self.build.nodeModListCache = { }
	self.build.radiusJewelNodeSet = nil

	--[[
	local start = GetTime()
	SetProfiling(true)
	for i = 1, 1000  do
		self.calcs.buildOutput(self.build, "MAIN")
	end
	SetProfiling(false)
	ConPrintf("Calc time: %d ms", GetTime() - start)
	--]]

	for _, node in pairs(self.build.spec.nodes) do
		-- Set default final mod list for all nodes; some may not be set during the main pass
		node.finalModList = node.modList
	end

	self.mainEnv = self.calcs.buildOutput(self.build, "MAIN")
	self.mainOutput = self.mainEnv.player.output
	self.calcsEnv = self.calcs.buildOutput(self.build, "CALCS")
	self.calcsOutput = self.calcsEnv.player.output

	if self.displayData then
		self.controls.breakdown:SetBreakdownData()
		self.controls.breakdown:SetBreakdownData(self.displayData, self.displayPinned)
	end
	
	-- Retrieve calculator functions
	self.nodeCalculator = { self.calcs.getNodeCalculator(self.build) }
	self.miscCalculator = { self.calcs.getMiscCalculator(self.build) }
end

-- Controls the coroutine that calculates node power
function CalcsTabClass:BuildPower()
	if self.powerBuildFlag then
		self.powerBuildFlag = false
		self.powerMax = nil
		self.powerBuilder = coroutine.create(self.PowerBuilder)
	end
	if self.powerBuilder then
		local res, errMsg = coroutine.resume(self.powerBuilder, self)
		if launch.devMode and not res then
			error(errMsg)
		end
		if coroutine.status(self.powerBuilder) == "dead" then
			self.powerBuilder = nil
			if self.build.powerBuilderCallback then
				self.build.powerBuilderCallback()
			end
		end
	end
end

-- Estimate the offensive and defensive power of all unallocated nodes
-- A tree node with the given mastery effect's stats applied, as used to
-- evaluate assigning that effect
function CalcsTabClass.BuildMasteryEffectNode(spec, node, effect)
	local effectNode = {
		id = node.id,
		type = node.type,
		name = node.name,
		sd = { },
	}
	for i, sd in ipairs(effect.sd or { }) do
		effectNode.sd[i] = sd
	end
	spec.tree:ProcessStats(effectNode)
	return effectNode
end

-- Builds the calculation override for one node-power evaluation key; lives
-- next to the PowerBuilder code that generates the keys, and is used by the
-- calculation pool workers (WorkerJobs nodePower) to interpret them, so the
-- two sides cannot drift. Keys: "123" adds node 123, "r123" removes allocated
-- node 123, "m123/456" tries mastery effect 456 on mastery node 123, "c<name>"
-- adds the cluster notable by name, "p123" removes allocated node 123 plus its
-- dependents. Returns the override and the node it evaluates.
function CalcsTabClass.BuildNodePowerOverride(spec, key)
	key = tostring(key)
	local removeId = key:match("^r(%d+)$")
	local masteryId, effectId = key:match("^m(%d+)/(%d+)$")
	if removeId then
		local node = spec.nodes[tonumber(removeId)]
		if node then
			return { removeNodes = { [node] = true } }, node
		end
	elseif masteryId then
		local node = spec.nodes[tonumber(masteryId)]
		local effect = spec.tree.masteryEffects[tonumber(effectId)]
		if node and effect then
			local effectNode = CalcsTabClass.BuildMasteryEffectNode(spec, node, effect)
			return { addNodes = { [effectNode] = true } }, effectNode
		end
	elseif key:byte(1) == 99 then -- "c<name>": cluster notable by name
		local node = spec.tree.clusterNodeMap[key:sub(2)]
		if node then
			return { addNodes = { [node] = true } }, node
		end
	elseif key:byte(1) == 112 then -- "p<id>": allocated node plus its dependents removed
		local node = spec.nodes[tonumber(key:sub(2))]
		if node and node.depends then
			local pathNodes = { }
			for _, depNode in ipairs(node.depends) do
				pathNodes[depNode] = true
			end
			return { removeNodes = pathNodes }, node
		end
	else
		local node = spec.nodes[tonumber(key)]
		if node then
			return { addNodes = { [node] = true } }, node
		end
	end
end

function CalcsTabClass:PowerBuilder()
	-- local timer_start = GetTime()
	-- The FullDPS roll-up is only needed when it is the selected power stat; for all
	-- other stats an explicit false skips its per-skill recalculation for every node
	local useFullDPS = (self.powerStat and self.powerStat.stat == "FullDPS") or false
	local calcFunc, calcBase = self:GetMiscCalculator()
	-- Composes most nodes' outputs from per-modifier deltas instead of running a full
	-- calculation per node; nodes it cannot compose fall through to the exact path below
	local aggregate = not self.nodePowerAggregateDisabled and self.calcs.newNodeAggregate(self.build, calcFunc, calcBase, useFullDPS) or nil
	local aggregateSample = { }
	local cache = { }
	local distanceMap = { }
	local distanceList = { }
	local masteryNodeList = { }
	local newPowerMax = {
		singleStat = 0,
		offence = 0,
		offencePerPoint = 0,
		defence = 0,
		defencePerPoint = 0
	}
	if not self.powerMax then
		self.powerMax = newPowerMax
	end
	if coroutine.running() then
		coroutine.yield()
	end

	local function buildMasteryEffectNode(node, effect)
		return CalcsTabClass.BuildMasteryEffectNode(self.build.spec, node, effect)
	end

	local function masteryEffectCanBeAssignedToNode(node, masteryEffect)
		local assignedNodeId = isValueInTable(self.build.spec.masterySelections, masteryEffect.effect)
		return not assignedNodeId or assignedNodeId == node.id
	end

	local function calculateAddNodePower(power, distance, node, output, getPathOutput)
		if self.powerStat and self.powerStat.stat and not self.powerStat.ignoreForNodes then
			power.singleStat = self:CalculatePowerStat(self.powerStat, output, calcBase)
			if node.path and not node.ascendancyName then
				newPowerMax.singleStat = m_max(newPowerMax.singleStat, power.singleStat)
				power.pathPower = power.singleStat
				if distance > 1 then
					power.pathPower = self:CalculatePowerStat(self.powerStat, getPathOutput(), calcBase)
				end
			end
		elseif not self.powerStat or not self.powerStat.ignoreForNodes then
			power.offence, power.defence = self:CalculateCombinedOffDefStat(output, calcBase)
			power.singleStat = power.offence
			if node.path and not node.ascendancyName then
				newPowerMax.offence = m_max(newPowerMax.offence, power.offence)
				newPowerMax.defence = m_max(newPowerMax.defence, power.defence)
				newPowerMax.offencePerPoint = m_max(newPowerMax.offencePerPoint, power.offence / distance)
				newPowerMax.defencePerPoint = m_max(newPowerMax.defencePerPoint, power.defence / distance)
			end
		end
	end
	
	-- Prefetch the unallocated-node outputs from the worker pool, sharded across
	-- all workers; the loop below uses them in place of local calculations
	local pooledOutputs
	local workerPool = main.workerPool
	if workerPool and workerPool:IsAvailable() then
		local ids = { }
		local extraIds = { }
		for nodeId, node in pairs(self.build.spec.nodes) do
			if node.modKey ~= "" and not self.mainEnv.grantedPassives[nodeId] then
				if node.type == "Mastery" and node.allMasteryOptions then
					if not (self.nodePowerMaxDepth and self.nodePowerMaxDepth < node.pathDist) then
						for _, masteryEffect in ipairs(node.masteryEffects or { }) do
							if masteryEffectCanBeAssignedToNode(node, masteryEffect) then
								t_insert(extraIds, "m" .. nodeId .. "/" .. masteryEffect.effect)
							end
						end
					end
				elseif node.alloc then
					t_insert(extraIds, "r" .. nodeId)
					if self.powerStat and self.powerStat.stat and not self.powerStat.ignoreForNodes and node.depends and #node.depends > 1 then
						t_insert(extraIds, "p" .. nodeId)
					end
				elseif not (self.nodePowerMaxDepth and (node.pathDist or 1000) > self.nodePowerMaxDepth) then
					t_insert(ids, nodeId)
				end
			end
		end
		local stats = { "LifeUnreserved", "Life", "Armour", "EnergyShield", "EnergyShieldRecoveryCap", "Evasion", "LifeRegenRecovery", "EnergyShieldRegenRecovery", "CombinedDPS" }
		if self.powerStat and self.powerStat.stat then
			t_insert(stats, self.powerStat.stat)
		end
		-- Near-first shard order, so results stream in roughly the same order the
		-- node loop below consumes them
		table.sort(ids, function(a, b)
			return (self.build.spec.nodes[a].pathDist or 1000) < (self.build.spec.nodes[b].pathDist or 1000)
		end)
		for clusterName, clusterNode in pairs(self.build.spec.tree.clusterNodeMap) do
			if not clusterNode.alloc and clusterNode.modKey ~= "" and not self.mainEnv.grantedPassives[clusterNode.id] then
				t_insert(extraIds, "c" .. clusterName)
			end
		end
		for _, id in ipairs(extraIds) do
			t_insert(ids, id)
		end
		-- Small shards: a single node evaluation can run over a second on heavy
		-- FullDPS builds, and a queued interactive batch (gem/item sort) can only
		-- start once a worker finishes its current shard. The default sharding can
		-- produce one fat shard per worker, pinning the whole pool for its duration.
		local shards = workerPool:ShardList(ids, "nodeIds", { stats = stats, useFullDPS = useFullDPS }, 2)
		-- A rebuild supersedes any still-queued shards from the previous one
		workerPool:CancelBatch(self.nodePowerPoolBatch)
		pooledOutputs = workerPool:SubmitBatch("nodePower", shards)
		self.nodePowerPoolBatch = pooledOutputs or nil
	end

	-- With the pool doing the heavy work, keep main-thread time slices short so the
	-- UI stays smooth; the old 100ms budget is only needed for all-local builds
	local frameBudget = pooledOutputs and 15 or 100

	local start = GetTime()
	local nodeIndex = 0
	local total = 0

	for nodeId, node in pairs(self.build.spec.nodes) do
		wipeTable(node.power)
		if node.type == "Mastery" then
			node.power.masteryEffects = { }
		end
		if node.modKey ~= "" and not self.mainEnv.grantedPassives[nodeId] then
			if node.type == "Mastery" and node.allMasteryOptions then
				if not (self.nodePowerMaxDepth and self.nodePowerMaxDepth < node.pathDist) then
					t_insert(masteryNodeList, node)
					for _, masteryEffect in ipairs(node.masteryEffects or { }) do
						if masteryEffectCanBeAssignedToNode(node, masteryEffect) then
							total = total + 1
						end
					end
				end
			else
				local dist = node.pathDist or 1000
				for _, leap in ipairs(node.intuitiveLeapLikesAffecting or {}) do
					if leap.alloc then
						dist = math.max(math.min(leap.pathDist or 1000, dist), 1)
					end
				end
				distanceMap[dist] = distanceMap[dist] or {}
				distanceMap[dist][nodeId] = node
				node.power.distance = dist
				if (not self.nodePowerMaxDepth) or dist <= self.nodePowerMaxDepth then
					total = total + 1
				end
			end
		end
	end
	for distance, nodes in pairs(distanceMap) do
		t_insert(distanceList, { distance, nodes })
	end
	distanceMap = nil
	table.sort(distanceList, function(a, b) return a[1] < b[1] end)
	-- Count eligible cluster nodes
	for _, node in pairs(self.build.spec.tree.clusterNodeMap) do
		if not node.alloc and node.modKey ~= "" and not self.mainEnv.grantedPassives[node.id] then
			total = total + 1
		end
	end

	for _, data in ipairs(distanceList) do
		local distance, nodes = data[1], data[2]
		if self.nodePowerMaxDepth and self.nodePowerMaxDepth < distance then
			break
		end
		for nodeId, node in pairs(nodes) do
			if not node.alloc and node.modKey ~= "" and not self.mainEnv.grantedPassives[nodeId] then
				if not cache[node.modKey] then
					-- Wait for the node's shard (already-processed nodes keep drawing);
					-- only compute locally if the batch ended without it (worker died)
					local pooled = pooledOutputs and pooledOutputs.results[tostring(nodeId)]
					while not pooled and pooledOutputs and pooledOutputs.pending > 0 do
						coroutine.yield()
						pooled = pooledOutputs.results[tostring(nodeId)]
					end
					if pooled then
						cache[node.modKey] = pooled
						if aggregate then
							aggregate:LearnExact(node, pooled, true)
						end
					else
						cache[node.modKey] = calcFunc({ addNodes = { [node] = true } }, useFullDPS)
						if aggregate then
							aggregate:LearnExact(node, cache[node.modKey])
						end
					end
				end
				local output = cache[node.modKey]
				calculateAddNodePower(node.power, distance, node, output, function()
					local pathArray = { }
					for _, pathNode in pairs(node.path) do
						t_insert(pathArray, pathNode)
					end
					local composed = aggregate and aggregate:ComposeNodes(pathArray)
					if composed then
						if #aggregateSample < 5 and #pathArray > 2 then
							t_insert(aggregateSample, { node = node, pathArray = pathArray, composed = composed })
						end
						return composed
					end
					local pathNodes = { }
					for _, pathNode in ipairs(pathArray) do
						pathNodes[pathNode] = true
					end
					return calcFunc({ addNodes = pathNodes }, useFullDPS)
				end)
			elseif node.alloc and node.modKey ~= "" and not self.mainEnv.grantedPassives[nodeId] then
				if not cache[node.modKey.."_remove"] then
					cache[node.modKey.."_remove"] = (pooledOutputs and pooledOutputs.results["r" .. nodeId])
						or calcFunc({ removeNodes = { [node] = true } }, useFullDPS)
				end
				local output = cache[node.modKey.."_remove"]
				if self.powerStat and self.powerStat.stat and not self.powerStat.ignoreForNodes then
					node.power.singleStat = self:CalculatePowerStat(self.powerStat, output, calcBase)
					if node.depends and not node.ascendancyName then
						node.power.pathPower = node.power.singleStat
						if #node.depends > 1 then
							local pathOutput = (pooledOutputs and pooledOutputs.results["p" .. nodeId]) or calcFunc(self.BuildNodePowerOverride(self.build.spec, "p" .. nodeId), useFullDPS)
							node.power.pathPower = self:CalculatePowerStat(self.powerStat, pathOutput, calcBase)
						end
					end
				end
			end
			if node.type == "Mastery" then
				local selectedEffectId = self.build.spec.masterySelections[node.id]
				if selectedEffectId then
					node.power.masteryEffects[selectedEffectId] = {
						singleStat = node.power.singleStat,
						pathPower = node.power.pathPower,
						offence = node.power.offence,
						defence = node.power.defence,
					}
				end
			end
			nodeIndex = nodeIndex + 1
			if coroutine.running() and GetTime() - start > frameBudget then
				if self.build.powerBuilderProgressCallback then
					self.build.powerBuilderProgressCallback(m_floor(nodeIndex/total*100))
				end
				coroutine.yield()
				start = GetTime()
			end
		end
	end

	for _, node in ipairs(masteryNodeList) do
		for _, masteryEffect in ipairs(node.masteryEffects or { }) do
			if masteryEffectCanBeAssignedToNode(node, masteryEffect) then
				local effect = self.build.spec.tree.masteryEffects[masteryEffect.effect]
				if effect then
					local effectNode = buildMasteryEffectNode(node, effect)
					if effectNode.modKey ~= "" then
						if not cache[effectNode.modKey] then
							local pooled = pooledOutputs and pooledOutputs.results["m" .. node.id .. "/" .. effect.id]
							if pooled then
								cache[effectNode.modKey] = pooled
								if aggregate then
									aggregate:LearnExact(effectNode, pooled, true)
								end
							else
								cache[effectNode.modKey] = calcFunc({ addNodes = { [effectNode] = true } }, useFullDPS)
								if aggregate then
									aggregate:LearnExact(effectNode, cache[effectNode.modKey])
								end
							end
						end
						local output = cache[effectNode.modKey]
						node.power.masteryEffects[effect.id] = { }
						local effectPower = node.power.masteryEffects[effect.id]
						calculateAddNodePower(effectPower, node.pathDist, node, output, function()
							local pathArray = { effectNode }
							for _, pathNode in pairs(node.path) do
								if pathNode ~= node then
									t_insert(pathArray, pathNode)
								end
							end
							local composed = aggregate and aggregate:ComposeNodes(pathArray)
							if composed then
								return composed
							end
							local pathNodes = { }
							for _, pathNode in ipairs(pathArray) do
								pathNodes[pathNode] = true
							end
							return calcFunc({ addNodes = pathNodes }, useFullDPS)
						end)
						if self.powerStat and self.powerStat.stat and not self.powerStat.ignoreForNodes then
							effectPower.pathPower = effectPower.pathPower or effectPower.singleStat
							node.power.singleStat = m_max(node.power.singleStat or 0, effectPower.singleStat)
							node.power.pathPower = m_max(node.power.pathPower or 0, effectPower.pathPower)
						elseif not self.powerStat or not self.powerStat.ignoreForNodes then
							node.power.offence = m_max(node.power.offence or 0, effectPower.offence)
							node.power.defence = m_max(node.power.defence or 0, effectPower.defence)
							node.power.singleStat = m_max(node.power.singleStat or 0, effectPower.singleStat)
						end
					end
					nodeIndex = nodeIndex + 1
					if coroutine.running() and GetTime() - start > frameBudget then
						if self.build.powerBuilderProgressCallback then
							self.build.powerBuilderProgressCallback(m_floor(nodeIndex/total*100))
						end
						coroutine.yield()
						start = GetTime()
					end
				end
			end
		end
	end

	-- Calculate the impact of every cluster notable
	-- used for the power report screen
	for nodeName, node in pairs(self.build.spec.tree.clusterNodeMap) do
		if not node.power then
			node.power = {}
		end
		wipeTable(node.power)
		if not node.alloc and node.modKey ~= "" and not self.mainEnv.grantedPassives[node.id] then
			if not cache[node.modKey] then
				cache[node.modKey] = (pooledOutputs and pooledOutputs.results["c" .. nodeName])
					or calcFunc({ addNodes = { [node] = true } }, useFullDPS)
			end
			local output = cache[node.modKey]
			if self.powerStat and self.powerStat.stat and not self.powerStat.ignoreForNodes then
				node.power.singleStat = self:CalculatePowerStat(self.powerStat, output, calcBase)
			end
			nodeIndex = nodeIndex + 1
			if coroutine.running() and GetTime() - start > frameBudget then
				if self.build.powerBuilderProgressCallback then
					self.build.powerBuilderProgressCallback(m_floor(nodeIndex/total*100))
				end
				coroutine.yield()
				start = GetTime()
			end
		end
	end
	-- Aggregate guardrail: recalculate a small sample of composed paths exactly and
	-- record the worst deviation, so a composition problem shows up in diagnostics
	-- instead of silently mis-colouring the heat map
	if aggregate then
		local worst = 0
		for _, sample in ipairs(aggregateSample) do
			local pathNodes = { }
			for _, pathNode in ipairs(sample.pathArray) do
				pathNodes[pathNode] = true
			end
			local exactOutput = calcFunc({ addNodes = pathNodes }, useFullDPS)
			if self.powerStat and self.powerStat.stat and not self.powerStat.ignoreForNodes then
				local exactStat = self:CalculatePowerStat(self.powerStat, exactOutput, calcBase)
				local composedStat = self:CalculatePowerStat(self.powerStat, sample.composed, calcBase)
				worst = m_max(worst, math.abs(exactStat - composedStat) / m_max(newPowerMax.singleStat, 1e-9))
			end
		end
		self.nodePowerAggregateInfo = {
			derivations = aggregate.derivations,
			composed = aggregate.composedCount,
			sampleWorstError = worst,
		}
		if launch.devMode then
			ConPrintf("Node aggregate: %d composed, %d derivations, sample worst path error %.4f%%", aggregate.composedCount, aggregate.derivations, worst * 100)
		end
	end

	self.powerMax = newPowerMax
	self.powerBuilderInitialized = true
	-- ConPrintf("Power Build time: %d ms", GetTime() - timer_start)
end

function CalcsTabClass:CalculatePowerStat(selection, original, modified)
	local originalValue = data.powerStatList.GetFromOutput(original, selection)
	local modifiedValue = data.powerStatList.GetFromOutput(modified, selection)
	return originalValue - modifiedValue
end

function CalcsTabClass:CalculateCombinedOffDefStat(original, modified)
	local defence = (original.LifeUnreserved - modified.LifeUnreserved) / m_max(3000, modified.Life) +
					(original.Armour - modified.Armour) / m_max(10000, modified.Armour) +
					((original.EnergyShieldRecoveryCap or original.EnergyShield) - (modified.EnergyShieldRecoveryCap or modified.EnergyShield)) / m_max(3000, (modified.EnergyShieldRecoveryCap or modified.EnergyShield)) +
					(original.Evasion - modified.Evasion) / m_max(10000, modified.Evasion) +
					(original.LifeRegenRecovery - modified.LifeRegenRecovery) / 500 +
					(original.EnergyShieldRegenRecovery - modified.EnergyShieldRegenRecovery) / 1000
	local modifiedDps = modified.CombinedDPS + (modified.Minion and modified.Minion.CombinedDPS or 0)
	local dpsIncr = original.CombinedDPS + (original.Minion and original.Minion.CombinedDPS or 0) - modifiedDps
	return dpsIncr / modifiedDps, defence
end

function CalcsTabClass:GetNodeCalculator()
	return unpack(self.nodeCalculator)
end

function CalcsTabClass:GetMiscCalculator()
	return unpack(self.miscCalculator)
end

function CalcsTabClass:CreateUndoState()
	return copyTable(self.input)
end

function CalcsTabClass:RestoreUndoState(state)
	wipeTable(self.input)
	for k, v in pairs(state) do
		self.input[k] = v
	end
end
