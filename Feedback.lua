--[[
	Feedback: the status bar, toasts, the empty and loading states, the sharing pill,
	presence, the mini bar and the text placement preview.

	  - No indicator for near-instant waits (SHOW_DELAY).
	  - Searching shows a short status line; downloading shows real progress.
	  - Failures end in a toast with Retry; info toasts fade by themselves.
]]

local ArtPad = ArtPad
local C = ArtPad.C

local SHOW_DELAY = 0.3 -- seconds before showing "looking for a canvas"
local ACTIVE_WINDOW = 5 -- seconds someone counts as "drawing now"
local PRESENCE_WINDOW = 60 -- seconds someone stays in the title bar after drawing
local REFRESH_INTERVAL = 0.4
local TOAST_TIME = { info = 3.5, success = 3.5, warn = 5, error = 10 }

local COLORS = {
	ok = C.ok,
	warn = C.warn,
	test = { 0.69, 0.49, 1 },
	info = { 0.30, 0.55, 1 },
	success = C.ok,
	error = { 1, 0.56, 0.52 },
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

--[[ Toasts ]]

-- kind: "info" | "success" | "warn" | "error".
-- opts: { action = { label, func }, duration = seconds (false = until dismissed), quiet = true }
-- While the window is closed, toasts go to chat instead, unless opts.quiet.
function ArtPad:Notify(msg, kind, opts)
	kind, opts = kind or "info", opts or {}
	local toast = self.toast
	if not (toast and self.window:IsShown()) then
		if not opts.quiet then self:Message(msg) end
		return
	end
	local c = COLORS[kind] or COLORS.info
	toast.dot:SetVertexColor(c[1], c[2], c[3], 1)
	toast.text:SetText(msg)
	toast.kind = kind
	local width = toast.text:GetStringWidth() + 44
	if opts.action then
		toast.action.label:SetText(opts.action[1])
		toast.action:SetWidth(toast.action.label:GetStringWidth() + 24)
		toast.action.func = opts.action[2]
		toast.action:Show()
		width = width + toast.action:GetWidth() + 10
	else
		toast.action:Hide()
	end
	toast:SetWidth(math.max(180, width))
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

--[[ Sharing state ]]

local function JoinNames(names)
	if #names == 1 then return names[1] .. " drawing" end
	if #names == 2 then return names[1] .. ", " .. names[2] .. " drawing" end
	return ("%s, %s +%d drawing"):format(names[1], names[2], #names - 2)
end

-- Returns pill label, colour key, and who can see the canvas.
function ArtPad:GetSharingState()
	if self.loopback then
		return "Loopback test", "test", "Only you, through the server."
	end
	if ArtPad_Settings.Mode == "GUILD" then
		if IsInGuild() then
			return "Guild", "ok", "Your guild sees what you draw."
		end
		return "Not shared", "warn", "Only you can see this. You're not in a guild."
	end
	local channel = self:GetChannel()
	if not channel then
		return "Not shared", "warn", "Only you can see this. You're not in a group."
	end
	local label = channel == "INSTANCE_CHAT" and "Instance" or (channel == "RAID" and "Raid" or "Party")
	return ("%s · %d"):format(label, GetNumGroupMembers()), "ok",
		"Your " .. (label == "Instance" and "group" or label:lower()) .. " sees what you draw."
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

local function SyncRemaining(self)
	local pct = self.syncProgress or 0
	if pct <= 0 or not self.syncDownloadStarted then return nil end
	local elapsed = GetTime() - self.syncDownloadStarted
	return math.max(1, math.floor(elapsed * (100 - pct) / pct + 0.5))
end

function ArtPad:RefreshStatus()
	if not self.statusBar then return end
	self.refreshPending = false
	local now = GetTime()

	-- Sharing pill + mini bar
	local label, colorKey = self:GetSharingState()
	local c = COLORS[colorKey]
	local pill = self.sharingButton

	-- Who's drawing
	local active, present = {}, {}
	for name, t in pairs(self.activeArtists) do
		if now - t <= ACTIVE_WINDOW then table.insert(active, name) end
		if now - t <= PRESENCE_WINDOW then
			table.insert(present, name)
		else
			self.activeArtists[name] = nil
		end
	end
	table.sort(active)
	table.sort(present)
	self:RefreshPresence(present)

	-- Status bar: sharing pill (dot shows sync state), then loading or activity
	local phase = self.syncPhase
	local dc = phase == "downloading" and COLORS.info or (colorKey == "ok" and C.ok or c)
	pill.dot:SetVertexColor(dc[1], dc[2], dc[3], 1)
	pill.text:SetText(label)
	pill:SetWidth(pill.text:GetStringWidth() + 28)
	if phase == "searching" and now - (self.syncStarted or now) >= SHOW_DELAY then
		self.syncText:SetText("Looking for a canvas" .. string.rep(".", math.floor(now * 3) % 4))
		self.syncText:Show()
		self.activityText:Hide()
	elseif phase == "downloading" then
		local pct = self.syncProgress or 0
		self.syncText:SetText(("Loading from %s  %d%%"):format(self.ShortName(self.syncSource or "?"), pct))
		self.syncText:Show()
		self.activityText:Hide()
	else
		self.syncText:Hide()
		if #active > 0 then
			self.activityText:SetText(JoinNames(active))
			self.activityText:Show()
		else
			self.activityText:Hide()
		end
	end

	-- Loading card
	if phase == "downloading" then
		local pct = self.syncProgress or 0
		self.loadingCard.title:SetText("Loading from " .. self.ShortName(self.syncSource or "?"))
		self.syncBar:SetValue(pct)
		self.loadingCard.pct:SetText(pct .. "%")
		local left = SyncRemaining(self)
		self.loadingCard.eta:SetText(left and ("~" .. left .. "s") or "")
		self.loadingCard:Show()
	else
		self.loadingCard:Hide()
	end

	-- Undo reflects whether there's anything to undo
	if self.undoButton then
		if self:HasUndo() then self.undoButton:Enable() else self.undoButton:Disable() end
		self.undoButton:SetAlpha(self:HasUndo() and 1 or 0.35)
	end

	self:UpdateTitle()

	-- Empty state: stays up while merely searching; steps aside once a canvas is on its way
	local wantHint = #self.items == 0 and phase ~= "downloading" and self.state ~= "PAINT"
	if wantHint then
		local _, _, desc = self:GetSharingState()
		self.emptyHint.sharing:SetText(desc)
		self.emptyHint.Layout()
		if not self.emptyHint:IsShown() then self.FadeTo(self.emptyHint, 1, 0.3) end
	elseif self.emptyHint:IsShown() and not fades[self.emptyHint] then
		self.FadeTo(self.emptyHint, 0, 0.2)
	end
end

local function RefresherOnUpdate(frame, elapsed)
	frame.t = (frame.t or 0) + elapsed
	local self = ArtPad
	if not self.window:IsShown() then return end
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
	self:Notify("Click to place. Esc to cancel.", "info", { duration = false })
end

function ArtPad:EndTextPlacement()
	self.pendingText = nil
	if self.state == "TEXT" then self.state = "SLEEP" end
	self.ghostText:Hide()
	self:DismissToast()
end

function ArtPad:UpdateGhost()
	local x, y = self.CursorOnCanvas(self.mainFrame)
	self.ghostText:ClearAllPoints()
	self.ghostText:SetPoint("BOTTOMLEFT", self.mainFrame, "BOTTOMLEFT", x, y)
end

--[[ Setup ]]

function ArtPad:SetupFeedback()
	self.activeArtists = {}
	local status, viewport = self.statusBar, self.viewport

	-- Status bar
	-- The sharing pill (Tools.lua) sits at the start; activity and loading follow it.
	self.activityText = status:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.activityText:SetPoint("LEFT", self.sharingButton, "RIGHT", 12, 0)
	self.syncText = status:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.syncText:SetPoint("LEFT", self.sharingButton, "RIGHT", 12, 0)
	self.syncText:Hide()

	-- Always-running refresher (also keeps the mini bar current)
	local refresher = CreateFrame("Frame")
	refresher:SetScript("OnUpdate", RefresherOnUpdate)
	self.refresher = refresher

	-- Toast, top of the canvas
	local toast = CreateFrame("Frame", "ArtPad_Toast", self.window)
	toast:SetHeight(32)
	toast:SetPoint("TOP", viewport, "TOP", 0, -12)
	toast:SetFrameLevel(self.window:GetFrameLevel() + 30)
	self.Background(toast, C.bar, 0.97)
	toast.dot = toast:CreateTexture(nil, "ARTWORK")
	toast.dot:SetTexture(self.MEDIA .. "dot")
	toast.dot:SetSize(8, 8)
	toast.dot:SetPoint("LEFT", 12, 0)
	toast.text = toast:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	toast.text:SetPoint("LEFT", toast.dot, "RIGHT", 10, 0)
	local action = self:FlatButton(toast, "ArtPad_ToastAction", 60, 24, "", function(btn)
		local func = btn.func
		self:DismissToast()
		if func then func() end
	end)
	action:SetPoint("RIGHT", -5, 0)
	self.Fill(action.bg, C.accent)
	action.label:SetTextColor(0.1, 0.08, 0.02)
	toast.action = action
	toast:EnableMouse(true)
	toast:SetScript("OnUpdate", ToastOnUpdate)
	toast:Hide()
	self.toast = toast

	-- Empty state, centred on the canvas area
	-- (a child of the viewport, so it's clipped to the canvas area like everything else there)
	local hint = CreateFrame("Frame", "ArtPad_EmptyHint", viewport)
	hint:SetSize(1, 1)
	hint:SetPoint("CENTER", viewport, "CENTER")
	hint:SetFrameLevel(viewport:GetFrameLevel() + 10)
	hint.title = hint:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
	hint.title:SetPoint("BOTTOM", hint, "CENTER", 0, 10)
	hint.title:SetText("Draw something!")
	hint.body = hint:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	hint.body:SetPoint("TOP", hint, "CENTER", 0, -4)
	hint.body:SetSpacing(6)
	hint.sharing = hint:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	hint.sharing:SetPoint("TOP", hint.body, "BOTTOM", 0, -12)
	-- Fit the hint to the canvas area: two rows when there's room, one control per line when not.
	function hint.Layout()
		local vw = self:ViewportSize()
		local width = math.max(60, vw - 32)
		for _, fs in ipairs({ hint.title, hint.body, hint.sharing }) do
			fs:SetWidth(width)
			fs:SetWordWrap(true)
		end
		if vw >= 520 then
			hint.body:SetText("Left-drag to draw   ·   Right-drag to pan   ·   Mouse wheel to zoom\n"
				.. "Ctrl-Z to undo   ·   [ ] to change brush size")
		else
			hint.body:SetText("Left-drag to draw\nRight-drag to pan\nMouse wheel to zoom\nCtrl-Z to undo")
		end
	end
	hint.Layout()
	hint:Hide()
	self.emptyHint = hint

	-- Loading card, centred on the canvas area
	local card = CreateFrame("Frame", "ArtPad_LoadingCard", self.window)
	card:SetSize(300, 78)
	card:SetPoint("CENTER", viewport, "CENTER")
	card:SetFrameLevel(self.window:GetFrameLevel() + 12)
	self.Background(card, C.bar, 0.97)
	card.title = card:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	card.title:SetPoint("TOPLEFT", 16, -14)
	local bar = CreateFrame("StatusBar", "ArtPad_SyncProgress", card)
	bar:SetSize(268, 6)
	bar:SetPoint("TOPLEFT", 16, -38)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:SetStatusBarColor(COLORS.info[1], COLORS.info[2], COLORS.info[3], 1)
	bar:SetMinMaxValues(0, 100)
	bar:SetValue(0)
	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetColorTexture(1, 1, 1, 0.12)
	track:SetAllPoints()
	card.pct = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	card.pct:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -8)
	card.eta = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	card.eta:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -8)
	card:Hide()
	self.loadingCard = card
	self.syncBar = bar

	-- Text placement preview
	self.ghostText = self.overlay:CreateFontString(nil, "OVERLAY")
	self.ghostText:SetFont(self.FONT, 14, "")
	self.ghostText:Hide()
end
