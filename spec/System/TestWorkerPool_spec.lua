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

	-- A gem dropdown standing on the currently displayed socket group, so the
	-- specs can call the control's real methods without a UI
	local function gemSelectStub(gemIndex)
		return setmetatable({ skillsTab = build.skillsTab, index = gemIndex }, { __index = common.classes.GemSelectControl })
	end

	local function addEmptySocketGroup()
		local group = { label = "", enabled = true, gemList = { } }
		table.insert(build.skillsTab.socketGroupList, group)
		build.buildFlag = true
		runCallback("OnFrame")
		return group
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
			-- real control method and the shared extraction
			local calcFunc = build.calcsTab:GetMiscCalculator()
			local uiControl = gemSelectStub(gemIndex)
			local expected = { }
			for _, gemId in ipairs(candidates) do
				local output = uiControl:CalcOutputWithThisGem(calcFunc, build.data.gems[gemId], false)
				expected[gemId] = build.skillsTab.ExtractGemDps(output, dpsField)
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
			local output = gemSelectStub(1):CalcOutputWithThisGem(calcFunc, build.data.gems[candidate], false)
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

		it("puts the group's display list back after staging a candidate", function()
			-- Calculating rebuilds displayGemList around the staged gem. The dropdown
			-- used to undo that at its own call site, so the workers -- which run the
			-- same staging directly -- left their build's group pointing at the last
			-- candidate they tried.
			addSocketGroup()
			local group = build.skillsTab.socketGroupList[1]
			build.skillsTab.displayGroup = group
			local candidate
			for gemId, gemData in pairs(build.data.gems) do
				if gemData.grantedEffect and not gemData.grantedEffect.support and not gemData.grantedEffect.hideFromGemList and gemData.name ~= "Cleave" then
					if not candidate or gemId < candidate then
						candidate = gemId
					end
				end
			end
			local before = group.displayGemList
			assert.is_not_nil(before)

			local calcFunc = build.calcsTab:GetMiscCalculator()
			build.skillsTab:CalcGemSwapOutput(group, 2, build.data.gems[candidate], calcFunc, false, nil)
			assert.are.equal(before, group.displayGemList)
			assert.is_nil(group.gemList[2])

			-- ...and when the calculation raises, so the error does not leave the
			-- group staged with a gem the user never picked
			local ok = pcall(build.skillsTab.CalcGemSwapOutput, build.skillsTab, group, 2,
				build.data.gems[candidate], function() error("boom") end, false, nil)
			assert.is_false(ok)
			assert.are.equal(before, group.displayGemList)
			assert.is_nil(group.gemList[2])
		end)

		it("the nodePower prefetch covers every evaluation PowerBuilder makes", function()
			-- BuildNodePowerPlan is the single place the evaluation workload is
			-- decided; the loops walk its structures, so drift is only possible if a
			-- loop asks for a key outside plan.ids. Hand PowerBuilder exactly the
			-- results a healthy pool would return for the plan -- any further
			-- evaluation is counted as a local miss.
			addSocketGroup()
			build.buildFlag = true
			runCallback("OnFrame")
			local calcsTab = build.calcsTab
			local plan = calcsTab:BuildNodePowerPlan()
			assert.is_true(#plan.ids > 0)
			local results = workerJobs.handlers.nodePower({ nodeIds = plan.ids, stats = calcsTab:NodePowerStats(), useFullDPS = false })
			local fake = { results = results, pending = 0 }
			local realSubmit = calcsTab.SubmitNodePowerPrefetch
			calcsTab.SubmitNodePowerPrefetch = function() return fake end
			local ok, err = pcall(function()
				calcsTab:PowerBuilder()
			end)
			calcsTab.SubmitNodePowerPrefetch = realSubmit
			assert(ok, err)
			assert.are.equal(0, fake.localMisses or 0)
		end)

		it("consumes pooled results as shards arrive, not once the batch is done", function()
			-- The other prefetch specs hand PowerBuilder a finished batch
			-- (pending 0), which skips the readiness gate entirely. Streaming only
			-- happens while a batch is in flight, so drive one that is still
			-- arriving. Which results are outstanding has to be chosen, not left to
			-- table order: the map is rebuilt one distance band at a time, so only
			-- a straggler inside the band being processed holds anything up, and an
			-- arbitrary half of the keys makes the outcome depend on LuaJIT's hash
			-- order rather than on the code under test. So: hold back exactly one
			-- node of the first band. Its neighbours have to be drawn now -- if they
			-- wait for it, or for the batch, the map paints in one jump at the end
			-- and the progress toast never moves.
			addSocketGroup()
			build.buildFlag = true
			runCallback("OnFrame")
			local calcsTab = build.calcsTab
			local plan = calcsTab:BuildNodePowerPlan()
			local all = workerJobs.handlers.nodePower({ nodeIds = plan.ids, stats = calcsTab:NodePowerStats(), useFullDPS = false })

			-- Results come back through JSON, so every key in a batch is a string;
			-- the keys the consumer waits on have to be the same ones
			for _, keys in pairs(plan.nodeKeys) do
				for _, key in ipairs(keys) do
					assert.are.equal("string", type(key))
					assert.is_not_nil(all[key])
				end
			end

			-- Unallocated nodes are the ones that record a power value in the
			-- default (no power stat selected) mode this spec runs in
			local band = { }
			for _, node in pairs(plan.distanceList[1][2]) do
				if not node.alloc then
					table.insert(band, node)
				end
			end
			assert.is_true(#band > 1)
			local straggler = band[1]
			local outstanding = { }
			for _, key in ipairs(plan.nodeKeys[straggler]) do
				outstanding[key] = true
			end
			local arrived = { }
			for key, value in pairs(all) do
				if not outstanding[key] then
					arrived[key] = value
				end
			end

			local fake = { results = arrived, pending = 1 }
			local realSubmit = calcsTab.SubmitNodePowerPrefetch
			calcsTab.SubmitNodePowerPrefetch = function() return fake end
			local builder = coroutine.create(calcsTab.PowerBuilder)
			local function pump(times)
				for _ = 1, times do
					if coroutine.status(builder) == "dead" then
						return
					end
					local ok, err = coroutine.resume(builder, calcsTab)
					assert(ok, err)
				end
			end
			pump(50)

			for i = 2, #band do
				assert.is_not_nil(band[i].power.offence,
					"node " .. band[i].id .. " waited on a straggler in its own band")
			end
			-- The one still being computed is neither drawn nor quietly recalculated
			-- on this thread
			assert.is_nil(straggler.power.offence)
			assert.are.equal(0, fake.localMisses or 0)

			-- It lands, the loop revisits it, and the build finishes
			for key, value in pairs(all) do
				fake.results[key] = value
			end
			fake.pending = 0
			pump(2000)
			calcsTab.SubmitNodePowerPrefetch = realSubmit
			assert.are.equal("dead", coroutine.status(builder))
			assert.is_not_nil(straggler.power.offence)
			assert.are.equal(0, fake.localMisses or 0)
		end)

		it("the nodePower prefetch also covers path evaluations in stat mode", function()
			-- Selecting a specific power stat makes the loops evaluate each node's
			-- whole path as well ("a"/"M" keys); those must be planned and pooled
			-- too, or the map quietly degrades to main-thread path calculations
			addSocketGroup()
			build.buildFlag = true
			runCallback("OnFrame")
			local calcsTab = build.calcsTab
			local restoreStat = calcsTab.powerStat
			for _, entry in ipairs(data.powerStatList) do
				if entry.stat == "Life" then
					calcsTab.powerStat = entry
					break
				end
			end
			assert.is_not_nil(calcsTab.powerStat and calcsTab.powerStat.stat)
			local plan = calcsTab:BuildNodePowerPlan()
			local pathKeys = 0
			for _, id in ipairs(plan.ids) do
				if tostring(id):match("^[aM]") then
					pathKeys = pathKeys + 1
				end
			end
			assert.is_true(pathKeys > 0)
			local results = workerJobs.handlers.nodePower({ nodeIds = plan.ids, stats = calcsTab:NodePowerStats(), useFullDPS = false })
			local fake = { results = results, pending = 0 }
			local realSubmit = calcsTab.SubmitNodePowerPrefetch
			calcsTab.SubmitNodePowerPrefetch = function() return fake end
			local ok, err = pcall(function()
				calcsTab:PowerBuilder()
			end)
			calcsTab.SubmitNodePowerPrefetch = realSubmit
			calcsTab.powerStat = restoreStat
			assert(ok, err)
			assert.are.equal(0, fake.localMisses or 0)
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
			local items = { new("Item"):Item(rawBetter), new("Item"):Item(rawWorse) }
			-- Interactive truth: the item DB list builder's synchronous path (the
			-- pool is unavailable under busted)
			local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 100, 100 }, build.itemsTab, { list = items }, "RARE")
			-- Sort by a dropdown entry as BuildSortOrder builds it, not by the raw
			-- data.powerStatList entry: the two are not interchangeable, because the
			-- dropdown's `label` carries a "Sort by " prefix for display. Assigning
			-- the raw entry here is what let that mismatch go unnoticed.
			-- (The sort dropdown control itself only exists for dbType "UNIQUE", so
			-- drive BuildSortOrder directly and pick the entry rather than selecting it.)
			control:BuildSortOrder()
			local sortOption
			for _, option in ipairs(control.sortDropList) do
				if data.powerStatList[option.statIndex] == statEntry then
					sortOption = option
					break
				end
			end
			assert.is_not_nil(sortOption)
			assert.are.equal("Sort by " .. statEntry.label, sortOption.label)
			control.sortDetail = sortOption
			control.sortOrder = { control.sortControl.STAT, control.sortControl.NAME }
			control:ListBuilder()
			local results = workerJobs.handlers.itemPower({
				statIndex = control.sortDetail.statIndex,
				slots = build.itemsTab:GetEquippableSlotNames(),
				items = { ["1"] = rawBetter, ["2"] = rawWorse },
			})
			assert.is_nil(results.workerError)
			for i, item in ipairs(items) do
				assert.are.equal(item.measuredPower, results[tostring(i)], item.name)
			end
		end)

		it("every item sort option resolves to the stat the itemPower worker will use", function()
			-- The handler looks its stat entry up by index. If an option does not
			-- resolve, or resolves to a different stat than the main thread sorts by,
			-- the pooled and local halves measure different things -- or the handler
			-- measures nothing at all, every candidate keeps its -inf placeholder and
			-- the list silently comes back unsorted.
			local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 100, 100 }, build.itemsTab, { list = { } }, "RARE")
			local checked = 0
			for _, option in ipairs(control.sortDropList) do
				if option.stat then
					local entry = data.powerStatList[option.statIndex]
					assert.is_not_nil(entry, "no powerStatList entry for sort option " .. tostring(option.label))
					assert.are.equal(option.stat, entry.stat, tostring(option.label))
					assert.are.equal(option.transform, entry.transform, tostring(option.label))
					assert.are.equal("Sort by " .. entry.label, option.label)
					checked = checked + 1
				end
			end
			assert.is_true(checked > 0)
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

	describe("options", function()
		it("is off unless the user asks for workers", function()
			-- The fleet is not free and is not lazy: it starts as soon as it is
			-- enabled, and each worker holds a full copy of the program for as long
			-- as it runs, so an install nobody has configured spawns nothing
			assert.are.equal(0, main.workerPoolCount)
			assert.are.equal(0, pool:DesiredCount())
			assert.is_false(pool:IsAvailable())
			assert.is_falsy(pool.started)
		end)
	end)

	describe("partial results", function()
		-- The pooled paths cannot run under busted (no subscript host), so these
		-- stand in a pool that loses its fleet part-way through a batch: it
		-- completes with the results that did arrive, which is what
		-- AbandonOutstanding does to release the consumer.
		local function withHalfLostFleet(fn)
			local realAvailable, realSubmit = pool.IsAvailable, pool.SubmitBatch
			pool.IsAvailable = function() return true end
			pool.SubmitBatch = function(_, kind, shards, opts)
				local batch = { id = 0, kind = kind, request = opts.request, state = "abandoned",
					results = { }, resultCount = 0, errorCount = 0, pending = 0, total = #shards }
				-- Exactly one work unit comes back, computed the way a worker would
				for _, shard in ipairs(shards) do
					for key, raw in pairs(shard.items) do
						batch.results[key] = workerJobs.handlers.itemPower({
							statIndex = shard.statIndex, slots = shard.slots,
							items = { [key] = raw },
						})[key]
						batch.resultCount = 1
						break
					end
					break
				end
				opts.onComplete(batch.results)
				return batch
			end
			local ok, err = pcall(fn)
			pool.IsAvailable, pool.SubmitBatch = realAvailable, realSubmit
			assert(ok, err)
		end

		it("measures the items a lost batch never got to", function()
			-- Items the batch did not measure are still on the -inf placeholder the
			-- pooled path seeds them with, and -inf sorts to the bottom looking
			-- exactly like a real measurement. Only a batch that came back
			-- completely empty used to be noticed.
			addSocketGroup()
			local items = {
				new("Item"):Item("New Item\nCoral Ring\n+100 to maximum Life"),
				new("Item"):Item("New Item\nCoral Ring\n+20 to maximum Life"),
			}
			local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 100, 100 }, build.itemsTab, { list = items }, "RARE")
			control:BuildSortOrder()
			for _, option in ipairs(control.sortDropList) do
				if option.stat == "Life" then
					control.sortDetail = option
					break
				end
			end
			assert.is_not_nil(control.sortDetail)
			control.sortOrder = { control.sortControl.STAT, control.sortControl.NAME }

			withHalfLostFleet(function()
				control:ListBuilder()
			end)

			-- Every item carries a real measurement, whichever half of the work the
			-- fleet managed
			local calcFunc = build.calcsTab:GetMiscCalculator()
			local slots = build.itemsTab:GetEquippableSlotNames()
			for _, item in ipairs(items) do
				assert.is_true(item.measuredPower > -math.huge, item.name .. " was left unmeasured")
				assert.are.equal(build.itemsTab:MeasureItemPower(item, control.sortDetail, calcFunc, false, slots),
					item.measuredPower, item.name)
			end
			-- ...so the list is actually in power order, not "measured first"
			assert.are.equal(items[1], control.list[1])
			assert.are.equal(items[2], control.list[2])
		end)
	end)

	describe("batch lifecycle", function()
		-- No subscript host here, so stand in a live fleet: the batch paths only
		-- read aliveCount and the job tables
		local function withFakeFleet(fn)
			local saved = { started = pool.started, startRequested = pool.startRequested,
				aliveCount = pool.aliveCount, workers = pool.workers, jobs = pool.jobs,
				jobQueue = pool.jobQueue, batches = pool.batches }
			-- The pool is off unless the option asks for workers, so a stand-in
			-- fleet has to say so too
			local savedCount = main.workerPoolCount
			main.workerPoolCount = 1
			pool.started = true
			pool.startRequested = nil
			pool.aliveCount = 1
			pool.workers = { [1] = { subId = 1, alive = true } }
			pool.jobs = { }
			pool.jobQueue = { }
			pool.batches = { }
			local ok, err = pcall(fn)
			main.workerPoolCount = savedCount
			for key, value in pairs(saved) do
				pool[key] = value
			end
			assert(ok, err)
		end

		local function submitTwoShards(request)
			local seen = { }
			local batch = pool:SubmitBatch("nodePower", { { nodeIds = { 1 } }, { nodeIds = { 2 } } }, {
				request = request,
				onComplete = function(results)
					seen.results = results
				end,
				onProgress = function(done, total)
					seen.done = done
				end,
			})
			assert.is_truthy(batch)
			assert.are.equal(2, batch.pending)
			return batch, seen
		end

		it("gives every task an id and a state it can be followed by", function()
			withFakeFleet(function()
				local first = submitTwoShards()
				local second = submitTwoShards()
				assert.are_not.equal(first.id, second.id)
				assert.are.equal("queued", first.state)
				-- The pool knows about a task until it reaches a terminal state
				assert.are.equal(first, pool.batches[first.id])

				local _, shardA = pool:DispatchNext(1)
				assert.are.equal("active", first.state)
				pool:CompleteJob(shardA, '{"1":{"CombinedDPS":1}}')
				assert.are.equal("active", first.state)
				assert.are.equal(1, first.pending)

				local _, shardB = pool:DispatchNext(1)
				pool:CompleteJob(shardB, '{"2":{"CombinedDPS":2}}')
				assert.are.equal("complete", first.state)
				assert.are.equal(2, first.resultCount)
				-- Terminal tasks leave the registry; the one still running stays
				assert.is_nil(pool.batches[first.id])
				assert.are.equal(second, pool.batches[second.id])
				assert.are.equal("queued", second.state)
			end)
		end)

		it("names the worker and the attempt a shard ran on", function()
			withFakeFleet(function()
				local batch = submitTwoShards()
				local _, shardId = pool:DispatchNext(1)
				local job = pool.jobs[shardId]
				assert.are.equal(1, job.workerId)
				assert.are.equal(1, job.shard)
				assert.are.equal(1, job.attempts)
				assert.are.equal("dispatched", job.state)
				-- A worker that dies mid-shard hands it back for another attempt
				pool.startRequested = true
				pool:WorkerDied(1)
				assert.are.equal("queued", job.state)
				assert.is_nil(job.workerId)
				assert.are.equal(job, pool.jobQueue[1])
				pool.workers[2] = { subId = 2, alive = true }
				pool:DispatchNext(2)
				assert.are.equal(2, job.workerId)
				assert.are.equal(2, job.attempts)
			end)
		end)

		it("marks a superseded task cancelled and releases nobody", function()
			withFakeFleet(function()
				local batch, seen = submitTwoShards()
				pool:CancelBatch(batch)
				assert.are.equal("cancelled", batch.state)
				-- Whoever cancelled has moved on, so no callback fires and results
				-- that arrive afterwards are dropped rather than applied
				assert.is_nil(seen.results)
				assert.is_nil(next(pool.jobs))
				assert.is_nil(pool.batches[batch.id])
			end)
		end)

		it("reuses a live task computing the same request", function()
			withFakeFleet(function()
				local request = { group = 1, index = 2, revision = 7 }
				local batch = submitTwoShards(request)
				assert.are.equal(batch, pool:FindBatch("nodePower", { group = 1, index = 2, revision = 7 }))
				-- A different build revision is a different task, however alike the
				-- rest of the request looks
				assert.is_nil(pool:FindBatch("nodePower", { group = 1, index = 2, revision = 8 }))
				assert.is_nil(pool:FindBatch("gemDps", request))
				-- A task submitted without a descriptor is never reused
				local anonymous = submitTwoShards()
				assert.is_nil(pool:FindBatch("nodePower", nil))
				assert.is_nil(anonymous.request)
			end)
		end)

		it("records worker errors without discarding the rest of the shard", function()
			withFakeFleet(function()
				local batch = submitTwoShards()
				-- A shard where one candidate threw still carries the others
				local _, shardId = pool:DispatchNext(1)
				pool:CompleteJob(shardId, '{"1":{"CombinedDPS":5},"workerError":"gemDps: boom"}')
				assert.are.equal(1, batch.errorCount)
				assert.are.equal("gemDps: boom", batch.firstError)
				assert.are.equal(5, batch.results["1"].CombinedDPS)
				assert.are.equal(1, batch.resultCount)
				assert.is_nil(batch.results.workerError)
			end)
		end)

		it("completes outstanding tasks when the last worker dies", function()
			-- A batch left pending is not merely lost work: PowerBuilder and the item
			-- sort yield until it completes, so they would wait forever
			withFakeFleet(function()
				local batch, seen = submitTwoShards()
				pool:WorkerDied(1)
				pool:OnFrame()
				assert.are.equal("abandoned", batch.state)
				assert.are.equal(0, batch.pending)
				assert.are.equal(2, seen.done)
				assert.is_not_nil(seen.results)
				assert.is_nil(next(pool.jobs))
				assert.is_nil(pool.jobQueue[1])
			end)
		end)

		it("keeps partial results so the consumer can use what arrived", function()
			withFakeFleet(function()
				local batch, seen = submitTwoShards()
				local _, shardId = pool:DispatchNext(1)
				pool:CompleteJob(shardId, '{"1":{"CombinedDPS":5}}')
				pool:WorkerDied(1)
				pool:OnFrame()
				assert.are.equal("abandoned", batch.state)
				assert.are.equal(0, batch.pending)
				assert.are.equal(1, batch.resultCount)
				assert.are.equal(5, seen.results["1"].CombinedDPS)
			end)
		end)

		it("does not abandon queued work while a resized fleet is starting", function()
			withFakeFleet(function()
				local batch = submitTwoShards()
				pool.startRequested = true
				pool:WorkerDied(1)
				pool:OnFrame()
				assert.are.equal("queued", batch.state)
				assert.are.equal(2, batch.pending)
				assert.is_not_nil(next(pool.jobs))
			end)
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

		it("cannot leave the deferral set once a frame is drawn", function()
			-- Init clears it on every path it can see, but it lives on the mode
			-- object, which outlives the load: a section that raised would leave it
			-- set and every later rebuild would silently do nothing
			build.deferSpecRebuild = true
			runCallback("OnFrame")
			assert.is_nil(build.deferSpecRebuild)
		end)

		it("activating a spec with a pending rebuild flushes it", function()
			local spec2 = new("PassiveSpec"):PassiveSpec(build, build.spec.treeVersion)
			spec2.title = "WorkerPool spec"
			table.insert(build.treeTab.specList, spec2)
			spec2.rebuildPending = true
			build.treeTab:SetActiveSpec(#build.treeTab.specList)
			assert.are.equal(spec2, build.spec)
			assert.is_nil(spec2.rebuildPending)
		end)

		it("calculating with a spec that was never activated flushes it", function()
			-- The tree list tooltip calculates with whichever spec is hovered, which
			-- is the one way a spec gets read without being switched to. Unbuilt, it
			-- has no allocatedMasteryTypes for CalcSetup to copy
			local source = build.treeTab.specList[1]
			local copy = new("PassiveSpec"):PassiveSpec(build, source.treeVersion)
			copy.title = "Second"
			copy.jewels = copyTable(source.jewels)
			copy:RestoreUndoState(source:CreateUndoState())
			copy:BuildClusterJewelGraphs()
			table.insert(build.treeTab.specList, copy)
			build.treeTab:SetActiveSpec(1)
			loadBuildFromXML(build:SaveDB("deferred spec rebuild"), "deferred spec rebuild")

			local inactive = build.treeTab.specList[2]
			assert.is_true(inactive.rebuildPending)
			assert.is_nil(inactive.allocatedMasteryTypes)

			local calcFunc = build.calcsTab:GetMiscCalculator()
			assert.is_not_nil(calcFunc({ spec = inactive }))
			assert.is_nil(inactive.rebuildPending)
		end)
	end)
end)
