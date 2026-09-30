import Foundation
import NaturalLanguage

/// 系统级全局检索：跨项目（跨 App 词典）用自然语言搜索 func。
///
/// 检索管线分五个阶段，全部为纯函数，便于离线测试：
///
/// 1. 查询理解（`GlobalSemanticQueryAnalyzer`）：归一化 → 分词（含 CJK
///    n-gram）→ 剔除停用词与检索套话 → 拆分 camelCase/snake_case 标识符
///    → 中英同义词扩展（带 0.85 折扣，保证原词始终压过扩展词）。
/// 2. 索引（`GlobalSearchIndex`）：每个 Definition 建五个加权字段桶
///    （alias 0.30 / semantic 0.24 / identity 0.20 / visual 0.12 / project
///    0.14），并维护 exact/token/trigram 倒排表；trigram 只在
///    exact/token 全部落空时取“最稀有”的一个做兜底，避免高频 trigram
///    引爆候选集。
/// 3. 打分：字段桶取“整查询匹配”与“实义词满足均值 × 0.92”的较大者。
///    每个实义词由它自己或它的同义词（打折）满足；总分 = Σ权重×字段分 ×
///    (0.70 + 0.30×词覆盖率) × humanPriority × activeContext 加成。多词
///    自然语言查询按覆盖比例得到部分分，避免“必须全词命中才能召回”。
/// 4. 跨项目归并：项目分 = best×0.75 + avg(top3)×0.25，最高分项目为
///    “匹配 App”主组；并列时先比命中数，再比项目名。
/// 5. 输出整形：主组展开返回 top 8，其余组折叠返回 top 3 预览 +
///    totalMatches；组内按相关度降序，平局按 canonicalName 稳定排序。
///
/// 索引是 Sendable 值快照：数据变化时整体重建，检索本身无共享可变状态，
/// 可在任意队列执行。
public enum GlobalSearchEngine {
    /// 低于该分的结果视为噪声丢弃。单个高权重字段命中（如 alias
    /// 0.30×1.0）仍可超过该值，而一行偶然的单 token 模糊命中不会。
    public static let minimumResultScore = 0.10

    /// 主组（匹配 App）展开展示的最大行数。
    public static let primaryResultLimit = 8
    /// 折叠组展示的预览行数。
    public static let collapsedResultLimit = 3

    public static func search(query: String, scopes: [GlobalSearchScope]) -> GlobalSearchResponse {
        search(query: query, index: GlobalSearchIndex(scopes: scopes))
    }

    public static func search(query: String, index: GlobalSearchIndex) -> GlobalSearchResponse {
        let analyzer = GlobalSemanticQueryAnalyzer(query: query)
        guard !analyzer.contentTokens.isEmpty else {
            return GlobalSearchResponse(query: query, groups: [])
        }
        let candidateIndices = index.candidateIndices(for: analyzer)
        guard !candidateIndices.isEmpty else {
            return GlobalSearchResponse(query: query, groups: [])
        }

        var scoredByProject: [String: [GlobalScoredDefinition]] = [:]
        for entryIndex in candidateIndices {
            let entry = index.entries[entryIndex]
            guard let scored = score(entry: entry, analyzer: analyzer) else { continue }
            guard scored.score >= minimumResultScore else { continue }
            scoredByProject[scored.definition.projectID, default: []].append(scored)
        }

        let groups = scoredByProject
            .compactMap { projectID, matches -> GlobalSearchGroup? in
                guard let projectName = index.projectName(byID: projectID) else { return nil }
                return makeGroup(projectID: projectID, projectName: projectName, matches: matches)
            }
            .sorted(by: groupOrder)

        guard let topGroup = groups.first else {
            return GlobalSearchResponse(query: query, groups: [])
        }
        let primary = GlobalSearchGroup(
            projectID: topGroup.projectID,
            projectName: topGroup.projectName,
            projectScore: topGroup.projectScore,
            isPrimary: true,
            totalMatches: topGroup.totalMatches,
            results: Array(topGroup.results.prefix(primaryResultLimit))
        )
        let collapsed = groups.dropFirst().map { group in
            GlobalSearchGroup(
                projectID: group.projectID,
                projectName: group.projectName,
                projectScore: group.projectScore,
                isPrimary: false,
                totalMatches: group.totalMatches,
                results: Array(group.results.prefix(collapsedResultLimit))
            )
        }
        return GlobalSearchResponse(query: query, groups: [primary] + collapsed)
    }

