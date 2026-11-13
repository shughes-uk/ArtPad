--[[
	Hidden benchmarks for finding the client's rendering limits. Not in the help text.
	Everything here is local: nothing is added to the canvas items, synced or saved.

	/ap bench lines <n> [per]    n raw lines in a grid over the canvas, [per] lines per frame
	                             (default: all on one frame)
	/ap bench tex <n> [per]      the same with plain textures, to see if the limit is lines-only
	/ap bench more <n>           add n more of the last kind, continuing the same grid
	/ap bench scribble <points>  a random scribble through the real stroke renderer
	/ap bench nolimit            toggle ArtPad's own line budget/cap (to reproduce the bug)
	/ap bench clear              hide everything the benchmarks made
	/ap bench                    print what's up

	Each cell of the grid holds one region, coloured by row (a rainbow top to bottom), so a
	cut-off shows as missing rows and a total failure as an empty canvas. Regions can't be
	destroyed, so /reload between runs for clean numbers.
]]

local ArtPad = ArtPad

local GRID_COLS, GRID_ROWS = 267, 150 -- 40050 cells: room for any test, same spot every time
local bench = { kind = nil, per = nil, count = 0, frames = {}, frame = nil, inFrame = 0, regions = {} }
ArtPad.bench = bench

local function Hue(t)
	local h = (t % 1) * 6
	local i, f = math.floor(h), h - math.floor(h)
	local rgb = { { 1, f, 0 }, { 1 - f, 1, 0 }, { 0, 1, f }, { 0, 1 - f, 1 }, { f, 0, 1 }, { 1, 0, 1 - f } }
	return unpack(rgb[i + 1])
end

