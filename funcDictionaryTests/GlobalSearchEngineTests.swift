import XCTest
#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import funcDictionaryMac
#else
@testable import funcDictionary
#endif

final class GlobalSearchEngineTests: XCTestCase {
    // MARK: 查询理解

    func testIdentifierSplittingHandlesCamelSnakeAndAcronyms() {
        XCTAssertEqual(GlobalSearchVocabulary.splitIdentifier("loadUserData"), ["load", "user", "data"])
        XCTAssertEqual(GlobalSearchVocabulary.splitIdentifier("user_profile_view"), ["user", "profile", "view"])
        XCTAssertEqual(GlobalSearchVocabulary.splitIdentifier("URLSession"), ["url", "session"])
        XCTAssertEqual(GlobalSearchVocabulary.splitIdentifier("fetch"), ["fetch"])
    }

    func testStopwordsAndSearchPhrasingAreStrippedFromQuery() {
        let analyzer = GlobalSemanticQueryAnalyzer(query: "帮我找登录的功能")
        XCTAssertEqual(analyzer.contentTokens.map(\.text), ["登录"])
        XCTAssertTrue(analyzer.contentTokens[0].variants.contains(where: { $0.text == "login" }))
    }

    func testMixedChineseAndAsciiQuerySplitsRuns() {
        let analyzer = GlobalSemanticQueryAnalyzer(query: "找loadUserData相关词条")
        let tokens = analyzer.contentTokens.map(\.text)
        XCTAssertTrue(tokens.contains("load"))
        XCTAssertTrue(tokens.contains("user"))
        XCTAssertTrue(tokens.contains("data"))
    }

    // MARK: 跨语言语义召回

    func testChineseQueryFindsEnglishSymbolViaSynonym() {
        let login = makeDefinition(
            id: "def_login",
            projectID: "project_shop",
            canonicalName: "LoginViewController",
            displayName: "登录页",
            symbol: "LoginViewController",
            purpose: "校验用户凭据并建立会话"
        )
        let cache = makeDefinition(
            id: "def_cache",
            projectID: "project_shop",
            canonicalName: "CacheManager",
            displayName: "缓存管理",
            symbol: "CacheManager",
            purpose: "清理过期缓存条目"
        )
        let response = GlobalSearchEngine.search(
            query: "帮我找登录的功能",
            scopes: [makeScope(id: "project_shop", name: "Shop", definitions: [login, cache])]
        )

        XCTAssertEqual(response.groups.count, 1)
        XCTAssertEqual(response.groups.first?.results.first?.definitionID, "def_login")
        XCTAssertEqual(response.groups.first?.projectName, "Shop")
    }

    func testEnglishQueryFindsChinesePurposeViaSynonym() {
        let pay = makeDefinition(
            id: "def_pay",
            projectID: "project_shop",
            canonicalName: "OrderPaymentFlow",
            displayName: "订单支付",
            symbol: "OrderPaymentFlow",
            purpose: "订单支付与退款处理"
        )
        let response = GlobalSearchEngine.search(
            query: "payment",
            scopes: [makeScope(id: "project_shop", name: "Shop", definitions: [pay])]
        )

        XCTAssertEqual(response.groups.first?.results.first?.definitionID, "def_pay")
    }

    func testCamelCaseQueryMatchesServiceThroughIdentifierParts() {
        let loader = makeDefinition(
            id: "def_loader",
            projectID: "project_shop",
            canonicalName: "LoadUserDataService",
            displayName: "用户资料加载",
            symbol: "LoadUserDataService",
            purpose: "加载并合并用户资料数据"
        )
        let payment = makeDefinition(
            id: "def_payment",
            projectID: "project_shop",
            canonicalName: "PaymentService",
            displayName: "支付服务",
            symbol: "PaymentService",
            purpose: "处理支付渠道请求"
        )
        let response = GlobalSearchEngine.search(
            query: "loadUserData",
            scopes: [makeScope(id: "project_shop", name: "Shop", definitions: [loader, payment])]
        )

        XCTAssertEqual(response.groups.first?.results.first?.definitionID, "def_loader")
        XCTAssertFalse(response.groups.first?.results.contains { $0.definitionID == "def_payment" } ?? true)
    }

