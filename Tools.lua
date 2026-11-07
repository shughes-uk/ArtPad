--[[
	Tools: the tool rail (left), the inspector (right), the marker picker and the sharing
	popover, plus shape geometry, previews, the stamp ghost and the laser pointer.

	Shapes become ordinary (non-smoothed) strokes, so syncing, erasing and undo just work.
	Laser strokes are never stored: they fade after a moment, for everyone.
]]

local ArtPad = ArtPad
local C = ArtPad.C

ArtPad.tool = "pen"
ArtPad.stampKey = "r8"

local SWATCHES = {
	{ 0.95, 0.95, 0.96 }, { 1, 0.42, 0.37 }, { 0.96, 0.63, 0.26 }, { 0.95, 0.82, 0.29 }, { 0.33, 0.78, 0.44 },
	{ 0.25, 0.78, 0.92 }, { 0.30, 0.55, 1 }, { 0.69, 0.49, 1 }, { 0.96, 0.55, 0.73 }, { 0.11, 0.12, 0.13 },
}
local PRESETS = { 2, 5, 8, 13 }
local LASER_HOLD, LASER_FADE = 1.2, 0.6

local TOOLS = {
	{ "pen", "Pen" }, { "line", "Line" }, { "arrow", "Arrow" }, { "rect", "Box" },
	{ "circle", "Circle" }, { "text", "Text" }, false,
	{ "markers", "Markers" }, { "laser", "Laser" }, { "eraser", "Eraser" },
}

local GLYPHS = {
	pen = { { 2, 5, 6, 13 }, { 6, 13, 11, 9 }, { 11, 9, 14, 16 }, { 14, 16, 18, 12 } },
	line = { { 3, 3, 17, 17 } },
	arrow = { { 3, 3, 17, 17 }, { 17, 17, 9, 16 }, { 17, 17, 16, 9 } },
	rect = { { 3, 4, 17, 4 }, { 17, 4, 17, 16 }, { 17, 16, 3, 16 }, { 3, 16, 3, 4 } },
	eraser = { { 4, 10, 10, 4 }, { 10, 4, 16, 10 }, { 16, 10, 10, 16 }, { 10, 16, 4, 10 } },
	undo = { { 4, 10, 9, 15 }, { 4, 10, 9, 5 }, { 4, 10, 16, 10 } },
}

--[[ Shape geometry ]]

local function Clamp(v, lo, hi)
	if v < lo then return lo elseif v > hi then return hi end
	return v
end

