--[[
	Feedback: everything that tells you what ArtPad is doing.

	  Status bar   under the toolbar: who you're sharing with (click to switch), who's drawing
	               right now, and canvas loading progress.
	  Toasts       short messages with an optional action button, instead of chat spam.
	  Empty state  a hint in the middle of the screen while the canvas is blank.
	  Text ghost   a preview of your text following the cursor until you click to place it.

	Guidelines followed:
	  - Don't flash indicators for near-instant waits (SHOW_DELAY).
	  - Unknown duration -> animated "looking..." text; known size -> real progress bar.
	  - Waits never spin forever: failures end in a toast with a Retry action.
	  - Success/info toasts fade by themselves; errors stay longer.
	  - Transient things fade instead of popping.
]]

local ArtPad = ArtPad

local SHOW_DELAY = 0.3 -- seconds before showing a "looking for a canvas" indicator
local ACTIVE_WINDOW = 5 -- seconds someone counts as "drawing now"
local REFRESH_INTERVAL = 0.4
local TOAST_TIME = { info = 3.5, success = 3.5, warn = 5, error = 10 }

local COLORS = {
	ok = { 0.35, 0.85, 0.45 },
	warn = { 1, 0.62, 0.2 },
	test = { 0.75, 0.55, 1 },
	info = { 0.55, 0.75, 1 },
	success = { 0.35, 0.85, 0.45 },
	error = { 1, 0.35, 0.35 },
}

--[[ Fading ]]

local fades = {}
local fadeFrame = CreateFrame("Frame")
fadeFrame:Hide()
fadeFrame:SetScript("OnUpdate", function(frame, elapsed)
	local busy = false
	for region, f in pairs(fades) do
		f.t = f.t + elapsed
		local p = math.min(1, f.t / f.d)
		region:SetAlpha(f.from + (f.to - f.from) * p)
		if p >= 1 then
			fades[region] = nil
			if f.to == 0 then region:Hide() end
		else
			busy = true
		end
	end
	if not busy then frame:Hide() end
end)

-- Fade a frame/region to `to` alpha over `duration` seconds (hides it at 0).
function ArtPad.FadeTo(region, to, duration)
	if to > 0 and not region:IsShown() then
		region:SetAlpha(0)
		region:Show()
	end
	if not region:IsShown() then return end
	fades[region] = { from = region:GetAlpha(), to = to, d = duration or 0.2, t = 0 }
	fadeFrame:Show()
end

local function Background(frame, alpha)
	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetColorTexture(0, 0, 0, alpha or 0.7)
	bg:SetAllPoints()
	return bg
end

--[[ Toasts ]]

-- kind: "info" | "success" | "warn" | "error".
-- opts: { action = { label, func }, duration = seconds (false = until dismissed), quiet = true }
-- While the canvas is closed, toasts go to chat instead, unless opts.quiet.
function ArtPad:Notify(msg, kind, opts)
	kind, opts = kind or "info", opts or {}
	local toast = self.toast
	if not (toast and self.mainFrame:IsShown()) then
		if not opts.quiet then self:Message(msg) end
		return
	end
	local c = COLORS[kind] or COLORS.info
	toast.stripe:SetColorTexture(c[1], c[2], c[3], 1)
	toast.text:SetText(msg)
	toast.kind = kind
	local width = toast.text:GetStringWidth() + 32
	if opts.action then
		toast.action:SetText(opts.action[1])
		toast.action:SetWidth(toast.action:GetTextWidth() + 24)
		toast.action.func = opts.action[2]
		toast.action:Show()
		width = width + toast.action:GetWidth() + 10
	else
		toast.action:Hide()
	end
	toast:SetWidth(math.max(200, width))
	-- An error you can act on (e.g. Retry) stays until you deal with it.
	if opts.duration == nil and kind == "error" and opts.action then
		opts.duration = false
	end
	if opts.duration == false then
		toast.expires = nil
	else
		toast.expires = GetTime() + (opts.duration or TOAST_TIME[kind] or 4)
	end
	self.FadeTo(toast, 1, 0.15)
end

function ArtPad:DismissToast()
	if self.toast and self.toast:IsShown() then
		self.toast.expires = nil
		self.FadeTo(self.toast, 0, 0.25)
	end
end

local function ToastOnUpdate(toast)
	if toast.expires and GetTime() >= toast.expires and not toast:IsMouseOver() then
		toast.expires = nil
		ArtPad.FadeTo(toast, 0, 0.4)
	end
end

--[[ Status bar ]]

