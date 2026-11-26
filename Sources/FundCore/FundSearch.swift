import Foundation

public enum FundSearch {
    public static let resultLimit = 35

    public static func catalogResults(
        _ catalog: [Fund], keyword: String, limit: Int = resultLimit
    ) -> [Fund] {
        let normalized = keyword.replacingOccurrences(of: " ", with: "").uppercased()
        guard !normalized.isEmpty, limit > 0 else { return [] }
        if Fund.validCode(normalized) {
            return catalog.first(where: { $0.code == normalized }).map { [$0] } ?? []
        }

        var results: [Fund] = []
        results.reserveCapacity(min(limit, catalog.count))
        for fund in catalog where fund.matchesSearch(normalized) {
            results.append(fund)
            if results.count == limit { break }
        }
        return results
    }

    public static func merge(
        _ watched: [Fund], _ other: [Fund], limit: Int = resultLimit
    ) -> [Fund] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var results: [Fund] = []
        results.reserveCapacity(min(limit, watched.count + other.count))
        for fund in watched + other {
            guard seen.insert(fund.code).inserted else { continue }
            results.append(fund)
            if results.count == limit { break }
        }
        return results
    }
}
