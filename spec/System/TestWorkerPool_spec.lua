-- Tests for the calculation worker pool's build synchronization and job
-- handlers. The pool itself cannot run here (no subscript host), so these
-- specs exercise the two halves directly:
--  * main side: sync serialization, section splitting and patch construction
--  * worker side: patch application and the job handlers, each verified
--    against the interactive calculation it mirrors
describe("WorkerPool", function()
	local pool = main.workerPool
	local workerJobs = LoadModule("Modules/WorkerJobs")

	local function syncText()
		return pool:StripSyncText(build:SaveDB("worker sync"))
	end

	-- Serialization normalizes some attribute ordering on the first
	-- save-load-save round trip; sync diffs in production always compare saves
	-- of the same live build, so tests must too
	local function normalizedBaseline()
		loadBuildFromXML(syncText(), "WorkerPool spec")
		return syncText()
	end

	local function changedSections(sectionsA, sectionsB)
		local changed = { }
		for name, sec in pairs(sectionsB) do
			if not sectionsA[name] or sectionsA[name].text ~= sec.text then
				table.insert(changed, name)
			end
		end
		for name in pairs(sectionsA) do
			if not sectionsB[name] then
				table.insert(changed, name)
			end
		end
		table.sort(changed)
		return changed
	end

	-- Constructs the patch a worker synced to textA would receive to reach textB
	local function buildPatchBetween(textA, sectionsA, textB)
		pool.buildXmlCache.sections = pool:SplitSections(textB)
		pool.buildXmlCache.patchCache = { }
		return pool:BuildPatch({ syncedText = textA, syncedSections = sectionsA }, textB)
	end

	-- All numeric outputs of a calculation, for exact-equality comparison
	local function probeOutputs()
		local calcFunc = build.calcsTab:GetMiscCalculator()
		local output = calcFunc()
		local snapshot = { }
		for k, v in pairs(output) do
			if type(v) == "number" then
				snapshot[k] = v
			end
		end
		if output.Minion then
			snapshot.MinionCombinedDPS = output.Minion.CombinedDPS
		end
		return snapshot
	end

	local function addSocketGroup()
		build.skillsTab:PasteSocketGroup("Slot: Helmet\nCleave 20/0  1\n")
		runCallback("OnFrame")
	end

	local function addRing(mod)
		build.itemsTab:CreateDisplayItemFromRaw("New Item\nCoral Ring\n" .. mod)
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")
	end

	local function findLinkedUnallocatedNode()
		for _, node in pairs(build.spec.nodes) do
			if not node.alloc and node.type == "Normal" and node.modKey ~= "" then
				for _, other in ipairs(node.linked or { }) do
					if other.alloc then
						return node
					end
				end
			end
		end
	end

	before_each(function()
		newBuild()
		pool.logPath = "/dev/null"
		pool.buildXmlCache = { }
	end)

	teardown(function()
		-- newBuild() takes care of resetting everything in setup()
	end)

	describe("sync serialization", function()
		it("excludes display stats and is stable across recalculation", function()
			addSocketGroup()
			local before = syncText()
			assert.is_nil(before:find("<PlayerStat", 1, true))
			assert.is_nil(before:find("<MinionStat", 1, true))
			assert.is_nil(before:find("<FullDPSSkill", 1, true))
			-- A recalculation must not change the sync text: if this fails, SaveDB
			-- gained an output-derived element that needs adding to StripSyncText,
			-- or workers will reload twice per edit
			build.buildFlag = true
			runCallback("OnFrame")
			assert.are.equal(before, syncText())
		end)
	end)

	describe("incremental section sync", function()
		it("a gem edit changes only the Skills section", function()
			addSocketGroup()
			local textA = normalizedBaseline()
			local sectionsA = pool:SplitSections(textA)
			build.skillsTab.socketGroupList[1].gemList[1].level = 10
			build.buildFlag = true
			runCallback("OnFrame")
			assert.are.same({ "Skills" }, changedSections(sectionsA, pool:SplitSections(syncText())))
		end)

		it("a config edit changes only the Config section", function()
			addSocketGroup()
			local textA = normalizedBaseline()
			local sectionsA = pool:SplitSections(textA)
			build.configTab.input.enemyIsBoss = "Boss"
			build.configTab:BuildModList()
			build.buildFlag = true
			runCallback("OnFrame")
			assert.are.same({ "Config" }, changedSections(sectionsA, pool:SplitSections(syncText())))
		end)

		it("a tree change forces a full sync", function()
			addSocketGroup()
			local textA = normalizedBaseline()
			local sectionsA = pool:SplitSections(textA)
			local node = findLinkedUnallocatedNode()
			assert.is_not_nil(node)
			build.spec:AllocNode(node)
			build.buildFlag = true
			runCallback("OnFrame")
			assert.is_nil(buildPatchBetween(textA, sectionsA, syncText()))
		end)

		local function assertPatchMatchesFullReload(edit)
			local textA = normalizedBaseline()
			local sectionsA = pool:SplitSections(textA)
			edit()
			build.buildFlag = true
			runCallback("OnFrame")
			local textB = syncText()
			local patch = buildPatchBetween(textA, sectionsA, textB)
			assert.is_not_nil(patch)
			-- Reference: a worker that reloads the edited build from scratch
			loadBuildFromXML(textB, "WorkerPool spec")
			local expected = probeOutputs()
			-- A worker on the old build applies the patch instead
			loadBuildFromXML(textA, "WorkerPool spec")
			workerJobs.ApplyPatch(patch.text)
			assert.are.same(expected, probeOutputs())
		end

		it("applying a gem edit patch matches a full reload", function()
			addSocketGroup()
			assertPatchMatchesFullReload(function()
				build.skillsTab.socketGroupList[1].gemList[1].level = 10
			end)
		end)

		it("applying a config edit patch matches a full reload", function()
			addSocketGroup()
			assertPatchMatchesFullReload(function()
				build.configTab.input.enemyIsBoss = "Boss"
				build.configTab:BuildModList()
			end)
		end)

		it("applying an item edit patch matches a full reload", function()
			addSocketGroup()
			addRing("+100 to maximum Life")
			assertPatchMatchesFullReload(function()
				for _, id in ipairs(build.itemsTab.itemOrderList) do
					local item = build.itemsTab.items[id]
					if item.name:match("Coral Ring") then
						item.explicitModLines[1].line = "+50 to maximum Life"
						item:BuildAndParseRaw()
						break
					end
				end
				build.itemsTab:PopulateSlots()
			end)
		end)
	end)

	describe("job handlers mirror interactive calculations", function()
		it("gemDps matches GemSelectControl:CalcOutputWithThisGem", function()
			addSocketGroup()
			build.skillsTab.displayGroup = build.skillsTab.socketGroupList[1]
			local candidates = { }
			for gemId, gemData in pairs(build.data.gems) do
				if gemData.grantedEffect and not gemData.grantedEffect.support and not gemData.grantedEffect.hideFromGemList then
					table.insert(candidates, gemId)
				end
			end
			table.sort(candidates)
			while #candidates > 3 do
				table.remove(candidates)
			end
			local gemIndex = 2 -- an empty slot next to the Cleave gem
			local dpsField = "CombinedDPS"
			-- Interactive truth: the dropdown's own calculation, run through the
			-- real control method with the extraction from BuildSortCache
			local calcFunc = build.calcsTab:GetMiscCalculator()
			local uiControl = { skillsTab = build.skillsTab, index = gemIndex }
			local expected = { }
			for _, gemId in ipairs(candidates) do
				local output = common.classes.GemSelectControl.CalcOutputWithThisGem(uiControl, calcFunc, build.data.gems[gemId], false)
				expected[gemId] = (output.Minion and output.Minion.CombinedDPS) or (output[dpsField] ~= nil and output[dpsField]) or 0
			end
			local results = workerJobs.handlers.gemDps({
				groupIndex = 1,
				gemIndex = gemIndex,
				dpsField = dpsField,
				defaultLevel = build.skillsTab.defaultGemLevel,
				defaultQuality = build.skillsTab.defaultGemQuality,
				gemIds = candidates,
			})
			assert.is_nil(results.workerError)
			for _, gemId in ipairs(candidates) do
				assert.are.equal(expected[gemId], results[gemId], "gem " .. gemId)
			end
		end)

		it("gemDps matches the dropdown for an occupied slot with non-default quality", function()
			-- Candidates evaluated for an occupied slot must inherit the existing
			-- gem's quality, exactly as the dropdown's hover calculation does; the
			-- pre-refactor worker copy reset it to the default quality instead
			addSocketGroup()
			build.skillsTab.displayGroup = build.skillsTab.socketGroupList[1]
			build.skillsTab.displayGroup.gemList[1].quality = 7
			build.buildFlag = true
			runCallback("OnFrame")
			local candidate
			for gemId, gemData in pairs(build.data.gems) do
				if gemData.grantedEffect and not gemData.grantedEffect.support and not gemData.grantedEffect.hideFromGemList and gemData.name ~= "Cleave" then
					if not candidate or gemId < candidate then
						candidate = gemId
					end
				end
			end
			local calcFunc = build.calcsTab:GetMiscCalculator()
			local uiControl = { skillsTab = build.skillsTab, index = 1 }
			local output = common.classes.GemSelectControl.CalcOutputWithThisGem(uiControl, calcFunc, build.data.gems[candidate], false)
			local expected = build.skillsTab.ExtractGemDps(output, "CombinedDPS")
			local results = workerJobs.handlers.gemDps({
				groupIndex = 1,
				gemIndex = 1,
				dpsField = "CombinedDPS",
				defaultLevel = build.skillsTab.defaultGemLevel,
				defaultQuality = build.skillsTab.defaultGemQuality,
				gemIds = { candidate },
			})
			assert.is_nil(results.workerError)
			assert.are.equal(expected, results[candidate])
		end)

		it("itemPower matches the ItemDBControl sort", function()
			addSocketGroup()
			local statEntry
			for _, entry in ipairs(data.powerStatList) do
				if entry.stat == "Life" then
					statEntry = entry
					break
				end
			end
			assert.is_not_nil(statEntry)
			local rawBetter = "New Item\nCoral Ring\n+100 to maximum Life"
			local rawWorse = "New Item\nCoral Ring\n+20 to maximum Life"
			local items = { new("Item", rawBetter), new("Item", rawWorse) }
			-- Interactive truth: the item DB list builder's synchronous path (the
			-- pool is unavailable under busted)
			local control = new("ItemDBControl", nil, { 0, 0, 100, 100 }, build.itemsTab, { list = items }, "RARE")
			control.sortDetail = statEntry
			control.sortOrder = { control.sortControl.STAT, control.sortControl.NAME }
			control:ListBuilder()
			local slots = { }
			for slotName, slot in pairs(build.itemsTab.slots) do
				if not slot.inactive and (not slot.weaponSet or slot.weaponSet == (build.itemsTab.activeItemSet.useSecondWeaponSet and 2 or 1)) then
					table.insert(slots, slotName)
				end
			end
			local results = workerJobs.handlers.itemPower({
				stat = statEntry.stat,
				statLabel = statEntry.label,
				slots = slots,
				items = { ["1"] = rawBetter, ["2"] = rawWorse },
			})
			for i, item in ipairs(items) do
				assert.are.equal(item.measuredPower, results[tostring(i)], item.name)
			end
		end)

		it("nodePower matches direct calculation for adds and removals", function()
			addSocketGroup()
			local addNode = findLinkedUnallocatedNode()
			assert.is_not_nil(addNode)
			local calcFunc = build.calcsTab:GetMiscCalculator()
			local expectedAdd = calcFunc({ addNodes = { [addNode] = true } }, false)
			build.spec:AllocNode(addNode)
			build.buildFlag = true
			runCallback("OnFrame")
			calcFunc = build.calcsTab:GetMiscCalculator()
			local expectedRemove = calcFunc({ removeNodes = { [addNode] = true } }, false)
			local results = workerJobs.handlers.nodePower({
				nodeIds = { "r" .. addNode.id },
				stats = { "Life", "Mana", "CombinedDPS" },
				useFullDPS = false,
			})
			for _, stat in ipairs({ "Life", "Mana", "CombinedDPS" }) do
				if type(expectedRemove[stat]) == "number" then
					assert.are.equal(expectedRemove[stat], results["r" .. addNode.id][stat], "removal " .. stat)
				end
			end
			-- Roll the allocation back and verify the "add" form on a fresh build
			build.spec:DeallocNode(addNode)
			build.spec:BuildAllDependsAndPaths()
			build.buildFlag = true
			runCallback("OnFrame")
			results = workerJobs.handlers.nodePower({
				nodeIds = { tostring(addNode.id) },
				stats = { "Life", "Mana", "CombinedDPS" },
				useFullDPS = false,
			})
			for _, stat in ipairs({ "Life", "Mana", "CombinedDPS" }) do
				if type(expectedAdd[stat]) == "number" then
					assert.are.equal(expectedAdd[stat], results[tostring(addNode.id)][stat], "addition " .. stat)
				end
			end
		end)
	end)

	describe("deferred tree rebuild", function()
		local function dependsFingerprint(spec)
			local fp = { }
			for id, node in pairs(spec.nodes) do
				fp[id] = string.format("%s:%d:%d", tostring(node.alloc), node.depends and #node.depends or -1, node.pathDist or -1)
			end
			return fp
		end

		it("finishes build load with no pending rebuild", function()
			assert.is_nil(build.deferSpecRebuild)
			assert.is_nil(build.spec.rebuildPending)
		end)

		it("the single deferred rebuild converges", function()
			addSocketGroup()
			local before = dependsFingerprint(build.spec)
			-- If load-time deferral skipped a rebuild whose result mattered, an
			-- explicit rebuild would change the graph state
			build.spec:BuildAllDependsAndPaths()
			assert.are.same(before, dependsFingerprint(build.spec))
		end)

		it("activating a spec with a pending rebuild flushes it", function()
			local spec2 = new("PassiveSpec", build, build.spec.treeVersion)
			spec2.title = "WorkerPool spec"
			table.insert(build.treeTab.specList, spec2)
			spec2.rebuildPending = true
			build.treeTab:SetActiveSpec(#build.treeTab.specList)
			assert.are.equal(spec2, build.spec)
			assert.is_nil(spec2.rebuildPending)
		end)
	end)
end)
