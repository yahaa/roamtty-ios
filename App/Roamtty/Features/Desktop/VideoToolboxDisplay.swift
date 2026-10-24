#if canImport(UIKit) && canImport(VideoToolbox) && canImport(CoreMedia)
import SwiftUI
import UIKit
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreImage
import RoamttyDesktopCore

/// Shows H.264 frames with `AVSampleBufferDisplayLayer` (plan §8). SPS/PPS from the first keyframe
/// build the format description; later access units are enqueued as AVCC sample buffers.
/// This file is UIKit/VideoToolbox-only and is **not compiled or verified on Linux**.
final class VideoToolboxDisplay: NSObject, DesktopVideoDisplay {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMFormatDescription?
    private var holders: [AvccHolder] = []
    private var latestKeyframe: ([UInt8], CMFormatDescription)? // accessed only on main
    private let snapshotQueue = DispatchQueue(label: "desktop-snapshot", qos: .utility)
    weak var decoder: DesktopVideoDecoder?
    var onSize: ((Int, Int) -> Void)?

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    #if DEBUG
    func showLayoutFixture() {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 1280, height: 720,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue, .systemYellow]
        for i in 0..<4 {
            context.setFillColor(colors[i].cgColor)
            context.fill(CGRect(x: (i % 2) * 640, y: (i / 2) * 360, width: 640, height: 360))
        }
        context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(16)
        context.stroke(CGRect(x: 8, y: 8, width: 1264, height: 704))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
                                                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        layer.enqueue(sample)
    }
    #endif

    func present(frame: Int64, keyframe: Bool, width: Int, height: Int, annexB: [UInt8], offset: Int, avcc: [UInt8]) {
        if keyframe {
            let (s, p) = H264.spsPps(annexB, offset: offset)
            if let s, let p,
               let f = Self.makeFormat(sps: Array(H264.NAL(bytes: s, type: 7).payload),
                                       pps: Array(H264.NAL(bytes: p, type: 8).payload)) {
                format = f
                onSize?(width, height)
            }
        }
        guard let format, !avcc.isEmpty else { decoder?.session?.needKeyframe(); return }
        guard let sample = Self.makeSample(avcc, format: format, frame: frame, store: &holders) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.layer.status == .failed {
                self.layer.flush()
                self.decoder?.reset()
                return
            }
            if keyframe { self.latestKeyframe = (avcc, format) }
            self.layer.enqueue(sample)
            // No per-frame render callback on older iOS; stamp render ≈ enqueue.
            self.decoder?.didRender(frame: frame, renderedUs: UdpLink.monotonicUs())
            if self.holders.count > 120 { self.holders.removeFirst(self.holders.count - 60) }
        }
    }

    func flush() {
        DispatchQueue.main.async {
            self.layer.flushAndRemoveImage()
            self.holders.removeAll()
            self.latestKeyframe = nil
        }
        format = nil
    }

    /// Copy the displayed frame without rendering the AV layer into a black UIKit screenshot.
    /// Older iOS falls back to decoding one retained keyframe, only at thumbnail cadence.
    @MainActor func snapshot(_ completion: @escaping @MainActor (UIImage?) -> Void) {
        let pixel: CVPixelBuffer?
        if #available(iOS 17.4, *) { pixel = layer.sampleBufferRenderer.displayedPixelBuffer() }
        else { pixel = nil }
        let keyframe = latestKeyframe
        snapshotQueue.async {
            let buffer = pixel ?? keyframe.flatMap { Self.decodeSnapshot($0.0, format: $0.1) }
            let image = buffer.flatMap { buffer -> UIImage? in
                let ci = CIImage(cvPixelBuffer: buffer)
                return CIContext().createCGImage(ci, from: ci.extent).map { UIImage(cgImage: $0) }
            }
            Task { @MainActor in completion(image) }
        }
    }

    private static func decodeSnapshot(_ bytes: [UInt8], format: CMFormatDescription) -> CVPixelBuffer? {
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil,
            decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        var holders: [AvccHolder] = []
        guard let sample = makeSample(bytes, format: format, frame: 0, store: &holders) else { return nil }
        var result: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            if status == noErr { result = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        withExtendedLifetime(holders) {}
        return status == noErr ? result : nil
    }

    private static func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMFormatDescription? {
        var format: CMFormatDescription?
        sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                var pointers = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                var sizes = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        return format
    }

    private static func makeSample(_ avcc: [UInt8], format: CMFormatDescription, frame: Int64,
                                   store: inout [AvccHolder]) -> CMSampleBuffer? {
        let holder = AvccHolder(avcc)
        store.append(holder)
        var block: CMBlockBuffer?
        let err: OSStatus = holder.bytes.withUnsafeBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: raw.baseAddress),
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &block)
        }
        guard err == noErr, let block else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frame, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}

private final class AvccHolder {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
}

/// Hosts the controller's `AVSampleBufferDisplayLayer`.
struct DesktopVideoSurface: UIViewRepresentable {
    let display: VideoToolboxDisplay
    func makeUIView(context: Context) -> DesktopVideoHostView {
        let view = DesktopVideoHostView()
        view.attach(display)
        return view
    }
    func updateUIView(_ uiView: DesktopVideoHostView, context: Context) {
        uiView.attach(display)
    }
}

final class DesktopVideoHostView: UIView {
    private weak var display: VideoToolboxDisplay?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isAccessibilityElement = true
        accessibilityIdentifier = "desktop-video-surface"
        accessibilityLabel = "Remote desktop picture"
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func attach(_ display: VideoToolboxDisplay) {
        if self.display === display { return }
        self.display?.layer.removeFromSuperlayer()
        self.display = display
        layer.addSublayer(display.layer)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        display?.layer.frame = bounds
    }
}
#endif