    // MARK: 打分

    private struct GlobalScoredDefinition {
        let definition: Definition
        let score: Double
        let evidence: String
    }

    private static func score(
        entry: GlobalSearchIndex.Entry,
        analyzer: GlobalSemanticQueryAnalyzer
    ) -> GlobalScoredDefinition? {
        var total = 0.0
        var evidence = ""
        var bestContribution = 0.0
        for bucket in entry.buckets {
            guard let match = bestFieldMatch(analyzer: analyzer, values: bucket.values) else { continue }
            let contribution = bucket.weight * min(match.score, 1)
            total += contribution
            if contribution > bestContribution {
                bestContribution = contribution
                evidence = match.evidence
            }
        }
        guard total > 0 else { return nil }

        // 多词自然语言查询按“命中了多少个实义词”给覆盖加成：整句匹配
        // 单词时不惩罚，多词只命中一个时缩水但仍保留部分相关度。
        let coverage = analyzer.coverage(ofTokens: entry.allTokens)
        total *= 0.70 + 0.30 * coverage

        let definition = entry.definition
        if let priority = definition.humanPriority {
            total *= priority.level == .critical ? 1.10 : 1.05
        }
        if definition.activeContext {
            total *= 1.05
        }
        return GlobalScoredDefinition(
            definition: definition,
            score: min(total, 1),
            evidence: evidence
        )
    }

    /// 单字段桶打分：整查询精确/前缀/包含通常压过逐词散命中；逐词满足
    /// 均值打 0.92 折用于多词自然语言查询。每个实义词由它自己或同义词
    /// （打折）满足，取较大者，保证扩展词不反超用户原词。
    private static func bestFieldMatch(
        analyzer: GlobalSemanticQueryAnalyzer,
        values: [GlobalSearchIndex.IndexedValue]
    ) -> GlobalSearchIndex.ValueMatch? {
        var best: GlobalSearchIndex.ValueMatch?
        for value in values where !value.normalized.isEmpty {
            if let match = value.match(wholeQuery: analyzer.normalized, queryTokens: analyzer.wholeQueryTokens) {
                if match.score * match.boost > (best?.score ?? 0) * (best?.boost ?? 0) {
                    best = match
                }
            }
        }

        var satisfiedTotal = 0.0
        var satisfiedCount = 0
        var tokenEvidence = ""
        for contentToken in analyzer.contentTokens {
            var tokenBest: GlobalSearchIndex.ValueMatch?
            for variant in contentToken.variants {
                for value in values where !value.normalized.isEmpty {
                    if let match = value.match(token: variant.text, discount: variant.discount),
                       match.score * match.boost > (tokenBest?.score ?? 0) * (tokenBest?.boost ?? 0) {
                        tokenBest = match
                    }
                }
            }
            if let tokenBest {
                satisfiedTotal += tokenBest.score * tokenBest.boost
                satisfiedCount += 1
                if tokenEvidence.isEmpty { tokenEvidence = tokenBest.evidence }
            }
        }
        guard satisfiedCount > 0 else { return best }
        let satisfiedMean = satisfiedTotal / Double(analyzer.contentTokens.count) * 0.92
        if satisfiedMean > (best?.score ?? 0) * (best?.boost ?? 1) {
            return GlobalSearchIndex.ValueMatch(score: satisfiedMean, boost: 1, evidence: tokenEvidence)
        }
        return best
    }

