# Backlog: Future Native Capabilities (Deferred Beyond Category 1)

- **Baseline frontend build:** `boq_gemini-web-uiserver_20261125.05_p0` + `bg3/boq-bard-web/islands`
- **Status:** Backlog checklist (deferred; Category 1 in-conversation micro-interactions researched separately)

---

## 1. 多模态媒体生成与代码执行输出

- [ ] **Python 代码沙盒执行输出 (`InlineCodeSandbox` / `code-output-stdout-stderr`)**
  - **线上模块：** `InlineCodeSandbox-D8TxmSbN.js`、`IceCodeBlockNodeView-SrrOmtCU.js`、DOM `[data-test-id="code-output-stdout-stderr"]`
  - **适配要点：** 解析模型端 Python 沙盒执行返回的 `stdout / stderr` 文本流及内联生成的图表文件，在代码块卡片底部追加可折叠输出栏。

- [ ] **Veo 视频生成与内联播放 (`FEATURE_MODE_VIDEO_GENERATION`)**
  - **线上模块：** `VideoGenerationOutputNodeView-DU1o-qB_.js`、`VideoGenerationChipEntryNodeView-DSNWDT5n.js`
  - **适配要点：** 输入框工具菜单支持视频生成模式；对话时间线内通过 `AVKit` 渲染生成的 MP4 / GIF 卡片并提供原片下载。

- [ ] **Audio Overview 双人播客与 Lyria 音乐生成 (`AUDIO_OVERVIEW` / `FEATURE_MODE_MUSIC_GENERATION`)**
  - **线上模块：** `AudioGenView-94WS_j0s.js`、`MusicGenerationOutputNodeView-DThXJH1N.js`
  - **适配要点：** 解析音频产物 URL / 流，提供原生播放进度条、倍速切换、±10 秒跳转、歌词/字幕显示及音频下载。

- [ ] **大图预览局部涂抹重绘 (`UnifiedImageLightbox` / `erase-brush-shader-canvas`)**
  - **线上模块：** `UnifiedImageLightbox-CssE1eyp.js`、DOM `[data-test-id="erase-brush-shader-canvas"]`
  - **适配要点：** 在原生图片预览层提供画笔蒙版选区（Mask），将选区图层连同修改指令回传重绘。

---

## 2. Canvas 右侧分栏细分渲染器

`v2.1` 已支持 `Document`、`Code`、`HTML / SVG` 实时预览与 `Deep Research` 报告；以下细分 `SidePanel*Content` 形态留待后续按需扩展：

- [ ] **交互式表格与 Vega-Lite 图表 (`SidePanelSpreadsheetContent` / `VegaLiteJsonFileNodeView`)**
  - **线上模块：** `SidePanelSpreadsheetContent-BXdYPABV.js`（`SPREADSHEET`）、`VegaLiteJsonFileNodeView-Dilb-c8l.js`（`VISUALIZATION_IMMERSIVE`）
  - **适配要点：** 支持按行筛选（Filter rows）、列数值求和统计、一键复制 CSV、导出 Google Sheets，以及沙盒渲染 Vega-Lite JSON 图表。

- [ ] **幻灯片分栏预览 (`SidePanelSlidesContent`)**
  - **线上模块：** `SidePanelSlidesContent-CQNkEaIK.js`（`SLIDES_IMMERSIVE`）
  - **适配要点：** 分栏内支持前后翻页浏览幻灯片、复制 HTML 及导出 PDF。

- [ ] **互动学习卡片：测验与抽认卡 (`FEATURE_MODE_LEARNING` / `Quiz` / `Flashcards`)**
  - **线上模块：** `SidePanelQuizContent-BfglJgEi.js`、`SidePanelFlashcardsContent-DTz5QkAa.js`（`LEARNING_IMMERSIVE` / `FLASHCARDS`）
  - **适配要点：** 原生单选/多选判分测验卡片与正反翻转记忆闪卡（支持打乱顺序与标记复习状态）。

