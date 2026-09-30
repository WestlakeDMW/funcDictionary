import Combine
import Darwin
import Foundation
import OSLog

private let harnessLogger = Logger(subsystem: "com.example.funcDictionary.mac", category: "Harness")

enum HarnessID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case hermes
    case zcode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .hermes: "Hermes"
        case .zcode: "zcode"
        }
    }

    var subtitle: String {
        switch self {
        case .codex: "OpenAI Codex CLI"
        case .hermes: "Hermes Agent CLI"
        case .zcode: "可配置的第三方 Harness"
        }
    }

    var executableCandidates: [String] {
        switch self {
        case .codex: ["codex"]
        case .hermes: ["hermes"]
        case .zcode: ["zcode"]
        }
    }

    var defaultArgumentTemplate: String {
        switch self {
        case .codex:
            // Read-only is deliberate: the first MVP connection must not
            // grant an external agent write access merely by being linked.
            return "exec --sandbox read-only -C {project} {prompt}"
        case .hermes:
            return "--in {project} --oneshot {prompt}"
        case .zcode:
            return "{prompt}"
        }
    }

    var connectionArguments: [String] { ["--version"] }
}

struct HarnessConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var argumentTemplate: String

    init(executablePath: String = "", argumentTemplate: String) {
        self.executablePath = executablePath
        self.argumentTemplate = argumentTemplate
    }
}

/// A fully materialized launch plan. The confirmation sheet stores this
/// value so changing a Harness setting after preview cannot silently alter
/// the command that the user is about to approve.
struct HarnessLaunchRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let command: String
}

enum HarnessConnectionStatus: String, Equatable, Sendable {
    case unavailable
    case available
    case testing
    case connected
    case failed

    var title: String {
        switch self {
        case .unavailable: "未找到"
        case .available: "可连接"
        case .testing: "测试中"
        case .connected: "CLI 可用"
        case .failed: "连接失败"
        }
    }

    var systemImage: String {
        switch self {
        case .unavailable: "questionmark.circle"
        case .available: "bolt.horizontal.circle"
        case .testing: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct HarnessConnection: Equatable, Identifiable, Sendable {
    let harness: HarnessID
    var executableURL: URL?
    var status: HarnessConnectionStatus
    var details: String
    var lastOutput: String
    var checkedAt: Date?
    var configuration: HarnessConfiguration

    var id: HarnessID { harness }
}

struct HarnessProcessResult: Sendable {
    let exitCode: Int32
    let output: String
    let error: String?
    let didTimeOut: Bool

    var succeeded: Bool { !didTimeOut && exitCode == 0 }
}

enum HarnessConnectorError: Error, LocalizedError, Sendable {
    case executableNotFound(HarnessID)
    case invalidTemplate(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let harness):
            return "没有找到 \(harness.displayName) 的可执行文件，请填写路径或安装对应 CLI。"
        case .invalidTemplate(let template):
            return "Harness 参数模板无法解析：\(template)"
        }
    }
}

enum HarnessExecutableResolver {
    static func resolve(harness: HarnessID, configuredPath: String) -> URL? {
        let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            let url = URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            return isExecutable(url) ? url : nil
        }

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirectories = environmentPath
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        let fallbackDirectories = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]
        var searchedDirectories: [String] = []
        for directory in pathDirectories + fallbackDirectories where !searchedDirectories.contains(directory) {
            searchedDirectories.append(directory)
            for candidate in harness.executableCandidates {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(candidate)
                if isExecutable(url) { return url }
            }
        }
        return nil
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}

enum HarnessArgumentTemplate {
    static func arguments(
        template: String,
        projectURL: URL,
        contextURL: URL,
        prompt: String
    ) throws -> [String] {
        let tokens = try tokenize(template)
        guard !tokens.isEmpty else { throw HarnessConnectorError.invalidTemplate(template) }
        let values = ["{project}": projectURL.path, "{context}": contextURL.path, "{prompt}": prompt]
        let pattern = try NSRegularExpression(pattern: #"\{(?:project|context|prompt)\}"#)
        return tokens.map { token in
            var result = token
            for match in pattern.matches(in: token, range: NSRange(token.startIndex..., in: token)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: values[String(result[range])] ?? "")
            }
            return result
        }
    }

