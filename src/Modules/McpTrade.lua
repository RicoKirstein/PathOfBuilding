-- Path of Building
--
-- Module: MCP Trade
-- The trade half of the MCP command surface (see Modules/McpCommands.lua for the
-- rest). It drives the same three classes the Trader popup does —
-- TradeQueryGenerator to turn "make this build better at X" into a weighted
-- query, TradeQueryRequests to talk to the trade API, and TradeQueryRateLimiter
-- to stay inside GGG's limits — so searches issued over the bridge are subject to
-- exactly the same backoff, retry and authorization handling as searches a user
-- clicks for.
--
-- Trade work cannot answer within one bridge request: mod weighting runs as a
-- coroutine across frames and the HTTP requests are queued behind a rate limiter.
-- So the commands here are a job API. `trade.*` starts a job and returns its id
-- immediately; `trade.job` reports progress and, once finished, the results. The
-- client half polls. Everything is pumped from Pump(), which McpServer calls each
-- frame, which is why these commands live outside McpCommands: that module is
-- deliberately free of threading and is driven synchronously by the spec suite.
--
local dkjson = require("dkjson")

local t_insert = table.insert
local s_format = string.format

local tradeHelpers = LoadModule("Classes/TradeHelpers")

-- LoadModule re-executes a file on every call rather than caching it, so this
-- module cannot reach for McpCommands itself: it would get a private copy and
-- register its handlers onto a table nobody reads. McpServer owns the one command
-- table that requests are dispatched against, and hands it to Register below.
local commands = { }
local getBuild

local trade = { }

---Adds the trade commands to a live McpCommands module.
---@param mcpCommands table @ the module McpServer dispatches against
function trade.Register(mcpCommands)
	getBuild = mcpCommands.getBuild
	for name, handler in pairs(commands) do
		mcpCommands.commands[name] = handler
	end
	return trade
end

trade.jobs = { }
trade.nextJobId = 1
-- Jobs are kept after they finish so a poll can still collect the results; drop
-- the oldest once there are enough of them that a long session would leak
local MAX_RETAINED_JOBS = 40

--------------------
-- Shared helpers --
--------------------

local function req(params, name)
	local value = params and params[name]
	if value == nil then
		error("missing required parameter '" .. name .. "'", 0)
	end
	return value
end

-- The rate limiter's state is what makes repeated searches safe, so the request
-- layer is created once and reused for the lifetime of the process
function trade:Requests()
	if not self.requests then
		-- ProcessQueue reads main.api.authToken on every request; the Trader popup
		-- creates it lazily and we may well run before it has ever been opened
		if not main.api then
			main.api = new("PoEAPI"):PoEAPI(main.lastToken, main.lastRefreshToken, main.tokenExpiry)
		end
		self.requests = new("TradeQueryRequests"):TradeQueryRequests()
	end
	return self.requests
end

-- TradeQueryGenerator only ever reaches through its "query tab" for itemsTab, so
-- a stub is enough and keeps this independent of whether the Trader popup is open
function trade:Generator(build)
	if not self.generator or self.generatorBuild ~= build then
		self.generator = new("TradeQueryGenerator"):TradeQueryGenerator({ itemsTab = build.itemsTab })
		self.generatorBuild = build
	end
	return self.generator
end

function trade:NewJob(kind)
	local id = self.nextJobId
	self.nextJobId = id + 1
	local job = {
		id = id,
		kind = kind,
		status = "running",
		phase = "starting",
		started = os.time(),
	}
	self.jobs[id] = job
	-- Trim the oldest finished jobs
	local ids = { }
	for jobId in pairs(self.jobs) do
		t_insert(ids, jobId)
	end
	if #ids > MAX_RETAINED_JOBS then
		table.sort(ids)
		for i = 1, #ids - MAX_RETAINED_JOBS do
			local old = self.jobs[ids[i]]
			if old and old.status ~= "running" then
				self.jobs[ids[i]] = nil
			end
		end
	end
	return job
end

function trade:GetJob(params)
	local id = tonumber(req(params, "jobId"))
	local job = self.jobs[id]
	if not job then
		error("no trade job with id " .. tostring(id) .. "; it may have been discarded", 0)
	end
	return job
