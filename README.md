# pi-bluetooth-configuration-client-ios

**aipicam** -- an iOS app to configure WiFi on a Raspberry Pi running
[pi-bluetooth-configuration](https://github.com/jacohanekom/pi-bluetooth-configuration-alpine),
talking plain HTTP/JSON over the phone's own WiFi connection -- to the
Pi's fallback access point while it's unconfigured, or to the Pi
directly once it's joined a real network. This started as the iOS
counterpart to a macOS client (`pi-bluetooth-configuration-client-mac`,
now retired -- a phone in your pocket covers the same provisioning need
without requiring a Mac, so there was no reason to keep maintaining
both): same HTTP API, same screens, same feature set, just with
iOS-appropriate chrome (a `NavigationStack` instead of a free-floating
window titlebar button, no fixed window size, autocorrection/
autocapitalization turned off on the address/SSID/password/IP fields
since iOS defaults to fighting all three).

Finds the Pi automatically on launch (mDNS/Bonjour -- see "Discovery"
below) and walks through a wizard: pick a WiFi network, enter its
password, confirm eth0's local network (gateway IP + DHCP range), then
finish -- no SSH, no keyboard on the Pi. If nothing's found (nothing set
up yet, or the Pi couldn't join your WiFi), the app tells you to join its
own fallback access point instead (its own WiFi network, named after its
serial number, defaulting to `192.168.5.1:8080` -- the same setup-AP
pattern any headless IoT device uses) and search again; manual address
entry is always available too. Once setup is finished, a details screen
shows WiFi/network stats, relay controls, and Victron solar/battery
telemetry behind three collapsible sections -- see "Using it" below for
the exact walkthrough.

Built with SwiftUI + URLSession + Network (`NWBrowser`/`NWConnection` for
discovery) -- no CoreBluetooth, no third-party dependency of any kind
(see git history for the earlier BLE-based revision this replaced).

This is a one-shot provisioning flow, not a managed session: the Pi
reboots itself a few seconds after **Finish** or a reset (see the
daemon's README, "One-shot provisioning and reboot behavior"), and a
successful **Connect** that started from the fallback AP reboots
immediately, no separate Finish step -- this radio can't run the AP and
a real network at once, so joining a new network necessarily means the
address this app was just using stops working. This app doesn't try to
keep managing anything once that happens; it surfaces it plainly instead
of pretending to recover, and sends you back to entering an address once
the Pi (hopefully) comes back up elsewhere.

## Security

There is no pairing, encryption, or authentication anywhere in this
flow. The Pi's fallback AP is open (no password), and every HTTP request
this app makes is plain, unencrypted HTTP -- WiFi SSID and password
cross both in the clear to anyone in range or on the same network during
the provisioning window. This is a deliberate choice, not an oversight
(see the daemon's README, "Security model", for the full reasoning). Use
this only on a trusted home/lab network, during a provisioning window
you control.

## Requirements

- iOS/iPadOS 16 or later, with WiFi on
- A Pi running `pi-bluetooth-configuration`, reachable either via its
  fallback AP or on a real network
- To build: Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)
- Runs fine in the iOS Simulator for a compile check, but the Simulator
  shares the Mac's own network rather than joining a Pi's fallback AP, so
  actually talking to a Pi needs a real device on the same WiFi network
  as it: an Apple ID signed into Xcode for free automatic signing, or a
  paid Apple Developer Program membership for distributing beyond your
  own devices

## Download a prebuilt .ipa (unsigned -- resign before installing)

Every push builds `aipicam-unsigned.ipa` (GitHub Actions artifact on
[the Build workflow](../../actions/workflows/build.yml); tagged `v*`
pushes also attach it to a
[GitHub Release](../../releases)). This lets you try aipicam on your own
iPhone/iPad without installing Xcode or XcodeGen at all -- just a
resigning tool and your own Apple ID.

**It's genuinely unsigned**, not ad-hoc-signed the way the Mac client's
`.app` is: CI has no paid Apple Developer Program enrollment, so there's
no real signing identity for it to sign with (see "Build for real
device" in `.github/workflows/build.yml` for exactly what that build
does instead). iOS refuses to run anything without a valid signature
from a certificate the device trusts, so this `.ipa` won't install as
downloaded -- you need to resign it yourself first, with your own
(free) Apple ID:

1. Download `aipicam-unsigned.ipa` from Actions or a Release.
2. Resign and install it with a sideloading tool, e.g.
   [Sideloadly](https://sideloadly.io/) (macOS/Windows) -- point it at
   the `.ipa`, sign in with your Apple ID, connect your device over USB,
   and it handles resigning and installing in one step. (Similar tools:
   [AltStore](https://altstore.io/), which additionally auto-refreshes
   the signature for you in the background.)
3. Trust the developer certificate on-device the first time: **Settings
   → General → VPN & Device Management → \[your Apple ID\] → Trust**.

**A free Apple ID's signature expires after 7 days** -- reinstall (or
let AltStore auto-refresh) to keep using it past that. A paid Apple
Developer Program membership signs for a full year instead, but isn't
required for this.

If you'd rather build and run from source directly (no separate
resigning step -- Xcode does it for you against your own Apple ID), see
"Build and run" below instead.

## TestFlight (requires an Apple Developer Program membership)

[`.github/workflows/testflight.yml`](.github/workflows/testflight.yml)
archives, signs with a *real* Apple Developer Program identity, and
uploads a build to App Store Connect on every `v*` tag push (or manually
via **Actions → TestFlight → Run workflow**) -- unlike `build.yml`'s
`aipicam-unsigned.ipa`, this produces something installable straight
from the TestFlight app, no resigning tool needed, for anyone you invite
as a tester.

This needs a handful of one-time setup steps on your end first --
things only you can do, since they require your own Apple ID/App Store
Connect login:

1. **Register the Bundle ID**, if you haven't already (skip this if
   you've ever archived/run this project locally in Xcode with your own
   team selected -- Xcode registers it automatically the first time it
   needs to): [developer.apple.com/account](https://developer.apple.com/account)
   → Certificates, Identifiers & Profiles → Identifiers → **+** → App
   IDs → Continue → App → Continue. Description `aipicam` (an internal
   label, not user-facing), Bundle ID **Explicit** →
   `com.jacohanekom.aipicam` (must match `project.yml`'s
   `PRODUCT_BUNDLE_IDENTIFIER` exactly). Leave every capability
   unchecked -- local network access needs no App ID capability, just the
   `NSLocalNetworkUsageDescription` string already in `Info.plist`.
   Continue → Register.
2. **Create the app record in App Store Connect**:
   [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Apps
   → **+** → New App. Platforms: iOS. Name: the public App Store listing
   name -- **must be globally unique across the whole App Store**, not
   just your account (try `aipicam` first; if it's taken, something like
   `aipicam WiFi Setup` instead -- this is separate from
   `CFBundleDisplayName`, which can stay `aipicam` either way). Bundle
   ID: pick `com.jacohanekom.aipicam` from the dropdown (only appears
   here once step 1 is done). SKU: any unique string for your own
   bookkeeping, e.g. `aipicam-ios-1` (never shown to users). User
   Access: Full Access. Create. Uploads fail outright if this app
   record doesn't exist yet; nothing in CI creates it for you.

   Once CI uploads a build, it shows up under this app's **TestFlight**
   tab after ~10-30 minutes of Apple's processing. Use **Internal
   Testing** to actually try it (add yourself/other App Store Connect
   users as internal testers under Users and Access -- available the
   moment processing finishes, no review needed); **External Testing**
   (a public link, anyone) additionally requires a short Beta App Review
   the first time.
3. **Create an App Store Connect API key**: App Store Connect → Users
   and Access → Integrations → App Store Connect API → **+**. Give it
   the **App Manager** role (not just Developer -- it needs to be able
   to create/renew signing certificates and provisioning profiles on
   its own, non-interactively, via `-allowProvisioningUpdates`).
   Download the `.p8` file **immediately** -- App Store Connect only
   lets you download it once. Note the **Key ID** and **Issuer ID**
   shown on that same page.
4. **Find your Team ID**: [developer.apple.com/account](https://developer.apple.com/account)
   → Membership details, or Xcode → Settings → Accounts → your team.
5. **Add four repo secrets** (Settings → Secrets and variables →
   Actions → New repository secret):

   | Secret | Value |
   |---|---|
   | `APPSTORE_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy`, then paste |
   | `APPSTORE_KEY_ID` | the Key ID from step 3 |
   | `APPSTORE_ISSUER_ID` | the Issuer ID from step 3 |
   | `APPSTORE_TEAM_ID` | the Team ID from step 4 |

6. Push a tag: `git tag v1.0.0 && git push origin v1.0.0` -- or just run
   the workflow manually once to test the setup without cutting a real
   version tag.

The version shown in TestFlight comes from the tag itself (`v1.2.3` →
`1.2.3`); the build number is the GitHub Actions run number, which only
ever goes up, since App Store Connect rejects re-uploading a build
number it's already seen for the same version.

**I can't test this workflow myself** -- it needs your actual Apple
Developer account, which I have no access to. Unlike `build.yml`'s
unsigned `.ipa` (which I built, downloaded, and inspected end-to-end
before calling it done), this one is written from documented Apple
tooling behavior, not verified against a real upload. Expect to iterate
on the first run or two -- share the failing step's log and I'll help
debug it.

## Why XcodeGen instead of a checked-in .xcodeproj

The now-retired macOS client's `.gitignore` excluded `*.xcodeproj` on
principle -- a generated project file is a build artifact, not source,
and raw `.pbxproj` diffs are unreviewable noise. That repo could still
ship without one because a plain `swift build` produces a real, runnable
macOS executable on its own. iOS has no equivalent: there's no SPM
product type for an installable, signed `.app`, and none of the leniency
macOS extends to a bare, unsigned CLI binary (that Mac client's trick of
embedding usage-description strings straight into the executable's
`__info_plist` section doesn't have an iOS counterpart -- iOS enforces
real app-bundle and code-signing rules unconditionally). An Xcode
project is unavoidable here.

[`project.yml`](project.yml) is the checked-in source of truth instead --
a small, readable, diffable spec that [XcodeGen](https://github.com/yonaskolb/XcodeGen)
turns into `Aipicam.xcodeproj` on demand. The generated project itself
stays out of git, same principle as before, just one level removed.

## Using it

1. Launch the app. It searches automatically (mDNS/Bonjour -- see
   "Discovery" below) for a few seconds; if a Pi is found, it connects
   straight to it, no tap needed.
2. **If nothing's found** (nothing set up yet, the Pi couldn't join your
   WiFi, or you're just not on the same network as it yet): join its
   fallback access point in the iOS Settings app -- **Settings → WiFi**,
   look for a network named after the Pi's hardware serial number, join
   it (no password) -- then tap **Search Again** in the app. Manual
   address entry (prefilled with `192.168.5.1:8080`, the fallback AP's
   default) is always available too, if you'd rather skip searching or
   already know the Pi's address on a real network.
3. **If setup already finished on this Pi**, you land straight on the
   details screen (see step 9 below for what's on it). Skip to step 8.
4. **Otherwise**, a wizard starts automatically:
   - It scans for networks right away (spinner, no button to press).
   - Pick one from the list, or **Enter Network Manually** for a hidden
     network.
5. Enter the password (leave blank for an open network) and tap
   **Connect**. A status line shows live progress
   (`connecting` → `connected`/`failed`) for as long as the app can
   still reach the Pi. **If the Pi was on its fallback AP**, expect to
   lose that connection entirely partway through -- joining the new
   network tears the AP down, since this radio can't run both at once.
   The app says so plainly and sends you back to address entry, which
   searches again automatically; rejoin your regular WiFi and wait a
   moment for the Pi to finish joining and re-advertise itself there
   (skipping straight to the details screen if it joined successfully --
   see step 9). **If the Pi was already on a real network**
   (reconfiguring), the connection normally survives and the wizard
   continues below.
6. Once WiFi joins (without the AP having been involved), the wizard
   moves to **Local Network Configuration**: `eth0` already has a
   working gateway IP and DHCP server (it's always on, from the moment
   the Pi first boots -- see the daemon's README, "Ethernet
   direct-connect"), prefilled here so you can just confirm it, or
   change the IP/DHCP range if you'd like something different.
7. Tap **Finish**. This is what actually concludes setup and reboots
   the Pi a few seconds later -- losing the connection is expected, not
   an error; the app reconnects to the same address automatically once
   the Pi is back up, landing on the details screen described next.
8. **Reset** removes the network the Pi last configured and reboots it
   the same way (this sends the same `/forget` request the daemon's API
   always had -- "Reset" is just how this app labels it). The Pi comes
   back up in fallback-AP mode afterward (nothing is configured anymore)
   -- rejoin that AP and search again, same as step 2. Only shown once
   setup has finished: resetting only makes sense once there's something
   to reset. Local network settings aren't touched by Reset and become
   editable again once the wizard restarts.
9. The post-setup details screen has three collapsible sections (tap
   each to expand/collapse -- **Connectivity** starts open, the other
   two start collapsed since there's a lot to show across all three):
   - **Connectivity**: WiFi network/IP, and the local network's gateway
     IP + DHCP range plus whatever's currently allocated to devices
     plugged into `eth0`.
   - **Relays**: one toggle switch per relay, if any are configured
     (see the daemon's README, "Relay control" -- an optional
     integration with
     [pi-relay-control-alpine](https://github.com/jacohanekom/pi-relay-control-alpine)).
     A switch is disabled while that relay's state reads as unknown
     (pi-relay-control-alpine not reachable on the configured port).
     Shows "No relays configured" if `[relays]` is empty.
   - **Solar/Battery Information**: the latest reading from a Victron
     MPPT solar charger, if one's connected (see the daemon's README,
     "Victron solar/battery telemetry" -- an optional integration with
     [victron-ve-direct-alpine](https://github.com/jacohanekom/victron-ve-direct-alpine)):
     device name/serial, battery voltage, battery current (labeled
     charging/discharging/idle, since the raw sign isn't obvious at a
     glance), solar voltage/input power, charge state, error, and yield
     today. Shows "No Victron device connected" if nothing's reachable.
     (State of charge / time to go aren't shown -- those only exist on
     battery monitors, not the MPPT chargers this integration targets.
     Load output isn't shown either -- not every MPPT has one, and it's
     always "ON" on this integration's hardware.)

Tap **Disconnect** in the toolbar at any point (during the wizard or on
the details screen) to end the session.

## Build and run

```sh
brew install xcodegen   # one-time
make open               # generates Aipicam.xcodeproj and opens it
```

Then in Xcode: pick your iPhone/iPad as the run destination (see
Requirements above for why a Simulator run can't actually reach a Pi's
fallback AP), select your team under Signing & Capabilities if this is
the first time, and Run.

`make build` builds for the Simulator with code signing disabled --
useful as a quick compile check. Unlike Bluetooth, the Simulator *can*
meaningfully exercise this app's networking, since it shares the Mac's
own network stack: pointed at a Pi's real address it can complete actual
HTTP requests, and mDNS discovery works too if the Mac itself is on the
same network as a Pi (it can't join a Pi's fallback AP itself, of
course, since that's a real WiFi join). `make generate` regenerates
`Aipicam.xcodeproj` from `project.yml` without building or opening
anything; `make clean` removes it again along with `DerivedData`.

## Discovery

Finds a Pi automatically via mDNS/Bonjour: `HTTPManager.swift`'s
`startDiscovery()` browses for "_aipicam._tcp" (the service the daemon
advertises -- see pi-bluetooth-configuration-alpine's README,
"Discovery") using `NWBrowser`, then resolves the first match to a real
host:port with a throwaway `NWConnection` (Network framework has no
"resolve without connecting" API for Bonjour endpoints -- confirmed
against Apple's own documented guidance, not guessed) before handing
that address to the same `connectToServer()` a manually-typed address
goes through.

Runs automatically once, for a few seconds, whenever the address-entry
screen appears (app launch, or returning to it after a disconnect); a
match connects immediately with no tap needed, and "Search Again" on the
resulting "No Pi found" screen re-runs it on demand. Manual address
entry stays available the whole time as a fallback -- for the rare
network that blocks mDNS multicast, or if nothing was found in time.

**Verified against a real (test) mDNS advertisement**: this discovery
code was run in the iOS Simulator (which shares the Mac's own network,
so it could actually reach a real mDNS responder) against a standalone
instance of pi-bluetooth-configuration-alpine's own `mdns_responder.hpp`
advertising a fake service, confirming the full browse → resolve →
connect path produces a correct, usable address end-to-end -- not just
that it compiles. One real bug this actually caught:
`NWEndpoint.Host`'s string form can carry a `%en0`-style zone-ID suffix
that isn't valid in a URL host, stripped explicitly in `resolve()` as a
result.

## Protocol

Talks directly to the HTTP API documented in
[pi-bluetooth-configuration-alpine's README](https://github.com/jacohanekom/pi-bluetooth-configuration-alpine)
("HTTP API") -- `Models.swift` has the exact JSON shapes,
`HTTPManager.swift` the routes it calls. This client doesn't add any
protocol of its own; the last-used address is remembered (`UserDefaults`)
so relaunching after setup reuses it automatically (discovery, if it
finds the same Pi again first, will overwrite it with a freshly-resolved
one anyway).

## Known limitations (v1)

- One server address at a time -- connecting to a new one disconnects
  from the previous one. No persisted list of previously-seen Pis.
- Discovery only ever acts on the *first* match found -- if more than
  one aipicam Pi is on the same network, there's no picker; whichever
  one answers first wins. Rare in practice (this is a single-device
  setup tool), but worth knowing if you're provisioning several at once.
- No automatic recovery from an address change *mid-connection*: if the
  Pi's fallback AP disappears mid-setup (see "Using it" above) or a
  Reset puts it back into AP mode, the app doesn't keep watching for it
  to reappear -- you return to the address-entry screen and search
  again (or enter its address manually) once it's back.
- No authentication or encryption at all -- see Security above.
- CI's `aipicam-unsigned.ipa` (see "Download a prebuilt .ipa" above) is
  genuinely unsigned -- resign it yourself with a sideloading tool
  before it'll install, or use the TestFlight workflow below instead if
  you have an Apple Developer Program membership.
