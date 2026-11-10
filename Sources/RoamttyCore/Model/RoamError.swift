import Foundation

public enum RoamError: Error, LocalizedError, Equatable {
    case invalid(String), transport(String), authentication, cancelled, timeout, hostKeyChanged(String, String), rejected, sessionLimit, tmuxMissing
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .transport(let s): return s
        case .authentication: return "认证失败 / Authentication failed"
        case .cancelled: return "已取消 / Cancelled"
        case .timeout: return "连接超时 / Connection timed out"
        case .hostKeyChanged: return "服务器指纹已变化 / Host key changed"
        case .rejected: return "未信任服务器 / Host not trusted"
        case .sessionLimit: return "每台主机最多 8 个会话 / Maximum 8 sessions per host"
        case .tmuxMissing: return "主机尚未安装 tmux / tmux is not installed"
        }
    }
}