end

local function finishJob(job, errMsg, items)
	if errMsg then
		job.status = "error"
		job.phase = "failed"
		job.error = errMsg
	else
		job.status = "done"
		job.phase = "complete"
		job.items = items
	end
	job.finished = os.time()
end

------------------------
-- Frame pump         --
------------------------

-- Called every frame by McpServer. Both halves of a trade job need it: the
-- generator's weighting coroutine, and the request queue that spaces HTTP calls
-- out according to the rate limiter.
function trade.Pump()
	if trade.generator and trade.generator.calcContext and trade.generator.calcContext.co then
		trade.generator:OnFrame()
	end
	if trade.requests then
		local hasWork = false
		for _, queue in pairs(trade.requests.requestQueue) do
			if #queue > 0 then
				hasWork = true
				break
			end
		end
		if hasWork then
			trade.requests:ProcessQueue(function(seconds)
				trade.rateLimitedFor = seconds
				trade.rateLimitedAt = os.time()
			end)
		end
	end
end

-----------------------------
-- Query generation inputs --
-----------------------------

local statByName = { }
for _, entry in ipairs(data.powerStatList) do
	if entry.stat then
		statByName[entry.stat] = entry
	end
end

-- Accepts [{stat="EnergyShield", weightMult=1}, ...]. The generator needs the
-- full powerStatList entry (its label, and the transform that makes
-- lower-is-better stats sort the right way), so look each one up rather than
-- taking the caller's word for the shape.
local function buildStatWeights(raw)
	if type(raw) ~= "table" or not raw[1] then
		error("'statWeights' must be a non-empty list of { stat = ..., weightMult = ... }", 0)
	end
	local weights = { }
	for _, entry in ipairs(raw) do
		local name = type(entry) == "table" and entry.stat or entry
		local template = statByName[tostring(name)]
		if not template then
			error("unknown stat '" .. tostring(name) .. "'; call trade.stats for the list", 0)
		end
		local weight = copyTable(template)
		weight.weightMult = tonumber(type(entry) == "table" and entry.weightMult) or 1
		t_insert(weights, weight)
	end
	return weights
end

-- Resolves the slot to search for: a named equipment slot, or a jewel socket
-- given by passive node id
local function resolveSlot(build, params)
	local itemsTab = build.itemsTab
	if params.nodeId then
		local nodeId = tonumber(params.nodeId)
		local socket = itemsTab.sockets[nodeId]
		if not socket then
			error("no jewel socket at passive node " .. tostring(nodeId), 0)
		end
		return socket
	end
	local slotName = tostring(req(params, "slot"))
	local slot = itemsTab.slots[slotName]
	if not slot then
		error("unknown slot '" .. slotName .. "'; call items.list for the slot names", 0)
	end
	return slot
end

local function boolOpt(params, name, default)
	local value = params[name]
	if value == nil then
		return default
	end
	return value and true or false
end

-- FinishQuery reads the listing status off the generator, not out of options,
-- because the Trader popup keeps it in a dropdown. Index into the same list it
-- does; without this the query goes out with no status and the API rejects it.
local TRADE_STATUS = { "securable", "available", "onlineleague", "online", "any" }

local function statusIndex(name)
	if not name then
		-- What the trade site itself defaults to
		return 4
	end
	for index, option in ipairs(TRADE_STATUS) do
		if option == name then
			return index
		end
	end
	error("unknown listing status '" .. tostring(name) .. "'; expected one of " .. table.concat(TRADE_STATUS, ", "), 0)
end

