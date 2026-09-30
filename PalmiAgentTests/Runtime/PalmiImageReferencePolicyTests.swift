import XCTest
@testable import PalmiAgent

/// 第七/十三节：参考选择、安全校验与请求编码的纯值验证。
final class PalmiImageReferencePolicyTests: XCTestCase {
    private let instance = "11111111-1111-1111-1111-111111111111"
    private let character = "22222222-2222-2222-2222-222222222222"
    private let anchor = "anchor-1"

    private func hex(_ marker: Character) -> String { String(repeating: String(marker), count: 64) }
    private func path(_ marker: Character, ext: String = "png") -> String { "assets/\(hex(marker)).\(ext)" }

    private func candidate(
        _ marker: Character, kind: PalmiReferenceKind, anchor: String? = "anchor-1",
        depicts: Bool = true, sequence: Int? = nil,
        instanceID: String? = nil, characterID: String? = nil, ext: String = "png"
    ) -> PalmiImageReferenceCandidate {
        PalmiImageReferenceCandidate(
            path: path(marker, ext: ext), sha256: hex(marker),
            installationID: instanceID ?? instance, characterID: characterID ?? character,
            kind: kind, identityAnchor: anchor, depictsCharacter: depicts, committedSequence: sequence
        )
    }

    func testSafeAssetPathAcceptsCanonicalHashNames() {
        XCTAssertTrue(PalmiImageReferencePolicy.isSafeAssetPath(path("a")))
        XCTAssertTrue(PalmiImageReferencePolicy.isSafeAssetPath(path("0", ext: "jpeg")))
        XCTAssertTrue(PalmiImageReferencePolicy.isSafeAssetPath(path("f", ext: "webp")))
    }

    func testSafeAssetPathRejectsTraversalAbsoluteAndRemote() {
        for unsafe in [
            "../assets/\(hex("a")).png",
            "/assets/\(hex("a")).png",
            "assets/../../../etc/passwd",
            "assets/%2e%2e/\(hex("a")).png",
            "https://example.com/\(hex("a")).png",
            "assets/short.png",
            "assets/\(hex("a")).exe",
            "file:///assets/\(hex("a")).png",
            "assets/sub/\(hex("a")).png"
        ] {
            XCTAssertFalse(PalmiImageReferencePolicy.isSafeAssetPath(unsafe), unsafe)
        }
    }

    func testAutoSelectsAvatarThenTwoMostRecentCommittedCharacterImages() throws {
        let catalog = [
            candidate("a", kind: .avatar),
            candidate("1", kind: .generated, sequence: 3),
            candidate("2", kind: .generated, sequence: 7),
            candidate("3", kind: .generated, sequence: 5),
            candidate("4", kind: .generated, sequence: 1),
            candidate("5", kind: .generated, depicts: false, sequence: 9) // 风景不入选
        ]
        let selected = try PalmiImageReferencePolicy.select(
            mode: .auto, depictsCharacter: true, requestedPaths: [],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )
        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(selected[0].kind, .avatar)
        // 最近两张按提交序号：7、5
        XCTAssertEqual(selected[1].sha256, hex("2"))
        XCTAssertEqual(selected[2].sha256, hex("3"))
    }

    func testAutoExcludesNonCharacterScenesPendingAndForeignScopes() throws {
        let catalog = [
            candidate("a", kind: .avatar),
            candidate("b", kind: .generated, depicts: false, sequence: 5),
            candidate("c", kind: .generated, sequence: nil), // 未提交
            candidate("d", kind: .generated, anchor: "other-anchor", sequence: 8),
            candidate("e", kind: .generated, sequence: 9, characterID: "33333333-3333-3333-3333-333333333333"),
            candidate("f", kind: .generated, sequence: 10, instanceID: "44444444-4444-4444-4444-444444444444")
        ]
        let selected = try PalmiImageReferencePolicy.select(
            mode: .auto, depictsCharacter: true, requestedPaths: [],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )
        XCTAssertEqual(selected.map(\.sha256), [hex("a")], "只有头像入选")
    }

