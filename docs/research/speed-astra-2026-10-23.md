I found no matched benchmark proving that QuickEdit will beat TextEdit. Performance recording is also blocked locally: `xctrace` reports `No instruments found`.

My recommendation is to keep ordinary editing on `NSTextView` with TextKit 2. Remove work proportional to the whole document from typing and opening. Treat responsive 1 GB editing as a separate, unproven requirement. Compiler flags alone will not solve it.

This is advice, not implementation or review approval.

Evidence labels:

- **Measured:** a reported observation, with its limits stated.
- **Vendor doc:** Apple documentation or an editor’s own source and release notes.
- **Opinion:** my recommendation or an author’s judgment.
- Undated sources were read on **2026-10-23**. Older sources below explain mechanisms still relevant to the 2024–2026 work.

The 15 changes I would prioritize are below. Their order and expected impact are **Opinion**. No percentage is implied where none was measured.

| Rank | Change | Expected effect and evidence |
|---:|---|---|
| 1 | Remove whole-document layout from opening, typing, counting, and navigation. | Potentially the largest improvement. **Measured, author report:** one custom TextKit 2 end-of-document jump took about **3 seconds**, while TextEdit handled the same file in milliseconds. This was macOS 14.5, not 27. E1. |
| 2 | Make each edit update only the changed range and nearby text. | High for large files. Avoid full-string counts, conversions, comparisons, searches, and attribute replacement after each key. No transferable timing found. E2, E3. |
| 3 | Move file reading and decoding off the main thread. | High for responsiveness. It need not reduce total opening time. Keep final UI installation short and measured. E4. |
| 4 | Start with spelling, grammar, corrections, substitutions, data detection, and prediction disabled. | Possibly high for typing consistency; magnitude unmeasured. Offer deliberate opt-ins. Compare TextEdit under both matched and default settings. |
| 5 | Add a large-file and long-line policy before allocating the full editing model. | Potentially decisive for avoiding hangs and memory pressure. CotEditor’s maintainer described roughly **120 MB** as a practical border in 2025 and warned above **200 MB**. Those are observations, not QuickEdit limits. E5. |
| 6 | Build only the first usable window during launch. | High if startup currently creates unused controllers or reads files. Defer preferences, optional panels, caches, and background housekeeping. E6. |
| 7 | Use a short encoding path: explicit choice/BOM, UTF-8, then bounded fallback choices. | Medium to high when detection otherwise tries many complete decodes. Never silently replace invalid bytes. E7. |
| 8 | Keep one authoritative text model and shorten temporary-buffer lifetimes. | High for peak memory. Avoid retaining raw bytes, decoded copies, attributed copies, and full-document undo snapshots together. E2, E4. |
| 9 | Populate initial storage before attaching the live view where practical. Batch related changes. | Potentially high during opening. Avoid repeated layout and notifications while installing chunks. The old TextEdit sample already detaches layout managers during loading. E8. |
| 10 | Preserve native undo coalescing; store edits rather than document snapshots. | Medium for sustained typing and memory. Break groups at meaningful boundaries, including saving. No timing gain established. E9. |
| 11 | Keep application dependencies static, or merge embedded dynamic frameworks in Release. | Conditional launch benefit. Little gain if QuickEdit already has one executable and only system frameworks. Mergeable libraries are not a reason to add frameworks. E10. |
| 12 | Restore documents without putting every restored window’s work before the first usable window. | High for saved sessions; little effect on an empty launch. Preserve document recovery and measure restoration separately. E11. |
| 13 | Establish an optimized Release build, then compare `-O` and `-Osize`. | Essential versus Debug; uncertain gain between optimized choices. Use whole-module optimization and dead stripping. Test LTO separately. E12. |
| 14 | Reach idle through events, cancellation, and timer tolerance. | High for idle energy if polling exists. Avoid a permanent display link. Apple recommends at least **10% timer tolerance** where timing permits; that is not a 10% energy claim. E13. |
| 15 | Keep the view tree small; test code-built UI and layer backing only against traces. | Usually lower priority. I found no credible universal launch gain from replacing a small nib with code, or typing gain from forcing layer backing. E6, E14. |

