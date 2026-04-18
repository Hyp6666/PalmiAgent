import Foundation
import Observation

enum ToolManagementSectionID: String, CaseIterable, Identifiable, Codable, Sendable {
    case app
    case nonApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app:
            return "APP 类"
        case .nonApp:
            return "非 APP 类"
        }
    }
}

struct ToolManagementSectionDefinition: Identifiable, Hashable, Sendable {
    let id: ToolManagementSectionID
    let title: String
}

enum ToolManagementGroupID: String, CaseIterable, Identifiable, Codable, Sendable {
    case calendar
    case reminders
    case contacts
    case timeAlarms
    case mapsLocation
    case cameraPhotos
    case scanRecognition
    case notificationsSpeech
    case communication
    case systemEntrypoints
    case workspaceFiles
    case scriptSandboxes
    case webResearch

    var id: String { rawValue }
}

struct ToolManagementGroupDefinition: Identifiable, Hashable, Sendable {
    let id: ToolManagementGroupID
    let sectionID: ToolManagementSectionID
    let title: String
    let subtitle: String
    let actionIDs: [ToolActionID]
}

enum ToolManagementCatalog {
    static let sections: [ToolManagementSectionDefinition] = [
        .init(id: .app, title: "APP 类"),
        .init(id: .nonApp, title: "非 APP 类")
    ]

    static let groups: [ToolManagementGroupDefinition] = [
        .init(
            id: .calendar,
            sectionID: .app,
            title: "日历",
            subtitle: "事件创建与读取",
            actionIDs: [.createCalendarEvent, .listTodayEvents]
        ),
        .init(
            id: .reminders,
            sectionID: .app,
            title: "提醒事项",
            subtitle: "提醒创建与读取",
            actionIDs: [.createReminder, .listReminders]
        ),
        .init(
            id: .contacts,
            sectionID: .app,
            title: "通讯录",
            subtitle: "联系人写入与搜索",
            actionIDs: [.createContact, .searchContacts]
        ),
        .init(
            id: .timeAlarms,
            sectionID: .app,
            title: "时间与闹钟",
            subtitle: "当前时间、系统闹钟、倒计时",
            actionIDs: [.getCurrentDateTime, .requestAlarmPermission, .listAlarms, .createAlarm, .createClockTimer, .manageAlarm]
        ),
        .init(
            id: .mapsLocation,
            sectionID: .app,
            title: "地图与定位",
            subtitle: "定位、附近搜索、路线",
            actionIDs: [.requestLocation, .searchNearbyPlaces, .openMapsRoute]
        ),
        .init(
            id: .cameraPhotos,
            sectionID: .app,
            title: "相机与照片",
            subtitle: "拍照、选图、生成图片",
            actionIDs: [.openCamera, .openPhotoLibrary, .saveGeneratedPhoto]
        ),
        .init(
            id: .scanRecognition,
            sectionID: .app,
            title: "扫描与识别",
            subtitle: "文档扫描与实时文字识别",
            actionIDs: [.scanDocument, .scanLiveText]
        ),
        .init(
            id: .notificationsSpeech,
            sectionID: .app,
            title: "通知与语音",
            subtitle: "通知、语音授权、朗读",
            actionIDs: [.requestNotificationPermission, .sendLocalNotification, .requestSpeechPermission, .speakText]
        ),
        .init(
            id: .communication,
            sectionID: .app,
            title: "通信能力",
            subtitle: "邮件、短信、电话、FaceTime",
            actionIDs: [.openMailDraft, .openMessageDraft, .callPhoneNumber, .openFaceTime]
        ),
        .init(
            id: .systemEntrypoints,
            sectionID: .app,
            title: "系统入口",
            subtitle: "设置、内容应用、Spotlight、Handoff",
            actionIDs: [.openAppSettings, .openAppStore, .openPodcasts, .openBooks, .openTV, .indexWorkspaceToSpotlight, .clearSpotlightIndex, .appIntentsDiagnostics, .publishHandoffActivity]
        ),
        .init(
            id: .workspaceFiles,
            sectionID: .nonApp,
            title: "工作区文件",
            subtitle: "目录、文件读写、导出",
            actionIDs: [.bootstrapWorkspace, .writeFile, .read, .listWorkspaceFiles, .exportWorkspace]
        ),
        .init(
            id: .scriptSandboxes,
            sectionID: .nonApp,
            title: "脚本与沙盒",
            subtitle: "能力边界、终端、JS、Python",
            actionIDs: [.inspectSandboxCapabilities, .runSandboxTerminal, .runJavaScriptSandbox, .pythonSandbox]
        ),
        .init(
            id: .webResearch,
            sectionID: .nonApp,
            title: "网页研究",
            subtitle: "搜索、抓取、浏览、落盘",
            actionIDs: [.searchWeb, .fetchStaticWebPage, .fetchWebBatch, .saveWebPageToWorkspace, .openInAppBrowser]
        )
    ]

