# Design canvas sources

Artboards for the charging state and the Lock Screen card, as mockups rather
than shipped code — decide here, then build it in `PaxController/Sources`.

Measurements are lifted from `DesignSystem.swift` so the mockups and the app
agree: a 390 × 844 frame, a 380 pt dial whose arc runs 270° clockwise from
135° at radius 164 with a 26 pt stroke, a 52 pt top bar, 38 pt capsules, the
66 pt temperature, and `#FF6A00` for the default LED colour.

| File | |
|------|--|
| `Main.dc.html` | Charging, direction A — the dial re-pointed at the battery |
| `ChargeQuiet.dc.html` | Charging, direction B — dial keeps meaning temperature, card below |
| `ChargeMinimal.dc.html` | Charging, direction C — charging and nothing else |
| `LockUsing.dc.html` | Lock Screen while heating, three directions |
| `LockCharging.dc.html` | Lock Screen on the charger, three directions |
| `LockScanning.dc.html` | Lock Screen while waiting for the device, three directions |
| `canvas.json` | How they are laid out, and the two pages they sit on |

Published at https://claude.ai/artifact/4dHqfFhkJGV4G5uQm41ZyT
