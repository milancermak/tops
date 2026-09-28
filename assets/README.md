# Tops app icon

`AppIcon.png` is the approved flying-note logo, centered by translating the
original pixels 33 pixels left and 12 pixels down. Its shape and colors are
unchanged from the original generated artwork. Earlier image-generation drafts
are local development output and are not needed to build the app.

The 1254 × 1254 source has green artwork bounds x=330…922, y=257…997. Opposing
margins differ by one pixel, the closest possible alignment using whole pixels
for this silhouette and canvas size.

`scripts/render-icon.swift` clips only the background to a continuous rounded
square with transparent padding, preserving the centered note's scale and
position. It writes `.build/AppIcon-macOS.png`; the original square PNG stays
unmasked. The legacy export uses a 100px inset on a 1024px canvas, matching the
25px inset measured in this Mac's 256px Notes and Calculator icons. The 185px
continuous corner radius is an export design choice, not a numeric HIG rule.

`scripts/build-icon.sh` creates all ten macOS icon representations from that
rounded export and packages `.build/AppIcon.icns`. `scripts/build-app.sh` includes
the icon in `Tops.app`.

Apple's [app-icon HIG](https://developer.apple.com/design/human-interface-guidelines/app-icons)
calls for centered content and a rounded-square final icon. Its current guidance
about unmasked layers applies to the newer system-masked/Icon Composer pipeline.
Tops' existing macOS 14/15 ICNS export supplies its own rounded silhouette and
transparent padding. See also Apple's
[WWDC25 explanation of the masking change](https://developer.apple.com/videos/play/wwdc2025/220/).
