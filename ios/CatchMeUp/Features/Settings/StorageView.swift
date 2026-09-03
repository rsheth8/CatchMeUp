import SwiftUI

/// Settings ▸ Storage. Where the audio is, what it costs, and every way to get
/// some of it back.
///
/// The rule this screen is built around: anything that removes the only copy of
/// a recording says so before it does it, and offers a way to keep one.
struct StorageView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(AudioOptimizer.self) private var optimizer

    @State private var usage = AudioUsage()
    @State private var orphanCount = 0
    @State private var showsAllRecordings = false
    @State private var confirmClearCompleted = false
    @State private var confirmLocalDeletion = false
    @State private var exported: ExportedFile?
    @State private var isExporting = false
    @State private var notice: String?

    private var target: AudioQuality { settings.recordingQuality }

    var body: some View {
        List {
            totalSection
            optimizeSection
            qualitySection
            if store.syncEnabled { cloudSection }
            retentionSection
            brainSection
            largestSection
            exportSection
            cleanupSection
        }
        .navigationTitle("Storage")
        .task { refresh() }
        .onChange(of: store.recordings) { _, _ in refresh() }
        .onChange(of: optimizer.state) { _, _ in refresh() }
        .onChange(of: settings.recordingQuality) { _, _ in refresh() }
        .sheet(item: $exported) { ShareSheet(url: $0.url) }
        .alert("Storage", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .confirmationDialog("Remove audio for \(usage.completedCount) recap\(usage.completedCount == 1 ? "" : "s")?",
                            isPresented: $confirmClearCompleted, titleVisibility: .visible) {
            Button("Remove audio, keep notes", role: .destructive) {
                let cleared = store.removeAudioForCompletedNotes()
                notice = "Removed the audio from \(cleared) recap\(cleared == 1 ? "" : "s"). The notes, transcripts and key moments are all still there."
                Haptics.success()
                refresh()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Frees \(byteText(usage.completedBytes)). Notes, transcripts, key moments and your brains are kept. Pinned recordings are skipped. This can't be undone for anything that isn't in iCloud.")
        }
        .confirmationDialog("Delete audio this iPhone is the only copy of?",
                            isPresented: $confirmLocalDeletion, titleVisibility: .visible) {
            Button("Allow, and delete permanently", role: .destructive) {
                settings.allowLocalAudioDeletion = true
                applyRetentionNow()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Without iCloud there's nowhere to get these back from. Export the recordings you want to keep first — the notes and transcripts stay either way.")
        }
    }

    // MARK: - Total

    private var totalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(byteText(usage.totalBytes))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("of audio")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                UsageBar(deviceBytes: usage.deviceBytes, totalBytes: usage.totalBytes)

                Text(totalBlurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
        } footer: {
            if usage.missingCount > 0 {
                Text("\(usage.missingCount) recap\(usage.missingCount == 1 ? "" : "s") reference audio that isn't on this device or in iCloud. Their notes are unaffected.")
            }
        }
    }

    private var totalBlurb: String {
        guard usage.fileCount > 0 else { return "No audio yet. Recordings you make will show up here." }
        var text = "\(usage.fileCount) recording\(usage.fileCount == 1 ? "" : "s") · \(byteText(usage.deviceBytes)) on this iPhone"
        if usage.inCloudCount > 0 {
            text += " · \(usage.inCloudCount) kept in iCloud only"
        }
        return text
    }

    // MARK: - Optimize

    @ViewBuilder
    private var optimizeSection: some View {
        Section {
            switch optimizer.state {
            case .scanning(let fraction):
                VStack(alignment: .leading, spacing: 7) {
                    Text("Checking your audio library…").font(.subheadline.weight(.semibold))
                    ProgressView(value: fraction).tint(.brand)
                }
                .padding(.vertical, 2)

            case .running(let progress), .paused(let progress):
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(optimizer.state.isPaused ? "Paused" : "Converting")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(progress.completed) of \(progress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress.fraction).tint(.brand)
                    if !progress.title.isEmpty {
                        Text(progress.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if progress.bytesSaved > 0 {
                        Text("Freed \(byteText(progress.bytesSaved)) so far")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 18) {
                        if optimizer.state.isPaused {
                            Button("Resume") { optimizer.resume(store: store, target: target) }
                        } else {
                            Button("Pause") { optimizer.pause() }
                        }
                        Button("Stop", role: .destructive) { optimizer.cancel() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                }
                .padding(.vertical, 2)

            case .finished(let report):
                VStack(alignment: .leading, spacing: 7) {
                    Label(report.bytesSaved > 0 ? "Freed \(byteText(report.bytesSaved))" : "Nothing to convert",
                          systemImage: report.failed > 0 ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(report.failed > 0 ? .orange : .green)
                    Text(reportText(report)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Done") { optimizer.dismissReport() }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.vertical, 2)

            case .idle:
                if usage.optimizableCount > 0 {
                    Button {
                        Haptics.tap()
                        optimizer.start(store: store, target: target)
                    } label: {
                        Label("Optimize imported audio", systemImage: "wand.and.sparkles")
                    }
                } else {
                    Label("Everything is already \(target.title.lowercased())",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Make existing audio smaller")
        } footer: {
            if case .idle = optimizer.state, usage.optimizableCount > 0 {
                Text("\(usage.optimizableCount) recording\(usage.optimizableCount == 1 ? "" : "s") could be re-encoded, freeing about \(byteText(usage.estimatedSaving)). Originals are only replaced once the new file is verified, and anything that fails is left exactly as it is.")
            } else if case .idle = optimizer.state {
                Text("Imported MP3 and WAV files get converted in the background as you add them.")
            }
        }
    }

    private func reportText(_ report: AudioOptimizer.Report) -> String {
        var parts: [String] = []
        if report.converted > 0 { parts.append("\(report.converted) converted") }
        if report.skipped > 0 { parts.append("\(report.skipped) already small enough") }
        if report.failed > 0 { parts.append("\(report.failed) left untouched") }
        return parts.isEmpty ? "There was nothing to do." : parts.joined(separator: " · ")
    }

    // MARK: - Quality

    private var qualitySection: some View {
        Section {
            ForEach(AudioQuality.allCases) { quality in
                Button {
                    Haptics.tap()
                    settings.recordingQuality = quality
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(quality.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(quality.sizeEstimate)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(quality.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: settings.recordingQuality == quality
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(settings.recordingQuality == quality
                                             ? Color.brand : Color.secondary.opacity(0.4))
                            .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Recording quality")
        } footer: {
            Text("All three record mono AAC, which is what speech needs. Changing this affects new recordings — existing ones stay as they are until you optimize.")
        }
    }

    // MARK: - iCloud

    private var cloudSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.optimizeCloudStorage) {
                Label("Optimize iPhone storage", systemImage: "icloud.and.arrow.down")
            }
            Button {
                Haptics.tap()
                let freed = store.freeSpaceForOlderCloudAudio()
                notice = freed > 0
                    ? "Removed \(freed) local cop\(freed == 1 ? "y" : "ies"). They're still in iCloud and will download when you play them."
                    : "Nothing to remove — everything on this iPhone is either recent or pinned."
                refresh()
            } label: {
                Label("Free up space now", systemImage: "arrow.down.circle.dotted")
            }
            .disabled(usage.deviceBytes == 0)
            if store.migration.isRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(store.migration.text).font(.subheadline)
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("With this on, recent and pinned recordings stay on this iPhone and older ones live in iCloud. Pressing play or opening a key moment downloads them again.")
        }
    }

    // MARK: - Retention

    private var retentionSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker(selection: Binding(
                get: { settings.audioRetention },
                set: { newValue in
                    settings.audioRetention = newValue
                    // Asking before the first automatic deletion, not after.
                    if newValue.isAutomatic, hasLocalOnlyAudio, !settings.allowLocalAudioDeletion {
                        confirmLocalDeletion = true
                    } else if newValue.isAutomatic {
                        applyRetentionNow()
                    }
                }
            )) {
                ForEach(AudioRetention.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Remove audio", systemImage: "clock.arrow.circlepath")
            }
            .pickerStyle(.menu)

            if settings.audioRetention.isAutomatic, hasLocalOnlyAudio {
                Toggle(isOn: Binding(
                    get: { settings.allowLocalAudioDeletion },
                    set: { on in
                        if on { confirmLocalDeletion = true }
                        else { settings.allowLocalAudioDeletion = false }
                    }
                )) {
                    Label("Include audio only on this iPhone", systemImage: "exclamationmark.triangle")
                }
            }
        } header: {
            Text("Keep audio")
        } footer: {
            Text(retentionFooter)
        }
    }

    private var retentionFooter: String {
        guard settings.audioRetention.isAutomatic else {
            return "Audio is kept indefinitely. Nothing is ever removed on its own."
        }
        let window = settings.audioRetention.title.lowercased()
        var text = "Audio is cleared \(window) without being played, and only once the notes are written. Pinned recordings are never touched."
        if hasLocalOnlyAudio {
            text += settings.allowLocalAudioDeletion
                ? " Recordings only on this iPhone are deleted permanently."
                : " Recordings only on this iPhone are left alone."
        }
        return text
    }

    private var hasLocalOnlyAudio: Bool {
        usage.entries.contains { $0.availability == .onDevice }
    }

    // MARK: - Per brain

    @ViewBuilder
    private var brainSection: some View {
        if usage.byBrain.count > 1 {
            Section("By brain") {
                ForEach(usage.byBrain) { bucket in
                    LabeledContent {
                        Text(byteText(bucket.bytes)).monospacedDigit()
                    } label: {
                        Label {
                            Text(bucket.name)
                            Text("\(bucket.count) recording\(bucket.count == 1 ? "" : "s")")
                        } icon: {
                            Image(systemName: bucket.brainID == nil ? "tray" : "brain")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Largest

    @ViewBuilder
    private var largestSection: some View {
        let all = usage.largest
        if !all.isEmpty {
            Section {
                ForEach(showsAllRecordings ? all : Array(all.prefix(5))) { entry in
                    RecordingUsageRow(entry: entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.removeAudio(entry.recordingID)
                                refresh()
                            } label: { Label("Remove audio", systemImage: "waveform.slash") }
                            if entry.availability.canFreeLocalCopy {
                                Button {
                                    try? store.freeLocalCopy(entry.recordingID)
                                    refresh()
                                } label: { Label("Free space", systemImage: "icloud.slash") }
                            }
                        }
                        .contextMenu { rowMenu(entry) }
                }
                if all.count > 5 {
                    Button(showsAllRecordings ? "Show less" : "Show all \(all.count)") {
                        withAnimation(.quick) { showsAllRecordings.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } header: {
                Text("Largest recordings")
            } footer: {
                Text("Swipe a row to free space or remove its audio. Notes and transcripts are never affected.")
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: AudioEntry) -> some View {
        if let recording = store.recording(entry.recordingID) {
            Button {
                export { try await AudioExport.stage(recording, store: store) }
            } label: { Label("Export to Files…", systemImage: "square.and.arrow.down") }
        }

        if entry.canOptimize {
            Button {
                optimizer.optimize(entry.recordingID, store: store, target: target)
            } label: { Label("Optimize now", systemImage: "wand.and.sparkles") }
        }

        if store.syncEnabled {
            Button {
                store.setKeepDownloaded(entry.recordingID, !entry.isPinned)
            } label: {
                Label(entry.isPinned ? "Stop keeping downloaded" : "Keep downloaded",
                      systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
        }

        if entry.availability.canFreeLocalCopy {
            Button {
                try? store.freeLocalCopy(entry.recordingID)
                refresh()
            } label: { Label("Remove download", systemImage: "icloud.slash") }
        }

        Button(role: .destructive) {
            store.removeAudio(entry.recordingID)
            refresh()
        } label: { Label("Remove audio, keep notes", systemImage: "waveform.slash") }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            Button {
                export {
                    try await AudioExport.archive(store.sortedRecordings,
                                                  named: "CatchMeUp Audio", store: store)
                }
            } label: {
                Label("Export everything to Files…", systemImage: "arrow.up.doc")
            }
            .disabled(isExporting || usage.fileCount == 0)

            if !store.visibleBrains.isEmpty {
                Menu {
                    ForEach(store.visibleBrains) { brain in
                        Button(brain.name) {
                            export {
                                try await AudioExport.archive(store.recordings(inBrain: brain.id),
                                                              named: brain.name, store: store)
                            }
                        }
                    }
                } label: {
                    Label("Export one brain…", systemImage: "brain")
                }
                .disabled(isExporting)
            }

            if isExporting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Building the export…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Back up")
        } footer: {
            Text("Exports are a zip of the audio with each recap's notes next to it, so an archive still makes sense years later. Recordings kept only in iCloud aren't included — play them once to download them first.")
        }
    }

    // MARK: - Cleanup

    private var cleanupSection: some View {
        Section {
            Button(role: .destructive) {
                Haptics.warning()
                confirmClearCompleted = true
            } label: {
                LabeledContent {
                    Text(byteText(usage.completedBytes)).monospacedDigit()
                } label: {
                    Label("Remove audio with finished notes", systemImage: "text.badge.checkmark")
                }
            }
            .disabled(usage.completedCount == 0)

            if orphanCount > 0 {
                Button {
                    let removed = store.removeOrphanedAudio()
                    notice = "Cleared \(removed) leftover file\(removed == 1 ? "" : "s")."
                    refresh()
                } label: {
                    Label("Clear \(orphanCount) leftover file\(orphanCount == 1 ? "" : "s")",
                          systemImage: "trash")
                }
            }
        } header: {
            Text("Clean up")
        } footer: {
            Text("\(usage.completedCount) recap\(usage.completedCount == 1 ? " has" : "s have") notes written, so their audio can go without losing anything you've read. Pinned recordings are skipped.")
        }
    }

    // MARK: - Actions

    private func refresh() {
        usage = store.audioUsage(target: target)
        orphanCount = store.audio.orphanedFiles(keeping: store.sortedRecordings).count
    }

    private func applyRetentionNow() {
        let cleared = store.applyRetention(settings.audioRetention,
                                           allowLocalDeletion: settings.allowLocalAudioDeletion)
        if cleared > 0 {
            notice = "Cleared audio for \(cleared) older recap\(cleared == 1 ? "" : "s")."
        }
        refresh()
    }

    private func export(_ build: @escaping () async throws -> URL) {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                exported = ExportedFile(url: try await build())
                Haptics.success()
            } catch {
                Haptics.warning()
                notice = error.localizedDescription
            }
        }
    }
}

// MARK: - Usage bar

/// How the total splits between this device and iCloud. Two segments rather
/// than a percentage, because "what's actually on my phone" is the number
/// people came to this screen for.
private struct UsageBar: View {
    let deviceBytes: Int64
    let totalBytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                let fraction = totalBytes > 0
                    ? min(1, Double(deviceBytes) / Double(totalBytes)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.brandLight, .brand],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * fraction))
                }
            }
            .frame(height: 8)

            if totalBytes > deviceBytes {
                HStack(spacing: 14) {
                    legend(color: .brand, text: "On this iPhone")
                    legend(color: Color.primary.opacity(0.18), text: "In iCloud only")
                }
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Row

private struct RecordingUsageRow: View {
    let entry: AudioEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: entry.availability.symbolName)
                        .imageScale(.small)
                    Text(entry.availability.label)
                    if entry.duration > 0 {
                        Text("·")
                        Text(durationText(entry.duration))
                    }
                    if let format = entry.format {
                        Text("·")
                        Text(format).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(byteText(entry.bytes))
                    .font(.subheadline.monospacedDigit())
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
