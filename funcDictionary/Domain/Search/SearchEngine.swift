import Foundation
import NaturalLanguage

public enum SearchField: String, Codable, CaseIterable, Sendable {
    case fuzzy
    case function
    case code
    case visual
    case relation
    case history
    case context
}

public enum SearchMatchKind: String, Codable, CaseIterable, Sendable {
    case exact
    case prefix
    case contains
    case token
    case fuzzy
}

public struct SearchMatchReason: Codable, Equatable, Hashable, Sendable {
    public var field: SearchField
    public var kind: SearchMatchKind
    public var evidence: String
    public var contribution: Double

    public init(field: SearchField, kind: SearchMatchKind, evidence: String, contribution: Double) {
        self.field = field
        self.kind = kind
        self.evidence = evidence
        self.contribution = contribution
    }
}

public struct DefinitionSearchResult: Codable, Equatable, Hashable, Sendable {
    public var definitionID: String
    public var projectID: String
    public var canonicalName: String
    public var displayName: String
    public var currentSymbol: String
    public var currentFunction: String
    public var score: Double
    public var reasons: [SearchMatchReason]

    public init(
        definitionID: String,
        projectID: String,
        canonicalName: String,
        displayName: String,
        currentSymbol: String,
        currentFunction: String,
        score: Double,
        reasons: [SearchMatchReason]
    ) {
        self.definitionID = definitionID
        self.projectID = projectID
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.currentSymbol = currentSymbol
        self.currentFunction = currentFunction
        self.score = score
        self.reasons = reasons
    }
}

public struct ClusterSearchResult: Codable, Equatable, Hashable, Sendable {
    public var clusterID: String
    public var projectID: String
    public var name: String
    public var primaryDefinitionID: String
    public var score: Double
    public var reasons: [SearchMatchReason]

    public init(
        clusterID: String,
        projectID: String,
        name: String,
        primaryDefinitionID: String,
        score: Double,
        reasons: [SearchMatchReason]
    ) {
        self.clusterID = clusterID
        self.projectID = projectID
        self.name = name
        self.primaryDefinitionID = primaryDefinitionID
        self.score = score
        self.reasons = reasons
    }
}

public struct SearchResponse: Codable, Equatable, Sendable {
    public var query: String
    public var direct: DefinitionSearchResult?
    public var candidates: [DefinitionSearchResult]
    public var related: [DefinitionSearchResult]
    public var clusters: [ClusterSearchResult]

    public init(
        query: String,
        direct: DefinitionSearchResult?,
        candidates: [DefinitionSearchResult],
        related: [DefinitionSearchResult],
        clusters: [ClusterSearchResult] = []
    ) {
        self.query = query
        self.direct = direct
        self.candidates = candidates
        self.related = related
        self.clusters = clusters
    }
}

public final class SearchEngine {
    public var configuration: ScoringConfiguration
    private var cachedSignature: Int?
    private var cachedDefinitions: [IndexedDefinition] = []
    private var cachedExactMatches: [String: Set<String>] = [:]
    private var cachedPrefixMatches: [String: Set<String>] = [:]
    private var cachedTokenMatches: [String: Set<String>] = [:]
    private var cachedTrigramMatches: [String: Set<String>] = [:]
    private let maxIndexedPrefixLength = 24

    public init(configuration: ScoringConfiguration = ScoringConfiguration()) {
        self.configuration = configuration
    }

    public func search(
        query: String,
        definitions: [Definition],
        clusters: [Cluster] = []
    ) -> SearchResponse {
        guard let projectID = definitions.first?.projectID,
              definitions.allSatisfy({ $0.projectID == projectID }),
              clusters.allSatisfy({ $0.projectID == projectID }) else {
            // A mixed-project input is rejected rather than silently allowing
            // vocabulary or relation context to leak across projects. Callers
            // that own a project should use the explicit projectID overload.
            return SearchResponse(query: query, direct: nil, candidates: [], related: [], clusters: [])
        }
        return search(query: query, projectID: projectID, definitions: definitions, clusters: clusters)
    }

