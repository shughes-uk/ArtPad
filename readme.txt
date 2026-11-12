ArtPad - a shared canvas for your guild or group.

Usage:
  /ap            open or close ArtPad (also: minimap button, addon compartment, key binding)
  Left drag      draw (or erase with the eraser tool; size follows the brush)
  Right drag     pan (middle drag works too)       Mouse wheel   zoom
  Ctrl-Z         undo your last stroke, text or marker
  [ ]            brush size (while the mouse is over the canvas)
  /ap options    settings (also Options > AddOns > ArtPad)
  /ap guild      share with your guild (default)
  /ap raid       share with your party / raid / instance group
  /ap local      share with whoever is at the same place (for now: the Lion's Pride Inn)
  /ap resync     re-download the canvas from others
  /ap versions   list ArtPad versions in your guild and group (different versions can't sync)
  /ap loopback   test sync on your own: your drawing round-trips through the server
  /ap resetui    put the window back to its default size and spot

Drawing on the world map: click the round pencil button on the world map, or hold Alt and
drag on the map. Each map has one drawing, shared with the same people as the canvas (your
guild, or your party / raid) and kept between sessions. Options has a switch to stop sharing.

Drag the title bar to move the window and the bottom-right corner to resize it. The pill in
the title bar shows who you're sharing with; click it to switch or to hide your name.

People who log in, join your group or switch mode receive the existing canvas. If copies
differ (say, two visits to the inn on different days), the most recently changed one wins -
including a clear, so cleared drawings don't come back from someone's old copy.

Local mode: share with whoever is at the same place instead of your guild or group. For now
the one place is the Lion's Pride Inn in Goldshire: there you get the inn's canvas, shared with
everyone there in Local mode, with the map of the area behind it. Elsewhere a local canvas
isn't shared. The inn's drawing is kept, so it's still there next visit.

Development:
  Link the repo folder into the game (no admin needed), then /reload after editing:
    New-Item -ItemType Junction -Path "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\ArtPad" -Target <repo>

  Tests simulate several players exchanging addon messages:
    pip install lupa
    python tests/run_tests.py

  Releases: push a tag; .github/workflows/release.yml packages it with the BigWigs packager.
