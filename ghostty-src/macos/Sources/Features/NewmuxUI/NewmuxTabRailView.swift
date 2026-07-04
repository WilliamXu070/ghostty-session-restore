import SwiftUI
import UniformTypeIdentifiers

struct NewmuxTabRailView: View {
    @ObservedObject var model: NewmuxUIModel
    @State private var expanded = false

    private var width: CGFloat {
        expanded ? 360 : 72
    }

    var body: some View {
        HStack(spacing: 0) {
            collapsedMarker
                .opacity(expanded ? 0 : 1)
                .frame(width: expanded ? 0 : 72)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    tabGroup
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                expanded = hovering
            }
            model.setRailExpanded(hovering)
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) {
                expanded = true
            }
            model.setRailExpanded(true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEWMUX UI")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange)
                )

            HStack {
                Text("Workspace")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.tabs.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var collapsedMarker: some View {
        VStack(spacing: 8) {
            Text("NM")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 38, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange)
                )

            Rectangle()
                .fill(Color.orange)
                .frame(width: 6, height: 120)
                .clipShape(Capsule())

            Text("\(model.tabs.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.35))
                )
            Spacer()
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
    }

    private var tabGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                Text("Tabs")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            ForEach(model.tabs) { tab in
                NewmuxTabItemView(tab: tab) {
                    model.select(tab)
                }
                .onDrag {
                    NSItemProvider(object: tab.id as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: NewmuxTabDropDelegate(model: model, target: tab)
                )
            }
        }
    }

    private var background: some View {
        Rectangle()
            .fill(expanded ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.orange.opacity(0.34)))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.orange.opacity(expanded ? 0.85 : 1.0))
                    .frame(width: expanded ? 4 : 6)
            }
            .shadow(color: Color.black.opacity(0.24), radius: expanded ? 20 : 10, x: -8, y: 0)
    }
}

private struct NewmuxTabItemView: View {
    let tab: NewmuxUITab
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tab.isActive ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.system(size: 12, weight: tab.isActive ? .semibold : .regular))
                        .lineLimit(1)

                    if let subtitle = tab.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(tab.isActive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct NewmuxTabDropDelegate: DropDelegate {
    let model: NewmuxUIModel
    let target: NewmuxUITab

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let draggedID = value as? String else { return }
            DispatchQueue.main.async {
                model.moveTab(id: draggedID, before: target)
            }
        }

        return true
    }
}
