-- Path of Building
--
-- Module: Trade Query
-- Provides PoB Trader pane for interacting with PoE Trade
--


local dkjson = require "dkjson"
local itemSlotHelper = require("Modules.ItemSlotHelper")

local get_time = os.time
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort
local m_abs = math.abs
local m_max = math.max
local m_min = math.min
local m_ceil = math.ceil
local s_format = string.format

local baseSlots = { "Weapon 1", "Weapon 2", "Weapon 1 Swap", "Weapon 2 Swap", "Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Ring 2", "Ring 3", "Belt", "Flask 1", "Flask 2", "Flask 3", "Flask 4", "Flask 5" }

---@class TradeQuery
local TradeQueryClass = newClass("TradeQuery")

function TradeQueryClass:TradeQuery(itemsTab)
	self.itemsTab = itemsTab
	self.itemsTab.leagueDropList = { }
	self.totalPrice = { }
	self.controls = { }
	-- table of price results index by slot and number of fetched results
	self.resultTbl = { }
	self.sortedResultTbl = { }
	self.itemIndexTbl = { }
	-- tooltip acceleration tables
	self.onlyWeightedBaseOutput = { }
	self.lastComparedWeightList = { }

	-- default set of trade item sort selection
	---@type TradeQuerySlotTable[]
	self.slotTables = { }
	self.pbItemSortSelectionIndex = 1
	-- for each realm and league, a table of values of each currency in div
	--- @type table<string, table<string, table<string, number>>>
	self.pbCurrencyConversion = {}
	self.lastCurrencyFileTime = { }
	self.pbFileTimestampDiff = { }
	self.pbRealm = ""
	self.pbRealmIndex = 1
	self.pbLeagueIndex = 1
	-- table holding all realm/league pairs. (allLeagues[realm] = [league.id,...])
	self.allLeagues = {}
	-- realm id-text table to pair realm name with API parameter
	self.realmIds = {
		["PC"] = "pc",
		["Xbox"] = "xbox",
		["Sony"] = "sony"
	}
	--- @type integer?
	self.backoffFinish = nil
	-- last query for each row
	self.lastQueries = {}

	self.tradeQueryRequests = new("TradeQueryRequests"):TradeQueryRequests()
	if not main.api then
		main.api = new("PoEAPI"):PoEAPI(main.lastToken, main.lastRefreshToken, main.tokenExpiry)
	end

	self.hostName = "https://www.pathofexile.com/"
	-- www. optional
	self.hostNamePattern = "h?t?t?p?s?:?/?/?w?w?w?%.?pathofexile%.com/"
	return self
end



-- Method to pull down and interpret available leagues from PoE
function TradeQueryClass:PullLeagueList()
	launch:DownloadPage(
		self.hostName .. "api/leagues?type=main&compact=1",
		function(response, errMsg)
			if errMsg then
				self:SetNotice(self.controls.pbNotice, "Error: " .. tostring(errMsg))
				return "POE ERROR", "Error: "..errMsg
			else
				local json_data = dkjson.decode(response.body)
				if not json_data then
					self:SetNotice(self.controls.pbNotice, "Failed to Get PoE League List response")
					return
				end
				table.sort(json_data, function(a, b)
					if a.endAt == nil then return false end
					if b.endAt == nil then return true end
					return a.id < b.id
				end)
				self.itemsTab.leagueDropList = {}
				for _, league_data in pairs(json_data) do
					if not league_data.id:find("SSF") then
						t_insert(self.itemsTab.leagueDropList,league_data.id)
					end
				end
				self.controls.league:SetList(self.itemsTab.leagueDropList)
				self.controls.league.selIndex = 1
				self.pbLeague = self.itemsTab.leagueDropList[self.controls.league.selIndex]
			end
		end)
end

--- @param currencyId string
--- @param amount integer
--- @return number?
function TradeQueryClass:ConvertCurrencyToDivs(currencyId, amount)
	local map = self.pbCurrencyConversion[self.pbRealm] and self.pbCurrencyConversion[self.pbRealm][self.pbLeague]
	if map and map[currencyId] then
		return amount * map[currencyId]
	end
end

local generalCurrencies = {
	["Metadata/Items/Currency/CurrencyModValues"] = true,
	["Metadata/Items/Currency/CurrencyRerollRare"] = true
}

-- Method to pull down and interpret the Currency Exchange JSON endpoint data
function TradeQueryClass:PullCXData()
	local realm = self.pbRealm
	if realm == "" then
		return
	end
	local now = get_time()
	-- Limit Currency Conversion request to 1 per hour
	if self.pbCurrencyConversion[realm] and ((now - self.pbCurrencyConversion[realm].timestamp) < 61 * 60) then
		return
	end

	-- download json containing short names for each item id
	launch:DownloadPage("https://www.pathofexile.com/api/trade/data/static", function(response, errMsg)
		if errMsg then
			self:SetNotice(self.controls.pbNotice, "Error: " .. tostring(errMsg))
			return
		end

		local static = dkjson.decode(response.body)
		if not static then
			self:SetNotice(self.controls.pbNotice, "Could not decode static trade data")
			return
		end
		local url = "https://web.poecdn.com/api/currency-exchange"
		if realm ~= "pc" then
			url = url .. "/" .. realm
		end
		local hourSeconds = 60 * 60
		url = url .. "/" .. ((math.floor(now / hourSeconds) - 1) * hourSeconds)
		launch:DownloadPage(url, function(response, errMsg)
			if errMsg then
				self:SetNotice(self.controls.pbNotice, "Error: " .. tostring(errMsg))
				return
			end
			local json = dkjson.decode(response.body)
			if not json then
				self:SetNotice(self.controls.pbNotice, "Malformed CX API response")
				return
			end

			if json.error then
				self:SetNotice(self.controls.pbNotice, "CX error: " .. json.error.message)
				return
			end
			local success, result = pcall(function()
				-- short currency names for each base item type id
				local currencyNames = {}
				local currencyIdMap = {}
				for id, name in pairs(require("Data.CurrencyNames")) do
					currencyIdMap[name] = id
				end
				for _, entry in ipairs(static.result[1].entries) do
					if entry.id ~= "sep" then
						local itemID = currencyIdMap[entry.text]
						-- Not every bulk trade item is exported as currency.
						if itemID then
							currencyNames[itemID] = entry.id
						end
					end
				end

				local out = {}
				for _, entry in ipairs(json.markets) do
					local league = entry.league
					if not out[league] then
						out[league] = {}
					end
					local leagueOut = out[league]

					-- Base type IDs are in the form Metadata/Items/.../CurrencyModValues.
					local fromID = entry.market_pair[1]
					local toID = entry.market_pair[2]

					-- Normalize entries to price each currency in chaos or divines.
					if generalCurrencies[fromID] and toID ~= "Metadata/Items/Currency/CurrencyModValues" then
						fromID, toID = toID, fromID
					end

					local fromShort = currencyNames[fromID]
					local toShort = currencyNames[toID]
					if not fromShort or not generalCurrencies[toID] or entry.lowest_ratio[fromID] == 0 then
						goto CXContinue
					end

					local newEntry = {
						currency = toShort,
						price = entry.lowest_ratio[toID] / entry.lowest_ratio[fromID],
						stock = entry.highest_stock[fromID]
					}
					-- Only keep the most popular option.
					if not leagueOut[fromShort] or leagueOut[fromShort].stock < newEntry.stock then
						leagueOut[fromShort] = newEntry
					end
					::CXContinue::
				end

				-- Convert any chaos prices to divine equivalent prices.
				for leagueName, leagueEntries in pairs(out) do
					for from, to in pairs(leagueEntries) do
						if to.currency ~= "divine" then
							local divEntry = leagueEntries[to.currency]
							if not divEntry then
								leagueEntries[from] = nil
							else
								leagueEntries[from] = divEntry.price * to.price
							end
						end
					end
					for from, to in pairs(leagueEntries) do
						if type(to) == "table" then
							leagueEntries[from] = to.price
						end
					end
					if not next(leagueEntries) then
						out[leagueName] = nil
					else
						leagueEntries.divine = 1
					end
				end

				return out
			end)
			if not success then
				self:SetNotice(self.controls.pbNotice, "Failed to process CX response")
				ConPrintf("CX error: %s", result)
				return
			end
			result.timestamp = now
			self.pbCurrencyConversion[realm] = result
		end)
	end)
end

local function initStatSortSelectionList(list)
	t_insert(list,  {
		label = "Full DPS",
		stat = "FullDPS",
		weightMult = 1.0,
	})
	t_insert(list,  {
		label = "Effective Hit Pool",
		stat = "TotalEHP",
		weightMult = 0.5,
	})
end

-- we do not want to overwrite previous list if the new list is the default, e.g. hitting reset multiple times in a row
local function isSameAsDefaultList(list)
	return list and #list == 2
		and list[1].stat == "FullDPS" and list[1].weightMult == 1.0
		and list[2].stat == "TotalEHP" and list[2].weightMult == 0.5
end

-- presets that ship with PoB. these are always offered and cannot be
-- overwritten or deleted, user presets live in Settings.xml
local builtinWeightPresets = {
	{ name = "Balanced (Default)", weights = {
		{ stat = "FullDPS", weightMult = 1.0 },
		{ stat = "TotalEHP", weightMult = 0.5 },
	} },
	{ name = "Damage Only", weights = {
		{ stat = "FullDPS", weightMult = 1.0 },
	} },
	{ name = "Survivability Only", weights = {
		{ stat = "TotalEHP", weightMult = 1.0 },
	} },
	{ name = "Damage + Life", weights = {
		{ stat = "FullDPS", weightMult = 1.0 },
		{ stat = "Life", weightMult = 0.5 },
	} },
}

local function isBuiltinPresetName(name)
	for _, preset in ipairs(builtinWeightPresets) do
		if preset.name == name then
			return true
		end
	end
	return false
end

-- copies a weight list, refreshing label and transform from the current power
-- stat list and dropping entries for stats that no longer exist
local function normaliseWeightList(weights)
	local normalised = { }
	for _, weight in ipairs(weights or { }) do
		for _, statEntry in ipairs(data.powerStatList) do
			if statEntry.stat and statEntry.stat == weight.stat then
				t_insert(normalised, {
					label = statEntry.label,
					stat = statEntry.stat,
					transform = statEntry.transform,
					weightMult = round(weight.weightMult or 0, 2),
				})
				break
			end
		end
	end
	return normalised
end

-- weight lists are unordered, so compare them by stat
local function weightListsMatch(listA, listB)
	if #listA ~= #listB then
		return false
	end
	for _, weightA in ipairs(listA) do
		local matched = false
		for _, weightB in ipairs(listB) do
			if weightA.stat == weightB.stat then
				matched = m_abs(weightA.weightMult - weightB.weightMult) < 0.005
				break
			end
		end
		if not matched then
			return false
		end
	end
	return true
end

-- built-in presets followed by the user's own
function TradeQueryClass:GetWeightPresets()
	local presets = { }
	for _, preset in ipairs(builtinWeightPresets) do
		t_insert(presets, { name = preset.name, builtin = true, weights = normaliseWeightList(preset.weights) })
	end
	for _, preset in ipairs(main.tradeWeightPresets or { }) do
		local weights = normaliseWeightList(preset.weights)
		if #weights > 0 then
			t_insert(presets, { name = preset.name, weights = weights })
		end
	end
	return presets
end

--- @return table[] list dropdown entries for the presets
--- @return integer selIndex index of the preset matching the given weights, or of the "Custom" entry
function TradeQueryClass:BuildWeightPresetList(weights)
	local list = { }
	local selIndex
	for _, preset in ipairs(self:GetWeightPresets()) do
		t_insert(list, { label = "^7"..preset.name, preset = preset })
		if not selIndex and weightListsMatch(preset.weights, weights) then
			selIndex = #list
		end
	end
	if not selIndex then
		t_insert(list, 1, { label = "^8Custom", custom = true })
		selIndex = 1
	end
	return list, selIndex
end

-- rebuilds the preset dropdown on the Trader pane and selects whichever preset
-- matches the weights currently in use
function TradeQueryClass:RefreshWeightPresetControl()
	local control = self.controls.weightPreset
	if not control then
		return
	end
	local list, selIndex = self:BuildWeightPresetList(self.statSortSelectionList)
	control:SetList(list)
	control.selIndex = selIndex
end

function TradeQueryClass:ApplyWeightPreset(preset)
	local weights = preset and normaliseWeightList(preset.weights)
	if not weights or #weights == 0 then
		return
	end
	self.statSortSelectionList = weights
	self.itemsTab.modFlag = true
	self:RefreshWeightPresetControl()
	for row_idx in pairs(self.resultTbl) do
		self:UpdateControlsWithItems(row_idx)
	end
end

-- adds or overwrites a user preset and persists it to Settings.xml
function TradeQueryClass:SaveWeightPreset(name, weights)
	main.tradeWeightPresets = main.tradeWeightPresets or { }
	local stored = { name = name, weights = { } }
	for _, weight in ipairs(weights) do
		t_insert(stored.weights, { label = weight.label, stat = weight.stat, weightMult = round(weight.weightMult, 2) })
	end
	for index, preset in ipairs(main.tradeWeightPresets) do
		if preset.name == name then
			main.tradeWeightPresets[index] = stored
			main:SaveSettings()
			return
		end
	end
	t_insert(main.tradeWeightPresets, stored)
	main:SaveSettings()
end

function TradeQueryClass:DeleteWeightPreset(name)
	for index, preset in ipairs(main.tradeWeightPresets or { }) do
		if preset.name == name then
			t_remove(main.tradeWeightPresets, index)
			main:SaveSettings()
			return
		end
	end
end

--- Popup asking for the name to store the given weights under
--- @param weights table[] weight list to store
--- @param onSaved fun(name: string)? called after the preset has been written
function TradeQueryClass:SaveWeightPresetPopup(weights, onSaved)
	local controls = { }
	controls.label = new("LabelControl"):LabelControl(nil, {0, 20, 0, 16}, "^7Preset name:")
	controls.edit = new("EditControl"):EditControl(nil, {0, 40, 250, 20}, nil, nil, nil, 40, function(buf)
		controls.save.enabled = buf:match("%S") ~= nil
	end)
	controls.save = new("ButtonControl"):ButtonControl(nil, {-45, 70, 80, 20}, "Save", function()
		local name = controls.edit.buf:match("^%s*(.-)%s*$")
		if name == "" then
			return
		end
		if isBuiltinPresetName(name) then
			main:OpenMessagePopup("Stat Weight Presets", "'"..name.."' is a built-in preset name.\nPlease choose a different name.")
			return
		end
		local function commit()
			self:SaveWeightPreset(name, weights)
			main:ClosePopup()
			if onSaved then
				onSaved(name)
			end
		end
		for _, preset in ipairs(main.tradeWeightPresets or { }) do
			if preset.name == name then
				main:OpenConfirmPopup("Overwrite Preset", "A preset named '"..name.."' already exists.\nOverwrite it?", "Overwrite", commit)
				return
			end
		end
		commit()
	end)
	controls.save.enabled = false
	controls.cancel = new("ButtonControl"):ButtonControl(nil, {45, 70, 80, 20}, "Cancel", function()
		main:ClosePopup()
	end)
	main:OpenPopup(280, 100, "Save Stat Weight Preset", controls, "save", "edit", "cancel")
