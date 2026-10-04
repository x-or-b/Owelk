# PDF annotations

## Use

- Select text to show three icons beside the selection endpoint: Highlight, Comment and Save Excerpt. Hover for descriptions. The toolbar stays inside the reader and does not shift PDF layout.
- Highlight offers Blue, Yellow, Green, Pink and Purple. Line geometry follows the selection; marking the same character range again changes its color without duplicating the highlight or removing its comment.
- Comment opens an explicit Save/Cancel editor, preserving the original quote separately. Click a comment marker to reopen it. Unsaved changes require confirmation before discarding.
- Right-click selected text for Copy, Select All on Page, Add Comment to Selection, Highlight Selection, Save Excerpt, AI actions, Capture a Region, Print and Export (Annotated PDF, Highlights and Captures as Markdown). Menus are as wide as their longest label.
- The 32px PDF toolbar centers zoom controls. On the right: annotation tools (Highlight, Draw, Comment, Text Box, Image), Capture a Region, then ⋯ (Find, Print, Export, Mark as Read, Paper Details). Panes narrower than 600px move the annotation tools into ⋯. AI is in the AI panel, the selection icons and the right-click menu, not the toolbar.
- Highlight and Draw have separate colors, shown as a bar under each icon and remembered across restarts. Click the icon to use the current color (with a selection, Highlight applies it at once); the small arrow beside it picks another color. Comments and text boxes use the highlight color.
- For page comments, text boxes and images, activate a tool then click or drag on the page. Images are copied into app storage; position and size can be edited as page percentages. Image editing applies only to app-added images, not embedded PDF content. Draw by dragging; Esc leaves the active tool.
- Right-click an existing annotation to edit its comment/text, replace an added image, change color or remove it. Drawing geometry cannot yet be reshaped. Color is chosen with the arrow beside Highlight or Draw, or an existing annotation's context menu.
- Change Color opens beside the clicked annotation, clamped inside the reader, even after text selection has cleared. The pointer is an I-beam over selectable text and an arrow in blank page space; capture/placement modes keep their crosshair.
- Home/Cmd+K Everything search includes highlighted quotes, comments and text-box contents (up to 20 matching annotations). Results verify the original file before navigating. PDF Text/Captures filters retain their existing meaning.

## Storage and safety

- Original PDFs are never modified. The local SQLite `highlights` table stores annotation kind, color, body, normalized rectangles, drawing points and image reference alongside source URL, SHA-256, page and quoted text. Existing databases receive additive columns with defaults.
- Saving selected text re-extracts and verifies its quote. Page annotations verify the reader's source fingerprint before saving. Loading verifies the current source off the UI thread; changed/missing PDFs do not receive stale annotations. Same-file relinking updates annotation paths transactionally.
- Added images are copied as PNG (at most 2048 pixels per side); decoding is limited to 25 megapixels. Comments/text are limited to 10,000 characters and strokes to 5,000 points. Replaced image assets are retained locally; automatic pruning is not implemented.
- HEIC/HEIF is accepted, including uppercase extensions. macOS uses ImageIO for bounded, orientation-aware decoding in both asynchronous previews and saved PNGs. On Windows/Linux, HEIC requires an installed Qt-compatible decoder; otherwise a conversion message is shown. Original image files are kept unchanged.
- Removal is soft deletion. Annotation trash/undo UI, multi-page selection and native editable PDF annotation export remain future work. Captures' trash does not restore annotations.

## Printing

- Print (⋯ or right-click) opens the native dialog and prints the PDF with current app annotations. When no printer is set up, Qt cannot show the macOS print panel, so Owelk asks where to save a printable PDF instead (same pages and annotations). Rendering is page-by-page in a worker; cancellation and source fingerprint checks are supported. Finish/cancel printing before closing the app.
- Output is rasterized at the printer resolution, capped at 300 dpi; for editable annotations use Export Annotated PDF. Comments print as markers, not their full note text. Choose a different output file when saving as PDF; the app rejects the original source path and its symlink aliases.
- Offscreen tests cover the print dialog (or, without a printer, the save dialog: cancel, save all pages, refuse the original), plus the annotation compositor. Native macOS dialogs and actual printer output still require manual testing. PDF source switches refresh fingerprint verification even when loading completes synchronously. Already-open print dialogs, unavailable source verification and an outdated non-widget app now have distinct messages; fully quit and reopen the rebuilt app before testing.

## Checks

Automated targeted checks: colored annotation persistence, comments preserving source quotes, text-box edits, image copying, drawings, invalid geometry/color rejection, search, source verification/relinking, unchanged original bytes, print compositing, selection toolbar position, context-menu Copy, comment editing, zoom/reopen/removal and the existing excerpt workflow.

Manual checklist:

1. Select several lines near each viewport edge. Check nearby icons, tooltips, five colors and right-click Copy.
2. Save a selected-text comment, reopen its marker, edit/cancel, then restart the app and verify preservation.
3. Add a text box, image and drawing. Zoom and split the same PDF; check alignment, right-click editing/color/removal, and image replacement/size fields.
4. Narrow a split: check centered zoom and overflow tools. Verify dark inactive panel labels and centered empty-outline text.
5. Open Print, cancel once, then print a small page range or save to a new PDF. Check placement and the documented marker-only comments. Never use the source PDF as the output target.
