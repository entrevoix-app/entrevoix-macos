import Foundation
import EntrevoixCore
import Observation

enum MicrophonePermissionRepairFeedback: Equatable {
    case succeeded
    case failed
}

@MainActor
@Observable
final class PermissionsStore {
    private let provider: any PermissionProviding
    private(set) var revision = 0
    private(set) var isResettingMicrophonePermission = false
    private(set) var microphonePermissionRepairFeedback: MicrophonePermissionRepairFeedback?
    private var accessibilityPollingTask: Task<Void, Never>?

    init(provider: any PermissionProviding) {
        self.provider = provider
    }

    var microphonePermission: PermissionStatus {
        _ = revision
        return provider.microphonePermission
    }

    var accessibilityPermission: PermissionStatus {
        _ = revision
        return provider.accessibilityPermission
    }

    func requestUnresolvedPermissionsAtLaunch() {
        if microphonePermission == .notDetermined {
            requestMicrophonePermission()
        }
        if accessibilityPermission != .granted {
            requestAccessibilityPermission()
        }
    }

    func requestMicrophonePermission() {
        microphonePermissionRepairFeedback = nil
        Task { [weak self] in
            guard let self else { return }
            _ = await self.provider.requestMicrophonePermission()
            self.refresh()
        }
    }

    func resetMicrophonePermission() {
        guard !isResettingMicrophonePermission else { return }

        isResettingMicrophonePermission = true
        microphonePermissionRepairFeedback = nil
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isResettingMicrophonePermission = false
                self.refresh()
            }

            do {
                try await self.provider.resetMicrophonePermission()
                self.microphonePermissionRepairFeedback = .succeeded
            } catch {
                self.microphonePermissionRepairFeedback = .failed
            }
        }
    }

    func requestAccessibilityPermission() {
        provider.requestAccessibilityPermission()
        refresh()
        accessibilityPollingTask?.cancel()
        accessibilityPollingTask = Task { [weak self] in
            for _ in 0..<30 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                self.refresh()
                if self.accessibilityPermission == .granted { return }
            }
        }
    }

    func refresh() {
        revision &+= 1
    }
}
