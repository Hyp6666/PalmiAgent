import Foundation

protocol BreakdownHandler: Sendable {
    func supports(_ format: BreakdownFormat) -> Bool
    func index(context: BreakdownContext, manifest: inout BreakdownManifest) async throws
    func generateParts(range: Range<Int>, context: BreakdownContext, manifest: inout BreakdownManifest) async throws
    func materialize(itemIDs: [String], context: BreakdownContext, manifest: inout BreakdownManifest) async throws
}
