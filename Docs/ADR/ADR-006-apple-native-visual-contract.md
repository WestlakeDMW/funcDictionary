# ADR-006：Apple 原生视觉与交互合同

## 决策

使用 UIKit 系统导航、列表、搜索、Sheet、Popover、SF Symbols、语义颜色和 Dynamic Type。内容层使用标准系统背景材质；Liquid Glass 仅由系统控件和导航层按系统能力提供。iPhone 采用导航栈，iPad / Catalyst 使用 Split View；Catalyst 额外提供菜单、快捷键、指针和窗口适配。

本轮 macOS MVP 使用 SwiftUI 原生桌面结构，不把 iPad/Catalyst 界面等比放大到 macOS。macOS 采用 `NavigationSplitView` 侧边栏、`HSplitView` 词典工作区、标准 `Window` 场景、系统菜单、键盘快捷键、`TextField`/`TextEditor`、`ContentUnavailableView`、`regularMaterial` 和 SF Symbols。AppKit 只通过 `NSOpenPanel`、`NSWorkspace`、`NSPasteboard` 与窗口激活做窄桥接；业务状态与领域逻辑仍由共享模型和 Core Data 仓储承载。

macOS 的桌面交互合同：项目、Definition 和 Harness 连接保持明确的空间层级；列表支持搜索与键盘选择；详情支持文本选择、复制 Context、显示交换文件；工作区路径可以由用户选择；连接器状态同时提供图标、文字和最后一次输出，不依赖颜色或动效单独表达。

## 无障碍与动效

- 默认触控目标至少 44×44 pt，Dynamic Type 验证至 200%。
- VoiceOver 顺序与视觉顺序一致，Change Heat 同时提供文本和朗读描述。
- 支持浅色、深色、增强对比度、降低透明度、减弱动态效果。
- Reduce Motion 时使用短暂淡变而非大范围位移；动画不是唯一状态说明。

macOS 同样遵守上述无障碍规则：使用系统字体和语义颜色、保持键盘可达、为核心控件提供可访问名称与帮助文本、让状态文字与图标同时出现，并在窗口缩放和较大字号下保持内容可读。

## 禁止项

不使用装饰性渐变、霓虹描边、大量悬浮胶囊、自绘系统玻璃背景，也不以单一颜色同时表达 Lifecycle、Human Priority、Active Context 与 Change Heat。
