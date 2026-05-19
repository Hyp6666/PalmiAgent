import Foundation

struct SandboxTerminalRun: Sendable {
    let transcript: String
    let artifactURL: URL
}

@MainActor
final class SandboxTerminalService {
    private let workspaceManager: WorkspaceManager
    private let javaScriptSandboxService: JavaScriptSandboxService

    init(workspaceManager: WorkspaceManager, javaScriptSandboxService: JavaScriptSandboxService) {
        self.workspaceManager = workspaceManager
        self.javaScriptSandboxService = javaScriptSandboxService
    }

    func capabilityReport(focus: String? = nil) -> String {
        let sections: [(tag: String, body: String)] = [
            ("filesystem", """
            工作区文件系统：
            - 在 app 自己的沙盒工作区内读写文件：可用
            - 递归列目录、创建目录、删除文件：可用
            - 把多种文本型文件统一读取成纯文本：可用
            - 访问工作区外部路径：不可用
            """),
            ("javascript", """
            JavaScriptCore：
            - 运行内联 JS：可用
            - 运行工作区 JS 文件：可用
            - 从 JS 读写工作区文件：可用
            - Node.js / npm 生态：不可用
            """),
            ("python", """
            Python 沙盒：
            - 运行内联 Python：可用
            - 运行工作区 .py 文件：可用
            - 计算、统计、CSV/JSON 处理、工作区文本读写：可用
            \(PythonPackageCatalog.capabilitySummary)
            - pip 动态装包 / 任意子进程：不可用
            """),
            ("terminal", """
            受控终端层：
            - help、pwd、ls、tree、mkdir、write、append、cat、rm：可用
            - js <file> / js -e <script>：可用
            - bash / zsh / 任意子进程：不可用
            """),
            ("network", """
            网络能力：
            - 通过 URLSession 抓取网页：可用
            - 批量并发抓取：可用
            - 浏览器内打开 URL：可用
            """),
            ("ios", """
            iOS 系统能力：
            - 日历、提醒事项、联系人、定位、地图：可用（受权限限制）
            - 相机、相册、文档扫描、实时文本、通知、语音：可用（受权限限制）
            - App Intents、Handoff、Spotlight：可用
            """)
        ]

        guard let focus, !focus.isEmpty else {
            return sections.map(\.body).joined(separator: "\n\n")
        }

        if let section = sections.first(where: { $0.tag.localizedCaseInsensitiveContains(focus) }) {
            return section.body
        }
        return "没有找到与 \(focus) 对应的能力分组。\n\n" + sections.map(\.body).joined(separator: "\n\n")
    }

    func runDemoSession() throws -> SandboxTerminalRun {
        if try !workspaceManager.itemExists(at: "sandbox-demo.js") {
            _ = try javaScriptSandboxService.writeDemoScript()
        }

        let script = """
        help
        pwd
        mkdir notes
        write notes/plan.txt "1. 封装工作区 API"
        append notes/plan.txt "\\n2. 补过程型终端算子"
        cat notes/plan.txt
        ls notes
        js -e "console.log('cwd=' + workspace.pwd()); console.log(workspace.listTree('.'));"
        js sandbox-demo.js
        tree
        """
        return try run(script: script)
    }

    func run(script: String) throws -> SandboxTerminalRun {
        let lines = script
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var transcript: [String] = []
        for line in lines {
            transcript.append("$ \(line)")
            let output = try execute(line: line)
            transcript.append(output.isEmpty ? "(无输出)" : output)
        }

        let fullTranscript = transcript.joined(separator: "\n")
        let artifactURL = try workspaceManager.writeText(fullTranscript, to: "logs/terminal-transcript.txt")
        return SandboxTerminalRun(transcript: fullTranscript, artifactURL: artifactURL)
    }

