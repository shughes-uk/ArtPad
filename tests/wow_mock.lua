-- Minimal World of Warcraft API mock: just enough to load ArtPad and its libraries headlessly.
-- One Lua state per simulated client. The Python harness drives time, events and the
-- "server" that routes addon messages between clients.

local CLIENT = CLIENT -- { name, guild = bool, guildRank, group = nil|"party"|"raid", groupMembers = {...} }

-- WoW's xpcall forwards extra arguments; Lua 5.1's doesn't.
local _xpcall = xpcall
xpcall = function(f, h, ...)
	local args, n = { ... }, select("#", ...)
	return _xpcall(function() return f(unpack(args, 1, n)) end, h)
end

local function noop() end

-- [[ Frames / regions ]]
ALL_FRAMES = {}
local Obj = {}
local methods = {}
Obj.__index = function(t, k)
	local m = methods[k]
	if m then return m end
	-- Unknown widget methods (CamelCase) are harmless no-ops; plain fields stay nil like in WoW.
	if type(k) == "string" and k:match("^%u") then return noop end
	return nil
end

local function new(kind, parent)
	local o = setmetatable({
		_kind = kind, _shown = true, _scripts = {}, _scale = 1, _w = 100, _h = 20,
		_left = 0, _bottom = 0, _alpha = 1, _parent = parent, _events = {},
	}, Obj)
	return o
end

function methods:GetObjectType() return self._kind end
function methods:IsObjectType(t) return self._kind == t end
function methods:CreateTexture() return new("Texture", self) end
function methods:CreateLine() local l = new("Line", self); l._shown = true; return l end
function methods:CreateFontString(_, _, template)
	local fs = new("FontString", self)
	fs._hasFont = template ~= nil -- templates provide a font
	return fs
end
function methods:SetScript(k, f) self._scripts[k] = f end
function methods:GetScript(k) return self._scripts[k] end
function methods:HookScript(k, f)
	local old = self._scripts[k]
	self._scripts[k] = function(...) if old then old(...) end; return f(...) end
end
function methods:Show()
	if not self._shown then
		self._shown = true
		if self._scripts.OnShow then self._scripts.OnShow(self) end
	end
end
function methods:Hide()
	if self._shown then
		self._shown = false
		if self._scripts.OnHide then self._scripts.OnHide(self) end
	end
end
function methods:SetTexture(t) self._texture = t end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self._shown end
function methods:IsVisible()
	local f = self
	while f do
		if not f._shown then return false end
		f = rawget(f, "_parent")
	end
	return true
end
function methods:GetParent() return self._parent end
function methods:SetScale(s) self._scale = s end
function methods:GetScale() return self._scale end
function methods:GetEffectiveScale() return self._scale end
function methods:SetAlpha(a) self._alpha = a end
function methods:GetAlpha() return self._alpha end
function methods:GetEffectiveAlpha()
	local a, f = 1, self
	while f do
		a = a * (rawget(f, "_alpha") or 1)
		f = rawget(f, "_parent")
	end
	return a
end
function methods:SetPoint(...)
	local args = { ... }
	-- Track BOTTOMLEFT anchors with numeric offsets so GetLeft/GetBottom are meaningful.
	if args[1] == "BOTTOMLEFT" and type(args[2]) == "number" then
		self._left, self._bottom = args[2], args[3]
	elseif args[1] == "BOTTOMLEFT" and args[3] == "BOTTOMLEFT" and type(args[4]) == "number" then
		self._left, self._bottom = args[4], args[5] -- relative to a parent at the origin
	end
	self._point = args
end
function methods:GetPoint() if self._point then return unpack(self._point) end end
function methods:GetLeft() return self._left end
function methods:GetBottom() return self._bottom end
function methods:GetRight() return self._left + self._w end
function methods:GetTop() return self._bottom + self._h end
function methods:GetCenter() return self._left + self._w / 2, self._bottom + self._h / 2 end
function methods:SetWidth(w) self._w = w end
function methods:SetHeight(h) self._h = h end
function methods:SetSize(w, h) self._w, self._h = w, h end
function methods:GetWidth() return self._w end
function methods:GetHeight() return self._h end
function methods:GetSize() return self._w, self._h end
function methods:GetTextWidth() return 50 end
function methods:GetTextHeight() return 12 end
function methods:GetStringWidth() return 8 * #(self._text or "") end
function methods:GetStringHeight() return 14 end
function methods:SetFrameStrata(s) self._strata = s end
function methods:GetFrameStrata() return self._strata or "MEDIUM" end
function methods:GetFrameLevel() return self._level or 1 end
function methods:SetFrameLevel(n) self._level = n end
function methods:SetText(t)
	-- Real WoW errors here, and the error aborts whatever was running.
	if self._kind == "FontString" and not self._hasFont then error("FontString:SetText(): Font not set", 2) end
	self._text = t
