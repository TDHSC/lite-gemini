import AVFoundation
import CryptoKit
import Foundation
import Observation
import SwiftUI
import os

// MARK: - TurnSpeechController

/// Workspace-scoped neural TTS playback controller for assistant turns.
///
/// Sanitizes Markdown prose for natural speech, splits long responses into `<= 3,000` UTF-8 byte
/// sentence-aligned chunks, streams MP3 audio via `AVAudioPlayer` with single-chunk lookahead
/// prefetching for gapless multi-paragraph playback, and falls back to `AVSpeechSynthesizer`
/// whenever cloud audio synthesis is unavailable.
@MainActor
@Observable
final class TurnSpeechController: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {

    // MARK: - Constants

    nonisolated static let defaultMaxChunkUTF8Bytes: Int = 3_000
    nonisolated static let supportedPlaybackRates: [Float] = [1.0, 1.25, 1.5, 2.0]

    @ObservationIgnored
    private static let logger = Logger(subsystem: "io.github.tdhsc.LiteGemini", category: "TurnSpeechController")

    // MARK: - Observable State

    /// Identifier of the turn currently active (loading, playing, or paused), or `nil` when idle.
    private(set) var activeTurnId: UUID?
    /// `true` while audio or fallback system speech is actively playing.
    private(set) var isPlaying: Bool = false
    /// `true` while fetching the initial or next MP3 audio chunk.
    private(set) var isLoadingAudio: Bool = false
    /// Active playback speed multiplier (`1.0`, `1.25`, `1.5`, `2.0`).
    var playbackRate: Float = 1.0 {
        didSet {
            let clamped = Self.clampedPlaybackRate(playbackRate)
            if clamped != playbackRate {
                playbackRate = clamped
                return
            }
            if let audioPlayer {
                audioPlayer.enableRate = true
                audioPlayer.rate = playbackRate
            }
        }
    }

    /// Compact rate display string (e.g. `"1.0×"`, `"1.25×"`, `"1.5×"`, `"2.0×"`).
    var formattedPlaybackRate: String {
        Self.formatPlaybackRate(playbackRate)
    }

    // MARK: - Internal Playback State

    @ObservationIgnored private var playbackGeneration: UInt64 = 0
    @ObservationIgnored private var chunks: [String] = []
    @ObservationIgnored private var currentChunkIndex: Int = 0
    @ObservationIgnored private var resolvedLocale: String = "en-US"
    @ObservationIgnored private var activeSynthesizeChunk: (@MainActor (String, String) async -> Data?)?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var prefetchedChunkIndex: Int?
    @ObservationIgnored private var prefetchedAudioData: Data?
    @ObservationIgnored private var prefetchTask: Task<Data?, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var isUsingSystemSpeechFallback: Bool = false
    @ObservationIgnored private var speechSynthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var activeUtteranceId: ObjectIdentifier?

    // MARK: - Initialization

    override init() {
        super.init()
    }

    isolated deinit {
        playbackGeneration &+= 1
        playbackTask?.cancel()
        prefetchTask?.cancel()
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        speechSynthesizer?.delegate = nil
        speechSynthesizer?.stopSpeaking(at: .immediate)
    }

    // MARK: - Public Playback Controls

