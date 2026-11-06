--[[
	Canvas frame, toolbar and input handling.
]]

local ArtPad = ArtPad

ArtPad.canvasSize = { X = 3840, Y = 2160 }
ArtPad.brushSizes = { 1, 2, 3, 5, 8, 13, 21 }
ArtPad.state = "SLEEP" -- SLEEP, PAINT, ERASE, MOVE, TEXT

local MIN_SEGMENT = 3 -- minimum distance (canvas px) between recorded points
local GRIP = 16 -- size of the drag handles on the toolbar and dock
local NAME_TAG_HOLD, NAME_TAG_FADE = 2, 1 -- seconds
local NAME_TAG_FONT_SIZE = 14 -- as it appears on screen, regardless of canvas zoom

-- Hidden/toolbar buttons that keyboard shortcuts are bound to while the canvas is shown.
ArtPad.shortcuts = {
	ArtPad_CloseButton = "ESCAPE",
	ArtPad_UndoButton = "CTRL-Z",
}

--[[ Brush ]]

function ArtPad:GetEraserRadius()
	return 4 + ArtPad_Settings.BrushSize
end

function ArtPad:SetBrushSize(n)
	ArtPad_Settings.BrushSize = math.max(1, math.min(self.MAX_WIDTH, math.floor(n)))
	if self.brushButton then
		self.brushButton:SetText("Brush: " .. ArtPad_Settings.BrushSize)
	end
	self:UpdateBrushPreview()
end

function ArtPad:SetColor(r, g, b, a)
	local c = self.brushColor
	c.r, c.g, c.b, c.a = r, g, b, a
	ArtPad_Settings.Color = { r = r, g = g, b = b, a = a }
	if self.brushColorSample then
		self.brushColorSample:SetColorTexture(r, g, b, 1)
	end
	self:UpdateBrushPreview()
	if self.RefreshDock then self:RefreshDock() end
end

-- A dot on the Brush button showing the actual size and colour you'll draw with.
function ArtPad:UpdateBrushPreview()
	local dot = self.brushPreview
	if not dot then return end
	local size = math.max(3, math.min(18, ArtPad_Settings.BrushSize))
	local c = self.brushColor
	dot:SetSize(size, size)
	dot:SetVertexColor(c.r, c.g, c.b, math.max(0.35, c.a))
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

--[[ Position / zoom ]]

function ArtPad:SavePosition()
	local f = self.mainFrame
	ArtPad_Settings.Scale = f:GetScale()
	ArtPad_Settings.Position = { f:GetLeft(), f:GetBottom() }
end

function ArtPad:RestorePosition()
	local f = self.mainFrame
	f:SetScale(ArtPad_Settings.Scale or 1)
	f:ClearAllPoints()
	local pos = ArtPad_Settings.Position
	if type(pos) == "table" and pos[1] and pos[2] then
		f:SetPoint("BOTTOMLEFT", pos[1], pos[2])
	else
		self:FitToScreen()
	end
end

-- Scale the whole canvas to fit the screen with a small margin, centered.
function ArtPad:FitToScreen()
	local f = self.mainFrame
	local uiScale = UIParent:GetEffectiveScale()
	local sw, sh = GetScreenWidth() * uiScale, GetScreenHeight() * uiScale
	local scale = 0.92 * math.min(sw / self.canvasSize.X, sh / self.canvasSize.Y)
	f:SetScale(scale)
	f:ClearAllPoints()
	f:SetPoint("CENTER")
end

function ArtPad:ResetPosition()
	ArtPad_Settings.Position = false
	self:FitToScreen()
end

function ArtPad:UpdateTitle()
	if not self.versionText then return end
	-- Loopback and loading state live in the status bar below the toolbar.
	local text = "ArtPad v" .. self.version
	if self.newerVersion then
		text = text .. " - |cffff4444UPDATE AVAILABLE (v" .. self.newerVersion .. ")|r"
	end
	self.versionText:SetText(text)
end

--[[ Name tags ]]

