<div align="center">

<img src="{icon_url}" width="96" alt="">

### PAX Controller {version}

Unsigned build · iOS 16 or later · {size}

</div>

---

{gallery}

---

## Install step by step

You need a free Apple ID. Nothing costs money, but a free account means the app
stops working after 7 days unless it is refreshed — step 8 takes care of that.

**1.** Install **iLoader** on a computer and connect your iPhone or iPad.
Follow the [SideStore install docs](https://docs.sidestore.io/docs/installation/install).

**2.** In iLoader: *Add Account* and sign in with your Apple Account, pick your
device under *Devices*, then pick **SideStore (Stable)** under *Installers*.

**3.** On the device, trust the app: *Settings → General → VPN & Device
Management → (your Apple Account) → Trust*.

**4.** Install **LocalDevVPN** and tap **Connect**. SideStore needs it to install
and refresh apps. If you use StosVPN or WireGuard, switch to LocalDevVPN for setup.

**5.** Open **SideStore**, sign in with the *same* Apple Account, go to *My Apps*
and tap the **7 DAYS** counter next to SideStore to finish setup.

**6.** Add this source — SideStore → *Sources* → **+**:

```
{source_url}
```

**7.** Install **PAX Controller** from the source, open it and tap *Scan*.
{shortcut_section}
## Which file do I want?

| File | Use it for |
|---|---|
| `PaxController.ipa` | **Normal install.** This is what the source above installs. |
| `PaxController-DEBUG.ipa` | Troubleshooting only. Adds a **Log** tab showing raw Bluetooth traffic. Installs as *PAX Debug* alongside the normal app. |

<details>
<summary><b>If something goes wrong</b></summary>

<br>

- **"Not connected to VPN"** when refreshing — open LocalDevVPN and reconnect.
- **Install or refresh fails** — in iLoader use *Manage Pairing File* → *Place*
  next to SideStore, and pick
  `On My iPhone/iPad → SideStore → ALTPairingFile.mobiledevicepairing`.
- **The Shortcut will not import** — shared shortcuts count as untrusted:
  turn on *Settings → Shortcuts → Allow Untrusted Shortcuts* once, then open
  the file again.
- **App opens but finds nothing** — Bluetooth permission is asked on the first
  scan, allow it, and make sure the PAX is awake.

</details>

<details>
<summary><b>About this build</b></summary>

<br>

Built automatically from source by GitHub Actions and ad-hoc signed only —
SideStore re-signs it with your own Apple ID while installing. The screenshots
above come from a simulator, which has no Bluetooth radio, so the app is shown
in its disconnected state.

Independent project, not affiliated with or endorsed by PAX Labs.

</details>
