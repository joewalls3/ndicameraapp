// FILE: AudioEngine.swift
import AVFoundation
import Combine
import CoreMedia

final class AudioEngine: ObservableObject {
    struct Route: Identifiable, Hashable, Equatable {
        let id: String
        let portDescription: AVAudioSessionPortDescription
        var name: String { portDescription.portName }

        static func == (lhs: Route, rhs: Route) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var availableRoutes: [Route] = []
    @Published var selectedRoute: Route? {
        didSet { applySelectedRoute() }
    }
    @Published var gain: Float = 0.0
    @Published var enableHighPass: Bool = false
    @Published var enableLimiter: Bool = false
    @Published var stereo: Bool = false

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var cancellables = Set<AnyCancellable>()

    init() {
        configureSession()
        buildGraph()
        refreshRoutes()

        $gain
            .sink { [weak self] value in
                self?.mixer.outputVolume = pow(10, value / 20)
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !isRunning else { return }
        do {
            try session.setActive(true)
            try engine.start()
            isRunning = true
        } catch {
            print("AudioEngine start error: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        do {
            try session.setActive(false)
        } catch {
            print("AudioEngine stop error: \(error)")
        }
        isRunning = false
    }

    func attachPCMBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime, ndiSender: NDIHXSender) {
        ndiSender.sendAudio(pcm: buffer, asbd: buffer.format.streamDescription.pointee, pts: pts)
    }

    func refreshRoutes() {
        let inputs = session.availableInputs ?? []
        availableRoutes = inputs.map { Route(id: $0.uid, portDescription: $0) }
        if selectedRoute == nil {
            selectedRoute = availableRoutes.first
        }
    }

    private func applySelectedRoute() {
        guard let route = selectedRoute else { return }
        do {
            try session.setPreferredInput(route.portDescription)
        } catch {
            print("Failed to set preferred input: \(error)")
        }
    }

    private func configureSession() {
        do {
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredInputNumberOfChannels(2)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }

    private func buildGraph() {
        engine.attach(mixer)
        engine.connect(engine.inputNode, to: mixer, format: engine.inputNode.inputFormat(forBus: 0))
        engine.connect(mixer, to: engine.mainMixerNode, format: engine.inputNode.inputFormat(forBus: 0))
        engine.mainMixerNode.outputVolume = 0.0
    }
}
