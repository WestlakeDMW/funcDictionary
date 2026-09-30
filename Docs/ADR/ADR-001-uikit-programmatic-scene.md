# ADR-001：UIKit、程序化 UI 与 UIScene 生命周期

## 决策

客户端采用 Swift + UIKit，全部界面程序化构建，不使用 Main Storyboard。App 使用 `UIApplicationDelegate` + `UIScene` / `UIWindowScene` 生命周期。iPhone 使用 `UINavigationController`，iPad 与 Mac Catalyst 使用 `UISplitViewController` 作为自适应导航骨架。

## 原因

产品需要 iPhone、iPad、Mac Catalyst 共用 UIKit 页面，同时保留原地展开、键盘、指针和菜单等平台能力。程序化 UI 让依赖装配、UI 测试启动参数和动态布局可以被代码审查。

## 约束

- UIKit 层不得直接访问 `NSManagedObject`。
- 不用自绘玻璃背景替代系统导航栏、工具栏、Sheet 或 Split View。
- 所有核心动作必须有可测试的 accessibility identifier。