local function buildOptions(params)
	local options = {
		statWeights = buildStatWeights(req(params, "statWeights")),
		influence1 = tonumber(params.influence1) or 1,
		influence2 = tonumber(params.influence2) or 1,
		includeMirrored = boolOpt(params, "includeMirrored", false),
		includeCorrupted = boolOpt(params, "includeCorrupted", true),
		includeScourge = boolOpt(params, "includeScourge", false),
		includeTalisman = boolOpt(params, "includeTalisman", false),
		includeAllWEMods = boolOpt(params, "includeAllWEMods", false),
		includeEldritch = params.includeEldritch,
		jewelType = params.jewelType or "Base",
		maxPrice = tonumber(params.maxPrice),
		maxPriceType = params.maxPriceType,
		maxLevel = tonumber(params.maxLevel),
		sockets = tonumber(params.sockets),
		links = tonumber(params.links),
		-- Suppresses the "Calculating Mod Weights..." modal. A search the user did
		-- not click for has no business taking over the window they are working in
		noPopup = true,
	}
	if params.requiredMods then
		local required = { }
		for _, entry in ipairs(params.requiredMods) do
			t_insert(required, {
				tradeId = tostring(req(entry, "tradeId")),
				value = tonumber(entry.value),
			})
		end
		options.requiredMods = required
	end
	return options
end

------------------------
-- Result conversion  --
------------------------

-- A trade result is only useful here if PoB can parse it back into an item and
-- the item can actually go in the slot we searched for
local function safeItems(build, entries, slotName)
	local safe = { }
	for _, entry in ipairs(entries or { }) do
		local ok, item = pcall(function() return new("Item"):Item(entry.item_string) end)
		if ok and item and item.base then
			if (not slotName) or build.itemsTab:IsItemValidForSlot(item, slotName) then
				entry.parsed = item
				t_insert(safe, entry)
			end
		end
	end
	return safe
end

local function entrySummary(entry, index)
	return {
		rank = index,
		id = entry.id,
		name = entry.parsed and (entry.parsed.name or entry.parsed.baseName) or nil,
		baseName = entry.parsed and entry.parsed.baseName or nil,
		itemLevel = entry.parsed and entry.parsed.itemLevel or nil,
		corrupted = entry.parsed and entry.parsed.corrupted or nil,
		price = entry.amount and (tostring(entry.amount) .. " " .. tostring(entry.currency)) or "no price",
		amount = entry.amount,
		currency = entry.currency,
		priceType = entry.priceType,
		seller = entry.trader,
		whisper = entry.whisper,
		weight = tonumber(entry.weight) or nil,
		text = entry.item_string,
	}
end

-- Every search command finishes the same way: keep what PoB can parse, summarise
-- it, and close the job
local function collector(job, build, slotName)
	return function(items, errMsg)
		if errMsg then
			return finishJob(job, errMsg)
		end
		local safe = safeItems(build, items, slotName)
		job.dropped = #(items or { }) - #safe
		local summaries = { }
		for index, entry in ipairs(safe) do
			t_insert(summaries, entrySummary(entry, index))
		end
		job.raw = safe
		if job.linkTarget then
			job.exact = false
			for _, entry in ipairs(safe) do
				if entry.id == job.linkTarget then
					job.exact = true
					break
				end
			end
		end
		finishJob(job, nil, summaries)
	end
end

-----------------------------
-- Pinning a single listing --
-----------------------------

-- The trade site has no per-item permalink: an item is only ever addressable as
-- a result inside some search. So to link one listing, build the narrowest search
-- that still contains it — its base type, its seller, and its own mod rolls as
-- exact filters.

local statTextById
local function statText(id)
	if not statTextById then
		statTextById = { }
		for _, category in ipairs(tradeHelpers.getTradeStats()) do
			for _, entry in ipairs(category.entries) do
				statTextById[entry.id] = entry.text
			end
		end
	end
	return statTextById[id]
end

local function isKnownStat(id)
	return statText(id) ~= nil
end

-- "+75 to maximum Energy Shield" on a helmet is the armour-local stat, but the
-- global one shares its wording and hashes first, so a filter built from the
-- obvious id matches nothing. Defence and weapon stats have a "(Local)" twin;
-- on a piece of gear that rolls them locally, that twin is the right one.
local function isLocalContext(item)
	local base = item and item.base
	return (base and (base.armour or base.weapon)) and true or false
end

