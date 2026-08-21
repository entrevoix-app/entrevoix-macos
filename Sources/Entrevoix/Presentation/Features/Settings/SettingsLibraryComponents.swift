import SwiftUI

struct SettingsLibraryHeader: View {
    let title: String
    let description: String
    let count: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(count)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, SettingsLayout.pageInset)
        .padding(.top, SettingsLayout.pageInset)
        .padding(.bottom, 12)
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
                    .frame(width: 16)
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
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
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
        HStack(spacing: 12) {
            configuration.icon
            configuration.title
        }
    }
}
