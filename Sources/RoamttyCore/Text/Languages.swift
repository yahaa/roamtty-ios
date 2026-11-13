import Foundation

/// The languages the code preview knows, and how a file or a Markdown fence names one.
public enum Languages {
    public static let plain = CodeLanguage(id: "plaintext", displayName: "Plain Text", mode: .plain)
    public static let kotlin = code("kotlin", "Kotlin", comments: ["//"], words: words([
        .keyword: "package import class interface fun val var object if else when for while return true false null",
        .type: "String Int Boolean Long Double",
        .constant: "true false null"
    ]))
    public static let python = code("python", "Python", comments: ["#"], words: words([
        .keyword: "def class if else elif return import from for while pass",
        .constant: "True False None self"
    ]))
    public static let shell = code("shell", "Shell", comments: ["#"], words: words([
        .keyword: "if then else fi for while do done function",
        .function: "echo printf cd ls rm git ssh"
    ]))
    public static let json = code("json", "JSON", words: words([.constant: "true false null"]))
    public static let javascript = code("javascript", "JavaScript", comments: ["//"], words: words([.keyword: "let const function return class import export", .constant: "true false null"]))
    public static let typescript = code("typescript", "TypeScript", comments: ["//"], words: javascript.words)
    public static let java = code("java", "Java", comments: ["//"], words: words([.keyword: "class public static void if else return import package", .type: "String int boolean"]))
    public static let go = code("go", "Go", comments: ["//"], words: words([.keyword: "func package import if else return var const type struct", .constant: "true false nil"]))
    public static let rust = code("rust", "Rust", comments: ["//"], words: words([.keyword: "fn let mut struct enum impl pub use if else return", .type: "str i32 u8 String", .constant: "true false"]))
    public static let c = code("c", "C", comments: ["//"], words: words([.keyword: "if else return for while struct typedef", .type: "int char void long"]))
    public static let cpp = code("cpp", "C++", comments: ["//"], words: c.words)
    public static let csharp = code("csharp", "C#", comments: ["//"], words: words([.keyword: "class public static void if else return using namespace", .type: "string int bool"]))
    public static let swift = code("swift", "Swift", comments: ["//"], words: words([.keyword: "func let var struct class enum if else return import", .constant: "true false nil"]))
    public static let html = CodeLanguage(id: "html", displayName: "HTML", mode: .markup)
    public static let xml = CodeLanguage(id: "xml", displayName: "XML", mode: .markup)
    public static let markdown = CodeLanguage(id: "markdown", displayName: "Markdown", mode: .markdown)
    public static let yaml = code("yaml", "YAML", comments: ["#"], words: words([.constant: "true false yes no null"]))
    public static let toml = code("toml", "TOML", comments: ["#"])
    public static let ini = code("ini", "Config", comments: ["#", ";"])
    public static let css = code("css", "CSS", words: words([.constant: "inherit initial unset none auto"]))
    public static let scss = code("scss", "SCSS", comments: ["//"], words: css.words)
    public static let sql = code("sql", "SQL", comments: ["--"], words: words([.keyword: "select from where insert update delete create table"]))
    public static let dockerfile = code("dockerfile", "Dockerfile", comments: ["#"], words: words([.keyword: "FROM RUN CMD COPY ADD ENV EXPOSE WORKDIR ENTRYPOINT"]))
    public static let diff = code("diff", "Diff")
    public static let log = code("log", "Log", words: words([.error: "ERROR FATAL", .warning: "WARN WARNING", .info: "INFO"]))
    public static let ruby = code("ruby", "Ruby", comments: ["#"], words: words([.keyword: "def class end if else module require"]))
    public static let php = code("php", "PHP", comments: ["//", "#"], words: words([.keyword: "function class if else return echo"]))
    public static let lua = code("lua", "Lua", comments: ["--"], words: words([.keyword: "function local if then else end return"]))
    public static let dart = code("dart", "Dart", comments: ["//"], words: words([.keyword: "class void if else return import"]))
    public static let makefile = code("makefile", "Makefile", comments: ["#"])
    public static let powershell = code("powershell", "PowerShell", comments: ["#"])
    public static let batch = code("bat", "Batch", comments: ["::"])

