import SwiftUI

enum SettingsLayout {
    static let pageInset: CGFloat = 12
    static let toolbarContentInset: CGFloat = 8
    static let cardContentInset: CGFloat = 16
    static let groupedFormTopInset: CGFloat = 24
    static let groupedFormHorizontalInset: CGFloat = 20
    static let gridSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 12
    static let iconTileSize: CGFloat = 48
    static let cardCornerRadius: CGFloat = 12
}

extension View {
    func settingsPageContentMargins() -> some View {
        contentMargins(.horizontal, SettingsLayout.pageInset, for: .scrollContent)
            .contentMargins(.top, SettingsLayout.toolbarContentInset, for: .scrollContent)
    }

    func settingsGroupedFormContentMargins() -> some View {
        contentMargins(
            .horizontal,
            SettingsLayout.pageInset - SettingsLayout.groupedFormHorizontalInset,
            for: .scrollContent
        )
        .contentMargins(
            .top,
            SettingsLayout.toolbarContentInset - SettingsLayout.groupedFormTopInset,
            for: .scrollContent
        )
    }
}
