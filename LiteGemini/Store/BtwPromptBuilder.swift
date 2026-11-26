import Foundation

// MARK: - BtwQuoteItem

/// Lightweight quoted passage attached to a `Btw` side-question turn, capped at `2,000` characters.
nonisolated struct BtwQuoteItem: Identifiable, Codable, Equatable, Hashable, Sendable {

    let id: UUID
    let quotedText: String
    let conversationId: String?
    let turnId: String?

    init(
        id: UUID = UUID(),
        quotedText: String,
        conversationId: String? = nil,
        turnId: String? = nil
    ) {
        self.id = id
        self.quotedText = BtwPromptBuilder.normalizeQuoteText(quotedText)
        self.conversationId = conversationId
        self.turnId = turnId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawQuotedText = try container.decode(String.self, forKey: .quotedText)
        self.quotedText = BtwPromptBuilder.normalizeQuoteText(rawQuotedText)
        self.conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        self.turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
    }
}

// MARK: - BtwPromptBuilder

/// Pure context-packing and prompt-assembly engine for the `Btw` ephemeral side-question panel,
/// matching Google's `btwUtils` 10-turn / 16,000-char packing and concise `<150 words` directives.
nonisolated enum BtwPromptBuilder: Sendable {

    // MARK: - Constants

    static let maxRecentTurns: Int = 10
    static let maxBackgroundChars: Int = 16_000
    static let maxFocusedTurnResponseChars: Int = 8_000
    static let maxRegularTurnResponseChars: Int = 2_400
    static let maxQuoteChars: Int = 2_000

    static let systemInstructionWithQuote: String =
        "You are answering a side question in Btw (an ephemeral side panel) so the main conversation stays clean. Focus on the highlighted passage, using the main conversation only as background. Keep your answer concise—under ~150 words unless asked for detail."

    static let systemInstructionWithoutQuote: String =
        "You are answering a side question in Btw (an ephemeral side panel) so the main conversation stays clean. Use the main conversation only as background context. Keep your answer concise—under ~150 words unless asked for detail."

    static let summarizePromptText: String =
        "Summarize the key takeaways, clarifications, or decisions from this Btw side thread in 2 to 5 concise Markdown bullet points (- ...) so they can be added back to the main conversation. Output only the bullet points with no preamble or closing text."

    static let notesPrefix: String = "Notes from Btw:"

    // MARK: - Slash Command Parsing

    /// Matches `/^\/btw(?:\s+([\s\S]*))?$/iu` against trimmed user input.
    static func parseSlashCommand(_ input: String) -> (matched: Bool, question: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else {
            return (false, "")
        }

        let prefixEnd = trimmed.index(trimmed.startIndex, offsetBy: 4)
        let prefix = trimmed[..<prefixEnd]
        guard prefix.lowercased() == "/btw" else {
            return (false, "")
        }

        if prefixEnd == trimmed.endIndex {
            return (true, "")
        }

        let nextCharacter = trimmed[prefixEnd]
        guard nextCharacter.isWhitespace else {
            return (false, "")
        }

        let question = String(trimmed[prefixEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, question)
    }

    // MARK: - Context Packing

    /// Packs the focused turn (if earlier than the last 10) plus up to the last `10` turns from
    /// the main conversation into `[Turn K | <id>]\nUser: ...\nGemini: ...` blocks, working
    /// backwards from the newest turn within the `16,000`-character budget.
    static func packMainChatBackground(
        turns: [ChatTurn],
        focusedTurnId: String?
    ) -> String {
        guard !turns.isEmpty else {
            return ""
        }

        let normalizedFocusId: String? = {
            guard let raw = focusedTurnId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return raw
        }()

        let recentStartIndex = max(0, turns.count - maxRecentTurns)
        var candidateIndices: [Int] = []
        candidateIndices.reserveCapacity(maxRecentTurns + 1)

        var focusedIndex: Int?
        if let normalizedFocusId {
            focusedIndex = turns.lastIndex { turn in
                turn.id == normalizedFocusId || turn.metadata.responseId == normalizedFocusId
            }
        }

        if let focusedIndex, focusedIndex < recentStartIndex {
            candidateIndices.append(focusedIndex)
        }
        candidateIndices.append(contentsOf: recentStartIndex..<turns.count)

        struct FormattedTurn {
            let turnIndex: Int
            let isFocused: Bool
            let block: String
        }

        let formattedCandidates: [FormattedTurn] = candidateIndices.compactMap { index in
            let turn = turns[index]
            let isFocused = (focusedIndex == index)
            guard let block = formatTurn(turn, turnNumber: index + 1, isFocused: isFocused) else {
                return nil
            }
            return FormattedTurn(turnIndex: index, isFocused: isFocused, block: block)
        }

        guard !formattedCandidates.isEmpty else {
            return ""
        }

        let separatorCount = 2 // "\n\n"
        var selectedByIndex: [Int: String] = [:]
        var usedChars = 0

        // Guarantee the focused turn fits inside the 16,000-char budget before packing recent turns.
        if let focusedCandidate = formattedCandidates.first(where: \.isFocused) {
            let fitted = truncate(focusedCandidate.block, maxChars: maxBackgroundChars)
            selectedByIndex[focusedCandidate.turnIndex] = fitted
            usedChars = fitted.count
        }

        for candidate in formattedCandidates.reversed() {
            if selectedByIndex[candidate.turnIndex] != nil {
                continue
            }

            let additionalCost = candidate.block.count + (selectedByIndex.isEmpty ? 0 : separatorCount)
            if usedChars + additionalCost <= maxBackgroundChars {
                selectedByIndex[candidate.turnIndex] = candidate.block
                usedChars += additionalCost
            } else if selectedByIndex.isEmpty {
                let fitted = truncate(candidate.block, maxChars: maxBackgroundChars)
                selectedByIndex[candidate.turnIndex] = fitted
                usedChars = fitted.count
                break
            } else {
                break
            }
        }

        return formattedCandidates
            .compactMap { selectedByIndex[$0.turnIndex] }
            .joined(separator: "\n\n")
    }

    // MARK: - Prompt Payload Assembly

    /// Builds the prompt payload dispatched to the isolated `Btw` ephemeral transport.
    /// First turns include the read-only main chat background, optional highlighted passages,
    /// and concise `<150 words` system instructions; subsequent turns send the clean follow-up
    /// directly (prepending any newly attached quotes if present).
    static func buildPromptPayload(
        userQuestion: String,
        quotes: [BtwQuoteItem],
        isFirstTurn: Bool,
        mainChatBackground: String
    ) -> String {
        let cleanQuestion = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let validQuotes = quotes.filter { !$0.quotedText.isEmpty }

        guard isFirstTurn else {
            if validQuotes.isEmpty {
                return cleanQuestion
            }
            var sections = validQuotes.map(formatQuoteSection)
            sections.append("Question: \(cleanQuestion)")
            return sections.joined(separator: "\n\n")
        }

        var sections: [String] = []

        let trimmedBackground = mainChatBackground.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBackground.isEmpty {
            sections.append("Main conversation background (read-only):\n\(trimmedBackground)")
        }

        for quote in validQuotes {
            sections.append(formatQuoteSection(quote))
        }

        sections.append(validQuotes.isEmpty ? systemInstructionWithoutQuote : systemInstructionWithQuote)
        sections.append("Question: \(cleanQuestion)")

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Summary Handoff

    /// Returns the official summarization directive sent to the `Btw` session before inserting notes
    /// back into the main conversation composer.
    static func buildSummarizePrompt() -> String {
        summarizePromptText
    }

    /// Formats a `Btw` summary into `"Notes from Btw:\n..."` ready to append into the main composer.
    static func formatNotesForMainChat(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if trimmed.lowercased().hasPrefix(notesPrefix.lowercased()) {
            return trimmed
        }
        return "\(notesPrefix)\n\(trimmed)"
    }

    // MARK: - Normalization & Truncation Helpers

    static func normalizeQuoteText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxQuoteChars else {
            return trimmed
        }
        return String(trimmed.prefix(maxQuoteChars))
    }

    static func truncate(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else {
            return ""
        }
        guard text.count > maxChars else {
            return text
        }
        if maxChars <= 1 {
            return String(text.prefix(maxChars))
        }
        return String(text.prefix(maxChars - 1)) + "…"
    }

    // MARK: - Private Formatting

    private static func formatTurn(
        _ turn: ChatTurn,
        turnNumber: Int,
        isFocused: Bool
    ) -> String? {
        let userText = turn.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAssistantText = turn.assistantMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !userText.isEmpty || !rawAssistantText.isEmpty else {
            return nil
        }

        let responseLimit = isFocused ? maxFocusedTurnResponseChars : maxRegularTurnResponseChars
        let promptLimit = isFocused ? maxFocusedTurnResponseChars : maxRegularTurnResponseChars
        let formattedUser = truncate(userText, maxChars: promptLimit)
        let formattedAssistant = truncate(rawAssistantText, maxChars: responseLimit)

        let turnIdentifier: String = {
            let trimmedId = turn.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedId.isEmpty {
                return trimmedId
            }
            if let responseId = turn.metadata.responseId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !responseId.isEmpty {
                return responseId
            }
            return "turn-\(turnNumber)"
        }()

        var lines: [String] = ["[Turn \(turnNumber) | \(turnIdentifier)]"]
        if !formattedUser.isEmpty {
            lines.append("User: \(formattedUser)")
        }
        if !formattedAssistant.isEmpty {
            lines.append("Gemini: \(formattedAssistant)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatQuoteSection(_ quote: BtwQuoteItem) -> String {
        let header: String
        if let turnId = quote.turnId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnId.isEmpty {
            header = "Highlighted passage (from turn \(turnId)):"
        } else {
            header = "Highlighted passage:"
        }
        return "\(header)\n\"\"\"\n\(quote.quotedText)\n\"\"\""
    }
}
