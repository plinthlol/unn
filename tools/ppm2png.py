#!/usr/bin/env python3
# Turns a unn headless screenshot (the control command `shot` writes a PPM) into a PNG, so
# screenshots can be committed, diffed and viewed without fiddling with hand-rolled bytes.
# usage: tools/ppm2png.py shot.ppm shot.png
import sys
from PIL import Image
Image.open(sys.argv[1]).save(sys.argv[2])
