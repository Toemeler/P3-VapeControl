# Typefaces

The eleven shipped themes were drawn with webfonts — Archivo, Instrument Serif,
IBM Plex Mono, Barlow Condensed, DM Sans, Space Grotesk, Instrument Sans,
Bricolage Grotesque, Manrope and Chivo. None of them are bundled here: they are
tens of megabytes, and this repository deliberately carries no redistributed
assets.

So out of the box the themes are **1:1 in layout, colour, metric, weight and
hierarchy, and approximate in typeface**. Each theme names the face it was drawn
with in `typography.family` / `typography.displayFamily`, and names a system
family to fall back to in `typography.design` and `typography.width`:

| Theme | Drawn with | Falls back to |
|-------|-----------|---------------|
| Classic | SF Pro | SF Pro |
| Werkstatt | Archivo | SF Pro |
| Editorial | Instrument Serif + IBM Plex Mono | New York (`design: "serif"`) |
| Native | SF Pro | SF Pro |
| Thermal | Barlow Condensed | SF Pro Condensed (`width: "condensed"`) |
| Instrument | DM Sans | SF Pro |
| Chart | Space Grotesk | SF Pro |
| Surface | Instrument Sans | SF Pro |
| Sentence | Bricolage Grotesque | SF Pro |
| Object | Manrope | SF Pro |
| Clock | Chivo | SF Pro |

`ThemeTokens.isAvailable(_:)` checks each name against the fonts actually
installed, so nothing has to change for a theme to pick its real face up.

## Getting the real faces

Two ways, both without editing any Swift:

1. **Install the font on the device.** Any font installed through iOS' own font
   management is visible to the app, and a theme naming it starts using it on
   next launch.
2. **Bundle it.** Drop the `.ttf` or `.otf` into `PaxController/Resources`, add
   it to the target, and list it under `UIAppFonts` in `Info.plist`. Use the
   font's PostScript name in the theme's `family` — it is what
   `UIFont(name:size:)` matches on.

Check the licence before bundling anything. All ten above are open-licensed
(SIL OFL) at the time of writing, but that is on whoever ships the build.
