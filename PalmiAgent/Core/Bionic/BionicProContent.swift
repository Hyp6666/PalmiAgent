import Foundation

extension BionicArchiveStore {
    /// User-facing reads are protected; model context reads remain available in Basic.
    func userMemoryDetail(_ instance: String, memoryID: String) throws -> BionicObject {
        try access.requirePro()
        guard let memory = try memoryList(instance).first(where: { $0.text("memory_id") == memoryID }) else {
            throw BionicFailure("sourceMissing")
        }
        return memory
    }

    func userMemorySource(_ instance: String, memoryID: String) throws -> String? {
        try userMemoryDetail(instance, memoryID: memoryID).optionalText("primary_source_message_id")
    }

    func userDiaryEntries(_ instance: String) throws -> [BionicDiaryEntry] {
        try access.requirePro()
        return try diaryEntries(instance)
    }
}
