import Foundation
import CoreMedia
import CoreVideo
import Libavformat
import Libavcodec

/// Callback type for decoded video frames.
///
/// `hdr10PlusT35` carries the source-frame's HDR10+ dynamic metadata,
/// already serialised to the ITU-T T.35 byte format Apple's
/// `kCMSampleAttachmentKey_HDR10PlusPerFrameData` expects. Nil for
/// non-HDR10+ streams.
typealias DecodedFrameHandler = (CVPixelBuffer, CMTime, Data?) -> Void

/// Common surface for the non-AVPlayer playback host's video decoder.
/// Both `SoftwareVideoDecoder` (libavcodec, used for AV1 / VP9) and
/// `HardwareVideoDecoder` (VTDecompressionSession, used for HEVC)
/// conform; the host swaps the implementation per codec at load time
/// without changing the demux-loop wiring.
protocol VideoDecodingPipeline: AnyObject {
    var onFrame: DecodedFrameHandler? { get set }
    var onFirstHDR10PlusDetected: (() -> Void)? { get set }
    var skipUntilPTS: CMTime? { get set }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws
    func decode(packet: UnsafeMutablePointer<AVPacket>)
    func flush()
    func close()
}

enum VideoDecoderError: Error, LocalizedError {
    case noCodecParameters
    case unsupportedCodec(id: UInt32)
    case noExtradata
    case formatDescriptionFailed(status: OSStatus)
    case sessionCreationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noCodecParameters: "No codec parameters"
        case .unsupportedCodec(let id): "Unsupported video codec (id: \(id))"
        case .noExtradata: "Missing codec extradata"
        case .formatDescriptionFailed(let s): "Format description failed (\(s))"
        case .sessionCreationFailed(let s): "Decoder session failed (\(s))"
        }
    }
}

/// FFmpeg-to-CoreVideo color metadata mapping shared by the SW and HW
/// video decoders (and the HDR gates elsewhere). One source of truth:
/// a new primaries/transfer case (P3-DCI, BT.601, ...) lands in every
/// pipeline at once instead of drifting between hand-kept copies.
enum ColorAttachments {
    static func primaries(_ v: AVColorPrimaries) -> CFString? {
        switch v {
        case AVCOL_PRI_BT709:    kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020:   kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: kCVImageBufferColorPrimaries_P3_D65
        default:                 nil
        }
    }

    static func transfer(_ v: AVColorTransferCharacteristic) -> CFString? {
        switch v {
        case AVCOL_TRC_BT709:        kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084:    kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:                     nil
        }
    }

    static func matrix(_ v: AVColorSpace) -> CFString? {
        switch v {
        case AVCOL_SPC_BT709:                       kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: kCVImageBufferYCbCrMatrix_ITU_R_2020
        default:                                    nil
        }
    }

    /// PQ (ST 2084) or HLG transfer means the stream is HDR.
    static func isHDRTransfer(_ trc: AVColorTransferCharacteristic) -> Bool {
        trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
    }
}