    public func search(
        query: String,
        projectID: String,
        definitions: [Definition],
        clusters: [Cluster] = []
    ) -> SearchResponse {
        let scopedDefinitions = definitions.filter { $0.projectID == projectID }
        let scopedClusters = clusters.filter { $0.projectID == projectID }
        guard scopedDefinitions.count == definitions.count,
              scopedClusters.count == clusters.count else {
            return SearchResponse(query: query, direct: nil, candidates: [], related: [], clusters: [])
        }
        return searchScoped(query: query, definitions: scopedDefinitions, clusters: scopedClusters)
    }

    private func searchScoped(
        query: String,
        definitions: [Definition],
        clusters: [Cluster]
    ) -> SearchResponse {
        let normalizedQuery = SearchNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return SearchResponse(query: query, direct: nil, candidates: [], related: [], clusters: [])
        }

        let indexedDefinitions = indexedDefinitions(for: definitions)
        let queryTokens = SearchNormalizer.tokens(normalizedQuery)
        let fastCandidateIDs = fastCandidateIDs(for: normalizedQuery, tokens: queryTokens)
        // Score the indexed candidate union rather than a single exact/prefix
        // bucket. The union includes exact values, prefixes, token matches,
        // and every query trigram, so a fast exact hit cannot hide a second
        // token/fuzzy candidate. If no index evidence exists, score all
        // definitions to preserve typo/fuzzy recall.
        let allScored = indexedDefinitions.map {
            guard fastCandidateIDs.isEmpty || fastCandidateIDs.contains($0.definition.id) else {
                return ScoredDefinition(definition: $0.definition, baseScore: 0, score: 0, reasons: [])
            }
            return score(indexedDefinition: $0, query: normalizedQuery, queryTokens: queryTokens, allowFuzzy: true)
        }
        let scored = allScored
            .filter {
                $0.baseScore >= configuration.candidateSearchThreshold
                    || $0.reasons.contains(where: { $0.field == .history })
                    // An exact user/agent vocabulary hit is an explicit
                    // candidate even when that single weighted bucket cannot
                    // reach the global score floor by itself.
                    || ($0.baseScore > 0 && $0.reasons.contains(where: { $0.field == .fuzzy && $0.kind == .exact }))
                    // A function name or purpose may occur in just one bucket
                    // (0.18 / 0.22), below the 0.35 multi-field threshold.
                    // Literal matches must still be discoverable in either direction.
                    || $0.reasons.contains(where: {
                        ($0.field == .code || $0.field == .function)
                            && ($0.kind == .exact || (normalizedQuery.count >= 2
                                && [.prefix, .contains, .token].contains($0.kind)))
                    })
            }
            .sorted {
                if $0.score == $1.score { return $0.definition.identity.canonicalName < $1.definition.identity.canonicalName }
                return $0.score > $1.score
            }

        let results = scored.map(makeResult)
        let direct: DefinitionSearchResult?
        if let first = scored.first {
            let secondScore = scored.dropFirst().first?.score ?? 0
            direct = first.baseScore >= configuration.directSearchThreshold
                && first.score - secondScore >= configuration.directSearchMargin
                ? makeResult(first)
                : nil
        } else {
            direct = nil
        }

        let directID = direct?.definitionID
        let candidates = results.filter { $0.definitionID != directID }
        let relatedIDs = relatedDefinitionIDs(for: direct?.definitionID, definitions: definitions)
        var related = relatedIDs.compactMap { relatedID in
            allScored.first(where: { $0.definition.id == relatedID && $0.definition.id != directID }).map(makeResult)
        }
        related = Array(related.prefix(5))

