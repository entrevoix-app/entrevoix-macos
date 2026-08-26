# Gates: macOS STT upload format settings

OWNS: Sources/Entrevoix/**, Tests/EntrevoixTests/**, Package.swift, Package.resolved, GATES.md

Scope: Expose a localized per-provider STT upload format choice and integrate the released shared dependency.

- [x] G1: the macOS test suite validates provider settings and localization without warnings
  CHECK: swift test -Xswiftc -warnings-as-errors && echo "macOS format tests passed"
  EXPECT: macOS format tests passed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/.codex/worktrees/8b17/entrevoix-macos; path=677d46ecdfd2/23 entries; EXPECT=matched; output-sha256=21759f7fb07da5ea5bc7744cc2f65e817690c2fa94fd0a186275ed1e68a7d093; output-bytes=56077

- [x] G2: the assembled app bundle validates with the released shared dependency
  CHECK: ENTREVOIX_SKIP_OPEN=1 ./Scripts/run-app.sh && ./Scripts/verify-app-bundle.sh "$(swift build --show-bin-path)/Entrevoix.app" && echo "macOS format bundle passed"
  EXPECT: macOS format bundle passed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/.codex/worktrees/8b17/entrevoix-macos; path=677d46ecdfd2/23 entries; EXPECT=matched; output-sha256=5fc856afffe24939f0b2aad1abcb671e8961e72e4f548187cbe69890f5ec6151; output-bytes=4337

- [x] G3: the macOS package builds without warnings
  CHECK: swift build -Xswiftc -warnings-as-errors && echo "macOS format build passed"
  EXPECT: macOS format build passed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/.codex/worktrees/8b17/entrevoix-macos; path=677d46ecdfd2/23 entries; EXPECT=matched; output-sha256=8e7bdf91b65f2f98bfb78585c16e4736bf2416402b22a663c69260ee9293cf89; output-bytes=3134
