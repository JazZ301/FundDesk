import Foundation

public struct ImportedObservation: Sendable {
    public let fund: Fund
    public let groups: [FundGroup]
    public let history: [NAV]
    public let observation: FundObservation

    public init(fund: Fund, groups: [FundGroup], history: [NAV], observation: FundObservation) {
        self.fund = fund
        self.groups = groups
        self.history = history
        self.observation = observation
    }
}

public struct ObservationImportResult: Sendable {
    public let observations: [ImportedObservation]
    public let sourceFolders: [String]
    public let warnings: [String]

    public init(observations: [ImportedObservation], sourceFolders: [String], warnings: [String]) {
        self.observations = observations
        self.sourceFolders = sourceFolders
        self.warnings = warnings
    }
}

public enum ObservationImport {
    public enum ImportError: LocalizedError {
        case noFolders
        case noData

        public var errorDescription: String? {
            switch self {
            case .noFolders: return "所选位置中没有 macd 或 red 文件夹。请选择包含它们的桌面文件夹。"
            case .noData: return "文件夹中没有找到可导入的数据。"
            }
        }
    }

    public static func load(from selectedFolder: URL) throws -> ObservationImportResult {
        let macdFolder = namedFolder("macd", under: selectedFolder)
        let redFolder = namedFolder("red", under: selectedFolder)
        guard macdFolder != nil || redFolder != nil else { throw ImportError.noFolders }

        var sourceFolders: [String] = []
        var warnings: [String] = []
        var merged: [String: ImportedObservation] = [:]
        var order: [String] = []
        if let macdFolder {
            if let rows = try? macdRows(in: macdFolder), !rows.isEmpty {
                sourceFolders.append("macd")
                merge(rows, into: &merged, order: &order)
            } else {
                warnings.append("macd 文件夹中没有可读取的分析数据。")
            }
        }
        if let redFolder {
            if let rows = try? redRows(in: redFolder), !rows.isEmpty {
                sourceFolders.append("red")
                merge(rows, into: &merged, order: &order)
            } else {
                warnings.append("red 文件夹中没有可读取的红利数据。")
            }
        }
        guard !merged.isEmpty else { throw ImportError.noData }
        return ObservationImportResult(
            observations: order.compactMap { merged[$0] },
            sourceFolders: sourceFolders,
            warnings: warnings
        )
    }

    private static func namedFolder(_ name: String, under selected: URL) -> URL? {
        if selected.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame,
           FileManager.default.fileExists(atPath: selected.path) {
            return selected
        }
        let direct = selected.appendingPathComponent(name, isDirectory: true)
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }

    private static func merge(
        _ incoming: [ImportedObservation], into result: inout [String: ImportedObservation],
        order: inout [String]
    ) {
        for item in incoming {
            guard let prior = result[item.fund.code] else {
                result[item.fund.code] = item
                order.append(item.fund.code)
                continue
            }
            let groups = Array(Set(prior.groups + item.groups)).sorted { $0.rawValue < $1.rawValue }
            let history = Dictionary(grouping: prior.history + item.history, by: \.day)
                .compactMapValues { $0.last }
                .values
                .sorted { $0.day < $1.day }
            let metrics = (prior.observation.metrics + item.observation.metrics)
                .reduce(into: [ObservationMetric]()) { rows, metric in
                    if let index = rows.firstIndex(where: { $0.key == metric.key }) {
                        rows[index] = metric
                    } else {
                        rows.append(metric)
                    }
                }
            let latest = max(prior.observation.updatedDay, item.observation.updatedDay)
            result[item.fund.code] = ImportedObservation(
                fund: item.fund.name.isEmpty ? prior.fund : item.fund,
                groups: groups,
                history: history,
                observation: FundObservation(
                    updatedDay: latest,
                    source: prior.observation.source + " + " + item.observation.source,
                    metrics: metrics,
                    series: item.observation.series ?? prior.observation.series,
                    macd: item.observation.macd ?? prior.observation.macd,
                    valuation: item.observation.valuation ?? prior.observation.valuation
                )
            )
        }
    }

    private static func macdRows(in folder: URL) throws -> [ImportedObservation] {
        if let htmlRows = try? macdHTMLRows(in: folder), !htmlRows.isEmpty {
            return htmlRows
        }
        let dataFolder = folder.appendingPathComponent("data", isDirectory: true)
        let analysisURL = dataFolder.appendingPathComponent("analysis.json")
        let payloadURL = dataFolder.appendingPathComponent("payload.json")
        let rowsURL = FileManager.default.fileExists(atPath: analysisURL.path) ? analysisURL : payloadURL
        guard let rows = try jsonArray(at: rowsURL) else { return [] }
        return macdObservations(rows, dataFolder: dataFolder)
    }

