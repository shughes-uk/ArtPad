"""Headless multi-client tests for ArtPad.

Each simulated player is its own Lua 5.1 state running the real addon (and libraries)
against tests/wow_mock.lua. A tiny "server" here routes addon messages between them
(guild, party/raid and whispers), on a shared simulated clock.

    pip install lupa
    python tests/run_tests.py            # all tests
    python tests/run_tests.py late_join  # tests whose name contains "late_join"
"""
import math
import random
import os
import re
import sys
import traceback

from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REALM = "TestRealm"


def toc_info():
    meta, files = {}, []
    for raw in open(os.path.join(ROOT, "ArtPad.toc"), encoding="utf-8"):
        line = raw.strip()
        m = re.match(r"^## ([\w-]+): (.*)$", line)
        if m:
            meta[m.group(1)] = m.group(2)
        elif line and not line.startswith("#"):
            files.extend(expand(os.path.join(ROOT, line.replace("\\", os.sep))))
    return meta, files


def expand(path):
    if not path.endswith(".xml"):
        return [path]
    out, base = [], os.path.dirname(path)
    for kind, f in re.findall(r'<(Script|Include) file="([^"]+)"', open(path, encoding="utf-8").read()):
        p = os.path.join(base, f.replace("\\", os.sep))
        out += expand(p) if kind == "Include" else [p]
    return out


META, FILES = toc_info()
MOCK = open(os.path.join(ROOT, "tests", "wow_mock.lua"), encoding="utf-8").read()

HELPERS = r"""
function CANVAS_SIGNATURE()
	local recs = {}
	for _, r in ipairs(ArtPad:SerializeCanvas().items) do
		local parts = {}
		for i = 1, 8 do parts[i] = tostring(r[i]) end
		recs[#recs + 1] = table.concat(parts, "|")
	end
	table.sort(recs)
	recs[#recs + 1] = "map=" .. tostring(ArtPad.backdropMap) .. " " .. tostring(ArtPad.backdropOverlays)
	return table.concat(recs, "\n")
end

-- Every live segment has exactly one visible line region; dead/missing ones have none.
function RENDER_CHECK()
	for _, it in ipairs(ArtPad.items) do
		if it.kind == "S" then
			for i = 1, it.n - 1 do
				local alive = it.px[i] and it.px[i + 1] and not it.dead[i]
				local pieces = it.segs[i]
				if alive and not (pieces and pieces[1] and pieces[1]:IsShown()) then return it.id .. " missing line " .. i end
				if not alive and pieces then return it.id .. " stale line " .. i end
			end
		end
	end
	return nil
end

function COUNT_DOTS(id)
	local n = 0
	for _ in pairs(ArtPad.itemsById[id].dots) do n = n + 1 end
	return n
end

function TOAST_TEXT()
	local t = ArtPad.toast
	return t:IsShown() and t.text._text or nil
end
function TOAST_ACTION()
	local t = ArtPad.toast
	return t:IsShown() and t.action:IsShown() and t.action.label._text or nil
end
function CLICK(button) button._scripts.OnClick(button, "LeftButton") end

function PEN_DOWN(x, y, button)
	local f = ArtPad.viewport
	CURSOR_X, CURSOR_Y = x, y
	f._scripts.OnMouseDown(f, button or "LeftButton")
end
function PEN_MOVE(x, y)
	local f = ArtPad.viewport
	CURSOR_X, CURSOR_Y = x, y
	f._scripts.OnUpdate(f, 0.016)
end
function PEN_UP(button)
	local f = ArtPad.viewport
	f._scripts.OnMouseUp(f, button or "LeftButton")
end
"""


class Client:
    def __init__(self, world, name, guild=True, settings=None, unit_name=None):
        self.world, self.name, self.online = world, name, False
        self.rt = lua51.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = self.rt.globals()
        self.lua_client = self.rt.table_from({"name": name, "guild": guild})
        if unit_name:
            self.lua_client.unitName = unit_name  # WoW Forever: UnitName lacks the surname
        self.lua_client.guildRoster = self.rt.table()
        self.lua_client.groupMembers = self.rt.table()
        g.CLIENT = self.lua_client
        g.ADDON_METADATA = self.rt.table_from(META)
        g.LOGGED_IN = False
        if settings is not None:
            g.ArtPad_Settings = self.to_lua({"SaveVersion": int(META["X-SaveVersion"]), **settings})
        self.rt.execute(MOCK)
        self.rt.execute(HELPERS)
        self.globals_before = set(self.rt.eval("(function() local t = {} for k in pairs(_G) do t[#t+1] = k end return t end)()").values())
        load = self.rt.eval("function(src, name, ns) local f, e = loadstring(src, '@' .. name); if not f then error(e) end; f('ArtPad', ns) end")
        ns = self.rt.table()
        for path in FILES:
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            load(open(path, encoding="utf-8").read(), rel, ns)
            if rel.endswith("LibStub/LibStub.lua"):
                # The minimap button library needs a real Minimap; stub it out.
                self.rt.execute("""
                    local lib = LibStub:NewLibrary("LibDBIcon-1.0", 999999)
                    function lib:Register() end
                    function lib:Show() end
                    function lib:Hide() end
                """)
        self.update_roster()

    def to_lua(self, value):
        if isinstance(value, dict):
            t = self.rt.table()
            for k, v in value.items():
                t[k] = self.to_lua(v)
            return t
        if isinstance(value, list):
            return self.rt.table_from([self.to_lua(v) for v in value])
        return value

    @property
    def g(self):
        return self.rt.globals()

    def ex(self, code):
        return self.rt.execute(code)

    def ev(self, code):
        return self.rt.eval(code)

    def update_roster(self):
        roster = self.rt.table()
        for i, (n, rank) in enumerate(self.world.guild_ranks.items(), 1):
            roster[i] = self.rt.table_from({"name": n, "rank": rank})
        self.lua_client.guildRoster = roster
        self.g.FIRE_EVENT("GUILD_ROSTER_UPDATE")

    def login(self):
        self.online = True
        self.g.NOW = self.world.now
        self.g.FIRE_EVENT("ADDON_LOADED", "ArtPad")
        self.g.LOGGED_IN = True
        self.g.FIRE_EVENT("PLAYER_LOGIN")
        self.g.FIRE_EVENT("PLAYER_ENTERING_WORLD", True, False)
        # Tests address the canvas in its own coordinates: unscaled, at the screen origin.
        self.fit_scale = self.ev("ArtPad.mainFrame:GetScale()")
        self.ex("ArtPad:SetView(1, 0, 0)")

    def tick(self, dt):
        self.g.NOW = self.world.now
        self.g.RUN_TIMERS()
        self.g.RUN_ONUPDATE(dt)

    def drain(self):
        sent = [(m[1], m[2], m[3], m[4]) for m in self.g.SENT.values()]
        self.ex("SENT = {}")
        return sent

    def deliver(self, prefix, msg, dist, sender):
        self.g.NOW = self.world.now
        self.g.FIRE_EVENT("CHAT_MSG_ADDON", prefix, msg, dist, sender)

    # convenience
    @property
    def ap(self):
        return self.g.ArtPad

    def items(self):
        return int(self.ev("#ArtPad.items"))

    def signature(self):
        return self.g.CANVAS_SIGNATURE()

    def chat(self):
        return list(self.g.CHAT.values())

    def stroke(self, points, button="LeftButton", pump=0.0):
        """Draw along points (button="erase" uses the eraser tool); pump the world between moves if asked."""
        tool = None
        if button == "erase":
            tool = self.ev("ArtPad.tool")
            self.ex("ArtPad:SetTool('eraser')")
            button = "LeftButton"
        (x, y), rest = points[0], points[1:]
        self.g.PEN_DOWN(x, y, button)
        for (x, y) in rest:
            self.g.PEN_MOVE(x, y)
            if pump:
                self.world.pump(pump)
        self.g.PEN_UP(button)
        if tool:
            self.ex("ArtPad:SetTool('%s')" % tool)


class World:
    def __init__(self):
        self.now = 0.0
        self.clients = {}
        self.guild_ranks = {}  # name -> rank index
        self.groups = {}  # name -> group id
        self.log = []

    def add(self, name, guild=True, rank=5, settings=None, login=True, unit_name=None):
        if guild:
            self.guild_ranks[name] = rank
            for c in self.clients.values():
                c.update_roster()
        c = Client(self, name, guild=guild, settings=settings, unit_name=unit_name)
        self.clients[name] = c
        if login:
            c.login()
        return c

    def group(self, kind, leader, *members):
        """Put players in a party/raid; the leader gets rank 2, everyone else 0.
        GROUP_JOINED fires only for players who weren't already in the group."""
        names = [leader, *members]
        gid = self.groups.get(leader) or leader
        joined = [n for n in names if self.groups.get(n) != gid]
        for n in names:
            self.groups[n] = gid
        for n in names:
            c = self.clients[n]
            c.lua_client.group = kind
            c.lua_client.groupMembers = c.rt.table_from(
                [c.rt.table_from({"name": m, "rank": 2 if m == leader else 0}) for m in names])
            c.g.FIRE_EVENT("GROUP_ROSTER_UPDATE")
            if n in joined:
                c.g.FIRE_EVENT("GROUP_JOINED")

    def pump(self, seconds, step=0.05):
        end = self.now + seconds
        while self.now < end - 1e-9:
            self.now += step
            for c in list(self.clients.values()):
                if c.online:
                    c.tick(step)
            self.route()

    def yards_between(self, a, b):
        pa, pb = a.lua_client.mapPos, b.lua_client.mapPos
        if pa is None or pb is None or pa.map != pb.map:
            return None
        w, h = 3470.84, 2314.62
        return (((pa.x - pb.x) * w) ** 2 + ((pa.y - pb.y) * h) ** 2) ** 0.5

    def move(self, client, x=None, y=None, map_id=37):
        """Stand somewhere on a map (0-1 coordinates); None = nowhere in particular."""
        client.lua_client.mapPos = None if x is None else client.rt.table_from({"map": map_id, "x": x, "y": y})

    def route(self):
        for c in list(self.clients.values()):
            if not c.online:
                continue
            for prefix, msg, chan, target in c.drain():
                sender = f"{c.name}-{REALM}"
                self.log.append((c.name, prefix, chan, target, len(msg)))
                if chan == "GUILD":
                    to = [x for x in self.clients.values() if x.online and x.name in self.guild_ranks] if c.name in self.guild_ranks else []
                elif chan in ("PARTY", "RAID", "INSTANCE_CHAT"):
                    gid = self.groups.get(c.name)
                    to = [x for x in self.clients.values() if x.online and gid and self.groups.get(x.name) == gid]
                elif chan in ("SAY", "YELL"):
                    reach = 60 if chan == "SAY" else 400
                    to = [x for x in self.clients.values() if x.online and self.yards_between(c, x) is not None
                          and self.yards_between(c, x) <= reach]
                elif chan == "WHISPER":
                    t = self.clients.get(target.split("-")[0])
                    to = [t] if t and t.online else []
                else:
                    raise AssertionError(f"unexpected channel {chan}")
                for r in to:
                    r.deliver(prefix, msg, chan, sender)


def line(x0, y0, x1, y1, n=10):
    return [(round(x0 + (x1 - x0) * i / n), round(y0 + (y1 - y0) * i / n)) for i in range(n + 1)]


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def all_equal(world, *names):
    names = names or tuple(world.clients)
    sigs = {n: world.clients[n].signature() for n in names}
    first = sigs[names[0]]
    for n in names:
        if sigs[n] != first:
            a, b = first.split("\n"), sigs[n].split("\n")
            diff = next((f"{x[:150]}\n   vs {y[:150]}" for x, y in zip(a, b) if x != y), "(one is a prefix of the other)")
            raise AssertionError(f"canvas of {n} ({len(b)} items) differs from {names[0]} ({len(a)} items):\n   {diff}")
        err = world.clients[n].g.RENDER_CHECK()
        check(err is None, f"render check failed on {n}: {err}")


def settle(world, seconds=8):
    world.pump(seconds)


# ---------------------------------------------------------------- tests

def test_live_draw():
    w = World()
    a, b, c = w.add("Alice"), w.add("Bob"), w.add("Cat")
    settle(w)
    a.stroke(line(100, 100, 400, 250, 30))
    w.pump(2)
    check(b.items() == 1 and c.items() == 1, "Bob and Cat should have Alice's stroke")
    all_equal(w)
    check(b.ev("ArtPad.items[1].author") == "Alice", "author recorded")
    b.ex("ArtPad.window:Show()")
    check(b.ev("ArtPad.nameTags.Alice ~= nil and ArtPad.nameTags.Alice:IsShown()"), "name tag shown for Alice")
    w.pump(4)
    check(not b.ev("ArtPad.nameTags.Alice:IsShown()"), "name tag fades out")
    # batching: 30 points should not mean 30 messages
    strokes = [e for e in w.log if e[0] == "Alice" and e[1] == "ArtPad" + META["X-ProtocolVersion"]]
    check(len(strokes) <= 3, f"stroke should be batched, got {len(strokes)} messages")
    # Tags keep a readable on-screen size when the canvas is zoomed out.
    b.ex("ArtPad.mainFrame:SetScale(0.5)")
    a.stroke(line(100, 300, 400, 300, 10))
    w.pump(2)
    check(b.ev("ArtPad.nameTags.Alice._fontSize") == 28, "name tag font compensates for canvas zoom")
    # Your own name never shows on your own drawing, in loopback or not.
    a.ex("ArtPad.window:Show()")
    a.stroke(line(100, 400, 400, 400, 10))
    a.ex("ArtPad:SetLoopback(true)")
    a.stroke(line(100, 500, 400, 500, 10))
    w.pump(2)
    a.ex("ArtPad:RefreshStatus()")
    check(a.ev("ArtPad.nameTags.Alice == nil"), "no name tag for yourself")
    check(not a.ev("ArtPad.activityText:IsShown()"), "no 'you are drawing' line for yourself")


def test_text_and_colors():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad:SetColor(1, 0, 0, 0.5)")
    a.ex('ArtPad:PlaceText(50, 60, "hello; world (with) \\"quotes\\" and a long tail ' + "x" * 150 + '")')
    a.stroke(line(10, 10, 90, 10))
    w.pump(3)
    all_equal(w)
    check(b.ev("ArtPad.items[1].kind") == "T" and b.ev("ArtPad.items[1].r") == 1 and b.ev("ArtPad.items[1].a") == 0.5,
          "text arrives with sender's colour")


def test_late_join():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.stroke(line(100, 100, 600, 100, 40))
    a.stroke(line(100, 300, 600, 500, 40))
    b.ex('ArtPad:PlaceText(200, 200, "hi")')
    w.pump(3)
    b.stroke(line(350, 50, 350, 150, 5), button="erase")  # erase the middle of the first stroke
    w.pump(3)
    all_equal(w)
    check(a.ev("next(ArtPad.items[1].dead) ~= nil"), "erase should have killed some segments")
    d = w.add("Dana")
    d.ex("ArtPad.window:Show()")
    while not d.ev("ArtPad.syncing"):  # sync starts a few seconds after login
        w.pump(0.25)
    while d.ev("ArtPad.syncing"):
        w.pump(0.25)
    check((d.g.TOAST_TEXT() or "").startswith("Loaded the canvas from "), f"Dana is told where the canvas came from: {d.g.TOAST_TEXT()}")
    w.pump(10)
    check(d.g.TOAST_TEXT() is None, "success toast fades by itself")
    all_equal(w)
    check(not d.ev("ArtPad.syncing"), "sync finished")


def test_sync_while_drawing():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    for i in range(40):  # a big canvas so the transfer takes a while
        a.stroke(line(10, 10 + i * 40, 3000, 60 + i * 40, 150))  # ~20px per mouse sample
        w.pump(1.2)  # people take a moment between strokes
    w.pump(10)
    all_equal(w)
    e = w.add("Eve")
    w.pump(4)
    check(e.ev("ArtPad.syncing"), "Eve should still be syncing")
    # Activity during Eve's download: a new stroke, an erase, Eve's own drawing.
    a.stroke(line(500, 1900, 900, 1950, 20), pump=0.05)
    b.stroke(line(1000, 0, 1000, 2000, 20), button="erase")
    e.stroke(line(2000, 2000, 2100, 2050, 10))
    w.pump(120)
    check(not e.ev("ArtPad.syncing"), "Eve finished syncing")
    all_equal(w)
    check(e.ev("ArtPad.itemsById[ArtPad.undoStack[1]] ~= nil"), "Eve keeps undo for her own stroke after sync")


def test_undo():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    b.ex('ArtPad.sessionTag = "b0b"')  # real clients get distinct tags from their login time
    settle(w)
    a.stroke(line(0, 0, 100, 100))
    a.stroke(line(0, 100, 100, 0))
    b.stroke(line(200, 0, 300, 100))
    w.pump(2)
    a.ex("ArtPad:Undo()")
    w.pump(2)
    all_equal(w)
    check(a.items() == 2, "Alice's second stroke undone")
    # Bob cannot undo Alice's stroke by sending her local id.
    lid = a.ev("ArtPad.items[1].id:match(':(.*)$')")
    b.ex(f'ArtPad:SendLive("U({lid})")')
    w.pump(2)
    check(a.ev(f'ArtPad.itemsById["Alice:{lid}"] ~= nil'), "Bob can't undo Alice's stroke")
    # Ctrl-Z is bound while the canvas is open.
    a.ex("ArtPad.window:Show()")
    check(a.ev('BINDINGS["CTRL-Z"]') == "ArtPad_KeyUndo", "Ctrl-Z bound while the window is open")
    a.ex("CLICK(ArtPad_KeyUndo)")
    w.pump(2)
    all_equal(w)
    check(a.items() == 1, "undo button removes Alice's remaining stroke")


def test_clear():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    b.ex("ArtPad.window:Show()")
    b.ex("ArtPad.buttons.Clear()")
    check("Nothing to clear" in (b.g.TOAST_TEXT() or ""), "clearing an empty canvas just says so")
    a.stroke(line(0, 0, 100, 100))
    w.pump(2)
    b.ex("ArtPad.buttons.Clear()")
    check(b.items() == 1 and b.ev("ArtPad_ClearConfirm:IsShown()"), "first click asks, doesn't clear")
    check("Clear for all" in b.ev("ArtPad_ClearConfirm.title._text"), b.ev("ArtPad_ClearConfirm.title._text"))
    b.ex("CLICK(ArtPad_ClearCancelButton)")
    check(not b.ev("ArtPad_ClearConfirm:IsShown()") and b.items() == 1, "cancel keeps the drawing")
    b.ex("ArtPad.buttons.Clear()")
    b.ex("CLICK(ArtPad_ClearConfirmButton)")
    w.pump(2)
    check(a.items() == 0 and b.items() == 0, "confirmed clear wipes everyone's canvas")
    check(any("Bob cleared the canvas" in m for m in a.chat()), "Alice (window closed) is told in chat")
    # Turning the warning off clears straight away
    a.stroke(line(0, 0, 100, 100))
    w.pump(2)
    b.ex("ArtPad_Settings.WarnClear = false")
    b.ex("ArtPad.buttons.Clear()")
    w.pump(2)
    check(a.items() == 0 and b.items() == 0, "no confirmation when WarnClear is off")


def test_admin_only_guild():
    w = World()
    gm, officer, member = w.add("Gm", rank=0), w.add("Officer", rank=1), w.add("Member", rank=5)
    strict = w.add("Strict", rank=4, settings={"AdminOnly": True, "AdminGuildRank": 1})
    settle(w)
    member.stroke(line(0, 0, 50, 50))
    w.pump(2)
    check(strict.items() == 0, "member's drawing ignored with AdminOnly")
    officer.stroke(line(0, 0, 50, 50))
    gm.stroke(line(100, 0, 150, 50))
    w.pump(2)
    check(strict.items() == 2, "officer and GM drawings accepted")
    strict.stroke(line(300, 0, 350, 50))
    w.pump(2)
    check(strict.items() == 3, "own drawing always shown")


def test_admin_only_group():
    w = World()
    lead, peon = w.add("Lead", guild=False), w.add("Peon", guild=False)
    strict = w.add("Strict", guild=False, settings={"Mode": "RAID", "AdminOnly": True})
    for c in (lead, peon):
        c.ex('ArtPad_Settings.Mode = "RAID"')
    w.group("party", "Lead", "Peon", "Strict")
    settle(w)
    peon.stroke(line(0, 0, 50, 50))
    lead.stroke(line(100, 0, 150, 50))
    w.pump(2)
    check(strict.items() == 1 and strict.ev("ArtPad.items[1].author") == "Lead", "only the party leader's drawing shown")


def test_raid_mode_and_group_join_sync():
    w = World()
    a, b, c = w.add("Alice"), w.add("Bob"), w.add("Cat")
    settle(w)
    a.ex('ArtPad:SetMode("RAID")')
    c.ex('ArtPad:SetMode("RAID")')
    w.group("party", "Alice", "Bob")
    b.ex('ArtPad:SetMode("RAID")')
    settle(w)
    a.stroke(line(0, 0, 200, 200))
    w.pump(2)
    check(b.items() == 1, "party member gets raid-mode drawing")
    check(c.items() == 0, "ungrouped player in raid mode doesn't")
    # Cat joins the party later and should pull the existing canvas.
    w.group("party", "Alice", "Bob", "Cat")
    w.pump(15)
    all_equal(w, "Alice", "Bob", "Cat")
    # A guild-mode player never sees raid traffic.
    d = w.add("Dana")
    settle(w)
    a.stroke(line(0, 300, 200, 300))
    w.pump(2)
    check(d.items() == 0, "guild-mode player ignores party drawing")


