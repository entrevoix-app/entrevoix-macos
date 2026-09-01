import AVFAudio
import Foundation
import Testing
import EntrevoixCore
@testable import EntrevoixOpenAIAdapters

@Test("AAC and FLAC uploads use matching multipart metadata and valid audio")
func remoteTranscriptionEncodesSelectedUploadFormat() async throws {
    let sourceURL = try makeWAVFixture()
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    for (format, filename, mimeType, fileExtension) in [
        (AudioUploadFormat.m4aAAC, "audio.m4a", "audio/mp4", "m4a"),
        (.flac, "audio.flac", "audio/flac", "flac")
    ] {
        let transport = TranscriptionHTTPStub()
        let service = OpenAITranscriptionService(transport: transport, makeBoundary: { "Audio-Test" })
        let configuration = ProviderConfiguration(
            name: "STT",
            baseURL: "https://stt.example.com/v1",
            path: "audio/transcriptions",
            model: "whisper-1",
            authentication: .none,
            audioUploadFormat: format
        )

        _ = try await service.transcribe(
            audioURL: sourceURL,
            configuration: configuration,
            apiKey: "",
            prompt: nil,
            language: nil
        )

        let request = try #require(await transport.request)
        let body = try #require(request.httpBody)
        let header = "filename=\"\(filename)\"\r\nContent-Type: \(mimeType)"
        #expect(String(decoding: body, as: UTF8.self).contains(header))

        let audioData = try extractedAudioData(from: body, mimeType: mimeType)
        #expect(audioData.count > 32)
        switch format {
        case .m4aAAC:
            #expect(audioData.dropFirst(4).prefix(4) == Data("ftyp".utf8))
        case .flac:
            #expect(audioData.prefix(4) == Data("fLaC".utf8))
        case .wav:
            Issue.record("Unexpected WAV format in compression test")
        }
        if format == .m4aAAC {
            let inspectedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Entrevoix-inspected-upload-\(UUID().uuidString).\(fileExtension)")
            defer { try? FileManager.default.removeItem(at: inspectedURL) }
            try audioData.write(to: inspectedURL)
            let inspected = try AVAudioFile(forReading: inspectedURL)
            #expect(inspected.length > 0)
            #expect(inspected.fileFormat.channelCount == 1)
            #expect(abs(inspected.fileFormat.sampleRate - 16_000) < 1)
        }
    }
}

@Test("Encoding failures do not upload audio")
func remoteTranscriptionDoesNotUploadWhenEncodingFails() async throws {
    let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Entrevoix-invalid-audio-\(UUID().uuidString).wav")
    try Data([0x00, 0x01, 0x02]).write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let transport = TranscriptionHTTPStub()
    let service = OpenAITranscriptionService(transport: transport)
    let configuration = ProviderConfiguration(
        name: "STT",
        baseURL: "https://stt.example.com",
        path: "audio/transcriptions",
        model: "whisper-1",
        authentication: .none,
        audioUploadFormat: .m4aAAC
    )

    do {
        _ = try await service.transcribe(
            audioURL: sourceURL,
            configuration: configuration,
            apiKey: "",
            prompt: nil,
            language: nil
        )
        Issue.record("Expected audio encoding to fail")
    } catch let error as TranscriptionError {
        guard case .audioEncodingFailed = error else {
            Issue.record("Unexpected transcription error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    let request = await transport.request
    #expect(request == nil)
}

private actor TranscriptionHTTPStub: HTTPTransporting {
    private(set) var request: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (
            Data(#"{"text":"transcribed"}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

private func makeWAVFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Entrevoix-upload-source-\(UUID().uuidString).wav")
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
    buffer.frameLength = 1_600
    let samples = try #require(buffer.floatChannelData?.pointee)
    for index in 0..<Int(buffer.frameLength) {
        samples[index] = index.isMultiple(of: 2) ? 0.1 : -0.1
    }
    try file.write(from: buffer)
    file.close()
    return url
}

private func extractedAudioData(from body: Data, mimeType: String) throws -> Data {
    let separator = Data("Content-Type: \(mimeType)\r\n\r\n".utf8)
    let terminator = Data("\r\n--Audio-Test--\r\n".utf8)
    let payloadStart = try #require(body.range(of: separator)?.upperBound)
    let payloadEnd = try #require(body.range(of: terminator, options: [], in: payloadStart..<body.endIndex)?.lowerBound)
    return body.subdata(in: payloadStart..<payloadEnd)
}
