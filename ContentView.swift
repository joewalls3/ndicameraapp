// FILE: ContentView.swift
import SwiftUI
import AVFoundation

private enum WhiteBalancePreset: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case daylight = "Daylight"
    case tungsten = "Tungsten"
    case fluorescent = "Fluorescent"

    var id: String { rawValue }

    var temperature: Float {
        switch self {
        case .auto: return 5000
        case .daylight: return 5600
        case .tungsten: return 3200
        case .fluorescent: return 4000
        }
    }

    var mode: AVCaptureDevice.WhiteBalanceMode {
        switch self {
        case .auto: return .continuousAutoWhiteBalance
        default: return .locked
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var captureManager: CaptureManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var bitrateMeter: BitrateMeter
    @EnvironmentObject private var motionLeveler: MotionLeveler
    @EnvironmentObject private var ndiSender: NDIHXSender

    @State private var showingControls = false
    @State private var torchLevel: Float = 0.0
    @State private var manualFocus: Float = 0.5
    @State private var focusLocked = false
    @State private var iso: Float = 200
    @State private var shutter: Double = 1.0 / 60.0
    @State private var exposureLocked = false
    @State private var whiteBalanceKelvin: Float = 5000
    @State private var wbPreset: WhiteBalancePreset = .auto
    @State private var zebrasEnabled = true
    @State private var showHistogram = true
    @State private var showFocusPeaking = false
    @State private var ndiSourceName: String = "iPhone NDI"
    @State private var ndiGroup: String = "default"
    @State private var baseZoom: CGFloat = 1.0

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                CameraPreviewView(captureManager: captureManager)
                    .overlay(alignment: .topLeading) {
                        if showHistogram && captureManager.histogramEnabled {
                            HistogramView(lumaSamples: captureManager.histogramData)
                                .padding()
                        }
                    }
                    .overlay(alignment: .center) {
                        if zebrasEnabled {
                            ZebrasView(threshold: captureManager.zebrasThreshold)
                        }
                    }
                    .overlay(alignment: .center) {
                        if showFocusPeaking {
                            FocusPeakingView()
                        }
                    }
                    .overlay(alignment: .center) {
                        FocusReticle(isVisible: $captureManager.focusReticleVisible, position: $captureManager.focusReticlePoint)
                    }
                    .overlay(alignment: .center) {
                        HorizonLevelView(roll: motionLeveler.roll)
                            .padding()
                    }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let location = value.location
                        let viewSize = geometry.size
                        captureManager.focus(at: location, viewSize: viewSize)
                    })
                    .gesture(MagnificationGesture().onChanged { value in
                        let newFactor = baseZoom * value
                        captureManager.setZoomFactor(newFactor)
                    }.onEnded { _ in
                        baseZoom = captureManager.zoomFactor
                    })
                    .onAppear {
                        captureManager.startPreview()
                        audioEngine.start()
                        ndiSourceName = ndiSender.sourceName
                        ndiGroup = ndiSender.group
                        baseZoom = captureManager.zoomFactor
                    }
                    .onDisappear {
                        captureManager.stopPreview()
                        audioEngine.stop()
                    }
            }

            topToolbar
            bottomPanel
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showingControls) {
            controlsSheet
                .presentationDetents([.medium, .large])
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation()
        }
    }

    private var topToolbar: some View {
        VStack {
            HStack(spacing: 12) {
                Menu {
                    ForEach(captureManager.lenses) { lens in
                        Button(action: { captureManager.switchLens(lens) }) {
                            Label(lens.localizedName, systemImage: captureManager.selectedLens?.id == lens.id ? "camera.fill" : "camera")
                        }
                    }
                } label: {
                    Label(captureManager.selectedLens?.localizedName ?? "Lens", systemImage: "camera.aperture")
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Toggle(isOn: Binding(get: { captureManager.stabilizationEnabled }, set: captureManager.toggleStabilization)) {
                    Label("Stab", systemImage: captureManager.stabilizationEnabled ? "video.fill" : "video")
                }
                .toggleStyle(.button)

                Toggle(isOn: Binding(get: { captureManager.hdrEnabled }, set: captureManager.toggleHDR)) {
                    Label("HDR", systemImage: captureManager.hdrEnabled ? "sun.max.fill" : "sun.max")
                }
                .toggleStyle(.button)

                Button {
                    let nextLevel: Float = torchLevel > 0 ? 0 : 1
                    captureManager.updateTorch(level: nextLevel)
                    torchLevel = nextLevel
                } label: {
                    Label("Torch", systemImage: torchLevel > 0 ? "flashlight.on.fill" : "flashlight.off.fill")
                }

                Text(String(format: "%.1fx", captureManager.zoomFactor))
                    .font(.footnote.monospacedDigit())
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                Button {
                    showingControls = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding([.top, .horizontal])
            Spacer()
        }
    }

    private var bottomPanel: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(.white)
                HStack(spacing: 12) {
                    statBadge(title: "NOW", value: String(format: "%.1f Mb/s", bitrateMeter.instantMbps))
                    statBadge(title: "10s AVG", value: String(format: "%.1f Mb/s", bitrateMeter.averageMbps))
                    statBadge(title: "NDI", value: ndiSender.state.rawValue)
                }
                HStack {
                    Button(action: toggleStreaming) {
                        Text(captureManager.streamState == .running ? "Stop" : "Go Live")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(captureManager.streamState == .running ? Color.red : Color.green, in: Capsule())
                            .foregroundColor(.white)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
        }
    }

    private var controlsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Focus")) {
                    Slider(value: $manualFocus, in: 0...1, onEditingChanged: { _ in
                        captureManager.setManualFocus(manualFocus, locked: focusLocked)
                    })
                    Toggle("Lock", isOn: $focusLocked)
                        .onChange(of: focusLocked) { newValue in
                            captureManager.setManualFocus(manualFocus, locked: newValue)
                        }
                    Button("Reset AF/AE") {
                        captureManager.resetExposureAndFocus()
                    }
                }

                Section(header: Text("Exposure")) {
                    Slider(value: $iso, in: 32...1600, step: 1) {
                        Text("ISO")
                    }
                    .onChange(of: iso) { _ in
                        captureManager.setManualExposure(iso: iso, durationSeconds: shutter, locked: exposureLocked)
                    }
                    Slider(value: $shutter, in: 1.0/1000.0...1.0/15.0) {
                        Text("Shutter")
                    }
                    .onChange(of: shutter) { _ in
                        captureManager.setManualExposure(iso: iso, durationSeconds: shutter, locked: exposureLocked)
                    }
                    Toggle("Lock", isOn: $exposureLocked)
                        .onChange(of: exposureLocked) { newValue in
                            captureManager.setManualExposure(iso: iso, durationSeconds: shutter, locked: newValue)
                        }
                }

                Section(header: Text("White Balance")) {
                    Picker("Preset", selection: $wbPreset) {
                        ForEach(WhiteBalancePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .onChange(of: wbPreset) { preset in
                        captureManager.setWhiteBalance(mode: preset.mode)
                        if preset != .auto {
                            whiteBalanceKelvin = preset.temperature
                            captureManager.setWhiteBalanceTemperature(kelvin: whiteBalanceKelvin)
                        }
                    }
                    Slider(value: $whiteBalanceKelvin, in: 2500...7500, step: 50) {
                        Text("Kelvin")
                    }
                    .onChange(of: whiteBalanceKelvin) { newValue in
                        wbPreset = .auto
                        captureManager.setWhiteBalance(mode: .locked)
                        captureManager.setWhiteBalanceTemperature(kelvin: newValue)
                    }
                }

                Section(header: Text("Overlays")) {
                    Toggle("Zebras", isOn: $zebrasEnabled)
                    Slider(value: $captureManager.zebrasThreshold, in: 0.5...1.0) {
                        Text("Zebra Threshold")
                    }
                    Toggle("Focus Peaking", isOn: $showFocusPeaking)
                        .onChange(of: showFocusPeaking) { value in
                            captureManager.focusPeakingEnabled = value
                        }
                    Toggle("Histogram", isOn: $showHistogram)
                        .onChange(of: showHistogram) { value in
                            captureManager.histogramEnabled = value
                        }
                }

                Section(header: Text("Torch")) {
                    Slider(value: $torchLevel, in: 0...1) {
                        Text("Torch")
                    }
                    .onChange(of: torchLevel) { newValue in
                        captureManager.updateTorch(level: newValue)
                    }
                }

                Section(header: Text("Audio")) {
                    Picker("Route", selection: $audioEngine.selectedRoute) {
                        ForEach(audioEngine.availableRoutes) { route in
                            Text(route.name).tag(Optional(route))
                        }
                    }
                    Slider(value: $audioEngine.gain, in: -12...12, step: 0.5) {
                        Text("Gain")
                    }
                    Toggle("High-Pass", isOn: $audioEngine.enableHighPass)
                    Toggle("Limiter", isOn: $audioEngine.enableLimiter)
                    Toggle("Stereo", isOn: $audioEngine.stereo)
                }

                Section(header: Text("Orientation")) {
                    Toggle("Lock", isOn: Binding(get: { captureManager.isOrientationLocked }, set: captureManager.toggleOrientationLock))
                }

                Section(header: Text("NDI")) {
                    TextField("Source Name", text: $ndiSourceName)
                        .onChange(of: ndiSourceName) { newValue in
                            ndiSender.sourceName = newValue
                        }
                    TextField("Group", text: $ndiGroup)
                        .onChange(of: ndiGroup) { newValue in
                            ndiSender.group = newValue
                        }
                    Text("Status: \(ndiSender.state.rawValue)")
                }
            }
            .navigationTitle("Pro Controls")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        showingControls = false
                    }
                }
            }
        }
    }

    private func statBadge(title: String, value: String) -> some View {
        VStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(8)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggleStreaming() {
        if captureManager.streamState == .running {
            captureManager.stopStreaming()
        } else {
            captureManager.startStreaming(ndiSender: ndiSender, meter: bitrateMeter)
        }
    }

    private var statusText: String {
        let resolution = "1080p30"
        let codec = captureManager.streamState == .running && ndiSender.state == .running ? "HEVC" : "Idle"
        return "\(captureManager.streamState == .running ? "Streaming" : "Preview") \(resolution) \(codec) @ 30 Mb/s"
    }

    private func updateOrientation() {
        let deviceOrientation = UIDevice.current.orientation
        let orientation: AVCaptureVideoOrientation
        switch deviceOrientation {
        case .landscapeLeft: orientation = .landscapeRight
        case .landscapeRight: orientation = .landscapeLeft
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        default: orientation = .portrait
        }
        captureManager.updateOrientation(orientation)
    }
}
