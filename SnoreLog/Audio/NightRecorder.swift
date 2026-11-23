import AVFoundation
import Foundation
import Observation

/// Records the night to short AAC files and keeps a per-second loudness track.
///
/// Snore detection does not run live: Apple's built-in sound classifier fails while
/// the app is in the background, so the audio is analyzed in the morning instead.
@Observable
final class NightRecorder {
    enum State: Equatable {
        case idle
        case recording
        /// A phone call, alarm or Siri took the microphone. Recording resumes when it ends.
        case interrupted
    }

    enum RecorderError: LocalizedError {
        case noMicrophone
        case cannotConvert

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "No microphone is available."
            case .cannotConvert: "The microphone's audio format isn't supported."
            }
        }
    }

    private(set) var state: State = .idle
    /// Recent level in dBFS, for the live meter.
    private(set) var currentLevel: Float = -80
    /// Seconds of audio recorded so far.
    private(set) var recordedSeconds: TimeInterval = 0

    // Everything below is touched on `queue` (or before the engine starts).
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let queue = DispatchQueue(label: "NightRecorder.write", qos: .userInitiated)
    @ObservationIgnored private var currentFile: AVAudioFile?
    @ObservationIgnored private var framesInSegment: AVAudioFramePosition = 0
    @ObservationIgnored private var totalFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var manifest = RecordingManifest()
    @ObservationIgnored private var folder: URL?

    // Level metering: RMS over 100 ms blocks, keep the loudest block of each second.
    @ObservationIgnored private var blockSumSquares: Float = 0
    @ObservationIgnored private var blockCount = 0
    @ObservationIgnored private var blocksThisSecond = 0
    @ObservationIgnored private var loudestBlockThisSecond: Float = -120
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private let blockSize = Int(RecordingFormat.sampleRate / 10)

    // MARK: - Start and stop

    func start(in folder: URL) throws {
        guard state == .idle else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep the recordings out of iCloud and iTunes backups. They are private and large.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableFolder = folder
        try? mutableFolder.setResourceValues(values)

        queue.sync {
            self.folder = folder
            self.manifest = RecordingManifest()
            self.currentFile = nil
            self.framesInSegment = 0
            self.totalFrames = 0
            self.resetMeter()
        }

        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers lets people keep a sleep-sounds app playing.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)

        try startEngine()
        addObservers()
        setState(.recording)
    }

    /// Stops recording, closes the last file and saves the manifest.
    func stop() {
        guard state != .idle else { return }
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {
            self.flushPartialSecond()
            self.currentFile = nil // Releasing the file finalizes the AAC container.
            self.saveManifest()
            self.folder = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        setState(.idle)
        DispatchQueue.main.async {
            self.currentLevel = -80
            self.recordedSeconds = 0
        }
    }

    // MARK: - Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noMicrophone }
        guard let converter = AVAudioConverter(from: inputFormat, to: RecordingFormat.processing) else {
            throw RecorderError.cannotConvert
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Convert on the audio thread (cheap), then meter and write on our own queue.
            guard let self, let output = NightRecorder.convert(buffer, with: converter) else { return }
            self.queue.async { self.handle(output) }
        }
        engine.prepare()
        try engine.start()
    }

    private func restartEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Start a new file, since the gap means the old file's timing would be off.
        queue.async { self.currentFile = nil }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
            setState(.recording)
        } catch {
            setState(.interrupted)
        }
    }

    // MARK: - Processing (on `queue`)

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = RecordingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: RecordingFormat.processing, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard folder != nil else { return }
        meter(buffer)
        write(buffer)
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let folder else { return }
        let segmentFrames = AVAudioFramePosition(RecordingFormat.segmentSeconds * RecordingFormat.sampleRate)
        if currentFile == nil || framesInSegment >= segmentFrames {
            let index = manifest.segments.count
            let name = String(format: "segment-%04d.m4a", index)
            let url = folder.appendingPathComponent(name)
            currentFile = try? AVAudioFile(
                forWriting: url,
                settings: RecordingFormat.fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            framesInSegment = 0
            if currentFile != nil {
                manifest.segments.append(.init(fileName: name, startOffset: Double(totalFrames) / RecordingFormat.sampleRate))
                saveManifest()
            }
        }
        guard let currentFile else { return }
        do {
            try currentFile.write(from: buffer)
            framesInSegment += AVAudioFramePosition(buffer.frameLength)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            self.currentFile = nil // Try a fresh file on the next buffer.
        }
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        for i in 0..<Int(buffer.frameLength) {
            let s = samples[i]
            blockSumSquares += s * s
            blockCount += 1
            if blockCount == blockSize {
                finishBlock()
            }
        }
    }

    private func finishBlock() {
        let rms = sqrt(blockSumSquares / Float(max(blockCount, 1)))
        let db = max(-120, 20 * log10(max(rms, 1e-7)))
        blockSumSquares = 0
        blockCount = 0
        loudestBlockThisSecond = max(loudestBlockThisSecond, db)
        blocksThisSecond += 1

        if blocksThisSecond % 5 == 0 {
            let level = db
            let seconds = Double(totalFrames) / RecordingFormat.sampleRate
            DispatchQueue.main.async {
                self.currentLevel = level
                self.recordedSeconds = seconds
            }
        }
        if blocksThisSecond == 10 {
            manifest.levels.append(loudestBlockThisSecond)
            loudestBlockThisSecond = -120
            blocksThisSecond = 0
            // Save every 5 minutes so a crash loses little.
            if manifest.levels.count % 300 == 0 { saveManifest() }
        }
    }

    private func flushPartialSecond() {
        if blockCount > 0 { finishBlock() }
        if blocksThisSecond > 0 {
            manifest.levels.append(loudestBlockThisSecond)
        }
        resetMeter()
    }

    private func resetMeter() {
        blockSumSquares = 0
        blockCount = 0
        blocksThisSecond = 0
        loudestBlockThisSecond = -120
    }

    private func saveManifest() {
        guard let folder else { return }
        try? manifest.save(to: folder)
    }

    // MARK: - Interruptions and route changes

    private func addObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            self.restartEngine()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            guard let self, self.state != .idle else { return }
            try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            self.restartEngine()
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            setState(.interrupted)
        case .ended:
            // Always try to resume: an overnight recorder should keep going after a call or alarm.
            restartEngine()
        @unknown default:
            break
        }
    }

    private func setState(_ newState: State) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }
}
