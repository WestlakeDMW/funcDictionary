# ADR-007：字段级 Revision 与冲突治理

## 决策

每个 Delta 携带 `deltaID`、`projectID`、`baseRevision`、`targetRevision`、`changedFields` 和时间。每个关键字段维护 `FieldRevision`；同一关键字段在共同 baseRevision 后被双方修改时建立 `ConflictRecord`，身份、canonical name、review status、lineage 与 protected structure 永远进入 Human Review。不同字段可自动合并。

## 原因

CloudKit 镜像和默认 last-write-wins 不能单独满足产品要求。显式字段 revision 让冲突可解释、可复现，并能在离线恢复后继续治理。

## 约束

- 合并成功必须记录 `ImplementationEvent` / `FieldRevision`。
- Conflict、Proposal、Change Request 是产品状态，不通过 UI 静默覆盖。
- 冲突判断不依赖 wall-clock 顺序；revision 和 baseRevision 是主要依据。

