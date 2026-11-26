import FundCore
import SwiftUI

struct FundDetailTabs: View {
    let tabs: [FundDetailTab]
    @Binding var selection: FundDetailTab
    let move: (FundDetailTab, FundDetailTab) -> Void

    private struct Move {
        let from: Int
        let to: Int
    }

    @GestureState private var drag: Move?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(tabs.count)
            HStack(spacing: 0) {
                ForEach(tabs.indices, id: \.self) { index in
                    let tab = tabs[index]
                    Button { selection = tab } label: {
                        Text(title(for: tab))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == tab ? Display.primaryStrong : Color.primary)
                    .frame(width: width)
                    .background(selection == tab || drag?.from == index ? Display.selected : Color.clear)
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle().fill(.primary.opacity(0.15))
                                .frame(width: 1)
                                .padding(.vertical, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .help("点击切换 · 左右拖动调整顺序")
                }
            }
            .background(Display.panel)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Display.stroke)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                if let drag, drag.from != drag.to {
                    let edge = drag.from < drag.to ? drag.to + 1 : drag.to
                    Capsule().fill(Display.primary)
                        .frame(width: 2)
                        .offset(x: min(max(CGFloat(edge) * width - 1, 0), geometry.size.width - 2))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in
                        state = destination(for: value, size: geometry.size, width: width)
                    }
                    .onEnded { value in
                        guard let drag = destination(for: value, size: geometry.size, width: width),
                              drag.from != drag.to else { return }
                        move(tabs[drag.from], tabs[drag.to])
                    }
            )
        }
        .frame(height: 23)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("基金详情")
    }

    private func destination(for value: DragGesture.Value, size: CGSize, width: CGFloat) -> Move? {
        guard width > 0,
              (0...size.width).contains(value.startLocation.x),
              (-8...(size.width + 8)).contains(value.location.x),
              (-8...(size.height + 8)).contains(value.location.y)
        else { return nil }
        let from = min(Int(value.startLocation.x / width), tabs.count - 1)
        let to = min(Int(max(value.location.x, 0) / width), tabs.count - 1)
        return Move(from: from, to: to)
    }

    private func title(for tab: FundDetailTab) -> String {
        switch tab {
        case .estimate: "净值估算"
        case .history: "历史净值"
        case .returns: "累计收益"
        case .holdings: "持仓明细"
        case .profile: "基金概况"
        case .observation: "观察数据"
        }
    }
}
