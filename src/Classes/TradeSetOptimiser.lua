-- Path of Building
--
-- Class: Trade Set Optimiser
-- Picks one item per slot out of the results the Trader has already fetched, to
-- maximise a chosen stat while keeping resistances capped, attribute
-- requirements met and the total inside a budget.
--
-- "Find best" answers one slot at a time, which is not the same question: the
-- best helmet on its own routinely breaks the resistance cap or drops the
-- Strength needed for a weapon, and paying it back costs more elsewhere than the
-- helmet gained. This searches combinations instead.
--
-- Three things about the problem shape the approach.
--
-- Feasibility is not a property of the items. A piece carrying "reduced
-- Attribute Requirements" lowers a requirement rather than raising an attribute,
-- so whether a set meets the Strength requirement of a staff is only answerable
-- once the whole set is measured. Constraints are therefore expressed against
-- calculator output, may reference other output values (Str >= ReqStr + margin),
-- and are only ever checked on measured results.
--
-- Stat totals do not add up. Increased-percent modifiers on one item scale flat
-- values from another, so a set's real Energy Shield is not the sum of its
-- parts. The linear sum is used only to rank what is worth measuring.
--
-- The space is far too large to walk. Eight slots with twenty candidates each is
-- 2.5e10 combinations, and each measurement costs a calculator pass. So: prune
-- each slot to its Pareto front, branch and bound over the linear model to get a
-- best-first shortlist, then measure the shortlist for real.
--
local t_insert = table.insert
local t_sort = table.sort
local m_max = math.max
local m_min = math.min
local m_huge = math.huge

local RESIST_STATS = { "FireResistTotal", "ColdResistTotal", "LightningResistTotal" }

---@class TradeSetOptimiser
local TradeSetOptimiserClass = newClass("TradeSetOptimiser")

function TradeSetOptimiserClass:TradeSetOptimiser(itemsTab)
	self.itemsTab = itemsTab
	self.build = itemsTab.build
	-- How often the solve coroutine comes up for air. Small enough that the
	-- window keeps drawing, large enough that yielding is not the bottleneck.
	self.measureChunk = 200
	self.boundChunk = 20000
	return self
end

----------------
-- Constraints --
----------------

--- Build the default constraint set: resistances at the cap and every attribute
--- requirement met with a little room.
---@param resistCap number
---@param attrMargin number
---@param chaosFloor number? @ optional minimum chaos resistance; nil or 0 to ignore
function TradeSetOptimiserClass:DefaultConstraints(resistCap, attrMargin, chaosFloor)
	resistCap = resistCap or 75
	attrMargin = attrMargin or 10
	local constraints = {
		{ stat = "FireResistTotal", min = resistCap },
		{ stat = "ColdResistTotal", min = resistCap },
		{ stat = "LightningResistTotal", min = resistCap },
		{ stat = "Str", atLeast = "ReqStr", margin = attrMargin },
		{ stat = "Dex", atLeast = "ReqDex", margin = attrMargin },
		{ stat = "Int", atLeast = "ReqInt", margin = attrMargin },
	}
	-- Chaos resistance is not capped the way the elements are and is expensive, so
	-- it is a floor only when asked for. Note that if the aim is survivability
	-- rather than raw Energy Shield, maximising Effective Hit Pool values chaos
	-- resistance on its own, without needing a floor at all.
	if chaosFloor and chaosFloor ~= 0 then
		t_insert(constraints, { stat = "ChaosResistTotal", min = chaosFloor })
	end
	return constraints
end

local function constraintFloor(constraint, stats)
	if constraint.atLeast then
		return (stats[constraint.atLeast] or 0) + (constraint.margin or 0)
	end
	return constraint.min + (constraint.margin or 0)
end

local function constraintMet(constraint, stats)
	return (stats[constraint.stat] or 0) >= constraintFloor(constraint, stats)
end

--------------------
-- Candidate prep --
--------------------