end
function methods:SetFontObject() self._hasFont = true end
function methods:SetFont(_, size) self._fontSize = size; self._hasFont = true; return true end
function methods:GetText() return self._text end
function methods:Enable() self._disabled = false end
function methods:Disable() self._disabled = true end
function methods:IsEnabled() return not self._disabled end
function methods:GetFontString()
	local fs = rawget(self, "_fontString")
	if not fs then fs = new("FontString", self); fs._hasFont = true; self._fontString = fs end
	return fs
end
function methods:SetValue(v) self._value = v end
function methods:GetValue() return self._value end
-- Geometric in WoW; here a per-frame switch (f._over) with a global default (MOUSE_OVER)
function methods:IsMouseOver()
	local over = rawget(self, "_over")
	if over ~= nil then return over end
	return MOUSE_OVER == true
end
function methods:SetChecked(v) self._checked = v end
function methods:GetChecked() return self._checked end
function methods:SetStartPoint(_, _, x, y) self.sx, self.sy = x, y end
function methods:SetEndPoint(_, _, x, y) self.ex, self.ey = x, y end
function methods:SetThickness(w) self.thickness = w end
function methods:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function methods:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
function methods:RegisterEvent(e) self._events[e] = true end
function methods:UnregisterEvent(e) self._events[e] = nil end
function methods:UnregisterAllEvents() self._events = {} end
function methods:IsEventRegistered(e) return self._events[e] == true end
function methods:CreateAnimationGroup() return new("AnimationGroup", self) end
function methods:CreateAnimation() return new("Animation", self) end
function methods:GetName() return self._name end
function methods:StartMoving() self._moving = true end
function methods:StopMovingOrSizing() self._moving = false end

function CreateFrame(kind, name, parent)
	local f = new(kind, parent)
	f._name = name
	if name then _G[name] = f end
	table.insert(ALL_FRAMES, f)
	return f
end

UIParent = CreateFrame("Frame", "UIParent")
WorldFrame = CreateFrame("Frame", "WorldFrame")
Minimap = CreateFrame("Frame", "Minimap")
Minimap._w, Minimap._h = 140, 140
GameTooltip = CreateFrame("GameTooltip", "GameTooltip")
-- what the tooltip says, for tests
function GameTooltip:SetOwner() self._lines = {} end
function GameTooltip:SetText(text) self._lines = { text } end
function GameTooltip:AddLine(text) self._lines = self._lines or {}; table.insert(self._lines, text) end
function TOOLTIP_TEXT() return table.concat(GameTooltip._lines or {}, " / ") end
ColorPickerFrame = CreateFrame("Frame", "ColorPickerFrame")
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(CHAT, m) end }
CHAT = {}
-- Like WoW, print() writes to the chat frame.
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	table.insert(CHAT, table.concat(parts, " "))
end

function GameTooltip_Hide() end
function StaticPopup_Show(which) LAST_POPUP = which end
StaticPopupDialogs = {}
YES, NO = "Yes", "No"
SlashCmdList = {}
Settings = nil -- exercise the legacy options path; RegisterCanvasLayoutCategory tested separately
function InterfaceOptions_AddCategory(panel) OPTIONS_PANEL = panel end
function InterfaceOptionsFrame_OpenToCategory() end

-- [[ Time & timers ]]
NOW = 0
function GetTime() return NOW end
function time() return 1700000000 + math.floor(NOW) end
function debugprofilestop() return NOW * 1000 end
function GetFramerate() return 60 end

TIMERS = {}
function GetServerTime() return 1700000000 + math.floor(NOW) end
C_Timer = {}
local function addTimer(d, f, repeats)
	local h = { t = NOW + d, f = f, d = d, repeats = repeats }
	function h:Cancel() self.cancelled = true end
	function h:IsCancelled() return self.cancelled end
	table.insert(TIMERS, h)
	return h