function ArtPad:ShowNameTag(author, x, y)
	if not ArtPad_Settings.NameTags or not x then return end
	local tag = self.nameTags[author]
	-- The canvas is a huge frame scaled down to fit the screen, so size tags in canvas units
	-- that come out like normal UI text at the current zoom.
	local k = UIParent:GetEffectiveScale() / self.mainFrame:GetEffectiveScale()
	local size = math.max(8, math.min(200, NAME_TAG_FONT_SIZE * k))
	if not tag then
		tag = self.mainFrame:CreateFontString(nil, "OVERLAY")
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

local function CursorOnCanvas(f)
	local mx, my = GetCursorPosition()
	local scale = f:GetScale()
	return math.floor(mx / scale - f:GetLeft()), math.floor(my / scale - f:GetBottom())
end

function ArtPad:ShowEraser(x, y)
	local r = self:GetEraserRadius()
	self.eraserCursor:SetSize(r * 2, r * 2)
	self.eraserCursor:ClearAllPoints()
	self.eraserCursor:SetPoint("CENTER", self.mainFrame, "BOTTOMLEFT", x, y)
	self.eraserCursor:Show()
end

function ArtPad:EndInteraction()
	if self.state == "PAINT" then
		self:EndStroke()
	elseif self.state == "ERASE" then
		self:FlushOutbox()
		self.eraserCursor:Hide()
	elseif self.state == "MOVE" then
		self.mainFrame:StopMovingOrSizing()
		self:SavePosition()
	elseif self.state == "SHAPE" then
		self:FinishShape()
	end
	if self.state ~= "TEXT" then
		self.state = "SLEEP"
	end
	self:RequestRefresh()
end

function ArtPad.OnMouseDown(frame, button)
	local self = ArtPad
	if self.state ~= "SLEEP" and self.state ~= "TEXT" then return end
	local x, y = CursorOnCanvas(frame)
	self.lastX, self.lastY = x, y
	if self.state == "TEXT" then
		local text = self.pendingText or ""
		self:EndTextPlacement()
		self:PlaceText(x, y, text)
	elseif button == "LeftButton" then
		local tool = self.tool
		if tool == "stamp" then
			self:PlaceStamp(self.stampKey, x, y)
		elseif tool == "pen" then
			self.state = "PAINT"
			self:BeginStroke(x, y)
		else
			self.state = "SHAPE"
			self.shapeStart = { x, y }
			self:UpdateShapePreview(x, y)
		end
		self:RequestRefresh() -- the empty-state hint gets out of the way immediately
	elseif button == "RightButton" then
		self.state = "ERASE"
		self:ShowEraser(x, y)
		self:EraseAt(x, y, x, y)
	end
end

function ArtPad.OnMouseUp()
	ArtPad:EndInteraction()
end

function ArtPad.OnUpdate(frame)
	local self = ArtPad
	if self.state == "TEXT" then
		self:UpdateGhost()
		return
	end
	if self.state == "SHAPE" then
		self:UpdateShapePreview(CursorOnCanvas(frame))
		return
	end
	if self.state == "SLEEP" and self.tool == "stamp" then
		self:UpdateStampGhost(CursorOnCanvas(frame))
		return
	end
	if self.state ~= "PAINT" and self.state ~= "ERASE" then return end
	local x, y = CursorOnCanvas(frame)
	if self.state == "ERASE" then
		self:ShowEraser(x, y)
	end
	local dx, dy = x - self.lastX, y - self.lastY
	if dx * dx + dy * dy < MIN_SEGMENT * MIN_SEGMENT then
		return -- too short; keep accumulating from the last point
	end
	if self.state == "PAINT" then
		self:PaintTo(x, y)
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

function ArtPad.OnMouseWheel(frame, delta)
	local self = ArtPad
	if self.state == "MOVE" then return end
	local oldScale = frame:GetScale()
	local newScale = oldScale + (oldScale * 0.10 * delta)
	if newScale >= 100 or newScale <= 0.05 then return end

	local cx, cy = GetCursorPosition()
	local fx = (cx - frame:GetLeft() * oldScale) / (frame:GetWidth() * oldScale)
	local fy = (cy - frame:GetBottom() * oldScale) / (frame:GetHeight() * oldScale)
	local newLeft = cx - fx * frame:GetWidth() * newScale
	local newBottom = cy - fy * frame:GetHeight() * newScale

	frame:SetScale(newScale)
	frame:ClearAllPoints()
	frame:SetPoint("BOTTOMLEFT", newLeft / newScale, newBottom / newScale)
	self:SavePosition()
