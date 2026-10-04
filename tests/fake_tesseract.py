#!/usr/bin/env python3
"""A stand-in for the tesseract command: lists languages, or 'reads' an image into fixed text."""
import os
import sys

args = sys.argv[1:]
if "--list-langs" in args:
    print("List of available languages in \"/usr/share/tessdata/\" (3):\neng\nkor\nosd")
    sys.exit(0)
# tesseract <image> stdout -l <languages>
image, languages = args[0], args[args.index("-l") + 1]
if not os.path.exists(image):
    sys.exit(1)
print("Scanned page about occlusion of objects behind furniture (%s)" % languages)