end
function C_Timer.After(d, f) addTimer(d, f) end
function C_Timer.NewTimer(d, f) return addTimer(d, f) end
function C_Timer.NewTicker(d, f, n) return addTimer(d, f, n or math.huge) end

function RUN_TIMERS()
	local ran = true
	while ran do
		ran = false
		for i, h in ipairs(TIMERS) do
			if h.cancelled then
				table.remove(TIMERS, i); ran = true; break
			elseif h.t <= NOW then
				table.remove(TIMERS, i)
				if h.repeats and h.repeats > 1 then
					h.repeats = h.repeats - 1
					h.t = NOW + h.d
					table.insert(TIMERS, h)
				end
				h.f(h)
				ran = true
				break
			end
		end
	end
end

function RUN_ONUPDATE(elapsed)
	for _, f in ipairs(ALL_FRAMES) do
		local s = f._scripts.OnUpdate
		if s and f:IsVisible() then s(f, elapsed) end
	end
end

function FIRE_EVENT(event, ...)
	for _, f in ipairs(ALL_FRAMES) do
		if f._events[event] and f._scripts.OnEvent then
			f._scripts.OnEvent(f, event, ...)
		end
	end
end

-- [[ Unit / social ]]
REALM = "TestRealm"
function UnitName(unit) if unit == "player" then return CLIENT.unitName or CLIENT.name end end
function UnitGUID(unit) if unit == "player" then return "Player-1-" .. CLIENT.name end end
function GetRealmName() return REALM end
function GetNormalizedRealmName() return REALM end
-- Like the client: "none" drops the realm only when it is the player's own
function Ambiguate(name, _)
	local base, realm = name:match("^([^%-]+)%-(.+)$")
	if base and realm == REALM then return base end
	return name
end
function UnitIsUnit() return false end
function IsInGuild() return CLIENT.guild end
function GetNumGuildMembers() return #CLIENT.guildRoster, #CLIENT.guildRoster end
function GetGuildRosterInfo(i)
	local m = CLIENT.guildRoster[i]
	if m then return m.name .. "-" .. REALM, "Rank" .. m.rank, m.rank end
end
function GuildControlGetRankName(i) return "Rank" .. (i - 1) end
C_GuildInfo = { GuildRoster = noop }
function UnitClass() return "Mage", "MAGE" end
RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
function GetScreenWidth() return 1920 end
function GetPhysicalScreenSize() return 2560, 1440 end
function GetScreenHeight() return 1080 end
-- Where this client stands: CLIENT.mapPos = { map = id, x = 0-1, y = 0-1 } (nil: nowhere)
MAP_YARDS = { [37] = { 3470.84, 2314.62 }, [1429] = { 3470.84, 2314.62 } }
C_Map = {
	GetBestMapForUnit = function() return CLIENT.mapPos and CLIENT.mapPos.map or MAP_ID end,
	GetPlayerMapPosition = function(mapID, unit)
		local p = CLIENT.mapPos
		if unit ~= "player" or not p or p.map ~= mapID then return nil end
		return { x = p.x, y = p.y, GetXY = function(v) return v.x, v.y end }
	end,
	GetMapWorldSize = function(mapID)
		local s = MAP_YARDS[mapID]
		if s then return s[1], s[2] end
		return 0, 0
	end,
	GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end,
	GetMapArtLayerTextures = function() local t = {} for i = 1, 12 do t[i] = 100 + i end return t end,
	GetMapInfo = function(id) return { name = "Map" .. id } end,
}
MAP_ID = 85
-- What this client has explored: a 300x200 area (2 tiles wide, 1 tall) plus a hover-only highlight
EXPLORED = {
	{ textureWidth = 300, textureHeight = 200, offsetX = 100, offsetY = 50, isShownByMouseOver = false, fileDataIDs = { 501, 502 } },
	{ textureWidth = 128, textureHeight = 128, offsetX = 0, offsetY = 0, isShownByMouseOver = true, fileDataIDs = { 599 } },
}
C_MapExplorationInfo = { GetExploredMapTextures = function() return EXPLORED end }
LE_PARTY_CATEGORY_INSTANCE = 2
-- CLIENT.instance = { name = , id = } while inside a dungeon
function IsInInstance() return CLIENT.instance ~= nil, CLIENT.instance and "party" or "none" end
function GetInstanceInfo()
	local i = CLIENT.instance
	if not i then return "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 end
	return i.name, "party", 1, "Normal", 5, 0, false, i.id
