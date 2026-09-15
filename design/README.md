# Design canvas sources

Artboards for the charging state and the Lock Screen card, as mockups rather
than shipped code — decide here, then build it in `PaxController/Sources`.

Settled so far: nothing on the charging screen is hidden or rearranged. The
battery is a third ring, nested inside the temperature arc (r164, 26 pt) and
the warm-up ring (r145, 3.5 pt) at r131 — a quiet 4 pt line normally, thickening
to 10 pt and turning green on the charger, with a highlight travelling around it
so the motion means current rather than a level changing. The steppers, presets
and mode tiles stay where they are and grey out.

Still open: how the three Lock Screen states relate to each other.

Measurements are lifted from `DesignSystem.swift` so the mockups and the app
agree: a 390 × 844 frame, a 380 pt dial whose arc runs 270° clockwise from
135° at radius 164 with a 26 pt stroke, a 52 pt top bar, 38 pt capsules, the
66 pt temperature, and `#FF6A00` for the default LED colour.

| File | |
|------|--|
| `Main.dc.html` | On the charger — battery as a third ring, controls greyed |
| `Normal.dc.html` | The same screen off the charger, to compare against |
| `LockUsing.dc.html` | Lock Screen while heating, three directions |
| `LockCharging.dc.html` | Lock Screen on the charger, three directions |
| `LockScanning.dc.html` | Lock Screen while waiting for the device, three directions |
| `canvas.json` | How they are laid out, and the two pages they sit on |

Published at https://claude.ai/artifact/4dHqfFhkJGV4G5uQm41ZyT
