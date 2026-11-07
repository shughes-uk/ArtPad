--[[
	The ArtPad window and canvas input.

	  Window     one movable, resizable window: title bar (drag to move), tool rail on the
	             left, inspector on the right, status bar at the bottom, canvas in the middle.
	  Viewport   clips the canvas; mouse wheel zooms at the cursor, middle-drag pans, Fit
	             fits it. The canvas is a fixed 3840x2160 surface, so everyone's coordinates
	             match whatever their window size or zoom.
	  Mini bar   the minimised window: a small pill that still shows who's drawing.
]]

local ArtPad = ArtPad

ArtPad.canvasSize = { X = 3840, Y = 2160 }
ArtPad.state = "SLEEP" -- SLEEP, PAINT, ERASE, SHAPE, TEXT, PAN, LASER

local MIN_SEGMENT = 3 -- minimum distance (canvas px) between recorded points
local NAME_TAG_HOLD, NAME_TAG_FADE = 2, 1 -- seconds
local NAME_TAG_FONT_SIZE = 14 -- as it appears on screen, regardless of canvas zoom

-- Window layout
local TITLE_H, STATUS_H, RAIL_W, INSPECTOR_W = 40, 26, 48, 220
local DEFAULT_W, DEFAULT_H = 1000, 640
local MIN_W, MIN_H = 620, 420 -- MIN_H grows to fit the rail and inspector (see FitContent)
ArtPad.layout = { TITLE_H = TITLE_H, STATUS_H = STATUS_H, RAIL_W = RAIL_W, INSPECTOR_W = INSPECTOR_W }

-- Palette
local C = {
	window = { 0.082, 0.094, 0.110 }, -- #15181c
	bar = { 0.110, 0.125, 0.145 }, -- #1c2025
	panel = { 0.102, 0.114, 0.133 }, -- #1a1d22
	canvas = { 0.035, 0.039, 0.047 }, -- #090a0c, the margin around the canvas
	line = { 0.169, 0.188, 0.216 }, -- #2b3037
	text = { 0.906, 0.914, 0.925 },
	muted = { 0.604, 0.639, 0.678 },
	accent = { 0.910, 0.690, 0.294 }, -- #e8b04b
	ok = { 0.33, 0.78, 0.44 },
	warn = { 0.96, 0.63, 0.26 },
	danger = { 0.90, 0.33, 0.29 },
}
ArtPad.C = C

-- Keys bound while the window is open, and brush-size keys bound only while the mouse is
-- over the canvas.
ArtPad.windowKeys = { ESCAPE = "ArtPad_CloseButton", ["CTRL-Z"] = "ArtPad_UndoButton" }
ArtPad.canvasKeys = { ["["] = "ArtPad_BrushSmaller", ["]"] = "ArtPad_BrushBigger" }

--[[ Small widget helpers ]]

function ArtPad.Fill(region, c, a)
	region:SetColorTexture(c[1], c[2], c[3], a or 1)
end

