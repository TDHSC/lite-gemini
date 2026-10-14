# Implementation plan: catch up with the current Gemini web app

Status: Phase A (A1–A5) shipped in v0.4.1 on 2026-10-13. Phase B accepted by the owner;
Phase C (default temporary chat) in progress. v0.4.2 will ship B and C together. Written
2026-10-13.

This plan is for an implementer who does not know the codebase. Follow it top to bottom,
one task at a time. Every task says which files to touch, where, which Apple APIs to use,
what the logic must do, which traps to avoid, how to verify, and what the commit must say.
It describes the behavior; it does not give finished code. When something in reality
contradicts this plan (an API behaves differently, a test fails for a reason not listed),
stop and report instead of improvising.

---

## 0. Ground rules

### 0.1 Environment

- macOS 27, Xcode 27.0 at `/Applications/Xcode.app`. `xcode-select` points at the Command
  Line Tools, so every shell that runs `xcodebuild`, `swiftc`, or `xcrun` must first run
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Debug build:
  `xcodebuild -project LiteGemini.xcodeproj -scheme "Lite Gemini" -configuration Debug -derivedDataPath /tmp/lg-build build`
- Release universal build, the same flags CI uses:
  `xcodebuild -project LiteGemini.xcodeproj -scheme "Lite Gemini" -configuration Release -derivedDataPath /tmp/lg-build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" clean build`
- "Zero warnings" check: pipe the build output through `grep -E "(warning|error):"`.
  - The only allowed line is the tool message
    `appintentsmetadataprocessor ... warning: Metadata extraction skipped`.
  - Every other warning or error must be fixed before committing.
- Built app: `/tmp/lg-build/Build/Products/<Config>/Lite Gemini.app`.

### 0.2 Project facts you must respect

- **File membership is automatic.** The target uses Xcode file-system-synchronized folders
  (`objectVersion = 77`).
  - Any file created inside `LiteGemini/` is automatically compiled or bundled.
  - Do not add `PBXFileReference` or `PBXBuildFile` entries by hand.
  - `LiteGemini/Info.plist` is deliberately excluded through a
    `PBXFileSystemSynchronizedBuildFileExceptionSet`. Do not touch that.
- **Concurrency settings.** Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
  - Every new type is main-actor isolated unless marked otherwise. That is what we want:
    all WebKit and AppKit delegate work happens on the main actor.
  - When the compiler complains that an AppKit completion closure is not isolated, wrap the
    closure body in `MainActor.assumeIsolated { ... }`. This is the pattern already used in
    `AppDelegate.windowShouldClose` and `HotKeyManager`.
  - Never silence concurrency diagnostics with `@unchecked Sendable`, `nonisolated(unsafe)`,
    or `@preconcurrency`.
- **Style.** Match the surrounding code:
  - `// MARK: - Section` headers.
  - `///` doc comment on every new property and method.
  - English comments.
  - Four-space indentation.
  - Delegate methods grouped under the matching MARK section.
- **Completion-handler delegate variants.** WebKit delegate methods exist in a completion
  handler form and an `async` form in Swift. Use the completion-handler form everywhere,
  matching the existing file. Never implement both forms of the same method. Every
  completion or decision handler must be called exactly once on every code path,
  including early returns.
- **Localization.**
  - Every new user-visible string needs an entry in `LiteGemini/Localizable.xcstrings`
    with a `zh-Hans` value in state `translated`.
  - `xcodebuild` does not add new keys to the catalog (only the Xcode IDE does), so add
    them by hand in the same JSON layout as existing entries: two-space indent,
    `" : "` separators, keys in alphabetical order.
  - A Swift string with interpolation, `String(localized: "Downloaded \(name)")`, has the
    catalog key `Downloaded %@`.
  - Info.plist strings go in `LiteGemini/InfoPlist.xcstrings` (task A2).
- **Do not touch:**
  - the IME fix script and console bridge in `WebViewModel.swift`
  - the User-Agent logic in `SettingsManager.swift`
  - Sparkle setup
  - `.github/workflows/*`
  - the app icon
  - `scripts/bump_version.sh`

### 0.3 Testing rules

- **Never launch the app on the owner's Mac** (no `open "Lite Gemini.app"`, no running the
  binary). It takes focus away from the owner. Anything that needs a real window or a
  signed-in Google account is done by the owner from the acceptance checklist in
  Appendix B.
- **Automated tests are headless harnesses** in `/tmp/lg-work/<name>/` (recipe in
  Appendix A). They compile real source files from `LiteGemini/` next to a throwaway
  `main.swift`. They are not committed.
- Harnesses may load `https://gemini.google.com` signed out for read-only checks. Never
  sign in, never submit prompts.

### 0.4 Git rules

- One branch per phase: `feat/web-capabilities` for Phase A, `feat/popup-windows` for
  Phase B. Branch from up-to-date `main`.
- One commit per task, in task order. Commit messages in English: a subject line, then a
  body covering what changed, why, and trade-offs. Each task lists what its body must
  mention.
- Do not push, merge, tag, publish a release, or comment on GitHub issues without the
  owner's explicit approval at that moment.

---

## 1. Background (why these tasks exist)

Checked 2026-10-13 against live gemini.google.com in a headless WKWebView with the app's
User-Agent, and against Gemini's current front-end bundles:

