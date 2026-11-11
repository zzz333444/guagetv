import Foundation
import Python

/// Embedded CPython runtime (stage 1) — BeeWare python-apple-support
/// 3.13, loaded once and kept for the app's lifetime.
///
/// Layout contract (produced by scripts/install_python_nosign.sh at
/// build time, mirroring BeeWare's own install step):
///   <bundle>/python/lib/python3.13/…   stdlib (PYTHONHOME=<bundle>/python)
///   <bundle>/Python/pybundle.zip       spider_runner + base.spider +
///                                      vendored requests stack + pure
///                                      Python Crypto shim (PYTHONPATH)
///   Application Support/spiders/       downloaded spider .py files
///
/// All interpreter access is serialized on one queue; every call wraps
/// PyGILState_Ensure/Release. Python exceptions never cross into Swift:
/// spider_runner converts them to {"ok": false, "error": …} JSON, and
/// boot/import failures are captured into `bootError` for the UI.
final class PythonRuntime {
    static let shared = PythonRuntime()

    enum RuntimeError: Error, CustomStringConvertible {
        case boot(String)
        case call(String)
        var description: String {
            switch self {
            case .boot(let message), .call(let message): return message
            }
        }
    }

    private let queue = DispatchQueue(label: "guage.python.runtime")
    private var booted = false
    private var runnerModule: UnsafeMutablePointer<PyObject>?
    private(set) var bootError: String?
    private(set) var versionText = ""

    var statusText: String {
        if booted { return versionText }
        if bootError != nil { return "启动失败" }
        return "未启动（打开 py 站点时自动启动）"
    }

    /// Call a spider_runner module function with string arguments; the
    /// function returns a JSON string. Throws with the Python-side
    /// message on any failure.
    func invoke(_ function: String, _ args: [String]) throws -> String {
        var result: Result<String, Error> = .failure(RuntimeError.call("未执行"))
        queue.sync {
            if !booted {
                bootLocked()
                if !booted {
                    result = .failure(RuntimeError.boot(bootError ?? "启动失败"))
                    return
                }
            }
            let gil = PyGILState_Ensure()
            result = callLocked(function, args)
            PyGILState_Release(gil)
        }
        return try result.get()
    }

    // MARK: - Boot (queue-confined)

    private func bootLocked() {
        let bundlePath = Bundle.main.bundlePath
        let zipPath = bundlePath + "/Python/pybundle.zip"
        guard FileManager.default.fileExists(atPath: zipPath) else {
            bootError = "pybundle.zip 不在应用包内"
            return
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let spidersDir = support.appendingPathComponent("spiders").path
        try? FileManager.default.createDirectory(
            atPath: spidersDir, withIntermediateDirectories: true)

        setenv("PYTHONHOME", bundlePath + "/python", 1)
        setenv("PYTHONPATH", zipPath + ":" + spidersDir, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)

        Py_Initialize()
        guard Py_IsInitialized() != 0 else {
            bootError = "解释器初始化失败"
            return
        }
        // This thread holds the GIL after Py_Initialize; import and warm
        // up directly, then hand the GIL back with PyEval_SaveThread so
        // later calls can re-acquire it from any thread.
        guard let module = PyImport_ImportModule("spider_runner") else {
            bootError = "spider_runner 导入失败：" + fetchPyError()
            return
        }
        runnerModule = module
        if case .success(let version) = callLocked("ping", []) {
            versionText = version
        }
        booted = true
        PyEval_SaveThread()
    }

    // MARK: - Call plumbing (GIL must be held)

    private func callLocked(_ function: String, _ args: [String]) -> Result<String, Error> {
        guard let module = runnerModule,
              let callable = PyObject_GetAttrString(module, function) else {
            return .failure(RuntimeError.call("spider_runner.\(function) 不存在：" + fetchPyError()))
        }
        defer { Py_DecRef(callable) }
        let tuple = PyTuple_New(args.count)
        for (index, arg) in args.enumerated() {
            PyTuple_SetItem(tuple, index, PyUnicode_FromString(arg))
        }
        guard let raw = PyObject_CallObject(callable, tuple) else {
            Py_DecRef(tuple)
            return .failure(RuntimeError.call(fetchPyError()))
        }
        Py_DecRef(tuple)
        defer { Py_DecRef(raw) }
        guard let cString = PyUnicode_AsUTF8(raw) else {
            return .failure(RuntimeError.call("桥接返回值不是字符串"))
        }
        return .success(String(cString: cString))
    }

    private func fetchPyError() -> String {
        var type: UnsafeMutablePointer<PyObject>?
        var value: UnsafeMutablePointer<PyObject>?
        var traceback: UnsafeMutablePointer<PyObject>?
        PyErr_Fetch(&type, &value, &traceback)
        defer {
            if let type { Py_DecRef(type) }
            if let value { Py_DecRef(value) }
            if let traceback { Py_DecRef(traceback) }
        }
        guard let value, let str = PyObject_Str(value) else { return "未知 Python 错误" }
        defer { Py_DecRef(str) }
        guard let cString = PyUnicode_AsUTF8(str) else { return "未知 Python 错误" }
        return String(cString: cString)
    }
}
