Unsigned IPA, version {version}. Requires iOS 16 or later.

Screenshots of every screen are attached to this release.

## Install step by step

You need a free Apple ID. Nothing is paid, but a free account means the app
stops working after 7 days unless it is refreshed — step 8 automates that.

1. **Install iLoader** on a computer and connect your iPhone or iPad.
   Follow the [SideStore install docs](https://docs.sidestore.io/docs/installation/install).
2. **In iLoader:** *Add Account* and sign in with your Apple Account, pick your
   device under *Devices*, then pick **SideStore (Stable)** under *Installers*.
3. **Trust the app:** on the device, *Settings → General → VPN & Device
   Management → (your Apple Account) → Trust*.
4. **Install LocalDevVPN** and tap **Connect**. SideStore needs it to install and
   refresh apps. If you use StosVPN or WireGuard, switch to LocalDevVPN for setup.
5. **Open SideStore**, sign in with the *same* Apple Account, go to *My Apps* and
   tap the **7 DAYS** counter next to SideStore to finish setup.
6. **Add this source:** SideStore → *Sources* → **+** → paste:

   ```
   {source_url}
   ```

7. **Install PAX Controller** from the source, then open it and tap *Scan*.
{shortcut_section}
## If something goes wrong

- *"Not connected to VPN"* when refreshing: open LocalDevVPN and reconnect.
- Install or refresh fails: in iLoader use *Manage Pairing File* → *Place* next to
  SideStore and select `On My iPhone/iPad → SideStore → ALTPairingFile.mobiledevicepairing`.
- The app opens but finds nothing: Bluetooth permission is requested on first
  scan — allow it, and make sure the PAX is awake.

## About this build

Built automatically from source by GitHub Actions. It is ad-hoc signed only;
SideStore re-signs it with your own Apple ID during installation. The simulator
has no Bluetooth radio, so the attached screenshots show the app's disconnected
state.
