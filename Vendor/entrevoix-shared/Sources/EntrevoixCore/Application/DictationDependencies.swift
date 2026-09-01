import Foundation

@MainActor
public struct DictationDependencies {
    public let audioRecorder: any AudioRecording
    public let audioCaptureTrimmer: any AudioCaptureTrimming
    public let microphonePermission: any MicrophonePermissionRequesting
    public let textDelivery: any TextDelivering
    public let transcriber: any SpeechTranscribing
    public let cleaner: any TextCleaning
    public let logger: any LogWriting
    public let sessionArbiter: (any SessionArbitrating)?

    public init(
        audioRecorder: any AudioRecording,
        audioCaptureTrimmer: any AudioCaptureTrimming = PassthroughAudioCaptureTrimmer(),
        microphonePermission: any MicrophonePermissionRequesting,
        textDelivery: any TextDelivering,
        transcriber: any SpeechTranscribing,
        cleaner: any TextCleaning,
        logger: any LogWriting,
        sessionArbiter: (any SessionArbitrating)? = nil
    ) {
        self.audioRecorder = audioRecorder
        self.audioCaptureTrimmer = audioCaptureTrimmer
        self.microphonePermission = microphonePermission
        self.textDelivery = textDelivery
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.logger = logger
        self.sessionArbiter = sessionArbiter
    }
}
