# ADR-005：`$func-sync` Skill 与 `/func-sync` 产品别名

## 决策

仓库级 Skill 的正式显式入口是 `$func-sync`。`/func-sync` 只作为产品文案和 description 中的兼容意图别名，不宣称已注册一个系统 Slash Command。Skill 输出严格的 Dictionary Delta，并运行仓库内 validator。

## 原因

Skill 的调用语法、产品语言和外部 Agent 控制能力是三个不同边界。区分它们可以避免把未注册的斜杠文案误报成可执行命令，也避免 Skill 越权执行身份级治理。

## 安全边界

- 只读取当前 Project 和当前项目交换目录。
- 不扫描项目目录之外的文件。
- 不自动批准 Split、Merge、Deprecated、Identity Change、删除或正式 Cluster。
- 不直接控制 Codex、IDE 或其他 App。