end

-- Opens the item pricing popup
function TradeQueryClass:PriceItem()
	self.tradeQueryGenerator = new("TradeQueryGenerator"):TradeQueryGenerator(self)
	main.onFrameFuncs["TradeQueryGenerator"] = function()
		self.tradeQueryGenerator:OnFrame()
	end

	-- Set main Price Builder pane height and width
	local row_height = 20
	local row_vertical_padding = 4
	local top_pane_alignment_ref = nil
	local pane_margins_horizontal = 16
	local pane_margins_vertical = 16

	local newItemList = { }
	for index, itemSetId in ipairs(self.itemsTab.itemSetOrderList) do
		local itemSet = self.itemsTab.itemSets[itemSetId]
		t_insert(newItemList, itemSet.title or "Default")
	end
	self.controls.setSelect = new("DropDownControl"):DropDownControl({"TOPLEFT", nil, "TOPLEFT"}, {pane_margins_horizontal, pane_margins_vertical, 188, row_height}, newItemList, function(index, value)
		self.itemsTab:SetActiveItemSet(self.itemsTab.itemSetOrderList[index])
		self.itemsTab:AddUndoState()
	end)
	self.controls.setSelect.enableDroppedWidth = true
	self.controls.setSelect.enabled = function()
		return #self.itemsTab.itemSetOrderList > 1
	end

	self.loginStatus = function()
		if main.api.authToken then
			self.clickTime = nil
			return "Authenticated"
		elseif self.clickTime then
			local left = m_max(0,(self.clickTime + 60) - os.time())
			if left == 0 then
				self.clickTime = nil
				return "Not authenticated"
			else
				return "Logging in... (" .. left .. ")"
			end
		else
			return colorCodes.WARNING.."Not authenticated"
		end
	end

	if main.api.authToken then
		main.api:ValidateAuth(function(valid)
			if valid then
				return
			else
				main.api:ResetDetails()
			end
		end)
	end
	self.controls.tradeAuthButton = new("ButtonControl"):ButtonControl({"TOPLEFT", self.controls.setSelect, "TOPLEFT"}, {0, row_height + row_vertical_padding, 188, row_height}, self.loginStatus, function()
		-- LOGIN
		if not main.api.authToken then
			main.api:FetchAuthToken(function()
				if main.api.authToken then
					self.loginStatus = "Authenticated"

					main.lastToken = main.api.authToken
					main.lastRefreshToken = main.api.refreshToken
					main.tokenExpiry = main.api.tokenExpiry
					main:SaveSettings()

					TradeQueryClass:SetNotice(self.controls.pbNotice, "")
				else
					self.loginStatus = colorCodes.WARNING.."Not authenticated"
				end
			end)
			self.clickTime = os.time()
		-- LOGOUT
		else
			main.lastToken = nil
			main.api.authToken = nil
			main.lastRefreshToken = nil
			main.api.refreshToken = nil
			main.tokenExpiry = nil
			main.api.tokenExpiry = nil
			main:SaveSettings()
		end
	end)
	self.controls.tradeAuthButton.tooltipText = [[
The Trader feature supports two modes of operation depending on the authorization availability.
You can click this button to authorize PoB by logging in.

^2Session Mode^7
- Requires authorization on pathofexile.com.
- You can search, compare, and quickly import items without leaving Path of Building.
- You can select an item and search it directly.
- You can generate and perform searches for the private leagues you are participating.

^xFF9922No Session Mode^7
- Doesn't require authorization.
- You cannot search and compare items in Path of Building.
- You can generate weighted search URLs but have to visit the trade site and manually import items.
- You can only generate weighted searches for public leagues. (Generated searches can be modified
on trade site to work on other leagues and realms)]]

	-- Buyout selection
	self.tradeTypes = {
		"Instant buyout",
		"Instant buyout and in person",
		"In person (online in league)",
		"In person (online)",
		"Any (includes offline)"
	}

	self.controls.tradeTypeSelection = new("DropDownControl"):DropDownControl({ "TOPLEFT", self.controls.tradeAuthButton, "BOTTOMLEFT" },
		{ 0, row_vertical_padding, 188, row_height }, self.tradeTypes, function(index, value)
			self.tradeTypeIndex = index
		end)
	-- remember previous choice
	self.controls.tradeTypeSelection:SetSel(self.tradeTypeIndex or 1)

	-- Fetches Box
	self.maxFetchPerSearchDefault = 2
	self.controls.fetchCountEdit = new("EditControl"):EditControl({"TOPRIGHT", nil, "TOPRIGHT"}, {-12, 19, 150, row_height}, "", "Fetch Pages", "%D", 3, function(buf)
		self.maxFetchPages = m_min(m_max(tonumber(buf) or self.maxFetchPerSearchDefault, 1), 10)
		self.tradeQueryRequests.maxFetchPerSearch = 10 * self.maxFetchPages
		self.controls.fetchCountEdit.focusValue = self.maxFetchPages
	end)
	self.controls.fetchCountEdit.focusValue = self.maxFetchPerSearchDefault
	self.tradeQueryRequests.maxFetchPerSearch = 10 * self.maxFetchPerSearchDefault
	self.controls.fetchCountEdit:SetText(tostring(self.maxFetchPages or self.maxFetchPerSearchDefault))
	function self.controls.fetchCountEdit:OnFocusLost()
		self:SetText(tostring(self.focusValue))
	end
	self.controls.fetchCountEdit.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "Specify maximum number of item pages to retrieve per search from PoE Trade.")
		tooltip:AddLine(16, "Each page fetches up to 10 items.")
		tooltip:AddLine(16, "Acceptable Range is: 1 to 10")
	end

	-- Stat sort popup button
	-- if the list is nil or empty, set default sorting, otherwise keep whatever was loaded from xml
	if not self.statSortSelectionList or (#self.statSortSelectionList) == 0 then
		self.statSortSelectionList = { }
		initStatSortSelectionList(self.statSortSelectionList)
	end
	self.controls.StatWeightMultipliersButton = new("ButtonControl"):ButtonControl({"TOPRIGHT", self.controls.fetchCountEdit, "BOTTOMRIGHT"}, {0, row_vertical_padding, 150, row_height}, "^7Adjust search weights", function()
		self.itemsTab.modFlag = true
		self:SetStatWeights()
	end)
	self.controls.StatWeightMultipliersButton.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "Sorts the weights by the stats selected multiplied by a value")
		tooltip:AddLine(16, "Currently sorting by:")
		for _, stat in ipairs(self.statSortSelectionList) do
			tooltip:AddLine(16, s_format("%s: %.2f", stat.label, stat.weightMult))
		end
	end

	-- Stat weight preset selection, for switching between saved sets of weights
	-- without having to open the weight popup
	self.controls.weightPresetLabel = new("LabelControl"):LabelControl({"LEFT", self.controls.tradeTypeSelection, "RIGHT"}, {18, 0, 0, row_height - 4}, "^7Weights:")
	self.controls.weightPreset = new("DropDownControl"):DropDownControl({"LEFT", self.controls.weightPresetLabel, "RIGHT"}, {6, 0, 170, row_height}, { }, function(index, value)
		if value.preset then
			self:ApplyWeightPreset(value.preset)
		end
	end)
	self.controls.weightPreset.enableDroppedWidth = true
	self.controls.weightPreset.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "Applies a saved set of stat weights to the searches on this pane.")
		tooltip:AddLine(16, "^8Presets are shared by all builds, and can be created")
		tooltip:AddLine(16, "^8and removed under 'Adjust search weights'.")
		local selValue = self.controls.weightPreset:GetSelValue()
		if selValue and selValue.custom then
			tooltip:AddLine(16, "")
			tooltip:AddLine(16, "^7The current weights do not match any preset.")
		end
	end
	self:RefreshWeightPresetControl()

	self.sortModes = {
		StatValue = "(Highest) Stat Value",
		StatValuePrice = "Stat Value / Price",
		Price = "(Lowest) Price",
		Weight = "(Highest) Weighted Sum",
	}
	-- Item sort dropdown
	self.itemSortSelectionList = {
		self.sortModes.StatValue,
		self.sortModes.StatValuePrice,
		self.sortModes.Price,
		self.sortModes.Weight,
	}
	self.controls.itemSortSelection = new("DropDownControl"):DropDownControl({"TOPRIGHT", self.controls.StatWeightMultipliersButton, "TOPLEFT"}, {-8, 0, 170, row_height}, self.itemSortSelectionList, function(index, value)
		self.pbItemSortSelectionIndex = index
		for row_idx, _ in pairs(self.resultTbl) do
			self:UpdateControlsWithItems(row_idx)
		end
	end)
	self.controls.itemSortSelection.tooltipText =
