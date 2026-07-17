import Foundation

enum ToolRiskLevel: Int, Codable, Sendable, Comparable {
    case r0TextOnly = 0
    case r1PublicRead = 1
    case r2LocalRead = 2
    case r3WorkspaceMutationOrSandbox = 3
    case r4PersonalDataOrSystemUI = 4
    case r5ExternalVisibleOrPersistentSystemChange = 5

    static func < (lhs: ToolRiskLevel, rhs: ToolRiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .r0TextOnly:
            "R0"
        case .r1PublicRead:
            "R1"
        case .r2LocalRead:
            "R2"
        case .r3WorkspaceMutationOrSandbox:
            "R3"
        case .r4PersonalDataOrSystemUI:
            "R4"
        case .r5ExternalVisibleOrPersistentSystemChange:
            "R5"
        }
    }
}

enum ToolSideEffect: String, Codable, Sendable {
    case none
    case readsPublicWeb
    case readsWorkspace
    case mutatesWorkspace
    case executesSandboxCode
    case readsPersonalData
    case mutatesPersonalData
    case opensSystemUI
    case externalVisibleSystemChange

    var title: String {
        switch self {
        case .none:
            "无副作用"
        case .readsPublicWeb:
            "读取公开网页"
        case .readsWorkspace:
            "读取工作区"
        case .mutatesWorkspace:
            "改动工作区"
        case .executesSandboxCode:
            "沙盒执行"
        case .readsPersonalData:
            "读取个人数据"
        case .mutatesPersonalData:
            "改动个人数据"
        case .opensSystemUI:
            "打开系统界面"
        case .externalVisibleSystemChange:
            "外部可见动作"
        }
    }
}

enum ToolParallelPolicy: String, Codable, Sendable {
    case parallelReadOnly
    case sequential
    case isolated
}

enum ToolConfirmationPolicy: String, Codable, Sendable {
    case allow
    case firstUse
    case always
}

struct ToolPolicyMetadata: Codable, Hashable, Sendable {
    let riskLevel: ToolRiskLevel
    let sideEffect: ToolSideEffect
    let parallelPolicy: ToolParallelPolicy
    let confirmationPolicy: ToolConfirmationPolicy
    let mutatesWorkspace: Bool
    let touchesPersonalData: Bool
    let isInteractive: Bool
    let isCacheable: Bool
    let isIdempotent: Bool

    static let localRead = ToolPolicyMetadata(
        riskLevel: .r2LocalRead,
        sideEffect: .readsWorkspace,
        parallelPolicy: .parallelReadOnly,
        confirmationPolicy: .allow,
        mutatesWorkspace: false,
        touchesPersonalData: false,
        isInteractive: false,
        isCacheable: true,
        isIdempotent: true
    )

    static let publicRead = ToolPolicyMetadata(
        riskLevel: .r1PublicRead,
        sideEffect: .readsPublicWeb,
        parallelPolicy: .parallelReadOnly,
        confirmationPolicy: .allow,
        mutatesWorkspace: false,
        touchesPersonalData: false,
        isInteractive: false,
        isCacheable: true,
        isIdempotent: true
    )
}

