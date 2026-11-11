--[[
	Map backdrop: the map of where you are, drawn under the canvas for everyone.

	Drawn like the world map: the base art tiles (C_Map.GetMapArtLayerTextures) plus the
	"explored area" overlays on top (C_MapExplorationInfo.GetExploredMapTextures) - without
	those, classic-style maps are mostly blank parchment. Everyone has explored different
	areas, so the sharer's explored overlays travel with the map ID (live "B" message and in
	snapshots) and everyone sees the same map as the person who shared it.

	Overlay string format: overlays separated by ";", each "w,h,x,y,id.id.id" (size and
	offset in map pixels, then the tile texture file IDs row by row).
]]

local ArtPad = ArtPad

local TILE = 256 -- overlay tile size, as used by the world map

function ArtPad:CanShowMaps()
	return C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil and C_Map.GetMapArtLayers ~= nil
		and C_Map.GetMapArtLayerTextures ~= nil
end

function ArtPad:GetMapTiles(mapID)
	if not self:CanShowMaps() then return nil end
	local layers = C_Map.GetMapArtLayers(mapID)
	local layer = layers and layers[1]
	if not layer then return nil end
	local textures = C_Map.GetMapArtLayerTextures(mapID, 1)
	if not textures or #textures == 0 then return nil end
	return layer, textures
end

function ArtPad:GetMapName(mapID)
	local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
	return info and info.name
end

-- The areas of this map you've explored, as an overlay string (see above). "" if none.
function ArtPad:GetExploredOverlays(mapID)
	if not (C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures) then return "" end
	local list = C_MapExplorationInfo.GetExploredMapTextures(mapID)
	local out = {}
	for _, info in ipairs(list or {}) do
		-- Hover-only highlights aren't part of the explored map
		if not info.isShownByMouseOver and info.fileDataIDs and #info.fileDataIDs > 0 then
			table.insert(out, ("%d,%d,%d,%d,%s"):format(info.textureWidth, info.textureHeight,
				info.offsetX, info.offsetY, table.concat(info.fileDataIDs, ".")))
		end
	end
	return table.concat(out, ";")
end

local function TileSpan(total, index, count)
	-- Pixel size of tile `index` along one axis, and the texture file's size along it
	-- (partial edge tiles live in the next power-of-two sized file, like the world map does).
	if index < count then return TILE, TILE end
	local px = total % TILE
	if px == 0 then px = TILE end
	local file = 16
	while file < px do file = file * 2 end
	return px, file
end

function ArtPad:AcquireMapTexture(sublevel)
	self.mapTextureCount = self.mapTextureCount + 1
	local tex = self.mapTextures[self.mapTextureCount]
	if not tex then
		tex = self.mainFrame:CreateTexture(nil, "BACKGROUND", nil, sublevel)
		self.mapTextures[self.mapTextureCount] = tex
	end
	tex:SetDrawLayer("BACKGROUND", sublevel)
	tex:ClearAllPoints()
	tex:Show()
	return tex
end

-- Apply locally (no network). nil removes the backdrop. view (optional): the part of the map
-- to show, { x0, y0, x1, y1 } in 0-1 map coordinates, stretched over the whole canvas (used by
-- places; see Nodes.lua). Without it the whole map is fitted into the canvas.
-- Overlay strings come from other players (live, and inside canvas copies), so they are
-- checked before anything is drawn or kept: each overlay must be well formed, fit on the map
-- and carry at least the tiles its size needs. A size the map couldn't have (a few digits are
-- enough to ask for millions of tiles) is dropped, not looped over.
local MAX_OVERLAYS, MAX_OVERLAY_TILES, MAX_OVERLAY_SIDE = 96, 64, 8192