    // MARK: 多词覆盖与排序

    func testMultiTokenQueryRanksFullCoverageAbovePartial() {
        let login = makeDefinition(
            id: "def_login",
            projectID: "project_shop",
            canonicalName: "LoginViewController",
            displayName: "登录页",
            symbol: "LoginViewController",
            purpose: "校验用户凭据并完成登录",
            fuzzyTerms: [FuzzyTerm(text: "登录", source: .user)]
        )
        let profile = makeDefinition(
            id: "def_profile",
            projectID: "project_shop",
            canonicalName: "UserProfileView",
            displayName: "用户资料",
            symbol: "UserProfileView",
            purpose: "展示用户资料与登录历史"
        )
        let response = GlobalSearchEngine.search(
            query: "用户 登录",
            scopes: [makeScope(id: "project_shop", name: "Shop", definitions: [login, profile])]
        )
        let results = response.groups.first?.results ?? []
        XCTAssertEqual(results.first?.definitionID, "def_login")
        XCTAssertEqual(results.count, 2)
        XCTAssertGreaterThan(results[0].score, results[1].score)
    }

    // MARK: 跨项目分组：匹配 App 优先，其余折叠

    func testBestMatchingProjectBecomesPrimaryAndOthersCollapse() {
        let imLogin = makeDefinition(
            id: "def_im_login",
            projectID: "project_im",
            canonicalName: "LoginViewController",
            displayName: "登录页",
            symbol: "LoginViewController",
            purpose: "登录鉴权并维护会话",
            fuzzyTerms: [FuzzyTerm(text: "登录", source: .user)]
        )
        let imChat = makeDefinition(
            id: "def_im_chat",
            projectID: "project_im",
            canonicalName: "ChatSessionStore",
            displayName: "会话存储",
            symbol: "ChatSessionStore",
            purpose: "登录后的会话消息存取"
        )
        let shopLogin = makeDefinition(
            id: "def_shop_login",
            projectID: "project_shop",
            canonicalName: "LoginManager",
            displayName: "登录管理",
            symbol: "LoginManager",
            purpose: "管理账号登录态"
        )
        let response = GlobalSearchEngine.search(
            query: "登录",
            scopes: [
                makeScope(id: "project_im", name: "即时通讯", definitions: [imLogin, imChat]),
                makeScope(id: "project_shop", name: "电商", definitions: [shopLogin])
            ]
        )

        XCTAssertEqual(response.groups.count, 2)
        XCTAssertEqual(response.groups[0].projectID, "project_im")
        XCTAssertTrue(response.groups[0].isPrimary)
        XCTAssertEqual(response.groups[0].results.first?.definitionID, "def_im_login")
        XCTAssertFalse(response.groups[1].isPrimary)
        XCTAssertLessThanOrEqual(response.groups[1].results.count, GlobalSearchEngine.collapsedResultLimit)
    }

    func testProjectsWithoutMatchesAreOmitted() {
        let login = makeDefinition(
            id: "def_login",
            projectID: "project_im",
            canonicalName: "LoginViewController",
            displayName: "登录页",
            symbol: "LoginViewController",
            purpose: "登录鉴权"
        )
        let cache = makeDefinition(
            id: "def_cache",
            projectID: "project_shop",
            canonicalName: "CacheManager",
            displayName: "缓存管理",
            symbol: "CacheManager",
            purpose: "清理缓存"
        )
        let response = GlobalSearchEngine.search(
            query: "登录",
            scopes: [
                makeScope(id: "project_im", name: "即时通讯", definitions: [login]),
                makeScope(id: "project_shop", name: "电商", definitions: [cache])
            ]
        )

        XCTAssertEqual(response.groups.count, 1)
        XCTAssertEqual(response.groups.first?.projectID, "project_im")
    }

