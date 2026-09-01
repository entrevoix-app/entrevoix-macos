# Gates: STT upload formats

OWNS: Sources/EntrevoixCore/**, Sources/EntrevoixOpenAIAdapters/**, Tests/EntrevoixCoreTests/**, Tests/EntrevoixAdapterAPITests/**, Package.swift, GATES.md

Scope: Persist the selected STT upload format and send valid, cleaned WAV, M4A/AAC, or FLAC uploads.

- [x] G1: selected formats persist and assemble into the correct multipart upload
  CHECK: swift test -Xswiftc -warnings-as-errors && echo "shared format tests passed"
  EXPECT: shared format tests passed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/Documents/Repositories/entrevoix/entrevoix-shared; path=cbec899744d6/21 entries; EXPECT=matched; output-sha256=50d228d152dad02f6eea868315ad0176455082d67270801eb74b1b2f90b62301; output-bytes=18213

- [x] G2: the shared package builds without warnings
  CHECK: swift build -Xswiftc -warnings-as-errors && echo "shared format build passed"
  EXPECT: shared format build passed
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/d9beud/Documents/Repositories/entrevoix/entrevoix-shared; path=cbec899744d6/21 entries; EXPECT=matched; output-sha256=62ae5f4b45df116672530cc3a8d9672f5093dac2b6ae4ef930f4a6c7e4a0ee10; output-bytes=146
