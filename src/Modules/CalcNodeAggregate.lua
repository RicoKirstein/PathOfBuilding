-- Path of Building
--
-- Module: Calc Node Aggregate
-- Composes estimated calculation outputs for passive tree nodes from per-modifier
-- output deltas, so that most nodes do not need a full calculation pass. Each
-- distinct modifier is measured once against the full build environment (items
-- included) using the exact calculator; a node's output is then the base output
-- plus the sum of its modifiers' deltas. This is exact for a single modifier and
-- a first-order estimate for combinations, so only plain additive scalar
-- modifiers are composed; nodes carrying anything else must be evaluated exactly
-- by the caller and can be fed back in via LearnExact for path composition.
--
---@class Calcs
local calcs = require("Modules.CalcBase")

local pairs = pairs
local ipairs = ipairs
local type = type
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format

-- Tags whose evaluation can change discontinuously when other stats change
local thresholdTagTypes = {
	["StatThreshold"] = true,
	["MultiplierThreshold"] = true,
}

-- Only plain additive scalar modifiers compose safely: their contribution to the
-- aggregated stat buckets is linear, so single-modifier deltas add up
local function modIsComposable(mod)
	if (mod.type ~= "BASE" and mod.type ~= "INC") or type(mod.value) ~= "number" then
		return false
	end
	for i = 1, #mod do
		if thresholdTagTypes[mod[i].type] then
			return false
		end
	end
	return true
end

-- Stable textual form of a modifier's tag list, used to identify modifiers that
-- differ only in value
local function tagSignature(mod)
	local parts = { }
	for i = 1, #mod do
		local tag = mod[i]
		local keys = { }
		for k in pairs(tag) do
			t_insert(keys, k)
		end
		t_sort(keys)
		for _, k in ipairs(keys) do
			local v = tag[k]
			if type(v) == "table" then
				local list = { }
				for _, entry in ipairs(v) do
					t_insert(list, tostring(entry))
				end
				v = "{" .. table.concat(list, ",") .. "}"
			end
			t_insert(parts, k .. "=" .. tostring(v))
		end
		t_insert(parts, ";")
	end
	return table.concat(parts, "|")
end

local function addSparseDelta(delta, output, base)
	for k, v in pairs(output) do
		if type(v) == "number" then
			local b = base[k]
			b = type(b) == "number" and b or 0
			if v ~= b then
				delta[k] = v - b
			end
		end
	end
	for k, b in pairs(base) do
		if type(b) == "number" and b ~= 0 and type(output[k]) ~= "number" then
			delta[k] = -b
		end
	end
end

-- Difference between two calculation outputs, as sparse tables of changed
-- numeric stats (player and minion separately)
local function sparseDelta(output, base)
	local delta = { stats = { } }
	addSparseDelta(delta.stats, output, base)
	local minionOut, minionBase = output.Minion, base.Minion
	if minionOut or minionBase then
		local minionDelta = { }
		addSparseDelta(minionDelta, minionOut or { }, minionBase or { })
		if next(minionDelta) then
			delta.minion = minionDelta
		end
	end
	return delta
end

local aggregateClass = { }
local aggregateMeta = { __index = aggregateClass }

-- calcFunc/baseOutput as returned by CalcsTab:GetMiscCalculator(); deltas are only
-- valid for the build state those were created from
function calcs.newNodeAggregate(build, calcFunc, baseOutput, useFullDPS)
	return setmetatable({
		calcFunc = calcFunc,
		base = baseOutput,
		useFullDPS = useFullDPS,
		radiusNodes = build.radiusJewelNodeSet or { },
		sigs = { },
		exact = { },
		modSigCache = setmetatable({ }, { __mode = "k" }),
		derivations = 0,
		composedCount = 0,
		baseMeta = { __index = baseOutput },
		minionMeta = baseOutput.Minion and { __index = baseOutput.Minion } or nil,
	}, aggregateMeta)
end

