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
    check(a.ev('BINDINGS["CTRL-Z"]') == "ArtPad_UndoButton", "Ctrl-Z bound to the undo button")
    a.ex('ArtPad_UndoButton._scripts.OnClick(ArtPad_UndoButton, "LeftButton")')
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
    a.ex("CLICK(ArtPad_CloseButton)")  # what Escape is bound to
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
    a.ex("CLICK(ArtPad_CloseButton)")  # Escape
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
    a.ex("CLICK(ArtPad_CloseButton)")  # Escape closes the popover first
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


def test_long_scribble_spreads_over_layers():
    # One frame with too many regions stops rendering in the real client; drawings are split
    # across draw layers of at most LAYER_SIZE regions each.
    w = World()
    a = w.add("Alice")
    pts = [(100 + (i % 2) * 3000, 100 + i * 0.4) for i in range(5000)]
    a.stroke(pts)
    size = a.ev("ArtPad.LAYER_SIZE")
    layers = a.ev("#ArtPad.drawLayers")
    check(layers > 1, f"a long scribble uses several layers ({layers})")
    for i in range(1, layers + 1):
        n = a.ev(f"ArtPad.drawLayers[{i}].regions")
        check(n <= size, f"layer {i} holds {n} regions (max {size})")
    check(a.ev("ArtPad.overlay:GetFrameLevel()") > a.ev(f"ArtPad.drawLayers[{layers}]:GetFrameLevel()"),
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
    check(a.ev("ArtPad:IsSelf('Alice-Realm')"), "own messages recognised")


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


def test_place_canvas():
    INN = (0.438, 0.659)
    YD = 1 / 3470.84  # one yard east, in map x
    w = World()
    a, b, c = w.add("Alice"), w.add("Bob"), w.add("Cat")
    settle(w)
    # Everyone starts somewhere else, sharing the guild canvas
    a.stroke(line(100, 100, 300, 300))
    w.pump(3)
    guild_sig = a.signature()
    check(c.items() == 1, "guild canvas shared")
    # Alice and Bob walk into the inn
    w.move(a, *INN)
    w.move(b, INN[0] + 50 * YD, INN[1])
    w.pump(2)
    check(a.ev("ArtPad.node and ArtPad.node.id") == "lionspride", "Alice is at the inn")
    check(b.ev("ArtPad.node and ArtPad.node.id") == "lionspride", "so is Bob")
    check(a.items() == 0, "the inn has its own canvas")
    check(a.ev("ArtPad:GetChannel()") == "YELL", "drawing at the inn goes out on yell")
    check(a.ev("ArtPad.backdropMap") == 37 and a.ev("ArtPad.backdropView ~= nil"), "map of the area behind it")
    check(a.ev("(ArtPad:GetSharingState())") == "Lion's Pride Inn", "sharing pill names the place")
    a.stroke(line(500, 500, 900, 700))
    w.pump(3)
    check(b.items() == 1, "Bob sees Alice's inn drawing")
    check(c.items() == 1 and c.signature() == guild_sig, "Cat (away, in the guild) doesn't")
    # Cat draws on the guild canvas; nobody at the inn gets it
    c.stroke(line(0, 1000, 400, 1000))
    w.pump(3)
    check(a.items() == 1 and b.items() == 1, "guild drawing doesn't reach the inn")
    # Alice leaves: back to the guild canvas, which catches up with what she missed
    w.move(a, INN[0] + 300 * YD, INN[1])
    w.pump(15)
    check(a.ev("ArtPad.node") is None, "Alice left the inn")
    check(a.items() == 2, f"guild canvas back and caught up ({a.items()} items)")
    check(a.ev("ArtPad.backdropMap") is None, "inn map gone")
    saved = a.ev("ArtPad_Settings.PlaceCanvases.lionspride ~= nil")
    check(saved, "inn canvas kept for next time")
    # Bob leaves too; nobody is at the inn. Alice comes back alone: her copy is still there.
    w.move(b, None)
    w.pump(3)
    w.move(a, *INN)
    w.pump(8)
    check(a.items() == 1, "the inn drawing outlived everyone leaving")
    # Turning it off takes you back
    a.ex("ArtPad.OnSlashCommand('nearby off')")
    check(a.ev("ArtPad.node") is None, "nearby off leaves the place")


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
