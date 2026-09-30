# ADR-002：Cloud Store 与 Local Store

## 决策

Core Data 模型从第一版声明两个 configuration：`CloudStore` 保存跨设备产品数据，`LocalStore` 保存项目本地路径、导入导出状态和设备运行状态。两个 configuration 之间不建立 Core Data relationship，只通过稳定的 `projectID` 等值 ID 关联。

## 原因

本地项目路径和 security-scoped bookmark 不应上传 CloudKit；Definition、治理状态和历史则需要在设备间同步。提前拆分 configuration 可以避免以后把本地权限数据误镜像到云端。

## 约束

- P2 先使用本地 SQLite / In-Memory；P7 才启用 CloudKit options。
- 所有跨项目查询必须注入 `projectID`。
- CloudKit 生产 Schema 提升不属于默认授权。

