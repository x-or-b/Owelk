# PDF annotations

## Use

- Select text to show three icons beside the selection endpoint: Highlight, Comment and Save Excerpt. Hover for descriptions. The toolbar stays inside the reader and does not shift PDF layout.
- Highlight offers Blue, Yellow, Green, Pink and Purple. Line geometry follows the selection; marking the same character range again changes its color without duplicating the highlight or removing its comment.
- Comment opens an explicit Save/Cancel editor, preserving the original quote separately. Click a comment marker to reopen it. Unsaved changes require confirmation before discarding.
- Right-click selected text for Copy, Select All on Page, Add Comment to Selection, Highlight Selection, Save Excerpt, Capture a Region and Print PDF. There is no unavailable AI action or misleading selection-only print action.
- The 32px PDF toolbar centers zoom controls. Right-side icons provide Comment, Highlight, Text Box, Image, Draw and Print. Narrow splits put these actions in an overflow menu.
- For page comments, text boxes and images, activate a tool then click or drag on the page. Images are copied into app storage; position and size can be edited as page percentages. Image editing applies only to app-added images, not embedded PDF content. Draw by dragging; Esc leaves the active tool.
- Right-click an existing annotation to edit its comment/text, replace an added image, change color or remove it. Drawing geometry cannot yet be reshaped. Color is chosen through the highlight picker or an existing annotation's context menu.
- Home/Cmd+K Everything search includes highlighted quotes, comments and text-box contents (up to 20 matching annotations). Results verify the original file before navigating. PDF Text/Captures filters retain their existing meaning.

## Storage and safety

- Original PDFs are never modified. The local SQLite `highlights` table stores annotation kind, color, body, normalized rectangles, drawing points and image reference alongside source URL, SHA-256, page and quoted text. Existing databases receive additive columns with defaults.
- Saving selected text re-extracts and verifies its quote. Page annotations verify the reader's source fingerprint before saving. Loading verifies the current source off the UI thread; changed/missing PDFs do not receive stale annotations. Same-file relinking updates annotation paths transactionally.
- Added images are copied as PNG (at most 2048 pixels per side); decoding is limited to 25 megapixels. Comments/text are limited to 10,000 characters and strokes to 5,000 points. Replaced image assets are retained locally; automatic pruning is not implemented.
- Removal is soft deletion. Annotation trash/undo UI, multi-page selection and native editable PDF annotation export remain future work. Captures' trash does not restore annotations.

## Printing

- Print opens the native dialog and prints the PDF with current app annotations. Rendering is page-by-page in a worker; cancellation and source fingerprint checks are supported. Finish/cancel printing before closing the app.
- Output is rasterized (approximately 144 dpi, capped at 4096 pixels per page edge), not an editable annotation export. Comments print as markers, not their full note text. Choose a different output file when saving as PDF; the app rejects the original source path and its symlink aliases.
- Native dialogs and actual printer output require manual testing; offscreen tests cover the annotation compositor and persistence.

## Checks

Automated targeted checks: colored annotation persistence, comments preserving source quotes, text-box edits, image copying, drawings, invalid geometry/color rejection, search, source verification/relinking, unchanged original bytes, print compositing, selection toolbar position, context-menu Copy, comment editing, zoom/reopen/removal and the existing excerpt workflow.

Manual checklist:

1. Select several lines near each viewport edge. Check nearby icons, tooltips, five colors and right-click Copy.
2. Save a selected-text comment, reopen its marker, edit/cancel, then restart the app and verify preservation.
3. Add a text box, image and drawing. Zoom and split the same PDF; check alignment, right-click editing/color/removal, and image replacement/size fields.
4. Narrow a split: check centered zoom and overflow tools. Verify dark inactive panel labels and centered empty-outline text.
5. Open Print, cancel once, then print a small page range or save to a new PDF. Check placement and the documented marker-only comments. Never use the source PDF as the output target.
