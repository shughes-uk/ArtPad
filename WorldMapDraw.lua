--[[
	PROTOTYPE: drawing on the world map itself. Local only - nothing here is sent to anyone.

	The design follows the map's own grammar (Blizzard_WorldMap's Map Pin button):

	  One round button at the map's top-right turns drawing on and off: it glows while on,
	  clicks like Blizzard's buttons, and turns itself off when the map closes. A small dot on
	  it means the map you're looking at has a drawing. Nothing else is on the map until then.

	  While on, a slim toolbar unfolds from the button: pen, eraser | undo, clear.
	    - Drag draws. A plain click still works the map (zones and pins), and so does
	      right-click (up a level): drawing never traps you. Hovering still works the map too.
	    - The pen icon wears the current colour. Click the active pen again for colours and
	      sizes. Shift + mouse wheel also changes the size.
	    - The cursor shows the tool: a dot of ink at the brush's real size and colour, or the
	      eraser's ring, which lights up the stroke it is about to remove.
	    - Undo (also Ctrl-Z) steps back through strokes, erasing and clearing alike, so Clear
	      needs no warning. Esc closes the options, then puts the tools away.
	  Holding Alt is a temporary pen without opening the toolbar.

	Each map (zone, continent...) has its own drawing, stored in 0-1 map coordinates and kept
	in ArtPad_Settings.MapDrawings.

	How it attaches to Blizzard's map (Blizzard_MapCanvas):
	  WorldMapFrame.ScrollContainer.Child is the layer that scrolls and zooms with the map.
	  Everything on the map is layered by frame level (MapCanvasPinFrameLevelsManager): the
	  explored-area art, fog and zone highlight are "pins" too, at levels 2001-2009, and icon
	  pins start above that. The drawing goes just above the zone highlight: over the map
	  art, under the player arrow, group members and other addons' pins. A second frame above
	  the pins catches mouse buttons, and only exists while drawing, so the map works normally
	  otherwise.

	Mouse, in detail. The catcher takes clicks only; mouse motion is left to the map, so zone
	highlights, coordinates and pin tooltips keep working. Right-clicks pass straight through.
	Left presses reach the map as well as the catcher ("propagate") whenever that is safe: the
	pen is in hand, the map can't be dragged to pan (not zoomed in) and the pen's options are
	closed. The map's own click test then ignores our drags and handles real clicks, pins
	included. Otherwise (eraser, zoomed in, client without the API) the catcher keeps the
	press and a click that did nothing is handed to the map by calling its navigation.
	Both switches are protected in combat, so they are only changed out of combat.

	Combat: override key bindings can't change in combat either. Esc and Ctrl-Z are released
	as combat starts and taken back when it ends.
]]

local ArtPad = ArtPad

local MIN_STEP = 3 -- screen pixels between sampled points
local CLICK_SLOP = 4.5 -- screen pixels: less movement than this is a click (Blizzard's own figure)
local SIMPLIFY = 0.75 -- screen pixels a finished stroke may deviate when its points are thinned
local MAX_LINES = 6000 -- per map
-- The client stops drawing everything past ~16384 quads on screen. The main canvas budgets
-- itself to 14500; when its window is open too, the map takes what is left of TOTAL_QUADS.
local TOTAL_QUADS, MIN_LINES = 15500, 500
local ERASE_RADIUS = 10 -- screen pixels
local FALLBACK_LEVEL = 2010 -- just above PIN_FRAME_LEVEL_MAP_HIGHLIGHT in Blizzard_WorldMap
local SIZES = { 3, 6, 11 } -- brush sizes offered in the pen's options (3 is ArtPad's default)
local MAX_SIZE = 24 -- largest size Shift + wheel reaches
local HISTORY = 50 -- undo steps kept per map (this session only)

-- 20x20 glyphs, origin bottom-left (see ArtPad.DrawGlyph)
local PENCIL = { { 4, 4, 6, 9 }, { 4, 4, 9, 6 }, { 6, 9, 13, 16 }, { 9, 6, 16, 13 }, { 13, 16, 16, 13 } }
local TRASH = {
	{ 4, 14, 16, 14 }, { 8, 14, 8, 16 }, { 8, 16, 12, 16 }, { 12, 16, 12, 14 },
	{ 6, 14, 7, 4 }, { 7, 4, 13, 4 }, { 13, 4, 14, 14 },
}

local wm = {
	pool = {}, -- free line regions
	count = 0, -- line regions in use (= segments drawn on the map on show)
	linesOf = setmetatable({}, { __mode = "k" }), -- stroke -> its line regions
	history = {}, -- mapID -> stack of earlier stroke lists
	on = false, -- the toolbar is out
	tool = "pen", -- "pen" or "eraser"
	propagating = false, -- left presses also reach the map (see the top of the file)
}
ArtPad.worldMapDraw = wm

--[[ Storage ]]

local function Drawings()
	if type(ArtPad_Settings.MapDrawings) ~= "table" then ArtPad_Settings.MapDrawings = {} end
	return ArtPad_Settings.MapDrawings
end

local function Strokes(mapID, create)
	local all = Drawings()
	if not all[mapID] and create then all[mapID] = {} end
	return all[mapID]
end

-- Remember this map's strokes as they are now, so the next change can be undone.
local function Snapshot(mapID)
	local h = wm.history[mapID]
	if not h then
		h = {}
		wm.history[mapID] = h
	end
	local copy = {}
	for i, stroke in ipairs(Strokes(mapID) or {}) do copy[i] = stroke end
	table.insert(h, copy)
	if #h > HISTORY then table.remove(h, 1) end
end

--[[ Rendering ]]

-- Canvas size in its own units, and canvas units per screen pixel.
local function CanvasSize()
	return wm.canvas:GetWidth() or 0, wm.canvas:GetHeight() or 0
