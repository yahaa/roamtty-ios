#if canImport(AVFoundation)
import AVFoundation
import Foundation
import os.lock
import RoamttyDesktopCore

/// Microphone permission state for contextual confirmation sheet notices.
enum VoiceMicPermission: Equatable, Sendable {
    case undetermined, granted, denied
}

/// Real-time-safe fixed-capacity mono Float32 ring buffer shared between the voice decode pump
/// and CoreAudio's `AVAudioSourceNode` pull render callback (zero allocations on the audio IO thread).
final class VoicePcmRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let maxQueued: Int
    private let storage: UnsafeMutablePointer<Float>
    private var lock = os_unfair_lock()
    private var readIdx = 0
    private var writeIdx = 0
    private var count = 0

    init(capacity: Int = 14_400, maxQueued: Int = 9_600) {
        self.capacity = capacity
        self.maxQueued = min(capacity, maxQueued)
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var queuedSamples: Int {
        os_unfair_lock_lock(&lock)
        let n = count
        os_unfair_lock_unlock(&lock)
        return n
    }

    /// Appends mono Float32 samples; drops OLDEST samples if overflow would exceed `maxQueued`
    /// so latency never accumulates and newest speech is never discarded.
    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        let n = samples.count
        if n >= maxQueued {
            readIdx = 0
            writeIdx = 0
            count = 0
            let start = n - maxQueued
            for i in 0..<maxQueued {
                storage[i] = samples[start + i]
            }
            writeIdx = maxQueued % capacity
            count = maxQueued
            os_unfair_lock_unlock(&lock)
            return
        }
        if count + n > maxQueued {
            let drop = (count + n) - maxQueued
            readIdx = (readIdx + drop) % capacity
            count -= drop
        }
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            let first = min(n, capacity - writeIdx)
            storage.advanced(by: writeIdx).update(from: base, count: first)
            let rem = n - first
            if rem > 0 {
                storage.update(from: base.advanced(by: first), count: rem)
            }
        }
        writeIdx = (writeIdx + n) % capacity
        count += n
        os_unfair_lock_unlock(&lock)
    }

    /// Non-blocking pull called on CoreAudio's real-time IO thread; fills remaining frames with silence.
    func readRealtime(into dst: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard os_unfair_lock_trylock(&lock) else {
            memset(dst, 0, frameCount * MemoryLayout<Float>.size)
            return
        }
        let take = min(frameCount, count)
        if take > 0 {
            let first = min(take, capacity - readIdx)
            dst.update(from: storage.advanced(by: readIdx), count: first)
            let rem = take - first
            if rem > 0 {
                dst.advanced(by: first).update(from: storage, count: rem)
            }
            readIdx = (readIdx + take) % capacity
            count -= take
        }
        if take < frameCount {
            memset(dst.advanced(by: take), 0, (frameCount - take) * MemoryLayout<Float>.size)
        }
        os_unfair_lock_unlock(&lock)
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        readIdx = 0
        writeIdx = 0
        count = 0
        os_unfair_lock_unlock(&lock)
    }
}

/// Stateful continuous linear resampler (`Int16` mono at `inputRate` -> `Float32` mono at `outputRate`).
/// Preserves interpolation phase and boundary sample across frames to eliminate block-boundary clicks.
final class VoiceLinearResampler {
    let inputRate: Double
    let outputRate: Double
    private let step: Double
    private var phase: Double = 0
    private var prevSample: Float = 0
    private var hasPrev = false

    init(inputRate: Double, outputRate: Double) {
        self.inputRate = max(8_000, inputRate)
        self.outputRate = max(8_000, outputRate)
        self.step = self.inputRate / self.outputRate
    }

    func reset() {
        phase = 0
        prevSample = 0
        hasPrev = false
    }

    func resample(_ samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let scale: Float = 1.0 / 32768.0
        if abs(inputRate - outputRate) < 1.0 {
            prevSample = Float(samples[samples.count - 1]) * scale
            hasPrev = true
            return samples.map { Float($0) * scale }
        }
        let estOut = Int((Double(samples.count) / step).rounded(.up)) + 4
        var out: [Float] = []
        out.reserveCapacity(estOut)
        let n = samples.count
        var pos = phase
        while pos < Double(n) {
            let idx = Int(floor(pos))
            let frac = Float(pos - Double(idx))
            let s0: Float
            let s1: Float
            if idx < 0 {
                s0 = hasPrev ? prevSample : Float(samples[0]) * scale
                s1 = Float(samples[0]) * scale
            } else if idx + 1 < n {
                s0 = Float(samples[idx]) * scale
                s1 = Float(samples[idx + 1]) * scale
            } else {
                s0 = Float(samples[n - 1]) * scale
                s1 = s0
            }
            out.append(s0 + (s1 - s0) * frac)
            pos += step
        }
        phase = pos - Double(n)
        prevSample = Float(samples[n - 1]) * scale
        hasPrev = true
        return out
    }
}

