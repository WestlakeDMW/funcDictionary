<p align="center"><img src="Docs/Brand/funcDictionary-icon.png" width="144" alt="funcDictionary 图标"></p>

# funcDictionary

**为 Vibe Coding 提供随代码持续更新、可以随时查询的函数词典。**

[中文](README.md) · [English](README.en.md) · [安装](#安装) · [Agent 接入](#agent-接入与持续更新)

funcDictionary 是一个原生 macOS 应用。它将用户的自然语言表达、AI Agent 使用的功能名称与项目中的实际函数关联起来，建立可复用的共同基准：**用户的说法 → 统一叫法与别名 → 稳定词条 ID → 当前实现与调用位置**。

在 Vibe Coding 过程中，“同步项目”“右上角的刷新按钮”等表达往往需要 Agent 重新搜索文件、阅读代码并推断所指的组件。换一个 Agent 或开始新对话后，这些定位工作又可能重复。funcDictionary 把已经确认的对应关系保存为项目词典，让后续 Agent 先查询已有定义，再定位代码，减少反复猜测与扫描带来的上下文和 Token 消耗。

减少 Token 是本项目的设计目标；目前没有量化节省比例或对照实验。第一次建立词典仍需要 Agent 阅读源码，词典质量与后续维护决定了它能帮助减少多少重复工作。

> **当前状态：开发中的开源 MVP，采用 MIT 许可，提供源码构建。尚无签名、公证的正式安装包。** 主要维护 macOS；界面目前以中文为主，英文 README 不代表界面已经完整本地化。

## 功能

| 功能 | 对 Vibe Coding 的作用 |
| --- | --- |
| 项目功能词典 | 保存统一功能名称、用途、人工叫法与稳定 ID，为不同 Agent 提供同一份函数基准 |
| 双向查询 | 从自然语言、函数名、别名或代码路径找词条；从函数了解它的用途 |
| 全局检索 | App 运行时按 `⌘⇧Space` 呼出跨项目检索；按项目分组，支持键盘选择并打开词条 |
| 代码定位与调用依据 | 查看当前实现、已记录的直接调用方、文件位置与证据，复制定位信息继续开发 |
| 人工说明 | 补充自己的叫法、备注和重要性判断，供后续 Agent 沿用 |
| 改名与移动历史 | 保留稳定身份、旧称与变化记录，帮助新对话找到当前实现 |
| Agent 数据接口 | 项目内导出 JSON 词典、上下文、协议、校验器与 CLI，供已有 Agent 会话读取和更新 |
| 增量同步 | App 运行时自动处理已关联且可访问项目的有效提交；退出期间排队，重新启动后处理 |

全局检索在本地完成，使用分词、标识符拆分、内置中英同义词和加权匹配，不需要为每次查询调用远程模型。CLI 使用词条字段匹配，其查询结果不等同于 App 的全局检索排序。匹配仍依赖词典中已收录的内容。

## 安装

### 环境要求

| 项目 | 要求 |
| --- | --- |
| 运行系统 | macOS 14 或更新版本；这是目标最低版本，并非所有版本均已实际验收 |
| 构建工具 | 完整 Xcode 27，含 macOS SDK；当前 `.icon` 源文件使用 Icon Composer 27 配置 |
| 命令行 | Git；使用项目 CLI 时需要 Python 3.9+，无需额外 Python 依赖 |
| Agent | 用户已有的代码 Agent 会话；模型登录、额度与权限由该工具管理 |

先启动一次 Xcode，完成其组件安装与许可确认。仅安装 Command Line Tools 无法替代完整 Xcode。

### 方法一：从源码构建并运行

```sh
git clone https://github.com/WestlakeDMW/funcDictionary.git
cd funcDictionary
./script/build_and_run.sh
```

脚本构建 `funcDictionaryMac` 并打开应用。默认关闭本地代码签名，不要求配置 Apple 开发团队。默认构建产物位于：

```text
.build/macos-derived/Build/Products/Debug/funcDictionaryMac.app
```

若安装了多个 Xcode，或当前开发工具指向 Command Line Tools，可为本次运行指定完整 Xcode 路径：

```sh
FUNC_DICTIONARY_XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh
```

如果 Xcode 的名称或安装位置不同，将该路径替换为对应的 `Contents/Developer`。

### 方法二：使用 Xcode

1. 克隆或下载本仓库源码。
2. 用完整 Xcode 打开 `funcDictionary.xcodeproj`。
3. 选择 Scheme **funcDictionaryMac**，运行目标 **My Mac**。
4. 执行 **Product → Run**（`⌘R`）。

请使用 macOS Scheme；仓库中的 `funcDictionary` Scheme 属于暂缓发布的 iOS/Catalyst 路线。

### 保存到应用程序目录

源码构建成功后，可在 Finder 中打开构建产物：

```sh
open .build/macos-derived/Build/Products/Debug
```

将 `funcDictionaryMac.app` 拖入自己的 `~/Applications`（没有该文件夹时可自行创建），以后从 Finder 或 Spotlight 打开。这是本地开发构建，尚未作为正式分发安装包验收。首次关联项目时请使用你实际保留的那份 App。

### 更新与演示

干净的源码工作区可以拉取新版本再重建；有自己的改动时先提交或备份：

```sh
git pull --ff-only
./script/build_and_run.sh
```

想先看演示内容，可以运行隔离的演示模式：

```sh
FUNC_DICTIONARY_DEMO_DATA=1 FUNC_DICTIONARY_UI_TESTING=1 ./script/build_and_run.sh
```

该模式使用测试设置和内存数据库，不用于保存正式词典。更新正式版本前应备份本地应用数据与项目交换资料。

## 第一次使用

1. 启动正常模式 App，点击「添加项目」，选择源码根目录。
2. 点击「复制接入说明」，交给正在使用的 Agent。
3. 让 Agent 保留已有项目规则，将维护约定接入它实际读取的 Skill 或 `AGENTS.md` 入口。
4. Agent 阅读现有函数和调用处，分批建立词典，校验并提交，等待 App 确认入库。
5. 搜索中文描述、函数名或别名，查看用途与位置；用「编辑说明」补充自己的叫法。

添加目录只会建立项目和接入资料，首次词典仍需 Agent 扫描源码。较大项目建议按模块盘点，记录已完成与未完成范围。

App 运行时可按 `⌘⇧Space` 打开跨项目检索，也可使用「检索 → 全局功能检索…」（`⌘⇧K`）。若全局快捷键被其他工具占用，使用菜单入口；可在设置中关闭系统级快捷键。

## Agent 接入与持续更新

关联项目后，App 在源码根目录生成 `.funcdictionary/`：

| 文件 | 用途 |
| --- | --- |
| `AGENTS.md` | Agent 的建词典、查询和任务收尾规范 |
| `dictionary.json` | 最近一次 App 导出的完整词典与版本 |
| `agent-context.json` | 当前选择与项目上下文 |
| `protocol.md`、JSON Schema、`validate_json.py` | 增量格式与校验 |
| `funcdictionary.py` | 项目 CLI，提供查询、状态和提交 |
| `deltas/`、`deltas/applied/` | 等待处理的增量与已应用回执 |

### 查询：先复用定义，再定位实现

在已经关联的项目根目录运行：

```sh
# 检查最近导出的版本、词条数和待入库文件
python3 .funcdictionary/funcdictionary.py --project . status

# 用自然语言查功能，或用函数名查用途
python3 .funcdictionary/funcdictionary.py --project . search '同步项目' --direction purpose
python3 .funcdictionary/funcdictionary.py --project . search 'startSync' --direction code

# 读取完整词典；其输出大小随项目词条数增长
python3 .funcdictionary/funcdictionary.py --project . context
```

日常定位优先使用 `search` 的相关词条，减少每次将全部词典塞入对话的需要；首次建立和增量校验仍按协作规范读取必要的完整数据。查询命令读取本地导出数据，可离线使用，但不代表 App 或模型在线。

### 编程结束：更新词典并确认入库

建议把以下约定接入 Agent 实际执行的任务规则：开始时读取已有词典 → 修改代码 → 更新受影响词条、调用与历史 → 校验并提交 → 确认 App 入库。不同 Agent 或不同对话沿用同一项目的稳定 ID、统一叫法和人工说明。

```sh
# draft.json 由 Agent 按导出的协议生成
python3 .funcdictionary/validate_json.py .funcdictionary/draft.json
python3 .funcdictionary/funcdictionary.py --project . submit .funcdictionary/draft.json --wait 30
```

CLI 输出 JSON；退出码 `0` 表示成功，`1` 表示错误，`2` 表示等待 App 确认。提交只有 `state: applied` 才算入库，`pending` 不算完成。App 必须运行且项目可访问；版本过期时重新读取并计算差异，不能强行覆盖。并发 Agent 按版本协调提交，避免互相覆盖。

普通有效更新自动入库。身份不确定或内容冲突需要处理，保留人工内容与最后可信定义。旧称和稳定标识用于维持改名、移动后的对应关系。

**导出文件本身不会强制任意 Agent 自动遵守规则。** 宿主 Agent 需要实际加载并执行约定。真实多 Agent 连续交接与无需提醒的自动收尾仍待端到端验收。完整规范见 [Agent workflow](SupportingFiles/agent-workflow.md) 与 [func-sync Skill](.agents/skills/func-sync/SKILL.md)。

## 使用范围与数据

- 当前提供项目词典与文件交换；尚未建立词条的函数不会自动出现在查询中。AI 解释与调用记录依赖代码证据，没有调用记录不代表无人使用。
- 词典、查询和应用存储以本地为主。`.funcdictionary/` 可能包含非公开代码信息和人工备注，应加入目标项目的 Git 忽略规则；本仓库已忽略该目录、数据库与构建产物。
- 外部 Agent 的模型认证、费用和数据传输由所选工具决定。项目不提供统一的模型托管服务或 Token 节省保证。
- 项目之间独立保存；跨项目检索只在本机聚合展示，不合并词条身份。跨 Agent/跨对话指向同一项目词典，不等于跨设备自动同步。
- CloudKit 正式跨设备同步尚未验收；iOS、iPadOS、Mac Catalyst 暂缓发布。
- 发布安装包前仍需配置自己的应用标识、签名与公证。JSON 导出不是完整的数据库迁移或备份方案。

## 常见问题

**构建提示缺少 SDK、工具或无法编译图标？** 检查是否使用完整 Xcode 27，并完成首次启动设置；按安装章节指定正确 Developer 路径。

**搜索没有结果？** 确认 Agent 已建立并提交词条、App 已入库；检查版本、别名和扫描范围。CLI 是字段匹配，不能保证任意换一种说法都能命中。

**提交一直 pending？** 打开 App，检查项目源码目录是否仍可访问和项目页的同步状态；根据错误修正增量，版本过期时先重新读取。

**换一个 Agent 后如何继续？** 将接入说明交给新 Agent，让它读取同一项目词典并沿用名称、ID 与人工说明；不必重新从零建立另一份词典。

## 开发与验证

```sh
./script/build_and_run.sh --test
python3 -m unittest discover -s script -p 'test_*.py'
./script/build_and_run.sh --verify
```

构建、测试、界面交互、搜索性能和真实 Agent 接入分别验证。GitHub Actions 当前执行 CLI 测试，不代表 macOS UI 或模型任务通过。记录见 [开源准备](Docs/OpenSourceReadiness.md)。

| 路径 | 内容 |
| --- | --- |
| `funcDictionaryMac/` | macOS SwiftUI 界面、全局检索、Agent 接入和增量监听 |
| `funcDictionary/Domain/` | 领域模型、搜索引擎、版本和增量规则 |
| `funcDictionary/Data/` | Core Data 等持久化适配 |
| `SupportingFiles/` | Schema、合成样例和协作规范 |
| `script/` | 构建脚本、CLI 和验证 |
| `funcDictionaryMac/funcDictionary.icon/` | 当前 Icon Composer 源文件 |

更多设计背景见 [精简版 PRD](Docs/PRD-精简版.md)。历史文档只代表其记录日期。

## 参与贡献与许可

欢迎 [提交 Issue](https://github.com/WestlakeDMW/funcDictionary/issues) 或 Pull Request。请先阅读 [贡献指南](CONTRIBUTING.md)，使用合成数据复现问题。安全问题按 [SECURITY.md](SECURITY.md) 私密报告。

代码与随附品牌素材采用 [MIT License](LICENSE)。第三方工具与商标遵循各自许可；本项目与 Apple 或任何 Agent 工具厂商不存在官方隶属关系。
