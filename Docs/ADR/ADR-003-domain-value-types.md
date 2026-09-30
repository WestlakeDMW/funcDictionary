# ADR-003：Domain 值类型与 Core Data 隔离

## 决策

业务规则以 Foundation 值类型、纯函数 Engine 和 Repository protocol 表达。Core Data 仅负责持久化和事务；映射层将 managed record 转换为不可变 Domain 快照。UIKit、搜索和治理引擎不持有 managed object。

## 原因

Collection、Search、Lifecycle、Change Heat、Protection 和 Merge 需要固定 fixture、确定性输出和独立单元测试；把规则放进 `NSManagedObject` 或 ViewController 会让 CloudKit、并发和测试互相耦合。

## 约束

- Domain Engine 不导入 UIKit 或 Core Data。
- Repository 方法必须显式携带 `projectID`。
- stable ID 的唯一性由应用层校验，不依赖 Core Data unique constraint。

