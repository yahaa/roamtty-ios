import Foundation

/// The 250 ms tick of a running stream: pings, the poor-link verdict and the statistics.
extension DesktopSession {
    func tick() {
        let now = Self.nowMs()
        if sync({ keyframes.pending }) { askKeyframe() }
        sendPings(nowUs: Self.nowUs())
        let l = sync { link }
        updateLinkQuality(l, now: now)
        publishStats(l, now: now)
    }

    private func sendPings(nowUs: Int64) {
        if let p = sync({ ping.due(nowUs: nowUs) }) { send(DesktopProtocol.ping(p)) }
        // A ping unanswered past 300 ms is sent again (UDP may have dropped it); two in a row, or a slow
        // answer, is a poor link. Five clean seconds restore it.
        if let p = sync({ ping.resendIfLate(nowUs: nowUs, lateMs: Self.POOR_MS) }) { send(DesktopProtocol.ping(p)) }
    }

    private func updateLinkQuality(_ l: UdpLink?, now: Int64) {
        let (rtt, missed) = sync { (ping.rttMs, ping.missed) }
        // On UDP the link itself says it: heartbeats answer every 250 ms, so 700 ms without a datagram is
        // a stall; heavy loss counts too. Lost pings there are just loss.
        let bad: Bool
        if let l, l.alive { bad = l.silentUs > 700_000 || l.loss > 0.25 || Int64(rtt) > Self.POOR_MS } else { bad = missed >= 2 || Int64(rtt) > Self.POOR_MS }
        let newPhase: DesktopPhase? = sync {
            if bad { goodSinceMs = 0 } else if goodSinceMs == 0 { goodSinceMs = now }
            guard case .connected(let wasPoor, let paused) = _phase else { return nil }
            let poor = bad || (wasPoor && now - goodSinceMs < 5000)
            return poor != wasPoor ? .connected(poor: poor, paused: paused) : nil
        }
        if let newPhase { setPhase(newPhase) }
    }

    /// Once a second: what the last second's frames amount to.
    private func publishStats(_ l: UdpLink?, now: Int64) {
        guard let (seconds, frames, bytes) = sync({ traffic.take(nowMs: now) }) else { return }
        let udp = l?.alive ?? false
        let taken = latency.take()
        let sink = video
        let sound = audio
        let audioMs: Int? = sync {
            guard let sound, sound.packets != audioPacketsSeen else { return nil }
            audioPacketsSeen = sound.packets
            return sound.queuedMs
        }
        updateStats { s in
            s.fps = Int(Double(frames) / seconds)
            s.kbps = Int(Double(bytes) * 8 / 1000 / seconds)
            s.decoder = sink?.decoderName ?? s.decoder
            s.frames = sink?.decodedFrames ?? s.frames
            s.link = udp ? "UDP" : "SSH"
            s.lossPercent = udp ? (l?.loss ?? 0) * 100 : nil
            s.fecRecovered = l?.fecRecovered ?? 0
            s.lostFrames = l?.lostMessages ?? 0
            // A still screen sends no frames: the last measured second stands.
            s.latency = taken ?? s.latency
            s.audioMs = audioMs
        }
    }
}
