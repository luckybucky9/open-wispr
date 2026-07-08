import Foundation

struct RecordingLifecycle {
    enum Action: Equatable {
        case none
        case startRecording
        case stopRecording
        case cancelRecording
        case prepareRecorder
    }

    private(set) var isRecording = false

    mutating func keyDown(toggleMode: Bool) -> Action {
        if toggleMode {
            if isRecording {
                isRecording = false
                return .stopRecording
            }
            isRecording = true
            return .startRecording
        }

        guard !isRecording else { return .none }
        isRecording = true
        return .startRecording
    }

    mutating func keyUp(toggleMode: Bool) -> Action {
        guard !toggleMode, isRecording else { return .none }
        isRecording = false
        return .stopRecording
    }

    mutating func systemWillSleep() -> Action {
        guard isRecording else { return .none }
        isRecording = false
        return .cancelRecording
    }

    func systemDidWake(isReady: Bool) -> Action {
        isReady ? .prepareRecorder : .none
    }

    /// The audio engine's I/O configuration was invalidated (an audio device
    /// was added or removed, or the default device changed). Any in-flight
    /// recording is already broken — its tap stops receiving buffers — so
    /// cancel it; otherwise rebuild the recorder so the next recording works.
    mutating func audioConfigurationChanged(isReady: Bool) -> Action {
        if isRecording {
            isRecording = false
            return .cancelRecording
        }
        return isReady ? .prepareRecorder : .none
    }

    /// The user asked to rebuild the audio engine from the menu bar (manual
    /// recovery when the engine is stranded). Same decision as an audio
    /// configuration change: cancel any in-flight recording — its tap is
    /// likely dead — otherwise just rebuild the recorder.
    mutating func manualEngineRestart(isReady: Bool) -> Action {
        audioConfigurationChanged(isReady: isReady)
    }

    mutating func recordingStartFailed() {
        isRecording = false
    }
}

enum RecordingCancellation {
    static func discardPartialRecording(at url: URL?, fileManager: FileManager = .default) {
        guard let url else { return }
        try? fileManager.removeItem(at: url)
    }

    static func discardTrackedPartialRecording(_ url: inout URL?, fileManager: FileManager = .default) {
        discardPartialRecording(at: url, fileManager: fileManager)
        url = nil
    }
}
