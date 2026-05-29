import Foundation
import Observation

enum ToolAuthorizationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case askEveryTime
    case allowAll
    case autoReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askEveryTime:
            "每次询问"
        case .allowAll:
            "全部同意"
        case .autoReview:
            "自动审查"
        }
    }
}

enum ToolApprovalResolution: Sendable {
    case rejected
    case approved
    case approvedForSession

    var isApproved: Bool {
        switch self {
        case .rejected:
            false
        case .approved, .approvedForSession:
            true
        }
    }
}

enum ToolSystemPermissionDomain: String, Codable, Sendable {
    case calendar
    case reminders
    case contacts
    case location
    case camera
    case photoLibrary
    case notifications
    case speechRecognition
    case spotlight

    var title: String {
        switch self {
        case .calendar:
            "日历"
        case .reminders:
            "提醒事项"
        case .contacts:
            "通讯录"
        case .location:
            "定位"
        case .camera:
            "相机"
        case .photoLibrary:
            "照片"
        case .notifications:
            "通知"
        case .speechRecognition:
            "语音识别"
        case .spotlight:
            "Spotlight"
        }
    }
}

struct ToolSystemPermissionRequirement: Hashable, Codable, Sendable {
    let domain: ToolSystemPermissionDomain
    let title: String
}

enum ToolSystemPermissionCatalog {
    static func requirements(for actionID: ToolActionID) -> [ToolSystemPermissionRequirement] {
        switch actionID {
        case .createCalendarEvent, .listTodayEvents:
            return [requirement(.calendar)]
        case .createReminder, .listReminders:
            return [requirement(.reminders)]
        case .createContact, .searchContacts:
            return [requirement(.contacts)]
        case .requestLocation, .searchNearbyPlaces, .openMapsRoute:
            return [requirement(.location)]
        case .openCamera, .scanDocument, .scanLiveText:
            return [requirement(.camera)]
        case .openPhotoLibrary, .saveGeneratedPhoto:
            return [requirement(.photoLibrary)]
        case .requestNotificationPermission, .sendLocalNotification:
            return [requirement(.notifications)]
        case .requestSpeechPermission, .speakText:
            return [requirement(.speechRecognition)]
        case .indexWorkspaceToSpotlight, .clearSpotlightIndex:
            return [requirement(.spotlight)]
        default:
            return []
        }
    }

    private static func requirement(_ domain: ToolSystemPermissionDomain) -> ToolSystemPermissionRequirement {
        ToolSystemPermissionRequirement(domain: domain, title: domain.title)
    }
}

@MainActor
@Observable
final class ToolAuthorizationStore {
    private let userDefaults: UserDefaults
    private let modeKey = "palmi.tool-authorization.mode.v1"
    private let sessionApprovalsKeyPrefix = "palmi.tool-authorization.session-approvals.v1"

    private var sessionApprovals: [UUID: Set<ToolActionID>] = [:]
    private(set) var mode: ToolAuthorizationMode = .askEveryTime

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadMode()
    }

    func setMode(_ mode: ToolAuthorizationMode) {
        self.mode = mode
        userDefaults.set(mode.rawValue, forKey: modeKey)
    }

    func isApproved(actionID: ToolActionID, in sessionID: UUID) -> Bool {
        approvedActionIDs(in: sessionID).contains(actionID)
    }

    func approve(actionID: ToolActionID, in sessionID: UUID) {
        var approvals = approvedActionIDs(in: sessionID)
        approvals.insert(actionID)
        sessionApprovals[sessionID] = approvals
        persistApprovals(approvals, for: sessionID)
    }

    func clearApprovals(in sessionID: UUID) {
        sessionApprovals[sessionID] = []
        userDefaults.removeObject(forKey: sessionApprovalsKey(for: sessionID))
    }

    func systemPermissionRequirements(for actionID: ToolActionID) -> [ToolSystemPermissionRequirement] {
        ToolSystemPermissionCatalog.requirements(for: actionID)
    }

    private func loadMode() {
        guard let rawValue = userDefaults.string(forKey: modeKey),
              let storedMode = ToolAuthorizationMode(rawValue: rawValue) else {
            mode = .askEveryTime
            return
        }
        mode = storedMode
    }

    private func approvedActionIDs(in sessionID: UUID) -> Set<ToolActionID> {
        if let cached = sessionApprovals[sessionID] {
            return cached
        }

        let rawValues = userDefaults.stringArray(forKey: sessionApprovalsKey(for: sessionID)) ?? []
        let approvals = Set(rawValues.compactMap(ToolActionID.init(rawValue:)))
        sessionApprovals[sessionID] = approvals
        return approvals
    }

    private func persistApprovals(_ approvals: Set<ToolActionID>, for sessionID: UUID) {
        userDefaults.set(
            approvals.map(\.rawValue).sorted(),
            forKey: sessionApprovalsKey(for: sessionID)
        )
    }

    private func sessionApprovalsKey(for sessionID: UUID) -> String {
        "\(sessionApprovalsKeyPrefix).\(sessionID.uuidString)"
    }
}
