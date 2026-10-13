# C2 Native Reader

An independent SwiftUI/TextKit client of ReaderEngine, with bundle ID
`io.legado.pathc.nativereader`. It does not share a sandbox with existing readers
or the C1 harness. C2 covers source import, single-source search, contents,
scrolling text, chapter navigation and typography. Bookshelf, persistent reading
positions, offline reopening and source switching remain outside this slice.

## Deliberate UI defaults

These are product defaults awaiting owner feedback, not recovered Wanyuan values:

- System-available PingFang, Songti and Kaiti candidates; unavailable fonts are omitted.
- 22-point initial text; size range 16–36, line spacing 6 (0–18), paragraph spacing
  12 (0–30), margins 24 (12–64). Maximum text column width is approximately 760 points.
- Warm light background; optional dark appearance. Settings last for the view session.
- Explicit show/hide control button instead of guessed tap regions. Long-press text
  selection follows UITextView behavior. No custom pagination engine.
- A paragraph-based UTF-16 anchor is transient presentation state. Layout changes
  restore it; successful chapter changes reset it. No upstream progress is written.

The existing IPA provides static menu, typography and navigation clues. It does
not establish default values, active interaction wiring or physical iPad comfort.
The approved scope and device acceptance are in local `SPEC-002`; its `docs/`
directory is ignored by the inherited repository policy.

## Build

Use the existing repository JDK/Xcode/native-library setup, then:

```sh
./gradlew --no-daemon --no-watch-fs :engine-ios:linkDebugFrameworkIosSimulatorArm64 :engine-ios:linkDebugFrameworkIosArm64
xcodegen generate --spec native-ios-app/project.yml
xcodebuild -project native-ios-app/NativeReader.xcodeproj -scheme NativeReader \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath native-ios-app/build CODE_SIGNING_ALLOWED=NO build
```

The Xcode configuration selects the simulator or device debug framework by SDK.
Device signing requires an explicitly chosen development team; no identity is
hard-coded. Building does not authorize replacing or installing an existing app.

Package a device build for owner-side signing with:

```sh
python3 scripts/path-c/package_native_ipa.py package \
  native-ios-app/build-device/Build/Products/Debug-iphoneos/NativeReader.app \
  /absolute/path/to/new-candidate.ipa
python3 -m unittest discover -s scripts/path-c -p test_package_native_ipa.py
```

Do not use default `ditto` ZIP packaging: it can add `Payload/._NativeReader.app`.
AltSign selects the first Payload entry with an `.app` suffix without checking
whether it is a directory. On the iOS simulator the original package selected
that AppleDouble file and failed application parsing; the clean package selected
the real bundle and passed. macOS Foundation hides this entry from its directory
listing, so a Mac-only bundle check missed the defect. The packaging script omits
metadata, validates the archive, preserves executable permissions and refuses to
overwrite an existing delivery. This check does not prove device signing/install.

After the owner's physical `-1022` failure and explicit HTTP authorization, build
0.1.0 (2) adds ATS exceptions for the 16 exact HTTP hosts in their 20-source bundle
and three separately owner-approved observed redirect hosts (`www.kk169.la`,
`www.xyetianlian.com`, `www.xbotaodz.info`).
`project.yml` is the authoritative host list. There is no global arbitrary-load
override, wildcard/subdomain exception, lowered TLS version, or custom certificate
trust bypass. Other HTTP hosts, including redirects to unlisted hosts, still need
an explicit policy decision. These transport entries do not rewrite source rules.
Import remains independent of transport reachability and live source correctness.

## Validation status

2026-10-12 local candidate checks:

- Device and simulator debug engine frameworks linked; original Compose UI compiled.
- C1 network / restart / fresh-network suites passed 82/82, 22/22 and 82/82
  observations. These include callback checks, not independent test counts.
- The independent app built for the simulator and, unsigned, for iOS devices.
- Two hosted XCTest cases passed using the real engine and controlled HTTP source:
  import/search/detail/TOC/two-page content, startup cancellation recovery, stale
  search cancellation, chapter cancellation/failure preserving content, successful
  retry, file-provider error isolation, real reader view contents round trip, and
  long Chinese text remaining visible after typography and layout changes.
- The initial directory round-trip check used `scrollRangeToVisible` and observed
  a changing offset. Deterministic nonanimated paragraph positioning passed without
  changing product navigation code. The original timing cause was not independently
  instrumented; this is not evidence of a repaired product navigation defect.

Reproduce the app tests on a dedicated simulator with this fixture running:

```sh
python3 scripts/path-c/c2_fixture_server.py
# In another terminal, after generating the project:
xcodebuild -project native-ios-app/NativeReader.xcodeproj -scheme NativeReader \
  -destination 'platform=iOS Simulator,id=<dedicated simulator UUID>' \
  -derivedDataPath native-ios-app/build CODE_SIGNING_ALLOWED=NO test
```

The C2 fixture binds loopback port 18769; the third chapter fails once per unique
URL namespace to exercise retry, and the second contains long original Chinese
text. Never terminate another process to take that port. C1 uses its existing
fixture ports and separate runner script.

Physical iPad installation, two live community-source journeys, actual split-view
interaction, and owner comfort acceptance remain pending. Host-view resizing and
an unsigned device build do not satisfy those gates. Controlled loopback success
is not a whole-source compatibility claim. Expand `Import details` to compare the
filename, decoded UTF-8 length and hash when a device import differs from a local
test; source contents and credentials are not shown in those diagnostics.
