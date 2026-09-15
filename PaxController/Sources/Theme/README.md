# Theming

The screen is not one design with a palette on top. A theme picks **which
screen** you get, and then every token that screen draws with.

```
AppTheme ─┬─ shell      stacked | chart | field | prose | object | countdown
          ├─ hero       arc | linearScale | rule | card | column | gauge
          ├─ target     stepperRound | stepperPlate | stepperHairline | slider | detents | none
          ├─ presets    capsules | plates | words | segmented | table | detents | none
          ├─ modes      tiles | switchBar | keys | list | words | selector | dots | none
          ├─ typography design, width, family, casing, tracking, weights
          ├─ metrics    gutter, radii, control heights, stroke widths, section gaps
          └─ light/dark a colour per role
```

`ThemedScreen` routes to a shell; `StackedShell` composes a hero and three
control variants, which is why Classic, Werkstatt, Editorial, Native, Thermal
and Instrument are one shell rather than six screens. Chart, Surface, Sentence,
Object and Clock change the structure itself, so each has its own shell.

| File | |
|------|--|
| `AppTheme.swift` | The theme value, the colour and metric roles, and `ThemeTokens`, which resolves a theme against light or dark |
| `ThemeCatalog.swift` | The eleven shipped themes, as the same data an imported file carries |
| `ThemeStore.swift` | Selection, persistence, import, export, duplicate, delete |
| `ThemeComponents.swift` | Header, readout, target, presets, modes, discovery — every variant the recipes select from |
| `ThemeHeroes.swift` | The six heroes, and the shapes they are drawn with |
| `ThemeShells.swift` | The router, the six shells, and the session recorder Chart and Clock need |
| `ThemePickerView.swift` | Choosing, importing and exporting, in Settings under Appearance |

## Writing a theme

A theme is JSON. Every field is optional except `id` and `name`, and even those
are filled in from the filename on import, so the smallest useful theme is:

```json
{ "name": "Ember", "dark": { "accent": "#FF5A1F" } }
```

Anything a theme leaves out falls back to the shipped value for that role, so a
theme can change one colour or rebuild the screen. `example-theme.json` beside
this file is a fuller starting point.

Get one in through **Settings → Appearance → Import from a file**, or paste the
JSON straight in. Duplicating a shipped theme gives you a copy you can export,
edit anywhere, and import back.

## Known gaps

- Typefaces fall back to system families unless the real fonts are installed or
  bundled. See `FONTS.md`.
- `TemperatureDial` still reads `DS.Palette.track`, `.charge` and `.low` rather
  than the active theme, so the arc hero's track and battery ring follow the
  shipped palette. Only the Classic theme uses that hero, where the two agree.
- The Chart and Clock themes record temperature only while their screen is on
  screen, so their trace and session clock start when you open the app rather
  than when the device did. Draws come from the PAX's own `boosting` state, not
  from guessing at the curve.
