import XCTest
@testable import PalmiAgent

@MainActor
final class WorkspaceFileTreeTests: XCTestCase {
    /// 工作区根用 /var/... 表示，而目录枚举返回 /private/var/...：子文件夹里的条目
    /// 仍必须得到完整相对路径，不能退化成只剩文件名。
    func testNestedNodesKeepFullRelativePathWhenRootIsSymlinkedVarPath() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let symlinkedPath = temporary.path.replacingOccurrences(of: "^/private", with: "", options: .regularExpression)
        let root = URL(fileURLWithPath: symlinkedPath, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WorkspaceManager(storageRootURL: root)
        _ = try manager.createProject(named: "Tree fixture")
        _ = try manager.writeText("a", to: "sub/a.txt")
        _ = try manager.writeText("b", to: "sub/deeper/README.md")
        _ = try manager.writeText("c", to: "README.md")

        let tree = try manager.listFileTree()
        let sub = try XCTUnwrap(tree.first { $0.name == "sub" })
        XCTAssertEqual(sub.relativePath, "sub")
        XCTAssertEqual(Set(sub.children.map(\.relativePath)), ["sub/a.txt", "sub/deeper"])
        let deeper = try XCTUnwrap(sub.children.first { $0.name == "deeper" })
        XCTAssertEqual(deeper.children.map(\.relativePath), ["sub/deeper/README.md"])
        // 同名文件位于不同文件夹时 ID 也必须唯一，列表才不会错位。
        XCTAssertNotEqual(tree.first { $0.name == "README.md" }?.id, deeper.children.first?.id)
        for node in [sub.children, deeper.children].joined() where !node.isDirectory {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.url(for: node.relativePath).path))
        }
    }

    func testFolderLookupFollowsPathPrefix() {
        let url = URL(fileURLWithPath: "/tmp")
        let leaf = WorkspaceFileNode(id: "a/b", name: "b", relativePath: "a/b", url: url, isDirectory: true, children: [])
        let tree = [
            WorkspaceFileNode(id: "ab", name: "ab", relativePath: "ab", url: url, isDirectory: true, children: []),
            WorkspaceFileNode(id: "a", name: "a", relativePath: "a", url: url, isDirectory: true, children: [leaf])
        ]
        XCTAssertEqual(WorkspaceFolderScreen.findNode(at: "a/b", in: tree)?.id, "a/b")
        XCTAssertNil(WorkspaceFolderScreen.findNode(at: "ab/b", in: tree))
    }
}
