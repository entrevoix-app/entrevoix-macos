import AudioToolbox
import AVFAudio
import Foundation
import EntrevoixCore

public struct OpenAITranscriptionService: SpeechTranscribing {
    private let transport: any HTTPTransporting
    private let makeBoundary: @Sendable () -> String

    public init(
        transport: any HTTPTransporting = SafeNetworkSession(),
        makeBoundary: @escaping @Sendable () -> String = { "Boundary-\(UUID().uuidString)" }
    ) {
        self.transport = transport
        self.makeBoundary = makeBoundary
    }

    public func transcribe(
        audioURL: URL,
        configuration: ProviderConfiguration,
        apiKey: String,
        prompt: String?,
        language: String?
    ) async throws -> String {
        guard let endpoint = configuration.endpointURL else { throw TranscriptionError.invalidEndpoint }
        let upload = try PreparedAudioUpload.make(
            from: audioURL,
            format: configuration.audioUploadFormat
        )
        defer { upload.deleteIfTemporary() }

        let audioData = try Data(contentsOf: upload.url)
        guard audioData.count <= 25 * 1024 * 1024 else { throw TranscriptionError.fileTooLarge }

        let boundary = makeBoundary()
        var body = Data()
        appendField("model", value: configuration.model, to: &body, boundary: boundary)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField("prompt", value: prompt, to: &body, boundary: boundary)
        }
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField(configuration.model == "gpt-transcribe" ? "languages[]" : "language", value: language, to: &body, boundary: boundary)
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(upload.filename)\"\r\nContent-Type: \(upload.mimeType)\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        switch configuration.authentication {
        case .bearer:
            guard !apiKey.isEmpty else { throw TranscriptionError.missingAPIKey }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            guard !apiKey.isEmpty else { throw TranscriptionError.missingAPIKey }
            let header = configuration.customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !header.isEmpty else { throw TranscriptionError.invalidHeader }
            request.setValue(apiKey, forHTTPHeaderField: header)
        case .none:
            break
        }

        let (data, response) = try await transport.data(for: request.withHTTPBody(body))
        guard let httpResponse = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranscriptionError.http(statusCode: httpResponse.statusCode, message: errorMessage(from: data))
        }
        if let result = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.emptyResult }
            return text
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw TranscriptionError.emptyResult }
        return text
    }

    private func appendField(_ name: String, value: String, to body: inout Data, boundary: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    private func errorMessage(from data: Data) -> String? {
        guard let error = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) else { return nil }
        return error.error.message
    }
}

private struct PreparedAudioUpload {
    let url: URL
    let filename: String
    let mimeType: String
    private let isTemporary: Bool

    static func make(from sourceURL: URL, format: AudioUploadFormat) throws -> Self {
        switch format {
        case .wav:
            return Self(url: sourceURL, filename: "audio.wav", mimeType: "audio/wav", isTemporary: false)
        case .m4aAAC:
            return try transcode(
                sourceURL: sourceURL,
                fileExtension: "m4a",
                filename: "audio.m4a",
                mimeType: "audio/mp4",
                settings: [
                    AVAudioFileTypeKey: kAudioFileM4AType,
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000
                ]
            )
        case .flac:
            return try transcodeFLAC(
                sourceURL: sourceURL,
                filename: "audio.flac",
                mimeType: "audio/flac"
            )
        }
    }

    func deleteIfTemporary() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func transcode(
        sourceURL: URL,
        fileExtension: String,
        filename: String,
        mimeType: String,
        settings: [String: Any]
    ) throws -> Self {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Entrevoix", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let input = try AVAudioFile(forReading: sourceURL)
            let output = try AVAudioFile(
                forWriting: destinationURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let capacity: AVAudioFrameCount = 8_192
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat,
                frameCapacity: capacity
            ) else {
                throw TranscriptionError.audioEncodingFailed
            }

            while input.framePosition < input.length {
                buffer.frameLength = 0
                let frameCount = AVAudioFrameCount(min(
                    AVAudioFramePosition(capacity),
                    input.length - input.framePosition
                ))
                try input.read(into: buffer, frameCount: frameCount)
                guard buffer.frameLength > 0 else { throw TranscriptionError.audioEncodingFailed }
                try output.write(from: buffer)
            }
            output.close()
            return Self(url: destinationURL, filename: filename, mimeType: mimeType, isTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if error is TranscriptionError { throw error }
            throw TranscriptionError.audioEncodingFailed
        }
    }

}

