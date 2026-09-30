# ADR-004：`.funcdictionary` 交换目录与原子写入

## 决策

`.funcdictionary` 是 App 与 Agent 之间的可移植交换包，不是运行时数据库。交换包使用 `project.json`、`definitions.json`、`clusters.json`、`agent-context.json`、`deltas/` 与 `snapshots/`；JSON 只保存 Snapshot 文件相对路径和元数据，不保存 Base64 图片。所有写入先写同目录临时文件、验证完整 Schema，再用原子替换提交。

## 原因

App 需要 Core Data 的离线、事务和 CloudKit 镜像；Agent 需要稳定、可 diff、可审阅的文件协议。分离两者可以避免手工编辑交换文件破坏运行时状态。

## 约束

- 导入必须校验 schema、projectID、baseRevision，并按 deltaID 幂等。
- 项目根目录和 security-scoped access 由 Mac Catalyst 负责；iPhone / iPad 不直接扫描开发项目。
- 敏感本地绝对路径不得写入共享 JSON。

