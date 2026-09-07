# Flight — Hermes Fleet 0.2

An original single wing formed by three bold vector planes, rising from lower left to upper right. The shipped source is `HermesFleetApp/FleetWing.icon`, compiled directly by Xcode's asset pipeline. Three SVG layers contain no baked lighting or shadows. Icon Composer renders the specular behavior and appearance variants.

`Default.png`, `Dark.png`, `TintedDark.png`, `ClearLight.png`, and `ClearDark.png` are native Icon Composer previews, including the system mask. Their transparent corner pixels are intentional preview geometry; they are not flat App Store uploads. `marketing-1024.png` is the opaque 1024-square presentation export. Previous wing explorations remain untouched.

Tool: `/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`.

Render each appearance with `--export-image --platform iOS --rendition <name> --width 1024 --height 1024 --scale 1 --output-file <path>`.
