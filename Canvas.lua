--[[
	Canvas model.

	Every drawn thing is an "item" with a globally unique id "<author>:<localId>".
	  Stroke: { kind = "S", px/py = point arrays, dead = erased segment set, w = width,
	            r/g/b/a, smooth = render as a curve (freehand) or straight (shapes) }
	          Segment i joins point i and i+1. Points are addressed by index, so applying
	          the same message twice is harmless (needed when replaying after a sync).
	  Text:   { kind = "T", x, y, text, r/g/b/a }
	  Stamp:  { kind = "M", x, y, key, size }   raid markers and role icons

	Items are kept in drawing order in ArtPad.items and indexed by id in ArtPad.itemsById.
	The shared backdrop map (if any) is ArtPad.backdropMap; see Map.lua.
]]

local ArtPad = ArtPad

local math_sqrt, math_min, math_max, math_huge, math_floor, math_ceil =
	math.sqrt, math.min, math.max, math.huge, math.floor, math.ceil
local tinsert, tremove = table.insert, table.remove

ArtPad.items = {}
ArtPad.itemsById = {}
ArtPad.undoStack = {}
ArtPad.canvasVersion = 0 -- bumped on every change; used to cache sync snapshots

local linePool, dotPool, textPool, stampPool = {}, {}, {}, {}

local DOT_MIN_WIDTH = 3 -- below this, joints are too small to need round caps
local CORNER_COS = math.cos(math.rad(25)) -- straight strokes get a joint dot past this turn
local CURVE_TOL = 1 -- max distance (canvas px) between a rendered curve and the true one
local MIN_PIECE = 4 -- canvas px; no point splitting a segment finer than this
local MAX_PIECES = 8
-- Measured (/ap bench): past ~16384 quads (65536 vertices / 4) the client stops drawing them
-- *all*. The pool is shared - splitting over frames doesn't help, and plain textures count the
-- same as lines - so this counts every quad the canvas uses (lines, dots, markers, text
-- glyphs) and leaves headroom for the window, map tiles and other UI. Past LINE_BUDGET curves
-- are drawn as straight segments (one line each); LINE_CAP is a hard stop for new lines.
local LINE_BUDGET, LINE_CAP = 11000, 14500
ArtPad.LINE_BUDGET, ArtPad.LINE_CAP = LINE_BUDGET, LINE_CAP
ArtPad.lineBudget, ArtPad.lineCap = LINE_BUDGET, LINE_CAP -- /ap bench nolimit lifts these
ArtPad.linesInUse = 0
ArtPad.quadsInUse = 0

local function Use(region, quads)
	region.quads = quads
	ArtPad.quadsInUse = ArtPad.quadsInUse + quads
end

ArtPad.MAX_WIDTH = 256

--[[ Stamps ]]

local RAID_ICONS = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local ROLE_ICONS = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

-- key -> { texture, l, r, t, b, label }
ArtPad.STAMPS = {}
ArtPad.STAMP_ORDER = {}
do
	local names = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
	for i, name in ipairs(names) do
		local col, row = (i - 1) % 4, math_floor((i - 1) / 4)
		local key = "r" .. i
		ArtPad.STAMPS[key] = { RAID_ICONS, col / 4, (col + 1) / 4, row / 4, (row + 1) / 4, name }
		tinsert(ArtPad.STAMP_ORDER, key)
	end
	ArtPad.STAMPS.tank = { ROLE_ICONS, 0, 19 / 64, 22 / 64, 41 / 64, "Tank" }
	ArtPad.STAMPS.heal = { ROLE_ICONS, 20 / 64, 39 / 64, 1 / 64, 20 / 64, "Healer" }
	ArtPad.STAMPS.dps = { ROLE_ICONS, 20 / 64, 39 / 64, 22 / 64, 41 / 64, "Damage" }
	tinsert(ArtPad.STAMP_ORDER, "tank")
	tinsert(ArtPad.STAMP_ORDER, "heal")
	tinsert(ArtPad.STAMP_ORDER, "dps")
