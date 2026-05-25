import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case summary = "Summary"
    case actions = "Actions"
    case highlights = "Highlights"
    case export = "Export"
    var id: String { rawValue }
}

struct TabsBar: View {
    @Binding var selected: MainTab

    var body: some View {
        HStack(spacing: 24) {
            ForEach(MainTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .background(Theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1.5)
        }
    }

    private func tabButton(_ tab: MainTab) -> some View {
        let isOn = selected == tab
        return Button(action: { selected = tab }) {
            VStack(spacing: 0) {
                Text(tab.rawValue)
                    .font(.ui(13, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? Theme.ink : Theme.inkMuted)
                    .padding(.vertical, 12)
                Rectangle()
                    .fill(isOn ? Theme.accent : .clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }
}