[[Weighted Sum searches will always sort using descending weighted sum
Additional post filtering options can be done these include:
Highest Stat Value - Sort from highest to lowest Stat Value change of equipping item
Highest Stat Value / Price - Sorts from highest to lowest by estimated Stat Value per currency
Lowest Price - Sorts from lowest to highest price of retrieved items
Highest Weight - Displays the order retrieved from trade]]
	-- avoid calling selFunc to avoid updating controls before they are initialised
	self.controls.itemSortSelection:SetSel(self.pbItemSortSelectionIndex, true)
	self.controls.itemSortSelectionLabel = new("LabelControl"):LabelControl({"TOPRIGHT", self.controls.itemSortSelection, "TOPLEFT"}, {-4, 0, 56, 16}, "^7Sort By:")

	-- Realm selection
	self.controls.realmLabel = new("LabelControl"):LabelControl({"LEFT", self.controls.setSelect, "RIGHT"}, {18, 0, 20, row_height - 4}, "^7Realm:")
	self.controls.realm = new("DropDownControl"):DropDownControl({"LEFT", self.controls.realmLabel, "RIGHT"}, {6, 0, 150, row_height}, self.realmDropList, function(index, value)
		self.pbRealmIndex = index
		if self.pbRealm ~= self.realmIds[value] then
			self.pbRealm = self.realmIds[value]
			self:PullCXData()
		end
		local function setLeagueDropList()
			self.itemsTab.leagueDropList = copyTable(self.allLeagues[self.pbRealm])
			self.controls.league:SetList(self.itemsTab.leagueDropList)
			-- invalidate selIndex to trigger select function call in the SetSel
			self.controls.league.selIndex = nil
			self.controls.league:SetSel(self.pbLeagueIndex)
		end
		if self.allLeagues[self.pbRealm] then
			setLeagueDropList()
		else
			self.tradeQueryRequests:FetchLeagues(self.pbRealm, function(leagues, errMsg)
				if errMsg then
					self:SetNotice(self.controls.pbNotice, "Error while fetching league list: "..errMsg)
					return
				end
				local sorted_leagues = { }
				for _, league in ipairs(leagues) do
					if league ~= "Standard" and  league ~= "Ruthless" and league ~= "Hardcore" and league ~= "Hardcore Ruthless" then
						t_insert(sorted_leagues, league)
					end
				end
				t_insert(sorted_leagues, "Standard")
				t_insert(sorted_leagues, "Hardcore")
				t_insert(sorted_leagues, "Ruthless")
				t_insert(sorted_leagues, "Hardcore Ruthless")
				self.allLeagues[self.pbRealm] = sorted_leagues
				setLeagueDropList()
			end)
		end
	end)
	self.controls.realm:SetSel(self.pbRealmIndex)
	self.controls.realm.enabled = function()
		return #self.controls.realm.list > 1
	end

	-- League selection
	self.controls.leagueLabel = new("LabelControl"):LabelControl({"TOPRIGHT", self.controls.realmLabel, "TOPRIGHT"}, {0, row_height + row_vertical_padding, 20, row_height - 4}, "^7League:")
	self.controls.league = new("DropDownControl"):DropDownControl({"LEFT", self.controls.leagueLabel, "RIGHT"}, {6, 0, 150, row_height}, self.itemsTab.leagueDropList, function(index, value)
		self.pbLeagueIndex = index
		self.pbLeague = value
	end)
	self.controls.league:SetSel(self.pbLeagueIndex)
	self.controls.league.enabled = function()
		return #self.controls.league.list > 1
	end

	if self.pbRealm == "" then
		self:UpdateRealms()
	end

	local activeAbyssalSockets = {
		["Weapon 1"] = { }, ["Weapon 2"] = { }, ["Helmet"] = { }, ["Body Armour"] = { }, ["Gloves"] = { }, ["Boots"] = { }, ["Belt"] = { },
	}
	-- loop all slots, set any active abyssal sockets
	for index, slot in pairs(self.itemsTab.slots) do
		if index:find("Abyssal") and slot.shown() then
			t_insert(activeAbyssalSockets[slot.parentSlot.slotName], slot)
		end
	end
	for _, abyssal in pairs(activeAbyssalSockets) do -- sort Abyssal #1 > Abyssal #2 etc
		t_sort(abyssal, function(a, b)
			return a.label < b.label
		end)
	end

	-- Individual slot rows
	---@class TradeQuerySlotTable
	---@field slotName string Display name of the row, also the slot name for regular slots
	---@field fullName string? Actual slot name for abyssal sockets, where slotName is the shortened label
	---@field nodeId number? Passive tree node id for jewel socket rows
	---@field unique boolean? Row targets a specific unique instead of a slot
	---@field alreadyCorrupted boolean? The targeted unique only drops corrupted
	---@field selectedJewelNodeId number? Jewel socket the unique row searches for
	---@field selectedSlotName string? A slot name which was selected in the TradeQueryGenerator popup

	---@type TradeQuerySlotTable[]
	local slotTables = {}
	for _, slotName in ipairs(baseSlots) do
		if self.itemsTab.slots[slotName].shown() then
			t_insert(slotTables, { slotName = slotName })
		end
		-- add abyssal sockets to slotTables if exist for this slot
		if activeAbyssalSockets[slotName] then
			for _, abyssalSocket in pairs(activeAbyssalSockets[slotName]) do
				t_insert(slotTables, { slotName = abyssalSocket.label, fullName = abyssalSocket.slotName }) -- actual slotName doesn't fit/excessive in slotName on popup but is needed for exact matching later
			end
		end
	end
	local activeSocketList = { }
	for nodeId, slot in pairs(self.itemsTab.sockets) do
		if not slot.inactive then
			t_insert(activeSocketList, nodeId)
		end
	end
	table.sort(activeSocketList)
	local activeUniqueJewelSocket
	for _, nodeId in ipairs(activeSocketList) do
		if not activeUniqueJewelSocket and not self.itemsTab.build.spec.nodes[nodeId].containJewelSocket then
			activeUniqueJewelSocket = nodeId
		end
		t_insert(slotTables, { slotName = self.itemsTab.sockets[nodeId].label, nodeId = nodeId })
	end

	self.controls.sectionAnchor = new("LabelControl"):LabelControl({"LEFT", self.controls.tradeTypeSelection, "LEFT"}, {0, row_vertical_padding, 0, 0}, "")
	top_pane_alignment_ref = {"TOPLEFT", self.controls.sectionAnchor, "TOPLEFT"}
	local scrollBarShown = #slotTables > 21 -- clipping starts beyond this
	-- dynamically hide rows that are above or below the scrollBar
	local hideRowFunc = function(self, index)
		if scrollBarShown then
			local rowWithPadding = row_height + row_vertical_padding
			-- this many items fit in the scrollBar "box" so as the offset moves, we need to dynamically show what is within the boundaries
			local maxItemsInView = math.floor(self.controls.scrollBar.height / rowWithPadding) - 2
			if (index <= maxItemsInView and (self.controls.scrollBar.offset < (rowWithPadding * (index - 1) + row_vertical_padding))) or
				-- the second and in this applies if we have more than 44 slots because we need to hide the next "page" of rows as they go above the line, e.g. #23 could be above or below the "box"
				(index >= maxItemsInView + 1 and (self.controls.scrollBar.offset > rowWithPadding * (index - maxItemsInView) and self.controls.scrollBar.offset < rowWithPadding * (index - 1))) then
				return true
			end
		else
			return true
		end
		return false
	end
	for index, slotTbl in pairs(slotTables) do
		self.slotTables[index] = slotTbl
		self:PriceItemRowDisplay(index, top_pane_alignment_ref, row_vertical_padding, row_height)
		self.controls["name"..index].shown = function()
			return hideRowFunc(self, index)
		end
	end

	self.controls.otherTradesLabel = new("LabelControl"):LabelControl(top_pane_alignment_ref, {0, (#slotTables+1)*(row_height + row_vertical_padding), 100, 16}, "^8Other trades:")
	self.controls.otherTradesLabel.shown = function()
		return hideRowFunc(self, #slotTables+1)
	end
	local row_count = #slotTables + 1
	self.slotTables[row_count] = { slotName = "Megalomaniac", unique = true, alreadyCorrupted = true, selectedJewelNodeId = activeUniqueJewelSocket }
	self:PriceItemRowDisplay(row_count, top_pane_alignment_ref, row_vertical_padding, row_height)
	self.controls["name"..row_count].y = self.controls["name"..row_count].y + (row_height + row_vertical_padding) -- Megalomaniac needs to drop an extra row for "Other Trades"
	self.controls["name"..row_count].shown = function()
		return hideRowFunc(self, row_count)
	end
	row_count = row_count + 1
	-- Watcher's Eye
	self.slotTables[row_count] = { slotName = "Watcher's Eye", unique = true, selectedJewelNodeId = activeUniqueJewelSocket }
	self:PriceItemRowDisplay(row_count, top_pane_alignment_ref, row_vertical_padding, row_height)
	self.controls["name"..row_count].y = self.controls["name"..row_count].y + (row_height + row_vertical_padding)
	self.controls["name"..row_count].shown = function()
		return hideRowFunc(self, row_count)
	end
	row_count = row_count + 1

	-- Pearl of Tsoatha
	self.slotTables[row_count] = { slotName = "Pearl of Tsoatha", unique = true }
	self:PriceItemRowDisplay(row_count, top_pane_alignment_ref, row_vertical_padding, row_height)
	self.controls["name" .. row_count].y = self.controls["name" .. row_count].y + (row_height + row_vertical_padding)
	self.controls["name" .. row_count].shown = function()
		return hideRowFunc(self, row_count)
	end
	-- fix case where the row count is reduced from the last time the popup was
	-- opened, which would leave extra row controls in the menu
	for k, v in pairs(self.controls) do
		local number = k:match("(%d+)")
		if number and tonumber(number) > row_count then
			self.controls[k] = nil
		end
	end

	row_count = row_count + 2

	local effective_row_count = row_count - ((scrollBarShown and #slotTables >= 19) and #slotTables-19 or 0) + 2 + 2 -- Two top menu rows, two bottom rows, slots after #19 overlap the other controls at the bottom of the pane
	self.effective_rows_height = row_height * (effective_row_count - #slotTables + (18 - (#slotTables > 37 and 3 or 0))) -- scrollBar height, "18 - slotTables > 37" logic is fine tuning whitespace after last row
	self.pane_height = (row_height + row_vertical_padding) * effective_row_count + 3 * pane_margins_vertical + row_height / 2
	local pane_width = 885 + (scrollBarShown and 25 or 0)

	self.controls.scrollBar = new("ScrollBarControl"):ScrollBarControl({"TOPRIGHT", self.controls["StatWeightMultipliersButton"],"TOPRIGHT"}, {0, 25, 18, 0}, 50, "VERTICAL", false)
	self.controls.scrollBar.shown = function() return scrollBarShown end

	self.controls.fullPrice = new("LabelControl"):LabelControl({"BOTTOM", nil, "BOTTOM"}, {0, -row_height - pane_margins_vertical - row_vertical_padding, pane_width - 2 * pane_margins_horizontal, row_height}, "")
	self.controls.close = new("ButtonControl"):ButtonControl({"BOTTOM", nil, "BOTTOM"}, {0, -pane_margins_vertical, 90, row_height}, "Done", function()
		main:ClosePopup()
	end)

	-- "Find best" answers one slot at a time, which is a different question from
	-- "what is the best set": the best helmet on its own often breaks the
	-- resistance cap or the Strength a weapon needs, and paying that back costs
	-- more than the helmet gained. This solves across the slots together.
	self.controls.solveSet = new("ButtonControl"):ButtonControl({"BOTTOMLEFT", nil, "BOTTOMLEFT"}, {pane_margins_horizontal, -pane_margins_vertical, 110, row_height}, "Solve Set", function()
		self:OptimiseSetPopup()
	end)
	-- Deliberately not gated on having fetched anything: the slots are picked
	-- inside the dialog and it does its own searching, so requiring results first
	-- would hide the only way to ask for them
	self.controls.solveSet.enabled = function()
		return self.pbLeague ~= nil
	end
	self.controls.solveSet.tooltipText = [[Buys a whole gear set rather than one slot at a time.

Tick the slots you are willing to replace, set what to maximise and a budget, and
it searches those slots and picks the best combination — keeping resistances
capped, attribute requirements met and the total inside the budget.

"Find best" answers one slot at a time, which is a different question: the best
helmet on its own often breaks the resistance cap or the Strength a weapon needs.

Anything already fetched above is reused; a slot may also be left alone if that
turns out better.]]
	self.controls.pbNotice = new("LabelControl"):LabelControl({"BOTTOMRIGHT", nil, "BOTTOMRIGHT"}, {-row_height - pane_margins_vertical - row_vertical_padding, -pane_margins_vertical, 300, row_height}, "")

	-- used in PopupDialog:Draw()
	local function scrollBarFunc()
		self.controls.scrollBar.height = self.pane_height-100
		self.controls.scrollBar:SetContentDimension(self.pane_height-100, self.effective_rows_height)
		self.controls.sectionAnchor.y = -self.controls.scrollBar.offset
	end

	local function onRateLimit(backoff)
		self.backoffFinish = get_time() + backoff
		self.countDown = coroutine.create(function()
			while self.backoffFinish do
				local now = get_time()
				if self.backoffFinish < (now + 0.5) then
					self.backoffFinish = nil
					self:SetNotice(self.controls.pbNotice, "")
					return
				end
				local msg = s_format("Rate limited. Retrying after %s seconds...", self.backoffFinish - now)
				self:SetNotice(self.controls.pbNotice, colorCodes.WARNING .. msg)
				coroutine.yield()
			end
		end)
	end
	main.onFrameFuncs["TradeQueryRequests"] = function()
		self.tradeQueryRequests:ProcessQueue(onRateLimit)
		if self.countDown then
			coroutine.resume(self.countDown)
			if coroutine.status(self.countDown) == "dead" then
				self.countDown = nil
			end
		end
	end
	self:PullCXData()
	main:OpenPopup(pane_width, self.pane_height, "Trader", self.controls, nil, nil, "close", (scrollBarShown and scrollBarFunc or nil))
end

-- Gather everything already fetched into pools the optimiser can search.
-- Prices are normalised to Chaos so a mixed-currency shortlist can be compared;
-- listings in a currency with no known rate are skipped rather than guessed at.
function TradeQueryClass:BuildOptimiserPools()
	local pools, skipped = { }, 0
	for rowIdx, results in pairs(self.resultTbl) do
		local slotTbl = self.slotTables[rowIdx]
		local slotName = slotTbl and (slotTbl.fullName or slotTbl.slotName)
		if slotName and self.itemsTab.slots[slotName] and results then
			local pool = { }
			for _, entry in ipairs(results) do
				local price = self:ConvertCurrencyToChaos(entry.currency, entry.amount)
				local ok, item = pcall(function() return new("Item"):Item(entry.item_string) end)
				if price and ok and item and item.base then
					item:NormaliseQuality()
					item:BuildModList()
					t_insert(pool, {
						slotName = slotName,
						rowIdx = rowIdx,
						item = item,
						price = price,
						listing = entry,
						label = (item.title or item.name or item.baseName) .. "  " ..
							tostring(entry.amount) .. " " .. tostring(entry.currency),
					})
				elseif not price then
					skipped = skipped + 1
				end
			end
			if pool[1] then
				pools[slotName] = pool
			end
		end
	end
	return pools, skipped
end

--- Chaos value of a listing. Chaos itself needs no table, which keeps the common
--- case working before the currency exchange rates have arrived.
function TradeQueryClass:ConvertCurrencyToChaos(currencyId, amount)
	if not amount then return nil end
	if currencyId == "chaos" then return amount end
	local divs = self:ConvertCurrencyToDivs(currencyId, amount)
	local rates = self.pbCurrencyConversion[self.pbRealm] and self.pbCurrencyConversion[self.pbRealm][self.pbLeague]
	local chaosPerDiv = rates and rates["chaos"]
	if divs and chaosPerDiv and chaosPerDiv > 0 then
		return divs / chaosPerDiv
	end
	return nil
end

--- Equipment slots the optimiser can search and swap, paired with their row in
--- the Trader so results land where the rest of the UI expects them.
function TradeQueryClass:OptimisableSlots()
	local slots = { }
	for rowIdx, slotTbl in pairs(self.slotTables) do
		local slotName = slotTbl.fullName or slotTbl.slotName
		local slot = slotName and self.itemsTab.slots[slotName]
		if slot and not slotTbl.unique and not slot.inactive then
			t_insert(slots, { slotName = slotName, rowIdx = rowIdx, slot = slot })
		end
	end
	t_sort(slots, function(a, b) return a.rowIdx < b.rowIdx end)
	return slots
end

-- Pseudo trade mods that total a stat across an item, which is what a search has
-- to ask for when the constraint is on the build's total rather than one roll
local pseudoForStat = {
	Str = "pseudo.pseudo_total_strength",
	Dex = "pseudo.pseudo_total_dexterity",
	Int = "pseudo.pseudo_total_intelligence",
}
local pseudoElementalResist = "pseudo.pseudo_total_elemental_resistance"
-- Ceilings so one demand cannot be set so high that the search returns nothing
local maxPseudoResist = 80
local maxPseudoAttribute = 45

--- Decide the handful of ways each slot should be searched.
---
--- The naive fix for "the best Energy Shield helmet has no resistances" is to
--- demand resistance on every search. That is the wrong answer, and it is the
--- reason this is hard: it forces every slot to pay for resistance, when the
--- cheapest set usually comes from one item carrying a great deal of it and the
--- rest carrying none. Forcing it everywhere prices out exactly the combination
--- worth having.
---
--- So each slot is searched several ways and the results pooled: once for the
--- objective alone, once for an item that carries a serious share of the missing
--- resistance, and once per short attribute. The solver then decides which slot
--- covers what — including leaving a slot with none of it.
---
--- The shortfall is measured with every slot being replaced emptied, because what
--- matters is what the new items must supply between them, not what the current
--- ones happen to have.
---@param slotEntries table @ the slots about to be searched
---@param constraints table
---@return table profiles, table summary
---@param overcapAllowance number? @ how far past the cap is acceptable
function TradeQueryClass:OptimiserSearchProfiles(slotEntries, constraints, overcapAllowance)
	local profiles = { { label = "best", requiredMods = nil } }
	local summary = { }
	if #slotEntries == 0 then
		return profiles, summary
	end

	local calcFunc = self.itemsTab.build.calcsTab:GetMiscCalculator()
	local repItems = { }
	for _, entry in ipairs(slotEntries) do
		repItems[entry.slotName] = false
	end
	local stripped = calcFunc({ repItems = repItems }, true)

	local function floorFor(constraint)
		if constraint.atLeast then
			return (stripped[constraint.atLeast] or 0) + (constraint.margin or 0)
		end
		return constraint.min + (constraint.margin or 0)
	end

	-- Resistances go in as one elemental total rather than three separate demands:
	-- an item carrying all three at once barely exists, the total is a normal
	-- roll, and the distribution can be sorted out afterwards
	local resistNeed = 0
	for _, constraint in ipairs(constraints) do
		if constraint.stat:find("ResistTotal$") then
			resistNeed = resistNeed + m_max(0, floorFor(constraint) - (stripped[constraint.stat] or 0))
		end
	end
	if resistNeed > 0 then
		-- Sized so roughly three items cover the shortfall, not one per slot.
		--
		-- Two competing pulls. Asking too little of each item means no combination
		-- reaches the cap. Asking too much wastes affixes: a slot has a fixed
		-- number of rolls, so every resistance beyond what is needed is a roll not
		-- spent on the stat being maximised -- which is why overshooting the cap
		-- costs more than the chaos it wastes. Three-ish carriers leaves the other
		-- slots free to be whatever is best for the objective.
		local ask = m_min(m_max(m_ceil((resistNeed + (overcapAllowance or 0)) / 3), 20), maxPseudoResist)
		t_insert(profiles, {
			label = "resistance",
			requiredMods = { { tradeId = pseudoElementalResist, value = ask } },
		})
		t_insert(summary, s_format("+%d%% elemental resistance", ask))
	end

	-- Attributes: only the ones actually short, worst first, at most two
	local attrNeeds = { }
	for _, constraint in ipairs(constraints) do
		local id = pseudoForStat[constraint.stat]
		if id then
			local need = floorFor(constraint) - (stripped[constraint.stat] or 0)
			if need > 0 then
				t_insert(attrNeeds, { stat = constraint.stat, id = id, need = need })
			end
		end
	end
	t_sort(attrNeeds, function(a, b) return a.need > b.need end)
	for index = 1, m_min(#attrNeeds, 2) do
		local entry = attrNeeds[index]
		local ask = m_min(m_ceil(entry.need / 2), maxPseudoAttribute)
		t_insert(profiles, {
			label = entry.stat,
			requiredMods = { { tradeId = entry.id, value = ask } },
		})
		t_insert(summary, s_format("+%d %s", ask, entry.stat))
	end
	return profiles, summary
end

--- Run one slot's weighted search, the same one "Find best" runs, without the
--- options popup. Results go into resultTbl so the Trader rows update too.
---@param entry table @ from OptimisableSlots
---@param settings table @ { objective, budget, includeCorrupted }
---@param callback fun(errMsg: string?)
function TradeQueryClass:SearchSlotForOptimiser(entry, settings, callback)
	-- Where a search's mod weights come from: TradeQueryGenerator tries every mod
	-- that can roll on the slot, measures what each does to these stats through the
	-- real calculator, and asks the trade site for the highest-scoring items. So a
	-- mod is only searched for if it moves one of these -- which is why an Energy
	-- Shield objective never surfaces spell suppression: suppression changes Energy
	-- Shield by exactly nothing, so it scores zero. Widening the objective (or
	-- borrowing the Trader's weight list) is what makes such mods visible.
	local statWeights = { }
	local seenStat = { }
	for _, entry in ipairs(settings.statWeights or { }) do
		if entry.stat and not seenStat[entry.stat] and (entry.weightMult or 0) ~= 0 then
			-- Resolved against powerStatList rather than trusted as given: the
			-- generator needs the full entry, including the transform that makes
			-- lower-is-better stats weigh the right way round
			for _, stat in ipairs(data.powerStatList) do
				if stat.stat == entry.stat then
					local template = copyTable(stat)
					template.weightMult = entry.weightMult
					t_insert(statWeights, template)
					seenStat[entry.stat] = true
					break
				end
			end
		end
	end
	if not statWeights[1] then
		return callback("No usable search weights are set")
	end

	local generator = self.tradeQueryGenerator
	if not generator then
		return callback("Trade query generator is not ready")
	end
	-- FinishQuery reads the listing status off the generator rather than options
	generator.tradeTypeIndex = self.tradeTypeIndex or 4
	generator.requesterCallback = function(context, query, errMsg)
		if errMsg then
			return callback(errMsg)
		end
		self.lastQueries[entry.rowIdx] = query
		self.tradeQueryRequests:SearchWithQueryWeightAdjusted(self.pbRealm, self.pbLeague, query,
			function(items, searchErr)
				if searchErr then
					return callback(searchErr)
				end
				callback(nil, self:FilterToSafeItems(items, entry.slotName))
			end,
			{
				callbackQueryId = function(queryId)
					local url = self.tradeQueryRequests:buildUrl(self.hostName .. "trade/search",
						self.pbRealm, self.pbLeague, queryId)
					if self.controls["uri" .. entry.rowIdx] then
						self.controls["uri" .. entry.rowIdx]:SetText(url, true)
					end
				end,
			})
	end
	generator.requesterContext = { }
	-- StartQuery bails before creating a context for an item type it cannot
	-- weight, leaving the previous slot's finished coroutine in place; clearing
	-- it first is what makes the check below mean anything
	generator.calcContext = generator.calcContext or { }
	generator.calcContext.co = nil
	generator:StartQuery(entry.slot, {
		statWeights = statWeights,
		influence1 = 1,
		influence2 = 1,
		includeMirrored = false,
		includeCorrupted = settings.includeCorrupted ~= false,
		includeScourge = false,
		includeTalisman = false,
		includeAllWEMods = false,
		jewelType = "Base",
		weaponCategory = settings.weaponCategory,
		maxPrice = settings.budget,
		maxPriceType = "chaos",
		-- The hard constraints, built into the query itself: without them the
		-- search returns the best items for the objective and nothing else, and
		-- no combination of those keeps the caps
		requiredMods = settings.requiredMods,
		-- The user is looking at this dialog; do not throw another one over it
		noPopup = true,
	})
	if not generator.calcContext.co then
		return callback("This slot cannot be searched for automatically")
	end
end

--- A trade site URL showing one specific solved item.
---
--- Built client-side into the "?q=" form the site accepts, so pressing the button
--- costs no API call and no rate limit. A rare's generated name goes in `term`,
--- the site's free-text field, which matches it directly -- `name` is a different
--- field, validated against the known-item table, and rejects rare names. Base
--- type, seller and exact price narrow it to the single listing.
---@param cand table @ a candidate from BuildOptimiserPools
---@return string
function TradeQueryClass:OptimiserItemURL(cand)
	local item, listing = cand.item, cand.listing or { }
	local query = {
		query = {
			status = { option = "any" },
			type = item.baseName,
			stats = { { type = "and", filters = { } } },
		},
		sort = { price = "asc" },
	}
	local term = item.title or item.name
	if term then
		query.query.term = term:gsub(",%s*" .. item.baseName:gsub("(%W)", "%%%1") .. "$", "")
	end
	local tradeFilters = { }
	if listing.trader then
		tradeFilters.account = { input = listing.trader }
	end
	if listing.amount and listing.currency then
		tradeFilters.price = { min = listing.amount, max = listing.amount, option = listing.currency }
	end
	if next(tradeFilters) then
		query.query.filters = { trade_filters = { filters = tradeFilters } }
	end
	return s_format("https://www.pathofexile.com/trade/search/%s?q=%s",
		self.pbLeague, urlEncode(dkjson.encode(query)))
end

--- Point each Trader row at the item the solve chose for it.
---
--- Without this the solved set exists only inside the dialog, so closing it
--- throws the links away and the rows behind still show whatever they showed
--- before. Selecting the result in the row means the ordinary per-row controls --
--- import, price, and the button that opens the listing -- act on the solved item.
---@param result table @ a successful solve
function TradeQueryClass:SelectOptimiserResultInRows(result)
	for _, cand in ipairs(result.combo or { }) do
		local rowIdx, listing = cand.rowIdx, cand.listing
		if not cand.keep and rowIdx and listing and self.resultTbl[rowIdx] then
			local rawIndex
			for index, entry in ipairs(self.resultTbl[rowIdx]) do
				if entry.id and entry.id == listing.id then
					rawIndex = index
					break
				end
			end
			if rawIndex then
				self.itemIndexTbl[rowIdx] = rawIndex
				self:SetFetchResultReturn(rowIdx, rawIndex)
				-- The dropdown indexes the sorted view, not the raw list
				local dropdown = self.controls["resultDropdown" .. rowIdx]
				local sorted = self.sortedResultTbl[rowIdx]
				if dropdown and sorted then
					for position, entry in ipairs(sorted) do
						if entry.index == rawIndex then
							dropdown:SetSel(position, true)
							break
						end
					end
				end
			end
		end
	end
end

-- Popup: configure and run the set solve
function TradeQueryClass:OptimiseSetPopup()
	local controls = { }
	local pools, skipped = self:BuildOptimiserPools()
	local slotNames = { }
	for slotName in pairs(pools) do t_insert(slotNames, slotName) end
	t_sort(slotNames)

	-- Persisted in Settings.xml so the dialog opens the way it was left
	local opt = main.tradeOptimiser
	local optimiser = new("TradeSetOptimiser"):TradeSetOptimiser(self.itemsTab)
	local row = 0
	local function nextY()
		row = row + 1
		return 26 * row - 6
	end

	-- Slot picker: which slots the solve is allowed to touch. Anything already
	-- fetched starts ticked, so the flow still works for someone who came here
	-- after pressing "Find best" a few times.
	local slotEntries = self:OptimisableSlots()
	local hasResults = { }
	for _, name in ipairs(slotNames) do hasResults[name] = true end

	controls.slotsLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY(), 0, 16 },
		"^7Slots to consider:")
	local perColumn = m_ceil(#slotEntries / 2)
	local slotRowTop = 26 * row - 6
	for index, entry in ipairs(slotEntries) do
		local column = index > perColumn and 1 or 0
		local rowInColumn = index > perColumn and (index - perColumn - 1) or (index - 1)
		local name = "slot" .. index
		controls[name] = new("CheckBoxControl"):CheckBoxControl({ "TOPLEFT", nil, "TOPLEFT" },
			{ 190 + column * 300, slotRowTop + 22 + rowInColumn * 22, 18, 18 },
			"^7" .. entry.slotName .. ":", function() end, nil, false)
		-- Remembered ticks win; otherwise anything already fetched starts on
		local remembered = opt.slots[entry.slotName]
		controls[name].state = remembered ~= nil and remembered or (next(opt.slots) == nil and hasResults[entry.slotName] or false)
		entry.control = controls[name]
		-- Every slot carries its own outcome. A single summary line cannot say
		-- which slot found nothing, and "no items were found" without a per-slot
		-- breakdown is not a diagnosis.
		-- The off-hand is the one slot whose category cannot be read off the build:
		-- an empty slot looks like a one-handed weapon, so a shield would never be
		-- searched for. Make the choice visible rather than deciding silently.
		local countAnchor = controls[name]
		if entry.slotName == "Weapon 2" then
			controls.offhandMode = new("DropDownControl"):DropDownControl({ "LEFT", controls[name], "RIGHT" },
				{ 6, 0, 110, 18 }, { "Weapons + Shields", "Weapons only", "Shields only" }, function() end)
			controls.offhandMode:SetSel(opt.offhandMode or 1)
			controls.offhandMode.tooltipText = [[What to search for in the off-hand.

Path of Building works the category out from whatever is equipped, so an empty off-hand reads as a one-handed weapon and shields are never considered. Searching both and letting the solver choose is usually what you want; it costs one extra search per profile.

Ignored if your main hand holds a two-handed weapon, since nothing can go here.]]
			countAnchor = controls.offhandMode
		end
		controls[name .. "n"] = new("LabelControl"):LabelControl({ "LEFT", countAnchor, "RIGHT" }, { 6, 0, 0, 14 },
			hasResults[entry.slotName] and ("^8" .. #(self.resultTbl[entry.rowIdx] or { }) .. " fetched") or "")
		entry.countLabel = controls[name .. "n"]
	end
	row = row + m_ceil(perColumn * 22 / 26) + 1

	-- What the build is trying to maximise is already a solved question in the
	-- Trader: a weight editor with saved presets. Reusing it means spell
	-- suppression, chaos resistance or anything else is expressible here the
	-- moment it is weighted there, with nothing to keep in sync.
	local function weightSummary()
		local list = self.statSortSelectionList or { }
		if not list[1] then
			return "^1none set - press Adjust"
		end
		local parts = { }
		for index, entry in ipairs(list) do
			if index > 4 then
				t_insert(parts, s_format("+%d more", #list - 4))
				break
			end
			t_insert(parts, s_format("%s x%.2g", entry.label or entry.stat, entry.weightMult or 1))
		end
		return "^8" .. table.concat(parts, ", ")
	end
	controls.objectiveLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY(), 100, 16 },
		function() return "^7Maximise: " .. weightSummary() end)
	controls.adjustWeights = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls.objectiveLabel, "TOPLEFT" },
		{ 560, -3, 150, 20 }, "^7Adjust search weights", function()
			self:SetStatWeights()
		end)
	controls.adjustWeights.tooltipText = [[Opens the Trader's own weight editor, with its saved presets.

These weights drive both halves of the solve: the searches ask the trade site for items that score well on them, and the solver ranks whole sets by them. A search only looks for mods that move the stats it is given -- weight Effective Hit Pool and spell suppression starts mattering, weight Spell Suppression Chance directly and it is searched for by name.]]

	controls.budgetLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY(), 100, 16 }, "^7Budget (Chaos):")
	controls.budget = new("EditControl"):EditControl({ "LEFT", controls.budgetLabel, "RIGHT" }, { 8, 0, 100, 20 },
		tostring(opt.budget), nil, "%D")

	-- Two fields to a row, each anchored off the row counter rather than off its
	-- neighbour: chaining them sideways ran the last field off the dialog and put
	-- the next row on top of the one after it
	controls.resistLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY(), 100, 16 }, "^7Resistances at least:")
	controls.resist = new("EditControl"):EditControl({ "LEFT", controls.resistLabel, "RIGHT" }, { 8, 0, 60, 20 },
		tostring(opt.resist), nil, "%D")
	controls.overcapLabel = new("LabelControl"):LabelControl({ "LEFT", controls.resist, "RIGHT" }, { 24, 0, 0, 16 }, "^7Allowed overcap:")
	controls.overcap = new("EditControl"):EditControl({ "LEFT", controls.overcapLabel, "RIGHT" }, { 8, 0, 60, 20 },
		tostring(opt.maxOvercap), nil, "%D")

	controls.chaosLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY(), 100, 16 },
		"^7Chaos resistance at least:")
	controls.chaos = new("EditControl"):EditControl({ "LEFT", controls.chaosLabel, "RIGHT" }, { 8, 0, 60, 20 },
		tostring(opt.chaosFloor or 0), nil, "%D")
	controls.attrLabel = new("LabelControl"):LabelControl({ "LEFT", controls.chaos, "RIGHT" }, { 24, 0, 0, 16 }, "^7Attribute headroom:")
	controls.attr = new("EditControl"):EditControl({ "LEFT", controls.attrLabel, "RIGHT" }, { 8, 0, 60, 20 },
		tostring(opt.attrMargin), nil, "%D")
	controls.chaos.tooltipText = [[Minimum chaos resistance. 0 means no requirement.

Chaos resistance is not capped the way the elements are, and demanding it is expensive. If the aim is survivability rather than raw Energy Shield, maximising Effective Hit Pool is usually the better lever: it values chaos resistance, elemental resistance and the pool itself together, and stops valuing a resistance once it is capped.]]

	controls.overcap.tooltipText = [[How far above the cap a resistance may go.

Resistance past the cap does nothing, so without a ceiling the solver will happily buy 250% fire resistance whenever those items also scored well -- budget that should have gone on the stat being maximised.

Set 0 to insist on landing exactly on the cap, which is usually impossible since resistance comes in whole rolls. If nothing fits the allowance, the closest set is used and the result says by how much it overshot.]]
	controls.attr.tooltipText = "Requirements are read from each set as it is measured, because gear with reduced Attribute Requirements lowers the requirement rather than raising the attribute. This is how much room to leave above whatever the requirement turns out to be."

	controls.swapCheck = new("CheckBoxControl"):CheckBoxControl({ "TOPLEFT", nil, "TOPLEFT" }, { 190, nextY(), 20, 20 },
		"^7Allow resistance swap crafts:", function(state) end, nil, false)
	controls.swapCheck.state = opt.swaps
	controls.swapCost = new("EditControl"):EditControl({ "LEFT", controls.swapCheck, "RIGHT" }, { 8, 0, 60, 20 },
		tostring(opt.swapCost), nil, "%D")
	controls.swapCost.shown = function() return controls.swapCheck.state end
	controls.swapCostLabel = new("LabelControl"):LabelControl({ "LEFT", controls.swapCost, "RIGHT" }, { 8, 0, 0, 16 }, "^8Chaos each")
	controls.swapCostLabel.shown = function() return controls.swapCheck.state end
	controls.swapCheck.tooltipText = [[The Harvest bench can change one elemental resistance to another on an uncorrupted, unmirrored item.

With this on, which element the resistance lands on stops mattering — only the total does — which usually finds a cheaper set. The result says how many swaps it needs.

Counted in resistance points rather than whole modifiers, so treat a nonzero count as "needs bench work" and check the per-element numbers before buying.]]

	controls.demands = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY(), 0, 16 }, "")
	controls.status = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY(), 0, 16 }, "")
	local resultRows = { }

	local function clearResults()
		for _, name in ipairs(resultRows) do controls[name] = nil end
		resultRows = { }
	end

	local solveState = { }

	local function showResult(result)
		clearResults()
		if not result.ok then
			controls.status.label = "^1" .. result.reason ..
				(result.measured and ("  ^8(measured " .. result.measured .. ")") or "")
			return
		end
		self.optimiserResult = result
		pcall(function() self:SelectOptimiserResultInRows(result) end)
		local gain = result.score - result.baseScore
		controls.status.label = s_format("^7Weighted score ^8%.3f ^7-> ^8%.3f ^7(%+.1f%%)   ^7cost ^8%.0f Chaos^7%s   ^8measured %d of %d",
			result.baseScore, result.score,
			result.baseScore ~= 0 and (gain / m_abs(result.baseScore) * 100) or 0, result.cost,
			(result.swaps > 0 and s_format("  ^7+ %d swap craft%s", result.swaps, result.swaps == 1 and "" or "s") or "")
				.. (result.overcapRelaxed and s_format("  ^1overcaps by %.0f", result.overcap or 0)
					or (result.overcap and result.overcap > 0 and s_format("  ^8overcap %.0f", result.overcap) or "")),
			result.measured, result.shortlisted)
		local anchor = controls.solve
		for _, cand in ipairs(result.combo) do
			if not cand.keep then
				local name = "res" .. #resultRows
				controls[name] = new("LabelControl"):LabelControl({ "TOPLEFT", anchor, "BOTTOMLEFT" },
					{ 0, anchor == controls.solve and 16 or 8, 0, 16 },
					s_format("^7%-14s ^8%s", cand.slotName, cand.label))
				anchor = controls[name]
				t_insert(resultRows, name)
				-- A solved set is no use without a way to actually buy it
				local openName = name .. "open"
				controls[openName] = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls[name], "TOPLEFT" },
					{ 470, -3, 90, 18 }, "Trade page", function()
						local url = self:OptimiserItemURL(cand)
						Copy(url)
						OpenURL(url)
					end)
				controls[openName].tooltipText = "Opens this listing on the trade site, and copies the link to the clipboard."
				t_insert(resultRows, openName)
				local whisperName = name .. "whisper"
				controls[whisperName] = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls[openName], "TOPRIGHT" },
					{ 6, 0, 80, 18 }, "Whisper", function()
						Copy((cand.listing or { }).whisper or "")
					end)
				controls[whisperName].enabled = function()
					return (cand.listing or { }).whisper ~= nil
				end
				controls[whisperName].tooltipText = "Copies the purchase whisper for this listing to the clipboard."
				t_insert(resultRows, whisperName)
			end
		end
		local resistLine = s_format("^8fire %.0f  cold %.0f  lightning %.0f  chaos %.0f      Str %.0f/%.0f  Dex %.0f/%.0f  Int %.0f/%.0f",
			result.stats.FireResistTotal or 0, result.stats.ColdResistTotal or 0,
			result.stats.LightningResistTotal or 0, result.stats.ChaosResistTotal or 0,
			result.stats.Str or 0, result.stats.ReqStr or 0,
			result.stats.Dex or 0, result.stats.ReqDex or 0,
			result.stats.Int or 0, result.stats.ReqInt or 0)
		controls.resistSummary = new("LabelControl"):LabelControl({ "TOPLEFT", anchor, "BOTTOMLEFT" }, { 0, 8, 0, 16 }, resistLine)
		t_insert(resultRows, "resistSummary")
	end

	-- Search driver. The generator holds one query at a time, so slots go through
	-- a queue rather than all at once; the request layer's rate limiter paces the
	-- HTTP behind it either way.
	local searchState = { queue = { }, active = nil, errors = { }, total = 0, done = 0 }

	--- Capture the dialog into the persisted settings, and write them to disk so
	--- the next session opens with the same choices.
	local function readSettings()
		opt.budget = tonumber(controls.budget.buf) or opt.budget
		opt.resist = tonumber(controls.resist.buf) or opt.resist
		opt.attrMargin = tonumber(controls.attr.buf) or opt.attrMargin
		opt.swaps = controls.swapCheck.state
		opt.swapCost = tonumber(controls.swapCost.buf) or opt.swapCost
		opt.maxOvercap = tonumber(controls.overcap.buf) or opt.maxOvercap
		opt.chaosFloor = tonumber(controls.chaos.buf) or opt.chaosFloor
		opt.offhandMode = controls.offhandMode and controls.offhandMode.selIndex or opt.offhandMode
		opt.refetch = controls.refetch.state
		opt.slots = { }
		for _, entry in ipairs(slotEntries) do
			opt.slots[entry.slotName] = entry.control.state
		end
		main:SaveSettings()
		return { statWeights = self.statSortSelectionList, budget = opt.budget }
	end

	local function refreshPools()
		pools, skipped = self:BuildOptimiserPools()
		slotNames = { }
		for slotName in pairs(pools) do t_insert(slotNames, slotName) end
		t_sort(slotNames)
	end

	local function startSolve()
		refreshPools()
		if not slotNames[1] then
			local why = "^1Nothing to solve with. "
			if searchState.errors and searchState.errors[1] then
				local first = searchState.errors[1]
				if #first > 90 then first = first:sub(1, 87) .. "..." end
				why = why .. s_format("^1%s%s", first,
					#searchState.errors > 1 and s_format(" (+%d more)", #searchState.errors - 1) or "")
			elseif skipped > 0 then
				why = why .. s_format("^1All %d listing(s) were priced in a currency with no known rate - the exchange rates have not arrived yet, try again shortly.", skipped)
			else
				why = why .. "^1The searches returned nothing for these slots. Try a larger budget, a lower resistance requirement, or fewer slots (the requirement is split across them)."
			end
			controls.status.label = why
			return
		end
		if skipped > 0 then
			controls.status.label = s_format("^8%d listing(s) skipped: no conversion rate for that currency.", skipped)
		end
		local settings = {
			statWeights = self.statSortSelectionList,
			budget = opt.budget,
			constraints = optimiser:DefaultConstraints(opt.resist, opt.attrMargin, opt.chaosFloor),
			resistTarget = opt.swaps and opt.resist or nil,
			overcapTarget = opt.resist,
			maxOvercap = opt.maxOvercap,
			resistSwapCost = opt.swaps and opt.swapCost or 0,
			maxResistSwaps = opt.swaps and 3 or 0,
		}
		clearResults()
		controls.status.label = "^7Solving..."
		-- Solving spans many calculator passes, so it runs as a coroutine off the
		-- frame loop; the window keeps drawing and the status line keeps moving
		solveState.co = coroutine.create(function()
			return optimiser:Solve(pools, settings, function(phase, done, total)
				controls.status.label = total
					and s_format("^7%s ^8%d / %d", phase, done, total)
					or s_format("^7%s^8%s", phase, done and (" " .. done) or "")
			end)
		end)
	end
	searchState.startSolve = startSolve

	controls.refetch = new("CheckBoxControl"):CheckBoxControl({ "TOPLEFT", nil, "TOPLEFT" }, { 190, nextY() + 8, 18, 18 },
		"^7Re-search slots with items:", function() end, nil, false)
	controls.refetch.state = opt.refetch
	controls.refetch.tooltipText = "Listings sell quickly. Leave this on if the results in the Trader are more than a few minutes old."

	controls.solve = new("ButtonControl"):ButtonControl({ "TOPLEFT", nil, "TOPLEFT" }, { 16, nextY() + 12, 150, 20 },
		"Solve Set", function()
			readSettings()
			clearResults()
			self.optimiserResult = nil
			-- Fetch whatever the ticked slots are missing, then solve. Slots that
			-- already have items are left alone unless asked for fresh ones.
			searchState.queue, searchState.errors = { }, { }
			local toSearch = { }
			for _, entry in ipairs(slotEntries) do
				if entry.control.state then
					local existing = self.resultTbl[entry.rowIdx]
					if controls.refetch.state or not (existing and existing[1]) then
						t_insert(toSearch, entry)
					end
				end
			end
			local constraints = optimiser:DefaultConstraints(opt.resist, opt.attrMargin, opt.chaosFloor)
			local profiles, summary = self:OptimiserSearchProfiles(toSearch, constraints, opt.maxOvercap)
			-- Each slot is searched once per profile and the results pooled, so a
			-- slot can end up with resistance-heavy items, pure objective items, or
			-- both, and the solver picks which slot carries what
			for _, entry in ipairs(toSearch) do
				-- An empty off-hand reads as a one-handed weapon, so a shield would
				-- never be considered. Search both and let the solver decide, the
				-- same way it decides which slot carries the resistance.
				local categories = { false }
				if entry.slotName == "Weapon 2" and controls.offhandMode then
					local mode = controls.offhandMode.selIndex or 1
					if mode == 2 then
						categories = { "1HWeapon" }
					elseif mode == 3 then
						categories = { "Shield" }
					else
						categories = { "1HWeapon", "Shield" }
					end
				end
				for _, category in ipairs(categories) do
					for profileIdx, profile in ipairs(profiles) do
						t_insert(searchState.queue, {
							entry = entry, profile = profile,
							weaponCategory = category or nil,
							first = profileIdx == 1 and categories[1] == category,
						})
					end
				end
			end
			searchState.total, searchState.done = #searchState.queue, 0
			searchState.settings = { statWeights = self.statSortSelectionList, budget = opt.budget }
			controls.demands.label = summary[1]
				and s_format("^7Searching each slot %d ways: ^8best %s, or carrying %s",
					#profiles, "the configured weights", table.concat(summary, " / "))
				or "^8Nothing to make up; searching on the configured weights alone."
			if searchState.total == 0 then
				startSolve()
			else
				searchState.thenSolve = true
				controls.status.label = s_format("^7Searching 0 / %d...", searchState.total)
			end
		end)
	controls.solve.enabled = function()
		if solveState.co or searchState.active or searchState.queue[1] then return false end
		for _, entry in ipairs(slotEntries) do
			if entry.control.state then return true end
		end
		return false
	end
	controls.solve.tooltipText = [[Tick the slots you are willing to replace, then press this.

Any ticked slot without items is searched first — the same weighted search "Find best" runs, using the objective and budget set here — and the solve follows automatically.

Searches run one slot at a time, because the query generator handles one at a time and the trade API is rate limited. Results also land in the Trader rows behind this dialog.]]

	controls.equip = new("ButtonControl"):ButtonControl({ "LEFT", controls.solve, "RIGHT" }, { 8, 0, 110, 20 }, "Equip Set", function()
		local result = self.optimiserResult
		if not (result and result.ok) then return end
		for _, cand in ipairs(result.combo) do
			if not cand.keep then
				local item = new("Item"):Item(cand.item:BuildRaw())
				item:NormaliseQuality()
				item:BuildModList()
				self.itemsTab:AddItem(item, true)
				self.itemsTab.slots[cand.slotName]:SetSelItemId(item.id)
			end
		end
		self.itemsTab:PopulateSlots()
		self.itemsTab:AddUndoState()
		self.itemsTab.build.buildFlag = true
		main:ClosePopup()
	end)
	controls.equip.enabled = function()
		return self.optimiserResult and self.optimiserResult.ok and true or false
	end
	controls.equip.tooltipText = "Puts the solved set into the build. Undoable with Ctrl+Z."

	controls.close = new("ButtonControl"):ButtonControl({ "LEFT", controls.equip, "RIGHT" }, { 8, 0, 90, 20 }, "Close", function()
		searchState.queue = { }
		main.onFrameFuncs["TradeSetOptimiser"] = nil
		main:ClosePopup()
	end)

	-- Reopening should show the last solve, links and all, rather than a blank
	-- dialog that makes it look as though nothing was ever found
	if self.optimiserResult and self.optimiserResult.ok then
		local ok = pcall(showResult, self.optimiserResult)
		if not ok then
			self.optimiserResult = nil
		end
	end

	main.onFrameFuncs["TradeSetOptimiser"] = function()
		-- One slot search at a time, then the solve
		if not searchState.active and searchState.queue[1] then
			local job = t_remove(searchState.queue, 1)
			local entry, profile = job.entry, job.profile
			searchState.active = job
			controls.status.label = s_format("^7Searching %s ^8(%s%s)  ^8%d / %d",
				entry.slotName, job.weaponCategory and (job.weaponCategory .. ", ") or "",
				profile.label, searchState.done + 1, searchState.total)
			if entry.countLabel then
				entry.countLabel.label = "^7searching " .. profile.label .. "..."
			end
			local settings = {
				statWeights = searchState.settings.statWeights,
				budget = searchState.settings.budget,
				requiredMods = profile.requiredMods,
				weaponCategory = job.weaponCategory,
			}
			self:SearchSlotForOptimiser(entry, settings, function(errMsg, items)
				searchState.done = searchState.done + 1
				if errMsg then
					-- One profile finding nothing is normal — no item on this base
					-- carries that much resistance — and must not discard the others
					if job.first then
						t_insert(searchState.errors, entry.slotName .. ": " .. tostring(errMsg))
					end
				else
					-- Pool with what the slot's other profiles found, by listing id
					local pooled, seen = { }, { }
					if not job.first then
						for _, existing in ipairs(self.resultTbl[entry.rowIdx] or { }) do
							if existing.id and not seen[existing.id] then
								seen[existing.id] = true
								t_insert(pooled, existing)
							end
						end
					end
					for _, found in ipairs(items or { }) do
						if found.id and not seen[found.id] then
							seen[found.id] = true
							t_insert(pooled, found)
						end
					end
					self.resultTbl[entry.rowIdx] = pooled
					-- Refreshing the Trader row is a convenience, not the point of
					-- the search; a failure there must not lose the results
					pcall(function() self:UpdateControlsWithItems(entry.rowIdx) end)
				end
				local pool = #(self.resultTbl[entry.rowIdx] or { })
				if entry.countLabel then
					entry.countLabel.label = (pool > 0 and "^8" or "^1") .. pool .. " found"
				end
				searchState.active = nil
				if not searchState.queue[1] then
					refreshPools()
					if searchState.errors[1] then
						-- Every slot failing the same way produces the same message N
						-- times, which ran off the side of the window and buried the
						-- one thing worth reading. Distinct reasons only, and capped.
						local seenReason, reasons = { }, { }
						for _, entry in ipairs(searchState.errors) do
							local reason = entry:match(":%s*(.+)$") or entry
							if not seenReason[reason] then
								seenReason[reason] = true
								t_insert(reasons, reason)
							end
						end
						local shown = reasons[1]
						if #reasons > 1 then
							shown = shown .. s_format(" (and %d other reason%s)", #reasons - 1,
								#reasons == 2 and "" or "s")
						end
						if #shown > 100 then
							shown = shown:sub(1, 97) .. "..."
						end
						controls.status.label = s_format("^7%d of %d search(es) failed: ^1%s",
							#searchState.errors, searchState.total, shown)
					end
					if searchState.thenSolve then
						searchState.thenSolve = false
						searchState.startSolve()
					end
				end
			end)
		end
		if solveState.co then
			local ok, result = coroutine.resume(solveState.co)
			if not ok then
				solveState.co = nil
				controls.status.label = "^1Solve failed: " .. tostring(result)
				ConPrintf("TradeSetOptimiser error: %s", tostring(result))
			elseif coroutine.status(solveState.co) == "dead" then
				solveState.co = nil
				showResult(result or { ok = false, reason = "No result." })
			end
		end
	end

	-- Slot grid, then the settings block, then the buttons, then up to one
	-- result row per slot plus the summary line
	-- Reserving a result row per slot makes the dialog taller than a screen once
	-- flasks and abyssal sockets are counted; nobody replaces that many at once
	local popupHeight = 210 + m_ceil(#slotEntries / 2) * 22 + 156 + (m_min(#slotEntries, 9) + 2) * 22
	main:OpenPopup(820, popupHeight, "Solve Gear Set", controls)
end

-- Popup to set stat weight multipliers for sorting
function TradeQueryClass:SetStatWeights(previousSelectionList)
	previousSelectionList = previousSelectionList or {}
	local controls = { }
	local statList = { }
	local sliderController = { index = 1 }
	local popupHeight = 530

	local presetYOffset = 18
	local sliderYOffset = 46
	local listYOffset = 72
	-- account for top gap, bottom button size and gap, and a gap before buttons
	local listHeight = popupHeight - listYOffset - 30 - 10

	controls.ListControl = new("TradeStatWeightMultiplierListControl"):TradeStatWeightMultiplierListControl({ "TOPLEFT", nil, "TOPRIGHT" },
		{ -410, listYOffset, 400, listHeight }, statList, sliderController)

	for _, stat in ipairs(data.powerStatList) do
		if not stat.ignoreForItems and stat.label ~= "Name" then
			t_insert(statList, {
				label = "0      :  "..stat.label,
				stat = {
					label = stat.label,
					stat = stat.stat,
					transform = stat.transform,
					weightMult = 0,
				}
			})
		end
	end

	controls.SliderLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPRIGHT" }, {-410, sliderYOffset, 0, 16}, "^7"..statList[1].stat.label..":")
	-- assigned further down, once the preset dropdown exists
	local refreshPresets
	controls.Slider = new("SliderControl"):SliderControl({ "TOPLEFT", controls.SliderLabel, "TOPRIGHT" }, {20, 0, 150, 16}, function(value)
		if value == 0 then
			controls.SliderValue.label = "^7Disabled"
			statList[sliderController.index].stat.weightMult = 0
			statList[sliderController.index].label = s_format("%d      :  ", 0)..statList[sliderController.index].stat.label
		else
			controls.SliderValue.label = s_format("^7%.2f", 0.01 + value * 0.99)
			statList[sliderController.index].stat.weightMult = 0.01 + value * 0.99
			statList[sliderController.index].label = s_format("%.2f :  ", 0.01 + value * 0.99)..statList[sliderController.index].stat.label
		end
		if refreshPresets then
			refreshPresets()
		end
	end)
	controls.SliderValue = new("LabelControl"):LabelControl({ "TOPLEFT", controls.Slider, "TOPRIGHT" }, {20, 0, 0, 16}, "^7Disabled")
	controls.Slider.tooltip.realDraw = controls.Slider.tooltip.Draw
	controls.Slider.tooltip.Draw = function(self, x, y, width, height, viewPort)
		local sliderOffsetX = round(184 * (1 - controls.Slider.val))
		local tooltipWidth, tooltipHeight = self:GetSize()
		if main.screenW >= 1338 - sliderOffsetX then
			return controls[stat.label.."Slider"].tooltip.realDraw(self, x - 8 - sliderOffsetX, y - 4 - tooltipHeight, width, height, viewPort)
		end
		return controls.Slider.tooltip.realDraw(self, x, y, width, height, viewPort)
	end
	sliderController.SliderLabel = controls.SliderLabel
	sliderController.Slider = controls.Slider
	sliderController.SliderValue = controls.SliderValue

	-- weights of the stats currently set above 0, in power stat list order.
	-- rounded to the two decimals the list and the slider display
	local function getEditedWeights()
		local weights = { }
		for _, statTable in ipairs(statList) do
			if statTable.stat.weightMult > 0 then
				t_insert(weights, {
					label = statTable.stat.label,
					stat = statTable.stat.stat,
					transform = statTable.stat.transform,
					weightMult = round(statTable.stat.weightMult, 2),
				})
			end
		end
		return weights
	end

	local function statRowLabel(statTable)
		return statTable.stat.weightMult > 0
			and s_format("%.2f :  ", statTable.stat.weightMult)..statTable.stat.label
			or s_format("%d      :  ", 0)..statTable.stat.label
	end

	-- moves the slider row onto the stat it points at
	local function syncSliderToSelection()
		local selected = statList[sliderController.index]
		if not selected then
			return
		end
		local weightMult = selected.stat.weightMult
		controls.SliderLabel.label = "^7"..selected.stat.label..":"
		controls.Slider:SetVal(weightMult == 0 and 0 or (weightMult == 1 and 1 or weightMult - 0.01))
		-- the slider callback rewrites the entry from the knob position, so put the exact value back
		selected.stat.weightMult = weightMult
		selected.label = statRowLabel(selected)
		controls.SliderValue.label = weightMult > 0 and s_format("^7%.2f", weightMult) or "^7Disabled"
	end

	-- resets every stat to 0 and applies the given weights on top
	local function applyWeights(weights)
		for _, statTable in ipairs(statList) do
			statTable.stat.weightMult = 0
			statTable.label = statRowLabel(statTable)
		end
		for _, statBase in ipairs(weights) do
			for _, statTable in ipairs(statList) do
				if statTable.stat.stat == statBase.stat then
					statTable.stat.weightMult = statBase.weightMult
					statTable.label = statRowLabel(statTable)
				end
			end
		end
		syncSliderToSelection()
		refreshPresets()
	end

	-- preset selection and management
	controls.presetLabel = new("LabelControl"):LabelControl({ "TOPLEFT", nil, "TOPRIGHT" }, {-410, presetYOffset + 2, 0, 16}, "^7Preset:")
	controls.preset = new("DropDownControl"):DropDownControl({ "TOPLEFT", controls.presetLabel, "TOPRIGHT" }, {6, -2, 172, 20}, { }, function(index, value)
		if value.preset then
			applyWeights(value.preset.weights)
		end
	end)
	controls.preset.enableDroppedWidth = true
	controls.preset.tooltipText = "Loads a saved set of stat weights.\nThe weights are only applied to your searches once you hit Save."
	refreshPresets = function()
		local list, selIndex = self:BuildWeightPresetList(getEditedWeights())
		controls.preset:SetList(list)
		controls.preset.selIndex = selIndex
	end
	controls.presetSave = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls.preset, "TOPRIGHT" }, {6, 0, 86, 20}, "Save As...", function()
		local weights = getEditedWeights()
		if #weights == 0 then
			main:OpenMessagePopup("Stat Weight Presets", "Set at least one stat weight above 0\nbefore saving it as a preset.")
			return
		end
		self:SaveWeightPresetPopup(weights, function()
			refreshPresets()
		end)
	end)
	controls.presetSave.tooltipText = "Saves the weights set below as a named preset, available to all builds."
	controls.presetDelete = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls.presetSave, "TOPRIGHT" }, {6, 0, 70, 20}, "Delete", function()
		local selValue = controls.preset:GetSelValue()
		if not selValue or not selValue.preset then
			return
		end
		local name = selValue.preset.name
		main:OpenConfirmPopup("Delete Preset", "Delete the stat weight preset '"..name.."'?", "Delete", function()
			self:DeleteWeightPreset(name)
			refreshPresets()
		end)
	end)
	controls.presetDelete.enabled = function()
		local selValue = controls.preset:GetSelValue()
		return (selValue and selValue.preset and not selValue.preset.builtin) == true
	end
	controls.presetDelete.tooltipText = "Removes the selected preset. Built-in presets cannot be removed."

	applyWeights(self.statSortSelectionList)

	controls.finalise = new("ButtonControl"):ButtonControl({ "BOTTOM", nil, "BOTTOM" }, {-90, -10, 80, 20}, "Save", function()
		main:ClosePopup()

		-- used in ItemsTab to save to xml under TradeSearchWeights node
		local statSortSelectionList = getEditedWeights()
		if (#statSortSelectionList) > 0 then
			--THIS SHOULD REALLY GIVE A WARNING NOT JUST USE PREVIOUS
			self.statSortSelectionList = statSortSelectionList
		end
		self:RefreshWeightPresetControl()
		for row_idx in pairs(self.resultTbl) do
			self:UpdateControlsWithItems(row_idx)
		end
    end)
	controls.cancel = new("ButtonControl"):ButtonControl({ "BOTTOM", nil, "BOTTOM" }, { 0, -10, 80, 20 }, "Cancel", function()
		if previousSelectionList and #previousSelectionList > 0 then
			self.statSortSelectionList = copyTable(previousSelectionList, true)
		end
		self:RefreshWeightPresetControl()
		main:ClosePopup()
	end)
	controls.reset = new("ButtonControl"):ButtonControl({ "BOTTOM", nil, "BOTTOM" }, { 90, -10, 80, 20 }, "Reset", function()
		local previousSelection = { }
		if isSameAsDefaultList(self.statSortSelectionList) then
			previousSelection = copyTable(previousSelectionList, true)
		else
			previousSelection = copyTable(self.statSortSelectionList, true) -- this is so we can revert if user hits Cancel after Reset
		end
		self.statSortSelectionList = { }
		initStatSortSelectionList(self.statSortSelectionList)
		main:ClosePopup()
		self:SetStatWeights(previousSelection)
	end)
	main:OpenPopup(420, popupHeight, "Stat Weight Multipliers", controls)
end

-- Method to set the notice message in upper right of PoB Trader pane
function TradeQueryClass:SetNotice(notice_control, msg)
	if msg:find("No Matching Results") then
		msg = colorCodes.WARNING .. msg
	elseif msg:find("Error") then
		msg = colorCodes.NEGATIVE .. msg
	end
	notice_control.label = msg
end

-- Method to reduce the full output to only the values that were 'weighted'
function TradeQueryClass:ReduceOutput(output)
	local smallOutput = {}
	for _, statTable in ipairs(self.statSortSelectionList) do
		smallOutput[statTable.stat] = data.powerStatList.GetFromOutput(output, statTable, true)
		if statTable.stat == "FullDPS" and not output.FullDPS then
			smallOutput.TotalDPS = data.powerStatList.GetFromOutput(output, { stat = "TotalDPS" })
			smallOutput.TotalDotDPS = data.powerStatList.GetFromOutput(output, { stat = "TotalDotDPS" })
			smallOutput.CombinedDPS = data.powerStatList.GetFromOutput(output, { stat = "CombinedDPS" })
		end
	end
	return smallOutput
end

-- Method to evaluate a result by getting it's output and weight
function TradeQueryClass:GetResultEvaluation(row_idx, result_index, calcFunc, baseOutput)
	local result = self.resultTbl[row_idx][result_index]
	if not calcFunc then -- Always evaluate when calcFunc is given
		calcFunc, baseOutput = self.itemsTab.build.calcsTab:GetMiscCalculator()
		local onlyWeightedBaseOutput = self:ReduceOutput(baseOutput)
		if not self.onlyWeightedBaseOutput[row_idx] then
			self.onlyWeightedBaseOutput[row_idx] = { }
		end
		if not self.lastComparedWeightList[row_idx] then
			self.lastComparedWeightList[row_idx] = { }
		end
		-- If the interesting stats are the same (the build hasn't changed) and result has already been evaluated, then just return that
		if result.evaluation and tableDeepEquals(onlyWeightedBaseOutput, self.onlyWeightedBaseOutput[row_idx][result_index]) and tableDeepEquals(self.statSortSelectionList, self.lastComparedWeightList[row_idx][result_index]) then
			return result.evaluation
		end
		self.onlyWeightedBaseOutput[row_idx][result_index] = onlyWeightedBaseOutput
		self.lastComparedWeightList[row_idx][result_index] = self.statSortSelectionList
	end
	local slotTbl = self.slotTables[row_idx]
	local jewelNodeId = slotTbl.nodeId or slotTbl.selectedJewelNodeId
	if slotTbl.slotName == "Megalomaniac" then
		local addedNodes = {}
		for nodeName in (result.item_string.."\r\n"):gmatch("1 Added Passive Skill is (.-)\r?\n") do
			t_insert(addedNodes, self.itemsTab.build.spec.tree.clusterNodeMap[nodeName])
		end
		local output12  = self:ReduceOutput(calcFunc({ addNodes = { [addedNodes[1]] = true, [addedNodes[2]] = true } }))
		local output13  = self:ReduceOutput(calcFunc({ addNodes = { [addedNodes[1]] = true, [addedNodes[3]] = true } }))
		local output23  = self:ReduceOutput(calcFunc({ addNodes = { [addedNodes[2]] = true, [addedNodes[3]] = true } }))
		local output123 = self:ReduceOutput(calcFunc({ addNodes = { [addedNodes[1]] = true, [addedNodes[2]] = true, [addedNodes[3]] = true } }))
		-- Sometimes the third node is as powerful as a wet noodle, so use weight per point spent, including the jewel socket
		local weight12  = self.tradeQueryGenerator.WeightedRatioOutputs(baseOutput, output12,  self.statSortSelectionList) / 4
		local weight13  = self.tradeQueryGenerator.WeightedRatioOutputs(baseOutput, output13,  self.statSortSelectionList) / 4
		local weight23  = self.tradeQueryGenerator.WeightedRatioOutputs(baseOutput, output23,  self.statSortSelectionList) / 4
		local weight123 = self.tradeQueryGenerator.WeightedRatioOutputs(baseOutput, output123, self.statSortSelectionList) / 5
		result.evaluation = {
			{ output = output12,  weight = weight12,  DNs = { addedNodes[1].dn, addedNodes[2].dn } },
			{ output = output13,  weight = weight13,  DNs = { addedNodes[1].dn, addedNodes[3].dn } },
			{ output = output23,  weight = weight23,  DNs = { addedNodes[2].dn, addedNodes[3].dn } },
			{ output = output123, weight = weight123, DNs = { addedNodes[1].dn, addedNodes[2].dn, addedNodes[3].dn } },
		}
		table.sort(result.evaluation, function(a, b) return a.weight > b.weight end)
	else
		if slotTbl.slotName == "Pearl of Tsoatha" and not slotTbl.selectedSlotName then
			for index = 1, 3 do
				local ringSlot = self.itemsTab.slots["Ring " .. index]
				if ringSlot and ringSlot.shown() then
					slotTbl.selectedSlotName = ringSlot.slotName
					break
				end
			end
		end
		local slotName = jewelNodeId and "Jewel " .. tostring(jewelNodeId) or slotTbl.selectedSlotName or slotTbl.slotName
		local item = new("Item"):Item(result.item_string)

		local output = self:ReduceOutput(calcFunc({ repSlotName = slotName, repItem = item }))
		local weight = self.tradeQueryGenerator.WeightedRatioOutputs(baseOutput, output, self.statSortSelectionList)
		result.evaluation = {{ output = output, weight = weight }}
	end
	return result.evaluation
end

-- Method to update controls after a search is completed
function TradeQueryClass:UpdateDropdownList(row_idx)
	local dropdownLabels = {}

	if not self.resultTbl[row_idx] then return end

	for result_index = 1, #self.resultTbl[row_idx] do

		local pb_index = self.sortedResultTbl[row_idx][result_index].index
		local result = self.resultTbl[row_idx][pb_index]
		local price = string.format(" %s(%d %s)", colorCodes["CURRENCY"], result.amount, result.currency)
		local item = new("Item"):Item(result.item_string)
		table.insert(dropdownLabels, colorCodes[item.rarity] .. item.name .. price)
	end
	self.controls["resultDropdown".. row_idx].selIndex = 1
	self.controls["resultDropdown".. row_idx]:SetList(dropdownLabels)
end
function TradeQueryClass:ResetResultRow(rowIdx)
	self.itemIndexTbl[rowIdx] = nil
	self.sortedResultTbl[rowIdx] = nil
	self.resultTbl[rowIdx] = nil
	self.totalPrice[rowIdx] = nil
	self:UpdateDropdownList(rowIdx)
	self.controls.fullPrice.label = "^7Total Price: " .. self:GetTotalPriceString()
end
function TradeQueryClass:UpdateControlsWithItems(row_idx)
	local sortMode = self.itemSortSelectionList[self.pbItemSortSelectionIndex]
	local sortedItems, errMsg = self:SortFetchResults(row_idx, sortMode)
	if errMsg == "MissingConversionRates" then
		self:SetNotice(self.controls.pbNotice, "^4Currency rates unavailable. Falling back to Stat Value sort.")
		sortedItems, errMsg = self:SortFetchResults(row_idx, self.sortModes.StatValue)
	elseif errMsg then
		self:SetNotice(self.controls.pbNotice, "Error: " .. errMsg)
		return
	else
		self:SetNotice(self.controls.pbNotice, "")
	end

	self.sortedResultTbl[row_idx] = sortedItems
	if not sortedItems[1] then
		self:ResetResultRow(row_idx)
		self:SetNotice(self.controls.pbNotice, "^4No compatible items found for this slot.")
		return
	end
	local pb_index = sortedItems[1].index
	self.itemIndexTbl[row_idx] = pb_index
	self.controls["priceButton".. row_idx].tooltipText = "Sorted by " .. self.itemSortSelectionList[self.pbItemSortSelectionIndex]
	self.totalPrice[row_idx] = {
		currency = self.resultTbl[row_idx][pb_index].currency,
		amount = self.resultTbl[row_idx][pb_index].amount,
	}
	self.controls.fullPrice.label = "^7Total Price: " .. self:GetTotalPriceString()
	self:UpdateDropdownList(row_idx)
end

-- Method to set the current result return in the pane based of an index
function TradeQueryClass:SetFetchResultReturn(row_idx, index)
	if self.resultTbl[row_idx] and self.resultTbl[row_idx][index] then
		self.totalPrice[row_idx] = {
			currency = self.resultTbl[row_idx][index].currency,
			amount = self.resultTbl[row_idx][index].amount,
		}
		self.controls.fullPrice.label = "^7Total Price: " .. self:GetTotalPriceString()
	end
end

-- Method to sort the fetched results
function TradeQueryClass:SortFetchResults(row_idx, mode)
	local calcFunc, baseOutput
	local function getResultWeight(result_index)
		if not calcFunc then
			calcFunc, baseOutput = self.itemsTab.build.calcsTab:GetMiscCalculator()
		end
		local sum = 0
		for _, eval in ipairs(self:GetResultEvaluation(row_idx, result_index)) do
			sum = sum + eval.weight
		end
		return sum
	end
	--- @return table<integer, number>?
	local function getPriceTable()
		--- @type table<integer, number>
		local divPrices = {}
		for idx, item in ipairs(self.resultTbl[row_idx]) do
			if item.currency and item.amount then
				local divs = self:ConvertCurrencyToDivs(item.currency, item.amount)
				if not divs then
					return nil
				end
				divPrices[idx] = divs
			else return nil end
		end
		return divPrices
	end
	local newTbl = {}
	if mode == self.sortModes.Weight then
		for index, _ in pairs(self.resultTbl[row_idx]) do
			t_insert(newTbl, { outputAttr = index, index = index })
		end
		return newTbl
	elseif mode == self.sortModes.StatValue  then
		for result_index = 1, #self.resultTbl[row_idx] do
			t_insert(newTbl, { outputAttr = getResultWeight(result_index), index = result_index })
		end
		table.sort(newTbl, function(a,b) return a.outputAttr > b.outputAttr end)
	elseif mode == self.sortModes.StatValuePrice then
		local priceTable = getPriceTable()
		if priceTable == nil then
			return nil, "MissingConversionRates"
		end
		for result_index = 1, #self.resultTbl[row_idx] do
			-- generally, because we are filtering our results to only the top
			-- contenders, we will end up with a small spread of result weights.
			-- this is however not true for prices as *decent* items might start
			-- at a couple of div while perfect items are worth hundreds of
			-- divs. I think the best option here is weight - k * log10(price)
			-- to prioritise good items while only slightly punishing high
			-- prices. another option would be weight / log10(price), but it
			-- still seems to overrate very cheap items that are bad

			-- scaling factor for price
			local k = 0.1
			t_insert(newTbl,
				{ outputAttr = getResultWeight(result_index) - k * math.log(priceTable[result_index], 10), index =
				result_index })
		end
		table.sort(newTbl, function(a,b) return a.outputAttr > b.outputAttr end)
	elseif mode == self.sortModes.Price then
		local priceTable = getPriceTable()
		if priceTable == nil then
			return nil, "MissingConversionRates"
		end
		for result_index, price in pairs(priceTable) do
			t_insert(newTbl, { outputAttr = price, index = result_index })
		end
		table.sort(newTbl, function(a,b) return a.outputAttr < b.outputAttr end)
	else
		return nil, "InvalidSort"
	end
	return newTbl
end

-- ensure we only take in items that parse properly to avoid crash issues and fit in the
-- provided slotName
---@param itemEntries table
---@param slotName string
function TradeQueryClass:FilterToSafeItems(itemEntries, slotName)
	local itemsSafe = {}
	for _, entry in ipairs(itemEntries) do
		local item = new("Item"):Item(entry.item_string)
		if item.base and ((not slotName) or self.itemsTab:IsItemValidForSlot(item, slotName)) then
			t_insert(itemsSafe, entry)
		end
	end
	return itemsSafe
end
-- Method to generate pane elements for each item slot
function TradeQueryClass:PriceItemRowDisplay(row_idx, top_pane_alignment_ref, row_vertical_padding, row_height)
	local controls = self.controls
	local slotTbl = self.slotTables[row_idx]
	local activeSlotRef = slotTbl.nodeId and self.itemsTab.activeItemSet[slotTbl.nodeId] or self.itemsTab.activeItemSet[slotTbl.slotName]
	local nodeId = slotTbl.nodeId or slotTbl.selectedJewelNodeId
	local activeSlot = nodeId and self.itemsTab.sockets[nodeId] or
		slotTbl.slotName and (self.itemsTab.slots[slotTbl.slotName] or
			-- fullName for Abyssal Sockets
			slotTbl.fullName and self.itemsTab.slots[slotTbl.fullName])
	local function getSelectedSlot()
		local selectedNodeId = slotTbl.nodeId or slotTbl.selectedJewelNodeId
		return selectedNodeId and self.itemsTab.sockets[selectedNodeId] or activeSlot
	end
	local nameColor = slotTbl.unique and colorCodes.UNIQUE or "^7"
	controls["name" .. row_idx] = new("LabelControl"):LabelControl(top_pane_alignment_ref, { 0, row_idx * (row_height + row_vertical_padding), 135, row_height - 4 }, nameColor .. slotTbl.slotName)
	controls["bestButton" .. row_idx] = new("ButtonControl"):ButtonControl({ "LEFT", controls["name" .. row_idx], "LEFT" }, { 135 + 8, 0, 80, row_height }, "Find best", function()
		self.tradeQueryGenerator:RequestQuery(activeSlot, { slotTbl = slotTbl, controls = controls, row_idx = row_idx }, self.statSortSelectionList, function(context, query, errMsg)
			if errMsg then
				self:SetNotice(context.controls.pbNotice, colorCodes.NEGATIVE .. errMsg)
				return
			else
				self:SetNotice(context.controls.pbNotice, "")
			end
			if main.api.authToken == nil then
				local url = self.tradeQueryRequests:buildUrl(self.hostName .. "trade/search", self.pbRealm, self.pbLeague)
				url = url .. "?q=" .. urlEncode(query)
				controls["uri"..context.row_idx]:SetText(url, true)
				return
			end
			context.controls["priceButton"..context.row_idx].label = "Searching..."
			self.lastQueries[row_idx] = query
			self.tradeQueryRequests:SearchWithQueryWeightAdjusted(self.pbRealm, self.pbLeague, query,
				function(items, errMsg)
					if errMsg then
						self:SetNotice(context.controls.pbNotice, colorCodes.NEGATIVE .. errMsg)
						context.controls["priceButton"..context.row_idx].label =  "Price Item"
						return
					else
						self:SetNotice(context.controls.pbNotice, "")
					end

					local selectedSlot = getSelectedSlot()
					local itemsSafe = self:FilterToSafeItems(items, selectedSlot and selectedSlot.slotName)
					-- replace eldritch mods or enchants if the user requested
					-- so in TradeQueryGenerator
					for i, _ in ipairs(itemsSafe) do
						local item = new("Item"):Item(itemsSafe[i].item_string)
						-- assume the user will add quality if they buy the item
						item:NormaliseQuality()
						if self.tradeQueryGenerator.lastIncludeEldritch == "Copy Current" or
							self.tradeQueryGenerator.lastCopyEnchantMode == "Copy Current" then
							self.itemsTab:CopyAnointsAndEldritchImplicits(item, true, true, context.slotTbl.slotName)
						elseif self.tradeQueryGenerator.lastIncludeEldritch == "Remove" then
							if item.tangle or item.cleansing then
								item.implicitModLines = {}
							end
						elseif self.tradeQueryGenerator.lastCopyEnchantMode == "Remove" then
							item.enchantModLines = {}
						end
						itemsSafe[i].item_string = item:BuildRaw()
					end

					self.resultTbl[context.row_idx] = itemsSafe
					self:UpdateControlsWithItems(context.row_idx)
					context.controls["priceButton"..context.row_idx].label =  "Price Item"
				end,
				{
					callbackQueryId = function(queryId)
						local url = self.tradeQueryRequests:buildUrl(self.hostName .. "trade/search", self.pbRealm, self.pbLeague, queryId)
						controls["uri"..context.row_idx]:SetText(url, true)
					end
				}
			)
		end)
	end)
	controls["bestButton"..row_idx].shown = function() return not self.resultTbl[row_idx] end
	controls["bestButton"..row_idx].enabled = function() return self.pbLeague end
	controls["bestButton"..row_idx].tooltipText = [[Creates a weighted search to find the highest Stat Value items for this slot.
Note that even if you are authenticated, you can click this button again to show the search link.
If you have additional requirements that the trade tool doesn't cover (e.g. Adorned Magic jewels),
you can add them, copy the link here, and press "Price Item" to evaluate the items.]]
	controls["bestButton" .. row_idx].onHover = function()
		local button = controls["bestButton" .. row_idx]
		local x, y = button:GetPos()
		local buttonWidth, _ = button:GetSize()
		local nodeId = slotTbl.nodeId
		if not nodeId then return end
		local boxSize = 250
		-- anchor bottom to top of button
		local viewerY = y - boxSize - 4
		local viewerX = x - boxSize / 2 + buttonWidth / 2
		itemSlotHelper.DrawViewer(self.itemsTab, nodeId, viewerX, viewerY, boxSize, boxSize)
	end
	local pbURL
	controls["uri"..row_idx] = new("EditControl"):EditControl({ "TOPLEFT", controls["bestButton"..row_idx], "TOPRIGHT"}, {8, 0, 514, row_height}, nil, nil, "^%C\t\n", nil, function(buf)
		local subpath = buf:match(self.hostNamePattern .. "trade/search/(.+)$") or ""
		local paths = {}
		for path in subpath:gmatch("[^/]+") do
			table.insert(paths, path)
		end
		controls["uri"..row_idx].validURL = #paths == 2 or #paths == 3
		if controls["uri"..row_idx].validURL then
			pbURL = buf
		elseif buf == "" then
			pbURL = ""
		end
		if not activeSlotRef and slotTbl.nodeId then
			self.itemsTab.activeItemSet[slotTbl.nodeId] = { pbURL = "" }
			activeSlotRef = self.itemsTab.activeItemSet[slotTbl.nodeId]
		end
	end, nil)
	controls["uri"..row_idx]:SetPlaceholder("Paste trade URL here...")
	if pbURL and pbURL ~= "" then
		controls["uri"..row_idx]:SetText(pbURL, true)
	end
	controls["uri"..row_idx].tooltipFunc = function(tooltip)
		tooltip:Clear()
		if controls["uri" .. row_idx].buf:find('^' .. self.hostNamePattern .. 'trade/search/') ~= nil then
			tooltip:AddLine(16, "Control + click to open in web-browser")
		end
	end
	controls["priceButton"..row_idx] = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls["uri"..row_idx], "TOPRIGHT"}, {8, 0, 100, row_height}, "Price Item",
		function()
			controls["priceButton"..row_idx].label = "Searching..."
			local url = controls["uri" .. row_idx].buf
			if not url:find("^https://") then
				url = "https://" .. url
			end
			self.tradeQueryRequests:SearchWithURL(url, function(items, errMsg, query)
				if errMsg then
					self:SetNotice(controls.pbNotice, "Error: " .. errMsg)
				else
					self:SetNotice(controls.pbNotice, "")
					self.lastQueries[row_idx] = query
					local selectedSlot = getSelectedSlot()
					local itemsSafe = self:FilterToSafeItems(items, selectedSlot and selectedSlot.slotName)
					self.resultTbl[row_idx] = itemsSafe
					self:UpdateControlsWithItems(row_idx)
				end
				controls["priceButton"..row_idx].label = "Price Item"
			end)
		end)
	local jewelUniques = {
		Megalomaniac = true,
		["Watcher's Eye"] = true,
	}
	controls["priceButton"..row_idx].enabled = function()
		local isAuthorized = main.api.authToken ~= nil
		local validURL = controls["uri"..row_idx].validURL
		local isSearching = controls["priceButton"..row_idx].label == "Searching..."
		local requiresJewelSlot = not slotTbl.unique or jewelUniques[slotTbl.slotName]
		local selectedJewelSlot = slotTbl.selectedJewelNodeId and self.itemsTab.sockets[slotTbl.selectedJewelNodeId]
		local hasRequiredJewelSlot = not slotTbl.unique or selectedJewelSlot and not selectedJewelSlot.inactive
		return isAuthorized and validURL and not isSearching and (hasRequiredJewelSlot or not requiresJewelSlot)
	end
	controls["priceButton"..row_idx].tooltipFunc = function(tooltip)
		tooltip:Clear()
		if not main.api.authToken then
			tooltip:AddLine(16, "You must log in to use the search feature")
		elseif not controls["uri"..row_idx].validURL then
			tooltip:AddLine(16, "Enter a valid trade URL")
		elseif jewelUniques[slotTbl.slotName] and (not slotTbl.selectedJewelNodeId or not self.itemsTab.sockets[slotTbl.selectedJewelNodeId] or self.itemsTab.sockets[slotTbl.selectedJewelNodeId].inactive) then
			tooltip:AddLine(16, "Requires an active Jewel Socket")
		end
	end
	local clampItemIndex = function(index)
		return m_min(m_max(index or 1, 1), self.sortedResultTbl[row_idx] and #self.sortedResultTbl[row_idx] or 1)
	end
	controls["changeButton" .. row_idx] = new("ButtonControl"):ButtonControl({ "LEFT", controls["name" .. row_idx], "LEFT" }, { 135 + 8, 0, 80, row_height }, "<< Search", function()
		self:ResetResultRow(row_idx)
	end)
	controls["changeButton"..row_idx].shown = function() return self.resultTbl[row_idx] end
	controls["resultDropdown" .. row_idx] = new("DropDownControl"):DropDownControl({ "TOPLEFT", controls["changeButton" .. row_idx], "TOPRIGHT" }, { 8, 0, 351, row_height }, {}, function(index)
		self.itemIndexTbl[row_idx] = self.sortedResultTbl[row_idx][index].index
		self:SetFetchResultReturn(row_idx, self.itemIndexTbl[row_idx])
	end)
	self:UpdateDropdownList(row_idx)
	local function addMegalomaniacCompareToTooltipIfApplicable(tooltip, result_index)
		if slotTbl.slotName ~= "Megalomaniac" then
			return
		end
		for _, evaluationEntry in ipairs(self:GetResultEvaluation(row_idx, result_index)) do
			tooltip:AddSeparator(10)
			local nodeDNs = evaluationEntry.DNs
			local nodeCombo = nodeDNs[1]
			for i = 2, #nodeDNs do
				nodeCombo = nodeCombo .. " ^8+^7 " .. nodeDNs[i]
			end
			self.itemsTab.build:AddStatComparesToTooltip(tooltip, self.onlyWeightedBaseOutput[row_idx][result_index], evaluationEntry.output, "^8Allocating ^7"..nodeCombo.."^8 will give You:", #nodeDNs + 2)
		end
	end
	controls["resultDropdown"..row_idx].tooltipFunc = function(tooltip, dropdown_mode, dropdown_index, dropdown_display_string)
		local sortedRow = self.sortedResultTbl[row_idx]
		if not sortedRow or not sortedRow[dropdown_index] then
			return
		end
		local pb_index = sortedRow[dropdown_index].index
		local result = self.resultTbl[row_idx] and self.resultTbl[row_idx][pb_index]
		if not result then
			return
		end
		local item = new("Item"):Item(result.item_string)
		tooltip:Clear()
		local tooltipSlot = slotTbl.selectedJewelNodeId and self.itemsTab.sockets[slotTbl.selectedJewelNodeId] or activeSlot
		self.itemsTab:AddItemTooltip(tooltip, item, tooltipSlot)
		addMegalomaniacCompareToTooltipIfApplicable(tooltip, pb_index)
		tooltip:AddSeparator(10)
		tooltip:AddLine(16, string.format("^7Price: %s %s", result.amount, result.currency))
	end
	controls["importButton"..row_idx] = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls["resultDropdown"..row_idx], "TOPRIGHT"}, {8, 0, 100, row_height}, "Import Item", function()
		self.itemsTab:CreateDisplayItemFromRaw(self.resultTbl[row_idx][self.itemIndexTbl[row_idx]].item_string)
		local item = self.itemsTab.displayItem
		-- pass "true" to not auto equip it as we will have our own logic
		self.itemsTab:AddDisplayItem(true)
		-- Autoequip it
		local jewelNodeId = slotTbl.nodeId or slotTbl.selectedJewelNodeId
		local slot = jewelNodeId and self.itemsTab.sockets[jewelNodeId] or self.itemsTab.slots[slotTbl.slotName]
		if slot and (jewelNodeId or slotTbl.slotName == slot.label) and slot:IsShown() and self.itemsTab:IsItemValidForSlot(item, slot.slotName) then
			slot:SetSelItemId(item.id)
			self.itemsTab:PopulateSlots()
			self.itemsTab:AddUndoState()
			self.itemsTab.build.buildFlag = true
		end
	end)
	controls["importButton"..row_idx].tooltipFunc = function(tooltip)
		tooltip:Clear()
		local selected_result_index = self.itemIndexTbl[row_idx]
		local item_string = self.resultTbl[row_idx][selected_result_index].item_string
		if selected_result_index and item_string then
			local item = new("Item"):Item(item_string)
			local tooltipSlot = slotTbl.selectedJewelNodeId and self.itemsTab.sockets[slotTbl.selectedJewelNodeId] or activeSlot
			self.itemsTab:AddItemTooltip(tooltip, item, tooltipSlot, true)
			addMegalomaniacCompareToTooltipIfApplicable(tooltip, selected_result_index)
		end
	end
	controls["importButton"..row_idx].enabled = function()
		return self.itemIndexTbl[row_idx] and self.resultTbl[row_idx][self.itemIndexTbl[row_idx]].item_string ~= nil
	end
	-- Whisper so we can copy to clipboard
	controls["whisperButton" .. row_idx] = new("ButtonControl"):ButtonControl({ "TOPLEFT", controls["importButton" .. row_idx], "TOPRIGHT" }, { 8, 0, 155, row_height }, function()
			local itemResult = self.itemIndexTbl[row_idx] and self.resultTbl[row_idx][self.itemIndexTbl[row_idx]]

			if not itemResult then return "" end

			local price = self.totalPrice[row_idx] and
				self.totalPrice[row_idx].amount .. " " .. self.totalPrice[row_idx].currency

			-- we also check the price type so we can prefer instant buyout over
			-- whisper
			if itemResult.whisper and (itemResult.priceType ~= "~b/o") then
				return price and "Whisper for " .. price or "Whisper"
			else
				return price and "Search for " .. price or "Search"
			end

		end, function()
			local itemResult = self.itemIndexTbl[row_idx] and self.resultTbl[row_idx][self.itemIndexTbl[row_idx]]
			if  itemResult.whisper and (itemResult.priceType ~= "~b/o") then
				Copy(itemResult.whisper)
			else
				local exactQuery = dkjson.decode(self.lastQueries[row_idx])
				-- use trade sum to get the specific item. both min and max
				-- weight on site uses floats but only shows integer in the api
				-- e.g. weight of 172.3 shows up as 172 in the api
				exactQuery.query.stats[1].value = { min = floor(itemResult.weight, 1) - 1, max = round(itemResult.weight, 1) + 1 }
				-- also apply trader name. this should make false positives
				-- extremely unlikely. this doesn't seem to take up a filter slot
				exactQuery.query.filters = exactQuery.query.filters or { }
				exactQuery.query.filters.trade_filters = exactQuery.query.filters.trade_filters or { filters = { } }
				exactQuery.query.filters.trade_filters.filters = exactQuery.query.filters.trade_filters.filters or { }
				exactQuery.query.filters.trade_filters.filters.account = { input = itemResult.trader }

				local exactQueryStr = dkjson.encode(exactQuery)

				local encodedUrl = s_format("https://www.pathofexile.com/trade/search/%s?q=%s", self.pbLeague, urlEncode(exactQueryStr))

				Copy(encodedUrl)
				OpenURL(encodedUrl)
			end
		end)

	controls["whisperButton" .. row_idx].tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip.center = true
		local itemResult = self.itemIndexTbl[row_idx] and self.resultTbl[row_idx][self.itemIndexTbl[row_idx]]
		local text = itemResult.whisper and "Copies the item purchase whisper to the clipboard" or
			"Opens the search page to show the item"
		tooltip:AddLine(16, text)
	end
end

-- Method to update the Total Price string sum of all items
function TradeQueryClass:GetTotalPriceString()
	local text = ""
	-- sum up prices
	local prices = {}
	for _, entry in pairs(self.totalPrice) do
		if prices[entry.currency] then
			prices[entry.currency] = prices[entry.currency] + entry.amount
		else
			prices[entry.currency] = entry.amount
		end
	end

	-- try to sort by the value of each currency, i.e. 1 mirror > 9999 div, 1 chaos > 123 ex
	-- if currency data isn't available, just sort by currency name
	local currencies = {}
	for currency, _ in pairs(prices) do
		table.insert(currencies, currency)
	end
	local currencyMap = self.pbCurrencyConversion[self.pbRealm] and
		self.pbCurrencyConversion[self.pbRealm][self.pbLeague]
		or {}
	table.sort(currencies, function(a, b)
		if currencyMap[a] and currencyMap[b] then
			return currencyMap[a] > currencyMap[b]
		else
			return a > b
		end
	end)
	for _, currency in ipairs(currencies) do
		local value = prices[currency]
		text = text .. tostring(value) .. " " .. currency .. ", "
	end
	if text ~= "" then
		text = text:sub(1, -3)
	end
	return text
end

-- Method to update realms and leagues
function TradeQueryClass:UpdateRealms()
	local function setRealmDropList()
		self.realmDropList = {}
		for realm, _ in pairs(self.realmIds) do
			-- place PC as the first entry
			if realm == "PC" then
				t_insert(self.realmDropList, 1, realm)
			else
				t_insert(self.realmDropList, realm)
			end
		end
		self.controls.realm:SetList(self.realmDropList)
		-- invalidate selIndex to trigger select function call in the SetSel
		-- DropDownControl doesn't check if the inner list has changed so selecting the first item doesn't count as an update after list refresh
		self.controls.realm.selIndex = nil
		self.controls.realm:SetSel(self.pbRealmIndex)
	end

	-- use trade leagues api to get trade leagues including private leagues is valid.
	self.allLeagues = {}
	for _, realmId in pairs (self.realmIds) do
		self.tradeQueryRequests:FetchLeagues(realmId, function(leagues, errMsg)
			if errMsg then
				self:SetNotice(self.controls.pbNotice, "Using Fallback Error while fetching league list: "..errMsg)
			end
			for _, league in ipairs(leagues) do
				if not self.allLeagues[realmId] then self.allLeagues[realmId] = {} end
				t_insert(self.allLeagues[realmId], league)
			end
			setRealmDropList()

		end)
	end

	-- perform a generic search to make sure the authorization is valid.
	self.tradeQueryRequests:PerformSearch("pc", "Standard", [[{"query":{"status":{"option":"online"},"stats":[{"type":"and","filters":[]}]},"sort":{"price":"asc"}}]], function(response, errMsg)
		if errMsg then
			-- a 403 here likely means that the user has an outdated scope
			if errMsg == "Response code: 403" then
				main.api:ResetDetails()
				errMsg = errMsg .. "\nPlease re-authenticate"
			end
			self:SetNotice(self.controls.pbNotice, "Error: " .. tostring(errMsg))
		end
	end)
end