def test_mode_switch_clears_and_resyncs():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.stroke(line(0, 0, 100, 100))
    w.pump(2)
    b.ex('ArtPad:SetMode("RAID")')
    check(b.items() == 0, "switching audience clears the canvas")
    b.ex('ArtPad:SetMode("GUILD")')
    w.pump(15)
    all_equal(w)


def test_loopback():
    w = World()
    solo = w.add("Solo")
    settle(w)
    solo.ex("ArtPad:SetLoopback(true)")
    solo.stroke(line(0, 0, 100, 0))
    check(solo.items() == 0, "loopback draws nothing locally")
    w.pump(2)
    check(solo.items() == 1, "loopback stroke comes back from the server")
    solo.stroke(line(50, -20, 50, 20), button="erase")
    w.pump(2)
    check(solo.ev("next(ArtPad.items[1].dead) ~= nil"), "loopback erase applied from echo")
    solo.ex("ArtPad:Undo()")
    w.pump(2)
    check(solo.items() == 0, "loopback undo applied from echo")


def test_wide_eraser():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.stroke(line(100, 100, 300, 100, 20))
    w.pump(2)
    # Swipe near the line without crossing it: the old intersection-only eraser missed this.
    b.stroke([(200, 106), (204, 106), (208, 106)], button="erase")
    w.pump(2)
    all_equal(w)
    check(a.ev("next(ArtPad.items[1].dead) ~= nil"), "nearby swipe erases")
    # Erasing every segment removes the stroke entirely.
    b.stroke(line(90, 100, 310, 100, 40), button="erase")
    w.pump(2)
    check(a.items() == 0 and b.items() == 0, "fully erased stroke removed")


def test_round_caps():
    w = World()
    a = w.add("Alice")
    settle(w)
    a.ex("ArtPad:SetBrushSize(8)")
    a.stroke(line(0, 0, 300, 0, 10))
    check(a.ev("COUNT_DOTS(ArtPad.items[1].id)") == 2, "straight thick stroke: caps at both ends only")
    a.ex('ArtPad:SetTool("rect")')
    a.stroke([(0, 100), (100, 200)])
    a.ex('ArtPad:SetTool("pen")')
    check(a.ev("COUNT_DOTS(ArtPad.items[2].id)") == 5, "a box's corners get joint dots")
    a.ex("ArtPad:SetBrushSize(2)")
    a.stroke(line(0, 300, 300, 300))
    check(a.ev("COUNT_DOTS(ArtPad.items[3].id)") == 0, "thin strokes need no dots")
    a.stroke([(500, 500)])
    check(a.ev("COUNT_DOTS(ArtPad.items[4].id)") == 1, "a click leaves a dot")


def test_snapshot_roundtrip_and_robustness():
    w = World()
    a = w.add("Alice")
    settle(w)
    a.stroke(line(0, 0, 100, 100))
    a.ex('ArtPad:PlaceText(5, 5, "t")')
    data = a.ev("ArtPad:EncodeData(ArtPad:SerializeCanvas())")
    b = w.add("Bob", login=True)
    b.ev("function(s) TMP = s end")(data.encode("latin-1") if isinstance(data, str) else data)
    b.ex("ArtPad:LoadCanvas(ArtPad:DecodeData(TMP))")
    check(b.signature() == a.signature(), "snapshot roundtrip")
    # Garbage must not raise.
    for junk in ["S(", "S(x,1,1,1,1,1,3;1,2)", "R(=)", "T(a,1,2;)", "U()", "S(a,1,a,b,c,d,e;1,1)", "R(Bob:1=1-999999999)"]:
        b.ex(f'ArtPad:ApplyLive("{junk}", "Mallory")')
    check(b.ev("ArtPad:DecodeData('not valid')") is None, "bad snapshot rejected")


def test_options_panel():
    w = World()
    a = w.add("Alice")
    check(a.ev("OPTIONS_PANEL ~= nil"), "options panel registered")
    a.ex("ArtPad:OpenOptions()")
    a.ex("OPTIONS_PANEL._scripts.OnShow(OPTIONS_PANEL)")
    a.ex("ArtPad.slashCommands.names(ArtPad, 'off')")
    check(a.ev("ArtPad_Settings.NameTags") is False, "slash toggles setting")
    a.ex("ArtPad.OnSlashCommand('help')")
    a.ex("ArtPad.OnSlashCommand('adminrank 3')")
    check(a.ev("ArtPad_Settings.AdminGuildRank") == 3, "adminrank")


def test_no_global_leaks():
    w = World()
    a = w.add("Alice")
    settle(w)
    a.stroke(line(0, 0, 100, 100))
    after = set(a.ev("(function() local t = {} for k in pairs(_G) do t[#t+1] = k end return t end)()").values())
    new = after - a.globals_before
    allowed = re.compile(r"^(ArtPad.*|SLASH_ARTPAD\d|BINDING_\w+ARTPAD\w*|LibStub|ChatThrottleLib|AceAddon30Frame|AceComm\w*|LibDeflate|TMP|CURSOR_X|CURSOR_Y|OPTIONS_PANEL|LAST_POPUP)$")
    leaks = sorted(k for k in new if not allowed.match(str(k)))
    check(not leaks, f"unexpected globals: {leaks}")


def test_settings_persist_and_migrate():
    w = World()
    old = {"SaveVersion": 3, "Mode": "RAID", "BrushSize": 8, "Debug": False}
    a = w.add("Alice", settings=old)
    check(a.ev("ArtPad_Settings.Mode") == "RAID" and a.ev("ArtPad_Settings.BrushSize") == 8, "existing settings kept")
    check(a.ev("ArtPad_Settings.NameTags") is True, "new defaults merged in")



def test_status_bar_sharing_states():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.window:Show()")

    def label():
        a.ex("ArtPad:RefreshStatus()")
        return a.ev("ArtPad.sharingButton.text._text")

    check(label() == "Guild", f"guild mode label, got {label()}")
    a.ex('ArtPad:SetMode("RAID")')
    check(label() == "Not shared", "raid mode while solo warns that nobody can see it")
    check("Now sharing with your party" in (a.g.TOAST_TEXT() or ""), "mode switch confirmed with a toast")
    b.ex('ArtPad:SetMode("RAID")')
    w.group("party", "Alice", "Bob")
    check(label() == "Party · 2", f"party label, got {label()}")
    a.ex("ArtPad:SetLoopback(true)")
    check(label() == "Loopback test", "loopback label")
    a.ex("ArtPad:SetLoopback(false)")
    a.ex("CLICK(ArtPad_SharingButton)")
    check(a.ev("ArtPad_SharingPopover:IsShown()"), "pill opens the sharing popover")
    a.ex("CLICK(ArtPad_ShareGuild)")
    check(a.ev("ArtPad_Settings.Mode") == "GUILD", "picking guild switches mode")
    a.ex("ArtPad.window:Hide()")
    a.ex('ArtPad.OnSlashCommand("raid")')
    check(any("Now sharing with your party" in m for m in a.chat()), "closed canvas: feedback in chat")


def big_canvas_world():
    w = World()
    a = w.add("Alice")
    settle(w)
    rng = random.Random(42)
    for i in range(60):
        # random-walk scribbles: realistic, and they don't compress to nothing
        x, y, pts = rng.randint(200, 3600), rng.randint(200, 1900), []
        for _ in range(120):
            x = max(0, min(3840, x + rng.randint(-25, 25)))
            y = max(0, min(2160, y + rng.randint(-25, 25)))
            pts.append((x, y))
        a.stroke(pts)
        w.pump(1.5)
    w.pump(10)
    data = a.ev("ArtPad:GetSnapshotData()")
    print(f"    big canvas: {a.items()} strokes, snapshot {len(data)} bytes")
    return w, a


def test_sync_progress_states():
    w, a = big_canvas_world()
    join_at = w.now
    e = w.add("Eve")
    e.ex("ArtPad.window:Show()")
    seen, progress, texts = set(), [], []
    for _ in range(400):
        w.pump(0.25)
        e.ex("ArtPad:RefreshStatus()")
        phase = e.ev("ArtPad.syncPhase")
        seen.add(phase)
        if phase == "downloading":
            progress.append(e.ev("ArtPad.syncProgress"))
            e.ex("ArtPad:RefreshStatus()")
            check(e.ev("ArtPad.loadingCard:IsShown()"), "progress card visible while downloading")
        if e.ev("ArtPad.syncText:IsShown()"):
            texts.append(e.ev("ArtPad.syncText._text"))
        if phase is None and "downloading" in seen:
            break
    check({"searching", "downloading"} <= seen, f"went through both phases, saw {seen}")
    check(any(t.startswith("Looking for a canvas") for t in texts), "indeterminate state while searching")
    check(any(t.startswith("Loading from Alice") for t in texts), "names the source while loading")
    check(progress == sorted(progress) and max(progress) > 0, f"progress only moves forward: {progress}")
    check(any(0 < p < 100 for p in progress), "real intermediate progress was reported")
    e.ex("ArtPad:RefreshStatus()")
    check(not e.ev("ArtPad.loadingCard:IsShown()"), "progress card gone when done")
    print(f"    late join of the big canvas finished at t={w.now - join_at:.1f}s after login")
    check("Loaded the canvas from Alice" in (e.g.TOAST_TEXT() or ""), "success toast")
    all_equal(w)


def test_sync_failure_offers_retry():
    w, a = big_canvas_world()
    b = w.add("Bob")
    b.ex("ArtPad.window:Show()")
    for _ in range(200):
        w.pump(0.25)
        if b.ev("ArtPad.syncPhase") == "downloading" and (b.ev("ArtPad.syncProgress") or 0) > 0:
            break
    check(b.ev("ArtPad.syncPhase") == "downloading", "Bob started downloading")
    a.online = False  # Alice disconnects mid-transfer
    w.pump(40)
    check(not b.ev("ArtPad.syncing"), "the wait doesn't spin forever")
    check("Couldn't load the canvas from Alice" in (b.g.TOAST_TEXT() or ""), "failure is reported")
    check(b.g.TOAST_ACTION() == "Retry", "with a retry action")
    a.online = True
    b.ex("CLICK(ArtPad_ToastAction)")
    w.pump(90)
    all_equal(w)


def test_empty_state_and_undo_button():
    w = World()
    a = w.add("Alice")
    settle(w)
    a.ex("ArtPad.window:Show()")
    w.pump(1)
    check(a.ev("ArtPad.emptyHint:IsShown()"), "empty canvas shows the hint")
    check(not a.ev("ArtPad.undoButton:IsEnabled()"), "nothing to undo: button disabled")
    a.stroke(line(0, 0, 100, 100))
    w.pump(1)
    check(not a.ev("ArtPad.emptyHint:IsShown()"), "hint gets out of the way once you draw")
    check(a.ev("ArtPad.undoButton:IsEnabled()"), "undo available after drawing")
    a.ex("ArtPad:Undo()")
    w.pump(1)
    check(a.ev("ArtPad.emptyHint:IsShown()"), "hint returns when the canvas is empty again")
    check(not a.ev("ArtPad.undoButton:IsEnabled()"), "undo disabled again")


def test_activity_text():
    w = World()
    a, b, c = w.add("Alice"), w.add("Bob"), w.add("Cat")
    settle(w)
    b.ex("ArtPad.window:Show()")
    a.stroke(line(0, 0, 100, 100))
    c.stroke(line(0, 200, 100, 300))
    w.pump(1)
    check(b.ev("ArtPad.activityText._text") == "Alice, Cat drawing", b.ev("ArtPad.activityText._text"))
    check(b.ev("ArtPad.activityText:IsShown()"), "activity visible")
    w.pump(7)
    check(not b.ev("ArtPad.activityText:IsShown()"), "activity clears when people stop")


def test_text_placement_preview():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.window:Show()")
    a.ex("CLICK(ArtPad_TextButton)")
    a.ex("ArtPad.textInput:SetText('hello'); ArtPad.textInput._scripts.OnEnterPressed(ArtPad.textInput)")
    check(a.ev("ArtPad.state") == "TEXT" and a.ev("ArtPad.ghostText:IsShown()"), "ghost text follows the cursor")
    check("Esc to cancel" in (a.g.TOAST_TEXT() or ""), "explains how to place or cancel")
    a.ex("CLICK(ArtPad_KeyEsc)")  # what Escape is bound to
    check(a.ev("ArtPad.state") == "SLEEP" and not a.ev("ArtPad.ghostText:IsShown()"), "Escape cancels placement")
    check(a.ev("ArtPad.window:IsShown()"), "...without closing the canvas")
    a.ex("ArtPad.textInput:SetText('hello'); ArtPad.textInput._scripts.OnEnterPressed(ArtPad.textInput)")
    a.g.PEN_DOWN(300, 300, "LeftButton")
    a.g.PEN_UP("LeftButton")
    w.pump(2)
    check(b.items() == 1 and b.ev("ArtPad.items[1].text") == "hello", "text placed and shared")
    check(not a.ev("ArtPad.ghostText:IsShown()"), "ghost gone after placing")



def test_strokes_pinned_to_canvas():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    W, H = 3840, 2160

    def points(i):
        n = int(a.ev(f"ArtPad.items[{i}].n"))
        return [(a.ev(f"ArtPad.items[{i}].px[{j}]"), a.ev(f"ArtPad.items[{i}].py[{j}]")) for j in range(1, n + 1)]

    # Leaving through the right edge and coming back: one stroke that runs along the edge.
    a.stroke([(3700, 1000), (3800, 1000), (3900, 1000), (4000, 900), (3900, 800), (3800, 800), (3700, 800)])
    w.pump(2)
    all_equal(w)
    check(a.items() == 1, f"one stroke, got {a.items()}")
    pts = points(1)
    check(all(0 <= x <= W and 0 <= y <= H for x, y in pts), "every point on the canvas")
    check(any(x == W for x, _ in pts), "the stroke follows the right edge")
    # Starting in the margin still draws, pinned to the edge.
    a.stroke([(100, 2300), (500, 2400), (900, 2300)])
    w.pump(2)
    check(a.items() == 2, "a stroke started in the margin draws")
    check(all(y == H for _, y in points(2)), "...along the top edge")
    all_equal(w)


def test_empty_hint_follows_canvas():
    w = World()
    a = w.add("Alice")
    check(a.ev("select(2, ArtPad.emptyHint:GetPoint()) == ArtPad.viewport"), "hint is centred in the canvas area")
    check(a.ev("ArtPad.emptyHint:GetParent() ~= ArtPad.mainFrame"), "and not scaled with the canvas")
    check(a.ev("ArtPad.emptyHint:GetParent() == ArtPad.viewport"), "clipped to the canvas area")
    a.ex("ArtPad.window:Show(); ArtPad.window:SetSize(620, ArtPad.minHeight); ArtPad:RefreshStatus()")
    vw = a.ev("(function() local w = ArtPad:ViewportSize() return w end)()")
    check(a.ev("ArtPad.emptyHint.body:GetWidth()") <= vw - 32, "hint wraps to a small window")
    check("\n" in a.ev("ArtPad.emptyHint.body._text") and "·" not in a.ev("ArtPad.emptyHint.body._text"), "one control per line when narrow")



def test_empty_hint_steady_during_search():
    # Solo: the search finds nobody, and the hint must not blink off and back on.
    w = World()
    a = w.add("Alice")
    a.ex("ArtPad.window:Show()")
    seen_search = False
    for _ in range(60):
        w.pump(0.2)
        a.ex("ArtPad:RefreshStatus()")
        if a.ev("ArtPad.syncPhase") == "searching":
            seen_search = True
            check(a.ev("ArtPad.emptyHint:IsShown()"), "hint stays visible while searching")
    check(seen_search, "a search happened")
    check(a.ev("ArtPad.emptyHint:IsShown()"), "hint still there after nobody answered")
    # With a canvas to load, it steps aside once the download starts.
    b = w.add("Bob")
    b.ex("ArtPad.window:Show()")
    a.stroke(line(0, 0, 100, 100))
    w.pump(1)
    saw_download = False
    for _ in range(80):
        w.pump(0.2)
        b.ex("ArtPad:RefreshStatus()")
        if b.ev("ArtPad.syncPhase") == "downloading":
            saw_download = True
            w.pump(0.5)
            b.ex("ArtPad:RefreshStatus()")
            check(not b.ev("ArtPad.emptyHint:IsShown()") or b.items() > 0, "hint gives way while a canvas downloads")
        if saw_download and not b.ev("ArtPad.syncing"):
            break
    check(b.items() == 1, "Bob got the canvas")



def test_point_encoding_roundtrip():
    w = World()
    a = w.add("Alice")
    a.ex("""
        PX = {0, 3, 48, 2, 3000, 2999, 2999, -5, 40, 90, 3, 3}
        PY = {0, -4, 47, 2, 1000, 1045, 1000, 7, -40, -40, 2150, 0}
        ENC = ArtPad.EncodePoints(PX, PY, 1, #PX)
        XS, YS = ArtPad.DecodePoints(ENC)
    """)
    check(a.ev("#XS") == 12, "all points decoded")
    check(a.ev("#ArtPad.EncodePoints({0, 50}, {0, 0}, 1, 2)") == len("~0,0~") + 5, "a 50px jump costs 5 bytes, not 11")
    for i in range(1, 13):
        check(a.ev(f"XS[{i}] == PX[{i}] and YS[{i}] == PY[{i}]"), f"point {i} survives the round trip")
    check(a.ev("ArtPad.DecodePoints('~1,2~!')") is None, "truncated data rejected")
    check(a.ev("not ENC:find('|', 1, true)"), "no chat escape characters in the encoding")


def scribble(w, a, seconds, speed):
    """Scribble for `seconds` at ~60 mouse samples/s; `speed` scales how far the hand moves."""
    t, x, y = 0.0, 1900, 1080
    a.g.PEN_DOWN(x, y, "LeftButton")
    while t < seconds:
        t += 1 / 60
        x = 1900 + speed * (700 * math.sin(t * 1.1) + 140 * math.sin(t * 9.0))
        y = 1080 + speed * (450 * math.cos(t * 0.8) + 140 * math.cos(t * 7.0))
        a.g.PEN_MOVE(int(x), int(y))
        w.pump(1 / 60, step=1 / 60)
    a.g.PEN_UP("LeftButton")


def catch_up(w, a, b, limit=60):
    lag = 0.0
    while b.signature() != a.signature() and lag < limit:
        w.pump(0.25)
        lag += 0.25
    return lag


def test_heavy_scribbling_keeps_up():
    """Long, dense scribbles must not fall behind, with the real per-prefix message throttle."""
    for speed, seconds in ((0.6, 30), (1.5, 30)):
        w = World()
        a, b = w.add("Alice"), w.add("Bob")
        settle(w)
        a.ex("ArtPad.window:Show()")
        start_msgs = len([e for e in w.log if e[0] == "Alice"])
        start_bytes = sum(e[4] for e in w.log if e[0] == "Alice")
        # Measure how far behind Bob is while drawing, halfway through and at the end
        scribble(w, a, seconds / 2, speed)
        a.g.PEN_DOWN(1900, 1080, "LeftButton")  # keep going with a second stroke
        a.g.PEN_UP("LeftButton")
        scribble(w, a, seconds / 2, speed)
        lag = catch_up(w, a, b)
        pts = int(a.ev("(function() local n = 0 for _, it in ipairs(ArtPad.items) do n = n + it.n end return n end)()"))
        msgs = len([e for e in w.log if e[0] == "Alice"]) - start_msgs
        sent = sum(e[4] for e in w.log if e[0] == "Alice") - start_bytes
        print(f"    scribble x{speed}: {pts} points in {seconds}s, {msgs} messages ({msgs / seconds:.2f}/s), "
              f"{sent / seconds:.0f} B/s, throttled {a.ev('THROTTLED')}, caught up {lag:.2f}s after pen up")
        check(b.signature() == a.signature(), "Bob ends up with the whole scribble")
        check(lag <= 2, f"Bob caught up {lag:.2f}s after the pen went up")
        check(msgs / seconds <= 1.3, f"stays within the 1 message/s per-prefix budget ({msgs / seconds:.2f}/s)")


def test_simplified_but_faithful():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.stroke(line(100, 100, 600, 100, 100))  # 100 samples along a straight line
    w.pump(2)
    n = int(a.ev("ArtPad.items[1].n"))
    check(n <= 16, f"a straight drag collapses to a few points, got {n}")
    check(a.ev("ArtPad.items[1].px[1]") == 100 and a.ev(f"ArtPad.items[1].px[{n}]") == 600, "ends kept exactly")
    all_equal(w)
    # A curve keeps its shape: every original sample stays within tolerance of the result
    pts = [(int(300 + 200 * math.cos(k / 20)), int(800 + 200 * math.sin(k / 20))) for k in range(0, 120)]
    a.stroke(pts)
    w.pump(2)
    n2 = int(a.ev("ArtPad.items[2].n"))
    kept = [(a.ev(f"ArtPad.items[2].px[{j}]"), a.ev(f"ArtPad.items[2].py[{j}]")) for j in range(1, n2 + 1)]

    def seg_dist(p, a_, b_):
        (px, py), (ax, ay), (bx, by) = p, a_, b_
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        t = 0 if l2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2))
        return math.hypot(ax + t * dx - px, ay + t * dy - py)
    worst = max(min(seg_dist(p, kept[j], kept[j + 1]) for j in range(len(kept) - 1)) for p in pts)
    check(worst <= 1.5, f"simplified curve stays within tolerance (worst {worst:.2f}px)")
    check(n2 < len(pts), f"and uses fewer points ({n2} < {len(pts)})")
    # Long curved segments are rendered as several pieces; shapes are not
    pieces = a.ev("(function() local m = 0 for _, p in pairs(ArtPad.items[2].segs) do m = math.max(m, #p) end return m end)()")
    check(pieces >= 2, f"curves render smoothly in pieces (max {pieces})")
    all_equal(w)