function ArtPad:SanitizeOverlays(mapID, overlays)
	if type(overlays) ~= "string" or overlays == "" then return "" end
	local layer = self:GetMapTiles(mapID)
	local maxW = layer and layer.layerWidth or MAX_OVERLAY_SIDE
	local maxH = layer and layer.layerHeight or MAX_OVERLAY_SIDE
	local out = {}
	for overlay in overlays:gmatch("[^;]+") do
		local w, h, x, y, ids = overlay:match("^(%d+),(%d+),(%-?%d+),(%-?%d+),([%d%.]+)$")
		w, h, x, y = tonumber(w), tonumber(h), tonumber(x), tonumber(y)
		if w and #overlay <= 600 and w >= 1 and h >= 1 and w <= maxW and h <= maxH
				and math.abs(x) <= MAX_OVERLAY_SIDE and math.abs(y) <= MAX_OVERLAY_SIDE then
			local tiles = math.ceil(w / TILE) * math.ceil(h / TILE)
			local _, count = ids:gsub("%d+", "")
			if tiles <= MAX_OVERLAY_TILES and count >= tiles then
				out[#out + 1] = overlay
				if #out >= MAX_OVERLAYS then break end
			end
		end
	end
	return table.concat(out, ";")
end

function ArtPad:SetBackdrop(mapID, overlays, view)
	overlays = mapID and self:SanitizeOverlays(mapID, overlays) or ""
	if mapID == self.backdropMap and overlays == (self.backdropOverlays or "") and view == self.backdropView then return end
	self.backdropView = mapID and view or nil
	self.mapTextures = self.mapTextures or {}
	for _, tex in ipairs(self.mapTextures) do tex:Hide() end
	self.mapTextureCount = 0
	self.backdropMap = mapID
	self.backdropOverlays = mapID and overlays or nil
	self:Changed()
	if mapID then self:DrawBackdrop(mapID, overlays) end
	self:UpdateMapButton()
end

function ArtPad:DrawBackdrop(mapID, overlays)
	local layer, textures = self:GetMapTiles(mapID)
	if not layer then return end
	local tw, th, lw, lh = layer.tileWidth, layer.tileHeight, layer.layerWidth, layer.layerHeight
	local W, H = self.canvasSize.X, self.canvasSize.Y
	-- The visible window of the map (in map pixels) and how it lands on the canvas.
	local vx0, vy0, vx1, vy1, sx, sy, ox, oy
	local view = self.backdropView
	if view then
		vx0, vy0, vx1, vy1 = view[1] * lw, view[2] * lh, view[3] * lw, view[4] * lh
		sx, sy, ox, oy = W / (vx1 - vx0), H / (vy1 - vy0), 0, 0
	else
		local scale = math.min(W / lw, H / lh)
		vx0, vy0, vx1, vy1 = 0, 0, lw, lh
		sx, sy, ox, oy = scale, scale, (W - lw * scale) / 2, (H - lh * scale) / 2
	end
	-- Draw the map rectangle (x, y, w, h), whose texture file spans fw x fh map pixels from
	-- (x, y), cropped to the visible window. Returns false if none of it is visible.
	local function Place(tex, x, y, w, h, fw, fh)
		local ix0, iy0 = math.max(x, vx0), math.max(y, vy0)
		local ix1, iy1 = math.min(x + w, vx1), math.min(y + h, vy1)
		if ix1 <= ix0 or iy1 <= iy0 then
			tex:Hide()
			return false
		end
		tex:SetTexCoord((ix0 - x) / fw, (ix1 - x) / fw, (iy0 - y) / fh, (iy1 - y) / fh)
		tex:SetSize((ix1 - ix0) * sx, (iy1 - iy0) * sy)
		tex:SetPoint("TOPLEFT", self.mainFrame, "TOPLEFT", ox + (ix0 - vx0) * sx, -(oy + (iy0 - vy0) * sy))
		return true
	end

	-- Base art
	local cols = math.ceil(lw / tw)
	for i, fileID in ipairs(textures) do
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		-- Edge tiles overhang the map; crop them to the map's real size.
		local cw = math.min(tw, lw - col * tw)
		local ch = math.min(th, lh - row * th)
		if cw > 0 and ch > 0 then
			local tile = self:AcquireMapTexture(1)
			tile:SetTexture(fileID)
			Place(tile, col * tw, row * th, cw, ch, tw, th)
		end
	end

	-- Explored areas
	for overlay in overlays:gmatch("[^;]+") do
		local w, h, x, y, ids = overlay:match("^(%d+),(%d+),(%-?%d+),(%-?%d+),([%d%.]+)$")
		if w then
			w, h, x, y = tonumber(w), tonumber(h), tonumber(x), tonumber(y)
			local fileIDs = {}
			for id in ids:gmatch("%d+") do table.insert(fileIDs, tonumber(id)) end
			local wide, tall = math.ceil(w / TILE), math.ceil(h / TILE)
			for j = 1, tall do
				local ph, fh = TileSpan(h, j, tall)
				for k = 1, wide do
					local fileID = fileIDs[(j - 1) * wide + k]
					if fileID then
						local pw, fw = TileSpan(w, k, wide)
						local tex = self:AcquireMapTexture(2)
						tex:SetTexture(fileID)
						Place(tex, x + TILE * (k - 1), y + TILE * (j - 1), pw, ph, fw, fh)
					end
				end
			end
		end
	end
end

function ArtPad:ToggleMap()
	if self.node then
		self:Notify(("The map stays up at %s."):format(self.node.name), "info")
		if self.mapSwitch then self.mapSwitch:Refresh() end
		return
	end
	if self.backdropMap then
		self:ShareBackdrop(nil)
		self:Notify("Map removed for everyone.", "info")
		return
	end
	if not self:CanShowMaps() then
		self:Notify("Maps aren't available on this client.", "error")
		return
	end
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID or not self:GetMapTiles(mapID) then
		self:Notify("There's no map for where you are right now.", "warn")
		return
	end
	self:ShareBackdrop(mapID, self:GetExploredOverlays(mapID))
	self:Notify(("Showing the map of %s for everyone."):format(self:GetMapName(mapID) or "this area"), "success")
end

-- The map switch and name live in the inspector; the map name also shows in the title bar.
function ArtPad:UpdateMapButton()
	if not self.backdropMap then self.backdropBy = nil end
	self:ApplyMapDim()
	if self.RefreshInspector then self:RefreshInspector() end
	if self.UpdateTitle then self:UpdateTitle() end
end

-- A dark layer over the map so drawings stand out (local setting).
function ArtPad:ApplyMapDim()
	local dim = self.mapDim
	if not dim then
		dim = self.mainFrame:CreateTexture(nil, "BACKGROUND", nil, 3)
		dim:SetAllPoints(self.mainFrame)
		self.mapDim = dim
	end
	dim:SetColorTexture(0, 0, 0, ArtPad_Settings.MapDim or 0)
	dim:SetShown(self.backdropMap ~= nil)
end

ArtPad.MapTileSpan = TileSpan -- for /ap bench mapshot (Debug.lua)
