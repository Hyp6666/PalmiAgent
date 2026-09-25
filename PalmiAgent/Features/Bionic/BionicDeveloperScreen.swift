import SwiftUI
import UIKit

struct BionicDeveloperScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var limit = 40
    @State private var actionRevision = 0
    @State private var submitting = false
    @State private var feedback: String?
    @State private var error: String?
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: PalmiL10n.tr("bionic.developer"), revision: store.diagnosticRevision &+ actionRevision,
            load: { try await store.archive.inspectorDashboard(instance, limit: limit) }) { data in
            Section(t("overview")) {
                LabeledContent(t("messages"), value: String(data.int("message_count")))
                LabeledContent(t("unanswered"), value: String(data.int("pending_reply_count")))
                NavigationLink { BionicReadableStateScreen(store: store, instance: instance) } label: {
                    Label(t("currentState"), systemImage: "list.bullet.rectangle")
                }
            }
            Section(t("context")) {
                NavigationLink { BionicContextPreviewScreen(store: store, instance: instance) }
                    label: { Label(t("inputPreview"), systemImage: "text.alignleft") }
                NavigationLink { BionicSummaryScreen(store: store, instance: instance) }
                    label: { Label(t("summary"), systemImage: "doc.text") }
                NavigationLink { BionicMemoryInspectorScreen(store: store, instance: instance) }
                    label: { Label(t("memories"), systemImage: "brain") }
                Button {
                    submitting = true; feedback = nil; error = nil
                    Task {
                        defer { submitting = false }
                        do {
                            let queued = try await store.coordinator.compactNow(instance)
                            feedback = t(queued ? "compactQueued" : "noNewMessages")
                            actionRevision += 1
                        } catch { self.error = BionicInspectorLabel.error(error) }
                    }
                } label: {
                    HStack { Label(t("compact"), systemImage: "arrow.down.right.and.arrow.up.left"); Spacer(); if submitting { ProgressView() } }
                }.disabled(submitting)
                if !data.object("latest_compaction").isEmpty {
                    let latest = data.object("latest_compaction")
                    NavigationLink {
                        BionicOperationScreen(store: store, instance: instance, operationID: latest.text("operation_id"))
                    } label: { LabeledContent(t("latestCompaction"), value: BionicInspectorLabel.phase(latest.text("phase"))) }
                }
                if let feedback { Text(feedback).foregroundStyle(.secondary) }
            }
            Section(t("delivery")) {
                NavigationLink { BionicOutboxScreen(store: store, instance: instance) } label: {
                    LabeledContent(t("scheduledMessages"), value: String(data.int("pending_delivery_count")))
                }
                NavigationLink { BionicNotificationScreen(store: store, instance: instance) }
                    label: { Label(t("notifications"), systemImage: "bell.badge") }
            }
            Section(t("activity")) {
                ForEach(data.records("operations"), id: \.inspectorID) { record in
                    NavigationLink { BionicOperationScreen(store: store, instance: instance, operationID: record.text("operation_id")) } label: {
                        BionicOperationRow(record: record)
                    }
                }
                if data.records("operations").isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
                if data.records("operations").count < data.int("operation_count") {
                    Button(PalmiL10n.tr("bionic.loadMore")) { limit += 40; actionRevision += 1 }
                }
                NavigationLink { BionicTransactionScreen(store: store, instance: instance) }
                    label: { Label(t("eventLog"), systemImage: "clock.arrow.circlepath") }
            }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
    }
}

