--[[
	ArtPad - a shared canvas for your guild or group.
	Originally by Dust (Turalyon-EU) & Catmancer (Moonguard-US).

	Files:
	  Core.lua     addon object, settings, modes, events, slash commands, launcher
	  Canvas.lua   drawing model (strokes/texts), rendering, hit testing, snapshots, undo
	  Comm.lua     live drawing protocol, canvas sync for late joiners, permissions
	  UI.lua       the window, canvas view (zoom/pan/fit), mouse and keys
	  Options.lua  settings panel
]]

local ADDON_NAME, ns = ...

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

local ArtPad = LibStub("AceAddon-3.0"):NewAddon("ArtPad", "AceComm-3.0", "AceSerializer-3.0")
_G.ArtPad = ArtPad -- Bindings.xml and other addons reference the global.
ns.ArtPad = ArtPad

ArtPad.version = GetAddOnMetadata(ADDON_NAME, "Version")
ArtPad.saveVersion = tonumber(GetAddOnMetadata(ADDON_NAME, "X-SaveVersion")) or 0
ArtPad.protocolVersion = GetAddOnMetadata(ADDON_NAME, "X-ProtocolVersion")

ArtPad.MEDIA = "Interface\\AddOns\\ArtPad\\"
ArtPad.ICON = ArtPad.MEDIA .. "icon"
ArtPad.ICON_ACTIVE = ArtPad.MEDIA .. "iconact"
ArtPad.FONT = "Fonts\\FRIZQT__.TTF"

ArtPad.DEBUG = false

local defaults = {
	SaveVersion = ArtPad.saveVersion,
	Mode = "GUILD", -- "GUILD", "RAID" (party/raid/instance group) or "LOCAL" (places, Nodes.lua)
	AdminOnly = false, -- only accept drawings from leaders/assists (group) or officers (guild)
	AdminGuildRank = 1, -- guild rank index counted as officer (0 = guild master)
	WarnClear = true, -- confirm before clearing the canvas for everyone
	FullNames = {}, -- character GUID -> name as others see it (WoW Forever adds a surname)
	PlaceCanvases = {}, -- place id -> saved canvas
	NameTags = true, -- show who is drawing
	ShowMyName = true, -- let others see my name on what I draw
	HideInCombat = true,
	View = false, -- { scale, x, y } of the canvas in the window; false = fit
	WindowSize = false, -- { w, h }; false = default
	MapDim = 0.4, -- darken the map backdrop so drawings stand out
	MapDrawings = {}, -- world map drawings, mapID -> strokes (WorldMapDraw.lua)
	MapShare = true, -- share them with the guild or group
	BrushSize = 3,
	Color = { r = 1, g = 1, b = 1, a = 1 },
	RecentColors = {},
	FramePositions = {}, -- window position
	MinimapIcon = {},
	Debug = false,
}

--[[ Helpers ]]

-- The name a player is known by here: the bare character name for someone on our own realm
-- (however the client formats it), "Name-Realm" for someone on another. Two characters with
-- the same name on different realms can share a cross-realm group, and must not be taken
-- for each other - or for us.
local function OwnRealm()
	local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
	return realm and (realm:gsub("[%s%-]", "")) or nil
end

function ArtPad.ShortName(name)
	if not name then return nil end
	local short = Ambiguate(name, "none")
	local base, realm = short:match("^([^%-]+)%-(.+)$")
	if not base then return short end
	local own = OwnRealm()
	-- our realm, or ours isn't known yet (addons still loading): the bare name
	if not own or realm:gsub("[%s%-]", "") == own then return base end
	return short
end

-- Our character's own name from the client, or nil while it is still a placeholder.
local function UnitNameNow()
	local name = ArtPad.ShortName(UnitName("player"))
	if name and name ~= "" and name ~= UNKNOWNOBJECT and name ~= "Unknown" then return name end
end

