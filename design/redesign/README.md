# Control screen — design directions

Mockups, not shipped code: decide here, then build it in `PaxController/Sources`.

Published at https://claude.ai/artifact/TLbwq5DwRAM55qpXJ3FXwj

## Page 1 — structural directions

Five answers to "what is this screen for", each with a different layout and a
different main gesture. The first pass (page 2) only restyled the shipped
layout; these replace it.

| File | |
|------|--|
| `Current.dc.html` | Today, for comparison. Tokens from `DesignSystem.swift` |
| `Main.dc.html` | **F · Chart** — the session's trace is the screen; presets are detents on the target scale |
| `Surface.dc.html` | **G · Surface** — the display is the control; seven elements total |
| `Sentence.dc.html` | **H · Sentence** — no components; state as prose, words as controls |
| `Object.dc.html` | **I · Object** — the device is the hero, the data is furniture |
| `Clock.dc.html` | **J · Clock** — hierarchy re-ranks by state; shown mid warm-up |

F and J propose data the app does not compute yet (a session buffer with draw
detection; a time-to-ready estimate derived from the rate of climb). Both are
flagged on their notes.

## Page 2 — first pass, surface themes

All five keep the shipped layout and change only the design language. Kept as a
palette and typography library: A's matte plates and one-accent discipline, or
E's printed gauge face, can be applied to any structure from page 1.

| File | |
|------|--|
| `Werkstatt.dc.html` | **A · Werkstatt** — Braun functionalism; linear printed scale |
| `Editorial.dc.html` | **B · Editorial** — Swiss page, hairline rules, no chrome |
| `Native.dc.html` | **C · Native** — stock iOS, system controls throughout |
| `Thermal.dc.html` | **D · Thermal** — warm graphite, the oven as a column of heat |
| `Instrument.dc.html` | **E · Instrument** — a printed gauge face, needle and bezel index |

## Conventions

Every frame shows the same moment — connected, 78% battery, oven at 193.4 °C,
target 193, Standard mode, the 193° preset live — so the only variable between
them is the design. `Clock.dc.html` is the exception: it is shown mid warm-up
(oven 162.7 °C, 14 s to go), because a hierarchy that re-ranks itself by state
has to be seen in the state it is built for.

Each direction's motivation and its main tradeoff are on the note beneath its
frame, and `canvas.json` holds the layout, the pages and those notes.
`Main.dc.html` holds the leading candidate until one is picked, at which point
the chosen direction is built into `Main.dc.html` and taken through the
remaining states — light and dark, warming up, charging, offline, locked, and
the Lock Screen card.