private struct BionicOperationRow: View {
    let record: BionicObject
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(BionicInspectorLabel.kind(record.text("kind")))
                Spacer()
                Text(BionicInspectorLabel.phase(record.optionalText("display_phase") ?? record.text("phase"))).font(.caption).foregroundStyle(.secondary)
            }
            Text(BionicInspectorLabel.time(record.text("created_at"))).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BionicReadableStateScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: t("currentState"), revision: store.diagnosticRevision, load: {
            var state = try await store.archive.inspectionState(instance)
            state["activity"] = .records(try await store.archive.inspectionOperations(instance, limit: Int.max).records)
            return state
        }) { data in
            let persona = data.object("persona"), state = data.object("runtime_state")
            Section {
                LabeledContent(PalmiL10n.tr("bionic.nickname"), value: persona.text("nickname"))
                LabeledContent(PalmiL10n.tr("bionic.nativeLanguage"), value: BionicPersonaCatalog.languageNames[persona.text("native_language")] ?? persona.text("native_language"))
                LabeledContent(PalmiL10n.tr("bionic.birthDate"), value: persona.text("birth_date"))
                LabeledContent(PalmiL10n.tr("bionic.replyTiming"), value: PalmiL10n.tr("bionic.replyTiming." + BionicReplyTiming.resolve(persona).rawValue))
            }
            Section(t("overview")) {
                LabeledContent(t("messages"), value: String(state.records("message_order").count))
                LabeledContent(t("summarizedThrough"), value: String(state.object("compaction_cursor").int("message_sequence")))
                LabeledContent(t("confirmed"), value: String(data.records("confirmed_memory_revisions").filter { $0.text("status") == "active" }.count))
                LabeledContent(t("awaitingConfirmation"), value: String(state.records("staged_memory_revisions").count))
            }
            Section(PalmiL10n.tr("bionic.personality")) {
                ForEach(BionicPersonaCatalog.dimensions, id: \.self) { dimension in
                    LabeledContent(PalmiL10n.tr("bionic.trait." + dimension),
                        value: PalmiL10n.tr("bionic.trait.\(dimension).\(persona.object("current_traits").int(dimension))"))
                }
            }
            Section(t("participants")) {
                ForEach(data.records("participants"), id: \.inspectorID) { person in
                    HStack {
                        Text(person.text("display_name")); Spacer()
                        if person.text("participant_id") == state.text("current_participant_id") { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
            Section(t("inProgress")) {
                let active = data.records("activity").filter { !["committed", "cancelled"].contains($0.text("phase")) }
                ForEach(active, id: \.inspectorID) { operation in
                    NavigationLink { BionicOperationScreen(store: store, instance: instance, operationID: operation.text("operation_id")) }
                        label: { BionicOperationRow(record: operation) }
                }
                if active.isEmpty { Text(t("idle")).foregroundStyle(.secondary) }
            }
            Section { BionicRawLink(value: .object(data)) }
        }
    }
}

private struct BionicContextPreviewScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    var body: some View {
        BionicInspectorPage(title: BionicInspectorLabel.text("inputPreview"), revision: store.diagnosticRevision, load: {
            let role = try await store.archive.loadRole(instance)
            let input = try await BionicPromptBuilder.daily(role, archive: store.archive, enforceBudget: false)
            return ["model_input": .object(input.json), "estimated_tokens": .count(try BionicPromptBuilder.estimatedTokens(input))]
        }) { data in
            BionicInputSections(input: BionicModelInput(data.object("model_input")), estimated: data.int("estimated_tokens"))
        }
    }
}
private struct BionicInputRecordScreen: View {
    let record: BionicObject
    var body: some View {
        List {
            if !record.text("prepared_at").isEmpty { LabeledContent(BionicInspectorLabel.text("requestPreparedAt"), value: BionicInspectorLabel.time(record.text("prepared_at"))) }
            if !record.text("model_label").isEmpty { LabeledContent(BionicInspectorLabel.text("model"), value: record.text("model_label")) }
            BionicInputSections(input: BionicModelInput(record.object("model_input")), estimated: nil, recordedTools: record["tool_definitions"] == nil ? nil : record.records("tool_definitions"), showRawInput: false)
            Section { BionicRawLink(value: .object(record)) }
        }.navigationTitle(BionicInspectorLabel.text("actualInput")).navigationBarTitleDisplayMode(.inline)
    }
}
private struct BionicInputSections: View {
    let input: BionicModelInput
    let estimated: Int?
    var recordedTools: [BionicObject]? = nil
    var showRawInput = true
    private var estimatedInput: Int {
        guard let recordedTools else { return (try? BionicPromptBuilder.estimatedTokens(input)) ?? 0 }
        let schema = recordedTools.compactMap { $0["parameters"] }
        let bytes = (try? BionicCodec.encode(.array(schema))) ?? Data()
        let images = input.messages.reduce(0) { $0 + $1.strings("image_assets").count }
        return ApproximateTokenCounter.estimate(chatMessages: BionicPromptBuilder.apiMessages(input))
            + ApproximateTokenCounter.estimate(String(decoding: bytes, as: UTF8.self)) + images * 4096 + 128
    }
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        Section {
            LabeledContent(t("estimatedInput"), value: String(estimated ?? estimatedInput))
            LabeledContent(PalmiL10n.tr("bionic.contextLimit"), value: String(input.contextLimit))
            if showRawInput { BionicRawLink(value: .object(input.json)) }
        }
        Section(t("tools")) {
            ForEach(input.toolNames, id: \.self) { name in
                let definition = recordedTools?.first { $0.text("name") == name }
                    ?? ["name": .string(name), "description": .string(BionicToolbox.descriptions[name] ?? ""), "parameters": BionicToolbox.schemas[name] ?? .null]
                NavigationLink(name) { BionicJSONScreen(title: name, value: .object(definition)) }
            }
        }
        Section(t("inputOrder")) {
            ForEach(Array(input.messages.enumerated()), id: \.offset) { pair in
                NavigationLink {
                    BionicContextModuleScreen(message: pair.element,
                        title: "\(pair.offset + 1) · \(BionicInspectorLabel.module(pair.element))")
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(pair.offset + 1) · \(BionicInspectorLabel.module(pair.element))")
                        if pair.element.text("module").isEmpty || ["instructions", "summary"].contains(pair.element.text("module")) {
                            Text(verbatim: pair.element.text("content")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}

private struct BionicSummaryScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: t("summary"), revision: store.diagnosticRevision, load: {
            try await store.archive.summary(instance) ?? [:]
        }) { record in
            if record.isEmpty { Text(t("noSummary")).foregroundStyle(.secondary) }
            else {
                Section { BionicMarkdownBody(text: record.text("text")).padding(.vertical, 6) }
                Section(t("recordInfo")) {
                    LabeledContent(t("updatedAt"), value: BionicInspectorLabel.time(record.text("recorded_at")))
                    LabeledContent(t("summarizedThrough"), value: String(record.object("to_cursor").int("message_sequence")))
                    NavigationLink(t("plainText")) { BionicTextDocument(title: t("summary"), text: record.text("text"), plain: true) }
                    if !record.text("source_operation_id").isEmpty {
                        NavigationLink(t("sourceActivity")) { BionicOperationScreen(store: store, instance: instance, operationID: record.text("source_operation_id")) }
                    }
                    BionicRawLink(value: .object(record))
                }
            }
        }
    }
}

private struct BionicMemoryInspectorScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var selection = "confirmed"
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: t("memories"), revision: store.diagnosticRevision,
            load: { try await store.archive.inspectorMemories(instance) }) { data in
            Section {
                Picker(t("status"), selection: $selection) {
                    Text(t("confirmed")).tag("confirmed")
                    Text(t("awaitingConfirmation")).tag("pending")
                    Text(t("deleted")).tag("deleted")
                }.pickerStyle(.segmented).labelsHidden()
            }
            Section {
                ForEach(data.records(selection), id: \.inspectorID) { memory in
                    NavigationLink { BionicMemoryRecordScreen(store: store, instance: instance, memory: memory) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(memory.text("title"))
                            Text(memory.text("content")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if selection == "pending" { Text(t(memory.object("previous_confirmed").isEmpty ? "newMemory" : "changedMemory")).font(.caption2).foregroundStyle(.tint) }
                        }
                    }
                }
                if data.records(selection).isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
            }
            Section { BionicRawLink(value: data[selection] ?? .array([])) }
        }
    }
}
private struct BionicMemoryRecordScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let memory: BionicObject
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: memory.text("title"), revision: 0,
            load: { try await store.archive.inspectorMemory(instance, memory: memory) }) { data in
            Section { BionicMarkdownBody(text: data.text("content")) }
            if !data.object("previous_confirmed").isEmpty {
                Section(t("previousContent")) { BionicMarkdownBody(text: data.object("previous_confirmed").text("content")) }
            }
            Section(t("recordInfo")) {
                LabeledContent(t("updatedAt"), value: BionicInspectorLabel.time(data.text("recorded_at")))
                LabeledContent(t("status"), value: t(data["previous_confirmed"] != nil ? (data.text("status") == "deleted" ? "pendingDelete" : "awaitingConfirmation") : (data.text("status") == "deleted" ? "deleted" : "confirmed")))
            }
            Section(PalmiL10n.tr("bionic.sources")) {
                ForEach(data.records("sources"), id: \.inspectorID) { source in
                    BionicRecordTextRow(title: BionicInspectorLabel.time(source.text("logical_at")), text: source.text("body"), raw: .object(source))
                }
                if data.records("sources").isEmpty { Text(PalmiL10n.tr("bionic.sourceMissing")).foregroundStyle(.secondary) }
            }
            Section { BionicRawLink(value: .object(data)) }
        }
    }
}

