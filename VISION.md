# Tuner — Vision

A native SwiftUI music client for iOS, iPadOS and macOS. It plays your self-hosted Navidrome/Subsonic library and internet radio, with an Apple Music–style UI and Spotify Connect–style device handoff.

**Audience:** me first, open source second. **Repo:** private until v1, license decided then.
**Design rule:** it should feel like Apple Music, not Spotify. Take Spotify's *features* (gestures, handoff, smart shuffle) and leave its *design*.

## Platforms
- **v1:** iOS 27, iPadOS 27, macOS 27. Only the newest APIs: Observation, SwiftData, Liquid Glass.
- **v1.1:** tvOS (exploring).
- **Not planned:** CarPlay, watchOS, visionOS (I don't have the hardware). Windows: no.
- **Far future, maybe:** a Linux GTK app. Keep core logic in a UI-free Swift package so that stays possible, but don't design for it now.

## Sources
Music only, no podcasts. Library and Radio are **separate sections**, like Apple Music's Radio tab.
1. **Navidrome / OpenSubsonic.** One server with multiple URLs (LAN / remote), switching automatically to whichever responds.
2. **Radio Browser** (`all.api.radio-browser.info`, with the server picked by DNS lookup).
3. **Later, needs thought:** Jellyfin, local files. Put sources behind a `MusicSource` protocol so these can be added without a rewrite.

## v1 scope: Player + Radio

### Playback
- Gapless playback.
- ReplayGain / loudness normalization (track and album).
- Choose original lossless or transcoded stream, with separate settings for Wi-Fi and cellular.
- Queue that works like Apple Music's.
- Offline downloads.
- Now Playing integration: Control Center, Lock Screen, media keys, AirPods.
- **Not in v1:** crossfade, Auto-DJ (both planned, large pieces of work).

### Library & UI
- Apple Music–style browsing: albums, artists, playlists, songs, search.
- **Home / For You:** recently played, rediscover, mixes built from server data and ListenBrainz.
- **Gestures:** swipe a row to queue it, swipe album art to skip, long-press previews, drag to reorder.
- **Smart shuffle / radio:** continue with similar tracks (Navidrome similar songs, ListenBrainz, Last.fm with a free API key).
- **Synced lyrics** (OpenSubsonic) and an animated, blurred-artwork Now Playing.
- Scrobbling goes **through Navidrome** (`scrobble` endpoint). Navidrome forwards plays to Last.fm and ListenBrainz itself.

### Radio (inspired by [Pladio](https://pladio.app/))
- Parse ICY stream metadata and look up artist, title and cover art for a rich Now Playing.
- ShazamKit identify, plus **"find in my library"**: jump to the track or artist on Navidrome.
- Power search (codec, bitrate, country, tags, comparisons like `bitrate >= 128`) and custom stream URLs.
- Not in v1: sleep timer, alarms.

### macOS
- A full window like Music.app (a real Mac app, not one that looks like Catalyst): sidebar, keyboard shortcuts, multiple windows.
- Menu bar mini player.
- Can act as the handoff host / "living room speaker".
- v1 aims for feature parity with iOS. After v1 the Mac gets *much* fuller features, for example dragging tracks from the library into Finder and other apps.

## Device handoff & remote control
- **v1 (LAN-only), two things:**
  1. **Remote control:** a phone controls a Tuner instance on the Mac (discovery over Bonjour).
  2. **Seamless move:** take the queue and position from one device and resume on another. Candidate building blocks: Subsonic `savePlayQueue`/`getPlayQueue` and a direct LAN transfer.
- **Still to figure out:** external targets (AirPlay is mostly free through the system; Chromecast, Sonos, UPnP), working away from home (would need a relay), and Navidrome jukebox mode.

## State & sync
- Music state (stars, ratings, playlists, play queue, scrobbles) lives on **Navidrome**.
- App-only state (radio favorites, custom stations, settings) syncs through **iCloud / CloudKit**.
- **Future (not v1):** a Navidrome extension or a small self-hosted state service, so state isn't locked to iCloud if non-Apple clients ever exist.

## Related projects to study
| Project | Why look |
|---|---|
| [Cassette](https://github.com/CassetteLab/cassette) | Closest overlap: Swift, Apple Music UI, iOS + macOS (MPL-2.0) |
| [Amperfy](https://github.com/BLeeEZ/amperfy) | Mature Swift client: gapless playback, offline, ReplayGain |
| [flo](https://github.com/kepelet/flo) | Swift Navidrome client (MIT) |
| [mpvg](https://github.com/sanhuesoft/mpvg) | Bit-perfect CoreAudio / mpv playback engine |
| [Shelv](https://github.com/gatzenga/Shelv) | Minimal native client, iCloud sync |
| [Agin Music](https://github.com/aginrocks/agin-music-mobile) | Feature ideas |
| [Musly](https://github.com/dddevid/Musly) | Flutter app with an Apple Music–style UI |
| Arpeggi, Minidisc | Praised UI and queue (Arpeggi); Apple Music styling (Minidisc) |
| [Pladio](https://pladio.app/) | Radio UX reference (closed source) |
| [RadioBrowserKit](https://swiftpackageregistry.com/phranck/RadioBrowserKit) | Existing Swift Radio Browser client |

## Open questions
- Audio engine: AVQueuePlayer (gapless is doable) or AVAudioEngine (needed later for crossfade, EQ and Auto-DJ). Decide early so crossfade can be added without rewriting playback.
- Handoff protocol design: transport, discovery, and conflicts when two devices are playing.
- Whether Jellyfin music support is worth doing.
- A Mac UI that goes beyond the iOS app after v1.
