import SwiftUI
import UniformTypeIdentifiers
import UIKit
import VisionKit

private let supportedMaterialTypes: [UTType] = [
    .pdf,
    UTType(filenameExtension: "pptx") ?? .data,
]

struct BrainKnowledgeCard: View {
    let brainID: UUID
    let tint: Color

    @Environment(MaterialStore.self) private var store
    @State private var importing = false
    @State private var scanning = false
    @State private var selected: SupplementalMaterial?

    private var materials: [SupplementalMaterial] { store.materials(inBrain: brainID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader("Knowledge", symbol: "books.vertical")
                Spacer()
                Menu {
                    Button { importing = true } label: {
                        Label("Choose from Files", systemImage: "folder")
                    }
                    Button { scanning = true } label: {
                        Label("Scan pages", systemImage: "doc.viewfinder")
                    }
                    .disabled(!VNDocumentCameraViewController.isSupported)
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if materials.isEmpty {
                Button {
                    importing = true
                } label: {
                    HStack(spacing: 13) {
                        IconTile(symbol: "doc.badge.plus", tint: tint, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Add slides or a PDF")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Give this brain the material around your recordings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(13)
                    .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Metric.card).strokeBorder(Color.hairline) }
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(materials.prefix(4)) { material in
                        Button {
                            selected = material
                            Haptics.tap()
                        } label: {
                            MaterialCompactRow(material: material, tint: tint)
                        }
                        .buttonStyle(.plain)
                        if material.id != materials.prefix(4).last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Metric.card).strokeBorder(Color.hairline) }

                Text("\(materials.count) material\(materials.count == 1 ? "" : "s") available to this brain")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 3)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: supportedMaterialTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                store.importFiles(urls, into: brainID)
                Haptics.success()
            }
        }
        .sheet(item: $selected) { material in
            MaterialDetailView(materialID: material.id, tint: tint)
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScannerView { url in
                store.importFiles([url], into: brainID)
                try? FileManager.default.removeItem(at: url)
                scanning = false
                Haptics.success()
            } onCancel: { scanning = false }
                .ignoresSafeArea()
        }
    }
}

struct RecapMaterialsCard: View {
    let recording: Recording

    @Environment(MaterialStore.self) private var store
    @State private var importing = false
    @State private var scanning = false
    @State private var choosing = false
    @State private var selected: SupplementalMaterial?

    private var attached: [SupplementalMaterial] { store.materials(forRecording: recording.id) }
    private var candidates: [SupplementalMaterial] {
        let available = recording.brainID.map { store.materials(inBrain: $0) } ?? store.visibleMaterials
        return available.filter { !attached.contains($0) }
    }
    private var suggestion: SupplementalMaterial? { store.suggestedMaterial(for: recording) }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionHeader("Related material", symbol: "paperclip")
                    Spacer()
                    Menu {
                        Button { importing = true } label: {
                            Label("Import a file", systemImage: "doc.badge.plus")
                        }
                        Button { scanning = true } label: {
                            Label("Scan pages", systemImage: "doc.viewfinder")
                        }
                        .disabled(!VNDocumentCameraViewController.isSupported)
                        if !candidates.isEmpty {
                            Button { choosing = true } label: {
                                Label(recording.brainID == nil ? "Attach existing material" : "Attach from this brain", systemImage: "link")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                }

                if let error = store.importError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                if attached.isEmpty {
                    if let suggestion {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("LOOKS RELATED")
                                .font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.tertiary)
                            HStack(spacing: 10) {
                                Image(systemName: suggestion.kind.symbol).foregroundStyle(recording.mode.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(suggestion.countLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Attach") {
                                    store.attach(suggestion.id, to: recording.id)
                                    Haptics.success()
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .tint(recording.mode.accent)
                            }
                        }
                        .padding(13)
                        .background(recording.mode.accent.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: Metric.tile))
                    } else {
                        Button { importing = true } label: {
                            Label("Add the slides, agenda, or reading for this \(recording.mode.title.lowercased())",
                                  systemImage: "doc.badge.plus")
                                .font(.subheadline)
                                .foregroundStyle(recording.mode.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(13)
                                .background(recording.mode.accent.opacity(0.09),
                                            in: RoundedRectangle(cornerRadius: Metric.tile))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(attached) { material in
                            Button { selected = material } label: {
                                MaterialCompactRow(material: material, tint: recording.mode.accent)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.detach(material.id, from: recording.id)
                                } label: { Label("Detach", systemImage: "link.badge.minus") }
                            }
                            if material.id != attached.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.card))
                    .overlay { RoundedRectangle(cornerRadius: Metric.card).strokeBorder(Color.hairline) }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: supportedMaterialTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    store.importFiles(urls, into: recording.brainID, attachingTo: recording.id)
                    Haptics.success()
                }
            }
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    List(candidates) { material in
                        Button {
                            store.attach(material.id, to: recording.id)
                            choosing = false
                            Haptics.success()
                        } label: {
                            Label(material.name, systemImage: material.kind.symbol)
                        }
                    }
                    .navigationTitle("Attach material")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $selected) { material in
                MaterialDetailView(materialID: material.id, tint: recording.mode.accent)
            }
            .fullScreenCover(isPresented: $scanning) {
                DocumentScannerView { url in
                    store.importFiles([url], into: recording.brainID, attachingTo: recording.id)
                    try? FileManager.default.removeItem(at: url)
                    scanning = false
                    Haptics.success()
                } onCancel: { scanning = false }
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Native document scanner

private struct DocumentScannerView: UIViewControllerRepresentable {
    let onPDF: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) { }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { parent.onCancel(); return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Scan-\(UUID().uuidString)")
                .appendingPathExtension("pdf")
            let first = scan.imageOfPage(at: 0)
            let bounds = CGRect(origin: .zero, size: first.size)
            let renderer = UIGraphicsPDFRenderer(bounds: bounds)
            do {
                try renderer.writePDF(to: url) { context in
                    for index in 0..<scan.pageCount {
                        let image = scan.imageOfPage(at: index)
                        context.beginPage(withBounds: CGRect(origin: .zero, size: image.size),
                                          pageInfo: [:])
                        image.draw(in: CGRect(origin: .zero, size: image.size))
                    }
                }
                parent.onPDF(url)
            } catch {
                parent.onCancel()
            }
        }
    }
}