private struct BionicOutboxScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var filter = "pending"
    @State private var limit = 60
    @State private var revision = 0
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: t("scheduledMessages"), revision: store.diagnosticRevision &+ revision,
            load: { try await store.archive.inspectorDeliveries(instance, state: filter, limit: limit) }) { data in
            Section {
                Picker(t("status"), selection: $filter) {
                    Text(t("waiting")).tag("pending"); Text(t("sent")).tag("committed"); Text(t("cancelled")).tag("cancelled")
                }.pickerStyle(.segmented).labelsHidden()
            }
            Section {
                ForEach(data.records("rows"), id: \.inspectorID) { item in
                    NavigationLink { BionicDeliveryRecordScreen(store: store, instance: instance, messageID: item.text("message_id")) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(t(item.text("delivery_kind") == "reply" ? "reply" : "proactive")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(BionicInspectorLabel.delivery(item.text("state"))).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.text("body")).lineLimit(3)
                            Text(t("generatedAt") + " · " + BionicInspectorLabel.time(item.text("generated_at"))).font(.caption2).foregroundStyle(.secondary)
                            Text(t("plannedAt") + " · " + BionicInspectorLabel.time(item.text("planned_at"))).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if data.records("rows").isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
                if data.records("rows").count < data.int("total") {
                    Button(PalmiL10n.tr("bionic.loadMore")) { limit += 60; revision += 1 }
                }
            }
        }
        .onChange(of: filter) { _, _ in limit = 60; revision += 1 }
    }
}
private struct BionicDeliveryRecordScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let messageID: String
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: t("message"), revision: store.diagnosticRevision,
            load: { try await store.archive.inspectorDelivery(instance, messageID: messageID) }) { data in
            Section { BionicMarkdownBody(text: data.text("body")) }
            Section(t("timing")) {
                LabeledContent(t("status"), value: BionicInspectorLabel.delivery(data.text("state")))
                LabeledContent(t("generatedAt"), value: BionicInspectorLabel.time(data.text("generated_at")))
                LabeledContent(t("plannedAt"), value: BionicInspectorLabel.time(data.text("planned_at")))
                if !data.object("message").isEmpty {
                    LabeledContent(t("committedAt"), value: BionicInspectorLabel.time(data.object("message").text("committed_at")))
                }
                if !data.text("cancelled_at").isEmpty {
                    LabeledContent(t("cancelledAt"), value: BionicInspectorLabel.time(data.text("cancelled_at")))
                    LabeledContent(t("reason"), value: BionicInspectorLabel.reason(data.text("cancel_reason")))
                }
            }
            Section {
                if !data.object("group").text("source_operation_id").isEmpty {
                    NavigationLink(t("sourceActivity")) {
                        BionicOperationScreen(store: store, instance: instance, operationID: data.object("group").text("source_operation_id"))
                    }
                }
                BionicRawLink(value: .object(data))
            }
        }
    }
}

