// FILE: CaptureManager.swift
import AVFoundation
import CoreImage
import SwiftUI
import ObjectiveC

final class CaptureManager: NSObject, ObservableObject {
    enum StreamState: String {
        case idle
        case running
    }

    @Published private(set) var streamState: StreamState = .idle
    @Published private(set) var lenses: [CameraLens] = []
    @Published var selectedLens: CameraLens?
    @Published var stabilizationEnabled: Bool = true
    @Published var hdrEnabled: Bool = false
    @Published var isOrientationLocked: Bool = false
    @Published var orientation: AVCaptureVideoOrientation = .portrait
    @Published var zoomFactor: CGFloat = 1.0
    @Published var zebrasThreshold: Double = 0.95
    @Published var focusPeakingEnabled: Bool = false
    @Published var histogramEnabled: Bool = true
    @Published var focusReticleVisible: Bool = false
    @Published var focusReticlePoint: CGPoint = .zero
    @Published var histogramData: [CGFloat] = Array(repeating: 0.0, count: 64)

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.ndi.capture.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var currentVideoDevice: AVCaptureDevice?
    private var currentFormat: AVCaptureDevice.Format?
    private var ndiSender: NDIHXSender?
    private weak var bitrateMeter: BitrateMeter?
    private let encoder = HEVCEncoder()
    private var isEncoderPrepared = false

    private var histogramSamples: [CGFloat] = Array(repeating: 0.0, count: 64)

    override init() {
        super.init()
        session.usesApplicationAudioSession = true
        session.automaticallyConfiguresApplicationAudioSession = false
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        encoder.onFrame = { [weak self] frame in
            self?.handleEncodedFrame(frame)
        }
        lenses = DeviceCapabilities.discoverVideoDevices()
        selectedLens = lenses.first
        configureSession()
    }

    func startPreview() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopPreview() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func startStreaming(ndiSender: NDIHXSender, meter: BitrateMeter) {
        self.ndiSender = ndiSender
        self.bitrateMeter = meter
        ndiSender.start()
        DispatchQueue.main.async {
            self.streamState = .running
        }
    }

    func stopStreaming() {
        DispatchQueue.main.async {
            self.streamState = .idle
        }
        ndiSender?.stop()
        ndiSender = nil
        bitrateMeter = nil
        encoder.flush()
        isEncoderPrepared = false
    }

    func switchLens(_ lens: CameraLens) {
        selectedLens = lens
        isEncoderPrepared = false
        configureSession()
    }

    func toggleStabilization(_ enabled: Bool) {
        stabilizationEnabled = enabled
        updateStabilization()
    }

    func toggleHDR(_ enabled: Bool) {
        hdrEnabled = enabled
        updateHDR()
    }

    func toggleOrientationLock(_ locked: Bool) {
        isOrientationLocked = locked
    }

    func updateOrientation(_ orientation: AVCaptureVideoOrientation) {
        guard !isOrientationLocked else { return }
        self.orientation = orientation
        sessionQueue.async {
            self.videoOutput.connection(with: .video)?.videoOrientation = orientation
        }
    }

