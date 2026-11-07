std = "lua51"
max_line_length = false
exclude_files = { "Libs/", "tests/", ".luarocks/", ".install/" }

-- Unused `self` and callback arguments are normal for WoW script handlers.
unused_args = false

-- Globals ArtPad defines on purpose.
globals = {
	"ArtPad",
	"ArtPad_Settings",
	"ArtPad_OnAddonCompartmentClick",
	"SLASH_ARTPAD1",
	"SLASH_ARTPAD2",
	"BINDING_HEADER_ARTPAD",
	"BINDING_NAME_ARTPAD_SHOW",
	"BINDING_NAME_ARTPAD_HIDE",
	"BINDING_NAME_ARTPAD_TOGGLE",
	"BINDING_NAME_ARTPAD_UNDO",
	SlashCmdList = { other_fields = true },
	StaticPopupDialogs = { other_fields = true },
	-- The legacy colour picker API is driven by setting fields on the frame.
	ColorPickerFrame = { other_fields = true },
}

-- WoW API ArtPad reads.
read_globals = {
	"LibStub",
	"C_AddOns", "GetAddOnMetadata",
	"C_Timer", "C_GuildInfo", "GuildRoster",
	"CreateFrame", "UIParent", "DEFAULT_CHAT_FRAME",
	"GameTooltip", "GameTooltip_Hide",
	"OpacitySliderFrame",
	"StaticPopup_Show", "YES", "NO",
	"Settings", "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory",
	"InCombatLockdown", "IsShiftKeyDown", "GetCursorPosition", "GetTime", "time",
	"SetOverrideBindingClick", "ClearOverrideBindings",
	"UnitName", "UnitGUID", "Ambiguate", "UNKNOWNOBJECT",
	"IsInGuild", "GetNumGuildMembers", "GetGuildRosterInfo", "GuildControlGetRankName",
	"IsInGroup", "IsInRaid", "GetNumGroupMembers", "GetRaidRosterInfo", "LE_PARTY_CATEGORY_INSTANCE",
	"CopyTable", "wipe", "tinsert", "strtrim",
	"GetScreenWidth", "GetScreenHeight", "C_Map", "C_MapExplorationInfo", "CreateVector2D", "UnitClass", "RAID_CLASS_COLORS",
}
