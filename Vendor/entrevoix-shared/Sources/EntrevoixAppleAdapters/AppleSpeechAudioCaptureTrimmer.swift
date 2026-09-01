import AVFAudio
import CoreMedia
import EntrevoixCore
import Foundation
import Speech

/// Uses Apple Speech's local time-indexed dictation model to retain only the
/// continuous span surrounding detected human speech. No assets are downloaded
/// here: unavailable analysis deliberately leaves the recording unchanged.
public actor AppleSpeechAudioCaptureTrimmer: AudioCaptureTrimming {
    private static let retainedPadding: TimeInterval = 0.2
    private static let longPauseThreshold: TimeInterval = 1
    private static let reducedPauseDuration: TimeInterval = 0.5

    public init() {}

    public func processCapture(
        in audioURL: URL,
        language: String?,
        removeEdgeSilence: Bool,
        reduceInternalPauses: Bool
    ) async -> AudioCaptureTrimResult {
        let requestedLocale = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return .unchanged(audioURL)
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            return .unchanged(audioURL)
        }

        do {
            let file = try AVAudioFile(forReading: audioURL)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            async let speechRanges = collectFinalSpeechRanges(from: transcriber)
            let finalTime = try await analyzer.analyzeSequence(from: file)
            if let finalTime {
                try await analyzer.finalizeAndFinish(through: finalTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let ranges = try await speechRanges
            guard let plan = Self.rewritePlan(
                for: ranges,
                file: file,
                removeEdgeSilence: removeEdgeSilence,
                reduceInternalPauses: reduceInternalPauses
            ) else {
                return .noSpeechDetected
            }
            guard !plan.isIdentity(for: file.length) else {
                return .unchanged(audioURL)
            }
            let trimmedURL = try Self.writeProcessedFile(
                from: file,
                sourceURL: audioURL,
                plan: plan
            )
            return .trimmed(trimmedURL)
        } catch is CancellationError {
            return .unchanged(audioURL)
        } catch {
            return .unchanged(audioURL)
        }
    }

    private func collectFinalSpeechRanges(
        from transcriber: DictationTranscriber
    ) async throws -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        for try await result in transcriber.results where result.isFinal {
            ranges.append(contentsOf: Self.wordTimeRanges(in: result.text))
        }
        return ranges
    }

    /// The result range covers an analysis/finalization segment and may include
    /// trailing silence. The time-indexed text attributes identify spoken words.
    static func wordTimeRanges(in text: AttributedString) -> [CMTimeRange] {
        text.runs.compactMap { run in
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
                  !range.isEmpty else { return nil }
            return range
        }
    }

    static func trimBounds(
        for speechRanges: [CMTimeRange],
        file: AVAudioFile
    ) -> (startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition)? {
        guard file.length > 0, file.fileFormat.sampleRate > 0 else { return nil }
        let validRanges = speechRanges.filter { !$0.isEmpty && $0.start.isNumeric && $0.end.isNumeric }
        guard let first = validRanges.map(\.start.seconds).min(),
              let last = validRanges.map(\.end.seconds).max() else { return nil }

        let sampleRate = file.fileFormat.sampleRate
        let startFrame = max(0, AVAudioFramePosition(((first - retainedPadding) * sampleRate).rounded(.down)))
        let endFrame = min(file.length, AVAudioFramePosition(((last + retainedPadding) * sampleRate).rounded(.up)))
        guard endFrame > startFrame else { return nil }
        return (startFrame, endFrame)
    }

    static func rewritePlan(
        for speechRanges: [CMTimeRange],
        file: AVAudioFile,
        removeEdgeSilence: Bool,
        reduceInternalPauses: Bool
    ) -> AudioCaptureRewritePlan? {
        guard file.length > 0, file.fileFormat.sampleRate > 0 else { return nil }
        let ranges = speechRanges
            .filter { !$0.isEmpty && $0.start.isNumeric && $0.end.isNumeric }
            .sorted { $0.start < $1.start }
        guard let first = ranges.first, let last = ranges.last else { return nil }

        let sampleRate = file.fileFormat.sampleRate
        let initialFrame = removeEdgeSilence
            ? max(0, AVAudioFramePosition(((first.start.seconds - retainedPadding) * sampleRate).rounded(.down)))
            : 0
        let finalFrame = removeEdgeSilence
            ? min(file.length, AVAudioFramePosition(((last.end.seconds + retainedPadding) * sampleRate).rounded(.up)))
            : file.length

        guard reduceInternalPauses else {
            return AudioCaptureRewritePlan(sourceRanges: [initialFrame..<finalFrame], insertedSilentFrames: 0)
        }

        var sourceRanges: [Range<AVAudioFramePosition>] = []
        var segmentStart = initialFrame
        var previousEnd = first.end.seconds
        for range in ranges.dropFirst() {
            let gap = range.start.seconds - previousEnd
            if gap > longPauseThreshold {
                let segmentEnd = min(
                    file.length,
                    AVAudioFramePosition((previousEnd * sampleRate).rounded(.up))
                )
                if segmentEnd > segmentStart { sourceRanges.append(segmentStart..<segmentEnd) }
                segmentStart = max(
                    0,
                    AVAudioFramePosition((range.start.seconds * sampleRate).rounded(.down))
                )
            }
            previousEnd = max(previousEnd, range.end.seconds)
        }
        if finalFrame > segmentStart { sourceRanges.append(segmentStart..<finalFrame) }
        guard !sourceRanges.isEmpty else { return nil }
        return AudioCaptureRewritePlan(
            sourceRanges: sourceRanges,
            insertedSilentFrames: sourceRanges.count > 1
                ? AVAudioFramePosition((reducedPauseDuration * sampleRate).rounded())
                : 0
        )
    }

    static func writeProcessedFile(
        from source: AVAudioFile,
        sourceURL: URL,
        plan: AudioCaptureRewritePlan
    ) throws -> URL {
        let temporaryURL = sourceURL
            .deletingPathExtension()
            .appendingPathExtension("trimmed-\(UUID().uuidString).wav")
        let maximumRangeLength = plan.sourceRanges.map { $0.upperBound - $0.lowerBound }.max() ?? 0
        let frameCapacity = AVAudioFrameCount(min(maximumRangeLength, 8_192))
        guard frameCapacity > 0 else { throw CocoaError(.fileReadUnknown) }

        do {
            let output = try AVAudioFile(
                forWriting: temporaryURL,
                settings: source.fileFormat.settings,
                commonFormat: source.processingFormat.commonFormat,
                interleaved: source.processingFormat.isInterleaved
            )
            for (index, range) in plan.sourceRanges.enumerated() {
                try write(source: source, range: range, to: output, frameCapacity: frameCapacity)
                if index < plan.sourceRanges.index(before: plan.sourceRanges.endIndex) {
                    try writeSilence(
                        frameCount: plan.insertedSilentFrames,
                        format: source.processingFormat,
                        to: output,
                        frameCapacity: frameCapacity
                    )
                }
            }
            output.close()
            try FileManager.default.removeItem(at: sourceURL)
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func write(
        source: AVAudioFile,
        range: Range<AVAudioFramePosition>,
        to output: AVAudioFile,
        frameCapacity: AVAudioFrameCount
    ) throws {
        source.framePosition = range.lowerBound
        var remaining = range.upperBound - range.lowerBound
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(frameCapacity)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count) else {
                throw CocoaError(.fileReadUnknown)
            }
            try source.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadUnknown) }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private static func writeSilence(
        frameCount: AVAudioFramePosition,
        format: AVAudioFormat,
        to output: AVAudioFile,
        frameCapacity: AVAudioFrameCount
    ) throws {
        var remaining = frameCount
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(frameCapacity)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw CocoaError(.fileReadUnknown)
            }
            buffer.frameLength = count
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(count)
        }
    }
}

