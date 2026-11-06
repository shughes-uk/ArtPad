--[[
	ArtPad - a shared canvas for your guild or group.
	Originally by Dust (Turalyon-EU) & Catmancer (Moonguard-US).

	Files:
	  Core.lua     addon object, settings, modes, events, slash commands, launcher
	  Canvas.lua   drawing model (strokes/texts), rendering, hit testing, snapshots, undo
	  Comm.lua     live drawing protocol, canvas sync for late joiners, permissions
	  UI.lua       canvas frame, toolbar, mouse handling, name tags, colour picker
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
	Mode = "GUILD", -- "GUILD" or "RAID" (party/raid/instance group)
	AdminOnly = false, -- only accept drawings from leaders/assists (group) or officers (guild)
	AdminGuildRank = 1, -- guild rank index counted as officer (0 = guild master)
	WarnClear = true, -- confirm before clearing the canvas for everyone
	NameTags = true, -- show who is drawing
	HideInCombat = true,
	Scale = 1,
	Position = false, -- { left, bottom } in canvas-scaled units, false = centered
	BrushSize = 3,
	Color = { r = 1, g = 1, b = 1, a = 1 },
	RecentColors = {},
	FramePositions = {}, -- toolbar / dock positions, see MakeMovable
	MinimapIcon = {},
	Debug = false,
}

--[[ Helpers ]]

function ArtPad.ShortName(name)
	return name and Ambiguate(name, "none")
end

function ArtPad:IsSelf(sender)
	return ArtPad.ShortName(sender) == self.playerName
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

	self.playerName = UnitName("player")
	self.sessionTag = string.format("%x", time() % 0x100000)
	self.idCounter = 0
end

local events = {}

function ArtPad:OnEnable()
	self:SetupUI()
	self:SetupTools()
	self:SetupFeedback()
	self:SetupComm()
	self:SetupOptions()
	self:SetupLauncher()

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

function events:PLAYER_REGEN_DISABLED()
	if ArtPad_Settings.HideInCombat and self.mainFrame:IsShown() then
		self.mainFrame:Hide()
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

function ArtPad:SetMode(mode)
	if ArtPad_Settings.Mode == mode then return end
	ArtPad_Settings.Mode = mode
	self:Notify(mode == "GUILD" and "Now sharing with your guild." or "Now sharing with your party / raid.", "success")
	self:RequestRefresh()
	-- A different audience means a different shared canvas.
	self:ClearAll()
	self:StartSync("mode change")
	self:RefreshOptions()
end

function ArtPad:Toggle()
	if not self.mainFrame then return end
	if self.mainFrame:IsShown() then
		self.mainFrame:Hide()
	else
		self.mainFrame:Show()
	end
end

--[[ Minimap button / addon compartment ]]

function ArtPad:SetLauncherActive(active)
	if self.launcher then
		self.launcher.icon = active and self.ICON_ACTIVE or self.ICON
	end
end

function ArtPad:NotifyActivity()
	if self.mainFrame and not self.mainFrame:IsShown() then
		self:SetLauncherActive(true)
	end
end

function ArtPad.MiniMapClick(_, button)
	local self = ArtPad
	if button == "RightButton" then
		self:SetMode(ArtPad_Settings.Mode == "GUILD" and "RAID" or "GUILD")
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
			tt:AddLine("|cffffff00Right Click|r to switch between guild and party/raid")
			tt:AddLine("|cffffff00Middle Click|r for options")
			tt:AddLine("Sharing with: " .. (ArtPad_Settings.Mode == "GUILD" and "guild" or "party/raid"), 1, 1, 1)
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
	show = function(self) self.mainFrame:Show() end,
	hide = function(self) self.mainFrame:Hide() end,
	toggle = function(self) self:Toggle() end,
	clear = function(self)
		self:ClearCanvas()
		self:Message("cleared your local canvas (others keep theirs).")
	end,
	undo = function(self) self:Undo() end,
	guild = function(self) self:SetMode("GUILD") end,
	raid = function(self) self:SetMode("RAID") end,
	resync = function(self)
		self:ClearAll()
		self:StartSync("manual")
	end,
	map = function(self) self:ToggleMap() end,
	resetui = function(self)
		self:ResetAllFramePositions()
		self:Message("toolbar and dock are back in their default spots.")
	end,
	fit = function(self) self:ResetPosition() end,
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
		self:Message("/ap guild | raid  - who shares your canvas")
		self:Message("/ap undo  (or Ctrl-Z)   /ap size <n>  - brush size")
		self:Message("/ap resync  - re-download the canvas   /ap clear  - clear locally")
		self:Message("/ap map  - show/hide the map of where you are   /ap fit  - fit canvas to screen")
		self:Message("/ap resetui  - put the toolbar and dock back (drag their grips to move them)")
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
