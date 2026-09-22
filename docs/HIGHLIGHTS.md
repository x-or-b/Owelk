# Persistent text highlights

## Use

- Select text in a PDF, then click `Highlight` in the floating selection toolbar. `PDF: Highlight Selected Text` is also available in Cmd/Ctrl+Shift+P.
- Highlight uses the shared blue accent at 25% opacity. It follows the selected lines, rather than filling a large box spanning the whole paragraph. The toolbar floats over the reader so selection does not shift the PDF layout, including in narrow splits.
- Highlights survive closing tabs and restarting. They appear in every tab showing the same verified PDF and scale with the page. Right-click a marked line and choose `Remove Highlight` to remove the whole selection's annotation.
- Home/Cmd+K's Everything search includes highlighted text (up to 20 matching highlights). Selecting a highlight result verifies the original file and returns to its source. Captures and PDF Text filters retain their existing meaning; a separate Highlights filter is not implemented yet.

## Storage and safety

- Original PDFs are never modified. Highlights live in the local SQLite `highlights` table, separately from captures: ID, source URL, SHA-256, page, literal quote, line rectangles in normalized PDF coordinates, text indices, creation time and deletion marker.
- Saving re-extracts and verifies the selected text and source fingerprint off the UI thread. Line heights reuse the reader's stable selection geometry. Saving the same source/page/character range twice does not stack duplicate marks.
- Loading verifies the current source fingerprint off the UI thread. Changed or missing PDFs do not receive stale annotations; the reader shows a warning. Old async results are ignored after tab/source changes. Same-file relinking includes highlight fingerprints and updates their paths transactionally.
- Removal is soft deletion in SQLite, not modification of the original file. A highlight trash/undo UI, multiple colors, multi-page selection and PDF annotation export are not included in this implementation. Captures' existing trash applies to captures, not highlights.

## Checks

Automated: persistence/restart, line geometry, duplicate suppression, unchanged PDF bytes, changed-source rejection, relinking, search/navigation, removal persistence, real offscreen text selection → Highlight → zoom → reopen → right-click removal, and existing excerpt flow.

Manual: select two or three lines → Highlight → click empty space → zoom and split/open the same PDF → restart → search a marked sentence in Cmd+K → right-click Remove Highlight. Check alignment, contrast and small split usability.
