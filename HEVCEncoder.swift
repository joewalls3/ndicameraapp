// FILE: HEVCEncoder.swift
import AVFoundation
import Foundation
import VideoToolbox

final class HEVCEncoder {
    enum Codec: String {
        case hevc = "hvc1"
        case h264 = "avc1"
    }

    struct EncodedFrame {
        let data: Data
        let presentationTimeStamp: CMTime
        let codec: Codec
    }

    private let callbackQueue = DispatchQueue(label: "com.ndi.encoder.callback")
    private var compressionSession: VTCompressionSession?
    private(set) var currentCodec: Codec = .hevc

    var onFrame: ((EncodedFrame) -> Void)?

    init() {}

    func prepare(with formatDescription: CMFormatDescription) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let width = Int32(dimensions.width)
        let height = Int32(dimensions.height)

        currentCodec = HEVCEncoder.isHEVCSupported ? .hevc : .h264
        let codecType: CMVideoCodecType = currentCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        teardown()

        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: width,
                                                height: height,
                                                codecType: codecType,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: HEVCEncoder.compressionOutputCallback,
                                                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                                compressionSessionOut: &compressionSession)

        guard status == noErr, let session = compressionSession else {
            print("Failed to create compression session: \(status)")
            return
        }

        configure(session: session)
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: imageBuffer,
                                                     presentationTimeStamp: presentationTimeStamp,
                                                     duration: .invalid,
                                                     frameProperties: nil,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: &flags)
        if status != noErr {
            print("Encode error: \(status)")
        }
    }

    func flush() {
        guard let session = compressionSession else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func teardown() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
    }

    deinit {
        teardown()
    }

    private func configure(session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2.0))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 30_000_000))
        let limits: [NSNumber] = [NSNumber(value: 60_000_000), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        if currentCodec == .hevc {
            VTSessionSetProperty(session,
                                 key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session,
                                 key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
    }
}

private extension HEVCEncoder {
    static let compressionOutputCallback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, _, sampleBuffer in
        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer),
              let refCon = outputCallbackRefCon else {
            return
        }

        let encoder = Unmanaged<HEVCEncoder>.fromOpaque(refCon).takeUnretainedValue()
        encoder.handleEncodedSample(sampleBuffer)
    }

    func isKeyFrame(sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool else {
            return true
        }
        return !notSync
    }

    func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: nil,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)
        if status != kCMBlockBufferNoErr { return }

        guard let dataPointer else { return }

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var annexBData = Data()
        var headerLength = 4
        let isKey = isKeyFrame(sampleBuffer: sampleBuffer)

        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            switch currentCodec {
            case .h264:
                headerLength = appendParameterSetsH264(from: formatDescription,
                                                       to: &annexBData,
                                                       includeParameterSets: isKey)
            case .hevc:
                headerLength = appendParameterSetsHEVC(from: formatDescription,
                                                       to: &annexBData,
                                                       includeParameterSets: isKey)
            }
        }

        headerLength = max(headerLength, 1)

        var bufferOffset = 0
        while bufferOffset + headerLength <= totalLength {
            var nalUnitLength: UInt32 = 0
            let rawPointer = UnsafeMutableRawPointer(dataPointer).advanced(by: bufferOffset)
            memcpy(&nalUnitLength, rawPointer, headerLength)

            switch headerLength {
            case 1:
                nalUnitLength = UInt32(UInt8(truncatingIfNeeded: nalUnitLength))
            case 2:
                nalUnitLength = UInt32(CFSwapInt16BigToHost(UInt16(truncatingIfNeeded: nalUnitLength)))
            default:
                nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
            }

            if nalUnitLength == 0 || bufferOffset + headerLength + Int(nalUnitLength) > totalLength {
                break
            }

            annexBData.append(contentsOf: startCode)
            let nalStart = bufferOffset + headerLength
            let nal = Data(bytes: dataPointer.advanced(by: nalStart), count: Int(nalUnitLength))
            annexBData.append(nal)

            bufferOffset += headerLength + Int(nalUnitLength)
        }

        if annexBData.isEmpty {
            annexBData = Data(bytes: dataPointer, count: totalLength)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = HEVCEncoder.EncodedFrame(data: annexBData, presentationTimeStamp: pts, codec: currentCodec)

        callbackQueue.async { [weak self] in
            self?.onFrame?(frame)
        }
    }

    func appendParameterSetsH264(from formatDescription: CMFormatDescription,
                                 to data: inout Data,
                                 includeParameterSets: Bool) -> Int {
        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int = 4
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize: Int = 0
        var headerLengthOut: Int = 0

        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription,
                                                                        parameterSetIndex: 0,
                                                                        parameterSetPointerOut: &parameterSetPointer,
                                                                        parameterSetSizeOut: &parameterSetSize,
                                                                        parameterSetCountOut: &parameterSetCount,
                                                                        nalUnitHeaderLengthOut: &headerLengthOut)
        if status == noErr {
            nalUnitHeaderLength = headerLengthOut
        }

        if includeParameterSets && parameterSetCount > 0 {
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size: Int = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription,
                                                                                parameterSetIndex: index,
                                                                                parameterSetPointerOut: &pointer,
                                                                                parameterSetSizeOut: &size,
                                                                                parameterSetCountOut: nil,
                                                                                nalUnitHeaderLengthOut: nil)
                if status == noErr, let pointer {
                    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    data.append(Data(bytes: pointer, count: size))
                }
            }
        }

        return nalUnitHeaderLength
    }

    func appendParameterSetsHEVC(from formatDescription: CMFormatDescription,
                                 to data: inout Data,
                                 includeParameterSets: Bool) -> Int {
        var parameterSetCount: Int = 0
        var nalUnitHeaderLength: Int = 4
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize: Int = 0
        var headerLengthOut: Int = 0

        let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription,
                                                                        parameterSetIndex: 0,
                                                                        parameterSetPointerOut: &parameterSetPointer,
                                                                        parameterSetSizeOut: &parameterSetSize,
                                                                        parameterSetCountOut: &parameterSetCount,
                                                                        nalUnitHeaderLengthOut: &headerLengthOut,
                                                                        parameterSetTypeOut: nil)
        if status == noErr {
            nalUnitHeaderLength = headerLengthOut
        }

        if includeParameterSets && parameterSetCount > 0 {
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size: Int = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription,
                                                                                parameterSetIndex: index,
                                                                                parameterSetPointerOut: &pointer,
                                                                                parameterSetSizeOut: &size,
                                                                                parameterSetCountOut: nil,
                                                                                nalUnitHeaderLengthOut: nil,
                                                                                parameterSetTypeOut: nil)
                if status == noErr, let pointer {
                    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    data.append(Data(bytes: pointer, count: size))
                }
            }
        }

        return nalUnitHeaderLength
    }

    static var isHEVCSupported: Bool {
        if #available(iOS 11.0, *) {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) || VTIsHardwareEncodeSupported(kCMVideoCodecType_HEVC)
        }
        return false
    }
}
