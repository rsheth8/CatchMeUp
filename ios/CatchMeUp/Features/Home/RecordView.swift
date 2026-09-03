import SwiftUI

struct RecordView: View {
    let mode: Mode
    let onFinish: (UUID) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = AudioRecorder()
    @State private var permissionDenied = false
    @State private var didStart = false

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Button("Cancel") { recorder.stop(); dismiss() }
                Spacer()
                Pill(text: mode.title, symbol: mode.symbol, tint: mode.accent)
            }
            .padding()

            Spacer()

            Text(timeString(recorder.elapsed))
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            meter

            Spacer()

            if permissionDenied {
                Text("Microphone access is off. Turn it on in Settings ▸ CatchMeUp.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }

            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red.gradient : mode.accent.gradient)
                        .frame(width: 92, height: 92)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .disabled(permissionDenied)

            Text(recorder.isRecording ? "Tap to stop and make notes" : "Tap to start")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.bottom, 40)
        }
        .background(Color.groupBG)
        .task {
            guard !didStart else { return }
            didStart = true
            let ok = await recorder.requestPermission()
            permissionDenied = !ok
        }
    }

    private var meter: some View {
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { i in
                Capsule()
                    .fill(mode.accent.opacity(barOn(i) ? 0.9 : 0.15))
                    .frame(width: 4, height: barOn(i) ? CGFloat(8 + (i % 5) * 6) : 8)
            }
        }
        .frame(height: 44)
        .animation(.easeOut(duration: 0.15), value: recorder.level)
    }

    private func barOn(_ i: Int) -> Bool {
        guard recorder.isRecording else { return false }
        return Double(i) / 28.0 < recorder.level
    }

    private func toggle() {
        if recorder.isRecording {
            finish()
        } else {
            let name = store.newAudioFilename()
            let url = store.audioDir.appendingPathComponent(name)
            do {
                try recorder.start(to: url)
            } catch {
                permissionDenied = true
            }
        }
    }

    private func finish() {
        guard let url = recorder.stop() else { dismiss(); return }
        let name = url.lastPathComponent
        let rec = Recording(title: "\(mode.title) · \(Date().formatted(date: .abbreviated, time: .shortened))",
                            mode: mode,
                            audioFilename: name,
                            duration: recorder.elapsed)
        store.upsert(rec)
        onFinish(rec.id)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