end

function ArtPad.OnShow()
	local self = ArtPad
	if not InCombatLockdown() then
		for button, key in pairs(self.shortcuts) do
			SetOverrideBindingClick(self.mainFrame, true, key, button)
		end
	end
	self:SetLauncherActive(false)
	self.controlsFrame:Show()
end

function ArtPad.OnHide()
	local self = ArtPad
	if not InCombatLockdown() then
		ClearOverrideBindings(self.mainFrame)
	end
	self:EndInteraction()
	self:EndTextPlacement()
	self:DisarmClear()
	self.state = "SLEEP"
	self.controlsFrame:Hide()
	self.textInput:Hide()
end

--[[ Toolbar ]]

-- Clearing wipes everyone's canvas and can't be undone, so it takes a second click: either
-- the Clear button again or the action in the toast. No modal popup in the way.
local CLEAR_CONFIRM_WINDOW = 5

function ArtPad:ArmClear()
	self.clearArmedUntil = GetTime() + CLEAR_CONFIRM_WINDOW
	if self.clearButton then
		self.clearButton.normal:SetColorTexture(0.55, 0.08, 0.08, 0.85)
	end
	self:Notify("Clear the canvas for everyone? This can't be undone.", "warn", {
		action = { "Clear for everyone", function() self:ConfirmClear() end },
		duration = CLEAR_CONFIRM_WINDOW,
	})
	C_Timer.After(CLEAR_CONFIRM_WINDOW, function()
		if self.clearArmedUntil and GetTime() >= self.clearArmedUntil then self:DisarmClear() end
	end)
end

function ArtPad:DisarmClear()
	self.clearArmedUntil = nil
	if self.clearButton then
		self.clearButton.normal:SetColorTexture(0, 0, 0, 0.69)
	end
end

function ArtPad:ConfirmClear()
	self:DisarmClear()
	self:DismissToast()
	self:ClearForEveryone()
end

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
		self:Notify("Type your text and press Enter.  Esc or click away to cancel.", "info", { duration = false })
	end,
	Brush = function(_, button)
		local self = ArtPad
		local sizes, cur = self.brushSizes, 1
		for i, s in ipairs(sizes) do
			if s <= ArtPad_Settings.BrushSize then cur = i end
		end
		cur = cur + (button == "RightButton" and -1 or 1)
		if cur > #sizes then cur = 1 elseif cur < 1 then cur = #sizes end
		self:SetBrushSize(sizes[cur])
	end,
	Color = function() ArtPad:OpenColorPicker() end,
	Undo = function() ArtPad:Undo() end,
	ArtMode = function()
		local self = ArtPad
		if self.mainFrame:GetFrameStrata() == "BACKGROUND" then
			self.mainFrame:SetFrameStrata("FULLSCREEN")
			self.controlsFrame:SetFrameStrata("TOOLTIP")
			self.canvasBackground:SetColorTexture(0, 0, 0, 1)
		else
			self.mainFrame:SetFrameStrata("BACKGROUND")
			self.controlsFrame:SetFrameStrata("BACKGROUND")
			self.canvasBackground:SetColorTexture(0, 0, 0, 0.5)
		end
	end,
	Clear = function()
		local self = ArtPad
		if #self.items == 0 then
			self:Notify("The canvas is already empty.", "info")
		elseif not ArtPad_Settings.WarnClear or (self.clearArmedUntil and GetTime() < self.clearArmedUntil) then
			self:ConfirmClear()
		else
			self:ArmClear()
		end
	end,
	Center = function() ArtPad:ResetPosition() end,
	Map = function() ArtPad:ToggleMap() end,
	Options = function() ArtPad:OpenOptions() end,
	Close = function()
		-- Escape backs out of text placement or a special tool before it closes the canvas.
		if ArtPad.state == "TEXT" then
			ArtPad:EndTextPlacement()
		elseif ArtPad.tool ~= "pen" then
			ArtPad:SetTool("pen")
		else
			ArtPad.mainFrame:Hide()
		end
	end,
}

