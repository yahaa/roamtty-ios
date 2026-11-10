import RoamttyCore

/// What the connection services (`HostLogins`, `HostConnectionPool`, `HostMonitor`) ask of the app around them.
/// They depend on this, not on `AppModel`, which is what provides it.
@MainActor protocol ConnectionEnvironment: AnyObject {
    /// In the background nothing logs in and nothing waits for the user.
    var foreground: Bool { get }
    /// Where host keys the user trusted are kept; nil when the store could not be opened.
    var pinStore: PinStore? { get }
    /// The saved host, nil once it was deleted.
    func host(_ id: String) -> Host?
    func text(_ chinese: String, _ english: String) -> String
}
