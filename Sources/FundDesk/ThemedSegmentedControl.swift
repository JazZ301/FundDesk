import SwiftUI

struct ThemedSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var title = ""
    var height: CGFloat = 24
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selection == option ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == option ? Display.primaryStrong : Color.primary)
                .background(selection == option ? Display.selected : Display.panelRaised)
                .overlay(alignment: .leading) {
                    if index > 0 {
                        Rectangle()
                            .fill(Display.stroke)
                            .frame(width: 1)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .frame(height: height)
        .background(Display.panel, in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Display.stroke)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
