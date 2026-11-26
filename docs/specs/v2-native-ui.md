# Spec: Lite Gemini v2 — Native Liquid Glass UI + Hidden WebView Session Bridge

- **Status:** active (`10 / 11` tickets complete — ready for T11 owner signed-in acceptance)
- **Target release:** `v2.0.0` (developed incrementally on `main` behind a feature flag)
- **Last updated:** 2026-11-25 (`T01`–`T10` complete & verified; Universal Release build ready at `/tmp/lg-build/Build/Products/Release/Lite Gemini.app`)

---

## How to Use This Spec (Session Handoff Protocol)

This document is the durable source of truth across disposable agent sessions. Every fresh session working on Lite Gemini v2 must follow this protocol:

1. **Read this spec in full** at the start of the session before exploring or editing code. Do not rely on prior chat noise.
2. **Respect all constraints in §3**, especially the **Owner Focus Gate** (never launch `Lite Gemini.app` on the owner's Mac) and Swift 6 `MainActor` concurrency rules.
3. **Work on one ticket at a time** from §6 whose dependencies are marked `done`.
4. **Mutate this spec as reality is discovered:**
   - Update the Ticket Tracker table in §6.1 (`pending` → `in_progress` → `done`, plus commit SHA).
   - When completing **T02 (Protocol & DOM Spike)**, populate **§5 (Verified Gemini Web Protocol Contract)** with real, verified request/response shapes and DOM selectors before marking T02 `done`.
   - If Google changes a frontend behavior or an Apple API behaves differently from what is assumed here, stop, report the discrepancy, and record the updated decision in §2 / §5 once approved.

---

## 1. Goal & Product Vision

Lite Gemini v1 (`v0.4.5`) wraps `https://gemini.google.com/app` directly inside a visible `WKWebView`. While lightweight compared to Electron, long conversations and streaming responses suffer from severe frame drops because Gemini's heavy Angular DOM is tuned for Blink/V8 rather than WebKit, and the UI cannot be customized beyond a thin titlebar band.

**Lite Gemini v2** replaces the user-facing chat surface with a **120Hz native SwiftUI + AppKit Liquid Glass interface**, while keeping a **hidden `WKWebView` running `gemini.google.com` underneath as an authenticated Session Bridge**:

- **Zero API cost / full web-account parity:** Users keep using their free Google account or Gemini Advanced web subscription (multi-account `?authuser=N` included) with no API keys.
- **Native macOS feel & speed:** Virtualized native message list, native AppKit `NSTextView` composer (eliminating WebKit CJK IME bugs entirely), instant cold-launch snapshot display, and native macOS Liquid Glass chrome.
- **Anti-abuse safety:** All network calls originate inside the real `gemini.google.com` WebView context, preserving official cookies, `__Secure-1PSIDTS` rotation, CSRF tokens, and BotGuard signatures.
- **Zero-downtime escape hatch:** Dual-mode switching (`Native | Web`) lets the user jump to the full Classic WebView at any time for web-only features (Canvas, Deep Research, Gems management, full history management) or if a Google frontend rollout temporarily breaks the bridge.

---

## 2. Architecture & Locked Decisions

### 2.1 Chosen Architecture & Rejected Alternatives

| Area | Locked Decision | Rejected Alternatives & Why |
|---|---|---|
| **App runtime** | **Pure Swift / SwiftUI / AppKit** in the existing Xcode project. | **Tauri / Rust (`wry`):** Uses the exact same macOS `WKWebView` under the hood, adds a second WebView if drawing custom UI in HTML/React, and lacks the WebKit delegate hooks already used by `PopupWindowController`, `DownloadManager`, and `NewWindowRouter`. |
| **Session transport** | **Hidden `WKWebView` Session Bridge** (`network_hook_plus_dom_driver`): hook `fetch`/`XMLHttpRequest` in JS to read raw streaming/RPC payloads; drive hidden page controls/handlers to submit prompts, attach files, switch models, and trigger turn actions. | **Raw HTTP cookie scraping (`URLSession` + `__Secure-1PSID`):** Breaks frequently due to high-frequency `1PSIDTS` cookie rotation and Google's BotGuard JS VM anti-bot tokens, risking session invalidation or account flags.<br>**Pure DOM `MutationObserver` scraping:** Keeps Angular layout churn alive and yields lossy HTML rather than clean Markdown/thinking/citation structures. |
| **OS target & visual style** | **`MACOSX_DEPLOYMENT_TARGET = 14.0`** (`arm64` + `x86_64` Universal). **macOS Liquid Glass** via `#available(macOS 26.0, *)` native glass APIs, degrading gracefully on macOS 14–15 to `.ultraThinMaterial` / `NSVisualEffectView` capsules with specular hairline strokes. | **Raising minimum OS to macOS 26+:** Drops macOS 14 Sonoma and macOS 15 Sequoia users unnecessarily when material fallback can be encapsulated in one design-system modifier. |
| **Rollout & branch model** | **Incremental commits on `main` behind a Feature Flag** (`enableNativeUI`, default `false` in `Settings → Advanced` during development; flipped to `true` in T10 for `v2.0.0`). | **Long-lived `v2` branch or separate target:** Increases merge drift and duplicates entitlements, Sparkle wiring, and WebKit infrastructure. |
| **Dual-mode handoff** | **Canonical URL Reload Handoff (`url_reload_handoff`):** Switching between `Native` and `Web` modes syncs by conversation URL (`/app` or `/app/<id>`, preserving `?authuser=N`) and reloads/re-fetches cleanly. | **Zero-reload live DOM sharing mid-stream:** Couples native state to transient half-rendered Angular DOM states and complicates CSS paint suppression. Trade-off: switching modes cancels/interrupts an active stream and performs a short sync load. |
| **Local persistence** | **Account-scoped Read-Only SWR Snapshot Cache (`swr_cache_v20`):** Caches the 15–20 most recent conversation summaries and visited conversation snapshots per account for 0ms cold launch and instant switching. **Server-Always-Wins** (atomic full-conversation overwrite; zero two-way merge). | **Two-way sync local database:** Creates severe conflict bugs across Native↔Web mode switches, multi-device prompt edits (which prune conversation subtrees), regenerations, web deletions, and multi-account switches. |
| **Markdown & rich text** | **Curated lightweight SPM AST parser (`swift-markdown`)** rendered into native SwiftUI block views, parsing incrementally per block so streaming only updates the active tail message. | **Regex/hand-rolled parser:** Brittle on nested lists, fenced code blocks inside lists, and tables.<br>**Heavy web/LaTeX engines:** Bloats binary size or reintroduces WebViews per cell. |

### 2.2 v2.0 Product Scope (`lean_mvp` + Prototype-Locked UI & Quick Mode)

#### Design Decisions Locked via Interactive Prototype (2026-11-25)
- **Main Window Top Bar (`Left Recent` layout):**
  - Bare macOS traffic lights sit directly on the window's top-left corner (never enclosed inside a pill border), followed on the left by a floating Liquid Glass **`Recent ▾`** capsule trigger.
  - Right cluster contains a paired **`[Temporary Chat · + New Chat]`** Liquid Glass capsule followed by a **standalone circular Account Avatar** (`28pt` circle only — **no** `?0` index text beside it).
  - **Temporary Chat toggle is icon-only:** Toggling Temporary Chat **never** adds a `"Temp"` text label or shifts layout; it signals active state strictly via icon fill/accent color shift (`oklch` violet/accent tint).
  - **No in-window `Native | Web` button & no `MenuBarExtra` status bar icon:** Mode switching (`Native Liquid Glass` ↔ `Classic Web Mode`) lives in the macOS system **`View` menu** (`Cmd+Shift+M`), plus contextual inline fallback actions (e.g., `"Open in Web ↗"` on unsupported Canvas/Deep Research cards).
- **Decluttered Conversation Surface:**
  - User turns use borderless tonal bubbles (`+0.07 L` lightness step) with rounded image thumbnails above the bubble; assistant prose renders directly on the canvas with an **inline compact `✦ Thought for X.Xs ›` disclosure** (no full-width gray thinking bar) and a single unified footer row combining Turn Actions + Grounding Citation chips.
- **3-State Adaptive Morphing Composer (`26pt` Concentric Capsule):**
  - **State A — Single-Row Pill (Idle / 1-line text, no attachments):** Compact `52pt`-tall pill (`26pt` corner radius, `8pt` inset padding) with a concentric `36×36pt` circular **`+`** button on the left, single-line `Ask anything…` input in the center, and **`Model ▾`** + `36×36pt` circular **`↑` Send** button on the right (muted neutral circle when empty; vivid accent blue circle as soon as text or an attachment is present; **`■` Stop** while streaming).
  - **State B — Multi-Line Card (`> 1` line wrapped text or `Shift+Return`):** Automatically morphs into a `26pt`-radius multi-row card (measured via single-row width hysteresis so expand/collapse never oscillates): full-width text area on top (up to **7 visible lines** max, scrolling internally with a `16pt` top edge `mask-image` fade when `scrollTop > 0`), and `[ (+)  …  Model ▾  (↑) ]` anchored on the bottom row.
  - **State C — Attachment Card (`Cmd+V` image or `+` file):** Morphs into a 3-row `26pt`-radius card with `68×68pt` rounded-`14pt` preview tiles (with corner `×` remove buttons) on the top row, full-width text input in the middle, and `[ (+)  …  Model ▾  (↑) ]` on the bottom row.

#### In Scope for v2.0 Native Mode
1. **Main Window Liquid Glass Chrome (`Left Recent`):**
   - Seamless hidden titlebar hosting bare macOS traffic lights and window drag/zoom support down to `360 × 400` companion size.
   - **Recent Chats Popover (`Recent ▾`):** Read-only glass dropdown on the top-left showing the 15–20 most recent conversations for instant switching (backed by SWR cache + background refresh).
   - **Right Action Cluster:** Icon-only **Temporary Chat** toggle (color-shift active state, honoring `defaultTemporaryChat`) + **`+` New Chat** button (`Cmd+Shift+N`) + **Circular Avatar** opening the multi-account switcher (`?authuser=N` + `"Add Another Account…"` via `PopupWindowController`).
   - **System `View` Menu Mode Switch (`Cmd+Shift+M`):** Switches between `Native Liquid Glass` and `Classic Web Mode` whenever `enableNativeUI` is enabled (no toolbar pill cluttering the window, no menu-bar status icon).
2. **Quick Mode (`快速模式`) — Spotlight-Style Floating Bar & Expandable Mini-Window:**
   - **Global Hotkeys (configurable in `Settings → Shortcuts`):**
     - **`Option + Space` (`⌥Space`) — New Quick Chat:** Summons a floating Quick Mode bar. If a pre-send Quick Bar was previously auto-dismissed with unsent text/attachments, `⌥Space` restores that exact in-progress bar; if the previous Quick session already sent at least one message, `⌥Space` archives it as the most recent Quick session and opens a fresh Quick Bar.
     - **`Option + Shift + Space` (`⌥⇧Space`) — Recent Quick Chat:** Reopens and focuses the most recent Quick session (in its expanded mini-window). **Cold-launch fallback:** If the app was freshly launched and no Quick session has sent a message yet in this app lifecycle, `⌥⇧Space` automatically falls back to opening a New Quick Bar (`⌥Space` behavior).
   - **Pre-Send Floating Bar Lifecycle:**
     - Before the first message is sent, **only the standalone 3-state Adaptive Morphing Composer bar** appears floating on screen (`~548pt` wide, zero window frame/header above it).
     - **Click-outside auto-dismiss with draft preservation:** Clicking anywhere outside the bar (`didResignKeyNotification` or `Esc` with no open popover/IME marked text) immediately hides the bar while **preserving any unsent draft text and staged attachments in memory** for the next `⌥Space`.
   - **Post-Send Expanded Mini-Window Lifecycle:**
     - Submitting the first message smoothly expands the floating bar upward (`bottom` origin) into a compact Liquid Glass mini-window (`~548 × 500pt`) showing the conversation stream above the composer.
     - **Minimalist Quick Chrome:** Top-left shows **macOS Traffic Lights (`● ● ●`) only**; top-right shows a **single circular `+` (New Quick Chat) glass button only**. Quick Mode omits `Recent`, `Avatar`, and any top-bar `Temp` button.
     - **Pinned until explicit close:** Once the first message has been sent, clicking outside **no longer** dismisses the window; the user closes it explicitly via the red Close traffic light button or `Cmd+W`.
   - **Persisted Quick-Mode Temporary Switch inside Model Picker:**
     - In Quick Mode, clicking `Model ▾` opens the Model Picker popover whose **top-right header** hosts a **`Temp` toggle switch**.
     - The user's choice is persisted in `UserDefaults` (`quickModeTemporaryChat`, independent of main window's `defaultTemporaryChat`) and automatically remembered across all subsequent Quick Mode sessions.