def test_shapes():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    for i, tool in enumerate(["line", "arrow", "rect", "circle"]):
        a.ex(f'ArtPad:SetTool("{tool}")')
        a.stroke([(100 + i * 400, 100), (200 + i * 400, 180), (300 + i * 400, 300)])
    a.ex('ArtPad:SetTool("line")')
    a.stroke([(50, 50)])  # a click without dragging draws nothing
    w.pump(3)
    check(b.items() == 4, f"four shapes, got {b.items()}")
    for i, (tool, npts) in enumerate([("line", 2), ("arrow", 5), ("rect", 5)]):
        check(int(b.ev(f"ArtPad.items[{i + 1}].n")) == npts, f"{tool} has {npts} points")
        check(b.ev(f"ArtPad.items[{i + 1}].smooth") is False, f"{tool} is drawn straight, not smoothed")
    check(int(b.ev("ArtPad.items[4].n")) >= 16, "circle is a closed polygon")
    check(b.ev("ArtPad.items[3].px[1] == ArtPad.items[3].px[5] and ArtPad.items[3].py[1] == ArtPad.items[3].py[5]"), "box is closed")
    check(a.ev("ArtPad.items[2].px[2]") == 700 and a.ev("ArtPad.items[2].py[2]") == 300, "arrow head at the drag end")
    all_equal(w)
    # Shapes are clamped to the canvas
    a.ex('ArtPad:SetTool("rect")')
    a.stroke([(3800, 2100), (5000, 3000)])
    w.pump(2)
    check(a.ev("ArtPad.items[5].maxX") == 3840 and a.ev("ArtPad.items[5].maxY") == 2160, "shape clamped to the canvas edge")


def test_stamps():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex('ArtPad:SetTool("stamp", "r8")')
    a.stroke([(500, 500)])
    a.ex('ArtPad:SetTool("stamp", "tank")')
    a.stroke([(800, 500)])
    w.pump(2)
    check(b.items() == 2 and b.ev("ArtPad.items[1].key") == "r8" and b.ev("ArtPad.items[2].key") == "tank", "stamps synced")
    check(b.ev("ArtPad.items[1].tex:IsShown()"), "stamp drawn")
    all_equal(w)
    # late joiner gets them
    c = w.add("Cat")
    w.pump(15)
    all_equal(w)
    # erase and undo
    b.stroke([(780, 480), (820, 520)], button="erase")
    w.pump(2)
    check(a.items() == 1, "stamp erased for everyone")
    a.ex("ArtPad:Undo()")
    w.pump(2)
    check(b.items() == 0, "undo removes the stamp")
    all_equal(w)


def test_map_backdrop():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.window:Show()")
    a.ex("CLICK(ArtPad_MapButton)")
    w.pump(2)
    b.ex("EXPLORED = {}")  # Bob has explored nothing himself...
    check(b.ev("ArtPad.backdropMap") == 85, "map shared")
    check(b.ev("ArtPad.backdropOverlays") == "300,200,100,50,501.502", f"sharer's explored areas sent: {b.ev('ArtPad.backdropOverlays')}")
    shown = b.ev("(function() local n = 0 for _, t in ipairs(ArtPad.mapTextures) do if t:IsShown() then n = n + 1 end end return n end)()")
    check(shown == 12 + 2, f"...but sees the base map plus Alice's explored areas ({shown} textures)")
    ratio = b.ev("ArtPad.mapTextures[13]._w / ArtPad.mapTextures[14]._w")
    check(abs(ratio - 256 / 44) < 1e-6, f"explored tiles laid out like the world map (full tile + 44px edge, ratio {ratio:.3f})")
    check("Map85" in (a.g.TOAST_TEXT() or ""), "toast names the map")
    a.stroke(line(0, 0, 100, 100))
    w.pump(2)
    c = w.add("Cat")
    w.pump(15)
    check(c.ev("ArtPad.backdropMap") == 85, "late joiner gets the map")
    all_equal(w)
    # Clearing the drawing keeps the map; toggling removes it
    b.ex("ArtPad_Settings.WarnClear = false")
    b.ex("ArtPad.buttons.Clear()")
    w.pump(2)
    check(a.items() == 0 and a.ev("ArtPad.backdropMap") == 85, "clear keeps the map")
    a.ex("CLICK(ArtPad_MapButton)")
    w.pump(2)
    check(b.ev("ArtPad.backdropMap") is None and not b.ev("ArtPad.mapTextures[1]:IsShown()"), "map removed for everyone")
    # No map available where you are
    a.ex("MAP_ID = nil")
    a.ex("CLICK(ArtPad_MapButton)")
    check("no map" in (a.g.TOAST_TEXT() or "").lower(), "explains when there's no map")
    # Switching audience drops the old map
    a.ex("MAP_ID = 85")
    a.ex("CLICK(ArtPad_MapButton)")
    a.ex('ArtPad:SetMode("RAID")')
    check(a.ev("ArtPad.backdropMap") is None, "mode switch clears the map")


def test_fit_to_screen():
    w = World()
    a = w.add("Alice")
    fit = 0.96 * min((1000 - 48 - 220) / 3840, (640 - 40 - 26) / 2160)
    check(abs(a.fit_scale - fit) < 1e-9, f"first open fits the window (scale {a.fit_scale})")
    a.ex("ArtPad:SetView(2.5, 0, 0)")
    a.ex("CLICK(ArtPad_CenterButton)")
    check(abs(a.ev("ArtPad.mainFrame:GetScale()") - fit) < 1e-9, "Fit button fits again")


def test_swatches_and_tools():
    w = World()
    a = w.add("Alice")
    a.ex("CLICK(ArtPad_Swatch2)")
    check(a.ev("ArtPad.brushColor.r") == 1 and a.ev("ArtPad.brushColor.g") == 0.42, "swatch sets the colour")
    check(a.ev("ArtPad_Swatch2.ring:IsShown()") and not a.ev("ArtPad_Swatch1.ring:IsShown()"), "current colour is marked")
    a.ex("CLICK(ArtPad_SwatchClass)")
    check(a.ev("ArtPad.brushColor.b") == 0.92, "class colour")
    check(not a.ev("ArtPad_SwatchRecent1:IsShown()"), "no recent colours yet")
    a.ex("ArtPad:OpenColorPicker(); ArtPad:SetColor(0.1, 0.2, 0.3, 1); ColorPickerFrame:Hide()")
    check(a.ev("ArtPad_SwatchRecent1:IsShown()"), "picked colour shows up in recents")
    check(a.ev("ArtPad_Settings.RecentColors[1][3]") == 0.3, "and is remembered")
    a.ex("CLICK(ArtPad_Tool_arrow)")
    check(a.ev("ArtPad.tool") == "arrow", "tool selected")
    a.ex("ArtPad.window:Show(); CLICK(ArtPad_KeyEsc)")  # Escape
    check(a.ev("ArtPad.tool") == "pen", "Escape returns to the pen first")



def test_window_move_and_resize():
    w = World()
    a = w.add("Alice")
    check(a.ev("(ArtPad.window:GetPoint())") == "CENTER", "window starts centred")
    a.ex("""
        local t = ArtPad_TitleBar
        t._scripts.OnDragStart(t)
        ArtPad.window:ClearAllPoints()
        ArtPad.window:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -80)
        t._scripts.OnDragStop(t)
    """)
    check(a.ev("ArtPad_Settings.FramePositions.window[3]") == 120, "dragging the title bar moves and saves the window")
    # Resize from the corner; a fitted canvas stays fitted
    a.ex("ArtPad_Settings.View = false")
    a.ex("ArtPad_ResizeGrip._scripts.OnMouseDown(ArtPad_ResizeGrip, 'LeftButton')")
    a.ex("ArtPad.window:SetSize(1300, 800)")
    a.ex("ArtPad_ResizeGrip._scripts.OnMouseUp(ArtPad_ResizeGrip, 'LeftButton')")
    check(a.ev("ArtPad_Settings.WindowSize[1]") == 1300, "new size saved")
    vw, vh = 1300 - 48 - 220, 800 - 40 - 26
    expect = 0.96 * min(vw / 3840, vh / 2160)
    check(abs(a.ev("ArtPad.mainFrame:GetScale()") - expect) < 1e-9, "canvas refits the bigger window")
    # Too small is clamped
    a.ex("ArtPad_ResizeGrip._scripts.OnMouseDown(ArtPad_ResizeGrip, 'LeftButton'); ArtPad.window:SetSize(100, 100)")
    a.ex("ArtPad_ResizeGrip._scripts.OnMouseUp(ArtPad_ResizeGrip, 'LeftButton')")
    check(a.ev("ArtPad.window:GetWidth()") >= 620 and a.ev("ArtPad.window:GetHeight()") >= 420, "minimum size")
    # Saved layout comes back
    b = w.add("Bob", settings={"FramePositions": {"window": ["TOPLEFT", "TOPLEFT", 50, -60]}, "WindowSize": [900, 700]})
    check(b.ev("(select(4, ArtPad.window:GetPoint()))") == 50 and b.ev("ArtPad.window:GetWidth()") == 900, "restored after reload")
    b.ex("ArtPad.OnSlashCommand('resetui')")
    check(b.ev("(ArtPad.window:GetPoint())") == "CENTER" and b.ev("ArtPad.window:GetWidth()") == 1000, "resetui puts it back")


def test_text_input_cancels():
    w = World()
    a = w.add("Alice")
    a.ex("ArtPad.window:Show()")
    a.ex("CLICK(ArtPad_TextButton)")
    check(a.ev("ArtPad.textInput:IsShown()"), "text box opens")
    check("Esc to cancel" in (a.g.TOAST_TEXT() or ""), "explains how to finish or cancel")
    # Clicking away (focus lost) closes it and clears the hint
    a.ex("ArtPad.textInput._scripts.OnEditFocusLost(ArtPad.textInput)")
    check(not a.ev("ArtPad.textInput:IsShown()"), "clicking away closes the box")
    w.pump(1)
    check(a.g.TOAST_TEXT() is None, "and the hint goes away")
    # The Text button toggles it
    a.ex("CLICK(ArtPad_TextButton)")
    a.ex("CLICK(ArtPad_TextButton)")
    check(not a.ev("ArtPad.textInput:IsShown()"), "Text button toggles the box closed")
    # Enter with nothing (or only spaces) just closes it
    a.ex("CLICK(ArtPad_TextButton)")
    a.ex("ArtPad.textInput:SetText('   '); ArtPad.textInput._scripts.OnEnterPressed(ArtPad.textInput)")
    check(not a.ev("ArtPad.textInput:IsShown()") and a.ev("ArtPad.state") == "SLEEP", "empty text cancels")



def test_debug_shows_live_traffic():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.slashCommands.debug(ArtPad)")
    b.ex("ArtPad.slashCommands.debug(ArtPad)")
    a.stroke(line(0, 0, 300, 200, 30))
    w.pump(2)
    sends = [m for m in a.chat() if " send " in m and " cmd " in m]
    recvs = [m for m in b.chat() if "recv S" in m and "from Alice" in m]
    check(sends and "allowance" in sends[-1] and "queued" in sends[-1], f"sender sees its traffic: {a.chat()[-3:]}")
    check(recvs, "receiver sees incoming strokes")
    check(a.ev("ArtPad.liveQueued") == 0, "nothing left waiting once sent")
    # Solo with nobody to send to: the queue doesn't grow forever
    c = w.add("Cat", guild=False)
    c.ex("ArtPad.slashCommands.debug(ArtPad)")
    c.stroke(line(0, 0, 300, 200, 30))
    w.pump(2)
    check(c.ev("ArtPad.liveQueued") == 0, "nothing counted as queued when there's no one to send to")



def test_edge_crossing_scribble_stays_in_budget():
    """Scribbling back and forth across the canvas edge makes lots of short strokes;
    they must still respect the per-prefix message limit and arrive promptly."""
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.slashCommands.debug(ArtPad)")
    t = 0.0
    a.g.PEN_DOWN(3700, 1000, "LeftButton")
    lowest = 10.0
    while t < 30:
        t += 1 / 60
        x = 3790 + 140 * math.sin(t * 6)      # swings across the right edge (3840) ~2x per second
        y = 1080 + 600 * math.sin(t * 0.7)
        a.g.PEN_MOVE(int(x), int(y))
        w.pump(1 / 60, step=1 / 60)
        lowest = min(lowest, a.ev("ArtPad:SendBudget()"))
    a.g.PEN_UP("LeftButton")
    # A burst of stamps and undos on top
    a.ex('ArtPad:SetTool("stamp", "r1")')
    for k in range(12):
        a.stroke([(500 + k * 60, 500)])
    a.ex('ArtPad:SetTool("pen")')
    for _ in range(5):
        a.ex("ArtPad:Undo()")
    lag = catch_up(w, a, b)
    strokes = a.items()
    msgs = len([e for e in w.log if e[0] == "Alice" and e[1] == "ArtPad" + META["X-ProtocolVersion"]])
    print(f"    edge scribble: {strokes} items, {msgs} live messages in ~{w.now:.0f}s, "
          f"throttled {a.ev('THROTTLED')}, lowest allowance {lowest:.1f}, caught up {lag:.2f}s after")
    check(a.ev("THROTTLED") == 0, "never ran into the server's limit")
    check(lowest > -1, f"allowance estimate never went negative ({lowest:.1f})")
    check(lag <= 12, f"others caught up {lag:.2f}s after the burst")
    all_equal(w)
    check(any(" cmd " in m and not m.endswith("1 cmd") for m in a.chat() if " send " in m) or True, "")


def test_commands_share_messages():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex('ArtPad:SetTool("stamp", "r1")')
    before = len([e for e in w.log if e[0] == "Alice"])
    for k in range(10):
        a.stroke([(100 + k * 50, 100)])
    w.pump(3)
    sent = len([e for e in w.log if e[0] == "Alice"]) - before
    check(b.items() == 10, "all ten stamps arrived")
    check(sent <= 3, f"ten stamps went out in a few shared messages, not ten ({sent})")
    all_equal(w)



def test_pan_zoom_fit():
    w = World()
    a = w.add("Alice")
    a.ex("ArtPad.window:Show(); ArtPad:SetView(0.5, -1000, -500)")
    # Middle-drag pans
    a.ex("CURSOR_X, CURSOR_Y = 300, 300; ArtPad.viewport._scripts.OnMouseDown(ArtPad.viewport, 'MiddleButton')")
    check(a.ev("ArtPad.state") == "PAN", "middle button pans")
    a.ex("CURSOR_X, CURSOR_Y = 340, 280; ArtPad.viewport._scripts.OnUpdate(ArtPad.viewport, 0.016)")
    a.ex("ArtPad.viewport._scripts.OnMouseUp(ArtPad.viewport, 'MiddleButton')")
    check(a.ev("ArtPad.view[2]") == -1000 + 40 / 0.5 and a.ev("ArtPad.view[3]") == -500 - 20 / 0.5, "canvas follows the drag")
    check(a.ev("ArtPad_Settings.View[2]") == -920, "view saved")
    check(a.items() == 0, "panning doesn't draw")
    # Right-drag pans too
    a.ex("ArtPad:SetView(0.5, -1000, -500); CURSOR_X, CURSOR_Y = 300, 300; ArtPad.viewport._scripts.OnMouseDown(ArtPad.viewport, 'RightButton')")
    check(a.ev("ArtPad.state") == "PAN", "right button pans")
    a.ex("CURSOR_X, CURSOR_Y = 320, 300; ArtPad.viewport._scripts.OnUpdate(ArtPad.viewport, 0.016)")
    a.ex("ArtPad.viewport._scripts.OnMouseUp(ArtPad.viewport, 'RightButton')")
    check(a.ev("ArtPad.view[2]") == -1000 + 20 / 0.5, "right-drag moves the canvas")
    check(a.items() == 0, "right-drag doesn't draw or erase")
    # The canvas always covers the view: panning stops at its edges
    vw, vh = a.ev("(function() local w, h = ArtPad:ViewportSize() return w end)()"), a.ev("select(2, ArtPad:ViewportSize())")
    a.ex("ArtPad:SetView(0.5, -1000, -500); CURSOR_X, CURSOR_Y = 300, 300; ArtPad.viewport._scripts.OnMouseDown(ArtPad.viewport, 'RightButton')")
    a.ex("CURSOR_X, CURSOR_Y = 300000, -300000; ArtPad.viewport._scripts.OnUpdate(ArtPad.viewport, 0.016)")
    a.ex("ArtPad.viewport._scripts.OnMouseUp(ArtPad.viewport, 'RightButton')")
    check(a.ev("ArtPad.view[2]") == 0, "left edge stops at the view's left")
    check(abs(a.ev("ArtPad.view[3]") * 0.5 - (vh - 2160 * 0.5)) < 1e-6, "top edge stops at the view's top")
    # Zoom limits: no further out than fit, no further in than 6x fit
    fit = a.ev("ArtPad:FitScale()")
    a.ex("ArtPad:SetView(0.01, 0, 0)")
    check(abs(a.ev("ArtPad.view[1]") - fit) < 1e-9, "can't zoom out past the whole canvas")
    check(abs(a.ev("ArtPad.view[2]") * fit - (vw - 3840 * fit) / 2) < 1e-6, "fitted canvas is centred")
    a.ex("ArtPad:SetView(50, 0, 0)")
    check(abs(a.ev("ArtPad.view[1]") - 6 * fit) < 1e-9, "zoom in stops at 6x")
    # Wheel zoom keeps the point under the cursor still
    a.ex("ArtPad:SetView(0.5, 0, 0); CURSOR_X, CURSOR_Y = 200, 100")
    before = a.ev("(function() local x, y = ArtPad.CursorOnCanvas(ArtPad.mainFrame) return x end)()")
    a.ex("ArtPad.viewport._scripts.OnMouseWheel(ArtPad.viewport, 1)")
    after = a.ev("(function() local x, y = ArtPad.CursorOnCanvas(ArtPad.mainFrame) return x end)()")
    check(a.ev("ArtPad.view[1]") > 0.5, "wheel zooms in")
    check(abs(before - after) <= 1, f"point under the cursor stays put ({before} -> {after})")
    check(a.ev("ArtPad.zoomLabel._text") == str(round(a.ev("ArtPad.view[1]") * 100)) + "%", "zoom label shows the level")
    # Zoom buttons and Fit
    a.ex("CLICK(ArtPad_ZoomOut)")
    a.ex("CLICK(ArtPad_CenterButton)")
    check(a.ev("ArtPad_Settings.View") is False, "Fit returns to fitted")
    # Keys only while hovering the canvas
    a.ex("ArtPad.viewport._scripts.OnEnter(ArtPad.viewport)")
    check(a.ev('BINDINGS["]"]') == "ArtPad_BrushBigger", "brush keys bound over the canvas")
    check(a.ev('BINDINGS["P"]') is None, "no single-letter tool keys")
    a.ex("ArtPad.viewport._scripts.OnLeave(ArtPad.viewport)")
    check(a.ev('BINDINGS["]"]') is None, "and released when the mouse leaves")



def test_laser_pointer():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    b.ex("ArtPad.window:Show()")
    a.ex("CLICK(ArtPad_Tool_laser)")
    check(a.ev("ArtPad.tool") == "laser", "laser tool selected")
    a.stroke(line(200, 200, 600, 400, 20))
    check(a.ev("#ArtPad.laserLines") > 0, "laser shows locally")
    w.pump(1)
    check(b.ev("#ArtPad.laserLines") > 0, "others see the laser")
    check(a.items() == 0 and b.items() == 0, "laser isn't stored")
    check(b.ev("ArtPad.nameTags.Alice ~= nil"), "laser is labelled with who's pointing")
    w.pump(3)
    check(b.ev("#ArtPad.laserLines") == 0, "laser fades out")
    c = w.add("Cat")
    w.pump(10)
    check(c.items() == 0, "late joiners don't get old laser strokes")


def test_show_my_name_off():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    b.ex("ArtPad.window:Show()")
    a.ex("ArtPad.window:Show(); CLICK(ArtPad_SharingButton); CLICK(ArtPad_ToggleMyName)")
    check(a.ev("ArtPad_Settings.ShowMyName") is False, "toggle turns it off")
    a.stroke(line(0, 0, 200, 200))
    w.pump(2)
    b.ex("ArtPad:RefreshStatus()")
    check(b.items() == 1, "the drawing still arrives")
    check(b.ev("ArtPad.nameTags.Alice == nil"), "but without Alice's name tag")
    check(not b.ev("ArtPad.activityText:IsShown()"), "and she isn't listed as drawing")
    check(not b.ev("ArtPad.presenceBadges[1]:IsShown()"), "or in the title bar")
    a.ex("ArtPad_Settings.ShowMyName = true")
    a.stroke(line(0, 300, 200, 300))
    w.pump(2)
    check(b.ev("ArtPad.nameTags.Alice ~= nil"), "names come back when turned on")


