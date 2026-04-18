import Foundation
import Python

struct EmbeddedPythonExecutionResult: Sendable {
    let transcript: String
    let runtimeDescription: String
}

@MainActor
final class EmbeddedPythonRuntime {
    static let shared = EmbeddedPythonRuntime()

    private let fileManager = FileManager.default
    private let pythonTag = "3.14"
    private let runtimeDescription = "CPython 3.14"
    private var initialized = false

    private init() {}

    func execute(scriptAt scriptURL: URL, workspaceRoot: URL) throws -> EmbeddedPythonExecutionResult {
        let supportRoot = try ensureSupportModules()
        try ensureInitialized(additionalModuleSearchPath: supportRoot.path)

        setenv("PALMI_WORKSPACE_ROOT", workspaceRoot.path, 1)

        let gilState = PyGILState_Ensure()
        defer { PyGILState_Release(gilState) }

        let bootstrap = pythonBootstrapScript(
            scriptPath: scriptURL.path,
            workspaceRoot: workspaceRoot.path,
            supportRoot: supportRoot.path
        )

        guard PyRun_SimpleStringFlags(bootstrap, nil) == 0 else {
            let failure = fetchPythonErrorDescription() ?? "Python runtime bootstrap failed."
            throw AppError.operationFailed(failure)
        }

        guard let mainModule = PyImport_AddModule("__main__"),
              let globals = PyModule_GetDict(mainModule) else {
            throw AppError.operationFailed("无法读取 Python 主模块状态。")
        }

        let transcript = pyDictString(globals, key: "__palmi_transcript")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = pyDictString(globals, key: "__palmi_error")?.trimmingCharacters(in: .whitespacesAndNewlines)
        clearBootstrapState(from: globals)

        if let errorText, !errorText.isEmpty {
            let combined = [transcript, errorText]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n\n")
            throw AppError.operationFailed(combined.isEmpty ? errorText : combined)
        }

        return EmbeddedPythonExecutionResult(
            transcript: transcript?.isEmpty == false ? transcript! : "(脚本已执行，但没有 stdout/stderr 输出)",
            runtimeDescription: runtimeDescription
        )
    }

    private func ensureInitialized(additionalModuleSearchPath: String) throws {
        guard !initialized else { return }

        let resourceRoot = try pythonResourceRoot()
        let stdlibPath = resourceRoot.appendingPathComponent("lib/python\(pythonTag)", isDirectory: true)
        let dynloadPath = stdlibPath.appendingPathComponent("lib-dynload", isDirectory: true)

        guard fileManager.fileExists(atPath: stdlibPath.path) else {
            throw AppError.invalidState(
                """
                Python 标准库还没有安装到应用包里。
                请确认 Xcode target 已执行 install-python-runtime 构建脚本。
                期望目录：\(stdlibPath.path)
                """
            )
        }

        setenv("LANG", "\(Locale.current.identifier).UTF-8", 1)

        var preconfig = PyPreConfig()
        PyPreConfig_InitIsolatedConfig(&preconfig)
        preconfig.utf8_mode = 1
        preconfig.configure_locale = 1

        var config = PyConfig()
        PyConfig_InitIsolatedConfig(&config)
        defer { PyConfig_Clear(&config) }

        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.module_search_paths_set = 1
        config.use_environment = 0
        config.install_signal_handlers = 0

        try check(Py_PreInitialize(&preconfig), context: "预初始化 Python")
        try setConfigBytesString(resourceRoot.path, on: &config, field: \.home, context: "设置 PYTHONHOME")
        try setConfigBytesString("palmi-python", on: &config, field: \.program_name, context: "设置 Python program_name")
        try check(PyConfig_Read(&config), context: "读取 Python 配置")

        try appendSearchPath(stdlibPath.path, to: &config)
        try appendSearchPath(dynloadPath.path, to: &config)
        try appendSearchPath(additionalModuleSearchPath, to: &config)

        try check(Py_InitializeFromConfig(&config), context: "初始化 Python 解释器")
        initialized = true
    }

