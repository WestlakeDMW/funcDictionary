import Foundation

enum AgentWorkspace {
    static let indexingPrompt = """
    每次开始任务先读取 .funcdictionary/AGENTS.md 和 dictionary.json。每次修改函数、方法或直接调用处后，
    在结束任务前更新受影响词条、调用记录与变更历史，并提交增量等待 App 确认；不要等用户提醒。
    将当前仓库中现有函数词典化时，
    盘点源码中的函数、方法与重载，逐项阅读实现及调用处；记录中文用途、输入输出、
    副作用、直接调用关系和代码位置，支持从用途找函数、从函数查用途。
    调用关系用 calls，从调用方指向被调用方，并记录相对 file、正整数 line 和 evidence；没有代码依据就不建边。
    保留已有 Definition ID 和人工注释，只向 .funcdictionary/deltas/ 提交经过校验的增量。
    不修改业务源码。分批提交，每批等待 App 确认后再读取最新 revision。
    在 .funcdictionary/coverage.json 记录已覆盖、排除与未完成范围；不要把部分扫描报告成全量完成。
    """

    static func validate(root: URL, projectID: String? = nil) throws {
        guard root.isFileURL,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw MacAppError.noWorkspace
        }
        let exchange = root.appendingPathComponent(".funcdictionary")
        // Never follow an exchange-directory symlink into another project.
        guard exchange.resolvingSymlinksInPath().standardizedFileURL.path == root.resolvingSymlinksInPath().appendingPathComponent(".funcdictionary").standardizedFileURL.path else {
            throw ExchangeValidationError.projectMismatch(".funcdictionary 不能是符号链接")
        }
        for name in ["project.json", "dictionary.json", "agent-context.json", "deltas", "deltas/applied"] {
            let url = exchange.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ExchangeValidationError.projectMismatch("交换文件不能是符号链接：\(name)")
            }
        }
        let manifest = exchange.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: manifest.path), let projectID {
            let project = try JSONCodec.decode(Project.self, from: Data(contentsOf: manifest))
            guard project.id == projectID else {
                throw ExchangeValidationError.projectMismatch("该目录已关联另一个词典项目：\(project.name)")
            }
        }
    }

    /// App-owned read models. Publish dictionary.json atomically as the
    /// authoritative CLI view; leave the inbox and its audit archive intact.
    static func publish(snapshot: ProjectSnapshot, root: URL, bundle: Bundle = .main) throws {
        try validate(root: root, projectID: snapshot.project.id)
        let directory = root.appendingPathComponent(".funcdictionary", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("deltas"), withIntermediateDirectories: true)
        let resources = [
            ("funcdictionary.py", "funcdictionary.py"),
            ("validate_json.py", "validate_json.py"),
            ("protocol.md", "protocol.md"),
            ("agent-workflow.md", "AGENTS.md"),
            ("dictionary-delta.schema.json", "dictionary-delta.schema.json"),
            ("dictionary-snapshot.schema.json", "dictionary-snapshot.schema.json")
        ]
        for (source, destination) in resources {
            guard let url = bundle.resourceURL?.appendingPathComponent(source),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "App 接入包缺少 \(source)，请重新构建应用。"])
            }
            try Data(contentsOf: url).write(to: directory.appendingPathComponent(destination), options: .atomic)
        }
        try JSONCodec.encode(snapshot.project).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        try JSONCodec.encode(snapshot).write(to: directory.appendingPathComponent("dictionary.json"), options: .atomic)
    }

    static func root(from url: URL) throws -> URL {
        guard url.scheme == "funcdictionary", url.host == "link",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 1, items[0].name == "path",
              let path = items[0].value, path.hasPrefix("/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try validate(root: root)
        return root
    }
}