extension ToolActionID {
    var policyMetadata: ToolPolicyMetadata {
        switch self {
        case .getCurrentDateTime:
            return ToolPolicyMetadata(
                riskLevel: .r2LocalRead,
                sideEffect: .none,
                parallelPolicy: .parallelReadOnly,
                confirmationPolicy: .allow,
                mutatesWorkspace: false,
                touchesPersonalData: false,
                isInteractive: false,
                isCacheable: true,
                isIdempotent: true
            )

        case .fileRead, .listDirectory:
            return .localRead

        case .detectWebSearchProviders, .searchWeb, .fetchStaticWebPage, .fetchWebBatch:
            return .publicRead

        case .fileWrite, .fileAppend, .fileManage, .saveWebPageToWorkspace:
            return ToolPolicyMetadata(
                riskLevel: .r3WorkspaceMutationOrSandbox,
                sideEffect: .mutatesWorkspace,
                parallelPolicy: .sequential,
                confirmationPolicy: .firstUse,
                mutatesWorkspace: true,
                touchesPersonalData: false,
                isInteractive: false,
                isCacheable: false,
                isIdempotent: false
            )

        case .recognizeImageText, .scanImageWithMultimodalModel:
            return ToolPolicyMetadata(
                riskLevel: .r3WorkspaceMutationOrSandbox,
                sideEffect: self == .recognizeImageText ? .mutatesWorkspace : .readsWorkspace,
                parallelPolicy: .sequential,
                confirmationPolicy: .firstUse,
                mutatesWorkspace: self == .recognizeImageText,
                touchesPersonalData: true,
                isInteractive: false,
                isCacheable: false,
                isIdempotent: true
            )

        case .runPython:
            return ToolPolicyMetadata(
                riskLevel: .r3WorkspaceMutationOrSandbox,
                sideEffect: .executesSandboxCode,
                parallelPolicy: .sequential,
                confirmationPolicy: .firstUse,
                mutatesWorkspace: true,
                touchesPersonalData: false,
                isInteractive: false,
                isCacheable: false,
                isIdempotent: false
            )

        case .listTodayEvents, .listReminders, .searchContacts, .requestLocation, .searchNearbyPlaces,
             .listAlarms:
            return ToolPolicyMetadata(
                riskLevel: .r4PersonalDataOrSystemUI,
                sideEffect: .readsPersonalData,
                parallelPolicy: .sequential,
                confirmationPolicy: .firstUse,
                mutatesWorkspace: false,
                touchesPersonalData: true,
                isInteractive: false,
                isCacheable: false,
                isIdempotent: true
            )

        case .createCalendarEvent, .createReminder, .createContact, .createAlarm, .createClockTimer,
             .manageAlarm, .saveGeneratedPhoto, .sendLocalNotification, .indexWorkspaceToSpotlight,
             .clearSpotlightIndex:
            return ToolPolicyMetadata(
                riskLevel: .r5ExternalVisibleOrPersistentSystemChange,
                sideEffect: .externalVisibleSystemChange,
                parallelPolicy: .isolated,
                confirmationPolicy: .always,
                mutatesWorkspace: false,
                touchesPersonalData: true,
                isInteractive: false,
                isCacheable: false,
                isIdempotent: false
            )

        case .requestAlarmPermission, .requestNotificationPermission, .requestSpeechPermission,
             .openMapsRoute, .openInAppBrowser, .openCamera, .openPhotoLibrary, .scanDocument, .scanLiveText,
             .openMailDraft, .openMessageDraft, .callPhoneNumber, .openFaceTime, .openAppSettings,
             .openAppStore, .openPodcasts, .openBooks, .openTV, .publishHandoffActivity,
             .appIntentsDiagnostics, .speakText:
            return ToolPolicyMetadata(
                riskLevel: .r4PersonalDataOrSystemUI,
                sideEffect: .opensSystemUI,
                parallelPolicy: .isolated,
                confirmationPolicy: .always,
                mutatesWorkspace: false,
                touchesPersonalData: self == .openCamera || self == .openPhotoLibrary || self == .scanDocument || self == .scanLiveText,
                isInteractive: presentationKind == .interactive,
                isCacheable: false,
                isIdempotent: false
            )
        }
    }
}

enum RoutedToolCallKind {
    case progress
    case taskState
    case subagent
    case external
}

struct RoutedToolCall {
    let toolUse: AgentToolUse
    let kind: RoutedToolCallKind
    let prepared: AgentPreparedToolExecution?
    let policy: ToolPolicyMetadata?
    let routingError: String?
}

struct ToolRouter {
    let phaseThoughtToolName: String
    let taskStateToolName: String
    let subagentToolNames: Set<String>

