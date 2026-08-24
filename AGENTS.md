# Entrevoix — Agent Instructions

Entrevoix is a privacy-conscious macOS 26 menu-bar dictation app. It records speech, sends it to an OpenAI-compatible speech-to-text (STT) endpoint, optionally cleans the transcript through an OpenAI-compatible text endpoint (TTT), then copies or inserts the result into the active app.

The repository is a Swift Package Manager project with no Xcode project. `Package.swift` uses Swift tools 6.2; development and CI currently use Xcode 26, Swift 6.3, and the macOS 26 SDK.

## Product behavior

- The app is a `MenuBarExtra` with no Dock icon (`LSUIElement = true`). Settings, logs, and onboarding are separate SwiftUI windows whose default launch behavior is suppressed.
- Dictation supports push-to-talk and toggle shortcuts, with a 150 ms debounce. Escape cancels an active permission request, recording, or transcription.
- The state machine is `idle -> requestingPermission -> recording -> transcribing -> idle/error`. Cleanup runs while the state remains `transcribing`.
- Recordings are 16 kHz mono PCM WAV files. Dictations shorter than 250 ms are rejected and a 10-minute watchdog stops long recordings.
- While recording, a non-activating floating indicator follows the caret and reacts to the microphone level. Its label changes from Listening to Transcribing and, when enabled, Improving text.
- Output is either clipboard-only or automatic insertion. Secure fields and missing Accessibility permission always fall back to copying.
- The UI is localized in English and French (`en`, `fr-FR`). Users can follow the system language or override it live without relaunching the app.
- First launch opens a five-step onboarding flow. The app also exposes STT connection testing, permission controls, launch at login, sound feedback, in-memory logs, and Sparkle updates.

## Commands

| Task | Command |
|------|---------|
| Build | `swift build` |
| Build as CI | `swift build -Xswiftc -warnings-as-errors` |
| Test as CI | `swift test -Xswiftc -warnings-as-errors` |
| Test with coverage gates | `./Scripts/check-coverage.sh` |
| Build, sign, verify, and launch the development app | `./Scripts/run-app.sh` |
| Assemble without launching | `ENTREVOIX_SKIP_OPEN=1 ./Scripts/run-app.sh` |
| Verify an assembled app | `./Scripts/verify-app-bundle.sh "$(swift build --show-bin-path)/Entrevoix.app"` |
| Build, sign, notarize, and report the digest of a release DMG | `./Scripts/release.sh` (requires release environment variables) |

**Never use `swift run Entrevoix` to validate application behavior.** It launches a raw executable without the app's `Info.plist`, entitlements, embedded frameworks, compiled localization catalogs, stable code signature, or LaunchServices behavior. Use `./Scripts/run-app.sh`.

## Git branches

- Name new branches `d9beuD/<type>/<description>`; do not use the `codex/` prefix.

A full Xcode installation is required for tests (`XCTest`) and app assembly (`xcstringstool`). Command Line Tools alone are insufficient. If necessary, select Xcode with `xcode-select` or `DEVELOPER_DIR`.

Before rebuilding the development `.app`, `run-app.sh` stops every running Entrevoix instance, including instances launched from another development environment, so it can safely replace and launch the requested bundle.

## Hexagonal architecture and package structure

Entrevoix uses a lightweight hexagonal architecture while intentionally retaining two
production SwiftPM targets. The targets provide the module boundary; folders make
the four logical layers explicit:

```text
Sources/EntrevoixCore/
  Domain/                 # pure entities, value objects, rules, errors, migrations
  Application/            # use cases, orchestration, application state snapshots
    Ports/                # outbound technical boundaries

Sources/Entrevoix/
  App/                    # @main, scenes, composition root, global configuration
  Presentation/           # SwiftUI views, @Observable stores, AppKit presentation
  Adapters/               # concrete system, network, persistence, and IO adapters
  Resources/
```

Dependencies always point inward: `Presentation -> Application -> Domain`;
`Adapters -> Application / Domain`; and `App` is the only layer permitted to
assemble all layers. `EntrevoixCore` must not import SwiftUI, Observation, AppKit,
AVFoundation, Security, URLSession, or any other UI/platform/technical framework.
Foundation and Swift Concurrency are permitted there. Do not add a third target
unless a subsystem has an independently managed lifecycle, meaningful reuse, or a
genuine independent dependency boundary.

SwiftUI is an incoming adapter. Views are declarative and thin: they render state,
collect input, and make a single call to an injected Store. Feature Stores are
`@MainActor @Observable`, own UI state exactly once, and delegate business work to
application use cases. Use `@State` for view-local drafts/navigation and
`@Bindable` only for editable Store state. Do not put validation, persistence,
networking, request assembly, or multi-step business workflows in a view.

Application services and coordinators are non-observable. They expose immutable
`Sendable` snapshots and typed lifecycle events for Presentation to interpret.
Define a protocol only for a real technical boundary (audio, permissions,
transcription, cleanup, delivery, preferences, Keychain, logging, hotkeys, or a
macOS service); keep test seams internal to an adapter when they do not cross that
boundary. Concrete adapters belong under `Adapters/`; visual AppKit integrations,
including the listening indicator, belong under `Presentation/`.