    private static func makeGroup(
        projectID: String,
        projectName: String,
        matches: [GlobalScoredDefinition]
    ) -> GlobalSearchGroup {
        let sorted = matches.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.definition.identity.canonicalName < rhs.definition.identity.canonicalName
            }
            return lhs.score > rhs.score
        }
        let topScores = sorted.prefix(3).map(\.score)
        let average = topScores.reduce(0, +) / Double(topScores.count)
        let projectScore = min(sorted[0].score * 0.75 + average * 0.25, 1)
        return GlobalSearchGroup(
            projectID: projectID,
            projectName: projectName,
            projectScore: projectScore,
            isPrimary: false,
            totalMatches: sorted.count,
            results: sorted.map { match in
                let definition = match.definition
                return GlobalSearchResult(
                    definitionID: definition.id,
                    projectID: definition.projectID,
                    canonicalName: definition.identity.canonicalName,
                    displayName: definition.identity.displayName,
                    functionName: definition.codeLocator.function,
                    symbol: definition.codeLocator.symbol,
                    comment: definition.codeLocator.comment,
                    purpose: definition.function.purpose,
                    score: match.score,
                    evidence: match.evidence
                )
            }
        )
    }

    private static func groupOrder(_ lhs: GlobalSearchGroup, _ rhs: GlobalSearchGroup) -> Bool {
        if lhs.projectScore == rhs.projectScore {
            if lhs.totalMatches == rhs.totalMatches {
                return lhs.projectName < rhs.projectName
            }
            return lhs.totalMatches > rhs.totalMatches
        }
        return lhs.projectScore > rhs.projectScore
    }
}

// MARK: - 查询输入/输出模型

/// 参与全局检索的一个项目（App）及其全部 Definition。
public struct GlobalSearchScope: Sendable {
    public let project: Project
    public let definitions: [Definition]

    public init(project: Project, definitions: [Definition]) {
        self.project = project
        self.definitions = definitions
    }
}

public struct GlobalSearchResult: Codable, Equatable, Hashable, Sendable {
    public var definitionID: String
    public var projectID: String
    public var canonicalName: String
    public var displayName: String
    public var functionName: String
    public var symbol: String
    public var comment: String
    public var purpose: String
    public var score: Double
    public var evidence: String

    public init(
        definitionID: String,
        projectID: String,
        canonicalName: String,
        displayName: String,
        functionName: String,
        symbol: String,
        comment: String,
        purpose: String,
        score: Double,
        evidence: String
    ) {
        self.definitionID = definitionID
        self.projectID = projectID
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.functionName = functionName
        self.symbol = symbol
        self.comment = comment
        self.purpose = purpose
        self.score = score
        self.evidence = evidence
    }
}

/// 按项目（App）聚合的一组结果。isPrimary 的组是“匹配 App”，界面展开
/// 展示；其余组折叠，只保留预览行。
public struct GlobalSearchGroup: Codable, Equatable, Sendable {
    public var projectID: String
    public var projectName: String
    public var projectScore: Double
    public var isPrimary: Bool
    public var totalMatches: Int
    public var results: [GlobalSearchResult]

    public init(
        projectID: String,
        projectName: String,
        projectScore: Double,
        isPrimary: Bool,
        totalMatches: Int,
        results: [GlobalSearchResult]
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.projectScore = projectScore
        self.isPrimary = isPrimary
        self.totalMatches = totalMatches
        self.results = results
    }
}

public struct GlobalSearchResponse: Codable, Equatable, Sendable {
    public var query: String
    public var groups: [GlobalSearchGroup]

    public init(query: String, groups: [GlobalSearchGroup]) {
        self.query = query
        self.groups = groups
    }

    public static let empty = GlobalSearchResponse(query: "", groups: [])

    public var isEmpty: Bool { groups.allSatisfy(\.results.isEmpty) }
}

// MARK: - 查询理解