local function ShowTooltip(button)
	if not button.tooltip then return end
	GameTooltip:SetOwner(button, "ANCHOR_BOTTOM")
	GameTooltip:SetText(button.tooltip[1])
	for i = 2, #button.tooltip do
		GameTooltip:AddLine(button.tooltip[i], 1, 1, 1)
	end
	GameTooltip:Show()
end

function ArtPad:CreateButton(name, func, text, tooltip)
	local button = CreateFrame("Button", name, self.controlsFrame)
	button:SetNormalFontObject("GameFontNormalLarge")
	button:SetHighlightFontObject("GameFontHighlightLarge")
	button:SetText(text)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", func)
	button:SetFrameStrata("FULLSCREEN")
	button:SetWidth(button:GetTextWidth() + 24)
	button:SetHeight(button:GetTextHeight() + 20)
	button.tooltip = tooltip
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)

	button:SetDisabledFontObject("GameFontDisableLarge")
	button:SetMotionScriptsWhileDisabled(true) -- keep tooltips on disabled buttons

	local normal = button:CreateTexture(nil, "BACKGROUND")
	normal:SetColorTexture(0, 0, 0, 0.69)
	normal:SetAllPoints()
	button.normal = normal
	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetColorTexture(0.15, 0.48, 0, 0.5)
	highlight:SetAllPoints()
	local pushed = button:CreateTexture(nil, "ARTWORK")
	pushed:SetColorTexture(0, 0, 0, 0.8)
	pushed:SetAllPoints()
	button:SetPushedTexture(pushed)
	local sep = button:CreateTexture(nil, "BORDER")
	sep:SetColorTexture(1, 1, 1, 0.15)
	sep:SetWidth(1)
	sep:SetPoint("TOPRIGHT")
	sep:SetPoint("BOTTOMRIGHT")
	return button
end

function ArtPad:CreateControls()
	local b = self.buttons
	local brush = self:CreateButton("ArtPad_BrushButton", b.Brush, "Brush: 21",
		{ "Brush size", "Left click: bigger, right click: smaller", "Also sets the eraser size" })
	brush:SetWidth(brush:GetWidth() + 22)
	brush:GetFontString():ClearAllPoints()
	brush:GetFontString():SetPoint("CENTER", 11, 0)
	local preview = brush:CreateTexture(nil, "OVERLAY")
	preview:SetTexture(self.MEDIA .. "dot")
	preview:SetPoint("CENTER", brush, "LEFT", 18, 0)
	self.brushPreview = preview
	self.brushButton = brush

	self.undoButton = self:CreateButton("ArtPad_UndoButton", b.Undo, "Undo",
		{ "Undo your last stroke, text or stamp", "Shortcut: Ctrl-Z" })
	self.clearButton = self:CreateButton("ArtPad_ClearButton", b.Clear, "Clear",
		{ "Clear the canvas for everyone", "Asks you to confirm first" })
	self.mapButton = self:CreateButton("ArtPad_MapButton", b.Map, "Map",
		{ "Map backdrop", "Show the map of where you are under the canvas, for everyone.", "Click again to remove it." })

	-- Tools, stamps and colours live in the dock on the left (Tools.lua).
	self.controls = {
		brush,
		self.undoButton,
		self.mapButton,
		self:CreateButton("ArtPad_ArtModeButton", b.ArtMode, "Art Mode", { "Toggle an opaque canvas above the game" }),
		self.clearButton,
		self:CreateButton("ArtPad_CenterButton", b.Center, "Fit", { "Fit the canvas to your screen" }),
		self:CreateButton("ArtPad_OptionsButton", b.Options, "Options"),
		self:CreateButton("ArtPad_CloseButton", b.Close, "Close", { "Close", "Shortcut: Escape" }),
	}

	-- Grab handle on the left to move the toolbar (status bar and toasts move with it).
	local grip = self:CreateGrip(self.controlsFrame, "ArtPad_ToolbarGrip", GRIP, 1, "vertical")
	grip:SetPoint("TOPLEFT")
	grip:SetPoint("BOTTOMLEFT")
	self:MakeMovable(self.controlsFrame, "toolbar", grip, function(f)
		f:SetPoint("TOP", UIParent, "TOP", 0, -40)
	end)

	local x = GRIP
	for _, control in ipairs(self.controls) do
		control:SetPoint("TOPLEFT", self.controlsFrame, "TOPLEFT", x, 0)
		control:SetPoint("BOTTOM", self.controlsFrame, "BOTTOM")
		x = x + control:GetWidth()
	end
	self.controlsFrame:SetWidth(x)