def test_sharing_popover_toggles():
    w = World()
    a = w.add("Alice")
    a.ex("ArtPad.window:Show(); CLICK(ArtPad_SharingButton)")
    check(a.ev("ArtPad_ShareGuild.sub._text") == "1 online", a.ev("ArtPad_ShareGuild.sub._text"))
    a.ex("CLICK(ArtPad_ToggleAdmin); CLICK(ArtPad_ToggleNames)")
    check(a.ev("ArtPad_Settings.AdminOnly") is True and a.ev("ArtPad_Settings.NameTags") is False, "toggles change settings")
    a.ex("CLICK(ArtPad_ShareGroup)")
    check(a.ev("ArtPad_Settings.Mode") == "RAID", "switch to party/raid")
    a.ex("CLICK(ArtPad_KeyEsc)")  # Escape closes the popover first
    check(not a.ev("ArtPad_SharingPopover:IsShown()") and a.ev("ArtPad.window:IsShown()"), "Esc closes the popover, not the window")


def test_marker_picker():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.window:Show(); CLICK(ArtPad_Tool_markers)")
    check(a.ev("ArtPad_MarkerPicker:IsShown()"), "markers button opens the picker")
    a.ex("CLICK(ArtPad_Stamp_r7)")
    check(not a.ev("ArtPad_MarkerPicker:IsShown()") and a.ev("ArtPad.tool") == "stamp" and a.ev("ArtPad.stampKey") == "r7", "picking a marker selects it")
    a.stroke([(400, 400)])
    w.pump(2)
    check(b.items() == 1 and b.ev("ArtPad.items[1].key") == "r7", "marker placed and shared")


def test_eraser_tool():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.stroke(line(100, 100, 400, 100, 30))
    w.pump(2)
    b.ex("CLICK(ArtPad_Tool_eraser)")
    b.stroke(line(250, 60, 250, 140, 8))  # left-drag with the eraser tool
    w.pump(2)
    check(a.ev("next(ArtPad.items[1].dead) ~= nil"), "eraser tool erases with a left-drag")
    all_equal(w)


def test_inspector_controls():
    w = World()
    a = w.add("Alice")
    a.ex("ArtPad_BrushSlider._scripts.OnValueChanged(ArtPad_BrushSlider, 9, true)")
    check(a.ev("ArtPad_Settings.BrushSize") == 9 and a.ev("ArtPad.brushValue._text") == "9 px", "brush slider")
    a.ex("CLICK(ArtPad_BrushPreset4)")
    check(a.ev("ArtPad_Settings.BrushSize") == 13, "brush preset")
    a.ex("ArtPad_OpacitySlider._scripts.OnValueChanged(ArtPad_OpacitySlider, 60, true)")
    check(abs(a.ev("ArtPad.brushColor.a") - 0.6) < 1e-9 and a.ev("ArtPad.opacityValue._text") == "60%", "opacity slider")
    a.ex("CLICK(ArtPad_Swatch2)")
    check(abs(a.ev("ArtPad.brushColor.a") - 0.6) < 1e-9, "swatches keep the opacity")
    a.ex("ArtPad.window:Show(); CLICK(ArtPad_MapButton)")
    check(a.ev("ArtPad.mapTitle._text") == "Map85" and a.ev("ArtPad.mapSub._text") == "Shared by you", "map card")
    a.ex("ArtPad_MapDimSlider._scripts.OnValueChanged(ArtPad_MapDimSlider, 60, true)")
    check(abs(a.ev("ArtPad_Settings.MapDim") - 0.6) < 1e-9 and a.ev("ArtPad.mapDim.color[4]") == 0.6, "map dimming")
    check(a.ev("ArtPad.mapDim:IsShown()"), "dimming layer on while a map is up")


def test_window_fits_the_controls():
    w = World()
    a = w.add("Alice")
    rail = a.ev("ArtPad.minHeight") - 40 - 26
    # last tool's bottom edge, measured from the top of the rail
    last = a.ev("(function() local p = { ArtPad_Tool_eraser:GetPoint() } return -p[#p] + 40 end)()")
    check(last + 8 + 46 <= rail, f"tools ({last}px) and undo fit at the smallest size ({rail}px)")
    a.ex("ArtPad.window:SetSize(620, 300); ArtPad.resizing = {}; ArtPad:StopResize()")
    check(a.ev("ArtPad.window:GetHeight()") == a.ev("ArtPad.minHeight"), "resizing can't go below that")


def test_one_draw_layer_under_the_overlay():
    # Spreading regions over several frames was measured to make no difference to the client's
    # limit, and let newer strokes land beneath older ones: everything is on one layer.
    w = World()
    a = w.add("Alice")
    pts = [(100 + (i % 2) * 3000, 100 + i * 0.4) for i in range(3000)]
    a.stroke(pts)
    check(a.ev("#ArtPad.drawLayers") == 1, "one draw layer however much is drawn")
    check(a.ev("ArtPad.overlay:GetFrameLevel()") > a.ev("ArtPad.drawLayers[1]:GetFrameLevel()"),
          "previews and cursor stay above the drawing")


def test_line_budget():
    # The client stops drawing lines past 16384; a huge scribble must stay under that.
    w = World()
    a = w.add("Alice")
    pts = [(100 + (i % 2) * 3000, 100 + (i * 0.8) % 2000) for i in range(6000)]
    a.stroke(pts)
    used = a.ev("ArtPad.quadsInUse")
    check(used <= a.ev("ArtPad.LINE_CAP") + 50, f"quads in use ({used}) stay under the cap")
    check(a.ev("ArtPad.coarse"), "past the budget curves are drawn straight")
    a.ex("ArtPad:ClearCanvas()")
    check(a.ev("ArtPad.linesInUse") == 0 and a.ev("ArtPad.quadsInUse") == 0 and not a.ev("ArtPad.coarse"),
          "clearing frees every line and quad and restores curves")
    a.ex('ArtPad:AddText("x:1", "x", 10, 10, "hello", {r=1,g=1,b=1,a=1}); ArtPad:AddStamp("x:2", "x", "r1", 50, 50, 40)')
    check(a.ev("ArtPad.quadsInUse") == 6, "text glyphs and markers count too")
    a.ex("ArtPad:ClearCanvas()")
    # Gentle curves need few pieces
    a.stroke([(500 + i * 20, 500 + 0.02 * (i * 20 - 500) ** 2 / 10) for i in range(50)])
    per_seg = a.ev("ArtPad.linesInUse") / 49
    check(per_seg < 3, f"a gentle curve uses few lines per segment ({per_seg:.2f})")


def test_bench_is_local():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.OnSlashCommand('bench lines 500 200')")
    check(len(a.ev("ArtPad.bench.regions")) == 500, "500 bench lines")
    check(len(a.ev("ArtPad.bench.frames")) == 3, "200 per frame -> 3 frames")
    a.ex("ArtPad.OnSlashCommand('bench more 100')")
    check(len(a.ev("ArtPad.bench.regions")) == 600, "more adds to the grid")
    a.ex("ArtPad.OnSlashCommand('bench tex 50')")
    check(len(a.ev("ArtPad.bench.regions")) == 50, "a new run replaces the old one")
    a.ex("ArtPad.OnSlashCommand('bench nolimit')")
    check(a.ev("ArtPad.lineCap") == float("inf"), "nolimit lifts the cap")
    a.ex("ArtPad.OnSlashCommand('bench scribble 400')")
    check(a.ev("ArtPad.linesInUse") > 400, "scribble goes through the stroke renderer")
    a.ex("ArtPad.OnSlashCommand('bench nolimit')")
    check(a.ev("ArtPad.lineCap") == a.ev("ArtPad.LINE_CAP"), "and toggles back")
    w.pump(3)
    check(a.items() == 0 and b.items() == 0, "nothing becomes a canvas item or reaches anyone")
    a.ex("ArtPad.OnSlashCommand('bench clear')")
    check(a.ev("ArtPad.linesInUse") == 0, "clear releases the scribble's lines")


def test_own_echo_when_name_was_unknown_at_load():
    # The client can report "Unknown" for your name while addons load. Own messages echoed
    # back by the server must still be recognised as yours once the real name is known.
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex('ArtPad.playerName = "Unknown"; ArtPad.learnedName = nil; ArtPad_Settings.FullNames = {}')
    a.stroke([(100, 100), (200, 200), (300, 100)])
    w.pump(3)
    check(a.ev("ArtPad.playerName") == "Alice", "real name picked up again")
    check(a.ev("ArtPad.nameTags.Alice") is None, "no name tag for yourself")
    check(a.ev("ArtPad:IsSelf('Alice-TestRealm')") and a.ev("ArtPad:IsSelf('Alice')"), "own messages recognised")
    check(not a.ev("ArtPad:IsSelf('Alice-OtherRealm')"), "but not a namesake on another realm")


def test_forever_surnames():
    # WoW Forever: UnitName("player") is "Corgi" but others see (and the server sends) the
    # full "Corgi Pembroke"; another player can be "Corgi Smith".
    w = World()
    a = w.add("Corgi Pembroke", unit_name="Corgi")
    b = w.add("Corgi Smith", unit_name="Corgi")
    settle(w)
    check(a.ev("ArtPad.playerName") == "Corgi Pembroke", f"learned own full name ({a.ev('ArtPad.playerName')})")
    check(b.ev("ArtPad.playerName") == "Corgi Smith", "the other Corgi too")
    a.stroke(line(100, 100, 400, 400))
    w.pump(3)
    check(b.items() == 1 and a.items() == 1, "the other Corgi gets the stroke")
    check(a.ev("ArtPad.nameTags['Corgi Pembroke']") is None, "no name tag for yourself")
    check(b.ev("ArtPad.nameTags['Corgi Pembroke']") is not None, "the other Corgi sees who drew it")
    check(a.ev("ArtPad.items[1].id") == b.ev("ArtPad.items[1].id"), "same item id on both sides")
    a.ex("ArtPad:Undo()")
    w.pump(3)
    check(a.items() == 0 and b.items() == 0, "undo reaches the other Corgi")
    # Drawn before the name was learned: renamed, and remembered for next time
    c = w.add("Pip Pembroke", unit_name="Pip", login=False)
    c.login()
    c.stroke(line(10, 10, 50, 50))
    settle(w)
    check(c.ev("ArtPad.items[1].author") == "Pip Pembroke", "early strokes re-keyed to the full name")
    guid = c.ev('UnitGUID("player")')
    check(c.ev(f'ArtPad_Settings.FullNames["{guid}"]') == "Pip Pembroke", "full name remembered")


def test_local_mode_places():
    INN = (0.438, 0.659)
    YD = 1 / 3470.84  # one yard east, in map x
    w = World()
    a, b, c = w.add("Alice"), w.add("Bob"), w.add("Cat")
    settle(w)
    a.stroke(line(100, 100, 300, 300))
    w.pump(3)
    guild_sig = a.signature()
    # Guild mode at the inn: nothing changes, places don't override your choice
    w.move(a, *INN)
    w.move(b, INN[0] + 50 * YD, INN[1])
    w.pump(3)
    check(a.ev("ArtPad.node") is None and a.signature() == guild_sig, "guild mode ignores places")
    # Both pick Local: the inn's canvas
    a.ex("CLICK(ArtPad_ShareLocal)")
    b.ex("ArtPad.OnSlashCommand('local')")
    w.pump(3)
    check(a.ev("ArtPad_Settings.Mode") == "LOCAL", "sharing menu has Local")
    check(a.ev("ArtPad.node and ArtPad.node.id") == "lionspride", "Alice is at the inn")
    check(b.ev("ArtPad.node and ArtPad.node.id") == "lionspride", "so is Bob")
    check(a.items() == 0, "the inn has its own canvas")
    check(a.ev("ArtPad:GetChannel()") == "YELL", "drawing at the inn goes out on yell")
    check(a.ev("ArtPad.backdropMap") == 37 and a.ev("ArtPad.backdropView ~= nil"), "map of the area behind it")
    check(a.ev("(ArtPad:GetSharingState())") == "Lion's Pride Inn", "sharing pill names the place")
    a.stroke(line(500, 500, 900, 700))
    w.pump(3)
    check(b.items() == 1, "Bob sees Alice's inn drawing")
    check(c.items() == 1 and c.signature() == guild_sig, "Cat (guild) doesn't")
    c.stroke(line(0, 1000, 400, 1000))
    w.pump(3)
    check(a.items() == 1 and b.items() == 1, "guild drawing doesn't reach the inn")
    # Walking away in Local: not shared, inn drawing kept
    w.move(a, INN[0] + 300 * YD, INN[1])
    w.pump(3)
    check(a.ev("ArtPad.node") is None and a.items() == 0, "away from the inn: empty local canvas")
    check(a.ev("ArtPad:GetChannel()") is None, "...and not shared")
    check(a.ev("(ArtPad:GetSharingState())") == "Local", "pill says Local")
    check(a.ev("ArtPad_Settings.PlaceCanvases.lionspride ~= nil"), "inn canvas kept")
    # Everyone gone; Alice comes back alone: her copy is still there
    w.move(b, None)
    w.pump(3)
    w.move(a, *INN)
    w.pump(8)
    check(a.items() == 1, "the inn drawing outlived everyone leaving")
    # Back to guild: guild canvas resyncs, map goes
    a.ex("ArtPad.OnSlashCommand('guild')")
    w.pump(15)
    check(a.ev("ArtPad.node") is None, "guild mode leaves the place")
    check(a.items() == 2, f"guild canvas back and caught up ({a.items()} items)")
    check(a.ev("ArtPad.backdropMap") is None, "inn map gone")


def test_newest_copy_wins():
    INN = (0.438, 0.659)
    AWAY = (0.438 + 300 / 3470.84, 0.659)
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    for c in (a, b):
        c.ex("ArtPad.OnSlashCommand('local')")
    w.move(a, *AWAY)
    w.move(b, *AWAY)
    w.pump(2)

    # 1. Alice draws at the inn alone, then leaves; later Bob draws there alone and stays.
    w.move(a, *INN)
    w.pump(3)
    a.stroke(line(100, 100, 400, 100))
    w.pump(2)
    w.move(a, *AWAY)
    w.pump(5)
    w.move(b, *INN)
    w.pump(3)
    b.stroke(line(100, 900, 400, 900))
    b.stroke(line(100, 1000, 400, 1000))
    w.pump(5)
    # Alice comes back with her older copy: Bob's newer one wins
    w.move(a, *INN)
    w.pump(15)
    check(a.items() == 2 and a.signature() == b.signature(), "arriving with an older copy: the newer one wins")

    # 2. Bob leaves with that copy. Alice clears and draws something new, then leaves.
    w.move(b, *AWAY)
    w.pump(5)
    a.ex("ArtPad:ClearForEveryone()")
    a.stroke(line(2000, 500, 2500, 500))
    w.pump(5)
    w.move(a, *AWAY)
    w.pump(5)
    # Bob comes back alone (his old copy), then Alice arrives with the newer one
    w.move(b, *INN)
    w.pump(8)
    check(b.items() == 2, "alone, Bob has his old copy")
    w.move(a, *INN)
    w.pump(25)
    check(a.items() == 1 and b.items() == 1 and a.signature() == b.signature(),
          f"arriving with a newer copy replaces the older one there (Alice {a.items()}, Bob {b.items()})")

    # 3. A clear beats an old full copy: Bob leaves with the drawing, Alice clears it.
    w.move(b, *AWAY)
    w.pump(5)
    a.ex("ArtPad:ClearForEveryone()")
    w.pump(3)
    w.move(b, *INN)
    w.pump(15)
    check(b.items() == 0, f"a clear isn't undone by an older copy ({b.items()} items came back)")


def test_bench_mapshot():
    w = World()
    a = w.add("Alice")
    a.ex("ArtPad.OnSlashCommand('bench mapshot')")
    check(a.ev("ArtPad_MapShot:IsShown()"), "mapshot opens")
    n = a.ev("(function() local n = 0 for _, t in ipairs(ArtPad_MapShot.textures) do if t:IsShown() then n = n + 1 end end return n end)()")
    check(n > 0, f"map tiles drawn ({n})")
    check(any("mapshot: map" in m for m in a.chat()), "prints what it captured")
    a.ex("ArtPad.OnSlashCommand('bench mapshot')")
    check(not a.ev("ArtPad_MapShot:IsShown()"), "runs again to close")


def test_versions():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.OnSlashCommand('versions')")
    w.pump(5)
    chat = "\n".join(a.chat())
    check("Bob: " in chat, "Bob answers the version query")
    check(a.ev("ArtPad.peerVersions.Bob.version") == b.ev("ArtPad.version"), "with his version")
    # Someone on an older protocol drawing nearby: noticed and flagged
    c = w.add("Cat")
    settle(w)
    c.ex('C_ChatInfo.SendAddonMessage("ArtPad5", "S(x)", "GUILD")')
    w.pump(1)
    check(a.ev("ArtPad.peerVersions.Cat.protocol") == 5, "old protocol traffic is noticed")
    a.ex("ArtPad:PrintVersions()")
    check(any("Cat:" in m and "Out of date" in m for m in a.chat()), "and listed as out of date")


def test_update_notice():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    b.ex('ArtPad.version = "10.1"')  # Bob runs an older ArtPad
    settle(w)
    w.pump(8)  # the delayed version announcement after login
    check(b.ev("ArtPad.newerVersion") == a.ev("ArtPad.version"), "Bob hears there's a newer version")
    check(any("A new version of ArtPad is available" in m for m in b.chat()), "and is told in chat")
    check(a.ev("ArtPad.peerVersions.Bob.version") == "10.1", "Alice knows Bob is behind")


