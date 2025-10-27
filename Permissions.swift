// FILE: Permissions.swift
import AVFoundation

actor Permissions {
    static let shared = Permissions()

    func ensureAllPermissions() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.requestVideo() }
            group.addTask { await self.requestAudio() }
        }
    }

    private func requestVideo() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .video)
        default:
            return
        }
    }

    private func requestAudio() async {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return
        case .undetermined:
            await AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        default:
            return
        }
    }
}