    private func appendSearchPath(_ path: String, to config: inout PyConfig) throws {
        let wide = try decodeWideString(path)
        defer { PyMem_RawFree(wide) }
        try check(
            PyWideStringList_Append(&config.module_search_paths, wide),
            context: "追加 Python 模块搜索路径：\(path)"
        )
    }

    private func setConfigBytesString(
        _ value: String,
        on config: inout PyConfig,
        field: WritableKeyPath<PyConfig, UnsafeMutablePointer<wchar_t>?>,
        context: String
    ) throws {
        try withUnsafeMutablePointer(to: &config) { configPointer in
            try withCString(value) { cString in
                let status = withUnsafeMutablePointer(to: &configPointer.pointee[keyPath: field]) { fieldPointer in
                    PyConfig_SetBytesString(configPointer, fieldPointer, cString)
                }
                try check(status, context: context)
            }
        }
    }

    private func pythonResourceRoot() throws -> URL {
        guard let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent("python", isDirectory: true) else {
            throw AppError.invalidState("无法定位应用资源目录。")
        }
        return resourceRoot
    }

    private func ensureSupportModules() throws -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PalmiPythonSupport", isDirectory: true)
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let workspaceModuleURL = baseURL.appendingPathComponent("workspace.py")
        let currentSource = (try? String(contentsOf: workspaceModuleURL, encoding: .utf8)) ?? ""
        if currentSource != workspaceModuleSource {
            try workspaceModuleSource.write(to: workspaceModuleURL, atomically: true, encoding: .utf8)
        }

        return baseURL
    }

    private func pythonBootstrapScript(
        scriptPath: String,
        workspaceRoot: String,
        supportRoot: String
    ) -> String {
        """
        import io
        import os
        import runpy
        import sys
        import traceback

        __palmi_stdout = io.StringIO()
        __palmi_stderr = io.StringIO()
        __palmi_prev_stdout = sys.stdout
        __palmi_prev_stderr = sys.stderr
        __palmi_error = ""

        try:
            sys.stdout = __palmi_stdout
            sys.stderr = __palmi_stderr
            os.environ["PALMI_WORKSPACE_ROOT"] = \(pythonStringLiteral(workspaceRoot))
            os.chdir(\(pythonStringLiteral(workspaceRoot)))
            if \(pythonStringLiteral(supportRoot)) not in sys.path:
                sys.path.insert(0, \(pythonStringLiteral(supportRoot)))
            if \(pythonStringLiteral(workspaceRoot)) not in sys.path:
                sys.path.insert(0, \(pythonStringLiteral(workspaceRoot)))
            runpy.run_path(\(pythonStringLiteral(scriptPath)), run_name="__main__")
        except SystemExit as exc:
            code = exc.code if exc.code is not None else 0
            if code not in (0, ""):
                traceback.print_exc()
                __palmi_error = __palmi_stderr.getvalue() or f"SystemExit: {code}"
        except Exception:
            traceback.print_exc()
            __palmi_error = __palmi_stderr.getvalue() or traceback.format_exc()
        finally:
            __palmi_stdout_text = __palmi_stdout.getvalue()
            __palmi_stderr_text = __palmi_stderr.getvalue()
            __palmi_transcript = __palmi_stdout_text + (__palmi_stderr_text if __palmi_stderr_text else "")
            sys.stdout = __palmi_prev_stdout
            sys.stderr = __palmi_prev_stderr
        """
    }

    private func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "'\(escaped)'"
    }

    private func pyDictString(_ dict: UnsafeMutablePointer<PyObject>, key: String) -> String? {
        key.withCString { cString in
            guard let value = PyDict_GetItemString(dict, cString) else {
                return nil
            }
            return pyString(value)
        }
    }

    private func pyString(_ object: UnsafeMutablePointer<PyObject>) -> String? {
        guard let utf8 = PyUnicode_AsUTF8(object) else {
            return nil
        }
        return String(cString: utf8)
    }

    private func pyObjectDescription(_ object: UnsafeMutablePointer<PyObject>) -> String? {
        guard let stringObject = PyObject_Str(object) else {
            return nil
        }
        defer { Py_DecRef(stringObject) }
        return pyString(stringObject)
    }

    private func clearBootstrapState(from globals: UnsafeMutablePointer<PyObject>) {
        [
            "__palmi_stdout",
            "__palmi_stderr",
            "__palmi_prev_stdout",
            "__palmi_prev_stderr",
            "__palmi_stdout_text",
            "__palmi_stderr_text",
            "__palmi_transcript",
            "__palmi_error"
        ].forEach { key in
            key.withCString { cString in
                _ = PyDict_DelItemString(globals, cString)
            }
        }
    }

    private func fetchPythonErrorDescription() -> String? {
        guard PyErr_Occurred() != nil else {
            return nil
        }

        var type: UnsafeMutablePointer<PyObject>?
        var value: UnsafeMutablePointer<PyObject>?
        var traceback: UnsafeMutablePointer<PyObject>?
        PyErr_Fetch(&type, &value, &traceback)
        PyErr_NormalizeException(&type, &value, &traceback)
        defer {
            if let type { Py_DecRef(type) }
            if let value { Py_DecRef(value) }
            if let traceback { Py_DecRef(traceback) }
        }

        if let valueDescription = value.flatMap(pyObjectDescription), !valueDescription.isEmpty {
            return valueDescription
        }
        if let typeDescription = type.flatMap(pyObjectDescription), !typeDescription.isEmpty {
            return typeDescription
        }
        PyErr_Clear()
        return "Python runtime bootstrap failed."
    }

    private func decodeWideString(_ string: String) throws -> UnsafeMutablePointer<wchar_t> {
        try string.withCString { cString in
            guard let decoded = Py_DecodeLocale(cString, nil) else {
                throw AppError.operationFailed("无法把路径转换为 Python 宽字符：\(string)")
            }
            return decoded
        }
    }

    private func withCString<T>(_ string: String, _ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        try string.withCString(body)
    }

    private func check(_ status: PyStatus, context: String) throws {
        if PyStatus_Exception(status) != 0 {
            let message = status.err_msg.map { String(cString: $0) } ?? "未知错误"
            throw AppError.operationFailed("\(context)失败：\(message)")
        }
    }

    private let workspaceModuleSource = #"""
