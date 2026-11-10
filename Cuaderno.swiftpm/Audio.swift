import SwiftUI
import AVFoundation

/// Grabaciones de audio de un cuaderno (se guardan como .m4a junto a sus páginas).
final class AudioModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var recording = false
    @Published var playing: String?
    @Published var files: [String] = []
    @Published var denied = false

    private let dir: URL
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?

    init(dir: URL) {
        self.dir = dir
        super.init()
        refresh()
    }

    func refresh() {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        files = all.filter { $0.hasSuffix(".m4a") }.sorted(by: >)
    }

    func toggleRecord() {
        if recording {
            stop()
            return
        }
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                if ok { self?.start() } else { self?.denied = true }
            }
        }
    }

    private func start() {
        stopPlayback()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("Audio " + f.string(from: Date()) + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            recording = true
        } catch {
            recording = false
        }
    }

    func stop() {
        guard recording else { return }
        recorder?.stop()
        recorder = nil
        recording = false
        refresh()
    }

    func play(_ name: String) {
        if playing == name {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let p = try? AVAudioPlayer(contentsOf: dir.appendingPathComponent(name)) else { return }
        p.delegate = self
        p.play()
        player = p
        playing = name
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
    }

    func delete(_ name: String) {
        if playing == name { stopPlayback() }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        refresh()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = nil
    }
}

struct AudioButton: View {
    @ObservedObject var audio: AudioModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: audio.recording ? "mic.fill" : "mic")
                .foregroundStyle(audio.recording ? Color.red : Color.accentColor)
        }
    }
}

struct AudioSheet: View {
    @ObservedObject var audio: AudioModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        audio.toggleRecord()
                    } label: {
                        Label(audio.recording ? "Detener grabación" : "Grabar audio",
                              systemImage: audio.recording ? "stop.circle.fill" : "record.circle")
                            .foregroundStyle(.red)
                    }
                    if audio.denied {
                        Text("Falta el permiso de micrófono. Activalo en Ajustes del iPad.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Podés cerrar esta ventana y seguir escribiendo mientras graba.")
                }
                Section("Grabaciones") {
                    ForEach(audio.files, id: \.self) { name in
                        Button {
                            audio.play(name)
                        } label: {
                            Label(name.replacingOccurrences(of: ".m4a", with: ""),
                                  systemImage: audio.playing == name ? "stop.fill" : "play.fill")
                        }
                    }
                    .onDelete { idx in
                        let names = idx.map { audio.files[$0] }
                        for n in names { audio.delete(n) }
                    }
                }
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
