# ADR 0014 — Shared package integration

Status: implemented

## Decision

The macOS executable depends on exact, tagged products from the public
`entrevoix-shared` Swift package: `EntrevoixCore`,
`EntrevoixOpenAIAdapters`, and `EntrevoixAppleAdapters`. The repository no
longer carries copies of their production source. Its `EntrevoixCoreTests`
target remains as a consumer-side regression suite for the resolved core.
`Package.resolved` records the selected immutable version.

The macOS repository retains presentation and macOS-specific system adapters,
including Accessibility delivery, global shortcuts, Sparkle, launch at login,
and Codex OAuth. Codex OAuth owns its Keychain and same-origin redirect helpers
because those are not part of the shared provider adapters.

## Consequences

`entrevoix-shared` owns the portable domain, application orchestration, and
Apple/OpenAI-compatible adapters. Its releases are versioned independently from
macOS Sparkle releases. This repository checks the shared core and selected
adapter coverage from the resolved package checkout. The consumer-side core test
suite keeps the existing 85% core coverage gate, while the shared package
validates the package itself on macOS and iOS.
