import Foundation

struct PythonNotebookExecutionResult: Sendable {
    let transcript: String
    let artifactURL: URL
    let sourcePath: String
    let runtimeDescription: String
}

@MainActor
final class PythonNotebookSandboxService {
    private let workspaceManager: WorkspaceManager
    private let runtime: EmbeddedPythonRuntime

    init(
        workspaceManager: WorkspaceManager,
        runtime: EmbeddedPythonRuntime? = nil
    ) {
        self.workspaceManager = workspaceManager
        self.runtime = runtime ?? .shared
    }

    func runScriptFile(at relativePath: String) throws -> PythonNotebookExecutionResult {
        guard relativePath.hasSuffix(".py") else {
            throw AppError.invalidState("script_path 必须指向 .py 文件。")
        }
        _ = try workspaceManager.readText(at: relativePath)
        return try execute(sourcePath: relativePath)
    }

    func runInlineScript(
        _ script: String,
        saveTo relativePath: String? = nil
    ) throws -> PythonNotebookExecutionResult {
        let sourcePath = relativePath ?? defaultInlineScriptPath()
        guard sourcePath.hasSuffix(".py") else {
            throw AppError.invalidState("save_to 必须是 .py 路径。")
        }
        _ = try workspaceManager.writeText(script, to: sourcePath)
        return try execute(sourcePath: sourcePath)
    }

    private func execute(sourcePath: String) throws -> PythonNotebookExecutionResult {
        let workspaceRoot = try workspaceManager.ensureWorkspace()
        let scriptURL = try workspaceManager.url(for: sourcePath)

        do {
            let execution = try runtime.execute(scriptAt: scriptURL, workspaceRoot: workspaceRoot)
            let artifactURL = try workspaceManager.writeText(
                execution.transcript,
                to: logPath(for: sourcePath)
            )

            return PythonNotebookExecutionResult(
                transcript: execution.transcript,
                artifactURL: artifactURL,
                sourcePath: sourcePath,
                runtimeDescription: execution.runtimeDescription
            )
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.operationFailed(error.localizedDescription)
        }
    }

    private func defaultInlineScriptPath() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "scripts/python-inline-\(formatter.string(from: .now)).py"
    }

    private func logPath(for sourcePath: String) -> String {
        let sanitized = sourcePath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".py", with: "")
        return "logs/python-\(sanitized).log"
    }
}
