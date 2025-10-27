// FILE: NDIHXSender.swift
import Foundation
import AVFoundation

final class NDIHXSender: ObservableObject {
    enum State: String {
        case stopped = "OFF"
        case running = "ON"
    }

    @Published private(set) var state: State = .stopped
    @Published var sourceName: String = "iPhone NDI"
    @Published var group: String = "default"

    func start() {
        state = .running
        // TODO: Integrate Vizrt NDI SDK start logic here.
    }

    func stop() {
        state = .stopped
        // TODO: Integrate Vizrt NDI SDK stop logic here.
    }

    func sendVideo(h265: Bool, data: Data, pts: CMTime) {
        guard state == .running else { return }
        // TODO: Send video frame to NDI SDK.
    }

    func sendAudio(pcm: AVAudioPCMBuffer, asbd: AudioStreamBasicDescription, pts: CMTime) {
        guard state == .running else { return }
        // TODO: Send audio frame to NDI SDK.
    }
}