end
function IsInGroup(cat) if cat == LE_PARTY_CATEGORY_INSTANCE then return false end return CLIENT.group ~= nil end
function IsInRaid() return CLIENT.group == "raid" end
function GetNumGroupMembers() return CLIENT.group and #CLIENT.groupMembers or 0 end
function GetRaidRosterInfo(i)
	local m = CLIENT.groupMembers[i]
	if m then return m.name, m.rank end
end
function InCombatLockdown() return IN_COMBAT == true end
function IsLoggedIn() return LOGGED_IN end
function IsShiftKeyDown() return SHIFT_DOWN end
function IsControlKeyDown() return false end
function GetCursorPosition() return CURSOR_X or 0, CURSOR_Y or 0 end
-- Override bindings belong to an owner frame, and (like the real client) can't be changed
-- in combat. BINDINGS is the resulting key -> button view; a later owner wins a shared key.
BINDINGS = {}
local bindingOwners, bindingsOf = {}, {}
local function RebuildBindings()
	BINDINGS = {}
	for _, owner in ipairs(bindingOwners) do
		for key, button in pairs(bindingsOf[owner] or {}) do BINDINGS[key] = button end
	end
end
function SetOverrideBindingClick(owner, _, key, button)
	if IN_COMBAT then error("SetOverrideBindingClick is blocked in combat") end
	if not bindingsOf[owner] then
		bindingsOf[owner] = {}
		table.insert(bindingOwners, owner)
	end
	bindingsOf[owner][key] = button
	RebuildBindings()
end
function ClearOverrideBindings(owner)
	if IN_COMBAT then error("ClearOverrideBindings is blocked in combat") end
	bindingsOf[owner] = nil
	for i, o in ipairs(bindingOwners) do
		if o == owner then table.remove(bindingOwners, i) break end
	end
	RebuildBindings()
end
function GetLocale() return "enUS" end
function geterrorhandler() return function(e) error(e, 0) end end
function seterrorhandler() end
function securecallfunction(f, ...) return f(...) end
-- hooksecurefunc(table, name, hook) or hooksecurefunc(name, hook): run hook after the original
function hooksecurefunc(t, name, hook)
	if type(t) ~= "table" then t, name, hook = _G, t, name end
	local orig = t[name]
	if type(orig) ~= "function" then return end -- not present on this (mock) client
	rawset(t, name, function(...)
		local r = { orig(...) }
		hook(...)
		return unpack(r)
	end)
end
function IsAltKeyDown() return ALT_DOWN or false end

-- A world map shaped like Blizzard_MapCanvas: a scroll container whose Child is the map
-- layer, the cursor in 0-1 map coordinates, and OnMapChanged on every map switch.
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame", UIParent)
WorldMapFrame:Hide()
WorldMapFrame.mapID = 37
function WorldMapFrame:GetMapID() return self.mapID end
function WorldMapFrame:OnMapChanged() end
-- Explored-area art and the zone highlight are pins at 2002-2009; icon pins come after.
-- Frame levels as Blizzard_WorldMap registers them (2000 = default, one level per type in
-- order): the area-covering layers end at MAP_HIGHLIGHT (2009), icon pins start at 2014.
local PIN_LEVELS = {
	PIN_FRAME_LEVEL_DEFAULT = 2000, PIN_FRAME_LEVEL_WOW_LABS_AREA = 2001, PIN_FRAME_LEVEL_MAP_EXPLORATION = 2002,
	PIN_FRAME_LEVEL_PLUNDERSTORM_CIRCLE = 2003, PIN_FRAME_LEVEL_EVENT_OVERLAY = 2004,
	PIN_FRAME_LEVEL_GARRISON_PLOT = 2005, PIN_FRAME_LEVEL_FOG_OF_WAR = 2006, PIN_FRAME_LEVEL_QUEST_BLOB = 2007,
	PIN_FRAME_LEVEL_SCENARIO_BLOB = 2008, PIN_FRAME_LEVEL_MAP_HIGHLIGHT = 2009, PIN_FRAME_LEVEL_DIG_SITE = 2014,
}
function WorldMapFrame:GetPinFrameLevelsManager()
	return { GetValidFrameLevel = function(_, kind) return PIN_LEVELS[kind] or PIN_LEVELS.PIN_FRAME_LEVEL_DEFAULT end }
