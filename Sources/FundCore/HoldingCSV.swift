import Foundation

public enum HoldingCSV {
    public static func export(_ holdings: [Holding]) -> Data {
        let rows = [["基金代码", "基金名称", "基金类型", "持有份额", "单位成本", "所属分类"]] + holdings.map { row in
            var categories = ["全部自选"]
            if (row.shares ?? 0) > 0 { categories.append("我的持仓") }
            categories.append(contentsOf: row.groupValues.map(\.title))
            return [row.id, spreadsheetText(row.fund.name), spreadsheetText(row.fund.kind),
                    entry(row.shares), entry(row.costPerShare), categories.joined(separator: "|")]
        }
        let text = rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
        return Data(("\u{FEFF}" + text + "\r\n").utf8)
    }

    static func parse(_ data: Data, catalog: [String: Fund]) throws -> (holdings: [Holding], invalid: Int) {
        let encoding: String.Encoding = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding), let fields = rows(text),
              let labels = fields.first else { throw ImportPreview.FormatError.invalid }
        let header = labels.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "").lowercased() }
        func index(_ options: [String]) -> Int? { header.firstIndex { options.contains($0) } }
        guard let codeIndex = index(["基金代码", "代码", "fundcode", "code"]) else {
            throw ImportPreview.FormatError.invalid
        }
        let name = index(["基金名称", "名称", "name"])
        let kind = index(["基金类型", "类型", "kind"])
        let shares = index(["持有份额", "持仓份额", "份额", "shares", "num"])
        let cost = index(["单位成本", "成本价", "持仓成本", "cost", "costpershare"])
        let categories = index(["所属分类"])
        var invalid = 0
        let holdings = fields.dropFirst().compactMap { row -> Holding? in
            func field(_ col: Int?) -> String {
                guard let col, row.indices.contains(col) else { return "" }
                return row[col].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let candidate = field(codeIndex)
            guard (1...6).contains(candidate.count), candidate.utf8.allSatisfy({ (48...57).contains($0) }) else {
                invalid += 1
                return nil
            }
            let code = String(repeating: "0", count: 6 - candidate.count) + candidate
            let quantityText = field(shares)
            let costText = field(cost)
            let num = decimal(quantityText)
            let base = decimal(costText)
            guard quantityText.isEmpty || num.map({ $0 >= 0 }) == true,
                  costText.isEmpty || base.map({ $0 >= 0 }) == true else {
                invalid += 1
                return nil
            }
            let fund = catalog[code] ?? Fund(code: code, name: field(name).isEmpty ? code : field(name), kind: field(kind))
            var holding = Holding(fund: fund, shares: num, costPerShare: base.flatMap { $0 > 0 ? $0 : nil })
            for category in field(categories).split(separator: "|") {
                let title = category.trimmingCharacters(in: .whitespaces)
                if let group = FundGroup.allCases.first(where: { $0.title == title }) { holding.add(group) }
            }
            return holding
        }
        return (holdings, invalid)
    }

    private static func rows(_ text: String) -> [[String]]? {
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var characters = text.drop(while: { $0 == "\u{FEFF}" }).makeIterator()
        var next = characters.next()
        while let current = next {
            next = characters.next()
            if current == "\"" && quoted && next == "\"" {
                field.append("\"")
                next = characters.next()
            } else if current == "\"" && (quoted || field.isEmpty) {
                quoted.toggle()
            } else if !quoted && current == "," {
                row.append(field)
                field = ""
            } else if !quoted && (current == "\r\n" || current == "\n" || current == "\r") {
                row.append(field)
                if row.contains(where: { !$0.isEmpty }) { result.append(row) }
                row = []
                field = ""
            } else {
                field.append(current)
            }
        }
        guard !quoted else { return nil }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { result.append(row) }
        return result
    }

    private static func entry(_ number: Decimal?) -> String {
        number.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }

    private static func escape(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func spreadsheetText(_ field: String) -> String {
        guard let first = field.trimmingCharacters(in: .whitespacesAndNewlines).first,
              ["=", "+", "-", "@"].contains(first) else { return field }
        return "'" + field
    }
}
