import Foundation

enum ApproximateTokenCounter {
    static func estimate(_ text: String) -> Int {
        var asciiScalarCount = 0
        var unicodeScalarCount = 0

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                continue
            }

            if scalar.isASCII {
                asciiScalarCount += 1
            } else {
                unicodeScalarCount += 1
            }
        }

        let asciiTokens = Int(ceil(Double(asciiScalarCount) / 4.0))
        let total = asciiTokens + unicodeScalarCount
        return max(total, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
    }

    static func estimate(chatMessages: [OpenAIChatMessage]) -> Int {
        chatMessages.reduce(into: 0) { partialResult, message in
            var serialized = message.role
            if let content = message.content {
                serialized += "\n\(content)"
            }
            if let toolCallID = message.toolCallID {
                serialized += "\n\(toolCallID)"
            }
            if let toolCalls = message.toolCalls {
                for toolCall in toolCalls {
                    serialized += "\n\(toolCall.id)\n\(toolCall.function.name)\n\(toolCall.function.arguments)"
                }
            }
            partialResult += estimate(serialized) + 4
        }
    }
}