private extension PreparedAudioUpload {
    private static func transcodeFLAC(
        sourceURL: URL,
        filename: String,
        mimeType: String
    ) throws -> Self {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Entrevoix", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")

        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let input = try AVAudioFile(forReading: sourceURL)
            try writeFLAC(from: input, to: destinationURL)
            try ensureNativeFLACHeader(at: destinationURL)
            return Self(url: destinationURL, filename: filename, mimeType: mimeType, isTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if error is TranscriptionError { throw error }
            throw TranscriptionError.audioEncodingFailed
        }
    }

    private static func writeFLAC(from input: AVAudioFile, to destinationURL: URL) throws {
        var encodedFormat = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var file: ExtAudioFileRef?
        try checkStatus(ExtAudioFileCreateWithURL(
            destinationURL as CFURL,
            kAudioFileFLACType,
            &encodedFormat,
            nil,
            1,
            &file
        ))
        guard let file else { throw TranscriptionError.audioEncodingFailed }
        defer { _ = ExtAudioFileDispose(file) }

        var clientFormat = input.processingFormat.streamDescription.pointee
        try checkStatus(ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        ))

        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: capacity
        ) else {
            throw TranscriptionError.audioEncodingFailed
        }
        while input.framePosition < input.length {
            buffer.frameLength = 0
            let frameCount = AVAudioFrameCount(min(
                AVAudioFramePosition(capacity),
                input.length - input.framePosition
            ))
            try input.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { throw TranscriptionError.audioEncodingFailed }
            try checkStatus(ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList))
        }
    }

    private static func checkStatus(_ status: OSStatus) throws {
        guard status == noErr else { throw TranscriptionError.audioEncodingFailed }
    }

    /// `ExtAudioFile` writes native FLAC metadata blocks but omits the mandatory
    /// stream marker on current macOS releases. Restore it before upload.
    private static func ensureNativeFLACHeader(at url: URL) throws {
        var data = try Data(contentsOf: url)
        let header = Data("fLaC".utf8)
        guard data.count >= header.count else { throw TranscriptionError.audioEncodingFailed }
        if data.prefix(header.count) == header { return }
        guard data.prefix(header.count) == Data(repeating: 0, count: header.count) else {
            throw TranscriptionError.audioEncodingFailed
        }
        data.replaceSubrange(0..<header.count, with: header)
        try data.write(to: url, options: .atomic)
    }
}

private extension URLRequest {
    func withHTTPBody(_ body: Data) -> URLRequest {
        var request = self
        request.httpBody = body
        return request
    }
}

private struct TranscriptionResponse: Decodable { let text: String }
private struct APIErrorEnvelope: Decodable { let error: APIError }
private struct APIError: Decodable { let message: String }

enum TranscriptionError: LocalizedError, LogSafeError, UserFacingErrorProviding {
    case invalidEndpoint
    case invalidHeader
    case missingAPIKey
    case fileTooLarge
    case audioEncodingFailed
    case invalidResponse
    case emptyResult
    case http(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The STT endpoint is invalid."
        case .invalidHeader: "The authentication header name is invalid."
        case .missingAPIKey: "The STT API key is missing."
        case .fileTooLarge: "The audio file exceeds the 25 MB limit."
        case .audioEncodingFailed: "The audio file could not be prepared for upload."
        case .invalidResponse: "The STT response is invalid."
        case .emptyResult: "The transcript is empty."
        case .http(let statusCode, let message):
            if let message { "STT error (HTTP \(statusCode)): \(message)" }
            else { "STT error (HTTP \(statusCode))." }
        }
    }

    var logMessage: String {
        switch self {
        case .http(let statusCode, _): "STT request failed (HTTP \(statusCode))."
        default: "STT transcription failed."
        }
    }

    var userFacingMessage: UserFacingErrorMessage {
        switch self {
        case .invalidEndpoint: .sttInvalidEndpoint
        case .invalidHeader: .sttInvalidHeader
        case .missingAPIKey: .sttMissingAPIKey
        case .fileTooLarge: .sttFileTooLarge
        case .audioEncodingFailed: .sttAudioEncodingFailed
        case .invalidResponse: .sttInvalidResponse
        case .emptyResult: .sttEmptyResult
        case .http(let statusCode, let message): .sttHTTP(statusCode: statusCode, providerMessage: message)
        }
    }
}