-- Could `full` be us as others see us? Our UnitName, possibly followed by a surname.
function ArtPad:LooksLikeMe(sender)
	local full = ArtPad.ShortName(sender)
	local unit = UnitNameNow()
	if not full or full == "" then return false end
	if not unit then return true end -- can't tell yet
	return full == unit or full:sub(1, #unit + 1) == unit .. " "
end

-- The one place the name changes: everything drawn under the old name is re-keyed first, so
-- item ids here keep matching the ids everyone else derives from our sender name.
function ArtPad:SetPlayerName(name)
	local old = self.playerName
	if not name or name == old then return end
	if old and self.RenameAuthor and self.items then self:Quietly(self.RenameAuthor, old, name) end
	self.playerName = name
end

-- Your name as other players see it: the sender name on your messages, and the author part
-- of your item ids. Usually UnitName("player"), but WoW Forever characters have a surname
-- that only appears in sender names ("Corgi Pembroke" vs "Corgi"), and only the full pair is
-- unique. The real one is learned from the server echoing our own sync request back
-- (LearnOwnName) and remembered per character. UnitName can also be a placeholder
-- ("Unknown") while addons load, so until then it's re-read.
function ArtPad:RefreshPlayerName()
	if self.learnedName then return self.playerName end
	local guid = UnitGUID and UnitGUID("player")
	local saved = guid and type(ArtPad_Settings.FullNames) == "table" and ArtPad_Settings.FullNames[guid]
	if type(saved) == "string" and saved ~= "" then
		-- trusted only while it still fits the character (it may have been renamed since)
		if self:LooksLikeMe(saved) then
			self:SetPlayerName(saved)
			return saved
		end
		ArtPad_Settings.FullNames[guid] = nil
	end
	local name = UnitNameNow()
	if name then self:SetPlayerName(name) end
	return self.playerName
end

function ArtPad:LearnOwnName(sender)
	local full = ArtPad.ShortName(sender)
	if not full or full == "" then return end
	-- Sanity check: it has to be our UnitName, possibly followed by a surname.
	if not self:LooksLikeMe(sender) then return end
	if full ~= self.playerName then
		self:Debug(("own name is %s (was %s)"):format(full, tostring(self.playerName)))
		self:SetPlayerName(full)
	end
	self.learnedName = true
	self.sentRecently = nil
	local guid = UnitGUID and UnitGUID("player")
	if guid then
		if type(ArtPad_Settings.FullNames) ~= "table" then ArtPad_Settings.FullNames = {} end
		ArtPad_Settings.FullNames[guid] = full
	end
end

function ArtPad:IsSelf(sender)
	return ArtPad.ShortName(sender) == self:RefreshPlayerName()
end

function ArtPad:Debug(...)
	if self.DEBUG then
		print("|cff88ccffArtPad|r", ...)
	end
end

function ArtPad:Message(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffArtPad:|r " .. msg)
end

-- Item ids are "<author>:<session tag>.<counter>", unique across reloads.
function ArtPad:NewLocalId()
	self.idCounter = self.idCounter + 1
	return self.sessionTag .. "." .. self.idCounter
end

--[[ Lifecycle ]]

function ArtPad:OnInitialize()
	if type(ArtPad_Settings) ~= "table" then
		ArtPad_Settings = {}
	elseif (tonumber(ArtPad_Settings.SaveVersion) or 0) < self.saveVersion then
		-- Older settings start over, but kept drawings and learned names carry across: each
		-- is checked for shape where it is read.
		local old = ArtPad_Settings
		ArtPad_Settings = {}
		for _, key in ipairs({ "PlaceCanvases", "MapDrawings", "MapShare", "FullNames", "MapHintSeen" }) do
			ArtPad_Settings[key] = old[key]
		end
	end
	for k, v in pairs(defaults) do
		if ArtPad_Settings[k] == nil then
			ArtPad_Settings[k] = type(v) == "table" and CopyTable(v) or v
		end
	end
	ArtPad_Settings.SaveVersion = self.saveVersion
	self.DEBUG = ArtPad_Settings.Debug

	self.playerName = ArtPad.ShortName(UnitName("player"))
	self:RefreshPlayerName()
	self.sessionTag = string.format("%x", time() % 0x100000)
	self.idCounter = 0
end

local events = {}

function ArtPad:OnEnable()
	self:RefreshPlayerName()
	-- Messaging first: it doesn't depend on the UI, so drawing and syncing keep working even
	-- if a piece of the UI fails to build. Each step reports its own error to chat.
	self:SetupComm()
	for _, step in ipairs({ "SetupUI", "SetupTools", "SetupFeedback", "SetupOptions", "SetupLauncher", "SetupPlaces", "SetupWorldMapDraw" }) do
		local ok, err = pcall(self[step], self)
		if not ok then
			self:Message("|cffff6060setup failed (" .. step .. "):|r " .. tostring(err))
		end
	end

	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end

	self.eventFrame = CreateFrame("Frame")
	for event in pairs(events) do
		pcall(self.eventFrame.RegisterEvent, self.eventFrame, event) -- not every client has every event
	end
	self.eventFrame:SetScript("OnEvent", function(_, event, ...)
		events[event](self, ...)
	end)
end

function events:PLAYER_ENTERING_WORLD()
	if not self.enteredWorld then
		self.enteredWorld = true
		self.wasInGuild = IsInGuild() and true or false
		-- Give the guild/group roster a moment to arrive before asking for the canvas.
		C_Timer.After(3, function() self:StartSync("login") end)
		C_Timer.After(6, function() self:AnnounceVersion() end)
	end
end

function events:PLAYER_LOGOUT()
	self:SavePlaceCanvas()
end

-- Fires just before combat locks key bindings: let go of ours now, so none can be left on a
-- window that gets closed during the fight. They come back when combat ends.
function events:PLAYER_REGEN_DISABLED()
	self:ReleaseBindings()
	if ArtPad_Settings.HideInCombat and self.window:IsShown() then
		self.window:Hide()
	end
end

function events:PLAYER_REGEN_ENABLED()
	self:SyncBindings()
end

function events:GROUP_JOINED()
	C_Timer.After(3, function() self:AnnounceVersion() end)
	if ArtPad_Settings.Mode == "RAID" and not self.loopback then
		local scope = self.scope
		C_Timer.After(2, function()
			if scope == self.scope then self:StartSync("group joined") end
		end)
	end
end

-- A sync that found nobody to ask (no guild or group known yet) goes ahead once there is one.
function ArtPad:RetryWantedSync()
	if self.wantSync and not self.syncing and self:GetChannel() then
		self:StartSync("someone to sync with now")
	end
end

function events:GUILD_ROSTER_UPDATE()
	self.guildRanks = nil -- rebuilt lazily by GetGuildRank
	self:RetryWantedSync()
end

-- Keep the "sharing with" indicator honest as groups and guilds change.
function events:GROUP_ROSTER_UPDATE()
	self:RequestRefresh()
	self:RetryWantedSync()
end

-- The group's canvas belonged to the group: leaving it is a change of audience.
function events:GROUP_LEFT()
	if ArtPad_Settings.Mode == "RAID" and not self.loopback then
		self:SwitchScope()
		self:ResetCanvas()
	end
	self:RequestRefresh()
end

-- So is leaving (or changing) guild. Gaining one is when the guild's canvas can be fetched.
function events:PLAYER_GUILD_UPDATE()
	local inGuild = IsInGuild() and true or false
	if ArtPad_Settings.Mode == "GUILD" and not self.loopback and self.wasInGuild and not inGuild then
		self:SwitchScope()
		self:ResetCanvas()
	end
	self.wasInGuild = inGuild
	self:RequestRefresh()
	self:RetryWantedSync()
end

--[[ Modes ]]

local MODE_MESSAGES = {
	GUILD = "Now sharing with your guild.",
	RAID = "Now sharing with your party / raid.",
	LOCAL = "Local: you share with whoever is at the same place, like the Lion's Pride Inn.",
}

function ArtPad:SetMode(mode)
	if ArtPad_Settings.Mode == mode or not MODE_MESSAGES[mode] then return end
	if self.node then self:LeavePlace(true) end -- keeps the place's drawing
	-- A different audience: end a drag, drop unsent work, abort a sync that is still running.
	self:SwitchScope()
	ArtPad_Settings.Mode = mode
	self:Notify(MODE_MESSAGES[mode], "success")
	self:RequestRefresh()
	-- A different audience means a different shared canvas.
	self:ResetCanvas()
	if mode == "LOCAL" then
		self:CheckPlaces() -- joins the place you're at, if any
	else
		self:StartSync("mode change")
	end
	self:RefreshOptions()
end

-- "Leaders only" changes whose drawings count, so the canvas is fetched again to match:
-- otherwise you keep a picture nobody else has until you reload it by hand.
function ArtPad:SetAdminOnly(on)
	on = on and true or false
	if on == (ArtPad_Settings.AdminOnly and true or false) then return end
	ArtPad_Settings.AdminOnly = on
	self.guildRanks = nil
	if not self.node and not self.loopback then self:Resync() end
	self:RefreshOptions()
	self:RequestRefresh()
end

local NEXT_MODE = { GUILD = "RAID", RAID = "LOCAL", LOCAL = "GUILD" }
local MODE_NAMES = { GUILD = "guild", RAID = "party/raid", LOCAL = "local (places)" }

--[[ Minimap button / addon compartment ]]

function ArtPad:SetLauncherActive(active)
	if self.launcher then
		self.launcher.icon = active and self.ICON_ACTIVE or self.ICON
	end
end

function ArtPad:NotifyActivity()
	if self.window and not self.window:IsShown() then
		self:SetLauncherActive(true)
	end
end

function ArtPad.MiniMapClick(_, button)
	local self = ArtPad
	if button == "RightButton" then
		self:SetMode(NEXT_MODE[ArtPad_Settings.Mode] or "GUILD")
	elseif button == "MiddleButton" then
		self:OpenOptions()
	elseif not InCombatLockdown() then
		self:Toggle()
	end
end

-- Global for the TOC's AddonCompartmentFunc (retail addon compartment menu).
function ArtPad_OnAddonCompartmentClick(_, button)
	ArtPad.MiniMapClick(nil, button)
end

function ArtPad:SetupLauncher()
	local LDB = LibStub("LibDataBroker-1.1", true)
	if not LDB then return end
	self.launcher = LDB:NewDataObject("ArtPad", {
		type = "launcher",
		icon = self.ICON,
		OnClick = self.MiniMapClick,
		OnTooltipShow = function(tt)
			tt:AddLine("ArtPad")
			tt:AddLine("|cffffff00Left Click|r to toggle the canvas")
			tt:AddLine("|cffffff00Right Click|r to switch: guild, party/raid, local")
			tt:AddLine("|cffffff00Middle Click|r for options")
			tt:AddLine("Sharing with: " .. (MODE_NAMES[ArtPad_Settings.Mode] or "?"), 1, 1, 1)
		end,
	})
	local LDBIcon = LibStub("LibDBIcon-1.0", true)
	if LDBIcon then
		LDBIcon:Register("ArtPad", self.launcher, ArtPad_Settings.MinimapIcon)
	end
end

function ArtPad:SetMinimapShown(shown)
	ArtPad_Settings.MinimapIcon.hide = not shown
	local LDBIcon = LibStub("LibDBIcon-1.0", true)
	if LDBIcon then
		if shown then LDBIcon:Show("ArtPad") else LDBIcon:Hide("ArtPad") end
	end
end

--[[ Slash commands ]]

local function OnOff(arg, current)
	if arg == "on" or arg == "true" then return true end
	if arg == "off" or arg == "false" then return false end
	return not current
end

ArtPad.slashCommands = {
	show = function(self) self.window:Show() end,
	hide = function(self) self.window:Hide() end,
	toggle = function(self) self:Toggle() end,
	clear = function(self)
		self:Quietly(self.ClearCanvas)
		self.canvasModified = 0 -- local only: must not beat anyone's copy
		self:Message("cleared your local canvas (others keep theirs).")
	end,
	undo = function(self) self:Undo() end,
	guild = function(self) self:SetMode("GUILD") end,
	raid = function(self) self:SetMode("RAID") end,
	["local"] = function(self) self:SetMode("LOCAL") end,
	resync = function(self) self:Resync() end,
	map = function(self) self:ToggleMap() end,
	resetui = function(self)
		self:ResetAllFramePositions()
		self:Message("window is back in its default spot.")
	end,
	fit = function(self) self:ResetPosition() end,
	stats = function(self) self:PrintStats() end,
	versions = function(self) self:QueryVersions() end,
	node = function(self) self:PrintPlaces() end, -- hidden: distances to places
	bench = function(self, arg) self:BenchCommand(arg) end, -- hidden: Debug.lua
	size = function(self, arg)
		local n = tonumber(arg)
		if n then self:SetBrushSize(n) end
		self:Message("brush size " .. ArtPad_Settings.BrushSize)
	end,
	adminonly = function(self, arg)
		self:SetAdminOnly(OnOff(arg, ArtPad_Settings.AdminOnly))
		self:Message("only leaders/officers: " .. (ArtPad_Settings.AdminOnly and "on" or "off"))
	end,
	adminrank = function(self, arg)
		local n = tonumber(arg)
		if n and n >= 0 and n <= 9 then
			ArtPad_Settings.AdminGuildRank = math.floor(n)
			self.guildRanks = nil
		end
		self:Message("guild ranks 0-" .. ArtPad_Settings.AdminGuildRank .. " count as officers.")
		self:RefreshOptions()
	end,
	warnclear = function(self, arg)
		ArtPad_Settings.WarnClear = OnOff(arg, ArtPad_Settings.WarnClear)
		self:Message("confirm before clearing: " .. (ArtPad_Settings.WarnClear and "on" or "off"))
		self:RefreshOptions()
	end,
	names = function(self, arg)
		ArtPad_Settings.NameTags = OnOff(arg, ArtPad_Settings.NameTags)
		self:Message("name tags: " .. (ArtPad_Settings.NameTags and "on" or "off"))
		self:RefreshOptions()
	end,
	minimap = function(self, arg)
		self:SetMinimapShown(OnOff(arg, not ArtPad_Settings.MinimapIcon.hide))
		self:RefreshOptions()
	end,
	options = function(self) self:OpenOptions() end,
	config = function(self) self:OpenOptions() end,
	loopback = function(self) self:SetLoopback(not self.loopback) end,
	debug = function(self)
		ArtPad_Settings.Debug = not ArtPad_Settings.Debug
		self.DEBUG = ArtPad_Settings.Debug
		self:Message("debug mode " .. (self.DEBUG and "on" or "off"))
	end,
	dumpvar = function(self)
		print("Mode: " .. ArtPad_Settings.Mode .. ", channel: " .. tostring(self:GetChannel()))
		print("Items: " .. #self.items .. ", undo stack: " .. #self.undoStack)
		print("Syncing: " .. tostring(self.syncing) .. ", loopback: " .. tostring(self.loopback))
	end,
}

function ArtPad.OnSlashCommand(msg)
	local self = ArtPad
	local cmd, arg = string.match(msg or "", "^(%a*)%s*(.-)%s*$")
	cmd = cmd and cmd:lower() or ""
	if cmd == "" then
		self:Toggle()
	elseif self.slashCommands[cmd] then
		self.slashCommands[cmd](self, arg and arg:lower())
	else
		self:Message("commands:")
		self:Message("/ap [show | hide | toggle]  /ap options")
		self:Message("/ap guild | raid | local  - who shares your canvas (local: places like inns)")
		self:Message("/ap undo  (or Ctrl-Z)   /ap size <n>  - brush size")
		self:Message("/ap resync  - re-download the canvas   /ap clear  - clear locally")
		self:Message("/ap versions  - list ArtPad versions in your guild and group")
		self:Message("/ap map  - show/hide the map of where you are   /ap fit  - fit canvas to screen")
		self:Message("/ap resetui  - put the window back to its default size and spot")
		self:Message("/ap adminonly [on|off]   /ap adminrank <n>")
		self:Message("/ap names | warnclear | minimap [on|off]")
		self:Message("/ap loopback  - test sync solo: round-trip your drawing through the server")
	end
end

SLASH_ARTPAD1 = "/artpad"
SLASH_ARTPAD2 = "/ap"
SlashCmdList.ARTPAD = ArtPad.OnSlashCommand

BINDING_HEADER_ARTPAD = "ArtPad"
BINDING_NAME_ARTPAD_SHOW = "Show Art Window"
BINDING_NAME_ARTPAD_HIDE = "Hide Art Window"
BINDING_NAME_ARTPAD_TOGGLE = "Toggle Art Window"
BINDING_NAME_ARTPAD_UNDO = "Undo Last Stroke"
