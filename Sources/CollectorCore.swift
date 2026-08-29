import Foundation
import Compression

// Port der Kernlogik von https://github.com/arod1213/collect-and-save (Zig).
// Prinzip: .als-Dateien werden NIE veraendert. Fehlende externe Samples werden
// in den Projektordner kopiert (Samples/Collected bzw. Presets), wo Ableton
// Live sie beim Oeffnen ueber die automatische Suche im Projektordner findet.

enum RefPathType: Int {
    case na = 0
    case external = 1
    case currentProject = 3
    case pluginData = 5
    case userLibrary = 6
    case builtin = 7
}

struct FileRefInfo {
    var name: String = ""          // Live 9/10: Name-Element; Live 11/12: basename(Path)
    var path: String = ""          // Live 11/12: Path-Attribut; Live 9/10: aus RelativePathElementen gebaut
    var size: UInt64 = 0
    var type: RefPathType = .na
}

// MARK: - gzip

enum GzipError: Error { case notGzip, corrupt }

func gunzip(_ data: Data) throws -> Data {
    guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else {
        throw GzipError.notGzip
    }
    let flags = data[3]
    var offset = 10
    if flags & 0x04 != 0 { // FEXTRA
        guard data.count > offset + 2 else { throw GzipError.corrupt }
        let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2 + xlen
    }
    if flags & 0x08 != 0 { // FNAME
        while offset < data.count, data[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 0x10 != 0 { // FCOMMENT
        while offset < data.count, data[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 } // FHCRC
    guard offset < data.count - 8 else { throw GzipError.corrupt }

    let deflated = data.subdata(in: offset..<(data.count - 8))
    // ISIZE-Trailer: unkomprimierte Groesse mod 2^32 als Startschaetzung
    let isize = data.withUnsafeBytes { buf -> UInt32 in
        buf.loadUnaligned(fromByteOffset: data.count - 4, as: UInt32.self)
    }

    var out = Data()
    out.reserveCapacity(Int(isize))
    let bufSize = 1 << 20
    let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { dstBuf.deallocate() }

    var stream = compression_stream(dst_ptr: dstBuf, dst_size: bufSize, src_ptr: dstBuf, src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
        throw GzipError.corrupt
    }
    defer { compression_stream_destroy(&stream) }

    try deflated.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
        stream.src_size = src.count
        while true {
            stream.dst_ptr = dstBuf
            stream.dst_size = bufSize
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            out.append(dstBuf, count: bufSize - stream.dst_size)
            if status == COMPRESSION_STATUS_END { break }
            guard status == COMPRESSION_STATUS_OK else { throw GzipError.corrupt }
        }
    }
    return out
}

// MARK: - XML-Parsing (alle FileRef-Knoten, Live 9-12)

final class FileRefParser: NSObject, XMLParserDelegate {
    private(set) var majorVersion: Int = 0
    private(set) var refs: [FileRefInfo] = []

    private var refStack: [FileRefInfo] = []
    private var elementPath: [String] = []
    private var relElements: [(id: Int, dir: String)] = []
    private var sawRoot = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        if !sawRoot {
            sawRoot = true
            // Root <Ableton MinorVersion="11.0_11202" ...>
            if let minor = attrs["MinorVersion"], let dot = minor.firstIndex(where: { $0 == "." || $0 == "_" }),
               let major = Int(minor[minor.startIndex..<dot]) {
                majorVersion = major
            }
        }
        elementPath.append(name)

        if name == "FileRef" {
            refStack.append(FileRefInfo())
            relElements = []
            return
        }
        guard !refStack.isEmpty else { return }
        let value = attrs["Value"]

        switch name {
        case "Path":
            if let v = value { refStack[refStack.count - 1].path = v }
        case "Name":
            if let v = value { refStack[refStack.count - 1].name = v }
        case "RelativePathType":
            if let v = value, let i = Int(v), let t = RefPathType(rawValue: i) {
                refStack[refStack.count - 1].type = t
            }
        case "OriginalFileSize", "FileSize":
            if let v = value, let s = UInt64(v) { refStack[refStack.count - 1].size = s }
        case "RelativePathElement":
            let id = Int(attrs["Id"] ?? "") ?? relElements.count
            // Leeres Dir-Attribut bedeutet im alten Format "eine Ebene hoch"
            let dir = (attrs["Dir"] ?? "").isEmpty ? ".." : attrs["Dir"]!
            relElements.append((id, dir))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if !elementPath.isEmpty { elementPath.removeLast() }
        guard name == "FileRef", var ref = refStack.popLast() else { return }

        if ref.path.isEmpty, !ref.name.isEmpty {
            // Live 9/10: Pfad aus RelativePathElementen + Name bauen (relativ zum Set)
            let dirs = relElements.sorted { $0.id < $1.id }.map(\.dir)
            ref.path = (dirs + [ref.name]).joined(separator: "/")
        }
        if ref.name.isEmpty {
            ref.name = (ref.path as NSString).lastPathComponent
        }
        if !ref.path.isEmpty {
            refs.append(ref)
        }
    }
}

// MARK: - Engine

let audioExtensions: Set<String> = ["wav", "mp3", "flac", "ogg", "mp4", "m4a", "aif", "aiff"]
let presetExtensions: Set<String> = ["adv", "adg", "amxd"]

func targetFolder(forExtension ext: String) -> String? {
    if audioExtensions.contains(ext) { return "Samples/Collected" }
    if presetExtensions.contains(ext) { return "Presets" }
    return nil
}

struct CollectStats {
    var projects = 0
    var copied = 0
    var alreadyPresent = 0
    var foundViaSearch = 0
    var missing: [String] = []
    var errors: [String] = []
}

struct CollectOptions {
    var dryRun: Bool
    var searchFolder: URL?
}

final class CollectEngine {
    let log: (String) -> Void
    // (fertig, gesamt, Name des aktuellen Sets)
    let progress: (Int, Int, String) -> Void
    var isCancelled: () -> Bool = { false }

    private var searchIndex: [String: [URL]]? = nil

    init(log: @escaping (String) -> Void, progress: @escaping (Int, Int, String) -> Void = { _, _, _ in }) {
        self.log = log
        self.progress = progress
    }

    func findSets(in folder: URL) -> [URL] {
        var sets: [URL] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "als" else { continue }
            let parent = url.deletingLastPathComponent().lastPathComponent
            if parent == "Backup" { continue } // automatische Backups ueberspringen
            sets.append(url)
        }
        return sets.sorted { $0.path < $1.path }
    }

    func run(folder: URL, options: CollectOptions) -> CollectStats {
        var stats = CollectStats()
        var isDir: ObjCBool = false
        let sets: [URL]
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), !isDir.boolValue {
            // Einzelnes Live-Set direkt ausgewaehlt
            sets = folder.pathExtension.lowercased() == "als" ? [folder] : []
        } else {
            sets = findSets(in: folder)
        }
        if sets.isEmpty {
            log("Keine .als-Dateien gefunden.")
            return stats
        }
        log("\(sets.count) Live-Set(s) gefunden.\n")
        for (i, set) in sets.enumerated() {
            if isCancelled() { log("\nAbgebrochen."); break }
            progress(i + 1, sets.count, set.deletingPathExtension().lastPathComponent)
            processSet(set, options: options, stats: &stats)
        }
        progress(sets.count, sets.count, "")
        return stats
    }

    private func processSet(_ setURL: URL, options: CollectOptions, stats: inout CollectStats) {
        let fm = FileManager.default
        let sessionDir = setURL.deletingLastPathComponent()
        let setName = setURL.deletingPathExtension().lastPathComponent

        let xmlData: Data
        do {
            let raw = try Data(contentsOf: setURL)
            if raw.count > 2, raw[0] == 0x1f, raw[1] == 0x8b {
                xmlData = try gunzip(raw)
            } else {
                xmlData = raw // Live liest auch unkomprimiertes XML
            }
        } catch {
            log("⛔️ \(setName): Datei konnte nicht gelesen werden (\(error.localizedDescription))")
            stats.errors.append(setURL.path)
            return
        }

        let parser = XMLParser(data: xmlData)
        let delegate = FileRefParser()
        parser.delegate = delegate
        guard parser.parse() || !delegate.refs.isEmpty else {
            log("⛔️ \(setName): Kein gueltiges Ableton-Set (XML nicht lesbar)")
            stats.errors.append(setURL.path)
            return
        }

        stats.projects += 1
        let versionText = delegate.majorVersion > 0 ? "Live \(delegate.majorVersion)" : "Live ?"
        log("🎛  \(setName)  (\(versionText))")

        // Einmal pro Projekt: alle vorhandenen Dateinamen im Projektordner einsammeln
        var existingNames = Set<String>()
        if let walker = fm.enumerator(at: sessionDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                existingNames.insert(url.lastPathComponent.lowercased())
            }
        }

        // Referenzen deduplizieren
        var seen = Set<String>()
        var actionable = 0
        for ref in delegate.refs {
            guard ref.type == .external || ref.type == .userLibrary else { continue }
            guard seen.insert(ref.path.lowercased()).inserted else { continue }
            let ext = (ref.path as NSString).pathExtension.lowercased()
            guard let subFolder = targetFolder(forExtension: ext) else { continue }
            let baseName = (ref.path as NSString).lastPathComponent

            if existingNames.contains(baseName.lowercased()) {
                stats.alreadyPresent += 1
                continue
            }
            actionable += 1

            // Quelldatei aufloesen
            var source: URL? = nil
            var viaSearch = false
            let candidate = ref.path.hasPrefix("/")
                ? URL(fileURLWithPath: ref.path)
                : URL(fileURLWithPath: ref.path, relativeTo: sessionDir).standardizedFileURL
            if fm.fileExists(atPath: candidate.path) {
                source = candidate
            } else if let found = searchFallback(name: baseName, size: ref.size, options: options) {
                source = found
                viaSearch = true
            }

            guard let src = source else {
                log("   ⚠️  fehlt: \(baseName)  (\(ref.path))")
                stats.missing.append(ref.path)
                continue
            }

            let destDir = sessionDir.appendingPathComponent(subFolder, isDirectory: true)
            let dest = destDir.appendingPathComponent(baseName)
            if options.dryRun {
                log("   🔍 wuerde kopieren: \(baseName)\(viaSearch ? "  (ueber Suchordner gefunden)" : "")")
                stats.copied += 1
                if viaSearch { stats.foundViaSearch += 1 }
                existingNames.insert(baseName.lowercased())
                continue
            }
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dest)
                existingNames.insert(baseName.lowercased())
                stats.copied += 1
                if viaSearch { stats.foundViaSearch += 1 }
                log("   ✅ kopiert: \(baseName)\(viaSearch ? "  (ueber Suchordner gefunden)" : "")")
            } catch {
                log("   ⛔️ Kopieren fehlgeschlagen: \(baseName) (\(error.localizedDescription))")
                stats.errors.append(ref.path)
            }
        }
        if actionable == 0 {
            log("   nichts zu tun – alle Samples liegen bereits im Projekt")
        }
        log("")
    }

    private func searchFallback(name: String, size: UInt64, options: CollectOptions) -> URL? {
        guard let searchRoot = options.searchFolder else { return nil }
        if searchIndex == nil {
            log("   (Suchordner wird einmalig eingelesen …)")
            var index: [String: [URL]] = [:]
            let fm = FileManager.default
            if let walker = fm.enumerator(at: searchRoot, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles]) {
                for case let url as URL in walker {
                    index[url.lastPathComponent.lowercased(), default: []].append(url)
                }
            }
            searchIndex = index
        }
        guard let candidates = searchIndex?[name.lowercased()], !candidates.isEmpty else { return nil }
        if size > 0 {
            for c in candidates {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: c.path),
                   let fileSize = attrs[.size] as? UInt64, fileSize == size {
                    return c
                }
            }
        }
        return candidates.first
    }
}