end

function ArtPad:GetStampSize()
	return math_floor(math_max(24, ArtPad_Settings.BrushSize * 6) * self:CanvasPerPixel() + 0.5)
end

--[[ Geometry ]]

local function PointSegDist(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local len2 = dx * dx + dy * dy
	local t = 0
	if len2 > 0 then
		t = ((px - ax) * dx + (py - ay) * dy) / len2
		if t < 0 then t = 0 elseif t > 1 then t = 1 end
	end
	local cx, cy = ax + t * dx - px, ay + t * dy - py
	return math_sqrt(cx * cx + cy * cy)
end

local function SegmentsIntersect(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1)
	local ux, uy = ax1 - ax0, ay1 - ay0
	local vx, vy = bx1 - bx0, by1 - by0
	local wx, wy = ax0 - bx0, ay0 - by0
	local D = ux * vy - uy * vx
	if D == 0 then return false end
	local s = (vx * wy - vy * wx) / D
	if s < 0 or s > 1 then return false end
	local t = (ux * wy - uy * wx) / D
	return t >= 0 and t <= 1
end

local function SegSegDist(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1)
	if SegmentsIntersect(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1) then
		return 0
	end
	return math_min(
		PointSegDist(ax0, ay0, bx0, by0, bx1, by1),
		PointSegDist(ax1, ay1, bx0, by0, bx1, by1),
		PointSegDist(bx0, by0, ax0, ay0, ax1, ay1),
		PointSegDist(bx1, by1, ax0, ay0, ax1, ay1))
end

ArtPad.PointSegDist = PointSegDist
ArtPad.SegSegDist = SegSegDist

--[[ Draw layers ]]

-- The client draws each frame's regions in batches with 16-bit vertex indices; a frame with
-- more than ~16k quads silently stops rendering *everything* on it. A long scribble easily
-- gets there (smooth segments are several lines each), so drawings are spread over child
-- frames of at most LAYER_SIZE regions. Pooled regions stay in the layer they were made in.
local LAYER_SIZE = 2000
ArtPad.LAYER_SIZE = LAYER_SIZE

function ArtPad:DrawLayer()
	local layers = self.drawLayers
	if not layers then
		layers = {}
		self.drawLayers = layers
	end
	local layer = layers[#layers]
	if not layer or layer.regions >= LAYER_SIZE then
		layer = CreateFrame("Frame", nil, self.mainFrame)
		layer:SetAllPoints(self.mainFrame)
		layer:SetFrameLevel(self.mainFrame:GetFrameLevel() + #layers + 1)
		layer.regions = 0
		tinsert(layers, layer)
	end
	layer.regions = layer.regions + 1
	return layer
end

-- /ap stats: what the canvas holds versus what is actually on screen, for tracking down
-- drawings that "vanish".
function ArtPad:PrintStats()
	local strokes, points, segs, shownLines, hiddenLines, other = 0, 0, 0, 0, 0, 0
	for _, item in ipairs(self.items) do
		if item.kind == "S" then
			strokes = strokes + 1
			points = points + (item.n or 0)
			for _, pieces in pairs(item.segs) do
				segs = segs + 1
				for _, line in ipairs(pieces) do
					if line:IsVisible() then shownLines = shownLines + 1 else hiddenLines = hiddenLines + 1 end
				end
			end
		else
			other = other + 1
		end
	end
	self:Message(("items %d (strokes %d, other %d), points %d, segments %d, lines shown %d / hidden %d, in use %d, quads %d%s")
		:format(#self.items, strokes, other, points, segs, shownLines, hiddenLines, self.linesInUse, self.quadsInUse,
			self.coarse and " (simplified)" or ""))
	local layers = {}
	for i, layer in ipairs(self.drawLayers or {}) do
		layers[i] = ("%d:%d%s a%.2f"):format(i, layer.regions, layer:IsVisible() and "" or " HIDDEN", layer:GetEffectiveAlpha())
	end
	self:Message("layers " .. (#layers > 0 and table.concat(layers, ", ") or "none"))
	local f, v = self.mainFrame, self.view or {}
	self:Message(("canvas shown %s, alpha %.2f, scale %.3f, offset %s,%s; queue %d; loopback %s; sync %s; me %s")
		:format(tostring(f:IsVisible()), f:GetEffectiveAlpha(), f:GetScale(), tostring(v[2]), tostring(v[3]),
			#(self.outQueue or {}), tostring(self.loopback and true or false), tostring(self.syncPhase), tostring(self.playerName)))
end

--[[ Region pools ]]

function ArtPad:AcquireLine()
	if self.quadsInUse >= self.lineCap then
		if not self.warnedFull then
			self.warnedFull = true
			if self.Notify then self:Notify("The canvas is full. Clear or erase something to keep drawing.", "warn") end
		end
		return nil
	end
	self.linesInUse = self.linesInUse + 1
	local line = tremove(linePool)
	if not line then
		line = self:DrawLayer():CreateLine(nil, "ARTWORK")
		-- Unsnapped lines look smoother when zoomed in (where the client supports it).
		if line.SetSnapToPixelGrid then line:SetSnapToPixelGrid(false) end
		if line.SetTexelSnappingBias then line:SetTexelSnappingBias(0) end
	end
	Use(line, 1)
	line:Show()
	return line
end

function ArtPad:AcquireDot()
	local dot = tremove(dotPool)
	if not dot then
		dot = self:DrawLayer():CreateTexture(nil, "ARTWORK", nil, 1)
		dot:SetTexture(self.MEDIA .. "dot")
	end
	Use(dot, 1)
	dot:Show()
	return dot
end

function ArtPad:AcquireFontString()
	local fs = tremove(textPool) or self:DrawLayer():CreateFontString(nil, "OVERLAY")
	fs:Show()
	return fs
end

local function Release(pool, region)
	ArtPad.quadsInUse = ArtPad.quadsInUse - (region.quads or 0)
	region.quads = nil
	region:Hide()
	region:ClearAllPoints()
	tinsert(pool, region)
end

local function ReleaseLine(line)
	ArtPad.linesInUse = ArtPad.linesInUse - 1
	Release(linePool, line)
end

local function ReleasePieces(pieces)
	for k = #pieces, 1, -1 do
		ReleaseLine(pieces[k])
		pieces[k] = nil
	end
end

--[[ Strokes ]]

local function SegAlive(s, i)
	return i >= 1 and s.px[i] ~= nil and s.px[i + 1] ~= nil and not s.dead[i]
end
ArtPad.SegAlive = SegAlive

--[[ Newest copy wins

	Every copy of a canvas remembers when it last changed (server time, so clocks agree):
	any stroke, erase, undo, clear or map change - yours or received live. When copies meet
	(joining, arriving at a place) the newest one wins; everyone in a session receives the
	same changes, so they hold the same time anyway. Housekeeping (loading a copy, switching
	canvases, a local-only clear) happens "quietly" and doesn't count as a change: a loaded
	copy keeps its own time, and an emptied canvas has time 0, so it never beats a real one.
]]

ArtPad.canvasModified = 0

function ArtPad:ServerNow()
	return GetServerTime and GetServerTime() or time()
end

function ArtPad:Changed()
	self.canvasVersion = self.canvasVersion + 1
	self.refreshPending = true -- status bar, undo button and empty state follow the canvas
	if (self.quiet or 0) == 0 then self.canvasModified = self:ServerNow() end
end

-- Run f(self, ...) without it counting as a change to the canvas.
function ArtPad:Quietly(f, ...)
	self.quiet = (self.quiet or 0) + 1
	local ok, err = pcall(f, self, ...)
	self.quiet = self.quiet - 1
	if not ok then error(err, 0) end
end

-- Empty the canvas (and map) as housekeeping: switching audience, resyncing.
function ArtPad:ResetCanvas()
	self:Quietly(self.ClearAll)
	self.canvasModified = 0
end

-- Returns the stroke with this id, creating it if needed (nil if the id is another kind).
function ArtPad:GetStroke(id, author, color, w, smooth)
	local item = self.itemsById[id]
	if item then
		return item.kind == "S" and item or nil
	end
	w = math_max(1, math_min(self.MAX_WIDTH, math_floor(tonumber(w) or 3)))
	local s = {
		id = id, kind = "S", author = author,
		r = color.r, g = color.g, b = color.b, a = color.a, w = w, smooth = smooth and true or false,
		px = {}, py = {}, n = 0, dead = {}, segs = {}, dots = {},
		minX = math_huge, minY = math_huge, maxX = -math_huge, maxY = -math_huge,
	}
	self.itemsById[id] = s
	tinsert(self.items, s)
	self:Changed()
	return s
end

-- Points along segment i: a Catmull-Rom curve for smooth strokes (using the neighbouring
-- points when they exist and are connected), a straight line otherwise.
local curveX, curveY = {}, {}
local function SegmentPath(s, i)
	local x1, y1, x2, y2 = s.px[i], s.py[i], s.px[i + 1], s.py[i + 1]
	curveX[1], curveY[1] = x1, y1
	local dx, dy = x2 - x1, y2 - y1
	local len = math_sqrt(dx * dx + dy * dy)
	local pieces = 1
	local x0, y0, x3, y3 = x1, y1, x2, y2
	if s.smooth and not ArtPad.coarse and len > MIN_PIECE then
		if SegAlive(s, i - 1) then x0, y0 = s.px[i - 1], s.py[i - 1] end
		if SegAlive(s, i + 1) then x3, y3 = s.px[i + 2], s.py[i + 2] end
		-- How far the curve bows away from the straight chord: Hermite form with Catmull-Rom
		-- tangents m1, m2; the bow is at most 4/27 (|m1 - d| + |m2 - d|), and shrinks with the
		-- square of the number of pieces.
		local ex1, ey1 = (x2 - x0) / 2 - dx, (y2 - y0) / 2 - dy
		local ex2, ey2 = (x3 - x1) / 2 - dx, (y3 - y1) / 2 - dy
		local bow = 4 / 27 * (math_sqrt(ex1 * ex1 + ey1 * ey1) + math_sqrt(ex2 * ex2 + ey2 * ey2))
		pieces = math_ceil(math_sqrt(bow / CURVE_TOL))
		pieces = math_max(1, math_min(MAX_PIECES, pieces, math_floor(len / MIN_PIECE)))
	end
	if pieces > 1 then
		for k = 1, pieces - 1 do
			local t = k / pieces
			local t2, t3 = t * t, t * t * t
			curveX[k + 1] = 0.5 * (2 * x1 + (x2 - x0) * t + (2 * x0 - 5 * x1 + 4 * x2 - x3) * t2 + (3 * x1 - x0 - 3 * x2 + x3) * t3)
			curveY[k + 1] = 0.5 * (2 * y1 + (y2 - y0) * t + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2 + (3 * y1 - y0 - 3 * y2 + y3) * t3)
		end
	end
	curveX[pieces + 1], curveY[pieces + 1] = x2, y2
	return pieces
end

function ArtPad:RenderSegment(s, i)
	if i < 1 then return end
	local pieces = s.segs[i]
	if not SegAlive(s, i) then
		if pieces then
			ReleasePieces(pieces)
			s.segs[i] = nil
		end
		return
	end
	if not pieces then
		pieces = {}
		s.segs[i] = pieces
	end
	local count = SegmentPath(s, i)
	-- Overlap neighbouring pieces a little so gentle bends have no gaps on the outside.
	local ext = 0.5 + 0.12 * s.w
	for k = 1, count do
		local line = pieces[k]
		if not line then
			line = self:AcquireLine()
			if not line then
				count = k - 1
				break
			end
			pieces[k] = line
		end
		local ax, ay, bx, by = curveX[k], curveY[k], curveX[k + 1], curveY[k + 1]
		local dx, dy = bx - ax, by - ay
		local len = math_sqrt(dx * dx + dy * dy)
		if len > 0 then
			dx, dy = dx / len * ext, dy / len * ext
		end
		line:SetColorTexture(s.r, s.g, s.b, s.a)
		line:SetThickness(s.w)
		line:SetStartPoint("BOTTOMLEFT", self.mainFrame, ax - dx, ay - dy)
		line:SetEndPoint("BOTTOMLEFT", self.mainFrame, bx + dx, by + dy)
	end
	for k = #pieces, count + 1, -1 do
		ReleaseLine(pieces[k])
		pieces[k] = nil
	end
end

-- Round caps at stroke ends; straight strokes (shapes) also get dots at sharp corners.
-- Smooth strokes have continuous tangents, so they only need caps.
function ArtPad:UpdateDot(s, i)
	if i < 1 or i > s.n then return end
	local want = false
	local x, y = s.px[i], s.py[i]
	if x then
		if s.n == 1 then
			want = true -- a single click
		elseif s.w >= DOT_MIN_WIDTH then
			local inAlive, outAlive = SegAlive(s, i - 1), SegAlive(s, i)
			if inAlive and outAlive then
				if not s.smooth then
					local ax, ay = x - s.px[i - 1], y - s.py[i - 1]
					local bx, by = s.px[i + 1] - x, s.py[i + 1] - y
					local la, lb = math_sqrt(ax * ax + ay * ay), math_sqrt(bx * bx + by * by)
					want = la == 0 or lb == 0 or (ax * bx + ay * by) / (la * lb) < CORNER_COS
				end
			else
				want = inAlive or outAlive
			end
		end
	end
	local dot = s.dots[i]
	if want then
		if not dot then
			dot = self:AcquireDot()
			s.dots[i] = dot
		end
		local size = math_max(s.w, 2)
		dot:SetVertexColor(s.r, s.g, s.b, s.a)
		dot:SetSize(size, size)
		dot:ClearAllPoints()
		dot:SetPoint("CENTER", self.mainFrame, "BOTTOMLEFT", x, y)
	elseif dot then
		Release(dotPool, dot)
		s.dots[i] = nil
	end
end

function ArtPad:SetStrokePoint(s, i, x, y)
	if s.px[i] == x and s.py[i] == y then return end
	s.px[i], s.py[i] = x, y
	if i > s.n then s.n = i end
	if x < s.minX then s.minX = x end
	if x > s.maxX then s.maxX = x end
	if y < s.minY then s.minY = y end
	if y > s.maxY then s.maxY = y end
	-- A curve segment depends on the points either side, so neighbours re-render too.
	local reach = s.smooth and 2 or 1
	for k = i - reach, i + reach - 1 do
		self:RenderSegment(s, k)
	end
	self:UpdateDot(s, i - 1)
	self:UpdateDot(s, i)
	self:UpdateDot(s, i + 1)
	self:Changed()
	self:CheckLineBudget()
end

-- Past LINE_BUDGET lines, redraw every curve as straight segments so the canvas stays under
-- the client's limit. Goes back to curves once the canvas is cleared.
function ArtPad:CheckLineBudget()
	if self.coarse or self.quadsInUse <= self.lineBudget then return end
	self.coarse = true
	for _, item in ipairs(self.items) do
		if item.kind == "S" and item.smooth then
			for k = 1, item.n - 1 do self:RenderSegment(item, k) end
		end
	end
end

-- segments: array of segment indices. Erasing every segment removes the stroke.
function ArtPad:EraseSegments(s, segments)
	for _, i in ipairs(segments) do
		if not s.dead[i] then
			s.dead[i] = true -- may arrive before the points do; they'll then never render
			for k = i - 1, i + 1 do self:RenderSegment(s, k) end
			self:UpdateDot(s, i)
			self:UpdateDot(s, i + 1)
		end
	end
	self:Changed()
	if s.n > 1 then
		for i = 1, s.n - 1 do
			if SegAlive(s, i) then return end
		end
		self:RemoveItem(s.id)
	end
end

--[[ Texts ]]

function ArtPad:AddText(id, author, x, y, text, color, size)
	if self.itemsById[id] then return end
	size = math_max(6, math_min(400, math_floor(tonumber(size) or 14)))
	local fs = self:AcquireFontString()
	fs:SetFont(self.FONT, size, "")
	fs:SetJustifyH("LEFT")
	fs:SetPoint("BOTTOMLEFT", self.mainFrame, "BOTTOMLEFT", x, y)
	fs:SetTextColor(color.r, color.g, color.b, color.a)
	fs:SetText(text)
	Use(fs, #text) -- about one quad per glyph
	local t = {
		id = id, kind = "T", author = author,
		x = x, y = y, text = text, r = color.r, g = color.g, b = color.b, a = color.a, size = size,
		fs = fs, x2 = x + fs:GetStringWidth(), y2 = y + fs:GetStringHeight(),
	}
	self.itemsById[id] = t
	tinsert(self.items, t)
	self:Changed()
	return t
end

--[[ Stamps ]]

function ArtPad:AddStamp(id, author, key, x, y, size)
	local def = self.STAMPS[key]
	if self.itemsById[id] or not def then return end
	size = math_max(8, math_min(512, math_floor(tonumber(size) or 40)))
	local tex = tremove(stampPool) or self:DrawLayer():CreateTexture(nil, "OVERLAY")
	tex:SetTexture(def[1])
	tex:SetTexCoord(def[2], def[3], def[4], def[5])
	tex:SetSize(size, size)
	tex:ClearAllPoints()
	tex:SetPoint("CENTER", self.mainFrame, "BOTTOMLEFT", x, y)
	Use(tex, 1)
	tex:Show()
	local m = { id = id, kind = "M", author = author, key = key, x = x, y = y, size = size, tex = tex }
	self.itemsById[id] = m
	tinsert(self.items, m)
	self:Changed()
	return m
end

--[[ Removal ]]

local function ReleaseItem(item)
	if item.kind == "S" then
		for _, pieces in pairs(item.segs) do ReleasePieces(pieces) end
		for _, dot in pairs(item.dots) do Release(dotPool, dot) end
		wipe(item.segs)
		wipe(item.dots)
	elseif item.kind == "M" then
		Release(stampPool, item.tex)
		item.tex = nil
	elseif item.fs then
		Release(textPool, item.fs)
		item.fs = nil
	end
end

ArtPad.ReleaseItem = ReleaseItem

-- Re-key everything `old` drew as `new` (see LearnOwnName).
function ArtPad:RenameAuthor(old, new)
	if not old or old == new then return end
	local prefix = old .. ":"
	local function Rekey(id)
		if type(id) == "string" and id:sub(1, #prefix) == prefix then
			return new .. ":" .. id:sub(#prefix + 1)
		end
		return id
	end
	for _, item in ipairs(self.items) do
		local id = Rekey(item.id)
		if id ~= item.id then
			self.itemsById[item.id] = nil
			item.id, item.author = id, new
			self.itemsById[id] = item
		end
	end
	for k, id in ipairs(self.undoStack) do self.undoStack[k] = Rekey(id) end
	if self.currentStroke then self.currentStroke.id = Rekey(self.currentStroke.id) end
	self:Changed()
end

function ArtPad:RemoveItem(id)
	local item = self.itemsById[id]
	if not item then return end
	ReleaseItem(item)
	self.itemsById[id] = nil
	for i = #self.items, 1, -1 do
		if self.items[i] == item then
			tremove(self.items, i)
			break
		end
	end
	self:Changed()
end

-- Clears the drawings (the backdrop map stays).
function ArtPad:ClearCanvas()
	for _, item in ipairs(self.items) do
		ReleaseItem(item)
	end
	wipe(self.items)
	wipe(self.itemsById)
	wipe(self.undoStack)
	self.coarse, self.warnedFull = false, false
	self:Changed()
end

-- Clears everything, including the backdrop (switching audience, reloading the canvas).
function ArtPad:ClearAll()
	self:ClearCanvas()
	if self.SetBackdrop and not self.node then self:SetBackdrop(nil) end -- a place keeps its map
end

--[[ Hit testing for the eraser ]]

-- Returns { [id] = true (whole item) | { segment indices } } for everything within
-- `radius` of the eraser segment (x1,y1)-(x2,y2).
function ArtPad:HitTest(x1, y1, x2, y2, radius)
	local hits = {}
	local ex0, ex1 = math_min(x1, x2), math_max(x1, x2)
	local ey0, ey1 = math_min(y1, y2), math_max(y1, y2)
	for _, it in ipairs(self.items) do
		if it.kind == "S" then
			local pad = radius + it.w / 2
			if it.maxX >= ex0 - pad and it.minX <= ex1 + pad and it.maxY >= ey0 - pad and it.minY <= ey1 + pad then
				local px, py = it.px, it.py
				if it.n == 1 then
					if px[1] and PointSegDist(px[1], py[1], x1, y1, x2, y2) <= pad then
						hits[it.id] = true
					end
				else
					local segs
					for i = 1, it.n - 1 do
						if SegAlive(it, i) and SegSegDist(x1, y1, x2, y2, px[i], py[i], px[i + 1], py[i + 1]) <= pad then
							segs = segs or {}
							tinsert(segs, i)
						end
					end
					hits[it.id] = segs
				end
			end
		elseif it.kind == "M" then
			if PointSegDist(it.x, it.y, x1, y1, x2, y2) <= radius + it.size / 2 then
				hits[it.id] = true
			end
		else
			local ax, ay, bx, by = it.x, it.y, it.x2, it.y2
			local inside = (x1 >= ax and x1 <= bx and y1 >= ay and y1 <= by) or (x2 >= ax and x2 <= bx and y2 >= ay and y2 <= by)
			if inside or math_min(
					SegSegDist(x1, y1, x2, y2, ax, ay, bx, ay),
					SegSegDist(x1, y1, x2, y2, bx, ay, bx, by),
					SegSegDist(x1, y1, x2, y2, bx, by, ax, by),
					SegSegDist(x1, y1, x2, y2, ax, by, ax, ay)) <= radius then
				hits[it.id] = true
			end
		end
	end
	return hits
end

-- Apply eraser hits (from HitTest or an incoming erase message).
function ArtPad:ApplyErase(hits)
	for id, h in pairs(hits) do
		local item = self.itemsById[id]
		if item then
			if h == true or item.kind ~= "S" then
				self:RemoveItem(id)
			else
				self:EraseSegments(item, h)
			end
		end
	end
end

--[[ Undo ]]

function ArtPad:PushUndo(id)
	tinsert(self.undoStack, id)
end

-- Undo your most recent stroke, text or stamp that still exists.
function ArtPad:Undo()
	while #self.undoStack > 0 do
		local id = tremove(self.undoStack)
		if self.itemsById[id] or (self.loopback and id:find(self.playerName .. ":", 1, true) == 1) then
			local localId = id:sub(#self.playerName + 2)
			if not self.loopback then
				self:RemoveItem(id)
			end
			self:QueueCommand("U(" .. localId .. ")")
			return true
		end
	end
	return false
end

--[[ Snapshots (late-join sync) ]]

local function Round2(n)
	return (string.format("%.2f", tonumber(n) or 0):gsub("0+$", ""):gsub("%.$", ""))
end
ArtPad.Round2 = Round2

function ArtPad.ColorString(c)
	return Round2(c.r) .. "," .. Round2(c.g) .. "," .. Round2(c.b) .. "," .. Round2(c.a)
end

local NUM = "(%-?%d+%.?%d*)"
ArtPad.NUM = NUM
local COLOR_PATTERN = "^" .. NUM .. "," .. NUM .. "," .. NUM .. "," .. NUM .. "$"

function ArtPad.ParseColor(str)
	local r, g, b, a = tostring(str):match(COLOR_PATTERN)
	if not r then return nil end
	return { r = tonumber(r), g = tonumber(g), b = tonumber(b), a = tonumber(a) }
end

function ArtPad:SerializeCanvas()
	local out = {}
	for _, it in ipairs(self.items) do
		if it.kind == "S" then
			local complete = true
			for i = 1, it.n do
				if not it.px[i] then complete = false break end
			end
			local points
			if complete and it.n > 0 then
				-- Same compact encoding as live drawing: keeps snapshots (and late-join waits) small
				points = "E" .. self.EncodePoints(it.px, it.py, 1, it.n)
			else
				local pts = {}
				for i = 1, it.n do
					pts[i] = it.px[i] and (it.px[i] .. "," .. it.py[i]) or "_"
				end
				points = table.concat(pts, ";")
			end
			local dead = {}
			for i in pairs(it.dead) do tinsert(dead, i) end
			table.sort(dead)
			tinsert(out, { it.id, "S", it.author, self.ColorString(it), it.w, points,
				table.concat(dead, ","), it.smooth and "s" or "" })
		elseif it.kind == "M" then
			tinsert(out, { it.id, "M", it.author, "1,1,1,1", it.x, it.y, it.key .. ":" .. it.size })
		else
			tinsert(out, { it.id, "T", it.author, self.ColorString(it), it.x, it.y, it.text, it.size })
		end
	end
	return { v = 2, items = out, map = self.backdropMap, mapOverlays = self.backdropOverlays,
		modified = self.canvasModified }
end

local function LoadCanvasBody(self, snapshot)
	self:ClearAll()
	if self.SetBackdrop and tonumber(snapshot.map) and not self.node then
		self:SetBackdrop(tonumber(snapshot.map), type(snapshot.mapOverlays) == "string" and snapshot.mapOverlays or "")
	end
	for _, rec in ipairs(snapshot.items) do
		local id, kind, author, color = rec[1], rec[2], rec[3], self.ParseColor(rec[4])
		if type(id) == "string" and type(author) == "string" and color and not self.itemsById[id] then
			if kind == "S" then
				local s = self:GetStroke(id, author, color, rec[5], rec[8] == "s")
				for d in tostring(rec[7] or ""):gmatch("%d+") do
					s.dead[tonumber(d)] = true
				end
				local points = tostring(rec[6] or "")
				if points:sub(1, 1) == "E" then
					local xs, ys = self.DecodePoints(points:sub(2))
					for i = 1, xs and #xs or 0 do
						self:SetStrokePoint(s, i, xs[i], ys[i])
					end
				else
					local i = 0
					for p in (points .. ";"):gmatch("([^;]*);") do
						i = i + 1
						local x, y = p:match("^" .. NUM .. "," .. NUM .. "$")
						if x then
							self:SetStrokePoint(s, i, tonumber(x), tonumber(y))
						end
					end
				end
				-- A fully erased stroke that slipped through; drop it.
				if s.n == 0 then self:RemoveItem(id) end
			elseif kind == "T" and tonumber(rec[5]) and tonumber(rec[6]) and type(rec[7]) == "string" then
				self:AddText(id, author, tonumber(rec[5]), tonumber(rec[6]), rec[7], color, rec[8])
			elseif kind == "M" and tonumber(rec[5]) and tonumber(rec[6]) then
				local key, size = tostring(rec[7]):match("^(%w+):(%d+)$")
				if key then
					self:AddStamp(id, author, key, tonumber(rec[5]), tonumber(rec[6]), tonumber(size))
				end
			end
		end
	end
end

-- Replace the canvas with a copy; it keeps the copy's own last-changed time.
function ArtPad:LoadCanvas(snapshot)
	self:Quietly(LoadCanvasBody, snapshot)
	self.canvasModified = tonumber(snapshot.modified) or 0
end
