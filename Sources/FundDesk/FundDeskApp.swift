import AppKit
import Combine
import FundCore
import SwiftUI

@main
struct FundDeskApp: App {
    @NSApplicationDelegateAdaptor(FundDeskAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("基金看板", id: "board") {
            BoardSceneContent(model: appDelegate.model, appDelegate: appDelegate)
        }
        .defaultSize(width: 1160, height: 810)
        .commands { BoardCommands(model: appDelegate.model) }
    }
}

private struct BoardCommands: Commands {
    @ObservedObject var model: BoardModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("基金") {
            Button("刷新数据") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.refreshing || model.board.holdings.isEmpty)
        }
    }
}

@MainActor
final class FundDeskAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = BoardModel()
    var openBoardWindow: OpenWindowAction?

    private var statusItem: NSStatusItem?
    private var quoteUpdates: AnyCancellable?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's MenuBarExtra drops foreground colors from its text label.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(toggleQuickLook)
        popover.behavior = .transient
        popover.delegate = self

        quoteUpdates = model.marketQuotes.$snapshot.sink { [weak self] snapshot in
            let change = snapshot?.value.first { $0.index == .shanghaiComposite }?.change
            self?.updateStatusTitle(change)
        }
        model.start()
    }

    private func updateStatusTitle(_ change: Decimal?) {
        let title = NSMutableAttributedString(string: "上证")
        if let change {
            let points = Display.signedNumber(change)
            let color = Display.changeColor(change)
            let attributes: [NSAttributedString.Key: Any] = color == .secondary
                ? [:] : [.foregroundColor: NSColor(color)]
            title.append(NSAttributedString(string: " " + points, attributes: attributes))
        }
        statusItem?.button?.attributedTitle = title
        statusItem?.button?.setAccessibilityLabel(title.string)
    }

    @objc private func toggleQuickLook() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let controller = NSHostingController(rootView: QuickLook(model: model, quotes: model.marketQuotes) { [weak self] in
            self?.popover.performClose(nil)
            self?.openBoardWindow?(id: "board")
            NSApp.activate(ignoringOtherApps: true)
        })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let openBoardWindow else { return true }
        openBoardWindow(id: "board")
        return false
    }
}

private struct BoardSceneContent: View {
    @ObservedObject var model: BoardModel
    let appDelegate: FundDeskAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        BoardView(model: model)
            .onAppear { appDelegate.openBoardWindow = openWindow }
    }
}

struct QuickLook: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var quotes: MarketQuotes
    @Environment(\.colorScheme) private var colorScheme
    let openBoard: () -> Void

    var body: some View {
        let quote = quotes.shanghaiQuote
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("上证指数").font(.headline)
                Text("000001").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("打开看板", systemImage: "macwindow", action: openBoard)
                    .buttonStyle(.borderless)
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Display.number(quote?.value, digits: 2))
                    .font(.title2.weight(.semibold).monospacedDigit())
                if let quote {
                    Text(Display.signedNumber(quote.change)).font(.callout.monospacedDigit())
                    Text(Display.percent(quote.rate)).font(.callout.weight(.semibold).monospacedDigit())
                }
            }
            .foregroundStyle(Display.changeColor(quote?.rate))
            Text(quoteStatus)
                .font(.caption)
                .foregroundStyle(quotes.failed ? Display.warning : Color.secondary)
            Divider()
            IndexTrendPane(research: model.research, index: .shanghaiComposite, height: 200,
                           title: "分时", refreshDisabled: quotes.loading) {
                Task { await quotes.refresh() }
            }
        }
        .id(model.board.appearanceThemeValue)
        .padding(16)
        .frame(width: 430)
        .background(Display.canvasWash)
        .tint(Display.primary(for: model.board.appearanceThemeValue, systemColorScheme: colorScheme))
        .preferredColorScheme(model.board.appearanceThemeValue.colorScheme)
    }

    private var quoteStatus: String {
        if let quote = quotes.shanghaiQuote {
            return (quotes.failed ? "报价刷新失败 · " : "") + quote.timestamp + " · 北京时间"
        }
        return quotes.loading ? "正在获取指数报价…" : "暂无指数报价"
    }
}
