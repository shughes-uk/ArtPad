--[[
	Tools: the dock on the left of the screen.

	  Tools    pen (freehand), line, arrow, box, circle, text
	  Stamps   raid target markers and tank/healer/damage icons
	  Colours  quick swatches, your class colour, recent custom colours and the full picker

	Shapes become ordinary (non-smoothed) strokes, so syncing, erasing and undo just work.
]]

local ArtPad = ArtPad

local BUTTON = 30
local GAP = 3
local COLUMNS = 2

ArtPad.tool = "pen"
ArtPad.stampKey = "r8"

local SWATCHES = {
	{ 1, 1, 1 }, { 1, 0.25, 0.25 }, { 1, 0.6, 0.15 }, { 1, 0.9, 0.2 },
	{ 0.3, 0.9, 0.35 }, { 0.3, 0.7, 1 }, { 0.75, 0.45, 1 }, { 0.1, 0.1, 0.1 },
}

local TOOL_NAMES = {
	pen = "Pen", line = "Line", arrow = "Arrow", rect = "Box", circle = "Circle",
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
			line = self.mainFrame:CreateLine(nil, "OVERLAY")
			lines[count] = line
		end
		line:SetColorTexture(c.r, c.g, c.b, c.a * 0.7)
		line:SetThickness(ArtPad_Settings.BrushSize)
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
	local pts = self:ShapePoints(self.tool, start[1], start[2], x, y, ArtPad_Settings.BrushSize)
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
	local pts = self:ShapePoints(self.tool, start[1], start[2], finish[1], finish[2], ArtPad_Settings.BrushSize)
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

--[[ Tool selection ]]

function ArtPad:SetTool(tool, stampKey)
	self.tool = tool
	if stampKey then self.stampKey = stampKey end
	if tool ~= "stamp" and self.stampGhost then self.stampGhost:Hide() end
	self:RefreshDock()
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
	self:RefreshDock()
end

local function SameColor(c, r, g, b)
	return math.abs(c.r - r) < 0.01 and math.abs(c.g - g) < 0.01 and math.abs(c.b - b) < 0.01
end

--[[ Dock widgets ]]

local function DockButton(parent, name, tooltip, onClick)
	local b = CreateFrame("Button", name, parent)
	b:SetSize(BUTTON, BUTTON)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(0, 0, 0, 0.6)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.15)
	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnClick", onClick)
	b.tooltip = tooltip
	b:SetScript("OnEnter", function(btn)
		if not btn.tooltip then return end
		GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
		GameTooltip:SetText(btn.tooltip[1])
		for i = 2, #btn.tooltip do GameTooltip:AddLine(btn.tooltip[i], 1, 1, 1, true) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

-- Draw a little icon from line segments in button coordinates (0..BUTTON).
local function IconLines(b, segs)
	for _, s in ipairs(segs) do
		local line = b:CreateLine(nil, "ARTWORK")
		line:SetColorTexture(1, 1, 1, 0.9)
		line:SetThickness(2)
		line:SetStartPoint("BOTTOMLEFT", b, s[1], s[2])
		line:SetEndPoint("BOTTOMLEFT", b, s[3], s[4])
	end
end

local TOOL_ICONS = {
	pen = { { 7, 9, 11, 19 }, { 11, 19, 16, 12 }, { 16, 12, 20, 21 }, { 20, 21, 23, 15 } },
	line = { { 8, 8, 22, 22 } },
	arrow = { { 8, 8, 22, 22 }, { 22, 22, 14, 21 }, { 22, 22, 21, 14 } },
	rect = { { 8, 9, 22, 9 }, { 22, 9, 22, 21 }, { 22, 21, 8, 21 }, { 8, 21, 8, 9 } },
}

function ArtPad:SetupTools()
	self.shapePreviewLines = {}
	if type(ArtPad_Settings.RecentColors) ~= "table" then ArtPad_Settings.RecentColors = {} end

	self.stampGhost = self.mainFrame:CreateTexture(nil, "OVERLAY", nil, 6)
	self.stampGhost:SetAlpha(0.55)
	self.stampGhost:Hide()

	local dock = CreateFrame("Frame", "ArtPad_Dock", self.controlsFrame)
	dock:SetWidth(COLUMNS * BUTTON + (COLUMNS - 1) * GAP + 12)
	local bg = dock:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.45)
	self.dock = dock

	-- Grab handle across the top: drag to move, right-click to reset.
	local grip = self:CreateGrip(dock, "ArtPad_DockGrip", 1, 14, "horizontal")
	grip:SetPoint("TOPLEFT")
	grip:SetPoint("TOPRIGHT")
	self:MakeMovable(dock, "dock", grip, function(f)
		f:SetPoint("LEFT", UIParent, "LEFT", 12, 0)
	end)

	local y = -20
	local index = 0
	local function Header(text)
		if index % COLUMNS ~= 0 then y = y - BUTTON - GAP end
		index = 0
		local fs = dock:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", 6, y - 2)
		fs:SetText(text)
		y = y - 16
	end
	local function Place(b)
		local col = index % COLUMNS
		b:SetPoint("TOPLEFT", dock, "TOPLEFT", 6 + col * (BUTTON + GAP), y)
		index = index + 1
		if index % COLUMNS == 0 then y = y - BUTTON - GAP end
	end

	-- Tools
	self.toolButtons = {}
	Header("Tools")
	for _, tool in ipairs({ "pen", "line", "arrow", "rect", "circle" }) do
		local tips = { TOOL_NAMES[tool], tool == "pen" and "Freehand drawing" or "Drag to draw" }
		local b = DockButton(dock, "ArtPad_Tool_" .. tool, tips, function() self:SetTool(tool) end)
		if TOOL_ICONS[tool] then
			IconLines(b, TOOL_ICONS[tool])
		else
			local ring = b:CreateTexture(nil, "ARTWORK")
			ring:SetTexture(self.MEDIA .. "ring")
			ring:SetSize(18, 18)
			ring:SetPoint("CENTER")
		end
		self.toolButtons[tool] = b
		Place(b)
	end
	local text = DockButton(dock, "ArtPad_TextButton", { "Text", "Type, press Enter, then click the canvas" },
		function() self.buttons.Text() end)
	local t = text:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	t:SetPoint("CENTER")
	t:SetText("T")
	Place(text)

	-- Stamps
	self.stampButtons = {}
	Header("Markers")
	for _, key in ipairs(self.STAMP_ORDER) do
		local def = self.STAMPS[key]
		local b = DockButton(dock, "ArtPad_Stamp_" .. key, { def[6], "Click the canvas to place it.", "Size follows the brush." },
			function() self:SetTool("stamp", key) end)
		local icon = b:CreateTexture(nil, "ARTWORK")
		icon:SetTexture(def[1])
		icon:SetTexCoord(def[2], def[3], def[4], def[5])
		icon:SetSize(BUTTON - 6, BUTTON - 6)
		icon:SetPoint("CENTER")
		self.stampButtons[key] = b
		Place(b)
	end

	-- Colours
	self.swatchButtons = {}
	Header("Colours")
	local function Swatch(name, tooltip, getColor)
		local b = DockButton(dock, name, tooltip, function()
			local r, g, bl = getColor()
			if r then self:SetColor(r, g, bl, 1) end
		end)
		b.color = b:CreateTexture(nil, "ARTWORK")
		b.color:SetPoint("TOPLEFT", 4, -4)
		b.color:SetPoint("BOTTOMRIGHT", -4, 4)
		b.ring = b:CreateTexture(nil, "OVERLAY")
		b.ring:SetTexture(self.MEDIA .. "ring")
		b.ring:SetAllPoints()
		b.ring:Hide()
		b.getColor = getColor
		table.insert(self.swatchButtons, b)
		Place(b)
		return b
	end
	for i, c in ipairs(SWATCHES) do
		Swatch("ArtPad_Swatch" .. i, nil, function() return c[1], c[2], c[3] end)
	end
	Swatch("ArtPad_SwatchClass", { "Class colour" }, function() return self:GetClassColor() end)
	local custom = DockButton(dock, "ArtPad_SwatchCustom", { "More colours...", "Opens the colour picker (with opacity)." },
		function() self:OpenColorPicker() end)
	local plus = custom:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	plus:SetPoint("CENTER")
	plus:SetText("+")
	Place(custom)
	for i = 1, 4 do
		local b = Swatch("ArtPad_SwatchRecent" .. i, { "Recent colour" }, function()
			local c = ArtPad_Settings.RecentColors[i]
			if c then return c[1], c[2], c[3] end
		end)
		b.recent = i
	end

	if index % COLUMNS ~= 0 then y = y - BUTTON - GAP end
	dock:SetHeight(-y + 4)

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

	self:RefreshDock()
end

function ArtPad:RefreshDock()
	if not self.dock then return end
	for tool, b in pairs(self.toolButtons) do
		if self.tool == tool then b.bg:SetColorTexture(0.15, 0.48, 0, 0.85) else b.bg:SetColorTexture(0, 0, 0, 0.6) end
	end
	for key, b in pairs(self.stampButtons) do
		if self.tool == "stamp" and self.stampKey == key then
			b.bg:SetColorTexture(0.15, 0.48, 0, 0.85)
		else
			b.bg:SetColorTexture(0, 0, 0, 0.6)
		end
	end
	local cur = self.brushColor
	for _, b in ipairs(self.swatchButtons) do
		local r, g, bl = b.getColor()
		if r then
			b.color:SetColorTexture(r, g, bl, 1)
			b:Show()
			b.ring:SetShown(SameColor(cur, r, g, bl))
		elseif b.recent then
			b:Hide()
		end
	end
end