private struct BionicNotificationScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var busy = false
    @State private var revision = 0
    @State private var logLimit = 40
    @State private var error: String?
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: t("notifications"), revision: store.diagnosticRevision &+ revision, load: {
            var data = await store.notifications.diagnostics()
            let local = try await store.archive.binding(instance)
            data["local"] = .object(["notifications_enabled": local["notifications_enabled"] ?? .bool(false)])
            data["history"] = .object(try await store.archive.inspectorNotificationHistory(instance, limit: logLimit))
            return data
        }) { data in
            Section {
                Toggle(t("allowNotifications"), isOn: Binding(get: { data.object("local").flag("notifications_enabled") }, set: { enabled in
                    busy = true
                    Task {
                        defer { busy = false; revision += 1 }
                        do { try await store.notifications.enable(instance, enabled: enabled); error = nil }
                        catch { self.error = BionicInspectorLabel.error(error) }
                    }
                })).disabled(busy)
                LabeledContent(t("applicationBadge"), value: String(data.int("badge_count")))
            }
            Section(t("permissions")) {
                let settings = data.object("system_settings")
                LabeledContent(t("authorization"), value: BionicInspectorLabel.permission(settings.text("authorization")))
                LabeledContent(t("banners"), value: BionicInspectorLabel.permission(settings.text("alert_setting")))
                LabeledContent(t("lockScreen"), value: BionicInspectorLabel.permission(settings.text("lock_screen_setting")))
                LabeledContent(t("sound"), value: BionicInspectorLabel.permission(settings.text("sound_setting")))
                LabeledContent(t("applicationBadge"), value: BionicInspectorLabel.permission(settings.text("badge_setting")))
                Button(t("systemSettings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button(t("reconcile")) { Task { await store.notifications.reconcile(); revision += 1 } }
            }
            Section(t("registered")) {
                let pending = data.records("pending").filter { $0.text("instance_id") == instance }
                ForEach(pending, id: \.inspectorID) { record in BionicNotificationRecordRow(record: record, pending: true) }
                if pending.isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
            }
            Section(t("notificationCenter")) {
                let delivered = data.records("delivered").filter { $0.text("instance_id") == instance }
                ForEach(delivered, id: \.inspectorID) { record in BionicNotificationRecordRow(record: record, pending: false) }
                if delivered.isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
            }
            Section(t("notificationHistory")) {
                let history = data.object("history")
                ForEach(history.records("rows"), id: \.inspectorID) { record in
                    NavigationLink {
                        List {
                            Text(record.text("body")).textSelection(.enabled)
                            LabeledContent(t("status"), value: BionicInspectorLabel.reason(record.text("result")))
                            LabeledContent(t("recordedAt"), value: BionicInspectorLabel.time(record.text("observed_at")))
                            if !record.text("planned_at").isEmpty { LabeledContent(t("plannedAt"), value: BionicInspectorLabel.time(record.text("planned_at"))) }
                            BionicRawLink(value: record["record"] ?? .null)
                        }.navigationTitle(t("notificationRecord"))
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(BionicInspectorLabel.reason(record.text("result")))
                            if !record.text("body").isEmpty { Text(record.text("body")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Text(BionicInspectorLabel.time(record.text("observed_at"))).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if history.flag("has_more") { Button(PalmiL10n.tr("bionic.loadMore")) { logLimit += 40; revision += 1 } }
                if history.records("rows").isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
            }
            if let lastError = data.optionalText("last_error") { Section(t("lastError")) { Text(lastError).textSelection(.enabled) } }
            if let error { Text(error).foregroundStyle(.red) }
            Section { BionicRawLink(value: .object(data)) }
        }
    }
}
private struct BionicNotificationRecordRow: View {
    let record: BionicObject
    let pending: Bool
    var body: some View {
        NavigationLink {
            List {
                BionicMarkdownBody(text: record.text("body"))
                LabeledContent(BionicInspectorLabel.text(pending ? "plannedAt" : "systemDeliveredAt"),
                    value: BionicInspectorLabel.time(record.text(pending ? "scheduled_at" : "delivered_at")))
                LabeledContent(BionicInspectorLabel.text("applicationBadge"), value: String(record.int("badge")))
                BionicRawLink(value: .object(record))
            }.navigationTitle(record.text("title"))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.text("body")).lineLimit(3)
                Text(BionicInspectorLabel.time(record.text(pending ? "scheduled_at" : "delivered_at"))).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BionicOperationScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let operationID: String
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        BionicInspectorPage(title: t("activityDetails"), revision: store.diagnosticRevision,
            load: { try await store.archive.inspectorOperation(instance, operationID: operationID) }) { data in
            let request = data.object("request")
            let root = data.records("checkpoints").first { $0.text("step_id") == "root" } ?? [:]
            let pending = data.records("delivery_groups").flatMap { $0.records("items") }.filter { data.object("delivery_states").text($0.text("message_id")) == "pending" }.count
            Section {
                LabeledContent(t("task"), value: BionicInspectorLabel.kind(request.text("kind")))
                LabeledContent(t("status"), value: BionicInspectorLabel.phase(data.text("display_phase")))
                LabeledContent(t("startedAt"), value: BionicInspectorLabel.time(request.text("created_at")))
                if pending > 0 {
                    NavigationLink { BionicOutboxScreen(store: store, instance: instance) } label: {
                        LabeledContent(t("waiting"), value: String(pending))
                    }
                }
                if request.text("kind") == "compaction" {
                    LabeledContent(t("coverage"), value: "\(data.int("first_message_number")) — \(data.int("last_message_number"))")
                }
            }
            Section(t("progress")) {
                let points = data.records("checkpoints").filter { $0.text("step_id") != "root" }
                ForEach(Array(points.enumerated()), id: \.offset) { pair in
                    HStack {
                        Image(systemName: pair.element.text("phase") == "committed" ? "checkmark.circle.fill" : (pair.element.text("phase") == "paused" ? "exclamationmark.circle" : "circle.dotted"))
                            .foregroundStyle(pair.element.text("phase") == "paused" ? Color.orange : Color.secondary)
                        Text((request.text("kind") == "compaction" ? t("compactSegment") :
                              request.text("kind") == "planning" ? t("planning") :
                              request.text("kind") == "evolution" ? t("evolution") : t("modelAction")) + " \(pair.offset + 1)")
                        Spacer()
                        Text(BionicInspectorLabel.phase(pair.element.text("phase"))).foregroundStyle(.secondary)
                    }
                }
                if points.isEmpty { Text(BionicInspectorLabel.phase(root.text("phase"))).foregroundStyle(.secondary) }
            }
            Section(t("results")) {
                let results = data.records("results")
                ForEach(Array(results.enumerated()), id: \.offset) { entry in
                    let result = entry.element
                    NavigationLink { BionicResultScreen(store: store, instance: instance, result: result) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(t("response") + " \(entry.offset + 1)")
                                Spacer(); Text(BionicInspectorLabel.phase(result.text("status"))).foregroundStyle(.secondary)
                            }
                            Text(BionicInspectorLabel.time(result.text("received_at"))).font(.caption).foregroundStyle(.secondary)
                            let effect = result.object("payload").object("accepted_effect")
                            let preview = effect.object("summary").text("text").isEmpty
                                ? (effect.records("messages").first?.text("text") ?? effect.records("groups").first?.records("items").first?.text("body") ?? "")
                                : effect.object("summary").text("text")
                            if !preview.isEmpty { Text(preview).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                            if let code = result.optionalText("error_code") { Text(PalmiL10n.tr("bionic.error." + code)).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
                if results.isEmpty { Text(t("noResultYet")).foregroundStyle(.secondary) }
            }
            Section(t("actualInputs")) {
                let attempts = data.records("steps").filter { !$0.text("prepared_at").isEmpty }
                ForEach(Array(attempts.enumerated()), id: \.offset) { pair in
                    NavigationLink { BionicInputRecordScreen(record: pair.element) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(t("request") + " \(pair.offset + 1) · " + pair.element.text("model_label"))
                            Text(BionicInspectorLabel.time(pair.element.text("prepared_at"))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if attempts.isEmpty { Text(t("notRequestedYet")).foregroundStyle(.secondary) }
            }
            Section { BionicRawLink(value: .object(data)) }
        }
    }
}
private struct BionicResultScreen: View {
    let store: BionicStore
    let instance: String
    let result: BionicObject
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        List {
            let effect = result.object("payload").object("accepted_effect")
            let usage = result.object("token_usage")
            Section {
                LabeledContent(t("status"), value: BionicInspectorLabel.phase(result.text("status")))
                LabeledContent(t("generatedAt"), value: BionicInspectorLabel.time(result.text("received_at")))
                if !result.text("tool_name").isEmpty { LabeledContent(t("tool"), value: result.text("tool_name")) }
            }
            if let code = result.optionalText("error_code") {
                Section(t("failure")) {
                    Text(PalmiL10n.tr("bionic.error." + code)).foregroundStyle(.red)
                    if !result.text("error_detail").isEmpty {
                        BionicRecordTextRow(title: t("details"), text: result.text("error_detail"), raw: result["diagnostics"])
                    }
                }
            }
            if !effect.text("summary").isEmpty { Section(t("summary")) { BionicMarkdownBody(text: effect.text("summary")) } }
            if !effect.object("summary").isEmpty { Section(t("summary")) { BionicMarkdownBody(text: effect.object("summary").text("text")) } }
            if !effect.records("messages").isEmpty {
                Section(t("preparedContent")) {
                    ForEach(Array(effect.records("messages").enumerated()), id: \.offset) { pair in
                        BionicRecordTextRow(title: t("message") + " \(pair.offset + 1)", text: pair.element.text("text"), raw: .object(pair.element))
                    }
                }
            }
            if !effect.records("memory_revisions").isEmpty {
                Section(t("memoryChanges")) {
                    ForEach(effect.records("memory_revisions"), id: \.inspectorID) { memory in
                        BionicRecordTextRow(title: memory.text("title"), text: memory.text("content"), raw: .object(memory))
                    }
                }
            }
            if !effect.records("groups").isEmpty {
                Section(t("scheduledMessages")) {
                    ForEach(effect.records("groups").flatMap { $0.records("items") }, id: \.inspectorID) { item in
                        BionicRecordTextRow(title: BionicInspectorLabel.time(item.text("planned_at")), text: item.text("body"), raw: .object(item))
                    }
                }
            }
            if result.text("tool_name") == "planning" && effect.records("groups").isEmpty && result.text("status") == "valid" {
                Section { Text(t("noFollowup")).foregroundStyle(.secondary) }
            }
            if !effect.object("tool_result").records("items").isEmpty {
                Section(t("recalled")) {
                    ForEach(Array(effect.object("tool_result").records("items").enumerated()), id: \.offset) { pair in
                        BionicRecordTextRow(title: t("record") + " \(pair.offset + 1)",
                            text: pair.element.text("body").isEmpty ? pair.element.text("content") : pair.element.text("body"), raw: .object(pair.element))
                    }
                }
            }
            if !effect.records("changes").isEmpty {
                Section(PalmiL10n.tr("bionic.personality")) {
                    ForEach(Array(effect.records("changes").enumerated()), id: \.offset) { pair in
                        LabeledContent(PalmiL10n.tr("bionic.trait." + pair.element.text("dimension")), value: String(pair.element.int("target_level")))
                    }
                }
            }
            if !usage.isEmpty {
                Section(t("usage")) {
                    LabeledContent(t("inputTokens"), value: usage["input_tokens"]?.int.map(String.init) ?? "—")
                    LabeledContent(t("outputTokens"), value: usage["output_tokens"]?.int.map(String.init) ?? "—")
                    LabeledContent(t("cacheTokens"), value: usage["cached_input_tokens"]?.int.map(String.init) ?? "—")
                }
            }
            Section { BionicRawLink(value: .object(result)) }
        }.navigationTitle(t("response")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct BionicTransactionScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var limit = 60
    @State private var revision = 0
    var body: some View {
        BionicInspectorPage(title: BionicInspectorLabel.text("eventLog"), revision: store.diagnosticRevision &+ revision, load: {
            let page = try await store.archive.inspectionTransactions(instance, limit: limit)
            return ["rows": .records(page.records), "total": .count(page.total)]
        }) { data in
            ForEach(data.records("rows"), id: \.inspectorID) { row in
                NavigationLink {
                    BionicEventRecordScreen(store: store, instance: instance, path: row.text("path"))
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.strings("event_types").map(BionicInspectorLabel.event).joined(separator: " · ")).lineLimit(2)
                        Text(BionicInspectorLabel.time(row.text("recorded_at"))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if data.records("rows").isEmpty { Text(BionicInspectorLabel.text("empty")).foregroundStyle(.secondary) }
            if data.records("rows").count < data.int("total") {
                Button(PalmiL10n.tr("bionic.loadMore")) { limit += 60; revision += 1 }
            }
        }
    }
}
private struct BionicEventRecordScreen: View {
    let store: BionicStore
    let instance: String
    let path: String
    var body: some View {
        BionicInspectorPage(title: BionicInspectorLabel.text("event"), revision: 0,
            load: { try await store.archive.inspectorEvent(instance, path: path) }) { data in
            LabeledContent(BionicInspectorLabel.text("recordedAt"), value: BionicInspectorLabel.time(data.object("record").text("recorded_at")))
            ForEach(Array(data.records("events").enumerated()), id: \.offset) { pair in
                Section(BionicInspectorLabel.event(pair.element.text("type"))) {
                    let payload = pair.element.object("payload")
                    if !pair.element.object("message").isEmpty { BionicMarkdownBody(text: pair.element.object("message").text("body")) }
                    if !pair.element.object("summary").isEmpty { BionicMarkdownBody(text: pair.element.object("summary").text("text")) }
                    if !pair.element.object("memory").isEmpty {
                        Text(pair.element.object("memory").text("title")).font(.headline)
                        BionicMarkdownBody(text: pair.element.object("memory").text("content"))
                    }
                    if !pair.element.object("persona").isEmpty { Text(pair.element.object("persona").text("nickname")) }
                    ForEach(payload.records("groups").flatMap { $0.records("items") }, id: \.inspectorID) { item in
                        BionicRecordTextRow(title: BionicInspectorLabel.time(item.text("planned_at")), text: item.text("body"), raw: .object(item))
                    }
                    if !payload.text("phase").isEmpty { Text(BionicInspectorLabel.phase(payload.text("phase"))) }
                    if !payload.text("reason").isEmpty { Text(BionicInspectorLabel.reason(payload.text("reason"))) }
                    if !payload.text("result").isEmpty { Text(BionicInspectorLabel.reason(payload.text("result"))) }
                    if !payload.object("details").text("body").isEmpty { Text(payload.object("details").text("body")).textSelection(.enabled) }
                    if !payload.object("details").text("deliver_at").isEmpty {
                        LabeledContent(BionicInspectorLabel.text("plannedAt"), value: BionicInspectorLabel.time(payload.object("details").text("deliver_at")))
                    }
                    if !payload.strings("message_ids").isEmpty {
                        LabeledContent(BionicInspectorLabel.text("messages"), value: String(payload.strings("message_ids").count))
                    }
                    BionicRawLink(value: .object(pair.element))
                }
            }
            Section { BionicRawLink(value: data["record"] ?? .null) }
        }
    }
}

nonisolated extension Dictionary where Key == String, Value == BionicJSON {
    var inspectorID: String {
        for key in ["identifier", "path", "result_id", "memory_revision_id", "message_id", "operation_id", "participant_id", "group_id"] {
            if let value = optionalText(key), !value.isEmpty { return value }
        }
        return (try? BionicCodec.hash(self)) ?? ""
    }
}


private struct BionicContextModuleScreen: View {
    let message: BionicObject
    let title: String
    private var content: String { message.text("content") }
    private var module: String { message.text("module") }
    private var data: BionicObject { BionicModuleContent.object(in: content) ?? [:] }
    private func t(_ key: String) -> String { BionicInspectorLabel.text(key) }
    var body: some View {
        List {
            switch module {
            case "persona" where !data.isEmpty:
                Section {
                    LabeledContent(PalmiL10n.tr("bionic.nickname"), value: data.text("nickname"))
                    LabeledContent(PalmiL10n.tr("bionic.birthDate"), value: data.text("birth_date"))
                    LabeledContent(PalmiL10n.tr("bionic.nativeLanguage"), value: BionicPersonaCatalog.languageNames[data.text("native_language")] ?? data.text("native_language"))
                    LabeledContent(PalmiL10n.tr("bionic.gender"), value: gender)
                }
                Section(PalmiL10n.tr("bionic.identity")) { BionicMarkdownBody(text: data.text("identity")) }
                if !data.text("background").isEmpty {
                    Section(PalmiL10n.tr("bionic.background")) { BionicMarkdownBody(text: data.text("background")) }
                }
                Section(PalmiL10n.tr("bionic.personality")) {
                    ForEach(BionicPersonaCatalog.dimensions, id: \.self) { dimension in
                        LabeledContent(PalmiL10n.tr("bionic.trait." + dimension), value: data.object("traits").text(dimension))
                    }
                    if !data.text("mbti").isEmpty { LabeledContent("MBTI", value: data.text("mbti")) }
                    if !data.text("mbti_preference").isEmpty { Text(data.text("mbti_preference")) }
                }
            case "memory" where !data.isEmpty:
                Section(t("confirmed")) {
                    ForEach(Array(data.records("facts").enumerated()), id: \.offset) { item in
                        BionicMarkdownBody(text: item.element.text("fact"))
                    }
                    if data.records("facts").isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
                }
                if !data.records("manual_corrections").isEmpty {
                    Section(t("manualCorrections")) {
                        ForEach(Array(data.records("manual_corrections").enumerated()), id: \.offset) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(t(item.element.text("current_status") == "deleted" ? "deleted" : "confirmed")).font(.caption).foregroundStyle(.secondary)
                                if !item.element.text("current_fact").isEmpty { Text(item.element.text("current_fact")) }
                                else { Text(item.element.text("topic_key")) }
                            }
                        }
                    }
                }
            case "clock" where !data.isEmpty:
                Section {
                    LabeledContent(t("requestPreparedAt"), value: data.text("current_local_time"))
                    LabeledContent(t("earliestDelivery"), value: data.text("reply_not_before"))
                    LabeledContent(t("timeZone"), value: data.text("timezone"))
                    LabeledContent(t("deliveryWindow"), value: t(data.text("reply_window") == "quiet" ? "quietWindow" : "availableWindow"))
                    LabeledContent(t("ageYears"), value: String(data.int("age_completed_years")))
                }
            case "message_index" where !data.isEmpty:
                Section(t("participants")) {
                    ForEach(Array(data.records("participants").enumerated()), id: \.offset) { item in Text(item.element.text("name")) }
                }
                Section(t("messageIndex")) {
                    ForEach(Array(data.records("messages").enumerated()), id: \.offset) { item in
                        HStack(alignment: .top) {
                            Text("\(item.element.int("position"))").monospacedDigit().foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(author(item.element.text("author")))
                                Text(item.element.text("sent_at")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !data.records("quoted_history").isEmpty {
                    Section(t("quotedHistory")) {
                        ForEach(Array(data.records("quoted_history").enumerated()), id: \.offset) { item in
                            BionicMarkdownBody(text: item.element.text("text"))
                        }
                    }
                }
                Section(t("unanswered")) {
                    LabeledContent(t("messages"), value: String(data.strings("pending_user_message_ids").count))
                    ForEach(Array(data.records("summarized_pending_requests").enumerated()), id: \.offset) { item in
                        if !item.element.text("text").isEmpty { BionicMarkdownBody(text: item.element.text("text")) }
                    }
                }
            case "recalled_evidence" where !data.isEmpty:
                Section {
                    ForEach(Array(data.records("items").enumerated()), id: \.offset) { item in
                        BionicRecordTextRow(title: t("record") + " \(item.offset + 1)",
                            text: item.element.text("body").isEmpty ? item.element.text("content") : item.element.text("body"), raw: .object(item.element))
                    }
                    if data.records("items").isEmpty { Text(t("empty")).foregroundStyle(.secondary) }
                }
            case "reply_delivery_tail" where !data.isEmpty:
                Section {
                    ForEach(Array(data.records("times").enumerated()), id: \.offset) { item in
                        LabeledContent(t("message") + " \(item.offset + 1)", value: BionicInspectorLabel.time(item.element.text("planned_at")))
                    }
                }
            default:
                Section { BionicMarkdownBody(text: content) }
            }
            Section {
                NavigationLink(t("plainText")) { BionicTextDocument(title: title, text: content, plain: true) }
                BionicRawLink(value: .object(message))
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private var gender: String {
        let value = data.text("gender_kind")
        if value == "custom" { return data.text("gender_text") }
        return PalmiL10n.tr("bionic." + (["male", "female"].contains(value) ? value : "genderNone"))
    }
    private func author(_ id: String) -> String {
        data.records("participants").first { $0.text("id") == id }?.text("name") ?? t("roleMessage")
    }
}
