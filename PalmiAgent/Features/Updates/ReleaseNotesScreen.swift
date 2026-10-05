import SwiftUI

/// Content identifiers are independent of build numbers, so patch builds do not repeat an announcement.
enum ReleaseNotesCatalog {
    static let currentID = "bionic-introduction-2026-09"
    static let acknowledgedKey = "palmi.release-notes.acknowledged"
    static let history = ["26.9", "26.8", "26.7", "1.0.1", "1.0.0"]
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
                VStack(alignment: .leading, spacing: 12) {
                    Text(PalmiL10n.tr("updates.highlights.title")).font(.title2.bold())
                    Text(PalmiL10n.tr("updates.highlights.body")).lineSpacing(5)
                }
                Divider()
                BionicIntroductionContent()
            }
            .frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    acknowledge()
                    onOpenBionic()
                } label: {
                    Text(PalmiL10n.tr("updates.openBionic"))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
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

struct ReleaseNotesHistoryScreen: View {
    let onOpenBionic: () -> Void
    var body: some View {
        List {
            NavigationLink(PalmiL10n.tr("updates.current")) {
                CurrentReleaseNotesScreen(onOpenBionic: onOpenBionic)
            }
            Section(PalmiL10n.tr("updates.history")) {
                ForEach(ReleaseNotesCatalog.history, id: \.self) { version in
                    NavigationLink("Palmi APP \(version)") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Palmi APP \(version)").font(.largeTitle.bold())
                                Text(PalmiL10n.tr("updates.history.\(version)"))
                                    .lineSpacing(5).textSelection(.enabled)
                                if let url = URL(string: "https://github.com/Hyp6666/PalmiAgent/releases/tag/v\(version)") {
                                    Link(PalmiL10n.tr("updates.source"), destination: url)
                                }
                            }
                            .frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                        }
                        .navigationTitle(version).navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("updates.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
