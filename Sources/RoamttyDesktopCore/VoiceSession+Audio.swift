import Foundation

/// Audio frame dispatch (`MIC_*`, `SPK_*`, `SPK_OPUS`, `VOICE_STATS`) and Opus/PCM uplink for `VoiceSession`.
extension VoiceSession {
    func handle(_ message: VoiceServerMessage, epoch: UUID? = nil) {
        handleLock.lock()
        defer { handleLock.unlock() }
        guard sync({ !closing && (epoch == nil || transportEpoch == epoch) }) else { return }
        switch message {
        case .micStart(let id, let rate, let ch): handleMicStart(streamId: id, sampleRate: rate, channels: ch)
        case .micStop(let id): handleMicStop(streamId: id)
        case .spkStart(let id, let rate, let ch): handleSpeakerStart(streamId: id, sampleRate: rate, channels: ch)
        case .spkAudio(let id, let pcm): handleSpeakerPcm(streamId: id, pcm: pcm)
        case .spkOpus(let pkt): handleSpeakerOpus(pkt)
        case .voiceStats(let st): handleVoiceStats(st)
        case .spkClear(let id): handleSpeakerClear(streamId: id, turn: nil)
        case .spkClearTurn(let id, let turn): handleSpeakerClear(streamId: id, turn: turn)
        case .spkStop(let id): handleSpeakerStop(streamId: id)
        case .state(let st): handleState(st)
        case .ping(let t1): let now = Self.nowUs(); sendFrame(VoiceProtocol.pong(t1, now, now), reliable: false)
        case .pong(let t1, _, _): _ = sync { ping.answer(t1: t1, nowUs: Self.nowUs()) }
        }
    }

    private func handleMicStart(streamId: UInt32, sampleRate: UInt32, channels: UInt8) {
        let accepted = sync { () -> Bool in
            guard !closing, activeMicStreamId != streamId, !closedMicIds.contains(streamId) else { return false }
            if let old = activeMicStreamId { closedMicIds.insert(old) }
            micPending.removeAll(keepingCapacity: true)
            activeMicStreamId = streamId
            micSender = voiceOpusEnabled && channels == 1 && VoiceOpusMath.isOpusSampleRate(sampleRate)
                ? VoiceRedSender(streamId: streamId, sampleRate: sampleRate, enableDtx: false)
                : nil
            return true
        }
        guard accepted else { return }
        audioIO?.startMic(streamId: streamId, sampleRate: sampleRate, channels: channels) { [weak self] id, pcm in
            self?.sendMicPcm(streamId: id, pcm: pcm)
        }
        if isClosing { audioIO?.stopAll(); return }
        mediaStarted()
        emit(.micStarted(streamId: streamId, sampleRate: sampleRate))
    }

    private func handleMicStop(streamId: UInt32) {
        let matched = sync { () -> Bool in
            closedMicIds.insert(streamId)
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

    private func handleSpeakerClear(streamId: UInt32, turn: UInt32?) {
        guard sync({
            guard !closing, activeSpkStreamId == streamId || drainingSpeakerId == streamId else { return false }
            if let turn {
                if let previous = lastSpeakerClearTurn, Int32(bitPattern: turn &- previous) <= 0 { return false }
                lastSpeakerClearTurn = turn
            }
            return true
        }) else { return }
        audioIO?.clearSpeaker(streamId: streamId, turn: turn)
        emit(.speakerCleared(streamId: streamId))
    }

    private func handleSpeakerStop(streamId: UInt32) {
        let matched = sync { () -> Bool in
            closedSpeakerIds.insert(streamId)
            guard activeSpkStreamId == streamId else { return false }
            activeSpkStreamId = nil
            drainingSpeakerId = streamId
            return true
        }
        guard matched else { return }
        let epoch = sync { transportEpoch }
        let drained = { [weak self] in
            guard let self else { return }
            let ended = self.sync {
                guard !self.closing, self.transportEpoch == epoch, self.drainingSpeakerId == streamId else { return false }
                self.drainingSpeakerId = nil
                return true
            }
            if ended { self.emit(.speakerStopped(streamId: streamId)) }
        }
        if let audioIO { audioIO.finishSpeaker(streamId: streamId, completion: drained) } else { drained() }
    }

    private func handleState(_ st: StateMessage) {
        if st.kicked { let s = sync { kicked = true; return stream }; s?.close(); wakeAll() }
        if let e = st.error { line(e) }
    }

    private func handleSpeakerStart(streamId: UInt32, sampleRate: UInt32, channels: UInt8) {
        guard sync({ !closing && !closedSpeakerIds.contains(streamId) }) else { return }
        if sync({ activeSpkStreamId == streamId }) {
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: true), reliable: true, fecRatio: 1.0)
            return
        }
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
                if let old = activeSpkStreamId { closedSpeakerIds.insert(old) }
                lastSpeakerClearTurn = nil
                activeSpkStreamId = streamId; return true
            }
            guard accepted else { audioIO?.stopAll(); return }
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: true), reliable: true, fecRatio: 1.0)
            mediaStarted()
            emit(.speakerStarted(streamId: streamId, sampleRate: sampleRate))
        case .failure(let error):
            guard !isClosing else { return }
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: false, error: error.description), reliable: true, fecRatio: 1.0)
        }
    }

    private func mediaStarted() {
        let ready: VoiceSessionPhase? = sync {
            guard !hadMediaThisAttempt, !closing else { return nil }
            hadMediaThisAttempt = true
            everConnected = true
            guard config.backend == .codex, let hello = _hello else { return nil }
            return .ready(micPort: hello.micPort, udp: link?.alive ?? false)
        }
        if let ready { setPhase(ready) }
    }

    /// Accumulate partial hardware callbacks until the encoder has a complete 20 ms frame.
    public func sendMicPcm(streamId: UInt32, pcm: [UInt8]) {
        let count = pcm.count & ~1
        guard count > 0 else { return }
        sync {
            guard !closing, !_muted, activeMicStreamId == streamId else { return }
            if let sender = micSender {
                micPending.append(contentsOf: pcm.prefix(count))
                let size = sender.frameBytes
                var offset = 0
                while micPending.count - offset >= size {
                    if let packet = sender.encodePcm20ms(Array(micPending[offset..<(offset + size)])) {
                        sendFrame(VoiceProtocol.micOpus(packet), reliable: false, fecRatio: 0)
                    }
                    offset += size
                }
                micPending.removeFirst(offset)
            } else {
                for offset in stride(from: 0, to: count, by: VoiceProtocol.micChunkBytes) {
                    let end = min(count, offset + VoiceProtocol.micChunkBytes)
                    sendFrame(VoiceProtocol.micAudio(streamId: streamId, pcm: Array(pcm[offset..<end])), reliable: false, fecRatio: 1)
                }
            }
        }
    }
}
