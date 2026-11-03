import Foundation

/// Own loopback-only runtime and cloned model cache. It never stops or configures
/// the existing Ollama services on 11434/11436.
@MainActor final class KiviLocalEditorRuntime {
    static let shared = KiviLocalEditorRuntime()
    private var process: Process?
    private var starting: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2; config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()
    func ensureRunning() async {
        guard !AppConstants.isRunningTests,
              let port = Bundle.main.object(forInfoDictionaryKey: "KiviCombinedEditorPort") as? Int,
              let models = Bundle.main.object(forInfoDictionaryKey: "KiviCombinedModels") as? String else { return }
        if let starting { await starting.value; return }
        let url = URL(string: "http://127.0.0.1:\(port)/api/tags")!
        starting = Task { @MainActor in
            if await responds(url) { return }
            guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ollama"), FileManager.default.fileExists(atPath: models) else { return }
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama"); task.arguments = ["serve"]
            var environment = ProcessInfo.processInfo.environment
            environment["OLLAMA_HOST"] = "127.0.0.1:\(port)"; environment["OLLAMA_MODELS"] = models; environment["OLLAMA_NO_CLOUD"] = "1"
            task.environment = environment
            let log = AppConstants.appSupportDirectory.appendingPathComponent("editor-server.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: log) { task.standardOutput = handle; task.standardError = handle }
            do { try task.run(); process = task } catch { return }
            for _ in 0..<20 { if await responds(url) { return }; try? await Task.sleep(for: .milliseconds(150)) }
        }
        await starting?.value; starting = nil
    }
    private func responds(_ url: URL) async -> Bool {
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    func stopOwnedServer() { if process?.isRunning == true { process?.terminate() }; process = nil }
}
