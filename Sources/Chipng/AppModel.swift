import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppSettings {
    var compress: Bool {
        didSet {
            UserDefaults.standard.set(compress, forKey: "compress")
            onChange?()
        }
    }

    var keepOriginalsInTrash: Bool {
        didSet { UserDefaults.standard.set(keepOriginalsInTrash, forKey: "keepOriginalsInTrash") }
    }

    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        UserDefaults.standard.register(defaults: ["compress": true, "keepOriginalsInTrash": true])
        compress = UserDefaults.standard.bool(forKey: "compress")
        keepOriginalsInTrash = UserDefaults.standard.bool(forKey: "keepOriginalsInTrash")
    }
}

@MainActor
@Observable
final class ImageItem: Identifiable {
    enum Status: Equatable {
        case queued
        case processing
        case ready
        case failed(String)
    }

    let id = UUID()
    let url: URL
    /// The file's bytes as they were when added. Re-processing always starts from
    /// these, even after the file on disk has been replaced.
    let originalData: Data
    var thumbnail: NSImage?
    var pixelSize: CGSize?
    var status: Status = .queued
    var output: Data?
    var method: ProcessedImage.Method?
    var isSavedToOriginal = false
    var hasTrashBackup = false
    @ObservationIgnored var generation = 0

    init(url: URL, data: Data) {
        self.url = url
        self.originalData = data
        self.thumbnail = Thumbnail.make(from: data)
    }

    var name: String { url.lastPathComponent }
    var originalSize: Int { originalData.count }
    var outputSize: Int? { output?.count }

