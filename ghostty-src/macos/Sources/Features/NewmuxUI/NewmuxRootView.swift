import SwiftUI

struct NewmuxRootView<TerminalContent: View>: View {
    @StateObject private var model = NewmuxUIModel()

    let terminal: TerminalContent

    init(@ViewBuilder terminal: () -> TerminalContent) {
        self.terminal = terminal()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            terminal
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if NewmuxUIFlag.enabled {
                NewmuxTabRailView(model: model)
            }

            if NewmuxUIFlag.enabled && NewmuxUIFlag.statusEnabled {
                NewmuxUIStatusView(status: model.status)
                    .padding(.top, 10)
                    .padding(.trailing, model.status.railExpanded ? 372 : 84)
            }
        }
        .onAppear {
            model.refresh()
        }
    }
}

private struct NewmuxUIStatusView: View {
    let status: NewmuxUIStatus

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(status.summary)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(status.markerText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1)
        )
        .accessibilityIdentifier("newmux-ui-status")
    }
}