-- Resolve one of an item's mod lines to the trade stat id and rolled value the
-- search API wants. Returns nil for lines the trade site does not index as a
-- stat, which is normal and not an error.
local function modLineFilter(modLine, modType, preferLocal)
	local line = modLine.line
	if not line then
		return nil
	end
	if modLine.range then
		local ok, applied = pcall(itemLib.applyRange, line, modLine.range, modLine.valueScalar)
		if ok and applied then
			line = applied
		end
	end
	-- Option-style stats (a named passive, a conqueror) carry their value as an
	-- option id rather than a number, so they resolve through a different table
	local optionId, optionValue = tradeHelpers.findTradeIdOption(line, modType)
	if optionId and isKnownStat(optionId) then
		return { id = optionId, value = { option = optionValue } }
	end
	local hashes, value, shouldNegate = tradeHelpers.findTradeHash(line)
	if not hashes or not value then
		return nil
	end
	if shouldNegate then
		-- "32% reduced Attribute Requirements" is the increased stat at -32 on the
		-- trade site. Filtering for min 32 matches nothing, which is exactly how a
		-- pin silently comes back empty
		value = -value
	end
	local candidates = { }
	for index = 1, #hashes do
		local id = s_format("%s.stat_%s", modType, hashes[index])
		if isKnownStat(id) then
			t_insert(candidates, id)
		end
	end
	if not candidates[1] then
		return nil
	end
	local chosen = candidates[1]
	if preferLocal then
		for _, id in ipairs(candidates) do
			if statText(id):find("(Local)", 1, true) then
				chosen = id
				break
			end
		end
	end
	-- min only, not min-and-max: PoB's parse of a roll and the trade site's own
	-- number can differ in the last digit on scaled mods, and an over-tight
	-- filter would exclude the very item being pinned
	return { id = chosen, value = { min = value } }
end

