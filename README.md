# Tuner

Native SwiftUI Navidrome/OpenSubsonic + internet radio client for iOS, iPadOS and macOS 27.
Vision: `VISION.md`. Architecture: the "Tuner — Architecture" doc.

## Layout
- `TunerKit/` — local Swift package, UI-free core + `TunerUI`
  - `TunerModel` domain types, `PlayQueue` · `SubsonicClient` API, auth, LAN/remote failover
  - `RadioBrowserClient` · `TunerRadio` power search, stream prober, artwork enrichment
  - `TunerStore` GRDB index + FTS5, stations, `LibrarySyncer` · `TunerPlayback` gapless AVAudioEngine player, ReplayGain, track cache, `PlayerController`
  - `TunerSystem` Now Playing / remote commands · `TunerUI` views and `AppModel`
- `Apps/` — thin iOS and macOS app targets. `project.yml` → `xcodegen generate` → `Tuner.xcodeproj`.

## Build & test
```sh
xcodegen generate
cd TunerKit && swift test                       # unit tests
scripts/make-test-library.sh /tmp/tuner-music   # then point a Navidrome at it
TUNER_IT_URL=http://127.0.0.1:4533 TUNER_IT_USER=… TUNER_IT_PASS=… swift test --filter IntegrationTests
```
Debug builds sign in automatically when `TUNER_DEV_URL`, `TUNER_DEV_USER` and `TUNER_DEV_PASS` are set
(for the simulator, prefix them with `SIMCTL_CHILD_`).
