#if canImport(UIKit) && canImport(VideoToolbox) && canImport(CoreMedia)
import SwiftUI
import UIKit
import AVFoundation
import VideoToolbox
import CoreMedia
import RoamttyDesktopCore

/// Shows H.264 frames with `AVSampleBufferDisplayLayer` (plan §8). SPS/PPS from the first keyframe
/// build the format description; later access units are enqueued as AVCC sample buffers.
/// This file is UIKit/VideoToolbox-only and is **not compiled or verified on Linux**.
final class VideoToolboxDisplay: NSObject, DesktopVideoDisplay {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMFormatDescription?
    private var holders: [AvccHolder] = []
    weak var decoder: DesktopVideoDecoder?
    var onSize: ((Int, Int) -> Void)?

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

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
        }
        format = nil
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