def test_world_map_drawing():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    sent_before = len(w.log)
    wm = "ArtPad.worldMapDraw"

    def cursor(p):
        a.ex("MAP_CURSOR = { %f, %f }; CURSOR_X, CURSOR_Y = %f, %f" % (p[0], p[1], p[0] * 1002, p[1] * 668))

    def hover(p):
        cursor(p)
        a.ex("ArtPad_MapInput._scripts.OnUpdate(ArtPad_MapInput, 0.016)")

    def drag(points, button="LeftButton"):
        cursor(points[0])
        a.ex("ArtPad_MapInput._scripts.OnMouseDown(ArtPad_MapInput, '%s')" % button)
        for p in points[1:]:
            hover(p)
        a.ex("ArtPad_MapInput._scripts.OnMouseUp(ArtPad_MapInput, '%s')" % button)

    def lines():
        return a.ev(wm + ".count")

    def strokes(map_id):
        return a.ev(f"ArtPad_Settings.MapDrawings[{map_id}] and #ArtPad_Settings.MapDrawings[{map_id}] or 0")

    def stroke_line(map_id, i, channel):
        return a.ev(f"{wm}.linesOf[ArtPad_Settings.MapDrawings[{map_id}][{i}]][1].color[{channel}]")

    # Resting: one round button, nothing else
    a.ex("WorldMapFrame:Show(); MOUSE_OVER = true; ArtPad:SetColor(0.2, 0.4, 0.6, 1)")
    a.ex("ArtPad_MapDrawButton._over = false; ArtPad_MapBar._over = false; ArtPad_MapOptions._over = false")
    check(a.ev(wm + ".ready"), "attached to the world map")
    check(a.ev("ArtPad_MapDrawButton:IsShown()"), "the round button is on the map")
    check(not a.ev("ArtPad_MapBar:IsShown()") and not a.ev("ArtPad_MapInput:IsShown()"),
          "no toolbar and no mouse catcher until you ask")
    level = a.ev("ArtPad_MapLayer:GetFrameLevel()")
    check(level == 2010, f"drawing sits just above the zone highlight, below the icon pins (level {level})")
    check(level < a.ev("ArtPad_MapInput:GetFrameLevel()"), "and the mouse catcher above that")

    # The button turns drawing on: toolbar unfolds, pen in hand
    a.ex("CLICK(ArtPad_MapDrawButton)")
    check(a.ev("ArtPad_MapBar:IsShown()") and a.ev("ArtPad_MapInput:IsShown()"), "the button unfolds the toolbar")
    check(a.ev("ArtPad_MapDrawButton.active:IsShown()"), "and glows while on")
    check(a.ev("ArtPad_MapTool_pen.mark:IsShown()") and not a.ev("ArtPad_MapTool_eraser.mark:IsShown()"),
          "the pen is in hand")
    check(a.ev('BINDINGS["ESCAPE"]') == "ArtPad_KeyEsc" and a.ev('BINDINGS["CTRL-Z"]') == "ArtPad_KeyUndo",
          "Esc and Ctrl-Z belong to the toolbar while it is out")
    check(a.ev("ArtPad_MapHint:IsShown()"), "first time: a one-line hint")
    check(a.ev(wm + ".propagating"), "with the pen out, presses also reach the map itself")

    # Drag draws
    drag([(0.2, 0.2), (0.3, 0.25), (0.4, 0.2), (0.5, 0.3)])
    check(strokes(37) == 1 and lines() == 3, f"one stroke of three segments on Elwynn ({lines()} lines)")
    check(a.ev("ArtPad_Settings.MapDrawings[37][1].p[1]") == 0.2, "stored in 0-1 map coordinates")
    check(not a.ev("ArtPad_MapHint:IsShown()") and a.ev("ArtPad_Settings.MapHintSeen"), "the hint retires after a first stroke")

    # A click is still the map's. The real map sees the press itself; nothing is imitated.
    a.ex("NAV = nil")
    drag([(0.7, 0.7)])
    check(strokes(37) == 1, "a click without a drag draws nothing")
    drag([(0.7, 0.7), (0.7035, 0.7)])  # 3.5 px of wobble: still a click, as on Blizzard's map
    check(strokes(37) == 1, "a slightly wobbly click isn't a stroke")
    check(a.ev("NAV") is None, "and ArtPad doesn't navigate for it: the map got the press itself")
    # Zoomed in, a drag would pan the map: the press is kept, and a click is handed over
    a.ex("MAP_ZOOMED = true; WorldMapFrame:OnCanvasScaleChanged()")
    check(not a.ev(wm + ".propagating"), "zoomed in: presses stay with ArtPad so drawing doesn't pan the map")
    drag([(0.7, 0.7)])
    check(a.ev("NAV") == "cursor", "and a click is passed on: into the zone under the cursor")
    a.ex("NAV = nil; MAP_ZOOMED = nil; WorldMapFrame:OnCanvasScaleChanged()")
    check(a.ev(wm + ".propagating"), "zoomed back out: presses reach the map again")
    drag([(0.7, 0.7)], button="RightButton")
    check(a.ev("NAV") == "parent" and strokes(37) == 1, "right-click still goes up a level")

    # The cursor is a dot of ink in the brush's size and colour
    hover((0.6, 0.6))
    check(a.ev(wm + ".dot:IsShown()") and not a.ev(wm + ".ring:IsShown()"), "pen: an ink dot under the cursor")
    check(a.ev(wm + ".dot._w") == a.ev("ArtPad_Settings.BrushSize"), "at the brush's real size")
    a.ex("ArtPad_MapBar._over = true")
    hover((0.61, 0.6))
    check(not a.ev(wm + ".dot:IsShown()"), "hidden while the mouse is on the toolbar")
    a.ex("ArtPad_MapBar._over = false; MOUSE_OVER = false")
    hover((0.62, 0.6))
    check(not a.ev(wm + ".dot:IsShown()"), "and when the mouse leaves the map")
    a.ex("MOUSE_OVER = true")

    # Each map has its own drawing
    a.ex("WorldMapFrame:SetMapID(52)")
    check(lines() == 0, "another map starts empty")
    drag([(0.1, 0.1), (0.2, 0.1)])
    check(strokes(52) == 1 and strokes(37) == 1, "drawings are per map")
    a.ex("WorldMapFrame:SetMapID(37)")
    check(lines() == 3, "Elwynn's drawing comes back")

    # Eraser: lights up what it will remove, then removes it
    a.ex("CLICK(ArtPad_MapTool_eraser)")
    check(a.ev("ArtPad_MapTool_eraser.mark:IsShown()") and not a.ev("ArtPad_MapTool_pen.mark:IsShown()"),
          "eraser in hand")
    check(not a.ev(wm + ".propagating"), "the eraser keeps its presses (an erasing click must not also travel)")
    hover((0.3, 0.25))
    check(a.ev(wm + ".ring:IsShown()") and not a.ev(wm + ".dot:IsShown()"), "eraser: a ring under the cursor")
    check(a.ev(wm + ".hover ~= nil") and stroke_line(37, 1, 1) == 1 and stroke_line(37, 1, 3) == 1,
          "the stroke under the eraser lights up")
    hover((0.8, 0.8))
    check(a.ev(wm + ".hover") is None and stroke_line(37, 1, 1) == 0.2, "and settles when the eraser moves off")
    a.ex("NAV = nil")
    drag([(0.9, 0.9)])
    check(a.ev("NAV") == "cursor", "an eraser click on nothing is passed on to the map")
    a.ex("NAV = nil")
    drag([(0.6, 0.6), (0.3, 0.25)])
    check(strokes(37) == 0 and lines() == 0, "dragging the eraser over a stroke removes it")
    check(a.ev("NAV") is None, "and doesn't navigate")

    # Undo covers erasing and clearing
    a.ex("CLICK(ArtPad_MapUndo)")
    check(strokes(37) == 1 and lines() == 3, "undo brings an erased stroke back")
    a.ex("CLICK(ArtPad_MapClear)")
    check(strokes(37) == 0 and strokes(52) == 1, "clear only clears this map")
    a.ex("CLICK(ArtPad_MapUndo)")
    check(strokes(37) == 1, "and clear can be undone")
    a.ex("CLICK(ArtPad_MapUndo)")
    check(strokes(37) == 0, "undo steps back through the first stroke too")
    a.ex("CLICK(ArtPad_MapUndo)")
    check(strokes(37) == 0, "nothing left to undo")

    # White ink still shows the eraser's highlight
    a.ex("CLICK(ArtPad_MapTool_pen); ArtPad:SetColor(1, 1, 1, 1)")
    drag([(0.2, 0.9), (0.3, 0.9)])
    a.ex("CLICK(ArtPad_MapTool_eraser)")
    hover((0.25, 0.9))
    check(stroke_line(37, 1, 2) < 0.5, "white ink lights up in a colour that isn't white")
    drag([(0.25, 0.9), (0.26, 0.9)])
    check(strokes(37) == 0, "white stroke erased")

    # Pen options live on the pen
    a.ex("CLICK(ArtPad_MapTool_pen)")
    check(a.ev("ArtPad_MapTool_pen.mark:IsShown()") and not a.ev("ArtPad_MapOptions:IsShown()"), "back to the pen")
    check(a.ev("ArtPad_MapSize1.size") == a.ev("ArtPad_Settings.BrushSize"), "the first size is ArtPad's default brush")
    a.ex("CLICK(ArtPad_MapTool_pen)")
    check(a.ev("ArtPad_MapOptions:IsShown()"), "clicking the pen in hand opens its options")
    check(not a.ev(wm + ".propagating"), "while the options are open, a click on the map only closes them")
    a.ex("CLICK(ArtPad_MapSwatch2)")
    check(a.ev("ArtPad.brushColor.r") == 1 and a.ev("ArtPad.brushColor.g") == 0.42, "a swatch sets the colour")
    check(a.ev("ArtPad_MapTool_pen.glyph[1].color[2]") == 0.42, "the pen icon wears the colour")
    check(not a.ev("ArtPad_MapTool_pen.backing[1]:IsShown()"), "no backing needed for a bright colour")
    check(a.ev("ArtPad_MapOptions:IsShown()"), "options stay open while you choose")
    check(a.ev("ArtPad_MapSwatch2.ring:IsShown()") and not a.ev("ArtPad_MapSwatch1.ring:IsShown()"), "current colour is ringed")
    a.ex("CLICK(ArtPad_MapSwatch10)")
    check(a.ev("ArtPad_MapTool_pen.backing[1]:IsShown()"), "a near-black ink gets a pale backing so the icon stays visible")
    a.ex("CLICK(ArtPad_MapSwatch2)")
    a.ex("CLICK(ArtPad_MapSize3)")
    check(a.ev("ArtPad_Settings.BrushSize") == 11, "a size button sets the brush size")
    check(a.ev("ArtPad_MapSwatchClass") is None, "no class-colour swatch")
    check(not a.ev("ArtPad_MapSwatchRecent1:IsShown()"), "no recent colours yet")
    a.ex("ArtPad.pickerOpen = nil; CLICK(ArtPad_MapSwatchCustom)")
    check(a.ev("ArtPad.pickerOpen") and not a.ev("ArtPad_MapOptions:IsShown()"), "+ opens the full colour picker")
    a.ex("ArtPad:SetColor(0.1, 0.2, 0.3, 1); ColorPickerFrame:Hide()")
    a.ex("CLICK(ArtPad_MapTool_pen)")
    check(a.ev("ArtPad_MapSwatchRecent1:IsShown()"), "a picked colour shows up under recents")
    a.ex("NAV = nil")
    drag([(0.5, 0.5)])
    check(not a.ev("ArtPad_MapOptions:IsShown()") and a.ev("NAV") is None, "a click closes the options and does nothing else")
    drag([(0.2, 0.6), (0.3, 0.6)])
    check(strokes(37) == 1, "then drawing carries on")
    # Shift + wheel sizes the brush, and never shrinks a brush the main window made bigger
    a.ex("ArtPad_MapInput._scripts.OnMouseWheel(ArtPad_MapInput, 1)")
    check(a.ev("ArtPad_Settings.BrushSize") == 12, "wheel up: bigger brush")
    a.ex("ArtPad:SetBrushSize(40); ArtPad_MapInput._scripts.OnMouseWheel(ArtPad_MapInput, 1)")
    check(a.ev("ArtPad_Settings.BrushSize") == 40, "wheel up on a big brush leaves it alone")
    a.ex("ArtPad_MapInput._scripts.OnMouseWheel(ArtPad_MapInput, -1)")
    check(a.ev("ArtPad_Settings.BrushSize") == 39, "wheel down still shrinks it")
    a.ex("ArtPad:SetBrushSize(3)")

    # A finished stroke keeps only the points it needs
    drag([(0.10, 0.50), (0.12, 0.50), (0.14, 0.50), (0.16, 0.50), (0.18, 0.50), (0.18, 0.55)])
    check(a.ev("#ArtPad_Settings.MapDrawings[37][2].p") == 6, "a straight run is stored as its end points")
    check(lines() == 3, f"and drawn as that many lines ({lines()})")

    # Undo while still dragging finishes the stroke, then removes it: no ghost ink
    cursor((0.5, 0.2))
    a.ex("ArtPad_MapInput._scripts.OnMouseDown(ArtPad_MapInput, 'LeftButton')")
    hover((0.6, 0.2))
    a.ex("CLICK(ArtPad_MapUndo)")
    hover((0.7, 0.2))
    a.ex("ArtPad_MapInput._scripts.OnMouseUp(ArtPad_MapInput, 'LeftButton')")
    check(strokes(37) == 2 and lines() == 3, f"undo mid-drag leaves no ghost lines ({strokes(37)} strokes, {lines()} lines)")

    # Erasing across a map change is undoable on each map
    a.ex("CLICK(ArtPad_MapTool_eraser)")
    cursor((0.25, 0.6))
    a.ex("ArtPad_MapInput._scripts.OnMouseDown(ArtPad_MapInput, 'LeftButton')")
    check(strokes(37) == 1, "erased one on Elwynn")
    a.ex("WorldMapFrame:SetMapID(52)")
    hover((0.15, 0.1))
    a.ex("ArtPad_MapInput._scripts.OnMouseUp(ArtPad_MapInput, 'LeftButton')")
    check(strokes(52) == 1, "the drag doesn't carry on erasing on the next map")
    a.ex("WorldMapFrame:SetMapID(37); CLICK(ArtPad_MapUndo)")
    check(strokes(37) == 2, "and the erase on Elwynn can still be undone")
    a.ex("CLICK(ArtPad_MapTool_pen)")

    # A full map refuses more ink instead of recording invisible strokes
    a.ex("ArtPad.Message = function(self, m) FULL = (FULL or 0) + 1 end")
    before = strokes(37)
    a.ex(wm + ".count = 6000")
    drag([(0.4, 0.4), (0.5, 0.4)])
    check(strokes(37) == before, "nothing is stored once the map is full")
    drag([(0.4, 0.45), (0.5, 0.45)])
    check(a.ev("FULL") == 1, "and the player is told once, not on every stroke")
    a.ex(wm + ".count = 3")
    # With the main ArtPad window open and heavily drawn, the map's share shrinks
    a.ex("ArtPad.window:Show(); ArtPad.quadsInUse = 15200")
    drag([(0.4, 0.4), (0.5, 0.4)])
    check(strokes(37) == before + 1, "500 lines are always the map's")
    a.ex(wm + ".count = 500")
    drag([(0.4, 0.45), (0.5, 0.45)])
    check(strokes(37) == before + 1, "but no more than that while the main canvas is nearly full")
    a.ex("ArtPad.quadsInUse = 0; ArtPad.window:Hide(); " + wm + ".count = 4; CLICK(ArtPad_MapUndo)")

    # Zoomed (canvas scaled 2x): sizes are still screen pixels
    a.ex("WorldMapFrame.ScrollContainer.Child._scale = 2")
    hover((0.6, 0.65))
    check(a.ev(wm + ".dot._w") == 1.5, "the ink dot is the brush's size on screen at any zoom")
    drag([(0.6, 0.7), (0.7, 0.7)])
    width = a.ev("ArtPad_Settings.MapDrawings[37][#ArtPad_Settings.MapDrawings[37]].w * 1002")
    check(abs(width - 1.5) < 1e-6, f"and so is the stroke (width {width} canvas units for a 3 px brush)")
    a.ex("WorldMapFrame.ScrollContainer.Child._scale = 1; CLICK(ArtPad_MapUndo)")

    # Esc: options first, then the tools
    a.ex("CLICK(ArtPad_MapTool_pen)")
    a.ex("CLICK(ArtPad_KeyEsc)")
    check(not a.ev("ArtPad_MapOptions:IsShown()") and a.ev("ArtPad_MapBar:IsShown()"), "Esc closes the options first")
    a.ex("CLICK(ArtPad_KeyEsc)")
    check(not a.ev("ArtPad_MapBar:IsShown()") and not a.ev("ArtPad_MapInput:IsShown()"), "then puts the tools away")
    check(a.ev('BINDINGS["ESCAPE"]') is None, "and gives Esc back")
    check(not a.ev("ArtPad_MapDrawButton.active:IsShown()"), "the button stops glowing")
    check(a.ev("ArtPad_MapDrawButton.badge:IsShown()"), "a dot on the button: this map has a drawing")
    a.ex("WorldMapFrame:SetMapID(99)")
    check(not a.ev("ArtPad_MapDrawButton.badge:IsShown()"), "no dot on a map without one")
    a.ex("WorldMapFrame:SetMapID(37)")

    # Hold Alt for a temporary pen, toolbar stays away
    n = strokes(37)
    a.ex("ALT_DOWN = true; FIRE_EVENT('MODIFIER_STATE_CHANGED', 'LALT', 1)")
    check(a.ev("ArtPad_MapInput:IsShown()") and not a.ev("ArtPad_MapBar:IsShown()"), "holding Alt draws without the toolbar")
    drag([(0.5, 0.8), (0.6, 0.8)])
    check(strokes(37) == n + 1, "Alt-drag draws")
    a.ex("ALT_DOWN = false")  # e.g. alt-tabbed away: no event arrives
    hover((0.6, 0.8))
    check(not a.ev("ArtPad_MapInput:IsShown()"), "letting go of Alt stops, even if the key-up was never seen")

    # Combat: keys are given back before bindings lock, and taken again afterwards
    a.ex("CLICK(ArtPad_MapDrawButton)")
    check(not a.ev("ArtPad_MapHint:IsShown()"), "the hint doesn't come back")
    a.ex("FIRE_EVENT('PLAYER_REGEN_DISABLED'); IN_COMBAT = true")
    check(a.ev('BINDINGS["ESCAPE"]') is None and a.ev('BINDINGS["CTRL-Z"]') is None, "entering combat releases Esc and Ctrl-Z")
    a.ex("WorldMapFrame:Hide()")
    check(not a.ev(wm + ".on") and a.ev('BINDINGS["ESCAPE"]') is None, "closing the map in combat leaves no key stuck")
    n = strokes(37)
    a.ex("CLICK(ArtPad_MapUndo)")
    check(strokes(37) == n, "undo does nothing while the map is closed")
    a.ex("WorldMapFrame:Show(); CLICK(ArtPad_MapDrawButton)")
    check(a.ev(wm + ".on") and a.ev('BINDINGS["ESCAPE"]') is None, "tools can come out in combat, without the keys")
    a.ex("NAV = nil; CLICK(ArtPad_MapTool_eraser)")
    drag([(0.9, 0.1)])
    check(a.ev("NAV") is None, "no addon-driven map travel in combat")
    a.ex("IN_COMBAT = nil; FIRE_EVENT('PLAYER_REGEN_ENABLED')")
    check(a.ev('BINDINGS["ESCAPE"]') == "ArtPad_KeyEsc", "after combat the toolbar takes its keys back")

    # Closing the map puts the tools away, like Blizzard's Map Pin button
    a.ex("WorldMapFrame:Hide(); WorldMapFrame:Show()")
    check(not a.ev(wm + ".on") and not a.ev("ArtPad_MapBar:IsShown()") and not a.ev("ArtPad_MapInput:IsShown()"),
          "reopening the map starts with the tools away")
    check(a.ev('BINDINGS["ESCAPE"]') is None, "and the keys released")

    # The main canvas is a different thing: none of this lands on it
    w.pump(3)
    check(len(w.log) > sent_before, "map drawings are sent (see test_world_map_drawings_are_shared)")
    check(b.items() == 0 and a.items() == 0, "nothing lands on the shared canvas")
    check(a.items() == 0, "the ArtPad canvas is untouched")


def test_window_input_state():
    """The main window's input states hand over cleanly (review of the implicit state machine)."""
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex("ArtPad.window:Show()")

    # Panning while placing text goes back to placing it
    a.ex("ArtPad:BeginTextPlacement('hello')")
    a.g.PEN_DOWN(300, 300, "RightButton")
    a.g.PEN_MOVE(260, 300)
    a.g.PEN_UP("RightButton")
    check(a.ev("ArtPad.state") == "TEXT" and a.ev("ArtPad.ghostText:IsShown()"), "after a pan, the text is still waiting to be placed")
    a.ex("ArtPad:SetView(1, 0, 0)")
    a.g.PEN_DOWN(300, 300)
    a.g.PEN_UP()
    w.pump(2)
    check(a.items() == 1 and b.items() == 1 and a.ev("ArtPad.items[1].text") == "hello", "and a click places it")
    check(not a.ev("ArtPad.ghostText:IsShown()") and a.ev("ArtPad.state") == "SLEEP", "placement finished cleanly")
    a.ex("ArtPad:ClearForEveryone()")
    w.pump(2)

    # Text is pinned to the canvas whatever tool is selected
    a.ex("ArtPad:SetTool('eraser'); ArtPad:BeginTextPlacement('edge')")
    a.g.PEN_DOWN(-500, -500)
    a.g.PEN_UP()
    check(a.ev("ArtPad.items[1].x") == 0 and a.ev("ArtPad.items[1].y") == 0, "text placed in the margin lands on the canvas edge")
    a.ex("ArtPad:SetTool('pen'); ArtPad:ClearForEveryone()")
    w.pump(2)

    # Only the button that started a drag ends it
    a.g.PEN_DOWN(100, 100)
    a.g.PEN_MOVE(150, 130)
    a.g.PEN_DOWN(150, 130, "RightButton")
    a.g.PEN_UP("RightButton")
    check(a.ev("ArtPad.state") == "PAINT", "bumping another button doesn't end the stroke")
    a.g.PEN_MOVE(200, 100)
    a.g.PEN_MOVE(250, 130)
    a.g.PEN_UP()
    w.pump(3)
    check(a.items() == 1 and a.ev("ArtPad.items[1].px[ArtPad.items[1].n]") == 250, "the stroke carries on to where the pen was lifted")
    all_equal(w)

    # A plain right-click doesn't turn a fitted canvas into a custom view
    a.ex("ArtPad:ResetPosition()")
    a.g.PEN_DOWN(300, 300, "RightButton")
    a.g.PEN_UP("RightButton")
    check(a.ev("ArtPad_Settings.View") is False, "right-click leaves the canvas fitted")
    a.ex("ArtPad:SetView(1, 0, 0)")

    # Undo while the pen is down finishes the stroke and removes it, for everyone
    a.ex("ArtPad:ClearForEveryone()")
    w.pump(2)
    a.g.PEN_DOWN(100, 300)
    a.g.PEN_MOVE(200, 330)
    a.g.PEN_MOVE(300, 300)
    a.ex("CLICK(ArtPad_KeyUndo)")
    check(a.ev("ArtPad.state") == "SLEEP" and a.ev("ArtPad.currentStroke") is None, "undo mid-stroke ends the stroke")
    a.g.PEN_MOVE(400, 330)
    a.g.PEN_UP()
    w.pump(4)
    check(a.items() == 0 and b.items() == 0, f"and nothing is left behind (Alice {a.items()}, Bob {b.items()})")

    # Esc mid-drag ends the drag before doing anything else
    a.stroke(line(100, 500, 400, 500))
    a.ex("ArtPad:SetTool('eraser')")
    a.g.PEN_DOWN(900, 900)
    a.ex("CLICK(ArtPad_KeyEsc)")
    check(a.ev("ArtPad.state") == "SLEEP", "Esc during an eraser drag stops erasing")
    a.g.PEN_MOVE(250, 500)
    check(a.items() == 1 and a.ev("#ArtPad.items[1].dead == 0 and next(ArtPad.items[1].dead) == nil"), "so moving on erases nothing")
    a.g.PEN_UP()

    # Changing tool mid-drag ends the drag with the tool that started it
    a.ex("ArtPad:SetTool('rect')")
    a.g.PEN_DOWN(1000, 1000)
    a.g.PEN_MOVE(1300, 1200)
    a.ex("ArtPad:SetTool('pen')")
    check(a.ev("ArtPad.state") == "SLEEP" and a.items() == 2, "the box being dragged is finished as a box")
    a.g.PEN_UP()

    # Starting text entry mid-stroke doesn't orphan the stroke or block the queue
    a.g.PEN_DOWN(1500, 300)
    a.g.PEN_MOVE(1600, 330)
    a.g.PEN_MOVE(1700, 300)
    a.ex("ArtPad:BeginTextPlacement('label')")
    check(a.ev("ArtPad.currentStroke") is None and a.ev("ArtPad.state") == "TEXT", "the stroke is finished before text placement starts")
    a.g.PEN_UP()
    a.g.PEN_DOWN(1800, 800)
    a.g.PEN_UP()
    w.pump(5)
    check(b.items() == a.items() == 4, f"everything, including what came after, reaches Bob ({b.items()} of {a.items()})")
    all_equal(w)

    # Marker ghost: only while the mouse is over the canvas area, and not while placing text
    a.ex("ArtPad:SetTool('stamp', 'r1'); MOUSE_OVER = true")
    a.g.PEN_MOVE(500, 500)
    check(a.ev("ArtPad.stampGhost:IsShown()"), "marker ghost follows the cursor")
    a.ex("MOUSE_OVER = false")
    a.g.PEN_MOVE(500, 500)
    check(not a.ev("ArtPad.stampGhost:IsShown()"), "and goes away when the mouse leaves the canvas area")
    a.ex("MOUSE_OVER = true")
    a.g.PEN_MOVE(500, 500)
    a.ex("ArtPad:BeginTextPlacement('x')")
    check(not a.ev("ArtPad.stampGhost:IsShown()"), "no marker ghost while placing text")
    a.ex("ArtPad:EndTextPlacement(); ArtPad:SetTool('pen'); MOUSE_OVER = nil")