local function Tooltip(frame, title, line)
	frame:SetScript("OnEnter", function(f)
		GameTooltip:SetOwner(f, "ANCHOR_BOTTOM")
		GameTooltip:SetText(f.tipTitle or title)
		if f.tipLine or line then GameTooltip:AddLine(f.tipLine or line, 1, 1, 1, true) end
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", GameTooltip_Hide)
end
ArtPad.Tooltip = Tooltip

-- A flat button: dark fill, lighter on hover, optional text.
function ArtPad:FlatButton(parent, name, w, h, label, onClick)
	local b = CreateFrame("Button", name, parent)
	b:SetSize(w, h)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	self.Fill(b.bg, { 0.137, 0.157, 0.188 })
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	if label then
		b.label = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		b.label:SetPoint("CENTER")
		b.label:SetText(label)
	end
	b:RegisterForClicks("LeftButtonUp")
	if onClick then b:SetScript("OnClick", onClick) end
	return b
end

-- An on/off switch drawn like the design: track + knob.
function ArtPad:Switch(parent, name, get, set)
	local s = CreateFrame("Button", name, parent)
	s:SetSize(34, 20)
	s.track = s:CreateTexture(nil, "BACKGROUND")
	s.track:SetAllPoints()
	s.knob = s:CreateTexture(nil, "ARTWORK")
	s.knob:SetTexture(self.MEDIA .. "dot")
	s.knob:SetSize(16, 16)
	s:SetScript("OnClick", function()
		set(not get())
		s:Refresh()
	end)
	function s.Refresh()
		local on = get()
		s.knob:ClearAllPoints()
		if on then
			ArtPad.Fill(s.track, C.accent)
			s.knob:SetVertexColor(0.1, 0.08, 0.02, 1)
			s.knob:SetPoint("RIGHT", -2, 0)
		else
			s.track:SetColorTexture(0.23, 0.25, 0.29, 1)
			s.knob:SetVertexColor(0.79, 0.81, 0.83, 1)
			s.knob:SetPoint("LEFT", 2, 0)
		end
		s.on = on
	end
	s:Refresh()
	return s
end

-- A plain horizontal slider.
function ArtPad:FlatSlider(parent, name, min, max, step, onChange)
	local s = CreateFrame("Slider", name, parent)
	s:SetOrientation("HORIZONTAL")
	s:SetHeight(16)
	s:SetMinMaxValues(min, max)
	s:SetValueStep(step)
	if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
	local track = s:CreateTexture(nil, "BACKGROUND")
	track:SetHeight(4)
	track:SetPoint("LEFT")
	track:SetPoint("RIGHT")
	track:SetColorTexture(0.18, 0.21, 0.24, 1)
	local thumb = s:CreateTexture(nil, "ARTWORK")
	thumb:SetTexture(self.MEDIA .. "dot")
	thumb:SetSize(14, 14)
	thumb:SetVertexColor(0.95, 0.95, 0.96, 1)
	s:SetThumbTexture(thumb)
	s:SetScript("OnValueChanged", function(_, value, userInput)
		if s.updating then return end
		onChange(value, userInput)
	end)
	function s.Set(value)
		s.updating = true
		s:SetValue(value)
		s.updating = false
	end
	return s
end

--[[ Brush ]]

-- Canvas units per on-screen UI pixel at the current zoom. Brush, eraser, marker and text
-- sizes are chosen in screen pixels and stored in canvas units, so they look the size you
-- picked and land the same size on everyone's canvas.
function ArtPad:CanvasPerPixel()
	if not self.mainFrame then return 1 end
	return UIParent:GetEffectiveScale() / self.mainFrame:GetEffectiveScale()
end

function ArtPad:BrushWidth()
	return math.max(1, math.min(self.MAX_WIDTH, math.floor(ArtPad_Settings.BrushSize * self:CanvasPerPixel() + 0.5)))
end

function ArtPad:GetEraserRadius()
	return (4 + ArtPad_Settings.BrushSize) * self:CanvasPerPixel()
end

function ArtPad:SetBrushSize(n)
	ArtPad_Settings.BrushSize = math.max(1, math.min(self.MAX_WIDTH, math.floor(n)))
	if self.RefreshInspector then self:RefreshInspector() end
end

function ArtPad:SetColor(r, g, b, a)
	local c = self.brushColor
	c.r, c.g, c.b, c.a = r, g, b, a
	ArtPad_Settings.Color = { r = r, g = g, b = b, a = a }
	if self.RefreshInspector then self:RefreshInspector() end
end

function ArtPad:OpenColorPicker()
	self.pickerOpen = true -- so the chosen colour is added to the recent swatches
	local c = self.brushColor
	local function Apply()
		local r, g, b = ColorPickerFrame:GetColorRGB()
		local a
		if ColorPickerFrame.GetColorAlpha then
			a = ColorPickerFrame:GetColorAlpha()
		elseif OpacitySliderFrame then
			a = OpacitySliderFrame:GetValue()
		end
		self:SetColor(r, g, b, a or c.a)
	end

	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({
			r = c.r, g = c.g, b = c.b,
			opacity = c.a,
			hasOpacity = true,
			swatchFunc = Apply,
			opacityFunc = Apply,
			cancelFunc = function(prev)
				self:SetColor(prev.r, prev.g, prev.b, prev.opacity or prev.a or c.a)
			end,
		})
	else
		ColorPickerFrame:SetColorRGB(c.r, c.g, c.b)
		ColorPickerFrame.hasOpacity, ColorPickerFrame.opacity = true, c.a
		ColorPickerFrame.previousValues = { c.r, c.g, c.b, c.a }
		ColorPickerFrame.func, ColorPickerFrame.opacityFunc = Apply, Apply
		ColorPickerFrame.cancelFunc = function(prev)
			self:SetColor(unpack(prev))
		end
		ColorPickerFrame:Hide() -- re-run OnShow
		ColorPickerFrame:Show()
	end
	ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
end

--[[ View: zoom, pan, fit ]]

-- Size of the area the canvas is shown in, in the window's own units.
function ArtPad:ViewportSize()
	local w = self.window:GetWidth() - RAIL_W - INSPECTOR_W
	local h = self.window:GetHeight() - TITLE_H - STATUS_H
	return math.max(1, w), math.max(1, h)
end

-- scale = canvas scale; ox, oy = canvas offset from the viewport's bottom-left, in canvas units.
-- The view never shows more than the canvas: zoom out stops at "whole canvas" (fit), zoom in
-- at MAX_ZOOM x that, and panning keeps the canvas covering the view on each axis where it's
-- bigger than the view, centred where it's smaller.
local FIT_MARGIN, MAX_ZOOM = 0.96, 6

function ArtPad:FitScale()
	local vw, vh = self:ViewportSize()
	return FIT_MARGIN * math.min(vw / self.canvasSize.X, vh / self.canvasSize.Y)
end

local function ClampOffset(offset, scale, size, viewSize)
	local span = size * scale
	if span <= viewSize then return (viewSize - span) / 2 / scale end
	return math.max(viewSize - span, math.min(0, offset * scale)) / scale
end

function ArtPad:SetView(scale, ox, oy)
	local vw, vh = self:ViewportSize()
	local fit = self:FitScale()
	scale = math.max(fit, math.min(fit * MAX_ZOOM, scale))
	ox = ClampOffset(ox, scale, self.canvasSize.X, vw)
	oy = ClampOffset(oy, scale, self.canvasSize.Y, vh)
	local f = self.mainFrame
	f:SetScale(scale)
	f:ClearAllPoints()
	f:SetPoint("BOTTOMLEFT", self.viewport, "BOTTOMLEFT", ox, oy)
	self.view = { scale, ox, oy }
	if self.RefreshZoomLabel then self:RefreshZoomLabel() end
end

function ArtPad:SaveView()
	ArtPad_Settings.View = { self.view[1], self.view[2], self.view[3] }
end

function ArtPad:FitToView()
	self:SetView(self:FitScale(), 0, 0) -- centred by SetView
end
ArtPad.FitToScreen = ArtPad.FitToView

function ArtPad:ResetPosition()
	ArtPad_Settings.View = false
	self:FitToView()
end

function ArtPad:RestoreView()
	local v = ArtPad_Settings.View
	if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
		self:SetView(v[1], v[2], v[3])
	else
		self:FitToView()
	end
end

-- Zoom by `factor`, keeping the canvas point under the viewport position (vx, vy) still.
function ArtPad:ZoomAt(factor, vx, vy)
	local s, ox, oy = self.view[1], self.view[2], self.view[3]
	local fit = self:FitScale()
	local s2 = math.max(fit, math.min(fit * MAX_ZOOM, s * factor))
	if math.abs(s2 - s) < 1e-9 then return end
	local cx, cy = vx / s - ox, vy / s - oy
	self:SetView(s2, vx / s2 - cx, vy / s2 - cy)
	self:SaveView()
end

function ArtPad:ZoomCentered(factor)
	local vw, vh = self:ViewportSize()
	self:ZoomAt(factor, vw / 2, vh / 2)
end

local function CursorOnCanvas(f)
	local mx, my = GetCursorPosition()
	local scale = f:GetEffectiveScale()
	return math.floor(mx / scale - f:GetLeft()), math.floor(my / scale - f:GetBottom())
end
ArtPad.CursorOnCanvas = CursorOnCanvas

-- Cursor position inside the viewport, in viewport units.
function ArtPad:CursorOnViewport()
	local mx, my = GetCursorPosition()
	local v = self.viewport
	local scale = v:GetEffectiveScale()
	return mx / scale - v:GetLeft(), my / scale - v:GetBottom()
end

function ArtPad:UpdateTitle()
	if not self.titleNote then return end
	if self.newerVersion then
		self.titleNote:SetText("|cffff8f84Update available: v" .. self.newerVersion .. "|r")
	elseif self.backdropMap and self.GetMapName then
		self.titleNote:SetText(self:GetMapName(self.backdropMap) or "")
	else
		self.titleNote:SetText("")
	end
end

--[[ Name tags ]]

function ArtPad:ShowNameTag(author, x, y)
	if not ArtPad_Settings.NameTags or not x then return end
	local tag = self.nameTags[author]
	-- Size tags in canvas units so they come out like normal UI text at the current zoom.
	local k = UIParent:GetEffectiveScale() / self.mainFrame:GetEffectiveScale()
	local size = math.max(8, math.min(200, NAME_TAG_FONT_SIZE * k))
	if not tag then
		tag = self.overlay:CreateFontString(nil, "OVERLAY")
		tag:SetFont(self.FONT, size, "OUTLINE") -- a font must be set before SetText
		tag:SetTextColor(1, 0.82, 0)
		tag:SetText(author)
		self.nameTags[author] = tag
	end
	tag:SetFont(self.FONT, size, "OUTLINE")
	tag:ClearAllPoints()
	tag:SetPoint("BOTTOMLEFT", self.mainFrame, "BOTTOMLEFT", x + 6 * k, y + 6 * k)
	tag:SetAlpha(1)
	tag:Show()
	tag.shownAt = GetTime()
	self.nameTagFader:Show()
end

local function FadeNameTags(fader)
	local now = GetTime()
	local active = false
	for _, tag in pairs(ArtPad.nameTags) do
		if tag:IsShown() then
			local age = now - tag.shownAt
			if age >= NAME_TAG_HOLD + NAME_TAG_FADE then
				tag:Hide()
			else
				active = true
				if age > NAME_TAG_HOLD then
					tag:SetAlpha(1 - (age - NAME_TAG_HOLD) / NAME_TAG_FADE)
				end
			end
		end
	end
	if not active then fader:Hide() end
end

--[[ Mouse handling ]]

function ArtPad:ShowEraser(x, y)
	local r = self:GetEraserRadius()
	self.eraserCursor:SetSize(r * 2, r * 2)
	self.eraserCursor:ClearAllPoints()
	self.eraserCursor:SetPoint("CENTER", self.mainFrame, "BOTTOMLEFT", x, y)
	self.eraserCursor:Show()
end

function ArtPad:EndInteraction()
	local state = self.state
	if state == "PAINT" then
		self:EndStroke()
	elseif state == "ERASE" then
		self:FlushOutbox()
		self.eraserCursor:Hide()
	elseif state == "SHAPE" then
		self:FinishShape()
	elseif state == "LASER" then
		self:EndLaser()
	elseif state == "PAN" then
		self.panStart = nil
		self:SaveView()
	end
	if state ~= "TEXT" then
		self.state = "SLEEP"
	end
	self:RequestRefresh()
end

-- Drawing tools pin the cursor to the nearest canvas edge, so a click or drag in the margin
-- still draws (along the border) instead of doing nothing.
local function PinToCanvas(x, y)
	local size = ArtPad.canvasSize
	return math.max(0, math.min(size.X, x)), math.max(0, math.min(size.Y, y))
end

function ArtPad.OnMouseDown(_, button)
	local self = ArtPad
	if self.state ~= "SLEEP" and self.state ~= "TEXT" then return end
	self:ClosePopovers()
	if button == "RightButton" or button == "MiddleButton" then
		local mx, my = GetCursorPosition()
		self.panStart = { mx, my, self.view[2], self.view[3] }
		self.state = "PAN"
		return
	end
	local x, y = CursorOnCanvas(self.mainFrame)
	if button ~= "LeftButton" then return end
	local erasing = self.tool == "eraser"
	if not erasing then x, y = PinToCanvas(x, y) end
	self.lastX, self.lastY = x, y
	if self.state == "TEXT" then
		local text = self.pendingText or ""
		self:EndTextPlacement()
		self:PlaceText(x, y, text)
	elseif erasing then
		self.state = "ERASE"
		self:ShowEraser(x, y)
		self:EraseAt(x, y, x, y)
	else
		local tool = self.tool
		if tool == "stamp" then
			self:PlaceStamp(self.stampKey, x, y)
		elseif tool == "pen" then
			self.state = "PAINT"
			self:BeginStroke(x, y)
		elseif tool == "laser" then
			self.state = "LASER"
			self:BeginLaser(x, y)
		else
			self.state = "SHAPE"
			self.shapeStart = { x, y }
			self:UpdateShapePreview(x, y)
		end
		self:RequestRefresh() -- the empty-state hint gets out of the way immediately
	end
end

function ArtPad.OnMouseUp()
	ArtPad:EndInteraction()
end

function ArtPad.OnUpdate()
	local self = ArtPad
	local state = self.state
	if state == "PAN" then
		local p = self.panStart
		local mx, my = GetCursorPosition()
		local scale = self.mainFrame:GetEffectiveScale()
		self:SetView(self.view[1], p[3] + (mx - p[1]) / scale, p[4] + (my - p[2]) / scale)
		return
	end
	if state == "TEXT" then
		self:UpdateGhost()
		return
	end
	if state == "SHAPE" then
		self:UpdateShapePreview(PinToCanvas(CursorOnCanvas(self.mainFrame)))
		return
	end
	if state == "SLEEP" then
		if self.tool == "stamp" then
			self:UpdateStampGhost(PinToCanvas(CursorOnCanvas(self.mainFrame)))
		end
		return
	end
	if state ~= "PAINT" and state ~= "ERASE" and state ~= "LASER" then return end
	local x, y = CursorOnCanvas(self.mainFrame)
	if state == "ERASE" then
		self:ShowEraser(x, y)
	else
		x, y = PinToCanvas(x, y)
	end
	local dx, dy = x - self.lastX, y - self.lastY
	if dx * dx + dy * dy < MIN_SEGMENT * MIN_SEGMENT then
		return -- too short; keep accumulating from the last point
	end
	if state == "PAINT" then
		self:PaintTo(x, y)
	elseif state == "LASER" then
		self:ExtendLaser(x, y)
	else
		self:EraseAt(self.lastX, self.lastY, x, y)
	end
	self.lastX, self.lastY = x, y
end

-- Clip segment (x0,y0)-(x1,y1) to the canvas rectangle (Liang-Barsky).
-- Returns t0, t1: the visible part runs from fraction t0 to t1 of the segment, or nil if none.
local function ClipToCanvas(x0, y0, x1, y1, w, h)
	local t0, t1 = 0, 1
	local dx, dy = x1 - x0, y1 - y0
	local p = { -dx, dx, -dy, dy }
	local q = { x0, w - x0, y0, h - y0 }
	for i = 1, 4 do
		if p[i] == 0 then
			if q[i] < 0 then return nil end
		else
			local t = q[i] / p[i]
			if p[i] < 0 then
				if t > t1 then return nil elseif t > t0 then t0 = t end
			else
				if t < t0 then return nil elseif t < t1 then t1 = t end
			end
		end
	end
	return t0, t1
end
ArtPad.ClipToCanvas = ClipToCanvas

-- Extend the current stroke towards (x, y), keeping it on the canvas: leaving the canvas ends
-- the stroke at the edge, and coming back in starts a new one where the cursor re-enters.
function ArtPad:PaintTo(x, y)
	local x0, y0 = self.lastX, self.lastY
	local t0, t1 = ClipToCanvas(x0, y0, x, y, self.canvasSize.X, self.canvasSize.Y)
	if not t0 then return end -- entirely off the canvas
	local function At(t)
		return math.floor(x0 + (x - x0) * t + 0.5), math.floor(y0 + (y - y0) * t + 0.5)
	end
	if not self.currentStroke then
		self:BeginStroke(At(t0))
	end
	local ex, ey = At(t1)
	local s = self.currentStroke
	if ex ~= s.px[s.n] or ey ~= s.py[s.n] then
		self:ExtendStroke(ex, ey)
	end
	if t1 < 1 then
		self:EndStroke() -- left the canvas
	end
end

function ArtPad.OnMouseWheel(_, delta)
	local self = ArtPad
	if self.state == "PAN" then return end
	self:ZoomAt(delta > 0 and 1.15 or 1 / 1.15, self:CursorOnViewport())
end

--[[ Keyboard shortcuts ]]

function ArtPad:BindCanvasKeys(on)
	if InCombatLockdown() then return end
	local owner = self.viewport
	ClearOverrideBindings(owner)
	if on then
		for key, button in pairs(self.canvasKeys) do
			SetOverrideBindingClick(owner, false, key, button)
		end
	end
end

--[[ Show / hide ]]

function ArtPad.OnShow()
	local self = ArtPad
	if not InCombatLockdown() then
		for key, button in pairs(self.windowKeys) do
			SetOverrideBindingClick(self.window, true, key, button)
		end
	end
	self:SetLauncherActive(false)
	self:RequestRefresh()
end

function ArtPad.OnHide()
	local self = ArtPad
	if not InCombatLockdown() then
		ClearOverrideBindings(self.window)
		ClearOverrideBindings(self.viewport)
	end
	self:EndInteraction()
	self:EndTextPlacement()
	self:ClosePopovers()
	self.state = "SLEEP"
	self.textInput:Hide()
end

function ArtPad:Toggle()
	if not self.window then return end
	if self.window:IsShown() then
		self.window:Hide()
	else
		self.window:Show()
	end
end

--[[ Clear (with an inline confirm) ]]

function ArtPad:ConfirmClear()
	self.clearConfirm:Hide()
	self:ClearForEveryone()
end

function ArtPad:CloseClearConfirm()
	if self.clearConfirm then self.clearConfirm:Hide() end
end

function ArtPad:AudienceCount()
	if self.loopback then return 1 end
	if ArtPad_Settings.Mode == "GUILD" then
		local _, online = GetNumGuildMembers()
		return online
	end
	return GetNumGroupMembers()
end

--[[ Buttons ]]

ArtPad.buttons = {
	Text = function()
		local self = ArtPad
		self:EndTextPlacement()
		if self.textInput:IsShown() then -- the Text button toggles the box
			self.textInput:Hide()
			return
		end
		self.textInput:SetText("")
		self.textInput:Show()
		self.textInput:SetFocus()
		self.textInputHint = true
		self:Notify("Type, then press Enter. Esc to cancel.", "info", { duration = false })
	end,
	Undo = function() ArtPad:Undo() end,
	Clear = function()
		local self = ArtPad
		if #self.items == 0 then
			self:Notify("Nothing to clear.", "info")
		elseif not ArtPad_Settings.WarnClear then
			self:ClearForEveryone()
		elseif self.clearConfirm:IsShown() then
			self.clearConfirm:Hide()
		else
			self:ClosePopovers()
			local n = self:AudienceCount()
			self.clearConfirm.title:SetText((n and n > 1) and ("Clear for all " .. n .. " people?") or "Clear for everyone?")
			self.clearConfirm:Show()
		end
	end,
	Center = function() ArtPad:ResetPosition() end,
	Map = function() ArtPad:ToggleMap() end,
	Options = function() ArtPad:OpenOptions() end,
	Close = function()
		local self = ArtPad
		-- Escape backs out of text placement, popovers or a special tool before closing.
		if self.state == "TEXT" then
			self:EndTextPlacement()
		elseif self:ClosePopovers() then
			return
		elseif self.tool ~= "pen" then
			self:SetTool("pen")
		else
			self.window:Hide()
		end
	end,
}

-- Hide any open popover; returns true if one was open.
function ArtPad:ClosePopovers()
	local closed = false
	for _, p in ipairs(self.popovers or {}) do
		if p:IsShown() then
			p:Hide()
			closed = true
		end
	end
	return closed
end

function ArtPad:RegisterPopover(frame)
	self.popovers = self.popovers or {}
	table.insert(self.popovers, frame)
end

--[[ Window position and size ]]

function ArtPad:SaveWindow()
	local w = self.window
	local point, _, relPoint, x, y = w:GetPoint(1)
	ArtPad_Settings.FramePositions.window = { point, relPoint, x, y }
	ArtPad_Settings.WindowSize = { w:GetWidth(), w:GetHeight() }
end

function ArtPad:RestoreWindow()
	local w = self.window
	local size = ArtPad_Settings.WindowSize
	if type(size) == "table" and tonumber(size[1]) and tonumber(size[2]) then
		w:SetSize(math.max(MIN_W, size[1]), math.max(ArtPad.minHeight or MIN_H, size[2]))
	else
		w:SetSize(DEFAULT_W, DEFAULT_H)
	end
	w:ClearAllPoints()
	local pos = ArtPad_Settings.FramePositions.window
	if type(pos) == "table" and pos[1] and tonumber(pos[3]) and tonumber(pos[4]) then
		w:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3], pos[4])
	else
		w:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
	end
