import AppKit
import Quartz
import QuickLookThumbnailing
import ImageIO
import PDFKit
import CryptoKit
import UniformTypeIdentifiers
import Darwin

// Apron stores references to originals. Imported clipboard/promise data lives separately,
// and removing a shelf item never deletes either kind of file.
enum ShelfStyle: String, Codable {
    case compact, glass
    var width: CGFloat { self == .compact ? 316 : 448 }
    var tileSize: NSSize { self == .compact ? NSSize(width: 88, height: 100) : NSSize(width: 128, height: 146) }
    var thumbnailSize: CGFloat { self == .compact ? 60 : 96 }
    var gap: CGFloat { self == .compact ? 8 : 14 }
    var radius: CGFloat { self == .compact ? 16 : 26 }
}
enum ItemKind: String, Codable { case file, text, image, link, received }
struct ShelfItem: Codable, Equatable {
    var id = UUID()
    var kind: ItemKind
    var name: String
    var location: String
    var created = Date()
}
struct ShelfGroup: Codable, Equatable {
    var id = UUID()
    var name: String
    var items = [ShelfItem]()
}
struct ShelfState: Codable, Equatable {
    var version = 1
    var groups: [ShelfGroup]
    var active: UUID
    init() { let group = ShelfGroup(name: "My shelf"); groups = [group]; active = group.id }
}
enum ShelfError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}
func readBoundedFile(_ url: URL, limit: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= limit else {
        throw ShelfError.invalid("This saved file is not a regular file or exceeds Apron’s safe size limit.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw ShelfError.invalid("This saved file exceeds Apron’s safe size limit.") }
    return data
}
final class ShelfStore {
    let directory: URL
    var manifest: URL { directory.appendingPathComponent("shelves.json") }
    var imports: URL { directory.appendingPathComponent("Imports", isDirectory: true) }
    private(set) var state = ShelfState()
    var groupIndex: Int { state.groups.firstIndex(where: { $0.id == state.active }) ?? 0 }
    var items: [ShelfItem] { state.groups[groupIndex].items }
    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: manifest.path) {
            let data = try readBoundedFile(manifest, limit: 32 * 1024 * 1024)
            let decoded = try JSONDecoder().decode(ShelfState.self, from: data)
            guard decoded.version == 1, !decoded.groups.isEmpty,
                  Set(decoded.groups.map(\.id)).count == decoded.groups.count,
                  decoded.groups.contains(where: { $0.id == decoded.active }),
                  decoded.groups.allSatisfy({ Set($0.items.map(\.id)).count == $0.items.count }) else {
                throw ShelfError.invalid("The saved shelves could not be read. Your files and saved database have been preserved.")
            }
            state = decoded
        } else { state = ShelfState() }
    }
    func change(_ transform: (inout ShelfState) -> Void) throws {
        var next = state
        transform(&next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: manifest, options: .atomic)
        state = next
    }
    func restore(_ snapshot: ShelfState) throws { try change { $0 = snapshot } }
    func addFiles(_ urls: [URL], groupID: UUID? = nil) throws {
        let target = groupID ?? state.active
        guard let index = state.groups.firstIndex(where: { $0.id == target }) else { throw ShelfError.invalid("The destination shelf no longer exists.") }
        let normalized = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard normalized.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw ShelfError.invalid("One of these files is no longer available. The shelf was not changed.") }
        try change { next in
            var seen = Set(next.groups[index].items.filter { $0.kind == .file }.map(\.location))
            for url in normalized where seen.insert(url.path).inserted {
                next.groups[index].items.append(ShelfItem(kind: .file, name: url.lastPathComponent, location: url.path))
            }
        }
    }
    func addData(_ data: Data, name: String, kind: ItemKind, groupID: UUID? = nil) throws {
        let target = groupID ?? state.active
        guard let index = state.groups.firstIndex(where: { $0.id == target }) else { throw ShelfError.invalid("The destination shelf no longer exists.") }
        guard data.count <= 128 * 1024 * 1024 else { throw ShelfError.invalid("This clipboard item is too large. Save it as a file, then add the file.") }
        let folder = imports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let destination = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        do {
            try data.write(to: destination, options: .atomic)
            let relative = folder.lastPathComponent + "/" + destination.lastPathComponent
            try change { $0.groups[index].items.append(ShelfItem(kind: kind, name: destination.lastPathComponent, location: relative)) }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    func addText(_ value: String) throws {
        guard !value.isEmpty else { return }
        let title = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Note"
        let sanitized = String(title.prefix(48)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try addData(Data(value.utf8), name: (sanitized.isEmpty ? "Note" : sanitized) + ".txt", kind: .text)
    }
    func addLink(_ url: URL) throws {
        guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { throw ShelfError.invalid("Only web and email links can be added as links.") }
        let index = groupIndex
        guard !items.contains(where: { $0.kind == .link && $0.location == url.absoluteString }) else { return }
        try change { $0.groups[index].items.append(ShelfItem(kind: .link, name: url.host ?? url.absoluteString, location: url.absoluteString)) }
    }
    func receive(_ url: URL, in folder: URL, groupID: UUID) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard resolved.path.hasPrefix(base), FileManager.default.fileExists(atPath: resolved.path),
              let index = state.groups.firstIndex(where: { $0.id == groupID }) else { throw ShelfError.invalid("The received file could not be added safely.") }
        let importRoot = imports.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard resolved.path.hasPrefix(importRoot) else { throw ShelfError.invalid("The received file is outside Apron’s import folder.") }
        let relative = String(resolved.path.dropFirst(importRoot.count))
        try change { $0.groups[index].items.append(ShelfItem(kind: .received, name: resolved.lastPathComponent, location: relative)) }
    }
    func url(for item: ShelfItem) -> URL? {
        switch item.kind {
        case .file: return item.location.hasPrefix("/") ? URL(fileURLWithPath: item.location) : nil
        case .link:
            guard let url = URL(string: item.location), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        default:
            let url = imports.appendingPathComponent(item.location).standardizedFileURL
            guard url.resolvingSymlinksInPath().path.hasPrefix(imports.resolvingSymlinksInPath().path + "/") else { return nil }
            return url
        }
    }
    func remove(ids: Set<UUID>) throws { let index = groupIndex; try change { $0.groups[index].items.removeAll { ids.contains($0.id) } } }
    func newGroup(name: String) throws { let group = ShelfGroup(name: name); try change { $0.groups.append(group); $0.active = group.id } }
    func selectGroup(_ id: UUID) throws { guard state.groups.contains(where: { $0.id == id }) else { return }; try change { $0.active = id } }
    func renameGroup(_ name: String) throws { let index = groupIndex; try change { $0.groups[index].name = name } }
}

// Quick Tools only produce new files. No encoder ever receives an input URL as output.
final class ToolCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
}
struct ToolResult { let url: URL; let detail: String }
enum ShelfQuickTools {
    static let maxInputBytes = 128 * 1024 * 1024
    static let maxPDFPages = 300
    static func validateDestination(_ output: URL, inputs: [URL]) throws {
        guard output.isFileURL else { throw ShelfError.invalid("Choose a local destination for the new copy.") }
        let resolved = output.standardizedFileURL.resolvingSymlinksInPath()
        guard !inputs.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == resolved }) else {
            throw ShelfError.invalid("Choose a different name or folder. Quick Tools never replace an original.")
        }
        var info = stat()
        guard lstat(output.path, &info) != 0, errno == ENOENT else {
            throw ShelfError.invalid("That destination already exists or cannot be checked. Choose a new filename; existing files and aliases are never replaced.")
        }
    }
    static func saveNew(_ data: Data, to output: URL, inputs: [URL], cancel: ToolCancellation, didWriteChunk: (() -> Void)? = nil) throws {
        try cancel.check(); try validateDestination(output, inputs: inputs)
        guard data.count <= maxInputBytes else { throw ShelfError.invalid("The new copy exceeds the 128 MB Quick Tools limit.") }
        // O_EXCL is the final race-safe no-overwrite check, including dangling symlinks.
        let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ShelfError.invalid("The new file could not be created. Choose a new name in a writable folder.") }
        var complete = false, identity = stat(); _ = fstat(descriptor, &identity)
        defer {
            close(descriptor)
            if !complete {
                var current = stat()
                if lstat(output.path, &current) == 0 && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino { _ = unlink(output.path) }
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try cancel.check()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(1024 * 1024, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ShelfError.invalid("The copy could not be saved. Check free space and folder access.") }
                offset += count; didWriteChunk?()
            }
        }
        guard fsync(descriptor) == 0 else { throw ShelfError.invalid("The copy could not be saved completely. Check free space.") }
        try cancel.check(); complete = true
    }
    static func runDitto(_ arguments: [String], cancel: ToolCancellation, log: URL, didLaunch: (() -> Void)? = nil) throws {
        try cancel.check()
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ShelfError.invalid("Could not prepare the ZIP operation.") }
        let errors = try FileHandle(forWritingTo: log); defer { try? errors.close() }
        let process = Process(), ended = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        process.terminationHandler = { _ in ended.signal() }
        try process.run(); didLaunch?()
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        do {
            while ended.wait(timeout: .now() + 0.1) == .timedOut {
                try cancel.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShelfError.invalid("ZIP creation took longer than one minute. Try fewer or smaller files.") }
            }
            try cancel.check()
        } catch {
            if process.isRunning {
                process.terminate()
                if ended.wait(timeout: .now() + 2) == .timedOut, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit() // Worker cleanup and app quit wait until our child is gone.
            throw error
        }
        guard process.terminationStatus == 0 else {
            let handle = try? FileHandle(forReadingFrom: log)
            let detail = handle.flatMap { try? $0.read(upToCount: 2048) }.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            try? handle?.close()
            throw ShelfError.invalid("macOS could not create this ZIP." + (detail.isEmpty ? "" : "\n" + detail))
        }
    }
    static func zipCopy(_ inputs: [URL], to output: URL, cancel: ToolCancellation, didLaunch: (() -> Void)? = nil) throws -> ToolResult {
        guard !inputs.isEmpty, inputs.count <= 100, inputs.allSatisfy(\.isFileURL) else { throw ShelfError.invalid("Choose between 1 and 100 local files or folders for a ZIP.") }
        try validateDestination(output, inputs: inputs); try cancel.check()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ApronZIP-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staging = scratch.appendingPathComponent("Contents", isDirectory: true), archive = scratch.appendingPathComponent("archive.zip")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var bytes = 0, entries = 0, names = Set<String>()
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        func stage(_ source: URL, at destination: URL, depth: Int) throws {
            try cancel.check(); entries += 1
            guard entries <= 4096, depth <= 32, ProcessInfo.processInfo.systemUptime < deadline else { throw ShelfError.invalid("ZIP creation is limited to 4096 entries, 32 folder levels and one minute of preparation. Choose a smaller selection.") }
            var info = stat()
            guard lstat(source.path, &info) == 0 else { throw ShelfError.invalid("\(source.lastPathComponent) is missing or cannot be read.") }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                guard !output.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(sourcePath) else { throw ShelfError.invalid("Save the ZIP outside the folders being archived.") }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                var enumerationError: Error?
                guard let children = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw ShelfError.invalid("\(source.lastPathComponent) could not be read.") }
                // One level at a time keeps depth/count/cancellation checks ahead of each read.
                while let child = children.nextObject() as? URL { try stage(child, at: destination.appendingPathComponent(child.lastPathComponent), depth: depth + 1) }
                // Enumeration failures must not silently create an incomplete archive.
                if let error = enumerationError { throw error }
            } else if kind == S_IFREG {
                let data = try readBoundedFile(source, limit: maxInputBytes - bytes); try cancel.check(); bytes += data.count
                try data.write(to: destination, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: Int(info.st_mode & 0o777), .modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))], ofItemAtPath: destination.path)
            } else { throw ShelfError.invalid("\(source.lastPathComponent) is a symbolic link or special file. ZIP export accepts regular files and folders without links.") }
        }
        for input in inputs {
            let base = input.lastPathComponent
            guard !base.isEmpty, base != "/", base != ".", base != ".." else { throw ShelfError.invalid("Choose individual files or folders rather than an entire volume.") }
            var name = base, suffix = 2
            while !names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted { name = "\(input.deletingPathExtension().lastPathComponent) (\(suffix))" + (input.pathExtension.isEmpty ? "" : "." + input.pathExtension); suffix += 1 }
            try stage(input, at: staging.appendingPathComponent(name), depth: 0)
        }
        try runDitto(["-c", "-k", "--norsrc", "--noextattr", staging.path, archive.path], cancel: cancel, log: scratch.appendingPathComponent("ditto.log"), didLaunch: didLaunch)
        let data = try readBoundedFile(archive, limit: maxInputBytes)
        try saveNew(data, to: output, inputs: inputs, cancel: cancel)
        return ToolResult(url: output, detail: "\(inputs.count) selected items · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))\nOriginal files are unchanged. Duplicate names are numbered in the archive.")
    }
    static func optimizeImage(_ input: URL, to output: URL, jpeg: Bool, maxDimension: Int?, quality: Double, cancel: ToolCancellation) throws -> ToolResult {
        try validateDestination(output, inputs: [input]); try cancel.check()
        let bytes = try readBoundedFile(input, limit: maxInputBytes)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ShelfError.invalid("This image format could not be read by macOS.") }
        guard CGImageSourceGetCount(source) == 1 else { throw ShelfError.invalid("Animated or multi-image files cannot be optimized here. Apron will not discard their frames.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= 100_000, height <= 100_000, Double(width) * Double(height) <= 100_000_000 else { throw ShelfError.invalid("This image exceeds the 100-megapixel Quick Tools input limit.") }
        let dimension = min(maxDimension ?? max(width, height), max(width, height))
        guard dimension > 0, Double(width) * Double(height) * pow(min(1, Double(dimension) / Double(max(width, height))), 2) <= 40_000_000 else { throw ShelfError.invalid("Original size would exceed 40 megapixels. Choose 1920 or 2560 pixels instead.") }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: dimension, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw ShelfError.invalid("macOS could not decode this image.") }
        try cancel.check()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShelfError.invalid("There is not enough memory to optimize this image.") }
        let rectangle = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        if jpeg { canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(rectangle) }
        canvas.draw(decoded, in: rectangle)
        guard let image = canvas.makeImage() else { throw ShelfError.invalid("The new image could not be created.") }
        // A fresh sRGB raster carries no source EXIF, GPS, IPTC, XMP or orientation metadata.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { throw ShelfError.invalid("The chosen image format is unavailable.") }
        let outputProperties: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))] : [:]
        CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ShelfError.invalid("The optimized image could not be encoded.") }
        try cancel.check(); try saveNew(data as Data, to: output, inputs: [input], cancel: cancel)
        let difference = bytes.count - data.length
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.length), countStyle: .file)
        let delta = ByteCountFormatter.string(fromByteCount: Int64(abs(difference)), countStyle: .file)
        let comparison = difference > 0 ? "\(delta) smaller" : difference < 0 ? "\(delta) larger" : "same file size"
        return ToolResult(url: output, detail: "\(image.width) × \(image.height) · \(size) · \(comparison)\nSource metadata and location information removed.")
    }
    static func pageIndices(_ text: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0, pageCount <= maxPDFPages, text.count <= 2048 else { throw ShelfError.invalid("Choose pages from a PDF with 1–300 pages.") }
        var result = [Int](), seen = Set<Int>()
        for part in text.replacingOccurrences(of: "–", with: "-").split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]), first >= 1, first <= pageCount,
                  let last = Int(bounds.last!), last >= first, last <= pageCount else { throw ShelfError.invalid("Use page numbers such as 1, 3–5 within 1–\(pageCount). Reversed or empty ranges are not allowed.") }
            for page in first...last {
                guard seen.insert(page).inserted else { throw ShelfError.invalid("Page \(page) is repeated. List each page only once.") }
                result.append(page - 1)
            }
        }
        return result
    }
    static func pdfCopy(_ inputs: [URL], to output: URL, pages: String? = nil, cancel: ToolCancellation) throws -> ToolResult {
        guard !inputs.isEmpty, inputs.count <= 20, pages == nil || inputs.count == 1 else { throw ShelfError.invalid("Choose at most 20 PDFs, or one PDF for page extraction.") }
        try validateDestination(output, inputs: inputs)
        var documents = [PDFDocument](), byteCount = 0, pageCount = 0
        for url in inputs {
            try cancel.check()
            let data = try readBoundedFile(url, limit: maxInputBytes - byteCount); byteCount += data.count
            guard let document = PDFDocument(data: data) else { throw ShelfError.invalid("\(url.lastPathComponent) is not a readable PDF.") }
            guard !document.isEncrypted && !document.isLocked else { throw ShelfError.invalid("\(url.lastPathComponent) is encrypted or locked. Use an unprotected copy.") }
            guard document.allowsCopying else { throw ShelfError.invalid("\(url.lastPathComponent) does not allow page copying.") }
            pageCount += document.pageCount
            guard document.pageCount > 0, pageCount <= maxPDFPages else { throw ShelfError.invalid("Quick Tools accepts at most 300 total PDF pages.") }
            documents.append(document)
        }
        let outputDocument = PDFDocument()
        for document in documents {
            let indices = try pages.map { try pageIndices($0, pageCount: document.pageCount) } ?? Array(0..<document.pageCount)
            for index in indices {
                try cancel.check()
                guard let page = document.page(at: index)?.copy() as? PDFPage else { throw ShelfError.invalid("A PDF page could not be copied.") }
                outputDocument.insert(page, at: outputDocument.pageCount)
            }
        }
        try cancel.check()
        guard let data = outputDocument.dataRepresentation() else { throw ShelfError.invalid("macOS could not create the new PDF.") }
        try saveNew(data, to: output, inputs: inputs, cancel: cancel)
        return ToolResult(url: output, detail: "\(outputDocument.pageCount) pages · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))\nOriginal PDFs are unchanged.")
    }
}
final class ImageToolOptions: NSView {
    let format = NSPopUpButton(), dimension = NSPopUpButton(), quality = NSSlider(value: 0.82, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    let qualityValue = NSTextField(labelWithString: "82%")
    override init(frame: NSRect) {
        super.init(frame: frame)
        format.addItems(withTitles: ["JPEG", "PNG"]); format.target = self; format.action = #selector(updateQuality(_:))
        dimension.addItems(withTitles: ["1920 pixels", "2560 pixels", "Original dimensions"]); dimension.selectItem(at: 1)
        quality.target = self; quality.action = #selector(updateQuality(_:))
        format.setAccessibilityLabel("Output image format"); dimension.setAccessibilityLabel("Maximum image dimension"); quality.setAccessibilityLabel("JPEG quality")
        let qualityRow = NSStackView(views: [quality, qualityValue]); qualityRow.orientation = .horizontal; qualityRow.spacing = 8
        let rows = [("Format", format as NSView), ("Longest edge", dimension as NSView), ("JPEG quality", qualityRow as NSView)]
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for (title, control) in rows {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            control.widthAnchor.constraint(equalToConstant: 208).isActive = true
            let row = NSStackView(views: [label, control]); row.spacing = 10; stack.addArrangedSubview(row)
        }
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func updateQuality(_ sender: Any?) { quality.isEnabled = format.indexOfSelectedItem == 0; qualityValue.stringValue = "\(Int((quality.doubleValue * 100).rounded()))%"; qualityValue.textColor = quality.isEnabled ? .labelColor : .disabledControlTextColor }
}

struct ShelfRequest: Codable { var paths: [String]; var show: Bool; var appearance: String?; var receiptID: UUID?; var quit: Bool?; var shakeEnabled: Bool?; var style: ShelfStyle? }
struct ShelfResponse: Codable { var ok: Bool; var added: Int; var error: String?; var visible: Bool? = nil; var processID: Int32? = nil; var style: ShelfStyle? = nil }
// flock is held for the lifetime of the process; requests are data-only files in a
// private directory. Vnode notifications are event-driven: Apron does no idle polling.
final class ShelfInstance {
    let inbox: URL
    let receipts: URL
    let descriptor: Int32
    let ownsLock: Bool
    var watch: DispatchSourceFileSystemObject?
    var watchFD: Int32 = -1
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        inbox = directory.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        receipts = directory.appendingPathComponent("Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ShelfError.invalid("Apron could not coordinate access to its saved shelves.") }
        ownsLock = flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
    deinit { watch?.cancel(); close(descriptor) }
    func send(paths: [String], appearance: String? = nil, receiptID: UUID? = nil, show: Bool = true, quit: Bool = false, shakeEnabled: Bool? = nil, style: ShelfStyle? = nil) throws {
        let request = ShelfRequest(paths: paths, show: show, appearance: appearance, receiptID: receiptID, quit: quit, shakeEnabled: shakeEnabled, style: style)
        try JSONEncoder().encode(request).write(to: inbox.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
    }
    func respond(to request: ShelfRequest, with response: ShelfResponse) throws {
        guard let id = request.receiptID else { return }
        try JSONEncoder().encode(response).write(to: receipts.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
    }
    func waitForResponse(_ id: UUID, timeout: TimeInterval = 15) throws -> ShelfResponse {
        let file = receipts.appendingPathComponent(id.uuidString + ".json")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: file.path) {
                let response = try JSONDecoder().decode(ShelfResponse.self, from: readBoundedFile(file, limit: 1024 * 1024))
                try? FileManager.default.removeItem(at: file)
                return response
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw ShelfError.invalid("Apron did not acknowledge the request within 15 seconds. Open Apron to check its state before retrying.")
    }
    func listen(_ receive: @escaping (ShelfRequest) -> Void) {
        func drain() {
            let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let data = try? readBoundedFile(file, limit: 1024 * 1024),
                      let request = try? JSONDecoder().decode(ShelfRequest.self, from: data), request.paths.count <= 4096,
                      request.paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
                      request.appearance == nil || ["system", "light", "dark"].contains(request.appearance!) else { try? FileManager.default.removeItem(at: file); continue }
                // Consume before dispatch: quit may terminate without unwinding Swift
                // defers, and a leftover quit packet would poison the next launch.
                do { try FileManager.default.removeItem(at: file) } catch { continue }
                receive(request)
            }
        }
        watchFD = Darwin.open(inbox.path, O_EVTONLY | O_CLOEXEC)
        guard watchFD >= 0 else { return }
        let fd = watchFD
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler(handler: drain)
        source.setCancelHandler { close(fd) }
        watch = source; source.resume(); drain()
    }
}

struct DragShakeDetector {
    struct Sample { var point: NSPoint; var time: TimeInterval }
    var samples = [Sample]()
    var lastActivation: TimeInterval = -100
    mutating func reset() { samples.removeAll(keepingCapacity: true) }
    mutating func record(_ point: NSPoint, at time: TimeInterval) -> Bool {
        guard time - lastActivation >= 8 else { return false }
        samples.removeAll { time - $0.time > 0.9 }
        samples.append(Sample(point: point, time: time))
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
        guard let first = samples.first, time - first.time >= 0.25, samples.count >= 5 else { return false }
        var direction: CGFloat = 0, extreme = first.point.x, turns = 0, travel: CGFloat = 0
        var previous = first.point.x
        for sample in samples.dropFirst() {
            let x = sample.point.x; travel += abs(x - previous); previous = x
            if direction == 0 {
                if abs(x - extreme) >= 18 { direction = x > extreme ? 1 : -1; extreme = x }
            } else if direction > 0 {
                if x > extreme { extreme = x }
                else if extreme - x >= 18 { turns += 1; direction = -1; extreme = x }
            } else {
                if x < extreme { extreme = x }
                else if x - extreme >= 18 { turns += 1; direction = 1; extreme = x }
            }
        }
        let xs = samples.map { $0.point.x }, ys = samples.map { $0.point.y }
        let width = (xs.max() ?? 0) - (xs.min() ?? 0), height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard turns >= 3, travel >= 220, width >= 55, width <= 300, height <= 180 else { return false }
        lastActivation = time; reset(); return true
    }
}
final class ApronPanel: NSPanel {
    weak var shelf: ShelfController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = shelf; panel.delegate = shelf }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}
final class ShelfGrid: NSCollectionView {
    weak var shelf: ShelfController?
    @objc func copy(_ sender: Any?) { shelf?.copyItems(sender) }
    @objc func paste(_ sender: Any?) { shelf?.pasteItems(sender) }
    @objc func undo(_ sender: Any?) { shelf?.undoShelf(sender) }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            switch event.keyCode {
            case 49: shelf?.preview(nil); return
            case 36, 76: shelf?.openItems(nil); return
            case 51, 117: shelf?.removeItems(nil); return
            case 53: window?.orderOut(nil); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); if event.clickCount == 2 { shelf?.openItems(nil) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let index = indexPathForItem(at: point), !selectionIndexPaths.contains(index) { selectionIndexPaths = [index]; shelf?.selectionChanged() }
        return super.menu(for: event)
    }
}
final class DropSurface: NSView {
    var drawsOpaqueBackground = false { didSet { needsDisplay = true } }
    weak var shelf: ShelfController?
    var isReceiving = false { didSet { needsDisplay = true } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { isReceiving = shelf?.canImport(sender.draggingPasteboard) ?? false; return isReceiving ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { isReceiving ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { isReceiving = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { isReceiving }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { isReceiving = false; return shelf?.importPasteboard(sender.draggingPasteboard, receivingDrag: true) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { isReceiving = false }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if drawsOpaqueBackground { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        if isReceiving {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 15, yRadius: 15)
            path.fill(); NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
        }
    }
}
final class EmptyShelfView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class TileBackground: NSView {
    var selected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
}
final class ShelfThumbnail: NSCollectionViewItem {
    let picture = NSImageView(), nameLabel = NSTextField(wrappingLabelWithString: "")
    var representedID: UUID?, request: QLThumbnailGenerator.Request?
    var imageDimensions = [NSLayoutConstraint]()
    var imageOperation: Operation?, representationKey: NSString?
    var isLoadingImage = false
    static let imageQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated; return queue
    }()
    static let cache = NSCache<NSString, NSImage>()
    override var isSelected: Bool { didSet { (view as? TileBackground)?.selected = isSelected; view.setAccessibilitySelected(isSelected) } }
    override func loadView() {
        view = TileBackground(frame: NSRect(x: 0, y: 0, width: 96, height: 112))
        for subview in [picture, nameLabel] { subview.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(subview) }
        picture.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 10, weight: .regular); nameLabel.alignment = .center; nameLabel.maximumNumberOfLines = 2; nameLabel.lineBreakMode = .byTruncatingMiddle
        imageDimensions = [picture.widthAnchor.constraint(equalToConstant: 60), picture.heightAnchor.constraint(equalToConstant: 60)]
        NSLayoutConstraint.activate(imageDimensions)
        NSLayoutConstraint.activate([
            picture.centerXAnchor.constraint(equalTo: view.centerXAnchor), picture.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4), nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 5), nameLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 29)
        ])
    }
    override func prepareForReuse() {
        super.prepareForReuse(); representedID = nil; representationKey = nil; imageOperation?.cancel(); imageOperation = nil; isLoadingImage = false
        if let request = request { QLThumbnailGenerator.shared.cancel(request) }; request = nil
    }
    func configure(_ item: ShelfItem, url: URL?, style: ShelfStyle) {
        _ = view; imageOperation?.cancel(); imageOperation = nil; isLoadingImage = false
        if let request = request { QLThumbnailGenerator.shared.cancel(request) }; request = nil
        representedID = item.id; representationKey = nil; nameLabel.stringValue = item.name; nameLabel.textColor = .labelColor
        view.setAccessibilityElement(true); view.setAccessibilityRole(.group)
        nameLabel.setAccessibilityElement(false); picture.setAccessibilityElement(false)
        imageDimensions.forEach { $0.constant = style.thumbnailSize }
        nameLabel.font = .systemFont(ofSize: style == .compact ? 10 : 11, weight: .regular)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.contentTintColor = nil
        guard let url = url, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            picture.image = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: "File unavailable"); picture.contentTintColor = .secondaryLabelColor
            let recovery = item.kind == .file ? "Use Locate Original from the item’s menu to reconnect it." : "The saved import is missing. Add it again from its source."
            nameLabel.stringValue = item.name + " · Missing"; nameLabel.textColor = .secondaryLabelColor
            view.toolTip = item.name + " is unavailable. " + recovery
            view.setAccessibilityLabel(item.name + ", missing file"); view.setAccessibilityHelp(recovery); return
        }
        view.toolTip = url.isFileURL ? url.path : url.absoluteString
        let kind = item.kind == .link ? "link" : item.kind == .text ? "text note" : item.kind == .image ? "image" : "file"
        view.setAccessibilityLabel(item.name + ", " + kind)
        view.setAccessibilityHelp("Space to preview. Return to open. Delete removes only the shelf reference.")
        if item.kind == .link {
            picture.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Web link")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: style == .compact ? 28 : 38, weight: .regular)); picture.imageScaling = .scaleNone; picture.contentTintColor = .secondaryLabelColor; return
        }
        picture.image = NSWorkspace.shared.icon(forFile: url.path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return }
        let modified: TimeInterval = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(style.rawValue)|\(modified)" as NSString
        representationKey = key
        if let image = Self.cache.object(forKey: key) { picture.image = image; return }
        Self.cache.totalCostLimit = 24 * 1024 * 1024
        if item.kind == .image || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            // ImageIO downsamples during decoding; no full-resolution NSImage load.
            // Preserve EXIF orientation and bound both pixels and concurrent work.
            let pixelLimit = min(256, Int(style.thumbnailSize * 2))
            let operation = BlockOperation(); isLoadingImage = true
            operation.addExecutionBlock { [weak self, weak operation] in
                guard operation?.isCancelled == false else { return }
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceCreateThumbnailWithTransform: true,
                               kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
                               kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions)
                let thumbnail = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
                guard operation?.isCancelled == false else { return }
                let image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                if let image = image, let thumbnail = thumbnail {
                    Self.cache.setObject(image, forKey: key, cost: thumbnail.width * thumbnail.height * 4)
                }
                DispatchQueue.main.async {
                    guard let self = self, self.representedID == item.id, self.representationKey == key else { return }
                    if let image = image { self.picture.image = image }
                    self.imageOperation = nil; self.isLoadingImage = false
                }
            }
            imageOperation = operation; Self.imageQueue.addOperation(operation); return
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: style.thumbnailSize, height: style.thumbnailSize), scale: 2, representationTypes: [.thumbnail, .icon])
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            if let image = image, representation?.type != .icon {
                Self.cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            }
            DispatchQueue.main.async {
                guard let self = self, self.representedID == item.id, self.representationKey == key else { return }
                if let image = image { self.picture.image = image }; self.request = nil
            }
        }
    }
}