end

--[[ Movable toolbar and dock ]]

-- A small handle with grip dots. Drag to move its frame, right-click to reset.
function ArtPad:CreateGrip(parent, name, w, h, orientation)
	local grip = CreateFrame("Frame", name, parent)
	grip:SetSize(w, h)
	grip:EnableMouse(true)
	grip:RegisterForDrag("LeftButton")
	local bg = grip:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.15, 0.15, 0.15, 0.85)
	grip.bg = bg
	for k = -1, 1 do
		local dot = grip:CreateTexture(nil, "ARTWORK")
		dot:SetTexture(self.MEDIA .. "dot")
		dot:SetSize(4, 4)
		dot:SetVertexColor(1, 1, 1, 0.6)
		if orientation == "vertical" then
			dot:SetPoint("CENTER", grip, "CENTER", 0, k * 7)
		else
			dot:SetPoint("CENTER", grip, "CENTER", k * 7, 0)
		end
	end
	grip:SetScript("OnEnter", function(g)
		g.bg:SetColorTexture(0.25, 0.5, 0.15, 0.95)
		GameTooltip:SetOwner(g, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to move")
		GameTooltip:AddLine("Right-click to put it back.", 1, 1, 1)
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", function(g)
		g.bg:SetColorTexture(0.15, 0.15, 0.15, 0.85)
		GameTooltip:Hide()
	end)
	return grip
end

-- Make `frame` draggable by `grip`, remembering its position under `key`.
-- placeDefault(frame) anchors it in its default spot.
function ArtPad:MakeMovable(frame, key, grip, placeDefault)
	self.movables = self.movables or {}
	self.movables[key] = { frame = frame, placeDefault = placeDefault }
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	grip:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	grip:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		frame:SetUserPlaced(false) -- we save it ourselves
		local point, _, relPoint, x, y = frame:GetPoint(1)
		ArtPad_Settings.FramePositions[key] = { point, relPoint, x, y }
	end)
	grip:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then self:ResetFramePosition(key) end
	end)
	self:RestoreFramePosition(key)
end

function ArtPad:RestoreFramePosition(key)
	local m = self.movables[key]
	local pos = ArtPad_Settings.FramePositions[key]
	m.frame:ClearAllPoints()
	if type(pos) == "table" and pos[1] and tonumber(pos[3]) and tonumber(pos[4]) then
		m.frame:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3], pos[4])
	else
		m.placeDefault(m.frame)
	end
end

function ArtPad:ResetFramePosition(key)
	ArtPad_Settings.FramePositions[key] = nil
	self:RestoreFramePosition(key)
end

