# 核心对象与协议映射

| MVP 对象 | Cloud Store / Local Store | JSON 位置 | 稳定标识 | 备注 |
| --- | --- | --- | --- | --- |
| Project | Cloud | `project` | `project.id` | 所有查询的隔离边界 |
| Definition | Cloud | `definitions[]` | `definition.id` | 概念身份，演变不换 ID |
| CodeLocator | Cloud | `definition.code_locator` | Definition ID + locator | 行号仅辅助 |
| VisualLocator | Cloud | `definition.visual_locator` | Definition ID | 与功能定位分离 |
| FunctionalLocator | Cloud | `definition.functional_locator` | Definition ID | 位置变化不改变身份 |
| FuzzyTerm | Cloud | `definition.fuzzy_terms[]` | term ID / Definition ID | user 权重最高 |
| Relation | Cloud | `definition.relations[]` | relation ID | 维护正向与反向查询 |
| Reference | Cloud | `definition.references[]` | reference ID | 外部来源元数据 |
| ImplementationEvent | Cloud | `definition.implementation_history[]` | revision | 保存 change / semantic impact |
| Snapshot | Cloud | `definition.snapshots[]` | snapshot ID | JSON 仅路径与元数据 |
| Cluster | Cloud | `clusters[]` | cluster ID | 正式建立必须经过 Proposal |
| ClusterMembership | Cloud | `cluster.definition_ids[]` | cluster + definition ID | 多簇成员，单一 primary |
| Proposal | Cloud | `delta.proposals[]` | proposal ID | Split/Merge/Deprecated/Identity/Cluster |
| ChangeRequest | Cloud | `delta.change_requests[]` | request ID | Protected 结构性修改 |
| HumanPriority | Cloud | `definition.human_priority` | Definition ID | 不覆盖系统 Lifecycle |
| ActiveContext | Local/derived | `agent_context` | Definition ID | 当前操作提升，不污染相关性 |
| FieldRevision | Cloud | `delta.changed_fields` + persistence record | entity + field | 关键字段冲突依据 |
| ConflictRecord | Cloud | `delta.conflict_records[]` | conflict ID | 身份冲突进入 Human Review |
| ProjectAccess | Local | 不进入共享 JSON | project ID | 路径与 bookmark 不上传 |
| ExportState | Local | 不进入共享 JSON | project ID | revision/hash/time |
| DeviceState | Local | 不进入共享 JSON | device ID | 设备与 CloudKit 事件 |

## Core Data / CloudKit 模型硬约束

- 不使用 Core Data unique constraints、Undefined、objectID 属性。
- Cloud Store relationship（如实现）必须 optional、有 inverse、非 Deny 删除。
- 两个 configuration 不建立关系。
- 每个产品实体具备 stable ID、schemaVersion、createdAt、updatedAt；应用层校验稳定 ID 唯一性。
- 删除优先采用软删除或状态迁移。

