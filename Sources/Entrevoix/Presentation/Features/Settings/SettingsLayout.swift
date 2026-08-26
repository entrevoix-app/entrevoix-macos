import SwiftUI

enum SettingsLayout {
    static let contentHorizontalInset: CGFloat = 20
    static let insetListHorizontalCompensation: CGFloat = 4
    static let contentBottomInset: CGFloat = 12
    static let toolbarContentInset: CGFloat = 8
    static let cardContentInset: CGFloat = 16
    static let listRowVerticalInset: CGFloat = 8
    static let promptInstructionsEditorHeight: CGFloat = 320
    static let promptInstructionsEditorInset: CGFloat = 8
    static let gridSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 12
    static let iconTileSize: CGFloat = 48
    static let cardCornerRadius: CGFloat = 12
}

extension View {
    func settingsPageContentMargins() -> some View {
        contentMargins(.horizontal, SettingsLayout.contentHorizontalInset, for: .scrollContent)
            .contentMargins(.top, SettingsLayout.toolbarContentInset, for: .scrollContent)
    }

    func settingsFormContentMargins() -> some View {
        contentMargins(.top, SettingsLayout.toolbarContentInset, for: .scrollContent)
    }

    func settingsInsetListContentMargins() -> some View {
        padding(.horizontal, SettingsLayout.insetListHorizontalCompensation)
            .contentMargins(.top, SettingsLayout.toolbarContentInset, for: .scrollContent)
    }
}
