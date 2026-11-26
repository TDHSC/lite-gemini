import AppKit
import Foundation

// Compile-time shim for `LiquidGlassColors.canvasBackground` (no AppKit windows or NSApp ever created).
enum AppDelegate {
    static let geminiSurfaceNSColor = NSColor.windowBackgroundColor
}

// MARK: - Minimal Test Harness

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private var passedTests = 0
private var failedTests = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if !condition() {
        throw TestFailure(message: "\(file):\(line) — \(message)")
    }
}

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if actual != expected {
        let suffix = message.isEmpty ? "" : " (\(message))"
        throw TestFailure(message: "\(file):\(line) — expected \(expected), got \(actual)\(suffix)")
    }
}

private func runTest(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passedTests += 1
        print("  [PASS] \(name)")
    } catch {
        failedTests += 1
        fputs("  [FAIL] \(name): \(error)\n", stderr)
    }
}

// MARK: - Pure Binary Protobuf Encoder (Test Fixture Builder)

private enum ProtoEncoder {
    static func varint(_ value: UInt64) -> Data {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while v != 0
        return Data(bytes)
    }

    static func tag(field: Int, wireType: Int) -> Data {
        varint(UInt64((field << 3) | wireType))
    }

    static func fieldVarint(_ field: Int, _ value: UInt64) -> Data {
        var out = tag(field: field, wireType: 0)
        out.append(varint(value))
        return out
    }

    static func fieldBool(_ field: Int, _ value: Bool) -> Data {
        fieldVarint(field, value ? 1 : 0)
    }