from __future__ import annotations

import os
import shutil
from pathlib import Path


def _root() -> Path:
    raw = os.environ.get("PALMI_WORKSPACE_ROOT")
    if not raw:
        raise RuntimeError("PALMI_WORKSPACE_ROOT is not set")
    root = Path(raw).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def _resolve(path: str = ".") -> Path:
    root = _root()
    if path in ("", "."):
        return root
    target = (root / path).resolve()
    target.relative_to(root)
    return target


def pwd() -> str:
    return str(_root())


def exists(path: str) -> bool:
    return _resolve(path).exists()


def readText(path: str) -> str:
    return _resolve(path).read_text(encoding="utf-8")


read_text = readText


def writeText(path: str, text: str) -> str:
    target = _resolve(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(str(text), encoding="utf-8")
    return str(target)


write_text = writeText


def appendText(path: str, text: str) -> str:
    target = _resolve(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a", encoding="utf-8") as handle:
        handle.write(str(text))
    return str(target)


append_text = appendText


def listFiles(path: str = ".") -> list[str]:
    return sorted(item.name for item in _resolve(path).iterdir())


list_files = listFiles


def listTree(path: str = ".") -> str:
    root = _resolve(path)
    lines: list[str] = []
    for child in sorted(root.rglob("*")):
        relative = child.relative_to(root)
        suffix = "/" if child.is_dir() else ""
        lines.append(f"{relative}{suffix}")
    return "\n".join(lines)


list_tree = listTree


def makeDirectory(path: str) -> str:
    target = _resolve(path)
    target.mkdir(parents=True, exist_ok=True)
    return str(target)


make_directory = makeDirectory


def removeItem(path: str) -> None:
    target = _resolve(path)
    if target.is_dir():
        shutil.rmtree(target)
    elif target.exists():
        target.unlink()
    else:
        raise FileNotFoundError(path)


remove_item = removeItem
"""#
}