function ArtPad:BenchFrame()
	if bench.frame and (not bench.per or bench.inFrame < bench.per) then return bench.frame end
	local f = CreateFrame("Frame", nil, self.mainFrame)
	f:SetAllPoints(self.mainFrame)
	f:SetFrameLevel(self.mainFrame:GetFrameLevel() + 500 + #bench.frames % 400)
	table.insert(bench.frames, f)
	bench.frame, bench.inFrame = f, 0
	return f
end

function ArtPad:BenchAdd(n)
	local W, H = self.canvasSize.X, self.canvasSize.Y
	local cw, ch = W / GRID_COLS, H / GRID_ROWS
	for _ = 1, n do
		local i = bench.count
		if i >= GRID_COLS * GRID_ROWS then break end
		local col, row = i % GRID_COLS, math.floor(i / GRID_COLS)
		local x, y = col * cw, H - (row + 0.5) * ch
		local r, g, b = Hue(row / GRID_ROWS)
		local f = self:BenchFrame()
		local region
		if bench.kind == "lines" then
			region = f:CreateLine(nil, "ARTWORK")
			region:SetThickness(ch * 0.6)
			region:SetColorTexture(r, g, b, 1)
			region:SetStartPoint("BOTTOMLEFT", self.mainFrame, x + cw * 0.1, y)
			region:SetEndPoint("BOTTOMLEFT", self.mainFrame, x + cw * 0.9, y)
		else
			region = f:CreateTexture(nil, "ARTWORK")
			region:SetColorTexture(r, g, b, 1)
			region:SetSize(cw * 0.8, ch * 0.6)
			region:SetPoint("LEFT", self.mainFrame, "BOTTOMLEFT", x + cw * 0.1, y)
		end
		region:Show()
		table.insert(bench.regions, region)
		bench.count = i + 1
		bench.inFrame = bench.inFrame + 1
	end
	self:BenchReport()
end

function ArtPad:BenchStart(kind, n, per)
	self:BenchClear(true)
	bench.kind, bench.per, bench.count = kind, per, 0
	bench.frame, bench.inFrame = nil, 0
	self:BenchAdd(n)
end

function ArtPad:BenchScribble(points)
	local s = {
		id = "bench:" .. (#(bench.strokes or {}) + 1), kind = "S", author = "bench",
		r = 1, g = 0.8, b = 0.2, a = 1, w = 4, smooth = true,
		px = {}, py = {}, n = 0, dead = {}, segs = {}, dots = {},
		minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge,
	}
	bench.strokes = bench.strokes or {}
	table.insert(bench.strokes, s)
	local x, y, angle = self.canvasSize.X / 2, self.canvasSize.Y / 2, 0
	self:Quietly(function() -- not a change to the shared canvas
	for i = 1, points do
		angle = angle + (math.random() - 0.5) * 2.4
		x = math.max(20, math.min(self.canvasSize.X - 20, x + 14 * math.cos(angle)))
		y = math.max(20, math.min(self.canvasSize.Y - 20, y + 14 * math.sin(angle)))
		self:SetStrokePoint(s, i, math.floor(x), math.floor(y))
	end
	end)
	self:Message(("bench: scribble of %d points; canvas lines in use %d (budget %s, cap %s)%s")
		:format(points, self.linesInUse, tostring(self.lineBudget), tostring(self.lineCap),
			self.coarse and ", simplified" or ""))
end

function ArtPad:BenchClear(quiet)
	for _, region in ipairs(bench.regions) do region:Hide() end
	wipe(bench.regions)
	for _, s in ipairs(bench.strokes or {}) do self.ReleaseItem(s) end
	bench.strokes = {}
	bench.count = 0
	self:AfterRemoval() -- the real canvas goes back to its normal detail
	if not quiet then self:Message("bench: cleared (/reload for a clean slate)") end
end

function ArtPad:BenchReport()
	self:Message(("bench: %d %s shown, %s per frame, %d frames made this session")
		:format(#bench.regions, bench.kind or "regions", bench.per and tostring(bench.per) or "all",
			#bench.frames))
end

function ArtPad:BenchCommand(arg)
	local cmd, a, b = (arg or ""):match("^(%a*)%s*(%d*)%s*(%d*)")
	a, b = tonumber(a), tonumber(b)
	if (cmd == "lines" or cmd == "tex") and a then
		self:BenchStart(cmd, a, b)
	elseif cmd == "more" and a and bench.kind then
		self:BenchAdd(a)
	elseif cmd == "scribble" and a then
		self:BenchScribble(a)
	elseif cmd == "nolimit" then
		if self.lineCap == math.huge then
			self.lineBudget, self.lineCap = self.LINE_BUDGET, self.LINE_CAP
			self:CheckLineBudget()
			self:Message("bench: line budget and cap back on")
		else
			self.lineBudget, self.lineCap = math.huge, math.huge
			self:AfterRemoval() -- with no budget, curves are drawn in full again
			self:Message("bench: line budget and cap OFF (drawings can vanish again)")
		end
	elseif cmd == "mapshot" then
		self:BenchMapShot(a)
	elseif cmd == "clear" then
		self:BenchClear()
	else
		self:BenchReport()
		self:Message("bench lines|tex <n> [per frame], more <n>, scribble <points>, nolimit, clear, mapshot [area]")
	end
end

--[[
	/ap bench mapshot [area]: the map around the first place (the Lion's Pride Inn), drawn
	full screen at exactly SHOT_SCALE screen pixels per map pixel with no filtering, on a
	magenta background, for a lossless screenshot of the original art (to upscale offline).
	area: how much more than the place's own view to include (default 3). Run it again to
	close it.
]]
local SHOT_SCALE = 4

function ArtPad:BenchMapShot(area)
	if self.mapShot and self.mapShot:IsShown() then
		self.mapShot:Hide()
		self:Message("mapshot: closed")
		return
	end
	area = area or 3
	local place = self.PLACES[1]
	local mapID, layer, textures
	for _, id in ipairs(place.mapIDs) do
		layer, textures = self:GetMapTiles(id)
		if layer then mapID = id break end
	end
	if not mapID then
		self:Message("mapshot: no map art for " .. place.name .. " on this client")
		return
	end
	local view = self:PlaceView(place, mapID)
	local tw, th, lw, lh = layer.tileWidth, layer.tileHeight, layer.layerWidth, layer.layerHeight
	-- Source window in whole map pixels, `area` times the place's view
	local cx, cy = (view[1] + view[3]) / 2 * lw, (view[2] + view[4]) / 2 * lh
	local hw, hh = (view[3] - view[1]) / 2 * lw * area, (view[4] - view[2]) / 2 * lh * area
	local vx0, vy0 = math.max(0, math.floor(cx - hw)), math.max(0, math.floor(cy - hh))
	local vx1, vy1 = math.min(lw, math.ceil(cx + hw)), math.min(lh, math.ceil(cy + hh))

	local f = self.mapShot
	if not f then
		f = CreateFrame("Frame", "ArtPad_MapShot", UIParent)
		f:SetFrameStrata("FULLSCREEN_DIALOG")
		f:SetIgnoreParentScale(true)
		f.bg = f:CreateTexture(nil, "BACKGROUND")
		f.bg:SetAllPoints()
		f.bg:SetColorTexture(1, 0, 1, 1)
		f.textures = {}
		self.mapShot = f
	end
	-- One unit = one physical screen pixel
	local pw, ph = GetPhysicalScreenSize()
	f:SetScale(768 / ph)
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	f:SetSize(pw, ph)
	for _, tex in ipairs(f.textures) do tex:Hide() end
	local used = 0
	local imgW, imgH = (vx1 - vx0) * SHOT_SCALE, (vy1 - vy0) * SHOT_SCALE
	local left, top = math.floor((pw - imgW) / 2), math.floor((ph - imgH) / 2)
	local function Draw(fileID, sublevel, x, y, w, h, fw, fh)
		local ix0, iy0 = math.max(x, vx0), math.max(y, vy0)
		local ix1, iy1 = math.min(x + w, vx1), math.min(y + h, vy1)
		if ix1 <= ix0 or iy1 <= iy0 then return end
		used = used + 1
		local tex = f.textures[used]
		if not tex then
			tex = f:CreateTexture(nil, "ARTWORK")
			f.textures[used] = tex
		end
		tex:SetDrawLayer("ARTWORK", sublevel)
		tex:SetTexture(fileID, nil, nil, "NEAREST")
		tex:SetTexCoord((ix0 - x) / fw, (ix1 - x) / fw, (iy0 - y) / fh, (iy1 - y) / fh)
		tex:ClearAllPoints()
		tex:SetSize((ix1 - ix0) * SHOT_SCALE, (iy1 - iy0) * SHOT_SCALE)
		tex:SetPoint("TOPLEFT", f, "TOPLEFT", left + (ix0 - vx0) * SHOT_SCALE, -(top + (iy0 - vy0) * SHOT_SCALE))
		tex:Show()
	end
	local cols = math.ceil(lw / tw)
	for i, fileID in ipairs(textures) do
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		local cw, ch = math.min(tw, lw - col * tw), math.min(th, lh - row * th)
		if cw > 0 and ch > 0 then Draw(fileID, 1, col * tw, row * th, cw, ch, tw, th) end
	end
	local TILE = 256
	for overlay in self:GetExploredOverlays(mapID):gmatch("[^;]+") do
		local w, h, x, y, ids = overlay:match("^(%d+),(%d+),(%-?%d+),(%-?%d+),([%d%.]+)$")
		if w then
			w, h, x, y = tonumber(w), tonumber(h), tonumber(x), tonumber(y)
			local fileIDs = {}
			for id in ids:gmatch("%d+") do table.insert(fileIDs, tonumber(id)) end
			local wide, tall = math.ceil(w / TILE), math.ceil(h / TILE)
			for j = 1, tall do
				local tph, fh = self.MapTileSpan(h, j, tall)
				for k = 1, wide do
					local fileID = fileIDs[(j - 1) * wide + k]
					if fileID then
						local tpw, fw = self.MapTileSpan(w, k, wide)
						Draw(fileID, 2, x + TILE * (k - 1), y + TILE * (j - 1), tpw, tph, fw, fh)
					end
				end
			end
		end
	end
	f:Show()
	self:Message(("mapshot: map %d, pixels %d,%d to %d,%d (%dx%d) at %dx on a %dx%d screen. "
		.. "For a lossless shot: /console screenshotFormat tga, then Print Screen. /ap bench mapshot again to close.")
		:format(mapID, vx0, vy0, vx1, vy1, vx1 - vx0, vy1 - vy0, SHOT_SCALE, pw, ph))
end

--[[
	Brush lab (hidden: /ap lab). A prototype for comparing ways of drawing a stroke, side by
	side, from the same points:

	  1. Today's world-map stroke: a straight Line between each two points.
	  2. Curves, round ends and an outline: the points joined by a centripetal Catmull-Rom
	     curve (sharp corners kept), Lines for the pieces, a dot at each end and corner, and a
	     wider contrasting copy underneath.
	  3. A welded ribbon: one Texture per piece whose four corners are moved (SetVertexOffset)
	     so that neighbouring pieces share an edge exactly - no gaps, no overlaps, width free
	     to change along the stroke (tapered ends) - with a soft edge from a small texture
	     sampled by distance from each side (the 8-number SetTexCoord).

	Drawing in any panel adds the stroke to all three (colour and size are ArtPad's brush).
	Nothing here is saved or sent. Whether 3 works at all in this client is what the lab is for.
]]

do -- (its own scope: the lab shares this file only so that /reload is enough to get it)
local PANEL_W, PANEL_H, GAP, DARK_H = 380, 420, 12, 130
local EDGE = ArtPad.MEDIA .. "lab_edge" -- 64x64, white; its top row and left column are transparent
local EDGE_N = 64
local MIN_STEP, THIN, STRING = 3, 0.75, 3 -- px: sampling, thinning tolerance, pull-string length

local lab = { strokes = {}, outline = true, taper = true, pools = { line = {}, quad = {}, dot = {} }, used = {} }
ArtPad.brushLab = lab

--[[ Geometry ]]

-- Ramer-Douglas-Peucker on { x, y, x, y, ... }.
local function Thin(p, tol)
	local n = #p / 2
	if n < 3 then return p end
	local keep = { [1] = true, [n] = true }
	local stack = { 1, n }
	while #stack > 0 do
		local b, a = table.remove(stack), table.remove(stack)
		local worst, at = tol, nil
		for i = a + 1, b - 1 do
			local d = ArtPad.PointSegDist(p[2 * i - 1], p[2 * i], p[2 * a - 1], p[2 * a], p[2 * b - 1], p[2 * b])
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
		if keep[i] then out[#out + 1], out[#out + 2] = p[2 * i - 1], p[2 * i] end
	end
	return out
end

-- The knots joined by a centripetal Catmull-Rom curve, flattened to { x, y, corner } points.
-- A knot where the stroke turns sharply is a corner: the curve stops and starts again there.
local function Curve(p)
	local n = #p / 2
	local function K(i) return p[2 * i - 1], p[2 * i] end
	if n < 3 then
		local out = {}
		for i = 1, n do out[i] = { p[2 * i - 1], p[2 * i], false } end
		return out
	end
	local corner = {}
	for i = 2, n - 1 do
		local ax, ay = K(i - 1)
		local bx, by = K(i)
		local cx, cy = K(i + 1)
		local ux, uy, vx, vy = bx - ax, by - ay, cx - bx, cy - by
		local lu, lv = math.sqrt(ux * ux + uy * uy), math.sqrt(vx * vx + vy * vy)
		corner[i] = lu > 0 and lv > 0 and (ux * vx + uy * vy) / (lu * lv) < 0.35 -- more than about 70 degrees
	end
	local out = {}
	local x1, y1 = K(1)
	out[1] = { x1, y1, false }
	for i = 1, n - 1 do
		local p1x, p1y = K(i)
		local p2x, p2y = K(i + 1)
		local dx, dy = p2x - p1x, p2y - p1y
		local d12 = math.sqrt(math.sqrt(dx * dx + dy * dy))
		local m1x, m1y, m2x, m2y = dx, dy, dx, dy
		if i > 1 and not corner[i] and d12 > 0 then
			local p0x, p0y = K(i - 1)
			local d01 = math.sqrt(math.sqrt((p1x - p0x) ^ 2 + (p1y - p0y) ^ 2))
			if d01 > 0 then
				m1x = dx + d12 * ((p1x - p0x) / d01 - (p2x - p0x) / (d01 + d12))
				m1y = dy + d12 * ((p1y - p0y) / d01 - (p2y - p0y) / (d01 + d12))
			end
		end
		if i < n - 1 and not corner[i + 1] and d12 > 0 then
			local p3x, p3y = K(i + 2)
			local d23 = math.sqrt(math.sqrt((p3x - p2x) ^ 2 + (p3y - p2y) ^ 2))
			if d23 > 0 then
				m2x = dx + d12 * ((p3x - p2x) / d23 - (p3x - p1x) / (d12 + d23))
				m2y = dy + d12 * ((p3y - p2y) / d23 - (p3y - p1y) / (d12 + d23))
			end
		end
		-- how far the curve bows from its chord decides how many pieces it gets
		local bow = 4 / 27 * (math.sqrt((m1x - dx) ^ 2 + (m1y - dy) ^ 2) + math.sqrt((m2x - dx) ^ 2 + (m2y - dy) ^ 2))
		local pieces = math.max(1, math.min(10, math.ceil(math.sqrt(bow / 0.2))))
		for k = 1, pieces do
			local t = k / pieces
			local t2, t3 = t * t, t * t * t
			local a, b, c, d = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
			out[#out + 1] = { a * p1x + b * m1x + c * p2x + d * m2x, a * p1y + b * m1y + c * p2y + d * m2y, k == pieces and corner[i + 1] or false }
		end
	end
	return out
end

--[[ Regions ]]

local function Acquire(kind, panel, layer, sub)
	local r = table.remove(lab.pools[kind])
	if not r then
		if kind == "line" then
			r = lab.window:CreateLine()
		else
			r = lab.window:CreateTexture()
		end
		if r.SetSnapToPixelGrid then r:SetSnapToPixelGrid(false) end
		if r.SetTexelSnappingBias then r:SetTexelSnappingBias(0) end
	end
	r:SetParent(panel)
	r:SetDrawLayer(layer, sub or 0)
	r:Show()
	table.insert(lab.used, { r, kind })
	panel.count = panel.count + 1
	return r
end

local function ReleaseAll()
	for _, u in ipairs(lab.used) do
		local r, kind = u[1], u[2]
		r:Hide()
		if kind == "quad" and r.ClearVertexOffsets then r:ClearVertexOffsets() end
		table.insert(lab.pools[kind], r)
	end
	lab.used = {}
	for _, panel in ipairs(lab.panels) do panel.count = 0 end
end

local function Line(panel, x1, y1, x2, y2, w, r, g, b, a, layer)
	local line = Acquire("line", panel, layer)
	line:SetColorTexture(r, g, b, a)
	line:SetThickness(w)
	line:SetStartPoint("BOTTOMLEFT", panel, x1, y1)
	line:SetEndPoint("BOTTOMLEFT", panel, x2, y2)
end

local function Dot(panel, x, y, size, r, g, b, a, layer)
	local dot = Acquire("dot", panel, layer)
	dot:SetTexture(ArtPad.MEDIA .. "dot")
	dot:SetTexCoord(0, 1, 0, 1)
	dot:SetVertexColor(r, g, b, a)
	dot:SetSize(size, size)
	dot:ClearAllPoints()
	dot:SetPoint("CENTER", panel, "BOTTOMLEFT", x, y)
end

-- The colour that stands out from an ink: pale under dark ink, dark under light ink.
local function Halo(r, g, b)
	if 0.299 * r + 0.587 * g + 0.114 * b < 0.4 then return 0.93, 0.86, 0.7, 0.55 end
	return 0.1, 0.07, 0.04, 0.55
end

--[[ 1. Today: straight Lines between the points ]]

local function DrawChords(panel, s)
	local p = s.raw or s.p
	for i = 1, #p - 3, 2 do
		Line(panel, p[i], p[i + 1], p[i + 2], p[i + 3], s.w, s.r, s.g, s.b, s.a, "ARTWORK")
	end
end

--[[ 2. Curves, round ends, outline: still Lines ]]

local function DrawCurve(panel, s)
	local pts = Curve(s.p)
	local function Pass(w, r, g, b, a, layer)
		for i = 1, #pts - 1 do
			Line(panel, pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2], w, r, g, b, a, layer)
		end
		-- round ends, and a round join where the curve was broken at a corner
		for i = 1, #pts do
			if i == 1 or i == #pts or pts[i][3] then Dot(panel, pts[i][1], pts[i][2], w, r, g, b, a, layer) end
		end
	end
	if lab.outline then
		local r, g, b, a = Halo(s.r, s.g, s.b)
		Pass(s.w + 3, r, g, b, a * s.a, "BORDER")
	end
	Pass(s.w, s.r, s.g, s.b, s.a, "ARTWORK")
end

--[[ 3. The welded ribbon ]]

-- Screen pixels per unit here: the soft edge is one screen pixel wide.
local function PixelsPerUnit()
	local _, h = GetPhysicalScreenSize()
	return lab.window:GetEffectiveScale() * (h or 768) / 768
end

-- One piece: a 2x2 texture at the stroke's anchor whose corners are moved to the four points.
-- L is the left rail, R the right; (wa, wb) the ink width at each end.
local function Quad(panel, ax, ay, lx1, ly1, rx1, ry1, lx2, ly2, rx2, ry2, wa, wb, r, g, b, a, layer)
	local q = Acquire("quad", panel, layer)
	q:SetSize(2, 2)
	q:ClearAllPoints()
	q:SetPoint("CENTER", panel, "BOTTOMLEFT", ax, ay)
	q:SetVertexOffset(1, lx1 - ax + 1, ly1 - ay - 1) -- upper left
	q:SetVertexOffset(2, rx1 - ax + 1, ry1 - ay + 1) -- lower left
	q:SetVertexOffset(3, lx2 - ax - 1, ly2 - ay - 1) -- upper right
	q:SetVertexOffset(4, rx2 - ax - 1, ry2 - ay + 1) -- lower right
	if lab.softEdge then
		-- distance from the right edge runs along u, from the left edge along v: the texture
		-- is transparent in its first column and first row, so both edges fade over one pixel
		local k = PixelsPerUnit()
		local near = (1 - 1) / EDGE_N -- (1 - k * pad), pad being one pixel
		local farA, farB = (1 + k * wa + 1) / EDGE_N, (1 + k * wb + 1) / EDGE_N
		q:SetTexture(EDGE, "CLAMP", "CLAMP", "LINEAR")
		q:SetTexCoord(farA, near, near, farA, farB, near, near, farB)
		q:SetVertexColor(r, g, b, a)
	else
		q:SetColorTexture(r, g, b, a)
	end
end

local function DrawRibbon(panel, s)
	if not lab.vertexOffsets then return end
	local pts = Curve(s.p)
	local n = #pts
	if n < 2 then return end
	-- how far along the stroke each point is, for the tapered ends
	local arc = { 0 }
	for i = 2, n do
		arc[i] = arc[i - 1] + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2)
	end
	local total = arc[n]
	local reach = math.min(total / 2, math.max(10, s.w * 3))
	local function WidthAt(i, base)
		if not lab.taper or reach <= 0 then return base end
		local t = math.min(1, math.min(arc[i], total - arc[i]) / reach)
		return base * (0.12 + 0.88 * t * (2 - t)) -- eased from a point to full width
	end
	local ax, ay = (pts[1][1] + pts[n][1]) / 2, (pts[1][2] + pts[n][2]) / 2 -- every piece hangs off this one spot
	local pad = lab.softEdge and 1 / PixelsPerUnit() or 0

	local function Pass(extra, r, g, b, a, layer)
		-- the rails: at each point, out along the mitre of the two pieces that meet there
		local L, R, cut, w = {}, {}, {}, {}
		for i = 1, n do
			w[i] = WidthAt(i, s.w) + extra
			local half = w[i] / 2 + pad
			local nx, ny
			local scale = 1
			local function Normal(j) -- of the piece from point j to j + 1
				local dx, dy = pts[j + 1][1] - pts[j][1], pts[j + 1][2] - pts[j][2]
				local len = math.sqrt(dx * dx + dy * dy)
				if len == 0 then return 0, 1 end
				return -dy / len, dx / len
			end
			if i == 1 then
				nx, ny = Normal(1)
			elseif i == n then
				nx, ny = Normal(n - 1)
			else
				local ax_, ay_ = Normal(i - 1)
				local bx, by = Normal(i)
				local mx, my = ax_ + bx, ay_ + by
				local len = math.sqrt(mx * mx + my * my)
				if len < 0.001 then
					nx, ny, cut[i] = ax_, ay_, true
				else
					mx, my = mx / len, my / len
					local c = mx * ax_ + my * ay_
					if c < 0.5 then -- a turn too sharp to mitre: end this run, start another
						nx, ny, cut[i] = ax_, ay_, true
					else
						nx, ny, scale = mx, my, 1 / c
					end
				end
			end
			L[i] = { pts[i][1] + nx * half * scale, pts[i][2] + ny * half * scale }
			R[i] = { pts[i][1] - nx * half * scale, pts[i][2] - ny * half * scale }
		end
		for i = 1, n - 1 do
			local l1, r1, l2, r2 = L[i], R[i], L[i + 1], R[i + 1]
			if cut[i] then
				-- after a cut the piece starts square to its own direction
				local dx, dy = pts[i + 1][1] - pts[i][1], pts[i + 1][2] - pts[i][2]
				local len = math.sqrt(dx * dx + dy * dy)
				if len > 0 then
					local half = w[i] / 2 + pad
					l1 = { pts[i][1] - dy / len * half, pts[i][2] + dx / len * half }
					r1 = { pts[i][1] + dy / len * half, pts[i][2] - dx / len * half }
				end
			end
			Quad(panel, ax, ay, l1[1], l1[2], r1[1], r1[2], l2[1], l2[2], r2[1], r2[2], w[i], w[i + 1], r, g, b, a, layer)
			if cut[i + 1] then Dot(panel, pts[i + 1][1], pts[i + 1][2], w[i + 1], r, g, b, a, layer) end
		end
		if not lab.taper then
			Dot(panel, pts[1][1], pts[1][2], w[1], r, g, b, a, layer)
			Dot(panel, pts[n][1], pts[n][2], w[n], r, g, b, a, layer)
		end
	end
	if lab.outline then
		local r, g, b, a = Halo(s.r, s.g, s.b)
		Pass(3, r, g, b, a * s.a, "BORDER")
	end
	Pass(0, s.r, s.g, s.b, s.a, "ARTWORK")
end

--[[ The sample drawing, and the window ]]

local function Samples()
	local out = {}
	local function Add(w, r, g, b, a, p) out[#out + 1] = { w = w, r = r, g = g, b = b, a = a, p = p } end
	local p = {} -- a slow wave
	for i = 0, 8 do p[#p + 1], p[#p + 2] = 30 + i * 40, 372 + 26 * math.sin(i * 1.3) end
	Add(10, 0.85, 0.15, 0.12, 1, p)
	Add(6, 0.1, 0.08, 0.06, 1, { 30, 315, 80, 275, 130, 320, 180, 270, 230, 315, 280, 273, 340, 310 }) -- sharp corners
	p = {} -- a spiral in see-through ink
	for t = 0, 12.5, 0.5 do p[#p + 1], p[#p + 2] = 110 + (10 + 5.5 * t) * math.cos(t), 195 + (10 + 5.5 * t) * math.sin(t) end
	Add(14, 0.2, 0.5, 1, 0.5, p)
	p = {} -- a figure of eight that crosses itself
	for t = 0, 6.3, 0.35 do p[#p + 1], p[#p + 2] = 290 + 58 * math.sin(t), 195 + 38 * math.sin(2 * t) end
	Add(12, 0.2, 0.8, 0.3, 0.5, p)
	p = {} -- thin handwriting-like loops, on the dark band
	for x = 30, 200, 8 do p[#p + 1], p[#p + 2] = x, 92 + 15 * math.sin(x / 8.5) end
	Add(2, 1, 1, 1, 1, p)
	p = {} -- dark ink on the dark band
	for t = 0, 3.2, 0.4 do p[#p + 1], p[#p + 2] = 285 + 60 * math.cos(t), 45 + 55 * math.sin(t) end
	Add(5, 0.1, 0.08, 0.06, 1, p)
	Add(8, 1, 0.8, 0.16, 1, { 30, 28, 90, 60, 150, 22, 200, 52 })
	return out
end

local RENDER = { DrawChords, DrawCurve, DrawRibbon }

function ArtPad:BrushLabRedraw()
	ReleaseAll()
	for i, panel in ipairs(lab.panels) do
		for _, s in ipairs(lab.samples) do RENDER[i](panel, s) end
		for _, s in ipairs(lab.strokes) do RENDER[i](panel, s) end
		if lab.live then RENDER[i](panel, lab.live) end
		panel.info:SetText(("%d pieces"):format(panel.count))
	end
end

-- Where the cursor is in a panel's own coordinates.
local function Cursor(panel)
	local x, y = GetCursorPosition()
	local scale = panel:GetEffectiveScale()
	return x / scale - panel:GetLeft(), y / scale - panel:GetBottom()
end

local function BuildPanel(self, window, index, title, note)
	local panel = CreateFrame("Frame", "ArtPad_LabPanel" .. index, window)
	panel:SetSize(PANEL_W, PANEL_H)
	panel:SetPoint("TOPLEFT", GAP + (index - 1) * (PANEL_W + GAP), -34)
	panel.count = 0
	local paper = panel:CreateTexture(nil, "BACKGROUND")
	paper:SetAllPoints()
	paper:SetColorTexture(0.78, 0.68, 0.47, 1) -- about the colour of the map's parchment
	local dark = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
	dark:SetPoint("BOTTOMLEFT")
	dark:SetPoint("BOTTOMRIGHT")
	dark:SetHeight(DARK_H)
	dark:SetColorTexture(0.11, 0.1, 0.09, 1)
	local name = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	name:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", 2, 5)
	name:SetText(title)
	panel.info = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	panel.info:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -2, 6)
	panel.note = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	panel.note:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 2, -5)
	panel.note:SetWidth(PANEL_W - 4)
	panel.note:SetHeight(12)
	panel.note:SetJustifyH("LEFT")
	if panel.note.SetWordWrap then panel.note:SetWordWrap(false) end
	panel.note:SetText(note)

	-- drawing in any panel draws in all of them
	panel:EnableMouse(true)
	panel:SetScript("OnMouseDown", function(_, button)
		if button ~= "LeftButton" then return end
		local x, y = Cursor(panel)
		local c = self.brushColor
		lab.pen = { panel = panel, x = x, y = y }
		lab.live = { w = math.max(1, ArtPad_Settings.BrushSize), r = c.r, g = c.g, b = c.b, a = c.a, p = { x, y }, raw = { x, y } }
	end)
	panel:SetScript("OnMouseUp", function()
		local s = lab.live
		lab.pen, lab.live = nil, nil
		if not s then return end
		if #s.raw >= 4 then
			-- the pen catches up with the cursor, then both paths are thinned as shared strokes are
			local n = #s.raw
			s.p[#s.p + 1], s.p[#s.p + 2] = s.raw[n - 1], s.raw[n]
			s.p, s.raw = Thin(s.p, THIN), Thin(s.raw, THIN)
			table.insert(lab.strokes, s)
		end
		self:BrushLabRedraw()
	end)
	panel:SetScript("OnUpdate", function()
		local pen, s = lab.pen, lab.live
		if not pen or pen.panel ~= panel or not s then return end
		local x, y = Cursor(panel)
		local raw = s.raw
		local dx, dy = x - raw[#raw - 1], y - raw[#raw]
		if dx * dx + dy * dy < MIN_STEP * MIN_STEP then return end
		raw[#raw + 1], raw[#raw + 2] = x, y
		-- the steadied pen: it is dragged on a short string, and only moves when the string is taut
		local sx, sy = x - pen.x, y - pen.y
		local d = math.sqrt(sx * sx + sy * sy)
		if d > STRING then
			pen.x, pen.y = x - sx / d * STRING, y - sy / d * STRING
			s.p[#s.p + 1], s.p[#s.p + 2] = pen.x, pen.y
		end
		self:BrushLabRedraw()
	end)
	return panel
end

function ArtPad:BrushLab(which)
	if which == "tests" then
		self:BrushLabTests() -- page two: the experiments (below)
		return
	end
	if lab.window then
		lab.window:SetShown(not lab.window:IsShown())
		return
	end
	local window = CreateFrame("Frame", "ArtPad_BrushLab", UIParent)
	lab.window = window
	window:SetSize(GAP + 3 * (PANEL_W + GAP), PANEL_H + 34 + 82)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	local bg = window:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.06, 0.06, 0.07, 0.97)

	-- what this client can do
	local probe = window:CreateTexture()
	lab.vertexOffsets = probe.SetVertexOffset ~= nil and pcall(probe.SetVertexOffset, probe, 1, 0, 0) or false
	-- (the soft edge needs lab_edge.tga, which the game only finds after a full restart)
	lab.softEdge = lab.vertexOffsets and probe:SetTexture(EDGE) == true
		and pcall(probe.SetTexCoord, probe, 0, 0, 0, 1, 1, 0, 1, 1) or false
	probe:Hide()

	lab.panels = {
		BuildPanel(self, window, 1, "1. Today (world map)", "Straight pieces between the points. No ends, no joins."),
		BuildPanel(self, window, 2, "2. Curves, round ends, outline", "Curved through the same points. Still separate pieces."),
		BuildPanel(self, window, 3, "3. Welded ribbon, soft edges",
			lab.vertexOffsets and (lab.softEdge and "Pieces share their edges. Edges fade over one pixel." or "Pieces share their edges. (Soft edges after a game restart.)")
				or "This client can't move a texture's corners: nothing to show."),
	}
	lab.samples = Samples()

	local function Button(label, x, onClick)
		local b = self:FlatButton(window, nil, 110, 22, label, onClick)
		b:SetPoint("BOTTOMLEFT", x, 10)
		return b
	end
	local outline, taper
	outline = Button("Outline: On", GAP, function()
		lab.outline = not lab.outline
		outline.label:SetText(lab.outline and "Outline: On" or "Outline: Off")
		self:BrushLabRedraw()
	end)
	taper = Button("Tapered ends: On", GAP + 116, function()
		lab.taper = not lab.taper
		taper.label:SetText(lab.taper and "Tapered ends: On" or "Tapered ends: Off")
		self:BrushLabRedraw()
	end)
	taper:SetWidth(140)
	Button("Clear mine", GAP + 262, function()
		lab.strokes = {}
		self:BrushLabRedraw()
	end)
	local close = self:FlatButton(window, "ArtPad_LabClose", 80, 22, "Close", function() window:Hide() end)
	close:SetPoint("BOTTOMRIGHT", -GAP, 10)
	local tests = self:FlatButton(window, "ArtPad_LabOpenTests", 100, 22, "Experiments", function() self:BrushLabTests() end)
	tests:SetPoint("RIGHT", close, "LEFT", -6, 0)
	local hint = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hint:SetPoint("BOTTOMLEFT", GAP, 40)
	hint:SetWidth(window:GetWidth() - 2 * GAP)
	hint:SetHeight(12)
	hint:SetJustifyH("LEFT")
	if hint.SetWordWrap then hint:SetWordWrap(false) end
	hint:SetText("Draw in any panel to see your stroke all three ways. Colour and size follow ArtPad's brush.")
	-- shrink to fit the screen whatever the interface scale is
	local w, h = UIParent:GetWidth() or 1365, UIParent:GetHeight() or 768
	window:SetScale(math.min(1, (w - 20) / window:GetWidth(), (h - 20) / window:GetHeight()))

	self:BrushLabRedraw()
end
end

--[[
	Brush lab, page two (hidden: /ap lab tests): twelve small experiments, one per panel, each
	answering a question about this client that the stroke research could not settle from the
	documentation. Every panel says what a good result looks like. The three with buttons make
	thousands of regions and clear themselves after ten seconds, because past the client's limit
	everything on screen stops being drawn.
]]

do
local T = { panels = {}, stress = {}, generation = 0 }
ArtPad.brushLabTests = T

-- A panel, top to bottom: title (one line), the drawing (clipped to its box), a row for
-- buttons, the result (one line), and what a good result looks like (up to three lines).
local COLS, PW, GAP = 4, 292, 8
local TITLE_H, BODY_H, BUTTON_H, RESULT_H, GOOD_H = 13, 152, 18, 13, 37
local PH = 3 + TITLE_H + 2 + BODY_H + 3 + BUTTON_H + 2 + RESULT_H + 1 + GOOD_H + 3

-- A line of text that keeps to its own row: fixed width, never wraps (it is cut short instead).
local function OneLine(fs, width)
	fs:SetWidth(width)
	fs:SetHeight(12)
	fs:SetJustifyH("LEFT")
	if fs.SetWordWrap then fs:SetWordWrap(false) end
end

-- Shrink a window so that it fits on the screen whatever the interface scale is.
local function FitToScreen(window)
	local w, h = UIParent:GetWidth() or 1365, UIParent:GetHeight() or 768
	local fit = math.min(1, (w - 20) / window:GetWidth(), (h - 20) / window:GetHeight())
	window:SetScale(fit)
	return fit
end
local EDGE, BANDS = ArtPad.MEDIA .. "lab_edge", ArtPad.MEDIA .. "lab_bands"
local EDGE_N = 64
-- lab_bands.tga: 16 x 256, one band per core width; each band is a clear row, n solid rows, a clear row
local BAND_N = { 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64 }
local BAND_Y = { 0, 3, 7, 12, 18, 26, 36, 50, 68, 94, 128, 178 }

local function PixelsPerUnit(frame)
	local _, h = GetPhysicalScreenSize()
	return frame:GetEffectiveScale() * (h or 768) / 768
end

local function NewLine(parent, x1, y1, x2, y2, w, r, g, b, a, layer)
	local line = parent:CreateLine(nil, layer or "ARTWORK")
	if line.SetSnapToPixelGrid then line:SetSnapToPixelGrid(false) end
	if line.SetTexelSnappingBias then line:SetTexelSnappingBias(0) end
	line:SetColorTexture(r, g, b, a or 1)
	line:SetThickness(w)
	line:SetStartPoint("BOTTOMLEFT", parent, x1, y1)
	line:SetEndPoint("BOTTOMLEFT", parent, x2, y2)
	return line
end

-- A texture whose corners are moved to four points (upper left, lower left, upper right, lower
-- right), given in `parent`'s own coordinates; its 2x2 base sits at (ax, ay).
local function NewQuad(parent, ax, ay, ul, ll, ur, lr, r, g, b, a)
	local q = parent:CreateTexture(nil, "ARTWORK")
	if q.SetSnapToPixelGrid then q:SetSnapToPixelGrid(false) end
	if q.SetTexelSnappingBias then q:SetTexelSnappingBias(0) end
	q:SetColorTexture(r, g, b, a or 1)
	q:SetSize(2, 2)
	q:SetPoint("CENTER", parent, "BOTTOMLEFT", ax, ay)
	q:SetVertexOffset(1, ul[1] - ax + 1, ul[2] - ay - 1)
	q:SetVertexOffset(2, ll[1] - ax + 1, ll[2] - ay + 1)
	q:SetVertexOffset(3, ur[1] - ax - 1, ur[2] - ay - 1)
	q:SetVertexOffset(4, lr[1] - ax - 1, lr[2] - ay + 1)
	return q
end

local function Label(panel, x, y, text)
	local fs = panel.body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	fs:SetPoint("BOTTOMLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function Paint(panel, r, g, b)
	panel.bodyBg:SetColorTexture(r, g, b, 1)
end
local function Parchment(panel) Paint(panel, 0.78, 0.68, 0.47) end

local function YesNo(v) return v and "|cff66dd66yes|r" or "|cffff7766no|r" end

--[[ The three heavy ones: thousands of tiny regions, cleared after ten seconds ]]

local function StressClear()
	for _, s in pairs(T.stress) do
		for i = 1, s.shown do s.regions[i]:Hide() end
		s.shown = 0
	end
	for _, panel in ipairs(T.panels) do
		if panel.stressText then panel.result:SetText(panel.stressText()) end
	end
end

-- Show `n` more regions of `kind` ("line" or "quad") in a grid over `panel`'s body, spread
-- over `frames` child frames (off-screen buffers if `buffered`).
local function StressAdd(panel, key, kind, n, frames, buffered)
	local s = T.stress[key]
	if not s then
		s = { regions = {}, shown = 0, frames = {} }
		T.stress[key] = s
		for f = 1, frames do
			local frame = CreateFrame("Frame", nil, panel.body)
			frame:SetAllPoints()
			if buffered then
				frame:SetFlattensRenderLayers(true)
				frame:SetIsFrameBuffer(true)
			end
			s.frames[f] = frame
		end
	end
	local cols = 186
	local start = debugprofilestop()
	for i = s.shown + 1, s.shown + n do
		local region = s.regions[i]
		if not region then
			local frame = s.frames[(i - 1) % frames + 1]
			local x, y = ((i - 1) % cols) * 1.5 + 4, math.floor((i - 1) / cols) % 96 * 1.5 + 4
			if kind == "line" then
				region = NewLine(frame, x, y, x + 1.1, y + 0.6, 1, 0.1, 0.08, 0.06, 1)
			else
				region = NewQuad(frame, 140, 70, { x, y + 1 }, { x, y }, { x + 1.1, y + 1.3 }, { x + 1.1, y + 0.2 }, 0.1, 0.25, 0.6, 1)
			end
			s.regions[i] = region
		end
		region:Show()
	end
	s.shown = s.shown + n
	s.ms = debugprofilestop() - start
	T.generation = T.generation + 1
	local generation = T.generation
	C_Timer.After(10, function()
		if T.generation == generation then StressClear() end
	end)
	return s
end

local function Shown(key) return T.stress[key] and T.stress[key].shown or 0 end

local function Button(panel, label, x, width, onClick)
	local b = ArtPad:FlatButton(panel, nil, width, 18, label, onClick)
	b:SetPoint("TOPLEFT", panel.body, "BOTTOMLEFT", x, -3)
	b:SetFrameLevel(panel:GetFrameLevel() + 5)
	panel.buttons = panel.buttons or {}
	panel.buttons[label] = b
	return b
end

-- A buffered frame that belongs to the screen (UIParent) and is laid over a rectangle of a
-- panel's box. In game this is the one arrangement that drew in the right place: buffers
-- inside the (scaled, clipped) lab window drew their contents tiny and displaced.
local function ScreenBuffer(panel, x, y, w, h)
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetFrameLevel(panel:GetFrameLevel() + 10)
	-- (In game, changing the window's scale left such a buffer where it had been: it is put
	-- in place again whenever the window is scaled or moved.)
	local function Place()
		f:ClearAllPoints()
		f:SetPoint("BOTTOMLEFT", panel.body, "BOTTOMLEFT", x, y)
		f:SetPoint("TOPRIGHT", panel.body, "BOTTOMLEFT", x + w, y + h)
	end
	Place()
	T.replace = T.replace or {}
	table.insert(T.replace, Place)
	f:SetFlattensRenderLayers(true)
	f:SetIsFrameBuffer(true)
	panel:HookScript("OnHide", function() f:Hide() end)
	panel:HookScript("OnShow", function() f:Show() end)
	return f
end

--[[ The experiments ]]

local TESTS = {
	{
		title = "1. Where is the limit? How fast are pieces?",
		good = "With ArtPad and a drawn-on world map open, add until something vanishes: what, and at what count? Good: 6,000 pieces in under 100 ms.",
		build = function(panel)
			Parchment(panel)
			panel.stressText = function()
				local function Ms(key)
					local s = T.stress[key]
					return s and s.ms and (" (%.0f ms)"):format(s.ms) or ""
				end
				return ("%d lines%s, %d pieces%s"):format(Shown("limit"), Ms("limit"), Shown("pieces"), Ms("pieces"))
			end
			Button(panel, "+4,000 lines", 0, 90, function()
				StressAdd(panel, "limit", "line", 4000, 1)
				panel.result:SetText(panel.stressText())
			end)
			Button(panel, "+6,000 pieces", 94, 96, function()
				StressAdd(panel, "pieces", "quad", 6000, 1)
				panel.result:SetText(panel.stressText())
			end)
			Button(panel, "Clear", 194, 50, StressClear)
			return panel.stressText()
		end,
	},
	{
		-- First answer (in game): 18,000 lines across two buffered frames stayed on screen.
		title = "2. How much can off-screen buffers hold?",
		good = "Plain should vanish. Good if each buffered one stays, and the frame rate (shown after two seconds) holds up.",
		build = function(panel)
			Parchment(panel)
			local last = ""
			panel.stressText = function()
				local n = Shown("plain") + Shown("two") + Shown("one") + Shown("three")
				return n > 0 and ("%d lines%s"):format(n, last) or "nothing shown"
			end
			local function Run(key, n, frames, buffered)
				StressClear()
				last = ""
				StressAdd(panel, key, "line", n, frames, buffered)
				panel.result:SetText(panel.stressText())
				C_Timer.After(2, function()
					if Shown(key) > 0 then
						last = (", %.0f frames a second"):format(GetFramerate())
						panel.result:SetText(panel.stressText())
					end
				end)
			end
			Button(panel, "Plain 18k", 0, 62, function() Run("plain", 18000, 2, false) end)
			Button(panel, "2 buffers 18k", 65, 78, function() Run("two", 18000, 2, true) end)
			Button(panel, "1 buffer 18k", 146, 72, function() Run("one", 18000, 1, true) end)
			Button(panel, "3 x 15k", 221, 52, function() Run("three", 45000, 3, true) end)
			return panel.stressText()
		end,
	},
	{
		title = "3. Are plain lines jagged?",
		good = "Look closely with the game's anti-aliasing off, then on. Jagged when off: soft edges are worth it.",
		build = function(panel)
			Parchment(panel)
			for i = 0, 17 do
				local a = math.rad(i * 5)
				NewLine(panel.body, 8, 6, 8 + 128 * math.cos(a), 6 + 128 * math.sin(a), 1.5, 0.1, 0.08, 0.06)
				NewLine(panel.body, 150, 6, 150 + 128 * math.cos(a), 6 + 128 * math.sin(a), 5, 0.1, 0.08, 0.06)
			end
			return "left 1.5 wide, right 5 wide"
		end,
	},
	{
		title = "4. Soft-edge strip on a plain line",
		good = "Good if the right column has soft edges on both sides and the same widths as the left.",
		build = function(panel)
			Parchment(panel)
			local probe = panel.body:CreateTexture()
			local found = probe:SetTexture(BANDS) == true
			probe:Hide()
			local k = PixelsPerUnit(panel)
			local y = 6
			for _, w in ipairs({ 1, 2, 3, 5, 8, 12, 20 }) do
				y = y + w / 2
				NewLine(panel.body, 8, y, 8 + 118, y + 22, w, 0.1, 0.08, 0.06)
				local line = NewLine(panel.body, 150, y, 150 + 118, y + 22, w, 0.1, 0.08, 0.06)
				if found then
					local best = 1
					for i, n in ipairs(BAND_N) do
						if math.abs(math.log(n / (w * k))) < math.abs(math.log(BAND_N[best] / (w * k))) then best = i end
					end
					local n, y0 = BAND_N[best], BAND_Y[best]
					line:SetTexture(BANDS, "CLAMP", "CLAMP", "LINEAR")
					line:SetTexCoord(0.5, 0.5, (y0 + 0.5) / 256, (y0 + n + 1.5) / 256)
					line:SetVertexColor(0.1, 0.08, 0.06, 1)
					line:SetThickness(w * (n + 1) / n)
				end
				y = y + w / 2 + 6
			end
			return found and "left plain, right with the strip" or "strip texture not found yet: restart the game once"
		end,
	},
	{
		title = "5. Which stroke ends up on top?",
		good = "Blue is drawn last in all three. Good if blue is on top in all three.",
		build = function(panel)
			Parchment(panel)
			local body = panel.body
			local function Cross(x, red, blue)
				red(x)
				blue(x)
			end
			local function Red(x) return NewLine(body, x, 30, x + 70, 110, 14, 0.85, 0.15, 0.12) end
			local function Blue(x) return NewLine(body, x, 110, x + 70, 30, 14, 0.2, 0.4, 1) end
			Cross(12, Red, Blue) -- plain over plain
			Cross(108, Red, function(x) -- a textured line over a plain one
				local line = Blue(x)
				line:SetTexture(ArtPad.MEDIA .. "dot")
				line:SetVertexColor(0.2, 0.4, 1, 1)
			end)
			-- a region made earlier (as when one is reused), but set up as the newer stroke
			local early = body:CreateLine(nil, "ARTWORK")
			Red(204)
			early:SetColorTexture(0.2, 0.4, 1, 1)
			early:SetThickness(14)
			early:SetStartPoint("BOTTOMLEFT", body, 204, 110)
			early:SetEndPoint("BOTTOMLEFT", body, 274, 30)
			Label(panel, 14, 4, "plain")
			Label(panel, 104, 4, "blue textured")
			Label(panel, 200, 4, "blue reused")
			return ""
		end,
	},
	{
		title = "6. Is a ribbon piece clipped by its corners?",
		good = "Good if the left box shows a green block, and the right block stops at the box's edge.",
		build = function(panel)
			Paint(panel, 0.11, 0.1, 0.09)
			local function Box(x)
				local box = CreateFrame("Frame", nil, panel.body)
				box:SetSize(110, 100)
				box:SetPoint("BOTTOMLEFT", x, 22)
				box:SetClipsChildren(true)
				local bg = box:CreateTexture(nil, "BACKGROUND")
				bg:SetAllPoints()
				bg:SetColorTexture(0.25, 0.24, 0.22, 1)
				return box
			end
			-- its base far outside the box, its corners inside
			NewQuad(Box(16), 400, 50, { 20, 80 }, { 20, 20 }, { 90, 80 }, { 90, 20 }, 0.3, 0.85, 0.35)
			-- its base inside the box, its corners running out of it
			NewQuad(Box(156), 30, 50, { 20, 80 }, { 20, 20 }, { 220, 80 }, { 220, 20 }, 0.3, 0.85, 0.35)
			Label(panel, 16, 6, "base outside")
			Label(panel, 156, 6, "corners outside")
			return ""
		end,
	},
	{
		title = "7. Do welded pieces show a seam?",
		good = "Good if no lighter or darker hairline shows where pieces meet. Try the Scale button and drag the window.",
		build = function(panel)
			Paint(panel, 0.11, 0.1, 0.09)
			local body = panel.body
			-- two pieces sharing an upright edge, two sharing a slanted one
			NewQuad(body, 50, 100, { 12, 130 }, { 12, 90 }, { 60, 130 }, { 60, 90 }, 1, 1, 1, 0.5)
			NewQuad(body, 50, 100, { 60, 130 }, { 60, 90 }, { 108, 130 }, { 108, 90 }, 1, 1, 1, 0.5)
			NewQuad(body, 190, 100, { 150, 132 }, { 150, 92 }, { 207.3, 129.1 }, { 189.7, 91.4 }, 1, 1, 1, 0.5)
			NewQuad(body, 190, 100, { 207.3, 129.1 }, { 189.7, 91.4 }, { 262, 128 }, { 262, 88 }, 1, 1, 1, 0.5)
			-- a zigzag ribbon, mitred, of changing width
			local pts = { { 14, 30 }, { 62, 62 }, { 110, 26 }, { 160, 66 }, { 210, 24 }, { 270, 58 } }
			local w = { 10, 16, 8, 18, 12, 6 }
			local L, R = {}, {}
			for i, p in ipairs(pts) do
				local function Normal(j)
					local dx, dy = pts[j + 1][1] - pts[j][1], pts[j + 1][2] - pts[j][2]
					local len = math.sqrt(dx * dx + dy * dy)
					return -dy / len, dx / len
				end
				local nx, ny, scale
				if i == 1 then
					nx, ny, scale = Normal(1)
				elseif i == #pts then
					nx, ny, scale = Normal(i - 1)
				else
					local ax, ay = Normal(i - 1)
					local bx, by = Normal(i)
					local len = math.sqrt((ax + bx) ^ 2 + (ay + by) ^ 2)
					nx, ny = (ax + bx) / len, (ay + by) / len
					scale = 1 / (nx * ax + ny * ay)
				end
				local half = w[i] / 2 * (scale or 1)
				L[i], R[i] = { p[1] + nx * half, p[2] + ny * half }, { p[1] - nx * half, p[2] - ny * half }
			end
			for i = 1, #pts - 1 do
				NewQuad(body, 140, 45, L[i], R[i], L[i + 1], R[i + 1], 0.3, 0.85, 1, 0.5)
			end
			return "all at half opacity"
		end,
	},
	{
		-- (Baking was the question here: OffScreenFrame:TakeSnapshot() is protected, so no. It is
		-- not called any more: the game counts each attempt against the addon.)
		-- In game: a buffer owned by the screen drew right; buffers inside this window drew tiny
		-- and displaced. These six cells separate the possible reasons.
		title = "8. Which buffers draw in the right place?",
		good = "Right = green fills the black outline and the red corner is top right. Which letters are right? Also read me the result line.",
		build = function(panel)
			Parchment(panel)
			local body = panel.body
			local SIZE = 40
			local function Flags(f)
				f:SetFlattensRenderLayers(true)
				f:SetIsFrameBuffer(true)
			end
			-- what goes in each buffer: a green square of a stated size with a red top-right corner
			local function Stated(f)
				local g = f:CreateTexture(nil, "ARTWORK")
				g:SetColorTexture(0.2, 0.75, 0.3, 1)
				g:SetSize(SIZE, SIZE)
				g:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
				local r = f:CreateTexture(nil, "OVERLAY")
				r:SetColorTexture(0.9, 0.15, 0.1, 1)
				r:SetSize(10, 10)
				r:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", SIZE - 10, SIZE - 10)
			end
			-- ...or the same thing sized by the buffer itself
			local function Fitted(f)
				local g = f:CreateTexture(nil, "ARTWORK")
				g:SetColorTexture(0.2, 0.75, 0.3, 1)
				g:SetAllPoints()
				local r = f:CreateTexture(nil, "OVERLAY")
				r:SetColorTexture(0.9, 0.15, 0.1, 1)
				r:SetPoint("TOPRIGHT")
				r:SetPoint("BOTTOMLEFT", f, "CENTER", SIZE / 4, SIZE / 4)
			end
			local function Cell(i, name)
				local x, y = 22 + ((i - 1) % 3) * 92, i <= 3 and 96 or 22
				NewLine(body, x - 1, y - 1, x + SIZE + 1, y - 1, 1, 0, 0, 0)
				NewLine(body, x - 1, y + SIZE + 1, x + SIZE + 1, y + SIZE + 1, 1, 0, 0, 0)
				NewLine(body, x - 1, y - 1, x - 1, y + SIZE + 1, 1, 0, 0, 0)
				NewLine(body, x + SIZE + 1, y - 1, x + SIZE + 1, y + SIZE + 1, 1, 0, 0, 0)
				Label(panel, x - 14, y - 15, name)
				return x, y
			end
			local function Inside(parent, x, y)
				local f = CreateFrame("Frame", nil, parent)
				f:SetSize(SIZE, SIZE)
				f:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", x, y)
				f:SetFrameLevel(panel:GetFrameLevel() + 10)
				return f
			end
			local x, y
			x, y = Cell(1, "a screen, fitted") -- the arrangement that worked
			Fitted(ScreenBuffer(panel, x, y, SIZE, SIZE))
			x, y = Cell(2, "b screen, stated")
			Stated(ScreenBuffer(panel, x, y, SIZE, SIZE))
			x, y = Cell(3, "c window, stated") -- in the scaled window, outside the clipped box
			local c = Inside(T.window, x, y)
			Flags(c)
			Stated(c)
			x, y = Cell(4, "d box, stated") -- in the scaled window and the clipped box (what failed)
			local d = Inside(body, x, y)
			Flags(d)
			Stated(d)
			x, y = Cell(5, "e box, fitted")
			local e = Inside(body, x, y)
			Flags(e)
			Fitted(e)
			x, y = Cell(6, "f box, late") -- made a buffer only after it has been drawn once
			local f = Inside(body, x, y)
			Stated(f)
			C_Timer.After(0.5, function() Flags(f) end)
			panel.describe = function()
				return ("scales: screen %.3f, window %.3f"):format(UIParent:GetEffectiveScale(), T.window:GetEffectiveScale())
			end
			return panel.describe()
		end,
	},
	{
		title = "9. One-pixel soft edge from a corner texture",
		good = "Good if every long side fades over about one pixel, with no grey fringe and no hard side.",
		build = function(panel)
			Paint(panel, 0.11, 0.1, 0.09)
			local body = panel.body
			local probe = body:CreateTexture()
			local found = probe:SetTexture(EDGE) == true
			probe:Hide()
			if not found then return "edge texture not found yet: restart the game once" end
			local k = PixelsPerUnit(panel)
			local pad = 1 / k
			-- a piece from (x1, y1) to (x2, y2) of width wa at its start and wb at its end
			local function Piece(x1, y1, x2, y2, wa, wb)
				local dx, dy = x2 - x1, y2 - y1
				local len = math.sqrt(dx * dx + dy * dy)
				local nx, ny = -dy / len, dx / len
				local ha, hb = wa / 2 + pad, wb / 2 + pad
				local q = NewQuad(body, (x1 + x2) / 2, (y1 + y2) / 2,
					{ x1 + nx * ha, y1 + ny * ha }, { x1 - nx * ha, y1 - ny * ha },
					{ x2 + nx * hb, y2 + ny * hb }, { x2 - nx * hb, y2 - ny * hb }, 1, 1, 1, 1)
				local farA, farB = (2 + k * wa) / EDGE_N, (2 + k * wb) / EDGE_N
				q:SetTexture(EDGE, "CLAMP", "CLAMP", "LINEAR")
				q:SetTexCoord(farA, 0, 0, farA, farB, 0, 0, farB)
				q:SetVertexColor(1, 1, 1, 1)
			end
			Piece(20, 122, 220, 122, 38, 38) -- level
			Piece(20, 62, 220, 92, 20, 20) -- slanted
			Piece(20, 22, 220, 30, 24, 3) -- narrowing
			Piece(240, 20, 262, 140, 2, 2) -- thin and steep
			return "level, slanted, narrowing, thin"
		end,
	},
	{
		title = "10. Colour and pattern along a piece",
		good = "Good if colour runs red to blue along the top pair, still does under the green tint, and the bottom pair is rows of dots.",
		build = function(panel)
			Parchment(panel)
			local body = panel.body
			local red, blue = CreateColor(1, 0.1, 0.1, 1), CreateColor(0.1, 0.2, 1, 1)
			local function Shapes(y)
				return NewLine(body, 14, y, 124, y + 24, 12, 1, 1, 1),
					NewQuad(body, 210, y + 15, { 160, y + 30 }, { 150, y + 2 }, { 270, y + 34 }, { 262, y + 16 }, 1, 1, 1)
			end
			local function Pair(y, tint)
				local line, quad = Shapes(y)
				local okLine = pcall(line.SetGradient, line, "HORIZONTAL", red, blue)
				local okQuad = pcall(quad.SetGradient, quad, "HORIZONTAL", red, blue)
				if tint then
					line:SetVertexColor(0.4, 1, 0.4, 1)
					quad:SetVertexColor(0.4, 1, 0.4, 1)
				end
				return okLine, okQuad
			end
			local okLine, okQuad = Pair(108, false)
			Pair(60, true)
			-- a texture repeated along the length: dotted or dashed ink in the same single piece
			local line, quad = Shapes(10)
			local okPattern = pcall(function()
				line:SetTexture(ArtPad.MEDIA .. "dot", "REPEAT", "CLAMP")
				line:SetTexCoord(0, 9, 0, 1)
				line:SetVertexColor(0.1, 0.08, 0.06, 1)
				quad:SetTexture(ArtPad.MEDIA .. "dot", "REPEAT", "CLAMP")
				quad:SetTexCoord(0, 0, 0, 1, 9, 0, 9, 1)
				quad:SetVertexColor(0.1, 0.08, 0.06, 1)
			end)
			return ("gradient: line %s, piece %s. pattern: %s"):format(YesNo(okLine), YesNo(okQuad), YesNo(okPattern))
		end,
	},
	{
		-- The first buffered cross came out smaller and fainter: it sat inside this window, where
		-- buffers draw at the wrong size. These buffers belong to the screen, which works.
		title = "11. Does a buffer keep its opacity?",
		good = "Top: is B as bright as A, and D as bright as C? Bottom: the left crossing is brighter than its arms. Good if the right cross is one even grey.",
		build = function(panel)
			Paint(panel, 0.11, 0.1, 0.09)
			local body = panel.body
			local function Plain(x, alpha)
				local t = body:CreateTexture(nil, "ARTWORK")
				t:SetColorTexture(1, 1, 1, alpha)
				t:SetSize(40, 40)
				t:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", x, 100)
			end
			local function Buffered(x, alpha)
				local f = ScreenBuffer(panel, x, 100, 40, 40)
				local t = f:CreateTexture(nil, "ARTWORK")
				t:SetColorTexture(1, 1, 1, 1)
				t:SetAllPoints()
				f:SetAlpha(alpha)
			end
			Plain(14, 0.4)
			Buffered(78, 0.4)
			Plain(158, 1)
			Buffered(222, 1)
			Label(panel, 14, 86, "A plain 40%")
			Label(panel, 78, 86, "B buffer 40%")
			Label(panel, 158, 86, "C plain")
			Label(panel, 222, 86, "D buffer")
			-- two crosses at 40%: drawn plainly, and drawn solid in a buffer that is then faded as one
			NewLine(body, 24, 10, 114, 70, 16, 1, 1, 1, 0.4)
			NewLine(body, 24, 70, 114, 10, 16, 1, 1, 1, 0.4)
			local cross = ScreenBuffer(panel, 160, 6, 100, 68)
			cross:SetAlpha(0.4)
			for _, ends in ipairs({ { "BOTTOMLEFT", "TOPRIGHT" }, { "TOPLEFT", "BOTTOMRIGHT" } }) do
				local line = cross:CreateLine(nil, "ARTWORK")
				line:SetColorTexture(1, 1, 1, 1)
				line:SetThickness(16)
				line:SetStartPoint(ends[1], cross, 0, 0)
				line:SetEndPoint(ends[2], cross, 0, 0)
			end
			return ""
		end,
	},
	{
		title = "12. Does this client have...",
		good = "Nothing to look at: these are yes or no. Tell me the answers.",
		build = function(panel)
			Paint(panel, 0.11, 0.1, 0.09)
			local body = panel.body
			local line, tex = body:CreateLine(), body:CreateTexture()
			local rows = {
				{ "corners of a texture can be moved", tex.SetVertexOffset ~= nil and pcall(tex.SetVertexOffset, tex, 1, 0, 0) },
				{ "corners of a line can be moved", line.SetVertexOffset ~= nil and pcall(line.SetVertexOffset, line, 1, 0, 0) },
				{ "eight-number texture coordinates", pcall(tex.SetTexCoord, tex, 0, 0, 0, 1, 1, 0, 1, 1) },
				{ "the same on a line", pcall(line.SetTexCoord, line, 0, 0, 0, 1, 1, 0, 1, 1) },
				{ "coordinates outside 0 to 1 on a line", pcall(line.SetTexCoord, line, -0.5, 1.5, 0, 1) },
				{ "a line that animates its length", pcall(function() return line:CreateAnimationGroup():CreateAnimation("LineScale") end) },
				{ "vector (SVG) textures", tex.SetSVG ~= nil },
				{ "off-screen buffers on frames", body.SetIsFrameBuffer ~= nil and body.SetFlattensRenderLayers ~= nil },
			}
			line:Hide()
			tex:Hide()
			local text = {}
			for i, row in ipairs(rows) do text[i] = ("%s: %s"):format(row[1], YesNo(row[2])) end
			local fs = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("TOPLEFT", 8, -6)
			fs:SetJustifyH("LEFT")
			fs:SetText(table.concat(text, "\n"))
			panel.answers = table.concat(text, "; ")
			return ""
		end,
	},
}

function ArtPad:BrushLabTests()
	if T.window then
		T.window:SetShown(not T.window:IsShown())
		if not T.window:IsShown() then StressClear() end
		return
	end
	local rows = math.ceil(#TESTS / COLS)
	local window = CreateFrame("Frame", "ArtPad_LabTests", UIParent)
	T.window = window
	window:SetSize(GAP + COLS * (PW + GAP), 30 + rows * (PH + GAP) + 32)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	-- screen-owned buffers are put back over their spots, now and once the layout has settled
	function T.Replace()
		local function Now()
			for _, place in ipairs(T.replace or {}) do place() end
			for _, panel in ipairs(T.panels) do
				if panel.describe then panel.result:SetText(panel.describe()) end
			end
		end
		Now()
		C_Timer.After(0.1, Now)
	end
	window:SetScript("OnDragStop", function(frame)
		frame:StopMovingOrSizing()
		T.Replace()
	end)
	window:SetScript("OnHide", StressClear)
	local fit = FitToScreen(window)
	local bg = window:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.06, 0.06, 0.07, 0.97)
	local heading = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	heading:SetPoint("TOPLEFT", GAP, -9)
	heading:SetText("ArtPad brush lab: twelve experiments")

	for i, test in ipairs(TESTS) do
		local panel = CreateFrame("Frame", "ArtPad_LabTest" .. i, window)
		panel:SetSize(PW, PH)
		panel:SetPoint("TOPLEFT", GAP + ((i - 1) % COLS) * (PW + GAP), -30 - math.floor((i - 1) / COLS) * (PH + GAP))
		local back = panel:CreateTexture(nil, "BACKGROUND")
		back:SetAllPoints()
		back:SetColorTexture(0.13, 0.13, 0.15, 1)
		local y = 3
		local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		title:SetPoint("TOPLEFT", 4, -y)
		OneLine(title, PW - 8)
		title:SetText(test.title)
		y = y + TITLE_H + 2
		panel.body = CreateFrame("Frame", nil, panel)
		panel.body:SetSize(PW - 8, BODY_H)
		panel.body:SetPoint("TOPLEFT", 4, -y)
		panel.body:SetClipsChildren(true) -- a drawing never spills out of its box
		panel.bodyBg = panel.body:CreateTexture(nil, "BACKGROUND")
		panel.bodyBg:SetAllPoints()
		y = y + BODY_H + 3 + BUTTON_H + 2 -- (the buttons, if any, hang under the box: see Button)
		panel.result = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		panel.result:SetPoint("TOPLEFT", 4, -y)
		OneLine(panel.result, PW - 8)
		y = y + RESULT_H + 1
		local good = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		good:SetPoint("TOPLEFT", 4, -y)
		good:SetWidth(PW - 8)
		good:SetHeight(GOOD_H)
		good:SetJustifyH("LEFT")
		if good.SetJustifyV then good:SetJustifyV("TOP") end
		if good.SetMaxLines then good:SetMaxLines(3) end
		good:SetText(test.good)
		T.panels[i] = panel
		-- one experiment failing must not take the others with it: say what went wrong in its panel
		local ok, result = pcall(test.build, panel)
		if ok then
			panel.result:SetText(result or "")
		else
			panel.failed = tostring(result)
			panel.result:SetText("|cffff7766failed|r")
			good:SetText(tostring(result))
		end
	end

	-- Three of the questions can come out differently on the world map, which scrolls, zooms and
	-- clips its own way: this puts the same samples on the map itself.
	local onMap
	onMap = self:FlatButton(window, "ArtPad_LabOnMap", 190, 20, "Samples on world map: Off", function()
		local map = WorldMapFrame
		local canvas = map and map.ScrollContainer and map.ScrollContainer.Child
		if not canvas then
			self:Message("The world map isn't available.")
			return
		end
		if not T.mapSamples then
			local holder = CreateFrame("Frame", "ArtPad_LabMapSamples", canvas)
			holder:SetAllPoints(canvas)
			holder:SetFrameLevel(9500) -- above the map's own pins
			holder:Hide()
			T.mapSamples = holder
			local top = (canvas:GetHeight() or 668) - 60
			-- a welded zigzag at half opacity: seams
			local pts = { { 60, top - 30 }, { 110, top }, { 160, top - 34 }, { 210, top + 2 }, { 260, top - 30 } }
			for i = 1, #pts - 1 do
				local a, b = pts[i], pts[i + 1]
				NewQuad(holder, 160, top - 15, { a[1], a[2] + 9 }, { a[1], a[2] - 9 }, { b[1], b[2] + 9 }, { b[1], b[2] - 9 }, 0.3, 0.85, 1, 0.5)
			end
			-- a piece whose base is far off to the side: is it drawn by its corners?
			NewQuad(holder, 2400, top - 110, { 60, top - 80 }, { 60, top - 130 }, { 150, top - 80 }, { 150, top - 130 }, 0.3, 0.85, 0.35, 1)
			-- see-through crosses: plain, and drawn solid inside an off-screen buffer then faded
			NewLine(holder, 190, top - 130, 250, top - 80, 14, 1, 1, 1, 0.4)
			NewLine(holder, 190, top - 80, 250, top - 130, 14, 1, 1, 1, 0.4)
			local layer = CreateFrame("Frame", nil, holder)
			layer:SetAllPoints()
			pcall(function()
				layer:SetFlattensRenderLayers(true)
				layer:SetIsFrameBuffer(true)
			end)
			layer:SetAlpha(0.4)
			NewLine(layer, 280, top - 130, 340, top - 80, 14, 1, 1, 1, 1)
			NewLine(layer, 280, top - 80, 340, top - 130, 14, 1, 1, 1, 1)
			local note = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			note:SetPoint("BOTTOMLEFT", 60, top - 150)
			note:SetText("ArtPad lab: welded zigzag / green block / plain cross / buffered cross")
		end
		T.mapSamples:SetShown(not T.mapSamples:IsShown())
		onMap.label:SetText("Samples on world map: " .. (T.mapSamples:IsShown() and "On" or "Off"))
	end)
	onMap:SetPoint("BOTTOMLEFT", GAP + 108, 6)

	local scales, at = { 1, 0.75, 0.64 }, 1
	local scale
	scale = self:FlatButton(window, nil, 100, 20, "Scale: 1", function()
		at = at % #scales + 1
		window:SetScale(fit * scales[at]) -- (relative to the size that fits the screen)
		scale.label:SetText("Scale: " .. scales[at])
		T.Replace()
	end)
	scale:SetPoint("BOTTOMLEFT", GAP, 6)
	local close = self:FlatButton(window, "ArtPad_LabTestsClose", 80, 20, "Close", function() window:Hide() end)
	close:SetPoint("BOTTOMRIGHT", -GAP, 6)
	local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", GAP + 310, 10)
	OneLine(hint, window:GetWidth() - (GAP + 310) - 100)
	hint:SetText("Panels with buttons make thousands of pieces and clear themselves after ten seconds.")
end
end