    private static func macdHTMLRows(in folder: URL) throws -> [ImportedObservation] {
        let htmlURL = folder.appendingPathComponent("基金_MACD战法适配度.html")
        guard let data = try? Data(contentsOf: htmlURL),
              let script = String(data: data, encoding: .utf8),
              let start = script.range(of: "let DATA = "),
              let end = script.range(of: ";\nlet NAV_END", range: start.upperBound..<script.endIndex) else {
            throw ImportError.noData
        }
        let payload = Data(script[start.upperBound..<end.lowerBound].utf8)
        guard let rows = try JSONSerialization.jsonObject(with: payload) as? [Any] else {
            throw ImportError.noData
        }
        return macdObservations(rows, dataFolder: folder.appendingPathComponent("data", isDirectory: true))
    }

    private static func macdObservations(_ rows: [Any], dataFolder: URL) -> [ImportedObservation] {
        return rows.compactMap { raw -> ImportedObservation? in
            guard let row = raw as? [String: Any],
                  let code = string(row["code"]), Fund.validCode(code),
                  let name = string(row["name"]) else { return nil }
            let fund = Fund(
                code: code,
                name: name,
                kind: string(row["ftype"]) ?? ""
            )
            let scriptURL = dataFolder
                .appendingPathComponent("fund", isDirectory: true)
                .appendingPathComponent(code + ".js")
            let scriptHistory: [NAV]
            if let data = try? Data(contentsOf: scriptURL),
               let rows = try? MarketProviders.decodeHistoryScript(data, money: false, limit: 600) {
                scriptHistory = rows
            } else {
                scriptHistory = []
            }
            let observationSeries: [ObservationPoint]
            if let data = try? Data(contentsOf: scriptURL),
               let cumulative = try? MarketProviders.decodeCumulativeHistoryScript(data, limit: 600) {
                observationSeries = cumulative.map { ObservationPoint(day: $0.day, value: $0.value) }
            } else {
                let chartValues = ((row["chart"] as? [String: Any])?["v"] as? [Any] ?? [])
                    .compactMap(decimalValue)
                observationSeries = zip(scriptHistory.suffix(chartValues.count), chartValues).map {
                    ObservationPoint(day: $0.day, value: $1)
                }
            }
            let latest = latestNAV(row["nav_last"], source: "MACD 本地数据")
            let history = scriptHistory.isEmpty ? (latest.map { [$0] } ?? []) : scriptHistory
            let updatedDay = history.last?.day ?? "—"
            return ImportedObservation(
                fund: fund,
                groups: [.macd],
                history: history,
                observation: FundObservation(
                    updatedDay: updatedDay,
                    source: "MACD 本地数据",
                    metrics: macdMetrics(row),
                    series: observationSeries.isEmpty ? nil : observationSeries,
                    macd: macdRating(row)
                )
            )
        }
    }

    private static func macdMetrics(_ row: [String: Any]) -> [ObservationMetric] {
        var metrics: [ObservationMetric] = []
        appendMetric(&metrics, "pattern", "适配形态", string(row["pattern"]))
        appendMetric(&metrics, "track", "跟踪指数", string(row["track"]))
        appendMetric(&metrics, "scale", "基金规模", string(row["scale"]))
        appendPercent(&metrics, row, "ret1y", "近一年", key: "ret1y")
        appendPercent(&metrics, row, "vol", "年化波动", key: "vol")
        appendMetric(&metrics, "er1", "效率比 ER(1Y)", number(row["er1"], digits: 3))
        appendMetric(&metrics, "r2", "趋势拟合 R²", number(row["r2"], digits: 3))
        appendPercent(&metrics, row, "mdd", "最大回撤", key: "mdd")
        appendPercent(&metrics, row, "pos", "当前历史位置", key: "pos")
        appendMetric(&metrics, "legs", "有效波段", integer(row["legs"]).map { "\($0) 段" })
        appendMetric(&metrics, "duration", "波段中位天数", number(row["dur_med"], digits: 0).map { $0 + " 天" })
        appendPercent(&metrics, row, "amplitude", "波段平均振幅", key: "amp_med")

        let backtest = (row["bt_all"] as? [String: Any])
            ?? ((row["bt"] as? [String: Any])?["all"] as? [String: Any])
        if let backtest {
            appendPercent(&metrics, backtest, "strategy", "策略累计收益", key: "strat")
            appendPercent(&metrics, backtest, "holding", "买入持有收益", key: "hold")
            appendMetric(&metrics, "trades", "回测交易", integer(backtest["n"]).map { "\($0) 次" })
            appendPercent(&metrics, backtest, "win", "盈利交易占比", key: "win")
            appendMetric(&metrics, "profit_factor", "盈亏比", number(backtest["pf"], digits: 2))
            appendPercent(&metrics, backtest, "backtest_drawdown", "策略最大回撤", key: "mdd")
        }
        return metrics
    }

