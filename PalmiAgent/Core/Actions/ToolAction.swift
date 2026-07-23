import Foundation

enum ToolPresentationKind: String, Codable, Sendable {
    case data
    case action
    case interactive

    var title: String {
        switch self {
        case .data:
            PalmiL10n.tr("tool.presentation.data")
        case .action:
            PalmiL10n.tr("tool.presentation.action")
        case .interactive:
            PalmiL10n.tr("tool.presentation.interactive")
        }
    }
}

enum ToolActionID: String, CaseIterable, Codable, Hashable, Sendable {
    case fileRead
    case breakDownFile
    case fileWrite
    case fileAppend
    case listDirectory
    case fileManage
    case runPython
    case readSkill
    case importSkill
    case recognizeImageText
    case scanImageWithMultimodalModel
    case detectWebSearchProviders
    case searchWeb
    case fetchStaticWebPage
    case fetchWebBatch
    case saveWebPageToWorkspace
    case openInAppBrowser
    case createCalendarEvent
    case listTodayEvents
    case createReminder
    case listReminders
    case createContact
    case searchContacts
    case getCurrentDateTime
    case requestAlarmPermission
    case listAlarms
    case createAlarm
    case createClockTimer
    case manageAlarm
    case requestLocation
    case searchNearbyPlaces
    case openMapsRoute
    case openCamera
    case openPhotoLibrary
    case saveGeneratedPhoto
    case scanDocument
    case scanLiveText
    case requestNotificationPermission
    case sendLocalNotification
    case requestSpeechPermission
    case speakText
    case openMailDraft
    case openMessageDraft
    case callPhoneNumber
    case openFaceTime
    case openAppSettings
    case openAppStore
    case openPodcasts
    case openBooks
    case openTV
    case indexWorkspaceToSpotlight
    case clearSpotlightIndex
    case appIntentsDiagnostics
    case publishHandoffActivity

    var modelToolName: String {
        AgentExternalToolFacadeCatalog.canonicalToolName(for: self)
    }

    func matchesModelToolName(_ name: String) -> Bool {
        name == modelToolName || name == rawValue
    }

    var presentationKind: ToolPresentationKind {
        switch self {
        case .openMapsRoute,
             .openMailDraft,
             .openMessageDraft,
             .callPhoneNumber,
             .openFaceTime,
             .openAppSettings,
             .openAppStore,
             .openPodcasts,
             .openBooks,
             .openTV,
             .publishHandoffActivity:
            return .action

        case .openInAppBrowser,
             .openCamera,
             .openPhotoLibrary,
             .scanDocument,
             .scanLiveText:
            return .interactive

        default:
            return .data
        }
    }
}

struct ToolAction: Identifiable, Hashable, Sendable {
    let id: ToolActionID
    let category: ToolCategory
    let title: String
    let effect: String
    let details: String
    let availability: ToolAvailability
}