-- Flat point list {x1, y1, x2, y2, ...} for a shape dragged from (x0,y0) to (x1,y1).
function ArtPad:ShapePoints(tool, x0, y0, x1, y1, w)
	local W, H = self.canvasSize.X, self.canvasSize.Y
	x1, y1 = Clamp(x1, 0, W), Clamp(y1, 0, H)
	local pts
	if tool == "line" then
		pts = { x0, y0, x1, y1 }
	elseif tool == "arrow" then
		local dx, dy = x1 - x0, y1 - y0
		local len = math.sqrt(dx * dx + dy * dy)
		if len < 1 then return { x0, y0 } end
		local ux, uy = dx / len, dy / len
		local wing = math.min(len * 0.4, math.max(16, w * 4))
		local c, s = math.cos(math.rad(28)), math.sin(math.rad(28))
		local lx, ly = x1 - wing * (ux * c - uy * s), y1 - wing * (uy * c + ux * s)
		local rx, ry = x1 - wing * (ux * c + uy * s), y1 - wing * (uy * c - ux * s)
		pts = { x0, y0, x1, y1, lx, ly, x1, y1, rx, ry }
	elseif tool == "rect" then
		pts = { x0, y0, x1, y0, x1, y1, x0, y1, x0, y0 }
	elseif tool == "circle" then
		local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
		local rx, ry = math.abs(x1 - x0) / 2, math.abs(y1 - y0) / 2
		local n = Clamp(math.floor(math.pi * (rx + ry) / 12), 16, 72)
		pts = {}
		for k = 0, n do
			local a = 2 * math.pi * k / n
			pts[#pts + 1] = cx + rx * math.cos(a)
			pts[#pts + 1] = cy + ry * math.sin(a)
		end
	else
		return nil
	end
	for k = 1, #pts, 2 do
		pts[k] = math.floor(Clamp(pts[k], 0, W) + 0.5)
		pts[k + 1] = math.floor(Clamp(pts[k + 1], 0, H) + 0.5)
	end
	return pts
end

--[[ Shape preview (local only) ]]

function ArtPad:ShowPolylinePreview(pts)
	local lines = self.shapePreviewLines
	local c = self.brushColor
	local count = 0
	for k = 1, #pts - 2, 2 do
		count = count + 1
		local line = lines[count]
		if not line then
			line = self.overlay:CreateLine(nil, "OVERLAY")
			lines[count] = line
		end
		line:SetColorTexture(c.r, c.g, c.b, c.a * 0.7)
		line:SetThickness(self:BrushWidth())
		line:SetStartPoint("BOTTOMLEFT", self.mainFrame, pts[k], pts[k + 1])
		line:SetEndPoint("BOTTOMLEFT", self.mainFrame, pts[k + 2], pts[k + 3])
		line:Show()
	end
	for k = count + 1, #lines do lines[k]:Hide() end
end

function ArtPad:HideShapePreview()
	for _, line in ipairs(self.shapePreviewLines) do line:Hide() end
end

function ArtPad:UpdateShapePreview(x, y)
	local start = self.shapeStart
	if not start then return end
	self.shapeEnd = { x, y }
	local pts = self:ShapePoints(self.tool, start[1], start[2], x, y, self:BrushWidth())
	if pts and #pts >= 4 then
		self:ShowPolylinePreview(pts)
	else
		self:HideShapePreview()
	end
end

function ArtPad:FinishShape()
	local start, finish = self.shapeStart, self.shapeEnd
	self.shapeStart, self.shapeEnd = nil, nil
	self:HideShapePreview()
	if not (start and finish) then return end
	local dx, dy = finish[1] - start[1], finish[2] - start[2]
	if dx * dx + dy * dy < 16 then return end -- a click, not a drag
	local pts = self:ShapePoints(self.tool, start[1], start[2], finish[1], finish[2], self:BrushWidth())
	if pts then self:DrawShape(pts) end
end

--[[ Stamp ghost ]]

function ArtPad:UpdateStampGhost(x, y)
	local ghost = self.stampGhost
	local def = self.STAMPS[self.stampKey]
	if self.tool ~= "stamp" or not def or x < 0 or y < 0 or x > self.canvasSize.X or y > self.canvasSize.Y then
		ghost:Hide()
		return
	end
	local size = self:GetStampSize()
	ghost:SetTexture(def[1])
	ghost:SetTexCoord(def[2], def[3], def[4], def[5])
	ghost:SetSize(size, size)
	ghost:ClearAllPoints()
	ghost:SetPoint("CENTER", self.mainFrame, "BOTTOMLEFT", x, y)
	ghost:Show()
end

--[[ Laser pointer: drawn locally and for everyone, never stored ]]

function ArtPad:DrawLaserSegment(x1, y1, x2, y2)
	local line = table.remove(self.laserPool)
	if not line then
		line = self.overlay:CreateLine(nil, "OVERLAY", nil, 6)
		if line.SetSnapToPixelGrid then line:SetSnapToPixelGrid(false) end
	end
	local k = UIParent:GetEffectiveScale() / self.mainFrame:GetEffectiveScale()
	line:SetColorTexture(1, 0.42, 0.37, 1)
	line:SetThickness(5 * k)
	line:SetStartPoint("BOTTOMLEFT", self.mainFrame, x1, y1)
	line:SetEndPoint("BOTTOMLEFT", self.mainFrame, x2, y2)
	line:SetAlpha(1)
	line:Show()
	line.born = GetTime()
	table.insert(self.laserLines, line)
	self.laserFader:Show()
end

local function FadeLaser(fader)
	local self = ArtPad
	local now = GetTime()
	for i = #self.laserLines, 1, -1 do
		local line = self.laserLines[i]
		local age = now - line.born
		if age >= LASER_HOLD + LASER_FADE then
			line:Hide()
			table.remove(self.laserLines, i)
			table.insert(self.laserPool, line)
		elseif age > LASER_HOLD then
			line:SetAlpha(1 - (age - LASER_HOLD) / LASER_FADE)
		end
	end
	if #self.laserLines == 0 then fader:Hide() end
end

function ArtPad:BeginLaser(x, y)
	local l = { localId = self:NewLocalId(), px = { x }, py = { y }, n = 1, sent = 0 }
	self.laser = l
	self:Enqueue({ laser = l })
end

function ArtPad:ExtendLaser(x, y)
	local l = self.laser
	if not l then return end
	x = Clamp(x, 0, self.canvasSize.X)
	y = Clamp(y, 0, self.canvasSize.Y)
	if not self.loopback then
		self:DrawLaserSegment(l.px[l.n], l.py[l.n], x, y)
	end
	l.n = l.n + 1
	l.px[l.n], l.py[l.n] = x, y
	self:QueueFlush()
end

function ArtPad:EndLaser()
	if self.laser then
		self.laser.done = true
		self.laser = nil
		self:QueueFlush()
	end
end

--[[ Tool selection ]]

function ArtPad:SetTool(tool, stampKey)
	if tool == "text" then
		self.buttons.Text()
		return
	end
	if tool == "markers" then
		self:ToggleMarkerPicker()
		return
	end
	self.tool = tool
	if stampKey then self.stampKey = stampKey end
	if tool ~= "stamp" and self.stampGhost then self.stampGhost:Hide() end
	self:RefreshRail()
end

function ArtPad:ToggleMarkerPicker()
	local picker = self.markerPicker
	if picker:IsShown() then
		picker:Hide()
	else
		self:ClosePopovers()
		picker:Show()
	end
end

--[[ Colours ]]

function ArtPad:GetClassColor()
	local _, class = UnitClass("player")
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return c.r, c.g, c.b end
end

function ArtPad:AddRecentColor(r, g, b)
	local recent = ArtPad_Settings.RecentColors
	for i = #recent, 1, -1 do
		local c = recent[i]
		if math.abs(c[1] - r) < 0.01 and math.abs(c[2] - g) < 0.01 and math.abs(c[3] - b) < 0.01 then
			table.remove(recent, i)
		end
	end
	table.insert(recent, 1, { r, g, b })
	while #recent > 4 do table.remove(recent) end
	self:RefreshInspector()
end

local function SameColor(c, r, g, b)
	return math.abs(c.r - r) < 0.01 and math.abs(c.g - g) < 0.01 and math.abs(c.b - b) < 0.01
end

-- A stable colour per player name for presence initials.
local NAME_COLORS = {
	{ 0.25, 0.78, 0.92 }, { 0.96, 0.55, 0.73 }, { 0.78, 0.61, 0.43 }, { 0.67, 0.83, 0.45 },
	{ 1, 0.49, 0.04 }, { 0.53, 0.53, 0.93 }, { 0.96, 0.96, 0.96 }, { 0, 1, 0.6 },
}
local function NameColor(name)
	local h = 0
	for i = 1, #name do h = (h * 31 + name:byte(i)) % 1000003 end
	return NAME_COLORS[h % #NAME_COLORS + 1]
end

--[[ Widgets ]]

local function Header(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function RailButton(self, parent, name, title, key, onClick)
	local b = CreateFrame("Button", name, parent)
	b:SetSize(40, 40)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(0, 0, 0, 0)
	b.mark = b:CreateTexture(nil, "BORDER")
	b.mark:SetPoint("TOPLEFT")
	b.mark:SetPoint("BOTTOMLEFT")
	b.mark:SetWidth(2)
	ArtPad.Fill(b.mark, C.accent)
	b.mark:Hide()
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnClick", onClick)
	b:SetMotionScriptsWhileDisabled(true)
	ArtPad.Tooltip(b, key and (title .. "  |cff9aa3ad" .. key .. "|r") or title)
	return b
end

function ArtPad:SetupTools()
	self.shapePreviewLines = {}
	self.laserLines, self.laserPool = {}, {}
	if type(ArtPad_Settings.RecentColors) ~= "table" then ArtPad_Settings.RecentColors = {} end

	self.stampGhost = self.overlay:CreateTexture(nil, "OVERLAY", nil, 6)
	self.stampGhost:SetAlpha(0.55)
	self.stampGhost:Hide()

	self.laserFader = CreateFrame("Frame", nil, self.mainFrame)
	self.laserFader:Hide()
	self.laserFader:SetScript("OnUpdate", FadeLaser)

	self:SetupRail()
	self:SetupInspector()
	self:SetupMarkerPicker()
	self:SetupSharing()

	-- Remember colours chosen in the full picker.
	if ColorPickerFrame and ColorPickerFrame.HookScript then
		ColorPickerFrame:HookScript("OnHide", function()
			if self.pickerOpen then
				self.pickerOpen = nil
				local c = self.brushColor
				self:AddRecentColor(c.r, c.g, c.b)
			end
		end)
	end

	self:RefreshRail()
	self:RefreshInspector()
end

--[[ Rail ]]

function ArtPad:SetupRail()
	local rail = self.rail
	self.toolButtons = {}
	local y = -6
	for _, t in ipairs(TOOLS) do
		if t then
			local tool, title, key = t[1], t[2], t[3]
			local name = tool == "text" and "ArtPad_TextButton" or ("ArtPad_Tool_" .. tool)
			local b = RailButton(self, rail, name, title, key, function() self:SetTool(tool) end)
			b:SetPoint("TOP", 0, y)
			if GLYPHS[tool] then
				self.DrawGlyph(b, GLYPHS[tool], 20, { 0.85, 0.87, 0.9 })
			elseif tool == "circle" then
				local ring = b:CreateTexture(nil, "ARTWORK")
				ring:SetTexture(self.MEDIA .. "ring")
				ring:SetSize(18, 18)
				ring:SetPoint("CENTER")
			elseif tool == "text" then
				local fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
				fs:SetPoint("CENTER")
				fs:SetText("T")
			elseif tool == "markers" then
				local def = self.STAMPS.r1
				local icon = b:CreateTexture(nil, "ARTWORK")
				icon:SetTexture(def[1])
				icon:SetTexCoord(def[2], def[3], def[4], def[5])
				icon:SetSize(20, 20)
				icon:SetPoint("CENTER")
				b.icon = icon
			elseif tool == "laser" then
				local dot = b:CreateTexture(nil, "ARTWORK")
				dot:SetTexture(self.MEDIA .. "dot")
				dot:SetVertexColor(1, 0.42, 0.37, 1)
				dot:SetSize(8, 8)
				dot:SetPoint("CENTER")
				local ring = b:CreateTexture(nil, "ARTWORK")
				ring:SetTexture(self.MEDIA .. "ring")
				ring:SetVertexColor(0.85, 0.87, 0.9, 0.7)
				ring:SetSize(18, 18)
				ring:SetPoint("CENTER")
			end
			self.toolButtons[tool] = b
			y = y - 42
		else
			local d = self.Divider(rail, true)
			d:SetPoint("TOPLEFT", 10, y - 4)
			d:SetPoint("TOPRIGHT", -10, y - 4)
			y = y - 10
		end
	end

	local undo = RailButton(self, rail, "ArtPad_UndoButton", "Undo", "Ctrl-Z", self.buttons.Undo)
	undo:SetPoint("BOTTOM", 0, 6)
	self.DrawGlyph(undo, GLYPHS.undo, 20, { 0.85, 0.87, 0.9 })
	self.undoButton = undo
	-- tools, a gap, then undo (40 + 6) at the bottom
	self:FitContent(-y + 8 + 46)
end

function ArtPad:RefreshRail()
	if not self.toolButtons then return end
	for tool, b in pairs(self.toolButtons) do
		local active = self.tool == tool or (tool == "markers" and self.tool == "stamp")
		if active then
			self.Fill(b.bg, C.accent, 0.20)
			b.mark:Show()
		else
			b.bg:SetColorTexture(0, 0, 0, 0)
			b.mark:Hide()
		end
	end
	-- the markers button shows the marker you're placing
	local mb = self.toolButtons.markers
	if mb and mb.icon then
		local def = self.STAMPS[self.stampKey] or self.STAMPS.r1
		mb.icon:SetTexture(def[1])
		mb.icon:SetTexCoord(def[2], def[3], def[4], def[5])
	end
end

--[[ Inspector ]]

function ArtPad:SetupInspector()
	local p = self.inspector
	local W = self.layout.INSPECTOR_W - 32
	local y = -16

	-- Brush
	Header(p, "BRUSH", 16, y)
	self.brushValue = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.brushValue:SetPoint("TOPRIGHT", -16, y)
	y = y - 22
	local preview = p:CreateTexture(nil, "ARTWORK")
	preview:SetTexture(self.MEDIA .. "dot")
	preview:SetPoint("CENTER", p, "TOPLEFT", 16 + 10, y - 8)
	self.brushPreview = preview
	local slider = self:FlatSlider(p, "ArtPad_BrushSlider", 1, 32, 1, function(v)
		self:SetBrushSize(v)
	end)
	slider:SetPoint("TOPLEFT", 16 + 28, y)
	slider:SetWidth(W - 28)
	self.brushSlider = slider
	y = y - 26
	self.presetButtons = {}
	local pw = (W - 3 * 6) / 4
	for i, size in ipairs(PRESETS) do
		local b = self:FlatButton(p, "ArtPad_BrushPreset" .. i, pw, 24, tostring(size), function() self:SetBrushSize(size) end)
		b:SetPoint("TOPLEFT", 16 + (i - 1) * (pw + 6), y)
		b.size = size
		self.presetButtons[i] = b
	end
	y = y - 44

	-- Colour
	Header(p, "COLOUR", 16, y)
	y = y - 20
	self.swatchButtons = {}
	local cell = (W - 5 * 6) / 6
	local function Swatch(name, index, getColor, tip)
		local b = CreateFrame("Button", name, p)
		b:SetSize(cell, 24)
		local col, row = (index - 1) % 6, math.floor((index - 1) / 6)
		b:SetPoint("TOPLEFT", 16 + col * (cell + 6), y - row * 30)
		b.color = b:CreateTexture(nil, "ARTWORK")
		b.color:SetAllPoints()
		b.ring = b:CreateTexture(nil, "BACKGROUND")
		b.ring:SetPoint("TOPLEFT", -3, 3)
		b.ring:SetPoint("BOTTOMRIGHT", 3, -3)
		b.ring:SetColorTexture(0.95, 0.95, 0.96, 1)
		b.ring:Hide()
		b.getColor = getColor
		b:SetScript("OnClick", function()
			local r, g, bl = getColor()
			if r then self:SetColor(r, g, bl, self.brushColor.a) end
		end)
		if tip then ArtPad.Tooltip(b, tip) end
		table.insert(self.swatchButtons, b)
		return b
	end
	for i, c in ipairs(SWATCHES) do
		Swatch("ArtPad_Swatch" .. i, i, function() return c[1], c[2], c[3] end)
	end
	local class = Swatch("ArtPad_SwatchClass", 11, function() return self:GetClassColor() end, "Class colour")
	local classLabel = class:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	classLabel:SetPoint("CENTER")
	classLabel:SetText("MY")
	classLabel:SetTextColor(0.05, 0.08, 0.1)
	local custom = self:FlatButton(p, "ArtPad_SwatchCustom", cell, 24, "+", function() self:OpenColorPicker() end)
	custom:SetPoint("TOPLEFT", 16 + 5 * (cell + 6), y - 30)
	ArtPad.Tooltip(custom, "More colours")
	for i = 1, 4 do
		local b = Swatch("ArtPad_SwatchRecent" .. i, 12 + i, function()
			local c = ArtPad_Settings.RecentColors[i]
			if c then return c[1], c[2], c[3] end
		end, "Recent")
		b.recent = i
	end
	y = y - 92
	local opLabel = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	opLabel:SetPoint("TOPLEFT", 16, y)
	opLabel:SetText("Opacity")
	self.opacityValue = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.opacityValue:SetPoint("TOPRIGHT", -16, y)
	y = y - 16
	local opacity = self:FlatSlider(p, "ArtPad_OpacitySlider", 10, 100, 5, function(v)
		local c = self.brushColor
		self:SetColor(c.r, c.g, c.b, v / 100)
	end)
	opacity:SetPoint("TOPLEFT", 16, y)
	opacity:SetWidth(W)
	self.opacitySlider = opacity
	y = y - 40

	-- Map
	Header(p, "MAP", 16, y)
	y = y - 20
	local card = CreateFrame("Frame", nil, p)
	card:SetSize(W, 50)
	card:SetPoint("TOPLEFT", 16, y)
	self.Background(card, { 0.133, 0.149, 0.173 })
	self.mapTitle = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.mapTitle:SetPoint("TOPLEFT", 10, -10)
	self.mapTitle:SetWidth(W - 60)
	self.mapTitle:SetJustifyH("LEFT")
	self.mapSub = card:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	self.mapSub:SetPoint("TOPLEFT", self.mapTitle, "BOTTOMLEFT", 0, -4)
	self.mapSwitch = self:Switch(card, "ArtPad_MapButton",
		function() return self.backdropMap ~= nil end,
		function() self:ToggleMap() end)
	self.mapSwitch:SetPoint("RIGHT", -10, 0)
	self.mapButton = self.mapSwitch
	y = y - 62
	local dimLabel = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	dimLabel:SetPoint("TOPLEFT", 16, y)
	dimLabel:SetText("Map dimming")
	self.dimValue = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	self.dimValue:SetPoint("TOPRIGHT", -16, y)
	y = y - 16
	local dim = self:FlatSlider(p, "ArtPad_MapDimSlider", 0, 80, 5, function(v)
		ArtPad_Settings.MapDim = v / 100
		self:ApplyMapDim()
		self:RefreshInspector()
	end)
	dim:SetPoint("TOPLEFT", 16, y)
	dim:SetWidth(W)
	self:FitContent(-y + 20 + 16) -- slider, bottom padding
	self.dimSlider = dim
end

function ArtPad:RefreshInspector()
	if not self.brushSlider then return end
	local size = ArtPad_Settings.BrushSize
	local c = self.brushColor
	self.brushValue:SetText(size .. " px")
	self.brushSlider.Set(math.min(32, size))
	local dot = math.max(3, math.min(20, size))
	self.brushPreview:SetSize(dot, dot)
	self.brushPreview:SetVertexColor(c.r, c.g, c.b, math.max(0.35, c.a))
	for _, b in ipairs(self.presetButtons) do
		if b.size == size then
			self.Fill(b.bg, C.accent, 0.25)
		else
			self.Fill(b.bg, { 0.137, 0.157, 0.188 })
		end
	end
	for _, b in ipairs(self.swatchButtons) do
		local r, g, bl = b.getColor()
		if r then
			b.color:SetColorTexture(r, g, bl, 1)
			b:Show()
			b.ring:SetShown(SameColor(c, r, g, bl))
		elseif b.recent then
			b:Hide()
		end
	end
	local pct = math.floor(c.a * 100 + 0.5)
	self.opacityValue:SetText(pct .. "%")
	self.opacitySlider.Set(pct)

	if self.node then
		self.mapTitle:SetText(self.node.name)
		self.mapSub:SetText("The map around you")
	elseif self.backdropMap then
		self.mapTitle:SetText(self:GetMapName(self.backdropMap) or "Map")
		self.mapSub:SetText(self.backdropBy and ("Shared by " .. self.backdropBy) or "Shared")
	else
		self.mapTitle:SetText("No map")
		self.mapSub:SetText(self:CanShowMaps() and "Show where you are" or "Not available here")
	end
	self.mapSwitch:Refresh()
	local dim = math.floor((ArtPad_Settings.MapDim or 0) * 100 + 0.5)
	self.dimValue:SetText(dim .. "%")
	self.dimSlider.Set(dim)
end

--[[ Marker picker ]]

function ArtPad:SetupMarkerPicker()
	local anchor = self.toolButtons.markers
	local picker = CreateFrame("Frame", "ArtPad_MarkerPicker", self.window)
	local cell = 48
	picker:SetSize(4 * cell + 3 * 6 + 24, 2 * cell + 6 + 36 + 8 + 24)
	picker:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
	picker:SetFrameLevel(self.window:GetFrameLevel() + 40)
	picker:EnableMouse(true)
	self.Background(picker, C.bar)
	self.stampButtons = {}
	local function Pick(key)
		picker:Hide()
		self:SetTool("stamp", key)
	end
	for i = 1, 8 do
		local key = "r" .. i
		local def = self.STAMPS[key]
		local b = self:FlatButton(picker, "ArtPad_Stamp_" .. key, cell, cell, nil, function() Pick(key) end)
		b:SetPoint("TOPLEFT", 12 + ((i - 1) % 4) * (cell + 6), -12 - math.floor((i - 1) / 4) * (cell + 6))
		local icon = b:CreateTexture(nil, "ARTWORK")
		icon:SetTexture(def[1])
		icon:SetTexCoord(def[2], def[3], def[4], def[5])
		icon:SetSize(26, 26)
		icon:SetPoint("CENTER")
		ArtPad.Tooltip(b, def[6])
		self.stampButtons[key] = b
	end
	local rw = (4 * cell + 3 * 6 - 2 * 6) / 3
	for i, key in ipairs({ "tank", "heal", "dps" }) do
		local def = self.STAMPS[key]
		local b = self:FlatButton(picker, "ArtPad_Stamp_" .. key, rw, 36, nil, function() Pick(key) end)
		b:SetPoint("TOPLEFT", 12 + (i - 1) * (rw + 6), -12 - 2 * (cell + 6))
		local icon = b:CreateTexture(nil, "ARTWORK")
		icon:SetTexture(def[1])
		icon:SetTexCoord(def[2], def[3], def[4], def[5])
		icon:SetSize(24, 24)
		icon:SetPoint("CENTER")
		ArtPad.Tooltip(b, def[6])
		self.stampButtons[key] = b
	end
	picker:Hide()
	self.markerPicker = picker
	self:RegisterPopover(picker)
end

--[[ Presence (title bar), sharing pill (status bar) and its popover ]]

function ArtPad:SetupSharing()
	local title = self.titleBar

	-- presence: initials of people drawing recently
	local presence = CreateFrame("Frame", "ArtPad_Presence", title)
	presence:SetSize(1, 26)
	presence:SetPoint("RIGHT", self.clearButton, "LEFT", -12, 0)
	self.presence = presence
	self.presenceBadges = {}
	for i = 1, 4 do
		local badge = CreateFrame("Frame", nil, presence)
		badge:SetSize(24, 24)
		badge.circle = badge:CreateTexture(nil, "ARTWORK")
		badge.circle:SetTexture(self.MEDIA .. "dot")
		badge.circle:SetAllPoints()
		badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		badge.text:SetPoint("CENTER")
		badge:Hide()
		self.presenceBadges[i] = badge
	end

	-- the pill: start of the status bar
	local pill = CreateFrame("Button", "ArtPad_SharingButton", self.statusBar)
	pill:SetHeight(20)
	pill:SetPoint("LEFT", 6, 0)
	self.Background(pill, { 0.137, 0.157, 0.188 })
	local hl = pill:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	pill.dot = pill:CreateTexture(nil, "ARTWORK")
	pill.dot:SetTexture(self.MEDIA .. "dot")
	pill.dot:SetSize(7, 7)
	pill.dot:SetPoint("LEFT", 8, 0)
	pill.text = pill:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	pill.text:SetPoint("LEFT", pill.dot, "RIGHT", 8, 0)
	pill:SetScript("OnClick", function()
		local pop = self.sharingPopover
		if pop:IsShown() then
			pop:Hide()
		else
			self:ClosePopovers()
			self:RefreshSharingPopover()
			pop:Show()
		end
	end)
	self.sharingButton = pill

	-- the popover
	local pop = CreateFrame("Frame", "ArtPad_SharingPopover", self.window)
	pop:SetSize(260, 218)
	pop:SetPoint("BOTTOMLEFT", pill, "TOPLEFT", 0, 8)
	pop:SetFrameLevel(self.window:GetFrameLevel() + 40)
	pop:EnableMouse(true)
	self.Background(pop, C.bar)
	local function Option(name, mode, label, y)
		local b = CreateFrame("Button", name, pop)
		b:SetSize(240, 44)
		b:SetPoint("TOPLEFT", 10, y)
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.bg:SetAllPoints()
		b.bg:SetColorTexture(0, 0, 0, 0)
		local hlo = b:CreateTexture(nil, "HIGHLIGHT")
		hlo:SetAllPoints()
		hlo:SetColorTexture(1, 1, 1, 0.06)
		b.radio = b:CreateTexture(nil, "ARTWORK")
		b.radio:SetTexture(self.MEDIA .. "ring")
		b.radio:SetSize(16, 16)
		b.radio:SetPoint("LEFT", 10, 0)
		b.radioDot = b:CreateTexture(nil, "OVERLAY")
		b.radioDot:SetTexture(self.MEDIA .. "dot")
		b.radioDot:SetSize(8, 8)
		b.radioDot:SetPoint("CENTER", b.radio, "CENTER")
		b.title = b:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		b.title:SetPoint("TOPLEFT", 36, -7)
		b.title:SetText(label)
		b.sub = b:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		b.sub:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -3)
		b.mode = mode
		b:SetScript("OnClick", function()
			self:SetMode(mode)
			self:RefreshSharingPopover()
		end)
		return b
	end
	self.shareGuild = Option("ArtPad_ShareGuild", "GUILD", "Guild", -10)
	self.shareGroup = Option("ArtPad_ShareGroup", "RAID", "Party / raid", -56)
	local d = self.Divider(pop, true)
	d:SetPoint("TOPLEFT", 14, -108)
	d:SetPoint("TOPRIGHT", -14, -108)
	self.shareSwitches = {}
	local function Toggle(name, label, key, y)
		local fs = pop:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		fs:SetPoint("TOPLEFT", 20, y - 3)
		fs:SetText(label)
		local s = self:Switch(pop, name, function() return ArtPad_Settings[key] and true or false end,
			function(v)
				ArtPad_Settings[key] = v
				if key == "AdminOnly" then self.guildRanks = nil end
				self:RefreshOptions()
				self:RequestRefresh()
			end)
		s:SetPoint("TOPRIGHT", -16, y)
		table.insert(self.shareSwitches, s)
	end
	Toggle("ArtPad_ToggleAdmin", "Leaders only", "AdminOnly", -122)
	Toggle("ArtPad_ToggleNames", "Name tags", "NameTags", -154)
	Toggle("ArtPad_ToggleMyName", "Show my name", "ShowMyName", -186)
	pop:Hide()
	self.sharingPopover = pop
	self:RegisterPopover(pop)
end

function ArtPad:RefreshSharingPopover()
	local _, online = GetNumGuildMembers()
	self.shareGuild.sub:SetText(IsInGuild() and ((online or 0) .. " online") or "Not in a guild")
	local n = GetNumGroupMembers()
	self.shareGroup.sub:SetText(n > 0 and (n .. " in group") or "Not in a group")
	for _, b in ipairs({ self.shareGuild, self.shareGroup }) do
		local on = ArtPad_Settings.Mode == b.mode
		if on then
			self.Fill(b.bg, C.accent, 0.16)
			b.radio:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1)
			b.radioDot:Show()
			b.radioDot:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1)
		else
			b.bg:SetColorTexture(0, 0, 0, 0)
			b.radio:SetVertexColor(0.42, 0.45, 0.5, 1)
			b.radioDot:Hide()
		end
	end
	for _, s in ipairs(self.shareSwitches) do s:Refresh() end
end

-- Initials of people who drew in the last minute.
function ArtPad:RefreshPresence(names)
	local badges = self.presenceBadges
	local shown = math.min(#names, #names > 4 and 3 or 4)
	local width = 0
	for i, badge in ipairs(badges) do
		badge:ClearAllPoints()
		if i <= shown then
			local name = names[i]
			local col = NameColor(name)
			badge.circle:SetVertexColor(col[1], col[2], col[3], 1)
			badge.text:SetText(name:sub(1, 2))
			badge.text:SetTextColor(0.06, 0.07, 0.08)
			badge:SetPoint("LEFT", self.presence, "LEFT", width, 0)
			badge:Show()
			width = width + 20
		elseif i == 4 and #names > 4 then
			badge.circle:SetVertexColor(0.2, 0.23, 0.26, 1)
			badge.text:SetText("+" .. (#names - 3))
			badge.text:SetTextColor(0.79, 0.81, 0.83)
			badge:SetPoint("LEFT", self.presence, "LEFT", width, 0)
			badge:Show()
			width = width + 20
		else
			badge:Hide()
		end
	end
	self.presence:SetWidth(math.max(1, width + (shown > 0 and 4 or 0)))
end