/// 自然语言查询理解器。产出：
/// - `normalized` / `wholeQueryTokens`：整句归一化文本及其分词；
/// - `contentTokens`：剔除停用词后的实义词，每个词携带“自身 + 同义扩展”
///    的满足方式（扩展带折扣）。
public struct GlobalSemanticQueryAnalyzer: Sendable {
    public struct ContentToken: Sendable {
        public let text: String
        /// 可满足该词的变体：自身（discount 1）+ 同义扩展（discount 0.85）。
        public let variants: [Variant]
        public struct Variant: Sendable {
            public let text: String
            public let discount: Double
        }
    }

    public let normalized: String
    public let wholeQueryTokens: [String]
    public let contentTokens: [ContentToken]

    public init(query: String) {
        let normalized = SearchNormalizer.normalize(query)
        let rawTokens = SearchNormalizer.tokens(normalized)

        // 停用词 + 检索套话剔除：保留携带检索意图的实义词。ASCII 词保留
        // 原始大小写后拆分（camelCase 边界在小写化后丢失），CJK 段用 NL
        // 分词取整词（字符 gram 留给索引侧做包含匹配）。
        var content: [String] = []
        var seen: Set<String> = []
        for word in Self.extractWords(from: query) {
            if GlobalSearchVocabulary.isStopWord(word) { continue }
            if seen.insert(word).inserted { content.append(word) }
        }
        // 全部词都被判为停用词时（如查询本身就是“搜索”），退回原词保证
        // 用户仍能检索到字面匹配。
        if content.isEmpty {
            for token in rawTokens where seen.insert(token).inserted {
                content.append(token)
            }
        }

        contentTokens = content.map { token in
            var variants = [ContentToken.Variant(text: token, discount: 1)]
            var expansionsSeen = Set([token])
            for synonym in GlobalSearchVocabulary.synonyms(for: token)
            where expansionsSeen.insert(synonym).inserted {
                variants.append(ContentToken.Variant(text: synonym, discount: 0.85))
            }
            return ContentToken(text: token, variants: variants)
        }
        self.normalized = normalized
        wholeQueryTokens = rawTokens
    }

    /// 把查询切成 ASCII 词段（保留大小写后走标识符拆分）与非 ASCII 字母
    /// 段（交给 NL 分词），避免“找login”这种混排被合并成一个词。
    private static func extractWords(from query: String) -> [String] {
        var words: [String] = []
        var asciiRun = ""
        var otherRun = ""

        func flushASCII() {
            guard !asciiRun.isEmpty else { return }
            words.append(contentsOf: GlobalSearchVocabulary.splitIdentifier(asciiRun))
            asciiRun = ""
        }
        func flushOther() {
            guard !otherRun.isEmpty else { return }
            words.append(contentsOf: GlobalSearchVocabulary.segment(otherRun))
            otherRun = ""
        }

        for character in query {
            guard character.isLetter || character.isNumber else {
                flushASCII()
                flushOther()
                continue
            }
            if character.isASCII {
                flushOther()
                asciiRun.append(character)
            } else {
                flushASCII()
                otherRun.append(character)
            }
        }
        flushASCII()
        flushOther()
        return words
    }

    /// 满足的实义词比例：多词查询按覆盖给分，缺词按比例缩水。
    /// `tokens` 是词条所有字段值 token 的并集。
    public func coverage(ofTokens tokens: Set<String>) -> Double {
        guard !contentTokens.isEmpty else { return 0 }
        var satisfied = 0
        for contentToken in contentTokens {
            if contentToken.variants.contains(where: { variant in tokens.contains(variant.text) }) {
                satisfied += 1
            }
        }
        return Double(satisfied) / Double(contentTokens.count)
    }
}

/// 离线检索词表：停用词、标识符拆分、中英同义扩展。
/// 保持小而保守：只收录高频、歧义低的映射，错配会直接污染排序。
public enum GlobalSearchVocabulary {
    public static func isStopWord(_ token: String) -> Bool {
        stopWords.contains(token)
    }