    private static func tokenize(_ template: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in template {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        guard !escaping, quote == nil else {
            throw HarnessConnectorError.invalidTemplate(template)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

}

@MainActor
final class HarnessCenterModel: ObservableObject {
    @Published private(set) var connections: [HarnessConnection]

    private let defaults: UserDefaults
    private let configurationsKey = "funcDictionary.mac.harnessConfigurations"
    private var configurations: [HarnessID: HarnessConfiguration]
    private var runningTasks: [HarnessID: Task<Void, Never>] = [:]
    private var runTokens: [HarnessID: UUID] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.configurations = Self.loadConfigurations(defaults: defaults, key: configurationsKey)
        self.connections = []
        refresh()
    }

    func connection(for harness: HarnessID) -> HarnessConnection? {
        connections.first { $0.harness == harness }
    }

    func refresh() {
        connections = HarnessID.allCases.map { harness in
            let configuration = configuration(for: harness)
            let executableURL = HarnessExecutableResolver.resolve(
                harness: harness,
                configuredPath: configuration.executablePath
            )
            return HarnessConnection(
                harness: harness,
                executableURL: executableURL,
                status: executableURL == nil ? .unavailable : .available,
                details: executableURL.map { "已发现 \($0.path)" } ?? "未在 PATH 或自定义路径中发现可执行文件",
                lastOutput: "",
                checkedAt: nil,
                configuration: configuration
            )
        }
    }

    func setExecutablePath(_ path: String, for harness: HarnessID) {
        var configuration = configuration(for: harness)
        configuration.executablePath = path
        configurations[harness] = configuration
        saveConfigurations()
        refresh()
    }

    func setArgumentTemplate(_ template: String, for harness: HarnessID) {
        var configuration = configuration(for: harness)
        configuration.argumentTemplate = template
        configurations[harness] = configuration
        saveConfigurations()
        refresh()
    }

    func previewCommand(
        for harness: HarnessID,
        projectURL: URL,
        contextURL: URL,
        prompt: String
    ) -> String? {
        previewLaunchRequest(
            for: harness,
            projectURL: projectURL,
            contextURL: contextURL,
            prompt: prompt
        )?.command
    }

    func previewLaunchRequest(
        for harness: HarnessID,
        projectURL: URL,
        contextURL: URL,
        prompt: String,
        dictionaryTask: Bool = false
    ) -> HarnessLaunchRequest? {
        guard let connection = connection(for: harness), let executableURL = connection.executableURL,
              let arguments = try? HarnessArgumentTemplate.arguments(
                  template: dictionaryTask && harness == .codex && connection.configuration.argumentTemplate == harness.defaultArgumentTemplate
                    ? "exec --sandbox workspace-write --skip-git-repo-check -C {project} {prompt}"
                    : connection.configuration.argumentTemplate,
                  projectURL: projectURL,
                  contextURL: contextURL,
                  prompt: prompt
              ) else { return nil }
        let command = ([executableURL.path] + arguments).map(Self.shellQuote).joined(separator: " ")
        return HarnessLaunchRequest(executableURL: executableURL, arguments: arguments, command: command)
    }

    func test(_ harness: HarnessID) {
        guard let connection = connection(for: harness), let executableURL = connection.executableURL else {
            harnessLogger.error("Harness unavailable: \(harness.rawValue, privacy: .public)")
            update(harness) {
                $0.status = .unavailable
                $0.details = HarnessConnectorError.executableNotFound(harness).localizedDescription
            }
            return
        }

        let token = beginRun(for: harness)
        update(harness) {
            $0.status = .testing
            $0.details = "正在运行 \(executableURL.lastPathComponent) --version"
        }
        harnessLogger.info("Testing \(harness.rawValue, privacy: .public) at \(executableURL.path, privacy: .public)")

        let task: Task<Void, Never> = Task { [weak self] in
            let result = await HarnessProcessRunner.run(
                executableURL: executableURL,
                arguments: harness.connectionArguments,
                workingDirectoryURL: nil,
                timeout: 30
            )
            guard let self else { return }
            self.finishTest(harness, result: result, executableURL: executableURL, token: token)
        }
        runningTasks[harness] = task
    }

    func send(
        _ harness: HarnessID,
        projectURL: URL,
        contextURL: URL,
        prompt: String
    ) {
        guard let launchRequest = previewLaunchRequest(
            for: harness,
            projectURL: projectURL,
            contextURL: contextURL,
            prompt: prompt
        ) else {
            update(harness) {
                $0.status = .unavailable
                $0.details = HarnessConnectorError.executableNotFound(harness).localizedDescription
            }
            return
        }

        send(harness, launchRequest: launchRequest, workingDirectoryURL: projectURL)
    }

    func send(
        _ harness: HarnessID,
        launchRequest: HarnessLaunchRequest,
        workingDirectoryURL: URL
    ) {
        let executableURL = launchRequest.executableURL
        let arguments = launchRequest.arguments

        let token = beginRun(for: harness)
        update(harness) {
            $0.status = .testing
            $0.details = "正在发送 Context，外部 Harness 将以当前参数模板启动"
        }

        let task: Task<Void, Never> = Task { [weak self] in
            let result = await HarnessProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectoryURL: workingDirectoryURL,
                timeout: 1800
            )
            guard let self else { return }
            self.finishSend(harness, result: result, executableURL: executableURL, token: token)
        }
        runningTasks[harness] = task
    }

    func cancel(_ harness: HarnessID) {
        guard runningTasks[harness] != nil else { return }
        runningTasks[harness]?.cancel()
        update(harness) { $0.details = "正在取消 Harness 进程…" }
    }

    private func beginRun(for harness: HarnessID) -> UUID {
        runningTasks[harness]?.cancel()
        let token = UUID()
        runTokens[harness] = token
        return token
    }

    private func finishTest(_ harness: HarnessID, result: HarnessProcessResult, executableURL: URL, token: UUID) {
        guard runTokens[harness] == token else { return }
        runningTasks[harness] = nil
        runTokens[harness] = nil
        update(harness) {
            $0.status = result.succeeded ? .connected : .failed
            $0.checkedAt = Date()
            $0.lastOutput = result.output
            $0.details = result.succeeded
                ? "连接测试通过：\(executableURL.path)"
                : Self.failureDetails(
                    prefix: result.didTimeOut ? "版本探测超时" : "版本探测失败，退出码 \(result.exitCode)",
                    result: result
                )
        }
        harnessLogger.info("Tested \(harness.rawValue, privacy: .public), exit=\(result.exitCode), success=\(result.succeeded, privacy: .public)")
    }

    private func finishSend(_ harness: HarnessID, result: HarnessProcessResult, executableURL: URL, token: UUID) {
        guard runTokens[harness] == token else { return }
        runningTasks[harness] = nil
        runTokens[harness] = nil
        update(harness) {
            $0.status = result.succeeded ? .connected : .failed
            $0.checkedAt = Date()
            $0.lastOutput = result.output
            $0.details = result.succeeded
                ? "Harness 已返回，Context 已通过 \(executableURL.lastPathComponent) 发送"
                : Self.failureDetails(
                    prefix: result.didTimeOut ? "Harness 响应超时" : "Harness 启动失败，退出码 \(result.exitCode)",
                    result: result
                )
        }
        harnessLogger.info("Sent \(harness.rawValue, privacy: .public), exit=\(result.exitCode), success=\(result.succeeded, privacy: .public)")
    }

    private func configuration(for harness: HarnessID) -> HarnessConfiguration {
        configurations[harness] ?? HarnessConfiguration(argumentTemplate: harness.defaultArgumentTemplate)
    }

    private func update(_ harness: HarnessID, mutation: (inout HarnessConnection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.harness == harness }) else { return }
        mutation(&connections[index])
    }

