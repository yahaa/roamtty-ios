// Behavioral port of Roamtty Android's HostSystem helpers.
import Foundation

public enum HostSystem: String, Codable, CaseIterable, Sendable {
    case UNKNOWN, OTHER, LINUX, WINDOWS, MACOS, UBUNTU, DEBIAN, CENTOS, FEDORA, ARCH, REDHAT, OPENSUSE, ROCKY, ALMALINUX, GENTOO, NIXOS, LINUXMINT
    public var label: String {
        switch self {
        case .UNKNOWN: return "未知系统"
        case .OTHER: return "其他系统"
        case .LINUX: return "Linux"
        case .WINDOWS: return "Windows"
        case .MACOS: return "macOS"
        case .UBUNTU: return "Ubuntu"
        case .DEBIAN: return "Debian"
        case .CENTOS: return "CentOS"
        case .FEDORA: return "Fedora"
        case .ARCH: return "Arch Linux"
        case .REDHAT: return "Red Hat Enterprise Linux"
        case .OPENSUSE: return "openSUSE"
        case .ROCKY: return "Rocky Linux"
        case .ALMALINUX: return "AlmaLinux"
        case .GENTOO: return "Gentoo"
        case .NIXOS: return "NixOS"
        case .LINUXMINT: return "Linux Mint"
        }
    }
    public static func fromStored(_ value: String) -> Self { Self(rawValue: value) ?? .UNKNOWN }
}

public enum HostSystemProbe {
    public static let kernelMarker = "__ITERMUX_KERNEL__", releaseMarker = "__ITERMUX_OS_RELEASE__", legacyMarker = "__ITERMUX_LEGACY_RELEASE__"
    public static let windowsCommand = "cmd.exe /c ver"
    public static let script = #"""
    printf '__ITERMUX_KERNEL__\n'; uname -s 2>/dev/null
    printf '__ITERMUX_OS_RELEASE__\n'
    if [ -r /etc/os-release ]; then head -c 4096 /etc/os-release
    elif [ -r /usr/lib/os-release ]; then head -c 4096 /usr/lib/os-release; fi
    printf '\n__ITERMUX_LEGACY_RELEASE__\n'
    if [ -r /etc/centos-release ]; then head -c 512 /etc/centos-release
    elif [ -r /etc/redhat-release ]; then head -c 512 /etc/redhat-release; fi
    exit 0
    """#
    public static func parse(unix: String?, windows: String? = nil) -> HostSystem {
        func section(_ start: String, until end: String?) -> String {
            guard let text = unix, let range = text.range(of: start + "\n") else { return "" }
            let rest = text[range.upperBound...]
            return String(end.flatMap { rest.range(of: $0).map { rest[..<$0.lowerBound] } } ?? rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let kernel = section(kernelMarker, until: releaseMarker).lowercased()
        if kernel == "linux" {
            var values: [String: String] = [:]
            for line in section(releaseMarker, until: legacyMarker).split(whereSeparator: \.isNewline) {
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let at = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<at]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: at)...]).trimmingCharacters(in: .whitespaces)
                for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) { value = String(value.dropFirst().dropLast()) }
                values[key] = value
            }
            let supported: [String: HostSystem] = ["ubuntu": .UBUNTU, "debian": .DEBIAN, "centos": .CENTOS, "fedora": .FEDORA, "arch": .ARCH,
                "rhel": .REDHAT, "opensuse": .OPENSUSE, "opensuse-leap": .OPENSUSE, "opensuse-tumbleweed": .OPENSUSE, "rocky": .ROCKY,
                "almalinux": .ALMALINUX, "gentoo": .GENTOO, "nixos": .NIXOS, "linuxmint": .LINUXMINT]
            if let id = values["ID"], !id.isEmpty { return supported[id.lowercased()] ?? .LINUX }
            let legacy = section(legacyMarker, until: nil).lowercased()
            if legacy.hasPrefix("centos") { return .CENTOS }
            if legacy.hasPrefix("red hat enterprise linux") { return .REDHAT }
            return .LINUX
        }
        if kernel == "darwin" { return .MACOS }
        if ["mingw", "msys", "cygwin"].contains(where: kernel.hasPrefix) { return .WINDOWS }
        if (windows ?? "").range(of: #"(?im)^\s*Microsoft Windows\s+\["#, options: .regularExpression) != nil { return .WINDOWS }
        return ["freebsd", "openbsd", "netbsd", "dragonfly", "sunos", "aix"].contains(kernel) ? .OTHER : .UNKNOWN
    }
}