    func setZoomFactor(_ factor: CGFloat, rampRate: CGFloat = 4.0) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.ramp(toVideoZoomFactor: clamped, withRate: rampRate)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.zoomFactor = clamped
                }
            } catch {
                print("Zoom error: \(error)")
            }
        }
    }

    func updateTorch(level: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if level > 0 {
                    try device.setTorchModeOn(level: min(max(level, 0.01), 1.0))
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch {
                print("Torch error: \(error)")
            }
        }
    }

    func focus(at point: CGPoint, viewSize: CGSize) {
        guard let device = currentVideoDevice else { return }
        let normalizedPoint = CGPoint(x: point.y / viewSize.height, y: 1.0 - point.x / viewSize.width)
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = normalizedPoint
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = normalizedPoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.focusReticlePoint = point
                    withAnimation { self.focusReticleVisible = true }
                }
            } catch {
                print("Focus error: \(error)")
            }
        }
    }

    func setManualFocus(_ value: Float, locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice, device.isFocusModeSupported(.locked) else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(value, 0.0), 1.0)
                device.setFocusModeLocked(lensPosition: clamped) { _ in }
                if !locked {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            } catch {
                print("Manual focus error: \(error)")
            }
        }
    }

    func setManualExposure(iso: Float, durationSeconds: Double, locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                let minDuration = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
                let maxDuration = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
                let seconds = min(max(durationSeconds, minDuration), maxDuration)
                let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
                device.setExposureModeCustom(duration: duration, iso: clampedISO) { _ in }
                if !locked {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                print("Manual exposure error: \(error)")
            }
        }
    }

    func setWhiteBalance(mode: AVCaptureDevice.WhiteBalanceMode) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isWhiteBalanceModeSupported(mode) {
                    device.whiteBalanceMode = mode
                }
                device.unlockForConfiguration()
            } catch {
                print("White balance error: \(error)")
            }
        }
    }

    func setWhiteBalanceTemperature(kelvin: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                let gains = device.deviceWhiteBalanceGains(for: temperature)
                let normalized = self.normalize(gains: gains, device: device)
                device.setWhiteBalanceModeLocked(with: normalized) { _ in }
                device.unlockForConfiguration()
            } catch {
                print("Kelvin white balance error: \(error)")
            }
        }
    }

    func resetExposureAndFocus() {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            } catch {
                print("Reset AF/AE error: \(error)")
            }
        }
    }

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1920x1080

            if let videoInput = self.videoInput {
                self.session.removeInput(videoInput)
                self.videoInput = nil
            }

            if let lens = self.selectedLens {
                do {
                    let input = try AVCaptureDeviceInput(device: lens.device)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.videoInput = input
                        self.currentVideoDevice = lens.device
                        self.configureFormat(for: lens.device)
                    }
                } catch {
                    print("Video input error: \(error)")
                }
            }

            if self.audioInput == nil {
                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    do {
                        let input = try AVCaptureDeviceInput(device: audioDevice)
                        if self.session.canAddInput(input) {
                            self.session.addInput(input)
                            self.audioInput = input
                        }
                    } catch {
                        print("Audio input error: \(error)")
                    }
                }
            }

            if !self.session.outputs.contains(self.videoOutput) {
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
            }

            if !self.session.outputs.contains(self.audioOutput) {
                if self.session.canAddOutput(self.audioOutput) {
                    self.session.addOutput(self.audioOutput)
                }
            }

            if let connection = self.videoOutput.connection(with: .video) {
                connection.videoOrientation = self.orientation
                connection.isVideoMirrored = self.currentVideoDevice?.position == .front
                connection.preferredVideoStabilizationMode = DeviceCapabilities.stabilizedMode(preferred: self.stabilizationEnabled ? .cinematic : .off, connection: connection)
            }

            self.session.commitConfiguration()
            self.updateHDR()
        }
    }

    private func configureFormat(for device: AVCaptureDevice) {
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if let format = DeviceCapabilities.bestFormat(for: device) {
                    device.activeFormat = format
                    self.currentFormat = format
                }
                let duration = CMTime(value: 1, timescale: 30)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                print("Format configuration failed: \(error)")
            }
        }
    }

    private func updateStabilization() {
        sessionQueue.async {
            guard let connection = self.videoOutput.connection(with: .video) else { return }
            connection.preferredVideoStabilizationMode = DeviceCapabilities.stabilizedMode(preferred: self.stabilizationEnabled ? .cinematic : .off, connection: connection)
        }
    }

    private func updateHDR() {
        sessionQueue.async {
            guard let device = self.currentVideoDevice, let format = self.currentFormat else { return }
            do {
                try device.lockForConfiguration()
                if DeviceCapabilities.supportsHDR(format: format) {
                    device.isVideoHDREnabled = self.hdrEnabled
                } else {
                    device.isVideoHDREnabled = false
                }
                device.unlockForConfiguration()
            } catch {
                print("HDR configuration error: \(error)")
            }
        }
    }

    private func normalize(gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var gains = gains
        gains.redGain = max(device.minWhiteBalanceGain, min(gains.redGain, device.maxWhiteBalanceGain))
        gains.greenGain = max(device.minWhiteBalanceGain, min(gains.greenGain, device.maxWhiteBalanceGain))
        gains.blueGain = max(device.minWhiteBalanceGain, min(gains.blueGain, device.maxWhiteBalanceGain))
        return gains
    }

    private func handleEncodedFrame(_ frame: HEVCEncoder.EncodedFrame) {
        ndiSender?.sendVideo(h265: frame.codec == .hevc, data: frame.data, pts: frame.presentationTimeStamp)
        bitrateMeter?.ingest(bytes: frame.data.count, timestamp: frame.presentationTimeStamp)
    }

    private func updateHistogram(from sampleBuffer: CMSampleBuffer) {
        guard histogramEnabled, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let binCount = histogramSamples.count
        var bins = Array(repeating: 0, count: binCount)
        let sampleCount = width * height
        let step = max(1, sampleCount / (binCount * 4))
        var index = 0
        while index < sampleCount {
            let y = buffer[index]
            let bin = Int(Double(y) / 255.0 * Double(binCount - 1))
            bins[bin] += 1
            index += step
        }
        histogramSamples = bins.map { CGFloat($0) / CGFloat(sampleCount) * 4.0 }
        DispatchQueue.main.async {
            self.histogramData = self.histogramSamples
        }
    }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            if !isEncoderPrepared {
                if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    encoder.prepare(with: formatDescription)
                    isEncoderPrepared = true
                }
            }
            if streamState == .running {
                encoder.encode(sampleBuffer: sampleBuffer)
            }
            updateHistogram(from: sampleBuffer)
        } else if output == audioOutput {
            guard streamState == .running else { return }
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let format = AVAudioFormat(cmAudioFormatDescription: formatDesc) else { return }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return }
            audioBuffer.frameLength = AVAudioFrameCount(numSamples)
            audioBuffer.mutableAudioBufferList.withUnsafeMutableAudioBufferListPointer { listPointer in
                CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples), into: listPointer.unsafeMutablePointer)
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let asbd = format.streamDescription?.pointee {
                ndiSender?.sendAudio(pcm: audioBuffer, asbd: asbd, pts: pts)
            }
        }
    }
}
