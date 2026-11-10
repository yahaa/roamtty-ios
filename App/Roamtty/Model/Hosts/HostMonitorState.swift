import RoamttyCore

/// Where a host page's metrics monitor stands.
struct HostMonitorState {
    var phase: ConnectionPhase
    var reconnecting = false
    var sampled = false
    var detail: String?
    /// The collectors ran but returned nothing usable: a permissions problem, not a lost login.
    var samplingFailed = false
}