end

local function UnitsPerPixel()
	return UIParent:GetEffectiveScale() / wm.canvas:GetEffectiveScale()
end

-- How many segments this map may hold right now (stored and drawn alike).
local function Budget()
	local main = ArtPad.window and ArtPad.window:IsShown() and ArtPad.quadsInUse or 0
	return math.max(MIN_LINES, math.min(MAX_LINES, TOTAL_QUADS - main))
end

local function WarnFull()
	if wm.warnedFull then return end
	wm.warnedFull = true
	ArtPad:Message("This map is full.")
end

local function AcquireLine()
	if wm.count >= Budget() then return nil end
	local line = table.remove(wm.pool)
	if not line then
		line = wm.layer:CreateLine(nil, "ARTWORK")
		if line.SetSnapToPixelGrid then line:SetSnapToPixelGrid(false) end
		if line.SetTexelSnappingBias then line:SetTexelSnappingBias(0) end
	end
	line:Show()
	wm.count = wm.count + 1
	return line
end

local function DrawSegment(stroke, i, W, H)
	local p = stroke.p
	local line = AcquireLine()
	if not line then return false end
	line:SetColorTexture(stroke.r, stroke.g, stroke.b, stroke.a)
	line:SetThickness(math.max(0.5, stroke.w * W))
	line:SetStartPoint("TOPLEFT", wm.layer, p[i] * W, -p[i + 1] * H)
	line:SetEndPoint("TOPLEFT", wm.layer, p[i + 2] * W, -p[i + 3] * H)
	local own = wm.linesOf[stroke]
	if not own then
		own = {}
		wm.linesOf[stroke] = own
	end
	table.insert(own, line)
	return true
end

local function DrawStroke(stroke, W, H)
	for i = 1, #stroke.p - 3, 2 do
		if not DrawSegment(stroke, i, W, H) then return end
	end
end

-- Take one stroke's lines off the map.
local function ReleaseStroke(stroke)
	local own = wm.linesOf[stroke]
	if not own then return end
	for i = #own, 1, -1 do
		own[i]:Hide()
		table.insert(wm.pool, own[i])
	end
	wm.count = wm.count - #own
	wm.linesOf[stroke] = nil
	if wm.hover == stroke then wm.hover = nil end
	if wm.count < Budget() then wm.warnedFull = false end
end

-- Draw the map on show. Skipped when that map is already drawn at this size, unless forced
-- (the stroke list itself was swapped: undo, clear).
function ArtPad:WorldMapRedraw(force)
	if not wm.ready then return end
	local mapID = WorldMapFrame:GetMapID()
	local W, H = CanvasSize()
	if not force and mapID == wm.mapID and W == wm.drawnW and H == wm.drawnH then return end
	for stroke in pairs(wm.linesOf) do ReleaseStroke(stroke) end
	wm.count = 0
	wm.warnedFull = false
	wm.hover = nil
	wm.cursorDirty = true
	wm.mapID, wm.drawnW, wm.drawnH = mapID, W, H
	local strokes = mapID and Strokes(mapID)
	if not strokes or W <= 0 or H <= 0 then return end
	for _, stroke in ipairs(strokes) do DrawStroke(stroke, W, H) end
end

-- The eraser lights up the stroke it would remove, in whichever of white or dark red stands
-- out from that stroke's own colour.
local function Tint(stroke, lit)
	local r, g, b, a = stroke.r, stroke.g, stroke.b, stroke.a
	if lit then
		if 0.299 * r + 0.587 * g + 0.114 * b > 0.6 then
			r, g, b, a = 0.8, 0.1, 0.1, 1
		else
			r, g, b, a = 1, 1, 1, 1
		end
	end
	for _, line in ipairs(wm.linesOf[stroke] or {}) do line:SetColorTexture(r, g, b, a) end
end

local function SetHover(stroke)
	if wm.hover == stroke then return end
	if wm.hover then Tint(wm.hover, false) end
	wm.hover = stroke
	if stroke then Tint(stroke, true) end
end

--[[ Drawing and erasing ]]

local function Cursor()
	local x, y = WorldMapFrame.ScrollContainer:GetNormalizedCursorPosition()
	if not x then return nil end
	return math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
end

-- The tool in hand: the toolbar's while it's out, otherwise (Alt held) the pen.
local function Tool()
	return wm.on and wm.tool or "pen"
end

-- Has the cursor left the spot it was pressed at? Until it has, the press is still a click.
local function PressMoved()
	local press = wm.press
	if not press then return true end
	local sx, sy = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	local dx, dy = (sx - press.x) / scale, (sy - press.y) / scale
	return dx * dx + dy * dy > CLICK_SLOP * CLICK_SLOP
end

local function Round(v)
	return math.floor(v * 10000 + 0.5) / 10000
end