    /// camelCase / snake_case / kebab-case 拆分为小写词。连续大写视作缩写
    /// 整体（URLSession → url session）。
    public static func splitIdentifier(_ token: String) -> [String] {
        guard token.contains(where: { $0.isUppercase }) || token.contains("_") || token.contains("-") else {
            return [token.lowercased()]
        }
        let characters = Array(token)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                continue
            }
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsNewWord =
                (character.isUppercase && (previous?.isLowercase == true || previous?.isNumber == true))
                || (character.isUppercase && previous?.isUppercase == true && next?.isLowercase == true)
            if startsNewWord, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        let lowered = words.map { $0.lowercased() }.filter { !$0.isEmpty }
        return lowered.isEmpty ? [token.lowercased()] : lowered
    }

    /// NL 分词的整词（不含字符 gram 展开），用于查询侧的 CJK 实义词。
    public static func segment(_ value: String) -> [String] {
        let normalized = SearchNormalizer.normalize(value)
        guard !normalized.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var words: [String] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let word = String(normalized[range])
            if !word.isEmpty { words.append(word) }
            return true
        }
        if words.isEmpty {
            words = normalized.split(separator: " ").map(String.init)
        }
        return words
    }

    /// 从原始（未小写化）文本提取标识符部件：loginView → login view。
    /// 索引侧与查询侧共用，保证两侧词形一致。
    public static func identifierParts(of raw: String) -> [String] {
        let words = raw.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        return words.flatMap { splitIdentifier(String($0)) }
    }

    /// 中英同义扩展：返回检索时可替代命中的词（小写）。只做单级扩展，
    /// 不传递（删除 → delete，但不再 delete → 删除）。
    public static func synonyms(for token: String) -> [String] {
        guard token.count >= 2 else { return [] }
        if let list = synonymTable[token] { return list }
        // 复合中文词不在表内时，截去常见界面后缀再查（列表页 → 列表）。
        for suffix in ["页面", "界面", "功能", "按钮", "弹窗"]
        where token.hasSuffix(suffix) && token.count > suffix.count {
            if let list = synonymTable[String(token.dropLast(suffix.count))] { return list }
        }
        return []
    }

    private static let stopWords: Set<String> = [
        // 中文虚词与检索套话（NL 分词可能把“帮我”拆成“帮”+“我”，
        // 所以口语动词的单字形态也要收录）
        "的", "了", "是", "在", "和", "与", "或", "我", "你", "他", "她", "它", "这", "那",
        "怎么", "怎样", "如何", "为什么", "哪个", "哪些", "哪里", "什么", "多少", "可以", "请问",
        "一下", "一个", "这个", "那个", "有没有", "帮我", "帮", "帮忙", "麻烦", "看看", "想找",
        "找", "找出", "查找", "搜索", "搜", "查", "查查",
        "函数", "方法", "接口", "功能", "代码", "实现", "相关", "对应", "地方", "位置",
        // 英文虚词与检索套话
        "the", "a", "an", "of", "to", "for", "and", "or", "is", "are", "be", "in", "on", "at",
        "it", "its", "this", "that", "how", "what", "which", "where", "when", "who", "why",
        "find", "search", "lookup", "look", "show", "me", "my", "func", "function", "method",
        "api", "code", "implement", "implementation", "place", "locate", "get"
    ]

    private static let synonymTable: [String: [String]] = [
        // 中文 → 英文
        "登录": ["login", "signin", "auth"], "登陆": ["login", "signin"],
        "注销": ["logout"], "注册": ["register", "signup"],
        "用户": ["user", "account"], "账号": ["account", "user"], "账户": ["account", "user"],
        "密码": ["password", "credential"],
        "删除": ["delete", "remove"], "移除": ["remove", "delete"],
        "新增": ["add", "create"], "添加": ["add", "create"], "创建": ["create", "add"],
        "编辑": ["edit", "modify"], "修改": ["modify", "edit", "update"], "更新": ["update", "refresh"],
        "列表": ["list"], "详情": ["detail"], "首页": ["home"],
        "筛选": ["filter"], "排序": ["sort"],
        "刷新": ["refresh", "reload"], "加载": ["load"], "下载": ["download"], "上传": ["upload"],
        "图片": ["image", "photo"], "视频": ["video"], "音频": ["audio"],
        "缓存": ["cache"], "网络": ["network"], "请求": ["request"], "响应": ["response"],
        "设置": ["settings", "preference"], "配置": ["config", "configuration"],
        "通知": ["notification"], "消息": ["message"], "提醒": ["reminder", "alert"],
        "权限": ["permission", "authority"], "支付": ["payment", "pay"], "订单": ["order"],
        "购物车": ["cart"], "分享": ["share"], "评论": ["comment", "review"],
        "收藏": ["favorite", "bookmark"], "点赞": ["like"],
        "主题": ["theme"], "深色": ["dark"], "浅色": ["light"],
        "验证": ["verify", "validation", "auth"], "校验": ["validation", "verify"],
        "同步": ["sync"], "备份": ["backup"], "导入": ["import"], "导出": ["export"],
        "弹窗": ["popup", "alert", "sheet"], "对话框": ["dialog", "alert"],
        "菜单": ["menu"], "导航": ["navigation", "nav"], "标签": ["tab", "tag", "label"],
        "按钮": ["button"], "输入": ["input"], "表单": ["form"], "键盘": ["keyboard"],
        "剪贴板": ["pasteboard", "clipboard"], "复制": ["copy"], "粘贴": ["paste"],
        "历史": ["history"], "记录": ["record", "log"], "日志": ["log"],
        "词典": ["dictionary"], "词条": ["definition", "entry"], "快照": ["snapshot"],
        "项目": ["project"], "工作区": ["workspace"],
        // 英文 → 中文
        "login": ["登录"], "signin": ["登录"], "logout": ["注销"],
        "user": ["用户"], "account": ["账号"], "password": ["密码"],
        "delete": ["删除"], "remove": ["删除"], "create": ["创建"], "add": ["添加"],
        "edit": ["编辑"], "update": ["更新"], "refresh": ["刷新"], "reload": ["刷新"],
        "list": ["列表"], "detail": ["详情"], "home": ["首页"],
        "filter": ["筛选"], "sort": ["排序"], "query": ["搜索"],
        "download": ["下载"], "upload": ["上传"], "image": ["图片"], "photo": ["图片"],
        "cache": ["缓存"], "network": ["网络"], "request": ["请求"], "response": ["响应"],
        "settings": ["设置"], "preference": ["设置"], "config": ["配置"],
        "notification": ["通知"], "message": ["消息"], "alert": ["提醒", "弹窗"],
        "permission": ["权限"], "payment": ["支付"], "pay": ["支付"], "order": ["订单"],
        "share": ["分享"], "comment": ["评论"], "favorite": ["收藏"], "bookmark": ["收藏"],
        "theme": ["主题"], "dark": ["深色"], "light": ["浅色"],
        "verify": ["验证"], "validation": ["校验"], "auth": ["登录", "验证"],
        "sync": ["同步"], "import": ["导入"], "export": ["导出"],
        "popup": ["弹窗"], "sheet": ["弹窗"], "dialog": ["对话框"],
        "menu": ["菜单"], "navigation": ["导航"], "tab": ["标签"], "label": ["标签"],
        "button": ["按钮"], "input": ["输入"], "form": ["表单"], "keyboard": ["键盘"],
        "copy": ["复制"], "paste": ["粘贴"], "clipboard": ["剪贴板"], "pasteboard": ["剪贴板"],
        "history": ["历史"], "log": ["日志"], "record": ["记录"],
        "dictionary": ["词典"], "definition": ["词条"], "snapshot": ["快照"],
        "project": ["项目"], "workspace": ["工作区"], "search": ["搜索"]
    ]
}

