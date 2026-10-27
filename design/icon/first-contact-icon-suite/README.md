# Eclipse — First Contact icon suite

The approved adjusted First Contact design: the original ivory moon is 5% smaller, the sun is a quarter of the way closer to the icon centre, and the moon is 15% closer to the sun's centre. The exact reference sun ripples and lunar bumps and the original palette are preserved; the darker moon studies are not used. This replaces the previous First Contact composition in the app.

## Assets

Only `source/`, `build.py` and this README are kept in git. Everything else below is written by `build.py` (see Rebuild) and ignored; the app's own copies live in `linux/icons`, `macos/Runner/Assets.xcassets` and `windows/runner/resources`.

- `source/eclipse.svg`: editable master, with transparent corners around its circular red tile.
- `png/`: native vector renders at 16, 20, 22, 24, 32, 40, 48, 64, 96, 128, 256, 512, 1024 and 2048 pixels.
- `linux/icons/hicolor/`: scalable SVG and eleven PNG sizes, named `dev.nicholas.productivity_app` to match this app's Linux application ID and desktop entry.
- `windows/app_icon.ico`: nine RGBA representations at 16, 20, 24, 32, 40, 48, 64, 128 and 256 pixels; individual PNGs are also included.
- `macos/Eclipse.icns`: eleven standard and Retina representations, up to 1024 pixels.
- `macos/AppIcon.appiconset/`: Xcode catalog with all ten macOS 1x/2x slots and `Contents.json`.
- `macos/Eclipse.iconset/`: standard iconset filenames for rebuilding with Apple's `iconutil`.
- `macos/eclipse.svg`: the same approved circle on a 1024-pixel canvas, with an 824-pixel circle and 100-pixel transparent margin. Its internal composition is unchanged.
- `preview.png`: light and dark background checks, macOS sizing, and native small-size samples.
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

That updates `linux/icons/hicolor`, `macos/Runner/Assets.xcassets/AppIcon.appiconset`, and `windows/runner/resources/app_icon.ico`. Linux launcher/tray lookup, Windows executable/tray/installer resources, and the macOS app icon already reference those locations. Rebuild the app on each OS to include the new assets. This does not install a new application binary into the operating system.

The builder verifies every PNG's dimensions and transparency, decodes every ICO/ICNS representation and compares it to its render, checks Xcode slots and palette, and verifies copied project assets and the ZIP archive. Native macOS and Windows application builds must run on their respective platforms; container-format checks on Linux do not replace those builds.

## Platform references

- [freedesktop Icon Theme Specification](https://specifications.freedesktop.org/icon-theme/)
- [Microsoft: Construct your Windows app's icon](https://learn.microsoft.com/en-us/windows/apps/design/style/iconography/app-icon-construction)
- [Apple: Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Apple: Icon Set Type](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/IconSetType.html)

The existing legacy icon suites and exploration files are retained separately.