--- Score an outcome against the stat weights the Trader is configured with.
---
--- Same weighting as TradeQueryGenerator.WeightedRatioOutputs, which is what the
--- Trader sorts its own results by, and deliberately the same stat weights: what
--- a build is trying to maximise is already a solved, user-editable question in
--- Path of Building, with a weight editor and saved presets behind it.
---
--- One difference, and it matters. That function clamps each ratio to
--- data.misc.maxStatIncrease, which is 2. That is right where it is used --
--- weighing one modifier at a time, where nothing doubles a stat -- but wrong
--- for ranking whole sets, where doubling is routine. Clamped, a set worth 2.5x
--- and one worth 6x score identically and the solver picks between them on
--- price. So the ratio is left uncapped here.
function TradeSetOptimiserClass:Score(output)
	local total = 0
	for _, weight in ipairs(self.statWeights) do
		local base = data.powerStatList.GetFromOutput(self.baseOutput, weight, true)
		local new = data.powerStatList.GetFromOutput(output, weight, true)
		local ratio
		if base == m_huge then
			ratio = 0
		elseif new == m_huge then
			ratio = m_huge
		else
			ratio = new / ((base ~= 0) and base or 1)
		end
		if weight.transform then
			ratio = weight.transform(ratio)
		end
		total = total + ratio * (weight.weightMult or 1)
	end
	return total
end

--- Measure what each candidate does on its own.
--- The result is only used for ranking and bounding, never for a verdict.
---@param pools table @ slotName -> array of { item = Item, price = number, ... }
---@param statNames string[]
function TradeSetOptimiserClass:MeasureCandidates(pools, statNames)
	local calcFunc, baseOutput = self.build.calcsTab:GetMiscCalculator()
	self.baseOutput = baseOutput
	for slotName, pool in pairs(pools) do
		for _, cand in ipairs(pool) do
			local output = calcFunc({ repItems = { [slotName] = cand.item } }, true)
			cand.deltas = { }
			for _, stat in ipairs(statNames) do
				cand.deltas[stat] = (output[stat] or 0) - (baseOutput[stat] or 0)
			end
			-- The scalar the shortlist ranks and bounds on
			cand.deltas.__score = self:Score(output)
		end
	end
	return baseOutput
end

--- Drop candidates that another candidate beats on every axis at no higher price.
--- Lossless: a strictly worse, strictly pricier item can never be in an optimal set.
local function paretoFront(pool, dims)
	local front = { }
	for _, a in ipairs(pool) do
		local dominated = false
		for _, b in ipairs(pool) do
			if b ~= a and b.price <= a.price then
				local worse = false
				local better = b.price < a.price
				for _, dim in ipairs(dims) do
					local bd, ad = b.deltas[dim] or 0, a.deltas[dim] or 0
					if bd < ad then
						worse = true
						break
					elseif bd > ad then
						better = true
					end
				end
				if not worse and better then
					dominated = true
					break
				end
			end
		end
		if not dominated then
			t_insert(front, a)
		end
	end
	return front
end

