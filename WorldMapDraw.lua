--[[
	Drawing on the world map itself, shared with whoever the canvas is shared with (see
	"Sharing" below).

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
	in ArtPad_Settings.MapDrawings[mapID]: a list of strokes { id, r, g, b, a, w, p = points }
	plus when it last changed (.t) and what is waiting to be sent (see "Sharing").

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
local PublishAdd, PublishRemove -- see "Sharing"

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
	history = {}, -- mapID -> stack of things done here: { add = strokes } or { remove = { {stroke, index} } }
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

local function IndexOf(list, id)
	for i, s in ipairs(list) do
		if s.id == id then return i end
	end
end

-- Every stroke has an id that is unique among everyone's strokes.
local function NewId()
	if not wm.tag then wm.tag = ArtPad:NewSyncNonce() end
	wm.seq = (wm.seq or 0) + 1
	return wm.tag .. "." .. wm.seq
end

-- Remember something done to this map here, so it can be undone.
local function Record(mapID, op)
	local h = wm.history[mapID]
	if not h then
		h = {}
		wm.history[mapID] = h
	end
	table.insert(h, op)
	if #h > HISTORY then table.remove(h, 1) end
	return op
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
		id = NewId(), u = true, -- not sent until the pen lifts
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
	PublishAdd(mapID, { stroke })
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
		table.insert(Strokes(wm.strokeMap, true), stroke)
		Record(wm.strokeMap, { add = { stroke } })
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
	local press = wm.press
	wm.press, wm.mode = nil, nil
	EndStroke()
	-- one message for everything a drag of the eraser took off
	if press and press.erased then PublishRemove(press.erasedMap, press.erased) end
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
		local press = wm.press
		local op = press and press.op
		if not op or press.erasedMap ~= wm.mapID then
			op = Record(wm.mapID, { remove = {} }) -- one undo step per drag
			if press then press.op, press.erased, press.erasedMap = op, {}, wm.mapID end
		end
		table.remove(Strokes(wm.mapID), index)
		ReleaseStroke(stroke)
		table.insert(op.remove, { stroke = stroke, index = index })
		if press then
			table.insert(press.erased, stroke)
		else
			PublishRemove(wm.mapID, { stroke })
		end
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
	local op = table.remove(h)
	local list = Strokes(wm.mapID, true)
	if op.add then
		-- take back what was drawn (unless someone has erased it since)
		local taken = {}
		for _, stroke in ipairs(op.add) do
			local i = IndexOf(list, stroke.id)
			if i then taken[#taken + 1] = table.remove(list, i) end
		end
		PublishRemove(wm.mapID, taken)
	else
		-- put back what was erased, where it was
		local back = {}
		for i = #op.remove, 1, -1 do
			local r = op.remove[i]
			if not IndexOf(list, r.stroke.id) then
				table.insert(list, math.min(r.index, #list + 1), r.stroke)
				back[#back + 1] = r.stroke
			end
		end
		PublishAdd(wm.mapID, back)
	end
	self:WorldMapRedraw(true)
	self:WorldMapRefreshBar()
end

-- Clearing is just another undoable step, so it needs no confirmation.
function ArtPad:WorldMapClear()
	EndGesture()
	local list = wm.mapID and Strokes(wm.mapID)
	if not list or #list == 0 then return end
	local op, all = Record(wm.mapID, { remove = {} }), {}
	for i, stroke in ipairs(list) do
		op.remove[i] = { stroke = stroke, index = i }
		all[i] = stroke
	end
	for i = #list, 1, -1 do list[i] = nil end -- the (empty) list stays: it holds when the map last changed
	PublishRemove(wm.mapID, all)
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


--[[ Sharing

	A map's drawing is shared with whoever the canvas is shared with (guild, or party/raid).
	There is one drawing per map; nothing about it is private.

	Live:  each change is broadcast as it happens, on a prefix of its own:
	         A:<map>:<t>:<strokes>    strokes added (one when the pen lifts; several on undo)
	         D:<map>:<t>:<id>,<id>..  strokes removed (eraser, clear, undo)
	       <t> is the map's new "last changed" time, the same for everyone who hears it.
	Later: with nobody to tell (no guild or group, Local mode, sharing off), changes wait:
	       added strokes are marked (stroke.u) and removed ids kept (list.gone), and both go
	       out the next time that map is looked at with someone to tell. Drawings made before
	       map drawings were shared are published the same way.
	Catching up: looking at a map asks who has a newer copy of it.
	         Q:<map>:<t>:<n>          broadcast: my copy's time and stroke count
	         H:<map>:<t>:<n>          whisper back from anyone whose copy is newer (or fuller)
	         G:<map>                  whisper to the best of those: send it
	         <map>:<t>:<strokes>      the copy, on the copy prefix
	       A copy replaces what was known of the map, except for what is still waiting to be
	       sent and whatever arrived live in the meantime.
]]

local MAP_PREFIX, COPY_PREFIX = "ArtPadMap1", "ArtPadMapC1"
local ASK_EVERY = 60 -- seconds before the same map is asked about again
local ASK_DWELL = 0.6 -- seconds a map must stay on show before it is asked about
local ASK_COLLECT = 1.5 -- seconds to wait for offers
local COPY_WAIT = 45 -- seconds to wait for a copy that was offered
local MAX_STROKES, MAX_POINTS, MAX_MAPS = 1500, 1500, 400 -- what is accepted from others
local BATCH = 40 -- strokes per message when a backlog is published
wm.asked = {} -- "<channel>:<map>" -> when we last asked

-- The channel map drawings go out on, or nil when there is nobody to share with.
local function Audience()
	if ArtPad_Settings.MapShare == false or ArtPad.loopback then return nil end
	local channel = ArtPad:GetChannel()
	if not channel or channel == "YELL" then return nil end
	return channel
end

local AUDIENCE_NAMES = { GUILD = "your guild", PARTY = "your party", RAID = "your raid", INSTANCE_CHAT = "your group" }

-- For the round button's tooltip.
local function SharingText()
	local channel = Audience()
	if channel then
		return "Draw on the map. Drawings are shared with " .. (AUDIENCE_NAMES[channel] or "your group") .. "."
	end
	return "Draw on the map. Drawings are shared when you are in a guild or group."
end

-- The map's next "last changed" time: now, and later than any time it has had.
local function Stamp(list)
	local t = math.max(GetServerTime(), (list.t or 0) + 1)
	list.t = t
	return t
end

-- Strokes everyone knows about (not still waiting to be sent).
local function PublicCount(list)
	local n = 0
	for _, s in ipairs(list) do
		if not s.u then n = n + 1 end
	end
	return n
end

-- Strokes as they travel: whole numbers only (they serialise much shorter).
local function Pack(strokes)
	local out = {}
	for _, s in ipairs(strokes) do
		local p = {}
		for i, v in ipairs(s.p) do p[i] = math.floor(v * 10000 + 0.5) end
		out[#out + 1] = {
			s.id, math.floor(s.r * 255 + 0.5), math.floor(s.g * 255 + 0.5), math.floor(s.b * 255 + 0.5),
			math.floor(s.a * 255 + 0.5), math.floor(s.w * 100000 + 0.5), p,
		}
	end
	return ArtPad:EncodeData(out)
end

local function Channel(v)
	v = tonumber(v) or 255
	if v ~= v then v = 255 end
	return math.max(0, math.min(255, v)) / 255
end

-- One stroke from someone else: checked, or nil.
local function Sanitize(rec)
	local id, p = rec[1], rec[7]
	if type(id) ~= "string" or #id > 24 or not id:match("^%w+%.%d+$") or type(p) ~= "table" then return nil end
	local n = #p
	if n < 4 or n % 2 ~= 0 or n > MAX_POINTS * 2 then return nil end
	local pts = {}
	for i = 1, n do
		local v = p[i]
		if type(v) ~= "number" or v ~= v or v < 0 or v > 10000 then return nil end
		pts[i] = math.floor(v + 0.5) / 10000
	end
	local w = tonumber(rec[6]) or 0
	if w ~= w then w = 0 end
	return {
		id = id, r = Channel(rec[2]), g = Channel(rec[3]), b = Channel(rec[4]), a = Channel(rec[5]),
		w = math.max(0.0002, math.min(0.06, w / 100000)), p = pts,
	}
end

local function Unpack(data)
	local list = ArtPad:DecodeData(data)
	if type(list) ~= "table" then return nil end
	local out = {}
	for _, rec in ipairs(list) do
		local s = type(rec) == "table" and Sanitize(rec)
		if s then out[#out + 1] = s end
		if #out >= MAX_STROKES then break end
	end
	return out
end

local function Send(msg, target)
	local channel = Audience()
	if not channel then return false end
	if target then
		ArtPad:SendCommMessage(MAP_PREFIX, msg, "WHISPER", target, "NORMAL")
	else
		ArtPad:SendCommMessage(MAP_PREFIX, msg, channel, nil, "NORMAL")
	end
	return true
end

-- Strokes were added to a map here: tell everyone, or mark them to be told later.
function PublishAdd(mapID, strokes)
	local list = Strokes(mapID)
	if not list or #strokes == 0 then return end
	if Audience() then
		for _, s in ipairs(strokes) do s.u = nil end
		for first = 1, #strokes, BATCH do
			local batch = {}
			for i = first, math.min(#strokes, first + BATCH - 1) do batch[#batch + 1] = strokes[i] end
			Send(("A:%d:%d:%s"):format(mapID, Stamp(list), Pack(batch)))
		end
	else
		for _, s in ipairs(strokes) do
			if list.gone and list.gone[s.id] then
				list.gone[s.id] = nil -- removed and put back while nobody was listening: no news
			else
				s.u = true
			end
		end
	end
end

-- Strokes were removed from a map here: tell everyone, or remember to.
function PublishRemove(mapID, strokes)
	local ids = {}
	for _, s in ipairs(strokes) do
		if s.id and not s.u then ids[#ids + 1] = s.id end -- nobody else has the unsent ones
	end
	if #ids == 0 then return end
	local list = Strokes(mapID, true)
	if Audience() then
		Send(("D:%d:%d:%s"):format(mapID, Stamp(list), table.concat(ids, ",")))
	else
		list.gone = list.gone or {}
		for _, id in ipairs(ids) do list.gone[id] = true end
	end
end

-- Send what has been waiting for someone to tell.
local function PublishBacklog(mapID)
	local list = Strokes(mapID)
	if not list or not Audience() then return end
	if list.gone then
		local ids = {}
		for id in pairs(list.gone) do ids[#ids + 1] = id end
		table.sort(ids)
		list.gone = nil
		if #ids > 0 then Send(("D:%d:%d:%s"):format(mapID, Stamp(list), table.concat(ids, ","))) end
	end
	local waiting = {}
	for _, s in ipairs(list) do
		if s.u and s ~= wm.stroke then waiting[#waiting + 1] = s end
	end
	PublishAdd(mapID, waiting)
end

-- A map changed from outside (someone's stroke, a copy): show it.
local function ShowRemote(mapID, added, removed)
	if not wm.ready or mapID ~= wm.mapID then return end
	if removed then ReleaseStroke(removed) end
	if added then
		local W, H = CanvasSize()
		if WorldMapFrame:IsShown() and W > 0 and H > 0 then
			DrawStroke(added, W, H)
		else
			wm.drawnW = nil -- drawn when the map is next opened
		end
	end
end

local function MapCount()
	local n = 0
	for _ in pairs(Drawings()) do n = n + 1 end
	return n
end

local function Settle(catch)
	if wm.catch ~= catch then return end
	wm.catch = nil
	PublishBacklog(catch.mapID)
	ArtPad:WorldMapAsk() -- the map on show now, if that is another one
end

-- Take a copy of a map from someone who has a newer one.
local function ApplyCopy(catch, t, strokes)
	local mapID = catch.mapID
	local old = Strokes(mapID, true)
	local new, seen = {}, {}
	for _, s in ipairs(strokes) do
		if not seen[s.id] and not (old.gone and old.gone[s.id]) and not catch.removed[s.id] then
			seen[s.id] = true
			new[#new + 1] = s
		end
	end
	-- kept from what we had: strokes nobody has been told about yet, the one under the pen,
	-- and whatever arrived live while the copy was on its way
	for _, s in ipairs(old) do
		if s.id and not seen[s.id] and (s.u or s == wm.stroke or catch.added[s.id]) then
			seen[s.id] = true
			new[#new + 1] = s
		end
	end
	new.t = math.max(old.t or 0, t)
	new.gone = old.gone
	Drawings()[mapID] = new
	if mapID == wm.mapID then
		ArtPad:WorldMapRedraw(true)
		ArtPad:WorldMapRefreshBar()
	end
end

-- Ask who has a newer copy of the map on show (at most once a minute per map and audience).
function ArtPad:WorldMapAsk()
	if not wm.ready or not WorldMapFrame:IsShown() or wm.catch then return end
	local channel, mapID = Audience(), WorldMapFrame:GetMapID()
	if not channel or not mapID then return end
	local key = channel .. ":" .. mapID
	local now = GetTime()
	if wm.asked[key] and now - wm.asked[key] < ASK_EVERY then return end
	wm.asked[key] = now
	local list = Strokes(mapID)
	local catch = { mapID = mapID, key = key, phase = "collect", offers = {}, added = {}, removed = {} }
	wm.catch = catch
	Send(("Q:%d:%d:%d"):format(mapID, list and list.t or 0, list and PublicCount(list) or 0))
	C_Timer.After(ASK_COLLECT, function()
		if wm.catch ~= catch then return end
		local best
		for _, offer in ipairs(catch.offers) do
			if not best or offer.t > best.t or (offer.t == best.t and offer.n > best.n) then best = offer end
		end
		if not best then
			Settle(catch) -- nobody has anything newer
			return
		end
		catch.phase, catch.source = "fetch", ArtPad.ShortName(best.sender)
		Send(("G:%d"):format(mapID), best.sender)
		C_Timer.After(COPY_WAIT, function()
			if wm.catch == catch then
				wm.asked[key] = nil -- it never came: ask again next time
				Settle(catch)
			end
		end)
	end)
end

-- The map on show changed: ask about it once it has stayed up for a moment.
local function QueueAsk()
	local mapID = WorldMapFrame:GetMapID()
	C_Timer.After(ASK_DWELL, function()
		if WorldMapFrame:IsShown() and WorldMapFrame:GetMapID() == mapID then ArtPad:WorldMapAsk() end
	end)
end

function ArtPad:OnMapMessage(_, msg, disType, sender)
	if #msg > 300000 or not Audience() or self:IsSelf(sender) then return end
	local kind, mapID, rest = msg:match("^(%a):(%d+):?(.*)$")
	mapID = tonumber(mapID)
	if not kind or not mapID or mapID < 1 or mapID > 9999999 then return end
	local whispered = disType == "WHISPER"
	if kind == "H" or kind == "G" then
		if not whispered then return end
	elseif not self:AcceptsDistribution(disType) then
		return
	end
	local list = Strokes(mapID)
	local catch = wm.catch and wm.catch.mapID == mapID and wm.catch or nil

	if kind == "A" or kind == "D" then
		if not self:ValidateSender(sender) then return end
		local t, body = rest:match("^(%d+):(.*)$")
		t = tonumber(t)
		-- a time from the future would make this copy the newest for ever
		if not t or t > GetServerTime() + 300 then return end
		if kind == "A" then
			local strokes = Unpack(body)
			if not strokes or #strokes == 0 then return end
			if not list then
				if MapCount() >= MAX_MAPS then return end
				list = Strokes(mapID, true)
			end
			for _, s in ipairs(strokes) do
				if #list < MAX_STROKES and not IndexOf(list, s.id) and not (list.gone and list.gone[s.id]) then
					table.insert(list, s)
					if catch then catch.added[s.id] = true end
					ShowRemote(mapID, s)
				end
			end
		else
			if not list then return end
			for id in body:gmatch("[^,]+") do
				local i = IndexOf(list, id)
				if i then ShowRemote(mapID, nil, table.remove(list, i)) end
				if catch then catch.removed[id] = true end
			end
		end
		list.t = math.max(list.t or 0, t)
		if mapID == wm.mapID then self:WorldMapRefreshBar() end

	elseif kind == "Q" then
		local t, n = rest:match("^(%d+):(%d+)$")
		t, n = tonumber(t), tonumber(n)
		if not t then return end
		local mine, count = list and list.t or 0, list and PublicCount(list) or 0
		if mine > t or (mine == t and count > n) then
			Send(("H:%d:%d:%d"):format(mapID, mine, count), sender)
		elseif t > mine or n > count then
			-- they have the newer one: ask for it ourselves (now, if we are looking at it)
			for key in pairs(wm.asked) do
				if key:match(":(%d+)$") == tostring(mapID) then wm.asked[key] = nil end
			end
			if wm.ready and WorldMapFrame:IsShown() and WorldMapFrame:GetMapID() == mapID then QueueAsk() end
		end

	elseif kind == "H" then
		local t, n = rest:match("^(%d+):(%d+)$")
		t, n = tonumber(t), tonumber(n)
		if t and catch and catch.phase == "collect" and t <= GetServerTime() + 300 and self:ValidateSender(sender) then
			table.insert(catch.offers, { sender = sender, t = t, n = n })
		end

	elseif kind == "G" then
		if not list then return end
		-- one copy per person and map every few seconds is plenty
		wm.served = wm.served or {}
		local key, now = sender .. ":" .. mapID, GetTime()
		if wm.served[key] and now - wm.served[key] < 10 then return end
		wm.served[key] = now
		local public = {}
		for _, s in ipairs(list) do
			if not s.u then public[#public + 1] = s end
		end
		self:SendCommMessage(COPY_PREFIX, ("%d:%d:%s"):format(mapID, list.t or 0, Pack(public)), "WHISPER", sender, "BULK")
	end
end

function ArtPad:OnMapCopy(_, msg, disType, sender)
	local catch = wm.catch
	if disType ~= "WHISPER" or #msg > 300000 or not catch or catch.phase ~= "fetch" or not Audience() then return end
	local mapID, t, body = msg:match("^(%d+):(%d+):(.*)$")
	mapID, t = tonumber(mapID), tonumber(t)
	if mapID ~= catch.mapID or self.ShortName(sender) ~= catch.source then return end
	local strokes = Unpack(body)
	if strokes and t <= GetServerTime() + 300 then ApplyCopy(catch, t, strokes) end
	Settle(catch)
end

-- Sharing switched on or off (Options): what is known of other people's copies is stale.
function ArtPad:SetMapSharing(on)
	ArtPad_Settings.MapShare = on and true or false
	wm.asked = {}
	wm.catch = nil
	if on then self:WorldMapAsk() end
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
		local body = type(text) == "function" and text() or text
		if body then GameTooltip:AddLine(body, 1, 0.82, 0, true) end
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
	MapTooltip(b, "Map Drawing", SharingText,
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
	if not wm.listening then
		-- other people's map drawings are taken in whether or not the map has been opened yet
		wm.listening = true
		self:RegisterComm(MAP_PREFIX, "OnMapMessage")
		self:RegisterComm(COPY_PREFIX, "OnMapCopy")
		-- drawings from before they were shared: give every stroke an id; they go out the
		-- first time their map is looked at with someone to tell
		for _, list in pairs(Drawings()) do
			if type(list) == "table" then
				for _, stroke in ipairs(list) do
					if type(stroke) == "table" and not stroke.id then
						stroke.id, stroke.u = NewId(), true
					end
				end
			end
		end
	end
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
		QueueAsk()
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
		QueueAsk()
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