commands["trade.item_link"] = function(params)
	local build = getBuild()
	local job = trade:GetJob(params)
	if job.status ~= "done" then
		error("job " .. job.id .. " is " .. job.status .. ", not done", 0)
	end
	local wanted = params.itemId and tostring(params.itemId) or nil
	local index = tonumber(params.index)
	local entry
	for position, candidate in ipairs(job.raw or { }) do
		if (wanted and candidate.id == wanted) or (not wanted and index and position == index) then
			entry = candidate
			break
		end
	end
	if not entry then
		error("that item is not in job " .. job.id .. "; pass itemId from the job's results, or index", 0)
	end
	local item = entry.parsed or new("Item"):Item(entry.item_string)
	local maxStats = tonumber(params.maxStats) or 4
	local preferLocal = isLocalContext(item)

	-- Explicit lines only. Implicits on a modern item are as likely to be
	-- eldritch, veiled or fractured, each of which the trade site indexes under a
	-- different id prefix than the one PoB's mod line resolves to — a filter that
	-- silently matches nothing is worse than no filter at all
	local statFilters = { }
	for _, modLine in ipairs(item.explicitModLines or { }) do
		if #statFilters >= maxStats then
			break
		end
		local filter = modLineFilter(modLine, "explicit", preferLocal)
		if filter then
			t_insert(statFilters, filter)
		end
	end

	local useAccount = params.includeAccount ~= false and entry.trader
	local league = tostring(params.league or job.league or req(params, "league"))
	local realm = params.realm or "pc"

	-- A rare's generated name is the best handle there is: `term` is the trade
	-- site's free-text field and matches it directly. (`name` is a different
	-- field — it is validated against the known-item table and answers "Unknown
	-- item name" for anything but a unique or a base.) Reconstructing an item
	-- from its mods is the fallback, and an unreliable one: fractured and crafted
	-- mods move between id namespaces and rolls get rounded.
	local term = item.title or item.name
	if term then
		-- PoB stores a rare's display name as "Fate Shelter, Lich's Circlet" in
		-- some paths; term wants just the name
		term = term:gsub(",%s*" .. item.baseName:gsub("(%W)", "%%%1") .. "$", "")
	end

	-- Whichever handle is available, start strict and relax a step at a time
	-- until the listing actually comes back. Each step is a real search, so the
	-- rate limiter paces them.
	local function buildQuery(step)
		local query = {
			query = {
				status = { option = params.status or "any" },
				filters = { },
				stats = { { type = "and", filters = { } } },
			},
			sort = { price = "asc" },
		}
		local misc = { }
		local trade_filters = { }
		if term then
			query.query.term = term
			-- The name alone is nearly unique; type and price only disambiguate
			-- the handful of listings that share a generated name
			if step <= 2 then
				query.query.type = item.baseName
			end
			if step <= 1 then
				if useAccount then
					trade_filters.account = { input = entry.trader }
				end
				if entry.amount and entry.currency then
					trade_filters.price = { min = entry.amount, max = entry.amount, option = entry.currency }
				end
			end
		else
			query.query.type = item.baseName
			if useAccount then
				trade_filters.account = { input = entry.trader }
			end
			if step <= 3 and entry.amount and entry.currency then
				trade_filters.price = { min = entry.amount, max = entry.amount, option = entry.currency }
			end
			if step <= 2 and item.itemLevel then
				misc.ilvl = { min = item.itemLevel, max = item.itemLevel }
			end
			if step <= 1 then
				for _, filter in ipairs(statFilters) do
					t_insert(query.query.stats[1].filters, filter)
				end
			end
		end
		if next(misc) then
			query.query.filters.misc_filters = { filters = misc }
		end
		if next(trade_filters) then
			query.query.filters.trade_filters = { filters = trade_filters }
		end
		return query
	end

	local STEP_NAMES = term
		and { "name+base+seller+price", "name+base", "name" }
		or { "stats+ilvl+price", "ilvl+price", "price", "base+seller" }
	local MAX_STEP = term and 3 or (useAccount and 4 or 3)

	local linkJob = trade:NewJob("item_link")
	linkJob.phase = "searching"
	linkJob.league = league
	linkJob.slot = job.slot
	linkJob.linkTarget = entry.id
	linkJob.pinned = {
		id = entry.id,
		baseName = item.baseName,
		name = item.name,
		seller = entry.trader,
		price = entry.amount and (tostring(entry.amount) .. " " .. tostring(entry.currency)) or nil,
		whisper = entry.whisper,
		availableStatFilters = #statFilters,
	}

	local requests = trade:Requests()
	requests.maxFetchPerSearch = 10 * (tonumber(params.fetchPages) or 1)

	local attempt
	attempt = function(step)
		local query = buildQuery(step)
		linkJob.phase = "searching (" .. STEP_NAMES[step] .. ")"
		linkJob.narrowedBy = STEP_NAMES[step]
		linkJob.query = dkjson.encode(query)
		local stepUrl
		local collect = collector(linkJob, build, nil)
		requests:SearchWithQuery(realm, league, linkJob.query, function(items, errMsg)
			local safe = { }
			if not errMsg then
				for _, candidate in ipairs(items or { }) do
					if candidate.id == entry.id then
						safe = items
						break
					end
				end
			end
			if #safe == 0 and step < MAX_STEP then
				-- Either the search found nothing or it found the wrong things;
				-- widen and try again
				linkJob.searchUrl = stepUrl
				return attempt(step + 1)
			end
			linkJob.searchUrl = stepUrl or linkJob.searchUrl
			collect(items, errMsg)
		end, {
			callbackQueryId = function(queryId)
				stepUrl = requests:buildUrl("https://www.pathofexile.com/trade/search", realm, league, queryId)
				linkJob.searchUrl = stepUrl
			end,
		})
	end
	attempt(1)

	return { jobId = linkJob.id, status = linkJob.status, pinned = linkJob.pinned }
end

------------------------
-- Commands           --
------------------------

commands["trade.leagues"] = function(params)
	local realm = params.realm or "pc"
	local job = trade:NewJob("leagues")
	job.phase = "fetching league list"
	trade:Requests():FetchLeagues(realm, function(leagues, errMsg)
		if errMsg then
			return finishJob(job, errMsg)
		end
		job.status = "done"
		job.phase = "complete"
		job.leagues = leagues
		job.finished = os.time()
	end)
	return { jobId = job.id, status = job.status }
end