    func route(_ toolUse: AgentToolUse, actions: [ToolAction]) -> RoutedToolCall {
        if toolUse.name == phaseThoughtToolName {
            return RoutedToolCall(
                toolUse: toolUse,
                kind: .progress,
                prepared: nil,
                policy: nil,
                routingError: nil
            )
        }

        if toolUse.name == taskStateToolName {
            return RoutedToolCall(
                toolUse: toolUse,
                kind: .taskState,
                prepared: nil,
                policy: nil,
                routingError: nil
            )
        }

        if subagentToolNames.contains(toolUse.name) {
            return RoutedToolCall(
                toolUse: toolUse,
                kind: .subagent,
                prepared: nil,
                policy: nil,
                routingError: nil
            )
        }

        guard let action = actions.first(where: { $0.id.rawValue == toolUse.name }) else {
            return RoutedToolCall(
                toolUse: toolUse,
                kind: .external,
                prepared: nil,
                policy: nil,
                routingError: "未知工具：\(toolUse.name)"
            )
        }

        do {
            let arguments = try ToolArguments(jsonString: toolUse.input)
            return RoutedToolCall(
                toolUse: toolUse,
                kind: .external,
                prepared: AgentPreparedToolExecution(
                    action: action,
                    arguments: arguments,
                    argumentsJSON: arguments.normalizedJSONString()
                ),
                policy: action.id.policyMetadata,
                routingError: nil
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return RoutedToolCall(
                toolUse: toolUse,
                kind: .external,
                prepared: nil,
                policy: action.id.policyMetadata,
                routingError: "工具参数解析失败：\(message)"
            )
        }
    }
}

enum ToolExecutionBatchKind {
    case progressOnly
    case parallelReadOnly
    case sequential
    case isolated
}

struct ToolExecutionBatch {
    let kind: ToolExecutionBatchKind
    let calls: [RoutedToolCall]
}

struct ToolExecutionPlanner {
    func plan(_ calls: [RoutedToolCall]) -> [ToolExecutionBatch] {
        var batches: [ToolExecutionBatch] = []
        var pendingParallel: [RoutedToolCall] = []
        var pendingSequential: [RoutedToolCall] = []

        func flushParallel() {
            guard !pendingParallel.isEmpty else { return }
            batches.append(ToolExecutionBatch(kind: .parallelReadOnly, calls: pendingParallel))
            pendingParallel.removeAll()
        }

        func flushSequential() {
            guard !pendingSequential.isEmpty else { return }
            batches.append(ToolExecutionBatch(kind: .sequential, calls: pendingSequential))
            pendingSequential.removeAll()
        }

        for call in calls {
            if case .progress = call.kind {
                flushParallel()
                flushSequential()
                batches.append(ToolExecutionBatch(kind: .progressOnly, calls: [call]))
                continue
            }

            if case .taskState = call.kind {
                flushParallel()
                flushSequential()
                batches.append(ToolExecutionBatch(kind: .progressOnly, calls: [call]))
                continue
            }

            if case .subagent = call.kind {
                flushParallel()
                flushSequential()
                batches.append(ToolExecutionBatch(kind: .progressOnly, calls: [call]))
                continue
            }

            guard call.routingError == nil,
                  let policy = call.policy else {
                flushParallel()
                pendingSequential.append(call)
                continue
            }

            switch policy.parallelPolicy {
            case .parallelReadOnly:
                flushSequential()
                pendingParallel.append(call)
            case .sequential:
                flushParallel()
                pendingSequential.append(call)
            case .isolated:
                flushParallel()
                flushSequential()
                batches.append(ToolExecutionBatch(kind: .isolated, calls: [call]))
            }
        }

        flushParallel()
        flushSequential()
        return batches
    }
}

enum RunVerifierDecision {
    case continueLoop
    case summarize(reason: String)
}

struct RunVerifier {
    func decisionAfterToolBatch(
        batch: ToolExecutionBatch,
        executedSteps: [LLMToolExecutionStep],
        hasQueuedGuidance: Bool
    ) -> RunVerifierDecision {
        if hasQueuedGuidance {
            return .continueLoop
        }
        if case .isolated = batch.kind {
            return .summarize(reason: "已执行系统动作、交互动作或沙盒执行动作。")
        }
        if let last = executedSteps.last,
           last.requiresUserInteraction || last.action.id.policyMetadata.parallelPolicy == .isolated {
            return .summarize(reason: "最后一步需要用户交互或必须单独收口。")
        }
        return .continueLoop
    }
}
