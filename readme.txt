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
  /ap resync     re-download the canvas from others
  /ap loopback   test sync on your own: your drawing round-trips through the server
  /ap resetui    put the window back to its default size and spot

Drag the title bar to move the window and the bottom-right corner to resize it. The pill in
the title bar shows who you're sharing with; click it to switch or to hide your name.

People who log in, join your group or switch mode receive the existing canvas from
whoever has the most complete copy.

Development:
  Link the repo folder into the game (no admin needed), then /reload after editing:
    New-Item -ItemType Junction -Path "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\ArtPad" -Target <repo>

  Tests simulate several players exchanging addon messages:
    pip install lupa
    python tests/run_tests.py

  Releases: push a tag; .github/workflows/release.yml packages it with the BigWigs packager.
