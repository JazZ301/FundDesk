import FundCore
import SwiftUI
import UniformTypeIdentifiers

enum FundRowLayout {
    static let height: CGFloat = 25.5
    static let handleWidth: CGFloat = 20
}

private extension UTType {
    static let fundRow = UTType(exportedAs: "local.ju.funddesk.holding-row", conformingTo: .data)
}

struct DraggableFundRow<Content: View>: View {
    let holding: Holding
    let move: (String, String, HoldingPlacement) -> Void
    @ViewBuilder let content: () -> Content
    @ViewState private var placement: HoldingPlacement?

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: FundRowLayout.handleWidth, height: FundRowLayout.height)
                .contentShape(Rectangle())
                .onDrag { itemProvider() }
                .help("拖动调整基金顺序")
                .accessibilityLabel("拖动\(holding.fund.name)调整顺序")
            content()
        }
        .contentShape(Rectangle())
        .overlay(alignment: placement == .before ? .top : .bottom) {
            if placement != nil {
                Capsule().fill(Display.primary)
                    .frame(height: 2)
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fundRow], delegate: FundRowDrop(target: holding.id, placement: $placement, move: move))
    }

    private func itemProvider() -> NSItemProvider {
        let code = holding.id
        let provider = NSItemProvider()
        provider.suggestedName = holding.fund.name
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fundRow.identifier, visibility: .ownProcess) { finish in
            finish(Data(code.utf8), nil)
            return nil
        }
        return provider
    }
}

private struct FundRowDrop: DropDelegate {
    let target: String
    @Binding var placement: HoldingPlacement?
    let move: (String, String, HoldingPlacement) -> Void

    func dropEntered(info: DropInfo) {
        placement = destination(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = destination(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        placement = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        placement = nil
        guard let provider = info.itemProviders(for: [.fundRow]).first else { return false }
        let destination = destination(info)
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fundRow.identifier) { data, _ in
            guard let data, let code = String(data: data, encoding: .utf8), Fund.validCode(code) else { return }
            Task { @MainActor in move(code, target, destination) }
        }
        return true
    }

    private func destination(_ info: DropInfo) -> HoldingPlacement {
        info.location.y < FundRowLayout.height / 2 ? .before : .after
    }
}
