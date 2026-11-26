import FundCore
import SwiftUI

struct PositionJournalView: View {
    @ObservedObject var model: BoardModel
    let code: String
    @Environment(\.dismiss) private var dismiss
    @ViewState private var action = PositionAction.buy
    @ViewState private var date = Date.now
    @ViewState private var shares = ""
    @ViewState private var price = ""
    @ViewState private var fee = ""
    @ViewState private var distribution = ""
    @ViewState private var error: String?
    @ViewState private var editingID: UUID?
    @ViewState private var deleting: PositionRecord?

    private var records: [PositionRecord] { model.board.journals?[code] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editingID == nil ? "持仓流水" : "编辑流水").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Picker("记录类型", selection: $action) {
                        ForEach(PositionAction.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                    }
                    DatePicker("确认日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                }
                HStack {
                    if action == .distribution {
                        TextField("到账金额", text: $distribution).accessibilityLabel("到账金额")
                    } else {
                        TextField("确认份额", text: $shares).accessibilityLabel("确认份额")
                        TextField("成交净值", text: $price).accessibilityLabel("成交净值")
                        TextField("手续费（可空）", text: $fee).accessibilityLabel("手续费")
                    }
                    Button(editingID == nil ? "保存记录" : "保存修改") { save() }
                        .disabled(!validInput)
                    if editingID != nil {
                        Button("取消修改") { resetForm() }
                    }
                }
                Text("填写平台已确认的份额和净值。修改或删除会按剩余流水重新计算持仓；加仓按加权平均更新成本，减仓按当前单位成本计算已实现收益。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(Display.danger) }
            }
            .researchCard()
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if records.isEmpty {
                        Text("还没有流水记录。").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(records.reversed())) { record in
                        HStack {
                            Text(record.day).foregroundStyle(.secondary)
                            Text(record.action.rawValue)
                            if let shares = record.shares { Text(Display.number(shares, digits: 2) + " 份") }
                            Spacer()
                            Text(Display.money(record.cash, signed: true)).monospacedDigit()
                            if let realized = record.realized {
                                Text("已实现 " + Display.money(realized, signed: true)).monospacedDigit()
                            }
                            Menu {
                                Button("编辑记录") { beginEdit(record) }
                                Button("删除记录", role: .destructive) { deleting = record }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 24)
                            .accessibilityLabel("流水操作")
                        }
                        .font(.callout)
                        Divider()
                    }
                }
                .researchCard()
                .padding(1)
            }
        }
        .padding(17)
        .frame(width: 620, height: 395)
        .background(Display.canvasWash)
        .tint(Display.primary)
        .environment(\.timeZone, MarketClock.calendar.timeZone)
        .alert(
            "删除这条流水？",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { record in
            Button("删除", role: .destructive) { delete(record) }
            Button("取消", role: .cancel) {}
        } message: { record in
            Text("将删除 \(record.day) 的\(record.action.rawValue)记录，并按剩余流水重新计算持仓。")
        }
    }

    private var validInput: Bool {
        if action == .distribution { return (decimal(distribution) ?? 0) > 0 }
        return (decimal(shares) ?? 0) > 0 && (decimal(price) ?? 0) > 0
            && (fee.isEmpty || decimal(fee).map({ $0 >= 0 }) == true)
    }

    private func save() {
        do {
            let dividend = action == .distribution
            let change = PositionChange(
                action: action, day: MarketClock.day(date),
                shares: dividend ? nil : decimal(shares),
                price: dividend ? nil : decimal(price),
                fee: dividend ? 0 : (decimal(fee) ?? 0),
                distribution: dividend ? decimal(distribution) : nil
            )
            if let editingID {
                try model.replaceRecord(code: code, recordID: editingID, change: change)
            } else {
                try model.record(code: code, change: change)
            }
            resetForm()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func beginEdit(_ record: PositionRecord) {
        editingID = record.id
        action = record.action
        date = MarketClock.timestamp(day: record.day) ?? .now
        shares = record.shares.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        price = record.price.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        fee = record.fee == 0 ? "" : NSDecimalNumber(decimal: record.fee).stringValue
        distribution = record.action == .distribution
            ? NSDecimalNumber(decimal: record.cash).stringValue : ""
        error = nil
    }

    private func delete(_ record: PositionRecord) {
        do {
            try model.deleteRecord(code: code, recordID: record.id)
            if editingID == record.id { resetForm() }
            deleting = nil
            error = nil
        } catch {
            deleting = nil
            self.error = error.localizedDescription
        }
    }

    private func resetForm() {
        editingID = nil
        shares = ""
        price = ""
        fee = ""
        distribution = ""
    }
}