    public static func forFence(_ info: String) -> CodeLanguage? {
        let key = info.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: " ").first?.split(separator: "{").first.map(String.init) ?? ""
        return aliases[key]
    }

    public static func detect(fileName: String, firstLine: String = "") -> CodeLanguage {
        let name = fileName.lowercased()
        if let language = byName[name] { return language }
        if name.hasPrefix(".env") { return ini }
        if name.hasPrefix("dockerfile") { return dockerfile }
        if name.hasSuffix("_history") { return shell }
        if let dot = name.lastIndex(of: "."), let language = byExtension[String(name[name.index(after: dot)...])] { return language }
        if firstLine.hasPrefix("#!") { return forShebang(firstLine) }
        if firstLine.hasPrefix("<?xml") || firstLine.hasPrefix("<svg") { return xml }
        if firstLine.lowercased().hasPrefix("<!doctype html") || firstLine.lowercased().hasPrefix("<html") { return html }
        return plain
    }

    /// The language of a script's `#!` line: its interpreter, a shell when it is none we know.
    private static func forShebang(_ firstLine: String) -> CodeLanguage {
        var interpreter = firstLine.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if interpreter.hasPrefix("env ") { interpreter = String(interpreter.dropFirst(4)) }
        interpreter = interpreter.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        if interpreter.hasPrefix("python") { return python }
        if ["node", "deno", "bun"].contains(where: interpreter.hasPrefix) { return javascript }
        if interpreter.hasPrefix("ruby") { return ruby }
        if interpreter.hasPrefix("php") { return php }
        if interpreter.hasPrefix("lua") { return lua }
        if interpreter.hasPrefix("pwsh") { return powershell }
        return shell
    }

    private static func code(_ id: String, _ name: String, comments: [String] = [], words: [String: TokenType] = [:]) -> CodeLanguage {
        CodeLanguage(id: id, displayName: name, lineComments: comments, words: words)
    }
    private static func words(_ groups: [TokenType: String]) -> [String: TokenType] {
        var map: [String: TokenType] = [:]
        for (type, list) in groups { for word in list.split(separator: " ") { map[String(word)] = type } }
        return map
    }
    private static let aliases: [String: CodeLanguage] = [
        "sh": shell, "bash": shell, "shell": shell, "console": shell, "zsh": shell, "js": javascript,
        "javascript": javascript, "ts": typescript, "typescript": typescript, "py": python, "python": python, "kotlin": kotlin,
        "java": java, "go": go, "golang": go, "rust": rust, "c": c, "cpp": cpp,
        "c++": cpp, "csharp": csharp, "cs": csharp, "swift": swift, "dart": dart, "php": php,
        "ruby": ruby, "rb": ruby, "lua": lua, "sql": sql, "json": json, "yaml": yaml,
        "yml": yaml, "toml": toml, "ini": ini, "css": css, "scss": scss, "html": html,
        "xml": xml, "diff": diff, "dockerfile": dockerfile, "docker": dockerfile, "makefile": makefile, "make": makefile,
        "powershell": powershell, "ps1": powershell, "kt": kotlin, "md": markdown, "markdown": markdown
    ]
    private static let byExtension: [String: CodeLanguage] = [
        "kt": kotlin, "kts": kotlin, "gradle": kotlin, "java": java, "groovy": java, "scala": java,
        "js": javascript, "mjs": javascript, "cjs": javascript, "jsx": javascript, "ts": typescript, "tsx": typescript,
        "mts": typescript, "cts": typescript, "py": python, "pyi": python, "pyw": python, "go": go,
        "rs": rust, "c": c, "h": c, "cc": cpp, "cpp": cpp, "cxx": cpp,
        "hpp": cpp, "hh": cpp, "hxx": cpp, "m": c, "mm": cpp, "cs": csharp,
        "swift": swift, "dart": dart, "php": php, "rb": ruby, "rake": ruby, "lua": lua,
        "sql": sql, "sh": shell, "bash": shell, "zsh": shell, "ksh": shell, "fish": shell,
        "ps1": powershell, "psm1": powershell, "bat": batch, "cmd": batch, "json": json, "jsonc": json,
        "json5": json, "geojson": json, "webmanifest": json, "ipynb": json, "yaml": yaml, "yml": yaml,
        "toml": toml, "ini": ini, "conf": ini, "cfg": ini, "properties": ini, "env": ini,
        "service": ini, "desktop": ini, "css": css, "scss": scss, "less": scss, "sass": scss,
        "html": html, "htm": html, "xhtml": html, "vue": html, "svelte": html, "xml": xml,
        "svg": xml, "plist": xml, "xsd": xml, "xsl": xml, "md": markdown, "markdown": markdown,
        "mdx": markdown, "diff": diff, "patch": diff, "log": log, "out": log, "err": log,
        "tf": ini, "dockerfile": dockerfile
    ]
    private static let byName: [String: CodeLanguage] = [
        "dockerfile": dockerfile, "containerfile": dockerfile, "makefile": makefile, "gnumakefile": makefile, "gemfile": ruby, "rakefile": ruby,
        "cmakelists.txt": makefile, ".bashrc": shell, ".bash_profile": shell, ".zshrc": shell, ".profile": shell, ".bash_aliases": shell,
        ".bash_logout": shell, ".zprofile": shell, ".zshenv": shell, "gradlew": shell, ".gitconfig": ini, ".editorconfig": ini,
        ".npmrc": ini, ".gitmodules": ini, ".tmux.conf": ini, "config": ini, "ssh_config": ini, "sshd_config": ini,
        ".gitignore": ini, ".dockerignore": ini, "jenkinsfile": java, "cargo.lock": toml, "pipfile": toml, "go.mod": go
    ]
}
