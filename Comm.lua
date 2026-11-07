--[[
	Networking.

	Live prefix "ArtPad<proto>", broadcast to guild or group (whispered to yourself in loopback):
	  S(lid,start,r,g,b,a,w,smooth;<points>)  stroke points, starting at point index `start`
	  R(id=1,4-9;id2=*)                       erase segments of items (* = whole item)
	  T(lid,x,y,r,g,b,a;text)                 text
	  M(lid,key,x,y,size)                     stamp (raid marker / role icon)
	  B(mapID)                                shared backdrop map (0 = none)
	  U(lid)                                  undo (sender's own item only)
	  X()                                     clear canvas
	"lid" is the sender's local id; the full item id is "<sender>:<lid>".

	<points> is compact: "~x,y~" gives an absolute point, then each following point is two
	characters, the x and y offsets from the previous point (-45..45). An offset that doesn't
	fit falls back to another absolute "~x,y~". That's ~2 bytes per point instead of ~9,
	which matters because addon messages are throttled to roughly 800 bytes/second.

	Sync prefix "ArtPadS<proto>" (late joiners):
	  Q(nonce)                  broadcast: who has a canvas?
	  H(nonce,items,bytes)      whisper reply: I do
	  G(nonce)                  whisper: send it to me
	Data prefixes "ArtPadD<proto>a..d":
	  P(nonce,i,n)<chunk>       whisper: chunk i of n of the canvas
	                            (AceSerializer -> LibDeflate -> channel-safe encoding)
	The joiner applies live messages immediately and also buffers them; once the snapshot
	arrives it replaces the canvas and replays the buffer. Messages are idempotent, so
	anything already in the snapshot is harmless to replay.
]]

local ArtPad = ArtPad
local LibDeflate = LibStub("LibDeflate")
local ShortName = ArtPad.ShortName
local NUM = ArtPad.NUM
local tinsert = table.insert

-- The server lets each addon prefix send a burst of 10 messages, then 1 per second
-- (patch 10.2.7 / 4.4.0, all chat types). Message count is what's limited, not bytes, so
-- live drawing is paced to that budget and each message is packed as full as it can be.
local BUDGET_MAX, BUDGET_RATE = 10, 1
local FAST_FLUSH, SLOW_FLUSH = 0.3, 1.0 -- seconds between flushes with / without spare budget
local MAX_MESSAGE = 250 -- bytes; longer messages get split into several (each one counts)
local SYNC_COLLECT = 2.5 -- seconds to wait for canvas offers

-- Streaming simplification: drop points that lie (almost) on the line between their
-- neighbours. Both the sender and receivers draw the simplified points.
local SIMPLIFY_TOLERANCE = 1.0 -- canvas px
local SIMPLIFY_MAX_RUN = 40 -- cap merged runs so the eraser (per segment) stays precise

--[[ Compact point encoding ]]

-- 91 printable characters (no "~" or "^", which are markers, and no "|", the chat escape).
--   two chars        small step: x and y offsets of -45..45
--   "^" + 4 chars    big step: x and y offsets of -4140..4140, two base-91 digits each
--   "~x,y~"          absolute point (first point of each message)
local DIGIT, DIGIT_VALUE = {}, {}
do
	local i = 0
	for c = 33, 126 do
		if c ~= 126 and c ~= 124 and c ~= 94 then
			DIGIT[i] = string.char(c)
			DIGIT_VALUE[c] = i
			i = i + 1
		end
	end
end
local SMALL, BIG = 45, 4140
local BYTE_ABS, BYTE_BIG = 126, 94

local function BigDigits(v)
	local u = v + BIG
	return DIGIT[math.floor(u / 91)] .. DIGIT[u % 91]
end

-- Encodes points from..to, stopping early if the result would exceed maxBytes.
-- Returns the encoded string and the index of the last point included.
function ArtPad.EncodePoints(px, py, from, to, maxBytes)
	local first = "~" .. px[from] .. "," .. py[from] .. "~"
	local out, len, last = { first }, #first, from
	for i = from + 1, to do
		local dx, dy = px[i] - px[i - 1], py[i] - py[i - 1]
		local piece
		if dx >= -SMALL and dx <= SMALL and dy >= -SMALL and dy <= SMALL then
			piece = DIGIT[dx + SMALL] .. DIGIT[dy + SMALL]
		elseif dx >= -BIG and dx <= BIG and dy >= -BIG and dy <= BIG then
			piece = "^" .. BigDigits(dx) .. BigDigits(dy)
		else
			piece = "~" .. px[i] .. "," .. py[i] .. "~"
		end
		if maxBytes and len + #piece > maxBytes then break end
		out[#out + 1] = piece
		len = len + #piece
		last = i
	end
	return table.concat(out), last
end

-- Returns arrays of x and y (nil on malformed input).
function ArtPad.DecodePoints(data)
	local xs, ys = {}, {}
	local pos, len, x, y = 1, #data, nil, nil
	local b = data.byte
	while pos <= len do
		local c = b(data, pos)
		if c == BYTE_ABS then
			local close = data:find("~", pos + 1, true)
			if not close then return nil end
			local ax, ay = data:sub(pos + 1, close - 1):match("^(%-?%d+),(%-?%d+)$")
			if not ax then return nil end
			x, y = tonumber(ax), tonumber(ay)
			pos = close + 1
		elseif c == BYTE_BIG then
			if not x or pos + 4 > len then return nil end
			local d1, d2 = DIGIT_VALUE[b(data, pos + 1)], DIGIT_VALUE[b(data, pos + 2)]
			local d3, d4 = DIGIT_VALUE[b(data, pos + 3)], DIGIT_VALUE[b(data, pos + 4)]
			if not (d1 and d2 and d3 and d4) then return nil end
			x, y = x + d1 * 91 + d2 - BIG, y + d3 * 91 + d4 - BIG
			pos = pos + 5
		else
			if not x or pos + 1 > len then return nil end
			local dx, dy = DIGIT_VALUE[c], DIGIT_VALUE[b(data, pos + 1)]
			if not dx or not dy then return nil end
			x, y = x + dx - SMALL, y + dy - SMALL
			pos = pos + 2
		end
		xs[#xs + 1], ys[#ys + 1] = x, y
	end
	return xs, ys
end

function ArtPad:SetupComm()
	self.livePrefix = "ArtPad" .. self.protocolVersion
	self.syncPrefix = "ArtPadS" .. self.protocolVersion
	self.versionPrefix = "ArtPad_Version"
	self.syncBuffer = {}
	self.outQueue = {}
	self.laserLast = {}
	self:RegisterComm(self.livePrefix, "OnLiveMessage")
	self:RegisterComm(self.syncPrefix, "OnSyncMessage")
	self:RegisterComm(self.versionPrefix, "OnVersionMessage")
	-- Snapshot chunks are spread over these so each one's message allowance adds up.
	self.dataPrefixes = {}
	for _, suffix in ipairs({ "a", "b", "c", "d" }) do
		local prefix = "ArtPadD" .. self.protocolVersion .. suffix
		table.insert(self.dataPrefixes, prefix)
		self:RegisterComm(prefix, "OnDataMessage")
	end
	self:Broadcast(self.versionPrefix, tostring(self.version), "BULK")
end

--[[ Channels ]]

-- Channel we broadcast on for the current mode, or nil if there's nobody to talk to.
function ArtPad:GetChannel()
	if ArtPad_Settings.Mode == "GUILD" then
		return IsInGuild() and "GUILD" or nil
	end
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
end

function ArtPad:AcceptsDistribution(disType)
	if ArtPad_Settings.Mode == "GUILD" then
		return disType == "GUILD"
	end
	return disType == "RAID" or disType == "PARTY" or disType == "INSTANCE_CHAT"
end

-- onSent(_, bytesSent, totalBytes) is called as the message actually goes out.
function ArtPad:Broadcast(prefix, msg, prio, onSent)
	if self.loopback and prefix == self.livePrefix then
		self:SendCommMessage(prefix, msg, "WHISPER", self.playerName, prio or "NORMAL", onSent)
		return
	end
	local channel = self:GetChannel()
	if channel then
		self:SendCommMessage(prefix, msg, channel, nil, prio or "NORMAL", onSent)
	elseif onSent then
		onSent(nil, #msg, #msg) -- nobody to send to: nothing is waiting
	end
end

function ArtPad:SetLoopback(on)
	self.loopback = on
	if on then
		self:Notify("Loopback on: your drawing goes through the server and back to only you.", "info")
	else
		self:Notify("Loopback off.", "info")
	end
	self:RequestRefresh()
end

--[[ Permissions ]]

function ArtPad:GetGuildRank(name)
	if not self.guildRanks then
		self.guildRanks = {}
		for i = 1, GetNumGuildMembers() do
			local member, _, rankIndex = GetGuildRosterInfo(i)
			if member then
				self.guildRanks[ShortName(member)] = rankIndex
			end
		end
	end
	return self.guildRanks[ShortName(name)]
end

-- With AdminOnly on, only accept officers (guild mode) or leader/assists (group mode).
function ArtPad:ValidateSender(sender)
	if not ArtPad_Settings.AdminOnly or self:IsSelf(sender) then
		return true
	end
	if ArtPad_Settings.Mode == "GUILD" then
		local rank = self:GetGuildRank(sender)
		return rank ~= nil and rank <= ArtPad_Settings.AdminGuildRank
	end
	-- Everyone in a party has "assist", so require the leader there.
	local minRank = IsInRaid() and 1 or 2
	local short = ShortName(sender)
	for i = 1, GetNumGroupMembers() do
		local name, rank = GetRaidRosterInfo(i)
		if name and ShortName(name) == short then
			return rank >= minRank
		end
	end
	return false
end

--[[ Sending ]]

-- Our estimate of the live prefix's remaining message allowance (see BUDGET_MAX).
function ArtPad:SendBudget()
	local now = GetTime()
	local b = self.budget
	if not b then
		b = { tokens = BUDGET_MAX, t = now }
		self.budget = b
	end
	b.tokens = math.min(BUDGET_MAX, b.tokens + (now - b.t) * BUDGET_RATE)
	b.t = now
	return b.tokens
end

-- Low-level: put one message (one or more newline-separated commands) on the wire.
-- Everything goes through the outgoing queue below, which decides when to call this.
function ArtPad:SendLive(msg, prio)
	if self.syncing then
		-- Replayed after a snapshot arrives so our own work isn't lost.
		tinsert(self.syncBuffer, { msg, self.playerName })
	end
	self:SendBudget()
	self.budget.tokens = self.budget.tokens - math.ceil(#msg / 255)
	-- Count messages handed over but not yet actually sent (they queue when throttled).
	self.liveQueued = (self.liveQueued or 0) + 1
	if self.DEBUG then
		local _, lines = msg:gsub("\n", "")
		self:Debug(("send %d cmd %dB  allowance ~%.1f  queued %d  waiting %d"):format(lines + 1, #msg,
			self.budget.tokens, self.liveQueued, #self.outQueue))
	end
	self:Broadcast(self.livePrefix, msg, prio, function(_, sent, total)
		if sent >= total then
			self.liveQueued = math.max(0, self.liveQueued - 1)
		end
	end)
end

-- How long to wait before the next batched send: quick while there's budget to spare,
-- then roughly the server's refill rate so a long scribble never builds up a backlog.
function ArtPad:FlushDelay()
	local tokens = self:SendBudget()
	if tokens >= 4 then return FAST_FLUSH end
	if tokens >= 1 then return SLOW_FLUSH end
	return (1 - tokens) / BUDGET_RATE + 0.05
end

function ArtPad:QueueFlush()
	if not self.flushTimer then
		self.flushTimer = C_Timer.NewTimer(self:FlushDelay(), function()
			self.flushTimer = nil
			self:FlushOutbox()
		end)
	end
end

local function EncodeIndices(list)
	table.sort(list)
	local out, i = {}, 1
	while i <= #list do
		local j = i
		while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
		tinsert(out, i == j and tostring(list[i]) or (list[i] .. "-" .. list[j]))
		i = j + 1
	end
	return table.concat(out, ",")
end

--[[ Outgoing queue

	Every drawing action becomes an entry in one ordered queue:
	  { stroke = s }   points of a stroke (still growing while it's being drawn)
	  { erase = map }  erased item ids/segments, merged while the eraser keeps moving
	  { cmd = "..." }  a finished command (text, stamp, undo, clear, map)
	FlushOutbox packs the front of the queue into messages of up to MAX_MESSAGE bytes,
	several commands per message (newline separated), and only sends while our estimate of
	the server's allowance permits. So bursts of short strokes, stamps or undos can't run
	ahead of the limit, and nothing ever overtakes something queued before it.
]]

function ArtPad:Enqueue(entry)
	tinsert(self.outQueue, entry)
	self:QueueFlush()
end

function ArtPad:QueueCommand(cmd)
	self:Enqueue({ cmd = cmd })
end

-- The next command from `entry` that fits in `room` bytes.
-- Returns cmd (or nil if nothing fits / nothing ready), and whether the entry is used up.
function ArtPad:NextCommand(entry, room, packetEmpty)
	if entry.cmd then
		if #entry.cmd <= room or packetEmpty then return entry.cmd, true end
		return nil, false
	end
	if entry.erase then
		local parts, len = {}, 3
		for id, segs in pairs(entry.erase) do
			local part
			if segs == true then
				part = id .. "=*"
			else
				local list = {}
				for i in pairs(segs) do tinsert(list, i) end
				part = id .. "=" .. EncodeIndices(list)
			end
			if len + #part + 1 > room and not (packetEmpty and #parts == 0) then break end
			tinsert(parts, part)
			len = len + #part + 1
			entry.erase[id] = nil
		end
		local done = next(entry.erase) == nil
		if #parts == 0 then return nil, done end
		return "R(" .. table.concat(parts, ";") .. ")", done
	end
	local s = entry.stroke or entry.laser
	if s.sent >= s.n then
		return nil, s.done -- caught up; more may come while it's still being drawn
	end
	local head
	if entry.laser then
		head = ("L(%s,%d;"):format(s.localId, s.sent + 1)
	else
		head = ("S(%s,%d,%s,%d,%d;"):format(s.localId, s.sent + 1, self.ColorString(s), s.w, s.smooth and 1 or 0)
	end
	local space = room - #head - 1
	if space < 12 and not packetEmpty then return nil, false end
	local data, last = self.EncodePoints(s.px, s.py, s.sent + 1, s.n, math.max(space, 12))
	s.sent = last
	return head .. data .. ")", s.done and s.sent >= s.n
end

function ArtPad:FlushOutbox()
	if self.flushTimer then
		self.flushTimer:Cancel()
		self.flushTimer = nil
	end
	local q = self.outQueue
	while q[1] and self:SendBudget() >= 1 do
		local parts, len = {}, ArtPad_Settings.ShowMyName and 0 or 4 -- room for the "H()" marker
		while q[1] do
			local sep = #parts > 0 and 1 or 0
			local cmd, finished = self:NextCommand(q[1], MAX_MESSAGE - len - sep, #parts == 0)
			if cmd then
				tinsert(parts, cmd)
				len = len + #cmd + sep
			end
			if finished then
				table.remove(q, 1)
			elseif not cmd or len >= MAX_MESSAGE - 12 then
				break -- message is full, or the front entry has nothing more to send yet
			end
		end
		if #parts == 0 then break end
		-- "Show my name" off: tell receivers not to tag these with our name
		if not ArtPad_Settings.ShowMyName then table.insert(parts, 1, "H()") end
		self:SendLive(table.concat(parts, "\n"))
	end
	if q[1] then
		self:QueueFlush() -- more to send once the allowance refills (or the stroke grows)
	end
end

--[[ Local drawing actions (called by the UI) ]]

-- In loopback mode nothing is applied locally: only what comes back from the server is drawn.

-- smooth: freehand (rendered as a curve, points simplified while drawing); false for shapes.
function ArtPad:BeginStroke(x, y, smooth)
	if smooth == nil then smooth = true end
	local c = self.brushColor
	local s = {
		localId = self:NewLocalId(),
		r = c.r, g = c.g, b = c.b, a = c.a, w = self:BrushWidth(), smooth = smooth,
		px = { x }, py = { y }, n = 1, sent = 0,
		pending = {}, -- simplified-away points since the last committed one (x1, y1, x2, y2, ...)
	}
	s.id = self.playerName .. ":" .. s.localId
	self.currentStroke = s
	self:PushUndo(s.id)
	self:MirrorStrokePoint(1)
	self:Enqueue({ stroke = s })
end

function ArtPad:MirrorStrokePoint(i)
	if self.loopback then return end
	local s = self.currentStroke
	local item = self:GetStroke(s.id, self.playerName, s, s.w, s.smooth)
	if item then
		self:SetStrokePoint(item, i, s.px[i], s.py[i])
	end
end

function ArtPad:CommitPoint(x, y)
	local s = self.currentStroke
	if s.px[s.n] == x and s.py[s.n] == y then return end
	s.n = s.n + 1
	s.px[s.n], s.py[s.n] = x, y
	wipe(s.pending)
	self:MirrorStrokePoint(s.n)
	self:QueueFlush()
end

-- Add a point to the stroke being drawn. Freehand strokes hold the latest point back as a
-- candidate and only commit it once the stroke bends away from the straight line, so long
-- straight-ish runs become one segment.
function ArtPad:ExtendStroke(x, y)
	local s = self.currentStroke
	if not s then return end
	if not s.smooth then
		self:CommitPoint(x, y)
		return
	end
	local cand = s.candidate
	if cand then
		local ax, ay = s.px[s.n], s.py[s.n]
		local dx, dy = x - ax, y - ay
		local ok = dx * dx + dy * dy <= SIMPLIFY_MAX_RUN * SIMPLIFY_MAX_RUN
			and (cand[1] - ax) * dx + (cand[2] - ay) * dy > 0
			and ArtPad.PointSegDist(cand[1], cand[2], ax, ay, x, y) <= SIMPLIFY_TOLERANCE
		local pending = s.pending
		for k = 1, #pending, 2 do
			if not ok then break end
			ok = ArtPad.PointSegDist(pending[k], pending[k + 1], ax, ay, x, y) <= SIMPLIFY_TOLERANCE
		end
		if ok then
			tinsert(pending, cand[1])
			tinsert(pending, cand[2])
		else
			self:CommitPoint(cand[1], cand[2])
		end
	end
	s.candidate = { x, y }
	self:UpdateStrokePreview()
end

-- Local-only preview from the last committed point to the held-back candidate.
function ArtPad:UpdateStrokePreview()
	local line = self.strokePreview
	local s = self.currentStroke
	if not line then return end
	if not s or not s.candidate or self.loopback then
		line:Hide()
		return
	end
	line:SetColorTexture(s.r, s.g, s.b, s.a)
	line:SetThickness(s.w)
	line:SetStartPoint("BOTTOMLEFT", self.mainFrame, s.px[s.n], s.py[s.n])
	line:SetEndPoint("BOTTOMLEFT", self.mainFrame, s.candidate[1], s.candidate[2])
	line:Show()
end

function ArtPad:EndStroke()
	local s = self.currentStroke
	if s and s.candidate then
		self:CommitPoint(s.candidate[1], s.candidate[2])
		s.candidate = nil
	end
	if s then
		s.done = true -- the queue sends the rest at its own pace; no forced send here
		self:QueueFlush()
	end
	self.currentStroke = nil
	self:UpdateStrokePreview()
end

-- Commit a whole shape (straight-edged polyline) as one stroke.
function ArtPad:DrawShape(points)
	if #points < 4 then return end
	self:BeginStroke(points[1], points[2], false)
	for k = 3, #points, 2 do
		self:CommitPoint(points[k], points[k + 1])
	end
	self:EndStroke()
end

function ArtPad:PlaceStamp(key, x, y)
	if not self.STAMPS[key] then return end
	local localId = self:NewLocalId()
	local id = self.playerName .. ":" .. localId
	local size = self:GetStampSize()
	if not self.loopback then
		self:AddStamp(id, self.playerName, key, x, y, size)
	end
	self:PushUndo(id)
	self:QueueCommand(("M(%s,%s,%d,%d,%d)"):format(localId, key, x, y, size))
end

-- Share a backdrop map (with your explored overlays) with everyone; nil removes it.
function ArtPad:ShareBackdrop(mapID, overlays)
	overlays = mapID and overlays or ""
	if not self.loopback then
		self.backdropBy = mapID and "you" or nil
		self:SetBackdrop(mapID, overlays)
	end
	self:QueueCommand("B(" .. (mapID or 0) .. (overlays ~= "" and (";" .. overlays) or "") .. ")")
end

function ArtPad:EraseAt(x1, y1, x2, y2)
	local hits = self:HitTest(x1, y1, x2, y2, self:GetEraserRadius())
	if not next(hits) then return end
	-- Merge into the erase entry at the back of the queue while the eraser keeps moving
	local q = self.outQueue
	local entry = q[#q]
	if not (entry and entry.erase) then
		entry = { erase = {} }
		tinsert(q, entry)
	end
	local map = entry.erase
	for id, h in pairs(hits) do
		local out = map[id]
		if h == true then
			map[id] = true
		elseif out ~= true then
			out = out or {}
			for _, i in ipairs(h) do out[i] = true end
			map[id] = out
		end
	end
	if not self.loopback then
		self:ApplyErase(hits)
	end
	self:QueueFlush()
end

function ArtPad:PlaceText(x, y, text)
	text = text:gsub("[\r\n]", " ")
	if text == "" then return end
	local localId = self:NewLocalId()
	local c = self.brushColor
	local id = self.playerName .. ":" .. localId
	local size = math.floor(14 * self:CanvasPerPixel() + 0.5)
	if not self.loopback then
		self:AddText(id, self.playerName, x, y, text, c, size)
	end
	self:PushUndo(id)
	self:QueueCommand(("T(%s,%d,%d,%s,%d;%s)"):format(localId, x, y, self.ColorString(c), size, text))
end

function ArtPad:ClearForEveryone()
	self.currentStroke = nil
	if not self.loopback then
		self:ClearCanvas()
	end
	-- Anything still queued is about to be cleared anyway
	wipe(self.outQueue)
	self:QueueCommand("X()")
end

--[[ Receiving ]]

local STROKE_HEADER = "^([^,]+),(%d+)," .. NUM .. "," .. NUM .. "," .. NUM .. "," .. NUM .. "," .. NUM .. ",([01])$"
local TEXT_PATTERN = "^([^,]+)," .. NUM .. "," .. NUM .. "," .. NUM .. "," .. NUM .. "," .. NUM .. "," .. NUM .. "," .. NUM .. ";(.*)$"
local STAMP_PATTERN = "^([^,]+),(%w+),(%-?%d+),(%-?%d+),(%d+)$"

-- A live message can carry several commands, one per line, applied in order.
function ArtPad:ApplyLivePacket(msg, author, isReplay)
	local anonymous = false
	for cmd in msg:gmatch("[^\n]+") do
		if cmd == "H()" then
			anonymous = true -- the sender doesn't want their name shown
		else
			self:ApplyLive(cmd, author, isReplay, anonymous)
		end
	end
end

-- Apply one live command from `author` (a short name). isReplay = re-applied after a sync.
function ArtPad:ApplyLive(msg, author, isReplay, anonymous)
	local kind, body = msg:match("^(%a)%((.*)%)$")
	if not kind then return end
	local fromOther = author ~= self.playerName and not isReplay
	-- Name tags and "is drawing" are only ever shown for other people, never yourself.
	local showTag = fromOther and not anonymous

	if kind == "S" then
		local head, pts = body:match("^([^;]*);(.*)$")
		if not head then return end
		local lid, start, r, g, b, a, w, smooth = head:match(STROKE_HEADER)
		if not lid then return end
		local xs, ys = self.DecodePoints(pts)
		if not xs then return end
		local s = self:GetStroke(author .. ":" .. lid, author,
			{ r = tonumber(r), g = tonumber(g), b = tonumber(b), a = tonumber(a) }, w, smooth == "1")
		if not s then return end
		local i = tonumber(start)
		for k = 1, #xs do
			self:SetStrokePoint(s, i + k - 1, xs[k], ys[k])
		end
		local lastX, lastY = xs[#xs], ys[#ys]
		if showTag and lastX then
			self:ShowNameTag(author, lastX, lastY)
			self:MarkActive(author)
			self:NotifyActivity()
		end
	elseif kind == "R" then
		local hits = {}
		for entry in body:gmatch("[^;]+") do
			local id, spec = entry:match("^(.+)=([^=]+)$")
			if id then
				if spec == "*" then
					hits[id] = true
				else
					local list = {}
					for part in spec:gmatch("[^,]+") do
						local from, to = part:match("^(%d+)%-(%d+)$")
						if from then
							for n = tonumber(from), math.min(tonumber(to), tonumber(from) + 10000) do
								tinsert(list, n)
							end
						elseif tonumber(part) then
							tinsert(list, tonumber(part))
						end
					end
					hits[id] = list
				end
			end
		end
		self:ApplyErase(hits)
	elseif kind == "T" then
		local lid, x, y, r, g, b, a, size, text = body:match(TEXT_PATTERN)
		if lid and text ~= "" then
			self:AddText(author .. ":" .. lid, author, tonumber(x), tonumber(y), text,
				{ r = tonumber(r), g = tonumber(g), b = tonumber(b), a = tonumber(a) }, size)
			if showTag then
				self:ShowNameTag(author, tonumber(x), tonumber(y))
				self:MarkActive(author)
				self:NotifyActivity()
			end
		end
	elseif kind == "M" then
		local lid, key, x, y, size = body:match(STAMP_PATTERN)
		if lid then
			x, y = tonumber(x), tonumber(y)
			self:AddStamp(author .. ":" .. lid, author, key, x, y, tonumber(size))
			if showTag then
				self:ShowNameTag(author, x, y)
				self:MarkActive(author)
				self:NotifyActivity()
			end
		end
	elseif kind == "B" then
		local id, overlays = body:match("^(%d+);?(.*)$")
		local mapID = tonumber(id)
		if mapID then
			self.backdropBy = mapID ~= 0 and (anonymous and "someone" or author) or nil
			self:SetBackdrop(mapID ~= 0 and mapID or nil, overlays)
			if fromOther then
				self:Notify(mapID ~= 0 and (author .. " put up a map.") or (author .. " took the map down."), "info", { quiet = true })
			end
		end
	elseif kind == "L" then
		if isReplay then return end -- lasers are momentary
		local lid, start, pts = body:match("^([^,]+),(%d+);(.*)$")
		local xs, ys
		if pts then xs, ys = self.DecodePoints(pts) end
		if not xs or #xs == 0 then return end
		start = tonumber(start)
		local last = self.laserLast[author]
		local px, py
		if last and last.lid == lid and last.n == start - 1 then px, py = last.x, last.y end
		for k = 1, #xs do
			if px then self:DrawLaserSegment(px, py, xs[k], ys[k]) end
			px, py = xs[k], ys[k]
		end
		self.laserLast[author] = { lid = lid, n = start + #xs - 1, x = px, y = py }
		if showTag then self:ShowNameTag(author, px, py) end
	elseif kind == "U" then
		-- The id is built from the sender's name, so people can only undo their own items.
		self:RemoveItem(author .. ":" .. body)
	elseif kind == "X" then
		self:ClearCanvas()
		if fromOther then
			self:Notify(author .. " cleared the canvas.", "info")
		end
	end
end

function ArtPad:OnLiveMessage(prefix, msg, disType, sender)
	local author = ShortName(sender)
	local me = self:RefreshPlayerName()
	if self.loopback then
		if disType ~= "WHISPER" or author ~= me then return end
	elseif author == me or not self:AcceptsDistribution(disType) or not self:ValidateSender(sender) then
		return
	end
	if self.syncing then
		tinsert(self.syncBuffer, { msg, author })
	end
	if self.DEBUG then
		self:Debug(("recv %s %dB from %s"):format(msg:sub(1, 1), #msg, author))
	end
	self:ApplyLivePacket(msg, author)
end

--[[ Sync ]]

function ArtPad:EncodeData(data)
	local compressed = LibDeflate:CompressDeflate(self:Serialize(data))
	return (LibDeflate:EncodeForWoWAddonChannel(compressed))
end

function ArtPad:DecodeData(data)
	local decoded = LibDeflate:DecodeForWoWAddonChannel(data)
	local decompressed = decoded and LibDeflate:DecompressDeflate(decoded)
	if not decompressed then
		self:Debug("error decompressing data")
		return nil
	end
	local ok, final = self:Deserialize(decompressed)
	if not ok then
		self:Debug("error deserializing: " .. tostring(final))
		return nil
	end
	return final
end

function ArtPad:GetSnapshotData()
	local cache = self.snapshotCache
	if not cache or cache.version ~= self.canvasVersion then
		cache = { version = self.canvasVersion, data = self:EncodeData(self:SerializeCanvas()) }
		self.snapshotCache = cache
	end
	return cache.data
end

function ArtPad:StartSync(reason)
	if self.syncing then return end
	local channel = self:GetChannel()
	if not channel then
		self:Debug("sync (" .. reason .. "): nobody to sync with")
		return
	end
	self:Debug("sync start: " .. reason)
	self.syncing = true
	self.syncNonce = string.format("%06x", math.random(0, 0xFFFFFF))
	self.syncOffers = {}
	self.syncBuffer = {}
	self.syncPhase = "searching"
	self.syncStarted = GetTime()
	self.syncProgress = nil
	self:RequestRefresh()
	local nonce = self.syncNonce
	self:SendCommMessage(self.syncPrefix, "Q(" .. nonce .. ")", channel, nil, "ALERT")
	C_Timer.After(SYNC_COLLECT, function() self:RequestSnapshot(nonce) end)
end

-- Ask the best remaining offer for its canvas; falls through to the next one on timeout.
function ArtPad:RequestSnapshot(nonce)
	if not self.syncing or nonce ~= self.syncNonce then return end
	local best
	for _, offer in ipairs(self.syncOffers) do
		if not offer.tried and (not best or offer.count > best.count
				or (offer.count == best.count and offer.bytes < best.bytes)) then
			best = offer
		end
	end
	if not best then
		self:Debug("sync: no (more) canvas offers")
		-- Everyone we asked failed us: say so (with a retry) rather than silently giving up.
		self:FinishSync(nil, nil, self.syncSource)
		return
	end
	best.tried = true
	self.syncSource = best.sender
	self.syncPhase = "downloading"
	self.syncProgress = 0
	self.syncDownloadStarted = GetTime()
	self.syncChunks = nil
	self:RequestRefresh()
	self:Debug(("sync: requesting %d items (%d bytes) from %s"):format(best.count, best.bytes, best.sender))
	self:SendCommMessage(self.syncPrefix, "G(" .. nonce .. ")", "WHISPER", best.sender, "ALERT")
	-- Until the first chunk shows up; after that, each chunk re-arms a shorter timeout.
	self:ArmSyncTimeout(nonce, 15)
end

-- Give up on the current source if nothing arrives within `seconds`; progress re-arms it.
function ArtPad:ArmSyncTimeout(nonce, seconds)
	local token = {}
	self.syncToken = token
	C_Timer.After(seconds, function()
		if self.syncing and self.syncToken == token then
			self:Debug("sync: timed out waiting for " .. tostring(self.syncSource))
			self:RequestSnapshot(nonce)
		end
	end)
end

function ArtPad:FinishSync(snapshot, from, failedFrom)
	local buffer = self.syncBuffer
	self.syncing = false
	self.syncToken = nil
	self.syncSource = nil
	self.syncBuffer = {}
	self.syncPhase = nil
	self.syncProgress = nil
	self:RequestRefresh()
	if failedFrom then
		self:Notify(("Couldn't load the canvas from %s."):format(ShortName(failedFrom)), "error", {
			action = { "Retry", function() self:StartSync("retry") end },
		})
	elseif not snapshot then
		self:Notify("Nobody else has a drawing up yet. You're starting fresh!", "info", { quiet = true })
	end
	if snapshot then
		local undo = self.undoStack
		self.undoStack = {}
		local ok, err = pcall(self.LoadCanvas, self, snapshot)
		if not ok then
			self:Debug("sync: bad snapshot: " .. tostring(err))
		end
		for _, entry in ipairs(buffer) do
			self:ApplyLivePacket(entry[1], entry[2], true)
		end
		-- Re-add any of our in-progress stroke that hasn't been sent yet.
		local s = self.currentStroke
		if s and not self.loopback then
			for i = 1, s.n do self:MirrorStrokePoint(i) end
		end
		for _, id in ipairs(undo) do
			if self.itemsById[id] then tinsert(self.undoStack, id) end
		end
		if #self.items > 0 then
			self:Notify(("Loaded the canvas from %s."):format(ShortName(from)), "success", { quiet = true })
			self:NotifyActivity()
		end
	end
end

function ArtPad:OnSyncMessage(prefix, msg, disType, sender)
	local kind, arg = msg:match("^(%a)%(([^)]*)%)")
	-- Our own canvas request coming back tells us the name others see us by.
	if kind == "Q" and self.syncNonce and arg == self.syncNonce then
		self:LearnOwnName(sender)
		return
	end
	if self:IsSelf(sender) then return end
	if not kind then return end

	if kind == "Q" then
		if disType == "WHISPER" or not self:AcceptsDistribution(disType) then return end
		-- Answer even while syncing ourselves (if we have something): otherwise two people
		-- joining at once would each wait on the other. The joiner picks the fullest canvas.
		if #self.items == 0 then return end
		local data = self:GetSnapshotData()
		self:SendCommMessage(prefix, ("H(%s,%d,%d)"):format(arg, #self.items, #data), "WHISPER", sender, "ALERT")
	elseif disType ~= "WHISPER" then
		return
	elseif kind == "H" then
		local nonce, count, bytes = arg:match("^(%x+),(%d+),(%d+)$")
		if self.syncing and nonce == self.syncNonce and self:ValidateSender(sender) then
			tinsert(self.syncOffers, { sender = sender, count = tonumber(count), bytes = tonumber(bytes) })
		end
	elseif kind == "G" then
		self:SendSnapshot(arg, sender)
	end
end

--[[ Snapshot transfer

	Each addon prefix may only send about one message per second (after a burst of 10), so
	one long message - split into 255-byte parts on a single prefix - would crawl. Instead
	the snapshot goes out as numbered chunks, round-robin over several data prefixes that
	each have their own allowance:  P(nonce,i,n)<chunk>
	ChatThrottleLib still caps total traffic (~800 bytes/s), which keeps us polite.
]]

local CHUNK_BYTES = 225

function ArtPad:SendSnapshot(nonce, target)
	local data = self:GetSnapshotData()
	local n = math.max(1, math.ceil(#data / CHUNK_BYTES))
	self:Debug(("sync: sending canvas to %s (%d bytes, %d chunks)"):format(target, #data, n))
	for i = 1, n do
		local prefix = self.dataPrefixes[(i - 1) % #self.dataPrefixes + 1]
		local chunk = data:sub((i - 1) * CHUNK_BYTES + 1, i * CHUNK_BYTES)
		self:SendCommMessage(prefix, ("P(%s,%d,%d)"):format(nonce, i, n) .. chunk, "WHISPER", target, "BULK")
	end
end

function ArtPad:OnDataMessage(prefix, msg, disType, sender)
	if disType ~= "WHISPER" or not self.syncing then return end
	local nonce, i, n, chunk = msg:match("^P%((%x+),(%d+),(%d+)%)(.*)$")
	if not nonce or nonce ~= self.syncNonce or ShortName(sender) ~= ShortName(self.syncSource) then return end
	i, n = tonumber(i), tonumber(n)
	local parts = self.syncChunks
	if not parts or parts.n ~= n then
		parts = { n = n, have = 0 }
		self.syncChunks = parts
	end
	if i < 1 or i > n or parts[i] then return end
	parts[i] = chunk
	parts.have = parts.have + 1
	-- Real progress from what has actually arrived
	self.syncProgress = math.floor(parts.have / n * 100)
	self:RequestRefresh()
	if parts.have < n then
		self:ArmSyncTimeout(nonce, 15) -- still arriving: keep waiting as long as chunks come in
		return
	end
	self.syncChunks = nil
	local snapshot = self:DecodeData(table.concat(parts, "", 1, n))
	if type(snapshot) == "table" and type(snapshot.items) == "table" then
		self:FinishSync(snapshot, sender)
	else
		self:RequestSnapshot(nonce)
	end
end

--[[ Version check ]]

function ArtPad:OnVersionMessage(prefix, message, disType, sender)
	local theirs, ours = tonumber(message), tonumber(self.version)
	if theirs and ours and theirs > ours and not self.newerVersion then
		self.newerVersion = message
		self:UpdateTitle()
	end
end
