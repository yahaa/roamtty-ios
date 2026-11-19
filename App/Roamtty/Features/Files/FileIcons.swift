import SwiftUI
import RoamttyCore

// Generated from Android's FileIconTheme.kt: editor-style badges for languages, tinted glyphs for media and documents.
enum FileIconSpec: Equatable {
    case badge(String, UInt32, label: UInt32 = 0xFFFFFF)
    case glyph(RemoteFileKind, UInt32)
    case folder(UInt32)
    /// The Android robot, for app packages.
    case android(UInt32 = 0x3DDC84)
}

enum FileIconTheme {
    static func spec(name: String, directory: Bool, permissions: UInt32 = 0) -> FileIconSpec {
        let lower = name.lowercased()
        if directory { return .folder(folderColors[lower] ?? defaultFolder) }
        if let spec = byName[lower] { return spec }
        if lower.hasPrefix(".env"), let env = byExtension["env"] { return env }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return docker }
        if lower.hasSuffix(".d.ts") { return ts }
        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, let spec = byExtension[ext] { return spec }
        let kind = remoteFileKind(name: name, isDirectory: false, permissions: permissions)
        return .glyph(kind, glyphColor(kind))
    }
    private static func glyphColor(_ kind: RemoteFileKind) -> UInt32 {
        switch kind {
        case .image: return 0x26A69A
        case .audio: return 0xEC407A
        case .video: return 0xFF7043
        case .archive: return 0xAF8F5A
        case .pdf: return 0xE53935
        case .document: return 0x2B7CD3
        case .spreadsheet: return 0x21A366
        case .presentation: return 0xD24726
        case .executable: return 0x4CAF50
        case .code: return 0x7986CB
        case .config: return 0x6D8086
        case .text: return 0x90A4AE
        case .directory: return defaultFolder
        case .file: return 0x90A4AE
        }
    }
    static func glyphIcon(_ kind: RemoteFileKind) -> String {
        switch kind {
        case .directory: return "ic_folder"
        case .text: return "ic_file_text"
        case .code: return "ic_file_code"
        case .config: return "ic_file_config"
        case .image: return "ic_image"
        case .audio: return "ic_file_audio"
        case .video: return "ic_file_video"
        case .archive: return "ic_file_archive"
        case .pdf: return "ic_file_pdf"
        case .document: return "ic_file_document"
        case .spreadsheet: return "ic_file_spreadsheet"
        case .presentation: return "ic_file_presentation"
        case .executable: return "ic_file_executable"
        case .file: return "ic_file"
        }
    }
}
