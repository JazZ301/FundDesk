import Foundation

public struct BoardStorage {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("board.json") }
    private var backup: URL { directory.appendingPathComponent("board.backup.json") }
    private var restoreDirectory: URL { directory.appendingPathComponent("restore-points", isDirectory: true) }
    private var catalogFile: URL { directory.appendingPathComponent("catalog.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public func open() -> (board: Board, recovered: Bool) {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: file), let board = try? decoder.decode(Board.self, from: data) {
            return (board, false)
        }
        if let data = try? Data(contentsOf: backup), let board = try? decoder.decode(Board.self, from: data) {
            return (board, true)
        }
        return (Board(), FileManager.default.fileExists(atPath: file.path))
    }

    public func save(_ board: Board) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(board)
        if let previous = try? Data(contentsOf: file), (try? JSONDecoder().decode(Board.self, from: previous)) != nil {
            // Keep the last readable version available if the primary file becomes damaged.
            try previous.write(to: backup, options: .atomic)
        }
        try data.write(to: file, options: .atomic)
    }

    public func latestRestorePoint() -> URL? {
        let files = try? FileManager.default.contentsOfDirectory(
            at: restoreDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return files?.filter { $0.pathExtension == "json" }.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    public func restore(_ board: Board, replacing current: Board) throws -> URL {
        try FileManager.default.createDirectory(at: restoreDirectory, withIntermediateDirectories: true)
        let timestamp = String(format: "%020.6f", Date.now.timeIntervalSince1970)
        let point = restoreDirectory.appendingPathComponent(timestamp + "-" + UUID().uuidString + ".json")
        try BoardBackup.exportRestorePoint(current).write(to: point, options: .atomic)
        do {
            try save(board)
        } catch {
            try? FileManager.default.removeItem(at: point)
            throw error
        }
        return point
    }

    public func loadCatalog() -> (funds: [Fund], updated: Date?) {
        let data = try? Data(contentsOf: catalogFile)
        let funds = data.flatMap { try? JSONDecoder().decode([Fund].self, from: $0) } ?? []
        let modified = try? catalogFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (funds, modified)
    }

    public func saveCatalog(_ funds: [Fund]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(funds).write(to: catalogFile, options: .atomic)
    }
}

public struct BoardBackup: Sendable {
    private struct Header: Decodable { let version: Int }

    fileprivate struct Legacy: Codable {
        let version: Int
        let holdings: [Holding]
        let journals: [String: [PositionRecord]]?
        let observations: [String: FundObservation]?
    }

    private struct Complete: Codable {
        let version: Int
        let board: Board
    }

    public enum RestoreError: LocalizedError {
        case unsupported
        case invalidHoldings

        public var errorDescription: String? {
            switch self {
            case .unsupported: return "无法读取基金看板备份。请选择本应用导出的 JSON 备份文件。"
            case .invalidHoldings: return "备份含有重复基金或无效的基金代码、份额或成本。"
            }
        }
    }

    public let board: Board
    private let version: Int
    public var includesSettings: Bool { version >= 2 }
    public var includesSnapshots: Bool { version == 2 || version == 4 }

    public static func export(_ board: Board) throws -> Data {
        try encode(board, version: 4)
    }

    public static func exportPortable(_ board: Board) throws -> Data {
        var portable = board
        portable.snapshots = [:]
        portable.observations = board.observations?.mapValues { observation in
            var details = observation
            details.series = nil
            return details
        }
        return try encode(portable, version: 3)
    }

    fileprivate static func exportRestorePoint(_ board: Board) throws -> Data {
        try encode(board, version: 2)
    }

    private static func encode(_ board: Board, version: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Complete(version: version, board: board))
    }

    fileprivate init?(recognizedData data: Data) throws {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { return nil }
        switch header.version {
        case 1:
            guard let legacy = try? decoder.decode(Legacy.self, from: data) else { return nil }
            var board = Board()
            board.holdings = legacy.holdings
            board.journals = legacy.journals
            board.observations = legacy.observations
            self.board = board
        case 2, 3, 4:
            guard let complete = try? decoder.decode(Complete.self, from: data) else {
                throw RestoreError.unsupported
            }
            board = complete.board
        default:
            return nil
        }
        version = header.version
    }

    public init(data: Data) throws {
        guard let backup = try Self(recognizedData: data) else { throw RestoreError.unsupported }
        let holdings = backup.board.holdings
        guard Set(holdings.map(\.id)).count == holdings.count, holdings.allSatisfy(Self.valid) else {
            throw RestoreError.invalidHoldings
        }
        self = backup
    }

    public func restoredBoard(over current: Board) -> Board {
        if includesSettings { return board }
        var restored = current
        restored.holdings = board.holdings
        let codes = Set(board.holdings.map(\.id))
        restored.snapshots = current.snapshots.filter { codes.contains($0.key) }
        restored.journals = board.journals
        restored.observations = board.observations
        return restored
    }

    fileprivate static func valid(_ holding: Holding) -> Bool {
        Fund.validCode(holding.id) && (holding.shares.map { $0 >= 0 } ?? true)
            && (holding.costPerShare.map { $0 > 0 } ?? true)
    }
}

