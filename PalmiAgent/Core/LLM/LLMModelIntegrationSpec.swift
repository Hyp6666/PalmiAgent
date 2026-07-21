import Foundation

enum ReasoningReplayPolicy: String, Codable, Sendable {
    case none
    case preserveWhenReturned
}

enum LLMReasoningControlKind: String, Codable, Sendable {
    case unified
}

enum ProviderCapabilitySource: String, Codable, Sendable {
    case remoteModelList
    case customUserInput
    case conservativeUnknown
}

struct LLMModelUIControls: Codable, Sendable, Hashable {
    let reasoning: LLMReasoningControlKind
    let allowsVisionInput: Bool
    let allowsToolCalling: Bool
    let allowsJSONMode: Bool

    static func from(capabilities: LLMModelCapabilities) -> LLMModelUIControls {
        LLMModelUIControls(
            reasoning: .unified,
            allowsVisionInput: capabilities.supportsVision,
            allowsToolCalling: capabilities.supportsToolCalls,
            allowsJSONMode: capabilities.supportsJSONMode
        )
    }
}

struct LLMEndpointSpec: Codable, Sendable, Hashable {
    let chatCompletionsPath: String

    static let openAICompatibleChat = LLMEndpointSpec(chatCompletionsPath: "chat/completions")
}

struct LLMRequestEncodingSpec: Codable, Sendable, Hashable {
    let notes: String
}

struct LLMResponseDecodingSpec: Codable, Sendable, Hashable {
    let reasoningContentField: String?
    let reasoningDetailsField: String?
}

struct LLMModelValidationPlan: Codable, Sendable, Hashable {
    let requiresChatSnapshot: Bool
    let requiresStreamSnapshot: Bool
    let requiresToolReplaySnapshot: Bool
    let requiresVisionSnapshot: Bool
}

struct LLMModelIntegrationSpec: Codable, Sendable, Hashable {
    let providerID: APIProviderID
    let modelID: String
    let modelFamily: String
    let officialDocs: [URL]
    let endpoint: LLMEndpointSpec
    let requestEncoding: LLMRequestEncodingSpec
    let responseDecoding: LLMResponseDecodingSpec
    let capabilities: LLMModelCapabilities
    let reasoningReplayPolicy: ReasoningReplayPolicy
    let uiControls: LLMModelUIControls
    let validationPlan: LLMModelValidationPlan
    let capabilitySource: ProviderCapabilitySource
    let isCurated: Bool
}

/// A model name is an opaque identifier. This catalog deliberately contains no
/// model-name matching, aliases, family tables, or model-specific capabilities.
enum LLMModelIntegrationCatalog {
    static func conservativeOpenAICompatibleSpec(
        modelID: String,
        capabilities evidence: ModelCandidateCapabilities
    ) -> LLMModelIntegrationSpec {
        makeSpec(
            providerID: .customOpenAI,
            modelID: modelID,
            supportsVision: evidence.supportsVision,
            capabilitySource: .customUserInput
        )
    }

    static func spec(for providerID: APIProviderID, modelID: String) -> LLMModelIntegrationSpec {
        makeSpec(
            providerID: providerID,
            modelID: modelID,
            supportsVision: false,
            capabilitySource: .conservativeUnknown
        )
    }

    static func spec(for providerID: APIProviderID, model: APIModelDefinition) -> LLMModelIntegrationSpec {
        makeSpec(
            providerID: providerID,
            modelID: model.id,
            supportsVision: model.supportsMultimodal,
            capabilitySource: .remoteModelList
        )
    }

    static func canonicalModelID(for _: APIProviderID, modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeSpec(
        providerID: APIProviderID,
        modelID: String,
        supportsVision: Bool,
        capabilitySource: ProviderCapabilitySource
    ) -> LLMModelIntegrationSpec {
        var capabilities = LLMModelCapabilities.standardText
        capabilities.supportsVision = supportsVision
        capabilities.supportsReasoningReplay = true
        capabilities.supportsPromptCacheUsage = false

        return LLMModelIntegrationSpec(
            providerID: providerID,
            modelID: canonicalModelID(for: providerID, modelID: modelID),
            modelFamily: "openai-compatible",
            officialDocs: [],
            endpoint: .openAICompatibleChat,
            requestEncoding: .init(notes: ""),
            responseDecoding: .init(
                reasoningContentField: "reasoning_content",
                reasoningDetailsField: "reasoning_details"
            ),
            capabilities: capabilities,
            reasoningReplayPolicy: .preserveWhenReturned,
            uiControls: .from(capabilities: capabilities),
            validationPlan: .init(
                requiresChatSnapshot: true,
                requiresStreamSnapshot: true,
                requiresToolReplaySnapshot: true,
                requiresVisionSnapshot: supportsVision
            ),
            capabilitySource: capabilitySource,
            isCurated: false
        )
    }
}