    private func saveConfigurations() {
        let encoded = configurations.reduce(into: [String: HarnessConfiguration]()) { result, item in
            result[item.key.rawValue] = item.value
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: configurationsKey)
    }

    private static func loadConfigurations(defaults: UserDefaults, key: String) -> [HarnessID: HarnessConfiguration] {
        guard let data = defaults.data(forKey: key),
              let encoded = try? JSONDecoder().decode([String: HarnessConfiguration].self, from: data) else {
            return [:]
        }
        return encoded.reduce(into: [HarnessID: HarnessConfiguration]()) { result, item in
            guard let harness = HarnessID(rawValue: item.key) else { return }
            var configuration = item.value
            if harness == .hermes, configuration.argumentTemplate == "--safe-mode --oneshot {prompt}" {
                configuration.argumentTemplate = harness.defaultArgumentTemplate
            }
            result[harness] = configuration
        }
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func failureDetails(prefix: String, result: HarnessProcessResult) -> String {
        let rawDetail = (result.error ?? result.output)
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDetail.isEmpty else { return prefix }
        return "\(prefix)：\(rawDetail.prefix(240))"
    }
}

enum HarnessProcessRunner {
    private static let maximumOutputBytes = 12_000

    // Finder-launched apps do not inherit a login shell PATH. CLI shims often
    // use /usr/bin/env node/python, so resolving the shim alone is insufficient.
    static func environment(for executableURL: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [executableURL.deletingLastPathComponent().path,
                           executableURL.resolvingSymlinksInPath().deletingLastPathComponent().path,
                           "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").components(separatedBy: ":")
        var seen = Set<String>()
        environment["PATH"] = directories.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL?,
        timeout: TimeInterval
    ) async -> HarnessProcessResult {
        do {
            let stdout = Pipe()
            let stderr = Pipe()
            let process = Process()
            let stdoutBuffer = OutputBuffer(maximumBytes: maximumOutputBytes)
            let stderrBuffer = OutputBuffer(maximumBytes: maximumOutputBytes)
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.environment = environment(for: executableURL)
            process.standardOutput = stdout
            process.standardError = stderr
            if let workingDirectoryURL {
                guard FileManager.default.fileExists(atPath: workingDirectoryURL.path),
                      (try? workingDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return HarnessProcessResult(
                        exitCode: -1,
                        output: "",
                        error: "工作目录不存在或不是文件夹：\(workingDirectoryURL.path)",
                        didTimeOut: false
                    )
                }
                process.currentDirectoryURL = workingDirectoryURL
            }

            do {
                // Drain both pipes while the process is alive. Waiting first can
                // deadlock when a CLI fills either pipe buffer before exiting.
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { stdoutBuffer.append(data) }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { stderrBuffer.append(data) }
                }
                try process.run()
                var didTimeOut = false
                let deadline = Date().addingTimeInterval(max(0, timeout))
                while process.isRunning {
                    if Task.isCancelled {
                        Self.stop(process, force: true)
                        return Self.result(
                            process: process,
                            stdout: stdout,
                            stderr: stderr,
                            stdoutBuffer: stdoutBuffer,
                            stderrBuffer: stderrBuffer,
                            didTimeOut: false,
                            cancellationError: "Harness 进程已取消"
                        )
                    }
                    if Date() >= deadline {
                        didTimeOut = true
                        Self.stop(process)
                        break
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        Self.stop(process, force: true)
                        return Self.result(
                            process: process,
                            stdout: stdout,
                            stderr: stderr,
                            stdoutBuffer: stdoutBuffer,
                            stderrBuffer: stderrBuffer,
                            didTimeOut: false,
                            cancellationError: "Harness 进程已取消"
                        )
                    }
                }
                if !didTimeOut {
                    process.waitUntilExit()
                } else {
                    // Give a cooperative CLI a short grace period. Never wait
                    // indefinitely after the deadline has already elapsed.
                    let graceDeadline = Date().addingTimeInterval(0.5)
                    while process.isRunning && Date() < graceDeadline {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    if process.isRunning { Self.stop(process, force: true) }
                }
                return Self.result(
                    process: process,
                    stdout: stdout,
                    stderr: stderr,
                    stdoutBuffer: stdoutBuffer,
                    stderrBuffer: stderrBuffer,
                    didTimeOut: didTimeOut,
                    cancellationError: nil
                )
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                return HarnessProcessResult(
                    exitCode: -1,
                    output: "",
                    error: error.localizedDescription,
                    didTimeOut: false
                )
            }
        }
    }