public struct ImportPreview {
    public let holdings: [Holding]
    public let duplicates: Int
    public let invalid: Int
    public let journals: [String: [PositionRecord]]
    public let observations: [String: FundObservation]

    public enum FormatError: LocalizedError {
        case invalid
        public var errorDescription: String? { "无法识别配置文件。请选择 JSON 备份、原插件配置或含基金代码列的 CSV。" }
    }

    public static func export(
        _ holdings: [Holding], journals: [String: [PositionRecord]]? = nil,
        observations: [String: FundObservation]? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(
            BoardBackup.Legacy(version: 1, holdings: holdings, journals: journals, observations: observations)
        )
    }

    public init(data: Data, existing: [Holding], catalog: [Fund]) throws {
        let byCode = Dictionary(grouping: catalog, by: \.code).compactMapValues(\.first)
        let incoming: [Holding]
        var records: [String: [PositionRecord]] = [:]
        var importedObservations: [String: FundObservation] = [:]
        var invalid = 0
        if let backup = try BoardBackup(recognizedData: data) {
            incoming = backup.board.holdings
            records = backup.board.journals ?? [:]
            importedObservations = backup.board.observations ?? [:]
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["fundListGroup"] != nil || json["fundListM"] != nil || json["fundList"] != nil {
            let groups = json["fundListGroup"] as? [[String: Any]] ?? []
            let groupRows = groups.flatMap { $0["funds"] as? [Any] ?? [] }
            let withHoldings = json["fundListM"] as? [Any] ?? []
            let standalone = json["fundList"] as? [Any] ?? []
            incoming = (groupRows + withHoldings + standalone).compactMap { item in
                let row = item as? [String: Any]
                let rawCode = row?["code"] ?? row?["fundcode"] ?? row?["fundCode"] ?? item
                guard let code = Self.code(rawCode) else { invalid += 1; return nil }
                let suppliedName = row?["name"] as? String
                let fund = byCode[code] ?? Fund(code: code, name: suppliedName ?? code)
                return Holding(fund: fund, shares: Self.number(row?["num"] ?? row?["shares"]),
                               costPerShare: Self.number(row?["cost"] ?? row?["costPerShare"]))
            }
        } else {
            let parsed = try HoldingCSV.parse(data, catalog: byCode)
            incoming = parsed.holdings
            invalid += parsed.invalid
        }

        var seen = Set(existing.map(\.id))
        var duplicates = 0
        var result: [Holding] = []
        for holding in incoming {
            guard BoardBackup.valid(holding) else {
                invalid += 1
                continue
            }
            guard seen.insert(holding.id).inserted else {
                duplicates += 1
                continue
            }
            result.append(holding)
        }
        self.holdings = result
        self.duplicates = duplicates
        self.invalid = invalid
        let imported = Set(result.map(\.id))
        self.journals = records.filter { imported.contains($0.key) }
        self.observations = importedObservations.filter { imported.contains($0.key) }
    }

    private static func code(_ value: Any?) -> String? {
        if let string = value as? String, Fund.validCode(string) { return string }
        if let number = value as? NSNumber, number.intValue >= 0, number.intValue < 1_000_000,
           number.doubleValue == Double(number.intValue) {
            return String(format: "%06d", number.intValue)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Decimal? {
        let string = value as? String ?? (value as? NSNumber)?.stringValue
        return decimal(string).flatMap { $0 > 0 ? $0 : nil }
    }
}
