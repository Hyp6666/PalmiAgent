import Foundation

// Display classification only. Never use this to authorize reading or executing a file.
nonisolated enum PalmiFileFamily: String, Sendable, CaseIterable {
    case folder, pdf, word, presentation, spreadsheet, table, text, markdown
    case markup, code, configuration, database, archive, image, audio, video, generic
}

nonisolated struct PalmiFilePresentation: Equatable, Sendable {
    let family: PalmiFileFamily
    let label: String
    let isRasterImage: Bool

    static func resolve(name: String, mimeType: String? = nil,
                        isDirectory: Bool = false) -> Self {
        if isDirectory { return Self(family: .folder, label: "", isRasterImage: false) }
        let base = name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? name
        let lower = base.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") {
            return item(.configuration, "ENV")
        }
        if ["dockerfile", "containerfile"].contains(lower)
            || lower.hasPrefix("dockerfile.") || lower.hasPrefix("containerfile.") {
            return item(.code, "DKR")
        }
        if ["makefile", "gnumakefile"].contains(lower) { return item(.code, "MAKE") }
        if lower == "cmakelists.txt" { return item(.code, "CMAKE") }
        if ["license", "licence", "readme", "notice", "authors", "copying"].contains(lower) {
            return item(.text, "TXT")
        }
        if [".gitignore", ".gitattributes", ".editorconfig", ".npmrc", ".prettierrc",
            ".eslintrc", ".bashrc", ".zshrc", ".gitmodules"].contains(lower) {
            return item(.configuration, "CONF")
        }
        for (suffix, label) in [("tar.gz", "TGZ"), ("tar.bz2", "TBZ"),
                                ("tar.xz", "TXZ"), ("tar.zst", "TZST")] {
            if lower.hasSuffix("." + suffix) { return item(.archive, label) }
        }
        let ext = (base as NSString).pathExtension.lowercased()
        if let known = extensionMap[ext] { return known }
        if let mime = mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let value = resolveMIME(mime) {
            return value
        }
        // Unknown names still get the same glyph everywhere; show a short format label.
        let safe = ext.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return item(.generic, safe.isEmpty ? "FILE" : String(safe.prefix(5)))
    }

    private static func item(_ family: PalmiFileFamily, _ label: String,
                             raster: Bool = false) -> Self {
        Self(family: family, label: label, isRasterImage: raster)
    }

    private static let extensionMap: [String: Self] = {
        var result: [String: Self] = [:]
        func add(_ family: PalmiFileFamily, _ names: String, raster: Bool = false) {
            for name in names.split(separator: " ").map(String.init) {
                result[name] = item(family, name.uppercased(), raster: raster)
            }
        }
        add(.pdf, "pdf")
        add(.word, "doc docs docx docm dot dotx dotm odt ott rtf pages epub gdoc")
        add(.presentation, "ppt pptx pptm pot potx potm pps ppsx ppsm odp otp key gslides")
        add(.spreadsheet, "xls xlsx xlsm xlsb xlt xltx xltm ods ots numbers gsheet")
        add(.table, "csv tsv parquet feather arrow")
        add(.text, "txt text log nfo rst tex bib")
        add(.markdown, "md markdown mdown mkd mdx")
        add(.markup, "html htm xhtml xml xsl xslt css scss sass less vue svelte")
        add(.configuration, "json jsonl ndjson yaml yml toml ini cfg conf config env plist")
        add(.database, "db sqlite sqlite3 sql graphql gql accdb mdb")
        add(.code, "py pyw ipynb js mjs cjs ts tsx jsx swift java kt kts go rs c cc cpp cxx h hh hpp hxx m mm cs fs vb php rb r jl lua dart sh zsh bash fish ps1 bat cmd proto gradle cmake asm s sol")
        add(.archive, "zip rar 7z tar gz tgz bz2 tbz tbz2 xz txz zst lz lzma cab iso dmg pkg deb rpm apk ipa")
        add(.image, "jpg jpeg png heic heif gif webp bmp tif tiff avif", raster: true)
        add(.image, "svg svgz ico icns psd ai eps raw dng cr2 nef")
        add(.audio, "mp3 m4a wav aac flac ogg opus aiff aif wma mid midi")
        add(.video, "mp4 mov m4v mkv webm avi mpg mpeg wmv flv 3gp")
        result["markdown"] = item(.markdown, "MD")
        result["mdown"] = item(.markdown, "MD")
        result["mkd"] = item(.markdown, "MD")
        result["htm"] = item(.markup, "HTML")
        result["yml"] = item(.configuration, "YAML")
        result["text"] = item(.text, "TXT")
        result["cs"] = item(.code, "C#")
        result["parquet"] = item(.table, "PARQ")
        result["feather"] = item(.table, "FTHR")
        result["numbers"] = item(.spreadsheet, "NUM")
        result["gslides"] = item(.presentation, "GSLD")
        result["gsheet"] = item(.spreadsheet, "GSHT")
        result["graphql"] = item(.database, "GQL")
        result["sqlite3"] = item(.database, "SQL")
        result["sqlite"] = item(.database, "SQL")
        return result
    }()

    private static func resolveMIME(_ mime: String) -> Self? {
        switch mime {
        case "application/pdf": return item(.pdf, "PDF")
        case "application/msword": return item(.word, "DOC")
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return item(.word, "DOCX")
        case "application/vnd.ms-powerpoint": return item(.presentation, "PPT")
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
            return item(.presentation, "PPTX")
        case "application/vnd.ms-excel": return item(.spreadsheet, "XLS")
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
            return item(.spreadsheet, "XLSX")
        case "text/markdown": return item(.markdown, "MD")
        case "text/html", "application/xhtml+xml": return item(.markup, "HTML")
        case "application/json", "application/ld+json": return item(.configuration, "JSON")
        case "text/csv": return item(.table, "CSV")
        case "text/tab-separated-values": return item(.table, "TSV")
        case "application/zip": return item(.archive, "ZIP")
        case "application/x-7z-compressed": return item(.archive, "7Z")
        case "application/vnd.rar", "application/x-rar-compressed": return item(.archive, "RAR")
        case "application/gzip": return item(.archive, "GZ")
        case "image/svg+xml": return item(.image, "SVG")
        case "image/jpeg": return item(.image, "JPG", raster: true)
        case "image/png": return item(.image, "PNG", raster: true)
        case "image/heic", "image/heif": return item(.image, "HEIC", raster: true)
        case "image/gif": return item(.image, "GIF", raster: true)
        case "image/webp": return item(.image, "WEBP", raster: true)
        case "image/tiff": return item(.image, "TIFF", raster: true)
        case "image/avif": return item(.image, "AVIF", raster: true)
        default:
            if mime.hasPrefix("text/") { return item(.text, "TXT") }
            if mime.hasPrefix("image/") { return item(.image, "IMG") }
            if mime.hasPrefix("audio/") { return item(.audio, "AUDIO") }
            if mime.hasPrefix("video/") { return item(.video, "VIDEO") }
            if mime.hasSuffix("+json") { return item(.configuration, "JSON") }
            if mime.hasSuffix("+xml") { return item(.markup, "XML") }
            return nil
        }
    }
}
