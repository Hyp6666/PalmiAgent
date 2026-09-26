import SwiftUI

struct BionicConversationDetailsScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let onJump: (String) -> Void
    @State private var developerVisible = true
    @State private var savingTiming = false
    @State private var savingMute = false
    @State private var savingPin = false
    @State private var error: String?

    private var role: BionicRole? {
        store.roles.first { $0.installationID == instance }
    }
    private var preferences: BionicChatPreferences {
        store.chatPreferences[instance] ?? BionicChatPreferences()
    }

    var body: some View {
        List {
            if let role {
                Section {
                    NavigationLink {
                        BionicRoleInfoScreen(store: store, instance: instance)
                    } label: {
                        HStack(spacing: 16) {
                            BionicAvatar(
                                data: store.avatars[instance + ":" + role.characterID],
                                name: role.name, size: 60
                            )
                            Text(role.name).font(.headline).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                    }
                    .accessibilityLabel(PalmiL10n.tr("bionic.roleInfo") + ", " + role.name)
                }
            }

            Section {
                NavigationLink {
                    BionicHistoryScreen(store: store, instance: instance, mode: .search, onJump: onJump)
                        .id("bionic-search-" + instance)
                } label: {
                    Label(PalmiL10n.tr("bionic.findConversation"), systemImage: "magnifyingglass")
                }
                NavigationLink {
                    BionicHistoryScreen(store: store, instance: instance, mode: .memory, onJump: onJump)
                        .id("bionic-memory-" + instance)
                } label: {
                    Label(PalmiL10n.tr("bionic.memory"), systemImage: "brain")
                }
            }

            Section {
                Picker(PalmiL10n.tr("bionic.replyTiming"), selection: Binding(
                    get: { BionicReplyTiming.resolve(role?.persona ?? [:]).rawValue },
                    set: changeTiming
                )) {
                    Text(PalmiL10n.tr("bionic.replyTiming.instant"))
                        .tag(BionicReplyTiming.instant.rawValue)
                    Text(PalmiL10n.tr("bionic.replyTiming.natural"))
                        .tag(BionicReplyTiming.natural.rawValue)
                }
                .pickerStyle(.menu)
                .disabled(role == nil || savingTiming)

                Toggle(PalmiL10n.tr("bionic.chatMuted"), isOn: Binding(
                    get: { preferences.muted },
                    set: changeMute
                ))
                .disabled(savingMute)

                Toggle(PalmiL10n.tr("bionic.chatPinned"), isOn: Binding(
                    get: { preferences.pinned },
                    set: changePin
                ))
                .disabled(savingPin)
            }

            Section {
                NavigationLink {
                    BionicChatBackgroundScreen(
                        store: store, instance: instance,
                        aspect: store.chatCanvasAspects[instance] ?? (9.0 / 16.0)
                    )
                } label: {
                    Label(PalmiL10n.tr("bionic.chatBackground"), systemImage: "photo")
                }
            }

            Section {
                NavigationLink {
                    BionicMigrationScreen(store: store, instance: instance)
                } label: {
                    Label(PalmiL10n.tr("bionic.migration"), systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("bionic.conversationDetails"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if developerVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        BionicDeveloperScreen(store: store, instance: instance)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(PalmiL10n.tr("bionic.developer"))
                }
            }
        }
        .task {
            await store.refresh(changed: instance)
            let binding = try? await store.archive.binding(instance)
            developerVisible = binding?["developer_visible"]?.bool ?? true
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) { }
        } message: { Text(error ?? "") }
    }

    private func changeTiming(_ raw: String) {
        guard !savingTiming, let timing = BionicReplyTiming(rawValue: raw),
              timing != BionicReplyTiming.resolve(role?.persona ?? [:]) else { return }
        savingTiming = true
        Task { @MainActor in
            defer { savingTiming = false }
            do { try await store.setReplyTiming(instance, timing: timing) }
            catch { self.error = BionicStore.errorText(error) }
        }
    }

    private func changeMute(_ value: Bool) {
        guard !savingMute else { return }
        savingMute = true
        Task { @MainActor in
            defer { savingMute = false }
            do { try await store.setChatMuted(instance, value) }
            catch { self.error = BionicStore.errorText(error) }
        }
    }

    private func changePin(_ value: Bool) {
        guard !savingPin else { return }
        savingPin = true
        Task { @MainActor in
            defer { savingPin = false }
            do { try await store.setChatPinned(instance, value) }
            catch { self.error = BionicStore.errorText(error) }
        }
    }
}