end
-- Blizzard's own top-right buttons are moved elsewhere on the client we target: not there
WorldMapFrame.WorldMapTrackingOptionsButton = false
WorldMapFrame.WorldMapTrackingPinButton = false
-- Navigation, as Blizzard_MapCanvas does it on a click: recorded in NAV for the tests
function WorldMapFrame:ProcessCanvasClickHandlers() return false end
function WorldMapFrame:NavigateToCursor() NAV = "cursor" return true end
function WorldMapFrame:NavigateToParentMap() NAV = "parent" end
function WorldMapFrame:SetMapID(id)
	if id ~= self.mapID then
		self.mapID = id
		self:OnMapChanged()
	end
end
WorldMapFrame.ScrollContainer = CreateFrame("ScrollFrame", nil, WorldMapFrame)
WorldMapFrame.ScrollContainer.Child = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer)
WorldMapFrame.ScrollContainer.Child:SetSize(1002, 668)
function WorldMapFrame.ScrollContainer:ShouldNavigateOnClick() return true end
function WorldMapFrame.ScrollContainer:CanPan() return MAP_ZOOMED == true end -- zoomed in: drags pan
function WorldMapFrame.ScrollContainer:ShouldNavigateIgnoreZoneMapPositionData() return false end
MAP_CURSOR = { 0.5, 0.5 }
function WorldMapFrame.ScrollContainer:GetNormalizedCursorPosition() return MAP_CURSOR[1], MAP_CURSOR[2] end
function GetAddOnInfo() return nil end

C_AddOns = {
	GetAddOnMetadata = function(_, key) return ADDON_METADATA[key] end,
	IsAddOnLoaded = function() return false end,
}

-- [[ Addon messaging ]]
SENT = {}
PREFIX_BUDGET = {}
THROTTLED = 0
C_ChatInfo = {
	RegisterAddonMessagePrefix = function() return true end,
	IsAddonMessagePrefixRegistered = function() return true end,
	-- Like the real client (10.2.7+ / 4.4.0+): each prefix has an allowance of 10 messages
	-- that refills at 1 per second; past that, sends fail with AddonMessageThrottle.
	SendAddonMessage = function(prefix, msg, channel, target)
		assert(#prefix <= 16, "prefix too long: " .. prefix)
		assert(#msg <= 255, "addon message too long")
		local b = PREFIX_BUDGET[prefix] or { tokens = 10, t = NOW }
		b.tokens = math.min(10, b.tokens + (NOW - b.t))
		b.t = NOW
		PREFIX_BUDGET[prefix] = b
		if b.tokens < 1 then
			THROTTLED = THROTTLED + 1
			return Enum.SendAddonMessageResult.AddonMessageThrottle
		end
		b.tokens = b.tokens - 1
		table.insert(SENT, { prefix, msg, channel, target })
		return Enum.SendAddonMessageResult.Success
	end,
}
C_ChatInfo.SendAddonMessageLogged = C_ChatInfo.SendAddonMessage
Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3 } }

-- [[ Lua/WoW string & table helpers ]]
strmatch, strsub, strlen, strbyte, strchar, strfind, strlower, strupper, strrep =
	string.match, string.sub, string.len, string.byte, string.char, string.find, string.lower, string.upper, string.rep
gsub, format, tinsert, tremove = string.gsub, string.format, table.insert, table.remove
floor, ceil, max, min, abs, sqrt = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt
function strsplit(d, s, n)
	local out, pattern = {}, "([^" .. d:gsub("%p", "%%%0") .. "]*)"
	for p in (s .. d):gmatch(pattern .. d:gsub("%p", "%%%0")) do out[#out + 1] = p end
	return unpack(out)
end
function strjoin(d, ...) return table.concat({ ... }, d) end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
table.wipe = wipe
function CopyTable(t)
	local c = {}
	for k, v in pairs(t) do c[k] = type(v) == "table" and CopyTable(v) or v end
	return c
end
function tContains(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
math.randomseed(#CLIENT.name * 7919)