// MARK: - 索引

/// 跨项目倒排索引快照。构建成本 O(定义数 × 字段值数)；检索 O(候选数)。
/// 值类型 + 全 Sendable，可在任意执行上下文之间传递。
public struct GlobalSearchIndex: Sendable {
    public struct IndexedValue: Sendable {
        let raw: String
        let normalized: String
        let tokens: Set<String>
        let boost: Double

        /// 整查询与该值的一级匹配（精确 > 前缀 > 包含 > 全词覆盖）。
        func match(wholeQuery query: String, queryTokens: [String]) -> ValueMatch? {
            if normalized == query {
                return ValueMatch(score: 1, boost: boost, evidence: raw)
            }
            if query.count >= 2 {
                if normalized.hasPrefix(query) {
                    return ValueMatch(score: 0.88, boost: boost, evidence: raw)
                }
                if normalized.contains(query) {
                    return ValueMatch(score: 0.72, boost: boost, evidence: raw)
                }
            }
            guard !queryTokens.isEmpty, !tokens.isEmpty else { return nil }
            let matched = queryTokens.filter { token in
                tokens.contains { $0 == token || $0.hasPrefix(token) || token.hasPrefix($0) }
            }
            if matched.count == queryTokens.count {
                return ValueMatch(score: 0.65, boost: boost, evidence: raw)
            }
            return nil
        }

