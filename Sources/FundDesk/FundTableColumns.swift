import FundCore
import SwiftUI

extension FundTableColumn {
    var title: String {
        switch self {
        case .name: return "基金名称"
        case .estimateRate: return "估算涨跌"
        case .dayProfit: return "日收益"
        case .value: return "持有金额"
        case .profit: return "持有收益"
        case .profitRate: return "持有收益率"
        case .estimateTime: return "估值更新"
        case .code: return "代码"
        case .nav: return "净值 / 万份"
        case .navDate: return "净值日"
        case .navRate: return "披露涨跌"
        case .estimate: return "估算净值"
        }
    }

    static let sortable: [Self] = [.estimateRate, .dayProfit, .value, .profit, .profitRate, .navRate]

    fileprivate var width: CGFloat? {
        switch self {
        case .name: return nil
        case .code, .navDate: return 45
        case .nav, .estimate: return 60
        case .navRate, .estimateRate: return 49
        case .dayProfit, .profit: return 76
        case .value: return 83
        case .profitRate, .estimateTime: return 59
        }
    }
}

struct FundTableColumnPicker: View {
    @ObservedObject var model: BoardModel
    @ViewState private var showingColumns = false

    var body: some View {
        let allColumns = model.board.fundColumns
        let visible = Set(model.board.visibleFundColumns)
        Button {
            showingColumns.toggle()
        } label: {
            Label("显示列", systemImage: "tablecells")
        }
        .controlSize(.small)
        .popover(isPresented: $showingColumns, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("显示列").font(.headline)
                ForEach(allColumns, id: \.self) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { model.board.visibleFundColumns.contains(column) },
                        set: { isVisible in
                            var updated = Set(model.board.visibleFundColumns)
                            if isVisible {
                                updated.insert(column)
                            } else {
                                updated.remove(column)
                            }
                            model.setVisibleFundColumns(updated)
                        }
                    ))
                    .disabled(column == .name)
                    .help(column == .name ? "基金名称始终显示" : "")
                }
                Divider()
                Button("显示全部列") {
                    model.setVisibleFundColumns(Set(allColumns))
                }
                .disabled(visible.count == allColumns.count)
            }
            .padding(14)
            .frame(minWidth: 160, alignment: .leading)
        }
    }
}

private enum FundTableLayout {
    static let spacing: CGFloat = 6
    static let inset: CGFloat = 10
    static let disclosureWidth: CGFloat = 9

    static func columnBounds(_ columns: [FundTableColumn], in width: CGFloat) -> [ClosedRange<CGFloat>] {
        let fixedWidths = columns.compactMap(\.width).reduce(0, +)
        let fixedSpacing = 2 * inset + CGFloat(columns.count) * spacing + disclosureWidth
        let nameWidth = max(0, width - fixedWidths - fixedSpacing)
        var x = inset
        return columns.map { column in
            let right = x + (column.width ?? nameWidth)
            let bounds = x...right
            x = right + spacing
            return bounds
        }
    }
}

struct FundTableLine<Cell: View>: View {
    let columns: [FundTableColumn]
    var showsDisclosure = true
    @ViewBuilder let cell: (FundTableColumn) -> Cell

    var body: some View {
        HStack(spacing: FundTableLayout.spacing) {
            ForEach(columns, id: \.self) { column in
                if let width = column.width {
                    cell(column).frame(width: width, alignment: .trailing)
                } else {
                    cell(column).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(showsDisclosure ? 1 : 0)
                .frame(width: FundTableLayout.disclosureWidth)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, FundTableLayout.inset)
    }
}

struct FundTableHeader: View {
    private struct Move {
        let from: Int
        let to: Int
    }

    let columns: [FundTableColumn]
    let sortColumn: FundTableColumn?
    let ascending: Bool
    let sort: (FundTableColumn) -> Void
    let save: ([FundTableColumn]) -> Void
    @GestureState private var move: Move?

    var body: some View {
        GeometryReader { geometry in
            let bounds = FundTableLayout.columnBounds(columns, in: geometry.size.width)
            FundTableLine(columns: columns, showsDisclosure: false) { column in
                headerCell(column)
            }
            .frame(maxHeight: .infinity)
            .background(alignment: .topLeading) {
                if let move {
                    let source = bounds[move.from]
                    Rectangle().fill(Display.selected)
                        .frame(width: source.upperBound - source.lowerBound)
                        .offset(x: source.lowerBound)
                }
            }
            .overlay(alignment: .topLeading) {
                if let move, move.from != move.to {
                    let target = bounds[move.to]
                    let x = move.from < move.to
                        ? target.upperBound + FundTableLayout.spacing / 2 : target.lowerBound - FundTableLayout.spacing / 2
                    Capsule().fill(Display.primary)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                        .offset(x: x - 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($move) { value, move, _ in
                        move = destination(for: value, bounds: bounds, height: geometry.size.height)
                    }
                    .onEnded { value in
                        guard let move = destination(for: value, bounds: bounds, height: geometry.size.height),
                              move.from != move.to else { return }
                        var reordered = columns
                        let column = reordered.remove(at: move.from)
                        reordered.insert(column, at: move.to)
                        save(reordered)
                    }
            )
        }
        .frame(height: 23)
        .background(Display.panelRaised)
    }

    @ViewBuilder
    private func headerCell(_ column: FundTableColumn) -> some View {
        let active = sortColumn == column
        if FundTableColumn.sortable.contains(column) {
            Button { sort(column) } label: {
                HStack(spacing: 2) {
                    Text(column.title).minimumScaleFactor(0.8)
                    if active {
                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Display.primaryStrong : Color.secondary)
            .accessibilityLabel(column.title + (active ? (ascending ? "，升序" : "，降序") : "，排序"))
            .help(active && !ascending ? "点击改为升序 · 拖动调整列序" : "点击降序排列 · 拖动调整列序")
        } else {
            Text(column.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(columns.count > 1 ? "拖动表头调整列序" : "")
        }
    }

    private func destination(for value: DragGesture.Value, bounds: [ClosedRange<CGFloat>], height: CGFloat) -> Move? {
        guard (-8...(height + 8)).contains(value.location.y),
              let source = bounds.firstIndex(where: { $0.contains(value.startLocation.x) })
        else { return nil }
        let target = bounds.firstIndex { value.location.x < $0.upperBound + FundTableLayout.spacing / 2 } ?? bounds.count - 1
        return Move(from: source, to: target)
    }
}