    static func fieldBytes(_ field: Int, _ payload: Data) -> Data {
        var out = tag(field: field, wireType: 2)
        out.append(varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    static func fieldString(_ field: Int, _ text: String) -> Data {
        fieldBytes(field, Data(text.utf8))
    }

    static func message(_ parts: [Data]) -> Data {
        var out = Data()
        for p in parts {
            out.append(p)
        }
        return out
    }
}

// MARK: - Test Suites

@main
struct OfflineContractTestRunner {
    static func main() {
        print("Running Lite Gemini Offline Protocol & Algorithm Contract Tests (v2.0 + v2.1 + v2.2)...")

        runTest("v2.0 WIZ signed-in vs signed-out auth state resolution") {
            // Signed-out anonymous WIZ_global_data (SNlM0e absent, S06Grb == "")
            let anonWIZ = JSONValue.object([
                "S06Grb": .string(""),
                "QrtxK": .string(""),
                "cfb2h": .string(GeminiBridgeSelectors.verifiedBuildLabel),
                "Lz8rbb": .bool(false)
            ])
            let anonBoot = GeminiPayloadParser.parseBootAuthSnapshot(wizJSON: anonWIZ)
            try expectEqual(anonBoot.xsrfTokenPresent, false)
            try expectEqual(anonBoot.gaiaUserId, nil)
            try expectEqual(
                GeminiPayloadParser.resolveAuthState(boot: anonBoot, peopleProfile: nil),
                .signedOut
            )

            // Explicit anonymous session flag forces signedOut even if other fields exist
            let flaggedAnonWIZ = JSONValue.object([
                "SNlM0e": .string("stale-token"),
                "S06Grb": .string("123456"),
                "Lz8rbb": .bool(true)
            ])
            let flaggedBoot = GeminiPayloadParser.parseBootAuthSnapshot(wizJSON: flaggedAnonWIZ)
            try expectEqual(
                GeminiPayloadParser.resolveAuthState(boot: flaggedBoot, peopleProfile: nil),
                .signedOut
            )

            // Signed-in WIZ + PeopleProfile
            let signedInWIZ = JSONValue.object([
                "SNlM0e": .string("AB12345:1730000000"),
                "S06Grb": .string("109876543210"),
                "oPEP7c": .string("alice@example.com"),
                "QrtxK": .string("1"),
                "Lz8rbb": .bool(false)
            ])
            let signedInBoot = GeminiPayloadParser.parseBootAuthSnapshot(
                wizJSON: signedInWIZ,
                pageURL: URL(string: "https://gemini.google.com/u/1/app")
            )
            let profile = PeopleProfile(
                email: "alice@example.com",
                displayName: "Alice Example",
                shortName: "Alice",
                avatarURL: URL(string: "https://lh3.googleusercontent.com/a/avatar.png")
            )
            let auth = GeminiPayloadParser.resolveAuthState(boot: signedInBoot, peopleProfile: profile)
            guard case .signedIn(let active, let available) = auth else {
                throw TestFailure(message: "Expected .signedIn, got \(auth)")
            }
            try expectEqual(active.email, "alice@example.com")
            try expectEqual(active.displayName, "Alice Example")
            try expectEqual(active.authUserIndex, 1)
            try expectEqual(available.count, 1)
            try expectEqual(active.scopeId, AccountScope.computeScopeId(for: "109876543210"))

            // Strict §4 #2 rule: never fabricate AccountScope without verified Gaia ID or email
            let unverifiedBoot = BootAuthSnapshot(xsrfTokenPresent: true, gaiaUserId: nil, email: nil)
            try expectEqual(
                GeminiPayloadParser.resolveAuthState(boot: unverifiedBoot, peopleProfile: nil),
                .unknown
            )
        }

        runTest("v2.0 ProcessSession [2,7,1,4,4] Protobuf decoding & chunk-split streaming resilience") {
            let idsMsg = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "c_proto123"),
                ProtoEncoder.fieldString(2, "r_proto456")
            ])
            let contentMsg = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "Hello **Lite Gemini**!")
            ])
            let completionMsg = ProtoEncoder.fieldVarint(1, 0)
            let thoughtStep = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "Checking protobuf wire format."),
                ProtoEncoder.fieldString(6, "Analyzing")
            ])
            let thoughtsMsg = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "Summary thought"),
                ProtoEncoder.fieldBytes(2, thoughtStep)
            ])
            let citationItem = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "Swift 6 Concurrency"),
                ProtoEncoder.fieldString(2, "https://swift.org/documentation/")
            ])
            let attachmentsMsg = ProtoEncoder.message([
                ProtoEncoder.fieldBytes(13, citationItem)
            ])
            let candidateMsg = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "rc_choice1"),
                ProtoEncoder.fieldBytes(2, contentMsg),
                ProtoEncoder.fieldBytes(9, completionMsg),
                ProtoEncoder.fieldBytes(13, attachmentsMsg),
                ProtoEncoder.fieldBytes(38, thoughtsMsg)
            ])
            let titleMsg = ProtoEncoder.fieldString(1, "Protobuf Smoke Test")
            let streamResp = ProtoEncoder.message([
                ProtoEncoder.fieldBytes(2, idsMsg),
                ProtoEncoder.fieldBytes(5, candidateMsg),
                ProtoEncoder.fieldBytes(11, titleMsg),
                ProtoEncoder.fieldBool(15, true),
                ProtoEncoder.fieldString(40, "cf41b0e0dd7d53e5"),
                ProtoEncoder.fieldString(43, "4 Hydrogen"),
                ProtoEncoder.fieldVarint(47, 2)
            ])

            // Wrap along path [2, 7, 1, 4, 4]
            let level4Inner = ProtoEncoder.fieldBytes(4, streamResp)
            let level1TurnPayload = ProtoEncoder.message([
                ProtoEncoder.fieldVarint(1, 1),
                ProtoEncoder.fieldBytes(4, level4Inner)
            ])
            let level7TurnUpdate = ProtoEncoder.fieldBytes(1, level1TurnPayload)
            let level2SessionEvent = ProtoEncoder.fieldBytes(7, level7TurnUpdate)
            let rootProcessSession = ProtoEncoder.fieldBytes(2, level2SessionEvent)

            let b64 = rootProcessSession.base64EncodedString()
            let frameJSON = "[[1,[\"\(b64)\"]]]"
            let noopJSON = "[[2,[\"noop\"]]]"
            let wirePayload = "\(frameJSON.utf16.count)\n\(frameJSON)\n\(noopJSON.utf16.count)\n\(noopJSON)\n"

            // Full decode
            let directDeltas = GeminiPayloadParser.parseWebChannelDeltas(wirePayload)
            try expectEqual(directDeltas.count, 1)
            let delta = directDeltas[0]
            try expectEqual(delta.conversationId, "c_proto123")
            try expectEqual(delta.responseId, "r_proto456")
            try expectEqual(delta.choiceId, "rc_choice1")
            try expectEqual(delta.markdownSnapshot, "Hello **Lite Gemini**!")
            try expectEqual(delta.isFinal, true)
            try expectEqual(delta.isThinkingComplete, true)
            try expect(delta.thinkingText?.contains("Analyzing") == true, "Expected thinking header")
            try expectEqual(delta.citations.first?.url.absoluteString, "https://swift.org/documentation/")

            // Arbitrary chunk-split resilience (3-char and 7-char splits)
            for strideSize in [1, 3, 7, 17] {
                var streamBuffer = WebChannelStreamBuffer()
                var frames: [ParsedStreamFrame] = []
                let chars = Array(wirePayload)
                var idx = 0
                while idx < chars.count {
                    let end = min(chars.count, idx + strideSize)
                    let piece = String(chars[idx..<end])
                    frames.append(contentsOf: streamBuffer.appendDelta(piece))
                    idx = end
                }
                frames.append(contentsOf: streamBuffer.finish())
                try expectEqual(frames.count, 1, "stride \(strideSize)")
                try expectEqual(frames[0].delta, delta, "stride \(strideSize)")
                try expectEqual(frames[0].generatedTitle, "Protobuf Smoke Test")
                try expectEqual(frames[0].modeId, "cf41b0e0dd7d53e5")
                try expectEqual(frames[0].modelAttributionName, "4 Hydrogen")
                try expectEqual(frames[0].isTemporaryChat, true)
            }

            // Cumulative XHR snapshot ingestion resilience
            var xhrBuffer = WebChannelStreamBuffer()
            var xhrFrames: [ParsedStreamFrame] = []
            let cut = wirePayload.index(wirePayload.startIndex, offsetBy: wirePayload.count / 2)
            xhrFrames.append(contentsOf: xhrBuffer.ingestCumulativeSnapshot(String(wirePayload[..<cut])))
            xhrFrames.append(contentsOf: xhrBuffer.ingestCumulativeSnapshot(wirePayload))
            xhrFrames.append(contentsOf: xhrBuffer.finish())
            try expectEqual(xhrFrames.count, 1)
            try expectEqual(xhrFrames[0].delta, delta)
        }

        runTest("v2.0 SSE streamGenerate & Legacy Boq wrb.fr framing (MaZiqc, hNvQHb, otAQ7b, o30O0e)") {
            // SSE split across chunks + inline error
            let sseArray = """
            [null,["c_sse1","r_sse1"],null,null,[["rc_sse1",["Streaming SSE reply"],null,null,null,null,null,null,[0]]],null,null,null,null,null,["SSE Title"],null,null,null,true]
            """
            let sseRaw = "data: \(sseArray)\n\ndata: {\"error\":{\"status\":\"UNAUTHENTICATED\",\"code\":401}}\n\ndata: [DONE]\n"
            var sseBuf = SSEStreamBuffer()
            let splitPoint = sseRaw.index(sseRaw.startIndex, offsetBy: 25)
            var sseOutputs = sseBuf.append(String(sseRaw[..<splitPoint]))
            sseOutputs.append(contentsOf: sseBuf.append(String(sseRaw[splitPoint...])))
            sseOutputs.append(contentsOf: sseBuf.finish())
            try expectEqual(sseOutputs.count, 2)
            guard case .frame(let sseFrame) = sseOutputs[0] else {
                throw TestFailure(message: "Expected SSE frame first")
            }
            try expectEqual(sseFrame.delta.conversationId, "c_sse1")
            try expectEqual(sseFrame.delta.markdownSnapshot, "Streaming SSE reply")
            try expectEqual(sseFrame.delta.isFinal, true)
            try expectEqual(sseOutputs[1], .rpcError(.unauthenticated))

            // Legacy Boq StreamGenerate with XSSI prefix + length-prefixed wrb.fr + NOT_FOUND error
            let innerEscaped = sseArray
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let boqFrame1 = "[[\"wrb.fr\",\"RxAFq\",\"\(innerEscaped)\",null,null,null,\"1\"]]"
            let boqFrame2 = "[[\"wrb.fr\",\"RxAFq\",null,null,null,[5],\"2\"]]"
            let boqRaw = ")]}'\n\n\(boqFrame1.utf16.count)\n\(boqFrame1)\n\(boqFrame2.utf16.count)\n\(boqFrame2)\n"
            var boqBuf = LegacyBoqStreamBuffer()
            var boqOut = boqBuf.append(String(boqRaw.prefix(4)))
            boqOut.append(contentsOf: boqBuf.append(String(boqRaw.dropFirst(4))))
            boqOut.append(contentsOf: boqBuf.finish())
            try expectEqual(boqOut.count, 2)
            guard case .frame(let boqParsed) = boqOut[0] else {
                throw TestFailure(message: "Expected legacy Boq frame")
            }
            try expectEqual(boqParsed.delta.markdownSnapshot, "Streaming SSE reply")
            try expectEqual(boqOut[1], .rpcError(.conversationNotFound))

            // MaZiqc (ListConversations): keeps visible, omits hidden & temporary
            let maZiqcJSON = JSONValue.array([
                .null,
                .string("next_tok"),
                .array([
                    .array([.string("c_keep"), .string("Pinned Chat"), .bool(true), .bool(false), .null, .array([.int(1_730_000_000), .int(0)])]),
                    .array([.string("c_hidden"), .string("Hidden"), .bool(false), .bool(true)]),
                    .array(Array(repeating: JSONValue.null, count: 30) + [.bool(true)])
                ])
            ])
            let convs = GeminiPayloadParser.parseListConversations(maZiqcJSON)
            try expectEqual(convs.count, 1)
            try expectEqual(convs[0].id, "c_keep")
            try expectEqual(convs[0].title, "Pinned Chat")
            try expectEqual(convs[0].isPinned, true)

            // hNvQHb (ListConversationTurns): sorts newest-first into chronological ascending order
            func makeTurn(respId: String, prompt: String, reply: String, ts: Int) -> JSONValue {
                .array([
                    .array([.string("c_keep"), .string(respId)]),
                    .null,
                    .array([.array([.string(prompt)]), .null, .null, .null, .string("mode_pro")]),
                    .array([
                        .array([
                            .array([.string("rc_alt"), .array([.string("Alt reply")])]),
                            .array([.string("rc_sel"), .array([.string(reply)])])
                        ]),
                        .null, .null, .string("rc_sel"),
                        .null, .null, .null, .null, .null, .bool(true)
                    ]),
                    .array([.int(ts), .int(0)])
                ])
            }
            let hNvQHbJSON = JSONValue.array([
                .array([
                    makeTurn(respId: "r_2", prompt: "Second", reply: "Reply 2", ts: 2000),
                    makeTurn(respId: "r_1", prompt: "First", reply: "Reply 1", ts: 1000)
                ])
            ])
            let turns = GeminiPayloadParser.parseListConversationTurns(hNvQHbJSON)
            try expectEqual(turns.count, 2)
            try expectEqual(turns[0].id, "r_1")
            try expectEqual(turns[0].assistantMarkdown, "Reply 1")
            try expectEqual(turns[1].id, "r_2")
            try expectEqual(turns[1].metadata.choiceId, "rc_sel")

            // otAQ7b (GetUserStatus): available models + unauthenticated challenge
            var statusArray = Array(repeating: JSONValue.null, count: 16)
            statusArray[14] = .int(1000)
            statusArray[15] = .array([
                .array([.string("m_fast"), .string("Flash"), .string("Fast everyday help")]),
                .array([.string("m_pro"), .string("Pro"), .string("Deep reasoning & thinking")])
            ])
            guard let statusRes = GeminiPayloadParser.parseUserStatus(.array(statusArray)) else {
                throw TestFailure(message: "Failed to parse otAQ7b")
            }
            try expectEqual(statusRes.statusCode, 1000)
            try expectEqual(statusRes.challenge, nil)
            try expectEqual(statusRes.models.count, 2)
            try expectEqual(statusRes.models[0].isThinkingCapable, false)
            try expectEqual(statusRes.models[1].isThinkingCapable, true)

            var unauthArray = Array(repeating: JSONValue.null, count: 15)
            unauthArray[14] = .int(1016)
            let unauthRes = GeminiPayloadParser.parseUserStatus(.array(unauthArray))
            try expectEqual(unauthRes?.isUnauthenticated, true)
            try expectEqual(unauthRes?.challenge?.kind, .reauthRequired)

            // o30O0e (GetPeople)
            var personArr = Array(repeating: JSONValue.null, count: 10)
            personArr[2] = .array([.array([.string("Jane Doe"), .null, .null, .string("Jane")])])
            personArr[3] = .array([.array([.string("https://lh3.googleusercontent.com/jane.png")])])
            personArr[9] = .array([.array([.string("jane@example.com")])])
            let peopleJSON = JSONValue.array([.array([.null, .null, .array(personArr)])])
            let people = GeminiPayloadParser.parsePeopleProfile(peopleJSON)
            try expectEqual(people?.email, "jane@example.com")
            try expectEqual(people?.displayName, "Jane Doe")
            try expectEqual(people?.shortName, "Jane")
        }

        runTest("v2.1 Artifact _.Cu oneofs (14/15/16/18) & Deep Research Plan (attachments 19) [Proto + JSON]") {
            // Build all 4 _.Cu Artifact oneof variants in binary Protobuf
            let docArt = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "art-doc-14"),
                ProtoEncoder.fieldString(3, "Architecture Spec"),
                ProtoEncoder.fieldBytes(14, ProtoEncoder.message([
                    ProtoEncoder.fieldString(1, "# Spec\nNative Canvas doc."),
                    ProtoEncoder.fieldString(5, "markdown")
                ]))
            ])
            let codeArt = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "art-code-15"),
                ProtoEncoder.fieldString(3, "Interactive Dashboard"),
                ProtoEncoder.fieldBytes(15, ProtoEncoder.message([
                    ProtoEncoder.fieldString(1, "<!DOCTYPE html><html><body>Hi</body></html>"),
                    ProtoEncoder.fieldString(2, "html")
                ]))
            ])
            let researchArt = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "art-dr-16"),
                ProtoEncoder.fieldString(3, "Quantum Computing Survey"),
                ProtoEncoder.fieldBytes(16, ProtoEncoder.message([
                    ProtoEncoder.fieldBytes(1, ProtoEncoder.fieldString(1, "# Report\nFull findings.")),
                    ProtoEncoder.fieldBytes(2, ProtoEncoder.fieldString(1, "<div>Visual Report</div>"))
                ]))
            ])
            let editorArt = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "art-edit-18"),
                ProtoEncoder.fieldString(3, "Parser.swift"),
                ProtoEncoder.fieldBytes(18, ProtoEncoder.message([
                    ProtoEncoder.fieldString(1, "struct Parser {}"),
                    ProtoEncoder.fieldString(3, "swift")
                ]))
            ])

            // Deep Research plan confirmation inside Candidate.attachments (13) -> field 19
            let drPlan = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "Battery Research Plan"),
                ProtoEncoder.fieldBytes(2, ProtoEncoder.message([
                    ProtoEncoder.fieldString(1, "Survey solid-state electrolytes"),
                    ProtoEncoder.fieldString(3, "Compare sulfide vs oxide cells")
                ])),
                ProtoEncoder.fieldBytes(2, ProtoEncoder.message([
                    ProtoEncoder.fieldString(1, "Analyze cycle life benchmarks")
                ])),
                ProtoEncoder.fieldString(4, "Estimated ~3 minutes")
            ])
            let attachments = ProtoEncoder.fieldBytes(19, drPlan)

            let candidate = ProtoEncoder.message([
                ProtoEncoder.fieldString(1, "rc_v21"),
                ProtoEncoder.fieldBytes(2, ProtoEncoder.fieldString(1, "Here are your artifacts.")),
                ProtoEncoder.fieldBytes(13, attachments),
                ProtoEncoder.fieldBytes(31, docArt),
                ProtoEncoder.fieldBytes(31, codeArt),
                ProtoEncoder.fieldBytes(42, researchArt),
                ProtoEncoder.fieldBytes(42, editorArt)
            ])
            let streamMsg = ProtoEncoder.message([
                ProtoEncoder.fieldBytes(2, ProtoEncoder.message([
                    ProtoEncoder.fieldString(1, "c_v21"),
                    ProtoEncoder.fieldString(2, "r_v21")
                ])),
                ProtoEncoder.fieldBytes(5, candidate),
                ProtoEncoder.fieldBool(15, true)
            ])
            guard let protoMsg = ProtoWireMessage.decode(streamMsg),
                  let frame = GeminiPayloadParser.parseStreamGenerateResponse(proto: protoMsg) else {
                throw TestFailure(message: "Failed to decode v2.1 protobuf StreamGenerateResponse")
            }

            let artifacts = frame.delta.artifacts
            try expectEqual(artifacts.count, 5, "Expected 1 DR plan + 4 _.Cu artifacts")

            let planCard = try unwrap(artifacts.first(where: { $0.isDeepResearchPlanCard }), "missing DR plan")
            try expectEqual(planCard.kind, .deepResearch)
            try expectEqual(planCard.title, "Battery Research Plan")
            try expectEqual(planCard.plan?.steps.count, 2)
            try expectEqual(planCard.plan?.estimatedTimeText, "Estimated ~3 minutes")
            try expectEqual(planCard.plan?.isConfirmed, false)

            let docCard = try unwrap(artifacts.first(where: { $0.id == "art-doc-14" }), "missing doc 14")
            try expectEqual(docCard.kind, .canvas)
            try expectEqual(docCard.language, "markdown")
            try expectEqual(docCard.isCodeWorkspace, false)

            let htmlCard = try unwrap(artifacts.first(where: { $0.id == "art-code-15" }), "missing code 15")
            try expectEqual(htmlCard.supportsLiveWebPreview, true)
            try expectEqual(htmlCard.suggestedFileExtension, "html")

            let drCard = try unwrap(artifacts.first(where: { $0.id == "art-dr-16" }), "missing DR 16")
            try expectEqual(drCard.kind, .deepResearch)
            try expectEqual(drCard.content, "# Report\nFull findings.")
            try expectEqual(drCard.htmlPreviewContent, "<div>Visual Report</div>")
            try expectEqual(drCard.supportsLiveWebPreview, true)

            let swiftCard = try unwrap(artifacts.first(where: { $0.id == "art-edit-18" }), "missing editor 18")
            try expectEqual(swiftCard.language, "swift")
            try expectEqual(swiftCard.isCodeWorkspace, true)
            try expectEqual(swiftCard.suggestedFileExtension, "swift")

            // Verify matching JSPB JSON decoding for attachments[18] (DR plan) & artifact[15] (DR report)
            var jspbAttachments = Array(repeating: JSONValue.null, count: 19)
            jspbAttachments[18] = .array([
                .string("JSON Plan"),
                .array([.array([.string("Step A"), .null, .string("Detail A")])]),
                .null,
                .string("~2 mins")
            ])
            var jspbDrArt = Array(repeating: JSONValue.null, count: 18)
            jspbDrArt[0] = .string("art-json-16")
            jspbDrArt[2] = .string("JSON Report")
            jspbDrArt[15] = .array([.array([.string("# JSON Findings")]), .array([.string("<p>Visual</p>")])])
            var jspbCand = Array(repeating: JSONValue.null, count: 31)
            jspbCand[0] = .string("rc_json_v21")
            jspbCand[1] = .array([.string("JSON prose")])
            jspbCand[12] = .array(jspbAttachments)
            jspbCand[30] = .array([.array(jspbDrArt)])
            var jspbResp = Array(repeating: JSONValue.null, count: 15)
            jspbResp[1] = .array([.string("c_jv21"), .string("r_jv21")])
            jspbResp[4] = .array([.array(jspbCand)])
            jspbResp[14] = .bool(true)
            let jsonFrame = try unwrap(
                GeminiPayloadParser.parseStreamGenerateResponse(json: .array(jspbResp)),
                "JSON v2.1 parse failed"
            )
            try expectEqual(jsonFrame.delta.artifacts.count, 2)
            try expect(jsonFrame.delta.artifacts.contains(where: { $0.isDeepResearchPlanCard && $0.title == "JSON Plan" }), "Missing JSON DR plan")
            try expect(jsonFrame.delta.artifacts.contains(where: { $0.id == "art-json-16" && $0.htmlPreviewContent == "<p>Visual</p>" }), "Missing JSON DR artifact")
        }

        runTest("v2.2 GeminiGraphQLClient decoders, error 1218, export allowlist & persistedQueryId extraction") {
            // 1. branchConversation
            let branchResp = GeminiGraphQLClient.parseResponse(
                .object([
                    "data": .object([
                        "branchConversation": .object([
                            "clientConversation": .object(["conversationId": .string("c_branched_99")])
                        ])
                    ])
                ])
            )
            try expectEqual(GeminiGraphQLClient.decodeBranchConversationId(from: branchResp), "c_branched_99")
            try expectEqual(GeminiGraphQLClient.canonicalConversationId("abc123"), "c_abc123")
            try expectEqual(GeminiGraphQLClient.canonicalConversationId("c_abc123"), "c_abc123")

            // 2. createPublicShareLink + error 1218 (.targetNotPersisted)
            let shareOK = GeminiGraphQLClient.parseResponse(
                .object([
                    "data": .object([
                        "createSharedConversation": .object([
                            "externalUrlId": .string("share999"),
                            "shareToken": .string("tok_abc"),
                            "shortenedUrl": .string("https://g.co/gemini/share/share999")
                        ])
                    ])
                ])
            )
            let shareRes = try GeminiGraphQLClient.decodeShareLinkResult(from: shareOK)
            try expectEqual(shareRes.url.absoluteString, "https://g.co/gemini/share/share999")
            try expectEqual(shareRes.externalUrlId, "share999")
            try expectEqual(shareRes.shareToken, "tok_abc")

            let err1218 = GeminiGraphQLClient.parseResponse(
                .object([
                    "errors": .array([
                        .object([
                            "message": .string("Target not persisted yet"),
                            "extensions": .object([
                                "bardErrorInfo": .object([
                                    "code": .int(1218),
                                    "reason": .string("SHARE_ERROR_TARGET_NOT_PERSISTED")
                                ])
                            ])
                        ])
                    ])
                ])
            )
            var caught1218 = false
            do {
                _ = try GeminiGraphQLClient.decodeShareLinkResult(from: err1218)
            } catch let err as GeminiTransportActionError {
                caught1218 = (err == .targetNotPersisted)
            }
            try expect(caught1218, "Error 1218 must throw .targetNotPersisted")

            // 3. exportMessage host allowlist validation + Gmail draft synthesis
            let docsOK = GeminiGraphQLClient.parseResponse(
                .object([
                    "data": .object([
                        "exportMessage": .object([
                            "artifactUrl": .string("https://docs.google.com/document/d/123/edit")
                        ])
                    ])
                ])
            )
            let docsURL = try GeminiGraphQLClient.decodeExportArtifactURL(from: docsOK, service: .docs)
            try expectEqual(docsURL.host, "docs.google.com")

            let gmailDraftOK = GeminiGraphQLClient.parseResponse(
                .object([
                    "data": .object([
                        "exportMessage": .object([
                            "gmailArtifacts": .object(["messageId": .string("msg_42")])
                        ])
                    ])
                ])
            )
            let gmailURL = try GeminiGraphQLClient.decodeExportArtifactURL(from: gmailDraftOK, service: .gmail)
            try expectEqual(gmailURL.absoluteString, "https://mail.google.com/mail/u/0/#drafts/msg_42")

            for badURL in [
                "https://evil.example.com/steal",
                "https://docs.google.com.evil.com/spoof",
                "http://docs.google.com/insecure"
            ] {
                let badResp = GeminiGraphQLClient.parseResponse(
                    .object(["data": .object(["exportMessage": .object(["artifactUrl": .string(badURL)])])])
                )
                var rejected = false
                do {
                    _ = try GeminiGraphQLClient.decodeExportArtifactURL(from: badResp, service: .docs)
                } catch GeminiTransportActionError.invalidArtifactURL {
                    rejected = true
                }
                try expect(rejected, "Must reject untrusted export URL: \(badURL)")
            }

            // 4. searchChats semantic hits decoding & highlight tag stripping
            let searchResp = GeminiGraphQLClient.parseResponse(
                .object([
                    "data": .object([
                        "viewer": .object([
                            "rpcs": .object([
                                "searchHistory": .object([
                                    "historySnippets": .array([
                                        .object([
                                            "conversationId": .string("c_hit1"),
                                            "title": .string("<b>Swift</b> Concurrency"),
                                            "snippet": .string("Use <mark>MainActor</mark> isolation."),
                                            "lastUpdatedTimestamp": .int(1_730_000_000)
                                        ]),
                                        .object([
                                            "conversationId": .string("c_hit1"),
                                            "title": .string("Duplicate should be ignored")
                                        ]),
                                        .object([
                                            "conversationId": .string("c_hit2"),
                                            "title": .string("Second Hit")
                                        ])
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            )
            let hits = GeminiGraphQLClient.decodeSearchHits(from: searchResp, limit: 10)
            try expectEqual(hits.count, 2)
            try expectEqual(hits[0].title, "Swift Concurrency")
            try expectEqual(hits[0].snippet, "Use MainActor isolation.")
            try expectEqual(hits[0].source, .cloudSemantic)

            // 5. responseTts base64url MP3 decoding (with '-' and '_', missing '=' padding)
            let rawAudio = Data([0x49, 0x44, 0x33, 0x03, 0xFB, 0xFF, 0xFE, 0x00, 0x11, 0x22])
            let base64url = rawAudio.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let ttsResp = GeminiGraphQLClient.parseResponse(
                .object([
                    "data": .object([
                        "viewer": .object([
                            "rpcs": .object([
                                "getTts": .object(["encodedAudio": .string(base64url)])
                            ])
                        ])
                    ])
                ])
            )
            try expectEqual(GeminiGraphQLClient.decodeAudioData(from: ttsResp), rawAudio)
            try expectEqual(GeminiGraphQLClient.decodeBase64URL("A"), nil)

            // 6. extractPersistedQueryId across double quotes, single quotes, and Rolldown backticks
            let expectedId = "2/JElMc8MRhiCK7G6DRucRllH8DyUUtlgZACqza4oLISU="
            let doubleQuoted = #"params:{id:"2/JElMc8MRhiCK7G6DRucRllH8DyUUtlgZACqza4oLISU=",metadata:{},name:"ChatResponseActionBarBranchMutation"}"#
            let singleQuoted = "params:{id:'2/JElMc8MRhiCK7G6DRucRllH8DyUUtlgZACqza4oLISU=',metadata:{},name:'ChatResponseActionBarBranchMutation'}"
            let backticked = "params:{id:`2/JElMc8MRhiCK7G6DRucRllH8DyUUtlgZACqza4oLISU=`,metadata:{},name:`ChatResponseActionBarBranchMutation`}"
            for src in [doubleQuoted, singleQuoted, backticked] {
                try expectEqual(
                    GeminiGraphQLClient.extractPersistedQueryId(
                        fromModuleSource: src,
                        operationName: "ChatResponseActionBarBranchMutation"
                    ),
                    expectedId
                )
            }
        }

        runTest("v2.2 BtwPromptBuilder 10-turn / 16,000-char packing, /btw parser & QuotedPassage") {
            // Slash command parser
            let cmd1 = BtwPromptBuilder.parseSlashCommand("  /btw   what does this mean?  ")
            try expectEqual(cmd1.matched, true)
            try expectEqual(cmd1.question, "what does this mean?")
            let cmd2 = BtwPromptBuilder.parseSlashCommand("/BTW")
            try expectEqual(cmd2.matched, true)
            try expectEqual(cmd2.question, "")
            try expectEqual(BtwPromptBuilder.parseSlashCommand("/btwx nope").matched, false)
            try expectEqual(BtwPromptBuilder.parseSlashCommand("hello /btw").matched, false)

            // 15 turns with heavy prose -> focused turn #2 preserved + newest turns packed <= 16,000 chars
            let bigChunk = String(repeating: "A", count: 2_300)
            let turns: [ChatTurn] = (1...15).map { idx in
                ChatTurn(
                    id: "turn-\(idx)",
                    userPrompt: "Question \(idx)",
                    assistantParts: [.markdown("Answer \(idx) \(bigChunk)")]
                )
            }
            let packed = BtwPromptBuilder.packMainChatBackground(turns: turns, focusedTurnId: "turn-2")
            try expect(packed.count <= BtwPromptBuilder.maxBackgroundChars, "Packed background exceeded 16,000 chars: \(packed.count)")
            try expect(packed.contains("[Turn 2 | turn-2]"), "Focused earlier turn-2 must be preserved")
            try expect(packed.contains("[Turn 15 | turn-15]"), "Newest turn-15 must be included")
            try expect(!packed.contains("[Turn 1 | turn-1]"), "Unfocused turn older than last 10 must be excluded")

            // Quote capping at 2,000 chars + first-turn vs follow-up prompt assembly
            let hugeQuote = BtwQuoteItem(quotedText: String(repeating: "Q", count: 2_500), turnId: "turn-2")
            try expectEqual(hugeQuote.quotedText.count, BtwPromptBuilder.maxQuoteChars)

            let firstPayload = BtwPromptBuilder.buildPromptPayload(
                userQuestion: "Explain briefly",
                quotes: [hugeQuote],
                isFirstTurn: true,
                mainChatBackground: packed
            )
            try expect(firstPayload.contains("Main conversation background (read-only):"), "Missing background header")
            try expect(firstPayload.contains("Highlighted passage (from turn turn-2):"), "Missing quote header")
            try expect(firstPayload.contains("under ~150 words"), "Missing concise directive")

            let followUpPayload = BtwPromptBuilder.buildPromptPayload(
                userQuestion: "Any caveat?",
                quotes: [],
                isFirstTurn: false,
                mainChatBackground: packed
            )
            try expectEqual(followUpPayload, "Any caveat?")

            try expectEqual(
                BtwPromptBuilder.formatNotesForMainChat("- Key insight"),
                "Notes from Btw:\n- Key insight"
            )

            // QuotedPassage markdown blockquote formatter
            let qp = QuotedPassage(quotedText: "Line 1\nLine 2")
            try expectEqual(
                QuotedPassage.formatPrompt("Explain", with: [qp]),
                "> Line 1\n> Line 2\n\nExplain"
            )
        }

        runTest("v2.2 TurnSpeechController <= 3,000 UTF-8 byte CJK/English chunker & Markdown stripper") {
            // Markdown code/math/table/URL sanitizer
            let rawMarkdown = """
            ## Heading Title

            Read [Swift Docs](https://swift.org/docs) and see ![Chart](https://example.com/chart.png).
            Visit https://example.com/raw-link.

            ```swift
            let hiddenCode = 42
            print(hiddenCode)
            ```

            $$
            \\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}
            $$

            | Col A | Col B |
            | --- | :---: |
            | Val 1 | Val 2 |

            This is **bold** and `inline_code` with snake_case_name.
            """
            let sanitized = TurnSpeechController.sanitizeMarkdownForSpeech(rawMarkdown)
            try expect(!sanitized.contains("hiddenCode"), "Fenced code block must be stripped")
            try expect(!sanitized.contains("\\int_0"), "Display math must be stripped")
            try expect(!sanitized.contains("https://"), "URLs must be stripped")
            try expect(!sanitized.contains("---"), "Table separator must be stripped")
            try expect(!sanitized.contains("##"), "Heading hashes must be stripped")
            try expect(!sanitized.contains("**"), "Bold markers must be stripped")
            try expect(sanitized.contains("Swift Docs"), "Link label must be preserved")
            try expect(sanitized.contains("Chart"), "Image alt text must be preserved")
            try expect(sanitized.contains("Val 1, Val 2"), "Table cells should become spoken phrases")

            // CJK + English <= 3,000 UTF-8 byte chunking invariant (each Chinese char is 3 UTF-8 bytes)
            let cjkSentence = "这是一个用于测试语音合成字节限制的中文句子，确保每个分段绝对不会超过三千字节上限。"
            let longCJK = Array(repeating: cjkSentence, count: 60).joined()
            try expect(longCJK.utf8.count > 6_000, "Test CJK string must exceed 6,000 UTF-8 bytes")
            let cjkChunks = TurnSpeechController.chunkTextForTTS(longCJK)
            try expect(cjkChunks.count >= 3, "Expected >= 3 chunks for > 6,000 byte CJK text")
            for (i, chunk) in cjkChunks.enumerated() {
                try expect(
                    chunk.utf8.count <= TurnSpeechController.defaultMaxChunkUTF8Bytes,
                    "CJK chunk \(i) exceeded 3,000 UTF-8 bytes: \(chunk.utf8.count)"
                )
            }

            // Mixed English + emoji (4-byte UTF-8) with tight custom byte budget (120 bytes)
            let englishLong = Array(
                repeating: "Lite Gemini streams crisp native typography smoothly 🚀. ",
                count: 25
            ).joined()
            let smallChunks = TurnSpeechController.chunkTextForTTS(englishLong, maxUTF8Bytes: 120)
            try expect(smallChunks.count > 5, "Expected multiple small chunks")
            for (i, chunk) in smallChunks.enumerated() {
                try expect(
                    chunk.utf8.count <= 120,
                    "Small chunk \(i) exceeded 120 UTF-8 bytes: \(chunk.utf8.count)"
                )
            }

            // Locale detection
            try expectEqual(TurnSpeechController.detectSpeechLocale(text: longCJK, hint: nil), "zh-CN")
            try expectEqual(TurnSpeechController.detectSpeechLocale(text: "こんにちは世界、音声テストです。", hint: nil), "ja-JP")
            try expectEqual(TurnSpeechController.detectSpeechLocale(text: "안녕하세요 음성 합성 테스트입니다.", hint: nil), "ko-KR")
            try expectEqual(TurnSpeechController.detectSpeechLocale(text: "Hello native macOS world.", hint: nil), "en-US")
            try expectEqual(TurnSpeechController.detectSpeechLocale(text: "Hello", hint: "zh_Hans"), "zh-CN")
        }

        print("Offline Contract Tests Summary: \(passedTests) passed, \(failedTests) failed.")
        if failedTests > 0 {
            exit(1)
        }
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw TestFailure(message: message)
        }
        return value
    }
}
