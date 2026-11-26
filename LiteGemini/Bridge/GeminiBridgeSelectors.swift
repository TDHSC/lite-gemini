import Foundation

/// Centralized, versioned protocol constants, `WIZ_global_data` keys, `batchexecute` RPC IDs,
/// protobuf/JSPB field indices, and primary + fallback CSS selectors verified against live
/// `https://gemini.google.com/app` (`boq_gemini-web-uiserver_20261125.05_p0`).
///
/// All Bridge scripts, parsers, and action drivers must reference these constants rather than
/// scattering magic strings across views or controllers.
nonisolated enum GeminiBridgeSelectors: Sendable {

    // MARK: - Schema Metadata

    /// Monotonic selector contract version bumped whenever Google shifts endpoints or DOM structure
    static let schemaVersion = "2026-11-25.1"

    /// Live `WIZ_global_data["cfb2h"]` build label verified during the T02 protocol spike
    static let verifiedBuildLabel = "boq_gemini-web-uiserver_20261125.05_p0"

    /// A primary CSS selector paired with ordered resilient fallbacks for DOM lookups
    struct SelectorGroup: Sendable, Equatable {
        /// Preferred selector matching current Luminous (`lr26`) Gemini DOM
        let primary: String
        /// Ordered fallback selectors covering legacy or variant Gemini DOM trees
        let fallbacks: [String]

        /// All selectors in priority order (`primary` followed by `fallbacks`)
        var all: [String] {
            [primary] + fallbacks
        }

        /// Comma-separated CSS selector list suitable for `document.querySelector`
        var combinedCSS: String {
            all.joined(separator: ", ")
        }
    }

    // MARK: - Endpoints & URLs

    /// Verified Gemini hosts, streaming/RPC paths, and authentication entry URLs
    nonisolated enum Endpoints: Sendable {
        /// Canonical Gemini web host
        static let geminiHost = "gemini.google.com"
        /// Primary clients6 API host for WebChannel `processSession` and SSE `streamGenerate`
        static let apiHost = "geminiweb-pa.clients6.google.com"
        /// File upload host (`WIZ_global_data["h1eoVe"]`)
        static let uploadHost = "push.clients6.google.com"
        /// Google Accounts authentication host
        static let accountsHost = "accounts.google.com"

        /// Canonical Gemini chat app URL
        static let appURLString = "https://gemini.google.com/app"
        /// Sign-in popup URL routed through `NewWindowRouter` / `PopupWindowController`
        static let signInURLString = "https://accounts.google.com/ServiceLogin?passive=1209600&osid=1&continue=https%3A%2F%2Fgemini.google.com%2Fapp"
        /// Add-another-account popup URL
        static let addAccountURLString = "https://accounts.google.com/AddSession?continue=https%3A%2F%2Fgemini.google.com%2Fapp"

        /// Primary streaming endpoint (2026 default for non-temporary chats): WebChannel over XHR
        static let processSessionPath = "/v1/processSession"
        /// Alternate WebChannel RPC path for `ProcessSession`
        static let processSessionRPCPath = "/$rpc/assistant.lamda.bard.GeminiWebService/ProcessSession"
        /// Secondary streaming endpoint (`fetch` SSE carrying JSPB JSON arrays of `StreamGenerateResponse`)
        static let streamGenerateSSEPath = "/v1/conversations:streamGenerate"
        /// Legacy Boq streaming endpoint (`)]}'\n` + length-prefixed `wrb.fr`, also used by Temporary Chat fallback)
        static let legacyStreamGeneratePath = "/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate"
        /// Boq `batchexecute` RPC endpoint
        static let batchExecutePath = "/_/BardChatUi/data/batchexecute"
        /// File upload endpoint path on `push.clients6.google.com`
        static let uploadPath = "/upload/"

        /// Query parameter key carrying the active Google account index (`0`, `1`, ...)
        static let authUserQueryParam = "authuser"
        /// Path prefix for Google multi-login URLs (`/u/<N>/app`)
        static let multiLoginPathPrefix = "/u/"
        /// Path substrings indicating an auth challenge, CAPTCHA, or unavailable interstitial
        static let challengePathIndicators: [String] = [
            "/sorry/",
            "/ServiceLogin",
            "/v3/signin",
            "/signin/",
            "/AccountChooser",
            "/unavailable"
        ]
    }

    // MARK: - WIZ Global Data Keys

    /// Keys present in `window.WIZ_global_data` inspected at boot and on SPA navigation
    nonisolated enum WizGlobalDataKeys: Sendable {
        /// XSRF `at` token; present non-empty string when signed in, absent when signed out
        static let xsrfToken = "SNlM0e"
        /// Numeric Gaia user ID; non-empty string when signed in, empty string `""` when signed out
        static let gaiaUserId = "S06Grb"
        /// Signed-in user email address (when exposed in boot globals; backed up by `o30O0e` / DOM)
        static let userEmail = "oPEP7c"
        /// Active multi-account `authuser` index (`"0"`, `"1"`, ... when signed in; `""` when signed out)
        static let authUserIndex = "QrtxK"
        /// Frontend build label sent as `bl` query param (e.g. `boq_gemini-web-uiserver_20261125.05_p0`)
        static let buildLabel = "cfb2h"
        /// Session ID sent as `f.sid` query param
        static let sessionId = "FdrFJe"
        /// Boq RPC prefix (`"/_/BardChatUi"`)
        static let rpcPrefix = "Im6cmf"
        /// Streaming API host (`"https://geminiweb-pa.clients6.google.com"`)
        static let apiHost = "GK6dn"
        /// Client API key header (`X-Goog-Api-Key`) for `geminiweb-pa.clients6.google.com`
        static let apiKey = "d2zJAe"
        /// File upload endpoint (`"https://push.clients6.google.com/upload/"`)
        static let uploadURL = "h1eoVe"
        /// Push upload tenant ID header (`Push-ID`)
        static let uploadPushId = "qKIAYe"
        /// Client context header (`X-Client-Pctx`) for uploads
        static let uploadClientContext = "Ylro7b"
        /// Page locale (e.g. `"en-US"`)
        static let locale = "TuX5cc"
        /// Signed-out / anonymous state boolean flag inspected by Gemini's internal auth helpers
        static let isAnonymousSession = "Lz8rbb"
        /// Server token sent as `X-Server-Token` on streaming requests
        static let serverToken = "PI9WOb"
        /// Secondary signed-out indicator string keys checked alongside `Lz8rbb`
        static let signedOutAuxiliaryKeys: [String] = ["M9l3o", "dSupif"]
    }

    // MARK: - BatchExecute RPC IDs

    /// Verified `rpcids` values on `POST /_/BardChatUi/data/batchexecute`
    nonisolated enum BatchExecuteRPC: Sendable {
        /// `BardFrontendService.ListConversations` — recent conversation summaries
        static let listConversations = "MaZiqc"
        /// `BardFrontendService.ListConversationTurns` — full turn history for `/app/<id>`
        static let listConversationTurns = "hNvQHb"
        /// `BardFrontendService.GetConversationTurn` — single turn fetch
        static let getConversationTurn = "EqPOKe"
        /// `BardFrontendService.GetUserStatus` — account eligibility status & available model list
        static let getUserStatus = "otAQ7b"
        /// `InternalPeopleService.GetPeople` — signed-in display name, avatar URL, and email
        static let getPeople = "o30O0e"
        /// `BardFrontendService.ReadUserProfile` — user profile metadata
        static let readUserProfile = "WTCNf"
        /// `BardFrontendService.ReadUserPreferences` — user settings/preferences
        static let readUserPreferences = "ESY5D"
        /// `BardFrontendService.ListBots` — user & system Gems list
        static let listBots = "CNgdBe"
        /// `BardFrontendService.StreamGenerate` — legacy streaming generation RPC identifier
        static let streamGenerate = "RxAFq"
        /// `BardFrontendService.MarkLastConversationTurn` — marks active head turn
        static let markLastConversationTurn = "kOWVAe"
        /// `BardFrontendService.ProcessFile` — processes uploaded file references
        static let processFile = "LbusCb"
        /// `BardFrontendService.UpdateConversation` — renames or updates conversation metadata
        static let updateConversation = "MUAZcd"
        /// `BardFrontendService.DeleteConversation` — deletes a conversation
        static let deleteConversation = "GzXR5e"
    }

    // MARK: - Wire Format & Proto / JSPB Field Indices

    /// Verified wire framing constants, protobuf field numbers (1-based), and corresponding
    /// JSPB JSON array indices (0-based = `protoFieldNumber - 1`).
    nonisolated enum WireFormat: Sendable {
        /// Google XSSI guard prefix stripped before parsing `batchexecute` and legacy `StreamGenerate`
        static let xssiPrefix = ")]}'\n"
        /// Envelope frame discriminator for Boq RPC payloads (`["wrb.fr", rpcId, innerJSON, ...]`)
        static let wrbFrameMarker = "wrb.fr"
        /// SSE data line prefix for `/v1/conversations:streamGenerate?alt=sse`
        static let sseDataPrefix = "data:"

        /// Canonical identifier prefixes returned by Gemini backend
        static let conversationIdPrefix = "c_"
        static let responseIdPrefix = "r_"
        static let choiceIdPrefix = "rc_"

        /// Protobuf field path inside a decoded WebChannel `ProcessSessionResponse` base64 frame
        /// leading to the embedded `StreamGenerateResponse` (`_.uv`) message:
        /// `2 (SessionEvent) -> 7 (TurnUpdate) -> 1 (TurnPayload) -> 4 -> 4 (StreamGenerateResponse)`
        static let processSessionStreamResponsePath: [Int] = [2, 7, 1, 4, 4]

        /// 1-based protobuf field numbers for `StreamGenerateResponse` (`_.uv`).
        /// For JSPB JSON arrays (SSE & legacy `StreamGenerate`), subtract 1 to get the array index.
        nonisolated enum StreamResponseField: Int, Sendable {
            /// `ConversationIds` (`field 1` = `conversationId`, `field 2` = `responseId`) — JSPB `[1]`
            case conversationIds = 2
            /// Repeated `Candidate` (`_.NEb`) list — JSPB `[4]`
            case candidates = 5
            /// Live progress / thinking status (`_.jI`; `field 6 -> field 1` = live thinking header) — JSPB `[6]`
            case progressStatus = 7
            /// Echoed user attachments (`zKe`) — JSPB `[9]`
            case userAttachments = 10
            /// Generated conversation title (`AKe`, `field 1` = title) — JSPB `[10]`
            case titleGeneration = 11
            /// Boolean indicating final chunk of stream — JSPB `[14]`
            case isFinal = 15
            /// Repeated `StructuredContent` (`_.WH`, parallel by index to `candidates`) — JSPB `[26]`
            case structuredContent = 27
            /// Active model `modeId` (e.g. `"cf41b0e0dd7d53e5"`) — JSPB `[39]`
            case modeId = 40
            /// Human-readable model attribution name (e.g. `"4 Hydrogen"`) — JSPB `[42]`
            case modelAttributionName = 43
            /// Follow-up regenerate options (`1001` Try again, `1004` Longer, `1005` Shorter) — JSPB `[44]`
            case regenerateOptions = 45
            /// Temporary chat state enum (`1` = off, `2` = on) — JSPB `[46]`
            case temporaryChatState = 47
        }

        /// 1-based protobuf field numbers for `Candidate` (`_.NEb`).
        /// For JSPB JSON arrays, subtract 1 to get the array index.
        nonisolated enum CandidateField: Int, Sendable {
            /// Candidate choice ID (`"rc_..."`) — JSPB `[0]`
            case choiceId = 1
            /// Primary markdown content (`_.VYd`; `field 1` = markdown text string) — JSPB `[1]`
            case content = 2
            /// Inline text citation spans (`bZd`; `field 1` repeated spans with start, end, URL) — JSPB `[2]`
            case inlineCitations = 3
            /// Candidate completion state (`n0d`; `field 1`: `0`/`2` complete, `1` partial) — JSPB `[8]`
            case completionState = 9
            /// Response language code (e.g. `"en"`) — JSPB `[9]`
            case language = 10
            /// Rich attachments & grounding sources (`_.EB`: `13`/`41`/`45` sources, `77` dynamic view HTML) — JSPB `[12]`
            case attachments = 13
            /// Alternate plain-text summary (`_.XYd`; `field 1` = text) — JSPB `[22]`
            case alternateText = 23
            /// Global grounding / inline sources (`dZd`) — JSPB `[28]`
            case globalSources = 29
            /// Primary Canvas / Deep Research / Immersive artifacts (repeated `_.Cu`) — JSPB `[30]`
            case artifacts = 31
            /// Thinking / reasoning trace (`_.TZd`: `field 1` summary, `field 2` repeated `_.UZd` steps) — JSPB `[37]`
            case thoughts = 38
            /// Secondary / Canvas artifacts (repeated `_.Cu`) — JSPB `[41]`
            case secondaryArtifacts = 42
        }

        /// 1-based protobuf field numbers for `StructuredContent` (`_.WH`) child nodes
        nonisolated enum StructuredNodeField: Int, Sendable {
            /// Markdown text segment
            case markdownText = 2
            /// Generated image container (`XEd` -> `field 1` repeated `_.TH`)
            case generatedImages = 10
            /// Web / inline image container (`_.pUd` -> `field 1` repeated `_.JVd`)
            case webImages = 21
        }

        /// 0-based JSPB array indices for `ListConversations` (`MaZiqc`) response
        nonisolated enum ListConversationsIndex: Int, Sendable {
            /// Pagination token string (proto field 2)
            case nextPageToken = 1
            /// Array of `Conversation` (`_.jv`) entries (proto field 3)
            case conversations = 2
        }

        /// 0-based JSPB array indices for each `Conversation` (`_.jv`) item in `MaZiqc`
        nonisolated enum ConversationItemIndex: Int, Sendable {
            /// Canonical `conversationId` (`"c_..."`, proto field 1)
            case id = 0
            /// Display title (proto field 2)
            case title = 1
            /// Pinned boolean (proto field 3)
            case isPinned = 2
            /// Hidden boolean (proto field 4)
            case isHidden = 3
            /// `[seconds, nanos]` timestamp (proto field 6)
            case updatedTimestamp = 5
            /// Associated Gem or Project ID (proto field 8)
            case botOrProjectId = 7
            /// Ephemeral / temporary marker (proto field 31)
            case isTemporary = 30
        }

        /// 0-based JSPB array indices for `ListConversationTurns` (`hNvQHb`) response
        nonisolated enum ListTurnsIndex: Int, Sendable {
            /// Array of `ConversationTurn` (`_.ZK`) entries (proto field 1)
            case turns = 0
            /// Pagination token string (proto field 2)
            case nextPageToken = 1
            /// Status container (`[0] == 2` means read-only / shared; proto field 5)
            case status = 4
        }

        /// 0-based JSPB array indices for each `ConversationTurn` (`_.ZK`) item in `hNvQHb`
        nonisolated enum TurnItemIndex: Int, Sendable {
            /// `[conversationId, responseId]` pair (proto field 1)
            case ids = 0
            /// Parent turn identifiers (proto field 2)
            case parentIds = 1
            /// User prompt container (`_.b4d`: `[0][0]` text, `[4]` modeId, `[0][4]` files; proto field 3)
            case userRequest = 2
            /// Model response container (`_.f0d`: `[0]` candidates, `[3]` selectedChoiceId, `[9]` isFinal, `[12]` structuredContent; proto field 4)
            case modelResponse = 3
            /// `[seconds, nanos]` turn timestamp (proto field 5)
            case timestamp = 4
        }

        /// 0-based JSPB array indices for `GetUserStatus` (`otAQ7b`) response
        nonisolated enum GetUserStatusIndex: Int, Sendable {
            /// Account eligibility status code (`1000` available, `1016` unauthenticated, `1033` untrusted, `1040` ToS; proto field 15)
            case statusCode = 14
            /// Array of available `ModelMode` (`_.Jqd`) entries (proto field 16)
            case availableModels = 15
        }

        /// Verified gRPC & Gemini application status codes used for challenge/error detection
        nonisolated enum StatusCode: Int, Sendable {
            /// gRPC `NOT_FOUND` (conversation or Gem deleted; evict from local cache)
            case grpcNotFound = 5
            /// gRPC `PERMISSION_DENIED` (signed-out or unauthorized account)
            case grpcPermissionDenied = 7
            /// gRPC `UNAUTHENTICATED` (mid-session expiry; triggers sign-in/challenge banner)
            case grpcUnauthenticated = 16
            /// `GetUserStatus` available & eligible
            case accountAvailable = 1000
            /// `GetUserStatus` unauthenticated (signed out)
            case accountUnauthenticated = 1016
            /// Rate limit / overloaded response
            case rateLimited = 1030
            /// Storage quota exceeded for file upload
            case storageQuotaExceeded = 1031
            /// Account untrusted / requires verification challenge
            case accountUntrusted = 1033
            /// File / document chat limit reached
            case fileChatLimitReached = 1036
            /// Terms of Service acceptance pending
            case tosPending = 1040
            /// Account rejected by guardian supervision
            case accountRejectedByGuardian = 1054
            /// Guardian approval required
            case guardianApprovalRequired = 1057
            /// Unsupported geographic region
            case locationRejected = 1060
            /// Dynamic view / interactive limit reached
            case dynamicViewLimitReached = 1068
        }
    }

    // MARK: - Auth & Account DOM Selectors

    /// Selectors for signed-in / signed-out detection and account identity fallback
    nonisolated enum AuthDOM: Sendable {
        /// Sign-in links/buttons present when signed out (Luminous + OneGoogle bar)
        static let signedOutTrigger = SelectorGroup(
            primary: #"a[href*="accounts.google.com/ServiceLogin"]"#,
            fallbacks: [
                #"button[jslog^="327170;"]"#,
                #"button[jslog^="325776;"]"#,
                #"[data-test-id="sign-out-banner"]"#,
                #"mat-card.signed-out"#
            ]
        )

        /// Signed-in account menu trigger in sidenav footer / OneGoogle bar
        static let signedInAccountTrigger = SelectorGroup(
            primary: #"sidenav-mavatar-footer a[gem-open-account-menu]"#,
            fallbacks: [
                #"a[href*="accounts.google.com/SignOutOptions"]"#,
                #"a[aria-label*="Google Account"]"#
            ]
        )

        /// Signed-in account avatar `<img>` element
        static let accountAvatarImage = SelectorGroup(
            primary: #"sidenav-mavatar-footer img.mavatar-image"#,
            fallbacks: [
                #"user-profile-picture img.user-icon"#,
                #"a[href*="SignOutOptions"] img"#
            ]
        )
    }

    // MARK: - Composer & Write-Path DOM Selectors

    /// Selectors for driving Gemini's hidden composer, send/stop, attachments, models, and temp chat
    nonisolated enum ComposerDOM: Sendable {
        /// Root composer host element
        static let inputArea = SelectorGroup(
            primary: "input-area-v2",
            fallbacks: ["input-container"]
        )

        /// Editable Quill / contenteditable prompt surface (explicitly excluding `.ql-clipboard`)
        static let editor = SelectorGroup(
            primary: #"rich-textarea .ql-editor[contenteditable="true"]"#,
            fallbacks: [
                #"rich-textarea [contenteditable="true"]:not(.ql-clipboard)"#,
                #"[role="textbox"][contenteditable="true"]"#,
                "input-area-v2 textarea"
            ]
        )

        /// Submit / Send button (Luminous uses VE ID `173899` + `arrow_upward`; legacy uses `.send-button` + `send`)
        static let sendButton = SelectorGroup(
            primary: #"input-area-v2 button[jslog^="173899;"]"#,
            fallbacks: [
                #"input-area-v2 button:has(mat-icon[fonticon="arrow_upward"])"#,
                #"input-area-v2 button:has(mat-icon[data-mat-icon-name="arrow_upward"])"#,
                "button.send-button",
                #"input-area-v2 button:has(mat-icon[fonticon="send"])"#,
                #"input-area-v2 button[aria-label*="Send" i]"#
            ]
        )

        /// Stop generating button (Luminous uses VE ID `188689` + `stop`; legacy uses `.stop-button`)
        static let stopButton = SelectorGroup(
            primary: #"input-area-v2 button[jslog^="188689;"]"#,
            fallbacks: [
                #"input-area-v2 button:has(mat-icon[fonticon="stop"])"#,
                #"input-area-v2 button:has(mat-icon[data-mat-icon-name="stop"])"#,
                "button.stop-button",
                ".blue-circle.stop-icon",
                #"input-area-v2 button[aria-label*="Stop" i]"#
            ]
        )

        /// Upload & tools (`+`) trigger inside the composer
        static let uploadMenuTrigger = SelectorGroup(
            primary: #"input-area-v2 button[jslog^="300142;"]"#,
            fallbacks: [
                #"input-area-v2 button:has(mat-icon[fonticon="plus"])"#,
                "button.upload-card-button"
            ]
        )

        /// Hidden `<input type="file">` inside the opened upload menu (secondary fallback to `ClipboardEvent('paste')`)
        static let fileInput = SelectorGroup(
            primary: #"images-files-uploader input[type="file"].hidden-file-input"#,
            fallbacks: [
                #"uploader input[type="file"].hidden-file-input"#,
                #"input[type="file"][multiple]"#,
                #"input[type="file"]"#
            ]
        )

        /// Attachment preview chips rendered inside the composer once files are staged/uploaded
        static let attachmentPreview = SelectorGroup(
            primary: "uploader-file-preview-container uploader-file-preview",
            fallbacks: [
                "uploader-file-preview",
                ".file-preview-chip",
                ".attachment-preview-wrapper"
            ]
        )

        /// Active upload spinner inside an attachment preview while bytes are still uploading
        static let attachmentUploadingSpinner = SelectorGroup(
            primary: "uploader-file-preview mat-progress-spinner",
            fallbacks: [
                ".file-preview-chip mat-progress-spinner",
                ".attachment-preview-wrapper mat-progress-spinner"
            ]
        )

        /// Model / Mode switcher trigger button
        static let modelSwitcherButton = SelectorGroup(
            primary: #"[data-test-id="bard-mode-menu-button"]"#,
            fallbacks: [
                "bard-mode-switcher button.input-area-switch",
                "bard-mode-switcher button"
            ]
        )

        /// Opened model picker menu container
        static let modelMenuContainer = SelectorGroup(
            primary: #"gem-menu[data-test-id="gem-mode-menu"]"#,
            fallbacks: [
                #"[data-test-id="bard-mode-desktop-gem-menu"]"#,
                ".cdk-overlay-container [role=\"menu\"]"
            ]
        )

        /// Individual selectable model option rows inside the opened model menu
        static let modelMenuItem = SelectorGroup(
            primary: #"gem-menu[data-test-id="gem-mode-menu"] gem-menu-item[role="menuitemradio"]"#,
            fallbacks: [
                #"gem-menu-item[data-mode-id]"#,
                #"[data-test-id^="bard-mode-option-"]"#
            ]
        )

        /// Attribute storing the canonical `modeId` on `<gem-menu-item>`
        static let modelModeIdAttribute = "data-mode-id"
        /// Child class storing the model title inside `<gem-menu-item-content>`
        static let modelItemLabelClass = ".label"
        /// Child class storing the model subtitle inside `<gem-menu-item-content>`
        static let modelItemSublabelClass = ".sublabel"

        /// Temporary chat toggle host element (`<temp-chat-button>`)
        static let tempChatHost = SelectorGroup(
            primary: "temp-chat-button",
            fallbacks: [".temp-chat-button"]
        )

        /// Clickable toggle element inside `<temp-chat-button>`
        static let tempChatToggle = SelectorGroup(
            primary: "temp-chat-button gem-icon-button.temp-chat-button button",
            fallbacks: [
                "temp-chat-button .temp-chat-button",
                "temp-chat-button button",
                "temp-chat-button"
            ]
        )

        /// Legacy CSS class applied when temporary chat is enabled
        static let tempChatLegacyActiveClass = "temp-chat-on"
        /// Luminous `fonticon` name shown on `<temp-chat-button>` when temporary chat is active
        static let tempChatActiveIconName = "close"
        /// Luminous `fonticon` name shown on `<temp-chat-button>` when temporary chat is inactive
        static let tempChatInactiveIconName = "gemini_chat_temp"

        /// New-chat trigger selectors (used to detect page-initiated new chat)
        static let newChatTrigger = SelectorGroup(
            primary: #"[data-test-id="reset-button"]"#,
            fallbacks: [
                "new-chat-button",
                #"[data-test-id="side-nav-sparkle-button"]"#
            ]
        )
    }

    // MARK: - Conversation, Turn Actions & DOM Fallback Selectors

    /// Selectors for reading conversation turns as secondary resilience and driving Edit / Regenerate
    nonisolated enum ConversationDOM: Sendable {
        /// Scrollable chat history container (also targeted by T10's `GeminiRenderSuppressor`)
        static let historyScrollContainer = SelectorGroup(
            primary: #"infinite-scroller[data-test-id="chat-history-container"]"#,
            fallbacks: [
                "infinite-scroller.chat-history",
                "chat-window-content"
            ]
        )

        /// User query turn host element
        static let userQuery = SelectorGroup(
            primary: "user-query",
            fallbacks: ["user-query-content"]
        )

        /// Visible user prompt text paragraphs inside `user-query`
        static let userQueryText = SelectorGroup(
            primary: "user-query .query-text .query-text-line",
            fallbacks: ["user-query .query-text"]
        )

        /// Model response turn host element
        static let modelResponse = SelectorGroup(
            primary: "model-response",
            fallbacks: ["response-container"]
        )

        /// Rendered markdown body container inside `model-response`
        static let modelMessageContent = SelectorGroup(
            primary: "model-response message-content .markdown-main-panel",
            fallbacks: [
                "model-response message-content",
                "message-content"
            ]
        )

        /// Thinking / reasoning trace container inside `model-response`
        static let modelThoughts = SelectorGroup(
            primary: #"model-thoughts [data-test-id="thoughts-content"]"#,
            fallbacks: [
                "model-thoughts",
                #"thinking-card [data-test-id="thinking-card"]"#,
                #"thinking-overlay [data-test-id="thinking-overlay-content"]"#,
                "thought-view"
            ]
        )

        /// Edit trigger button on the latest `user-query` turn
        static let editLatestPromptButton = SelectorGroup(
            primary: #"user-query [data-test-id="prompt-edit-button"] button"#,
            fallbacks: [
                #"user-query [data-test-id="prompt-edit-button"]"#,
                #"user-query button[jslog^="173924;"]"#,
                #"user-query button:has(mat-icon[fonticon="edit"])"#
            ]
        )

        /// Editable field opened inside `user-query` after clicking Edit (Luminous rich editor or legacy textarea)
        static let editPromptField = SelectorGroup(
            primary: #"user-query rich-textarea.edit-rich-textarea .ql-editor[contenteditable="true"]"#,
            fallbacks: [
                #"user-query .query-content.edit-mode [contenteditable="true"]:not(.ql-clipboard)"#,
                "user-query .query-content.edit-mode textarea",
                "user-query textarea[cdktextareaautosize]"
            ]
        )

        /// Confirm / submit button inside `user-query` edit mode
        static let editPromptUpdateButton = SelectorGroup(
            primary: "user-query .edit-button-area .update-button button",
            fallbacks: [
                "user-query .edit-button-area .update-button",
                "user-query button.update-button"
            ]
        )

        /// Cancel button inside `user-query` edit mode
        static let editPromptCancelButton = SelectorGroup(
            primary: "user-query .edit-button-area .cancel-button button",
            fallbacks: [
                "user-query .edit-button-area .cancel-button",
                "user-query button.cancel-button"
            ]
        )

        /// Regenerate / Redo trigger button on the latest `model-response` turn
        static let regenerateButton = SelectorGroup(
            primary: "model-response regenerate-button button",
            fallbacks: [
                "model-response message-actions regenerate-button",
                #"model-response message-actions button:has(mat-icon[fonticon="refresh"])"#,
                #"model-response button[aria-label="Redo"]"#
            ]
        )

        /// Menu item inside the Regenerate menu when Gemini opens a dropdown instead of immediate redo
        static let regenerateMenuOption = SelectorGroup(
            primary: #".cdk-overlay-container [data-test-id="regenerate-option"]"#,
            fallbacks: [
                ".cdk-overlay-container .regenerate-menu button[mat-menu-item]",
                #".cdk-overlay-container button:has(mat-icon[fonticon="refresh"])"#
            ]
        )
    }
}
