import AVFoundation
import Speech
import SwiftUI

/// Voice search (v1.60): Mandarin speech recognition feeding
/// the search field. Partial transcripts stream into `partial`
/// (SearchView mirrors them into the keyword, whose debounce
/// auto-searches); the final transcript fires `onFinal`.
final class VoiceSearchController: ObservableObject {
    @Published var listening = false
    @Published var partial = ""
    var onFinal: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    func toggle() {
        listening ? stop() : start()
    }

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.begin() }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable, !listening else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true,
                                                          options: .notifyOthersOnDeactivation)
        } catch {
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        listening = true
        partial = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.partial = text
                    if result.isFinal {
                        self.stop()
                        if !text.isEmpty { self.onFinal?(text) }
                    }
                }
            } else if error != nil {
                DispatchQueue.main.async { self.stop() }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if listening {
            listening = false
            try? AVAudioSession.sharedInstance().setActive(false,
                                                           options: .notifyOthersOnDeactivation)
        }
    }
}
