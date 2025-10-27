// FILE: DeviceCapabilities.swift
import AVFoundation
import CoreMedia

struct CameraLens: Identifiable, Hashable {
    enum LensType: String {
        case ultraWide = "Ultra-Wide"
        case wide = "Wide"
        case telephoto = "Telephoto"
        case front = "Front"
    }

    let id = UUID()
    let device: AVCaptureDevice
    let lensType: LensType

    var localizedName: String {
        switch lensType {
        case .ultraWide: return "Ultra-Wide"
        case .wide: return "Wide"
        case .telephoto: return "Telephoto"
        case .front: return "Front"
        }
    }
}

enum DeviceCapabilities {
    static func discoverVideoDevices() -> [CameraLens] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInDualCamera,
            .builtInTrueDepthCamera
        ], mediaType: .video, position: .unspecified)

        var lenses: [CameraLens] = []
        for device in discovery.devices {
            let lensType: CameraLens.LensType
            switch device.position {
            case .front:
                lensType = .front
            case .back:
                if device.deviceType == .builtInUltraWideCamera {
                    lensType = .ultraWide
                } else if device.deviceType == .builtInTelephotoCamera {
                    lensType = .telephoto
                } else {
                    lensType = .wide
                }
            default:
                continue
            }
            lenses.append(CameraLens(device: device, lensType: lensType))
        }

        let preferredOrder: [CameraLens.LensType] = [.wide, .ultraWide, .telephoto, .front]
        return lenses.sorted { lhs, rhs in
            if lhs.device.position == rhs.device.position {
                return lhs.device.uniqueID < rhs.device.uniqueID
            }
            guard let leftIndex = preferredOrder.firstIndex(of: lhs.lensType),
                  let rightIndex = preferredOrder.firstIndex(of: rhs.lensType) else {
                return lhs.device.position.rawValue < rhs.device.position.rawValue
            }
            return leftIndex < rightIndex
        }
    }

    static func bestFormat(for device: AVCaptureDevice, targetDimensions: CMVideoDimensions = CMVideoDimensions(width: 1920, height: 1080), targetFrameRate: Double = 30.0) -> AVCaptureDevice.Format? {
        let formats = device.formats.filter { format in
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            return dimensions.width >= 1280 && dimensions.height >= 720 && format.isVideoSupported(at: targetFrameRate)
        }

        let sorted = formats.sorted { lhs, rhs in
            let leftDimensions = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rightDimensions = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let leftScore = score(dimensions: leftDimensions, target: targetDimensions)
            let rightScore = score(dimensions: rightDimensions, target: targetDimensions)
            if leftScore == rightScore {
                return lhs.videoSupportedFrameRateRange(for: targetFrameRate)?.maxFrameRate ?? 0 > rhs.videoSupportedFrameRateRange(for: targetFrameRate)?.maxFrameRate ?? 0
            }
            return leftScore < rightScore
        }

        return sorted.first ?? device.formats.sorted { lhs, rhs in
            let leftDimensions = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rightDimensions = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return leftDimensions.width * leftDimensions.height > rightDimensions.width * rightDimensions.height
        }.first
    }

    static func supportsHDR(format: AVCaptureDevice.Format) -> Bool {
        if #available(iOS 13.0, *) {
            return format.isVideoHDRSupported
        }
        return false
    }

    static func supportedStabilizationModes(for connection: AVCaptureConnection) -> [AVCaptureVideoStabilizationMode] {
        var modes: [AVCaptureVideoStabilizationMode] = []
        if connection.isVideoStabilizationSupported {
            if connection.isVideoStabilizationModeSupported(.cinematic) {
                modes.append(.cinematic)
            }
            if connection.isVideoStabilizationModeSupported(.standard) {
                modes.append(.standard)
            }
            if connection.isVideoStabilizationModeSupported(.off) {
                modes.append(.off)
            }
        }
        return modes
    }

    static func stabilizedMode(preferred: AVCaptureVideoStabilizationMode, connection: AVCaptureConnection) -> AVCaptureVideoStabilizationMode {
        let modes = supportedStabilizationModes(for: connection)
        return modes.contains(preferred) ? preferred : (modes.contains(.standard) ? .standard : .off)
    }

    private static func score(dimensions: CMVideoDimensions, target: CMVideoDimensions) -> Int64 {
        let dw = abs(Int64(dimensions.width) - Int64(target.width))
        let dh = abs(Int64(dimensions.height) - Int64(target.height))
        return dw * dw + dh * dh
    }
}

private extension AVCaptureDevice.Format {
    func isVideoSupported(at frameRate: Double) -> Bool {
        for range in videoSupportedFrameRateRanges where range.minFrameRate <= frameRate && range.maxFrameRate >= frameRate {
            return true
        }
        return false
    }

    func videoSupportedFrameRateRange(for frameRate: Double) -> AVFrameRateRange? {
        return videoSupportedFrameRateRanges.first { frameRate >= $0.minFrameRate && frameRate <= $0.maxFrameRate }
    }
}
