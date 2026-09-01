import AVFAudio
import CoreMedia
import Foundation
import Testing
@testable import EntrevoixAppleAdapters

@Test("Speech trimming keeps 200 ms around the outer spoken ranges")
func speechTrimmingKeepsTwoHundredMillisecondsOfPadding() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ))
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppleSpeechAudioCaptureTrimmerTests-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let source = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
    buffer.frameLength = 96_000
    try source.write(from: buffer)
    source.close()

    let input = try AVAudioFile(forReading: sourceURL)
    let speech = [
        CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 16_000), duration: CMTime(seconds: 1, preferredTimescale: 16_000)),
        CMTimeRange(start: CMTime(seconds: 4, preferredTimescale: 16_000), duration: CMTime(seconds: 1, preferredTimescale: 16_000))
    ]
    let plan = try #require(AppleSpeechAudioCaptureTrimmer.rewritePlan(
        for: speech,
        file: input,
        removeEdgeSilence: true,
        reduceInternalPauses: true
    ))

    #expect(plan.sourceRanges == [12_800..<32_000, 64_000..<83_200])
}