end

function ArtPad:ResetAllFramePositions()
	ArtPad_Settings.FramePositions.window = nil
	ArtPad_Settings.WindowSize = nil
	self:RestoreWindow()
	self:FitToView()
end

function ArtPad:ApplyResizeBounds()
	local win = self.window
	if win.SetResizeBounds then
		win:SetResizeBounds(MIN_W, self.minHeight)
	elseif win.SetMinResize then
		win:SetMinResize(MIN_W, self.minHeight)
	end
	if win:GetHeight() < self.minHeight then win:SetSize(win:GetWidth(), self.minHeight) end
end

-- A side column needs `height` between the title and status bars: never let the window get
-- shorter than that, or its controls spill over the status bar.
function ArtPad:FitContent(height)
	local need = math.ceil(TITLE_H + STATUS_H + height)
	if need > self.minHeight then
		self.minHeight = need
		self:ApplyResizeBounds()
	end
end

-- Corner grip: resize the window. A fitted canvas stays fitted.
function ArtPad:StartResize()
	self.resizing = { wasFitted = not ArtPad_Settings.View }
	self.window:StartSizing("BOTTOMRIGHT")
end

function ArtPad:StopResize()
	if not self.resizing then return end
	self.window:StopMovingOrSizing()
	local w = self.window
	w:SetSize(math.max(MIN_W, w:GetWidth()), math.max(self.minHeight, w:GetHeight()))
	if self.resizing.wasFitted then self:FitToView() end
	self.resizing = nil
	self:SaveWindow()
