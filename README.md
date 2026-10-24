# Bastion for iPhone

A private browser that puts you in control: private meta-search ranked on the phone, ad, tracker and malware blocking with a breakdown of every page, a YouTube ad shield, Web history (the Wayback Machine), and a home page of your own news, channels and live streams. No accounts, no telemetry.

This is the iOS build of [Bastion](https://github.com/sosejjdawgg) (the Android app). It does everything Android v0.8 does, apart from the differences listed under **iOS differences** below.

## Install (sideload)

Each push to `main` builds an unsigned `Bastion.ipa` on GitHub's Mac build servers and publishes it under **Releases → latest**.

**Sideloadly (Windows or Mac)**
1. Install [Sideloadly](https://sideloadly.io) and plug your iPhone into the computer.
2. Download `Bastion.ipa` from the latest release and drag it into Sideloadly.
3. Enter your Apple ID and press **Start**. Sideloadly signs the app with your own free developer certificate.
4. On the iPhone, go to **Settings → General → VPN & Device Management**, tap your Apple ID and choose **Trust**.
5. On iOS 16 or later, turn on **Settings → Privacy & Security → Developer Mode** and restart the phone when it asks.

**AltStore**
1. Install AltServer on your computer and AltStore on the iPhone ([altstore.io](https://altstore.io)).
2. Open `Bastion.ipa` with AltStore (**My Apps → +**).
3. AltStore re-signs the app in the background every 7 days, while your computer is on the same Wi-Fi.

With a free Apple ID the app has to be re-signed every **7 days**. AltStore does this automatically; with Sideloadly, run it again. A paid Apple Developer account ($99 a year) makes a signature last a year.

## iOS differences

- **Blocking runs through Safari's content-blocking engine.** iOS lets apps block requests only through WebKit content rules, so Bastion compiles its filter lists (EasyList, EasyPrivacy, uBlock filters, Peter Lowe, URLhaus, NoCoin and the curated tracker map, about 149,000 rules) into roughly 120,000 Safari rules.
  - The first compile takes a few seconds after installing, and after each filter-list update. After that it's cached.
  - Cosmetic filters, scriptlets and the YouTube shield run as page scripts, the same as on Android.
- **The privacy report is built differently.** Safari doesn't say which requests it blocked, so a small reporter lists what each page *tried* to load. Bastion then scores that list with the same engine the Safari rules came from.
- **There's no system-wide DNS blocking.** It needs a Network Extension, which Apple only allows with a paid developer account.
- **Third-party cookies** are handled by WebKit's Intelligent Tracking Prevention, which is always on.

## Build

- `Core/` is a Swift package with the shared logic: feed parsing, the source resolver, curation and filtering, the filter engine and Safari-rule converter, Wayback, search, geo, and live and episode probes. It has no UIKit dependency and is tested with `swift test`, which runs on macOS and Linux.
- `App/` is the SwiftUI app.
- `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. To build locally, run `xcodegen generate` and open `Bastion.xcodeproj`.
- `.github/workflows/ios.yml` runs the core tests, then builds an unsigned release `.ipa` and publishes it.
