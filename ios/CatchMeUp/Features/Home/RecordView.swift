import SwiftUI

struct RecordView: View {
    let initialMode: Mode
    let onFinish: (UUID) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode
    @State private var recorder = AudioRecorder()
    @State private var permissionDenied = false
    @State private var didStart = false
    @State private var confirmDiscard = false

    init(initialMode: Mode, onFinish: @escaping (UUID) -> Void) {
        self.initialMode = initialMode
        self.onFinish = onFinish
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                Spacer()
                timer
                waveform
                    .padding(.top, 26)
                Spacer()
                status
                controls
                    .padding(.bottom, Metric.gutter)
            }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            let granted = await recorder.requestPermission()
            permissionDenied = !granted
        }
        .onDisappear { if recorder.isRecording { recorder.stop() } }
        .alert("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Keep recording", role: .cancel) { }
            Button("Discard", role: .destructive) { recorder.stop(); dismiss() }
        } message: {
            Text("The audio won't be saved.")
        }
    }

    // MARK: - Background
    //
    // A deep ground that breathes with the input level, so you can tell the mic
    // is live from across the room.

    private var background: some View {
        ZStack {
            Color.groupBG
            RadialGradient(colors: [mode.accent.opacity(recorder.isRecording && !recorder.isPaused
                                                        ? 0.10 + 0.22 * recorder.level : 0.10),
                                    .clear],
                           center: .center, startRadius: 10,
                           endRadius: 320 + 140 * (recorder.isPaused ? 0 : recorder.level))
            .animation(.easeOut(duration: 0.22), value: recorder.level)
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                if recorder.isRecording { confirmDiscard = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            if recorder.isRecording {
                Chip(text: mode.title, symbol: mode.symbol, tint: mode.accent, filled: true)
                    .transition(.opacity.combined(with: .scale))
            } else {
                modePicker
            }

            Spacer()

            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .animation(.quick, value: recorder.isRecording)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { m in
                Button {
                    Haptics.tap()
                    withAnimation(.quick) { mode = m }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.symbol).font(.caption.weight(.bold))
                        Text(m.title)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(mode == m ? .white : Color.secondary)
                    .background {
                        if mode == m { Capsule().fill(m.accent.gradient) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.hairline) }
    }

    // MARK: - Timer + waveform

    private var timer: some View {
        VStack(spacing: 6) {
            Text(clock(recorder.elapsed))
                .font(.system(size: 62, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
                .animation(.default, value: Int(recorder.elapsed))

            Text(mode == .meeting ? "Decisions, owners and follow-ups" : "Definitions, examples and what to study")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var waveform: some View {
        WaveBars(levels: recorder.levels, tint: mode.accent, barWidth: 4, spacing: 3.5)
            .frame(height: 84)
            .padding(.horizontal, 28)
            .opacity(recorder.isRecording ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: recorder.levels)
    }

    // MARK: - Status + controls

    @ViewBuilder
    private var status: some View {
        Group {
            if permissionDenied {
                Text("Microphone access is off. Turn it on in iOS Settings ▸ CatchMeUp.")
            } else if recorder.isStarting {
                Text("Starting the mic…")
            } else if recorder.isPaused {
                Text("Paused")
            } else if recorder.isRecording {
                Text("Recording — audio stays on this iPhone")
            } else {
                Text("Tap to start. You can pause any time.")
            }
        }
        .font(.footnote)
        .foregroundStyle(recorder.isPaused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .padding(.bottom, 18)
    }

    private var controls: some View {
        HStack(spacing: 34) {
            // pause / resume
            Button {
                Haptics.tap()
                recorder.isPaused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(recorder.isRecording ? Color.primary : Color.secondary)
                    .frame(width: 58, height: 58)
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(Color.hairline) }
            }
            .buttonStyle(.plain)
            .disabled(!recorder.isRecording || recorder.isStarting)
            .opacity(recorder.isRecording && !recorder.isStarting ? 1 : 0.35)

            // record / stop
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .stroke(mode.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 104, height: 104)
                        .scaleEffect(recorder.isRecording && !recorder.isPaused ? 1 + 0.08 * recorder.level : 1)
                        .animation(.easeOut(duration: 0.2), value: recorder.level)

                    Circle()
                        .fill(recorder.isRecording
                              ? AnyShapeStyle(Color.red.gradient)
                              : AnyShapeStyle(mode.accent.gradient))
                        .frame(width: 88, height: 88)
                        .shadow(color: (recorder.isRecording ? Color.red : mode.accent).opacity(0.35),
                                radius: 18, y: 8)

                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .disabled(permissionDenied)

            // spacer that matches the pause button so the record circle stays centred
            Color.clear.frame(width: 58, height: 58)
        }
    }

    // MARK: - Actions

    private func toggle() {
        if recorder.isRecording {
            Haptics.success()
            finish()
        } else {
            Haptics.tap(.medium)
            Task {
                let url = store.audio.directory.appendingPathComponent(store.audio.newFilename())
                do { try await recorder.start(to: url, quality: settings.recordingQuality) }
                catch { permissionDenied = true }
            }
        }
    }

    private func finish() {
        let elapsed = recorder.elapsed
        let url = recorder.stop()
        // Nothing usable was captured (e.g. stopped while the mic was still
        // spinning up) — don't leave an empty recap behind.
        guard let url, elapsed > 0.4 else { dismiss(); return }
        let rec = Recording(title: "\(mode.title) · \(Date().formatted(date: .abbreviated, time: .shortened))",
                            mode: mode,
                            audioFilename: url.lastPathComponent,
                            duration: elapsed)
        store.upsert(rec)
        onFinish(rec.id)

        // Measured after the fact so the size shows up on the storage screen
        // without holding up the recap the user is waiting for. The encoder
        // needs a moment to finish flushing the file it just closed.
        Task {
            if let facts = await AudioFile.facts(at: url) {
                store.noteAudioFacts(rec.id, facts)
            }
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
