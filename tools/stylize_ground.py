#!/usr/bin/env python3
"""Orthofoto in einen gemalten Kartenstil umrechnen (ground.jpg).

Die Parameter sind Geschmackssache: weniger Sättigung, mehr Helligkeit,
wenige Farben, leichte Weichzeichnung. Ziel ist ein ruhiger, illustrativer
Untergrund, auf dem Gebäude, Straßen und Bäume gut lesbar bleiben.

  python3 tools/stylize_ground.py                 # ortho.jpg -> ground.jpg
  python3 tools/stylize_ground.py --keep-detail   # weniger stark abstrahiert
"""
import argparse
import os

from PIL import Image, ImageEnhance, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENE = os.path.join(ROOT, "web", "data", "scene")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(SCENE, "ortho.jpg"))
    ap.add_argument("--dst", default=os.path.join(SCENE, "ground.jpg"))
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--colors", type=int, default=44)
    ap.add_argument("--brightness", type=float, default=1.34)
    ap.add_argument("--saturation", type=float, default=0.88)
    ap.add_argument("--contrast", type=float, default=1.07)
    ap.add_argument("--median", type=int, default=9)
    ap.add_argument("--blur", type=float, default=0.35)
    ap.add_argument("--quality", type=int, default=90)
    ap.add_argument("--keep-detail", action="store_true")
    args = ap.parse_args()

    im = Image.open(args.src).convert("RGB")
    if im.width > args.width:
        im = im.resize((args.width, int(round(im.height * args.width / im.width))), Image.LANCZOS)

    if not args.keep_detail:
        im = im.filter(ImageFilter.MedianFilter(args.median))
        im = ImageEnhance.Color(im).enhance(args.saturation)
        im = ImageEnhance.Brightness(im).enhance(args.brightness)
        im = ImageEnhance.Contrast(im).enhance(args.contrast)
        im = im.quantize(colors=args.colors, method=Image.MEDIANCUT).convert("RGB")
        im = im.filter(ImageFilter.GaussianBlur(args.blur))

    im.save(args.dst, quality=args.quality, optimize=True, progressive=True)
    print("%s  %s  %.0f kB" % (args.dst, im.size, os.path.getsize(args.dst) / 1024))


if __name__ == "__main__":
    main()