    func testAutoWithoutAvatarOrHistoryYieldsZeroReferences() throws {
        let selected = try PalmiImageReferencePolicy.select(
            mode: .auto, depictsCharacter: true, requestedPaths: [],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: []
        )
        XCTAssertTrue(selected.isEmpty, "没有头像且无历史图时 auto 合法退化为 0 张")
    }

    func testAutoWithLandscapeIntentDoesNotAttachAvatar() throws {
        let catalog = [candidate("a", kind: .avatar), candidate("1", kind: .generated, sequence: 3)]
        let selected = try PalmiImageReferencePolicy.select(
            mode: .auto, depictsCharacter: false, requestedPaths: [],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )
        XCTAssertTrue(selected.isEmpty, "风景图不自动附带角色头像")
    }

    func testNoneAlwaysYieldsZero() throws {
        let catalog = [candidate("a", kind: .avatar), candidate("1", kind: .generated, sequence: 3)]
        let selected = try PalmiImageReferencePolicy.select(
            mode: .none, depictsCharacter: true, requestedPaths: [],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )
        XCTAssertTrue(selected.isEmpty, "none 即使有头像也零参考")
    }

    func testExplicitKeepsOrderAndDoesNotInjectAvatar() throws {
        let catalog = [
            candidate("a", kind: .avatar),
            candidate("1", kind: .generated, sequence: 3),
            candidate("2", kind: .generated, sequence: 7)
        ]
        let selected = try PalmiImageReferencePolicy.select(
            mode: .explicit,
            depictsCharacter: true,
            requestedPaths: [path("2"), path("1")],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )
        XCTAssertEqual(selected.map(\.sha256), [hex("2"), hex("1")], "严格按提供顺序，不自动塞头像")
    }

    func testExplicitDeduplicatesSameContent() throws {
        let catalog = [candidate("1", kind: .generated, sequence: 3)]
        let selected = try PalmiImageReferencePolicy.select(
            mode: .explicit, depictsCharacter: true,
            requestedPaths: [path("1"), path("1")],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )
        XCTAssertEqual(selected.count, 1)
    }

    func testFourthReferenceFailsExplicitly() {
        let catalog = [candidate("1", kind: .generated, sequence: 1)]
        XCTAssertThrowsError(try PalmiImageReferencePolicy.select(
            mode: .explicit, depictsCharacter: true,
            requestedPaths: [path("1"), path("1"), path("1"), path("1")],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )) { XCTAssertEqual($0 as? PalmiReferencePolicyError, .tooManyReferences) }
    }

    func testPathsWithAutoOrNoneAreConflicting() {
        for mode in [PalmiReferenceMode.auto, .none] {
            XCTAssertThrowsError(try PalmiImageReferencePolicy.select(
                mode: mode, depictsCharacter: true, requestedPaths: [path("1")],
                installationID: instance, characterID: character, identityAnchor: anchor, catalog: []
            )) { XCTAssertEqual($0 as? PalmiReferencePolicyError, .conflictingArguments) }
        }
    }

    func testUnknownAndUnsafeExplicitPathsFailBeforeAnyNetworkCall() {
        let catalog = [candidate("1", kind: .generated, sequence: 1)]
        XCTAssertThrowsError(try PalmiImageReferencePolicy.select(
            mode: .explicit, depictsCharacter: true, requestedPaths: [path("9")],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )) { XCTAssertEqual($0 as? PalmiReferencePolicyError, .unknownReference(path("9"))) }
        XCTAssertThrowsError(try PalmiImageReferencePolicy.select(
            mode: .explicit, depictsCharacter: true, requestedPaths: ["assets/../secret.png"],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: catalog
        )) { XCTAssertEqual($0 as? PalmiReferencePolicyError, .invalidPath) }
    }