-- Thin a finished stroke's points (Ramer-Douglas-Peucker): drop every point that lies within
-- `tolerance` canvas units of the line through its kept neighbours. Coordinates are rounded
-- to 4 places (a tenth of a map pixel), which keeps the saved file small.
local function Simplify(p, W, H, tolerance)
	local n = #p / 2
	local keep = { [1] = true, [n] = true }
	local stack = { 1, n }
	while #stack > 0 do
		local b = table.remove(stack)
		local a = table.remove(stack)
		local ax, ay, bx, by = p[2 * a - 1] * W, p[2 * a] * H, p[2 * b - 1] * W, p[2 * b] * H
		local worst, at = tolerance, nil
		for i = a + 1, b - 1 do
			local d = ArtPad.PointSegDist(p[2 * i - 1] * W, p[2 * i] * H, ax, ay, bx, by)
			if d > worst then worst, at = d, i end
		end
		if at then
			keep[at] = true
			stack[#stack + 1], stack[#stack + 2] = a, at
			stack[#stack + 1], stack[#stack + 2] = at, b
		end
	end
	local out = {}
	for i = 1, n do
		if keep[i] then
			out[#out + 1] = Round(p[2 * i - 1])
			out[#out + 1] = Round(p[2 * i])
		end
	end
	return out
end

local function BeginStroke()
	local x, y = Cursor()
	local mapID = WorldMapFrame:GetMapID()
	local W = CanvasSize()
	if not x or not mapID or W <= 0 then return end
	if wm.count >= Budget() then
		WarnFull() -- nothing more fits; the press stays a click
		return
	end
	local c = ArtPad.brushColor
	wm.stroke = {
		r = c.r, g = c.g, b = c.b, a = c.a,
		w = ArtPad_Settings.BrushSize * UnitsPerPixel() / W, -- as a fraction of the map's width
		p = { x, y },
	}
	wm.strokeMap, wm.strokeReal = mapID, false
end

-- Finish the stroke in progress: thin its points and redraw it from them.
local function EndStroke()
	local stroke, mapID, real = wm.stroke, wm.strokeMap, wm.strokeReal
	wm.stroke, wm.strokeMap, wm.strokeReal = nil, nil, false
	if not stroke or not real then return end
	local W, H = CanvasSize()
	if W <= 0 or H <= 0 then return end
	stroke.p = Simplify(stroke.p, W, H, SIMPLIFY * UnitsPerPixel())
	if mapID == wm.mapID then
		ReleaseStroke(stroke)
		DrawStroke(stroke, W, H)
	end
end

local function ExtendStroke()
	local stroke = wm.stroke
	if not stroke or WorldMapFrame:GetMapID() ~= wm.strokeMap then return end
	local x, y = Cursor()
	if not x then return end
	local W, H = CanvasSize()
	local p = stroke.p
	local n = #p
	if not wm.strokeReal then
		-- Still a click until the cursor leaves the spot it was pressed at; then the press was
		-- a drag and the stroke becomes real, starting from that spot.
		if not PressMoved() then return end
		Snapshot(wm.strokeMap)
		table.insert(Strokes(wm.strokeMap, true), stroke)
		wm.strokeReal = true
		if wm.press then wm.press.acted = true end
		ArtPad:WorldMapHint(false)
	else
		local dx, dy = (x - p[n - 1]) * W, (y - p[n]) * H
		local step = MIN_STEP * UnitsPerPixel()
		if dx * dx + dy * dy < step * step then return end
	end
	if wm.count >= Budget() then
		-- full: stop here rather than record ink that can't be shown
		WarnFull()
		wm.mode = nil
		EndStroke()
		ArtPad:WorldMapRefreshBar()
		return
	end
	p[n + 1], p[n + 2] = x, y
	DrawSegment(stroke, n - 1, W, H)
	if n == 2 then ArtPad:WorldMapRefreshBar() end
end

-- Drop whatever the mouse was in the middle of (the map changed, undo, the catcher hid).
local function EndGesture()
	wm.press, wm.mode = nil, nil
	EndStroke()
end

-- The topmost stroke of this map within the eraser's radius of (x, y): index, stroke.
local function StrokeAt(x, y)
	local strokes = wm.mapID and Strokes(wm.mapID)
	if not strokes then return nil end
	local W, H = CanvasSize()
	local radius = ERASE_RADIUS * UnitsPerPixel()
	for s = #strokes, 1, -1 do
		local p = strokes[s].p
		local reach = radius + strokes[s].w * W / 2
		for i = 1, #p - 3, 2 do
			if ArtPad.PointSegDist(x * W, y * H, p[i] * W, p[i + 1] * H, p[i + 2] * W, p[i + 3] * H) <= reach then
				return s, strokes[s]
			end
		end
	end
end

-- Remove every stroke under the eraser. One undo step per drag (and per map).
local function EraseAtCursor()
	local x, y = Cursor()
	if not x then return end
	local changed = false
	local index, stroke = StrokeAt(x, y)
	while index do
		if wm.press and wm.press.snapped ~= wm.mapID then
			Snapshot(wm.mapID)
			wm.press.snapped = wm.mapID
		end
		table.remove(Strokes(wm.mapID), index)
		ReleaseStroke(stroke)
		changed = true
		index, stroke = StrokeAt(x, y)
	end
	if changed then
		if wm.press then wm.press.acted = true end
		ArtPad:WorldMapRefreshBar()
	end
end

function ArtPad:WorldMapUndo()
	if not (wm.ready and WorldMapFrame:IsShown()) then return end
	EndGesture() -- a stroke still being drawn is finished first, and is then what gets undone
	local h = wm.mapID and wm.history[wm.mapID]
	if not h or #h == 0 then return end
	local strokes = table.remove(h)
	Drawings()[wm.mapID] = #strokes > 0 and strokes or nil
	self:WorldMapRedraw(true)
	self:WorldMapRefreshBar()
end

-- Clearing is just another undoable step, so it needs no confirmation.
function ArtPad:WorldMapClear()
	EndGesture()
	local strokes = wm.mapID and Strokes(wm.mapID)
	if not strokes or #strokes == 0 then return end
	Snapshot(wm.mapID)
	Drawings()[wm.mapID] = nil
	self:WorldMapRedraw(true)
	self:WorldMapRefreshBar()
end

-- A press that did nothing is a click, and clicks belong to the map. When the press didn't
-- reach the map by itself (see the top of the file), do what
-- MapCanvasScrollControllerMixin:OnMouseUp would have done: left goes into the zone under the
-- cursor, right goes up a level. Not in combat: map changes started by an addon there get
-- Blizzard's pins blocked.
local function PassClick(button)
	if InCombatLockdown() then return end
	local map, container = WorldMapFrame, WorldMapFrame.ScrollContainer
	local ok, err = pcall(function()
		local x, y = container:GetNormalizedCursorPosition()
		if map.ProcessCanvasClickHandlers and map:ProcessCanvasClickHandlers(button, x, y) then return end
		if not (container.ShouldNavigateOnClick and container:ShouldNavigateOnClick()) then return end
		local ignoreZone = container.ShouldNavigateIgnoreZoneMapPositionData
			and container:ShouldNavigateIgnoreZoneMapPositionData() or false
		if button == "LeftButton" then
			if map.NavigateToCursor then map:NavigateToCursor(ignoreZone) end
		elseif button == "RightButton" then
			if map.NavigateToParentMap and not ignoreZone then map:NavigateToParentMap() end
		end
	end)
	if not ok then ArtPad:Debug("world map: passing the click on failed: " .. tostring(err)) end
end

-- Let left presses reach the map too whenever that is safe (see the top of the file).
local function UpdatePropagation()
	local input = wm.input
	if not input.SetPropagateMouseClicks or InCombatLockdown() then return end
	local container = WorldMapFrame.ScrollContainer
	local pannable = container.CanPan and container:CanPan() or false
	local want = Tool() == "pen" and not pannable and not wm.bar.options:IsShown()
	if want ~= wm.propagating and pcall(input.SetPropagateMouseClicks, input, want) then
		wm.propagating = want
	end
end

--[[ The cursor shows the tool ]]

local function HideCursor()
	wm.dot:Hide()
	wm.dotRing:Hide()
	wm.ring:Hide()
	SetHover(nil)
	wm.cursorX = nil
end

-- Is the mouse on ArtPad's own controls rather than the map?
local function OverControls()
	return wm.entry:IsMouseOver() or (wm.bar:IsShown() and wm.bar:IsMouseOver())
		or (wm.bar.options:IsShown() and wm.bar.options:IsMouseOver())
end

local function UpdateCursor()
	local x, y = Cursor()
	if not x or not wm.input:IsMouseOver() or OverControls() then
		HideCursor()
		return
	end
	local tool = Tool()
	-- nothing moved and nothing changed: nothing to do
	if x == wm.cursorX and y == wm.cursorY and tool == wm.cursorTool and not wm.cursorDirty then return end
	wm.cursorX, wm.cursorY, wm.cursorTool, wm.cursorDirty = x, y, tool, false
	local W, H = CanvasSize()
	local k = UnitsPerPixel()
	local function Place(region, size)
		region:SetSize(size, size)
		region:ClearAllPoints()
		region:SetPoint("CENTER", wm.input, "TOPLEFT", x * W, -y * H)
		region:Show()
	end
	if tool == "eraser" then
		wm.dot:Hide()
		wm.dotRing:Hide()
		Place(wm.ring, 2 * ERASE_RADIUS * k)
		if wm.mode ~= "erase" then
			local _, stroke = StrokeAt(x, y)
			SetHover(stroke)
		end
	else
		wm.ring:Hide()
		SetHover(nil)
		-- the blob of ink the pen will leave: same size, same colour, same opacity
		local c = ArtPad.brushColor
		local size = math.max(3, ArtPad_Settings.BrushSize) * k
		wm.dot:SetVertexColor(c.r, c.g, c.b, math.max(0.35, c.a))
		Place(wm.dot, size)
		Place(wm.dotRing, size + 5 * k)
	end
end

--[[ Mode, tools and the toolbar ]]

local function ClickSound(on)
	if not (PlaySound and SOUNDKIT) then return end
	local id
	if on then
		id = SOUNDKIT.UI_MAP_WAYPOINT_BUTTON_CLICK_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
	else
		id = SOUNDKIT.UI_MAP_WAYPOINT_BUTTON_CLICK_OFF or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF
	end
	if id then PlaySound(id) end
end

-- Esc and Ctrl-Z belong to the toolbar while it's out. Bindings can't change in combat, so
-- they are also dropped as combat starts and taken back when it ends (see the events below).
local function Bind(on)
	if InCombatLockdown() then return end
	if on then
		-- the same hidden targets the ArtPad window binds; ArtPad:OnKey sends the key to
		-- whichever of the two the mouse is over
		SetOverrideBindingClick(wm.bar, true, "ESCAPE", "ArtPad_KeyEsc")
		SetOverrideBindingClick(wm.bar, true, "CTRL-Z", "ArtPad_KeyUndo")
	else
		ClearOverrideBindings(wm.bar)
	end
end

-- The mouse catcher is up while the toolbar is out or Alt is held (and the map is open).
function ArtPad:WorldMapUpdateInput()
	if not wm.ready then return end
	local alt = IsAltKeyDown and IsAltKeyDown() or false
	local active = WorldMapFrame:IsShown() and (wm.on or alt) or false
	wm.input:SetShown(active)
	-- Shift + wheel sizes the brush; a plain wheel is left to the map
	wm.input:EnableMouseWheel(active and IsShiftKeyDown() and true or false)
	if not active then HideCursor() end
	if wm.on and not wm.bar:IsShown() then
		self.FadeTo(wm.bar, 1, 0.15)
	elseif not wm.on then
		wm.bar:Hide()
	end
	UpdatePropagation()
	self:WorldMapRefreshBar()
end

-- Turn drawing on or off (the round button, Esc, or the map closing).
function ArtPad:WorldMapSetActive(on, silent)
	on = on and true or false
	if on == wm.on then return end
	EndGesture()
	wm.on = on
	wm.tool = "pen"
	if not silent then ClickSound(on) end
	self:WorldMapToggleOptions(false)
	Bind(on)
	self:WorldMapHint(on and not ArtPad_Settings.MapHintSeen)
	self:WorldMapUpdateInput()
end

-- Esc backs out one step at a time: the colour picker, the options, then the tools.
function ArtPad:WorldMapEsc()
	if not wm.on then return end
	if ColorPickerFrame and ColorPickerFrame:IsShown() and self.pickerOpen then
		ColorPickerFrame:Hide()
	elseif wm.bar.options:IsShown() then
		self:WorldMapToggleOptions(false)
	else
		self:WorldMapSetActive(false)
	end
end

-- Pick a tool. Picking the pen while it's active opens its options (colour and size).
function ArtPad:WorldMapSetTool(tool)
	if tool == "pen" and wm.tool == "pen" then
		self:WorldMapToggleOptions()
		return
	end
	EndGesture()
	wm.tool = tool
	self:WorldMapToggleOptions(false)
	UpdatePropagation()
	self:WorldMapRefreshBar()
end

-- The one-time hint under the map. Hiding it after a first stroke retires it for good.
function ArtPad:WorldMapHint(show)
	if not wm.hint then return end
	if show then
		self.FadeTo(wm.hint, 1, 0.2)
	elseif wm.hint:IsShown() then
		wm.hint:Hide()
		if wm.stroke then ArtPad_Settings.MapHintSeen = true end
	end
end

function ArtPad:WorldMapRefreshBar()
	local bar = wm.bar
	if not bar then return end
	wm.cursorDirty = true
	for tool, b in pairs(bar.tools) do
		if wm.tool == tool then
			self.Fill(b.bg, self.C.accent, 0.16)
			b.mark:Show()
		else
			b.bg:SetColorTexture(0, 0, 0, 0)
			b.mark:Hide()
		end
	end
	-- the pen wears the current colour, on a pale backing when the colour is too dark to see
	local c = self.brushColor
	local pen = bar.tools.pen
	for _, line in ipairs(pen.glyph) do line:SetColorTexture(c.r, c.g, c.b, 1) end
	local dark = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b < 0.3
	for _, line in ipairs(pen.backing) do line:SetShown(dark) end
	local strokes = wm.mapID and Strokes(wm.mapID)
	local any = strokes and #strokes > 0 or false
	local h = wm.mapID and wm.history[wm.mapID]
	bar.undo:SetAlpha(h and #h > 0 and 1 or 0.35)
	bar.clear:SetAlpha(any and 1 or 0.35)
	wm.entry.active:SetShown(wm.on)
	wm.entry.badge:SetShown(any and not wm.on)
	if bar.options:IsShown() then self:WorldMapRefreshOptions() end
end

-- Pen options: sizes, swatch colours with a ring on the current one, recents if there are any.
function ArtPad:WorldMapRefreshOptions()
	local pop = wm.bar.options
	local c = self.brushColor
	for _, b in ipairs(pop.sizes) do
		if ArtPad_Settings.BrushSize == b.size then
			self.Fill(b.bg, self.C.accent, 0.3)
		else
			self.Fill(b.bg, { 0.137, 0.157, 0.188 })
		end
		b.dot:SetVertexColor(c.r, c.g, c.b, 1)
	end
	local anyRecent = false
	for _, b in ipairs(pop.swatches) do
		local r, g, bl = b.getColor()
		if r then
			b.color:SetColorTexture(r, g, bl, 1)
			b:Show()
			b.ring:SetShown(math.abs(c.r - r) < 0.01 and math.abs(c.g - g) < 0.01 and math.abs(c.b - bl) < 0.01)
			if b.recent then anyRecent = true end
		elseif b.recent then
			b:Hide()
		end
	end
	pop:SetHeight(anyRecent and pop.tall or pop.short)
end

function ArtPad:WorldMapToggleOptions(show)
	local pop = wm.bar and wm.bar.options
	if not pop then return end
	if show == nil then show = not pop:IsShown() end
	if show then
		self:WorldMapRefreshOptions()
		GameTooltip:Hide() -- the pen's tooltip sits where the options open
	end
	pop:SetShown(show and true or false)
	UpdatePropagation()
end

-- Brush size from the options or Shift + wheel. The wheel stops at MAX_SIZE but never
-- shrinks a brush that the main window made bigger than that.
function ArtPad:WorldMapSetSize(size, fromWheel)
	local now = ArtPad_Settings.BrushSize
	if fromWheel and size > now and now >= MAX_SIZE then return end
	if fromWheel then size = math.min(math.max(MAX_SIZE, now), size) end
	self:SetBrushSize(math.max(1, size))
	self:WorldMapRefreshBar()
end

--[[ Building the pieces ]]

-- The frame level just above the map's area-covering layers (see the top of the file).
local function DrawingLevel(map)
	local manager = map.GetPinFrameLevelsManager and map:GetPinFrameLevelsManager()
	local ok, level = pcall(function() return manager:GetValidFrameLevel("PIN_FRAME_LEVEL_MAP_HIGHLIGHT") end)
	if ok and type(level) == "number" and level > 0 then return level + 1 end
	return FALLBACK_LEVEL
end

-- Tooltips worded and coloured like the map's own (see WorldMapTrackingPinButtonMixin:OnEnter):
-- a white title, one plain sentence in the normal gold, then what to do in green. `hide` is
-- an optional function; no tooltip while it returns true.
local function MapTooltip(frame, title, text, instructions, hide)
	frame:SetScript("OnEnter", function(f)
		if hide and hide() then return end
		GameTooltip:SetOwner(f, "ANCHOR_BOTTOM")
		GameTooltip:SetText(title, 1, 1, 1)
		if text then GameTooltip:AddLine(text, 1, 0.82, 0, true) end
		if instructions then
			GameTooltip:AddLine(" ")
			for _, line in ipairs(instructions) do GameTooltip:AddLine(line, 0.1, 1, 0.1, true) end
		end
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", GameTooltip_Hide)
end

-- A dark panel with a thin warm edge, so it sits on the parchment like part of the map frame.
local function Panel(frame, alpha)
	ArtPad.Background(frame, ArtPad.C.bar, alpha)
	frame.smartNavigationIgnored = true -- as Blizzard marks its own map layer for gamepad navigation
	for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local edge = frame:CreateTexture(nil, "BORDER")
		edge:SetColorTexture(0.49, 0.42, 0.25, 1)
		if side == "TOP" or side == "BOTTOM" then
			edge:SetHeight(1)
			edge:SetPoint(side .. "LEFT")
			edge:SetPoint(side .. "RIGHT")
		else
			edge:SetWidth(1)
			edge:SetPoint("TOP" .. side)
			edge:SetPoint("BOTTOM" .. side)
		end
	end
end

-- The way in: a round button like Blizzard's own Map Pin button (same art, same size).
local function BuildEntry(self, map)
	local b = CreateFrame("Button", "ArtPad_MapDrawButton", map)
	b:SetFrameStrata("HIGH")
	b:SetFrameLevel(500)
	b:SetSize(32, 32)
	b.smartNavigationIgnored = true
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(25, 25)
	bg:SetPoint("TOPLEFT", 3, -4)
	self.DrawGlyph(b, PENCIL, 20, { 1, 0.86, 0.45 })
	-- pressed: the icon darkens, as the Map Pin button's does
	local pressed = b:CreateTexture(nil, "OVERLAY")
	pressed:SetTexture(self.MEDIA .. "dot")
	pressed:SetVertexColor(0, 0, 0, 0.35)
	pressed:SetSize(22, 22)
	pressed:SetPoint("CENTER", bg, "CENTER")
	pressed:Hide()
	b:SetScript("OnMouseDown", function() pressed:Show() end)
	b:SetScript("OnMouseUp", function() pressed:Hide() end)
	local border = b:CreateTexture(nil, "OVERLAY", nil, 1)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(54, 54)
	border:SetPoint("TOPLEFT")
	b.active = b:CreateTexture(nil, "OVERLAY", nil, 2)
	b.active:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Toggle")
	b.active:SetBlendMode("ADD")
	b.active:SetSize(37, 37)
	b.active:SetPoint("TOPLEFT", border, "TOPLEFT", -2, 1)
	b.active:Hide()
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
	-- a dot when the map on show has a drawing
	b.badge = b:CreateTexture(nil, "OVERLAY", nil, 3)
	b.badge:SetTexture(self.MEDIA .. "dot")
	b.badge:SetVertexColor(1, 0.82, 0.2, 1)
	b.badge:SetSize(8, 8)
	b.badge:SetPoint("CENTER", b, "TOPRIGHT", -6, -6)
	b.badge:Hide()
	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnClick", function() self:WorldMapSetActive(not wm.on) end)
	-- worded after Blizzard's Map Pin button, which sits in the same stack
	MapTooltip(b, "Map Drawing", "Draw on the map. Your drawings are only visible to you.",
		{ "Click this button and then drag on the map to draw or <Alt drag directly on the map>" })
	return b
end

-- Blizzard stacks its own round buttons down the map's top-right corner (32 apart); sit below
-- whichever of them are there on this client.
local function PlaceEntry(map)
	local taken = 0
	for _, key in ipairs({ "WorldMapTrackingOptionsButton", "WorldMapTrackingPinButton" }) do
		local theirs = map[key]
		if type(theirs) == "table" and theirs.IsShown and theirs:IsShown() and theirs:GetPoint(1) == "TOPRIGHT" then
			taken = taken + 1
		end
	end
	wm.entry:ClearAllPoints()
	wm.entry:SetPoint("TOPRIGHT", map.ScrollContainer, "TOPRIGHT", -4, -2 - 32 * taken)
end

local BAR_H, BTN, PAD, GAP = 32, 28, 4, 2

-- Icon-only toolbar button; the active tool gets a soft tint and a gold underline.
local function MiniButton(self, bar, name, onClick)
	local b = CreateFrame("Button", name, bar)
	b:SetSize(BTN, BTN)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(0, 0, 0, 0)
	b.mark = b:CreateTexture(nil, "BORDER")
	b.mark:SetPoint("BOTTOMLEFT", 6, 0)
	b.mark:SetPoint("BOTTOMRIGHT", -6, 0)
	b.mark:SetHeight(2)
	self.Fill(b.mark, self.C.accent)
	b.mark:Hide()
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnClick", onClick)
	return b
end

-- The pen's options, under the toolbar: sizes, the main panel's swatches, "+" for the full
-- colour picker, then a row of recent colours.
local function BuildOptions(self, bar)
	local CELL, CGAP, CPAD, COLS = 24, 6, 10, 6
	local pop = CreateFrame("Frame", "ArtPad_MapOptions", bar)
	pop:SetFrameLevel(bar:GetFrameLevel() + 20)
	local swatchTop = CPAD + CELL + 10
	pop.short = swatchTop + CELL * 2 + CGAP + CPAD
	pop.tall = pop.short + CELL + CGAP
	pop:SetSize(CPAD * 2 + CELL * COLS + CGAP * (COLS - 1), pop.short)
	pop:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -6)
	pop:EnableMouse(true)
	Panel(pop, 0.96)

	local label = pop:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	label:SetPoint("LEFT", pop, "TOPLEFT", CPAD, -CPAD - CELL / 2)
	label:SetText("Size")
	pop.sizes = {}
	for i, size in ipairs(SIZES) do
		local b = self:FlatButton(pop, "ArtPad_MapSize" .. i, 40, CELL, nil, function() self:WorldMapSetSize(size) end)
		b:SetPoint("TOPRIGHT", -CPAD - (#SIZES - i) * (40 + CGAP), -CPAD)
		b.size = size
		b.dot = b:CreateTexture(nil, "ARTWORK")
		b.dot:SetTexture(self.MEDIA .. "dot")
		b.dot:SetSize(size + 3, size + 3)
		b.dot:SetPoint("CENTER")
		pop.sizes[i] = b
	end

	pop.swatches = {}
	local function Place(b, index)
		local col, row = (index - 1) % COLS, math.floor((index - 1) / COLS)
		b:SetSize(CELL, CELL)
		b:SetPoint("TOPLEFT", CPAD + col * (CELL + CGAP), -swatchTop - row * (CELL + CGAP))
	end
	local function Swatch(name, index, getColor, tip)
		local b = CreateFrame("Button", name, pop)
		Place(b, index)
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
		if tip then MapTooltip(b, tip) end
		table.insert(pop.swatches, b)
		return b
	end
	for i, c in ipairs(self.SWATCHES) do
		Swatch("ArtPad_MapSwatch" .. i, i, function() return c[1], c[2], c[3] end)
	end
	local custom = self:FlatButton(pop, "ArtPad_MapSwatchCustom", CELL, CELL, "+", function()
		self:WorldMapToggleOptions(false)
		self:OpenColorPicker()
	end)
	Place(custom, 11)
	MapTooltip(custom, "Colour Picker")
	for i = 1, 4 do
		local b = Swatch("ArtPad_MapSwatchRecent" .. i, 12 + i, function()
			local c = ArtPad_Settings.RecentColors[i]
			if c then return c[1], c[2], c[3] end
		end, "Recently Used")
		b.recent = i
	end
	pop:Hide()
	return pop
end

-- The toolbar: one slim strip that unfolds from the round button.
--   pen  eraser  |  undo  clear
local function BuildBar(self, map)
	local GLYPH_COLOUR = { 0.85, 0.87, 0.9 }
	local bar = CreateFrame("Frame", "ArtPad_MapBar", map)
	bar:SetFrameStrata("HIGH") -- like Blizzard's own buttons on the map
	bar:SetFrameLevel(500)
	bar:SetPoint("RIGHT", wm.entry, "LEFT", -4, 0)
	Panel(bar, 0.94)
	bar:EnableMouse(true) -- clicks between the buttons don't fall through to the map

	bar.tools = {}
	local x = PAD
	local function Add(name, glyph, onClick)
		local b = MiniButton(self, bar, name, onClick)
		b:SetPoint("LEFT", x, 0)
		b.glyph = self.DrawGlyph(b, glyph, 20, GLYPH_COLOUR)
		x = x + BTN + GAP
		return b
	end

	local pen = MiniButton(self, bar, "ArtPad_MapTool_pen", function() self:WorldMapSetTool("pen") end)
	pen:SetPoint("LEFT", x, 0)
	-- a pale, wider copy of the squiggle behind it, shown when the ink colour is too dark to see
	pen.backing = self.DrawGlyph(pen, self.GLYPHS.pen, 20, { 0.85, 0.87, 0.9, 0.55 })
	for _, line in ipairs(pen.backing) do
		line:SetThickness(4.5)
		line:SetDrawLayer("BORDER")
		line:Hide()
	end
	pen.glyph = self.DrawGlyph(pen, self.GLYPHS.pen, 20, GLYPH_COLOUR)
	x = x + BTN + GAP
	bar.tools.pen = pen
	-- no tooltip over the open options: it would cover them
	MapTooltip(pen, "Pen", "Click and drag on the map to draw.",
		{ "<Click again to change colour and size>", "<Shift Mouse Wheel to change size>" },
		function() return bar.options:IsShown() end)
	bar.tools.eraser = Add("ArtPad_MapTool_eraser", self.GLYPHS.eraser, function() self:WorldMapSetTool("eraser") end)
	MapTooltip(bar.tools.eraser, "Eraser", "Click and drag over a line to erase it.")

	-- hairline between the tools and undo/clear
	local d = bar:CreateTexture(nil, "ARTWORK")
	d:SetColorTexture(1, 1, 1, 0.12)
	d:SetSize(1, BAR_H - 14)
	d:SetPoint("LEFT", x + 2, 0)
	x = x + 5 + GAP

	bar.undo = Add("ArtPad_MapUndo", self.GLYPHS.undo, function() self:WorldMapUndo() end)
	MapTooltip(bar.undo, "Undo |cffffd200(Ctrl-Z)|r", "Undo your last change to this map.")
	bar.clear = Add("ArtPad_MapClear", TRASH, function() self:WorldMapClear() end)
	MapTooltip(bar.clear, "Clear All", "Erase everything drawn on this map. This can be undone.")

	bar:SetSize(x - GAP + PAD, BAR_H)
	bar.options = BuildOptions(self, bar)
	bar:Hide()
	return bar
end

local function BuildHint(map)
	local hint = CreateFrame("Frame", "ArtPad_MapHint", map)
	hint:SetFrameStrata("HIGH")
	hint:SetFrameLevel(500)
	hint:SetPoint("BOTTOM", map.ScrollContainer, "BOTTOM", 0, 16)
	Panel(hint, 0.92)
	local text = hint:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	text:SetPoint("CENTER")
	text:SetText("Click and drag on the map to draw.")
	hint:SetSize((text:GetStringWidth() or 220) + 28, 26)
	hint:Hide()
	return hint
end

function ArtPad:SetupWorldMapDraw()
	if wm.ready then return end
	local map = WorldMapFrame
	local container = map and map.ScrollContainer
	if not (container and container.Child and container.GetNormalizedCursorPosition and map.GetMapID) then
		-- The map UI isn't loaded yet (or isn't the kind we know): try again when addons load.
		if not wm.waiter then
			wm.waiter = CreateFrame("Frame")
			wm.waiter:RegisterEvent("ADDON_LOADED")
			wm.waiter:SetScript("OnEvent", function() if WorldMapFrame then self:SetupWorldMapDraw() end end)
		end
		return
	end
	if wm.waiter then wm.waiter:UnregisterEvent("ADDON_LOADED") end
	local canvas = container.Child
	wm.canvas = canvas

	local layer = CreateFrame("Frame", "ArtPad_MapLayer", canvas)
	layer:SetAllPoints(canvas)
	layer:SetFrameLevel(DrawingLevel(map))
	layer:SetScript("OnSizeChanged", function() self:WorldMapRedraw() end)
	wm.layer = layer

	local input = CreateFrame("Frame", "ArtPad_MapInput", canvas)
	input:SetAllPoints(canvas)
	input:SetFrameLevel(9000) -- the highest level the map gives any pin
	input:EnableMouse(true)
	-- Clicks only: mouse motion stays with the map (zone highlight, coordinates, pin tooltips).
	if input.SetMouseMotionEnabled then input:SetMouseMotionEnabled(false) end
	-- Right-clicks go straight through to the map where the client allows it; where it
	-- doesn't, they arrive here and are passed on by hand (PassClick). Protected in combat.
	if input.SetPassThroughButtons and not InCombatLockdown() then
		pcall(input.SetPassThroughButtons, input, "RightButton")
	end
	input:Hide()
	input:SetScript("OnMouseDown", function(_, button)
		if button ~= "LeftButton" and button ~= "RightButton" then return end
		local sx, sy = GetCursorPosition()
		wm.press = { button = button, x = sx, y = sy }
		if wm.bar.options:IsShown() then
			-- this click only closes the options; it is not the map's
			wm.press.acted = true
			self:WorldMapToggleOptions(false)
		end
		if button ~= "LeftButton" then return end
		if Tool() == "eraser" then
			wm.mode = "erase"
			EraseAtCursor()
		else
			wm.mode = "draw"
			BeginStroke()
		end
	end)
	input:SetScript("OnMouseUp", function(_, button)
		local press = wm.press
		local moved = PressMoved()
		EndGesture()
		-- A press that did nothing is a click. If it didn't reach the map by itself, pass it on.
		if press and press.button == button and not press.acted and not moved
				and not (wm.propagating and button == "LeftButton") then
			PassClick(button)
		end
	end)
	input:SetScript("OnUpdate", function()
		if not wm.on and not (IsAltKeyDown and IsAltKeyDown()) then
			-- Alt was let go without us hearing about it (alt-tab): stand down
			self:WorldMapUpdateInput()
			return
		end
		if wm.mode == "draw" then
			ExtendStroke()
		elseif wm.mode == "erase" then
			EraseAtCursor()
		end
		UpdateCursor()
	end)
	input:SetScript("OnMouseWheel", function(_, delta)
		self:WorldMapSetSize(ArtPad_Settings.BrushSize + (delta > 0 and 1 or -1), true)
	end)
	input:SetScript("OnHide", EndGesture)
	wm.input = input

	-- cursor visuals: a dot of ink for the pen, a ring for the eraser
	wm.dotRing = input:CreateTexture(nil, "OVERLAY", nil, 1)
	wm.dotRing:SetTexture(self.MEDIA .. "ring")
	wm.dotRing:SetVertexColor(1, 1, 1, 0.9)
	wm.dotRing:Hide()
	wm.dot = input:CreateTexture(nil, "OVERLAY", nil, 2)
	wm.dot:SetTexture(self.MEDIA .. "dot")
	wm.dot:Hide()
	wm.ring = input:CreateTexture(nil, "OVERLAY", nil, 2)
	wm.ring:SetTexture(self.MEDIA .. "ring")
	wm.ring:SetVertexColor(1, 1, 1, 0.85)
	wm.ring:Hide()

	wm.entry = BuildEntry(self, map)
	PlaceEntry(map)
	wm.bar = BuildBar(self, map)
	wm.hint = BuildHint(map)

	wm.ready = true

	-- Secure hooks only: nothing of Blizzard's is replaced.
	hooksecurefunc(map, "OnMapChanged", function()
		EndGesture() -- a drag doesn't carry over to another map
		self:WorldMapRedraw()
		self:WorldMapRefreshBar()
	end)
	if map.OnCanvasScaleChanged then
		hooksecurefunc(map, "OnCanvasScaleChanged", function()
			wm.cursorDirty = true
			UpdatePropagation() -- zoomed in, a drag pans the map
		end)
	end
	map:HookScript("OnShow", function()
		PlaceEntry(map)
		self:WorldMapRedraw()
		self:WorldMapUpdateInput()
	end)
	-- like the Map Pin button: closing the map puts the tools away
	map:HookScript("OnHide", function()
		self:WorldMapSetActive(false, true)
		wm.input:Hide()
	end)

	local events = CreateFrame("Frame")
	events:RegisterEvent("MODIFIER_STATE_CHANGED")
	events:RegisterEvent("PLAYER_REGEN_DISABLED")
	events:RegisterEvent("PLAYER_REGEN_ENABLED")
	events:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_REGEN_DISABLED" then
			-- Combat is about to lock bindings: give Esc and Ctrl-Z back now, so they can
			-- never be stuck on a toolbar that gets put away mid-fight.
			ClearOverrideBindings(wm.bar)
		elseif event == "PLAYER_REGEN_ENABLED" then
			Bind(wm.on)
			UpdatePropagation()
		elseif map:IsShown() then
			self:WorldMapUpdateInput()
		end
	end)

	self:WorldMapRedraw(true)
	self:WorldMapRefreshBar()
end