        /// 单 token 与该值的匹配；discount 作用于得分，保证扩展词不压过原词。
        func match(token: String, discount: Double) -> ValueMatch? {
            if tokens.contains(token) {
                return ValueMatch(score: discount, boost: boost, evidence: raw)
            }
            if token.count >= 2, normalized.contains(token) {
                return ValueMatch(score: 0.72 * discount, boost: boost, evidence: raw)
            }
            // 模糊兜底：只与值内 token 做 Levenshtein，避免对长文本逐字符算。
            var bestSimilarity = 0.0
            for valueToken in tokens {
                let similarity = SearchNormalizer.similarity(token, valueToken)
                if similarity > bestSimilarity { bestSimilarity = similarity }
            }
            guard bestSimilarity >= 0.72 else { return nil }
            return ValueMatch(score: bestSimilarity * 0.60 * discount, boost: boost, evidence: raw)
        }
    }

    public struct ValueMatch: Sendable {
        let score: Double
        let boost: Double
        let evidence: String
    }

    struct IndexedBucket: Sendable {
        let weight: Double
        let values: [IndexedValue]
    }

    public struct Entry: Sendable {
        public let definition: Definition
        let buckets: [IndexedBucket]
        /// 所有字段值 token 的并集，供覆盖率检查。
        public let allTokens: Set<String>
    }

    let entries: [Entry]
    private let projectNames: [String: String]
    private let exactMap: [String: IndexSet]
    private let tokenMap: [String: IndexSet]
    private let trigramMap: [String: IndexSet]