    func testHashMismatchWithFilenameFails() {
        let tampered = PalmiImageReferenceCandidate(
            path: path("a"), sha256: hex("b"),
            installationID: instance, characterID: character,
            kind: .avatar, identityAnchor: anchor, depictsCharacter: true, committedSequence: nil
        )
        XCTAssertThrowsError(try PalmiImageReferencePolicy.select(
            mode: .auto, depictsCharacter: true, requestedPaths: [],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: [tampered]
        )) { XCTAssertEqual($0 as? PalmiReferencePolicyError, .invalidMetadata) }
    }

    func testCrossScopeAndCrossCharacterCandidatesAreExcludedFromAuto() throws {
        // auto 模式下跨角色/跨实例的候选由 scope 过滤排除，而不是抛错。
        let foreign = candidate("a", kind: .avatar, characterID: "33333333-3333-3333-3333-333333333333")
        let selected = try PalmiImageReferencePolicy.select(
            mode: .auto, depictsCharacter: true, requestedPaths: [],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: [foreign]
        )
        XCTAssertTrue(selected.isEmpty, "其他角色的头像不会自动入选")
        // 显式指定时不安全/越界的路径必须在网络调用前失败。
        let foreignGenerated = candidate("b", kind: .generated, sequence: 3,
                                         characterID: "33333333-3333-3333-3333-333333333333")
        XCTAssertThrowsError(try PalmiImageReferencePolicy.select(
            mode: .explicit, depictsCharacter: true, requestedPaths: [foreignGenerated.path],
            installationID: instance, characterID: character, identityAnchor: anchor, catalog: [foreignGenerated]
        )) { XCTAssertEqual($0 as? PalmiReferencePolicyError, .wrongScope) }
    }

    func testIdentityAnchorIsStableAndChangesWithAvatar() {
        let a1 = BionicIdentityAnchor.anchor(characterID: character, avatarAsset: "assets/\(hex("a")).png")
        let a2 = BionicIdentityAnchor.anchor(characterID: character, avatarAsset: "assets/\(hex("a")).png")
        XCTAssertEqual(a1, a2, "头像不变时锚点稳定")
        let b = BionicIdentityAnchor.anchor(characterID: character, avatarAsset: "assets/\(hex("b")).png")
        XCTAssertNotEqual(a1, b, "换头像后锚点改变，旧图不再自动跟随")
        let unanchored = BionicIdentityAnchor.anchor(characterID: character, avatarAsset: nil)
        XCTAssertNotEqual(a1, unanchored)
        XCTAssertEqual(unanchored, BionicIdentityAnchor.anchor(characterID: character, avatarAsset: nil), "无头像时角色专属标识稳定")
    }

    func testContextImageDispositionKeepsUserVisualInput() {
        XCTAssertEqual(PalmiContextImagePolicy.disposition(authorKind: "user", origin: "user_input"), .visualInput)
        XCTAssertEqual(PalmiContextImagePolicy.disposition(authorKind: "character", origin: "reply"), .lightReference)
        XCTAssertEqual(PalmiContextImagePolicy.disposition(authorKind: "character", origin: "proactive"), .lightReference)
    }
}

/// 第八/十三节：运输层编码与端点契约。
final class PalmiImageRequestEncodingTests: XCTestCase {
    private func reference(_ byte: UInt8, mime: String = "image/png") -> PalmiPreparedReference {
        PalmiPreparedReference(sourcePath: "assets/\(String(repeating: "a", count: 64)).png",
                               sourceSHA256: String(repeating: "b", count: 64),
                               preparedSHA256: String(repeating: "c", count: 64),
                               mimeType: mime, bytes: Data(repeating: byte, count: 64))
    }

    func testZeroReferenceUsesGenerationsWithoutImagesField() throws {
        let encoded = try PalmiImageRequestEncoding.make(model: "gpt-image-2", prompt: "a cat", references: [])
        XCTAssertEqual(encoded.endpointPath, "images/generations")
        let object = try JSONSerialization.jsonObject(with: encoded.body) as? [String: Any]
        XCTAssertNil(object?["images"], "零参考正文无 images 字段")
        XCTAssertEqual(object?["n"] as? Int, 1)
        XCTAssertNil(object?["input_fidelity"], "不无条件发送 input_fidelity")
    }

