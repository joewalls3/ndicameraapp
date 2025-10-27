// FILE: ImageAnalysis.swift
import Foundation
import CoreVideo
import CoreGraphics

final class HistogramGenerator {
    private let binCount: Int

    init(binCount: Int = 64) {
        self.binCount = max(1, binCount)
    }

    func generate(from pixelBuffer: CVPixelBuffer) -> [CGFloat]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        if width == 0 || height == 0 { return nil }

        var bins = Array(repeating: 0, count: binCount)
        let xStep = max(1, width / 256)
        let yStep = max(1, height / 256)
        var sampledPixels = 0

        for y in stride(from: 0, through: height - 1, by: yStep) {
            let rowPointer = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, through: width - 1, by: xStep) {
                let luma = Int(rowPointer[x])
                let normalized = Double(luma) / 255.0
                let index = Int(normalized * Double(binCount - 1))
                bins[index] += 1
                sampledPixels += 1
            }
        }

        let total = max(sampledPixels, 1)
        return bins.map { CGFloat($0) / CGFloat(total) }
    }
}

final class ZebraMaskGenerator {
    private let scale: Int
    private let colorSpace = CGColorSpaceCreateDeviceGray()

    init(scale: Int = 3) {
        self.scale = max(1, scale)
    }

    func makeMask(from pixelBuffer: CVPixelBuffer, threshold: Double) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        if width == 0 || height == 0 { return nil }

        let downsampledWidth = max(1, width / scale)
        let downsampledHeight = max(1, height / scale)
        var mask = [UInt8](repeating: 0, count: downsampledWidth * downsampledHeight)
        let clampedThreshold = min(max(threshold, 0.0), 1.0)

        for y in 0..<downsampledHeight {
            let sourceY = min(height - 1, y * scale)
            let rowPointer = baseAddress.advanced(by: sourceY * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<downsampledWidth {
                let sourceX = min(width - 1, x * scale)
                let luma = Int(rowPointer[sourceX])
                let normalized = Double(luma) / 255.0
                if normalized >= clampedThreshold {
                    let pattern = ((x + y) % 2 == 0) ? 255 : 90
                    mask[y * downsampledWidth + x] = UInt8(pattern)
                }
            }
        }

        return makeImage(width: downsampledWidth, height: downsampledHeight, data: mask)
    }

    private func makeImage(width: Int, height: Int, data: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

final class FocusPeakingMaskGenerator {
    private let scale: Int
    private let colorSpace = CGColorSpaceCreateDeviceGray()

    init(scale: Int = 3) {
        self.scale = max(1, scale)
    }

    func makeMask(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        if width < 3 || height < 3 { return nil }

        let downsampledWidth = max(2, width / scale)
        let downsampledHeight = max(2, height / scale)
        var mask = [UInt8](repeating: 0, count: downsampledWidth * downsampledHeight)

        func luma(x: Int, y: Int) -> Int {
            let clampedX = min(max(x, 0), width - 1)
            let clampedY = min(max(y, 0), height - 1)
            let rowPointer = baseAddress.advanced(by: clampedY * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            return Int(rowPointer[clampedX])
        }

        for y in 1..<(downsampledHeight - 1) {
            let sourceY = y * scale
            for x in 1..<(downsampledWidth - 1) {
                let sourceX = x * scale
                let p00 = luma(x: sourceX - scale, y: sourceY - scale)
                let p01 = luma(x: sourceX, y: sourceY - scale)
                let p02 = luma(x: sourceX + scale, y: sourceY - scale)
                let p10 = luma(x: sourceX - scale, y: sourceY)
                let p12 = luma(x: sourceX + scale, y: sourceY)
                let p20 = luma(x: sourceX - scale, y: sourceY + scale)
                let p21 = luma(x: sourceX, y: sourceY + scale)
                let p22 = luma(x: sourceX + scale, y: sourceY + scale)

                let gx = (-p00 - 2 * p01 - p02) + (p20 + 2 * p21 + p22)
                let gy = (-p00 - 2 * p10 - p20) + (p02 + 2 * p12 + p22)
                let magnitude = sqrt(Double(gx * gx + gy * gy))
                if magnitude > 120 {
                    let scaled = min(255, Int(magnitude * 0.6))
                    mask[y * downsampledWidth + x] = UInt8(scaled)
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(mask) as CFData) else { return nil }
        return CGImage(width: downsampledWidth,
                       height: downsampledHeight,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: downsampledWidth,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