## Package structure

- `Sources/EntrevoixCore/` — reusable `Domain` and `Application` code plus outbound ports. It has no UI or concrete infrastructure dependency.
- `Sources/Entrevoix/` — executable target containing the app composition, presentation Stores/views, and live adapters.
  - `App/` — `EntrevoixApp`, `CompositionRoot`, `AppEnvironment`, scene wiring, diagnostics, and localization.
  - `Presentation/` — menu bar, settings, onboarding, logs, listening indicator, error adaptation, and observable Stores.
  - `Adapters/` — Accessibility, audio, cleanup, delivery, hotkeys, networking, persistence, Keychain, system services, and transcription implementations.
  - `Resources/` — `Localizable.xcstrings` and `InfoPlist.xcstrings`.
- `Tests/EntrevoixCoreTests/` — domain and coordinator tests.
- `Tests/EntrevoixTests/` — application, localization, feature, and infrastructure tests.
- `Configuration/Info.plist` — bundle identity, menu-bar mode, microphone usage text, Sparkle configuration, and supported localizations.
- `Configuration/Entrevoix.entitlements` — signing entitlements; the app is currently distributed outside the App Sandbox.
- `Scripts/` — development app assembly, bundle verification, coverage, DMG construction, and release/notarization.
- `docs/adr/` — milestone decisions and architectural rationale. Treat older “awaiting validation” notes as historical when newer code/tests/scripts supersede them.

## Architecture and runtime flow

- Entry point: `Sources/Entrevoix/App/EntrevoixApp.swift` (`@main`).
- `CompositionRoot.makeLaunchState()` is the only place that builds the live object graph. Keep concrete adapter construction there.
- `AppEnvironment` owns the shared feature Stores and application services. It is the ready result injected into scenes; it is not observable itself.
- `DictationCoordinator` and `ConnectionTestCoordinator` are `@MainActor` application services. They own session state, cancellation/stale-session protection, cleanup, and typed snapshots/events; they never import Observation or know about views, panels, sounds, or localized labels.
- Feature Stores own UI orchestration such as hotkey semantics, live language changes, permission refreshes, feedback sounds, and indicator transitions. Do not allow a connection test and dictation to run together.
- Core dependencies enter through application dependency values and ports. Add a port only for a real external boundary, not merely because a test needs a double.
- UI-facing types and all adapters touching AppKit, Accessibility, pasteboard, hotkeys, windows, or permissions stay on `@MainActor`. Domain values crossing concurrency boundaries must be `Sendable`.
- Coordinator lifecycle callbacks drive presentation effects. Keep the indicator and sounds outside `EntrevoixCore`; the core should not know about panels, AppKit, or localized labels.

## Platform lessons and invariants

### App bundle, signing, and TCC

- A real `.app` bundle is required for windows, global shortcuts, microphone permission, Accessibility permission, localization, Sparkle, and launch-at-login behavior.
- Keep `CFBundleIdentifier` stable (`com.d9beuD.Entrevoix`) and sign the development app with a stable identity when available. Ad hoc signatures can make macOS treat rebuilds as a different Accessibility client, requiring permission to be renewed.
- Apply `Configuration/Entrevoix.entitlements` when signing both development and release builds. Missing or inconsistent entitlements/signatures can make TCC permission appear granted while Accessibility calls still fail.
- `run-app.sh` and `build-dmg.sh` must embed `Sparkle.framework`, add `@executable_path/../Frameworks`, copy SPM resource bundles, compile string catalogs, and sign the final hierarchy. Do not “simplify” away those steps.
- After changing packaging, signing, localization, dependencies, or `Info.plist`, assemble with `ENTREVOIX_SKIP_OPEN=1` and run `verify-app-bundle.sh`. It checks Sparkle linkage/rpath, compiled English/French resources, runtime localization lookup, and the code signature.

### Accessibility, insertion, and the listening indicator

- `FocusedTextElementResolver.shared` is the common source of focus truth for delivery and indicator positioning. Keep their candidate-resolution behavior aligned.
- Focus information is unreliable across apps: the system-wide focused element can lag behind the frontmost application, especially in Firefox, Chromium, and Electron. The resolver enables web accessibility, checks application/window focus first, walks editable ancestors, and uses a bounded descendant search. Preserve the traversal bounds and short AX messaging timeout.
- Native editable controls may use `AXSelectedText` replacement. Web editors (`AXGroup`, `AXGenericElement`, or `AXWebArea` ancestry) must use clipboard plus a synthetic Command-V event; direct AX replacement is not dependable for contenteditable controls.
- Never insert through Accessibility into secure/password fields. Copy instead. If focus resolution or paste event posting fails, retain the transcript on the clipboard and return a typed fallback result.
- Caret anchoring is progressively resolved: selected-text bounds, browser text-marker bounds, adjacent-character bounds, focused-control frame, then pointer fallback. The last good non-fallback anchor is retained while the indicator is visible to avoid visual jumps.
- The indicator must remain a borderless, non-activating, click-through `NSPanel`; it must never steal key focus from the destination app. It follows all spaces, clamps to the visible screen, polls position at a bounded interval, and cancels position/audio tasks when hidden.
- Keep indicator logs diagnostic-only: anchor source and safe AX summaries are allowed; focused text, transcripts, and control values are not.

