--[[
	Map backdrop: the map of where you are, drawn under the canvas for everyone.

	Uses the same art tiles as the world map (C_Map.GetMapArtLayers / GetMapArtLayerTextures),
	scaled to fit the canvas. The map ID is shared (live "B(id)" message and in snapshots), so
	everyone sees the same map even if they're somewhere else. Clients without the API keep
	track of the shared map ID (so they can pass it on) but can't draw it.
]]

local ArtPad = ArtPad

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

-- Apply locally (no network). nil removes the backdrop.
function ArtPad:SetBackdrop(mapID)
	if mapID == self.backdropMap then return end
	self.mapTiles = self.mapTiles or {}
	for _, tile in ipairs(self.mapTiles) do tile:Hide() end
	self.backdropMap = mapID
	self:Changed()
	self:UpdateMapButton()
	if not mapID then return end

	local layer, textures = self:GetMapTiles(mapID)
	if not layer then return end
	local tw, th, lw, lh = layer.tileWidth, layer.tileHeight, layer.layerWidth, layer.layerHeight
	local W, H = self.canvasSize.X, self.canvasSize.Y
	local scale = math.min(W / lw, H / lh)
	local ox, oy = (W - lw * scale) / 2, (H - lh * scale) / 2
	local cols = math.ceil(lw / tw)
	for i, fileID in ipairs(textures) do
		local tile = self.mapTiles[i]
		if not tile then
			tile = self.mainFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
			self.mapTiles[i] = tile
		end
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		-- Edge tiles overhang the map; crop them to the map's real size.
		local cw = math.min(tw, lw - col * tw)
		local ch = math.min(th, lh - row * th)
		if cw > 0 and ch > 0 then
			tile:SetTexture(fileID)
			tile:SetTexCoord(0, cw / tw, 0, ch / th)
			tile:SetSize(cw * scale, ch * scale)
			tile:ClearAllPoints()
			tile:SetPoint("TOPLEFT", self.mainFrame, "TOPLEFT", ox + col * tw * scale, -(oy + row * th * scale))
			tile:Show()
		end
	end
end

function ArtPad:ToggleMap()
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
	self:ShareBackdrop(mapID)
	self:Notify(("Showing the map of %s for everyone."):format(self:GetMapName(mapID) or "this area"), "success")
end

function ArtPad:UpdateMapButton()
	local b = self.mapButton
	if not b then return end
	if self.backdropMap then
		b.normal:SetColorTexture(0.1, 0.3, 0.55, 0.85)
		b.tooltip = { "Map backdrop", "Showing: " .. (self:GetMapName(self.backdropMap) or "a map"), "Click to remove it for everyone." }
	else
		b.normal:SetColorTexture(0, 0, 0, 0.69)
		b.tooltip = { "Map backdrop", "Show the map of where you are under the canvas, for everyone.",
			not self:CanShowMaps() and "|cffff6060Not available on this client.|r" or nil }
	end
end
