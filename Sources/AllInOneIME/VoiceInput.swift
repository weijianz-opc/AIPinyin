import AllInOneIMECore
import AVFoundation
import Foundation
import Speech

/// Voice input: hold the right Option key, speak, release. Speech is recognized on the Mac by
/// Apple's SpeechAnalyzer (macOS 26+); audio never leaves the machine. The language follows the
/// input mode: Chinese (pinyin) → zh_CN, English → en_US.
enum VoiceInput {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    static func locale(for language: Language) -> Locale {
        Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
    }

    enum MicrophoneAccess { case granted, notDetermined, denied }

    static var microphoneAccess: MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Shows the system prompt (once); the answer applies from the next recording on.
    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// Whether the speech model for `language` is on this Mac (shared by all apps).
    static func isModelInstalled(_ language: Language) async -> Bool {
        guard #available(macOS 26.0, *),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale(for: language))
        else { return false }
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Downloads the speech model for `language` (a one-time system download), reporting 0…1.
    static func downloadModel(_ language: Language, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else { throw VoiceError.unsupportedSystem }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale(for: language)) else {
            throw VoiceError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return  // already installed
        }
        let report = request.progress
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(report.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
        await progress(1)
    }

    /// Model downloads in progress in this process, by language (0…1).
    @MainActor static var downloads: [Language: Double] = [:]
    @MainActor private static var observers: [Language: [(progress: (@MainActor (Double) -> Void)?,
                                                          done: @MainActor (Error?) -> Void)]] = [:]

    /// Starts the download for `language`, or follows the one already running; `done` gets nil or the error.
    @MainActor
    static func startDownload(_ language: Language, progress: (@MainActor (Double) -> Void)? = nil,
                              done: @escaping @MainActor (Error?) -> Void) {
        observers[language, default: []].append((progress, done))
        if let running = downloads[language] {
            progress?(running)
            return
        }
        downloads[language] = 0
        log.notice("downloading the \(language.rawValue, privacy: .public) speech model")
        Task { @MainActor in
            var failure: Error?
            do {
                try await downloadModel(language) { fraction in
                    downloads[language] = fraction
                    for observer in observers[language] ?? [] { observer.progress?(fraction) }
                }
            } catch {
                failure = error
                log.error("speech model download failed: \(String(describing: error), privacy: .public)")
            }
            downloads[language] = nil
            for observer in observers.removeValue(forKey: language) ?? [] { observer.done(failure) }
        }
    }
}

enum VoiceError: Error, LocalizedError {
    case unsupportedSystem
    case unsupportedLanguage
    case modelMissing(Language)
    case noMicrophone
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return "语音输入需要 macOS 26 或更新版本"
        case .unsupportedLanguage: return "这台 Mac 不支持这种语言的语音识别"
        case let .modelMissing(language): return "\(language.displayName)语音模型未安装"
        case .noMicrophone: return "没有可用的麦克风"
        case .noAudioFormat: return "语音识别无法处理这个音频格式"
        }
    }
}

/// One recording: audio from the microphone (or a file) is converted to the analyzer's format and
/// recognized while it is being recorded; `stop()` finalizes, `cancel()` discards. Audio captured
/// while the model is still loading is queued, so the first words aren't lost.
/// Callbacks arrive on the main thread.
@available(macOS 26.0, *)
final class DictationSession: @unchecked Sendable {
    enum Source {
        case microphone
        /// For the self-test: plays a file into the recognizer at `speed` × real time.
        case file(URL, speed: Double)
    }

    let id: Int
    let language: Language
    private let onText: @MainActor (String) -> Void
    private let onFinish: @MainActor (Result<String, Error>) -> Void

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var inputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending: [AVAudioPCMBuffer] = []
    private var inputEnded = false
    private var cancelled = false
    private var finished = false
    private var analyzer: SpeechAnalyzer?
    private var finalized = ""
    private var volatile = ""
    private var feeder: Task<Void, Never>?

    init(id: Int, language: Language,
         onText: @escaping @MainActor (String) -> Void,
         onFinish: @escaping @MainActor (Result<String, Error>) -> Void) {
        self.id = id
        self.language = language
        self.onText = onText
        self.onFinish = onFinish
    }

    /// Whether the file source has delivered all of its audio (self-test).
    var isFileFed: Bool { lock.withLock { fileFed } }
    private var fileFed = false

    func start(source: Source) {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        do {
            switch source {
            case .microphone: try startMicrophone()
            case let .file(url, speed): try startFile(url, speed: speed)
            }
        } catch {
            finish(.failure(error))
            return
        }
        Task { await run(stream) }
    }

    /// Ends the recording; the final transcript follows through `onFinish`.
    func stop() {
        stopAudio()
        endInput()
    }

