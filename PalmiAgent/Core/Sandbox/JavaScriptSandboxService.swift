import Foundation
import JavaScriptCore

struct JavaScriptExecutionResult: Sendable {
    let transcript: String
    let artifactURL: URL
    let scriptPath: String
}

@MainActor
final class JavaScriptSandboxService {
    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func writeDemoScript() throws -> URL {
        try workspaceManager.writeJavaScriptDemoScript()
    }

    func runDefaultScript() throws -> JavaScriptExecutionResult {
        if try !workspaceManager.itemExists(at: "sandbox-demo.js") {
            _ = try writeDemoScript()
        }
        return try runScriptFile(at: "sandbox-demo.js")
    }

    func runScriptFile(at relativePath: String) throws -> JavaScriptExecutionResult {
        let source = try workspaceManager.readText(at: relativePath)
        return try evaluate(script: source, scriptPath: relativePath)
    }

    func runInlineScript(_ script: String, sourceName: String = "inline.js") throws -> JavaScriptExecutionResult {
        try evaluate(script: script, scriptPath: sourceName)
    }

    private func evaluate(script: String, scriptPath: String) throws -> JavaScriptExecutionResult {
        guard let context = JSContext() else {
            throw AppError.operationFailed("JavaScriptCore 初始化失败。")
        }

        var logs: [String] = []
        var capturedException: String?
        let manager = self.workspaceManager

        func normalized(_ path: String) -> String {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "." : trimmed
        }

        func report(_ error: Error) {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            capturedException = message
            context.exception = JSValue(newErrorFromMessage: message, in: context)
        }

        let logBlock: @convention(block) (String) -> Void = { message in
            logs.append(message)
        }
        let pwdBlock: @convention(block) () -> String = {
            (try? manager.rootPath()) ?? "ManualWorkspace"
        }
        let nowBlock: @convention(block) () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
        let listFilesBlock: @convention(block) (String) -> [String] = { path in
            do {
                return try manager.listEntryNames(at: normalized(path))
            } catch {
                report(error)
                return []
            }
        }
        let listTreeBlock: @convention(block) (String) -> String = { path in
            do {
                return try manager.directoryTree(at: normalized(path))
            } catch {
                report(error)
                return ""
            }
        }
        let existsBlock: @convention(block) (String) -> Bool = { path in
            do {
                return try manager.itemExists(at: normalized(path))
            } catch {
                report(error)
                return false
            }
        }
        let readTextBlock: @convention(block) (String) -> String = { path in
            do {
                return try manager.readText(at: normalized(path))
            } catch {
                report(error)
                return ""
            }
        }
        let writeTextBlock: @convention(block) (String, String) -> String = { path, text in
            do {
                let url = try manager.writeText(text, to: normalized(path))
                return url.lastPathComponent
            } catch {
                report(error)
                return ""
            }
        }
        let appendTextBlock: @convention(block) (String, String) -> String = { path, text in
            do {
                let url = try manager.appendText(text, to: normalized(path))
                return url.lastPathComponent
            } catch {
                report(error)
                return ""
            }
        }
        let makeDirectoryBlock: @convention(block) (String) -> String = { path in
            do {
                let url = try manager.createDirectory(at: normalized(path))
                return url.lastPathComponent
            } catch {
                report(error)
                return ""
            }
        }
        let removeItemBlock: @convention(block) (String) -> String = { path in
            do {
                try manager.removeItem(at: normalized(path))
                return path
            } catch {
                report(error)
                return ""
            }
        }

        context.setObject(logBlock, forKeyedSubscript: "__palmiLog" as NSString)
        context.setObject(pwdBlock, forKeyedSubscript: "__workspacePwd" as NSString)
        context.setObject(nowBlock, forKeyedSubscript: "__workspaceNow" as NSString)
        context.setObject(listFilesBlock, forKeyedSubscript: "__workspaceListFiles" as NSString)
        context.setObject(listTreeBlock, forKeyedSubscript: "__workspaceListTree" as NSString)
        context.setObject(existsBlock, forKeyedSubscript: "__workspaceExists" as NSString)
        context.setObject(readTextBlock, forKeyedSubscript: "__workspaceReadText" as NSString)
        context.setObject(writeTextBlock, forKeyedSubscript: "__workspaceWriteText" as NSString)
        context.setObject(appendTextBlock, forKeyedSubscript: "__workspaceAppendText" as NSString)
        context.setObject(makeDirectoryBlock, forKeyedSubscript: "__workspaceMakeDirectory" as NSString)
        context.setObject(removeItemBlock, forKeyedSubscript: "__workspaceRemoveItem" as NSString)

        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "JavaScript 执行失败。"
            if capturedException == nil {
                capturedException = message
            }
            logs.append("[exception] \(message)")
        }

        _ = context.evaluateScript(
            """
            const console = {
              log: (...parts) => __palmiLog(parts.map(part => {
                if (typeof part === "string") { return part; }
                try { return JSON.stringify(part, null, 2); }
                catch { return String(part); }
              }).join(" ")),
              error: (...parts) => __palmiLog("[error] " + parts.join(" "))
            };

            const workspace = {
              pwd: () => __workspacePwd(),
              now: () => __workspaceNow(),
              listFiles: (path = ".") => __workspaceListFiles(path),
              listTree: (path = ".") => __workspaceListTree(path),
              exists: (path) => __workspaceExists(path),
              readText: (path) => __workspaceReadText(path),
              writeText: (path, text) => __workspaceWriteText(path, String(text)),
              appendText: (path, text) => __workspaceAppendText(path, String(text)),
              makeDirectory: (path) => __workspaceMakeDirectory(path),
              removeItem: (path) => __workspaceRemoveItem(path)
            };
            """,
            withSourceURL: URL(fileURLWithPath: "runtime-prelude.js")
        )

        let value = context.evaluateScript(script, withSourceURL: URL(fileURLWithPath: scriptPath))
        if let capturedException {
            throw AppError.operationFailed(capturedException)
        }

        if let value, !value.isUndefined {
            logs.append("[return] \(value.toString() ?? "undefined")")
        }

        if logs.isEmpty {
            logs.append("(脚本已执行，但没有 console 输出)")
        }

        let transcript = logs.joined(separator: "\n")
        let artifactURL = try workspaceManager.writeText(transcript, to: "logs/js-runtime-output.txt")
        return JavaScriptExecutionResult(transcript: transcript, artifactURL: artifactURL, scriptPath: scriptPath)
    }
}