local function JoinNames(names)
	if #names == 1 then return names[1] .. " is drawing" end
	if #names == 2 then return names[1] .. " and " .. names[2] .. " are drawing" end
	return ("%s, %s and %d more are drawing"):format(names[1], names[2], #names - 2)
end

-- Returns label, colour key, longer description.
function ArtPad:GetSharingState()
	if self.loopback then
		return "Loopback test", "test", "Your drawing goes through the server and back to you only."
	end
	if ArtPad_Settings.Mode == "GUILD" then
		if IsInGuild() then
			return "Guild", "ok", "Everyone in your guild with ArtPad sees this canvas."
		end
		return "Not shared", "warn", "You're not in a guild, so only you can see this. Click to share with your party/raid instead."
	end
	local channel = self:GetChannel()
	if not channel then
		return "Not shared", "warn", "You're not in a group, so only you can see this. Click to share with your guild instead."
	end
	local label = channel == "INSTANCE_CHAT" and "Instance group" or (channel == "RAID" and "Raid" or "Party")
	return ("%s (%d)"):format(label, GetNumGroupMembers()), "ok",
		"Everyone in your " .. label:lower() .. " with ArtPad sees this canvas."
end

function ArtPad:MarkActive(author)
	self.activeArtists[author] = GetTime()
	self:RequestRefresh()
end

function ArtPad:HasUndo()
	for i = #self.undoStack, 1, -1 do
		if self.itemsById[self.undoStack[i]] then return true end
	end
	return false
end

function ArtPad:RequestRefresh()
	self.refreshPending = true
end

function ArtPad:RefreshStatus()
	if not self.statusBar then return end
	self.refreshPending = false
	local now = GetTime()

	-- Sharing pill
	local label, colorKey = self:GetSharingState()
	local c = COLORS[colorKey]
	local pill = self.sharingButton
	pill.dot:SetVertexColor(c[1], c[2], c[3], 1)
	pill.text:SetText(label)
	pill:SetWidth(pill.text:GetStringWidth() + 26)

	-- Right side: loading progress takes priority over activity
	local phase = self.syncPhase
	if phase == "searching" and now - (self.syncStarted or now) >= SHOW_DELAY then
		local dots = string.rep(".", math.floor(now * 3) % 4)
		self.syncText:SetText("Looking for a canvas to load" .. dots)
		self.syncText:Show()
		self.syncBar:Hide()
		self.activityText:Hide()
	elseif phase == "downloading" then
		local pct = self.syncProgress or 0
		self.syncText:SetText(("Loading canvas from %s  %d%%"):format(self.ShortName(self.syncSource or "?"), pct))
		self.syncBar:SetValue(pct)
		self.syncText:Show()
		self.syncBar:Show()
		self.activityText:Hide()
	else
		self.syncText:Hide()
		self.syncBar:Hide()
		local names = {}
		for name, t in pairs(self.activeArtists) do
			if now - t <= ACTIVE_WINDOW then
				table.insert(names, name)
			else
				self.activeArtists[name] = nil
			end
		end
		table.sort(names)
		if #names > 0 then
			self.activityText:SetText(JoinNames(names))
			self.activityText:Show()
		else
			self.activityText:Hide()
		end
	end

	if self.UpdateMapButton then self:UpdateMapButton() end

	-- Undo button reflects whether there's anything to undo
	if self.undoButton then
		if self:HasUndo() then self.undoButton:Enable() else self.undoButton:Disable() end
	end

	-- Empty state
	-- Keep the hint up while merely searching (usually nobody answers, and you can draw meanwhile);
	-- only step aside once a canvas is actually on its way.
	local wantHint = #self.items == 0 and self.syncPhase ~= "downloading" and self.state ~= "PAINT"
	if wantHint and not self.emptyHint:IsShown() then
		local _, _, desc = self:GetSharingState()
		self.emptyHint.sharing:SetText(desc)
		self.FadeTo(self.emptyHint, 1, 0.3)
	elseif wantHint then
		local _, _, desc = self:GetSharingState()
		self.emptyHint.sharing:SetText(desc)
	elseif self.emptyHint:IsShown() and not fades[self.emptyHint] then
		self.FadeTo(self.emptyHint, 0, 0.2)
	end
end

local function RefresherOnUpdate(frame, elapsed)
	frame.t = (frame.t or 0) + elapsed
	local self = ArtPad
	-- Animate while searching; otherwise refresh when something changed or periodically
	if self.refreshPending or frame.t >= REFRESH_INTERVAL or self.syncPhase == "searching" then
		frame.t = 0
		self:RefreshStatus()
	end
end

--[[ Text placement preview ]]

function ArtPad:BeginTextPlacement(text)
	self.pendingText = text
	self.state = "TEXT"
	local c = self.brushColor
	self.ghostText:SetText(text)
	self.ghostText:SetTextColor(c.r, c.g, c.b, 0.6)
	self:UpdateGhost()
	self.ghostText:Show()
	self:Notify("Click the canvas to place your text.  Esc to cancel.", "info", { duration = false })
end

function ArtPad:EndTextPlacement()
	self.pendingText = nil
	if self.state == "TEXT" then self.state = "SLEEP" end
	self.ghostText:Hide()
	self:DismissToast()
end

function ArtPad:UpdateGhost()
	local f = self.mainFrame
	local mx, my = GetCursorPosition()
	local scale = f:GetScale()
	self.ghostText:ClearAllPoints()
	self.ghostText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", mx / scale - f:GetLeft(), my / scale - f:GetBottom())
end

--[[ Setup ]]

function ArtPad:SetupFeedback()
	self.activeArtists = {}
	local controls = self.controlsFrame

	-- Status bar
	local bar = CreateFrame("Frame", "ArtPad_StatusBar", controls)
	bar:SetHeight(24)
	bar:SetPoint("TOPLEFT", controls, "BOTTOMLEFT", 0, -1)
	bar:SetPoint("TOPRIGHT", controls, "BOTTOMRIGHT", 0, -1)
	Background(bar, 0.6)
	self.statusBar = bar

	local pill = CreateFrame("Button", "ArtPad_SharingButton", bar)
	pill:SetHeight(20)
	pill:SetPoint("LEFT", 6, 0)
	pill.dot = pill:CreateTexture(nil, "ARTWORK")
	pill.dot:SetTexture(self.MEDIA .. "dot")
	pill.dot:SetSize(10, 10)
	pill.dot:SetPoint("LEFT", 2, 0)
	pill.text = pill:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	pill.text:SetPoint("LEFT", pill.dot, "RIGHT", 6, 0)
	local hl = pill:CreateTexture(nil, "HIGHLIGHT")
	hl:SetColorTexture(1, 1, 1, 0.08)
	hl:SetAllPoints()
	pill:SetScript("OnClick", function()
		self:SetMode(ArtPad_Settings.Mode == "GUILD" and "RAID" or "GUILD")
	end)
	pill:SetScript("OnEnter", function(btn)
		local label, _, desc = self:GetSharingState()
		GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText("Sharing: " .. label)
		GameTooltip:AddLine(desc, 1, 1, 1, true)
		GameTooltip:AddLine("Click to switch between guild and party/raid.", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	pill:SetScript("OnLeave", GameTooltip_Hide)
	self.sharingButton = pill

	self.activityText = bar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.activityText:SetPoint("RIGHT", -10, 0)
	self.activityText:SetTextColor(1, 0.82, 0)

	local syncBar = CreateFrame("StatusBar", "ArtPad_SyncProgress", bar)
	syncBar:SetSize(140, 8)
	syncBar:SetPoint("RIGHT", -10, 0)
	syncBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	syncBar:SetStatusBarColor(COLORS.info[1], COLORS.info[2], COLORS.info[3], 1)
	syncBar:SetMinMaxValues(0, 100)
	syncBar:SetValue(0)
	local track = syncBar:CreateTexture(nil, "BACKGROUND")
	track:SetColorTexture(1, 1, 1, 0.15)
	track:SetAllPoints()
	syncBar:Hide()
	self.syncBar = syncBar

	self.syncText = bar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.syncText:SetPoint("RIGHT", syncBar, "LEFT", -8, 0)
	self.syncText:Hide()

	local refresher = CreateFrame("Frame", nil, bar)
	refresher:SetScript("OnUpdate", RefresherOnUpdate)
	refresher:SetScript("OnShow", function() self:RefreshStatus() end)

	-- Toast
	local toast = CreateFrame("Frame", "ArtPad_Toast", controls)
	toast:SetHeight(28)
	toast:SetPoint("TOP", bar, "BOTTOM", 0, -6)
	toast:SetFrameStrata("TOOLTIP")
	Background(toast, 0.8)
	toast.stripe = toast:CreateTexture(nil, "ARTWORK")
	toast.stripe:SetWidth(4)
	toast.stripe:SetPoint("TOPLEFT")
	toast.stripe:SetPoint("BOTTOMLEFT")
	toast.text = toast:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	toast.text:SetPoint("LEFT", 14, 0)
	local action = CreateFrame("Button", "ArtPad_ToastAction", toast, "UIPanelButtonTemplate")
	action:SetHeight(22)
	action:SetPoint("RIGHT", -4, 0)
	action:SetScript("OnClick", function(btn)
		local func = btn.func
		self:DismissToast()
		if func then func() end
	end)
	toast.action = action
	toast:EnableMouse(true)
	toast:SetScript("OnUpdate", ToastOnUpdate)
	toast:Hide()
	self.toast = toast

	-- Empty state: pinned to the middle of the canvas so it moves with it, but parented to the
	-- UI so the text stays a normal readable size at any zoom.
	local hint = CreateFrame("Frame", "ArtPad_EmptyHint", controls)
	hint:SetSize(1, 1)
	hint:SetPoint("CENTER", self.mainFrame, "CENTER")
	hint.title = hint:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
	hint.title:SetPoint("BOTTOM", hint, "CENTER", 0, 10)
	hint.title:SetText("Draw something!")
	hint.body = hint:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	hint.body:SetPoint("TOP", hint, "CENTER", 0, -4)
	hint.body:SetSpacing(6)
	hint.body:SetText("Left-drag to draw   ·   Right-drag to erase   ·   Ctrl-Z to undo\n"
		.. "Drag the bar above the canvas to move it   ·   Mouse wheel to zoom")
	hint.sharing = hint:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	hint.sharing:SetPoint("TOP", hint.body, "BOTTOM", 0, -12)
	hint:Hide()
	self.emptyHint = hint

	-- Text placement preview
	self.ghostText = self.mainFrame:CreateFontString(nil, "OVERLAY")
	self.ghostText:SetFont(self.FONT, 14, "")
	self.ghostText:Hide()
end