    func cancel() {
        lock.withLock { cancelled = true }
        stopAudio()
        endInput()
        let analyzer = lock.withLock { self.analyzer }
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    // MARK: Recognition

    private func run(_ stream: AsyncStream<AnalyzerInput>) async {
        var results: Task<Void, Error>?
        defer { results?.cancel() }
        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: VoiceInput.locale(for: language)) else {
                throw VoiceError.unsupportedLanguage
            }
            guard await VoiceInput.isModelInstalled(language) else { throw VoiceError.modelMissing(language) }
            // Models are shared by all apps; reserve this one for us (a no-op once reserved).
            if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                do {
                    _ = try await AssetInventory.reserve(locale: locale)
                } catch {
                    log.error("could not reserve the speech locale: \(String(describing: error), privacy: .public)")
                }
            }
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw VoiceError.noAudioFormat
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let stop = lock.withLock { () -> Bool in
                self.analyzer = analyzer
                return cancelled
            }
            if stop { return }
            results = Task {
                for try await result in transcriber.results {
                    self.received(String(result.text.characters), isFinal: result.isFinal)
                }
            }
            try await analyzer.prepareToAnalyze(in: format)
            setTargetFormat(format)
            try await analyzer.start(inputSequence: stream)
            // Returns once the input has ended (stop / cancel) and everything is finalized.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results?.value
            let text = lock.withLock { Self.join(finalized, volatile) }
            finish(.success(text))
        } catch {
            finish(.failure(error))
        }
    }

    private func received(_ text: String, isFinal: Bool) {
        let current: String = lock.withLock {
            if isFinal {
                finalized = Self.join(finalized, text)
                volatile = ""
            } else {
                volatile = text
            }
            return Self.join(finalized, volatile)
        }
        guard !lock.withLock({ cancelled }) else { return }
        let onText = self.onText
        Task { @MainActor in onText(current) }
    }

    /// Joins recognized segments: English words get a space between them, Chinese doesn't.
    static func join(_ a: String, _ b: String) -> String {
        let b = a.isEmpty ? b.trimmingCharacters(in: .whitespaces) : b
        guard let last = a.last, let first = b.first, !last.isWhitespace, !first.isWhitespace else { return a + b }
        let latin: (Character) -> Bool = { ($0.isLetter || $0.isNumber) && !String($0).containsHan }
        return (latin(last) || ".,!?;:".contains(last)) && latin(first) ? a + " " + b : a + b
    }

    private func finish(_ result: Result<String, Error>) {
        let deliver: Bool = lock.withLock {
            defer { finished = true }
            return !finished && !cancelled
        }
        stopAudio()
        guard deliver else { return }
        let onFinish = self.onFinish
        let trimmed = result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        Task { @MainActor in onFinish(trimmed) }
    }

    // MARK: Audio

    private func startMicrophone() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        lock.withLock { inputFormat = format }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        lock.withLock { tapInstalled = true }
        engine.prepare()
        try engine.start()
    }

    private func startFile(_ url: URL, speed: Double) throws {
        let file = try AVAudioFile(forReading: url)
        lock.withLock { inputFormat = file.processingFormat }
        let task = Task.detached { [weak self] in
            let chunk: AVAudioFrameCount = 4096
            while !Task.isCancelled, let self {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0
                else { break }
                self.feed(buffer)
                let seconds = Double(buffer.frameLength) / file.processingFormat.sampleRate / max(speed, 0.1)
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard let self else { return }
            self.lock.withLock { self.fileFed = true }
        }
        lock.withLock { feeder = task }
    }

    /// Stops the microphone / file once, whichever thread gets here first; the engine itself is
    /// only touched on the main thread.
    private func stopAudio() {
        let (tap, feeder) = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            defer {
                tapInstalled = false
                self.feeder = nil
            }
            return (tapInstalled, self.feeder)
        }
        feeder?.cancel()
        guard tap else { return }
        let engine = self.engine
        let teardown = {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        if Thread.isMainThread { teardown() } else { DispatchQueue.main.async(execute: teardown) }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !inputEnded else { return }
        if let targetFormat {
            if let converted = convert(buffer, to: targetFormat) { continuation?.yield(AnalyzerInput(buffer: converted)) }
        } else if let copy = buffer.copy() as? AVAudioPCMBuffer {
            pending.append(copy)  // the tap reuses its buffers
        }
    }

    private func setTargetFormat(_ format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        targetFormat = format
        if let inputFormat, inputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
        }
        for buffer in pending {
            if let converted = convert(buffer, to: format) { continuation?.yield(AnalyzerInput(buffer: converted)) }
        }
        pending.removeAll()
        if inputEnded {
            drainConverter()
            continuation?.finish()
        }
    }

    private func endInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !inputEnded else { return }
        inputEnded = true
        // Audio queued before the format was known is flushed by setTargetFormat first.
        if cancelled {
            continuation?.finish()
        } else if targetFormat != nil {
            drainConverter()
            continuation?.finish()
        }
    }

    /// The sample-rate converter holds back a few milliseconds; hand them over at the end. Caller holds the lock.
    private func drainConverter() {
        guard let converter, let targetFormat,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status != .error, output.frameLength > 0 { continuation?.yield(AnalyzerInput(buffer: output)) }
    }

    /// Converts to the analyzer's format (sample rate, sample type, channels). Caller holds the lock.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else {
            // Same format: still copy, the tap reuses its buffers.
            return buffer.format == format ? buffer.copy() as? AVAudioPCMBuffer : nil
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