-- Nodes whose effect cannot be modelled as a sum of independent modifier deltas:
-- keystones (merged from outside the node's own list), ascendancy nodes,
-- radius-jewel-affected nodes, nodes with any non-composable modifier, and nodes
-- with several modifiers of the same stat (their joint effect through non-linear
-- curves like accuracy or the hit-chance cap is not the sum of the solo effects)
local seenNames = { }
function aggregateClass:IsNodeComposable(node)
	if node.type == "Keystone" or node.ascendancyName or self.radiusNodes[node.id] then
		return false
	end
	for k in pairs(seenNames) do
		seenNames[k] = nil
	end
	for _, mod in ipairs(node.modList) do
		if not modIsComposable(mod) or seenNames[mod.name] then
			return false
		end
		seenNames[mod.name] = true
	end
	return true
end

-- Measure the output delta of a single synthetic node through the exact calculator
function aggregateClass:deriveDelta(sig, nodeType, nodeName, modList)
	local synthNode = {
		id = "nodeAggregate:" .. sig,
		type = nodeType,
		name = nodeName,
		modKey = sig,
		modList = modList,
		grantedSkills = { },
	}
	local output = self.calcFunc({ addNodes = { [synthNode] = true } }, self.useFullDPS)
	self.derivations = self.derivations + 1
	return sparseDelta(output, self.base)
end

function aggregateClass:GetModEntry(mod)
	-- One entry per distinct (modifier, value): measured deltas must not be scaled
	-- to other values, as the output can respond in staircases (tick and breakpoint
	-- mechanics) where extrapolation fabricates or inverts effects. This makes
	-- composed single-modifier nodes exact by construction.
	local sig = self.modSigCache[mod]
	if not sig then
		sig = s_format("%s|%s|%s|%s|%s|%s", mod.name, mod.type, tostring(mod.value), tostring(mod.flags), tostring(mod.keywordFlags), tagSignature(mod))
		self.modSigCache[mod] = sig
	end
	local entry = self.sigs[sig]
	if entry then
		return entry, 1
	end
	local modList = newModList()
	modList:AddMod(mod)
	entry = { refValue = mod.value, delta = self:deriveDelta(sig, "Normal", "Node aggregate probe", modList) }
	self.sigs[sig] = entry
	return entry, 1
end

-- Delta of just the node-type allocation counters (e.g. Multiplier:AllocatedNotable,
-- mastery type counts), which the synthetic "Normal" probes above do not carry
function aggregateClass:GetTypeEntry(nodeType, nodeName)
	local sig = "@type:" .. nodeType .. (nodeType == "Mastery" and ("/" .. (nodeName or "")) or "")
	local entry = self.sigs[sig]
	if not entry then
		entry = { refValue = 1, delta = self:deriveDelta(sig, nodeType, nodeName or "Node aggregate probe", newModList()) }
		self.sigs[sig] = entry
	end
	return entry
end

-- Remember the measured delta of an exactly-calculated node, so paths crossing it
-- can still be composed
-- partial: output only carries a subset of stats (e.g. from a pool worker), so
-- only record deltas for the stats it actually has
function aggregateClass:LearnExact(node, output, partial)
	if node.modKey and node.modKey ~= "" and not self.exact[node.modKey] then
		if partial then
			local delta = { stats = { } }
			for k, v in pairs(output) do
				if type(v) == "number" then
					local b = self.base[k]
					b = type(b) == "number" and b or 0
					if v ~= b then
						delta.stats[k] = v - b
					end
				end
			end
			if output.Minion and type(output.Minion.CombinedDPS) == "number" then
				local b = self.base.Minion and self.base.Minion.CombinedDPS or 0
				if output.Minion.CombinedDPS ~= b then
					delta.minion = { CombinedDPS = output.Minion.CombinedDPS - b }
				end
			end
			self.exact[node.modKey] = delta
		else
			self.exact[node.modKey] = sparseDelta(output, self.base)
		end
	end
end

local function applyDelta(stats, minionStats, delta, scale)
	for k, d in pairs(delta.stats) do
		stats[k] = (stats[k] or 0) + d * scale
	end
	if delta.minion then
		for k, d in pairs(delta.minion) do
			minionStats[k] = (minionStats[k] or 0) + d * scale
		end
	end
end

-- Compose an output table for a set of nodes. Returns nil if any node is neither
-- composable nor already learned from an exact calculation.
function aggregateClass:ComposeNodes(nodeList)
	local stats, minionStats = { }, { }
	for _, node in ipairs(nodeList) do
		if node.modKey == "" then
			-- Nodes with no modifiers (e.g. jewel sockets in a path) contribute nothing
		elseif self.exact[node.modKey] then
			applyDelta(stats, minionStats, self.exact[node.modKey], 1)
		elseif self:IsNodeComposable(node) then
			for _, mod in ipairs(node.modList) do
				local entry, scale = self:GetModEntry(mod)
				applyDelta(stats, minionStats, entry.delta, scale)
			end
			if node.type ~= "Normal" then
				applyDelta(stats, minionStats, self:GetTypeEntry(node.type, node.name).delta, 1)
			end
		else
			return nil
		end
	end
	local base = self.base
	for k, d in pairs(stats) do
		local b = base[k]
		stats[k] = (type(b) == "number" and b or 0) + d
	end
	local out = setmetatable(stats, self.baseMeta)
	if next(minionStats) then
		local minionBase = base.Minion or { }
		for k, d in pairs(minionStats) do
			local b = minionBase[k]
			minionStats[k] = (type(b) == "number" and b or 0) + d
		end
		out.Minion = self.minionMeta and setmetatable(minionStats, self.minionMeta) or minionStats
	end
	self.composedCount = self.composedCount + 1
	return out
end

local composeScratch = { }
function aggregateClass:ComposeNode(node)
	composeScratch[1] = node
	return self:ComposeNodes(composeScratch)
end