### Localization and preferences

- User-visible strings belong in `Sources/Entrevoix/Resources/Localizable.xcstrings`; bundle metadata strings belong in `InfoPlist.xcstrings`. Add both English and French translations and extend `LocalizationTests` when adding required keys.
- Resolve explicit app-language strings through `EntrevoixLocalization` and pass `model.interfaceLocale` into each SwiftUI scene. Using only the process locale or `NSLocalizedString` can prevent live language changes.
- SwiftPM resources live in `Bundle.module`, then inside `Entrevoix_Entrevoix.bundle` in the assembled app. Do not assume localized strings are in `Bundle.main`.
- `AppPreferences` uses versioned `Codable` JSON in `UserDefaults` (`currentSchemaVersion`). New fields need safe decoding defaults and migration behavior for existing installations.
- The default cleanup prompt is localizable while custom and legacy prompts must be preserved. Respect `CleanupPromptMode` when changing language or migrating preferences.
- Provider UUIDs identify their Keychain entries. Preserve or deliberately migrate IDs when editing provider configuration; regenerating an ID disconnects the saved API key.

### Privacy, networking, and logs

- API keys are stored only in macOS Keychain, never in `UserDefaults`, source, fixtures, or logs.
- Audio files live only in the temporary directory and must be deleted after success, failure, or cancellation. Do not commit audio artifacts.
- Networking uses an ephemeral `URLSession`: no persistent cache or cookies, and cross-origin redirects are rejected so authorization headers cannot leak to another origin.
- Entrevoix has no backend of its own. Audio goes only to the configured STT endpoint; transcript text goes to the configured cleanup endpoint only when cleanup is enabled.
- Logs are memory-only. Never log API keys, authorization headers, audio, transcripts, prompts, pasteboard contents, or raw provider bodies. Use redacted safe-error helpers for diagnostics.

## Dependencies

- `KeyboardShortcuts` 1.10.0, exact and tracked in `Package.resolved`.
- `Sparkle` 2.9.5, exact and tracked in `Package.resolved`.
- Networking and audio use Apple frameworks; do not add a third-party HTTP or recording layer without a concrete need.

When changing dependencies, preserve exact pinning unless the task explicitly calls for an upgrade, update `Package.resolved`, and verify the assembled app—not only `swift build`.

## Testing and change discipline

- CI treats warnings as errors and runs on `macos-26`.
- `./Scripts/check-coverage.sh` enforces 85% line coverage for `EntrevoixCore` and 80% for selected testable application/infrastructure logic.
- Prefer deterministic protocol-backed tests over live microphone, network, Keychain UI, Accessibility prompts, global events, or sleeps. Inject clocks/sleep and use spies/fakes already present in test support.
- Add regression tests for state transitions, cancellation, stale sessions, secret/log redaction, preference decoding, localization keys, AX focus variants, secure-field fallback, web-editor paste, and indicator task/position behavior when those areas change.
- Interactive validation is still required for macOS integration: global key down/up in background apps, microphone and Accessibility prompts, caret placement across native/Chromium/Electron apps, sound feedback, launch at login, and Sparkle update UI.
- Preserve unrelated work in a dirty worktree. Do not commit `.build/`, `.swiftpm/`, `DerivedData/`, app bundles, DMGs, audio, certificates, provisioning profiles, API keys, or notarization credentials.
- Repository audits reject tracked audio/signing artifacts and OpenAI-style secret patterns. Keep `.gitignore` and CI audits aligned when adding generated formats.

## Release

- GitHub Release descriptions, including drafts and pre-releases, must be written in English.

- `./Scripts/release.sh` requires `ENTREVOIX_VERSION`, `ENTREVOIX_BUILD_NUMBER`, `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `BUILD_KEYCHAIN_PASSWORD`, `APP_STORE_CONNECT_KEY_BASE64`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`.
- `ENTREVOIX_VERSION` is a semantic version without the `v` prefix; the Git tag uses `v`. `ENTREVOIX_BUILD_NUMBER` is the monotonic Sparkle bundle version.
- Release builds use Hardened Runtime, the same entitlements and embedded resources as development builds, Developer ID signing, notarization, stapling, DMG creation, and SHA-256 output.
- The manual GitHub Actions release workflow also generates and signs `appcast.xml`, uploads it with the DMG, and creates the GitHub release. GitHub reports the DMG's SHA-256 digest. Do not publish a hand-written appcast.
- Keep `SUFeedURL` and `SUPublicEDKey` in `Configuration/Info.plist` valid; the release script rejects placeholders. Follow `docs/RELEASE_CHECKLIST.md` for the human validation steps.
