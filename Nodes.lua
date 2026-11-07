--[[
	Places: canvases tied to a spot in the world, shared with whoever is standing there.

	A place is a point on a zone map plus a radius. Walk inside it and ArtPad switches from
	your guild/group canvas to the place's canvas; walk out and it switches back. Drawing at a
	place goes out on YELL, which reaches about 400 yards, so with a radius of at most 200
	everyone at the place hears everyone else directly. Joining a place asks the people there
	for its canvas (by whisper, like any sync), and each client keeps its own copy of every
	place it has drawn at, so drawings outlive the people who made them.

	The canvas background is the patch of map around the place.
]]

local ArtPad = ArtPad

local CHECK_EVERY = 1 -- seconds
local LEAVE_MARGIN = 20 -- yards past the radius before leaving, so the edge doesn't flicker
local CANVAS_ASPECT = 16 / 9

-- mapIDs: the same zone has different UI map IDs on different clients (retail / classic).
-- x, y: 0-1 map coordinates (what Wowhead and TomTom show, divided by 100). radius: yards.
ArtPad.PLACES = {
	{
		id = "lionspride", name = "Lion's Pride Inn",
		mapIDs = { 37, 1429 }, x = 0.438, y = 0.659, radius = 100, -- Innkeeper Farley
	},
}

-- Size of a map in yards: GetMapWorldSize where it exists, otherwise from its corners.
local function MapYards(mapID)
	if C_Map.GetMapWorldSize then
		local w, h = C_Map.GetMapWorldSize(mapID)
		if w and w > 0 and h and h > 0 then return w, h end
	end
	if C_Map.GetWorldPosFromMapPos and CreateVector2D then
		local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
		local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
		if a and b then
			local ax, ay = a:GetXY()
			local bx, by = b:GetXY()
			-- world axes are swapped relative to map axes; the size is what matters
			return math.abs(ay - by), math.abs(ax - bx)
		end
	end
end

local function PlayerOn(mapID)
	local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
	if not pos then return nil end
	local x, y
	if pos.GetXY then x, y = pos:GetXY() else x, y = pos.x, pos.y end
	if not x or (x == 0 and y == 0) then return nil end
	return x, y
end

-- Distance in yards from the player to a place, plus the map ID it was measured on;
-- nil if you're not on any of its maps.
function ArtPad:PlaceDistance(place)
	for _, mapID in ipairs(place.mapIDs) do
		local x, y = PlayerOn(mapID)
		if x then
			local w, h = MapYards(mapID)
			if w then
				return math.sqrt(((x - place.x) * w) ^ 2 + ((y - place.y) * h) ^ 2), mapID
			end
		end
	end
end

-- The part of the map shown behind a place's canvas: centred on it, as tall as its diameter.
function ArtPad:PlaceView(place, mapID)
	local w, h = MapYards(mapID)
	if not w then return nil end
	local hy = place.radius / h
	local hx = place.radius * CANVAS_ASPECT / w
	return { place.x - hx, place.y - hy, place.x + hx, place.y + hy }
end

function ArtPad:CheckPlaces()
	local current = self.node
	if not ArtPad_Settings.Nearby or self.loopback then
		if current then self:LeavePlace() end
		return
	end
	if current then
		local d = self:PlaceDistance(current)
		if not d or d > current.radius + LEAVE_MARGIN then self:LeavePlace() end
		return
	end
	for _, place in ipairs(self.PLACES) do
		local d, mapID = self:PlaceDistance(place)
		if d and d <= place.radius then
			self:EnterPlace(place, mapID)
			return
		end
	end
end

-- Switching canvases: finish what you're doing and drop anything not yet sent, so it can't
-- leak to the other audience.
function ArtPad:SwitchScope()
	if self.EndInteraction then self:EndInteraction() end
	if self.outQueue then wipe(self.outQueue) end
	self.syncing, self.syncNonce, self.syncToken, self.syncPhase = false, nil, nil, nil
	self.syncBuffer = {}
	wipe(self.activeArtists or {})
end

function ArtPad:SavePlaceCanvas()
	local place = self.node
	if not place then return end
	if type(ArtPad_Settings.PlaceCanvases) ~= "table" then ArtPad_Settings.PlaceCanvases = {} end
	ArtPad_Settings.PlaceCanvases[place.id] = #self.items > 0 and self:SerializeCanvas() or nil
end

function ArtPad:EnterPlace(place, mapID)
	self:SwitchScope()
	self.outsideCanvas = self:SerializeCanvas() -- your guild/group canvas, back when you leave
	self.node = place
	self:ClearCanvas()
	self.backdropBy = nil
	self:SetBackdrop(mapID, self:GetExploredOverlays(mapID), self:PlaceView(place, mapID))
	local saved = type(ArtPad_Settings.PlaceCanvases) == "table" and ArtPad_Settings.PlaceCanvases[place.id]
	if type(saved) == "table" and type(saved.items) == "table" then
		local ok, err = pcall(self.LoadCanvas, self, saved)
		if not ok then self:Debug("place: bad saved canvas: " .. tostring(err)) end
	end
	self:Notify(("You're at %s. Everyone here with ArtPad shares this canvas."):format(place.name), "info")
	self:StartSync("arrived at " .. place.id)
	self:RequestRefresh()
end

function ArtPad:LeavePlace()
	local place = self.node
	if not place then return end
	self:SavePlaceCanvas()
	self:SwitchScope()
	self.node = nil
	self:ClearAll()
	local outside = self.outsideCanvas
	self.outsideCanvas = nil
	if outside then
		local ok, err = pcall(self.LoadCanvas, self, outside)
		if not ok then self:Debug("place: couldn't restore canvas: " .. tostring(err)) end
	end
	local label = self:GetSharingState()
	self:Notify(("Left %s. Back to your canvas (%s)."):format(place.name, label), "info", { quiet = true })
	self:StartSync("left " .. place.id)
	self:RequestRefresh()
end

function ArtPad:SetNearby(on)
	ArtPad_Settings.Nearby = on and true or false
	self:CheckPlaces()
	if self.RefreshOptions then self:RefreshOptions() end
	self:RequestRefresh()
end

function ArtPad:SetupPlaces()
	self.placeTicker = C_Timer.NewTicker(CHECK_EVERY, function() self:CheckPlaces() end)
end

-- /ap node: where you are relative to each place (for checking coordinates in game).
function ArtPad:PrintPlaces()
	for _, place in ipairs(self.PLACES) do
		local d, mapID = self:PlaceDistance(place)
		self:Message(("%s: %s%s"):format(place.name,
			d and ("%.0f yd away (map %d), radius %d"):format(d, mapID, place.radius) or "not on its map",
			self.node == place and " - you're here" or ""))
	end
	local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local x, y = mapID and PlayerOn(mapID)
	if x then
		self:Message(("you: map %d at %.4f, %.4f"):format(mapID, x, y))
	end
end