3. **Authentication & Mid-Session Challenge UX:**
   - **Signed-Out Welcome Screen:** Native Mode requires a signed-in Google account. When signed out, the main window (and Quick Mode upon summon) displays a native Liquid Glass Welcome gate with **"Sign in with Google"** (opening `PopupWindowController` over the shared `WKWebsiteDataStore`) and a secondary **"Switch to Classic Web Mode"** button.
   - **Mid-Session Challenge Banner:** If a signed-in session encounters re-auth, CAPTCHA, Workspace policy prompts, or unexpected navigation away from `gemini.google.com/app`, any active stream halts immediately (never hanging on an infinite spinner) and displays an actionable banner with **"Verify in Popup"** and **"Web Mode"**.
4. **Native Conversation Stream:**
   - 120Hz scrollable conversation timeline with smart auto-scroll lock during streaming and a floating **"Scroll to bottom"** glass pill when scrolled up.
   - Incremental Markdown block rendering: headings, paragraphs, ordered/unordered/task lists, blockquotes, pipe tables, inline code, links, and fenced code blocks with language label + one-click Copy.
   - Compact inline **`✦ Thought for X.Xs ›`** disclosure (streams live thoughts, collapses cleanly once the final answer begins; expands a subtle left-bordered reasoning trace on click).
   - **Inline & Generated Images:** Loaded asynchronously inside turns with click-to-preview and one-click save to `~/Downloads` via `DownloadManager`.
   - **Citation / Grounding Chips:** Clickable source pills on the turn footer row routed to the default external browser.
   - **Unsupported Rich Artifact Cards:** Canvas documents/code workspaces, Deep Research plans/reports, Gems editors, and interactive extension widgets render as a Liquid Glass card with artifact title/kind and an **"Open in Web ↗"** button that switches the main window directly to `/app/<id>` in Classic Web Mode.
   - **Turn Actions:** **Stop** during active streaming, **Copy** full response Markdown + per-block code copy, **Regenerate** on latest model turn, and **Edit** on latest user turn (`↑` in empty composer or footer button).
5. **Native 3-State Adaptive Morphing Composer:**
   - AppKit `NSTextView`-backed input (`Enter` sends when `!hasMarkedText()`, `Shift+Enter` inserts newline, `↑` in an empty composer edits the last user prompt). Native CJK IME and macOS system Dictation (`Fn Fn`) work natively with zero JS key-swallowing hacks.
   - **Model Picker (`Model ▾` — Shared Compact Abstraction):** Both Main Window and Quick Mode use the **exact same `ModelPickerPopover` component**, sized intrinsically to hug its content (`fixedSize(horizontal: true, vertical: true)` with a tight `12–16pt` gap before the active checkmark — **never** a wide hardcoded popover width that leaves empty whitespace on the right). Lists models available to the current account and conditionally shows the top-right persisted `Temp` switch in Quick Mode.
   - **Clipboard & Single/Multi-File Attachments:** Supports `Cmd+V` image paste, drag-and-drop, and `+` open panel for images and regular files (`68×68pt` rounded-`14pt` preview tiles in the expanded composer). Folder uploads (`webkitdirectory`) display a lightweight banner offering Classic Web Mode.
6. **Legacy WebView Housekeeping (Applies to Both Modes):**
   - Gate `consoleLogBridgeScript` and `consoleLog` IPC handler behind `#if DEBUG`.
   - Remove the `1500ms` `setInterval(reportBg, 1500)` style-recalc loop in `themeSyncScript`, relying on `MutationObserver` + `matchMedia('(prefers-color-scheme: dark)')` instead. Keep `imeFixScript` untouched for Classic Web Mode.

#### Explicitly Deferred to v2.1+ (Handled via `Native | Web` Switch in v2.0)
- Full history sidebar management (full-text search, rename, pin, delete conversations).
- Native Canvas split-pane code/document editor and Deep Research plan approval UI.
- Custom Gemini web microphone capture button inside Native Mode (system macOS Dictation works natively).
- Gems creation/management and Google Workspace connector configuration UI (OAuth popups triggered from Web Mode continue to work via `PopupWindowController`).
- Native LaTeX math typesetting engine (raw `$...$` / `$$...$$` renders cleanly as monospaced/styled math blocks without broken Markdown).

---

### 2.3 Code Organization, Reuse & Isolation Architecture

To keep Main Window, Classic Web Mode, and Quick Mode (`⌥Space` / `⌥⇧Space`) maximally shared with zero boolean-prop tangle and 100% headless testability, all code under `LiteGemini/` follows a strict **Unidirectional Dependency Pyramid** (`Domain` ← `Pure Engines` ← `WebKitHost & Bridge` ← `Stores & Coordinators` ← `Shared UI` ← `Window Shells & AppCoordinator`):

#### 2.3.1 Directory Layout (Synchronized Group — Keep Root Resources Untouched)
> **`Info.plist` (listed in `PBXFileSystemSynchronizedBuildFileExceptionSet`), `*.xcstrings`, `LiteGemini.entitlements`, `Assets.xcassets`, and `AppIcon.icon` MUST remain at the `LiteGemini/` root.** Swift sources organize into layered subfolders:

```text
LiteGemini/
├── App/                        # Composition root & app lifecycle (only layer touching .shared singletons)
│   ├── LiteGeminiApp.swift     # WindowGroup + system View menu (⌘⇧M mode switch) + Settings scene
│   ├── AppDelegate.swift       # Main window transparent titlebar & Sparkle gentle reminder delegate
│   ├── AppCoordinator.swift    # Wires Settings, HotKeys, MainWorkspaceStore & QuickWorkspaceController
│   └── WindowVisibility.swift  # Main window show/hide fade & background Dock policy
├── Settings/
│   ├── SettingsManager.swift   # UserDefaults persistence (enableNativeUI, quickModeTemporaryChat, hotkeys)
│   ├── SettingsView.swift      # General / Shortcuts (⌃`, ⌘⇧N, ⌥Space, ⌥⇧Space) / Advanced / About
│   ├── HotKeyManager.swift     # Carbon hotkey dispatch (showHide, newChat, quickNew, quickRecent)
│   └── HotKeyRecorderView.swift
├── Domain/                     # Layer 0: Pure Swift 6 Sendable value types & protocols (Foundation only)
│   ├── AccountModels.swift     # AccountScope, AuthState, ChallengeBannerState
│   ├── ChatModels.swift        # ConversationSummary, ConversationSnapshot, ChatTurn, MessagePart, ModelOption
│   ├── ComposerModels.swift    # StagedAttachment, ComposerLayoutMode (.compactPill | .expandedCard)
│   ├── GeminiURLRoute.swift    # Pure /app, /app/<id>, /gem/..., ?authuser=N parser & builder
│   └── ChatTransport.swift     # protocol ChatTransport (decouples stores from WKWebView for harnesses)
├── Storage/                    # Layer 1A: Account-scoped SWR snapshot cache (Foundation + CryptoKit)
│   └── SWRConversationCache.swift
├── Markdown/                   # Layer 1B: Incremental AST block parser (Foundation + swift-markdown)
│   └── IncrementalMarkdownParser.swift
├── WebKitHost/                 # Layer 2A: Shared WebKit host primitives extracted from legacy WebViewModel
│   ├── GeminiBaseWebView.swift
│   ├── NewWindowRouter.swift
│   ├── PopupWindowController.swift
│   ├── PopupCoordinator.swift  # Owns active PopupWindowController array; shared by Web, Main & Quick
│   ├── DownloadManager.swift
│   ├── TemporaryChatController.swift
│   ├── ClassicWebScripts.swift # Extracted imeFixScript, themeSyncScript & #if DEBUG consoleLogScript
│   └── ClassicWebViewModel.swift
├── Bridge/                     # Layer 2B: Hidden WebView Session Bridge conforming to ChatTransport
│   ├── GeminiBridgeSelectors.swift
│   ├── GeminiPayloadParser.swift
│   ├── GeminiBridgeScript.swift
│   ├── GeminiActionDriver.swift
│   ├── GeminiRenderSuppressor.swift
│   └── GeminiSessionEngine.swift
├── Store/                      # Layer 3A: Reusable @MainActor conversation & draft state machines
│   ├── ComposerDraftState.swift# Text, staged attachments, edit-rollback snapshot (survives Quick hide)
│   ├── ChatSessionStore.swift  # Shared single-conversation engine (turns, 60fps stream coalescer, actions)
│   └── MainWorkspaceStore.swift# Main window orchestrator (RecentChats, AccountScope, Native↔Web handoff)
├── QuickMode/                  # Layer 3B: Quick Mode (⌥Space / ⌥⇧Space) lifecycle & NSPanel controller
│   ├── QuickWorkspaceController.swift # Holds ChatSessionStore + (.barOnly ↔ .expanded) + cold fallback
│   └── QuickPanelController.swift     # Borderless NSPanel: pre-send resign-key hide, post-send expand & pin
└── UI/                         # Layer 4: Design system, shared chat surface & thin window shells
    ├── DesignSystem/           # LiquidGlass.swift, WindowDragArea.swift, MonochromeSparkShape.swift
    ├── Composer/               # AdaptiveComposerView, ComposerTextView, AttachmentTileStrip, ModelPickerPopover
    ├── Chat/                   # ChatSurfaceView, ConversationTimelineView, ChatTurnRowView, MarkdownBlockViews,
    │                           # ThinkingDisclosureView, CodeBlockCardView, InlineImageGalleryView,
    │                           # ArtifactFallbackCardView, StatusBanners
    └── Shells/                 # MainRootView, MainTopBarView, RecentChatsPopover, AccountPopover,
                                # QuickRootView, QuickMiniTopBarView
