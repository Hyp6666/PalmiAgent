# Palmi Icon Artwork

This folder keeps the Palmi app icon artwork deterministic.

## Source of truth

- `PalmiIconRecipe.json` contains all geometry, colors, opacity, and line weights.
- `PalmiIconRenderer.swift` renders the recipe with SwiftUI.
- Generated files go to `artifacts/palmi-icon/v1` by default.

## Render

```bash
swift -module-cache-path .build/swift-module-cache \
  Design/PalmiIcon/PalmiIconRenderer.swift \
  --recipe Design/PalmiIcon/PalmiIconRecipe.json \
  --out artifacts/palmi-icon/v1
```

The renderer writes:

- `png-layers/palmi-icon-preview.png`: full preview.
- `png-layers/00-background.png`: square background preview layer.
- `png-layers/10-face.png`: face layer.
- `png-layers/20-face-rim.png`: optional baked rim.
- `png-layers/30-highlight.png`: optional baked highlight.
- `png-layers/40-features.png`: eyes and mouth.
- `svg-layers/*.svg`: vector-friendly layers for Icon Composer.

## Icon Composer import

Use the SVG layers first:

1. Create a new Icon Composer document.
2. Set the canvas background to a soft light cyan gradient matching `background.topLeading` and `background.bottomTrailing`.
3. Drag in `10-face.svg` and `40-features.svg`.
4. Put `10-face.svg` in its own group and keep Liquid Glass enabled for that group.
5. Keep `40-features.svg` flat, with Liquid Glass disabled, so the eyes and mouth stay crisp.
6. Only add `20-face-rim.svg` or `30-highlight.svg` if Icon Composer's specular controls cannot provide enough edge definition.
7. Tune the face group with low-to-medium translucency, subtle refraction, and a clean specular highlight.
8. Preview Default, Dark, Mono, Clear light, and Clear dark before saving the `.icon` file.

Do not export the rounded app icon mask from SwiftUI; Icon Composer and the system apply the platform mask.

## Xcode AppIcon export

The shipping app icon is exported from the saved Icon Composer document, not from the SwiftUI preview renderer:

```bash
/Applications/Icon\ Composer.app/Contents/Executables/ictool \
  artifacts/palmi-icon/v1/PalmiIcon.icon \
  --export-image \
  --output-file PalmiAgent/Assets.xcassets/AppIcon.appiconset/palmi-iconcomposer-default.png \
  --platform iOS \
  --rendition Default \
  --width 1024 \
  --height 1024 \
  --scale 1
```

Use `--rendition Dark` for `palmi-iconcomposer-dark.png`, and `--rendition TintedLight` for `palmi-iconcomposer-tinted.png`.