-- The headline command: "find me the best item for this slot", where "best" is
-- whatever combination of build stats the caller weights.
commands["trade.search_slot"] = function(params)
	local build = getBuild()
	local slot = resolveSlot(build, params)
	local league = tostring(req(params, "league"))
	local realm = params.realm or "pc"
	local options = buildOptions(params)

	local requests = trade:Requests()
	requests.maxFetchPerSearch = 10 * (tonumber(params.fetchPages) or 1)

	local job = trade:NewJob("search_slot")
	job.slot = slot.slotName
	job.league = league
	job.phase = "weighting mods"

	local generator = trade:Generator(build)
	generator.tradeTypeIndex = statusIndex(params.status)
	generator.requesterCallback = function(context, query, errMsg)
		if errMsg then
			return finishJob(job, errMsg)
		end
		job.query = query
		job.phase = "searching"
		requests:SearchWithQueryWeightAdjusted(realm, league, query, collector(job, build, slot.slotName), {
			callbackQueryId = function(queryId)
				job.searchUrl = requests:buildUrl("https://www.pathofexile.com/trade/search", realm, league, queryId)
			end,
		})
	end
	generator.requesterContext = { }
	generator:StartQuery(slot, options)
	if not generator.calcContext.co then
		error("could not start a weighted query for slot '" .. tostring(slot.slotName) .. "'; that item type may not be supported", 0)
	end
	return { jobId = job.id, status = job.status, slot = slot.slotName }
end

-- Run a search the caller already has: a trade site URL, or a raw query object.
-- Both go through the same rate limiter as a generated search.
commands["trade.search_url"] = function(params)
	local build = getBuild()
	local url = tostring(req(params, "url"))
	local slotName = params.slot and tostring(params.slot) or nil
	local job = trade:NewJob("search_url")
	job.phase = "searching"
	job.searchUrl = url
	trade:Requests().maxFetchPerSearch = 10 * (tonumber(params.fetchPages) or 1)
	local collect = collector(job, build, slotName)
	trade:Requests():SearchWithURL(url, function(items, errMsg, query)
		job.query = query
		collect(items, errMsg)
	end)
	return { jobId = job.id, status = job.status }
end

commands["trade.search_raw"] = function(params)
	local build = getBuild()
	local league = tostring(req(params, "league"))
	local realm = params.realm or "pc"
	local query = req(params, "query")
	if type(query) == "table" then
		query = dkjson.encode(query)
	end
	query = tostring(query)
	local slotName = params.slot and tostring(params.slot) or nil
	local job = trade:NewJob("search_raw")
	job.phase = "searching"
	job.query = query
	local requests = trade:Requests()
	requests.maxFetchPerSearch = 10 * (tonumber(params.fetchPages) or 1)
	requests:SearchWithQuery(realm, league, query, collector(job, build, slotName), {
		callbackQueryId = function(queryId)
			job.searchUrl = requests:buildUrl("https://www.pathofexile.com/trade/search", realm, league, queryId)
		end,
	})
	return { jobId = job.id, status = job.status }
end

commands["trade.job"] = function(params)
	local job = trade:GetJob(params)
	local result = {
		jobId = job.id,
		kind = job.kind,
		status = job.status,
		phase = job.phase,
		slot = job.slot,
		league = job.league,
		searchUrl = job.searchUrl,
		error = job.error,
		leagues = job.leagues,
		pinned = job.pinned,
		-- item_link only: whether the narrowed search still contains the listing,
		-- and which relaxation step it took to get there
		exact = job.exact,
		narrowedBy = job.narrowedBy,
		droppedUnparseable = job.dropped,
		elapsed = (job.finished or os.time()) - job.started,
	}
	if trade.rateLimitedAt and job.status == "running" and os.time() - trade.rateLimitedAt < 5 then
		result.rateLimitedForSeconds = trade.rateLimitedFor
	end
	if job.status == "done" and job.items then
		result.count = #job.items
		local items = job.items
		if params.includeText == false then
			items = { }
			for _, entry in ipairs(job.items) do
				local copy = copyTable(entry)
				copy.text = nil
				t_insert(items, copy)
			end
		end
		result.items = items
	end
	if params.includeQuery then
		result.query = job.query
	end
	return result
