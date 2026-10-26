# Eclipse - app icons

Eclipse's app icons on every platform: the circle on Linux and Windows, and the same mark on a squircle for macOS. The circle is a variant of the **clean subtle-rugged Stillness mark**, using ink `#211B2B` on off-white `#F8F7F4`.

The entire visible outside is a circle. Everything beyond it is transparent. The ink mark retains its fragile brush flecks and subtle lunar edge, without interior dots.

## Tela-circle research and adaptation

[Tela Circle](https://github.com/vinceliuice/Tela-circle-icon-theme) describes itself as a flat, colourful theme. Inspection of the locally installed theme's Telegram, Firefox, Terminal, Calculator, and Calendar app SVGs showed flat circular backgrounds with a common radius of 27 on a 64 px canvas (54 px disc, 5 px margins). Some icons use small detail shadows, but a shadow is not required for the circular shape or spacing.

This version adopts that circular silhouette and grid, while retaining Eclipse's current ink/off-white colours and original mark. It is an original Eclipse adaptation, not an official Tela-circle theme asset. No artwork from other applications is included.

## Files

- `icons/hicolor/scalable/apps/dev.nicholas.productivity_app.svg`: the finished circular vector icon.
- `icons/hicolor/NxN/apps/dev.nicholas.productivity_app.png`: PNGs at 16, 24, 32, 48, 64, 128, 256, and 512 px.
- `macos/AppIcon.appiconset/`: squircle PNGs at 16-1024 px on Apple's grid (824 px tile at 100,100 on a 1024 px canvas, radius 185), mark at 70% of the tile (74% at 64 px and below).
- `windows/app_icon.ico`: the circle at 16, 20, 24, 32, 40, 48, 64, 128 and 256 px.
- `eclipse-linux-circle-512.png`: convenient large PNG.
- `preview/light-and-dark.png`: large light/dark previews plus actual-size small icons.
- `source/`: approved full-detail and simplified marks, plus a portable rebuild script.

Full-detail marks occupy 74% of the disc's diameter. Small exports at 64 px and below use the approved simplified master at 78%, with explicit native-pixel positioning at 16, 24, and 32 px. Optical centring shifts the ink slightly right and upwards. There is no surrounding rounded-square tile or drop shadow.

## Project integration and rebuild

The repository's Linux, macOS and Windows app icons all come from this pack.

To rebuild and copy them into the project:

```sh
python3 tool/generate_linux_circle_icon.py --update-project
```

`bash tool/make_icons.sh` runs the same thing.

To rebuild an extracted standalone pack:

```sh
python3 source/build.py
```

Requires Python 3, Pillow, and `rsvg-convert`. The generator updates project files only when requested; it does not install into the user's live icon theme or operating system.
