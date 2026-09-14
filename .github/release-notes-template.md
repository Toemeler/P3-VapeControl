<div align="center">

<img src="{icon_url}" width="88" alt="">

### PAX Controller {version}

Unsigned · iOS 16+ · {size}

</div>

{gallery}

Add this source in SideStore → *Sources* → **+**

```
{source_url}
```

<details>
<summary><b>Install — step by step</b></summary>

<br>

Free Apple ID is enough. Apps signed with one expire after 7 days — see **AutoRefreshApps** below.

1. Install **iLoader** on a computer, connect the device — [docs](https://docs.sidestore.io/docs/installation/install).
2. iLoader → *Add Account*, pick your device, install **SideStore (Stable)**.
3. On the device: *Settings → General → VPN & Device Management → your account → Trust*.
4. Install **LocalDevVPN**, tap **Connect**.
5. Open **SideStore**, sign in with the same account, *My Apps* → tap the **7 DAYS** counter.
6. *Sources* → **+** → paste the URL above.
7. Install **PAX Controller**, open it, tap *Scan*.

<details>
<summary><b>Problems</b></summary>

<br>

- **"Not connected to VPN"** — reconnect LocalDevVPN.
- **Install or refresh fails** — iLoader → *Manage Pairing File* → *Place* next to SideStore, pick `On My iPhone → SideStore → ALTPairingFile.mobiledevicepairing`.
- **Finds no device** — allow Bluetooth on first scan, make sure the PAX is awake.

</details>

</details>

<details>
<summary><b>AutoRefreshApps — stop the 7-day expiry</b></summary>

<br>

Add [**AutoRefreshApps.shortcut**]({shortcut_url}) and run it daily via *Shortcuts → Automation*. It calls SideStore's refresh before the signature runs out.

- Needs **iOS 27 or later**. Older iOS: refresh by hand in SideStore.
- Will not import? Turn on *Settings → Shortcuts → Allow Untrusted Shortcuts*.

</details>

<details>
<summary><b>Which file?</b></summary>

<br>

| File | For |
|---|---|
| `PaxController.ipa` | Normal install — what the source installs. |
| `PaxController-DEBUG.ipa` | Troubleshooting. Adds a **Log** tab, installs as *PAX Debug* next to the normal app. |

</details>


<sub>Built by GitHub Actions, ad-hoc signed — SideStore re-signs it with your Apple ID. Screenshots come from a simulator. Not affiliated with PAX Labs.</sub>
