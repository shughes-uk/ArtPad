--[[
	Settings panel (Options -> AddOns -> ArtPad), built from plain widgets so it works on
	every client that has either the modern Settings UI or the legacy Interface Options.
]]

local ArtPad = ArtPad

local widgets = {}

local function CreateCheck(panel, label, tooltip, get, set)
	local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	check:SetSize(26, 26)
	local text = check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", check, "RIGHT", 4, 1)
	text:SetText(label)
	check:SetScript("OnClick", function(btn)
		set(btn:GetChecked() and true or false)
		ArtPad:RefreshOptions()
	end)
	if tooltip then
		check:SetScript("OnEnter", function(btn)
			GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
			GameTooltip:SetText(label)
			GameTooltip:AddLine(tooltip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		check:SetScript("OnLeave", GameTooltip_Hide)
	end
	check.Refresh = function() check:SetChecked(get()) end
	tinsert(widgets, check)
	return check
end

local function CreateButton(panel, label, width, onClick)
	local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	button:SetSize(width, 24)
	button:SetText(label)
	button:SetScript("OnClick", onClick)
	return button
end

function ArtPad:SetupOptions()
	local panel = CreateFrame("Frame", "ArtPad_OptionsPanel")
	panel.name = "ArtPad"
	self.optionsPanel = panel

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("ArtPad v" .. self.version)

	local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	sub:SetText("A shared canvas for your guild or group. Type /ap to open it.")

	local y = -70
	local function Place(widget, indent)
		widget:SetPoint("TOPLEFT", 16 + (indent or 0), y)
		y = y - 30
		return widget
	end

	local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", 16, y)
	header:SetText("Share drawings with")
	y = y - 22

	Place(CreateCheck(panel, "My guild", nil,
		function() return ArtPad_Settings.Mode == "GUILD" end,
		function() self:SetMode("GUILD") end), 8)
	Place(CreateCheck(panel, "My party / raid", "Includes instance groups.",
		function() return ArtPad_Settings.Mode == "RAID" end,
		function() self:SetMode("RAID") end), 8)
	Place(CreateCheck(panel, "Whoever's at the same place (local)", "For now: the Lion's Pride Inn in Goldshire.",
		function() return ArtPad_Settings.Mode == "LOCAL" end,
		function() self:SetMode("LOCAL") end), 8)

	y = y - 10
	Place(CreateCheck(panel, "Only show drawings from leaders and officers",
		"Party: the leader. Raid: leader and assistants. Guild: ranks up to the officer rank below.",
		function() return ArtPad_Settings.AdminOnly end,
		function(v) self:SetAdminOnly(v) end))

	-- Guild officer rank: -/+ stepper
	local rankLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	local minus = CreateButton(panel, "-", 24, function()
		ArtPad_Settings.AdminGuildRank = math.max(0, ArtPad_Settings.AdminGuildRank - 1)
		self.guildRanks = nil
		self:RefreshOptions()
	end)
	local plus = CreateButton(panel, "+", 24, function()
		ArtPad_Settings.AdminGuildRank = math.min(9, ArtPad_Settings.AdminGuildRank + 1)
		self.guildRanks = nil
		self:RefreshOptions()
	end)
	minus:SetPoint("TOPLEFT", 48, y)
	plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
	rankLabel:SetPoint("LEFT", plus, "RIGHT", 8, 0)
	rankLabel.Refresh = function()
		local rank = ArtPad_Settings.AdminGuildRank
		local names = {}
		if IsInGuild() and GuildControlGetRankName then
			for i = 0, rank do
				local name = GuildControlGetRankName(i + 1)
				if name and name ~= "" then table.insert(names, name) end
			end
		end
		rankLabel:SetText(("Guild officer ranks: 0-%d%s"):format(rank,
			#names > 0 and (" (" .. table.concat(names, ", ") .. ")") or ""))
	end
	tinsert(widgets, rankLabel)
	y = y - 40

	Place(CreateCheck(panel, "Show the names of people drawing", nil,
		function() return ArtPad_Settings.NameTags end,
		function(v) ArtPad_Settings.NameTags = v end))
	Place(CreateCheck(panel, "Show my name to others when I draw", nil,
		function() return ArtPad_Settings.ShowMyName end,
		function(v) ArtPad_Settings.ShowMyName = v end))
	Place(CreateCheck(panel, "Ask before clearing the canvas for everyone", nil,
		function() return ArtPad_Settings.WarnClear end,
		function(v) ArtPad_Settings.WarnClear = v end))
	Place(CreateCheck(panel, "Hide the canvas when entering combat", nil,
		function() return ArtPad_Settings.HideInCombat end,
		function(v) ArtPad_Settings.HideInCombat = v end))
	Place(CreateCheck(panel, "Show minimap button", nil,
		function() return not ArtPad_Settings.MinimapIcon.hide end,
		function(v) self:SetMinimapShown(v) end))
	Place(CreateCheck(panel, "Loopback test mode",
		"Sends your drawing to yourself through the server and only shows what comes back. Handy for testing on your own.",
		function() return self.loopback end,
		function(v) self:SetLoopback(v) end))

	y = y - 10
	local resync = CreateButton(panel, "Reload canvas from others", 200, function() self:Resync() end)
	resync:SetPoint("TOPLEFT", 16, y)
	local recenter = CreateButton(panel, "Fit canvas to screen", 180, function()
		self:ResetPosition()
	end)
	recenter:SetPoint("LEFT", resync, "RIGHT", 8, 0)
	local resetui = CreateButton(panel, "Reset window", 180, function()
		self:ResetAllFramePositions()
	end)
	resetui:SetPoint("LEFT", recenter, "RIGHT", 8, 0)

	panel:SetScript("OnShow", function() self:RefreshOptions() end)

	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, "ArtPad")
		Settings.RegisterAddOnCategory(category)
		self.optionsCategory = category
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
end

function ArtPad:RefreshOptions()
	for _, widget in ipairs(widgets) do
		widget.Refresh()
	end
	for _, s in ipairs(self.shareSwitches or {}) do s:Refresh() end
	if self.sharingPopover and self.sharingPopover:IsShown() then self:RefreshSharingPopover() end
end

function ArtPad:OpenOptions()
	if self.optionsCategory and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(self.optionsCategory:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		-- Called twice: the first call only opens the frame on some clients.
		InterfaceOptionsFrame_OpenToCategory(self.optionsPanel)
		InterfaceOptionsFrame_OpenToCategory(self.optionsPanel)
	end
end
