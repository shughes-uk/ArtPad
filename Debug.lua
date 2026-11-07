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
	self.quiet = (self.quiet or 0) + 1 -- not a change to the shared canvas
	for i = 1, points do
		angle = angle + (math.random() - 0.5) * 2.4
		x = math.max(20, math.min(self.canvasSize.X - 20, x + 14 * math.cos(angle)))
		y = math.max(20, math.min(self.canvasSize.Y - 20, y + 14 * math.sin(angle)))
		self:SetStrokePoint(s, i, math.floor(x), math.floor(y))
	end
	self.quiet = self.quiet - 1
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
			self:Message("bench: line budget and cap back on")
		else
			self.lineBudget, self.lineCap = math.huge, math.huge
			self:Message("bench: line budget and cap OFF (drawings can vanish again)")
		end
	elseif cmd == "clear" then
		self:BenchClear()
	else
		self:BenchReport()
		self:Message("bench lines|tex <n> [per frame], more <n>, scribble <points>, nolimit, clear")
	end
end
