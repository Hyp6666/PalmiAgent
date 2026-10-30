import SwiftUI

/// Content identifiers are independent of build numbers, so patch builds do not repeat an announcement.
enum ReleaseNotesCatalog {
    static let currentID = "release-26.11"
    static let currentItems = ["chat", "interface", "browser", "models", "tools", "interactive", "replies", "files", "questions", "background", "bionic", "languages", "navigation"]
    static let acknowledgedKey = "palmi.release-notes.acknowledged"
    static func title(for version: String) -> String {
        let legacyVersions = ["1.0.0", "1.0.1", "26.7", "26.8", "26.9"]
        return "\(legacyVersions.contains(version) ? "PalmiAgent" : "Palmi") \(version)"
    }

    static let history = ["26.10", "26.9", "26.8", "26.7", "1.0.1", "1.0.0"]
}

struct BionicIntroductionContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(PalmiL10n.tr("bionic.introduction.title")).font(.title.bold())
            ForEach(["origin", "create", "life", "cost", "closing"], id: \.self) { section in
                VStack(alignment: .leading, spacing: 12) {
                    if section != "origin" {
                        Text(PalmiL10n.tr("bionic.introduction.\(section).title")).font(.title3.bold())
                    }
                    Text(sectionBody(section))
                        .font(.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func sectionBody(_ section: String) -> AttributedString {
        let content = PalmiL10n.tr("bionic.introduction.\(section)")
        guard section == "cost",
              let linkedContent = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              ) else { return AttributedString(content) }
        return linkedContent
    }
}

struct BionicIntroductionScreen: View {
    var body: some View {
        ScrollView {
            BionicIntroductionContent().frame(maxWidth: 680, alignment: .leading)
                .padding(24).frame(maxWidth: .infinity)
        }
        .navigationTitle(PalmiL10n.tr("bionic.introduction.shortTitle"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CurrentReleaseNotesScreen: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReleaseNotesCatalog.acknowledgedKey) private var acknowledged = ""
    let onOpenBionic: () -> Void
    var onClose: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(PalmiL10n.tr("updates.current")).font(.largeTitle.bold())
                ForEach(ReleaseNotesCatalog.currentItems, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("•").foregroundStyle(.secondary)
                        Text(PalmiL10n.tr("updates.26.11.\(item)"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(PalmiL10n.tr("updates.dismiss")) { acknowledge() }
                    .font(.subheadline)
            }
            .frame(maxWidth: 680).padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(.bar)
        }
        .navigationTitle(PalmiL10n.tr("updates.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func acknowledge() {
        acknowledged = ReleaseNotesCatalog.currentID
        if let onClose { onClose() } else { dismiss() }
    }
}

struct Release2610Content: View {
    @State private var showsIntroduction = false
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Palmi 26.10").font(.largeTitle.bold())
            releaseSection("bionic", items: ["characters", "conversations", "plans"], introductionHelp: true)
            releaseSection("models", items: ["oauth", "images"])
            releaseSection("neo", items: ["timeline", "details"])
            releaseSection("interaction", items: ["settings", "unread"])
            Divider()
            Text(PalmiL10n.tr("updates.modelUsageNote"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsIntroduction) {
            NavigationStack {
                BionicIntroductionScreen().toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(PalmiL10n.tr("common.done")) { showsIntroduction = false }
                    }
                }
            }
        }
    }

    private func releaseSection(_ section: String, items: [String], introductionHelp: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PalmiL10n.tr("updates.\(section).title")).font(.title2.bold())
                if introductionHelp {
                    Button { showsIntroduction = true } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(minWidth: 36, minHeight: 36).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PalmiL10n.tr("bionic.introduction.shortTitle"))
                    .accessibilityIdentifier("updates.bionic.introduction")
                }
            }
            ForEach(items, id: \.self) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(PalmiL10n.tr("updates.\(section).\(item).title")).font(.headline)
                    Text(PalmiL10n.tr("updates.\(section).\(item).body"))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

}

struct ReleaseNotesHistoryScreen: View {
    let onOpenBionic: () -> Void
    var body: some View {
        List {
            NavigationLink(PalmiL10n.tr("updates.current")) {
                CurrentReleaseNotesScreen(onOpenBionic: onOpenBionic)
            }
            Section(PalmiL10n.tr("updates.history")) {
                ForEach(ReleaseNotesCatalog.history, id: \.self) { version in
                    NavigationLink(ReleaseNotesCatalog.title(for: version)) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                if version == "26.10" {
                                    Release2610Content()
                                } else {
                                    Text(ReleaseNotesCatalog.title(for: version)).font(.largeTitle.bold())
                                    Text(PalmiL10n.tr("updates.history.\(version)"))
                                        .lineSpacing(5).textSelection(.enabled)
                                }
                                if let url = URL(string: "https://github.com/Hyp6666/PalmiAgent/releases/tag/v\(version)") {
                                    Link(PalmiL10n.tr("updates.source"), destination: url)
                                }
                            }
                            .frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                        }
                        .navigationTitle(ReleaseNotesCatalog.title(for: version)).navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("updates.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
