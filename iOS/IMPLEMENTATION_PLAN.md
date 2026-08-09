# Tiny Cloud Music iOS Execution Plan

## 1. Goal And Fixed Constraints

Build a native iPhone version of the current Tiny Cloud Music app without changing the macOS project or removing any user-facing capability.

- Device baseline: iPhone 13 Pro (390 x 844 pt), portrait-first with landscape support.
- Compatibility: `IPHONEOS_DEPLOYMENT_TARGET = 18.0`; build with Xcode 26.3 / iOS SDK 26.2 and avoid APIs newer than iOS 18 unless guarded.
- Project boundary: every new or adapted file lives under `iOS/`. Existing `Package.swift`, `Sources/`, `Tests/`, `Checks/`, resources, and docs remain read-only.
- Security boundary: production credentials are constructed only by the iOS composition root. Tests use in-memory credentials or unique isolated Keychain services. No authenticated or mutating live check runs without explicit authorization.
- Parity baseline: repository commit `891fcb17906e518bb04bd9569ba34a53502a1ec9` plus the current worktree at the start of iOS implementation.

## 2. Architecture

Use the smallest structure that keeps the macOS tree untouched:

```text
iOS/
  TinyCloudMusicIOS.xcodeproj
  project.yml
  TinyCloudMusicIOS/
    App/
    Platform/
    UI/
    Assets.xcassets/
  TinyCloudMusicIOSTests/
  design-system/
```

- Generate one native Xcode app target and one unit-test target with XcodeGen; commit the generated project so normal Xcode use does not require regeneration.
- File-reference cross-platform models, repositories, transport, cache, download/upload engines, and controllers from `../Sources/TinyCloudMusic` when they compile unchanged.
- Exclude AppKit composition/UI and macOS NIM binaries. Put every necessary iOS replacement in `iOS/TinyCloudMusicIOS`.
- Keep Nuke pinned to 13.0.6 through Xcode Swift Package Manager, matching the macOS dependency.
- Use no additional runtime dependency except the official iOS NIM SDK required for Together realtime transport.

## 3. Complete Feature Parity Matrix

Each row is complete only when the entry is reachable, its loading/empty/error/cancel states work, and an offline test or deterministic build check covers its platform logic.

| Domain | Required iOS capability | Primary iOS surface |
| --- | --- | --- |
| App shell | Five-tab phone navigation, typed deep navigation, mini player, toast/alert/sheet routing | App, Root, Router |
| Home | Configurable recommendation sections, independent retry, account refresh | Discover |
| Search | Default term, hot search, suggestions, direct multi-match, songs/artists/albums/playlists/users/MV/video scopes, pagination | Search |
| Details | Artist, album, playlist, user, song metadata; related artists/playlists/songs; user relations | Navigation destinations |
| Player | Queue creation, next/previous, seek, volume, repeat, shuffle, heart mode, prebuffer, cache-first playback, 0-12 s crossfade | Mini Player, Now Playing |
| Playback metadata | Main/translated/word lyrics, active-line follow, availability/trial state, alternate versions, quality switching | Now Playing |
| System playback | Background audio, interruption/route handling, lock-screen metadata, remote commands, Now Playing artwork | iOS audio coordinator |
| Personal FM | Continuous queue, skip, trash/dislike, playback handoff | Media |
| Comments | Read, thread/replies, emoji rendering, publish, reply, like, delete, report, login gating | Song/video detail |
| Music library | Daily recommendations, liked songs, playlists, subscribed albums/artists/users, recommended users | Library |
| Playlist management | Create/delete, subscribe, add/remove songs, metadata, cover, playlist/song order, privacy | Playlist screens/sheets |
| History and memory | Recent songs/albums/playlists/video/voice, recommendation history, first-listen memory | Library |
| Reports | Today/week/month/year listening footprints and annual reports | Library |
| Cloud music | List/detail, lyric/download, upload, upload progress/recovery | Library |
| Downloads | Audio/video queue, progress, pause/resume/cancel/retry, artwork/lyrics, cache management, Files share/export | Library/Account |
| Video | Recommendations, MV/video detail, native playback, quality, related video, collect, comments, download | Media |
| Audio content | Podcast/radio discovery, subscriptions, podcast/episode/channel detail, episode lyrics/playback | Media |
| Uploads | Cloud and podcast audio selection, validation, multipart/resume, progress, cancellation, reconciliation | Library/Media |
| Music knowledge | Styles, style detail, sheets/image/PDF preview and save, encyclopedia/UGC summaries | Media/details |
| Account | Native QR login, official WebKit fallback, session restore/refresh/logout, VIP credential validation | Account |
| Together | Create/join/invite, room recovery, realtime commands, queue/version sync, heartbeat, reconnect, teardown | Now Playing sheet |
| Settings | Appearance, playback/download/video quality, crossfade, concurrency, home sections, storage/cache controls | Account |

