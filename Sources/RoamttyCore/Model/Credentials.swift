import Foundation

public struct Credentials: Sendable {
    public var password: Data?
    public var privateKey: Data?
    public var passphrase: String?
    public init(password: Data? = nil, privateKey: Data? = nil, passphrase: String? = nil) {
        self.password = password; self.privateKey = privateKey; self.passphrase = passphrase
    }
    public mutating func clear() {
        if let count = password?.count { password?.resetBytes(in: 0..<count) }
        if let count = privateKey?.count { privateKey?.resetBytes(in: 0..<count) }
        password = nil; privateKey = nil; passphrase = nil
    }
}