    private static func macdRating(_ row: [String: Any]) -> MACDRating? {
        guard let rating = row["g"] as? [String: Any] else { return nil }
        let grade = string(rating["grade"]) ?? "—"
        let recommendation: String
        switch grade {
        case "S": recommendation = "优先适配"
        case "A": recommendation = "适配"
        case "B": recommendation = "有条件适配"
        case "C": recommendation = "不推荐"
        default: recommendation = "样本或规模不满足"
        }
        return MACDRating(
            score: decimalValue(rating["score"]),
            grade: grade,
            recommendation: recommendation,
            fee8: decimalValue(row["fee8"]),
            reasons: (rating["reasons"] as? [String]) ?? []
        )
    }

    private static func redRows(in folder: URL) throws -> [ImportedObservation] {
        let cacheURL = folder.appendingPathComponent(".cache.json")
        if let cache = try jsonObject(at: cacheURL) as? [String: Any],
           let funds = cache["funds"] as? [[String: Any]], !funds.isEmpty {
            return funds.compactMap { redObservation($0, generatedAt: string(cache["generated_at"])) }
        }

        let historyURL = folder.appendingPathComponent("history.json")
        guard var history = try jsonArray(at: historyURL)?
            .compactMap({ $0 as? [String: Any] }) else { return [] }
        history.sort { (string($0["date"]) ?? "") < (string($1["date"]) ?? "") }
        let latest = history.last ?? [:]
        let funds = latest["funds"] as? [[String: Any]] ?? []
        return funds.compactMap { redObservation($0, generatedAt: string(latest["ts"])) }
    }

    private static func redObservation(_ row: [String: Any], generatedAt: String?) -> ImportedObservation? {
        guard let code = string(row["code"]), Fund.validCode(code),
              let name = string(row["name"]) else { return nil }
        let fund = Fund(code: code, name: name, kind: "指数型-股票")
        let navDay = string(row["nav_date"]) ?? "—"
        let nav = number(row["nav"], digits: nil).flatMap { value in
            navDay == "—" ? nil : NAV(
                day: navDay,
                value: parseDecimal(string(row["nav"])) ?? 0,
                rate: parseDecimal(string(row["rate"])),
                source: "红利本地数据"
            )
        }
        var metrics: [ObservationMetric] = []
        appendMetric(&metrics, "track", "跟踪指数", string(row["track"]))
        appendMetric(&metrics, "anchor", "估值锚", string(row["anchor_name"]))
        appendMetric(&metrics, "anchor_mode", "锚定方式", string(row["anchor_mode"]).map {
            $0 == "exact" ? "精确对应" : "代理参照"
        })

        if let valuation = row["anchor_valuation"] as? [String: Any] {
            appendPercent(&metrics, valuation, "dividend", "股息率", key: "dividend")
            appendMetric(&metrics, "pe", "PE / 分位", combined(
                number(valuation["pe"], digits: 2),
                number(valuation["pe_pct"], digits: 2).map { $0 + "%" }
            ))
            appendMetric(&metrics, "pb", "PB / 分位", combined(
                number(valuation["pb"], digits: 2),
                number(valuation["pb_pct"], digits: 2).map { $0 + "%" }
            ))
        }
        if let evaluation = row["eval"] as? [String: Any] {
            appendMetric(&metrics, "level", "估值结论", (evaluation["level"] as? [String: Any]).flatMap {
                string($0["label"])
            })
            appendMetric(&metrics, "advice", "操作提示", (evaluation["level"] as? [String: Any]).flatMap {
                string($0["advice"])
            }, note: "来自红利本地模型")
            appendMetric(&metrics, "spread", "股债利差", number(evaluation["spread"], digits: 2).map {
                $0 + " 个百分点"
            })
        }
        if let relative = row["rs"] as? [String: Any] {
            appendMetric(&metrics, "relative", "相对强弱", (relative["signal"] as? [String: Any]).flatMap {
                string($0["label"])
            }, note: "与本地基准区间收益比较")
            appendMetric(&metrics, "relative_diff", "超额收益", number(relative["diff"], digits: 2).map {
                $0 + " 个百分点"
            })
        }
        if let stats = row["stats"] as? [String: Any] {
            for (key, label) in [("1y", "近一年"), ("6m", "近六月"), ("3m", "近三月")] {
                if let point = stats[key] as? [String: Any] {
                    appendPercent(&metrics, point, "stats_" + key, label + "涨幅", key: "ret")
                }
            }
        }
        let updated = string(row["nav_date"]) ?? generatedAt?.prefix(10).description ?? "—"
        let valuation = redValuation(row)
        return ImportedObservation(
            fund: fund,
            groups: [.red],
            history: nav.map { [$0] } ?? [],
            observation: FundObservation(
                updatedDay: updated,
                source: "红利本地数据",
                metrics: metrics,
                valuation: valuation
            )
        )
    }