    var savings: Double? {
        guard let outputSize, originalSize > 0 else { return nil }
        return 1 - Double(outputSize) / Double(originalSize)
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    var items: [ImageItem] = []
    var selection: Set<ImageItem.ID> = []
    var isWorking = false
    var engineError: String?
    var alert: AlertMessage?
    var showReplaceConfirmation = false
    /// Items the pending "Replace Originals" confirmation applies to.
    var replaceTargets: [ImageItem] = []

    @ObservationIgnored private var running = 0
    @ObservationIgnored private var settingsDebounce: Task<Void, Never>?
    private let maxConcurrent = 4

    init() {
        settings.onChange = { [weak self] in self?.settingsChanged() }
        Task {
            do {
                try await SquooshEngine.shared.prepare()
            } catch {
                engineError = error.localizedDescription
            }
        }
    }

    // MARK: Derived state

    var readyItems: [ImageItem] { items.filter { $0.status == .ready && $0.output != nil } }
    var pendingCount: Int { items.filter { $0.status == .queued || $0.status == .processing }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true } else { return false } }.count }
    var isProcessing: Bool { pendingCount > 0 }
    var canExport: Bool { !readyItems.isEmpty && !isProcessing && !isWorking }

    var selectedItems: [ImageItem] { items.filter { selection.contains($0.id) } }

    /// The rows a context-menu or toolbar action applies to: the selection if
    /// there is one, otherwise everything.
    func targets(_ ids: Set<ImageItem.ID>? = nil) -> [ImageItem] {
        let ids = ids ?? selection
        let chosen = ids.isEmpty ? items : items.filter { ids.contains($0.id) }
        return chosen.filter { $0.status == .ready && $0.output != nil }
    }

    // MARK: Adding & removing

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose PNG images, or folders containing them."
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.url.standardizedFileURL))
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> [(URL, Data)] in
                Self.collectPNGs(urls)
                    .filter { !existing.contains($0.standardizedFileURL) }
                    .compactMap { url in (try? Data(contentsOf: url)).map { (url, $0) } }
            }.value
            var seen = Set(items.map(\.url.standardizedFileURL))
            for (url, data) in loaded where seen.insert(url.standardizedFileURL).inserted {
                items.append(ImageItem(url: url, data: data))
            }
            pump()
        }
    }

    nonisolated private static func collectPNGs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let file = enumerator?.nextObject() as? URL {
                    if file.pathExtension.lowercased() == "png" { result.append(file) }
                }
            } else if url.pathExtension.lowercased() == "png" {
                result.append(url)
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func remove(_ ids: Set<ImageItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func removeAll() {
        items.removeAll()
        selection.removeAll()
    }

    // MARK: Processing

    private func settingsChanged() {
        settingsDebounce?.cancel()
        settingsDebounce = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            for item in items {
                item.generation += 1
                item.status = .queued
                item.output = nil
                item.isSavedToOriginal = false
            }
            pump()
        }
    }

    private func pump() {
        while running < maxConcurrent, let item = items.first(where: { $0.status == .queued }) {
            running += 1
            item.status = .processing
            let generation = item.generation
            let compress = settings.compress
            let source = item.originalData
            Task {
                let result: Result<ProcessedImage, Error>
                do {
                    result = .success(try await ImageProcessor.process(source, compress: compress))
                } catch {
                    result = .failure(error)
                }
                running -= 1
                if item.generation == generation, items.contains(where: { $0 === item }) {
                    switch result {
                    case .success(let processed):
                        item.output = processed.data
                        item.pixelSize = CGSize(width: processed.width, height: processed.height)
                        item.method = processed.method
                        item.thumbnail = Thumbnail.make(from: processed.data) ?? item.thumbnail
                        item.status = .ready
                    case .failure(let error):
                        item.status = .failed(error.localizedDescription)
                    }
                }
                pump()
            }
        }
    }

    // MARK: Replace originals

    func requestReplace(_ ids: Set<ImageItem.ID>? = nil) {
        replaceTargets = targets(ids)
        guard !replaceTargets.isEmpty else { return }
        showReplaceConfirmation = true
    }

    func replaceOriginals(_ targets: [ImageItem]) {
        var failures: [String] = []
        for item in targets {
            guard let output = item.output else { continue }
            do {
                if settings.keepOriginalsInTrash && !item.hasTrashBackup {
                    try Self.moveCopyToTrash(item.originalData, named: item.name)
                    item.hasTrashBackup = true
                }
                try output.write(to: item.url, options: .atomic)
                item.isSavedToOriginal = true
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            alert = AlertMessage(title: "Some files couldn't be replaced", message: failures.joined(separator: "\n"))
        }
    }

    /// Puts a copy of the original bytes in the Trash. Going through a temporary
    /// file works on every volume, including cloud drives that have no Trash.
    nonisolated private static func moveCopyToTrash(_ data: Data, named name: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Chipng-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Export

    func exportToFolder(_ ids: Set<ImageItem.ID>? = nil) {
        let targets = targets(ids)
        guard !targets.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(targets.count == 1 ? "the image" : "\(targets.count) images")."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var names = Self.uniqueNames(for: targets)
        let conflicts = names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = conflicts.count == 1
                ? "“\(conflicts[0])” already exists in “\(folder.lastPathComponent)”."
                : "\(conflicts.count) files already exist in “\(folder.lastPathComponent)”."
            alert.informativeText = "Do you want to replace them, or keep both?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: names = Self.uniqueNames(for: targets, avoiding: folder)
            default: return
            }
        }

        var written: [URL] = []
        var failures: [String] = []
        for (item, name) in zip(targets, names) {
            let destination = folder.appendingPathComponent(name)
            do {
                try item.output?.write(to: destination, options: .atomic)
                written.append(destination)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            alert = AlertMessage(title: "Some images couldn't be exported", message: failures.joined(separator: "\n"))
        }
        if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
    }

    func exportZip(_ ids: Set<ImageItem.ID>? = nil) {
        let targets = targets(ids)
        guard !targets.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "images.zip"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let files = zip(Self.uniqueNames(for: targets), targets.compactMap(\.output)).map { ($0, $1) }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await Task.detached { try Self.writeZip(files, to: destination) }.value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                alert = AlertMessage(title: "Couldn't create the ZIP archive", message: error.localizedDescription)
            }
        }
    }

    nonisolated private static func writeZip(_ files: [(String, Data)], to destination: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Chipng-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }

        let archive = folder.appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--norsrc", folder.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "ditto exited with status \(ditto.terminationStatus)"])
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: archive)
        } else {
            try FileManager.default.moveItem(at: archive, to: destination)
        }
    }

    /// Gives duplicate file names a " (1)", " (2)" … suffix, optionally also
    /// avoiding files that already exist in `folder`.
    private static func uniqueNames(for items: [ImageItem], avoiding folder: URL? = nil) -> [String] {
        var used = Set<String>()
        return items.map { item in
            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            var candidate = item.name
            var n = 1
            func taken(_ name: String) -> Bool {
                used.contains(name.lowercased())
                    || (folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } ?? false)
            }
            while taken(candidate) {
                candidate = "\(base) (\(n)).\(ext)"
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    // MARK: Finder

    func revealInFinder(_ ids: Set<ImageItem.ID>) {
        let urls = items.filter { ids.contains($0.id) }.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

enum Thumbnail {
    static func make(from data: Data, maxPixelSize: Int = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// The image with alpha ignored, which shows the colours hidden in transparent
    /// pixels — i.e. what alpha bleeding filled in.
    static func revealingHiddenColors(_ data: Data) -> NSImage? {
        guard var image = try? PNGCodec.decode(data) else { return nil }
        for i in stride(from: 3, to: image.pixels.count, by: 4) { image.pixels[i] = 255 }
        let provider = CGDataProvider(data: Data(image.pixels) as CFData)!
        guard let cg = CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.width, height: image.height))
    }
}
