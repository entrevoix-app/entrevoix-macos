import SwiftUI

struct SettingsLibraryHeader: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        VStack(spacing: SettingsLayout.contentBottomInset) {
            Image(systemName: systemImage)
                .font(.title2.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: SettingsLayout.iconTileSize, height: SettingsLayout.iconTileSize)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius, style: .continuous)
                )

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SettingsLayout.cardContentInset)
        .padding(.vertical, SettingsLayout.cardContentInset)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius, style: .continuous)
        )
        .padding(.bottom, SettingsLayout.sectionSpacing)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

enum SettingsLibraryRowStatus {
    case active(String)
    case warning(String)
}

struct SettingsLibraryRow: View {
    let title: String
    let systemImage: String
    let detail: String?
    let status: SettingsLibraryRowStatus?
    let showsDisclosure: Bool

    init(
        title: String,
        systemImage: String,
        detail: String? = nil,
        status: SettingsLibraryRowStatus? = nil,
        showsDisclosure: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.status = status
        self.showsDisclosure = showsDisclosure
    }

    var body: some View {
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: SettingsLibraryRowLayout.iconWidth)
            }
            .labelStyle(SettingsLibraryRowLabelStyle())

            Spacer(minLength: 12)
            statusView

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading] + SettingsLibraryRowLayout.separatorLeadingInset
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .active(let label):
            Label(label, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
        case .warning(let label):
            Label(label, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }
}

private struct SettingsLibraryRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingsLibraryRowLayout.iconSpacing) {
            configuration.icon
            configuration.title
        }
    }
}

private enum SettingsLibraryRowLayout {
    static let iconWidth: CGFloat = 16
    static let iconSpacing: CGFloat = 12
    static let separatorLeadingInset = iconWidth + iconSpacing
}