    /// Starts, pauses, or resumes neural TTS playback for `turnId`.
    ///
    /// Starting playback on a new turn immediately stops any previously active turn.
    /// If `synthesizeChunk` returns `nil` on chunk `0` (or fails to decode), playback seamlessly
    /// falls back to `AVSpeechSynthesizer` so reading aloud works even offline.
    func togglePlayback(
        turnId: UUID,
        markdown: String,
        localeHint: String? = nil,
        synthesizeChunk: @escaping @MainActor (String, String) async -> Data?
    ) {
        if activeTurnId == turnId {
            if isLoadingAudio {
                stop()
            } else if isPlaying {
                pause()
            } else {
                resume()
            }
            return
        }

        stop()

        let sanitized = Self.sanitizeMarkdownForSpeech(markdown)
        let chunked = Self.chunkTextForTTS(sanitized, maxUTF8Bytes: Self.defaultMaxChunkUTF8Bytes)
        guard !chunked.isEmpty else {
            return
        }

        let locale = Self.detectSpeechLocale(text: sanitized, hint: localeHint)
        playbackGeneration &+= 1
        let generation = playbackGeneration

        activeTurnId = turnId
        chunks = chunked
        currentChunkIndex = 0
        resolvedLocale = locale
        activeSynthesizeChunk = synthesizeChunk
        isUsingSystemSpeechFallback = false
        isLoadingAudio = true
        isPlaying = false

        playbackTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let firstAudioData = await synthesizeChunk(chunked[0], locale)
            guard !Task.isCancelled, self.playbackGeneration == generation else {
                return
            }

            if let firstAudioData, !firstAudioData.isEmpty,
               self.startAudioPlayer(with: firstAudioData, chunkIndex: 0, generation: generation) {
                return
            }

            Self.logger.notice("Cloud TTS unavailable for initial chunk; falling back to AVSpeechSynthesizer")
            self.startSystemSpeechFallback(fromChunkIndex: 0, generation: generation)
        }
    }

    /// Pauses active audio or system speech playback without discarding the current turn session.
    func pause() {
        guard activeTurnId != nil, isPlaying else {
            return
        }
        if isUsingSystemSpeechFallback {
            speechSynthesizer?.pauseSpeaking(at: .immediate)
        } else {
            audioPlayer?.pause()
        }
        isPlaying = false
    }

    /// Resumes paused audio or system speech playback for the active turn.
    func resume() {
        guard activeTurnId != nil, !isPlaying, !isLoadingAudio else {
            return
        }
        if isUsingSystemSpeechFallback {
            if speechSynthesizer?.continueSpeaking() == true {
                isPlaying = true
            }
        } else if let audioPlayer {
            audioPlayer.enableRate = true
            audioPlayer.rate = playbackRate
            if audioPlayer.play() {
                isPlaying = true
            }
        }
    }

    /// Stops all audio playback, cancels lookahead prefetch tasks, and resets observable state.
    func stop() {
        playbackGeneration &+= 1

        playbackTask?.cancel()
        playbackTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedChunkIndex = nil
        prefetchedAudioData = nil

        if let audioPlayer {
            audioPlayer.delegate = nil
            audioPlayer.stop()
            self.audioPlayer = nil
        }

        if let speechSynthesizer {
            speechSynthesizer.delegate = nil
            speechSynthesizer.stopSpeaking(at: .immediate)
            self.speechSynthesizer = nil
        }

        activeUtteranceId = nil
        isUsingSystemSpeechFallback = false
        activeSynthesizeChunk = nil
        chunks = []
        currentChunkIndex = 0
        activeTurnId = nil
        isLoadingAudio = false
        isPlaying = false
    }

    /// Cycles playback speed across `1.0×`, `1.25×`, `1.5×`, and `2.0×`.
    func cyclePlaybackRate() {
        let rates = Self.supportedPlaybackRates
        if let currentIndex = rates.firstIndex(where: { abs($0 - playbackRate) < 0.01 }) {
            playbackRate = rates[(currentIndex + 1) % rates.count]
        } else {
            playbackRate = rates[0]
        }
    }

    /// Sets playback speed directly, clamping to supported `AVAudioPlayer` bounds.
    func setPlaybackRate(_ rate: Float) {
        playbackRate = Self.clampedPlaybackRate(rate)
    }

    // MARK: - Private Audio & Lookahead Pipeline

    @discardableResult
    private func startAudioPlayer(with data: Data, chunkIndex: Int, generation: UInt64) -> Bool {
        guard playbackGeneration == generation else {
            return false
        }

        if let existing = audioPlayer {
            existing.delegate = nil
            existing.stop()
            audioPlayer = nil
        }

        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()

            audioPlayer = player
            currentChunkIndex = chunkIndex
            isUsingSystemSpeechFallback = false

            // Kick off lookahead prefetch for the next chunk before audio completes.
            schedulePrefetch(forChunkIndex: chunkIndex + 1, generation: generation)

            guard player.play() else {
                player.delegate = nil
                audioPlayer = nil
                return false
            }

            isLoadingAudio = false
            isPlaying = true
            return true
        } catch {
            Self.logger.error("AVAudioPlayer failed to decode TTS chunk \(chunkIndex): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func schedulePrefetch(forChunkIndex nextIndex: Int, generation: UInt64) {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedChunkIndex = nil
        prefetchedAudioData = nil

        guard chunks.indices.contains(nextIndex),
              let synthesizeChunk = activeSynthesizeChunk else {
            return
        }

        let chunkText = chunks[nextIndex]
        let locale = resolvedLocale
        prefetchedChunkIndex = nextIndex

        prefetchTask = Task { @MainActor [weak self] () -> Data? in
            let data = await synthesizeChunk(chunkText, locale)
            guard let self, !Task.isCancelled, self.playbackGeneration == generation else {
                return nil
            }
            if self.prefetchedChunkIndex == nextIndex {
                self.prefetchedAudioData = data
            }
            return data
        }
    }

    private func advanceToNextAudioChunk(generation: UInt64) {
        guard playbackGeneration == generation else {
            return
        }

        let nextIndex = currentChunkIndex + 1
        guard chunks.indices.contains(nextIndex) else {
            stop()
            return
        }

        // Fast path: lookahead chunk already buffered -> zero-gap playback.
        if prefetchedChunkIndex == nextIndex, let buffered = prefetchedAudioData {
            prefetchedChunkIndex = nil
            prefetchedAudioData = nil
            prefetchTask = nil
            if !buffered.isEmpty, startAudioPlayer(with: buffered, chunkIndex: nextIndex, generation: generation) {
                return
            }
            startSystemSpeechFallback(fromChunkIndex: nextIndex, generation: generation)
            return
        }

        // Slow path: await in-flight prefetch task or synthesize on demand.
        let inFlightTask = (prefetchedChunkIndex == nextIndex) ? prefetchTask : nil
        prefetchedChunkIndex = nil
        prefetchedAudioData = nil
        prefetchTask = nil

        isLoadingAudio = true
        isPlaying = false

        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let nextData: Data?
            if let inFlightTask {
                nextData = await inFlightTask.value
            } else if let synthesizeChunk = self.activeSynthesizeChunk, self.chunks.indices.contains(nextIndex) {
                nextData = await synthesizeChunk(self.chunks[nextIndex], self.resolvedLocale)
            } else {
                nextData = nil
            }

            guard !Task.isCancelled, self.playbackGeneration == generation else {
                return
            }

            if let nextData, !nextData.isEmpty,
               self.startAudioPlayer(with: nextData, chunkIndex: nextIndex, generation: generation) {
                return
            }

            Self.logger.notice("Cloud TTS unavailable on chunk \(nextIndex); continuing via AVSpeechSynthesizer")
            self.startSystemSpeechFallback(fromChunkIndex: nextIndex, generation: generation)
        }
    }

    private func startSystemSpeechFallback(fromChunkIndex index: Int, generation: UInt64) {
        guard playbackGeneration == generation else {
            return
        }
        guard chunks.indices.contains(index) else {
            stop()
            return
        }

        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedChunkIndex = nil
        prefetchedAudioData = nil

        if let audioPlayer {
            audioPlayer.delegate = nil
            audioPlayer.stop()
            self.audioPlayer = nil
        }

        let synthesizer: AVSpeechSynthesizer
        if let existing = speechSynthesizer {
            synthesizer = existing
        } else {
            let created = AVSpeechSynthesizer()
            created.delegate = self
            speechSynthesizer = created
            synthesizer = created
        }

        isUsingSystemSpeechFallback = true
        currentChunkIndex = index
        isLoadingAudio = false
        isPlaying = true

        speakSystemChunk(at: index, using: synthesizer)
    }

    private func speakSystemChunk(at index: Int, using synthesizer: AVSpeechSynthesizer) {
        guard chunks.indices.contains(index) else {
            stop()
            return
        }

        let utterance = AVSpeechUtterance(string: chunks[index])
        if let voice = AVSpeechSynthesisVoice(language: resolvedLocale) {
            utterance.voice = voice
        }
        utterance.rate = Self.mappedSystemSpeechRate(for: playbackRate)
        activeUtteranceId = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    // MARK: - Delegate Callbacks (Strict Swift 6 Isolation)

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerId = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.handleAudioPlayerDidFinish(playerId: playerId, successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let playerId = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.handleAudioPlayerDecodeError(playerId: playerId)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceId = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleSystemSpeechDidFinish(utteranceId: utteranceId)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceId = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleSystemSpeechDidCancel(utteranceId: utteranceId)
        }
    }

    private func handleAudioPlayerDidFinish(playerId: ObjectIdentifier, successfully: Bool) {
        guard let currentPlayer = audioPlayer, ObjectIdentifier(currentPlayer) == playerId else {
            return
        }
        let generation = playbackGeneration
        if successfully {
            advanceToNextAudioChunk(generation: generation)
        } else {
            startSystemSpeechFallback(fromChunkIndex: currentChunkIndex, generation: generation)
        }
    }

    private func handleAudioPlayerDecodeError(playerId: ObjectIdentifier) {
        guard let currentPlayer = audioPlayer, ObjectIdentifier(currentPlayer) == playerId else {
            return
        }
        startSystemSpeechFallback(fromChunkIndex: currentChunkIndex, generation: playbackGeneration)
    }

    private func handleSystemSpeechDidFinish(utteranceId: ObjectIdentifier) {
        guard isUsingSystemSpeechFallback, activeUtteranceId == utteranceId else {
            return
        }
        let nextIndex = currentChunkIndex + 1
        guard chunks.indices.contains(nextIndex), let synthesizer = speechSynthesizer else {
            stop()
            return
        }
        currentChunkIndex = nextIndex
        speakSystemChunk(at: nextIndex, using: synthesizer)
    }

    private func handleSystemSpeechDidCancel(utteranceId: ObjectIdentifier) {
        guard isUsingSystemSpeechFallback, activeUtteranceId == utteranceId else {
            return
        }
        isPlaying = false
    }

    // MARK: - Pure Text Pipeline (nonisolated)

    /// Strips non-spoken Markdown syntax so neural and system TTS read prose naturally.
    ///
    /// Removes fenced code blocks (` ```...``` ` / `~~~...~~~`), display math (`$$...$$`),
    /// Markdown table separator rows (`|---|---|`), image URLs (preserving `alt`), link URLs
    /// (preserving `label`), raw `https?://` URLs, heading `#` prefixes, and `*`/`_`/`~`/`` ` `` markers.
    nonisolated static func sanitizeMarkdownForSpeech(_ markdown: String) -> String {
        guard !markdown.isEmpty else {
            return ""
        }

        var text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 1. Strip fenced code blocks (backtick or tilde, closed or unclosed trailing fence).
        text = stripFencedCodeBlocks(in: text)

        // 2. Strip display math blocks (`$$...$$`).
        text = replacingMatches(
            in: text,
            pattern: #"\$\$[\s\S]*?\$\$"#,
            options: [],
            replacement: " "
        )

        // 3. Process line-oriented Markdown constructs (table separators, HR, reference defs, headings, quotes).
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var cleanedLines: [String] = []
        cleanedLines.reserveCapacity(rawLines.count)

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                cleanedLines.append("")
                continue
            }

            // Skip Markdown table alignment separator rows (`|---|---|`, `:---:|:---:`).
            if isTableSeparatorRow(trimmed) {
                continue
            }

            // Skip horizontal rules (`---`, `***`, `___`).
            if isThematicBreakRow(trimmed) {
                continue
            }

            // Skip reference link definitions (`[id]: https://...`).
            if matchesPattern(trimmed, pattern: #"^\[[^\]]+\]:\s+\S+"#) {
                continue
            }

            var line = rawLine

            // Strip leading blockquote markers (`> `).
            line = replacingMatches(in: line, pattern: #"^\s*(?:>\s?)+"#, options: [], replacement: "")

            // Strip heading `#` prefixes (and optional closing `#` markers).
            line = replacingMatches(in: line, pattern: #"^\s*#{1,6}\s+"#, options: [], replacement: "")
            line = replacingMatches(in: line, pattern: #"\s+#+\s*$"#, options: [], replacement: "")

            // Strip unordered list bullet prefixes (`- `, `* `, `+ `) and task checkboxes (`[x] `).
            line = replacingMatches(in: line, pattern: #"^\s*[-*+]\s+(?:\[[ xX]\]\s+)?"#, options: [], replacement: "")

            // Convert pipe-delimited table rows into comma-separated spoken phrases.
            let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
            if lineTrimmed.contains("|"),
               (lineTrimmed.hasPrefix("|") || lineTrimmed.hasSuffix("|") || lineTrimmed.contains(" | ")) {
                let cells = lineTrimmed
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                line = cells.joined(separator: ", ")
            }

            cleanedLines.append(line)
        }

        text = cleanedLines.joined(separator: "\n")

        // 4. Replace image syntax `![alt](url)` -> `alt` (must precede link replacement).
        text = replacingMatches(
            in: text,
            pattern: #"!\[([^\]]*)\]\((?:[^()\s]+|\([^()]*\))*(?:\s+"[^"]*")?\)"#,
            options: [],
            replacement: "$1"
        )

        // 5. Replace inline links `[label](url)` -> `label` and reference links `[label][ref]` -> `label`.
        text = replacingMatches(
            in: text,
            pattern: #"\[([^\]]+)\]\((?:[^()\s]+|\([^()]*\))*(?:\s+"[^"]*")?\)"#,
            options: [],
            replacement: "$1"
        )
        text = replacingMatches(
            in: text,
            pattern: #"\[([^\]]+)\]\[[^\]]*\]"#,
            options: [],
            replacement: "$1"
        )

        // 6. Strip raw `http://` and `https://` URLs while preserving sentence-ending punctuation.
        text = stripRawURLs(in: text)

        // 7. Strip simple inline HTML tags (`<br>`, `<span>`, `</span>`, etc.).
        text = replacingMatches(
            in: text,
            pattern: #"</?[a-zA-Z][a-zA-Z0-9-]*(?:\s+[^<>]*)?/?>"#,
            options: [],
            replacement: " "
        )

        // 8. Strip inline formatting tokens (`*`, `_`, `~`, `` ` ``).
        // Replace word-internal underscores (`snake_case`) with spaces for natural speech before stripping remaining `_`.
        text = replacingMatches(
            in: text,
            pattern: #"(?<=[A-Za-z0-9])_(?=[A-Za-z0-9])"#,
            options: [],
            replacement: " "
        )
        text = text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "`", with: "")

        // 9. Normalize horizontal spaces and collapse excess blank lines.
        let normalizedLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let collapsed = replacingMatches(in: String(line), pattern: #"[ \t]{2,}"#, options: [], replacement: " ")
                return collapsed
                    .replacingOccurrences(of: " .", with: ".")
                    .replacingOccurrences(of: " ,", with: ",")
                    .trimmingCharacters(in: .whitespaces)
            }

        var finalLines: [String] = []
        finalLines.reserveCapacity(normalizedLines.count)
        for line in normalizedLines where !line.isEmpty {
            finalLines.append(line)
        }

        return finalLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits speech-ready prose into chunks of at most `maxUTF8Bytes` UTF-8 bytes.
    ///
    /// Prefers sentence boundaries (`。`, `！`, `？`, `.`, `!`, `?`, `\n`), falling back to clause
    /// boundaries (`，`, `；`, `,`, `;`, ` `) and ultimately UTF-8 scalar boundaries so no returned
    /// chunk ever exceeds `maxUTF8Bytes`.
    nonisolated static func chunkTextForTTS(
        _ text: String,
        maxUTF8Bytes: Int = TurnSpeechController.defaultMaxChunkUTF8Bytes
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let budget = max(4, maxUTF8Bytes)
        if trimmed.utf8.count <= budget {
            return [trimmed]
        }

        let sentences = splitIntoSentenceSegments(trimmed)
        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let cleaned = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                chunks.append(cleaned)
            }
            current = ""
        }

        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSentence.isEmpty else {
                continue
            }

            if trimmedSentence.utf8.count > budget {
                flushCurrent()
                chunks.append(contentsOf: splitOversizedSegment(trimmedSentence, maxUTF8Bytes: budget))
                continue
            }

            if current.isEmpty {
                current = trimmedSentence
            } else {
                let separator = preferredJoinSeparator(between: current, and: trimmedSentence)
                let combinedBytes = current.utf8.count + separator.utf8.count + trimmedSentence.utf8.count
                if combinedBytes <= budget {
                    current += separator + trimmedSentence
                } else {
                    flushCurrent()
                    current = trimmedSentence
                }
            }
        }

        flushCurrent()
        return chunks
    }

    /// Resolves a BCP-47 speech locale, honoring valid `hint` values before falling back to
    /// script-ratio inspection (`zh-CN`, `ja-JP`, `ko-KR`, default `en-US`).
    nonisolated static func detectSpeechLocale(text: String, hint: String?) -> String {
        if let hint, let normalizedHint = normalizedBCP47Locale(hint) {
            return normalizedHint
        }

        var hangulCount = 0
        var kanaCount = 0
        var hanCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                hangulCount += 1
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
                kanaCount += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
                hanCount += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
                latinCount += 1
            default:
                break
            }
        }

        let totalScriptLetters = hangulCount + kanaCount + hanCount + latinCount
        guard totalScriptLetters > 0 else {
            return "en-US"
        }

        let total = Double(totalScriptLetters)
        if kanaCount > 0 && (kanaCount >= 3 || Double(kanaCount + hanCount) / total >= 0.15) {
            return "ja-JP"
        }
        if hangulCount > 0 && (hangulCount >= 3 || Double(hangulCount) / total >= 0.15) {
            return "ko-KR"
        }
        if hanCount > 0 && Double(hanCount) / total >= 0.15 {
            return "zh-CN"
        }
        return "en-US"
    }

    /// Deterministically maps a string turn identifier (such as `ChatTurn.id`) to a stable `UUID`.
    nonisolated static func stableTurnUUID(for turnIdentifier: String) -> UUID {
        if let parsed = UUID(uuidString: turnIdentifier) {
            return parsed
        }
        let digest = Array(SHA256.hash(data: Data(turnIdentifier.utf8)))
        let bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], (digest[6] & 0x0F) | 0x50, digest[7],
            (digest[8] & 0x3F) | 0x80, digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }

    // MARK: - Private Text Pipeline Helpers

    private nonisolated static func stripFencedCodeBlocks(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var activeFence: (char: Character, length: Int)? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                if isClosingFence(trimmed, char: fence.char, minLength: fence.length) {
                    activeFence = nil
                }
                continue
            }
            if let opened = openingFence(trimmed) {
                activeFence = opened
                continue
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private nonisolated static func openingFence(_ trimmedLine: String) -> (char: Character, length: Int)? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else {
            return nil
        }
        var count = 0
        for ch in trimmedLine {
            if ch == first {
                count += 1
            } else {
                break
            }
        }
        guard count >= 3 else {
            return nil
        }
        return (char: first, length: count)
    }

    private nonisolated static func isClosingFence(_ trimmedLine: String, char: Character, minLength: Int) -> Bool {
        var count = 0
        for ch in trimmedLine {
            if ch == char {
                count += 1
            } else {
                return false
            }
        }
        return count >= minLength
    }

    private nonisolated static func isTableSeparatorRow(_ trimmed: String) -> Bool {
        guard trimmed.contains("-") else {
            return false
        }
        return matchesPattern(trimmed, pattern: #"^\|?(?:\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?$"#)
            || matchesPattern(trimmed, pattern: #"^\|?\s*:?-{3,}:?\s*\|?$"#)
    }

    private nonisolated static func isThematicBreakRow(_ trimmed: String) -> Bool {
        matchesPattern(trimmed, pattern: #"^(?:-\s*){3,}$|^(?:\*\s*){3,}$|^(?:_\s*){3,}$"#)
    }

    private nonisolated static func stripRawURLs(in text: String) -> String {
        guard text.contains("http://") || text.contains("https://"),
              let regex = try? NSRegularExpression(pattern: #"https?://\S+"#, options: []) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else {
            return text
        }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let matchedString = nsText.substring(with: match.range)
            // Keep a trailing sentence terminator if the URL sat directly at the end of a sentence.
            if let lastChar = matchedString.last,
               ".!?;,。！？；，".contains(lastChar) {
                mutable.replaceCharacters(in: match.range, with: String(lastChar))
            } else {
                mutable.replaceCharacters(in: match.range, with: "")
            }
        }
        return mutable as String
    }

    private nonisolated static func replacingMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options,
        replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private nonisolated static func matchesPattern(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private nonisolated static func splitIntoSentenceSegments(_ text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        let trailingClosers: Set<Character> = ["”", "\"", "'", "’", ")", "）", "]", "】", "」", "』"]

        var segments: [String] = []
        var buffer = ""
        let chars = Array(text)
        let count = chars.count
        var idx = 0

        while idx < count {
            let ch = chars[idx]
            if ch == "\n" {
                let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    segments.append(piece)
                }
                buffer = ""
                idx += 1
                continue
            }

            buffer.append(ch)
            let isSentenceBreak: Bool
            if ch == "." {
                isSentenceBreak = (idx + 1 == count)
                    || chars[idx + 1].isWhitespace
                    || trailingClosers.contains(chars[idx + 1])
                    || chars[idx + 1] == "."
            } else {
                isSentenceBreak = terminators.contains(ch)
            }

            if isSentenceBreak {
                // Consume repeated punctuation (`...`, `?!`) and closing quotes attached to the sentence.
                while idx + 1 < count,
                      (terminators.contains(chars[idx + 1]) && chars[idx + 1] != "\n")
                      || trailingClosers.contains(chars[idx + 1]) {
                    idx += 1
                    buffer.append(chars[idx])
                }
                let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    segments.append(piece)
                }
                buffer = ""
            }
            idx += 1
        }

        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            segments.append(remainder)
        }
        return segments
    }

    private nonisolated static func splitOversizedSegment(_ segment: String, maxUTF8Bytes: Int) -> [String] {
        let clauseDelimiters: Set<Character> = ["，", "；", ",", ";", " ", "、", "：", ":"]
        let clauses = splitPreservingDelimiters(segment, delimiters: clauseDelimiters)

        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let cleaned = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                chunks.append(cleaned)
            }
            current = ""
        }

        for clause in clauses {
            guard !clause.isEmpty else {
                continue
            }
            if clause.utf8.count > maxUTF8Bytes {
                flushCurrent()
                chunks.append(contentsOf: splitByUTF8Scalars(clause, maxUTF8Bytes: maxUTF8Bytes))
                continue
            }

            if current.isEmpty {
                current = clause.trimmingCharacters(in: .whitespaces)
            } else if current.utf8.count + clause.utf8.count <= maxUTF8Bytes {
                current += clause
            } else {
                flushCurrent()
                current = clause.trimmingCharacters(in: .whitespaces)
            }
        }

        flushCurrent()
        return chunks
    }

    private nonisolated static func splitPreservingDelimiters(
        _ text: String,
        delimiters: Set<Character>
    ) -> [String] {
        var parts: [String] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            if delimiters.contains(ch) {
                parts.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            parts.append(buffer)
        }
        return parts
    }

    private nonisolated static func splitByUTF8Scalars(_ text: String, maxUTF8Bytes: Int) -> [String] {
        var chunks: [String] = []
        var buffer = ""
        var bufferBytes = 0

        for scalar in text.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            if bufferBytes > 0 && bufferBytes + scalarBytes > maxUTF8Bytes {
                let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    chunks.append(piece)
                }
                buffer = ""
                bufferBytes = 0
            }
            buffer.unicodeScalars.append(scalar)
            bufferBytes += scalarBytes
        }

        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            chunks.append(remainder)
        }
        return chunks
    }

    private nonisolated static func preferredJoinSeparator(between lhs: String, and rhs: String) -> String {
        guard let lastScalar = lhs.unicodeScalars.last,
              let firstScalar = rhs.unicodeScalars.first else {
            return " "
        }
        if isCJKOrJapaneseScalar(lastScalar) && isCJKOrJapaneseScalar(firstScalar) {
            return ""
        }
        return " "
    }

    private nonisolated static func isCJKOrJapaneseScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    private nonisolated static func normalizedBCP47Locale(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty else {
            return nil
        }

        let subtags = trimmed.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let primary = subtags.first,
              (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }

        for subtag in subtags.dropFirst() {
            guard (1...8).contains(subtag.count),
                  subtag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                return nil
            }
        }

        let canonicalLower = trimmed.lowercased()
        switch canonicalLower {
        case "zh", "zh-hans":
            return "zh-CN"
        case "zh-hant":
            return "zh-TW"
        case "ja":
            return "ja-JP"
        case "ko":
            return "ko-KR"
        case "en":
            return "en-US"
        default:
            if subtags.count == 1 {
                return primary.lowercased()
            }
            var formatted: [String] = [primary.lowercased()]
            for subtag in subtags.dropFirst() {
                if subtag.count == 2 {
                    formatted.append(subtag.uppercased())
                } else if subtag.count == 4 {
                    formatted.append(subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased())
                } else {
                    formatted.append(subtag.lowercased())
                }
            }
            return formatted.joined(separator: "-")
        }
    }

    private nonisolated static func clampedPlaybackRate(_ rate: Float) -> Float {
        min(max(rate, 0.5), 2.0)
    }

    private nonisolated static func formatPlaybackRate(_ rate: Float) -> String {
        if abs(rate - 1.25) < 0.01 {
            return "1.25×"
        }
        if abs(rate - 1.5) < 0.01 {
            return "1.5×"
        }
        if abs(rate - 2.0) < 0.01 {
            return "2.0×"
        }
        if abs(rate - 1.0) < 0.01 {
            return "1.0×"
        }
        return String(format: "%.2g×", rate)
    }

    private nonisolated static func mappedSystemSpeechRate(for multiplier: Float) -> Float {
        let base = AVSpeechUtteranceDefaultSpeechRate
        let delta = (multiplier - 1.0) * 0.22
        return min(
            max(base + delta, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
    }
}

// MARK: - TurnSpeechControlView

/// Compact Liquid Glass TTS control embedded in an assistant turn's footer.
///
/// Renders as a circular speaker orb while idle on `turnId` and morphs into an inline
/// `[ ⏸/▶️  1.0×  ⏹ ]` Liquid Glass capsule while active on `turnId`.
struct TurnSpeechControlView: View {

    let turnId: UUID
    let markdown: String
    var localeHint: String? = nil
    let controller: TurnSpeechController
    let synthesizeChunk: @MainActor (String, String) async -> Data?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringIdle = false
    @State private var isHoveringPlayPause = false
    @State private var isHoveringRate = false
    @State private var isHoveringStop = false

    private var isActiveTurn: Bool {
        controller.activeTurnId == turnId
    }

    init(
        turnId: UUID,
        markdown: String,
        localeHint: String? = nil,
        controller: TurnSpeechController,
        synthesizeChunk: @escaping @MainActor (String, String) async -> Data?
    ) {
        self.turnId = turnId
        self.markdown = markdown
        self.localeHint = localeHint
        self.controller = controller
        self.synthesizeChunk = synthesizeChunk
    }

    init(
        turnKey: String,
        markdown: String,
        localeHint: String? = nil,
        controller: TurnSpeechController,
        synthesizeChunk: @escaping @MainActor (String, String) async -> Data?
    ) {
        self.init(
            turnId: TurnSpeechController.stableTurnUUID(for: turnKey),
            markdown: markdown,
            localeHint: localeHint,
            controller: controller,
            synthesizeChunk: synthesizeChunk
        )
    }

    var body: some View {
        Group {
            if isActiveTurn {
                activePlaybackCapsule
            } else {
                idleSpeakerOrb
            }
        }
        .animation(LiquidGlassMotion.morph(reduceMotion: reduceMotion), value: isActiveTurn)
    }

    // MARK: - Idle Orb

    private var idleSpeakerOrb: some View {
        Button {
            controller.togglePlayback(
                turnId: turnId,
                markdown: markdown,
                localeHint: localeHint,
                synthesizeChunk: synthesizeChunk
            )
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isHoveringIdle ? 0.94 : 0.68))
                .glassOrb(
                    size: 28,
                    variant: .clear,
                    tint: isHoveringIdle ? LiquidGlassColors.hoverHighlight : nil,
                    interactive: true
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHoveringIdle = hovering
            }
        }
        .help(String(localized: "Listen"))
        .accessibilityLabel(Text("Listen"))
    }

    // MARK: - Active Playback Capsule

    private var activePlaybackCapsule: some View {
        HStack(spacing: 2) {
            Button {
                controller.togglePlayback(
                    turnId: turnId,
                    markdown: markdown,
                    localeHint: localeHint,
                    synthesizeChunk: synthesizeChunk
                )
            } label: {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(isHoveringPlayPause ? LiquidGlassColors.hoverHighlight : Color.clear)

                    if controller.isLoadingAudio {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(LiquidGlassColors.sendButtonBlue)
                    }
                }
                .frame(width: 24, height: 22)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringPlayPause = hovering
                }
            }
            .help(controller.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
            .accessibilityLabel(controller.isPlaying ? Text("Pause") : Text("Play"))

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(width: 1, height: 12)

            Button {
                controller.cyclePlaybackRate()
            } label: {
                Text(verbatim: controller.formattedPlaybackRate)
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(isHoveringRate ? 0.96 : 0.80))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isHoveringRate ? LiquidGlassColors.hoverHighlight : Color.clear)
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringRate = hovering
                }
            }
            .help(String(localized: "Playback Speed"))
            .accessibilityLabel(Text("Playback Speed \(controller.formattedPlaybackRate)"))

            Rectangle()
                .fill(LiquidGlassColors.subtleHairline)
                .frame(width: 1, height: 12)

            Button {
                controller.stop()
            } label: {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(isHoveringStop ? LiquidGlassColors.hoverHighlight : Color.clear)

                    Image(systemName: "stop.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(isHoveringStop ? 0.94 : 0.70))
                }
                .frame(width: 24, height: 22)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringStop = hovering
                }
            }
            .help(String(localized: "Stop"))
            .accessibilityLabel(Text("Stop"))
        }
        .padding(.horizontal, 3)
        .frame(height: 28)
        .glassCapsule(
            variant: .clear,
            tint: LiquidGlassColors.sendButtonBlue.opacity(0.08),
            interactive: true
        )
    }
}