end

--[[ Setup ]]

local function Background(frame, c, a, layer)
	local t = frame:CreateTexture(nil, layer or "BACKGROUND")
	t:SetAllPoints()
	ArtPad.Fill(t, c, a)
	return t
end
ArtPad.Background = Background

local function Divider(parent, horizontal)
	local t = parent:CreateTexture(nil, "BORDER")
	ArtPad.Fill(t, C.line)
	if horizontal then t:SetHeight(1) else t:SetWidth(1) end
	return t
end
ArtPad.Divider = Divider

local function IconButton(parent, name, tipTitle, tipLine, onClick)
	local b = CreateFrame("Button", name, parent)
	b:SetSize(28, 28)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnClick", onClick)
	Tooltip(b, tipTitle, tipLine)
	return b
end
ArtPad.IconButton = IconButton

-- Line-drawn glyphs (button coordinates, 0..size)
function ArtPad.DrawGlyph(frame, segs, size, color)
	local lines = {}
	for _, s in ipairs(segs) do
		local line = frame:CreateLine(nil, "ARTWORK")
		line:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
		line:SetThickness(2)
		line:SetStartPoint("BOTTOMLEFT", frame, (frame:GetWidth() - size) / 2 + s[1], (frame:GetHeight() - size) / 2 + s[2])
		line:SetEndPoint("BOTTOMLEFT", frame, (frame:GetWidth() - size) / 2 + s[3], (frame:GetHeight() - size) / 2 + s[4])
		table.insert(lines, line)
	end
	return lines