-- A bar along the top edge of the canvas: drag to move the canvas, right-click to fit it.
-- It's parented to the toolbar (not the canvas) so it stays a readable size at any zoom,
-- but anchored to the canvas so it moves with it.
function ArtPad:CreateCanvasHandle()
	local handle = self:CreateGrip(self.controlsFrame, "ArtPad_CanvasHandle", 1, 18, "horizontal")
	handle:SetPoint("BOTTOMLEFT", self.mainFrame, "TOPLEFT")
	handle:SetPoint("BOTTOMRIGHT", self.mainFrame, "TOPRIGHT")
	local label = handle:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	label:SetPoint("LEFT", 8, 0)
	label:SetText("ArtPad")
	handle:SetScript("OnDragStart", function()
		self:EndInteraction()
		self.state = "MOVE"
		self.mainFrame:StartMoving()
	end)
	handle:SetScript("OnDragStop", function()
		if self.state == "MOVE" then
			self:EndInteraction() -- stops moving and saves the position
		end
	end)
	handle:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then self:ResetPosition() end
	end)
	handle:SetScript("OnEnter", function(g)
		g.bg:SetColorTexture(0.25, 0.5, 0.15, 0.95)
		GameTooltip:SetOwner(g, "ANCHOR_TOP")
		GameTooltip:SetText("Drag to move the canvas")
		GameTooltip:AddLine("Right-click to fit it to your screen. Mouse wheel on the canvas zooms.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	self.canvasHandle = handle
end

function ArtPad:ResetAllFramePositions()
	for key in pairs(self.movables or {}) do
		self:ResetFramePosition(key)
	end
end

--[[ Setup ]]

function ArtPad:SetupUI()
	local c = ArtPad_Settings.Color
	self.brushColor = { r = c.r or 1, g = c.g or 1, b = c.b or 1, a = c.a or 1 }
	self.nameTags = {}

	-- Deliberately parentless so it stays visible with the UI hidden (Alt-Z).
	local f = CreateFrame("Frame", "ArtPad_Canvas")
	self.mainFrame = f
	f:SetFrameStrata("BACKGROUND")
	f:SetSize(self.canvasSize.X, self.canvasSize.Y)
	f:SetMovable(true)
	f:SetClampedToScreen(false)
	f:Hide()
	self:RestorePosition()

	self.canvasBackground = f:CreateTexture(nil, "BACKGROUND")
	self.canvasBackground:SetColorTexture(0, 0, 0, 0.5)
	self.canvasBackground:SetAllPoints(f)

	local BORDER = 5
	local function Edge(p1, p2, w, h)
		local t = f:CreateTexture(nil, "BORDER")
		t:SetColorTexture(1, 1, 1, 0.7)
		t:SetPoint(p1)
		t:SetPoint(p2)
		if w then t:SetWidth(w) end
		if h then t:SetHeight(h) end
	end
	Edge("TOPLEFT", "TOPRIGHT", nil, BORDER)
	Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, BORDER)
	Edge("TOPLEFT", "BOTTOMLEFT", BORDER, nil)
	Edge("TOPRIGHT", "BOTTOMRIGHT", BORDER, nil)

	self.eraserCursor = f:CreateTexture(nil, "OVERLAY", nil, 7)
	self.eraserCursor:SetTexture(self.MEDIA .. "ring")
	self.eraserCursor:SetVertexColor(1, 1, 1, 0.8)
	self.eraserCursor:Hide()

	-- Shows the not-yet-committed tail of a freehand stroke (see ExtendStroke).
	self.strokePreview = f:CreateLine(nil, "ARTWORK")
	self.strokePreview:Hide()

	self.nameTagFader = CreateFrame("Frame", nil, f)
	self.nameTagFader:Hide()
	self.nameTagFader:SetScript("OnUpdate", FadeNameTags)

	-- Toolbar
	self.controlsFrame = CreateFrame("Frame", "ArtPad_Controls", UIParent)
	self.controlsFrame:SetHeight(45)
	self.controlsFrame:Hide() -- positioned by MakeMovable in CreateControls
	self:CreateControls()
	self:CreateCanvasHandle()
	self:SetBrushSize(ArtPad_Settings.BrushSize)
	self:SetColor(self.brushColor.r, self.brushColor.g, self.brushColor.b, self.brushColor.a)

	self.versionText = self.controlsFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	self.versionText:SetPoint("BOTTOM", self.controlsFrame, "TOP", 0, 5)
	self:UpdateTitle()

	local input = CreateFrame("EditBox", "ArtPad_TextInput", self.controlsFrame, "InputBoxTemplate")
	self.textInput = input
	input:SetSize(300, 30)
	input:SetPoint("TOP", self.controlsFrame, "BOTTOM", 0, -66) -- below the status bar and toast
	input:SetAutoFocus(true)
	input:SetMaxLetters(200)
	input:SetFrameStrata("TOOLTIP")
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

	f:EnableMouse(true)
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseDown", self.OnMouseDown)
	f:SetScript("OnMouseUp", self.OnMouseUp)
	f:SetScript("OnMouseWheel", self.OnMouseWheel)
	f:SetScript("OnUpdate", self.OnUpdate)
	f:SetScript("OnShow", self.OnShow)
	f:SetScript("OnHide", self.OnHide)
end
