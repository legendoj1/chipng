import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model

        Group {
            if model.items.isEmpty {
                EmptyStateView()
            } else {
                ImageTable()
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle("Chipng")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 270, ideal: 300, max: 380)
        }
        .confirmationDialog(
            replaceTitle,
            isPresented: $model.showReplaceConfirmation,
            presenting: model.replaceTargets
        ) { targets in
            Button("Replace") { model.replaceOriginals(targets) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(model.settings.keepOriginalsInTrash
                 ? "A copy of each original will be put in the Trash, just in case."
                 : "The original files will be overwritten. This can’t be undone.")
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }

    private var subtitle: String {
        let count = model.items.count
        return count == 0 ? "" : "\(count) image\(count == 1 ? "" : "s")"
    }

    private var replaceTitle: String {
        let count = model.replaceTargets.count
        return count == 1
            ? "Replace “\(model.replaceTargets.first?.name ?? "")” with the processed version?"
            : "Replace \(count) original files with the processed versions?"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Add Images", systemImage: "plus")
            }
            .help("Add PNG images or folders")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.removeAll()
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .help("Remove all images from the list")
            .disabled(model.items.isEmpty)

            Menu {
                Button("Export Each to Folder…") { model.exportToFolder() }
                Button("Export as ZIP…") { model.exportZip() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            } primaryAction: {
                model.exportToFolder()
            }
            .help("Save each image as a separate file (click), or choose ZIP from the menu")
            .disabled(!model.canExport)

            Button {
                model.requestReplace()
            } label: {
                Label("Replace Originals", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .help("Overwrite the original files with the processed images")
            .disabled(!model.canExport)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Drop PNG Images Here", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Chipng alpha-bleeds transparent edges so images don’t get dark outlines when Roblox scales them, then shrinks them with Squoosh.")
        } actions: {
            Button("Choose Images…") { model.presentOpenPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - Table

private struct ImageTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Table(model.items, selection: $model.selection) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    ThumbnailView(image: item.thumbnail)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(item.isFailed)
                        .foregroundStyle(item.isFailed ? .secondary : .primary)
                }
                .help(item.url.path)
            }
            .width(min: 160, ideal: 220)

            TableColumn("Dimensions") { item in
                Text(item.pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 76, ideal: 84)

            TableColumn("Original") { item in
                Text(item.originalSize.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 62)

            TableColumn("Result") { item in
                Text(item.outputSize.map { $0.formatted(.byteCount(style: .file)) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 62)

            TableColumn("Change") { item in
                if let savings = item.savings {
                    Text(savings >= 0 ? "−\(savings.formatted(.percent.precision(.fractionLength(0))))"
                                      : "+\((-savings).formatted(.percent.precision(.fractionLength(0))))")
                        .foregroundStyle(savings > 0.005 ? .green : .secondary)
                        .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 48, ideal: 56)

            TableColumn("Status") { item in
                StatusCell(item: item)
            }
            .width(min: 100, ideal: 110)
        }
        .contextMenu(forSelectionType: ImageItem.ID.self) { ids in
            if !ids.isEmpty {
                Button("Replace Original\(ids.count == 1 ? "" : "s")…") { model.requestReplace(ids) }
                    .disabled(model.targets(ids).isEmpty)
                Button("Export to Folder…") { model.exportToFolder(ids) }
                    .disabled(model.targets(ids).isEmpty)
                Button("Export as ZIP…") { model.exportZip(ids) }
                    .disabled(model.targets(ids).isEmpty)
                Divider()
                Button("Show in Finder") { model.revealInFinder(ids) }
                Divider()
                Button("Remove from List") { model.remove(ids) }
            }
        } primaryAction: { ids in
            model.revealInFinder(ids)
        }
        .onDeleteCommand { model.remove(model.selection) }
    }
}

private struct ThumbnailView: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            Checkerboard(squareSize: 4)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
    }
}

private struct StatusCell: View {
    let item: ImageItem

    var body: some View {
        switch item.status {
        case .queued:
            Label("Waiting", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .processing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Processing").foregroundStyle(.secondary)
            }
        case .ready:
            if item.isSavedToOriginal {
                Label("Replaced", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label("Can’t Process", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }
}

extension ImageItem {
    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if model.isProcessing {
                let total = model.items.count
                let done = total - model.pendingCount
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("Processing \(done) of \(total)…")
            } else if model.isWorking {
                ProgressView().controlSize(.small)
                Text("Exporting…")
            } else if let summary {
                Text(summary)
            } else {
                Text(model.engineError ?? "Ready")
                    .foregroundStyle(model.engineError == nil ? Color.secondary : Color.red)
            }
            Spacer()
            Label(model.settings.compress ? "Alpha Bleed + Squoosh" : "Alpha Bleed Only", systemImage: "wand.and.stars")
                .labelStyle(.titleAndIcon)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String? {
        let ready = model.readyItems
        guard !ready.isEmpty else { return nil }
        let before = ready.reduce(0) { $0 + $1.originalSize }
        let after = ready.reduce(0) { $0 + ($1.outputSize ?? 0) }
        var text = "\(before.formatted(.byteCount(style: .file))) → \(after.formatted(.byteCount(style: .file)))"
        if before > 0 {
            let change = 1 - Double(after) / Double(before)
            text += change >= 0
                ? " (\(change.formatted(.percent.precision(.fractionLength(0)))) smaller)"
                : " (\((-change).formatted(.percent.precision(.fractionLength(0)))) larger)"
        }
        if model.failedCount > 0 { text += " · \(model.failedCount) couldn’t be processed" }
        return text
    }
}

// MARK: - Checkerboard

struct Checkerboard: View {
    var squareSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            let columns = Int(ceil(size.width / squareSize)), rows = Int(ceil(size.height / squareSize))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * squareSize, y: CGFloat(row) * squareSize, width: squareSize, height: squareSize))
                }
            }
            context.fill(path, with: .color(Color(white: 0.84)))
        }
    }
}
