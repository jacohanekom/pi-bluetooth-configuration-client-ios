# pi-bluetooth-configuration-client-ios

**aipicam** -- an iOS app to configure WiFi on a Raspberry Pi running
[pi-bluetooth-configuration](https://github.com/jacohanekom/pi-bluetooth-configuration-alpine)
over Bluetooth LE, using the iPhone/iPad's own Bluetooth radio. This is
the iOS counterpart to
[pi-bluetooth-configuration-client-mac](https://github.com/jacohanekom/pi-bluetooth-configuration-client-mac)
-- same GATT protocol, same screens, same feature set; `Models.swift` and
`BLEManager.swift` are near-identical ports (CoreBluetooth's central-role
API doesn't differ between the two platforms), and `ContentView.swift`
carries over the same wizard/details-screen logic with iOS-appropriate
chrome (a `NavigationStack` instead of a free-floating window titlebar
button, no fixed window size, autocorrection/autocapitalization turned
off on the SSID/password/IP fields since iOS defaults to fighting all
three).

Scans for nearby devices (shown by hardware serial number, so multiple
units are distinguishable), connects (no pairing -- see Security below),
and walks through a wizard: pick a WiFi network, enter its password,
confirm eth0's local network (gateway IP + DHCP range), then finish --
no SSH, no keyboard on the Pi. Once setup is finished, a details screen
shows WiFi/network stats, relay controls, and Victron solar/battery
telemetry behind three collapsible sections -- see
pi-bluetooth-configuration-client-mac's README, "Using it", for the exact
walkthrough (identical on this platform).

Built with SwiftUI + CoreBluetooth.

This is a one-shot provisioning flow, not a managed session: the Pi
reboots itself a few seconds after **Finish** or a reset (see the
daemon's README, "One-shot provisioning and reboot behavior"). This app
doesn't try to keep managing anything over the network once that
happens, and treats the BLE disconnect that follows the reboot as
expected, not an error.

## Security

There is no pairing, encryption, or authentication anywhere in this
flow. WiFi SSID and password cross BLE in the clear to any device that
connects while the Pi is advertising. This was a deliberate choice made
after BLE pairing/bonding proved unreliable on the Pi 3's hardware (see
the daemon's README, "Security model", for the full reasoning). Use this
only on a trusted home/lab network, during a provisioning window you
control.

## Requirements

- iOS/iPadOS 16 or later, with Bluetooth on
- A Pi running `pi-bluetooth-configuration`, advertising and reachable
- To build: Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)
- To run on a real device (required -- the iOS Simulator has no
  Bluetooth radio at all): an Apple ID signed into Xcode for free
  automatic signing, or a paid Apple Developer Program membership for
  distributing beyond your own devices

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

1. **Create the app record in App Store Connect**, if you haven't
   already: [App Store Connect](https://appstoreconnect.apple.com) →
   Apps → **+** → New App, bundle ID `com.jacohanekom.aipicam`
   (register that bundle ID under Certificates, Identifiers & Profiles
   first if it doesn't already exist -- Xcode does this for you
   automatically the first time you archive locally with your own team
   selected, if you'd rather not do it by hand). Uploads fail outright
   if there's no app record matching the bundle ID yet; nothing in CI
   creates this step for you.
2. **Create an App Store Connect API key**: App Store Connect → Users
   and Access → Integrations → App Store Connect API → **+**. Give it
   the **App Manager** role (not just Developer -- it needs to be able
   to create/renew signing certificates and provisioning profiles on
   its own, non-interactively, via `-allowProvisioningUpdates`).
   Download the `.p8` file **immediately** -- App Store Connect only
   lets you download it once. Note the **Key ID** and **Issuer ID**
   shown on that same page.
3. **Find your Team ID**: [developer.apple.com/account](https://developer.apple.com/account)
   → Membership details, or Xcode → Settings → Accounts → your team.
4. **Add four repo secrets** (Settings → Secrets and variables →
   Actions → New repository secret):

   | Secret | Value |
   |---|---|
   | `APPSTORE_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy`, then paste |
   | `APPSTORE_KEY_ID` | the Key ID from step 2 |
   | `APPSTORE_ISSUER_ID` | the Issuer ID from step 2 |
   | `APPSTORE_TEAM_ID` | the Team ID from step 3 |

5. Push a tag: `git tag v1.0.0 && git push origin v1.0.0` -- or just run
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

pi-bluetooth-configuration-client-mac's `.gitignore` already excludes
`*.xcodeproj` on principle -- a generated project file is a build
artifact, not source, and raw `.pbxproj` diffs are unreviewable noise.
That repo can still ship without one because a plain `swift build`
produces a real, runnable macOS executable on its own. iOS has no
equivalent: there's no SPM product type for an installable, signed `.app`,
and none of the leniency macOS extends to a bare, unsigned CLI binary
(the Mac client's trick of embedding `NSBluetoothAlwaysUsageDescription`
straight into the executable's `__info_plist` section doesn't have an
iOS counterpart -- iOS enforces real app-bundle and code-signing rules
unconditionally). An Xcode project is unavoidable here.

[`project.yml`](project.yml) is the checked-in source of truth instead --
a small, readable, diffable spec that [XcodeGen](https://github.com/yonaskolb/XcodeGen)
turns into `Aipicam.xcodeproj` on demand. The generated project itself
stays out of git, same as the Mac client's philosophy, just one level
removed.

## Build and run

```sh
brew install xcodegen   # one-time
make open               # generates Aipicam.xcodeproj and opens it
```

Then in Xcode: pick your iPhone/iPad as the run destination (not a
Simulator -- see Requirements above), select your team under Signing &
Capabilities if this is the first time, and Run.

`make build` builds for the Simulator with code signing disabled --
useful as a quick compile check, but the resulting build can't actually
talk to a Pi (no Bluetooth radio in the Simulator). `make generate`
regenerates `Aipicam.xcodeproj` from `project.yml` without building or
opening anything; `make clean` removes it again along with `DerivedData`.

## Protocol

Talks directly to the GATT service documented in
[pi-bluetooth-configuration-alpine's README](https://github.com/jacohanekom/pi-bluetooth-configuration-alpine)
-- `Models.swift` has the exact UUIDs and JSON shapes. This client
doesn't add any protocol of its own.

## Known limitations (v1)

- One connection at a time -- connecting to a new device disconnects
  the previous one.
- No persisted list of previously-seen Pis; every launch re-scans.
- No pairing/encryption at all -- see Security above.
- CI's `aipicam-unsigned.ipa` (see "Download a prebuilt .ipa" above) is
  genuinely unsigned -- resign it yourself with a sideloading tool
  before it'll install, or use the TestFlight workflow below instead if
  you have an Apple Developer Program membership.