- [ ] **有声绘本与动态交互视图 (`SidePanelStorybookContent` / `GenUiHtmlNodeView`)**
  - **线上模块：** `SidePanelStorybookContent-DODnz7-b.js`（`STORYBOOK_IMMERSIVE`）、`GenUiHtmlNodeView-BVgsqUps.js`（`Candidate.attachments` 字段 `77`）
  - **适配要点：** 绘本图文翻页 + 旁白配音播放；字段 `77` 动态生成的交互式 HTML 小组件接入现有无状态沙盒 `WKWebView`。

---

## 3. 代码仓库直连与重型工作台模块

- [ ] **GitHub 仓库 URL 直连导入 (`CodeImportDialogContent`)**
  - **线上模块：** `CodeImportDialogContent-ECY5Ubbs.js`（位于 `<code-import>` 菜单内）
  - **适配要点：** 支持输入公开或已授权 GitHub 仓库 URL 与分支名直接挂载上下文（单仓库上限 `100 MB`）。

- [ ] **外部 MCP 工具交互卡片 (`McpToolUiFrameNodeView`)**
  - **线上模块：** `McpToolUiFrameNodeView-CmvndTGI.js`、`mcpAppsGraphqlApi-BF1FqfxK.js`、`ToolConsentDialog-BG8V96T4.js`
  - **适配要点：** 工具调用授权确认弹窗与内嵌 MCP 工具帧展示、外链二次确认拦截。

- [ ] **Projects 项目空间与 NotebookLM 联动 (`projects.ts` / `NotebooksDialogContent`)**
  - **线上模块：** `ProjectHomeSurface-BO3hMhH7.js`、`ProjectSourcesSurface-vlqYLNnM.js`、`MoveConversationToNotebookDialog-WZmSDqnJ.js`
  - **适配要点：** 项目级固定指令（Instructions）、项目知识库文件池管理及对话移入 NotebookLM。

- [ ] **定时任务 (`VegaSchedulesPanel`) 与每日简报 (`DailyBriefSurface`)**
  - **线上模块：** `VegaSchedulesPanel-BCIWIECi.js`、`ScheduledTasksSidePanelContent-B5aIP9E4.js`、`DailyBriefSurface-CAbdKhdu.js`
  - **适配要点：** 查看、暂停、恢复或删除周期性执行的 Gemini 定时任务；卡片流形式展示每日个性化简报。

- [ ] **个人记忆管理 (`rememberedItems.ts` / `ImportMemorySurface`)**
  - **线上模块：** `RememberedItemsSurface-RjuBAU8m.js`、`RememberedItemsResponseBlock-D8E3s4c8.js`、`ImportMemorySurface-8_0cFDZl.js`
  - **适配要点：** 对话内提示“已记住某偏好”小徽章，以及记忆条目的增删与外部记忆导入。

- [ ] **远程浏览器/电脑接管 (`ComputerUseSidePanelContent`)**
  - **线上模块：** `ComputerUseSidePanelContent-D-XF0Skt.js`、`computer-use-action-menu`
  - **适配要点：** 展示云端虚拟机实时截图/画面流，支持人工接管（Take over task）与归还控制权。

- [ ] **Gemini Live 实时双向语音 (`LiveVoiceBarSlot`)**
  - **线上模块：** `LiveVoiceBarSlot-C6NCH88K.js`、`LiveMicButton-DcGhEwWZ.js`
  - **适配要点：** 基于 WebRTC 音频轨道的低延迟双向全双工语音会话。

---

## 4. 此前已明确延后的基础模块（备查）

- [ ] **完整历史会话管理：** 置顶（Pin）、重命名（`MUAZcd`）、删除（`GzXR5e`）与滚动分页加载更多。
- [ ] **Gems 与 `@` Google Workspace 扩展：** `CNgdBe`（`ListBots`）切换及 `@Gmail / @Drive / @Docs / @YouTube` 自动补全菜单（`ChatAtMentionsMenu`）。
- [ ] **输入框内建语音听写按钮：** `speech-dictation-mic-button`（macOS 系统级听写快捷键已天然支持 `ComposerTextView`）。
