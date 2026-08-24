import AVFAudio
import CoreMedia
import EntrevoixCore
import Foundation
import Speech

/// Uses Apple Speech's local time-indexed dictation model to retain only the
/// continuous span surrounding detected human speech. No assets are downloaded
/// here: unavailable analysis deliberately leaves the recording unchanged.
actor AppleSpeechAudioCaptureTrimmer: AudioCaptureTrimming {
    private static let retainedPadding: TimeInterval = 0.1

    func trimLeadingAndTrailingSilence(
        in audioURL: URL,
        language: String?
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
            guard let bounds = Self.trimBounds(for: ranges, file: file) else {
                return .noSpeechDetected
            }
            guard bounds.startFrame > 0 || bounds.endFrame < file.length else {
                return .unchanged(audioURL)
            }
            let trimmedURL = try Self.writeTrimmedFile(
                from: file,
                sourceURL: audioURL,
                startFrame: bounds.startFrame,
                endFrame: bounds.endFrame
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
            guard !String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else { continue }
            ranges.append(result.range)
        }
        return ranges
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

    static func writeTrimmedFile(
        from source: AVAudioFile,
        sourceURL: URL,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition
    ) throws -> URL {
        let temporaryURL = sourceURL
            .deletingPathExtension()
            .appendingPathExtension("trimmed-\(UUID().uuidString).wav")
        let frameCapacity = AVAudioFrameCount(min(endFrame - startFrame, 8_192))
        guard frameCapacity > 0 else { throw CocoaError(.fileReadUnknown) }

        do {
            let output = try AVAudioFile(
                forWriting: temporaryURL,
                settings: source.fileFormat.settings,
                commonFormat: source.processingFormat.commonFormat,
                interleaved: source.processingFormat.isInterleaved
            )
            source.framePosition = startFrame
            var remaining = endFrame - startFrame
            while remaining > 0 {
                let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(frameCapacity)))
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: source.processingFormat,
                    frameCapacity: count
                ) else { throw CocoaError(.fileReadUnknown) }
                try source.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw CocoaError(.fileReadUnknown) }
                try output.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
            output.close()
            try FileManager.default.removeItem(at: sourceURL)
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