final class ShelfController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate, NSSearchFieldDelegate, NSMenuItemValidation, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let store: ShelfStore, instance: ShelfInstance
    let panel = ApronPanel(contentRect: NSRect(x: 0, y: 0, width: 344, height: 196), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
    let surface = DropSurface(), effect = NSVisualEffectView(), grid = ShelfGrid(), scroll = NSScrollView()
    let empty = EmptyShelfView(), shelfPicker = NSPopUpButton(), count = NSTextField(labelWithString: "0 items")
    let status = NSTextField(labelWithString: "")
    let searchField = NSSearchField(), searchRow = NSView()
    let emptyTitle = NSTextField(labelWithString: "Drop files here"), emptyHint = NSTextField(labelWithString: "or paste with ⌘V")
    var searchHeight: NSLayoutConstraint?
    var visibleItems = [ShelfItem](), selectedIDs = Set<UUID>()
    var updatingSelection = false
    var sharingPicker: NSSharingServicePicker?
    var activeTool: ToolCancellation?
    var quitAfterTool = false
    let queue = OperationQueue()
    var previewURLs = [URL](), pendingReceivers = [UUID: NSFilePromiseReceiver]()
    var lastState: ShelfState?, initialPaths: [String], appearance: String
    var accessibilityObserver: NSObjectProtocol?
    var glass: NSView?
    var style: ShelfStyle
    var toolbar: NSStackView?
    var background: Bool, shakeEnabled: Bool
    var statusItem: NSStatusItem?, statusSummary: NSMenuItem?
    var dragMonitor: Any?, shake = DragShakeDetector()
    var dragPasteboardCount = NSPasteboard(name: .drag).changeCount
    var pendingErrors = [Error]()
    let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    init(store: ShelfStore, instance: ShelfInstance, paths: [String], appearance: String, background: Bool = false, shakeEnabled: Bool = true, style: ShelfStyle = .compact) {
        self.store = store; self.instance = instance; initialPaths = paths; self.appearance = appearance; self.background = background; self.shakeEnabled = shakeEnabled; self.style = style
        super.init(); queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow(); buildMenu(); buildStatusItem(); configureDragMonitor(); refresh()
        if !initialPaths.isEmpty { perform { try store.addFiles(initialPaths.map { URL(fileURLWithPath: $0) }) } }
        instance.listen { [weak self] request in
            guard let self = self else { return }
            if request.quit == true { NSApp.terminate(nil); return }
            if let enabled = request.shakeEnabled { self.shakeEnabled = enabled; self.configureDragMonitor() }
            if let style = request.style, style != self.style { self.applyStyle(style) }
            let previousCount = self.store.items.count
            var response = ShelfResponse(ok: true, added: 0, error: nil)
            if !request.paths.isEmpty {
                let before = self.store.state
                do {
                    try self.store.addFiles(request.paths.map { URL(fileURLWithPath: $0) })
                    if before != self.store.state { self.lastState = before }
                    response.added = self.store.items.count - previousCount
                    self.refresh()
                } catch {
                    response = ShelfResponse(ok: false, added: 0, error: error.localizedDescription)
                    self.status.stringValue = error.localizedDescription
                    if request.receiptID == nil { self.report(error) }
                }
            }
            if let appearance = request.appearance {
                self.appearance = appearance
                self.panel.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
                self.updateAccessibility()
            }
            if request.show { self.show() }
            response.visible = self.panel.isVisible; response.processID = getpid(); response.style = self.style
            do { try self.instance.respond(to: request, with: response) } catch { self.report(error) }
        }
        if !background { show() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let tool = activeTool else { return .terminateNow }
        quitAfterTool = true; tool.cancel()
        statusSummary?.title = "Cancelling Quick Tool before quitting…"
        // All menu, IPC and system quit requests wait for the worker's write cleanup.
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = dragMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        instance.watch?.cancel()
    }
    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Apron file shelf")
        icon?.isTemplate = true; item.button?.image = icon; item.button?.toolTip = "Apron — File shelf"
        let menu = NSMenu()
        addMenu(menu, "Open Apron", #selector(showShelf(_:)))
        statusSummary = NSMenuItem(title: "File shelf", action: nil, keyEquivalent: ""); statusSummary?.isEnabled = false
        menu.addItem(statusSummary!); menu.addItem(.separator())
        addMenu(menu, "Add Files…", #selector(showAddFiles(_:)))
        addMenu(menu, "Paste into Shelf", #selector(showAndPaste(_:)))
        menu.addItem(.separator())
        addMenu(menu, "Quit Apron", #selector(quitShelf(_:)))
        item.menu = menu; statusItem = item
    }
    @objc func showShelf(_ sender: Any?) { show() }
    @objc func showAddFiles(_ sender: Any?) { show(); addFiles(sender) }
    @objc func showAndPaste(_ sender: Any?) { show(); pasteItems(sender) }
    @objc func quitShelf(_ sender: Any?) { NSApp.terminate(nil) }
    func configureDragMonitor() {
        if let monitor = dragMonitor { NSEvent.removeMonitor(monitor); dragMonitor = nil }
        shake.reset(); dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        guard shakeEnabled else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            let pasteboard = NSPasteboard(name: .drag)
            if event.type != .leftMouseDragged {
                self.shake.reset(); self.dragPasteboardCount = pasteboard.changeCount; return
            }
            guard !self.panel.isVisible, pasteboard.changeCount != self.dragPasteboardCount, self.canImport(pasteboard) else { return }
            if self.shake.record(NSEvent.mouseLocation, at: event.timestamp) { self.summonDuringDrag() }
        }
        // A denied/unavailable monitor simply leaves the hotkey and menu available.
    }
    func summonDuringDrag() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            let size = panel.frame.size
            let x = min(max(point.x + 24, bounds.minX + 16), max(bounds.minX + 16, bounds.maxX - size.width - 16))
            let y = min(max(point.y - size.height + 72, bounds.minY + 16), max(bounds.minY + 16, bounds.maxY - size.height - 16))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        refresh(); panel.orderFrontRegardless()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        perform { try store.addFiles(filenames.map { URL(fileURLWithPath: $0) }) }; show(); sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowShouldClose(_ sender: NSWindow) -> Bool { QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared()?.orderOut(nil) : (); sender.orderOut(nil); return false }
    func windowDidBecomeKey(_ notification: Notification) { refresh(preservingSelection: true) }
    func show() { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); panel.makeFirstResponder(grid) }
    func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; return field
    }
    func button(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
        button.bezelStyle = .texturedRounded; button.toolTip = title; button.setAccessibilityLabel(title); return button
    }
    func buildWindow(fixture: Bool = false) {
        panel.shelf = self; panel.delegate = self; panel.title = "Apron — File shelf"
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: style.width, height: 154); panel.maxSize = NSSize(width: 656, height: 660)
        if !fixture { panel.setFrameAutosaveName("ApronTray"); if !panel.setFrameUsingName("ApronTray") { panel.center() } }
        if appearance == "dark" { panel.appearance = NSAppearance(named: .darkAqua) }
        if appearance == "light" { panel.appearance = NSAppearance(named: .aqua) }
        panel.contentView = surface; surface.shelf = self; surface.registerForDraggedTypes(dragTypes)
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(effect, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([effect.leadingAnchor.constraint(equalTo: surface.leadingAnchor), effect.trailingAnchor.constraint(equalTo: surface.trailingAnchor), effect.topAnchor.constraint(equalTo: surface.topAnchor), effect.bottomAnchor.constraint(equalTo: surface.bottomAnchor)])
        surface.wantsLayer = true; surface.layer?.cornerRadius = style.radius; surface.layer?.masksToBounds = true; updateAccessibility()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateAccessibility() }
        shelfPicker.target = self; shelfPicker.action = #selector(changeShelf(_:)); shelfPicker.isBordered = false
        shelfPicker.font = .systemFont(ofSize: style == .compact ? 11 : 12, weight: .regular); shelfPicker.setAccessibilityLabel("Current shelf")
        shelfPicker.toolTip = "Apron · Switch shelves"
        count.font = .systemFont(ofSize: 10, weight: .regular); count.textColor = .tertiaryLabelColor
        let close = button("xmark", title: "Close shelf (⌘W)", action: #selector(closeShelf(_:)))
        let add = button("plus", title: "Add files (⌘O)", action: #selector(addFiles(_:)))
        let more = button("ellipsis", title: "Shelf actions", action: #selector(shelfMenu(_:)))
        let find = button("magnifyingglass", title: "Find in shelf (⌘F)", action: #selector(findItems(_:)))
        for button in [close, find, add, more] {
            button.isBordered = false; button.contentTintColor = .secondaryLabelColor
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let toolbar = NSStackView(views: [close, shelfPicker, NSView(), count, find, add, more]); toolbar.orientation = .horizontal; toolbar.spacing = 4; self.toolbar = toolbar
        shelfPicker.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = style.tileSize
        layout.minimumInteritemSpacing = style.gap; layout.minimumLineSpacing = style.gap; layout.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        grid.frame = NSRect(x: 0, y: 0, width: style.width - 16, height: style.tileSize.height + style.gap); grid.autoresizingMask = [.width]
        grid.collectionViewLayout = layout; grid.shelf = self; grid.backgroundColors = [.clear]
        grid.isSelectable = true; grid.allowsMultipleSelection = true; grid.dataSource = self; grid.delegate = self
        grid.register(ShelfThumbnail.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("Thumbnail"))
        grid.registerForDraggedTypes(dragTypes); grid.setDraggingSourceOperationMask(.copy, forLocal: false); grid.setDraggingSourceOperationMask(.copy, forLocal: true)
        grid.setAccessibilityLabel("Shelf files"); grid.setAccessibilityHelp("Select files and drag them out together. Space previews, Return opens, Delete removes from the shelf.")
        let menu = NSMenu(); menu.delegate = self; grid.menu = menu
        scroll.documentView = grid; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let dropIcon = NSImageView(image: NSImage(systemSymbolName: "tray", accessibilityDescription: nil)!); dropIcon.contentTintColor = .secondaryLabelColor; dropIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
        emptyHint.font = .systemFont(ofSize: 11); emptyHint.textColor = .tertiaryLabelColor
        searchField.placeholderString = "Find in shelf"; searchField.delegate = self
        searchField.target = self; searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true; searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("Find in current shelf"); searchField.toolTip = "Search names and paths. Escape clears, then closes search."
        searchField.font = .systemFont(ofSize: 11); searchField.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchField); searchRow.isHidden = true
        searchHeight = searchRow.heightAnchor.constraint(equalToConstant: 0); searchHeight?.isActive = true
        NSLayoutConstraint.activate([searchField.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor), searchField.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor), searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor)])
        let emptyContent = NSStackView(views: [dropIcon, emptyTitle, emptyHint]); emptyContent.orientation = .vertical; emptyContent.spacing = 7; emptyContent.alignment = .centerX
        emptyContent.translatesAutoresizingMaskIntoConstraints = false; empty.addSubview(emptyContent)
        NSLayoutConstraint.activate([emptyContent.centerXAnchor.constraint(equalTo: empty.centerXAnchor), emptyContent.centerYAnchor.constraint(equalTo: empty.centerYAnchor, constant: -5), dropIcon.widthAnchor.constraint(equalToConstant: 32), dropIcon.heightAnchor.constraint(equalToConstant: 32)])
        for view in [toolbar, searchRow, scroll, empty] { view.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12), toolbar.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10), toolbar.heightAnchor.constraint(equalToConstant: 26),
            searchRow.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16), searchRow.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16), searchRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8), scroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 4), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), empty.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), empty.topAnchor.constraint(equalTo: scroll.topAnchor), empty.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ])
        applyStyle(style)
    }
    func applyStyle(_ next: ShelfStyle) {
        style = next
        panel.minSize = NSSize(width: style.width, height: 154)
        var frame = panel.frame; frame.size.width = style.width; panel.setFrame(frame, display: true, animate: false)
        shelfPicker.font = .systemFont(ofSize: style == .compact ? 11 : 12, weight: .regular)
        toolbar?.spacing = style == .compact ? 4 : 7
        surface.layer?.cornerRadius = style.radius
        if let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = style.tileSize; layout.minimumInteritemSpacing = style.gap; layout.minimumLineSpacing = style.gap
            layout.sectionInset = NSEdgeInsets(top: style == .compact ? 2 : 10, left: 8, bottom: 8, right: 8)
            layout.invalidateLayout()
        }
        updateAccessibility(); refresh(preservingSelection: true)
    }
    func fitTray() {
        let columns = max(3, Int((panel.frame.width - 24) / (style.tileSize.width + style.gap)))
        let rows = min(4, max(1, Int(ceil(Double(visibleItems.count) / Double(columns)))))
        let height: CGFloat = (visibleItems.isEmpty ? (style == .compact ? 154 : 204) : CGFloat(rows) * (style.tileSize.height + style.gap) + (style == .compact ? 48 : 66)) + (searchRow.isHidden ? 0 : 28)
        var frame = panel.frame; frame.origin.y += frame.height - height; frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }
    func updateAccessibility() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        var usesGlass = false
        effect.material = style == .compact ? .popover : .underWindowBackground
        if opaque || style == .compact {
            if let backdrop = glass, backdrop.value(forKey: "contentView") as? NSView === surface {
                backdrop.setValue(nil, forKey: "contentView"); panel.contentView = surface
            }
        } else {
            // Public runtime lookup also compiles with older macOS SDKs. These are
            // public NSGlassEffectView properties, guarded before KVC is used.
            if glass == nil, #available(macOS 26.0, *), let type = NSClassFromString("NSGlassEffectView") as? NSView.Type {
                let backdrop = type.init()
                if backdrop.responds(to: NSSelectorFromString("setContentView:")),
                   backdrop.responds(to: NSSelectorFromString("contentView")),
                   backdrop.responds(to: NSSelectorFromString("setCornerRadius:")) {
                    backdrop.setValue(style.radius, forKey: "cornerRadius"); glass = backdrop
                }
            }
            if let backdrop = glass {
                backdrop.setValue(style.radius, forKey: "cornerRadius")
                if backdrop.responds(to: NSSelectorFromString("setStyle:")) { backdrop.setValue(1, forKey: "style") }
                if backdrop.value(forKey: "contentView") as? NSView !== surface {
                    panel.contentView = backdrop; backdrop.setValue(surface, forKey: "contentView")
                }
                usesGlass = true
            }
        }
        effect.isHidden = opaque || usesGlass; surface.drawsOpaqueBackground = opaque
        surface.layer?.backgroundColor = NSColor.clear.cgColor
        panel.isOpaque = opaque; panel.backgroundColor = opaque ? .windowBackgroundColor : .clear
        // No repeating animations. All state changes remain immediate with Reduce Motion.
    }
    func buildMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem(), fileItem = NSMenuItem()
        main.addItem(appItem); main.addItem(fileItem); main.addItem(editItem)
        let app = NSMenu(title: "Apron"); appItem.submenu = app
        app.addItem(withTitle: "About Apron", action: #selector(about(_:)), keyEquivalent: "").target = self
        app.addItem(.separator()); app.addItem(withTitle: "Hide Apron", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Apron", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File"); fileItem.submenu = file
        addMenu(file, "Add Files…", #selector(addFiles(_:)), key: "o")
        addMenu(file, "New Shelf…", #selector(newShelf(_:)), key: "n")
        addMenu(file, "Share…", #selector(shareItems(_:)))
        addMenu(file, "Close Shelf Window", #selector(closeShelf(_:)), key: "w")
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: #selector(ShelfGrid.undo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Copy Items", action: #selector(ShelfGrid.copy(_:)), keyEquivalent: "c")
        let contents = addMenu(edit, "Copy Contents", #selector(copyContents(_:)), key: "c"); contents.keyEquivalentModifierMask = [.command, .shift]
        addMenu(edit, "Find in Shelf…", #selector(findItems(_:)), key: "f")
        edit.addItem(withTitle: "Paste", action: #selector(ShelfGrid.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }
    @discardableResult func addMenu(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    var selected: [ShelfItem] { grid.selectionIndexPaths.sorted { $0.item < $1.item }.compactMap { visibleItems.indices.contains($0.item) ? visibleItems[$0.item] : nil } }
    static func matchingItems(_ items: [ShelfItem], query: String) -> [ShelfItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.isEmpty ? items : items.filter { item in terms.allSatisfy { item.name.localizedStandardContains($0) || item.location.localizedStandardContains($0) } }
    }
    func refresh(preservingSelection: Bool = false) {
        if !preservingSelection { selectedIDs.removeAll() }
        selectedIDs.formIntersection(Set(store.items.map(\.id)))
        shelfPicker.removeAllItems()
        for group in store.state.groups { shelfPicker.addItem(withTitle: group.name) }
        shelfPicker.selectItem(at: store.groupIndex)
        let shelfName = store.state.groups[store.groupIndex].name
        panel.title = "Apron — " + shelfName
        shelfPicker.setAccessibilityLabel("Shelf: " + shelfName); shelfPicker.setAccessibilityHelp("Choose a shelf. Use Shelf actions to rename or create one.")
        grid.setAccessibilityLabel(shelfName + " · Shelf items")
        updatingSelection = true
        visibleItems = Self.matchingItems(store.items, query: searchField.stringValue)
        grid.reloadData()
        grid.selectionIndexPaths = Set(visibleItems.indices.filter { selectedIDs.contains(visibleItems[$0].id) }.map { IndexPath(item: $0, section: 0) })
        updatingSelection = false
        empty.isHidden = !visibleItems.isEmpty; scroll.isHidden = visibleItems.isEmpty
        let filtering = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        emptyTitle.stringValue = filtering ? "No matching items" : "Drop files here"
        emptyHint.stringValue = filtering ? "Try another name or clear search" : "or paste with ⌘V"
        empty.setAccessibilityElement(true); empty.setAccessibilityRole(.group)
        empty.setAccessibilityLabel(shelfName + (filtering ? ": no matching items" : ": empty shelf"))
        empty.setAccessibilityHelp(filtering ? "Clear the search field to show all items. Escape clears search." : "Drop files here, paste with Command V, or use Add files with Command O. Original files remain in place.")
        count.stringValue = filtering ? "\(visibleItems.count)/\(store.items.count)" : "\(store.items.count)"; count.isHidden = store.items.isEmpty
        count.setAccessibilityLabel("\(visibleItems.count) of \(store.items.count) items")
        fitTray()
        statusSummary?.title = "\(store.items.count) items · \(store.state.groups[store.groupIndex].name)"
        updateSelectionStatus()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true { updatePreview() }
    }
    @objc func findItems(_ sender: Any?) {
        searchRow.isHidden = false; searchHeight?.constant = 28; fitTray()
        panel.makeFirstResponder(searchField); searchField.selectText(nil)
    }
    @objc func searchChanged(_ sender: Any?) { refresh(preservingSelection: true) }
    func controlTextDidChange(_ notification: Notification) { refresh(preservingSelection: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if searchField.stringValue.isEmpty { searchRow.isHidden = true; searchHeight?.constant = 0; panel.makeFirstResponder(grid) }
            else { searchField.stringValue = "" }
            refresh(preservingSelection: true); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)) { panel.makeFirstResponder(grid); return true }
        return false
    }
    func perform(_ operation: () throws -> Void) {
        let before = store.state
        do { try operation(); if before != store.state { lastState = before }; refresh() }
        catch { report(error) }
    }
    func report(_ error: Error) { status.stringValue = error.localizedDescription; pendingErrors.append(error); presentNextError() }
    func presentNextError() {
        guard panel.attachedSheet == nil, !pendingErrors.isEmpty else { return }
        let alert = NSAlert(error: pendingErrors.removeFirst())
        alert.beginSheetModal(for: panel) { [weak self] _ in DispatchQueue.main.async { self?.presentNextError() } }
    }
    func windowDidEndSheet(_ notification: Notification) { DispatchQueue.main.async { [weak self] in self?.presentNextError() } }
    func updateSelectionStatus() {
        status.stringValue = selected.isEmpty ? "Original files stay where they are" : "\(selected.count) selected · Ready to drag out"
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { visibleItems.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("Thumbnail"), for: indexPath) as! ShelfThumbnail
        let item = visibleItems[indexPath.item]; cell.configure(item, url: store.url(for: item), style: style); return cell
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func selectionChanged() {
        guard !updatingSelection else { return }
        selectedIDs.subtract(visibleItems.map(\.id)); selectedIDs.formUnion(selected.map(\.id))
        updateSelectionStatus(); if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true { updatePreview() } }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard visibleItems.indices.contains(indexPath.item), let url = store.url(for: visibleItems[indexPath.item]), !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url as NSURL
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if info.draggingSource as AnyObject? === grid { return [] }
        return canImport(info.draggingPasteboard) ? .copy : []
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool { importPasteboard(info.draggingPasteboard, receivingDrag: true) }
    func canImport(_ pasteboard: NSPasteboard) -> Bool { pasteboard.availableType(from: dragTypes) != nil }
    @discardableResult func importPasteboard(_ pasteboard: NSPasteboard, receivingDrag: Bool = false) -> Bool {
        // AppKit raises an exception if promises are received outside a real drag callback.
        if receivingDrag, let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receivePromises(receivers); return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            perform { try store.addFiles(urls) }; return true
        }
        if let data = pasteboard.data(forType: .png) {
            perform { try store.addData(data, name: "Image.png", kind: .image) }; return true
        }
        if let data = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            perform { try store.addData(png, name: "Image.png", kind: .image) }; return true
        }
        if let value = pasteboard.string(forType: .URL), let url = URL(string: value), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            perform { try store.addLink(url) }; return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), !trimmed.contains(where: \.isWhitespace), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { perform { try store.addLink(url) } }
            else { perform { try store.addText(text) } }; return true
        }
        status.stringValue = pasteboard.availableType(from: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }) != nil ? "Drag this attachment into Apron to receive its file" : "Copy a file, image, text or web link first"; return false
    }
    func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let groupID = store.state.active
        guard receivers.count <= 4096 else { report(ShelfError.invalid("Too many promised files in one drop.")); return }
        status.stringValue = "Receiving files…"
        // AppKit requires every receiver from the same drag to share a destination.
        // fileNames is intentionally empty until receivePromisedFiles is called.
        let folder = store.imports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        catch { report(error); return }
        for receiver in receivers {
            let id = UUID()
            pendingReceivers[id] = receiver
            var completed = 0
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { [weak self] url, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    completed += 1
                    if let error = error { self.report(error) }
                    else { self.perform { try self.store.receive(url, in: folder, groupID: groupID) } }
                    if completed >= max(1, receiver.fileNames.count) { self.pendingReceivers.removeValue(forKey: id) }
                }
            }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hasSelection = !selected.isEmpty
        addMenu(menu, "Quick Look", #selector(preview(_:))).isEnabled = hasSelection
        addMenu(menu, "Open", #selector(openItems(_:))).isEnabled = hasSelection
        addMenu(menu, "Reveal in Finder", #selector(revealItems(_:))).isEnabled = hasSelection
        menu.addItem(.separator())
        addMenu(menu, "Share…", #selector(shareItems(_:))).isEnabled = hasSelection
        addMenu(menu, "Copy Items", #selector(copyItems(_:))).isEnabled = hasSelection
        addMenu(menu, "Copy Contents", #selector(copyContents(_:))).isEnabled = canCopyContents
        addMenu(menu, "Copy Paths / Links", #selector(copyPaths(_:))).isEnabled = hasSelection
        if selected.count == 1, selected[0].kind == .file { addMenu(menu, "Locate Original…", #selector(locateOriginal(_:))) }
        if store.state.groups.count > 1 && hasSelection {
            let move = NSMenuItem(title: "Move to Shelf", action: nil, keyEquivalent: ""), submenu = NSMenu()
            for group in store.state.groups where group.id != store.state.active {
                let item = addMenu(submenu, group.name, #selector(moveItems(_:))); item.representedObject = group.id.uuidString
            }
            move.submenu = submenu; menu.addItem(move)
        }
        menu.addItem(.separator())
        addQuickTools(to: menu)
        menu.addItem(.separator())
        addMenu(menu, "Remove from Shelf", #selector(removeItems(_:))).isEnabled = hasSelection
        menu.autoenablesItems = false
    }
    var selectedLocalURLs: [URL] { selected.compactMap(store.url).filter(\.isFileURL) }
    func addQuickTools(to menu: NSMenu) {
        let item = NSMenuItem(title: "Quick Tools", action: nil, keyEquivalent: ""), tools = NSMenu()
        let urls = selectedLocalURLs, idle = activeTool == nil && panel.attachedSheet == nil
        let image = urls.count == 1 && selected.count == 1 && UTType(filenameExtension: urls[0].pathExtension)?.conforms(to: .image) == true
        let pdfs = !urls.isEmpty && urls.count == selected.count && urls.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
        addMenu(tools, "Optimize Image…", #selector(optimizeImage(_:))).isEnabled = idle && image
        addMenu(tools, "Merge PDFs…", #selector(mergePDFs(_:))).isEnabled = idle && pdfs && urls.count >= 2 && urls.count <= 20
        addMenu(tools, "Extract PDF Pages…", #selector(extractPDFPages(_:))).isEnabled = idle && pdfs && urls.count == 1
        tools.addItem(.separator())
        addMenu(tools, "Create ZIP…", #selector(createZIP(_:))).isEnabled = idle && !urls.isEmpty && urls.count == selected.count && urls.count <= 100
        if activeTool != nil { tools.addItem(.separator()); addMenu(tools, "Cancel Current Tool", #selector(cancelQuickTool(_:))) }
        tools.autoenablesItems = false; item.submenu = tools; menu.addItem(item)
    }
    @objc func createZIP(_ sender: Any?) {
        let inputs = selectedLocalURLs
        guard activeTool == nil, panel.attachedSheet == nil, !inputs.isEmpty, inputs.count == selected.count, inputs.count <= 100 else { return }
        let groupID = store.state.active, alert = NSAlert()
        alert.messageText = "Create ZIP"
        alert.informativeText = "Archive \(inputs.count) selected files or folders into a new ZIP. Originals stay in place.\n\nUp to 128 MB and 4096 entries. Symbolic links and special files are not included; selecting one stops the operation. File contents, names and folders are preserved; Mac resource forks and extended attributes are omitted."
        alert.addButton(withTitle: "Choose Destination…"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = inputs.count == 1 ? inputs[0].deletingPathExtension().lastPathComponent + ".zip" : "Shelf files.zip"
            self.chooseToolDestination(name: name, type: .zip, inputs: inputs) { output in
                self.runQuickTool(title: "Creating ZIP…", successTitle: "ZIP saved", groupID: groupID) { cancel in
                    try ShelfQuickTools.zipCopy(inputs, to: output, cancel: cancel)
                }
            }
        }
    }
    @objc func optimizeImage(_ sender: Any?) {
        guard activeTool == nil, panel.attachedSheet == nil, selected.count == 1, let input = selectedLocalURLs.first else { return }
        let groupID = store.state.active, alert = NSAlert(), options = ImageToolOptions(frame: NSRect(x: 0, y: 0, width: 310, height: 106))
        alert.messageText = "Optimize Image"
        alert.informativeText = "Save a new copy. Source metadata, including GPS location, will be removed. JPEG uses a white background for transparency. Animated and multi-image files are not supported."
        alert.accessoryView = options; alert.addButton(withTitle: "Choose Destination…"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let jpeg = options.format.indexOfSelectedItem == 0
            let size: Int? = [1920, 2560, nil][options.dimension.indexOfSelectedItem]
            let quality = options.quality.doubleValue
            self.chooseToolDestination(name: input.deletingPathExtension().lastPathComponent + " optimized." + (jpeg ? "jpg" : "png"), type: jpeg ? .jpeg : .png, inputs: [input]) { output in
                self.runQuickTool(title: "Optimizing image…", successTitle: "Image copy saved", groupID: groupID) { cancel in
                    try ShelfQuickTools.optimizeImage(input, to: output, jpeg: jpeg, maxDimension: size, quality: quality, cancel: cancel)
                }
            }
        }
    }
    @objc func mergePDFs(_ sender: Any?) {
        let inputs = selectedLocalURLs
        guard activeTool == nil, panel.attachedSheet == nil, (2...20).contains(inputs.count), inputs.count == selected.count else { return }
        let groupID = store.state.active, alert = NSAlert()
        alert.messageText = "Merge \(inputs.count) PDFs"
        alert.informativeText = "Pages will follow the visible shelf order:\n\n" + inputs.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }.joined(separator: "\n") + "\n\nUp to 300 pages and 128 MB in total. Originals are unchanged. The new PDF does not retain document signatures or bookmarks."
        alert.addButton(withTitle: "Choose Destination…"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.chooseToolDestination(name: "Merged.pdf", type: .pdf, inputs: inputs) { output in
                self.runQuickTool(title: "Merging PDFs…", successTitle: "Merged PDF saved", groupID: groupID) { cancel in
                    try ShelfQuickTools.pdfCopy(inputs, to: output, cancel: cancel)
                }
            }
        }
    }
    @objc func extractPDFPages(_ sender: Any?) {
        guard activeTool == nil, panel.attachedSheet == nil, selected.count == 1, let input = selectedLocalURLs.first else { return }
        let groupID = store.state.active, alert = NSAlert(), pages = NSTextField(string: "1")
        alert.messageText = "Extract PDF Pages"
        alert.informativeText = "Enter page numbers or ranges, such as 1, 3–5. Pages are copied in the order entered, without repeats.\n\nUp to 300 source pages and 128 MB. Originals are unchanged. The new PDF does not retain document signatures or bookmarks."
        pages.frame = NSRect(x: 0, y: 0, width: 310, height: 24); pages.placeholderString = "1, 3–5"; pages.setAccessibilityLabel("Pages to extract")
        alert.accessoryView = pages; alert.addButton(withTitle: "Choose Destination…"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let range = pages.stringValue
            do { _ = try ShelfQuickTools.pageIndices(range, pageCount: ShelfQuickTools.maxPDFPages) }
            catch { self.report(error); return }
            self.chooseToolDestination(name: input.deletingPathExtension().lastPathComponent + " pages.pdf", type: .pdf, inputs: [input]) { output in
                self.runQuickTool(title: "Extracting PDF pages…", successTitle: "PDF pages saved", groupID: groupID) { cancel in
                    try ShelfQuickTools.pdfCopy([input], to: output, pages: range, cancel: cancel)
                }
            }
        }
        alert.window.makeFirstResponder(pages)
    }
    func chooseToolDestination(name: String, type: UTType, inputs: [URL], completion: @escaping (URL) -> Void) {
        let save = NSSavePanel(); save.nameFieldStringValue = name; save.allowedContentTypes = [type]; save.canCreateDirectories = true
        save.directoryURL = inputs.first?.deletingLastPathComponent()
        save.prompt = "Save New Copy"; save.message = "Choose a new filename. Existing files, including the originals, will never be replaced."
        save.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let output = save.url else { return }
            do { try ShelfQuickTools.validateDestination(output, inputs: inputs); completion(output) }
            catch { self?.report(error) }
        }
    }
    @objc func cancelQuickTool(_ sender: Any?) { activeTool?.cancel(); statusSummary?.title = "Cancelling Quick Tool…" }
    func runQuickTool(title: String, successTitle: String, groupID: UUID, work: @escaping (ToolCancellation) throws -> ToolResult) {
        guard activeTool == nil else { return }
        let cancel = ToolCancellation(), progress = NSAlert(); activeTool = cancel
        progress.messageText = title; progress.informativeText = "Creating a new copy. Your original files stay unchanged. Cancelling may take a moment while macOS finishes the current file, page or image."
        progress.addButton(withTitle: "Cancel"); statusSummary?.title = title
        progress.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertFirstButtonReturn, self?.activeTool === cancel { self?.cancelQuickTool(nil) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try autoreleasepool { try work(cancel) } }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activeTool = nil
                if let parent = progress.window.sheetParent { parent.endSheet(progress.window, returnCode: .alertSecondButtonReturn) }
                if self.quitAfterTool { NSApp.reply(toApplicationShouldTerminate: true); return }
                DispatchQueue.main.async {
                    guard !self.quitAfterTool else { return }
                    switch result {
                    case .success(let output):
                        do {
                            let before = self.store.state
                            try self.store.addFiles([output.url], groupID: groupID); try self.store.selectGroup(groupID)
                            self.lastState = before; self.searchField.stringValue = ""
                            self.selectedIDs = Set(self.store.items.filter { self.store.url(for: $0) == output.url }.map(\.id))
                            self.refresh(preservingSelection: true)
                            let notice = NSAlert(); notice.messageText = successTitle; notice.informativeText = output.url.lastPathComponent + "\n\n" + output.detail
                            notice.addButton(withTitle: "Done"); notice.beginSheetModal(for: self.panel)
                        } catch { self.report(ShelfError.invalid("The copy was saved at \(output.url.path), but could not be added to its shelf: \(error.localizedDescription)")) }
                    case .failure(let error):
                        self.refresh(preservingSelection: true)
                        if !(error is CancellationError) { self.report(error) }
                    }
                }
            }
        }
    }
    @objc func addFiles(_ sender: Any?) {
        let open = NSOpenPanel(); open.canChooseDirectories = true; open.canChooseFiles = true; open.allowsMultipleSelection = true; open.prompt = "Add to Shelf"; open.message = "Original files stay in their current location."
        open.beginSheetModal(for: panel) { [weak self] response in guard response == .OK, let self = self else { return }; self.perform { try self.store.addFiles(open.urls) } }
    }
    @objc func pasteItems(_ sender: Any?) { importPasteboard(.general) }
    @objc func closeShelf(_ sender: Any?) { if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }; panel.orderOut(nil) }
    @objc func changeShelf(_ sender: Any?) {
        do { try store.selectGroup(store.state.groups[shelfPicker.indexOfSelectedItem].id); searchField.stringValue = ""; refresh() }
        catch { report(error) }
    }
    @objc func openItems(_ sender: Any?) {
        for item in selected {
            guard let url = store.url(for: item), !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else { report(ShelfError.invalid("\(item.name) is unavailable. Use Locate Original to reconnect it.")); return }
            if !NSWorkspace.shared.open(url) { report(ShelfError.invalid("macOS could not open \(item.name).")); return }
        }
    }
    @objc func revealItems(_ sender: Any?) { let urls = selected.compactMap(store.url).filter { $0.isFileURL }; if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) } }
    @objc func copyItems(_ sender: Any?) {
        let urls = selected.compactMap(store.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls.map { $0 as NSURL }); status.stringValue = "Copied \(urls.count) \(urls.count == 1 ? "item" : "items")"
    }
    var canCopyContents: Bool { selected.count == 1 && [.text, .image, .link].contains(selected[0].kind) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyContents(_:)) { return canCopyContents }
        if menuItem.action == #selector(shareItems(_:)) { return !selected.isEmpty }
        return true
    }
    @objc func shareItems(_ sender: Any?) {
        let urls = selected.compactMap(store.url)
        guard !urls.isEmpty else { return }
        guard urls.allSatisfy({ !$0.isFileURL || FileManager.default.fileExists(atPath: $0.path) }) else { report(ShelfError.invalid("A selected file is unavailable. Locate its original before sharing.")); return }
        sharingPicker = NSSharingServicePicker(items: urls)
        let anchor = toolbar ?? surface
        sharingPicker?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    func writeContents(of item: ShelfItem, to pasteboard: NSPasteboard) throws {
        guard let url = store.url(for: item) else { throw ShelfError.invalid("This item is unavailable.") }
        let payload = NSPasteboardItem()
        switch item.kind {
        case .link:
            payload.setString(url.absoluteString, forType: .URL); payload.setString(url.absoluteString, forType: .string)
        case .text:
            let data = try readBoundedFile(url, limit: 16 * 1024 * 1024)
            guard let text = String(data: data, encoding: .utf8) else { throw ShelfError.invalid("This note could not be read as text.") }
            payload.setString(text, forType: .string)
        case .image:
            let data = try readBoundedFile(url, limit: 128 * 1024 * 1024)
            payload.setData(data, forType: .png)
        default: throw ShelfError.invalid("Copy Contents is available for one imported note, image or link.")
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([payload]) else { throw ShelfError.invalid("macOS could not copy this item’s contents.") }
    }
    @objc func copyContents(_ sender: Any?) {
        guard canCopyContents, let item = selected.first else { return }
        do { try writeContents(of: item, to: .general); status.stringValue = "Copied contents" }
        catch { report(error) }
    }
    @objc func copyPaths(_ sender: Any?) {
        let paths = selected.compactMap(store.url).map { $0.isFileURL ? $0.path : $0.absoluteString }
        guard !paths.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string); status.stringValue = "Copied paths and links"
    }
    @objc func removeItems(_ sender: Any?) { let ids = Set(selected.map(\.id)); if !ids.isEmpty { perform { try store.remove(ids: ids) } } }
    @objc func undoShelf(_ sender: Any?) { guard let snapshot = lastState else { return }; perform { try store.restore(snapshot) } }
    @objc func moveItems(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value), let destination = store.state.groups.firstIndex(where: { $0.id == id }) else { return }
        let selection = selected, ids = Set(selection.map(\.id)), source = store.groupIndex
        perform { try store.change { $0.groups[source].items.removeAll { ids.contains($0.id) }; $0.groups[destination].items.append(contentsOf: selection) } }
    }
    @objc func locateOriginal(_ sender: Any?) {
        guard let item = selected.first, item.kind == .file else { return }
        let open = NSOpenPanel(); open.canChooseDirectories = true; open.canChooseFiles = true; open.prompt = "Reconnect"; open.message = "Choose the current location of \(item.name)."
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url, let self = self else { return }
            self.perform { try self.store.change { state in
                for group in state.groups.indices { if let index = state.groups[group].items.firstIndex(where: { $0.id == item.id }) { state.groups[group].items[index].location = url.path; state.groups[group].items[index].name = url.lastPathComponent } }
            } }
        }
    }
    @objc func preview(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true { QLPreviewPanel.shared()?.orderOut(nil); return }
        updatePreview(); guard !previewURLs.isEmpty else { return }
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
    }
    func updatePreview() {
        previewURLs = selected.compactMap(store.url).filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        if let preview = QLPreviewPanel.shared() { preview.dataSource = self; preview.delegate = self; preview.reloadData() }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }
    @objc func shelfMenu(_ sender: NSButton) {
        let menu = NSMenu(); addMenu(menu, "New Shelf…", #selector(newShelf(_:))); addMenu(menu, "Rename Shelf…", #selector(renameShelf(_:)))
        menu.addItem(.separator()); addMenu(menu, "Clear Shelf…", #selector(clearShelf(_:)))
        if store.state.groups.count > 1 { addMenu(menu, "Remove Shelf…", #selector(deleteShelf(_:))) }
        menu.addItem(.separator()); addQuickTools(to: menu)
        menu.addItem(.separator()); addMenu(menu, "Show Saved Imports", #selector(showImports(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    func askName(title: String, initial: String, accept: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Keep related items together for your next move."; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24); alert.accessoryView = field
        alert.beginSheetModal(for: panel) { response in let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if response == .alertFirstButtonReturn && !value.isEmpty { accept(String(value.prefix(80))) } }
        alert.window.makeFirstResponder(field)
    }
    @objc func newShelf(_ sender: Any?) { askName(title: "New shelf", initial: "Untitled shelf") { [weak self] name in guard let self = self else { return }; self.perform { try self.store.newGroup(name: name) } } }
    @objc func renameShelf(_ sender: Any?) { askName(title: "Rename shelf", initial: store.state.groups[store.groupIndex].name) { [weak self] name in guard let self = self else { return }; self.perform { try self.store.renameGroup(name) } } }
    func confirmRemoval(title: String, action: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Original files will stay where they are. Saved imports remain in Apron’s Imports folder. You can undo this shelf change with ⌘Z."; alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { response in if response == .alertFirstButtonReturn { action() } }
    }
    @objc func clearShelf(_ sender: Any?) { confirmRemoval(title: "Clear this shelf?") { [weak self] in guard let self = self else { return }; self.perform { try self.store.remove(ids: Set(self.store.items.map(\.id))) } } }
    @objc func deleteShelf(_ sender: Any?) {
        guard store.state.groups.count > 1 else { return }
        confirmRemoval(title: "Remove this shelf?") { [weak self] in guard let self = self else { return }; self.perform { try self.store.change { state in state.groups.removeAll { $0.id == state.active }; state.active = state.groups[0].id } } }
    }
    @objc func showImports(_ sender: Any?) { NSWorkspace.shared.open(store.imports) }
    @objc func about(_ sender: Any?) { let alert = NSAlert(); alert.messageText = "Apron"; alert.informativeText = "A file shelf for Hangar.\n\nGather files, notes, images and links. Select several items to drag them together. Original files stay in place.\n\nSpace — Quick Look\nReturn — Open\nDelete — Remove from shelf\n⌘Z — Undo last change\n⌘V — Paste\n⌘N — New shelf\n⌘F — Find in shelf\n⇧⌘C — Copy Contents"; alert.beginSheetModal(for: panel) }
}


func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    if !condition() { throw NSError(domain: "ApronTest", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
}
func runStorageTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ApronTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = root.appendingPathComponent("Original 日本語.txt")
    try Data("original survives".utf8).write(to: original)
    let stateRoot = root.appendingPathComponent("state")
    let store = try ShelfStore(directory: stateRoot)
    try store.addFiles([original])
    try require(store.items.count == 1, "file reference added")
    try store.addFiles([original])
    try require(store.items.count == 1, "duplicate references coalesced")
    try store.addText("A useful note 🛫")
    try store.addLink(URL(string: "https://example.com/a?q=hello")!)
    try require(ShelfController.matchingItems(store.items, query: "  ORIGINAL 日本語 ").map(\.id) == [store.items[0].id], "search ignores case and matches all name/path terms")
    try require(ShelfController.matchingItems(store.items, query: "example.com").map(\.id) == [store.items[2].id], "search includes link destinations")
    try require(ShelfController.matchingItems(store.items, query: "missing-result").isEmpty, "search has empty results")
    let restarted = try ShelfStore(directory: stateRoot)
    try require(restarted.items.count == 3, "all kinds survive restart")
    try require(restarted.items[0].kind == .file, "reference kind preserved")
    let imported = restarted.url(for: restarted.items[1])!
    let text = try String(contentsOf: imported, encoding: .utf8)
    try require(text == "A useful note 🛫", "imported text roundtrips")
    try restarted.remove(ids: Set(restarted.items.map(\.id)))
    try require(restarted.items.isEmpty, "removal clears shelf references")
    try require(FileManager.default.fileExists(atPath: original.path), "removal preserves original")
    try require(FileManager.default.fileExists(atPath: imported.path), "removal retains imported content for recovery")
    try restarted.addFiles([original])
    try FileManager.default.removeItem(at: original)
    try require(restarted.url(for: restarted.items[0]) != nil, "missing reference retained")
    let before = restarted.state
    try FileManager.default.removeItem(at: restarted.manifest)
    try FileManager.default.createDirectory(at: restarted.manifest, withIntermediateDirectories: true)
    do { try restarted.addText("cannot save"); throw NSError(domain: "ApronTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "write failure must throw"]) }
    catch let error as NSError where error.domain != "ApronTest" { }
    try require(restarted.state == before, "failed write does not mutate visible state")
    let recovery = try ShelfStore(directory: root.appendingPathComponent("recovery"))
    try recovery.addText("first note")
    let firstGroup = recovery.state.active
    try recovery.newGroup(name: "Trip ✈︎")
    try recovery.addText("second note")
    let secondGroup = recovery.state.active
    let receiveFolder = recovery.imports.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: receiveFolder, withIntermediateDirectories: false)
    let promised = receiveFolder.appendingPathComponent("Mail attachment.txt")
    try Data("received attachment".utf8).write(to: promised)
    try recovery.receive(promised, in: receiveFolder, groupID: firstGroup)
    try require(recovery.items.count == 1, "promise completion preserves active shelf")
    try recovery.selectGroup(firstGroup)
    try require(recovery.items.count == 2 && recovery.items[1].kind == .received, "promise lands in original target shelf")
    try require(recovery.url(for: recovery.items[1]) == promised, "promised file URL resolves")
    let escaped = ShelfItem(kind: .received, name: "escape", location: "../../outside")
    try require(recovery.url(for: escaped) == nil, "import traversal rejected")
    let external = root.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: external)
    let symlink = receiveFolder.appendingPathComponent("escape.txt")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
    do { try recovery.receive(symlink, in: receiveFolder, groupID: firstGroup); throw NSError(domain: "ApronTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "symlink escape must fail"]) }
    catch let error as NSError where error.domain != "ApronTest" { }
    let snapshot = recovery.state
    try recovery.remove(ids: Set(recovery.items.map(\.id)))
    try require(FileManager.default.fileExists(atPath: promised.path), "received file survives shelf removal")
    try recovery.restore(snapshot)
    let restored = try ShelfStore(directory: recovery.directory)
    try require(restored.state == snapshot && restored.state.groups.contains { $0.id == secondGroup }, "named shelves and undo survive restart")
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: restored.manifest)
    do { _ = try ShelfStore(directory: restored.directory); throw NSError(domain: "ApronTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "corrupt manifest must not load"]) }
    catch let error as NSError where error.domain != "ApronTest" { }
    let preserved = try Data(contentsOf: restored.manifest)
    try require(preserved == corrupt, "corrupt manifest remains untouched")
    let ipcDirectory = root.appendingPathComponent("ipc")
    let primary = try ShelfInstance(directory: ipcDirectory), secondary = try ShelfInstance(directory: ipcDirectory)
    try require(primary.ownsLock && !secondary.ownsLock, "only one process owns shelf lock")
    let receiptID = UUID()
    try secondary.send(paths: [external.path], appearance: "dark", receiptID: receiptID)
    var requests = [ShelfRequest]()
    primary.listen { request in requests.append(request); try? primary.respond(to: request, with: ShelfResponse(ok: true, added: 1, error: nil)) }
    try require(requests.count == 1 && requests[0].paths == [external.path] && requests[0].appearance == "dark", "secondary request is delivered to primary")
    try require((try? FileManager.default.contentsOfDirectory(atPath: primary.inbox.path).isEmpty) == true, "delivered IPC request is consumed")
    let receipt = try secondary.waitForResponse(receiptID, timeout: 0.1)
    try require(receipt.ok && receipt.added == 1, "synchronous launcher receives committed import acknowledgement")
    let tooLarge = root.appendingPathComponent("oversized")
    try Data(repeating: 65, count: 129).write(to: tooLarge)
    do { _ = try readBoundedFile(tooLarge, limit: 128); throw NSError(domain: "ApronTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "oversized external data must fail"]) }
    catch let error as NSError where error.domain != "ApronTest" { }
    var deliberate = DragShakeDetector()
    var triggered = false
    for (index, x) in [100.0, 160, 90, 160, 90].enumerated() { triggered = deliberate.record(NSPoint(x: x, y: 100), at: Double(index) * 0.12) || triggered }
    try require(triggered, "deliberate three-reversal drag summons shelf")
    var coolingDown = false
    for (index, x) in [100.0, 160, 90, 160, 90].enumerated() { coolingDown = deliberate.record(NSPoint(x: x, y: 100), at: 1 + Double(index) * 0.12) || coolingDown }
    try require(!coolingDown, "drag shake cooldown suppresses repeated summons")
    var ordinary = DragShakeDetector(), falsePositive = false
    for index in 0..<30 { falsePositive = ordinary.record(NSPoint(x: Double(index) * 8, y: 100), at: Double(index) * 0.025) || falsePositive }
    try require(!falsePositive, "ordinary directional drag does not summon shelf")
    print("PASS: Apron original safety, Unicode/duplicate imports, text/link restart, missing files, write rollback, named shelves/undo, promised-file receipt, traversal/symlink rejection, corrupt-state preservation, single-instance IPC/receipts, bounded reads and drag-shake intent/cooldown")
}

func runQuickToolTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ApronQuickTools-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func rejects(_ description: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw ShelfError.invalid("Quick Tools test: " + description)
    }
    func hash(_ file: URL) throws -> SHA256.Digest { SHA256.hash(data: try Data(contentsOf: file)) }
    let canvas = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    canvas.setFillColor(CGColor(red: 0.15, green: 0.65, blue: 0.4, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    let image = canvas.makeImage()!, input = url("Original.jpg")
    let originalWriter = CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(originalWriter, image, [kCGImagePropertyOrientation: 6, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:05 12:34:56"], kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Private camera"], kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 77.5, kCGImagePropertyGPSLongitudeRef: "E"]] as CFDictionary)
    try require(CGImageDestinationFinalize(originalWriter), "image fixture encoded")
    let originalHash = try hash(input), originalSource = CGImageSourceCreateWithURL(input as CFURL, nil)!
    let originalProperties = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as! [CFString: Any]
    try require(originalProperties[kCGImagePropertyGPSDictionary] != nil, "fixture carries GPS metadata")
    let png = url("Optimized.png")
    let optimized = try ShelfQuickTools.optimizeImage(input, to: png, jpeg: false, maxDimension: 64, quality: 0.82, cancel: ToolCancellation())
    let pngSource = CGImageSourceCreateWithURL(png as CFURL, nil)!, pngImage = CGImageSourceCreateImageAtIndex(pngSource, 0, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(pngSource, 0, nil) as! [CFString: Any]
    try require(pngImage.width == 32 && pngImage.height == 64, "image resize honors orientation and maximum dimension")
    try require(properties[kCGImagePropertyGPSDictionary] == nil && (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil && (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil, "optimized raster strips source GPS and EXIF")
    try require(optimized.detail.contains("smaller") || optimized.detail.contains("larger") || optimized.detail.contains("same file size"), "size result reports actual comparison")
    _ = try ShelfQuickTools.optimizeImage(input, to: url("Optimized.jpg"), jpeg: true, maxDimension: 40, quality: 0.5, cancel: ToolCancellation())
    let jpeg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url("Optimized.jpg") as CFURL, nil)!, 0, nil)!
    try require(jpeg.width == 20 && jpeg.height == 40, "JPEG output dimensions")
    let animation = url("Animation.gif"), gif = CGImageDestinationCreateWithURL(animation as CFURL, UTType.gif.identifier as CFString, 2, nil)!
    CGImageDestinationAddImage(gif, image, nil); CGImageDestinationAddImage(gif, image, nil)
    try require(CGImageDestinationFinalize(gif), "animated fixture encoded")
    try rejects("animation must never flatten") { _ = try ShelfQuickTools.optimizeImage(animation, to: url("Flattened.png"), jpeg: false, maxDimension: 64, quality: 1, cancel: ToolCancellation()) }
    try require(!FileManager.default.fileExists(atPath: url("Flattened.png").path), "rejected animation leaves no output")
    let hardlink = url("Original hardlink.jpg"), symlink = url("Original symlink.jpg")
    try FileManager.default.linkItem(at: input, to: hardlink); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
    for protected in [input, hardlink, symlink, png] {
        try rejects("existing files and aliases must not be overwritten") { try ShelfQuickTools.saveNew(Data("replacement".utf8), to: protected, inputs: [input], cancel: ToolCancellation()) }
    }
    let dangling = url("Dangling.png"); try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: url("missing.png"))
    try rejects("dangling output symlink must not be followed") { try ShelfQuickTools.saveNew(Data(), to: dangling, inputs: [input], cancel: ToolCancellation()) }
    let duringWrite = ToolCancellation(), interrupted = url("Interrupted copy.png")
    var observedPartial = false
    try rejects("cancellation during a write must clean the new file") {
        try ShelfQuickTools.saveNew(Data(repeating: 42, count: 2 * 1024 * 1024), to: interrupted, inputs: [input], cancel: duringWrite) {
            observedPartial = FileManager.default.fileExists(atPath: interrupted.path); duringWrite.cancel()
        }
    }
    try require(observedPartial && !FileManager.default.fileExists(atPath: interrupted.path), "mid-write cancellation removes its partial copy before returning")
    let cancelled = ToolCancellation(); cancelled.cancel()
    try rejects("cancelled operation must not publish") { try ShelfQuickTools.saveNew(Data("cancelled".utf8), to: url("Cancelled.png"), inputs: [input], cancel: cancelled) }
    try require(!FileManager.default.fileExists(atPath: url("Cancelled.png").path), "cancelled output absent")
    let finalImageHash = try hash(input)
    try require(finalImageHash == originalHash, "image original bytes survive all operations")
    func makePDF(_ name: String, widths: [Int], locked: Bool = false) throws -> URL {
        let file = url(name), data = NSMutableData(), consumer = CGDataConsumer(data: data)!
        let metadata: [CFString: Any] = locked ? [kCGPDFContextOwnerPassword: "owner", kCGPDFContextUserPassword: "reader"] : [:]
        let context = CGContext(consumer: consumer, mediaBox: nil, metadata as CFDictionary)!
        for width in widths {
            var box = CGRect(x: 0, y: 0, width: width, height: 200)
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 5, y: 5, width: 20, height: 20)); context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to: file); return file
    }
    let first = try makePDF("First.pdf", widths: [100, 200]), second = try makePDF("Second.pdf", widths: [300])
    let firstHash = try hash(first), secondHash = try hash(second), merged = url("Merged.pdf")
    _ = try ShelfQuickTools.pdfCopy([first, second], to: merged, cancel: ToolCancellation())
    let mergedDocument = PDFDocument(url: merged)!
    try require(mergedDocument.pageCount == 3 && (0..<3).map { Int(mergedDocument.page(at: $0)!.bounds(for: .mediaBox).width) } == [100, 200, 300], "PDF merge preserves input and page order")
    _ = try ShelfQuickTools.pdfCopy([merged], to: url("Extracted.pdf"), pages: "3, 1", cancel: ToolCancellation())
    let extracted = PDFDocument(url: url("Extracted.pdf"))!
    try require(extracted.pageCount == 2 && [0, 1].map { Int(extracted.page(at: $0)!.bounds(for: .mediaBox).width) } == [300, 100], "PDF extraction honors requested page order")
    for range in ["", "0", "4", "2-1", "1,1", "1,", "1--2", "-1"] { try rejects("invalid page range must fail: " + range) { _ = try ShelfQuickTools.pageIndices(range, pageCount: 3) } }
    let validRange = try ShelfQuickTools.pageIndices("1, 2–3", pageCount: 3)
    try require(validRange == [0, 1, 2], "page range includes endpoints")
    let locked = try makePDF("Locked.pdf", widths: [100], locked: true)
    try rejects("encrypted PDFs must fail") { _ = try ShelfQuickTools.pdfCopy([locked], to: url("Unlocked.pdf"), cancel: ToolCancellation()) }
    let excessive = try makePDF("Too many pages.pdf", widths: Array(repeating: 100, count: 301))
    try rejects("PDF page limit must fail") { _ = try ShelfQuickTools.pdfCopy([excessive], to: url("Too many output.pdf"), cancel: ToolCancellation()) }
    try rejects("PDF file limit must fail") { _ = try ShelfQuickTools.pdfCopy(Array(repeating: first, count: 21), to: url("Too many files.pdf"), cancel: ToolCancellation()) }
    try rejects("same PDF destination must fail") { _ = try ShelfQuickTools.pdfCopy([first, second], to: first, cancel: ToolCancellation()) }
    let finalFirstHash = try hash(first), finalSecondHash = try hash(second)
    try require(finalFirstHash == firstHash && finalSecondHash == secondHash, "PDF original hashes unchanged")
    let folder = url("Trip 日本語"), nested = folder.appendingPathComponent("Nested"), emptyFolder = folder.appendingPathComponent("Empty")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: false)
    let nestedFile = nested.appendingPathComponent("--notes $(literal).txt")
    try Data("Original folder content".utf8).write(to: nestedFile)
    let duplicateFolder = url("Other"); try FileManager.default.createDirectory(at: duplicateFolder, withIntermediateDirectories: false)
    let duplicate = duplicateFolder.appendingPathComponent("Original.jpg"); try Data("Different file with same name".utf8).write(to: duplicate)
    let nestedHash = try hash(nestedFile), archive = url("Export.zip")
    _ = try ShelfQuickTools.zipCopy([folder, input, duplicate], to: archive, cancel: ToolCancellation())
    let extractedZIP = url("Extracted ZIP"); try FileManager.default.createDirectory(at: extractedZIP, withIntermediateDirectories: false)
    try ShelfQuickTools.runDitto(["-x", "-k", archive.path, extractedZIP.path], cancel: ToolCancellation(), log: url("extract.log"))
    let extractedNested = extractedZIP.appendingPathComponent("Trip 日本語/Nested/--notes $(literal).txt")
    let extractedNestedHash = try hash(extractedNested), extractedImageHash = try hash(extractedZIP.appendingPathComponent("Original.jpg"))
    let duplicateData = try Data(contentsOf: extractedZIP.appendingPathComponent("Original (2).jpg"))
    try require(extractedNestedHash == nestedHash && extractedImageHash == originalHash && duplicateData == Data("Different file with same name".utf8), "ZIP roundtrip preserves Unicode/path contents and disambiguates duplicate names")
    try require(FileManager.default.fileExists(atPath: extractedZIP.appendingPathComponent("Trip 日本語/Empty").path), "ZIP preserves empty folders")
    try rejects("ZIP cannot overwrite original") { _ = try ShelfQuickTools.zipCopy([input], to: input, cancel: ToolCancellation()) }
    try rejects("ZIP destination cannot be inside selected folder") { _ = try ShelfQuickTools.zipCopy([folder], to: folder.appendingPathComponent("Inside.zip"), cancel: ToolCancellation()) }
    let unsafeFolder = url("Unsafe folder"); try FileManager.default.createDirectory(at: unsafeFolder, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: unsafeFolder.appendingPathComponent("External link"), withDestinationURL: input)
    try rejects("ZIP must reject links instead of following outside selection") { _ = try ShelfQuickTools.zipCopy([unsafeFolder], to: url("Unsafe.zip"), cancel: ToolCancellation()) }
    let zipCancel = ToolCancellation(), cancelledZIP = url("Cancelled.zip")
    try rejects("ZIP cancellation stops its native child") { _ = try ShelfQuickTools.zipCopy([folder], to: cancelledZIP, cancel: zipCancel) { zipCancel.cancel() } }
    try require(!FileManager.default.fileExists(atPath: cancelledZIP.path), "cancelled ZIP leaves no published or partial archive")
    let finalNestedHash = try hash(nestedFile), finalZIPInputHash = try hash(input)
    try require(finalNestedHash == nestedHash && finalZIPInputHash == originalHash, "ZIP leaves original file hashes unchanged")
    print("PASS: ZIP native roundtrip, Unicode/metacharacter filenames, duplicate names, folder structure, source/link protection, child cancellation and original SHA-256 preservation")
    print("PASS: Quick Tools image dimensions/orientation/metadata/animation safety, exclusive copy/alias protection/cancel, PDF merge order/extraction/range validation/encryption/page/file limits, original SHA-256 preservation")
}

final class PromiseTestWriter: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Promised attachment.txt" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try Data("Actual AppKit file promise".utf8).write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}
func runPasteboardTests() throws {
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ApronPasteboardTests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ShelfStore(directory: root), instance = try ShelfInstance(directory: root)
    let controller = ShelfController(store: store, instance: instance, paths: [], appearance: "system", shakeEnabled: false)
    controller.buildWindow(fixture: true)
    let quittingTool = ToolCancellation(); controller.activeTool = quittingTool
    try require(controller.applicationShouldTerminate(app) == .terminateLater && controller.quitAfterTool, "quit is deferred while Quick Tools owns a worker")
    do { try quittingTool.check(); throw ShelfError.invalid("quit must cancel active Quick Tool") }
    catch is CancellationError { }
    controller.activeTool = nil; controller.quitAfterTool = false
    try require(controller.applicationShouldTerminate(app) == .terminateNow, "idle quit does not wait")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    guard board.setString("A clipboard note 🛫", forType: .string) else { throw ShelfError.invalid("The tool sandbox denied private pasteboard access. Run this native integration test from a normal macOS session.") }
    try require(controller.importPasteboard(board) && store.items.count == 1 && store.items[0].kind == .text, "native plain-text pasteboard import")
    board.clearContents(); board.setString("https://example.com/pasteboard", forType: .URL)
    try require(controller.importPasteboard(board) && store.items.count == 2 && store.items[1].kind == .link, "native web URL pasteboard import")
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
    image.setColor(NSColor(deviceRed: 0, green: 0.7, blue: 0.6, alpha: 1), atX: 0, y: 0)
    board.clearContents(); board.setData(image.representation(using: .png, properties: [:])!, forType: .png)
    try require(controller.importPasteboard(board) && store.items.count == 3 && store.items[2].kind == .image, "native PNG pasteboard import")
    let original = root.appendingPathComponent("Original clipboard file.txt")
    try Data("Keep original".utf8).write(to: original)
    board.clearContents(); board.writeObjects([original as NSURL])
    try require(controller.importPasteboard(board) && store.items.count == 4 && store.items[3].kind == .file, "native file URL pasteboard import")
    try require(controller.panel.title == "Apron — My shelf" && controller.shelfPicker.accessibilityLabel() == "Shelf: My shelf", "window and picker identify the active shelf")
    let missingCell = ShelfThumbnail(), missing = ShelfItem(kind: .file, name: "Lost file.txt", location: root.appendingPathComponent("gone.txt").path)
    missingCell.configure(missing, url: store.url(for: missing), style: .compact)
    try require(missingCell.view.accessibilityLabel()?.contains("missing file") == true && missingCell.view.accessibilityHelp()?.contains("Locate Original") == true, "missing original announces recovery action")
    let importedItems = store.items
    try controller.writeContents(of: importedItems[0], to: board)
    try require(board.string(forType: .string) == "A clipboard note 🛫" && board.data(forType: .fileURL) == nil, "Copy Contents writes note text, not a file reference")
    try controller.writeContents(of: importedItems[1], to: board)
    try require(board.string(forType: .URL) == "https://example.com/pasteboard" && board.string(forType: .string) == "https://example.com/pasteboard", "Copy Contents writes link and text representations")
    try controller.writeContents(of: importedItems[2], to: board)
    try require(board.data(forType: .png) == (try? Data(contentsOf: store.url(for: importedItems[2])!)), "Copy Contents preserves original PNG bytes")
    controller.grid.selectionIndexPaths = [IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0)]; controller.selectionChanged()
    controller.searchField.stringValue = "image"; controller.refresh(preservingSelection: true)
    try require(controller.visibleItems.map(\.id) == [importedItems[2].id] && controller.selected.map(\.id) == [importedItems[2].id], "filter selection follows stable IDs rather than old indices")
    let dragWriter = controller.collectionView(controller.grid, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) as? NSURL
    try require(dragWriter == store.url(for: importedItems[2])! as NSURL, "filtered drag exports the displayed file")
    controller.searchField.stringValue = "not-present"; controller.refresh(preservingSelection: true)
    try require(controller.selected.isEmpty && controller.emptyTitle.stringValue == "No matching items" && controller.empty.accessibilityLabel() == "My shelf: no matching items", "hidden selections cannot be acted on and empty search has an explanation")
    controller.searchField.stringValue = ""; controller.refresh(preservingSelection: true)
    try require(Set(controller.selected.map(\.id)) == Set([importedItems[0].id, importedItems[2].id]), "clearing search restores selected IDs")
    controller.searchField.stringValue = "image"; controller.refresh(preservingSelection: true)
    controller.removeItems(nil)
    try require(store.items.map(\.id) == [importedItems[0].id, importedItems[1].id, importedItems[3].id], "filtered remove leaves hidden selected items untouched")
    try require(FileManager.default.fileExists(atPath: store.url(for: importedItems[2])!.path), "filtered remove preserves imported image bytes")
    controller.undoShelf(nil); controller.searchField.stringValue = ""; controller.refresh()
    let writer = PromiseTestWriter()
    let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: writer)
    board.clearContents(); board.writeObjects([provider])
    try require(!controller.importPasteboard(board) && store.items.count == 4, "promise-only clipboard is safely refused outside a real drag session")
    print("PASS: actual AppKit pasteboard text, web link, PNG and original-file imports; promise-only clipboard safely requires a drag; contents payloads and filtered selection/drag identity")
    withExtendedLifetime(writer) {}; withExtendedLifetime(provider) {}
}

struct ShelfArguments {
    var stateDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LeanMac/Apron", isDirectory: true)
    var paths = [String](), appearance = "system", selfTest = false, pasteboardTest = false, wait = false, background = false, noShake = false, quit = false
    var renderPreview: String?
    var style: ShelfStyle?
    var stateDirectoryExplicit = false
    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--self-test": selfTest = true
            case "--self-test-pasteboard": pasteboardTest = true
            case "--wait": wait = true
            case "--background": background = true
            case "--no-shake": noShake = true
            case "--quit": quit = true
            case "--state-dir", "--appearance", "--render-preview", "--style":
                let option = arguments[index]; index += 1
                guard index < arguments.count else { throw ShelfError.invalid("Missing value for \(option)") }
                if option == "--style" { guard let parsed = ShelfStyle(rawValue: arguments[index]) else { throw ShelfError.invalid("Style must be compact or glass.") }; style = parsed }
                else if option == "--render-preview" { renderPreview = arguments[index] }
                else if option == "--state-dir" { stateDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true).standardizedFileURL; stateDirectoryExplicit = true }
                else { appearance = arguments[index]; guard ["system", "dark", "light"].contains(appearance) else { throw ShelfError.invalid("Appearance must be system, light or dark.") } }
            case "--add":
                index += 1
                guard index < arguments.count else { throw ShelfError.invalid("--add requires one or more file paths.") }
                while index < arguments.count && !arguments[index].hasPrefix("--") { paths.append(URL(fileURLWithPath: arguments[index]).standardizedFileURL.path); index += 1 }
                index -= 1
            case "--help", "-h":
                print("Apron — Hangar file shelf\nUsage: hangar-shelf [--state-dir PATH] [--appearance system|light|dark] [--style compact|glass] [--wait] [--add PATH ...]\n       hangar-shelf --background [--no-shake]\n       hangar-shelf --quit\n       hangar-shelf --self-test\n       hangar-shelf --render-preview OUTPUT.png\n--wait returns a JSON receipt after saved import (15-second timeout).\nClose hides the shelf; reopening restores it. Removing items never deletes original or imported files."); exit(0)
            default: throw ShelfError.invalid("Unknown option: \(arguments[index])")
            }
            index += 1
        }
    }
}
do {
    let arguments = try ShelfArguments(Array(CommandLine.arguments.dropFirst()))
    if arguments.selfTest {
        let noStyle = try ShelfArguments([]), glassStyle = try ShelfArguments(["--style", "glass"]), compactStyle = try ShelfArguments(["--style", "compact"])
        try require(noStyle.style == nil, "omitted style does not reset a running shelf")
        try require(glassStyle.style == .glass, "glass style parsed")
        try require(compactStyle.style == .compact, "compact style parsed")
        try runStorageTests(); try runQuickToolTests(); exit(0)
    }
    if arguments.pasteboardTest { try runPasteboardTests(); exit(0) }
    if let destination = arguments.renderPreview {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ApronPreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let store = try ShelfStore(directory: arguments.stateDirectoryExplicit ? arguments.stateDirectory : temporary.appendingPathComponent("State"))
        if !arguments.stateDirectoryExplicit {
            let photo = temporary.appendingPathComponent("Coast.heic")
            let nativePhoto = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/The Beach.heic")
            let fallbackPhoto = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
            try FileManager.default.copyItem(at: FileManager.default.fileExists(atPath: nativePhoto.path) ? nativePhoto : fallbackPhoto, to: photo)
            let document = temporary.appendingPathComponent("Itinerary.pdf")
            let commands = "0.12 0.25 0.32 rg BT /F1 23 Tf 28 365 Td (Weekend itinerary) Tj ET 0.35 0.35 0.35 rg BT /F1 11 Tf 28 339 Td (Coast road / 2 days) Tj ET 0.15 0.15 0.15 rg BT /F1 14 Tf 28 285 Td (Friday) Tj /F1 11 Tf 0 -24 Td (Check in by the water) Tj 0 -18 Td (Sunset walk along the shore) Tj /F1 14 Tf 0 -56 Td (Saturday) Tj /F1 11 Tf 0 -24 Td (Breakfast at the harbour) Tj 0 -18 Td (Coastal trail and picnic) Tj ET"
            let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 420] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)\nendstream"]
            var pdf = Data("%PDF-1.4\n".utf8), offsets = [0]
            for (index, object) in objects.enumerated() { offsets.append(pdf.count); pdf.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
            let xref = pdf.count
            pdf.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
            for offset in offsets.dropFirst() { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
            pdf.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
            try pdf.write(to: document)
            try store.addFiles([photo, document]); try store.addLink(URL(string: "https://www.parks.ca.gov/")!)
        }
        let instance = try ShelfInstance(directory: temporary.appendingPathComponent("IPC"))
        let controller = ShelfController(store: store, instance: instance, paths: [], appearance: arguments.appearance, style: arguments.style ?? .compact)
        controller.buildWindow(fixture: true); controller.refresh()
        if let glass = controller.glass { glass.setValue(nil, forKey: "contentView"); controller.panel.contentView = controller.surface }
        controller.effect.isHidden = true
        controller.surface.drawsOpaqueBackground = true
        controller.fitTray()
        controller.surface.layoutSubtreeIfNeeded(); controller.grid.layoutSubtreeIfNeeded()
        let thumbnailDeadline = Date().addingTimeInterval(2)
        while controller.grid.visibleItems().contains(where: { (($0 as? ShelfThumbnail)?.request != nil || ($0 as? ShelfThumbnail)?.isLoadingImage == true) }) && Date() < thumbnailDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        controller.surface.displayIfNeeded()
        guard let bitmap = controller.surface.bitmapImageRepForCachingDisplay(in: controller.surface.bounds) else { throw ShelfError.invalid("Could not create the native preview bitmap.") }
        controller.panel.effectiveAppearance.performAsCurrentDrawingAppearance { controller.surface.cacheDisplay(in: controller.surface.bounds, to: bitmap) }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ShelfError.invalid("Could not encode the native preview.") }
        try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        print("Wrote native Apron \(arguments.stateDirectoryExplicit ? "saved-state" : "fixture") preview: \(destination)")
        try? FileManager.default.removeItem(at: temporary)
        exit(0)
    }
    let instance = try ShelfInstance(directory: arguments.stateDirectory)
    if arguments.quit {
        if !instance.ownsLock { try instance.send(paths: [], show: false, quit: true) }
        exit(0)
    }
    if arguments.wait {
        let id = UUID()
        try instance.send(paths: arguments.paths, appearance: arguments.appearance, receiptID: id, show: !arguments.background, shakeEnabled: arguments.noShake ? false : nil, style: arguments.style)
        if instance.ownsLock {
            // The launcher releases its coordination lock before starting the GUI.
            // Concurrent launchers may race, but only one child can own the shelf.
            flock(instance.descriptor, LOCK_UN)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--state-dir", arguments.stateDirectory.path, "--appearance", arguments.appearance, "--background"] + (arguments.noShake ? ["--no-shake"] : []) + (arguments.style.map { ["--style", $0.rawValue] } ?? [])
            child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
        }
        let response = try instance.waitForResponse(id)
        FileHandle.standardOutput.write(try JSONEncoder().encode(response) + Data([10]))
        exit(response.ok ? 0 : 1)
    }
    if !instance.ownsLock { try instance.send(paths: arguments.paths, appearance: arguments.appearance, show: !arguments.background, shakeEnabled: arguments.noShake ? false : nil, style: arguments.style); print("Apron request delivered to the running shelf."); exit(0) }
    let store = try ShelfStore(directory: arguments.stateDirectory)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = ShelfController(store: store, instance: instance, paths: arguments.paths, appearance: arguments.appearance, background: arguments.background, shakeEnabled: !arguments.noShake, style: arguments.style ?? .compact)
    app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
} catch {
    FileHandle.standardError.write(Data(("Apron: " + error.localizedDescription + "\n").utf8))
    if Bundle.main.bundleURL.pathExtension == "app" && !CommandLine.arguments.contains("--self-test") && !CommandLine.arguments.contains("--help") {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error); alert.messageText = "Apron could not open"; alert.runModal()
    }
    exit(1)
}