| Area | Finding |
|---|---|
| Still fine | Page loads; prompt box `rich-textarea [contenteditable="true"]` appears in ~1.6 s; home path `/app`; "Sign in" link uses `target=_top`. |
| Upload | Never worked. Apple: "By default on macOS, file uploads are disabled if you don't implement" `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`. Gemini uses hidden `<input type=file>` elements (`multiple`), and `webkitdirectory` for "Import code → Upload folder". |
| Dictation | Never worked. Gemini's Dictate button (Cmd+Shift+D) calls `navigator.mediaDevices.getUserMedia({audio})` (not Web Speech). WebKit refuses capture when the host app's Info.plist lacks `NSMicrophoneUsageDescription` (`checkUsageDescriptionStringForType` in `WebKit/UIProcess/Cocoa/MediaPermissionUtilities.mm`). |
| Downloads | Never worked. Gemini downloads by clicking a temporary `<a download>`. The URL is a blob URL, or on AppleWebKit a data URL made with FileReader. With the app's current delegates this silently does nothing (verified with a harness). |
| New chat | Gemini still registers Cmd+Shift+O. It picks Cmd vs Ctrl from `navigator.userAgent.toLowerCase().includes("mac")`, so a custom non-Mac UA silently breaks our hotkey. |
| Popups | `createWebViewWith` sends every new window to the default browser. That breaks adding a second Google account (issue #2) and connector OAuth flows. |

---

## Phase A (release v0.4.1): tasks A1–A4

Order: A1 → A2 → A3 → A4, one commit each, on branch `feat/web-capabilities`.

---

### A1. File uploads through the system open panel

**Goal.** "+" → Upload files / Upload images / Import code → Upload folder opens a
native macOS file dialog, and the chosen items are attached in Gemini.

**Files.** `LiteGemini/WebViewModel.swift` only.

**Where.** In the `// MARK: - WKUIDelegate` section, directly after the existing
`webView(_:createWebViewWith:for:windowFeatures:)` method.

**What to implement.** The `WKUIDelegate` method
`webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`
(macOS 10.12+, so no availability check is needed for our macOS 14 target).

Logic, in order:
1. Create an `NSOpenPanel`.
2. Copy `parameters.allowsMultipleSelection` to the panel's `allowsMultipleSelection`.
3. If `parameters.allowsDirectories` is true (the code-folder case): allow choosing
   directories and disallow choosing files. Otherwise allow files and disallow
   directories.
4. Do not set `allowedContentTypes`. The public API does not tell us the page's `accept`
   list.
5. If `webView.window` is non-nil, present the panel as a sheet on that window
   (`beginSheetModal(for:)`). Otherwise run it modally (`runModal()`).
6. When the panel ends: if the response is `.OK`, call the completion handler with
   `panel.urls`. For any other response, call it with `nil`.

**Traps.**
- The completion handler must be called exactly once, on Cancel too. If it is never
  called, the page's upload control stays stuck until reload.
- Do not enumerate directory contents yourself. Pass the directory URL and WebKit expands
  it.
- If the compiler reports an isolation problem inside the sheet completion closure, use
  `MainActor.assumeIsolated` (§0.2).

**Verification.**
- Debug build succeeds with zero new warnings.
- No automated test. Synthetic clicks do not reliably reach file inputs headlessly.
- Owner checks A1-1 … A1-4 in Appendix B.

**Done when** the build is clean and the owner's A1 checks pass.

**Commit.** Subject: `feat: support file uploads through the system open panel`. Body must
say:
- Apple disables WKWebView file uploads on macOS unless the UI delegate implements
  `runOpenPanel`, so the "+" menu upload items did nothing.
- Folder selection is enabled when the page asks for it (`webkitdirectory`, used by Import
  code).
- Trade-off: the panel cannot filter by file type because the public API does not expose
  `accept`. Gemini validates and rejects unsupported files itself.

---

### A2. Microphone access for Gemini's Dictate button

**Goal.** Clicking Dictate (or pressing Cmd+Shift+D) shows the macOS microphone prompt
once. After the user allows it, speech is transcribed into the prompt box.

**Files.**
- `LiteGemini.xcodeproj/project.pbxproj`: the two target build configurations only.
- New `LiteGemini/InfoPlist.xcstrings`.
- `LiteGemini/WebViewModel.swift`.

**Step 1: hardened-runtime microphone entitlement.**
- In `project.pbxproj`, change `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = NO;` to `YES;`.
  It appears in two target configurations: `272B661B2F3AFDA400EBF5DA /* Debug */` and
  `272B661C2F3AFDA400EBF5DA /* Release */`.
- Leave every other `ENABLE_RESOURCE_ACCESS_*` setting at `NO`. Do not edit
  `LiteGemini.entitlements`.
- Verified on 2026-10-13: with this setting, Xcode adds
  `com.apple.security.device.audio-input` to the signed entitlements.
- Why it matters: local builds use the hardened runtime, which silently denies the
  microphone without this entitlement.

**Step 2: usage description.**
- In the same two configurations, add a build setting next to
  `INFOPLIST_KEY_NSHumanReadableCopyright`:
  `INFOPLIST_KEY_NSMicrophoneUsageDescription = "Lite Gemini uses the microphone when you dictate a prompt to Gemini.";`
- `GENERATE_INFOPLIST_FILE = YES` merges it into the built Info.plist.
- The string must be non-empty. WebKit denies capture when it is missing or empty.

**Step 3: Chinese translation of the usage description.**
- Create `LiteGemini/InfoPlist.xcstrings`. It is a String Catalog with the same JSON
  layout as `Localizable.xcstrings`: `"sourceLanguage" : "en"`, `"version" : "1.0"`.
- It holds one key, `NSMicrophoneUsageDescription`, with two localizations:
  - `en`: the English text from step 2.
  - `zh-Hans`, state `translated`: `当你向 Gemini 语音输入时，Lite Gemini 需要使用麦克风。`
- Verified on 2026-10-13: this produces
  `Contents/Resources/zh-Hans.lproj/InfoPlist.strings` in the built app.

**Step 4: grant the page's microphone request.**
- In `WebViewModel.swift`, in the `// MARK: - WKUIDelegate` section after the A1 method,
  implement `webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)`
  (macOS 12+, no availability check needed).
- Decide as follows:
  - **Grant** (`.grant`) only when all three hold:
    - the origin's protocol is `https`
    - the origin's host is exactly `gemini.google.com`
    - the type is exactly `.microphone`
  - **Deny** (`.deny`) everything else: `.camera`, `.cameraAndMicrophone`, and any other
    host.
- Why grant instead of leaving the default: if the method is not implemented, WebKit
  answers `.prompt`, which shows a WebKit permission dialog every session on top of the
  system prompt.

**Traps.**
- `WKSecurityOrigin`'s scheme property is named `protocol`, which is a Swift keyword. Write
  it with backticks.
- Compare the host with `==`. Do not use `hasSuffix("google.com")`: it would also match
  any `*.google.com` page opened later in a popup.
- Implement only this completion-handler form, not the `async` variant named
  `webView(_:decideMediaCapturePermissionsFor:initiatedBy:type:)`.

**Verification (automated, after a Debug build).**
- `plutil -p "<app>/Contents/Info.plist" | grep NSMicrophoneUsageDescription` prints the
  English text.
- `plutil -p "<app>/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"` prints the
  Chinese text.
- `codesign -d --entitlements - --xml "<app>" | plutil -p -` lists
  `com.apple.security.device.audio-input => true`.

**Verification (owner).** A2-1 … A2-4 in Appendix B.

**Release-build note.** CI re-signs the app with `codesign --deep --force --sign -`, which
drops entitlements and the hardened runtime. That is acceptable here: without the hardened
runtime no entitlement is needed, and the Info.plist key is what matters. Check that key
on the CI-built DMG during release (§R step 8).

**Commit.** Subject: `feat: let Gemini's Dictate button use the microphone`. Body must say:
- WebKit refuses `getUserMedia` audio when the app has no `NSMicrophoneUsageDescription`,
  so Dictate never worked.
- What was added: the usage string (en and zh-Hans), the audio-input resource access for
  hardened-runtime builds, and the permission delegate.
- Trade-offs:
  - Microphone requests from gemini.google.com are granted without WebKit's extra
    per-session prompt. The one-time macOS prompt and the recording indicator remain.
  - Release builds are ad-hoc signed, so macOS may ask for microphone permission again
    after each update. Only Developer ID signing avoids this.

---

### A3. Downloads saved to ~/Downloads

**Goal.** When Gemini triggers a download (generated image, exported file), it is saved
to `~/Downloads` without overwriting existing files. The user sees a short in-window
notice with "Show in Finder", and the Dock's Downloads stack bounces.

**Files.**
- New `LiteGemini/DownloadManager.swift`.
- `LiteGemini/WebViewModel.swift`.
- `LiteGemini/ContentView.swift`.
- `LiteGemini/Localizable.xcstrings`.

**Step 1: `DownloadManager.swift` (new).** It contains two types.

`DownloadNotice` is a small value type describing one notice:
- a unique `id` (UUID), used so the view can restart its auto-dismiss timer
- `message: String` (already localized)
- `fileURL: URL?` (present on success, used by "Show in Finder")
- `isError: Bool`

`DownloadManager` is a `final class` inheriting `NSObject` and conforming to
`WKDownloadDelegate`.
- **Stored state:**
  - `destinationDirectory: URL`, passed to `init`. The default argument is the user's
    Downloads folder from `FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)`.
    The parameter exists so the harness can pass a temporary directory.
  - A dictionary from `ObjectIdentifier(download)` to the destination URL chosen for that
    download.
  - `onNotice: ((DownloadNotice) -> Void)?`, a callback the owner sets.
- **Two static policy helpers**, so the decision logic is testable and `WebViewModel`
  stays thin:
  - **For a navigation action:** return `.download` when the action's
    `shouldPerformDownload` is true (this is the `<a download>` path Gemini uses).
    Otherwise return `.allow`.
  - **For a navigation response:** this helper takes plain values, not a
    `WKNavigationResponse`: a `URLResponse` and a `canShowMIMEType` Bool. `WebViewModel`
    passes `navigationResponse.response` and `navigationResponse.canShowMIMEType`. The
    harness can then test the header logic with hand-built `HTTPURLResponse` objects
    (case 6 below). It also takes `isForMainFrame: Bool`, which `WebViewModel` fills from
    `navigationResponse.isForMainFrame`. Return `.download` when either of these holds:
    - `canShowMIMEType` is false and the response is for the main frame. Unshowable
      subframe content (ads, widgets) must not land in ~/Downloads silently.
    - the response, in any frame, is an `HTTPURLResponse` whose `Content-Disposition`
      header, lowercased and trimmed, starts with `attachment`

    Otherwise return `.allow`.
- **`begin(_ download: WKDownload)`:** sets `download.delegate = self`. `WKDownload.delegate`
  is weak, which is why `WebViewModel` must keep the manager alive (step 2).
- **`download(_:decideDestinationUsing:suggestedFilename:completionHandler:)`:**
  1. Take the last path component of the suggested filename and trim whitespace. If the
     result is empty, use `download`.
  2. Build `destinationDirectory/<name>`. A name is taken if a file exists there **or** it
     is already reserved by another in-flight download in the dictionary. Two downloads
     with the same name can start before either file exists. If the name is taken, try
     `<base> (1).<ext>`, `<base> (2).<ext>`, and so on until a free name is found. Keep the
     extension; a name with no extension gets no dot. Stop after 1000 attempts and use a
     UUID-based name.
  3. Store the chosen URL in the dictionary and pass it to the completion handler.
     WebKit fails the download if the destination already exists, which is why step 2
     must find a free name.
- **`downloadDidFinish(_:)`:**
  1. Look up the stored URL and remove the dictionary entry.
  2. Post a distributed notification named `com.apple.DownloadFileFinished` with the file
     path as the object, via `DistributedNotificationCenter.default()`. This makes the
     Dock's Downloads stack bounce. It is undocumented but harmless if ignored.
  3. Call `onNotice` with a success notice. The message is
     `String(localized: "Downloaded \(fileName)")` and `fileURL` is set.
- **`download(_:didFailWithError:resumeData:)`:**
  1. Look up and remove the dictionary entry. If a partial file exists at that URL, delete
     it.
  2. If the error is `NSURLErrorCancelled`, stop: no notice.
  3. Otherwise call `onNotice` with an error notice. The message is
     `String(localized: "Download failed: \(error.localizedDescription)")`, `isError` is
     true, and `fileURL` is nil.

**Step 2: wire it into `WebViewModel.swift`.**
- **Properties** (under `// MARK: - Public Properties`):
  - `let downloadManager = DownloadManager()`
  - `@Published var downloadNotice: DownloadNotice?`
- **In `init`,** right after the existing `webView.navigationDelegate = self` and
  `webView.uiDelegate = self` lines, set `downloadManager.onNotice` to a closure that
  captures `self` weakly and assigns the notice to `downloadNotice`.
- **New `WKNavigationDelegate` methods** in the `// MARK: - WKNavigationDelegate` section,
  all in completion-handler form:
  - `webView(_:decidePolicyFor:decisionHandler:)` for `WKNavigationAction`: call the
    decision handler with the manager's action-policy helper.
  - `webView(_:decidePolicyFor:decisionHandler:)` for `WKNavigationResponse`: call the
    decision handler with the manager's response-policy helper.
  - `webView(_:navigationAction:didBecome:)` and `webView(_:navigationResponse:didBecome:)`:
    both call `downloadManager.begin(download)`.
- **Fix the existing error handlers.** When a navigation turns into a download, WebKit
  fails that navigation with domain `WebKitErrorDomain` and code 102
  (`WebKitErrorFrameLoadInterruptedByPolicyChange`). Today `didFail` and
  `didFailProvisionalNavigation` only ignore `NSURLErrorCancelled`, so the user would see
  the "Unable to connect to Gemini" overlay after every download. Extend both ignore
  conditions to also skip that domain and code. Keep `isLoading = false` in both handlers
  as today.

**Traps.**
- **Everything else must stay `.allow`.** Today no `decidePolicyFor` exists, so WebKit
  allows everything. Your implementation must keep allowing every non-download
  navigation, or Gemini stops loading.
- **One form only.** Implement only the completion-handler forms. Implementing the
  `async` form as well makes Swift report ambiguity.
- **No new branches for `target=_blank`.** Those links do not reach `decidePolicyFor` on
  the main view; they go through `createWebViewWith`, which A3 does not change.

**Step 3: the notice in `ContentView.swift`.**
- Add a new layer to the existing `ZStack`, after the error overlay so it draws on top.
  It is shown only when `viewModel.downloadNotice` is non-nil.
- Position it at the top center with about 12 pt padding. It must not cover the prompt
  box, which sits at the bottom.
- Content, in one row:
  - **Icon:** an SF Symbol, `arrow.down.circle.fill` for success or
    `exclamationmark.triangle.fill` for an error.
  - **Message:** the notice's text.
  - **Button:** when `fileURL` is present, a "Show in Finder" button that calls
    `NSWorkspace.shared.activateFileViewerSelecting` with that URL.
  - **Background:** `.regularMaterial` in a rounded rectangle, with a light shadow.
- Auto-dismiss: attach `.task(id: notice.id)` that sleeps 4 seconds and then, if
  `viewModel.downloadNotice?.id` still equals that id, sets it to nil. Using `.task(id:)`
  cancels the old timer when a newer notice replaces it.
- Animate appearance and disappearance with a move-from-top plus opacity transition.

**Step 4: strings.** Add these three keys to `Localizable.xcstrings`, zh-Hans state
`translated`:

| Key | zh-Hans |
|---|---|
| `Downloaded %@` | `已下载 %@` |
| `Download failed: %@` | `下载失败：%@` |
| `Show in Finder` | `在访达中显示` |

**Automated verification: harness `dltest2`** (Appendix A recipe).
- Compile the real `LiteGemini/DownloadManager.swift` with a test `main.swift`.
- The test creates a headless `WKWebView` (non-persistent store) whose navigation
  delegate does only what `WebViewModel` does:
  - calls the two static policy helpers
  - calls `begin` in both `didBecome` methods
  - records the domain and code of any provisional-navigation error
- Use a `DownloadManager` whose destination is a fresh temporary directory.
- Serve test content through a `WKURLSchemeHandler` registered for a custom scheme (for
  example `lgtest`), so no network is needed.

Cases and expected results:

| # | Action | Expected |
|---|---|---|
| 1 | Page at `lgtest://app/` creates a blob of `hello`, clicks `<a download="note.txt">` | `note.txt` exists with content `hello` |
| 2 | Same as 1 again | `note (1).txt` exists; `note.txt` unchanged |
| 3 | Page clicks `<a download="image.png">` whose href is a data URL of a 1×1 PNG | `image.png` exists and starts with the PNG signature bytes |
| 4 | Main frame navigates to `lgtest://app/report.txt`, served as `application/octet-stream` | The web view still shows the previous page. The recorded provisional error is `WebKitErrorDomain` / 102. Make no assertion about a file, either way (see the note below) |
| 5 | Main frame navigates to `lgtest://app/page`, served as `text/html` | Page is displayed, no file is created |
| 6 | No web view: call the response-policy helper directly with hand-built responses | See the list below |
| 7 | Main frame navigates to a `data:application/octet-stream;base64,…` URL whose content is `report` | Exactly one new file appears in the destination with content `report`. Don't check its name: WebKit suggests `Unknown` for a nameless data URL. The web view still shows the previous page. The recorded provisional error, if any, is `WebKitErrorDomain` / 102 |

Case 6 inputs and expected policies:
- `HTTPURLResponse` with `Content-Disposition: attachment; filename="a.txt"`,
  `canShowMIMEType` true → `.download`
- header `Attachment; filename="a.txt"` (capital A) → `.download`
- header `  attachment` (leading spaces) → `.download`
- header `inline; filename="a.pdf"`, `canShowMIMEType` true → `.allow`
- `HTTPURLResponse` with no `Content-Disposition`, `canShowMIMEType` true → `.allow`
- `HTTPURLResponse` with no `Content-Disposition`, `canShowMIMEType` false → `.download`
- plain `URLResponse` (not HTTP), `canShowMIMEType` true → `.allow`
- subframe, no `Content-Disposition`, `canShowMIMEType` false → `.allow`
- subframe, `Content-Disposition: attachment`, `canShowMIMEType` true → `.download`

Case 8: in one JavaScript turn, click two `<a download="same.txt">` links with different
blob contents. Expect `same.txt` and `same (1).txt` with the two contents, and no error
notice.

Two WebKit limitations shape cases 4, 6 and 7. Both were confirmed during implementation on
2026-10-13.
- **Custom-scheme headers are dropped.** For non-http(s) schemes, WebKit rebuilds the
  response handed to `decidePolicyFor navigationResponse` as a plain `NSURLResponse`
  without headers (`ResourceResponse::initNSURLResponse` in WebKit's
  `ResourceResponseCocoa.mm`). A custom-scheme harness can never deliver a
  `Content-Disposition` header, so case 6 covers the header branch instead. Real
  `https://` responses keep their headers.
- **Custom-scheme responses never become downloads.** A custom-scheme response that gets
  the `.download` policy never produces a `WKDownload`, because the download machinery
  cannot re-fetch a resource served by a `WKURLSchemeHandler`. So case 4 only checks that
  the conversion leaves the page in place and reports code 102. Case 7 exercises the full
  response → `WKDownload` → file path with a data URL. Gemini itself downloads through
  `<a download>` (cases 1–3), not through this path.

- Print one `PASS` or `FAIL` line per case and exit non-zero on any failure.
- If case 3 fails (data URLs not downloadable through WKDownload), stop and report. Do not
  write a custom data-URL decoder without approval.

**Other verification.**
- Debug and Release builds are clean.
- `plutil -p "<app>/Contents/Resources/zh-Hans.lproj/Localizable.strings"` contains the
  three new keys.
- Owner checks A3-1 … A3-4.

**Commit.** Subject: `feat: save web downloads to the Downloads folder`. Body must say:
- Gemini downloads through `<a download>` with blob or data URLs. Without download
  handling WebKit dropped them silently.
- What was added: the policy rules, where files go, and how name clashes are resolved.
- Code 102 errors are now ignored, so a download no longer shows the network-error
  overlay.
- Trade-offs:
  - Files go straight to `~/Downloads` with no save dialog.
  - The Dock bounce uses an undocumented notification.

---

### A4. New-chat hotkey fallback

**Goal.** The global new-chat hotkey always ends on a fresh chat, even if Gemini ignores
the synthetic Cmd+Shift+O. That happens with a custom non-Mac User-Agent, or if Google
changes the shortcut.

**Files.**
- `LiteGemini/HotKeyManager.swift`.
- `LiteGemini/WebViewModel.swift`.

**Current flow.** `HotKeyManager.onNewChatHotKeyPressed()` shows the window if needed,
waits 0.2 s, and calls `sendCmdShiftO()`. That function builds Cmd+Shift+O with `CGEvent`
and sends it to the key window. `HotKeyManager` has no access to the web view, so it
cannot check the result.

**Step 1: notification name.** In `WebViewModel.swift`, add `newChatRequested` next to the
existing `Notification.Name.browsingDataCleared` extension, with a `///` comment.

**Step 2: `HotKeyManager.swift`.**
- In `onNewChatHotKeyPressed()`, replace both calls to `sendCmdShiftO()` with posting
  `.newChatRequested` on `NotificationCenter.default`.
- Keep the visibility check, `showWithAnimation`, and the 0.2 s delay exactly as they are.
- Delete `sendCmdShiftO()`; it moves to `WebViewModel`. If `import Carbon` is still needed
  for the hotkey APIs, keep it.

**Step 3: `WebViewModel.swift`.**
- **Observe.** In `init`, observe `.newChatRequested` the same way `.browsingDataCleared`
  is observed: selector-based, with a private `@objc` handler.
- **Property.** Add `private var newChatFallbackTask: Task<Void, Never>?` with a doc
  comment, next to the other task properties.
- **Deinit.** Cancel it in `isolated deinit`, like the other tasks.
- **Handler logic:**
  1. If `webView.url` is nil, load `Constants.geminiURL` and stop.
  2. Remember the current URL path as `pathBefore`. Compare paths only, never full URLs,
     because query strings change.
  3. Ask `webView.window` to make `webView` the first responder, then send Cmd+Shift+O to
     that window. Reuse the event-building approach of the deleted `sendCmdShiftO()`:
     - key code `0x1F`, with a comment saying it is the O key, matching how `sendEnterKey`
       writes `0x24`
     - flags Command + Shift
     - key down, then key up, both through `window.sendEvent`

     If there is no window, skip sending and go straight to the fallback check.
  4. Cancel any previous `newChatFallbackTask`. Start a new task that:
     - sleeps 1 second
     - returns if cancelled
     - reads the path again; if `pathBefore` is not `/app` and the path is unchanged,
       loads `Constants.geminiURL`

**Traps.**
- Do not fall back when `pathBefore` is `/app`. The user is already on a fresh chat, and
  the shortcut legitimately changes nothing.
- Gemini changes the URL with `history.pushState`. `webView.url` reflects that, so no
  JavaScript is needed.
- Do not look up the "New chat" button by its label. Labels are localized (Chinese UI),
  and Google's internal test IDs are not stable.

**Verification.**
- Builds are clean.
- Owner checks A4-1 … A4-3. No automated test: synthetic key delivery needs a real key
  window.

**Commit.** Subject: `fix: make the new-chat hotkey fall back to loading /app`. Body must
say:
- Gemini maps the shortcut to Cmd or Ctrl based on whether the UA contains "mac". A custom
  non-Mac UA, or a future shortcut change, made the hotkey do nothing.
- The logic moved into `WebViewModel` because it needs the web view's URL.
- Trade-off: the fallback is a full page load (about 1–2 s), used only when the shortcut
  had no effect.

---

### A5. IME commits must never send the prompt (found in owner acceptance)

**Bug.** With an attachment in the composer, choosing a Chinese IME candidate sends the
message immediately. Without attachments, everything works.

**Cause.** `imeFixScript` in `WebViewModel.swift` (upstream code) dispatches a synthetic
**Enter** keydown/keyup 50 ms after every `compositionend`.
- Gemini's Safari path deliberately swallows the next Enter after `compositionend`, and the
  synthetic Enter exists to use up that swallow, so the user's next real Enter sends on the
  first press.
- Whenever Gemini's swallow is not armed, as observed with attachments, the synthetic Enter
  is handled as a real Enter and submits.

How Gemini's swallow works (current bundles, checked 2026-10-13):
- The composer's `compositionend` handler sets a "swallow next Enter" flag only when the
  UA is Safari.
- The composer's keydown handler clears that flag on **any** keydown, and if that keydown
  is a plain Enter it calls `preventDefault` and returns without submitting.

**Fix.** Replace the synthetic Enter with a synthetic **Shift** keydown/keyup.
- Event properties: `key: "Shift"`, `code: "ShiftLeft"`, `keyCode: 16`, `which: 16`,
  `shiftKey: true` on keydown, `bubbles: true`, `cancelable: true`.
- Why Shift: any keydown clears Gemini's flag, so the user's next Enter still sends on the
  first press. Shift can never submit in any Gemini path, and Gemini's composer explicitly
  treats Shift as a no-op key.

Keep these parts of the script unchanged:
- the 50 ms delay
- cancelling the timer when a trusted Enter keydown arrives within 50 ms (confirm-with-Enter)
- the `isComposing` re-send fix

Then clean up what only existed for the synthetic Enter:
- Remove the `syntheticEnterInFlight` flag. A Shift keydown already exits the Enter
  listeners early, because they return for non-Enter keys and for `shiftKey`.
- Update the comments and `[IME Debug]` messages to say "synthetic Shift", and explain why
  a synthetic Enter must never be used.

**Verification, automated.** Write harness `imetest2`. Start from the template at
`/tmp/lg-work/imetest/main.swift`, which already:
- loads signed-out Gemini with the app's UA
- swaps `requestAnimationFrame` for a 16 ms timer, because headless web views never run
  animation frames and Gemini clears its composition state in one
- intercepts `StreamGenerate` XHR/fetch, so nothing is sent and each attempt counts as a
  submit
- simulates IME commits with `compositionstart`/`compositionend` on the prompt editor

The harness must also inject the **real** `imeFixScript`. Read `LiteGemini/WebViewModel.swift`
at runtime and extract the text between `imeFixScript = """` and the closing `"""`. Inject it
at document start, like the app does.

Count page-level Enter keydowns with a document capture listener added **before** the IME
script (`e.key === "Enter"`). Cases:

| # | Steps | Expected |
|---|---|---|
| 1 | type text, plain Enter | submits = 1 |
| 2 | type text, IME commit, wait 1500 ms | submits = 0, and no Enter keydown reached the page |
| 3 | type text, IME commit, wait 300 ms, one Enter | submits = 1 after the Enter (first press sends) |
| 4 | same as 3 but with the old script from `main` (synthetic Enter) | submits = 1 after the Enter, and case 2 on the old script shows one synthetic Enter keydown reached the page. This documents the old behavior. |

**Verification, owner.** Repeat each check with an attachment in the composer and without:
- Pick a candidate with Space: no send. Then press Enter once: it sends.
- Pick a candidate with a number key: same result.
- If the IME confirms raw letters with Enter, that Enter does not send.
- English text plus Enter sends. Shift+Enter inserts a newline.

**Commit.** Subject: `fix: stop IME candidate commits from sending the prompt`. Body must say:
- the bug and why the synthetic Enter submitted whenever Gemini's swallow was not armed
- why Shift clears the swallow but can never submit
- the harness cases
- Trade-off: the fix still depends on Gemini clearing its swallow flag on any keydown. If
  Gemini changes that, the failure mode is "press Enter twice", not "accidental send".

---

### Phase A completion

1. All four commits are on `feat/web-capabilities`.
2. The Release universal build is clean, and the `dltest2` harness passes.
3. The owner runs the Phase A checklist (Appendix B). Fix failures with new commits.
4. Follow the release procedure (§R) for version `0.4.1`.

---

## Phase B (release v0.4.2): popups and multiple accounts (issue #2)

Branch `feat/popup-windows` from the local `main`, which already contains this plan.

**Owner availability (decided 2026-10-13).** The owner tests only once, after the whole
phase is finished and reviewed.
- Implement B1–B4 in one go. Do not stop for an owner logging session.
- B2's rules are therefore designed from what can be known without a signed-in session.
- B1's log lines stay in the product. During the final acceptance they show what any
  misrouted flow actually requested, so the rules can be adjusted.

---

### B1. Log new-window requests

**Goal.** Record every new-window request, so that any flow the routing gets wrong can be
diagnosed from the logs during acceptance and later.

**Files.** `LiteGemini/WebViewModel.swift`.

**What to implement.**
- Add `import os`. Add a private static `Logger` with subsystem
  `io.github.tdhsc.LiteGemini` and category `NewWindow`.
- At the top of `webView(_:createWebViewWith:for:windowFeatures:)`, before the existing
  behavior, emit one `.notice`-level entry containing:
  - the target URL's scheme, host, and path. Mark these `privacy: .public`. Never log the
    query or fragment, because they can contain tokens and email addresses.
  - `navigationAction.navigationType`, as a readable name
  - `windowFeatures.width` and `windowFeatures.height`, or `nil`
  - the source frame's host and whether it is the main frame
- Use `.notice`, not `.info` or `.debug`. Lower levels are not persisted, and the logs are
  read after the owner's acceptance session.
- B4 adds the chosen route to the same log line, so one entry shows both the request and
  the decision.
- The existing behavior (open in the default browser) stays unchanged in this commit.

**Reading the logs** (coordinator, during or after the final acceptance):
`log show --last 60m --style compact --predicate 'subsystem == "io.github.tdhsc.LiteGemini" AND category == "NewWindow"'`

**Commit.** Subject: `chore: log new-window requests`. Body must say:
- why: to diagnose popup routing from real signed-in flows, which cannot be reproduced
  headlessly
- what is logged, and that query strings are never logged
- why the level is `.notice`

---

### B2. Routing rules as a pure function

**File.** New `LiteGemini/NewWindowRouter.swift`.

**Types.**
- `NewWindowRoute`, an enum with four cases:
  - `mainWebView(URL)`: load it in the main view
  - `popup`: open an in-app popup window
  - `externalBrowser(URL)`: hand it to the default browser
  - `ignore`
- `PopupNavigationDecision`, an enum for main-frame navigations inside a popup:
  - `allow`
  - `moveToMain(URL)`
  - `moveToBrowser(URL)`
- `NewWindowRouter`, a caseless enum used as a namespace, with three static functions.
  Their inputs are plain values, so tests do not need WebKit objects, which cannot be
  constructed by hand:
  - `route(url: URL?, isLinkActivated: Bool, hasExplicitSize: Bool) -> NewWindowRoute`
  - `isAccountFlow(initialURL: URL?, hadExplicitSize: Bool) -> Bool`
  - `routeInsidePopup(url: URL, openedForAccount: Bool, startedBlank: Bool, isFirstNavigation: Bool, hadExplicitSize: Bool) -> PopupNavigationDecision`

**`route` rules.** First match wins. Compare hosts and paths case-insensitively. These
rules are designed without signed-in logs (see the Phase B intro); B1's logs are used to
adjust them if acceptance finds a misrouted flow.

| # | Condition | Result |
|---|---|---|
| 1 | URL is nil or `about:blank` | `popup`. A script will navigate it later; `routeInsidePopup` decides then. |
| 2 | Scheme is `javascript` | `ignore` |
| 3 | Scheme is not `http`/`https` (`mailto:`, `tel:`, …) | `externalBrowser` |
| 4 | Host is `gemini.google.com` | `mainWebView` (account switching with `?authuser=N`, chat links) |
| 5 | Host is `accounts.google.com` | `popup` (add account, re-auth, Google OAuth) |
| 6 | Not `isLinkActivated`, and either `hasExplicitSize` or the path contains `oauth` or `authorize` | `popup` (a script-opened OAuth window; some OAuth popups are opened without a size) |
| 7 | Anything else | `externalBrowser` (answer links, citations, store links) |

**`isAccountFlow` rule.** True only when all three hold:
- the initial URL's host is `accounts.google.com`
- `hadExplicitSize` is false
- the path does not contain `oauth`

Why: the account menu's "Add another account" is a plain link without a size, while
connector sign-ins use OAuth paths such as `/o/oauth2/...` and `/signin/oauth/...`. An
OAuth popup must never be treated as an account flow: rule 1 below would pull its Gemini
callback into the main view and break the handshake with the page that opened it.

**`routeInsidePopup` rules.** First match wins.

| # | Condition | Result |
|---|---|---|
| 1 | `openedForAccount`, host is `gemini.google.com`, and the path is `/` or starts with `/app` or `/gem` | `moveToMain`. The add-account flow finished and returned to Gemini. |
| 2 | `startedBlank` and `isFirstNavigation` and not `hadExplicitSize`, host is `accounts.google.com` | `allow` |
| 3 | `startedBlank` and `isFirstNavigation` and not `hadExplicitSize`, host is `gemini.google.com` | `moveToMain` |
| 4 | `startedBlank` and `isFirstNavigation` and not `hadExplicitSize`, any other host | `moveToBrowser` (for example Export to Docs) |
| 5 | Anything else | `allow`. OAuth popups wander across hosts and then close themselves. |

**Test harness `routertest`** (Appendix A). Compile the real `NewWindowRouter.swift`. Each
case prints `PASS`/`FAIL`; any failure exits non-zero.

| Input | Expected |
|---|---|
| `https://gemini.google.com/app?authuser=1`, link, no size | `mainWebView` |
| `https://accounts.google.com/AddSession?x=y`, link, no size | `popup` |
| `https://accounts.google.com/o/oauth2/v2/auth?x=y`, script, size | `popup` |
| `https://github.com/login/oauth/authorize?x=y`, script, size | `popup` |
| `https://github.com/login/oauth/authorize?x=y`, script, no size | `popup` |
| `https://example.com/login`, script, no size | `externalBrowser` |
| `https://example.com/oauth/start`, link, no size | `externalBrowser` (a clicked link is never an OAuth popup) |
| `https://en.wikipedia.org/wiki/Gemini`, link, no size | `externalBrowser` |
| `https://docs.google.com/document/d/abc`, script, no size | `externalBrowser` |
| nil, script, size | `popup` |
| `about:blank`, script, no size | `popup` |
| `mailto:someone@example.com`, link, no size | `externalBrowser` |
| `javascript:void(0)`, link, no size | `ignore` |
| isAccountFlow: `https://accounts.google.com/AddSession?x=y`, no size | true |
| isAccountFlow: `https://accounts.google.com/o/oauth2/v2/auth?x=y`, no size | false |
| isAccountFlow: `https://accounts.google.com/signin/oauth/consent?x=y`, no size | false |
| isAccountFlow: `https://accounts.google.com/AddSession?x=y`, size | false |
| isAccountFlow: nil | false |
| inside popup: account flow → `https://gemini.google.com/app?authuser=1` | `moveToMain` |
| inside popup: account flow → `https://gemini.google.com/` | `moveToMain` |
| inside popup: account flow → `https://gemini.google.com/_/callback` | `allow` |
| inside popup: sized OAuth → `https://gemini.google.com/oauth/callback` | `allow` |
| inside popup: blank, first nav, no size → `https://docs.google.com/document/d/abc` | `moveToBrowser` |
| inside popup: blank, first nav, no size → `https://accounts.google.com/x` | `allow` |
| inside popup: blank, first nav, sized → `https://github.com/login/oauth/authorize` | `allow` |
| inside popup: not first nav, no size → `https://example.com/` | `allow` |

---

### B3. The popup window

**File.** New `LiteGemini/PopupWindowController.swift`: a `final class` inheriting
`NSObject`, conforming to `NSWindowDelegate`, `WKNavigationDelegate`, and `WKUIDelegate`.

**Inputs to its initializer.**
- the `WKWebViewConfiguration` that WebKit passed to `createWebViewWith`
- the initial `WKNavigationAction` and `WKWindowFeatures`
- the main window, as the parent for position and window level
- three closures supplied by `WebViewModel`:
  - `openInMain(URL)`
  - `routeNewWindow`, for nested popups. It takes the same three arguments as
    `createWebViewWith` and returns `WKWebView?`.
  - `onClose(PopupWindowController)`

**State.**
- **Views:** the popup's `WKWebView` and its `NSWindow`.
- **Routing flags:**
  - `openedForAccount`: the result of `NewWindowRouter.isAccountFlow` with the initial URL
    and `hadExplicitSize`
  - `startedBlank`: the initial URL is nil or `about:blank`
  - `hadExplicitSize`: either window feature is present
  - `isFirstNavigation`: starts true. Only http(s) main-frame navigations set it to false;
    the initial `about:blank` load does not.
- **Title observer:** the stored key-value observation for the web view's `title`.

**Creating the web view.**
- Create the `WKWebView` with exactly the configuration that was passed in. WebKit throws
  an exception if `createWebViewWith` returns a web view built with any other
  configuration. That configuration also carries the shared cookie store and the opener
  link that OAuth needs.
- Set its `customUserAgent` to `SettingsManager.shared.userAgent`. A custom UA is a
  property of the web view, not of the configuration. Without it the popup sends
  WebKit's bare UA, and Google may refuse sign-in as an embedded browser.
- Set its navigation and UI delegates to the controller.
- Do not call `load` on it. WebKit loads the request itself after `createWebViewWith`
  returns.

**Creating the window.**
- Style: titled, closable, miniaturizable, resizable. Set `isReleasedWhenClosed = false`.
  The web view is the content view, and the window's delegate is the controller.
- **Size:** use the window features' width and height when present, clamped to 400–1000
  wide and 500–900 tall. The default is 520 × 680.
- **Position:** centered over the main window, or on screen if there is none.
- **Window level:** the same as the main window's current level. With "Always on top" on,
  the main window is `.floating`; a `.normal` popup would open behind it.
- **Title:** starts as the initial URL's host and follows the web view's `title` through
  the observation.
- Show it with `makeKeyAndOrderFront`.

**Navigation delegate.** Implement `webView(_:decidePolicyFor:decisionHandler:)` for
`WKNavigationAction`:
- For non-main-frame navigations, or non-http(s) URLs: `.allow`.
- Otherwise ask `NewWindowRouter.routeInsidePopup` with the current flags, then set
  `isFirstNavigation = false`. Act on the decision:
  - `allow`: `.allow`.
  - `moveToMain(url)`: cancel, call `openInMain(url)`, close the window.
  - `moveToBrowser(url)`: cancel, open `url` with `NSWorkspace.shared.open`, close the
    window.

**UI delegate.**
- `webViewDidClose(_:)`: close the window. Pages call `window.close()` when an OAuth flow
  ends.
- `webView(_:createWebViewWith:for:windowFeatures:)`: return `routeNewWindow(...)`, so
  nested popups follow the same rules.

**Window delegate.** `windowWillClose(_:)`:
1. Stop loading.
2. Invalidate the title observation.
3. Clear the web view's delegates.
4. Call `onClose(self)`.

**Cmd+W.** No change needed. The app's "Close Window" command closes any key window whose
delegate is not `AppDelegate`.

---

### B4. Wire-up

**`WebViewModel.swift`.**
- Add `private var popups: [PopupWindowController] = []`.
- **Rewrite `createWebViewWith`.**
  - Keep the B1 log line.
  - Compute the route with `NewWindowRouter.route`:
    - `url`: the request URL
    - `isLinkActivated`: `navigationAction.navigationType == .linkActivated`
    - `hasExplicitSize`: `windowFeatures.width != nil || windowFeatures.height != nil`
  - Act on the route:
    - `mainWebView(url)`: load it in the main web view (`self.webView`, not the `webView`
      parameter, which can be a popup's web view in nested calls). Return nil.
    - `externalBrowser(url)`: `NSWorkspace.shared.open(url)`, return nil.
    - `ignore`: return nil.
    - `popup`: create a `PopupWindowController`:
      - parent: the main web view's window
      - `openInMain`: loads the URL in `self.webView`
      - `routeNewWindow`: calls this same method
      - `onClose`: removes the controller from `popups`

      Append it to `popups` and return its web view.
  - Extend the B1 log line with the chosen route.
- All three closures must capture `self` weakly. `popups` holds the controllers strongly,
  so a strong capture would create a retain cycle.
- Rename the method's first parameter label internally if needed, so `webView` (the
  parameter) and `self.webView` (the main view) are never confused.
- In `isolated deinit` and in the `.browsingDataCleared` handler, close every popup.
- Copy `popups` before iterating, because closing mutates the array through `onClose`.

**`AppDelegate.swift`.** In `applicationShouldHandleReopen`, pick the window whose delegate
is `AppDelegate` instead of the first window that can become key. Otherwise a popup could
be brought forward instead of the main window.

**Commit for B2–B4 together.** Subject:
`feat: open Google sign-in and OAuth popups in an in-app window`. Body must say:
- the problem: issue #2, and connector OAuth landing in a browser with a different session
- the routing rules, and that they were designed without signed-in logs (the B1 logs
  exist to correct them)
- that popups share the main session and use the app's UA
- Trade-offs:
  - Credentials for Google and third-party sign-in are entered inside the app, as the main
    sign-in already is.
  - Unknown script-opened windows without a size or an OAuth-looking path go to the
    browser.

**Verification.**
- The `routertest` harness passes.
- Release build is clean.
- Owner checks B-1 … B-8.
- After release, with owner approval, close issue #2 with a comment that names the
  release.

---

### Phase B completion

1. Run these and report the results to the coordinator. Do not contact the owner.
   - B1 is committed, and B2–B4 are committed together.
   - The Release universal build is clean.
   - `routertest` passes.
   - The Phase A harnesses (`dltest2`, `imetest2`) still pass.
   - The build is in a fresh `-derivedDataPath`.
2. The coordinator reviews the work and then hands the build to the owner for a single
   acceptance session:
   - Appendix B Phase B (B-1 … B-8)
   - a Phase A smoke check: one upload, one dictation, one download, and one IME candidate
     pick with an attachment present

   The coordinator reads the `NewWindow` logs from that session.
3. The owner accepted Phase B on 2026-10-13, then asked for Phase C before any release.
   v0.4.2 therefore ships Phase B and Phase C together (see Phase C completion).

---

## Phase C (ships with Phase B in v0.4.2): default temporary chat

Branch `feat/default-temp-chat` from the HEAD of `feat/popup-windows`, which is the commit
that added this Phase C section on top of `f8e0201`. It contains all of Phase B, so
releasing this branch releases both phases.

The owner tests only once, after the phase is finished and reviewed (same rule as
Phase B).

### Background (checked in Gemini's bundles on 2026-10-13)

- **No URL for temporary chat.** Temporary chat is Gemini router *state*
  (`{isTemporaryChat: true}`), not a URL. There is no link that opens a temporary chat
  directly.
- **The toggle element.** It is an Angular component, `<temp-chat-button>`. Its button has
  the class `temp-chat-button`, plus `temp-chat-on` while temporary chat is on. These names
  do not depend on the UI language. The `aria-label` and tooltip ("Temporary chat",
  "Turn on temporary chat") are localized, so never use them.
- **New-chat elements.** The page's own new-chat controls are `<new-chat-button>` and
  `[data-test-id="side-nav-sparkle-button"]`. The user can also press Cmd+Shift+O inside
  the page.
- **Signed-out pages have no temporary chat.** Automated tests therefore use a fixture
  page that imitates the element names above.

### C1. Setting: new chats start as temporary chats

**Behavior.** When the setting is on, every time a new, empty chat opens in the main
window, the app makes sure Gemini's temporary chat is on:
- it never clicks the toggle when the button already has `temp-chat-on`
- it never turns temporary chat off
- if the user turns it off inside a chat, it stays off until the next new chat

**Files.**
- `LiteGemini/SettingsManager.swift`
- `LiteGemini/SettingsView.swift`
- `LiteGemini/Localizable.xcstrings`
- new `LiteGemini/TemporaryChatController.swift`
- `LiteGemini/WebViewModel.swift`

**Step 1: the setting.** In `SettingsManager.swift`, follow the existing `windowAnimation`
pattern exactly:
- a `Defaults` entry `defaultTemporaryChat = false`
- a `Keys` entry `defaultTemporaryChat = "defaultTemporaryChat"`
- `@Published var defaultTemporaryChat: Bool`, saving in `didSet`
- in `init`, read the stored value only if one exists; otherwise use the default

**Step 2: the UI.** In `SettingsView.swift`, Section "General", directly after the
"Window Animation" toggle, add:
- a toggle labeled `New Chats Start as Temporary Chats`, bound to the setting
- under it, a caption: `Lite Gemini turns on Gemini's temporary chat whenever a new chat
  opens. If you turn it off in a chat, it stays off until the next new chat.`

Style the caption like the other captions in this file.

**Step 3: strings.** Add both strings to `Localizable.xcstrings`, zh-Hans `translated`:

| Key | zh-Hans |
|---|---|
| `New Chats Start as Temporary Chats` | `新对话默认使用临时会话` |
| the caption above | `每次打开新对话时，Lite Gemini 会自动开启 Gemini 的临时会话。在某个对话里手动关闭后，到下一个新对话前都保持关闭。` |

**Step 4: `TemporaryChatController.swift` (new).** It is separate from `WebViewModel` so a
harness can compile and test it on its own.
- **Type and inputs.** A `final class`, main-actor isolated by default. Its initializer
  takes the main `WKWebView` (stored weakly) and an `isEnabled: () -> Bool` closure.
- **Logging.** A `Logger` with subsystem `io.github.tdhsc.LiteGemini` and category
  `TemporaryChat`. Log one `.notice` line per attempt with the reason and the final
  result (`already-on`, `clicked → on`, `clicked → off`, `missing`, `disabled`, or
  `skipped-recent-click`).
- **`static let intentScriptSource: String`.** A page script, injected at document start
  in the main frame only. It installs two capture-phase listeners on `document`. Each
  posts the message `newChat` to the script message handler named `temporaryChatIntent`,
  and only for trusted events (`event.isTrusted`):
  - a `click` whose target is inside `new-chat-button` or
    `[data-test-id="side-nav-sparkle-button"]` (use `closest`)
  - a `keydown` with `metaKey`, `shiftKey`, no `altKey`, no `ctrlKey`, and
    `key.toLowerCase() === "o"`
- **The probe script.** A private builder that produces one JavaScript snippet. The
  snippet finds `document.querySelector("temp-chat-button")`, then the element with class
  `temp-chat-button` inside it (or the host itself), and returns:
  - `"missing"` if neither exists
  - `"on"` if that element has the class `temp-chat-on`
  - in click mode: clicks it once and returns `"clicked"`
  - in verify mode: returns `"off"`
- **`func ensure(reason: String)`:**
  1. If `isEnabled()` is false, log `disabled` and return.
  2. If the last click was less than 2 seconds ago (keep a
     `ContinuousClock.Instant?`), log `skipped-recent-click` and return. Several triggers
     can fire for the same new chat, and a second click before Gemini updates the class
     would turn temporary chat back off.
  3. Cancel any running task and start a new one that:
     - sleeps 300 ms
     - polls the probe in click mode every 250 ms for up to 10 s:
       - `"on"`: confirm before stopping. Sleep 600 ms, then probe once in verify mode:
         - still `"on"`: log `already-on` and stop
         - otherwise: keep polling

         Why: Gemini resets a new chat to a normal chat (its new-chat code requests
         `isTemporaryChat: false` by default), and that reset can land after the first
         probe. A single early read would see the previous chat's state, stop, and leave
         the new chat normal.
       - `"missing"`: keep polling
       - `"clicked"`: record the click time, sleep 500 ms, run the probe once in verify
         mode, log `clicked → <result>`, and stop. Never click a second time in the same
         task.
     - on timeout, logs `missing`
- **`func cancel()`.** Cancels the task.

**Step 5: wire it into `WebViewModel.swift`.**
- **Ownership.** Add a `temporaryChatController` property. Create it right after the
  delegates are set, passing `webView` and a closure that captures `self` weakly and
  reads `settings.defaultTemporaryChat`.
- **Intent script.** Add `TemporaryChatController.intentScriptSource` as a
  `WKUserScript` (document start, main frame only) next to the existing scripts. Register
  the `temporaryChatIntent` message handler through the existing `WeakScriptMessageHandler`.
  Remove that handler in `isolated deinit`, like the others.
- **Triggers.** Each one calls `ensure(reason:)` with the reason in brackets:
  - (a) **`url`:** `webView.publisher(for: \.url)`, mapped to the path, with
    `removeDuplicates()`. When the path becomes exactly `/app`, call `ensure`. This covers
    leaving a conversation for a new chat and Gemini's in-app navigation. Store the
    subscription in `cancellables`.
  - (b) **`load`:** in `webView(_:didFinish:)`, when the path is `/app`. A full reload or
    first launch resets Gemini's temporary-chat state even though the path did not change.
  - (c) **`hotkey`:** at the end of `handleNewChatRequested`, after the shortcut is sent
    and the fallback task is scheduled.
  - (d) **`page`:** in `userContentController(_:didReceive:)`, a new case for
    `temporaryChatIntent`. This covers the page's own New chat while the URL stays `/app`.
  - (e) **`setting`:** `settings.$defaultTemporaryChat.dropFirst()`. When it turns true
    and the current path is `/app`, call `ensure`. Turning the setting off does nothing to
    the current chat.
- **Deinit.** Call `temporaryChatController.cancel()` in `isolated deinit`.

**Traps.**
- **Main window only.** Popups never get the controller or the intent script.
- **No localized labels.** Do not match the toggle or new-chat controls by text or
  `aria-label`.
- **One click per new chat.** The 2-second guard and the single click per task are what
  prevent toggling temporary chat back off. Do not remove them to "make it more reliable".

**Verification: harness `tempchattest`** (Appendix A recipe).
- **Sources.** Compile the real `TemporaryChatController.swift` against a fixture page
  served through a `WKURLSchemeHandler` (`lgtest://app/app`, so the path is `/app`).
- **Fixture page.** It contains
  `<temp-chat-button><button class="temp-chat-button"></button></temp-chat-button>`.
  The button's click handler increments `window.__clicks`, then toggles `temp-chat-on`
  after 100 ms, imitating Gemini's asynchronous update.
- **Query parameters.** The fixture takes query parameters to:
  - start with the button already on
  - insert the button only after 1.5 s
  - omit the button entirely

| # | Setup | Action | Expected |
|---|---|---|---|
| 1 | enabled, button off | `ensure` | `__clicks == 1`, class on |
| 2 | enabled, button already on | `ensure` | `__clicks == 0` |
| 3 | disabled, button off | `ensure` | `__clicks == 0` |
| 4 | enabled, button off | `ensure` twice, 50 ms apart | `__clicks == 1`, class on |
| 5 | enabled, button inserted after 1.5 s | `ensure` | `__clicks == 1`, class on |
| 6 | enabled, no button | `ensure`, wait 11 s | `__clicks == 0`, no crash |
| 8 | enabled, button starts on; the fixture turns it off 400 ms after `ensure` is called, imitating Gemini resetting a new chat | `ensure` | `__clicks == 1`, class on |
| 7 | intent script injected; the harness counts `temporaryChatIntent` messages | a synthetic (untrusted) click on a fixture `<new-chat-button>`, and a synthetic Cmd+Shift+O keydown | 0 messages. The script ignores untrusted events, so the app's own synthetic events and page scripts cannot trigger it. |

Also run the Release universal build (zero warnings), and rerun `routertest`, `dltest2`,
and `imetest2`. The latter two cover the Phase A code paths that `WebViewModel` changes
touch.

**Commit.** Subject: `feat: add a setting to start new chats as temporary chats`. Body
must say:
- Temporary chat has no URL, so the app turns on Gemini's own toggle.
- Which element names it relies on, and why not labels.
- The five triggers.
- The 2-second and single-click guards.
- Trade-off: it depends on Gemini's internal component names. If Google renames them the
  setting silently does nothing, and the `TemporaryChat` log shows `missing`.

### Phase C completion

1. Report the following to the coordinator, not the owner:
   - commit hash
   - `tempchattest`, `routertest`, `dltest2`, and `imetest2` outputs
   - a clean Release universal build in a fresh `-derivedDataPath` (`/tmp/lg-build-c`)
2. After review, the owner runs one session:
   - **Phase C checks:**
     - **C-1** Turn the setting on; within about 2 s the open new chat is temporary.
     - **C-2** Send a message in that temporary chat, then click the page's New chat.
       The new chat is temporary.
     - **C-3** Press the global new-chat hotkey. The new chat is temporary.
     - **C-4** In a new temporary chat, turn temporary chat off by hand. It stays off,
       and the next new chat is temporary again.
     - **C-5** Quit and relaunch the app. The first chat is temporary.
     - **C-6** Collapse the sidebar and start a new chat. It is still temporary.
     - **C-7** Turn the setting off. New chats are normal, and the current chat is
       unchanged.
     - **C-8** With the app language set to Chinese, the setting shows in Chinese and
       works.
   - **Smoke checks:** the new-chat hotkey (A4), one sign-in popup (B-1 or B-3), and an
     IME candidate pick.

   The coordinator reads the `TemporaryChat` and `NewWindow` logs from that session.
3. After the owner approves, follow §R for version `0.4.2`. In §R step 6, the release
   notes are:
   - **New:**
     - Google sign-in and app-connection popups now open inside Lite Gemini, so adding a
       second Google account works (closes #2).
     - New setting: new chats start as temporary chats.
   - **Notes:** the same as v0.4.1.

   Merge `feat/default-temp-chat` into `main` with a fast-forward. It contains Phase B.
   Delete `feat/popup-windows` and `feat/default-temp-chat` afterwards.

---

## R. Release procedure (used for v0.4.1 and v0.4.2)

Every step that pushes, tags, publishes, or comments needs the owner's approval at that
moment.

1. Branch is complete; Release universal build is clean; harnesses pass; owner checklist
   passes.
2. Fast-forward merge into `main` (`git merge --ff-only <branch>`). Push `main`. Delete the
   local branch.
3. Run `./scripts/bump_version.sh <version>`. It updates `MARKETING_VERSION` and increments
   `CURRENT_PROJECT_VERSION`, the build number Sparkle compares. It does not commit.
4. Commit as `release: v<version>`. Create tag `v<version>`. Push `main` and the tag.
5. The tag triggers `.github/workflows/build.yml` on the `xcode-27` runner image.
   - Watch it with `gh run watch`.
   - v0.4.1 is the first release built on that image. If it fails:
     1. Fix the problem on `main`.
     2. With owner approval, delete the tag locally and on the remote.
     3. Re-tag.
6. CI creates a draft release with the DMG. Replace the generated notes with English
   release notes. Sections:
   - **New:** what users can now do.
   - **Fixes.**
   - **Notes:**
     - the app is not notarized, plus the existing `xattr` instruction
     - for v0.4.1: macOS may ask for microphone permission again after updates
7. Publish. `update-appcast.yml` then runs. Confirm that
   `https://tdhsc.github.io/lite-gemini/appcast.xml` has a new item with:
   - `sparkle:version` equal to the new build number
   - `sparkle:shortVersionString` equal to the version
   - an `sparkle:edSignature`
8. Download the DMG from the release, mount it, and check:
   - `lipo -info` on the binary shows `x86_64 arm64`.
   - `plutil -p` on its Info.plist shows `NSMicrophoneUsageDescription` (from v0.4.1 on).

---

## Out of scope

- CI re-signing that strips the hardened runtime and entitlements. Separate task.
- Issue #3 (proxy).
- The README screenshot.
- `@Observable` migration.
- Official-app features a web wrapper cannot match: window sharing, Fn dictation into other
  apps, Antigravity.

---

## Appendix A. Headless harness recipe

1. Create `/tmp/lg-work/<name>/main.swift`. The structure is:
   - an `@MainActor func run() async` that does the test, prints results, and calls
     `exit(0)` (or `exit(1)` on failure)
   - top-level `Task { await run() }`
   - `RunLoop.main.run()`
2. Compile the real sources next to it:
   `swiftc -swift-version 6 -default-isolation MainActor <repo>/LiteGemini/<File>.swift main.swift -o <name>`
   - If you get isolation errors that the Xcode build does not show, add the two features
     the project's approachable-concurrency setting enables:
     `-enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault`.
   - If a source file references app types the harness lacks, such as `SettingsManager`,
     add a tiny stub with the same name in `main.swift` instead of compiling more of the
     app.
3. Web views in harnesses:
   - Create them with a frame but never put them in a window.
   - Use `WKWebsiteDataStore.nonPersistent()`.
   - Never call `NSApp.activate`, open panels, alerts, or windows.
   - Wait for page work with `Task.sleep` polling loops that have a timeout.
4. Serve test content with a `WKURLSchemeHandler` on a custom scheme. Responses are
   `HTTPURLResponse` objects with whatever headers the case needs, which avoids network
   flakiness.

## Appendix B. Owner acceptance checklist

The owner runs these signed in, on a build of the branch. The implementer prepares the
build and reads results; the implementer does not operate the app.

**Phase A**
- **A1-1** "+" → Upload files: the dialog allows several files; they appear as
  attachments.
- **A1-2** "+" → images: the chosen image appears as an attachment.
- **A1-3** Import code → Upload folder: the dialog only allows choosing a folder; the
  folder is attached.
- **A1-4** Open the dialog and press Cancel. Nothing is attached, and opening the dialog
  again still works.
- **A2-1** Click Dictate. The macOS microphone prompt names Lite Gemini and shows the usage
  text, in Chinese when the system language is Chinese.
- **A2-2** Allow it. Speech appears in the prompt box, and the orange recording indicator
  shows only while dictating.
- **A2-3** No second, WebKit-style "Allow gemini.google.com to use your microphone?"
  dialog appears.
- **A2-4** Reset with `tccutil reset Microphone io.github.tdhsc.LiteGemini` and deny. Gemini
  shows its own "microphone blocked" message, and the app does not crash.
- **A3-1** Generate an image and click its download button. The file appears in
  `~/Downloads`, the notice appears with "Show in Finder", and the Dock Downloads stack
  bounces.
- **A3-2** Download the same image again. A " (1)" copy is created; the first file is
  untouched.
- **A3-3** "Show in Finder" reveals the file. The notice disappears after about 4 s.
- **A3-4** No "Unable to connect to Gemini" overlay appears after a download.
- **A4-1** Inside a conversation, press the new-chat hotkey with the window visible. A new
  chat opens.
- **A4-2** Hide the window, press the hotkey. The window appears with a new chat.
- **A4-3** In Settings, set a non-Mac User-Agent, e.g.
  `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36`.
  Then:
  1. Press Cmd+R and open a conversation.
  2. Press the hotkey. A new chat opens within about 1–2 s (fallback).
  3. Reset the User-Agent to default.

**Phase B**
- **B-1** Add another account. A small in-app window shows Google sign-in. After sign-in it
  closes, and the main window shows Gemini for the new account.
- **B-2** Switch accounts. The main window switches; no browser opens.
- **B-3** Connect an app. The consent flow runs in an in-app window that closes itself at
  the end; the connector shows as connected.
- **B-4** Export to Docs or another "Open in" action. It opens in the default browser.
- **B-5** Click a citation link. It opens in the default browser.
- **B-6** Cmd+W on a popup closes only the popup.
- **B-7** With "Always on top" on, a popup opens above the main window.
- **B-8** Close a popup mid-flow. No crash, and starting the flow again works.