The evidence table separates what sources establish from what still needs testing.

| ID | Date and source | Class | Finding and limit |
|---|---|---|---|
| E1 | **August 2024**, Simon Støvring and Apple DTS: [scrolling to a TextKit 2 target](https://developer.apple.com/forums/thread/761364) | Measured, author report; vendor doc | Full-document `ensureLayout` took about 3 seconds on the author’s 2021 MacBook Pro. Apple recommends laying out the target range and aligning the viewport. Its position can remain estimated. |
| E2 | **WWDC 2024**, [Explore Swift performance](https://developer.apple.com/videos/play/wwdc2024/10217/) | Vendor doc | Apple prioritizes algorithm changes, then allocation, copying, representation, and dispatch costs. It gives no general Swift editor speedup. |
| E3 | **WWDC 2021**, [Meet TextKit 2](https://developer.apple.com/videos/play/wwdc2021/10061/) | Vendor doc | TextKit 2 always uses non-contiguous layout. Work should stay near the viewport. Asking for layout outside it can be expensive. |
| E4 | **2026-10-23**, CotEditor commit `b7924dd`: [TextDocument.swift](https://raw.githubusercontent.com/coteditor/CotEditor/b7924dd483ae791e95d925cbcd6b4052d923d8b7/CotEditor/Sources/Document/TextDocument.swift) | Vendor doc/source | Concurrent reading is enabled. Reading and decoding precede main-thread storage replacement. The code also retains original file data for change detection, a memory tradeoff worth examining. |
| E5 | **2025-09-19**, [CotEditor issue 1924](https://github.com/coteditor/CotEditor/issues/1924#issuecomment-3310923964) | Opinion; user observation | Maintainer estimates a roughly 120 MB practical border and describes a warning above 200 MB. A user reproduced scrolling hangs with 120 MB on an M3 with 36 GB RAM. Not a controlled benchmark. |
| E6 | **WWDC 2019**, [Optimizing App Launch](https://developer.apple.com/videos/play/wwdc2019/423/) | Vendor doc; measured demo | Apple’s example exposed roughly 370 ms in an unnecessary library initializer. This demonstrates the mechanism, not an expected QuickEdit saving. Profiling overhead can greatly distort launch timing. |
| E7 | **2026-10-23**, [CotEditor encoding code](https://raw.githubusercontent.com/coteditor/CotEditor/b7924dd483ae791e95d925cbcd6b4052d923d8b7/Packages/EditorCore/Sources/FileEncoding/String%2BEncoding.swift) | Vendor doc/source | Checks BOM, encoding metadata, optional declarations, then candidate encodings. Declaration scanning is bounded to the first 1,024 bytes. Candidate decoding can still inspect the full data. |
| E8 | **2013**, local Apple TextEdit source | Vendor doc/source | Enables non-contiguous layout, concurrent plain-text reads, and disabled undo registration while loading. It removes layout managers around the import. These optimizations are already in the old baseline. |
| E9 | Undated, [Apple undo-coalescing documentation](https://developer.apple.com/tutorials/data/documentation/appkit/nstextview/breakundocoalescing().md) | Vendor doc | `breakUndoCoalescing()` starts a new typing group. Apple calls out saving as a required boundary for correct dirty-state tracking. |
| E10 | **WWDC 2023**, [Meet mergeable libraries](https://developer.apple.com/videos/play/wwdc2023/10268/) | Vendor doc | Release merging offers static-link-like behavior while retaining dynamic development builds. System libraries remain separate. |
| E11 | Archived, [Document-based app core behaviors](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/StandardBehaviors/StandardBehaviors.html) | Vendor doc | Restoration reopens documents and restores windows, selections, and scroll state. The guide establishes work performed, not a fixed restoration cost. |
| E12 | Undated, [Xcode build settings](https://developer.apple.com/tutorials/data/documentation/xcode/build-settings-reference.md) | Vendor doc | Documents Swift speed/size optimization, whole-module compilation, dead stripping, merging, and LTO settings. |
| E13 | **2016-09-13**, [timer guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) and [App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html) | Vendor doc | Replace polling with events, stop unused timers, allow tolerance, and stop unnecessary work before App Nap intervenes. |
| E14 | **WWDC 2023**, [What’s new in AppKit](https://developer.apple.com/videos/play/wwdc2023/10054/?time=1496) | Vendor doc | View-bound display links follow the relevant display. They support animation timing; Apple does not present them as an ordinary text-input accelerator. |
| E15 | **WWDC 2022**, [Link fast](https://developer.apple.com/videos/play/wwdc2022/110362/) | Vendor doc; measured demo | Explains cached loader work and page-in linking. Its TextEdit example shows **15 ms of loader launch work**, including **1 ms for fixups**. This is not time to a usable window. |
| E16 | **2025-08-15**, Marcin Krzyżanowski: [TextKit 2—the promised land](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/) | Opinion with demonstrations | Describes unstable height estimates, scrolling corrections, and storage limitations after four years building STTextView. The page displays August 15 despite August 14 in its URL. |
| E17 | Current source, [STTextView](https://github.com/krzyzanowskim/STTextView) | Vendor doc/source | Documents custom content storage, layout fragments, and rendering. Lists long-line jumping and viewport callback bugs. Reports do not establish whether each bug remains in macOS 27. |
| E18 | **WWDC 2026**, [Elevate your app’s text experience](https://developer.apple.com/videos/play/wwdc2026/370/) | Vendor doc | Adds framework text-view viewport callbacks and rendering-surface APIs. The installed SDK confirms `NSTextView` callbacks are available in macOS 27.0. |
| E19 | **2026-10-23**, [CotEditor LayoutManager.swift](https://raw.githubusercontent.com/coteditor/CotEditor/b7924dd483ae791e95d925cbcd6b4052d923d8b7/CotEditor/Sources/Document%20Window/Text%20View/LayoutManager.swift) | Vendor doc/source | CotEditor’s main layout manager still subclasses `NSLayoutManager`, meaning TextKit 1, and enables non-contiguous layout. |
| E20 | Current source, [Runestone](https://github.com/simonbs/Runestone) | Vendor doc/source | Credits incremental parsing and AvalonEdit-derived line management. Requires Release builds for meaningful performance tests. Primarily iOS; Catalyst support is incomplete. |
| E21 | **2024-08-06**, **2024-12-20**, [Sublime Text release notes](https://www.sublimetext.com/download) | Vendor doc | Records lower large-file memory use and a later large-file editing regression fix. Also documents limits for expensive search and syntax features. No comparable timing published there. |
| E22 | Undated, current [BBEdit FAQ](https://barebones.com/support/bbedit/faqs.html) | Vendor doc | Claims large-file support, with some operations limited above 2 GB. Does not disclose enough internals to attribute this to memory mapping or a particular buffer structure. |

Launch needs two separate investigations: work before `main`, and work before the first accepted key.

**Vendor doc:** `dyld`, the dynamic loader, caches dependency work between launches. Page-in linking applies pointer fixups when memory pages are first needed. Modern deployment targets enable this machinery; there is no application switch that guarantees a warm cache. Apple’s 2022 explanation also says libraries loaded later through `dlopen` did not receive that launch-time path. [Link fast, WWDC 2022](https://developer.apple.com/videos/play/wwdc2022/110362/)

**Opinion:** Keep the initial dependency graph small. Avoid expensive static initialization and early singleton access. Profile before adding symbol-order files or manual loading. Static linking your own Swift modules does not remove the system Swift runtime.

**Vendor doc:** Swift’s runtime is supplied by Apple’s operating systems. **Opinion:** I found no defensible fixed “Swift startup tax” for this Mac and SDK. Measure runtime initialization, metadata work, and first-use allocations separately. [Swift ABI explanation, 2019-02-11](https://www.swift.org/blog/abi-stability-and-apple/)

**Opinion:** Code-built menus and one code-built window are reasonable for this small app. Their main benefit is control over what gets created. A small nib can also be cheap. Do not replace `NSApplication` startup or document recovery to chase an assumed saving.

**Vendor doc:** `applicationDidFinishLaunching` occurs before the app receives its first event. It is therefore an unsuitable endpoint for “keystroke-ready.” [Apple startup documentation, undated](https://developer.apple.com/tutorials/data/documentation/appkit/nsapplication/finishlaunching().md)

The old TextEdit sample does more than display a text view. It registers defaults, queries spelling preferences, sets up document-controller bindings, uses a document-window nib, and configures text services. Relevant inspected files are:

- [Controller.m](/Users/yili/work/Projects/QuickEdit/reference/apple/Controller.m:109)
- [DocumentController.m](/Users/yili/work/Projects/QuickEdit/reference/apple/DocumentController.m:72)
- [DocumentWindowController.m](/Users/yili/work/Projects/QuickEdit/reference/apple/DocumentWindowController.m:88)
- [Document.m](/Users/yili/work/Projects/QuickEdit/reference/apple/Document.m:160)

These are **Vendor source facts about the 2013 sample**. They do not establish the current system TextEdit’s startup sequence.

For typing, retain the system text-input path and minimize the work around it.

**Vendor doc:** Accessing `textView.layoutManager`, including through its text container, can force compatibility mode into TextKit 1. Apple describes this switch as expensive and one-way for that view. Audit old helper code, including measurement code, for this access. [TextKit update, WWDC 2022](https://developer.apple.com/videos/play/wwdc2022/10090/)

**Opinion:** Measure insertion, storage processing, layout, and presentation separately. TextKit 2 has no published constant cost per keystroke. Paragraph length, wrapping, Unicode shaping, attribute changes, and callbacks all affect the result.

**Opinion:** Avoid replacing `.string` on every edit or keeping a second full-document model synchronized after each key. Do not compute wrapped-line counts through full layout during typing. Delay optional counts and searches, cancel stale work, and preserve input-method composition.

**Opinion:** Test long unbroken paragraphs explicitly. Disabling wrapping may reduce work but is not a guaranteed cure. Test scrolling to the end, thumb dragging, resizing, and edits near the final line. These expose estimated-height problems that ordinary typing tests miss. E16–E18 support the test choice, not a claim that macOS 27 necessarily has each older bug.

**Opinion:** Layer backing should be a controlled comparison. It cannot eliminate text shaping or storage work. A continuously running display link adds wakeups; stock `NSTextView` should not need one. Use a view-bound link only for a measured custom animation or drawing need.

For large files, I would use the following provisional policy. These sizes are **Opinion**, not verified acceptance limits.

| File | Starting policy | Required proof |
|---|---|---|
| 10 MB | Full editing with TextKit 2. Background read and decode. | Opening, typing, undo, search, end jump, and resize remain responsive. |
| 100 MB | Explicit large-file mode. Disable optional analysis and expensive automatic services. | Peak memory and typing tails remain acceptable for both short lines and huge paragraphs. |
| 1 GB | Offer a limited viewer first, pending measurements. | A bounded decoded window must remain responsive without loading the entire file into live text storage. |

**Vendor doc:** `.mappedIfSafe` is a hint to map file bytes into virtual memory when safe. It does not provide a decoded, editable, lazily paged text model. Apple also recommends keeping file-system work off the main thread. [Reading options, undated](https://developer.apple.com/documentation/foundation/nsdata/readingoptions), [Foundation update, WWDC 2019](https://developer.apple.com/videos/play/wwdc2019/723/?time=67)

**Opinion:** Benchmark mapped versus ordinary reads. Mapping may save an input-buffer copy while decoding still touches the whole file. It can move page faults into later work rather than eliminate them.

**Opinion:** A 1 GB ASCII file represented as UTF-16 code units alone requires roughly 2 GB, before layout, copies, undo, and other app memory. Actual storage representation varies. This Mac has only **8 GiB RAM**, confirmed locally. Peak allocation matters more than file size alone.

**Opinion:** Making an entire `NSTextView` read-only does not make its storage bounded. A genuinely bounded viewer needs chunked decoding, line indexing, and a window of displayed content. It must handle encoding boundaries and file changes. That is a separate subsystem.

**Opinion:** Choose TextKit 1 as a fallback only after a reproducible TextKit 2 failure on macOS 27. Recreate the view deliberately. TextKit 1 with non-contiguous layout is a useful comparison, but it does not automatically solve 1 GB storage. CotEditor is evidence of both its usefulness and its limits.

The projects offer different lessons:

- **CotEditor:** Best starting reference for document handling, encoding, native behavior, cancellation, and TextKit 1 layout. Its current main editor is not evidence of TextKit 2 performance.
- **STTextView:** Best reference for TextKit 2 fragment rendering and practical bug workarounds. Read the author’s 2025 report before assuming a custom text view will be simpler.
- **Runestone:** Useful for incremental line indexing and keeping analysis local. It is not an AppKit `NSTextView` replacement.
- **Sublime Text:** Useful precedent for limiting expensive features on large files. Public release notes do not reveal its complete buffer implementation.
- **BBEdit:** A useful large-file comparison target. Its claims do not establish that its implementation can be reproduced through stock `NSTextView`.

For builds, my starting configuration is **Opinion**, based on Apple’s documented settings:

```text
SWIFT_OPTIMIZATION_LEVEL = -O
SWIFT_COMPILATION_MODE = wholemodule
DEAD_CODE_STRIPPING = YES
```

Compare `-Osize` against that baseline. Smaller code can help loading and instruction-cache use; it may hurt hot loops. Test `LLVM_LTO` separately and inspect the actual Swift and Clang invocations. Neither LTO nor whole-module optimization can optimize inside the shipped AppKit binary. [Xcode settings, undated](https://developer.apple.com/tutorials/data/documentation/xcode/build-settings-reference.md)

**Vendor doc:** Swift 6 strict concurrency checking is a compile-time checking mode. Concurrency implementation choices can still add runtime work. Swift 6.2’s SE-0461 introduces caller-actor execution for nonisolated async functions under its feature setting, plus explicit `@concurrent` execution. **Opinion:** Merely adding `async` or `Task {}` does not prove decoding left the main actor. Avoid one task or actor hop per character. [SE-0461, Swift 6.2](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)

**Vendor doc:** Gatekeeper can use a notarization ticket online or stapled to the app at first installation or execution. **Opinion:** Keep hardened runtime enabled. Test the signed distribution build. Report first downloaded launch separately from later launches. I found no reliable fixed hardened-runtime or notarization penalty to subtract. [Apple notarization documentation, undated](https://developer.apple.com/tutorials/data/documentation/security/notarizing-macos-software-before-distribution.md)

For memory and energy, **Opinion:** measure empty-window physical footprint, peak opening footprint, post-edit footprint, and memory after closing. Report resident memory separately from physical footprint. At idle, target no recurring application work beyond required system behavior. Cancel analysis for closed documents and avoid permanent activity assertions that prevent App Nap. No defensible universal “idle MB” target emerged from the sources.

The benchmark should prove a user-visible result. This proposed procedure is **Opinion**:

1. **Define the endpoint.** Start at the external launch request. Stop when a visible, focused editor accepts a real input event. Record first visible character separately.
2. **Add internal signposts.** Mark entry to `main`, document creation, read, decode, storage installation, first viewport layout, and first accepted edit. `OSSignposter` records intervals for Instruments; an internal start excludes earlier loader work. [Apple signpost documentation](https://developer.apple.com/tutorials/data/documentation/os/ossignposter.md)
3. **Use identical workloads.** Match font, window width, wrapping, checking settings, file bytes, and restoration state. Also compare each app’s normal defaults.
4. **Separate launch cases.** Empty launch, file launch, restored session, first installed launch, and repeated launch are different tests. Repeated launches are not cold-cache tests.
5. **Cover bad text shapes.** Use 10 MB, 100 MB, and 1 GB files with short lines, giant paragraphs, ASCII, non-ASCII text, and mixed line endings. Test start, middle, and end edits; paste; undo; search; scrolling; resize; and autosave.
6. **Report distributions and failures.** Use repeated runs, median and p95, sample counts, peak memory, and timeouts. Alternate app order. Keep profiler runs separate from low-overhead timing runs.

The App Launch template can explain launch phases where it is available. Its completion marker does not prove the first key was accepted. A display or layout callback also does not prove pixels reached the screen.

These are **proposed commands, not executed recordings**. Set `QE_APP` to the built app and provide an available template:

```bash
xcrun xctrace record \
  --template 'App Launch' \
  --time-limit 10s \
  --output "$TMPDIR/qe-launch.trace" \
  --launch -- "$QE_APP"

xcrun xctrace record \
  --template "$QE_TEMPLATE" \
  --time-limit 20s \
  --output "$TMPDIR/qe-edit.trace" \
  --launch -- "$QE_APP"

xcrun xctrace export \
  --input "$TMPDIR/qe-launch.trace" \
  --toc
```

A direct `xctrace --launch` run is diagnostic. Use the same Launch Services-based external driver for the user-facing comparison. Timing the return of `open` alone does not measure readiness.

The exact environment commands I ran produced these results:

| Command | Result |
|---|---|
| `git status --short` | Initially empty. Final check showed untracked `bench/` and `docs/`; I did not create or change them. |
| `sw_vers` | macOS **27.0.1**, build **26A434**. |
| `xcodebuild -version` | Xcode **27.1**, build **27A9275**. |
| `sysctl -n hw.model hw.memsize` | `Mac14,3`; `8589934592` bytes, **8 GiB**. |
| `xcrun --show-sdk-path` | `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` |
| `xcrun xctrace list templates` | Listed 11 templates. Neither App Launch nor Time Profiler appeared. |
| `xcrun xctrace list instruments` | `No instruments found`. |
| `xcrun xctrace help record` | Confirmed the proposed recording command syntax. |

All these commands exited 0. That does **not** mean profiling is functional. I also used read-only `rg`, `sed`, and bounded Python HTTP reads to inspect the cited source and SDK declarations. No application build, performance test, or regression test ran.

My confidence is **high** in the priority of bounded layout, local edits, fewer copies, and less startup work. It is **medium** that TextKit 2 will meet the 100 MB goal. It is **low** that an unrestricted 1 GB editor built around stock `NSTextView` will meet the goal on this 8 GiB Mac without a limited mode.

The open questions are:

1. What are TextEdit’s actual launch and typing distributions on this machine?
2. Which older TextKit 2 long-line and viewport failures remain in macOS 27.0.1?
3. How much memory does QuickEdit retain after decoding, installation, editing, and undo?
4. Does the product require full 1 GB editing, or is an explicit limited viewer acceptable?
5. Why does the installed `xctrace` expose templates but no instruments?

Web retrieval limits: Apple’s JavaScript documentation pages initially returned shells. The build-settings Markdown link also failed in the web tool. Direct Python reads of Apple’s Markdown endpoints recovered the cited content. I did not use Reddit or X pullers because they call other models, which this task forbids. No secondary-source claim was used as a substitute for primary evidence.

No project files changed. No speed advantage has been verified. The immediate next step is to fix the recording setup and measure TextEdit and a minimal Release editor under the same workloads.