```

#### 2.3.2 Five Core Reuse & Isolation Contracts
1. **Dual `GeminiSessionEngine` Instances over One Shared Cookie Store (`WKWebsiteDataStore.default()`):**
   - `GeminiSessionEngine` is a single reusable class implementing `ChatTransport`, sharing `WKWebsiteDataStore.default()` (all Google auth cookies and `__Secure-1PSIDTS` rotations), `PopupCoordinator`, and `DownloadManager`.
   - **Main Window** uses `mainEngine` (whose `WKWebView` also serves directly as the Classic Web Mode view when `interfaceMode == .web`).
   - **Quick Mode** uses a **lazy `quickEngine`** created only on the first `⌥Space` / `⌥⇧Space` invocation (`0 MB` cold-launch overhead; eligible for idle `WKWebView` teardown after closing while retaining `mostRecentQuickSession` turns in Swift memory). This guarantees invoking Quick Mode **never** navigates Main Window away from an open Classic Web Mode Canvas or interrupts an active Main Window stream.
2. **Single `ChatSessionStore` Reused Across Both Windows:**
   - Optimistic user turn insertion, attachment staging, ~60fps streaming chunk coalescing, `Stop`, `Edit` last prompt, `Regenerate`, and `15s` timeout draft rollback live in **one** `ChatSessionStore` class (`init(transport: any ChatTransport, cache: SWRConversationCache?)`), instantiated once inside `MainWorkspaceStore` and once inside `QuickWorkspaceController`.
3. **Single `ChatSurfaceView` Shared Container (Preserving `NSTextView` Structural Identity):**
   - Both Main Window and Quick Mode mount the **exact same `ChatSurfaceView<TopBar, EmptyState>`** container (hosting `topBar`, `ConversationTimelineView`, smart scroll-lock + floating `"Scroll to bottom"` pill, dynamic bottom safe-area inset tracking composer height, banners/toasts, and bottom `AdaptiveComposerView`):
     ```swift
     struct ChatSurfaceView<TopBar: View, EmptyState: View>: View {
         @ObservedObject var store: ChatSessionStore
         var isExpanded: Bool = true                    // true in Main Window; (phase == .expanded) in Quick Mode
         var quickModeTempBinding: Binding<Bool>? = nil // nil in Main Window; $settings.quickModeTemporaryChat in Quick Mode
         var onOpenInWebMode: ((String?) -> Void)? = nil
         @ViewBuilder var topBar: () -> TopBar
         @ViewBuilder var emptyState: () -> EmptyState
     }
     ```
   - Keeping `AdaptiveComposerView` at a constant SwiftUI structural path inside `ChatSurfaceView` while `isExpanded` flips `false → true` on Quick Mode's first send ensures AppKit's `NSTextView` is **never destroyed or unfocused** during upward window expansion.
4. **Single `AdaptiveComposerView` + `ComposerDraftState` (Hysteresis-Measured Morphing):**
   - Single-row vs multi-row layout transitions measure text width against the **single-row text slot width** (with hysteresis) rather than the expanded full-card width, eliminating expand↔collapse oscillation loops.
   - `ComposerDraftState` lives in the store layer so hiding `QuickPanelController` before the first send preserves draft text and staged tiles with zero serialization overhead.
5. **Single Compact `ModelPickerPopover` Abstraction:**
   - Used identically by Main Window (`quickModeTempBinding = nil`) and Quick Mode (`quickModeTempBinding = $settings.quickModeTemporaryChat`), sized strictly via `.fixedSize(horizontal: true, vertical: true)` so the popover hugs its content tightly without trailing whitespace.

---

## 3. Ground Rules & Constraints

Every session must follow these project invariants (inherited and updated from `docs/plans/2026-10-web-capabilities.md`):

### 3.1 Build & Zero-Warning Gate
- **Developer directory:** Every shell invoking `xcodebuild`, `swiftc`, or `xcrun` must set:
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **Debug build:**
  `xcodebuild -project LiteGemini.xcodeproj -scheme "Lite Gemini" -configuration Debug -derivedDataPath /tmp/lg-build build`
- **Release Universal build (matches CI):**
  `xcodebuild -project LiteGemini.xcodeproj -scheme "Lite Gemini" -configuration Release -derivedDataPath /tmp/lg-build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" clean build`
- **Zero-warnings requirement:** Pipe build output through `rg "(warning|error):"`. The only permitted warning is `appintentsmetadataprocessor ... warning: Metadata extraction skipped`. Every other warning or error must be fixed before committing.

### 3.2 Xcode Project & Swift 6 Concurrency Rules
- **File membership is automatic:** `LiteGemini/` uses Xcode file-system-synchronized groups (`objectVersion = 77`). Subfolders and `.swift` files placed inside `LiteGemini/` are compiled automatically. Never add manual `PBXFileReference` or `PBXBuildFile` entries (except SPM package product dependencies when adding `swift-markdown` in T06). Do not touch `PBXFileSystemSynchronizedBuildFileExceptionSet` (`Info.plist`).
- **Swift 6 strict concurrency:** `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
  - Types default to `@MainActor`, which fits SwiftUI, AppKit, and WebKit delegates.
  - Background work (e.g., disk snapshot encoding/decoding or large payload parsing if offloaded) must use explicit `nonisolated` value types / actors with clean `Sendable` boundaries.
  - Wrap non-annotated AppKit main-thread callbacks in `MainActor.assumeIsolated { ... }`.
  - **Forbidden:** `@unchecked Sendable`, `nonisolated(unsafe)`, and `@preconcurrency`.
- **WebKit delegates:** Implement only completion-handler delegate variants (never mix `async` and completion-handler overloads of the same `WKNavigationDelegate` / `WKUIDelegate` method), and ensure every completion/decision handler is called **exactly once** on every path.
- **Code style:** Four-space indentation, `// MARK: - Section` headers, English `///` doc comments on new types/properties/methods, no narrating comments.

### 3.3 Localization (`Localizable.xcstrings`)
- Every user-visible string added in v2 must have an entry in `LiteGemini/Localizable.xcstrings` with both English (`en` source key) and Simplified Chinese (`zh-Hans`, `"state" : "translated"`).
- Maintain alphabetical key order, two-space indentation, and `" : "` key-value separators matching Xcode's String Catalog format.

### 3.4 Testing & Strict Owner Focus Gate
- **NEVER launch the built app on the owner's Mac** (`open "Lite Gemini.app"`, running the app binary directly, or calling `NSApp.activate` in tests is strictly forbidden). It steals window focus from the owner.
- **Automated verification uses headless harnesses** in `/tmp/lg-work/<name>/` (not committed to git):
  - Compile real source files from `LiteGemini/` alongside a standalone `main.swift` using `swiftc -swift-version 6 -default-isolation MainActor -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault ...` (or run via an Xcode test/executable harness that creates offscreen non-windowed `WKWebView` instances with `WKWebsiteDataStore.nonPersistent()`).
  - Serve deterministic mock HTML/XHR/streaming fixtures via `WKURLSchemeHandler` (`lgtest://`).
- **Signed-in verification:** Any check requiring a real signed-in Google session (specifically the T02 diagnostic capture and T10 acceptance) is run manually by the owner once the build is ready; the agent inspects `os.Logger` output (`log show`) or sanitized diagnostic files afterward.

### 3.5 Git & Release Discipline
- Work lands on `main` (or short-lived ticket branches fast-forwarded onto `main` if requested) with `enableNativeUI` defaulting to `false` until T10.
- One clean, atomic commit per ticket (or logical sub-step where specified) with an English commit subject and body explaining **what changed, why, and trade-offs**.
- Never push, tag, create/publish a GitHub release, or modify `.github/workflows/*` without explicit owner approval at that moment.

---

## 4. Data, Sync & Privacy Invariants

To guarantee zero data corruption or privacy leaks across multi-account, multi-device, and dual-mode usage, all data handling in v2 must obey these six invariants:

1. **Server-Always-Wins (Read-Only SWR Cache):**
   - Local storage (`~/Library/Application Support/LiteGemini/Cache/v2/`) is strictly a disposable `stale-while-revalidate` snapshot cache, never an authoritative database.
   - Whenever the Session Bridge receives a conversation payload for `(accountScope, conversationId)` or a fresh Recent Chats list, it **atomically replaces** the entire cached snapshot for that item. No diffing or three-way merging is ever performed.
2. **Strict Account Scope Isolation:**
   - Every cached file/record is partitioned under an opaque `accountScope` directory (e.g., SHA-256 prefix of the signed-in Google email / Gaia ID extracted from the page).
   - If the active account cannot be determined or the user is signed out, `SWRConversationCache` neither reads nor writes disk snapshots. Switching `?authuser=0` ↔ `?authuser=1` swaps the active `accountScope` immediately so accounts never bleed into one another.
3. **Memory-Only Optimistic State:**
   - Optimistic user prompts, edits in progress, attachments being uploaded, and partial streaming tokens live **exclusively in `@MainActor` memory (`ChatSessionStore` / `ComposerDraftState`)**.
   - A conversation snapshot is written to disk **only** from complete, server-acknowledged turn payloads carrying canonical IDs. Interrupted streams never leave half-baked turns on disk.
4. **Temporary Chat Zero-Disk Guarantee:**
   - Whenever `isTemporaryChat == true`, the active session is marked ephemeral: turns are held only in memory, omitted from Recent Chats cache writes, and purged from memory as soon as the user starts a new chat, switches chats, or hits `backgroundTimeout`.
5. **Deletion, Eviction & Clear Browsing Data:**
   - Cached conversations per `accountScope` are capped at **20** via LRU eviction.
   - If navigating to `/app/<id>` redirects back to `/app` or returns a not-found error from Gemini, that `conversationId` is immediately deleted from the local cache.
   - Posting `Notification.Name.browsingDataCleared` (from `Settings → Advanced → Clear Data`) synchronously deletes the entire `Cache/v2/` directory and resets `MainWorkspaceStore` and `QuickWorkspaceController` to the signed-out welcome state.
6. **Cold-Launch & Background Timeout Alignment:**
   - On launch or reopen while `enableNativeUI == true`:
     - If `SettingsManager.shared.backgroundTimeout` has **not** elapsed (e.g., cold launch with `.never`, or reopen within the configured window) and a cached non-temporary last-active conversation exists for the current account, Native Mode renders the cached snapshot in **0ms** and triggers a silent background revalidation of `/app/<id>`.
     - Otherwise, Native Mode opens an empty **0ms** New Chat state (and applies `TemporaryChatController` if `defaultTemporaryChat` is on).

---

## 5. Verified Gemini Web Protocol Contract

> **Verified Live (T02 — 2026-11-25):** Audited against live `https://gemini.google.com/app` build `boq_gemini-web-uiserver_20261125.05_p0` via headless offscreen `WKWebView` captures and static analysis of the live `boq-gemini-web-uiserver` bundle + lazy UI modules. All constants below are centralized in `LiteGemini/Bridge/GeminiBridgeSelectors.swift`.

