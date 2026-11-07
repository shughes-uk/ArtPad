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
	BrushSize = 3,
	Color = { r = 1, g = 1, b = 1, a = 1 },
	RecentColors = {},
	FramePositions = {}, -- window position
	MinimapIcon = {},
	Debug = false,
}

--[[ Helpers ]]

-- Character name without realm. Character names can't contain "-", so strip from the first
-- one too, in case a client formats senders differently from what Ambiguate expects.
function ArtPad.ShortName(name)
	if not name then return nil end
	return (Ambiguate(name, "none"):gsub("%-.*$", ""))
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
		self.playerName = saved
		return saved
	end
	local name = ArtPad.ShortName(UnitName("player"))
	if name and name ~= "" and name ~= UNKNOWNOBJECT and name ~= "Unknown" then
		self.playerName = name
	end
	return self.playerName
end

function ArtPad:LearnOwnName(sender)
	local full = ArtPad.ShortName(sender)
	if not full or full == "" then return end
	-- Sanity check: it has to be our UnitName, possibly followed by a surname.
	local unit = ArtPad.ShortName(UnitName("player"))
	if unit and unit ~= "" and unit ~= "Unknown" and unit ~= UNKNOWNOBJECT
			and full ~= unit and full:sub(1, #unit + 1) ~= unit .. " " then
		return
	end
	self.learnedName = true
	local guid = UnitGUID and UnitGUID("player")
	if guid then
		if type(ArtPad_Settings.FullNames) ~= "table" then ArtPad_Settings.FullNames = {} end
		ArtPad_Settings.FullNames[guid] = full
	end
	if full ~= self.playerName then
		self:Debug(("own name is %s (was %s)"):format(full, tostring(self.playerName)))
		if self.RenameAuthor then self:Quietly(self.RenameAuthor, self.playerName, full) end
		self.playerName = full
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
	if type(ArtPad_Settings) ~= "table" or (tonumber(ArtPad_Settings.SaveVersion) or 0) < self.saveVersion then
		ArtPad_Settings = {}
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
	for _, step in ipairs({ "SetupUI", "SetupTools", "SetupFeedback", "SetupOptions", "SetupLauncher", "SetupPlaces" }) do
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
		self.eventFrame:RegisterEvent(event)
	end
	self.eventFrame:SetScript("OnEvent", function(_, event, ...)
		events[event](self, ...)
	end)
end

function events:PLAYER_ENTERING_WORLD()
	if not self.enteredWorld then
		self.enteredWorld = true
		-- Give the guild/group roster a moment to arrive before asking for the canvas.
		C_Timer.After(3, function() self:StartSync("login") end)
	end
end

function events:PLAYER_LOGOUT()
	self:SavePlaceCanvas()
end

function events:PLAYER_REGEN_DISABLED()
	if ArtPad_Settings.HideInCombat and self.window:IsShown() then
		self.window:Hide()
	end
end

function events:GROUP_JOINED()
	if ArtPad_Settings.Mode == "RAID" then
		C_Timer.After(2, function() self:StartSync("group joined") end)
	end
end

function events:GUILD_ROSTER_UPDATE()
	self.guildRanks = nil -- rebuilt lazily by GetGuildRank
end

-- Keep the "sharing with" indicator honest as groups and guilds change.
function events:GROUP_ROSTER_UPDATE() self:RequestRefresh() end
function events:GROUP_LEFT() self:RequestRefresh() end
function events:PLAYER_GUILD_UPDATE() self:RequestRefresh() end

--[[ Modes ]]

local MODE_MESSAGES = {
	GUILD = "Now sharing with your guild.",
	RAID = "Now sharing with your party / raid.",
	LOCAL = "Local: you share with whoever is at the same place, like the Lion's Pride Inn.",
}

function ArtPad:SetMode(mode)
	if ArtPad_Settings.Mode == mode or not MODE_MESSAGES[mode] then return end
	if self.node then self:LeavePlace(true) end -- keeps the place's drawing
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
	resync = function(self)
		self:ResetCanvas()
		self:StartSync("manual")
	end,
	map = function(self) self:ToggleMap() end,
	resetui = function(self)
		self:ResetAllFramePositions()
		self:Message("window is back in its default spot.")
	end,
	fit = function(self) self:ResetPosition() end,
	stats = function(self) self:PrintStats() end,
	node = function(self) self:PrintPlaces() end, -- hidden: distances to places
	bench = function(self, arg) self:BenchCommand(arg) end, -- hidden: Debug.lua
	size = function(self, arg)
		local n = tonumber(arg)
		if n then self:SetBrushSize(n) end
		self:Message("brush size " .. ArtPad_Settings.BrushSize)
	end,
	adminonly = function(self, arg)
		ArtPad_Settings.AdminOnly = OnOff(arg, ArtPad_Settings.AdminOnly)
		self:Message("only leaders/officers: " .. (ArtPad_Settings.AdminOnly and "on" or "off"))
		self:RefreshOptions()
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