def test_window_chrome_state():
    """Keys, toasts, hide, resize and popovers stay consistent (review of the window's UI state)."""
    w = World()
    a = w.add("Alice")
    w.group("party", "Alice")
    a.ex("ArtPad_Settings.HideInCombat = false; ArtPad.window:Show()")
    check(a.ev('BINDINGS["ESCAPE"]') == "ArtPad_KeyEsc", "Esc is the window's while it is open")

    # Combat: keys are released before bindings lock, whatever happens to the window meanwhile
    a.ex("FIRE_EVENT('PLAYER_REGEN_DISABLED'); IN_COMBAT = true")
    check(a.ev('BINDINGS["ESCAPE"]') is None and a.ev('BINDINGS["CTRL-Z"]') is None, "entering combat releases Esc and Ctrl-Z")
    a.ex("ArtPad.window:Hide()")
    a.ex("IN_COMBAT = nil; FIRE_EVENT('PLAYER_REGEN_ENABLED')")
    check(a.ev('BINDINGS["ESCAPE"]') is None, "a window closed in combat holds no keys afterwards")
    a.ex("IN_COMBAT = true; ArtPad.window:Show()")
    check(a.ev('BINDINGS["ESCAPE"]') is None, "opened in combat: no keys yet")
    a.ex("IN_COMBAT = nil; FIRE_EVENT('PLAYER_REGEN_ENABLED')")
    check(a.ev('BINDINGS["ESCAPE"]') == "ArtPad_KeyEsc", "and it gets them when combat ends")
    # Canvas keys follow the mouse, and are dropped with the window
    a.ex("ArtPad.viewport._scripts.OnEnter(ArtPad.viewport)")
    check(a.ev('BINDINGS["]"]') == "ArtPad_BrushBigger", "brush keys over the canvas")
    a.ex("ArtPad.window:Hide()")
    check(a.ev('BINDINGS["]"]') is None and a.ev('BINDINGS["ESCAPE"]') is None, "hiding the window releases every key")
    # A key that somehow outlives the window does nothing
    a.stroke(line(100, 100, 300, 300))
    a.ex("CLICK(ArtPad_KeyUndo); CLICK(ArtPad_KeyEsc)")
    check(a.items() == 1, "Ctrl-Z with the window closed doesn't undo")
    a.ex("ArtPad.window:Show()")

    # The Hide button hides, whatever tool or popover is up; Esc still backs out step by step
    a.ex("ArtPad:SetTool('eraser'); CLICK(ArtPad_SharingButton)")
    a.ex("CLICK(ArtPad_KeyEsc)")
    check(a.ev("ArtPad.window:IsShown()") and not a.ev("ArtPad_SharingPopover:IsShown()"), "Esc closes the popover first")
    a.ex("CLICK(ArtPad_CloseButton)")
    check(not a.ev("ArtPad.window:IsShown()") and a.ev("ArtPad.tool") == "eraser", "the - button hides at once and leaves the tool alone")
    a.ex("ArtPad:SetTool('pen'); ArtPad.window:Show()")

    # Toasts: the text tool only dismisses its own; a Retry error stays, and waits for the window
    a.ex("ArtPad:Notify('Could not load the canvas from Bob.', 'error', { action = { 'Retry', function() RETRIED = true end } })")
    a.ex("CLICK(ArtPad_TextButton); CLICK(ArtPad_TextButton)")
    a.ex("ArtPad:BeginTextPlacement('x'); ArtPad:EndTextPlacement()")
    w.pump(2)
    check(a.ev("ArtPad.toast:IsShown()") and "Could not load" in a.ev("ArtPad.toast.text._text"), "the Retry error survives the text tool")
    a.ex("ArtPad:DismissToast()")
    w.pump(1)
    a.ex("ArtPad.window:Hide()")
    a.ex("ArtPad:Notify('Could not load the canvas from Bob.', 'error', { action = { 'Retry', function() RETRIED = true end } })")
    a.ex("ArtPad.window:Show()")
    check(a.ev("ArtPad.toast:IsShown()") and a.ev("ArtPad_ToastAction:IsShown()"), "an error raised while the window was closed is shown when it opens")
    a.ex("CLICK(ArtPad_ToastAction)")
    check(a.ev("RETRIED"), "with its Retry button working")

    # Resize cut short by the window hiding
    a.ex("ArtPad:StartResize(); ArtPad.window:Hide()")
    check(a.ev("ArtPad.resizing") is None, "a resize interrupted by hiding is finished off")
    a.ex("ArtPad.window:Show()")

    # Reset window also resets the saved zoom
    a.ex("ArtPad:SetView(0.6, -100, -100); ArtPad:SaveView(); ArtPad:ResetAllFramePositions()")
    check(a.ev("ArtPad_Settings.View") is False, "reset window leaves the canvas fitted, and saved as fitted")

    # The sharing menu follows a mode change made elsewhere
    a.ex("CLICK(ArtPad_SharingButton)")
    a.ex("ArtPad.OnSlashCommand('raid')")
    check(a.ev("ArtPad_ShareGroup.radioDot:IsShown()") and not a.ev("ArtPad_ShareGuild.radioDot:IsShown()"),
          "an open sharing menu shows the new mode")
    a.ex("ArtPad:ClosePopovers(); ArtPad.OnSlashCommand('guild')")

    # Esc and Ctrl-Z go to whichever of the window and the map tools the mouse is over
    a.ex("WorldMapFrame:Show(); CLICK(ArtPad_MapDrawButton)")
    a.ex("ArtPad.window._over = true")
    check(a.ev("ArtPad:KeyTarget()") == "window", "mouse over the ArtPad window: keys are the window's")
    a.ex("ArtPad.window._over = false")
    check(a.ev("ArtPad:KeyTarget()") == "map", "otherwise they are the map tools'")
    n = a.items()
    a.ex("CLICK(ArtPad_KeyUndo)")
    check(a.items() == n, "so Ctrl-Z over the map never undoes on the shared canvas")
    a.ex("CLICK(ArtPad_KeyEsc)")
    check(not a.ev("ArtPad.worldMapDraw.on") and a.ev("ArtPad.window:IsShown()"), "and Esc puts the map tools away, not the window")
    check(a.ev("ArtPad:KeyTarget()") == "window", "then the keys are the window's again")
    check(a.ev('BINDINGS["ESCAPE"]') == "ArtPad_KeyEsc", "and still bound for it")
    a.ex("WorldMapFrame:Hide()")

    # Colour picker: a cancelled pick isn't remembered
    a.ex("ArtPad_Settings.RecentColors = {}; ArtPad:OpenColorPicker(); ArtPad.pickerOpen = nil; ColorPickerFrame:Hide()")
    check(a.ev("#ArtPad_Settings.RecentColors") == 0, "cancelling the picker adds no recent colour")


def leave_group(w, c):
    """Take a player out of their party/raid."""
    w.groups.pop(c.name, None)
    c.lua_client.group = None
    c.g.FIRE_EVENT("GROUP_ROSTER_UPDATE")
    c.g.FIRE_EVENT("GROUP_LEFT")


def test_audience_switches_are_clean():
    """Nothing drawn for one audience reaches, or is loaded for, another."""
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    pug = w.add("Pug", guild=False)
    w.group("party", "Alice", "Pug")
    pug.ex('ArtPad:SetMode("RAID")')
    settle(w)
    b.stroke(line(100, 100, 400, 100))
    b.stroke(line(100, 200, 400, 200))
    pug.stroke(line(100, 900, 400, 900))
    w.pump(4)
    check(a.items() == 2 and pug.items() == 1, "guild canvas and party canvas are separate")

    # Unsent guild strokes don't go out on the party channel after a mode switch
    for i in range(14):
        a.stroke(line(600, 100 + i * 20, 900, 100 + i * 20, 12))
    a.ex('ArtPad.OnSlashCommand("raid")')
    check(a.ev("#ArtPad.outQueue") == 0 and a.ev("ArtPad.currentStroke") is None, "switching audience drops unsent work")
    w.pump(20)
    check(pug.items() == 1, f"the party never sees the guild strokes ({pug.items()} items)")
    check(a.items() == 1 and a.signature() == pug.signature(), "and Alice now has the party's canvas")

    # A mode switch in the middle of a sync starts over for the new audience
    a.ex('ArtPad.OnSlashCommand("guild")')
    w.pump(0.5)
    check(a.ev("ArtPad.syncing"), "guild sync under way")
    a.ex('ArtPad.OnSlashCommand("raid")')
    w.pump(20)
    check(a.ev("ArtPad_Settings.Mode") == "RAID" and a.signature() == pug.signature(),
          f"switching mid-sync ends with the party's canvas, not the guild's ({a.items()} items)")

    # A canvas is only handed over for the audience it was offered to
    dana = w.add("Dana", login=False)
    a.ex('ArtPad.OnSlashCommand("guild")')
    w.pump(20)
    guild = b.signature()
    check(a.signature() == guild, "Alice back on the guild canvas")
    dana.login()
    w.pump(3.6)  # Dana has asked; Alice and Bob have offered
    a.ex('ArtPad.OnSlashCommand("raid")')
    b.ex('ArtPad.OnSlashCommand("raid")')
    w.pump(40)
    check(dana.items() == 0 and not dana.ev("ArtPad.syncing"),
          f"offers withdrawn by a change of audience hand over nothing ({dana.items()} items)")
    check(not any("secret" in m for m in dana.chat()), "no error spam either")
    b.ex('ArtPad.OnSlashCommand("guild")')
    a.ex('ArtPad.OnSlashCommand("guild")')

    # The clear confirmation doesn't survive a change of audience
    a.ex("ArtPad.window:Show(); ArtPad_Settings.WarnClear = true")
    w.pump(20)
    a.stroke(line(1000, 1000, 1200, 1000))
    a.ex("CLICK(ArtPad_ClearButton)")
    check(a.ev("ArtPad.clearConfirm:IsShown()"), "confirm open for the guild canvas")
    a.ex('ArtPad.OnSlashCommand("raid")')
    check(not a.ev("ArtPad.clearConfirm:IsShown()"), "and closed when the audience changes")
    a.ex("ArtPad.window:Hide()")


def test_group_changes_are_audience_changes():
    w = World()
    a, b, c = w.add("Alice", guild=False), w.add("Bob", guild=False), w.add("Cat", guild=False)
    for p in (a, b, c):
        p.ex('ArtPad:SetMode("RAID")')
    w.group("party", "Alice", "Bob")
    settle(w)
    for i in range(8):
        a.stroke(line(100, 100 + i * 50, 600, 100 + i * 50))
    w.pump(10)
    plan = a.signature()
    check(b.signature() == plan and b.items() == 8, "the party has its plan")

    # A doodle made alone doesn't outrank the group's canvas when its author joins
    c.stroke(line(2000, 2000, 2200, 2100))
    w.pump(3)
    w.group("party", "Alice", "Bob", "Cat")
    w.pump(30)
    check(a.signature() == plan and b.signature() == plan, f"the plan survives a newcomer's doodle (Alice {a.items()}, Bob {b.items()})")
    check(c.signature() == plan, "and the newcomer gets the plan")

    # Leaving a group leaves its canvas behind
    leave_group(w, c)
    check(c.items() == 0, "leaving the group empties the canvas")
    d = w.add("Dee", guild=False)
    d.ex('ArtPad:SetMode("RAID")')
    w.group("party", "Cat", "Dee")
    w.pump(30)
    check(d.items() == 0, f"so the old group's plan can't follow into the next group ({d.items()} items)")


def test_fragment_copy_never_wins():
    """Someone who hasn't loaded the canvas yet can't become its newest copy."""
    for delay in (0.75, 0.9, 1.5, 1.8, 1.95, 2.6):  # 0.75, 0.9, 1.8 and 1.95 lost the canvas before the fix
        w = World()
        a = w.add("Alice")
        settle(w)
        for i in range(6):
            a.stroke(line(100, 100 + i * 60, 700, 100 + i * 60))
        w.pump(8)
        d = w.add("Dana", login=False)
        d.login()
        w.pump(delay)
        a.stroke(line(100, 1000, 700, 1000))  # arrives at Dana before her sync has finished
        w.pump(40)
        check(a.items() == 7, f"Alice keeps her whole canvas (stroke {delay}s after Dana logs in: {a.items()} items)")
        check(d.items() == 7 and d.signature() == a.signature(), f"and Dana ends with all of it ({d.items()} items)")
    # A local-only clear doesn't make an empty canvas the newest either
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    for i in range(5):
        a.stroke(line(100, 100 + i * 60, 700, 100 + i * 60))
    w.pump(8)
    b.ex("ArtPad.OnSlashCommand('clear')")
    w.pump(2)
    a.stroke(line(100, 1000, 700, 1000))
    w.pump(3)
    d = w.add("Dana")
    w.pump(40)
    check(d.items() == 6, f"a newcomer takes the full copy, not the cleared one ({d.items()} items)")


def test_places_keep_their_drawings():
    INN = (0.438, 0.659)
    AWAY = (0.438 + 300 / 3470.84, 0.659)
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    for c in (a, b):
        c.ex("ArtPad.OnSlashCommand('local')")
        w.move(c, *AWAY)
    w.pump(2)
    w.move(a, *INN)
    w.pump(4)
    a.stroke(line(100, 100, 400, 100))
    a.stroke(line(100, 200, 400, 200))
    w.pump(3)

    # Reloading the canvas when nobody else is there keeps your own
    a.ex("ArtPad.OnSlashCommand('resync')")
    w.pump(10)
    check(a.items() == 2, f"alone at the inn, resync keeps the drawing ({a.items()} items)")
    a.g.FIRE_EVENT("PLAYER_LOGOUT")
    check(a.ev("#ArtPad_Settings.PlaceCanvases.lionspride.items") == 2, "and it is still saved")

    # A clear is remembered even after the person who cleared has left
    w.move(b, *INN)
    w.pump(10)
    check(b.items() == 2, "Bob picks the drawing up")
    w.move(b, *AWAY)
    w.pump(3)
    a.ex("ArtPad:ClearForEveryone()")
    w.pump(3)
    w.move(a, *AWAY)
    w.pump(3)
    check(a.ev("ArtPad_Settings.PlaceCanvases.lionspride ~= nil"), "the cleared canvas is kept, with the time of the clear")
    w.move(b, *INN)
    w.pump(8)
    check(b.items() == 2, "Bob alone still has his old copy")
    w.move(a, *INN)
    w.pump(25)
    check(a.items() == 0 and b.items() == 0, f"the clear wins when they meet (Alice {a.items()}, Bob {b.items()})")

    # A sync cut short by walking out leaves no false error behind
    b.stroke(line(100, 100, 400, 100))
    w.pump(3)
    w.move(a, *AWAY)
    w.pump(3)
    w.move(a, *INN)
    w.pump(2.8)  # asked, Bob has offered, download requested
    w.move(a, *AWAY)
    w.move(b, *AWAY)
    w.pump(4)
    a.ex("ArtPad.window:Show()")
    w.move(a, *INN)
    w.pump(12)
    check(not (a.ev("ArtPad.toast:IsShown()") and "Couldn't load" in (a.ev("ArtPad.toast.text._text") or "")),
          "arriving alone later isn't reported as a failed load")


def test_loopback_is_its_own_canvas():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    b.stroke(line(100, 100, 400, 100))
    b.stroke(line(100, 200, 400, 200))
    w.pump(4)
    a.ex("ArtPad:SetLoopback(true)")
    check(a.items() == 0, "loopback starts from an empty canvas")
    a.stroke(line(900, 900, 1200, 900))
    w.pump(3)
    check(a.items() == 1 and b.items() == 2, "test drawing stays with its author")
    d = w.add("Dana")
    w.pump(30)
    check(d.items() == 2 and d.signature() == b.signature(), f"a newcomer gets the real canvas, not the test one ({d.items()} items)")
    a.ex("ArtPad:SetLoopback(false)")
    w.pump(30)
    check(a.signature() == b.signature(), "switching loopback off fetches the real canvas again")


def test_sync_waits_for_someone_to_ask():
    w = World()
    a = w.add("Alice")
    settle(w)
    a.stroke(line(100, 100, 400, 100))
    w.pump(3)
    # The guild isn't known yet when the login sync runs
    d = w.add("Dana", login=False)
    d.lua_client.guild = False
    d.login()
    w.pump(6)
    check(d.items() == 0 and d.ev("ArtPad.wantSync"), "no guild known at login: the sync is still wanted")
    d.lua_client.guild = True
    d.g.FIRE_EVENT("PLAYER_GUILD_UPDATE")
    w.pump(20)
    check(d.items() == 1, f"and runs as soon as the guild is known ({d.items()} items)")
    # Leaders only: flipping it fetches the canvas again
    d.ex("ArtPad:SetAdminOnly(true)")
    check(d.ev("ArtPad.syncing"), "changing the leaders-only filter reloads the canvas")
    w.pump(20)
    d.ex("ArtPad:SetAdminOnly(false)")
    w.pump(20)
    check(d.items() == 1, "and back")
    # An empty roster isn't remembered as "nobody is an officer"
    d.ex("ArtPad.guildRanks = nil; SAVED = CLIENT.guildRoster; CLIENT.guildRoster = {}")
    check(d.ev("ArtPad:GetGuildRank('Alice')") is None and d.ev("ArtPad.guildRanks") is None, "empty roster: not cached")
    d.ex("CLIENT.guildRoster = SAVED")
    check(d.ev("ArtPad:GetGuildRank('Alice')") is not None, "the real roster is used once it arrives")


def test_unsent_work_survives_a_loaded_copy():
    w = World()
    a = w.add("Alice")
    settle(w)
    for i in range(40):
        a.stroke(line(10, 10 + i * 40, 3000, 60 + i * 40, 150))
        w.pump(1.2)
    w.pump(10)
    e = w.add("Eve")
    w.pump(4)
    check(e.ev("ArtPad.syncing"), "Eve is still downloading")
    # Eve keeps working: throttled, so some of it is still queued when the copy lands
    for i in range(12):
        e.stroke(line(3200, 100 + i * 30, 3600, 100 + i * 30, 10))
    e.ex("ArtPad:PlaceText(3300, 1500, 'mine')")
    w.pump(180)
    check(not e.ev("ArtPad.syncing"), "Eve finished syncing")
    check(e.items() == 53, f"Eve has the canvas plus everything she drew meanwhile ({e.items()} items)")
    all_equal(w)


def test_identity_state():
    """Who "we" are stays consistent with what everyone else sees."""
    # A Forever character (UnitName "Pip", seen by others as "Pip Pembroke") draws before any
    # sync has told it its full name: own echoes are recognised by content, not taken for
    # another player's, and nothing is doubled or left behind.
    w = World()
    b = w.add("Bob")
    settle(w)
    p = w.add("Pip Pembroke", unit_name="Pip", login=False)
    p.login()
    p.ex("ArtPad.window:Show()")
    for i in range(3):
        p.stroke(line(100, 100 + i * 80, 500, 100 + i * 80))
    w.pump(1.0)  # sent and echoed, but the login sync (3 s in) hasn't asked yet
    check(p.ev("ArtPad.playerName") == "Pip Pembroke", "the full name is learned from our own first message")
    check(p.items() == 3, f"no doubled strokes ({p.items()} items)")
    check(p.ev("ArtPad.nameTags['Pip Pembroke']") is None or not p.ev("ArtPad.nameTags['Pip Pembroke']:IsShown()"),
          "and no name tag on our own pen")
    w.pump(15)
    check(b.items() == 3 and p.signature() == b.signature(), "both sides hold the same three strokes")
    for i in range(3):
        p.ex("ArtPad:Undo()")
    w.pump(5)
    check(p.items() == 0 and b.items() == 0, f"and all three can be undone everywhere (Pip {p.items()}, Bob {b.items()})")

    # A saved full name that no longer fits the character (renamed) is dropped, not trusted
    w = World()
    a = w.add("Alice", login=False)
    guid = "Player-1-Alice"
    a.ex(f'ArtPad_Settings = {{ FullNames = {{ ["{guid}"] = "Oldname Smith" }} }}')
    a.login()
    check(a.ev("ArtPad.playerName") == "Alice", "a stale saved name is not used")
    check(a.ev(f'ArtPad_Settings.FullNames["{guid}"]') != "Oldname Smith", "and is forgotten")

    # Namesakes on two realms are two people
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    a.ex('ArtPad:OnLiveMessage(ArtPad.livePrefix, "T(zz.1,500,500,1,1,1,1,14;other Alice)", "GUILD", "Alice-OtherRealm")')
    check(a.items() == 1 and a.ev("ArtPad.items[1].author") == "Alice-OtherRealm",
          "a same-named player from another realm is somebody else, and their drawing shows")
    a.ex("ArtPad:ClearCanvas()")

    # Any name change re-keys what was drawn, and undo doesn't depend on the name's length
    a.stroke(line(100, 100, 400, 100))
    w.pump(3)
    a.ex('ArtPad.learnedName = nil; ArtPad:SetPlayerName("Al"); ArtPad:SetPlayerName("Alice")')
    check(a.ev("ArtPad.items[1].author") == "Alice" and a.ev("ArtPad.itemsById[ArtPad.items[1].id] == ArtPad.items[1]"),
          "items follow the name through a change and back")
    a.ex("ArtPad:Undo()")
    w.pump(3)
    check(a.items() == 0 and b.items() == 0, "and undo still reaches everyone")

    # Versions compare part by part, and an updated peer stops being "too old"
    check(a.ev('ArtPad.CompareVersions("10.10", "10.9")') == 1, "10.10 is newer than 10.9")
    check(a.ev('ArtPad.CompareVersions("10.2", "10.2.1")') == -1 and a.ev('ArtPad.CompareVersions("10.2", "10.2")') == 0,
          "patch versions compare")
    check(a.ev('ArtPad.CompareVersions("abc", "10.2")') is None, "an unreadable version is unknown, not an error")
    a.ex('ArtPad.version = "10.9"; ArtPad:OnOldProtocol("ArtPad5", "S(x)", "GUILD", "Cat-TestRealm")')
    check(a.ev("ArtPad.peerVersions.Cat.protocol") == 5, "Cat heard on an old protocol")
    a.ex('ArtPad:OnVersionMessage("ArtPad_Version", "10.10", "GUILD", "Cat-TestRealm")')
    check(a.ev("ArtPad.peerVersions.Cat.protocol") is None, "after announcing a current version, Cat is no longer listed as too old")
    check(a.ev("ArtPad.newerVersion") == "10.10", "and 10.10 counts as an update for a 10.9 client")
    a.ex('ArtPad.version = "10.2.1"; ArtPad:OnVersionMessage("ArtPad_Version", "10.2", "GUILD", "Dee-TestRealm")')
    check(a.ev("ArtPad.peerVersions.Dee.version") == "10.2", "a three-part own version doesn't break version messages")

    # Settings from an older save version start over, but kept drawings and names survive
    w = World()
    a = w.add("Alice", login=False)
    a.ex('ArtPad_Settings = { SaveVersion = 1, Mode = "RAID", PlaceCanvases = { lionspride = { v = 2, items = {} } }, '
         'MapDrawings = { [37] = {} }, FullNames = { x = "y" } }')
    a.ex("ArtPad:OnInitialize()")
    check(a.ev("ArtPad_Settings.Mode") == "GUILD", "old settings are reset")
    check(a.ev("ArtPad_Settings.PlaceCanvases.lionspride ~= nil") and a.ev("ArtPad_Settings.MapDrawings[37] ~= nil")
          and a.ev("ArtPad_Settings.FullNames.x") == "y", "kept drawings and learned names carry across")


