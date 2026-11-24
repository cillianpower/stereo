# Stereo

Native SwiftUI Navidrome/OpenSubsonic + internet radio client for iOS, iPadOS and macOS 27.
Vision: `VISION.md`. Architecture: the "Stereo — Architecture" doc.

## Layout
- `StereoKit/` — local Swift package, UI-free core + `StereoUI`
  - `StereoModel` domain types, `PlayQueue` · `SubsonicClient` API, auth, LAN/remote failover
  - `RadioBrowserClient` · `StereoRadio` power search, stream prober, artwork enrichment
  - `StereoStore` GRDB index + FTS5, stations, `LibrarySyncer` · `StereoPlayback` gapless AVAudioEngine player, ReplayGain, track cache, `PlayerController`
  - `StereoSystem` Now Playing / remote commands · `StereoUI` views and `AppModel`
- `Apps/` — thin iOS and macOS app targets. `project.yml` → `xcodegen generate` → `Stereo.xcodeproj`.

## Build & test
```sh
xcodegen generate
cd StereoKit && swift test                       # unit tests
scripts/make-test-library.sh /tmp/stereo-music   # then point a Navidrome at it
STEREO_IT_URL=http://127.0.0.1:4533 STEREO_IT_USER=… STEREO_IT_PASS=… swift test --filter IntegrationTests
```
Debug builds sign in automatically when `STEREO_DEV_URL`, `STEREO_DEV_USER` and `STEREO_DEV_PASS` are set
(for the simulator, prefix them with `SIMCTL_CHILD_`).
