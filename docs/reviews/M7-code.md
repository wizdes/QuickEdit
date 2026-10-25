# M7 code review (Astra and Opus, 2026-10-24, on dev 7e8a45f plus the M7 work)

| # | Finding | From | Decision |
| --- | --- | --- | --- |
| 1 | Overwriting an existing PDF on another disk fails: the temp file is in the system temp folder and `replaceItemAt` needs one volume | Opus | Accept. Temp folder from `.itemReplacementDirectory` next to the target. |
| 2 | Every PDF write reads `info.dictionary()` and opens the print helper; U1 says no printer contact | Both (Astra as open question) | Accept. Measure; if NSPrintOperation still connects, draw the PDF with Core Graphics and QuickEdit's own header and footer. |
| 3 | The first `printInfo` read calls NSDocument's setter, which records an undoable change and can mark the document edited | Opus | Accept. Stored print info, no super setter from the getter. |
| 4 | The paper size is fixed on first use, so a Settings change can reach an open document; the test reads it first and hides this | Both | Accept. Fix it at create or open; test with no earlier read. |
| 5 | Tests that pass with the behavior broken: temp cleanup, page-number check uses `contains("1")`, self-referential page count, sorted characters, missing header-on plus rewrap-off case, partial read counter | Both | Accept. |
| 6 | Missing tests: empty document, typing after a Wrap to Page PDF, 1 MB Wrap to Page time, Cmd+P with the panel open | Opus | Accept. |
| 7 | PrintingTextView may point at a freed layout manager after detach | Opus (uncertain) | Accept: hold it strongly. |
| 8 | Finder File > Print or a script reaches NSDocument's default and shows an error | Opus (uncertain) | Accept: route it to the PDF Save panel. |
| 9 | Two alerts at once when printing fails for a reason like a full disk | Opus (uncertain) | Follow-up. |
| 10 | Large Wrap to Page documents may freeze while every page is laid out | Opus (uncertain) | Measure in row 6; M8 if slow. |

## Re-review of the new PDF drawing code (Astra, 2026-10-24)

After row 2, the builder measured that NSPrintOperation always contacts the print helper, so QuickEdit now draws PDFs itself (`PDFRenderer.swift`).

| # | Finding | Decision |
| --- | --- | --- |
| 11 | A partial PDF can replace a good file: only the temp file's existence is checked | Accept. Open the temp PDF and match its page count before replacing; test with a truncated file. |
| 12 | A line taller than a page runs past the footer and the paper edge | Accept. Clip to the text area; test with a 900 pt font. |
| 13 | The full fixture matrix (3 fixtures x 2 modes x header x rewrap) is incomplete | Accept. One table-driven test; add CR-only and trailing-empty-line cases. |
| 14 | 100 MB memory and responsiveness of PDF output not measured | M8. |