    static func groups(in sectionID: ToolManagementSectionID) -> [ToolManagementGroupDefinition] {
        groups.filter { $0.sectionID == sectionID }
    }

    static func group(for groupID: ToolManagementGroupID) -> ToolManagementGroupDefinition {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            preconditionFailure("Missing tool management group for \(groupID.rawValue)")
        }
        return group
    }
}

@MainActor
@Observable
final class ToolPermissionStore {
    private let userDefaults: UserDefaults
    private let defaultsKey = "PalmiAgent.disabled_tool_action_ids.v1"

    private var disabledActionIDs: Set<ToolActionID> = []

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    func isEnabled(_ actionID: ToolActionID) -> Bool {
        !disabledActionIDs.contains(actionID)
    }

    func setEnabled(_ enabled: Bool, for actionID: ToolActionID) {
        if enabled {
            disabledActionIDs.remove(actionID)
        } else {
            disabledActionIDs.insert(actionID)
        }
        persist()
    }

    func isEnabled(_ groupID: ToolManagementGroupID) -> Bool {
        let group = ToolManagementCatalog.group(for: groupID)
        return group.actionIDs.allSatisfy(isEnabled(_:))
    }

    func isPartiallyEnabled(_ groupID: ToolManagementGroupID) -> Bool {
        let group = ToolManagementCatalog.group(for: groupID)
        let enabledCount = group.actionIDs.filter(isEnabled(_:)).count
        return enabledCount > 0 && enabledCount < group.actionIDs.count
    }

    func setEnabled(_ enabled: Bool, for groupID: ToolManagementGroupID) {
        let group = ToolManagementCatalog.group(for: groupID)
        for actionID in group.actionIDs {
            if enabled {
                disabledActionIDs.remove(actionID)
            } else {
                disabledActionIDs.insert(actionID)
            }
        }
        persist()
    }

    func enabledCount(in groupID: ToolManagementGroupID) -> Int {
        ToolManagementCatalog.group(for: groupID).actionIDs.filter(isEnabled(_:)).count
    }

    func actionCount(in groupID: ToolManagementGroupID) -> Int {
        ToolManagementCatalog.group(for: groupID).actionIDs.count
    }

    func enabledActionCount(in actions: [ToolAction]) -> Int {
        actions.filter { isEnabled($0.id) }.count
    }

    func enabledActions(from actions: [ToolAction]) -> [ToolAction] {
        actions.filter { isEnabled($0.id) }
    }

    private func load() {
        let rawValues = userDefaults.stringArray(forKey: defaultsKey) ?? []
        disabledActionIDs = Set(rawValues.compactMap(ToolActionID.init(rawValue:)))
    }

    private func persist() {
        let rawValues = disabledActionIDs.map(\.rawValue).sorted()
        userDefaults.set(rawValues, forKey: defaultsKey)
    }
}