Desktop-only presentation is translated, not removed: Finder reveal becomes Files share/export; separate windows become pushed, sheet, or full-screen destinations; menu-bar controls become mini player, lock-screen controls, and remote commands.

## 4. Platform Replacements

| macOS dependency | iOS replacement |
| --- | --- |
| `NSApplication` / windows / menu bar | SwiftUI `App`, scenes, tabs, sheets, full-screen covers |
| `NSViewRepresentable` WebKit/video/PDF | `UIViewRepresentable` / native SwiftUI wrappers |
| `NSImage`, `NSColor`, `NSPasteboard` | `UIImage`, semantic `Color`, `UIPasteboard` / `ShareLink` |
| `NSOpenPanel`, `NSSavePanel`, Finder reveal | `fileImporter`, `fileExporter`, document picker, share sheet |
| `NSAccessibility.post` | SwiftUI accessibility state plus UIKit announcement where required |
| desktop AVPlayer lifecycle | `AVAudioSession`, interruption/route observers, background audio, MediaPlayer commands |
| macOS NIM dylibs | official NIM iOS SDK adapter implementing `ListenTogetherRealtimeTransport` |

## 5. Execution Phases And Gates

### Phase A - Environment And Project

1. Install XcodeGen only; do not add Tuist, CocoaPods, Carthage, Mint, or lint frameworks unless the official NIM distribution requires one.
2. Generate the independent app/test project, assets, Info settings, background-audio entitlement, privacy usage strings, and an unsigned simulator scheme.
3. Create shutdown iPhone 13 Pro simulators for iOS 18.0 and 26.2 using Apple's signed runtimes.

Gate: project lists cleanly in `xcodebuild`; a minimal app builds unsigned for iPhone 13 Pro; non-`iOS/` Git diff is empty.

### Phase B - Shared Core And Platform Services

1. Add shared source references in dependency order and replace only files that fail on iOS.
2. Add iOS composition root, isolated credential tests, application directories, audio session, MediaPlayer, WebKit, QR image, clipboard/share, document picker, PDF, and video adapters.
3. Integrate official iOS NIM SDK and implement the existing realtime protocol. Never embed the macOS dylibs.

Gate: all core targets compile for iOS 18 deployment; transport/parser/cache/controller tests pass; Together transport has deterministic adapter tests.

### Phase C - Native Phone UI

1. Build the shell, typed router, mini player, Now Playing, home, and search.
2. Port details, comments, library/mutations, history/reports, cloud/downloads/uploads.
3. Port video, podcasts/radio, Personal FM, music knowledge, account/login, Together, and settings.
4. Apply the design master to every screen; preserve all state and error behavior from macOS.

Gate: every row in the parity matrix is reachable on a guest-safe simulator; no placeholder or disabled parity route remains.

### Phase D - Verification

1. Run warnings-as-errors simulator builds and offline unit tests with code signing disabled.
2. Run UI smoke tests for all routes using in-memory/fixture data; never use the production Keychain.
3. Inspect iPhone 13 Pro screenshots in portrait/landscape, light/dark, default/largest Dynamic Type, and reduced motion.
4. Build against deployment target 18.0 under SDK 26.2; also run on iOS 18.x and 26.2 runtimes when both are locally available.
5. Recheck that `git diff -- . ':!iOS/**'` is empty.

Gate: clean build/tests, visual/accessibility checklist complete, no macOS file changed.

### Phase E - Physical iPhone Handoff

1. User selects their Apple Development Team and unique bundle identifier in Xcode.
2. User connects/trusts the iPhone 13 Pro and enables Developer Mode if required.
3. Build/install from Xcode. Any authenticated account or mutating live verification requires a separate explicit authorization for that exact run.

Gate: signed app launches on the user's iPhone 13 Pro and guest-safe workflows pass. Authenticated parity remains unclaimed until separately authorized and verified.

## 6. Known External Blockers

- The official NIMSDK_LITE/NOS 10.9.40 iOS SDK is integrated and compiles for Simulator and arm64 devices. Its acceptance of production Together credentials, callback ordering, and reconnect behavior still require a separately authorized authenticated device check.
- Automatic signing and physical-device installation depend on the user's Apple account/team, device trust, and Developer Mode. These cannot be completed by an unsigned automated build without accessing user credentials or changing external developer-portal state.
- The signed iOS 18.0 (22A3351) and iOS 26.2 (23C54) runtimes are installed with matching shutdown iPhone 13 Pro simulators. Runtime and screenshot verification remains an explicit gate because neither simulator has been launched.

No blocker is resolved by hiding or deleting the corresponding feature. A blocked feature remains an explicit open gate.