end

function ArtPad:SetupUI()
	local c = ArtPad_Settings.Color
	self.brushColor = { r = c.r or 1, g = c.g or 1, b = c.b or 1, a = c.a or 1 }
	self.nameTags = {}

	-- Window
	local win = CreateFrame("Frame", "ArtPad_Window", UIParent)
	self.window = win
	self.controlsFrame = win -- older name, still used by a few helpers
	win:SetFrameStrata("HIGH")
	win:SetToplevel(true)
	win:SetMovable(true)
	win:SetResizable(true)
	self.minHeight = MIN_H
	self:ApplyResizeBounds()
	win:SetClampedToScreen(true)
	win:EnableMouse(true)
	Background(win, C.window, 0.97)
	win:Hide()
	self:RestoreWindow()

	-- Title bar: drag to move
	local title = CreateFrame("Frame", "ArtPad_TitleBar", win)
	title:SetHeight(TITLE_H)
	title:SetPoint("TOPLEFT")
	title:SetPoint("TOPRIGHT")
	Background(title, C.bar)
	title:EnableMouse(true)
	title:RegisterForDrag("LeftButton")
	title:SetScript("OnDragStart", function() win:StartMoving() end)
	title:SetScript("OnDragStop", function()
		win:StopMovingOrSizing()
		win:SetUserPlaced(false) -- saved by us
		self:SaveWindow()
	end)
	self.titleBar = title
	local titleLine = Divider(win, true)
	titleLine:SetPoint("TOPLEFT", 0, -TITLE_H)
	titleLine:SetPoint("TOPRIGHT", 0, -TITLE_H)

	local name = title:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	name:SetPoint("LEFT", 14, 0)
	name:SetText("ArtPad")
	self.titleNote = title:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	self.titleNote:SetPoint("LEFT", name, "RIGHT", 10, 0)

	-- right side, from the edge inwards
	local hide = IconButton(title, "ArtPad_CloseButton", "Hide", "Esc", self.buttons.Close)
	hide:SetPoint("RIGHT", -8, 0)
	self.DrawGlyph(hide, { { 3, 8, 13, 8 } }, 16, C.muted)
	local options = IconButton(title, "ArtPad_OptionsButton", "Options", nil, self.buttons.Options)
	options:SetPoint("RIGHT", hide, "LEFT", -2, 0)
	self.DrawGlyph(options, { { 3, 4, 13, 4 }, { 3, 8, 13, 8 }, { 3, 12, 13, 12 } }, 16, C.muted)

	local clear = self:FlatButton(title, "ArtPad_ClearButton", 54, 26, "Clear", self.buttons.Clear)
	clear:SetPoint("RIGHT", options, "LEFT", -8, 0)
	self.Fill(clear.bg, { 0.23, 0.14, 0.13 })
	clear.label:SetTextColor(1, 0.82, 0.8)
	self.clearButton = clear

	-- Body
	local rail = CreateFrame("Frame", "ArtPad_Rail", win)
	rail:SetPoint("TOPLEFT", 0, -TITLE_H - 1)
	rail:SetPoint("BOTTOMLEFT", 0, STATUS_H + 1)
	rail:SetWidth(RAIL_W)
	Background(rail, C.panel)
	self.rail = rail
	local railLine = Divider(win)
	railLine:SetPoint("TOPLEFT", RAIL_W, -TITLE_H - 1)
	railLine:SetPoint("BOTTOMLEFT", RAIL_W, STATUS_H + 1)

	local inspector = CreateFrame("Frame", "ArtPad_Inspector", win)
	inspector:SetPoint("TOPRIGHT", 0, -TITLE_H - 1)
	inspector:SetPoint("BOTTOMRIGHT", 0, STATUS_H + 1)
	inspector:SetWidth(INSPECTOR_W)
	Background(inspector, C.panel)
	self.inspector = inspector
	local inspLine = Divider(win)
	inspLine:SetPoint("TOPRIGHT", -INSPECTOR_W, -TITLE_H - 1)
	inspLine:SetPoint("BOTTOMRIGHT", -INSPECTOR_W, STATUS_H + 1)

	local status = CreateFrame("Frame", "ArtPad_StatusBar", win)
	status:SetHeight(STATUS_H)
	status:SetPoint("BOTTOMLEFT")
	status:SetPoint("BOTTOMRIGHT")
	Background(status, C.bar)
	self.statusBar = status
	local statusLine = Divider(win, true)
	statusLine:SetPoint("BOTTOMLEFT", 0, STATUS_H)
	statusLine:SetPoint("BOTTOMRIGHT", 0, STATUS_H)

	-- Corner grip: resize the window
	local grip = CreateFrame("Button", "ArtPad_ResizeGrip", win)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then self:StartResize() end
	end)
	grip:SetScript("OnMouseUp", function() self:StopResize() end)
	Tooltip(grip, "Resize")

	-- Viewport + canvas
	local viewport = CreateFrame("Frame", "ArtPad_Viewport", win)
	viewport:SetPoint("TOPLEFT", RAIL_W + 1, -TITLE_H - 1)
	viewport:SetPoint("BOTTOMRIGHT", -INSPECTOR_W - 1, STATUS_H + 1)
	viewport:SetClipsChildren(true)
	Background(viewport, C.canvas)
	self.viewport = viewport

	local f = CreateFrame("Frame", "ArtPad_Canvas", viewport)
	self.mainFrame = f
	f:SetSize(self.canvasSize.X, self.canvasSize.Y)
	self.canvasBackground = f:CreateTexture(nil, "BACKGROUND")
	self.canvasBackground:SetColorTexture(0.09, 0.105, 0.12, 1)
	self.canvasBackground:SetAllPoints(f)
	self:RestoreView()

	-- Previews, laser, cursor and name tags: above every draw layer (see Canvas.lua DrawLayer)
	local overlay = CreateFrame("Frame", "ArtPad_CanvasOverlay", f)
	overlay:SetAllPoints(f)
	overlay:SetFrameLevel(f:GetFrameLevel() + 1000)
	self.overlay = overlay

	self.eraserCursor = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
	self.eraserCursor:SetTexture(self.MEDIA .. "ring")
	self.eraserCursor:SetVertexColor(1, 1, 1, 0.8)
	self.eraserCursor:Hide()

	-- Shows the not-yet-committed tail of a freehand stroke (see ExtendStroke).
	self.strokePreview = overlay:CreateLine(nil, "ARTWORK")
	self.strokePreview:Hide()

	self.nameTagFader = CreateFrame("Frame", nil, f)
	self.nameTagFader:Hide()
	self.nameTagFader:SetScript("OnUpdate", FadeNameTags)

	viewport:EnableMouse(true)
	viewport:EnableMouseWheel(true)
	viewport:SetScript("OnMouseDown", self.OnMouseDown)
	viewport:SetScript("OnMouseUp", self.OnMouseUp)
	viewport:SetScript("OnMouseWheel", self.OnMouseWheel)
	viewport:SetScript("OnUpdate", self.OnUpdate)
	viewport:SetScript("OnEnter", function() self:BindCanvasKeys(true) end)
	viewport:SetScript("OnLeave", function()
		self:BindCanvasKeys(false)
		if self.stampGhost then self.stampGhost:Hide() end
	end)

	-- Zoom control, bottom-right of the canvas
	local zoom = CreateFrame("Frame", "ArtPad_Zoom", viewport)
	zoom:SetSize(156, 34)
	zoom:SetPoint("BOTTOMRIGHT", -12, 12)
	zoom:SetFrameLevel(viewport:GetFrameLevel() + 20)
	Background(zoom, C.bar, 0.95)
	local zoomOut = self:FlatButton(zoom, "ArtPad_ZoomOut", 28, 26, "-", function() self:ZoomCentered(1 / 1.25) end)
	zoomOut:SetPoint("LEFT", 4, 0)
	self.zoomLabel = zoom:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.zoomLabel:SetPoint("LEFT", zoomOut, "RIGHT", 4, 0)
	self.zoomLabel:SetWidth(44)
	local zoomIn = self:FlatButton(zoom, "ArtPad_ZoomIn", 28, 26, "+", function() self:ZoomCentered(1.25) end)
	zoomIn:SetPoint("LEFT", self.zoomLabel, "RIGHT", 4, 0)
	local fit = self:FlatButton(zoom, "ArtPad_CenterButton", 36, 26, "Fit", self.buttons.Center)
	fit:SetPoint("LEFT", zoomIn, "RIGHT", 4, 0)
	Tooltip(fit, "Fit to window")
	function self.RefreshZoomLabel()
		self.zoomLabel:SetText(math.floor(self.view[1] * 100 + 0.5) .. "%")
	end
	self:RefreshZoomLabel()

	-- Clear confirmation, under the Clear button
	local confirm = CreateFrame("Frame", "ArtPad_ClearConfirm", win)
	confirm:SetSize(270, 108)
	confirm:SetPoint("TOPRIGHT", clear, "BOTTOMRIGHT", 0, -8)
	confirm:SetFrameLevel(win:GetFrameLevel() + 40)
	confirm:EnableMouse(true)
	Background(confirm, C.bar)
	confirm.title = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	confirm.title:SetPoint("TOPLEFT", 14, -14)
	local sub = confirm:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	sub:SetPoint("TOPLEFT", confirm.title, "BOTTOMLEFT", 0, -8)
	sub:SetText("Can't be undone.")
	local yes = self:FlatButton(confirm, "ArtPad_ClearConfirmButton", 70, 28, "Clear", function() self:ConfirmClear() end)
	yes:SetPoint("BOTTOMRIGHT", -12, 12)
	self.Fill(yes.bg, C.danger)
	local no = self:FlatButton(confirm, "ArtPad_ClearCancelButton", 70, 28, "Cancel", function() confirm:Hide() end)
	no:SetPoint("RIGHT", yes, "LEFT", -8, 0)
	confirm:Hide()
	self.clearConfirm = confirm
	self:RegisterPopover(confirm)

	-- Text input, floating at the top of the canvas
	local input = CreateFrame("EditBox", "ArtPad_TextInput", win, "InputBoxTemplate")
	self.textInput = input
	input:SetSize(300, 30)
	input:SetPoint("TOP", viewport, "TOP", 0, -56)
	input:SetAutoFocus(true)
	input:SetMaxLetters(200)
	input:SetFrameLevel(win:GetFrameLevel() + 30)
	input:Hide()
	input:SetScript("OnEnterPressed", function(box)
		local text = strtrim(box:GetText() or "")
		box:Hide()
		if text ~= "" then
			self:BeginTextPlacement(text)
		end
	end)
	input:SetScript("OnEscapePressed", function(box) box:Hide() end)
	-- Clicking anywhere else (including the canvas) cancels instead of leaving the box hanging.
	input:SetScript("OnEditFocusLost", function(box) box:Hide() end)
	input:SetScript("OnHide", function(box)
		box:ClearFocus()
		if self.textInputHint then
			self.textInputHint = nil
			if self.state ~= "TEXT" then self:DismissToast() end
		end
	end)

	-- Hidden click targets for the [ and ] brush-size keys
	local smaller = CreateFrame("Button", "ArtPad_BrushSmaller", win)
	smaller:SetScript("OnClick", function() self:SetBrushSize(ArtPad_Settings.BrushSize - 1) end)
	smaller:Hide()
	local bigger = CreateFrame("Button", "ArtPad_BrushBigger", win)
	bigger:SetScript("OnClick", function() self:SetBrushSize(ArtPad_Settings.BrushSize + 1) end)
	bigger:Hide()


	win:SetScript("OnShow", self.OnShow)
	win:SetScript("OnHide", self.OnHide)
	win:SetScript("OnSizeChanged", function()
		if self.resizing and self.resizing.wasFitted then
			self:FitToView()
		elseif self.view then
			self:SetView(self.view[1], self.view[2], self.view[3])
		end
	end)
end