struct AudioCaptureRewritePlan: Equatable {
    let sourceRanges: [Range<AVAudioFramePosition>]
    let insertedSilentFrames: AVAudioFramePosition

    func isIdentity(for sourceLength: AVAudioFramePosition) -> Bool {
        sourceRanges == [0..<sourceLength] && insertedSilentFrames == 0
    }
}

public actor AppleSpeechAudioCaptureTrimmingResourceManager: AudioCaptureTrimmingResourceManaging {
    public init() {}

    public func preparationState(for requestedLocale: Locale) async -> AudioCaptureTrimmingResourceState {
        guard let transcriber = await makeTranscriber(for: requestedLocale) else {
            return .unsupported
        }

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .ready
        case .downloading:
            return .downloading
        case .supported:
            return .downloadRequired
        case .unsupported:
            return .unsupported
        @unknown default:
            return .failed
        }
    }

    public func download(for requestedLocale: Locale) async throws {
        guard let transcriber = await makeTranscriber(for: requestedLocale) else {
            throw AudioCaptureTrimmingResourceError.unsupportedLocale
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        try Task.checkCancellation()
        try await request.downloadAndInstall()
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AudioCaptureTrimmingResourceError.installationIncomplete
        }
    }

    private func makeTranscriber(for requestedLocale: Locale) async -> DictationTranscriber? {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return nil
        }
        return DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
    }
}

private enum AudioCaptureTrimmingResourceError: Error, Sendable {
    case unsupportedLocale
    case installationIncomplete
}