    private static func redValuation(_ row: [String: Any]) -> RedValuation? {
        guard let evaluation = row["eval"] as? [String: Any],
              let total = integer(evaluation["total"]) else { return nil }
        let level = evaluation["level"] as? [String: Any] ?? [:]
        let anchors = (evaluation["anchors"] as? [[String: Any]] ?? []).compactMap { anchor -> ValuationAnchor? in
            guard let key = string(anchor["key"]), let name = string(anchor["name"]),
                  let score = integer(anchor["score"]), let label = string(anchor["label"]) else { return nil }
            let unit = string(anchor["unit"]) ?? ""
            let value = number(anchor["value"], digits: 2).map {
                $0 + (unit == "pct" ? "pct" : unit)
            } ?? "—"
            return ValuationAnchor(
                key: key,
                name: name,
                value: value,
                score: score,
                label: label,
                rule: string(anchor["rule"])
            )
        }
        let stats = (row["stats"] as? [String: Any])?["1y"] as? [String: Any]
        let relative = row["rs"] as? [String: Any]
        let signal = relative?["signal"] as? [String: Any]
        return RedValuation(
            total: total,
            maximum: integer(evaluation["max"]) ?? 8,
            level: string(level["label"]) ?? "—",
            levelDescription: string(level["desc"]),
            advice: string(level["advice"]) ?? "",
            anchors: anchors,
            oneYearPercentile: decimalValue(stats?["pct"]),
            oneYearHigh: decimalValue(stats?["hi"]),
            oneYearLow: decimalValue(stats?["lo"]),
            oneYearReturn: decimalValue(stats?["ret"]),
            fromHigh: decimalValue(stats?["from_high"]),
            relativeDifference: decimalValue(relative?["diff"]),
            relativeLabel: string(signal?["label"]),
            relativeAdvice: string(signal?["advice"])
        )
    }

    private static func appendMetric(
        _ metrics: inout [ObservationMetric], _ key: String, _ label: String, _ value: String?,
        note: String? = nil
    ) {
        guard let value, !value.isEmpty else { return }
        metrics.append(ObservationMetric(key: key, label: label, value: value, note: note))
    }

    private static func appendPercent(
        _ metrics: inout [ObservationMetric], _ row: [String: Any], _ key: String,
        _ label: String, key metricKey: String
    ) {
        let rawKey = key == "amplitude" ? "amp_med" : (
            key == "strategy" ? "strat" : (
                key == "holding" ? "hold" : (
                    key == "backtest_drawdown" ? "mdd" : key
                )
            )
        )
        guard var raw = number(row[rawKey], digits: 2) else { return }
        if rawKey == "pos", let value = decimalValue(row[rawKey]) {
            raw = NSDecimalNumber(decimal: value * 100)
                .doubleValue
                .formatted(.number.precision(.fractionLength(2)))
        }
        let percentFields: Set<String> = [
            "ret1y", "vol", "mdd", "pos", "amp_med", "strat", "hold", "win", "dividend", "ret"
        ]
        let suffix = percentFields.contains(rawKey) ? "%" : ""
        metrics.append(ObservationMetric(key: metricKey, label: label, value: raw + suffix))
    }

    private static func latestNAV(_ value: Any?, source: String) -> NAV? {
        guard let pair = value as? [Any], pair.count >= 2,
              let day = string(pair[0]), MarketClock.timestamp(day: day) != nil,
              let text = string(pair[1]), let value = parseDecimal(text), value > 0 else { return nil }
        return NAV(day: day, value: value, source: source)
    }

    private static func combined(_ values: String?...) -> String? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " / ")
    }

    private static func number(_ value: Any?, digits: Int?) -> String? {
        guard let decimal = decimalValue(value) else { return nil }
        if let digits {
            return NSDecimalNumber(decimal: decimal).doubleValue
                .formatted(.number.precision(.fractionLength(digits)))
        }
        return NSDecimalNumber(decimal: decimal).stringValue
    }

    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return string(value).flatMap(Int.init)
    }

    private static func parseDecimal(_ value: String?) -> Decimal? {
        guard let value,
              value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#,
                          options: .regularExpression) != nil else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func decimalValue(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber {
            return parseDecimal(String(format: "%.12g", number.doubleValue))
        }
        return parseDecimal(value as? String)
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func jsonObject(at url: URL) throws -> Any? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 10_000_000 else { throw ImportError.noData }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func jsonArray(at url: URL) throws -> [Any]? {
        try jsonObject(at: url) as? [Any]
    }
}
