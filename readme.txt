ArtPad - a shared canvas for your guild or group.

Usage:
  /ap            toggle the canvas (also: minimap button, addon compartment, key binding)
  Left drag      draw            Right drag    erase (size follows the brush)
  Drag the bar on top of the canvas to move it (right-click it to fit)
  Mouse wheel    zoom
  Ctrl-Z         undo your last stroke or text
  /ap options    settings (also Options > AddOns > ArtPad, or middle-click the minimap button)
  /ap guild      share with your guild (default)
  /ap raid       share with your party / raid / instance group
  /ap resync     re-download the canvas from others
  /ap loopback   test sync on your own: your drawing round-trips through the server
  /ap resetui    put the toolbar and dock back (drag their grips to move them)

People who log in, join your group or switch mode receive the existing canvas from
whoever has the most complete copy.

The dock on the left has the tools (pen, line, arrow, box, circle, text), raid marker and
role stamps, and colours. Map (toolbar) shows the map of where you are under the canvas
for everyone. Fit scales the canvas to your screen.

The bar under the toolbar shows who you're sharing with (click it to switch), who is
drawing right now, and progress while a canvas is loading.

Development:
  Link the repo folder into the game (no admin needed), then /reload after editing:
    New-Item -ItemType Junction -Path "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\ArtPad" -Target <repo>

  Tests simulate several players exchanging addon messages:
    pip install lupa
    python tests/run_tests.py

  Releases: push a tag; .github/workflows/release.yml packages it with the BigWigs packager.
