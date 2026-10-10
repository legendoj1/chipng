import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            if let item = model.selectedItems.first, model.selectedItems.count == 1 {
                PreviewSection(item: item)
            }

            Section {
                Toggle("Compress with Squoosh", isOn: $settings.compress)
            } footer: {
                Footnote(settings.compress
                    ? "Images are alpha-bled, then shrunk like TinyPNG using Squoosh’s palette reduction and OxiPNG. Images that would lose quality are compressed losslessly instead."
                    : "Images are only alpha-bled, so edges stay clean when Roblox resizes them.")
            }

            Section {
                Toggle("Keep originals in Trash", isOn: $settings.keepOriginalsInTrash)
            } footer: {
                Footnote(settings.keepOriginalsInTrash
                    ? "Replace Originals puts a copy of each original file in the Trash first."
                    : "Replace Originals overwrites files without keeping a copy.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreviewSection: View {
    let item: ImageItem
    @State private var showHiddenColors = false
    @State private var preview: NSImage?

    var body: some View {
        Section {
            ZStack {
                Checkerboard(squareSize: 8)
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(8)
                } else if item.status == .processing || item.status == .queued {
                    ProgressView()
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

            Toggle("Show Hidden Colors", isOn: $showHiddenColors)
                .help("Ignore transparency to see the colours alpha bleeding put behind invisible pixels")

            if let method = item.method {
                LabeledContent("Compression", value: method.description)
            }
            if case .failed(let message) = item.status {
                LabeledContent("Error") {
                    Text(message).foregroundStyle(.red)
                }
            }
        } header: {
            Text(item.name).lineLimit(1).truncationMode(.middle)
        }
        .task(id: PreviewKey(id: item.id, size: item.output?.count, hidden: showHiddenColors)) {
            let data = item.output ?? item.originalData
            let hidden = showHiddenColors
            preview = await Task.detached(priority: .userInitiated) {
                hidden ? Thumbnail.revealingHiddenColors(data) : NSImage(data: data)
            }.value
        }
    }

    private struct PreviewKey: Hashable {
        var id: UUID
        var size: Int?
        var hidden: Bool
    }
}

extension ProcessedImage.Method: CustomStringConvertible {
    var description: String {
        switch self {
        case .bleedOnly: return "None"
        case .palette(let colors): return "Palette, \(colors) colors"
        case .lossless: return "Lossless"
        }
    }
}