end

-- Measure what each result would actually do to the build. The weighted search
-- ranks by a synthetic score computed from mod weights; this runs the real
-- calculator on the real items, which is the only thing that settles whether a
-- candidate keeps resistances capped.
commands["trade.evaluate"] = function(params)
	local build = getBuild()
	local job = trade:GetJob(params)
	if job.status ~= "done" then
		error("job " .. job.id .. " is " .. job.status .. ", not done", 0)
	end
	local slotName = params.slot and tostring(params.slot) or job.slot
	if not slotName then
		error("this job did not target a slot; pass 'slot' to say what to evaluate against", 0)
	end
	if not build.itemsTab.slots[slotName] then
		error("unknown slot '" .. slotName .. "'", 0)
	end
	local statNames = params.stats
	if type(statNames) ~= "table" or not statNames[1] then
		-- OverCap alongside the capped value: once a resistance is at the cap the
		-- capped number stops moving, and the headroom is what says whether a
		-- swap elsewhere is still affordable
		statNames = {
			"EnergyShield", "TotalEHP", "Life", "Mana",
			"FireResist", "FireResistOverCap",
			"ColdResist", "ColdResistOverCap",
			"LightningResist", "LightningResistOverCap",
			"ChaosResist",
			"Str", "Dex", "Int",
			"EffectiveMovementSpeedMod",
			"FullDPS",
		}
	end
	build:PerformRecalc()
	local baseOutput = build.calcsTab.mainOutput
	local calcFunc = build.calcsTab:GetMiscCalculator()

	local results = { }
	for index, entry in ipairs(job.raw or { }) do
		local item = entry.parsed or new("Item"):Item(entry.item_string)
		item:NormaliseQuality()
		item:BuildModList()
		local newOutput = calcFunc({ repSlotName = slotName, repItem = item }, true)
		local stats = { }
		for _, name in ipairs(statNames) do
			local before = baseOutput[name]
			local after = newOutput[name]
			if type(before) == "number" or type(after) == "number" then
				before, after = before or 0, after or 0
				stats[name] = { before = before, after = after, delta = after - before }
			end
		end
		local summary = entrySummary(entry, index)
		summary.text = params.includeText and summary.text or nil
		summary.stats = stats
		t_insert(results, summary)
	end

	-- Rank by the first requested stat unless told otherwise, so the caller gets
	-- an ordered answer rather than search order
	local sortStat = params.sortBy or statNames[1]
	table.sort(results, function(a, b)
		local av = a.stats[sortStat] and a.stats[sortStat].delta or -math.huge
		local bv = b.stats[sortStat] and b.stats[sortStat].delta or -math.huge
		if av == bv then
			return (a.rank or 0) < (b.rank or 0)
		end
		return av > bv
	end)
	return { slot = slotName, sortedBy = sortStat, count = #results, items = results }
end

-- The stat names trade.search_slot weights by, and trade.evaluate reports
commands["trade.stats"] = function(params)
	local query = params.query and tostring(params.query):lower() or nil
	local stats = { }
	for _, entry in ipairs(data.powerStatList) do
		if entry.stat then
			if not query or entry.stat:lower():find(query, 1, true) or (entry.label or ""):lower():find(query, 1, true) then
				t_insert(stats, { stat = entry.stat, label = entry.label })
			end
		end
	end
	return { stats = stats }
end

-- Trade site mod ids, for requiredMods and for hand-written raw queries
commands["trade.mod_ids"] = function(params)
	local query = tostring(req(params, "query")):lower()
	local wantType = params.type and tostring(params.type):lower() or nil
	local limit = tonumber(params.limit) or 25
	local matches = { }
	for _, category in ipairs(tradeHelpers.getTradeStats()) do
		if not wantType or tostring(category.id):lower() == wantType then
			for _, entry in ipairs(category.entries) do
				if entry.text:lower():find(query, 1, true) then
					t_insert(matches, { id = entry.id, text = entry.text, type = entry.type or category.id })
					if #matches >= limit then
						return { matches = matches, truncated = true }
					end
				end
			end
		end
	end
	return { matches = matches }
end

return trade