--- Reduce every slot to a shortlist, with the option of changing nothing there.
function TradeSetOptimiserClass:PrepareOptions(pools, constraints, perSlot)
	local dims = { "__score" }
	local seen = { __score = true }
	for _, constraint in ipairs(constraints) do
		if not seen[constraint.stat] then
			seen[constraint.stat] = true
			t_insert(dims, constraint.stat)
		end
	end
	local options = { }
	for slotName, pool in pairs(pools) do
		local front = paretoFront(pool, dims)
		t_sort(front, function(a, b)
			return (a.deltas.__score or 0) > (b.deltas.__score or 0)
		end)
		local shortlist = { { slotName = slotName, keep = true, price = 0, deltas = { } } }
		for i = 1, m_min(#front, perSlot) do
			t_insert(shortlist, front[i])
		end
		options[slotName] = shortlist
	end
	return options
end

----------------------
-- Branch and bound --
----------------------

--- Best-first shortlist of combinations under the linear model.
--- Every bound here is admissible: it can only discard sets that could not have
--- won, so the shortlist is the true linear top-N.
function TradeSetOptimiserClass:Shortlist(options, slotOrder, budget, constraints, limit, onProgress)
	local perSlot = { }
	for i, slotName in ipairs(slotOrder) do
		perSlot[i] = options[slotName]
	end
	local n = #perSlot

	-- Suffix bests, so a partial assignment can be bounded without looking ahead
	local bestObj, minCost = { }, { }
	local bestStat = { }
	for _, constraint in ipairs(constraints) do
		bestStat[constraint.stat] = { }
		bestStat[constraint.stat][n + 1] = 0
	end
	bestObj[n + 1], minCost[n + 1] = 0, 0
	for i = n, 1, -1 do
		local pool = perSlot[i]
		local bo, mc = -m_huge, m_huge
		for _, cand in ipairs(pool) do
			bo = m_max(bo, cand.deltas.__score or 0)
			mc = m_min(mc, cand.price)
		end
		bestObj[i] = bestObj[i + 1] + bo
		minCost[i] = minCost[i + 1] + mc
		for _, constraint in ipairs(constraints) do
			local bs = -m_huge
			for _, cand in ipairs(pool) do
				bs = m_max(bs, cand.deltas[constraint.stat] or 0)
			end
			bestStat[constraint.stat][i] = bestStat[constraint.stat][i + 1] + bs
		end
	end

	-- Screening floors, relative to where the build already is. A relative
	-- constraint moves with the set, so its base value is only an approximation
	-- here; the real check happens on measured output.
	local floors = { }
	for _, constraint in ipairs(constraints) do
		floors[constraint.stat] = constraintFloor(constraint, self.baseOutput)
			- (self.baseOutput[constraint.stat] or 0)
	end

	local results, worstKept = { }, -m_huge
	local chosen, totals = { }, { }
	for _, constraint in ipairs(constraints) do
		totals[constraint.stat] = 0
	end
	local visited = 0

	local function recurse(i, cost, obj)
		if cost + minCost[i] > budget then return end
		if #results >= limit and obj + bestObj[i] <= worstKept then return end
		for _, constraint in ipairs(constraints) do
			if totals[constraint.stat] + bestStat[constraint.stat][i] < floors[constraint.stat] then
				return
			end
		end
		if i > n then
			local combo = { }
			for k = 1, n do combo[k] = chosen[k] end
			t_insert(results, { obj = obj, combo = combo })
			t_sort(results, function(a, b) return a.obj > b.obj end)
			for k = #results, limit + 1, -1 do results[k] = nil end
			worstKept = results[#results].obj
			return
		end
		for _, cand in ipairs(perSlot[i]) do
			local newCost = cost + cand.price
			if newCost <= budget then
				chosen[i] = cand
				for _, constraint in ipairs(constraints) do
					totals[constraint.stat] = totals[constraint.stat] + (cand.deltas[constraint.stat] or 0)
				end
				recurse(i + 1, newCost, obj + (cand.deltas.__score or 0))
				for _, constraint in ipairs(constraints) do
					totals[constraint.stat] = totals[constraint.stat] - (cand.deltas[constraint.stat] or 0)
				end
				chosen[i] = nil
				visited = visited + 1
				if visited % self.boundChunk == 0 then
					if onProgress then onProgress("Searching combinations", visited) end
					coroutine.yield()
				end
			end
		end
	end
	recurse(1, 0, 0)

	local combos = { }
	for _, entry in ipairs(results) do
		t_insert(combos, entry.combo)
	end
	return combos
end

-------------------------
-- Resistance crafting --
-------------------------

--- How many Harvest element-swap crafts a set needs, and whether they can work.
--- A swap moves one elemental resistance onto another element; it cannot create
--- resistance, so the surplus has to cover the shortfall.
---
--- Deliberately approximate: it counts resistance points rather than whole
--- modifiers, so a plan that would need an exact split across two mods may not be
--- achievable in the bench. A nonzero count means "needs bench work", not "free".
local function resistSwapPlan(stats, target, maxSwaps)
	local deficit, surplus, swaps = 0, 0, 0
	for _, stat in ipairs(RESIST_STATS) do
		local value = stats[stat] or 0
		if value < target then
			deficit = deficit + (target - value)
			swaps = swaps + 1
		else
			surplus = surplus + (value - target)
		end
	end
	return swaps, (deficit <= surplus and swaps <= maxSwaps)
end

--------------
-- Solving  --
--------------

--- How far past the cap the worst resistance sits.
--- Resistance above the cap does nothing, so a set that overshoots has spent
--- budget on a stat with no effect -- budget that could have bought the objective.
local function worstOvercap(stats, target)
	local worst = 0
	for _, stat in ipairs(RESIST_STATS) do
		worst = m_max(worst, (stats[stat] or 0) - target)
	end
	return worst
end

--- Measure a shortlist and keep the best set that satisfies every constraint.
function TradeSetOptimiserClass:Measure(combos, constraints, budget, options, onProgress)
	local calcFunc = self.build.calcsTab:GetMiscCalculator()
	local best, rejected, measured = nil, { }, 0
	local resistTarget = options.resistTarget
	local swapCost, maxSwaps = options.resistSwapCost or 0, options.maxResistSwaps or 0
	-- Cap resistance from above as well as below. Without this the constraint is a
	-- floor with nothing above it, so overshooting is free and the solver happily
	-- buys 250% fire resistance because those items also happened to be good.
	local capTarget, allowance = options.overcapTarget, options.maxOvercap
	-- Resistance comes in whole rolls, so a set landing within a tight allowance
	-- may not exist. Falling back to "best objective among everything that
	-- overshoots" is no fallback at all: overshooting is unpenalised there, so it
	-- picks the most resistance-stacked set in the shortlist. Instead, keep the
	-- best set in each overshoot tier and answer from the tightest tier that has
	-- one, so relaxing gives up as little as it has to.
	local tiers = nil
	if capTarget and allowance then
		tiers = { }
		local step = m_max(allowance, 5)
		for i = 1, 5 do
			t_insert(tiers, { limit = allowance + step * (i - 1), best = nil })
		end
		t_insert(tiers, { limit = m_huge, best = nil })
	end

	for index, combo in ipairs(combos) do
		local repItems, cost = { }, 0
		for _, cand in ipairs(combo) do
			if not cand.keep then
				repItems[cand.slotName] = cand.item
				cost = cost + cand.price
			end
		end
		local stats = calcFunc({ repItems = repItems }, true)
		measured = measured + 1

		local swaps, ok = 0, true
		if resistTarget and maxSwaps > 0 then
			swaps, ok = resistSwapPlan(stats, resistTarget, maxSwaps)
			if not ok then
				rejected.resistances = (rejected.resistances or 0) + 1
			end
		end
		if ok then
			local failed
			for _, constraint in ipairs(constraints) do
				local skip = false
				if resistTarget and maxSwaps > 0 then
					for _, stat in ipairs(RESIST_STATS) do
						if constraint.stat == stat then skip = true break end
					end
				end
				if not skip and not constraintMet(constraint, stats) then
					failed = constraint.stat
					break
				end
			end
			if failed then
				rejected[failed] = (rejected[failed] or 0) + 1
			else
				local total = cost + swaps * swapCost
				if total > budget then
					rejected.budget = (rejected.budget or 0) + 1
				else
					local score = self:Score(stats)
					local over = capTarget and worstOvercap(stats, capTarget) or 0
					local entry = { score = score, cost = total, swaps = swaps, combo = combo,
						stats = stats, overcap = over }
					local function better(current)
						return not current or score > current.score
							or (score == current.score and total < current.cost)
					end
					if not tiers then
						if better(best) then best = entry end
					elseif over <= allowance then
						if better(best) then best = entry end
					else
						rejected.overcap = (rejected.overcap or 0) + 1
						for _, tier in ipairs(tiers) do
							if over <= tier.limit and better(tier.best) then
								tier.best = entry
							end
						end
					end
				end
			end
		end
		if index % self.measureChunk == 0 then
			if onProgress then onProgress("Measuring sets", index, #combos) end
			coroutine.yield()
		end
	end
	if not best and tiers then
		for _, tier in ipairs(tiers) do
			if tier.best then
				tier.best.overcapRelaxed = true
				return tier.best, measured, rejected
			end
		end
	end
	return best, measured, rejected
end

--- The whole solve, as a coroutine body.
---@param pools table @ slotName -> array of { item = Item, price = number, listing = table }
---@param settings table
function TradeSetOptimiserClass:Solve(pools, settings, onProgress)
	-- Resolved against powerStatList rather than used as given: the saved weight
	-- list carries stat and multiplier, but the transform that makes
	-- lower-is-better stats weigh the right way round lives on the stat entry
	self.statWeights = { }
	for _, entry in ipairs(settings.statWeights or { }) do
		if entry.stat and (entry.weightMult or 0) ~= 0 then
			for _, stat in ipairs(data.powerStatList) do
				if stat.stat == entry.stat then
					local resolved = copyTable(stat)
					resolved.weightMult = entry.weightMult
					t_insert(self.statWeights, resolved)
					break
				end
			end
		end
	end
	if not self.statWeights[1] then
		return { ok = false, reason = "No search weights are set. Use \"Adjust search weights\" to say what this build is trying to maximise." }
	end
	local constraints = settings.constraints or self:DefaultConstraints(75, 10)
	local budget = settings.budget or m_huge
	local perSlot = settings.perSlot or 16
	local shortlistSize = settings.shortlist or 3000

	local statNames = { }
	local seen = { }
	local function want(stat)
		if stat and not seen[stat] then
			seen[stat] = true
			t_insert(statNames, stat)
		end
	end
	for _, weight in ipairs(self.statWeights) do want(weight.stat) end
	for _, constraint in ipairs(constraints) do
		want(constraint.stat)
		want(constraint.atLeast)
	end
	for _, stat in ipairs(RESIST_STATS) do want(stat) end

	if onProgress then onProgress("Measuring candidates") end
	self:MeasureCandidates(pools, statNames)
	coroutine.yield()

	local options = self:PrepareOptions(pools, constraints, perSlot)
	local slotOrder = { }
	for slotName in pairs(options) do t_insert(slotOrder, slotName) end
	t_sort(slotOrder, function(a, b) return #options[a] > #options[b] end)

	-- Hold back enough budget that a set needing the bench can still afford it
	local craftReserve = (settings.resistSwapCost or 0) * (settings.maxResistSwaps or 0)
	local combos = self:Shortlist(options, slotOrder, budget - craftReserve,
		constraints, shortlistSize, onProgress)
	if #combos == 0 then
		-- The shortlist is empty when the bounds proved no assignment could both
		-- fit the budget and reach every floor. Saying "nothing fits the budget"
		-- would send the user to the wrong dial.
		return { ok = false, shortlisted = 0, measured = 0,
			reason = "No combination can fit the budget and still meet the requirements. Raise the budget, lower the requirements, or fetch more items." }
	end

	settings.overcapTarget = settings.overcapTarget or settings.resistTarget
	local best, measured, rejected = self:Measure(combos, constraints, budget, settings, onProgress)
	if not best then
		return { ok = false, reason = "Every set that fits the budget failed a requirement.",
			measured = measured, rejected = rejected }
	end
	return {
		ok = true,
		-- The score is a weighted ratio against the current build, so 1.0 is "no
		-- better than what is equipped" and it has no unit of its own
		score = best.score,
		baseScore = self:Score(self.baseOutput),
		statWeights = self.statWeights,
		cost = best.cost,
		swaps = best.swaps,
		overcap = best.overcap,
		overcapRelaxed = best.overcapRelaxed,
		stats = best.stats,
		combo = best.combo,
		measured = measured,
		rejected = rejected,
		shortlisted = #combos,
	}
end

return TradeSetOptimiserClass