/// Opus speaker pump, format conversion, and level metering helpers for `VoiceAudioEngine`.
extension VoiceAudioEngine {
    func startSpeakerPumpLocked() {
        stopSpeakerPumpLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.pumpOpusSpeakerLocked()
        }
        spkPumpTimer = timer
        timer.resume()
    }

    func stopSpeakerPumpLocked() {
        spkPumpTimer?.cancel()
        spkPumpTimer = nil
    }

    func pumpOpusSpeakerLocked() {
        guard !interrupted, spkStreamId != nil, let jb = spkJitter, let resampler = spkResampler else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let nowMs = Int64(nowNs / 1_000_000)
        var poppedAny = false
        while pcmRing.queuedSamples < Self.pumpTargetRingSamples {
            guard let samples = jb.popFrame(nowMs: nowMs) else { break }
            poppedAny = true
            updateSpeakerLevel(samples: samples)
            pcmRing.write(resampler.resample(samples))
            lastSpeakerAudioNs = nowNs
        }
        let silentNs = nowNs > lastSpeakerAudioNs ? nowNs - lastSpeakerAudioNs : 0
        if !poppedAny && pcmRing.queuedSamples == 0 && smoothedSpkLevel > 0 && silentNs > Self.speakerSilenceDecayNs {
            resetSpeakerLevel()
        }
    }

    func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard input.format == converter.inputFormat else { return nil }
        let ratio = format.sampleRate / max(1, input.format.sampleRate)
        let capacity = max(1, AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var status: AVAudioConverterOutputStatus = .error
        var err: NSError?
        let ok = RoamttyAudioConverterConvert(converter, input, output, &status, &err)
        guard ok, status != .error, output.frameLength > 0 else {
            if let err { logAudioError("converter.convert", err) }
            return nil
        }
        return output
    }

    func updateMicLevel(samples: UnsafePointer<Int16>, count: Int) {
        var sumSq = 0.0
        for i in 0..<count {
            let s = Double(samples[i]) / 32768.0
            sumSq += s * s
        }
        let rms = Float(min(1.0, (sumSq / Double(max(1, count))).squareRoot() * 3.2))
        smoothedMicLevel = smoothedMicLevel * 0.65 + rms * 0.35
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastEmittedMicNs >= Self.levelThrottleNs,
              abs(smoothedMicLevel - lastEmittedMicLevel) > Self.levelMinDelta else { return }
        lastEmittedMicNs = now
        lastEmittedMicLevel = smoothedMicLevel
        onMicLevel?(smoothedMicLevel)
    }

    func updateSpeakerLevel(samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var sumSq = 0.0
        for sample in samples {
            let s = Double(sample) / 32768.0
            sumSq += s * s
        }
        let rms = Float(min(1.0, (sumSq / Double(samples.count)).squareRoot() * 2.8))
        smoothedSpkLevel = smoothedSpkLevel * 0.55 + rms * 0.45
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - lastEmittedSpkNs
        let activeFlip = (smoothedSpkLevel > 0.01) != (lastEmittedSpkLevel > 0.01)
        let deltaChanged = elapsed >= Self.levelThrottleNs && abs(smoothedSpkLevel - lastEmittedSpkLevel) > Self.levelMinDelta
        let keepalive = smoothedSpkLevel > 0.01 && elapsed >= Self.speakerKeepaliveNs
        guard activeFlip || deltaChanged || keepalive else { return }
        lastEmittedSpkNs = now
        lastEmittedSpkLevel = smoothedSpkLevel
        onSpeakerLevel?(smoothedSpkLevel)
    }

    func resetMicLevel() {
        smoothedMicLevel = 0
        lastEmittedMicNs = 0
        if lastEmittedMicLevel != 0 {
            lastEmittedMicLevel = 0
            onMicLevel?(0)
        }
    }

    func resetSpeakerLevel() {
        smoothedSpkLevel = 0
        lastEmittedSpkNs = 0
        if lastEmittedSpkLevel != 0 {
            lastEmittedSpkLevel = 0
            onSpeakerLevel?(0)
        }
    }
}
#endif
