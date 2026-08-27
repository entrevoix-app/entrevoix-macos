# Gates: startup permission requests

OWNS: Sources/Entrevoix/App/EntrevoixApp.swift, Sources/Entrevoix/Presentation/Stores/AppStore.swift, Sources/Entrevoix/Presentation/Stores/PermissionsStore.swift, Tests/EntrevoixTests/App/AppStoreTests.swift, Tests/EntrevoixTests/Support/TestSupport.swift, GATES.md

Scope: Request macOS microphone and Accessibility authorization automatically once at application launch when each permission is still unresolved, without prompting again after it is granted.

- [x] G0: this ledger states outcomes that can fail
  CHECK: node /Users/d9beud/.agents/skills/unlazy/scripts/gate-lint.mjs GATES.md
  EXPECT: LINT OK
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/.codex/worktrees/21eb/entrevoix-macos; path=677d46ecdfd2/23 entries; EXPECT=matched; output-sha256=48630b7361dd44ee870917b12c3d19b9d7bdea738aaca16bb04d4cab83b772d2; output-bytes=8

- [x] G1: startup permission orchestration requests only unresolved microphone and Accessibility permissions
  CHECK: swift test -Xswiftc -warnings-as-errors --filter AppStoreTests/testRequestsUnresolvedPermissionsAtLaunch && echo "startup permission orchestration tests passed"
  EXPECT: startup permission orchestration tests passed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/.codex/worktrees/21eb/entrevoix-macos; path=677d46ecdfd2/23 entries; EXPECT=matched; output-sha256=4c6cfa7162feeb38631572d9d10f291d676b9aafe15c68c0f610d96f519cd925; output-bytes=1169

- [x] G2: the macOS package builds without warnings after startup permission integration
  CHECK: swift build -Xswiftc -warnings-as-errors && echo "startup permission build passed"
  EXPECT: startup permission build passed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/.codex/worktrees/21eb/entrevoix-macos; path=677d46ecdfd2/23 entries; EXPECT=matched; output-sha256=296721779f811144b7e23db6f2170d484d9955eca811ea12a7500f6c2b69c8e1; output-bytes=151
