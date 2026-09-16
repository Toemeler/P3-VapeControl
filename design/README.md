# Design canvas sources

Artboards for the charging state and the Lock Screen card, as mockups rather
than shipped code — decide here, then build it in `PaxController/Sources`.

Settled so far: nothing on the charging screen is hidden or rearranged. The
battery is a third ring, nested inside the temperature arc (r164, 26 pt) and
the warm-up ring (r145, 3.5 pt) at r131 — a quiet 4 pt line normally, thickening
to 10 pt and turning green on the charger, with a highlight travelling around it
so the motion means current rather than a level changing. The steppers, presets
and mode tiles stay where they are and grey out.

A fourth ring at r114, innermost: the time ring. It times a session off the
charger and a charge on it, which are never both true, so one lane carries both
readings and the dial gains nothing to fit them in. The arc is a compressed
timeline that never fills; the thickness is how much has accumulated — minutes
and draws for a session, minutes for a charge; and the beads are the events
themselves, one per draw or per ten percent of a charge, standing where they
happened. On a session the brighter segment at the leading edge is what is left
of the auto-off window, refilled by every draw.

Nothing on this dial grows outward. The oven's ring has its outer edge pinned
at r177 and thickens inward over a draw, so no draw however long can reach the
preset dots at r185 or the edge of the canvas. Worst case, every ring at its
maximum: oven 141.5–177, battery 123.7–138.3, time 108–120. The readout in the
middle is capped at 184 pt wide for the same reason.

Settled: the three Lock Screen states share one skeleton — ring, name and
state, lead number — and only what the ring measures and which number leads
changes between them. A card that rearranges itself has to be read again every
time. Built in `PaxController/LiveActivity/PaxStatusLiveActivity.swift`; the
artboards stay as the record of what was considered.

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
