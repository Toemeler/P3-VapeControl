# Control screen — design directions

Five design languages for the control screen, and the screen as it ships
today to compare them against. Mockups, not shipped code: decide here, then
build it in `PaxController/Sources`.

All six frames show the same moment — connected, 78% battery, oven at
193.4 °C, target 193, Standard mode, the 193° preset live — so the only
thing that varies between them is the design language.

| File | |
|------|--|
| `Current.dc.html` | Today, at that reading. Tokens from `DesignSystem.swift` |
| `Main.dc.html` | **A · Werkstatt** — Braun functionalism; linear printed scale |
| `Editorial.dc.html` | **B · Editorial** — Swiss page, hairline rules, no chrome |
| `Native.dc.html` | **C · Native** — stock iOS, system controls throughout |
| `Thermal.dc.html` | **D · Thermal** — warm graphite, the oven as a column of heat |
| `Instrument.dc.html` | **E · Instrument** — a printed gauge face, needle and bezel index |
| `canvas.json` | How they are laid out, and the note under each one |

Each direction's motivation and its main tradeoff are on the sticky note
beneath its frame. Nothing is chosen yet; `Main.dc.html` holds the leading
candidate until one is picked, at which point the chosen direction is built
into `Main.dc.html` and taken through the remaining states — light and dark,
warming up, charging, offline, and the Lock Screen card.

Published at https://claude.ai/artifact/TLbwq5DwRAM55qpXJ3FXwj
