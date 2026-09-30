import Foundation
import XCTest
@testable import funcDictionaryMac

@MainActor
final class HarnessConnectorTests: XCTestCase {
    func testFinderEnvironmentCanResolveShimRuntime() {
        let result = HarnessProcessRunner.environment(
            for: URL(fileURLWithPath: "/tmp/toolchain/bin/codex"), inherited: ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertTrue(result["PATH"]!.hasPrefix("/tmp/toolchain/bin:"))
        XCTAssertTrue(result["PATH"]!.contains("/opt/homebrew/bin"))
    }

    func testPlaceholdersInsideReplacementValuesStayLiteral() throws {
        let arguments = try HarnessArgumentTemplate.arguments(
            template: "-C {project} {prompt}",
            projectURL: URL(fileURLWithPath: "/tmp/{prompt}"),
            contextURL: URL(fileURLWithPath: "/tmp/context"), prompt: "keep {context} literal"
        )
        XCTAssertEqual(arguments, ["-C", "/tmp/{prompt}", "keep {context} literal"])
    }

    func testDictionaryTaskUsesWritableSandboxOnlyForDefaultCodexTemplate() throws {
        let suite = "dictionary-task-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HarnessCenterModel(defaults: defaults)
        model.setExecutablePath("/usr/bin/true", for: .codex)
        let root = URL(fileURLWithPath: "/tmp")
        let request = try XCTUnwrap(model.previewLaunchRequest(for: .codex, projectURL: root,
            contextURL: root, prompt: "index", dictionaryTask: true))
        XCTAssertTrue(request.arguments.contains("workspace-write"))
        let readOnly = try XCTUnwrap(model.previewLaunchRequest(for: .codex, projectURL: root,
            contextURL: root, prompt: "explain"))
        XCTAssertTrue(readOnly.arguments.contains("read-only"))
        model.setArgumentTemplate("custom {prompt}", for: .codex)
        XCTAssertEqual(model.previewLaunchRequest(for: .codex, projectURL: root, contextURL: root,
            prompt: "index", dictionaryTask: true)?.arguments, ["custom", "index"])
    }

    func testHermesLegacySafeModeMigratesWithoutDiscardingPath() throws {
        let suite = "hermes-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(["hermes": HarnessConfiguration(
            executablePath: "/usr/bin/true", argumentTemplate: "--safe-mode --oneshot {prompt}"
        )]), forKey: "funcDictionary.mac.harnessConfigurations")
        let configuration = HarnessCenterModel(defaults: defaults).connection(for: .hermes)?.configuration
        XCTAssertEqual(configuration?.executablePath, "/usr/bin/true")
        XCTAssertEqual(configuration?.argumentTemplate, "--in {project} --oneshot {prompt}")
    }

    func testArgumentTemplateReplacesValuesWithoutSplittingPrompt() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/Project With Space", isDirectory: true)
        let contextURL = projectURL.appendingPathComponent(".funcdictionary/agent-context.json")

        let arguments = try HarnessArgumentTemplate.arguments(
            template: "exec --sandbox read-only -C {project} {prompt}",
            projectURL: projectURL,
            contextURL: contextURL,
            prompt: "读取 Context 并解释 Definition"
        )

        XCTAssertEqual(arguments, [
            "exec",
            "--sandbox",
            "read-only",
            "-C",
            projectURL.path,
            "读取 Context 并解释 Definition"
        ])
    }

    func testArgumentTemplateSupportsQuotesAndRejectsUnclosedQuotes() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/Project", isDirectory: true)
        let contextURL = projectURL.appendingPathComponent("context.json")

        let arguments = try HarnessArgumentTemplate.arguments(
            template: "--in \"{project}\" --context '{context}' {prompt}",
            projectURL: projectURL,
            contextURL: contextURL,
            prompt: "hello world"
        )
        XCTAssertEqual(arguments, ["--in", projectURL.path, "--context", contextURL.path, "hello world"])

        XCTAssertThrowsError(
            try HarnessArgumentTemplate.arguments(
                template: "--in \"{project}",
                projectURL: projectURL,
                contextURL: contextURL,
                prompt: "hello"
            )
        )
    }

    func testPreviewLaunchRequestRemainsFrozenAfterConfigurationChanges() async throws {
        let suiteName = "funcDictionary.mac.harness-preview-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarnessCenterModel(defaults: defaults)
        model.setExecutablePath("/usr/bin/true", for: .zcode)
        model.setArgumentTemplate("{prompt}", for: .zcode)

        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-preview-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let request = try XCTUnwrap(model.previewLaunchRequest(
            for: .zcode,
            projectURL: projectURL,
            contextURL: projectURL.appendingPathComponent("context.json"),
            prompt: "frozen prompt"
        ))

        model.setExecutablePath("/usr/bin/false", for: .zcode)
        model.send(.zcode, launchRequest: request, workingDirectoryURL: projectURL)
        try await waitForStatus(.connected, harness: .zcode, model: model)
    }

    func testResolverHonorsConfiguredExecutableAndReportsMissingPath() {
        XCTAssertEqual(
            HarnessExecutableResolver.resolve(harness: .codex, configuredPath: "/usr/bin/true")?.path,
            "/usr/bin/true"
        )
        XCTAssertNil(
            HarnessExecutableResolver.resolve(harness: .codex, configuredPath: "/tmp/not-a-real-harness")
        )
    }

    func testConfigurationPersistsPerHarness() {
        let suiteName = "funcDictionary.mac.harness-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstModel = HarnessCenterModel(defaults: defaults)
        firstModel.setArgumentTemplate("--context {context} {prompt}", for: .zcode)

        let secondModel = HarnessCenterModel(defaults: defaults)
        XCTAssertEqual(
            secondModel.connection(for: .zcode)?.configuration.argumentTemplate,
            "--context {context} {prompt}"
        )
    }

    func testProcessRunnerUpdatesConnectedAndFailedStates() async throws {
        let suiteName = "funcDictionary.mac.harness-process-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarnessCenterModel(defaults: defaults)

        model.setExecutablePath("/usr/bin/true", for: .zcode)
        model.test(.zcode)
        try await waitForStatus(.connected, harness: .zcode, model: model)

        model.setExecutablePath("/usr/bin/false", for: .zcode)
        model.test(.zcode)
        try await waitForStatus(.failed, harness: .zcode, model: model)
        XCTAssertTrue(model.connection(for: .zcode)?.details.contains("退出码") == true)
    }

    func testSendUsesTemplateAndCapturesLocalHarnessOutput() async throws {
        let suiteName = "funcDictionary.mac.harness-send-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HarnessCenterModel(defaults: defaults)

        model.setExecutablePath("/usr/bin/printf", for: .zcode)
        model.setArgumentTemplate("%s {prompt}", for: .zcode)
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-send-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        model.send(
            .zcode,
            projectURL: projectURL,
            contextURL: projectURL.appendingPathComponent("context.json"),
            prompt: "local harness output"
        )

        try await waitForStatus(.connected, harness: .zcode, model: model)
        XCTAssertEqual(model.connection(for: .zcode)?.lastOutput, "local harness output")
        XCTAssertTrue(model.connection(for: .zcode)?.details.contains("Context 已通过 printf 发送") == true)
    }

    func testProcessRunnerCapturesBoundedOutputWithoutWaitingForPipeDrain() async {
        let result = await HarnessProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", String(repeating: "x", count: 40_000)],
            workingDirectoryURL: nil,
            timeout: 5
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output.count, 12_000)
        XCTAssertFalse(result.didTimeOut)
    }

    func testProcessRunnerStopsAStalledHarnessAtTimeout() async {
        let startedAt = Date()
        let result = await HarnessProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            workingDirectoryURL: nil,
            timeout: 0.1
        )

        XCTAssertTrue(result.didTimeOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testProcessRunnerCanBeCancelledAndKillsChildProcess() async throws {
        let task = Task {
            await HarnessProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 5"],
                workingDirectoryURL: nil,
                timeout: 10
            )
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -3)
        XCTAssertFalse(result.didTimeOut)
        XCTAssertTrue(result.error?.contains("取消") == true)
    }

    func testProcessRunnerKeepsStdoutAndStderrBoundedAndSeparated() async {
        let result = await HarnessProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf stdout; printf stderr >&2"],
            workingDirectoryURL: nil,
            timeout: 5
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.output.contains("stdout"))
        XCTAssertTrue(result.output.contains("[stderr]"))
        XCTAssertTrue(result.output.contains("stderr"))
        XCTAssertEqual(result.error, "stderr")
    }

    func testProcessRunnerRejectsMissingWorkingDirectoryBeforeLaunching() async {
        let result = await HarnessProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/funcDictionary-no-such-directory"),
            timeout: 1
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.error?.contains("工作目录不存在") == true)
    }

    private func waitForStatus(
        _ expected: HarnessConnectionStatus,
        harness: HarnessID,
        model: HarnessCenterModel
    ) async throws {
        for _ in 0..<40 {
            if model.connection(for: harness)?.status == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Expected \(expected), got \(model.connection(for: harness)?.status as Any)")
    }
}
