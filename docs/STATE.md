# QuickEdit state

Rewritten at each milestone, never appended. Last rewrite: 2026-10-23, stage 0.

## Where things are
- Plan: `docs/plan-page.html`, published at https://claude.ai/artifact/Qpy5RUjidhcEjs7dNpgoxP. The plan file is mirrored in `docs/plan.md`.
- Old code (read only): `reference/apple` (Apple archive, project version 309) and `reference/zadr` (version 285, the 10.8 sample with ARC).
- Speed bar: `bench/baseline/textedit-launch.csv`. System TextEdit window-visible median 265.2 ms, n=7, 2 warm-ups, 2026-10-23, Mac14,3, macOS 27.0.1.

## Approvals from the user (2026-10-23)
1. Plain text only. Rich text and the RTF, RTFD, HTML and Word formats are out.
2. Swift on AppKit with NSTextView (TextKit 2). The old Objective-C is built once as a reference.
3. Name QuickEdit, bundle ID dev.yili.QuickEdit.
4. Do not block on the user. Astra and Fable vote on critical questions; the majority wins and root breaks a tie.
5. The 10-milestone plan was approved in plan mode.

## Stage 0 facts found so far
- The Apple copy builds on Xcode 27.1 after two fixes: the six `English.lproj/*.strings` files ship as binary plists and must be turned into text, and the build needs `ARCHS=arm64 VALID_ARCHS=arm64` (the project lists only i386, x86_64 and old ARM, so without it the build "succeeds" with no binary). Its Info.plist hardcodes `com.apple.TextEdit`; rename it before launching. 107 warnings, 0 errors.
- The built reference app launched and stayed running for 4 s. A System Events window query timed out (-1712); window checks must not use System Events.

## Next action
Write Doc B from `docs/codemap.md` and the research, then the M1 plan.