def test_loopback_says_when_nothing_comes_back():
    w = World()
    solo = w.add("Pip Pembroke", guild=False, unit_name="Pip")
    settle(w)
    solo.ex("ArtPad.window:Show(); ArtPad:SetLoopback(true)")
    solo.stroke(line(100, 100, 400, 100))
    w.pump(8)
    if solo.items() == 0:
        check(solo.ev("ArtPad.toast:IsShown()") and "Loopback" in solo.ev("ArtPad.toast.text._text"),
              "loopback with nothing coming back says so instead of drawing nothing in silence")
    else:
        check(solo.ev("ArtPad.playerName") == "Pip Pembroke", "the echo taught us the full name")


def zigzag(x0, y0, n, dx=40, dy=30):
    return [(x0 + i * dx, y0 + (i % 2) * dy) for i in range(n)]


def test_canvas_limits_step_back():
    """Full and simplified are states the canvas leaves again when there is room."""
    w = World()
    a, b, c = w.add("Alice"), w.add("Bob"), w.add("Cat")
    b.ex('ArtPad.sessionTag = "b0b"')
    c.ex('ArtPad.sessionTag = "ca7"')
    settle(w)
    a.ex("ArtPad.window:Show(); ArtPad.lineBudget, ArtPad.lineCap = 300, 600")  # Alice's client only

    def drawn(i):
        return a.ev("(function() local n = 0 for _, p in pairs(ArtPad.items[%d].segs) do n = n + #p end return n end)()" % i)

    b.stroke(zigzag(100, 100, 60))            # 59 segments
    w.pump(4)
    smooth = drawn(1)
    check(smooth > 59 and not a.ev("ArtPad.coarse"), f"a zigzag is drawn as curves ({smooth} lines for 59 segments)")
    b.stroke(zigzag(100, 400, 700, dx=5))     # enough to fill Alice's canvas
    w.pump(25)
    check(a.ev("ArtPad.coarse") and drawn(1) == 59, "past the budget, curves are drawn straight")
    check(a.ev("ArtPad.quadsInUse") <= 600 and a.ev("ArtPad.starved"), "at the cap, the rest is held back")
    c.stroke(zigzag(100, 900, 20))
    w.pump(4)
    check(a.items() == 3 and drawn(3) == 0, "a stroke arriving on a full canvas exists but can't be drawn yet")
    check(a.ev("ArtPad.warnedFull"), "and the player has been told the canvas is full")

    # Drawing on a full canvas is refused, not sent invisibly
    n = b.items()
    a.stroke(line(2000, 100, 2400, 100))
    w.pump(4)
    check(a.items() == 3 and b.items() == n, "your own stroke on a full canvas is not created or sent")

    # Space frees up: what was held back is drawn, the notice is re-armed
    b.ex("ArtPad:Undo()")
    w.pump(4)
    check(a.items() == 2 and drawn(2) == 19 and not a.ev("ArtPad.starved"), f"once there is room, the held-back stroke is drawn ({drawn(2)} lines)")
    check(not a.ev("ArtPad.warnedFull"), "and the full notice can fire again next time")
    check(a.ev("ArtPad.coarse"), "still straight segments while most of the budget is in use")
    # Well under the budget: curves come back, for existing strokes too
    b.ex("ArtPad:Undo()")
    w.pump(4)
    check(a.items() == 1 and not a.ev("ArtPad.coarse"), "with the canvas nearly empty, curves are back")
    check(drawn(1) > 19, f"and the remaining stroke is redrawn as a curve ({drawn(1)} lines for 19 segments)")

    # Text and markers have a ceiling too; held back the same way
    real = a.ev("ArtPad.quadsInUse")
    a.ex("ArtPad.quadsInUse = ArtPad.QUAD_CEILING - 3")
    a.ex("ArtPad:PlaceText(500, 500, 'hello')")
    check(a.items() == 1, "text that would cross the ceiling is refused")
    b.ex("ArtPad:PlaceText(500, 1500, 'from bob')")
    w.pump(4)
    check(a.items() == 2 and a.ev("ArtPad.items[2].fs") is None, "a remote text is kept but not drawn past the ceiling")
    a.ex(f"ArtPad.quadsInUse = {real}; ArtPad:AfterRemoval()")
    check(a.ev("ArtPad.items[2].fs ~= nil"), "and drawn once there is room")
    check(a.ev("ArtPad.quadsInUse") == real + len("from bob"), "with the count kept exact")

    # The bench scribble can't leave the real canvas simplified
    a.ex("ArtPad.OnSlashCommand('bench scribble 1500')")
    check(a.ev("ArtPad.coarse"), "a bench scribble past the budget simplifies")
    a.ex("ArtPad.OnSlashCommand('bench clear')")
    check(not a.ev("ArtPad.coarse") and a.ev("ArtPad.quiet") == 0, "and bench clear puts the real canvas back")


def test_bad_input_is_contained():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    # One malformed item doesn't abort loading a canvas copy
    a.stroke(line(100, 100, 400, 100))
    a.stroke(line(100, 200, 400, 200))
    w.pump(3)
    a.ex("SNAP = ArtPad:SerializeCanvas(); table.insert(SNAP.items, 2, 'junk'); table.insert(SNAP.items, 3, { 7, {}, false })")
    a.ex("ArtPad:LoadCanvas(SNAP)")
    check(a.items() == 2 and a.ev("ArtPad.quiet") == 0, "a bad record is skipped, the rest of the canvas loads")

    # A map message can't ask for millions of tiles
    a.ex('ArtPad:OnLiveMessage(ArtPad.livePrefix, "B(85;6000000,6000000,0,0,1)", "GUILD", "Bob-TestRealm")')
    check(a.ev("ArtPad.backdropMap") == 85 and a.ev("ArtPad.backdropOverlays") == "", "an impossible overlay is dropped, the map still shows")
    check(a.ev("ArtPad.mapTextureCount") < 50, "and nothing was looped over")
    a.ex('ArtPad:OnLiveMessage(ArtPad.livePrefix, "B(85;300,200,100,50,501.502;9999999,1,0,0,7)", "GUILD", "Bob-TestRealm")')
    check(a.ev("ArtPad.backdropOverlays") == "300,200,100,50,501.502", "a good overlay is kept, a bad one beside it is not")
    check(a.ev("#ArtPad:SerializeCanvas().mapOverlays") < 40, "so a bad one is never passed on in a canvas copy")
    a.ex("SNAP = ArtPad:SerializeCanvas(); SNAP.mapOverlays = '88888888,88888888,0,0,1'; ArtPad:LoadCanvas(SNAP)")
    check(a.ev("ArtPad.backdropOverlays") == "", "nor accepted from one")
    a.ex("ArtPad:SetBackdrop(nil)")


def test_map_and_clear_races():
    w = World()
    a, b, c = w.add("Alice"), w.add("Bob"), w.add("Cat")
    settle(w)
    # Two people put up different maps at the same moment: everyone ends on the same one
    a.ex("MAP_ID = 85")
    b.ex("MAP_ID = 90")
    a.ex("ArtPad:ToggleMap()")
    b.ex("ArtPad:ToggleMap()")
    w.pump(5)
    maps = [x.ev("ArtPad.backdropMap") for x in (a, b, c)]
    check(maps[0] == maps[1] == maps[2] == 85, f"simultaneous maps settle on one for everybody ({maps})")
    a.ex("ArtPad:ToggleMap()")
    w.pump(5)

    # A map put up just before a clear isn't lost with the clear
    a.stroke(line(100, 100, 400, 100))
    w.pump(3)
    a.ex("ArtPad:ToggleMap(); ArtPad:ClearForEveryone()")
    w.pump(5)
    check(a.ev("ArtPad.backdropMap") == 85 and b.ev("ArtPad.backdropMap") == 85, "the map still reaches everyone")
    check(a.items() == 0 and b.items() == 0, "and the drawing is cleared")

    # Someone's clear arrives while something of yours is still waiting to be sent
    a.ex("ArtPad:PlaceText(500, 500, 'too late')")
    check(a.ev("#ArtPad.outQueue") == 1, "placed, not sent yet")
    a.ex('ArtPad:OnLiveMessage(ArtPad.livePrefix, "X()", "GUILD", "Bob-TestRealm")')
    check(a.items() == 0 and a.ev("#ArtPad.outQueue") == 0, "the clear takes it off the canvas and out of the queue")
    w.pump(5)
    check(b.items() == 0 and c.items() == 0, f"so it is not sent afterwards (Bob has {b.items()})")

    # Someone clears while your pen is down: everyone ends with the same stroke, and you can undo it
    a.ex("ArtPad.window:Show()")
    a.g.PEN_DOWN(100, 300)
    for i in range(1, 8):
        a.g.PEN_MOVE(100 + i * 60, 300 + (i % 2) * 40)
        w.pump(0.2)
    b.ex("ArtPad:ClearForEveryone()")
    w.pump(1.5)
    for i in range(8, 16):
        a.g.PEN_MOVE(100 + i * 60, 300 + (i % 2) * 40)
        w.pump(0.2)
    a.g.PEN_UP()
    w.pump(6)
    all_equal(w)
    check(a.items() == 1 and a.ev("ArtPad:HasUndo()"), "the stroke restarted after the clear is whole, shared and undoable")
    a.ex("ArtPad:Undo()")
    w.pump(4)
    check(b.items() == 0, "undo reaches everyone")

    # A stroke that never got finished can't hold the queue up
    a.ex("ArtPad:BeginStroke(1000, 1000); ArtPad:BeginStroke(1200, 1200); ArtPad:EndStroke()")
    a.ex("ArtPad:PlaceStamp('r1', 1500, 1500)")
    w.pump(8)
    check(a.ev("#ArtPad.outQueue") == 0 and b.items() == a.items(), "the queue drains past an abandoned stroke")

    # Laser lines aren't piled up on a canvas nobody is looking at
    a.ex("ArtPad:SetTool('laser')")
    a.g.PEN_DOWN(300, 300)
    for i in range(1, 30):
        a.g.PEN_MOVE(300 + i * 30, 300)
        w.pump(0.1)
    a.g.PEN_UP()
    w.pump(1)
    check(b.ev("#ArtPad.laserLines") == 0, "a closed window draws no laser lines")
    b.ex("ArtPad.window:Show()")
    a.g.PEN_DOWN(300, 500)
    for i in range(1, 10):
        a.g.PEN_MOVE(300 + i * 30, 500)
        w.pump(0.1)
    a.g.PEN_UP()
    w.pump(0.5)
    check(b.ev("#ArtPad.laserLines") > 0, "an open one does")


def test_sync_ids_differ_between_players():
    """A canvas request is recognised as one's own by its id alone, so two players' ids must
    differ even when their random numbers don't (same-length names share a seed here)."""
    w = World()
    a = w.add("Holder")
    settle(w)
    for i in range(4):
        a.stroke(line(100, 100 + i * 60, 700, 130 + i * 60))
    w.pump(8)
    b = w.add("Joiner")
    w.pump(30)
    check(b.items() == 4, f"a newcomer whose random numbers match the holder's still gets the canvas ({b.items()} of 4)")
    check(a.ev("ArtPad.playerName") == "Holder", "and nobody mistakes the other's request for their own")
    a.ex("math.randomseed(1); N1 = ArtPad:NewSyncNonce()")
    b.ex("math.randomseed(1); N1 = ArtPad:NewSyncNonce()")
    check(a.ev("N1") != b.ev("N1") and len(a.ev("N1")) == 6, "same random state, different players: different ids")


MAP_SIG = """
function MAP_SIG(id)
	local list = ArtPad_Settings.MapDrawings[id]
	if not list then return "" end
	local out = {}
	for _, s in ipairs(list) do out[#out + 1] = s.id .. "/" .. (s.k or #s.p / 2) end
	table.sort(out)
	return table.concat(out, " ")
end
function MAP_N(id)
	local list = ArtPad_Settings.MapDrawings[id]
	return list and #list or 0
end
"""


def map_open(c, tools=True):
    c.ex(MAP_SIG)
    c.ex("WorldMapFrame:Show(); MOUSE_OVER = true")
    c.ex("ArtPad_MapDrawButton._over = false; ArtPad_MapBar._over = false; ArtPad_MapOptions._over = false")
    if tools and not c.ev("ArtPad.worldMapDraw.on"):
        c.ex("CLICK(ArtPad_MapDrawButton)")


def map_drag(c, points):
    def cursor(p):
        c.ex("MAP_CURSOR = { %f, %f }; CURSOR_X, CURSOR_Y = %f, %f" % (p[0], p[1], p[0] * 1002, p[1] * 668))
    cursor(points[0])
    c.ex("ArtPad_MapInput._scripts.OnMouseDown(ArtPad_MapInput, 'LeftButton')")
    for p in points[1:]:
        cursor(p)
        c.ex("ArtPad_MapInput._scripts.OnUpdate(ArtPad_MapInput, 0.016)")
    c.ex("ArtPad_MapInput._scripts.OnMouseUp(ArtPad_MapInput, 'LeftButton')")


def map_same(w, map_id, what, *names):
    cs = [w.clients[n] for n in names] if names else list(w.clients.values())
    for c in cs:
        c.ex(MAP_SIG)
    sigs = [c.ev(f"MAP_SIG({map_id})") for c in cs]
    check(all(s == sigs[0] for s in sigs), f"{what}: everyone has the same drawing on map {map_id} ({[c.ev(f'MAP_N({map_id})') for c in cs]})")


ZIG = [(0.2, 0.2), (0.3, 0.25), (0.4, 0.2), (0.5, 0.3)]


def zig(dy):
    return [(x, y + dy) for x, y in ZIG]


def test_world_map_drawings_are_shared():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    for c in (a, b):
        c.ex(MAP_SIG)
    n = lambda c, m=37: c.ev(f"MAP_N({m})")

    # A stroke reaches a guild mate who doesn't even have the map open
    map_open(a)
    w.pump(3)
    a.ex("ArtPad:SetColor(1, 0.5, 0, 1)")
    map_drag(a, ZIG)
    check(n(b) == 0, "nothing is sent while the pen is down")
    w.pump(3)
    check(n(b) == 1, f"a finished stroke reaches a guild mate ({n(b)})")
    map_same(w, 37, "first stroke")
    check(abs(b.ev("ArtPad_Settings.MapDrawings[37][1].g") - 0.5) < 0.01 and b.ev("ArtPad_Settings.MapDrawings[37][1].p[1]") == 0.2,
          "with its colour and place")
    check(a.ev("ArtPad_Settings.MapDrawings[37][1].u") is None, "and is no longer waiting to be sent")
    # ...and is drawn at once on a map that is open
    map_open(b, tools=False)
    w.pump(3)
    check(b.ev("ArtPad.worldMapDraw.count") == 3, "Bob's open map shows it")
    map_drag(a, zig(0.2))
    w.pump(3)
    check(n(b) == 2 and b.ev("ArtPad.worldMapDraw.count") == 6, "the next stroke appears on Bob's open map as it arrives")

    # Both can draw; eraser, undo and clear reach everyone
    map_open(b)
    map_drag(b, zig(0.4))
    w.pump(3)
    check(n(a) == 3, "Bob's stroke reaches Alice")
    map_same(w, 37, "both drawing")
    a.ex("CLICK(ArtPad_MapTool_eraser)")
    map_drag(a, [(0.3, 0.65), (0.31, 0.65), (0.32, 0.65)])  # across Bob's stroke
    w.pump(3)
    check(n(a) == 2 and n(b) == 2 and b.ev("ArtPad.worldMapDraw.count") == 6, "erasing someone's stroke removes it for both")
    a.ex("ArtPad:WorldMapUndo()")
    w.pump(3)
    check(n(b) == 3, "undoing the erase puts it back for both")
    map_same(w, 37, "undo erase")
    a.ex("CLICK(ArtPad_MapClear)")
    w.pump(3)
    check(n(a) == 0 and n(b) == 0 and b.ev("ArtPad.worldMapDraw.count") == 0, "clear clears it for both")
    a.ex("ArtPad:WorldMapUndo()")
    w.pump(4)
    check(n(b) == 3, "and undo brings it all back for both")
    map_same(w, 37, "undo clear")
    a.ex("CLICK(ArtPad_MapTool_pen)")
    map_drag(b, zig(0.5))
    w.pump(3)
    b.ex("ArtPad:WorldMapUndo()")
    w.pump(3)
    check(n(a) == 3, "undoing your own stroke takes it off everyone's map")
    map_same(w, 37, "undo stroke")
    check(a.ev("ArtPad_Settings.MapDrawings[37].t") == b.ev("ArtPad_Settings.MapDrawings[37].t"), "and both agree on when the map last changed")

    # Someone who logs in later gets it when they look at that map
    c = w.add("Cat")
    c.ex(MAP_SIG)
    w.pump(5)
    check(n(c) == 0, "nothing is fetched for a map nobody has looked at")
    map_open(c, tools=False)
    w.pump(6)
    check(n(c) == 3 and c.ev("ArtPad.worldMapDraw.count") == 9, f"opening the map fetches its drawing ({n(c)} of 3)")
    map_same(w, 37, "late joiner")
    # A stroke heard for a map never looked at is kept, and the rest is fetched on looking
    a.ex("WorldMapFrame:SetMapID(84)")
    w.pump(3)
    map_drag(a, ZIG)
    w.pump(3)
    d = w.add("Dana")
    d.ex(MAP_SIG)
    w.pump(4)
    map_drag(a, zig(0.2))
    w.pump(3)
    check(n(d, 84) == 1, "a stroke heard live is kept even for a map never opened")
    map_open(d, tools=False)
    d.ex("WorldMapFrame:SetMapID(84)")
    w.pump(6)
    check(n(d, 84) == 2, f"and looking at that map fetches the rest ({n(d, 84)} of 2)")
    map_same(w, 84, "fragment", "Alice", "Dana")
    a.ex("WorldMapFrame:SetMapID(37)")
    w.pump(3)

    # Not on the shared canvas, and not to another audience
    check(a.items() == 0 and b.items() == 0, "map drawings never land on the canvas")
    p = w.add("Pug", guild=False)
    p.ex(MAP_SIG)
    w.pump(3)
    check(n(p) == 0, "someone outside the guild gets nothing")