    func testGibberishQueryReturnsEmptyResponse() {
        let login = makeDefinition(
            id: "def_login",
            projectID: "project_im",
            canonicalName: "LoginViewController",
            displayName: "登录页",
            symbol: "LoginViewController",
            purpose: "登录鉴权"
        )
        let response = GlobalSearchEngine.search(
            query: "zzqqxx",
            scopes: [makeScope(id: "project_im", name: "即时通讯", definitions: [login])]
        )

        XCTAssertTrue(response.groups.isEmpty)
        XCTAssertTrue(response.isEmpty)
    }

    func testEmptyAndWhitespaceQueriesReturnEmptyResponse() {
        let login = makeDefinition(
            id: "def_login",
            projectID: "project_im",
            canonicalName: "LoginViewController",
            displayName: "登录页",
            symbol: "LoginViewController",
            purpose: "登录鉴权"
        )
        XCTAssertTrue(GlobalSearchEngine.search(query: "", scopes: [makeScope(id: "project_im", name: "IM", definitions: [login])]).groups.isEmpty)
        XCTAssertTrue(GlobalSearchEngine.search(query: "   ", scopes: [makeScope(id: "project_im", name: "IM", definitions: [login])]).groups.isEmpty)
    }

    // MARK: 数据治理

    func testArchivedDefinitionsAreExcluded() {
        let active = makeDefinition(
            id: "def_active",
            projectID: "project_im",
            canonicalName: "LoginViewController",
            displayName: "登录页",
            symbol: "LoginViewController",
            purpose: "登录鉴权"
        )
        var archived = makeDefinition(
            id: "def_archived",
            projectID: "project_im",
            canonicalName: "LegacyLoginFlow",
            displayName: "旧登录",
            symbol: "LegacyLoginFlow",
            purpose: "已废弃的登录实现"
        )
        archived.reviewStatus = .archived
        let response = GlobalSearchEngine.search(
            query: "登录",
            scopes: [makeScope(id: "project_im", name: "即时通讯", definitions: [active, archived])]
        )

        let ids = response.groups.flatMap { $0.results.map(\.definitionID) }
        XCTAssertEqual(ids, ["def_active"])
    }

    func testPrimaryGroupIsCappedAndReportsTotalMatches() {
        var definitions: [Definition] = []
        for index in 0..<12 {
            definitions.append(
                makeDefinition(
                    id: "def_tool_\(index)",
                    projectID: "project_tool",
                    canonicalName: "ToolEntry\(index)",
                    displayName: "工具 \(index)",
                    symbol: "ToolEntry\(index)",
                    purpose: "工具入口 \(index)",
                    fuzzyTerms: [FuzzyTerm(text: "工具", source: .user)]
                )
            )
        }
        let response = GlobalSearchEngine.search(
            query: "工具",
            scopes: [makeScope(id: "project_tool", name: "Toolbox", definitions: definitions)]
        )

        XCTAssertEqual(response.groups.count, 1)
        XCTAssertEqual(response.groups.first?.totalMatches, 12)
        XCTAssertEqual(response.groups.first?.results.count, GlobalSearchEngine.primaryResultLimit)
    }

    // MARK: 构造辅助

    private func makeScope(id: String, name: String, definitions: [Definition]) -> GlobalSearchScope {
        GlobalSearchScope(
            project: Project(id: id, name: name),
            definitions: definitions
        )
    }

    private func makeDefinition(
        id: String,
        projectID: String,
        canonicalName: String,
        displayName: String,
        symbol: String,
        purpose: String,
        fuzzyTerms: [FuzzyTerm] = []
    ) -> Definition {
        Definition(
            id: id,
            projectID: projectID,
            identity: DefinitionIdentity(
                canonicalName: canonicalName,
                displayName: displayName,
                kind: .function
            ),
            function: FunctionDescriptor(domain: "Test", purpose: purpose),
            codeLocator: CodeLocator(symbol: symbol, function: "\(canonicalName).run()", file: "\(canonicalName).swift"),
            visualLocator: VisualLocator(),
            functionalLocator: FunctionalLocator(),
            fuzzyTerms: fuzzyTerms
        )
    }
}
