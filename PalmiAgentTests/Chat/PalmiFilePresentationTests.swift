import XCTest
@testable import PalmiAgent

final class PalmiFilePresentationTests: XCTestCase {
    func testFileTypesRemainSpecificInEverySurface() {
        let examples: [(String, PalmiFileFamily, String)] = [
            ("notes.txt", .text, "TXT"), ("README.md", .markdown, "MD"),
            ("index.HTML", .markup, "HTML"), ("proposal.doc", .word, "DOC"),
            ("proposal.docx", .word, "DOCX"), ("talk.ppt", .presentation, "PPT"),
            ("talk.pptx", .presentation, "PPTX"), ("budget.xlsx", .spreadsheet, "XLSX"),
            ("data.csv", .table, "CSV"), ("paper.pdf", .pdf, "PDF"),
            (".env.local", .configuration, "ENV"), (".gitignore", .configuration, "CONF"),
            ("archive.tar.gz", .archive, "TGZ"), ("Dockerfile.dev", .code, "DKR"),
            ("CMakeLists.txt", .code, "CMAKE"), ("image.svg", .image, "SVG"),
            ("sound.flac", .audio, "FLAC"), ("movie.mov", .video, "MOV")
        ]
        for (name, family, label) in examples {
            let value = PalmiFilePresentation.resolve(name: name)
            XCTAssertEqual(value.family, family, name)
            XCTAssertEqual(value.label, label, name)
            XCTAssertEqual(value, PalmiFilePresentation.resolve(name: "folder/" + name), name)
        }
    }

    func testKnownExtensionWinsOverGenericMIMEAndFolderWinsOverExtension() {
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "README.md", mimeType: "text/plain").family, .markdown)
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "index.html", mimeType: "text/plain").label, "HTML")
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "files.pdf", isDirectory: true).family, .folder)
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "opaque", mimeType: "application/pdf; charset=binary").label, "PDF")
    }

    func testUnknownAndUnsafeLookingNamesStayPresentationData() {
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "data.bim").label, "BIM")
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "no-extension").label, "FILE")
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "README.MD").family, .markdown)
        XCTAssertEqual(PalmiFilePresentation.resolve(name: "C:\\work\\report.DOCX").label, "DOCX")
        XCTAssertFalse(PalmiFilePresentation.resolve(name: "image.svg").isRasterImage)
        XCTAssertTrue(PalmiFilePresentation.resolve(name: "photo.HEIC").isRasterImage)
    }
}