        let clusterResults = clusters
            .compactMap { clusterResult(for: $0, definitions: definitions, query: normalizedQuery) }
            .sorted {
                if $0.score == $1.score { return $0.name < $1.name }
                return $0.score > $1.score
            }
        return SearchResponse(
            query: query,
            direct: direct,
            candidates: candidates,
            related: related,
            clusters: clusterResults
        )
    }

    private struct ScoredDefinition {
        let definition: Definition
        let baseScore: Double
        let score: Double
        let reasons: [SearchMatchReason]
    }

    private struct IndexedValue {
        let raw: String
        let normalized: String
        let tokens: [String]
        let boost: Double
    }

    private struct IndexedGroup {
        let field: SearchField
        let weight: Double
        let values: [IndexedValue]
    }

    private struct IndexedDefinition {
        let definition: Definition
        let groups: [IndexedGroup]
    }

    private func indexedDefinitions(for definitions: [Definition]) -> [IndexedDefinition] {
        var hasher = Hasher()
        for definition in definitions {
            hasher.combine(definition)
        }
        let signature = hasher.finalize()
        if cachedSignature == signature {
            return cachedDefinitions
        }
        let result = definitions
            .filter { $0.reviewStatus != .archived }
            .map { definition in
                IndexedDefinition(
                    definition: definition,
                    groups: indexedGroups(for: definition)
                )
            }
        cachedSignature = signature
        cachedDefinitions = result
        var exactMatches: [String: Set<String>] = [:]
        var prefixMatches: [String: Set<String>] = [:]
        var tokenMatches: [String: Set<String>] = [:]
        var trigramMatches: [String: Set<String>] = [:]
        for indexedDefinition in result {
            for group in indexedDefinition.groups {
                for value in group.values where !value.normalized.isEmpty {
                    exactMatches[value.normalized, default: []].insert(indexedDefinition.definition.id)
                    for token in value.tokens {
                        tokenMatches[token, default: []].insert(indexedDefinition.definition.id)
                    }
                    let characters = Array(value.normalized)
                    for length in 1...min(maxIndexedPrefixLength, characters.count) {
                        let prefix = String(characters.prefix(length))
                        prefixMatches["\(length):\(prefix)", default: []].insert(indexedDefinition.definition.id)
                    }
                    guard characters.count >= 3 else { continue }
                    for start in 0...(characters.count - 3) {
                        let trigram = String(characters[start...(start + 2)])
                        trigramMatches[trigram, default: []].insert(indexedDefinition.definition.id)
                    }
                }
            }
        }
        cachedExactMatches = exactMatches
        cachedPrefixMatches = prefixMatches
        cachedTokenMatches = tokenMatches
        cachedTrigramMatches = trigramMatches
        return result
    }

    private func fastCandidateIDs(for query: String, tokens: [String]) -> Set<String> {
        var candidates = cachedExactMatches[query] ?? []
        let characters = Array(query)
        if !characters.isEmpty {
            let prefixLength = min(maxIndexedPrefixLength, characters.count)
            let prefixKey = "\(prefixLength):\(String(characters.prefix(prefixLength)))"
            let hasExactOrPrefix = !candidates.isEmpty || cachedPrefixMatches[prefixKey] != nil
            candidates.formUnion(cachedPrefixMatches[prefixKey] ?? [])
            for token in tokens {
                candidates.formUnion(cachedTokenMatches[token] ?? [])
            }
            // A common trigram such as "def" maps to nearly every indexed
            // definition and destroys the fast path. Use a single rarest
            // trigram only when no exact/prefix/token evidence exists; this
            // retains a bounded typo-recall path without broad fan-out.
            guard !hasExactOrPrefix, candidates.isEmpty, characters.count >= 3 else {
                return candidates
            }
            let trigramSets = (0...(characters.count - 3)).compactMap { start in
                cachedTrigramMatches[String(characters[start...(start + 2)])]
            }
            if let rarest = trigramSets.min(by: { $0.count < $1.count }) {
                candidates.formUnion(rarest)
            }
        }
        return candidates
    }

    private func indexedGroups(for definition: Definition) -> [IndexedGroup] {
        [
            indexedGroup(
                field: .fuzzy,
                weight: 0.28,
                values: definition.fuzzyTerms.map {
                    ($0.text, fuzzyTermBoost(for: $0.source, weight: $0.weight))
                }
            ),
            indexedGroup(
                field: .function,
                weight: 0.22,
                values: [
                    (definition.function.domain, 1),
                    (definition.function.purpose, 1),
                    (definition.codeLocator.comment, 1),
                    (definition.function.actions.joined(separator: " "), 1),
                    (definition.functionalLocator.domain, 1),
                    (definition.functionalLocator.role, 1),
                    (definition.functionalLocator.trigger, 1)
                ]
            ),
            indexedGroup(
                field: .code,
                weight: 0.18,
                values: [
                    (definition.identity.canonicalName, 1),
                    (definition.identity.displayName, 1),
                    (definition.codeLocator.symbol, 1),
                    (definition.codeLocator.function, 1),
                    (definition.codeLocator.signature, 1),
                    (definition.codeLocator.owner, 1),
                    (definition.codeLocator.file, 1),
                    (definition.codeLocator.module, 1)
                ]
            ),
            indexedGroup(
                field: .visual,
                weight: 0.16,
                values: [
                    (definition.visualLocator.screen, 1),
                    (definition.visualLocator.container, 1),
                    (definition.visualLocator.region, 1),
                    (definition.visualLocator.hierarchy.joined(separator: " "), 1)
                ]
            ),
            // The PRD allocates one combined relation/context bucket (0.11).
            // Keep the bucket together so the score remains comparable when a
            // definition is related to the active working context.
            indexedGroup(
                field: .relation,
                weight: 0.11,
                values: definition.relations.flatMap { relation in
                    [(relation.type.rawValue, 1), (relation.targetDefinitionID, 1)]
                        + relation.metadata.map { ($0.key + " " + $0.value, 1) }
                } + (definition.activeContext ? [("active context", 1)] : [])
            ),
            indexedGroup(
                field: .history,
                weight: 0.05,
                values: definition.implementationHistory.flatMap { event in
                    [(event.changeType, 1)] + event.changes.map { ($0.key + " " + $0.value, 1) }
                } + definition.lineage.map { ($0, 1) }
            )
        ]
    }

    private func indexedGroup(
        field: SearchField,
        weight: Double,
        values: [(String, Double)]
    ) -> IndexedGroup {
        IndexedGroup(
            field: field,
            weight: weight,
            values: values.map {
                IndexedValue(
                    raw: $0.0,
                    normalized: SearchNormalizer.normalize($0.0),
                    tokens: SearchNormalizer.tokens($0.0),
                    boost: $0.1
                )
            }
        )
    }

    private func score(
        indexedDefinition: IndexedDefinition,
        query: String,
        queryTokens: [String],
        allowFuzzy: Bool
    ) -> ScoredDefinition {
        let definition = indexedDefinition.definition

        var total = 0.0
        var reasons: [SearchMatchReason] = []
        for group in indexedDefinition.groups where group.weight > 0 {
            guard let best = bestMatch(
                query: query,
                queryTokens: queryTokens,
                values: group.values,
                allowFuzzy: allowFuzzy
            ) else { continue }
            let contribution = min(group.weight, group.weight * best.score * best.boost)
            total += contribution
            reasons.append(
                SearchMatchReason(
                    field: group.field,
                    kind: best.kind,
                    evidence: best.evidence,
                    contribution: contribution
                )
            )
        }
        let baseScore = min(total, 1)
        // Human priority is a tie-breaker for relevant results, not a way to
        // make an unrelated Definition match every query.
        if !reasons.isEmpty {
            if let priority = definition.humanPriority {
                total *= priority.level == .critical ? 1.10 : 1.05
            }
            if definition.activeContext {
                total *= 1.05
            }
        }
        return ScoredDefinition(
            definition: definition,
            baseScore: baseScore,
            score: min(total, 1),
            reasons: reasons.sorted { $0.contribution > $1.contribution }
        )
    }

    private struct FieldMatch {
        let score: Double
        let boost: Double
        let kind: SearchMatchKind
        let evidence: String
    }

    private func bestMatch(
        query: String,
        queryTokens: [String],
        values: [IndexedValue],
        allowFuzzy: Bool = true
    ) -> FieldMatch? {
        return values
            .compactMap { value -> FieldMatch? in
                let normalized = value.normalized
                guard !normalized.isEmpty else { return nil }
                if normalized == query {
                    return FieldMatch(score: 1, boost: value.boost, kind: .exact, evidence: value.raw)
                }
                if normalized.hasPrefix(query) {
                    return FieldMatch(score: 0.88, boost: value.boost, kind: .prefix, evidence: value.raw)
                }
                if normalized.contains(query) {
                    return FieldMatch(score: 0.72, boost: value.boost, kind: .contains, evidence: value.raw)
                }
                let valueTokens = value.tokens
                guard !valueTokens.isEmpty, !queryTokens.isEmpty else { return nil }
                let matched = queryTokens.filter { token in valueTokens.contains { $0 == token || $0.hasPrefix(token) || token.hasPrefix($0) } }
                if matched.count == queryTokens.count {
                    return FieldMatch(score: 0.65, boost: value.boost, kind: .token, evidence: value.raw)
                }
                guard allowFuzzy else { return nil }
                let similarity = queryTokens.map { token in
                    valueTokens.map { SearchNormalizer.similarity(token, $0) }.max() ?? 0
                }.max() ?? 0
                guard similarity >= 0.62 else { return nil }
                return FieldMatch(score: similarity * 0.60, boost: value.boost, kind: .fuzzy, evidence: value.raw)
            }
            .max { lhs, rhs in lhs.score * lhs.boost < rhs.score * rhs.boost }
    }

    private func makeResult(_ scored: ScoredDefinition) -> DefinitionSearchResult {
        let locator = scored.definition.codeLocator
        return DefinitionSearchResult(
            definitionID: scored.definition.id,
            projectID: scored.definition.projectID,
            canonicalName: scored.definition.identity.canonicalName,
            displayName: scored.definition.identity.displayName,
            currentSymbol: locator.symbol,
            currentFunction: locator.function,
            score: scored.score,
            reasons: scored.reasons
        )
    }

    private func clusterResult(
        for cluster: Cluster,
        definitions: [Definition],
        query: String
    ) -> ClusterSearchResult? {
        let memberValues = cluster.definitionIDs.flatMap { definitionID in
            definitions.first(where: { $0.id == definitionID }).flatMap { definition in
                [definition.identity.canonicalName, definition.identity.displayName]
                    + definition.fuzzyTerms.map(\.text)
            } ?? []
        }
        let values = ([cluster.name] + memberValues).map {
            IndexedValue(
                raw: $0,
                normalized: SearchNormalizer.normalize($0),
                tokens: SearchNormalizer.tokens($0),
                boost: 1
            )
        }
        guard let match = bestMatch(
            query: query,
            queryTokens: SearchNormalizer.tokens(query),
            values: values
        ) else {
            return nil
        }
        return ClusterSearchResult(
            clusterID: cluster.id,
            projectID: cluster.projectID,
            name: cluster.name,
            primaryDefinitionID: cluster.primaryDefinitionID,
            score: match.score,
            reasons: [SearchMatchReason(
                field: .relation,
                kind: match.kind,
                evidence: "Cluster: \(match.evidence)",
                contribution: match.score
            )]
        )
    }

    private func relatedDefinitionIDs(for definitionID: String?, definitions: [Definition]) -> Set<String> {
        guard let definitionID else { return [] }
        var related: Set<String> = []
        for definition in definitions where definition.id == definitionID {
            for relation in definition.relations {
                related.insert(relation.targetDefinitionID)
                related.insert(relation.sourceDefinitionID)
            }
        }
        for definition in definitions where definition.relations.contains(where: {
            $0.sourceDefinitionID == definitionID || $0.targetDefinitionID == definitionID
        }) {
            related.insert(definition.id)
        }
        return related
    }

    private func fuzzyTermBoost(for source: FuzzyTermSource, weight: Double) -> Double {
        switch source {
        case .user: max(0, weight) * 1.35
        case .humanAdded: max(0, weight) * 1.15
        case .aiGenerated: max(0, weight) * 0.95
        }
    }
}

public enum SearchNormalizer {
    public static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let characters = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(characters).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func tokens(_ value: String) -> [String] {
        let normalized = normalize(value)
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

        // NaturalLanguage provides word segmentation for Chinese and other
        // CJK text. Character grams keep partial visual/function memories
        // searchable when the tokenizer selects a longer compound word.
        var expanded = words
        for word in words where containsCJK(word) {
            let characters = Array(word)
            expanded.append(contentsOf: characters.map(String.init))
            guard characters.count >= 2 else { continue }
            for length in 2...min(3, characters.count) {
                for start in 0...(characters.count - length) {
                    expanded.append(String(characters[start..<(start + length)]))
                }
            }
        }

        var seen: Set<String> = []
        return expanded.filter { seen.insert($0).inserted }
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
        }
    }

    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let distance = levenshtein(lhs, rhs)
        return 1 - Double(distance) / Double(max(lhs.count, rhs.count))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[right.count]
    }
}
