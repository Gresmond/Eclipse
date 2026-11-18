# Eclipse — First Contact icon suite

The approved adjusted First Contact design: the original ivory moon is 5% smaller, the sun is a quarter of the way closer to the icon centre, and the moon is 15% closer to the sun's centre. The exact reference sun ripples and lunar bumps and the original palette are preserved; the darker moon studies are not used. This replaces the previous First Contact composition in the app.

## Assets

Only `source/`, `build.py` and this README are kept in git. Everything else below is written by `build.py` (see Rebuild) and ignored; the app's own copies live in `linux/icons`, `android/app/src/main/res` and `web/icon.svg`.

- `source/eclipse.svg`: editable master, with transparent corners around its circular red tile.
- `png/`: native vector renders at 16, 20, 22, 24, 32, 40, 48, 64, 96, 128, 256, 512, 1024 and 2048 pixels.
- `linux/icons/hicolor/`: scalable SVG and eleven PNG sizes, named `dev.nicholas.productivity_app` to match this app's Linux application ID and desktop entry.
- `android/res/`: the phone's launcher icon at five densities: the circle, and the sun and moon alone as an adaptive icon's top layer over the red in the app's `values/colors.xml`.
- `preview.png`: light and dark background checks and native small-size samples.
- `manifest.json` and `SHA256SUMS`: design provenance, validation results, and file checksums.

Palette: red `#C44430`, sun `#F8BD49`, moon `#FFF6DE`. All raster exports are RGBA PNGs. The edge detail naturally becomes subtle at small sizes; it is not replaced by new artwork.

## Rebuild

Requires Python 3, Pillow, and `rsvg-convert` (librsvg).

```sh
python3 build.py
```

Inside the app repository, regenerate and copy the icons into the app with:

```sh
ECLIPSE_ICON_PYTHON=python3 bash tool/make_icons.sh
```

That updates `linux/icons/hicolor`, the PNGs in `android/app/src/main/res` and the web version's `web/icon.svg`. The Linux launcher and tray lookup and the Android launcher already reference those locations. Rebuild the app to include the new assets. This does not install a new application binary into the operating system.

The builder verifies every PNG's dimensions and transparency, checks the palette, and verifies copied project assets and the ZIP archive.

## Platform references

- [freedesktop Icon Theme Specification](https://specifications.freedesktop.org/icon-theme/)
