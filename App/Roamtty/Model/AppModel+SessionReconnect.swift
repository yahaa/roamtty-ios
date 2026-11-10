import Foundation
import RoamttyCore

/// Sessions that dropped, or came back from the journal, reconnect by themselves.
extension AppModel {
    // MARK: Reconnecting by itself

    /// Opening a dropped or restored terminal reconnects it, at most once per `SessionReconnect.interval`.
    func reconnectOnOpen(_ record: SessionRecord) async {
        guard SessionReconnect.onOpen(sessionEnd(record)) else { return }
        let wait = SessionReconnect.delay(lastAttempt: autoReconnectedAt[record.id], now: Date())
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled, foreground, records.contains(record), SessionReconnect.onOpen(sessionEnd(record)) else { return }
        autoReconnectedAt[record.id] = Date()
        reconnect(record)
    }
    func beginSessionListVisit() { retriedThisVisit = [] }
    /// While the session list is on screen, sessions that dropped, came back from the journal or lost the network
    /// reconnect by themselves: only on hosts that need nothing typed, and only once the host answers again.
    func reconnectFromList() {
        guard foreground else { return }
        let now = Date()
        for record in records where !retriedThisVisit.contains(record.id) {
            let end = sessionEnd(record)
            // This runs every two seconds: the session's own state rules it out before its host's login is read
            // from the Keychain.
            guard SessionReconnect.fromList(end), SessionReconnect.delay(lastAttempt: autoReconnectedAt[record.id], now: now) == 0,
                  let host = host(record.hostID), logins.canLoginSilently(host) else { continue }
            // An offline host is left alone, not retried on every visit: a fresh probe must find its sshd first.
            if !hostConnected(host) {
                let since: Date
                if let waiting = waitingForHostSince[record.id] { since = waiting } else { since = now; waitingForHostSince[record.id] = now; Task { await reachability.probe([host]) } }
                guard SessionReconnect.hostBack(online: reachability[host.id]?.isOnline == true, checkedAt: reachability.checkedAt(host.id), since: since) else { continue }
            }
            waitingForHostSince.removeValue(forKey: record.id)
            // A host still out of reach is tried once per visit, not every few seconds.
            if !SessionReconnect.onOpen(end) { retriedThisVisit.insert(record.id) }
            autoReconnectedAt[record.id] = now
            if runtimes[record.id] == nil { connectSession(record) } else { reconnect(record) }
        }
    }
}
