describe("TreeTab", function()
	local originalClusterNodeMap
	local originalMasteryEffects

	local function findMasteryNode()
		for _, node in pairs(build.spec.nodes) do
			if node.type == "Mastery" and node.masteryEffects and #node.masteryEffects > 0 then
				return node
			end
		end
	end

	before_each(function()
		newBuild()
		originalClusterNodeMap = build.spec.tree.clusterNodeMap
		originalMasteryEffects = build.spec.tree.masteryEffects
	end)

	after_each(function()
		build.spec.tree.clusterNodeMap = originalClusterNodeMap
		build.spec.tree.masteryEffects = originalMasteryEffects
	end)

	it("restores a Runegraft after rebuilding mastery options", function()
		local node = assert(findMasteryNode())
		local override
		for _, tattooNode in pairs(build.spec.tree.tattoo.nodes) do
			if tattooNode.overrideType == "AlternateMastery" then
				override = copyTable(tattooNode, true)
				break
			end
		end
		assert(override)
		override.id = node.id
		build.spec.hashOverrides[node.id] = override
		build.spec:ReplaceNode(node, override)

		build.spec:DeallocSingleNode(node)
		build.spec:BuildAllDependsAndPaths()

		assert.is_false(node.allMasteryOptions)
		assert.are.equal("AlternateMastery", node.overrideType)
	end)

	it("clears the selected mastery reminder after deallocation", function()
		local node = assert(findMasteryNode())
		node.reminderText = { "Tip: Right click to select a different effect" }

		build.spec:DeallocSingleNode(node)
		build.spec:BuildAllDependsAndPaths()

		assert.is_nil(node.reminderText)
	end)

	it("adds separate power report entries for mastery effects", function()
		local treeTab = build.treeTab
		local parentNode = { id = 2 }
		local masteryNode = {
			id = 1,
			type = "Mastery",
			dn = "Two Hand Mastery",
			power = {
				masteryEffects = {
					[101] = { singleStat = 10, pathPower = 10 },
					[102] = { singleStat = 20, pathPower = 20 },
				},
			},
			masteryEffects = {
				{ effect = 101 },
				{ effect = 102 },
			},
			path = { parentNode, false },
			x = 10,
			y = 20,
		}
		masteryNode.path[2] = masteryNode

		treeTab.build.displayStats = {
			{ stat = "Damage", label = "Damage", fmt = ".1f" },
		}
		treeTab.build.spec.nodes = {
			[masteryNode.id] = masteryNode,
		}
		treeTab.build.spec.masterySelections = { }
		treeTab.build.spec.tree.clusterNodeMap = { }
		treeTab.build.spec.tree.masteryEffects = {
			[101] = { id = 101, sd = { "Gain 10 Damage" }, stats = { "Gain 10 Damage" } },
			[102] = { id = 102, sd = { "Gain 20 Damage" }, stats = { "Gain 20 Damage" } },
		}
		treeTab.build.calcsTab.mainEnv = { grantedPassives = { } }

		local report = treeTab:BuildPowerReportList({ stat = "Damage", label = "Damage" })

		assert.are.same(2, #report)
		assert.are.same("Mastery", report[1].type)
		assert.are.same("Two Hand Mastery: Gain 20 Damage", report[1].name)
		assert.are.same(20, report[1].power)
		assert.are.same(2, report[1].pathDist)
		assert.are.same(10, report[2].power)
		assert.are.same("Two Hand Mastery: Gain 10 Damage", report[2].name)
	end)

	-- Pass: a column the user sorted by survives the report being rebuilt
	-- Fail: every recalculation throws the chosen order away, which makes the
	-- report unusable while editing the build it describes
	it("keeps the power report on the column the user sorted by", function()
		local reportList = build.treeTab.controls.powerReportList
		local stat = { stat = "Damage", label = "Damage" }
		-- The report is generated in power order
		local function generatedReport()
			return {
				{ type = "Node", name = "High", power = 30, powerStr = "30", pathDist = 3, pathPower = 10, pathPowerStr = "10" },
				{ type = "Node", name = "Mid", power = 20, powerStr = "20", pathDist = 1, pathPower = 20, pathPowerStr = "20" },
				{ type = "Node", name = "Low", power = 10, powerStr = "10", pathDist = 2, pathPower = 5, pathPowerStr = "5" },
			}
		end
		local function names()
			local names = { }
			for _, entry in ipairs(reportList.list) do
				table.insert(names, entry.name)
			end
			return names
		end

		reportList:SetReport(stat, generatedReport())
		assert.are.same({ "High", "Mid", "Low" }, names())

		-- Clicking the "Points" header is what the list control calls
		reportList:ReSort(4)
		assert.are.same({ "Mid", "Low", "High" }, names())

		-- A build edit regenerates the report from scratch
		reportList:SetReport(stat, generatedReport())
		assert.are.same({ "Mid", "Low", "High" }, names())

		-- As does re-listing it, which the filter controls do
		reportList:ReList()
		assert.are.same({ "Mid", "Low", "High" }, names())
	end)

	-- Pass: the Summary tab's comparison report keeps its column too
	-- Fail: it re-sorts by impact whenever either build changes
	it("keeps the compare power report on the column the user sorted by", function()
		local reportList = build.compareTab.controls.comparePowerReportList
		local stat = { stat = "Damage", label = "Damage" }
		local function generatedReport()
			return {
				{ category = "Tree", name = "High", impact = 30, impactStr = "30", pathDist = 3, perPoint = 10 },
				{ category = "Tree", name = "Mid", impact = 20, impactStr = "20", pathDist = 1, perPoint = 20 },
				{ category = "Tree", name = "Low", impact = 10, impactStr = "10", pathDist = 2, perPoint = 5 },
			}
		end
		local function names()
			local names = { }
			for _, entry in ipairs(reportList.list) do
				table.insert(names, entry.name)
			end
			return names
		end

		reportList:SetReport(stat, generatedReport())
		assert.are.same({ "High", "Mid", "Low" }, names())

		reportList:ReSort(4) -- "Points"
		assert.are.same({ "Mid", "Low", "High" }, names())

		reportList:SetReport(stat, generatedReport())
		assert.are.same({ "Mid", "Low", "High" }, names())
	end)
end)