    private func execute(line: String) throws -> String {
        let tokens = try tokenize(line)
        guard let command = tokens.first else {
            return ""
        }

        switch command {
        case "help":
            return """
            可用命令：
            - pwd
            - ls [path]
            - tree [path]
            - mkdir <path>
            - write <path> <text>
            - append <path> <text>
            - cat <path>
            - rm <path>
            - js <script-path>
            - js -e <inline-script>
            """
        case "pwd":
            return try workspaceManager.rootPath()
        case "ls":
            let path = argument(at: 1, from: tokens) ?? "."
            let names = try workspaceManager.listEntryNames(at: path)
            return names.isEmpty ? "(空目录)" : names.joined(separator: "\n")
        case "tree":
            let path = argument(at: 1, from: tokens) ?? "."
            return try workspaceManager.directoryTree(at: path)
        case "mkdir":
            let path = try requiredArgument(at: 1, from: tokens, usage: "mkdir <path>")
            let url = try workspaceManager.createDirectory(at: path)
            return "created \(url.lastPathComponent)"
        case "write":
            let path = try requiredArgument(at: 1, from: tokens, usage: "write <path> <text>")
            let content = try requiredRemainder(from: tokens, startingAt: 2, usage: "write <path> <text>")
            let url = try workspaceManager.writeText(content, to: path)
            return "wrote \(url.lastPathComponent)"
        case "append":
            let path = try requiredArgument(at: 1, from: tokens, usage: "append <path> <text>")
            let content = try requiredRemainder(from: tokens, startingAt: 2, usage: "append <path> <text>")
            let url = try workspaceManager.appendText(content, to: path)
            return "appended \(url.lastPathComponent)"
        case "cat":
            let path = try requiredArgument(at: 1, from: tokens, usage: "cat <path>")
            return try workspaceManager.readText(at: path)
        case "rm":
            let path = try requiredArgument(at: 1, from: tokens, usage: "rm <path>")
            try workspaceManager.removeItem(at: path)
            return "removed \(path)"
        case "js":
            return try runJavaScript(tokens: tokens)
        default:
            throw AppError.unsupported("不支持的命令：\(command)")
        }
    }

    private func runJavaScript(tokens: [String]) throws -> String {
        if tokens.count >= 3 && tokens[1] == "-e" {
            let inlineSource = try requiredRemainder(from: tokens, startingAt: 2, usage: "js -e <script>")
            let result = try javaScriptSandboxService.runInlineScript(inlineSource, sourceName: "terminal-inline.js")
            return result.transcript
        }

        let path = try requiredArgument(at: 1, from: tokens, usage: "js <script-path>")
        let result = try javaScriptSandboxService.runScriptFile(at: path)
        return result.transcript
    }

    private func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in line {
            if isEscaping {
                current.append(unescaped(character))
                isEscaping = false
                continue
            }

            switch character {
            case "\\":
                isEscaping = true
            case "\"", "'":
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    current.append(character)
                }
            case " ", "\t":
                if quote == nil {
                    if !current.isEmpty {
                        tokens.append(current)
                        current.removeAll(keepingCapacity: true)
                    }
                } else {
                    current.append(character)
                }
            default:
                current.append(character)
            }
        }

        if isEscaping || quote != nil {
            throw AppError.invalidState("命令引号没有闭合：\(line)")
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func unescaped(_ character: Character) -> Character {
        switch character {
        case "n":
            "\n"
        case "t":
            "\t"
        default:
            character
        }
    }

    private func argument(at index: Int, from tokens: [String]) -> String? {
        guard tokens.indices.contains(index) else { return nil }
        return tokens[index]
    }

    private func requiredArgument(at index: Int, from tokens: [String], usage: String) throws -> String {
        guard let value = argument(at: index, from: tokens) else {
            throw AppError.invalidState("参数不足，用法：\(usage)")
        }
        return value
    }

    private func requiredRemainder(from tokens: [String], startingAt index: Int, usage: String) throws -> String {
        guard tokens.count > index else {
            throw AppError.invalidState("参数不足，用法：\(usage)")
        }
        return tokens[index...].joined(separator: " ")
    }
}
