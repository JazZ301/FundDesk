import Foundation

enum StockMarket: String, Codable, Sendable {
    case shanghai = "sh"
    case shenzhen = "sz"
    case beijing = "bj"
    case hongKong = "hk"
    case unitedStates = "us"
    case unsupported

    init(exchange: String?, legacyExchange: String?) {
        switch (exchange, legacyExchange) {
        case ("0", "4"), (nil, "4"): self = .beijing
        case ("1", _), (nil, "1"): self = .shanghai
        case ("0", _), (nil, "0"), (nil, "2"): self = .shenzhen
        case ("116", _), (nil, "5"): self = .hongKong
        case ("105", _), ("106", _), ("107", _), (nil, "7"): self = .unitedStates
        default: self = .unsupported
        }
    }

    func quoteSymbol(code: String) -> String? {
        let ticker = self == .unitedStates ? code.uppercased().replacingOccurrences(of: "-", with: ".") : code
        let symbol = rawValue + ticker
        return Self.validQuoteSymbol(symbol) ? symbol : nil
    }

    static func validQuoteSymbol(_ symbol: String) -> Bool {
        symbol.range(of: #"^(?:(?:sh|sz|bj)[0-9]{6}|hk[0-9]{5}|us[A-Z][A-Z0-9]{0,7}(?:\.[A-Z0-9]{1,4})?)$"#,
                     options: .regularExpression) != nil
    }
}

public struct StockQuote: Sendable {
    public let rate: Decimal
    public let timestamp: Date
}

extension MarketProviders {
    public func stockQuotes(symbols: Set<String>) async throws -> [String: StockQuote] {
        let symbols = symbols.filter(StockMarket.validQuoteSymbol).sorted()
        guard !symbols.isEmpty else { return [:] }
        let batchSize = 60
        var quotes: [String: StockQuote] = [:]
        for start in stride(from: 0, to: symbols.count, by: batchSize) {
            let batch = symbols[start..<min(start + batchSize, symbols.count)]
            let data = try await fetch(host: "qt.gtimg.cn", path: "/q=" + batch.joined(separator: ","))
            for (symbol, quote) in Self.decodeStockQuotes(data, symbols: Set(batch)) {
                quotes[symbol] = quote
            }
        }
        guard !quotes.isEmpty else { throw FeedError.incomplete }
        return quotes
    }

    static func decodeStockQuotes(_ data: Data, symbols: Set<String>) -> [String: StockQuote] {
        var quotes: [String: StockQuote] = [:]
        // The response is GB18030. Only ASCII symbols, numbers and timestamps are read.
        for row in String(decoding: data, as: UTF8.self).split(separator: ";") {
            let pair = row.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("v_") else { continue }
            let symbol = String(key.dropFirst(2))
            let fields = pair[1].split(separator: "~", omittingEmptySubsequences: false)
            guard symbols.contains(symbol), fields.count > 32,
                  let price = decimal(String(fields[3])), price > 0,
                  let rate = decimal(String(fields[32])),
                  let timestamp = stockQuoteTimestamp(String(fields[30]), symbol: symbol) else { continue }
            quotes[symbol] = StockQuote(rate: rate, timestamp: timestamp)
        }
        return quotes
    }

    private static func stockQuoteTimestamp(_ raw: String, symbol: String) -> Date? {
        if raw.count == 14, raw.allSatisfy(\.isNumber) {
            let day = "\(raw.prefix(4))-\(raw.dropFirst(4).prefix(2))-\(raw.dropFirst(6).prefix(2))"
            let time = "\(raw.dropFirst(8).prefix(2)):\(raw.dropFirst(10).prefix(2)):\(raw.suffix(2))"
            return MarketClock.timestamp(day: day, time: time)
        }
        let parts = raw.replacingOccurrences(of: "/", with: "-").split(separator: " ")
        guard parts.count == 2 else { return nil }
        let session: IndexTradingSession = symbol.hasPrefix("us") ? .unitedStates
            : symbol.hasPrefix("hk") ? .hongKong : .mainlandChina
        return session.timestamp(day: String(parts[0]), time: String(parts[1]))
    }
}
