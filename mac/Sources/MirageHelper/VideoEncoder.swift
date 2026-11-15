import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import MirageCore

public struct EncodedFrame: Sendable {
    public let header: VideoHeader
    public let data: Data
    public let encodeLatencyMicros: UInt64

    public init(header: VideoHeader, data: Data, encodeLatencyMicros: UInt64 = 0) {
        self.header = header
        self.data = data
        self.encodeLatencyMicros = encodeLatencyMicros
    }
}

public enum VideoEncoderError: Error {
    case createFailed(OSStatus)
    case encodeFailed(OSStatus)
}

public final class VideoEncoder: @unchecked Sendable {
    public var onFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private var frameID: UInt32 = 0
    private var parameterSets: [Data] = []
    private let debug = ProcessInfo.processInfo.environment["MIRAGE_DEBUG"] == "1"

    public init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        var session: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VideoEncoderError.createFailed(status)
        }
        self.session = session

        setProperty(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        setProperty(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        setProperty(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        setProperty(
            kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray
        )
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    public func setBitrate(_ bitrate: Int) {
        setProperty(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        setProperty(
            kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray
        )
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) throws {
        guard let session else { return }
        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            throw VideoEncoderError.encodeFailed(status)
        }
    }

    public func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func setProperty(_ key: CFString, _ value: CFTypeRef?) {
        guard let session, let value else { return }
        VTSessionSetProperty(session, key: key, value: value)
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr, let refcon, let sampleBuffer else { return }
        Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue().handle(sampleBuffer)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        updateParameterSets(from: format)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        )
        guard status == noErr, let pointer else { return }

        let avcc = Data(bytes: pointer, count: length)
        let nalUnits = splitAVCC(avcc)
        guard !nalUnits.isEmpty else { return }

        let isKeyframe = !isNotSync(sampleBuffer)
        let units = isKeyframe ? parameterSets + nalUnits : nalUnits
        let data = annexB(nalUnits: units)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundHalfAwayFromZero).value))
        frameID &+= 1
        if debug && frameID % 60 == 0 {
            print("encoded_frames=\(frameID) keyframe=\(isKeyframe)")
            fflush(stdout)
        }

        let header = VideoHeader(
            codec: 1,
            flags: isKeyframe ? 1 : 0,
            frameID: frameID,
            captureTimestampMicros: micros,
            reserved: 0
        )
        let now = monotonicMicros()
        let encodeLatency = now >= micros ? now - micros : 0
        onFrame?(EncodedFrame(header: header, data: data, encodeLatencyMicros: encodeLatency))
    }

    private func isNotSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let list = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = list.first else {
            return false
        }
        return attachments[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
    }

    private func updateParameterSets(from format: CMVideoFormatDescription) {
        guard parameterSets.isEmpty else { return }

        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        )

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        parameterSets = sets
    }
}