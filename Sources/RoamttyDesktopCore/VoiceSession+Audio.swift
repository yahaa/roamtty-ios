import Foundation

/// Audio frame dispatch (`MIC_*`, `SPK_*`, `SPK_OPUS`, `VOICE_STATS`) and Opus/PCM uplink for `VoiceSession`.
extension VoiceSession {
    func handle(_ message: VoiceServerMessage) {
        handleLock.lock()
        defer { handleLock.unlock() }
        guard !isClosing else { return }
        switch message {
        case .micStart(let id, let rate, let ch): handleMicStart(streamId: id, sampleRate: rate, channels: ch)
        case .micStop(let id): handleMicStop(streamId: id)
        case .spkStart(let id, let rate, let ch): handleSpeakerStart(streamId: id, sampleRate: rate, channels: ch)
        case .spkAudio(let id, let pcm): handleSpeakerPcm(streamId: id, pcm: pcm)
        case .spkOpus(let pkt): handleSpeakerOpus(pkt)
        case .voiceStats(let st): handleVoiceStats(st)
        case .spkClear(let id): handleSpeakerClear(streamId: id)
        case .spkStop(let id): handleSpeakerStop(streamId: id)
        case .state(let st): handleState(st)
        case .ping(let t1): let now = Self.nowUs(); sendFrame(VoiceProtocol.pong(t1, now, now), reliable: false)
        case .pong(let t1, _, _): _ = sync { ping.answer(t1: t1, nowUs: Self.nowUs()) }
        }
    }

    private func handleMicStart(streamId: UInt32, sampleRate: UInt32, channels: UInt8) {
        let accepted = sync { () -> Bool in
            guard !closing else { return false }
            activeMicStreamId = streamId
            micSender = voiceOpusEnabled && VoiceOpusMath.isOpusSampleRate(sampleRate)
                ? VoiceRedSender(streamId: streamId, sampleRate: sampleRate, enableDtx: true)
                : nil
            return true
        }
        guard accepted else { return }
        audioIO?.startMic(streamId: streamId, sampleRate: sampleRate, channels: channels) { [weak self] id, pcm in
            self?.sendMicPcm(streamId: id, pcm: pcm)
        }
        if isClosing { audioIO?.stopAll(); return }
        emit(.micStarted(streamId: streamId, sampleRate: sampleRate))
    }

    private func handleMicStop(streamId: UInt32) {
        let matched = sync { () -> Bool in
            guard activeMicStreamId == streamId else { return false }
            activeMicStreamId = nil
            if micSender?.streamId == streamId { micSender = nil }
            return true
        }
        if matched { audioIO?.stopMic(streamId: streamId); emit(.micStopped(streamId: streamId)) }
    }

    private func handleSpeakerPcm(streamId: UInt32, pcm: [UInt8]) {
        guard sync({ !closing && activeSpkStreamId == streamId }) else { return }
        audioIO?.playSpeaker(streamId: streamId, pcm: pcm)
        emit(.speakerAudio(streamId: streamId, bytes: pcm.count))
    }

    private func handleSpeakerOpus(_ pkt: VoiceOpusPacket) {
        guard sync({ !closing && activeSpkStreamId == pkt.streamId }) else { return }
        audioIO?.playSpeakerOpus(streamId: pkt.streamId, packet: pkt)
        emit(.speakerAudio(streamId: pkt.streamId, bytes: max(1, pkt.primary.count)))
    }

    private func handleVoiceStats(_ st: VoiceStats) {
        let nowMs = Self.nowUs() / 1000
        sync {
            lastUplinkStats = st
            if let sender = micSender, sender.streamId == st.streamId {
                sender.onPeerStats(st, nowMs: nowMs)
            }
        }
    }

    private func handleSpeakerClear(streamId: UInt32) {
        guard sync({ !closing && activeSpkStreamId == streamId }) else { return }
        audioIO?.clearSpeaker(streamId: streamId)
        emit(.speakerCleared(streamId: streamId))
    }

    private func handleSpeakerStop(streamId: UInt32) {
        let matched = sync { () -> Bool in
            guard activeSpkStreamId == streamId else { return false }
            activeSpkStreamId = nil; return true
        }
        if matched { audioIO?.stopSpeaker(streamId: streamId); emit(.speakerStopped(streamId: streamId)) }
    }

    private func handleState(_ st: StateMessage) {
        if st.kicked { let s = sync { kicked = true; return stream }; s?.close(); wakeAll() }
        if let e = st.error { line(e) }
    }

    private func handleSpeakerStart(streamId: UInt32, sampleRate: UInt32, channels: UInt8) {
        guard !isClosing else { return }
        guard VoiceProtocol.speakerRateRange.contains(sampleRate), channels == 1 else {
            let err = "unsupported format \(sampleRate)Hz \(channels)ch"
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: false, error: err), reliable: true, fecRatio: 1.0)
            return
        }
        let result = audioIO?.startSpeaker(streamId: streamId, sampleRate: sampleRate, channels: channels) ?? .success(())
        switch result {
        case .success:
            let accepted = sync { () -> Bool in
                guard !closing else { return false }
                activeSpkStreamId = streamId; return true
            }
            guard accepted else { audioIO?.stopAll(); return }
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: true), reliable: true, fecRatio: 1.0)
            emit(.speakerStarted(streamId: streamId, sampleRate: sampleRate))
        case .failure(let error):
            guard !isClosing else { return }
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: false, error: error.description), reliable: true, fecRatio: 1.0)
        }
    }

    /// Sends captured 16 kHz mono s16le PCM as Opus+RED frames when negotiated (single UDP shard, DTX),
    /// otherwise falls back to legacy single-shard PCM16 (`<= 640 B`).
    public func sendMicPcm(streamId: UInt32, pcm: [UInt8]) {
        let alignedCount = pcm.count & ~1
        let (ok, useOpus) = sync { (!closing && !_muted && activeMicStreamId == streamId, voiceOpusEnabled) }
        guard alignedCount > 0, ok else { return }
        let chunk = VoiceProtocol.micChunkBytes
        var offset = 0
        while offset < alignedCount {
            let end = min(offset + chunk, alignedCount)
            let slice = Array(pcm[offset..<end])
            if useOpus {
                let encoded: VoiceOpusPacket? = sync {
                    guard let sender = micSender, sender.streamId == streamId else { return nil }
                    return sender.encodePcm20ms(slice)
                }
                if let pkt = encoded {
                    sendFrame(VoiceProtocol.micOpus(pkt), reliable: false, fecRatio: 0.0)
                }
            } else {
                sendFrame(VoiceProtocol.micAudio(streamId: streamId, pcm: slice), reliable: false, fecRatio: 1.0)
            }
            offset = end
        }
    }
}
