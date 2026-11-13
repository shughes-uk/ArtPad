"""Make brush.tga, the one texture every world-map stroke piece is drawn with (WorldMapDraw.lua, "The brush").

usage: python tests/make_brush_tga.py [out.tga]      (needs Pillow and numpy)

256 x 256, 32-bit, white everywhere (so filtering never pulls a dark fringe in); only the alpha varies:

  (0, 0) 128 x 128    the soft edge: clear in its first row and first column, solid elsewhere. A ribbon
                      piece samples it by distance from one side along u and from the other along v, which
                      gives an edge one texel (one screen pixel) soft on both sides at any width.
  (128, 0) 128 x 128  a round disc, for ends and sharp joins
  (0, 128) 64 x 64    the same disc, smaller: the size nearest the one on screen is used, so that it
  (64, 128) 32 x 32   is never shrunk much (the game keeps no smaller copies of a TGA)
  (96, 128) 16 x 16
  (112, 128) 8 x 8

Each disc has a radius of half its cell less two texels, with an edge one texel soft.
"""
import os
import sys

import numpy as np
from PIL import Image

SIZE = 256
a = np.zeros((SIZE, SIZE), np.float32)

# the soft-edge corner
a[0:128, 0:128] = 1
a[0, 0:128] = 0
a[0:128, 0] = 0

# discs
for cell, left, top in ((128, 128, 0), (64, 0, 128), (32, 64, 128), (16, 96, 128), (8, 112, 128)):
    radius = cell / 2 - 2
    ys, xs = np.mgrid[0:cell, 0:cell]
    d = np.sqrt((xs + 0.5 - cell / 2) ** 2 + (ys + 0.5 - cell / 2) ** 2)
    a[top:top + cell, left:left + cell] = np.clip(radius + 0.5 - d, 0, 1)

rgba = np.full((SIZE, SIZE, 4), 255, np.uint8)
rgba[..., 3] = (a * 255 + 0.5).astype(np.uint8)
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "brush.tga")
Image.fromarray(rgba, "RGBA").save(out)
print("wrote", os.path.normpath(out))