struct MaterialCompactRow: View {
    let material: SupplementalMaterial
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: material.kind.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(material.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(material.state.isReady ? material.countLabel : material.state.label)
                    if material.state.isWorking {
                        ProgressView(value: material.state.progress)
                            .frame(width: 42)
                            .tint(tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: material.state.isReady ? "chevron.right" : "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct MaterialDetailView: View {
    let materialID: UUID
    let tint: Color
    var initialPage: Int? = nil

    @Environment(MaterialStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedPage: MaterialPage?
    @State private var confirmDelete = false

    private var material: SupplementalMaterial? { store.material(materialID) }
    private var filteredPages: [MaterialPage] {
        guard let material else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? material.pages : material.pages.filter {
            $0.combinedText.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let material {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                hero(material)
                                if material.state.isWorking { progress(material) }
                                if case .failed(let message) = material.state { failure(message) }
                                if material.state.isReady { content(material) }
                            }
                            .padding(16)
                        }
                        .onAppear {
                            if let initialPage { proxy.scrollTo(initialPage, anchor: .top) }
                        }
                    }
                } else {
                    ContentUnavailableView("Material not found", systemImage: "doc.questionmark")
                }
            }
            .background(AmbientBackground(tint: tint))
            .navigationTitle(material?.name ?? "Material")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search this material")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let material {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ShareLink(item: store.originalURL(for: material)) {
                                Label("Share original", systemImage: "square.and.arrow.up")
                            }
                            if case .failed = material.state {
                                Button { store.process(material.id) } label: {
                                    Label("Try again", systemImage: "arrow.clockwise")
                                }
                            }
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Label("Delete material", systemImage: "trash")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .confirmationDialog("Delete this material?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let material { store.delete(material) }
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its extracted pages and connections will also be removed. Your recordings stay untouched.")
        }
        .sheet(item: $selectedPage) { page in
            MaterialPageView(materialID: materialID, page: page, tint: tint)
        }
    }

    private func hero(_ material: SupplementalMaterial) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: material.kind.symbol)
                    .font(.title2.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(material.kind.title.uppercased())
                        .font(.caption2.weight(.bold)).tracking(0.8).opacity(0.72)
                    Text(material.countLabel).font(.subheadline.weight(.semibold))
                }
                Spacer()
            }
            Text(material.name).font(.title2.weight(.bold))
            if !material.summary.isEmpty {
                Text(material.summary).font(.subheadline).opacity(0.88).lineLimit(3)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: tint.opacity(0.24), radius: 16, y: 7)
    }

    private func progress(_ material: SupplementalMaterial) -> some View {
        Card(tint: tint) {
            VStack(alignment: .leading, spacing: 9) {
                Label(material.state.label, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: material.state.progress).tint(tint)
                Text("You can leave this screen. Understanding continues in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't understand this file", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try again") { store.process(materialID) }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func content(_ material: SupplementalMaterial) -> some View {
        if !material.concepts.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader("Key concepts", symbol: "point.3.connected.trianglepath.dotted")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(material.concepts.prefix(12)) { concept in
                            Chip(text: concept.name, symbol: nil, tint: tint)
                        }
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(material.kind == .slides ? "Slides" : "Pages", symbol: "square.stack.3d.up")
            if filteredPages.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredPages) { page in
                        Button { selectedPage = page } label: {
                            MaterialPageRow(materialID: material.id, page: page,
                                            kind: material.kind, tint: tint, store: store)
                        }
                        .buttonStyle(.plain)
                        .id(page.number)
                    }
                }
            }
        }
    }
}

private struct MaterialPageRow: View {
    let materialID: UUID
    let page: MaterialPage
    let kind: MaterialKind
    let tint: Color
    let store: MaterialStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                Text("\(kind == .slides ? "Slide" : "Page") \(page.number)")
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                Text(page.title.isEmpty ? String(page.text.prefix(90)) : page.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(page.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if !page.speakerNotes.isEmpty {
                    Label("Includes speaker notes", systemImage: "text.bubble")
                        .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: Metric.tile))
        .overlay { RoundedRectangle(cornerRadius: Metric.tile).strokeBorder(Color.hairline) }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = store.thumbnailURL(materialID: materialID, filename: page.thumbnailFilename),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 82, height: 68).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1))
                .frame(width: 82, height: 68)
                .overlay { Image(systemName: "doc.text").foregroundStyle(tint) }
        }
    }
}

private struct MaterialPageView: View {
    let materialID: UUID
    let page: MaterialPage
    let tint: Color

    @Environment(MaterialStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let url = store.thumbnailURL(materialID: materialID, filename: page.thumbnailFilename),
                       let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                    }
                    if !page.title.isEmpty { Text(page.title).font(.title3.weight(.bold)) }
                    Text(page.text).font(.body).textSelection(.enabled)
                    if !page.speakerNotes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Speaker notes", systemImage: "text.bubble")
                                .font(.headline).foregroundStyle(tint)
                            Text(page.speakerNotes).font(.body).textSelection(.enabled)
                        }
                    }
                }
                .padding(18)
            }
            .background(AmbientBackground(tint: tint))
            .navigationTitle("Page \(page.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
