<div align="center">

<img src="{icon_url}" width="88" alt="">

### PAX Controller {version}

Unsigned · iOS 16+ · {size}

</div>

{gallery}

{add_source}

<details>
<summary><b>Install — step by step</b></summary>

<br>

A free Apple ID is enough — see **AutoRefreshApps** below for what that means after seven days.

1. Install **iLoader** on a computer, connect the device — [docs](https://docs.sidestore.io/docs/installation/prerequisites).
2. iLoader → *Add Account*, pick your device, install **SideStore (Stable)**.
3. On the device: *Settings → General → VPN & Device Management → your account → Trust*.
4. Install **[LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)**, tap **Connect**.
5. Open **SideStore**, sign in with the same account, *My Apps* → tap the **7 DAYS** counter.
6. In **SideStore** → *Sources* → **+**, add `{source_url}`.
7. Install **PAX Controller** and open it — it finds and connects to your PAX by itself.

<details>
<summary><b>Problems</b></summary>

<br>

- **"Not connected to VPN"** — reconnect LocalDevVPN.
- **Install or refresh fails** — in iLoader, click *Place pairing file*.
- **Finds no device** — allow Bluetooth when asked, make sure the PAX is awake.

</details>

</details>

<details>
<summary><b>AutoRefreshApps — stop the 7-day expiry</b></summary>

<br>

Add [**AutoRefreshApps.shortcut**]({shortcut_url}).

- Needs **iOS 27 or later**. Older iOS: refresh by hand in SideStore.

</details>

<details>
<summary><b>PaxControllerLab.ipa — what the second file is</b></summary>

<br>

The same app with a protocol workbench compiled in, under its own bundle id so
it installs beside the normal one rather than replacing it. *Settings →
Diagnostics → Lab*: read every attribute the firmware answers, snapshot the
device in one state and diff it against another, and write arbitrary attributes.

That last part can take a PAX offline until it is power-cycled. Install this one
only if that is what you came for.

</details>

<sub>Not affiliated with PAX Labs.</sub>