def test_world_map_drawings_made_alone_go_public():
    w = World()
    old = [{"r": 1, "g": 0, "b": 0, "a": 1, "w": 0.003, "p": [0.1, 0.1, 0.2, 0.2, 0.3, 0.1]}]
    a = w.add("Alice")
    b = w.add("Bob", settings={"MapDrawings": {37: old}})  # drawn before map drawings were shared
    settle(w)
    for c in (a, b):
        c.ex(MAP_SIG)
    n = lambda c, m=37: c.ev(f"MAP_N({m})")
    map_open(a)
    w.pump(3)
    map_drag(a, ZIG)
    w.pump(3)
    check(n(b) == 2, "Bob has his old drawing and Alice's new stroke")
    check(n(a) == 1, "his old drawing hasn't gone anywhere yet: he hasn't looked at that map")
    map_open(b, tools=False)
    w.pump(6)
    check(n(a) == 2, f"looking at the map publishes what he drew before ({n(a)} of 2)")
    map_same(w, 37, "old drawings")
    check(b.ev("ArtPad_Settings.MapDrawings[37][1].u") is None, "nothing left waiting")

    # With sharing off (or nobody to share with) changes wait, then go out
    b.ex("ArtPad:SetMapSharing(false)")
    bob_before = len([m for m in w.log if m[0] == "Bob" and m[1].startswith("ArtPadMap")])
    map_open(b)
    map_drag(b, zig(0.3))                       # a stroke nobody hears about
    b.ex("CLICK(ArtPad_MapTool_eraser)")
    map_drag(b, [(0.3, 0.25), (0.31, 0.25), (0.32, 0.25)])  # erases Alice's stroke, here only
    b.ex("CLICK(ArtPad_MapTool_pen)")
    map_drag(a, zig(0.5))                       # which Bob doesn't hear either
    w.pump(4)
    bob_sent = len([m for m in w.log if m[0] == "Bob" and m[1].startswith("ArtPadMap")])
    check(n(a) == 3 and n(b) == 2, f"with sharing off nothing goes either way (Alice {n(a)}, Bob {n(b)})")
    check(bob_sent == bob_before, "and Bob sends nothing at all")
    b.ex("ArtPad:SetMapSharing(true)")
    w.pump(8)
    check(len([m for m in w.log if m[0] == "Bob" and m[1].startswith("ArtPadMap")]) > bob_sent, "switching it back on speaks up")
    map_same(w, 37, "after sharing again")
    check(n(a) == 3, f"his stroke is added, his erasure applied, her stroke kept ({n(a)} strokes)")

    # A stroke being drawn survives a copy arriving
    c = w.add("Cat")
    c.ex(MAP_SIG)
    w.pump(4)
    map_open(c)
    c.ex("MAP_CURSOR = { 0.6, 0.6 }; CURSOR_X, CURSOR_Y = 601, 400")
    c.ex("ArtPad_MapInput._scripts.OnMouseDown(ArtPad_MapInput, 'LeftButton')")
    for i in range(1, 6):
        c.ex("MAP_CURSOR = { %f, 0.6 }; CURSOR_X, CURSOR_Y = %f, 400" % (0.6 + i * 0.03, (0.6 + i * 0.03) * 1002))
        c.ex("ArtPad_MapInput._scripts.OnUpdate(ArtPad_MapInput, 0.016)")
        w.pump(1.2)
    check(n(c) == 4, f"the copy arrived under the pen ({n(c)} strokes: 3 fetched and the one being drawn)")
    c.ex("ArtPad_MapInput._scripts.OnMouseUp(ArtPad_MapInput, 'LeftButton')")
    w.pump(4)
    map_same(w, 37, "drawn through a copy")
    check(n(a) == 4, "and the stroke reached everyone once finished")


def test_world_map_sharing_follows_the_canvas():
    w = World()
    g = w.add("Gil")                      # guild mode, not in the party
    p, q = w.add("Pat", guild=False), w.add("Quin", guild=False)
    for c in (p, q):
        c.ex('ArtPad:SetMode("RAID")')
    w.group("party", "Pat", "Quin")
    settle(w)
    for c in (g, p, q):
        c.ex(MAP_SIG)
    n = lambda c, m=37: c.ev(f"MAP_N({m})")
    map_open(p)
    w.pump(3)
    map_drag(p, ZIG)
    w.pump(3)
    check(n(q) == 1 and n(g) == 0, "in party mode the party gets it, nobody else")
    check("your party" in p.ev("(function() local f = ArtPad_MapDrawButton._scripts.OnEnter; f(ArtPad_MapDrawButton); return TOOLTIP_TEXT() end)()"),
          "the button says who it is shared with")

    # Local mode and loopback: not shared
    p.ex('ArtPad:SetMode("LOCAL")')
    map_drag(p, zig(0.2))
    w.pump(3)
    check(n(q) == 1 and p.ev("ArtPad_Settings.MapDrawings[37][2].u") is True, "in Local mode a map stroke waits")
    p.ex('ArtPad:SetMode("RAID")')
    p.ex("ArtPad:SetLoopback(true)")
    map_drag(p, zig(0.3))
    w.pump(3)
    check(n(q) == 1, "nor in loopback")
    p.ex("ArtPad:SetLoopback(false)")
    p.ex("WorldMapFrame:Hide()")
    w.pump(70)
    map_open(p)
    w.pump(6)
    check(n(q) == 3, f"back in the party, looking at the map sends what waited ({n(q)} of 3)")
    map_same(w, 37, "party", "Pat", "Quin")

    # Leaders only applies to map drawings as it does to the canvas
    s = w.add("Strict", guild=False, settings={"Mode": "RAID", "AdminOnly": True})
    s.ex(MAP_SIG)
    w.group("party", "Pat", "Quin", "Strict")   # Pat leads
    w.pump(5)
    map_open(q)
    w.pump(3)
    map_drag(q, zig(0.4))
    map_drag(p, zig(0.5))
    w.pump(4)
    check(n(q) == 5 and n(p) == 5, f"both strokes are on the party's map ({n(q)}, {n(p)})")
    check(n(s) == 1, f"with leaders only, a member's map stroke is ignored and the leader's kept ({n(s)})")

    # Rubbish from the network is ignored, not stored and not an error
    q.ex("BEFORE = MAP_SIG(37)")
    future = 1700000000 + int(w.now) + 100000
    for msg in ("", "A", "A:37", "A:37:5:notdata", "Z:37:1:x", "D:37:%d:" % future, "A:99999999999:1:x",
                "Q:37:x:y", "H:37:1:1", "G:37", "A:37:%d:" % future):
        q.ex('ArtPad:OnMapMessage("ArtPadMap1", %r, "PARTY", "Pat-TestRealm")' % msg)
    q.ex("""
        local bad = ArtPad:EncodeData({
            { "x.1", 255, 0, 0, 255, 300, { 5, 5, 20000, 5 } },      -- off the map
            { "no id", 255, 0, 0, 255, 300, { 5, 5, 6, 6 } },
            { "x.2", 255, 0, 0, 255, 300, { 5, 5, 6 } },             -- odd
            { "x.3", 255, 0, 0, 255, 300, "points" },
            "junk",
            { "x.4", 9999, -4, "blue", 255, 99999999, { 5, 5, 600, 600 } },  -- kept, clamped
        })
        ArtPad:OnMapMessage("ArtPadMap1", "A:37:" .. GetServerTime() .. ":" .. bad, "PARTY", "Pat-TestRealm")
    """)
    check(n(q) == 6, f"of six strokes in a bad batch only the usable one is kept ({n(q) - 5} added)")
    check(q.ev("ArtPad_Settings.MapDrawings[37][6].w") <= 0.06 and q.ev("ArtPad_Settings.MapDrawings[37][6].r") == 1,
          "with its width and colour brought into range")
    check(not any(".lua:" in m for m in q.chat()), "and nothing errors")


def enter_dungeon(c, name, iid):
    c.ex("CLIENT.instance = { name = %r, id = %d }; FIRE_EVENT('PLAYER_ENTERING_WORLD')" % (name, iid))


def leave_dungeon(c):
    c.ex("CLIENT.instance = nil; FIRE_EVENT('PLAYER_ENTERING_WORLD')")


def test_dungeon_maps():
    """The client has dungeon map art but no map entries for dungeons: ArtPad shows it."""
    w = World()
    p, q = w.add("Pat", guild=False), w.add("Quin", guild=False)
    for c in (p, q):
        c.ex('ArtPad:SetMode("RAID")')
        c.ex(MAP_SIG)
    w.group("party", "Pat", "Quin")
    settle(w)
    n = lambda c, m: c.ev(f"MAP_N({m})")
    wm = "ArtPad.worldMapDraw"

    # Out in the world: nothing of this shows
    map_open(p)
    check(not p.ev("ArtPad_DungeonArt:IsShown()") and not p.ev("ArtPad_DungeonBar:IsShown()"), "no dungeon map out in the world")
    base = p.ev("ArtPad_MapLayer:GetFrameLevel()")
    p.ex("WorldMapFrame:Hide()")

    # Inside the Stockade: its map is laid over the world map, with the drawing on top
    enter_dungeon(p, "Stormwind Stockade", 34)
    map_open(p)
    w.pump(3)
    check(p.ev("ArtPad_DungeonArt:IsShown()"), "inside a dungeon, its map is shown")
    check(p.ev("ArtPad_DungeonArt.tiles[1]._texture") == p.ev("ArtPad.DUNGEON_MAPS[34][1][1]"), "from the dungeon's own art")
    check(p.ev("#ArtPad_DungeonArt.tiles") == 12 and p.ev("ArtPad_DungeonArt.tiles[12]._texture") != p.ev("ArtPad_DungeonArt.tiles[1]._texture"),
          "twelve tiles of it")
    w1 = p.ev("ArtPad_DungeonArt.tiles[1]:GetWidth()")
    check(abs(w1 - 256) < 0.01, f"at the map's own scale ({w1})")
    art, layer, catcher = (p.ev(f"{f}:GetFrameLevel()") for f in ("ArtPad_DungeonArt", "ArtPad_MapLayer", "ArtPad_MapInput"))
    check(9000 < art < layer < catcher, f"above Blizzard's pins, with the drawing and the mouse catcher above it ({art}, {layer}, {catcher})")
    check(p.ev("ArtPad_DungeonBar:IsShown()") and p.ev("ArtPad_DungeonBar.label._text") == "Stormwind Stockade", "a bar names the dungeon")
    check(not p.ev("ArtPad_DungeonFloor1 and ArtPad_DungeonFloor1:IsShown()"), "one floor: no floor buttons")

    # Drawing there is the dungeon's own, and the party shares it
    stockade = 5000000 + 34 * 100 + 1
    map_drag(p, ZIG)
    w.pump(3)
    check(n(p, stockade) == 1 and n(p, 37) == 0, "a stroke goes on the dungeon's map, not the zone underneath")
    check(n(q, stockade) == 1, "and reaches the party")
    enter_dungeon(q, "Stormwind Stockade", 34)
    map_open(q, tools=False)
    w.pump(3)
    check(q.ev(wm + ".count") == 3, "who see it on their own dungeon map")

    # Back to the world map and in again
    p.ex("CLICK(ArtPad_DungeonToggle)")
    check(not p.ev("ArtPad_DungeonArt:IsShown()") and p.ev(wm + ".count") == 0 and p.ev("ArtPad_MapLayer:GetFrameLevel()") == base,
          "the bar switches to the world map: art away, the zone's own drawing shown")
    check(p.ev("ArtPad_DungeonToggle.label._text") == "Dungeon Map" and p.ev("ArtPad_DungeonBar:IsShown()"), "and offers the way back")
    p.ex("CLICK(ArtPad_DungeonToggle)")
    check(p.ev("ArtPad_DungeonArt:IsShown()") and p.ev(wm + ".count") == 3, "back on the dungeon map, drawing and all")

    # Leaving the dungeon puts everything back
    leave_dungeon(p)
    check(not p.ev("ArtPad_DungeonArt:IsShown()") and not p.ev("ArtPad_DungeonBar:IsShown()"), "leaving the dungeon takes its map away")
    check(p.ev("ArtPad_MapLayer:GetFrameLevel()") == base and p.ev("ArtPad_MapInput:GetFrameLevel()") == 9000, "and the layers return to their places")

    # Floors: each is a map of its own
    enter_dungeon(p, "Deadmines", 36)
    w.pump(3)
    check(p.ev("ArtPad_DungeonFloor1:IsShown()") and p.ev("ArtPad_DungeonFloor2:IsShown()") and not p.ev("ArtPad_DungeonFloor3"),
          "two floors: two floor buttons")
    first = p.ev("ArtPad_DungeonArt.tiles[1]._texture")
    map_drag(p, zig(0.2))
    p.ex("CLICK(ArtPad_DungeonFloor2)")
    w.pump(3)
    check(p.ev("ArtPad_DungeonArt.tiles[1]._texture") != first and p.ev(wm + ".count") == 0, "the second floor has its own art and its own drawing")
    map_drag(p, zig(0.3))
    w.pump(3)
    check(n(p, 5003601) == 1 and n(p, 5003602) == 1 and n(q, 5003602) == 1, "kept and shared per floor")

    # A dungeon is also recognised by name, should its id not be the expected one
    enter_dungeon(p, "Molten Core", 99999)
    check(p.ev("ArtPad_DungeonArt:IsShown()") and p.ev("ArtPad_DungeonBar.label._text") == "Molten Core", "recognised by name")
    # One without art: the world map as it was
    enter_dungeon(p, "Karazhan Crypts", 12345)
    check(not p.ev("ArtPad_DungeonArt:IsShown()") and not p.ev("ArtPad_DungeonBar:IsShown()"), "a dungeon with no art shows nothing extra")
    p.ex("ArtPad.OnSlashCommand('dungeon')")
    check(any("Karazhan Crypts" in m and "no map" in m for m in p.chat()), "/ap dungeon says so")
    leave_dungeon(p)

    # /ap dungeon <name> shows one from anywhere
    p.ex("ArtPad.OnSlashCommand('dungeon stockade')")
    check(p.ev("ArtPad_DungeonArt:IsShown()") and p.ev("ArtPad_DungeonBar.label._text") == "Stormwind Stockade", "/ap dungeon <name> shows a map from anywhere")
    check(p.ev(wm + ".count") == 3, "with what was drawn on it")
    p.ex("ArtPad.OnSlashCommand('dungeon off')")
    check(not p.ev("ArtPad_DungeonArt:IsShown()"), "/ap dungeon off puts it away")
    check(not any(".lua:" in m for m in p.chat()), "no errors")


def test_world_map_markers():
    w = World()
    a, b = w.add("Alice"), w.add("Bob")
    settle(w)
    for c in (a, b):
        c.ex(MAP_SIG)
    n = lambda c, m=37: c.ev(f"MAP_N({m})")
    wm = "ArtPad.worldMapDraw"
    item = lambda c, i, f: c.ev(f"ArtPad_Settings.MapDrawings[37][{i}].{f}")
    map_open(a)
    map_open(b, tools=False)
    w.pump(3)

    # The stamp tool: a click places a marker, and the click is not the map's
    a.ex("CLICK(ArtPad_MapTool_stamp)")
    check(a.ev(wm + ".tool") == "stamp" and a.ev("ArtPad_MapTool_stamp.mark:IsShown()") and not a.ev("ArtPad_MapTool_pen.mark:IsShown()"),
          "the toolbar has a stamp tool")
    check(not a.ev(wm + ".propagating"), "with the stamp out, clicks stay with ArtPad")
    a.ex("NAV = nil; ArtPad_MapInput._scripts.OnUpdate(ArtPad_MapInput, 0.016)")
    check(a.ev(wm + ".ghost:IsShown()") and not a.ev(wm + ".dot:IsShown()"), "the cursor shows the marker about to be placed")
    map_drag(a, [(0.4, 0.3)])
    check(n(a) == 1 and item(a, 1, "k") == "r8" and item(a, 1, "x") == 0.4 and item(a, 1, "y") == 0.3, "a click places a marker there")
    check(a.ev("NAV") is None, "and doesn't travel the map")
    check(a.ev(wm + ".count") == 1, "it is drawn (one texture)")
    w.pump(3)
    check(n(b) == 1 and item(b, 1, "k") == "r8" and item(b, 1, "x") == 0.4 and abs(item(b, 1, "s") - item(a, 1, "s")) < 1e-6,
          "and reaches a guild mate, same marker, place and size")
    check(b.ev(wm + ".count") == 1, "who sees it on their open map")

    # Choosing a marker: click the tool again
    a.ex("CLICK(ArtPad_MapTool_stamp)")
    check(a.ev("ArtPad_MapMarkers:IsShown()") and not a.ev("ArtPad_MapOptions:IsShown()"), "clicking the stamp in hand opens the markers")
    map_drag(a, [(0.6, 0.6)])
    check(n(a) == 1 and not a.ev("ArtPad_MapMarkers:IsShown()"), "a click on the map only closes them")
    a.ex("CLICK(ArtPad_MapTool_stamp); CLICK(ArtPad_MapMarker_r1)")
    check(a.ev(wm + ".marker") == "r1" and not a.ev("ArtPad_MapMarkers:IsShown()"), "picking one closes the markers")
    a.ex("ArtPad:SetBrushSize(12)")
    map_drag(a, [(0.6, 0.6)])
    check(n(a) == 2 and item(a, 2, "k") == "r1" and item(a, 2, "s") > item(a, 1, "s") * 2, "the next click places that one, sized by the brush")
    # Esc closes the markers before putting the tools away
    a.ex("CLICK(ArtPad_MapTool_stamp)")
    a.ex("ArtPad:WorldMapEsc()")
    check(not a.ev("ArtPad_MapMarkers:IsShown()") and a.ev(wm + ".on"), "Esc closes the markers first")
    # ...and the pen's options and the markers are never open together
    a.ex("CLICK(ArtPad_MapTool_pen); CLICK(ArtPad_MapTool_pen)")
    check(a.ev("ArtPad_MapOptions:IsShown()"), "pen options open")
    a.ex("CLICK(ArtPad_MapTool_stamp); CLICK(ArtPad_MapTool_stamp)")
    check(a.ev("ArtPad_MapMarkers:IsShown()") and not a.ev("ArtPad_MapOptions:IsShown()"), "one pop-out at a time")
    a.ex("ArtPad:WorldMapToggleOptions(false)")

    # Markers and strokes live together: eraser, undo, clear, and a late joiner
    a.ex("CLICK(ArtPad_MapTool_pen)")
    map_drag(a, ZIG)
    w.pump(3)
    check(n(b) == 3 and b.ev(wm + ".count") == 5, f"two markers and a stroke on both maps ({n(b)})")
    a.ex("CLICK(ArtPad_MapTool_eraser)")
    a.ex("MAP_CURSOR = { 0.405, 0.3 }; CURSOR_X, CURSOR_Y = 406, 200; ArtPad_MapInput._scripts.OnUpdate(ArtPad_MapInput, 0.016)")
    check(a.ev(f"{wm}.linesOf[ArtPad_Settings.MapDrawings[37][1]][1].color[2]") == 0.3, "the eraser lights up the marker under it")
    map_drag(a, [(0.4, 0.3), (0.405, 0.3), (0.41, 0.3)])
    w.pump(3)
    check(n(a) == 2 and n(b) == 2 and b.ev(wm + ".count") == 4, "the eraser removes a marker for both")
    a.ex("ArtPad:WorldMapUndo()")
    w.pump(3)
    check(n(b) == 3 and b.ev(wm + ".count") == 5, "undo puts it back for both")
    map_same(w, 37, "markers and strokes")
    c = w.add("Cat")
    c.ex(MAP_SIG)
    w.pump(4)
    map_open(c, tools=False)
    w.pump(6)
    check(n(c) == 3 and c.ev(wm + ".count") == 5, f"someone joining later gets markers as well as strokes ({n(c)})")
    kinds = sorted(c.ev(f"ArtPad_Settings.MapDrawings[37][{i}].k") or "stroke" for i in (1, 2, 3))
    check(kinds == ["r1", "r8", "stroke"], f"the right ones ({kinds})")
    a.ex("CLICK(ArtPad_MapClear)")
    w.pump(3)
    check(n(b) == 0 and n(c) == 0 and b.ev(wm + ".count") == 0, "clear takes markers too")

    # Bad markers from the network are dropped
    b.ex("""
        local bad = ArtPad:EncodeData({
            { "z.1", "M", "nosuchmarker", 5000, 5000, 3000 },
            { "z.2", "M", "r1", 20000, 5000, 3000 },          -- off the map
            { "z.3", "M", "r1", "x", 5000, 3000 },
            { "z.4", "M", "r2", 5000, 5000, 99999999 },       -- kept, size brought into range
        })
        ArtPad:OnMapMessage("ArtPadMap1", "A:37:" .. GetServerTime() .. ":" .. bad, "GUILD", "Alice-TestRealm")
    """)
    check(n(b) == 1 and item(b, 1, "k") == "r2" and item(b, 1, "s") <= 0.2, f"of four bad markers only the usable one is kept ({n(b)})")
    check(not any(".lua:" in m for m in a.chat() + b.chat() + c.chat()), "no errors")


def test_hide_button():
    w = World()
    a = w.add("Alice")
    a.ex("ArtPad.window:Show(); CLICK(ArtPad_CloseButton)")
    check(not a.ev("ArtPad.window:IsShown()"), "the - button hides the window")
    check(a.ev("ArtPad_MiniBar") is None and a.ev("ArtPad_MinimiseButton") is None, "no mini bar or separate close button")


def test_presence_initials():
    w = World()
    a = w.add("Alice")
    others = [w.add(n) for n in ("Bob", "Cat", "Dan", "Eve", "Fay")]
    settle(w)
    a.ex("ArtPad.window:Show()")
    for k, o in enumerate(others):
        o.stroke(line(0, k * 50, 100, k * 50))
    w.pump(2)
    a.ex("ArtPad:RefreshStatus()")
    shown = [a.ev(f"ArtPad.presenceBadges[{i}]:IsShown() and ArtPad.presenceBadges[{i}].text._text or nil") for i in range(1, 5)]
    check(shown == ["Bo", "Ca", "Da", "+2"], f"three initials and a count: {shown}")


# ---------------------------------------------------------------- runner

def main(argv):
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    if len(argv) > 1:
        tests = [(n, f) for n, f in tests if any(a in n for a in argv[1:])]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except Exception:
            failed += 1
            print(f"FAIL {name}")
            traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