    public init(scopes: [GlobalSearchScope]) {
        var builtEntries: [Entry] = []
        var names: [String: String] = [:]
        var exact: [String: IndexSet] = [:]
        var tokenIndex: [String: IndexSet] = [:]
        var trigrams: [String: IndexSet] = [:]

        for scope in scopes {
            names[scope.project.id] = scope.project.name
            for definition in scope.definitions where definition.reviewStatus != .archived {
                let entryIndex = builtEntries.count
                var buckets: [IndexedBucket] = []
                var entryTokens: Set<String> = []

                func bucket(_ weight: Double, _ values: [(String, Double)]) {
                    var indexed: [IndexedValue] = []
                    for (raw, boost) in values
                    where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let normalized = SearchNormalizer.normalize(raw)
                        guard !normalized.isEmpty else { continue }
                        // token 集 = NL 分词（含 CJK gram）∪ 标识符部件
                        // （LoginViewController → login/view/controller），
                        // 让中英同义词与 camelCase 查询都能直接命中倒排表。
                        var tokens = Set(SearchNormalizer.tokens(raw))
                        tokens.formUnion(GlobalSearchVocabulary.identifierParts(of: raw))
                        indexed.append(IndexedValue(raw: raw, normalized: normalized, tokens: tokens, boost: boost))
                        entryTokens.formUnion(tokens)
                        exact[normalized, default: IndexSet()].insert(entryIndex)
                        for token in tokens {
                            tokenIndex[token, default: IndexSet()].insert(entryIndex)
                        }
                        let characters = Array(normalized)
                        guard characters.count >= 3 else { continue }
                        for start in 0...(characters.count - 3) {
                            trigrams[String(characters[start..<(start + 3)]), default: IndexSet()].insert(entryIndex)
                        }
                    }
                    if !indexed.isEmpty {
                        buckets.append(IndexedBucket(weight: weight, values: indexed))
                    }
                }

                // alias：人类维护的别名词，权重最高的召回面。
                bucket(
                    0.30,
                    definition.fuzzyTerms.map {
                        ($0.text, max(0, $0.weight) * Self.fuzzyTermBoost($0.source))
                    }
                )
                // semantic：用途/注释/职责描述，自然语言检索的主战场。
                bucket(0.24, [
                    (definition.function.purpose, 1),
                    (definition.function.domain, 1),
                    (definition.codeLocator.comment, 1),
                    (definition.function.actions.joined(separator: " "), 1),
                    (definition.functionalLocator.domain, 1),
                    (definition.functionalLocator.role, 1),
                    (definition.functionalLocator.trigger, 1)
                ])
                // identity：规范名/显示名/符号/函数签名/文件路径。
                bucket(0.20, [
                    (definition.identity.canonicalName, 1),
                    (definition.identity.displayName, 1),
                    (definition.codeLocator.symbol, 1),
                    (definition.codeLocator.function, 1),
                    (definition.codeLocator.signature, 1),
                    (definition.codeLocator.file, 1),
                    (definition.codeLocator.module, 1)
                ])
                // visual：界面位置记忆。
                bucket(0.12, [
                    (definition.visualLocator.screen, 1),
                    (definition.visualLocator.container, 1),
                    (definition.visualLocator.region, 1),
                    (definition.visualLocator.hierarchy.joined(separator: " "), 1)
                ])
                // project：项目名本身，让“在 XX 里搜登录”这类查询给整个
                // App 的词条加权。
                bucket(0.14, [(scope.project.name, 1.1)])

                builtEntries.append(
                    Entry(definition: definition, buckets: buckets, allTokens: entryTokens)
                )
            }
        }

        entries = builtEntries
        projectNames = names
        exactMap = exact
        tokenMap = tokenIndex
        trigramMap = trigrams
    }

    public func projectName(byID projectID: String) -> String? {
        projectNames[projectID]
    }

    /// 候选生成：exact → token 的并集；全部落空时取查询串的“最稀有
    /// trigram”兜底（保持错别字召回，同时限制 fan-out）。
    func candidateIndices(for analyzer: GlobalSemanticQueryAnalyzer) -> IndexSet {
        var candidates = IndexSet()
        let query = analyzer.normalized
        if !query.isEmpty, let exactHit = exactMap[query] {
            candidates.formUnion(exactHit)
        }
        for contentToken in analyzer.contentTokens {
            for variant in contentToken.variants {
                if let tokenHits = tokenMap[variant.text] {
                    candidates.formUnion(tokenHits)
                }
            }
        }
        if !candidates.isEmpty || query.count < 3 {
            return candidates
        }
        let characters = Array(query)
        guard characters.count >= 3 else { return candidates }
        let sets = (0...(characters.count - 3)).compactMap { start in
            trigramMap[String(characters[start..<(start + 3)])]
        }
        if let rarest = sets.min(by: { $0.count < $1.count }) {
            candidates.formUnion(rarest)
        }
        return candidates
    }

    private static func fuzzyTermBoost(_ source: FuzzyTermSource) -> Double {
        switch source {
        case .user: 1.35
        case .humanAdded: 1.15
        case .aiGenerated: 0.95
        }
    }
}

public extension Notification.Name {
    /// 本机词典数据发生变化（delta 应用、手动编辑、项目增删）时广播，
    /// 全局检索面板据此刷新索引快照。
    static let funcDictionaryStoreDidChange = Notification.Name("funcDictionary.storeDidChange")
}