### 5.1 Auth & Multi-Account Detection
- **Signed-in vs signed-out signal (`WIZ_global_data` + `batchexecute` + DOM):**
  - **Primary boot globals (`window.WIZ_global_data`):**
    - `SNlM0e` (XSRF `at` token): **present non-empty string** when signed in; **absent (`undefined`)** when signed out.
    - `S06Grb` (numeric Gaia User ID): **non-empty numeric string** when signed in; **`""` (empty string)** when signed out.
    - `QrtxK` (`authuser` index): **`"0"`, `"1"`, …** when signed in; **`""`** when signed out.
    - `oPEP7c` (user email, when populated in boot globals): absent when signed out.
    - `Lz8rbb` (anonymous/signed-out boolean flag) + `M9l3o` / `dSupif` (auxiliary signed-out markers inspected by Gemini's internal auth guard).
    - Non-PII operational boot keys: `cfb2h` (build label), `FdrFJe` (`f.sid`), `Im6cmf` (`/_/BardChatUi`), `GK6dn` (`https://geminiweb-pa.clients6.google.com`), `d2zJAe` (API key), `h1eoVe` (`https://push.clients6.google.com/upload/`), `TuX5cc` (locale).
  - **Signed-out DOM markers:** Presence of `a[href*="accounts.google.com/ServiceLogin"]`, top-bar Sign-in `button[jslog^="327170;"]`, sidenav Sign-in `button[jslog^="325776;"]`, or `[data-test-id="sign-out-banner"]` / `mat-card.signed-out`.
  - **Signed-out RPC confirmation:** `batchexecute?rpcids=otAQ7b` (`GetUserStatus`) returns status code `1016` (`UNAUTHENTICATED`) at JSPB `[14]` (proto field `15`), and `o30O0e` (`GetPeople`) / `CNgdBe` (`ListBots`) return `[["wrb.fr","<id>",null,null,null,[7],"generic"]]` (gRPC `7` = `PERMISSION_DENIED`).
- **Active account identity (`accountScope` source, email, avatar URL, `?authuser` index):**
  - **`accountScope` hash input (strictly isolated per §4 #2):** Prefer SHA-256 prefix of `WIZ_global_data["S06Grb"]` (Gaia ID) or lowercased email from `o30O0e` (`InternalPeopleService.GetPeople`) / `WIZ_global_data["oPEP7c"]`. Never read/write `SWRConversationCache` if neither Gaia ID nor email is available.
  - **Live profile & avatar discovery (`o30O0e`):** On signed-in boot, Gemini issues `POST /_/BardChatUi/data/batchexecute?rpcids=o30O0e`, returning `person = arr[0][2]` with `displayName = person[2][0][0]`, `shortName = person[2][0][3]`, `photoUrl = person[3][0][0]`, and `email = person[9][0][0]`.
  - **DOM fallback:** `sidenav-mavatar-footer a[gem-open-account-menu]` and `sidenav-mavatar-footer img.mavatar-image` (fallback `user-profile-picture img.user-icon`).
  - **Active `?authuser` index:** Read from URL query `?authuser=<N>` (or `/u/<N>/` path) reconciled against `WIZ_global_data["QrtxK"]` (defaults to `0` when signed in).
- **Available signed-in accounts & switching mechanism:**
  - Switching accounts navigates the hidden `WKWebView` to `https://gemini.google.com/app?authuser=<N>`.
  - Adding an account opens `https://accounts.google.com/AddSession?continue=https%3A%2F%2Fgemini.google.com%2Fapp` via `PopupCoordinator` / `PopupWindowController`.
  - Initial sign-in opens `https://accounts.google.com/ServiceLogin?passive=1209600&osid=1&continue=https%3A%2F%2Fgemini.google.com%2Fapp` via the same popup flow.
  - Known signed-in `AccountScope` profiles discovered across `?authuser=0..N` visits are retained in non-sensitive metadata for instant switching in `AccountPopover`.
- **Mid-session challenge / redirect indicators:**
  - Main-frame navigation away from `gemini.google.com` (e.g., `accounts.google.com`, `www.google.com/sorry/index`) or onto `/unavailable`.
  - HTTP `401` or `403` on `/v1/processSession`, `/v1/conversations:streamGenerate`, `/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate`, or `/_/BardChatUi/data/batchexecute`.
  - `wrb.fr` / RPC error status `16` (`UNAUTHENTICATED`) or `7` (`PERMISSION_DENIED` on authenticated RPCs), or `GetUserStatus` (`otAQ7b`) status code at `[14]` in `{1016, 1033, 1040, 1054, 1057, 1060}`.
  - gRPC `5` (`NOT_FOUND`) evicts the missing `conversationId` from `SWRConversationCache`.

### 5.2 Outbound & Inbound Network Endpoints (Read Path)
All three streaming transports carry the **same `StreamGenerateResponse` (`_.uv`) protobuf schema** (1-based protobuf field number `N` corresponds to 0-based JSPB JSON array index `N - 1`).

1. **Streaming Transport A — Primary Live Default (`WebChannel` `ProcessSession` over `XMLHttpRequest`):**
   - **Endpoint:** `https://geminiweb-pa.clients6.google.com/v1/processSession` (or `/$rpc/assistant.lamda.bard.GeminiWebService/ProcessSession`), downlink `GET ...?VER=8&RID=rpc&...&TYPE=xmlhttp` observed via `XMLHttpRequest` `progress` events.
   - **Framing:** Length-prefixed WebChannel frames `<charLength>\n[[<seq>,["<base64-encoded-protobuf>"]]]`.
   - **Protobuf unwrap path to `StreamGenerateResponse` (`_.uv`):** `2 -> 7 -> 1 -> 4 -> 4` (with `2 -> 7 -> 1 -> 1` varint `0`=streaming, `1`=complete).
2. **Streaming Transport B — SSE (`fetch`):**
   - **Endpoint:** `POST https://geminiweb-pa.clients6.google.com/v1/conversations:streamGenerate?alt=sse`.
   - **Framing:** `data: <JSON array>\n\n` where each JSON array is JSPB `StreamGenerateResponse` (`_.uv`).
3. **Streaming Transport C — Legacy Boq (`fetch`/`XHR`, also used by Temporary Chat fallback):**
   - **Endpoint:** `POST https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate`.
   - **Framing:** XSSI prefix `)]}'\n` + length-prefixed `[["wrb.fr",null,"<escaped-inner-json-string>"]]` whose inner JSON array is JSPB `StreamGenerateResponse` (`_.uv`).

- **Verified `StreamGenerateResponse` (`_.uv`) Field Map (`protoField` / `JSPB[protoField - 1]`):**
  - `conversationId`: `2.1` (`[1][0]`, `"c_..."`); `responseId`: `2.2` (`[1][1]`, `"r_..."`).
  - `candidates` (`5` / `[4]`): `choiceId` `1` (`[0]`, `"rc_..."`), markdown body `2.1` (`[1][0]`), inline citations `3.1` (`[2][0]`), completion state `9.1` (`[8][0]`: `0`/`2` complete, `1` partial), grounding sources `13.13` (`[12][12]`) / `13.41` (`[12][40]`) / `29` (`[28]`), dynamic view HTML `13.77` (`[12][76]`), Canvas/Deep Research/Immersive artifacts `31` (`[30]`) & `42` (`[41]`), thinking trace `38` (`[37]`: summary `[37][0]`, steps `[37][1]` where each step's markdown body is `[0][0]` and header is `[5]`).
  - Live thinking status header: `7.6.1` (`[6][5][0]`), active flag `7.4` (`[6][3]`).
  - Generated chat title: `11.1` (`[10][0]`); stream final flag: `15` (`[14]`).
  - Structured content & images: `27` (`[26]`) — child field `10` generated images, child field `21` inline web images.
  - Active model metadata: `40` (`[39]` `modeId`), `43` (`[42]` `modelAttributionName`); temporary chat state echo: `47` (`[46]`: `1` off, `2` on).
- **`batchexecute` RPCs (`POST /_/BardChatUi/data/batchexecute?rpcids=<ID>`):**
  - `MaZiqc` (`ListConversations`): `[1]`=`nextPageToken`, `[2]`=conversations (`[0]`=`id`, `[1]`=`title`, `[2]`=`isPinned`, `[3]`=`isHidden`, `[5]`=`[seconds, nanos]`, `[30]`=`isTemporary`).
  - `hNvQHb` (`ListConversationTurns`): `[0]`=turns (`[0]`=`[conversationId, responseId]`, `[2][0][0]`=user prompt, `[2][4]`=`modeId`, `[3][0]`=candidates using `_.NEb`, `[3][3]`=selected `choiceId`, `[3][9]`=`isFinal`, `[3][12]`=structured content, `[4]`=`[seconds, nanos]`).
  - `otAQ7b` (`GetUserStatus`): `[14]`=status code (`1000` ok), `[15]`=available models (`[0]`=`modeId`, `[1]`=`title`, `[2]`=`description`, `[11]`=`luminousTitle`, `[12]`=`luminousDescription`).
  - `o30O0e` (`GetPeople`): `[0][2]` -> `[2][0][0]`=`displayName`, `[3][0][0]`=`photoUrl`, `[9][0][0]`=`email`.

### 5.3 Hidden Page Action Drivers (Write Path)
- **Composer editor selector & text injection:**
  - Primary: `rich-textarea .ql-editor[contenteditable="true"]` (excluding `.ql-clipboard`; fallbacks in `GeminiBridgeSelectors.ComposerDOM.editor`).
  - Injection: `editor.focus()`, `document.execCommand('selectAll', false, null)`, `document.execCommand('insertText', false, text)`, plus `new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text })`.
- **Submit & Stop Generating triggers (`GeminiBridgeSelectors.ComposerDOM`):**
  - **Send (Luminous `lr26`):** `input-area-v2 button[jslog^="173899;"]`, fallbacks `mat-icon[fonticon="arrow_upward"]`, legacy `button.send-button` (wait one frame after text insertion).
  - **Stop (Luminous `lr26`):** `input-area-v2 button[jslog^="188689;"]`, fallbacks `mat-icon[fonticon="stop"]`, legacy `button.stop-button`.
- **Attachment injection:**
  - Primary: Construct `DataTransfer` with `File` objects, focus editor, and dispatch synthetic `ClipboardEvent('paste', { clipboardData, bubbles: true, cancelable: true })`.
  - Fallback: Click upload trigger (`button[jslog^="300142;"]`), assign `DataTransfer.files` to `images-files-uploader input[type="file"].hidden-file-input`, dispatch `change`.
  - Gate send until `uploader-file-preview` count matches staged count and `uploader-file-preview mat-progress-spinner` count drops to `0` (15s timeout).
- **Model picker discovery & selection:**
  - Read via `otAQ7b` `[15]`; switch by clicking `[data-test-id="bard-mode-menu-button"]`, waiting for `gem-menu[data-test-id="gem-mode-menu"]`, and clicking `gem-menu-item[data-mode-id="<id>"]:not([aria-disabled="true"])`.
- **Edit latest user turn & Regenerate latest model turn:**
  - **Edit:** Last `user-query` -> click `[data-test-id="prompt-edit-button"] button` -> replace text in `rich-textarea.edit-rich-textarea .ql-editor[contenteditable="true"]` (fallback `textarea[cdktextareaautosize]`) -> click `.edit-button-area .update-button button`.
  - **Regenerate:** Last `model-response` -> click `regenerate-button button` (if `.regenerate-menu` opens, click `[data-test-id="regenerate-option"]`).
- **Temporary chat state & toggle (Luminous + legacy):**
  - Detect active ON state when either `temp-chat-button` / `.temp-chat-button` has `.temp-chat-on` **OR** `temp-chat-button mat-icon` carries `fonticon="close"` (`data-mat-icon-name="close"`); OFF when `fonticon="gemini_chat_temp"` and no `.temp-chat-on`. Click `temp-chat-button gem-icon-button.temp-chat-button button` (or fallback) only when current state != desired state.

### 5.4 Bridge Resilience Rules
- Centralize all CSS selectors, `WIZ_global_data` keys, `batchexecute` RPC IDs, and protobuf/JSPB field indices in `LiteGemini/Bridge/GeminiBridgeSelectors.swift` — never scatter magic strings across views or stores.
- Every parser function must treat all JSON/array/protobuf lookups defensively (bounds-checked optional decoding, never force-unwrapping). If an unrecognized payload shape arrives, log a structured `os.Logger` `.error` entry under subsystem `io.github.tdhsc.LiteGemini`, category `GeminiBridge` (never logging private prompt/response text or auth tokens), and surface a non-crashing fallback banner offering **"Open in Web Mode"**.
- Every write-path action driver enforces a bounded timeout (15s) and preserves/rolls back `ComposerDraftState` on selector failure so user input is never lost.

---

## 6. Tickets

### 6.1 Ticket Tracker

| ID | Title | Depends On | Status | Commit |
|---|---|---|---|---|
| **T01** | WebKitHost extraction, WebView perf cleanup & v2 feature flag | — | `done` | `7c10c5f` |
| **T02** | Gemini web protocol & DOM spike (populate §5) | T01 | `done` | `e98e2ca` |
| **T03** | `Domain` models, `SWRConversationCache` & reusable `ChatSessionStore` | T01 | `done` | `325d8c4` |
| **T04** | `LiquidGlass` design system, `MainTopBarView` & `View` menu mode handoff | T01, T03 | `done` | `86dc912` |
| **T05** | Session Bridge Part 1: `GeminiSessionEngine`, auth & read stream parser | T02, T03, T04 | `done` | `ba93627` |
| **T06** | Shared `ChatSurfaceView`, 120Hz timeline & incremental Markdown renderer | T03, T04 | `done` | `c24c214` |
| **T07** | Shared `AdaptiveComposerView`, compact `ModelPickerPopover` & attachments | T03, T04 | `done` | `631a89e` |
| **T08** | Session Bridge Part 2: `GeminiActionDriver` write path | T05, T06, T07 | `done` | `2ee988f` |
| **T09** | Quick Mode (`⌥Space` / `⌥⇧Space`) lazy engine & expandable `NSPanel` | T06, T07, T08 | `done` | `068ae7c` |
| **T10** | Hidden WebView render suppression, polish & localization audit | T08, T09 | `done` | `76971e9` |
| **T11** | End-to-end owner acceptance & `v2.0.0` default flip | T10 | `in_progress` | — |

---

### T01. WebKitHost Extraction, WebView Performance Cleanup & v2 Feature Flag

- **Goal:** Reorganize existing sources into §2.3's modular directories (`App/`, `Settings/`, `WebKitHost/`, `UI/DesignSystem/`), extract `PopupCoordinator` & `ClassicWebScripts` from the 834-line `WebViewModel`, eliminate Release main-thread IPC/style-polling overhead, and wire the `enableNativeUI` feature flag without changing default `v0.4.5` behavior.
- **Touched Areas:**
  - `LiteGemini/App/`, `LiteGemini/Settings/`, `LiteGemini/WebKitHost/`, `LiteGemini/UI/DesignSystem/` (move existing `.swift` files cleanly via `git mv`, keeping `Info.plist` & resources at `LiteGemini/` root)
  - `LiteGemini/WebKitHost/ClassicWebScripts.swift` & `LiteGemini/WebKitHost/PopupCoordinator.swift`
  - `LiteGemini/WebKitHost/ClassicWebViewModel.swift` (slimmed from `WebViewModel.swift`)
  - `LiteGemini/Settings/SettingsManager.swift` & `LiteGemini/Settings/SettingsView.swift`
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **Modular directory setup & `WebViewModel` extraction:** Move existing Swift files into §2.3.1's `App/`, `Settings/`, `WebKitHost/`, and `UI/DesignSystem/` (`MonochromeSparkShape`, `WindowDragArea`) folders; extract inline JS literals into `ClassicWebScripts.swift` and popup array ownership into `PopupCoordinator.swift` so `PopupWindowController` + `NewWindowRouter` can be shared with `GeminiSessionEngine` later without duplication.
  2. **Console bridge `#if DEBUG` gate:** Inject `consoleLogBridgeScript` and register/remove `"consoleLog"` only under `#if DEBUG`. Wrap `[IME Debug]` native `print` statements in `ClassicWebViewModel` and `GeminiBaseWebView` in `#if DEBUG` (keeping `imeFixScript` behavior intact).
  3. **Event-driven theme sync:** Remove `setInterval(reportBg, 1500)` from `themeSyncScript`. Keep `DOMContentLoaded` / `load` + `MutationObserver`, and add `window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', reportBg)`.
  4. **Feature flag & mode state in `SettingsManager`:**
     - `enableNativeUI: Bool` (key `"enableNativeUI"`, default `false` until T11).
     - `interfaceMode: InterfaceMode` (`enum InterfaceMode: String { case native, web }`, key `"interfaceMode"`, default `.native`; active only when `enableNativeUI == true`).
  5. **Settings UI & Root Mode Shell:** Add `"Enable Native UI (Experimental)"` toggle in `SettingsView → Advanced` (`en` + `zh-Hans` in `Localizable.xcstrings`), and route root view between `v0.4.5` Classic WebView (when `!enableNativeUI` or `interfaceMode == .web`) and a minimal Native stub (when `enableNativeUI && interfaceMode == .native`).
- **Verification:**
  - Clean Debug & Release Universal builds (zero warnings; verify `Info.plist` exception path remains untouched).
  - Existing harnesses (`dltest2`, `routertest`, `tempchattest`) pass against `WebKitHost/`.
- **Commit:** `refactor: extract WebKitHost modules, remove Release polling, and add Native UI flag`

---

### T02. Gemini Web Protocol & DOM Spike (Populate §5)

- **Goal:** Verify Gemini's live web protocol, `WIZ_global_data` / `AF_initDataCallback` boot payloads, `StreamGenerate` & `batchexecute` wire shapes, and hidden DOM action triggers, then record the exact contract in **§5** and save sanitized fixture samples for offline harness testing.
- **Touched Areas:**
  - `LiteGemini/Bridge/GeminiSpikeRecorder.swift` (`#if DEBUG` only, controlled by environment variable or debug toggle so normal Debug runs stay quiet)
  - `docs/specs/v2-native-ui.md` (§5 populated in full)
- **Requirements:**
  1. **Diagnostic probe script (`#if DEBUG`):** Build a non-destructive JS probe injected when a debug setting/env flag is active that logs sanitized structural summaries (field paths, value types, RPC IDs, element tag/class/attributes — **never** logging cookies, auth tokens, raw emails, or private prompt text to persistent system logs; full sanitized JSON structure dumps may be written to `/tmp/lg-spike/` with strings redacted/truncated for the owner-run capture).
  2. **Headless signed-out probe:** Run an automated headless harness in `/tmp/lg-work/spike-signedout/` against signed-out `https://gemini.google.com/app` to verify signed-out markers, boot globals, and composer DOM structure.
  3. **Single owner signed-in capture:** Provide the owner a 5-step 2-minute checklist to run once in a local Debug build (open `/app`, switch model, send one text prompt + one image prompt, click Regenerate/Edit, open Recent Chats / switch account if applicable). Read the resulting `/tmp/lg-spike/` structural traces.
  4. **Populate §5 of this spec** with exact verified findings for §5.1–§5.3 and define canonical mock fixtures (as Swift string/JSON test fixtures for harnesses in T05 and T08). Remove or keep `GeminiSpikeRecorder` strictly inert unless explicitly enabled in `#if DEBUG`.
- **Verification:**
  - §5 contains zero `TBD (T02)` placeholders.
  - Debug & Release Universal builds pass with zero warnings (`Release` compiles zero spike code).
- **Commit:** `docs: record verified Gemini web bridge contract from T02 spike`

---

### T03. `Domain` Models, `SWRConversationCache` & Reusable `ChatSessionStore`

- **Goal:** Build the zero-WebKit `Domain/` layer (`ChatTransport` protocol + `Sendable` models), account-scoped `SWRConversationCache`, and reusable `@MainActor` `ChatSessionStore` + `MainWorkspaceStore` with 100% deterministic harness coverage.
- **Touched Areas:**
  - `LiteGemini/Domain/AccountModels.swift`, `ChatModels.swift`, `ComposerModels.swift`, `GeminiURLRoute.swift`, `ChatTransport.swift`
  - `LiteGemini/Storage/SWRConversationCache.swift`
  - `LiteGemini/Store/ComposerDraftState.swift`
  - `LiteGemini/Store/ChatSessionStore.swift`
  - `LiteGemini/Store/MainWorkspaceStore.swift`
- **Requirements:**
  1. **`Domain/` value types & `ChatTransport` protocol (`Codable`, `Equatable`, `Sendable`, zero AppKit/WebKit imports):**
     - `AccountScope`, `ConversationSummary`, `ChatTurn`, `MessagePart` (`.markdown`, `.inlineImage`, `.unsupportedArtifact`), `ConversationSnapshot`, `ModelOption`, `StagedAttachment`, `GeminiURLRoute`.
     - `protocol ChatTransport` defining async stream/action hooks so `ChatSessionStore` is 100% testable with `MockChatTransport`.
  2. **`SWRConversationCache`:**
     - Stores JSON snapshots atomically (`.atomic` write) under `~/Library/Application Support/LiteGemini/Cache/v2/<accountScopeId>/` (configurable base `URL` in `init` so harnesses use `/tmp/`).
     - Enforces **all six invariants in §4**: full-snapshot overwrite (`Server-Always-Wins`), strict `accountScope` isolation, LRU eviction above 20 conversations per account, immediate eviction on server not-found, zero disk writes when `isTemporaryChat == true`, and full directory wipe on `.browsingDataCleared`.
  3. **Reusable `ChatSessionStore` + `ComposerDraftState` + `MainWorkspaceStore`:**
     - `ChatSessionStore` encapsulates single-conversation turns, ~60fps streaming chunk coalescer, `ComposerDraftState` (draft text, staged attachments, edit-rollback snapshot), `isTemporaryChat`, `selectedModelId`, and `challengeBanner` — designed to be instantiated identically by `MainWorkspaceStore` and `QuickWorkspaceController` (T09).
     - `MainWorkspaceStore` composes `ChatSessionStore` with `authState`, `recentConversations`, `?authuser=N` account switching, and cold-start restoration (taking injected `backgroundTimeout` config rather than reading singletons directly).
- **Verification:**
  - Headless harness `cachetest` in `/tmp/lg-work/cachetest/` covering:
    1. Cold read/write round-trip and atomic full-snapshot overwrite (older turns pruned after web edit disappear locally).
    2. Multi-account isolation (`accountA` vs `accountB` with identical `conversationId` never collide).
    3. `isTemporaryChat == true` writes zero files to disk.
    4. Optimistic pending/streaming state never persists to disk if interrupted.
    5. LRU cap at 20 evicts oldest snapshot while keeping newest 20.
    6. `.browsingDataCleared` wipes all account directories cleanly.
    7. `backgroundTimeout` expired vs active cold-start restoration behavior.
  - Clean Debug & Release Universal builds.
- **Commit:** `feat: add native chat models, account-scoped SWR cache, and store`

---

### T04. `LiquidGlass` Design System, `MainTopBarView` & `View` Menu Mode Handoff

- **Goal:** Build the reusable `LiquidGlass` design primitives (`macOS 26+` native glass + `macOS 14–15` material fallback), `MainTopBarView` (`Left Recent` layout), and `url_reload_handoff` dual-mode switching via the system `View` menu.
- **Touched Areas:**
  - `LiteGemini/UI/DesignSystem/LiquidGlass.swift`
  - `LiteGemini/UI/Shells/MainTopBarView.swift`
  - `LiteGemini/UI/Shells/RecentChatsPopover.swift`
  - `LiteGemini/UI/Shells/AccountPopover.swift`
  - `LiteGemini/UI/Shells/MainRootView.swift`
  - `LiteGemini/App/AppCoordinator.swift` & `LiteGemini/App/LiteGeminiApp.swift`
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **`LiquidGlass` design primitives:**
     - `glassCapsule()`, `glassCard(cornerRadius:)`, and `glassToolbarButton()` view modifiers: use `#available(macOS 26.0, *)` native SwiftUI `.glassEffect(...)` where available; fall back cleanly on macOS 14–15 to `.ultraThinMaterial` / `.regularMaterial`, adaptive subtle tint, `0.5pt` specular top/perimeter stroke, and soft elevation shadow in both Light and Dark appearances.
  2. **Top Glass Chrome (`Left Recent` layout, responsive down to `minWidth: 360`):**
     - Bare macOS traffic lights sit directly on the window's top-left corner (never enclosed inside a pill border), preserving `28pt`+ clearance and `WindowDragArea` double-click zoom.
     - Left cluster (beside traffic lights): **`Recent ▾`** Liquid Glass capsule trigger opening `RecentChatsPopover` (up to 20 cached/synced titles).
     - Right cluster: paired **`[Temporary Chat · + New Chat]`** Liquid Glass capsule + **standalone circular Avatar** (`28pt` circle only, zero `?0` index label; opens `AccountPopover` with active email, signed-in account list, and `"Add Another Account…"`).
     - **Temporary Chat toggle is strictly icon-only:** Toggling Temporary Chat shifts the ghost icon's fill/accent color (`oklch` violet tint) without ever displaying `"Temp"` text or shifting layout.
     - **Zero in-window `Native | Web` button and zero `MenuBarExtra` status icon:** Keep the window toolbar completely free of mode-switch chrome.
  3. **System `View` Menu Mode Switch & Shortcuts:**
     - Place `"Native Liquid Glass"` / `"Classic Web Mode"` (`Cmd+Shift+M`) inside the macOS system `View` menu (`LiteGeminiApp` `CommandGroup` when `enableNativeUI` is on).
     - Route `Cmd+R` in Native Mode to re-sync the current conversation, and `.newChatRequested` (`Cmd+Shift+N`) to start a fresh chat in whichever mode is active.
  4. **URL Reload Handoff (`url_reload_handoff`):**
     - Switching `Native → Web`: navigates/ensures the underlying `WKWebView` is at the active conversation URL (`/app` or `/app/<id>` with active `?authuser=N`) and reveals the Classic WebView seamlessly.
     - Switching `Web → Native`: reads `webView.url`, cancels any in-flight native transient state, sets `MainWorkspaceStore` to that URL's conversation (or `/app` new chat), and triggers a fresh bridge sync.
- **Verification:**
  - Headless unit harness `urlhandofftest` verifying URL parsing (`/app`, `/app/<id>`, `/gem/...`, `?authuser=N` preservation) and mode-switch state transitions.
  - Clean Debug & Release Universal builds (confirm `#available(macOS 26.0, *)` compiles cleanly with `MACOSX_DEPLOYMENT_TARGET = 14.0` and `CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE`).
- **Commit:** `feat: implement Liquid Glass chrome and URL-based dual-mode handoff`

---

### T05. Session Bridge Part 1: `GeminiSessionEngine`, Auth & Read Stream Parser

- **Goal:** Build the reusable `GeminiSessionEngine` (conforming to `ChatTransport`, sharing `WKWebsiteDataStore.default()`, `PopupCoordinator`, and `DownloadManager`) and connect its read path to `MainWorkspaceStore` / `ChatSessionStore` and `SWRConversationCache`.
- **Touched Areas:**
  - `LiteGemini/Bridge/GeminiBridgeSelectors.swift`
  - `LiteGemini/Bridge/GeminiBridgeScript.swift`
  - `LiteGemini/Bridge/GeminiPayloadParser.swift`
  - `LiteGemini/Bridge/GeminiSessionEngine.swift`
  - `LiteGemini/UI/Chat/StatusBanners.swift` (`NativeWelcomeView`, `ChallengeBannerView`, `DownloadToastView`)
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **JS Read Tap (`GeminiBridgeScript`):** Injected at `.atDocumentStart` in main frame (`gemini.google.com`), wrapping `window.fetch` and `XMLHttpRequest` to tee response streams/bodies for the endpoints verified in §5 without mutating or delaying the page's own consumers, posting structured messages to `WKScriptMessageHandler` (`"geminiBridge"`).
  2. **Pure Swift Parser (`GeminiPayloadParser`):** Parses boot/account metadata, Recent Chats payloads, full conversation turn payloads, and incremental `StreamGenerate` chunks (markdown text deltas/snapshots, thinking text, citations, inline image URLs, Canvas/Deep Research artifact detection, canonical IDs). Zero WebKit imports so harnesses test it directly against §5 fixtures.
  3. **Auth & Account Flows:**
     - Signed-out state shows `NativeWelcomeView` (Liquid Glass card with `"Sign in with Google"` and `"Use Classic Web Mode"`). Clicking `"Sign in with Google"` opens `https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fapp` via `window.open` inside the hidden `WKWebView`, reusing `NewWindowRouter` + `PopupWindowController` so completion automatically routes `.moveToMain` and unlocks Native Mode.
     - Account switching (`?authuser=N`) reloads the hidden `WKWebView` at the target account URL, updates `AccountScope`, and loads that account's isolated SWR cache. `"Add Another Account…"` opens `accounts.google.com/AddSession` via the same popup path.
  4. **Mid-Session Challenge Detection:** If `StreamGenerate`/`batchexecute` fails with auth/challenge status or the main frame redirects off `gemini.google.com`, immediately terminate `ChatSessionStore` streaming state and surface `ChallengeBannerView` (`"Verify in Popup"` / `"Switch to Web Mode"`).
- **Verification:**
  - Headless harness `bridgetest` in `/tmp/lg-work/bridgetest/` testing `GeminiPayloadParser` + `GeminiSessionEngine` against `WKURLSchemeHandler` mock pages serving T02's sanitized signed-out, signed-in, multi-chunk streaming, Canvas artifact, and mid-stream HTTP 401/redirect fixtures.
  - Clean Debug & Release Universal builds.
- **Commit:** `feat: add Gemini session read bridge, auth welcome flow, and stream parser`

---

### T06. Shared `ChatSurfaceView`, 120Hz Timeline & Incremental Markdown Renderer

- **Goal:** Build the shared `ChatSurfaceView<TopBar, EmptyState>` container (reused identically by Main Window and Quick Mode so `NSTextView` preserves structural identity across Quick Mode expansion) along with the 120Hz `ConversationTimelineView` and AST-backed `IncrementalMarkdownParser`.
- **Touched Areas:**
  - `LiteGemini.xcodeproj/project.pbxproj` & `Package.resolved` (add `https://github.com/apple/swift-markdown` SPM package)
  - `LiteGemini/Markdown/IncrementalMarkdownParser.swift`
  - `LiteGemini/UI/Chat/ChatSurfaceView.swift`
  - `LiteGemini/UI/Chat/ConversationTimelineView.swift`
  - `LiteGemini/UI/Chat/ChatTurnRowView.swift`
  - `LiteGemini/UI/Chat/MarkdownBlockViews.swift`
  - `LiteGemini/UI/Chat/CodeBlockCardView.swift`
  - `LiteGemini/UI/Chat/ThinkingDisclosureView.swift`
  - `LiteGemini/UI/Chat/InlineImageGalleryView.swift`
  - `LiteGemini/UI/Chat/ArtifactFallbackCardView.swift`
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **Shared `ChatSurfaceView<TopBar, EmptyState>` (§2.3.2 #3):** Encapsulates `topBar`, `ConversationTimelineView` + `emptyState` (collapsed when `isExpanded == false` in Quick Mode's pre-send bar), smart scroll-lock + floating `"Scroll to bottom"` pill, dynamic bottom content-margin tracking composer height, banners/toasts, and bottom composer slot so `NSTextView` never unmounts when `isExpanded` flips `false → true`.
  2. **Incremental AST caching:** Completed turns parse their Markdown AST once and memoize the resulting block models by `(turnId, contentHash)`. During live streaming, only the trailing active turn re-parses (throttled to ~30–60fps coalesced UI ticks if chunks arrive faster), keeping scroll performance at 120Hz even in 100-turn chats.
  3. **Block Views:** Headings, selectable body text (`textSelection(.enabled)`), nested ordered/unordered lists, blockquotes, horizontal scrollable pipe tables, inline monospaced code, and external links. Raw `$...$` / `$$...$$` math blocks render cleanly in styled monospaced math containers without mangling underscores/asterisks.
  4. **Code Block Cards:** Recessed tonal card showing language identifier + `"Copy"` / `"Copied"` feedback button, horizontal scroll monospaced code content.
  5. **Thinking, Images, Citations & Artifacts:**
     - `ThinkingDisclosureView`: compact borderless inline trigger (`✦ Thought for X.Xs ›` / live pulsing `"Thinking…"`), never a full-width gray bar; expands a subtle left-bordered reasoning trace on click.
     - `InlineImageGalleryView`: authenticated image loading (sharing `WKWebsiteDataStore.default().httpCookieStore` session cookies if image URLs require Google auth!), `1pt` translucent black/white `10%` inset outline, click-to-zoom Quick Look / sheet preview, and one-click save button wired to `DownloadManager`.
     - `CitationChipsView`: compact pills rendered inline on the unified turn footer row alongside Turn Actions, opening source URLs via `NSWorkspace.shared.open`.
     - `ArtifactFallbackCardView`: Liquid Glass card for Canvas / Deep Research / unsupported rich cards with `"Open in Web ↗"` button invoking the T04 mode handoff on Main Window for `/app/<id>`.
  6. **Action Bar & Scroll Behavior:** Unified footer bar on turns for **Copy**, **Regenerate** (latest model turn), and **Edit** (latest user turn). Auto-scroll sticks to bottom during streaming until user scrolls upward manually; floating `"Scroll to bottom"` glass pill restores lock.
- **Verification:**
  - Headless harness `markdowntest` verifying AST block splitting on streaming partial fences, nested lists, pipe tables, math spans, and memoization cache hits.
  - Clean Debug & Release Universal builds (`xcodebuild -resolvePackageDependencies` + universal build).
- **Commit:** `feat: add 120Hz native conversation timeline and incremental Markdown renderer`

---

### T07. Shared `AdaptiveComposerView`, Compact `ModelPickerPopover` & Attachments

- **Goal:** Build the shared AppKit-backed 3-state `AdaptiveComposerView` (`26pt` concentric capsule) with hysteresis single-row measurement, native macOS IME/Dictation handling, shared compact `ModelPickerPopover`, and `68×68pt` attachment tiles.
- **Touched Areas:**
  - `LiteGemini/UI/Composer/ComposerTextView.swift` (`NSViewRepresentable` wrapping `NSTextView`)
  - `LiteGemini/UI/Composer/AdaptiveComposerView.swift`
  - `LiteGemini/UI/Composer/AttachmentTileStrip.swift`
  - `LiteGemini/UI/Composer/ModelPickerPopover.swift`
  - `LiteGemini/App/AppCoordinator.swift` (route input focus on window activation to native composer when in Native Mode)
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **3-State Adaptive Morphing Layout (`AdaptiveComposerView` + `ComposerTextView`):**
     - **Concentric geometry:** `26pt` outer corner radius with `8pt` inset around `36×36pt` (`18pt` radius) circular left **`+`** and right **`↑` Send / `■` Stop** buttons.
     - **State A (Single-Row Pill):** When text fits on 1 line and no attachments/banners are active, renders as a compact `52pt` single-row pill: `[ (+)  Ask anything…  Model ▾  (↑) ]`.
     - **State B (Multi-Line Card):** As soon as text wraps past the single-row width (measured via single-row width hysteresis so expand/collapse never oscillates) or contains a newline, morphs into a 2-row `26pt` card: full-width text area on top (growing up to **7 visible lines** max before internal scrolling, applying a `16pt` top edge fade mask when `scrollTop > 0`) and `[ (+)  …  Model ▾  (↑) ]` on the bottom bar.
     - **State C (Attachment Card):** When one or more images/files are staged, morphs into a 3-row `26pt` card with **`68×68pt` rounded-`14pt` preview tiles** (with corner `×` remove buttons) on the top row, full-width `Ask anything…` input in the middle, and `[ (+)  …  Model ▾  (↑) ]` on the bottom bar.
     - **Zero CJK IME bugs:** Respects `hasMarkedText()` natively — `Return` during active IME composition confirms candidates through macOS TextInputClient and **never** submits; plain `Return` when `!hasMarkedText()` submits; `Shift+Return` inserts a newline.
     - Pressing `↑` (Up Arrow) when empty and `!hasMarkedText()` triggers edit mode on the latest user turn (`Esc` cancels).
     - Intercepts `paste(_:)` (`Cmd+V`) and drag-and-drop (`NSDraggingDestination`) to stage clipboard screenshots and files into `StagedAttachment` tiles.
  2. **Attachments & Folder Fallback:**
     - Circular `+` button opens `NSOpenPanel` for images and regular files (`allowsMultipleSelection = true`, `canChooseDirectories = false`), plus `"Upload Folder in Web Mode…"` (and dragging a directory shows a dismissible banner offering Classic Web Mode).
  3. **Composer Controls (`ModelPickerPopover` & Send Circle):**
     - **Single shared `ModelPickerPopover` abstraction** reused identically across Main Window and Quick Mode: uses **compact intrinsic width (`fixedSize(horizontal: true, vertical: true)`)** hugging the longest model name/subtitle plus a tight `12–16pt` trailing gap to the checkmark — **never** an oversized fixed width with dead whitespace on the right.
     - Accepts an optional `quickModeTempBinding: Binding<Bool>?` parameter (`nil` in Main Window; non-`nil` in Quick Mode) that renders the compact **`Temp` toggle switch** in the top-right header row when present.
     - `36×36pt` circular Send button uses muted neutral fill when empty/disabled, vivid accent blue when text or attachments are ready, and `■` Stop while streaming.
  4. **Window Activation Auto-Focus:** When `WindowVisibility.shared.show()` or `appDidBecomeActive` fires in Native Mode, focus lands directly in `ComposerTextView`.
- **Verification:**
  - Headless harness `composertest` testing `NSTextView` key routing (`hasMarkedText` mocked true vs false on `insertNewline`, `Shift+Return`, `Up Arrow` empty-composer edit trigger, single-row vs multi-line morph hysteresis, and image/directory pasteboard classification).
  - Clean Debug & Release Universal builds.
- **Commit:** `feat: build 3-state adaptive morphing NSTextView composer with model picker and attachment tiles`

---

### T08. Session Bridge Part 2: `GeminiActionDriver` Write Path

- **Goal:** Complete the end-to-end interactive loop in `GeminiSessionEngine` by wiring prompt sending, staged file/image attachment injection, model switching, Stop Generating, Edit latest prompt, Regenerate, New Chat, and Temporary Chat through `GeminiActionDriver`.
- **Touched Areas:**
  - `LiteGemini/Bridge/GeminiActionDriver.swift`
  - `LiteGemini/Bridge/GeminiSessionEngine.swift`
  - `LiteGemini/Store/ChatSessionStore.swift`
  - `LiteGemini/WebKitHost/TemporaryChatController.swift` (extend to support explicit ON/OFF synchronization for both Main Window and Quick Mode)
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **Send & Optimistic Lifecycle:** Submitting from `AdaptiveComposerView` immediately appends an in-memory optimistic turn in `ChatSessionStore`, injects staged attachments (if any) + prompt text into `GeminiSessionEngine`'s hidden `WKWebView` using §5.3's verified driver, triggers Gemini's send action, streams live chunks via T05's read tap, and upon stream completion replaces the optimistic turn with the canonical server turn and writes the updated snapshot to `SWRConversationCache` (unless `isTemporaryChat`).
  2. **Attachment Injection:** Transfers staged image/file bytes into the hidden page's file input / `DataTransfer` pipeline (chunked/base64 or local blob creation inside page context, capped at sensible size limits with clear error notice on rejection) and waits for Gemini's upload-ready indicator before clicking Send.
  3. **Model Switching:** Selecting a `ModelOption` drives Gemini's model switcher in the hidden page and verifies the active state; surfaces a toast if unavailable.
  4. **Stop, Edit Latest Turn & Regenerate:**
     - **Stop:** Clicks Gemini's stop button in the hidden page and finalizes the partial stream in memory without corrupting cache.
     - **Edit latest user prompt:** Drives Gemini's edit-last-query UI/action in the hidden page, pruning the replaced response in `ChatSessionStore` and streaming the new response.
     - **Regenerate latest response:** Triggers Gemini's redo/regenerate control on the last model turn and streams the replacement response.
  5. **New Chat & Temporary Chat:** Starting a new chat or toggling Temporary Chat in Native Mode keeps the hidden page at `/app` and synchronizes `.temp-chat-on` state via `TemporaryChatController`.
  6. **Timeout & Failure Recovery:** Every write driver has an explicit timeout (e.g., 15s to start streaming / attach); if a DOM selector fails (e.g., Google changed a button class), log `.error` in `GeminiBridge`, roll back optimistic send (restoring the user's draft text & attachments into the composer so nothing is lost!), and show a banner with **"Switch to Web Mode"**.
- **Verification:**
  - Headless harness `drivertest` in `/tmp/lg-work/drivertest/` serving an interactive mock Gemini DOM + `StreamGenerate` endpoint via `WKURLSchemeHandler`, verifying: send text, send image attachment, stop mid-stream, edit last turn, regenerate, selector-missing draft rollback (draft text preserved!), and temporary-chat toggle sync.
  - Clean Debug & Release Universal builds.
- **Commit:** `feat: wire session bridge write drivers for send, attachments, edit, and regenerate`

---

### T09. Quick Mode (`⌥Space` / `⌥⇧Space`) Lazy Engine & Expandable `NSPanel`

- **Goal:** Deliver Quick Mode (`⌥Space` new / `⌥⇧Space` recent with cold-launch fallback) by composing the shared `ChatSurfaceView`, `ChatSessionStore`, and a lazy second `GeminiSessionEngine` instance inside `QuickPanelController`.
- **Touched Areas:**
  - `LiteGemini/QuickMode/QuickWorkspaceController.swift`
  - `LiteGemini/QuickMode/QuickPanelController.swift` (`NSPanel` floating bar ↔ expanded mini-window controller)
  - `LiteGemini/UI/Shells/QuickRootView.swift` & `LiteGemini/UI/Shells/QuickMiniTopBarView.swift`
  - `LiteGemini/Settings/HotKeyManager.swift` (add `HotKeyIDs.quickNew` & `HotKeyIDs.quickRecent`)
  - `LiteGemini/Settings/SettingsManager.swift` (`quickNewHotKey`, `quickRecentHotKey`, `quickModeTemporaryChat`)
  - `LiteGemini/Settings/SettingsView.swift` (add Quick Mode shortcut recorders in `Shortcuts` tab)
  - `LiteGemini/App/AppCoordinator.swift`
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **Global Hotkeys & Cold-Launch Fallback:**
     - `quickNewHotKey`: default **`Option + Space` (`⌥Space`, `kVK_Space` + `optionKey`)**.
       - If the Quick panel is hidden in `.barOnly` phase (dismissed before sending its first message), re-shows the bar with **any in-progress unsent `ComposerDraftState` text and staged attachments intact**.
       - If the Quick panel is already key & visible in `.barOnly` phase, hides it (preserving `ComposerDraftState`).
       - If the active Quick session is in `.expanded` phase (has ≥1 sent message, whether open or closed), saves its turns as `mostRecentQuickSession` and resets `ChatSessionStore` to a **fresh `.barOnly` Quick Bar** inheriting `settings.quickModeTemporaryChat`.
     - `quickRecentHotKey`: default **`Option + Shift + Space` (`⌥⇧Space`, `kVK_Space` + `optionKey | shiftKey`)**.
       - If `mostRecentQuickSession != nil` in the current app process lifetime, opens and focuses the Quick panel in `.expanded` mini-window phase showing that conversation.
       - **Cold-launch fallback:** If the app was freshly launched (`mostRecentQuickSession == nil`), automatically falls back to `⌥Space` behavior (opening a New Quick Bar).
  2. **Shared `ChatSurfaceView` Mounting (Zero `NSTextView` Unmount on Expand):**
     - `QuickRootView` mounts the shared `ChatSurfaceView` with `isExpanded = (controller.phase == .expanded)` and `topBar = { QuickMiniTopBarView(...) }`.
     - **Pre-send (`.barOnly`):** Borderless transparent floating `NSPanel` (`~548pt` wide, `.canJoinAllSpaces`, `.fullScreenAuxiliary`) where `isExpanded == false` hides the header & timeline while keeping `AdaptiveComposerView`'s `NSTextView` alive at the same structural path. On `NSWindow.didResignKeyNotification` (unless a child `NSOpenPanel` / popover owns focus) or `Esc` (when no popover/IME marked text is active), hides the panel (`orderOut(nil)`) **without** clearing `ComposerDraftState`.
     - **Post-send (`.expanded`):** Submitting the first message flips `phase = .expanded`, animating the `NSPanel` frame upward from its bottom edge to `~548 × 500pt` with **zero focus loss**. `QuickMiniTopBarView` renders **macOS Traffic Lights (`● ● ●`) on top-left** and a **single `30pt` circular `+` glass orb on top-right** (no `Recent`, no `Avatar`, no toolbar `Temp`). Once `.expanded`, `didResignKeyNotification` **no longer** hides the panel; it closes only via the red Close button or `Cmd+W`.
  3. **Persisted Quick-Mode `Temp` Switch in Shared `ModelPickerPopover`:**
     - Passes `$settings.quickModeTemporaryChat` (`UserDefaults` key `"quickModeTemporaryChat"`) as `quickModeTempBinding` into `ChatSurfaceView` → `AdaptiveComposerView` → `ModelPickerPopover`, remembering the user's choice across all future Quick Mode sessions.
  4. **Lazy Isolated `GeminiSessionEngine` (§2.3.2 #1):**
     - `QuickWorkspaceController` instantiates its dedicated `quickEngine: GeminiSessionEngine` lazily on the first Quick Mode summon (sharing `WKWebsiteDataStore.default()`, `PopupCoordinator`, and `DownloadManager` with `mainEngine`), guaranteeing Quick Mode never interrupts or navigates Main Window's active Native or Classic Web session.
- **Verification:**
  - Headless harness `quickmodetest` in `/tmp/lg-work/quickmodetest/` verifying:
    1. Cold-launch `⌥⇧Space` automatically falls back to `.barOnly` New Quick Bar.
    2. Typing draft + Staging image in `.barOnly` → simulated resign-key auto-hides → next `⌥Space` restores exact draft & attachment.
    3. First send transitions `.barOnly → .expanded`; subsequent resign-key keeps window open; explicit close hides window and populates `mostRecentQuickSession`; `⌥⇧Space` reopens `mostRecentQuickSession`.
    4. Toggling `Temp` inside Model Picker persists `quickModeTemporaryChat` across new `⌥Space` and `+` Quick sessions.
  - Clean Debug & Release Universal builds (never activating/focusing visible windows on the owner's screen during harness runs!).
- **Commit:** `feat: add Quick Mode floating bar (Opt+Space / Opt+Shift+Space) and expandable mini-window`

---

### T10. Hidden WebView Render Suppression, Polish & Localization Audit

- **Goal:** Minimize CPU/GPU/memory cost of the hidden `WKWebView` while in Native Mode, polish animations/accessibility/narrow-window edge cases across both Main Window and Quick Mode, and audit 100% bilingual string coverage.
- **Touched Areas:**
  - `LiteGemini/Bridge/GeminiRenderSuppressor.swift`
  - `LiteGemini/UI/...` & `LiteGemini/QuickMode/...` (layout/animation/accessibility refinements)
  - `LiteGemini/Localizable.xcstrings`
- **Requirements:**
  1. **Safe WebView Paint Suppression in Native Mode:**
     - Keep the underlying `WKWebView` mounted with a minimal valid geometry (do not `0×0` or detach in a way that throttles `requestAnimationFrame` or breaks Angular's composer/upload handlers — verify in harness!), keep it behind the opaque/glass native layer (`allowsHitTesting(false)`, `accessibilityHidden(true)`), and inject a toggleable stylesheet in Native Mode that disables heavy CSS animations, transitions, syntax-highlight repaints, and offscreen history layout (`content-visibility: hidden` on Gemini's message scroll container while keeping composer/toolbar/menu DOM interactive for `GeminiActionDriver`).
     - Immediately remove the suppression stylesheet when switching to `Web` mode so Classic WebView renders identically to v1.
  2. **UX & Edge-Case Polish:**
     - Verify `360 × 400` minimum window layout across Welcome screen, active chat, editing banner, challenge banner, Recent Chats popover, Account menu, and Quick Mode mini-window.
     - Verify network offline / load failure states in Native Mode (clean retry + cached read access).
     - Verify keyboard navigation (`Cmd+,`, `Cmd+W` in Main vs Quick window, `Cmd+Q` with `keepRunningInBackground`, `Cmd+R`, `Cmd+Shift+N`, `Cmd+Shift+M`, `⌥Space`, `⌥⇧Space`, `Esc` to cancel edit/popovers/pre-send Quick Bar) and VoiceOver labels on all icon-only glass buttons.
  3. **Localization Audit:** Check every `String(localized:)` / SwiftUI string literal across all new files against `LiteGemini/Localizable.xcstrings` (`en` + `zh-Hans` `translated`), verifying compiled `.lproj/Localizable.strings` with `plutil -p`.
- **Verification:**
  - Automated harness confirming `GeminiActionDriver` (send/attach/temp-chat) still succeeds with `GeminiRenderSuppressor` active, and that disabling suppression restores normal computed styles.
  - `plutil -p` check on built `zh-Hans.lproj/Localizable.strings`.
  - Clean Debug & Release Universal builds.
- **Commit:** `perf: suppress hidden WebView paint work in Native Mode and complete zh-Hans localization`

---

### T11. End-to-End Owner Acceptance & `v2.0.0` Default Flip

- **Goal:** Pass the full automated test suite and the signed-in Owner Acceptance Checklist (§7), resolve any real-world edge cases, flip `enableNativeUI` default to `true`, update documentation, and prepare `v2.0.0`.
- **Touched Areas:**
  - `LiteGemini/SettingsManager.swift` (flip `Defaults.enableNativeUI = true`; rename setting label from `"Enable Native UI (Experimental)"` to `"Use Native Interface"` while keeping Classic Web Mode one click away in `View` menu)
  - `README.md` & `README_CN.md`
  - `docs/specs/v2-native-ui.md` (mark complete)
- **Requirements:**
  1. Run all headless harnesses (`dltest2`, `routertest`, `tempchattest`, `cachetest`, `urlhandofftest`, `bridgetest`, `markdowntest`, `composertest`, `drivertest`, `quickmodetest`) and a clean Universal Release build before handing the build to the owner.
  2. Hand over `/tmp/lg-build/Build/Products/Release/Lite Gemini.app` to the owner to run **§7 Owner Acceptance Checklist** in a single signed-in session; inspect `os.Logger` categories (`GeminiBridge`, `NewWindow`, `TemporaryChat`) afterward and fix any issues in dedicated commits.
  3. Once the owner approves, flip `Defaults.enableNativeUI = true`, update `README.md` and `README_CN.md` for v2.0, mark all tickets `done` in this spec, and follow the release procedure (only pushing/tagging upon explicit owner approval).
- **Commit:** `feat: enable Native Liquid Glass UI by default for v2.0`

---

## 7. Owner Acceptance Checklist for v2.0 (Executed in T11)

The owner runs these checks signed in on the Release Universal build. The agent never launches the app directly.

- **Auth & Accounts**
  - **V2-1** Clear browsing data in Settings: Native Mode immediately displays the Liquid Glass Welcome screen and `Cache/v2/` on disk is empty.
  - **V2-2** Click "Sign in with Google": `PopupWindowController` opens, sign-in completes, popup closes automatically, and Native Mode unlocks showing the signed-in account pill.
  - **V2-3** Click Account Pill → "Add Another Account…": sign in to a second Google account; switch between Account 0 and Account 1 from the Account Pill. Recent Chats and cached conversations stay strictly separated per account.
- **Core Chat, Markdown & Thinking**
  - **V2-4** Send a prompt asking for headings, nested lists, a Markdown table, inline `$E=mc^2$` math, and a fenced Swift code block: streams at 120Hz with zero stutter; code block Copy button copies exact code.
  - **V2-5** Select a Thinking/Pro model from the composer's Model Picker and send a reasoning prompt: live thinking streams inside the collapsible disclosure view, then collapses cleanly when the final answer streams; model actually used matches selection.
  - **V2-6** Click **Stop** mid-stream: generation halts immediately without hanging or corrupting the conversation.
  - **V2-7** Press `↑` in an empty composer (or click Edit on the last user message), modify the prompt, and submit: previous reply is replaced and the new reply streams cleanly.
  - **V2-8** Click **Regenerate** on the latest assistant reply: a fresh response replaces it cleanly.
- **IME, Attachments & Rich Content**
  - **V2-9** Type Chinese with macOS Pinyin IME (confirming candidates with Space, number keys, and raw-English Enter), both with and without an image attached in the composer: candidate confirmation **never** accidentally sends; first real `Enter` after composition sends immediately; `Shift+Enter` inserts a newline.
  - **V2-10** Take a screenshot to clipboard and press `Cmd+V` in the native composer, then attach a second file via `+`: preview chips appear, prompt sends with attachments, and Gemini answers about the image/file.
  - **V2-11** Drag a folder onto the composer: banner offers one-click switch to Web Mode.
  - **V2-12** Ask Gemini to generate an image (or display an inline image): image renders in the native bubble and clicking Download saves it to `~/Downloads` with the top download notice + Finder reveal.
  - **V2-13** Trigger a Canvas or Deep Research response: Native Mode displays a Liquid Glass artifact card; clicking **"Open in Web Mode"** switches to Classic WebView on that exact `/app/<id>` conversation.
- **Recent Chats, Cache, Dual-Mode & Privacy**
  - **V2-14** Open **Recent Chats** popover in the top bar and switch among 3 existing conversations: first load fetches and caches; revisiting a cached conversation renders in 0ms and silently refreshes if modified on another device.
  - **V2-15** Switch `Native → Web`, send one follow-up turn inside Web Mode, then switch `Web → Native`: Native Mode reloads `/app/<id>`, displays the new turn from Web Mode, and updates the local snapshot.
  - **V2-16** Turn on **Temporary Chat** (both manually and via `New Chats Start as Temporary Chats` setting), send a message, then start a new chat: zero snapshot files are written to `Cache/v2/` for the temporary session, and it never appears in Recent Chats.
  - **V2-17** Resize the window down to `360 × 400`, toggle Light/Dark appearance, test global hotkeys (`Ctrl+\`` show/hide with auto-focus into native composer, `Cmd+Shift+N` new chat), and switch app language to Simplified Chinese (`zh-Hans`): all controls remain usable, unclipped, and fully translated.
- **Quick Mode (`⌥Space` / `⌥⇧Space`)**
  - **V2-18** Right after launching the app (cold launch), press `⌥⇧Space`: automatically falls back to opening a new floating Quick Bar (`[ (+)  Ask anything…  Model ▾  (↑) ]`). Type half a sentence, click on the desktop outside to dismiss, then press `⌥Space`: the floating Quick Bar reappears with the exact unsent draft preserved.
  - **V2-19** Open `Model ▾` on the Quick Bar and toggle the top-right **Temp** switch ON, then send the message: the bar expands upward into the minimalist Quick Mini-Window (top-left traffic lights + top-right `+` button only; no `Recent`, `Avatar`, or toolbar `Temp`). Click on the desktop outside: the expanded Quick Mini-Window stays open until closed explicitly via the red traffic light button or `Cmd+W`.
  - **V2-20** After closing the expanded Quick Mini-Window, press `⌥⇧Space` to verify the recent Quick conversation reopens intact; then press `⌥Space` (or click `+`) to open a fresh Quick Bar and confirm the **Temp** switch inside `Model ▾` remembered its ON state.