    func testOneTwoThreeReferencesUseEditsInOrder() throws {
        for count in 1...3 {
            let references = (0..<count).map { reference(UInt8($0 + 1)) }
            let encoded = try PalmiImageRequestEncoding.make(model: "gpt-image-2", prompt: "a cat", references: references)
            XCTAssertEqual(encoded.endpointPath, "images/edits")
            let object = try JSONSerialization.jsonObject(with: encoded.body) as? [String: Any]
            let images = object?["images"] as? [[String: Any]]
            XCTAssertEqual(images?.count, count)
            for (index, image) in (images ?? []).enumerated() {
                let url = image["image_url"] as? String ?? ""
                XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
                let base64 = String(url.dropFirst("data:image/png;base64,".count))
                XCTAssertEqual(Data(base64Encoded: base64), references[index].bytes, "顺序与冻结清单一致")
            }
        }
    }

    func testFourthReferenceIsRejected() {
        XCTAssertThrowsError(try PalmiImageRequestEncoding.make(
            model: "gpt-image-2", prompt: "a cat", references: (0..<4).map { reference(UInt8($0 + 1)) }
        )) { XCTAssertEqual($0 as? PalmiImageEncodingError, .tooManyReferences) }
    }

    func testInvalidMimeAndEmptyBytesAreRejected() {
        XCTAssertThrowsError(try PalmiImageRequestEncoding.make(
            model: "gpt-image-2", prompt: "a cat", references: [reference(1, mime: "image/gif")]
        )) { XCTAssertEqual($0 as? PalmiImageEncodingError, .invalidReference) }
        let empty = PalmiPreparedReference(sourcePath: "assets/x.png", sourceSHA256: "b", preparedSHA256: "c",
                                           mimeType: "image/png", bytes: Data())
        XCTAssertThrowsError(try PalmiImageRequestEncoding.make(
            model: "gpt-image-2", prompt: "a cat", references: [empty]
        )) { XCTAssertEqual($0 as? PalmiImageEncodingError, .invalidReference) }
    }

    func testBlankModelOrPromptIsRejected() {
        XCTAssertThrowsError(try PalmiImageRequestEncoding.make(model: " ", prompt: "a cat", references: [])) {
            XCTAssertEqual($0 as? PalmiImageEncodingError, .invalidInput)
        }
        XCTAssertThrowsError(try PalmiImageRequestEncoding.make(model: "gpt-image-2", prompt: "\n", references: [])) {
            XCTAssertEqual($0 as? PalmiImageEncodingError, .invalidInput)
        }
    }

    func testOversizeReferenceExceedsBudget() {
        let big = PalmiPreparedReference(
            sourcePath: "assets/x.png", sourceSHA256: "b", preparedSHA256: "c",
            mimeType: "image/png", bytes: Data(repeating: 1, count: PalmiImageRequestEncoding.perReferenceLimit + 1)
        )
        XCTAssertThrowsError(try PalmiImageRequestEncoding.make(
            model: "gpt-image-2", prompt: "a cat", references: [big]
        )) { XCTAssertEqual($0 as? PalmiImageEncodingError, .referenceBudgetExceeded) }
    }

    func testFingerprintChangesWithReferencesAndPrompt() {
        let base = PalmiImageRequestFingerprint(accountID: "acc", model: "m", prompt: "p", references: [])
        XCTAssertEqual(base.value, PalmiImageRequestFingerprint(accountID: "acc", model: "m", prompt: "p", references: []).value)
        XCTAssertNotEqual(base.value, PalmiImageRequestFingerprint(accountID: "acc", model: "m", prompt: "q", references: []).value)
        XCTAssertNotEqual(base.value, PalmiImageRequestFingerprint(accountID: "acc2", model: "m", prompt: "p", references: []).value)
        XCTAssertNotEqual(base.value, PalmiImageRequestFingerprint(accountID: "acc", model: "m", prompt: "p", references: [reference(1)]).value)
    }
}