    private static func result(
        process: Process,
        stdout: Pipe,
        stderr: Pipe,
        stdoutBuffer: OutputBuffer,
        stderrBuffer: OutputBuffer,
        didTimeOut: Bool,
        cancellationError: String?
    ) -> HarnessProcessResult {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        if !process.isRunning {
            stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        }

        let standardOutput = string(from: stdoutBuffer.data)
        let standardError = string(from: stderrBuffer.data)
        let combinedOutput: String
        if standardOutput.isEmpty {
            combinedOutput = standardError
        } else if standardError.isEmpty {
            combinedOutput = standardOutput
        } else {
            combinedOutput = "\(standardOutput)\n[stderr]\n\(standardError)"
        }
        return HarnessProcessResult(
            exitCode: cancellationError == nil ? (didTimeOut ? -2 : process.terminationStatus) : -3,
            output: String(combinedOutput.prefix(maximumOutputBytes)),
            error: cancellationError ?? (standardError.isEmpty ? nil : String(standardError.prefix(maximumOutputBytes))),
            didTimeOut: didTimeOut
        )
    }

    private static func stop(_ process: Process, force: Bool = false) {
        guard process.isRunning else { return }
        if force {
            Darwin.kill(process.processIdentifier, SIGKILL)
        } else {
            process.terminate()
        }
    }

    private static func string(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let maximumBytes: Int
        private let lock = NSLock()
        private(set) var data = Data()

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func append(_ newData: Data) {
            guard !newData.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard data.count < maximumBytes else { return }
            data.append(newData.prefix(maximumBytes - data.count))
        }
    }
}
