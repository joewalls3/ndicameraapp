// FILE: HEVCEncoder.swift
import AVFoundation
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
                                                outputCallback: compressionOutputCallback,
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 30_000_000 as CFTypeRef)
        let limits: [Int] = [60_000_000, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        if currentCodec == .hevc {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
    }
}

private func compressionOutputCallback(outputCallbackRefCon: UnsafeMutableRawPointer?,
                                       sourceFrameRefCon: UnsafeMutableRawPointer?,
                                       status: OSStatus,
                                       infoFlags: VTEncodeInfoFlags,
                                       sampleBuffer: CMSampleBuffer?) {
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer),
          let refCon = outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<HEVCEncoder>.fromOpaque(refCon).takeUnretainedValue()

    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
    let isKeyFrame = !isNotSync

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(blockBuffer,
                                             atOffset: 0,
                                             lengthAtOffsetOut: &lengthAtOffset,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPointer)
    if status != kCMBlockBufferNoErr { return }

    guard let dataPointer = dataPointer else { return }

    var nalData = Data(bytes: dataPointer, count: totalLength)
    if isKeyFrame == false {
        // Already in Annex-B if encoded with VideoToolbox in this configuration.
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let frame = HEVCEncoder.EncodedFrame(data: nalData, presentationTimeStamp: pts, codec: encoder.currentCodec)

    encoder.callbackQueue.async {
        encoder.onFrame?(frame)
    }
}

private extension HEVCEncoder {
    static var isHEVCSupported: Bool {
        if #available(iOS 11.0, *) {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) || VTIsHardwareEncodeSupported(kCMVideoCodecType_HEVC)
        }
        return false
    }
}
