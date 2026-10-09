# PDF annotations

## Use

- Select text to show icons beside the selection endpoint: Highlight, Comment, Gloss and Ask AI. Hover for descriptions. The toolbar stays inside the reader and does not shift PDF layout.
- Highlight offers Blue, Yellow, Green, Pink and Purple. Line geometry follows the selection; marking the same character range again changes its color without duplicating the highlight or removing its comment.
- Comment opens an explicit Save/Cancel editor, preserving the original quote separately. Click a comment marker to reopen it. Unsaved changes require confirmation before discarding.
- Right-click the page or selected text for actions about that spot: Copy, Select All on Page, Add Comment, Highlight, AI (Gloss, Ask) and Mark Region. Paper-wide actions (Find, Print, Export, Mark as Read, Paper Details) are in the toolbar ⋯. Menus are as wide as their longest label.
- The 32px PDF toolbar centers zoom controls. On the right: annotation tools in the order Draw, Highlight (the two inks, each with its color bar), Comment, Text Box (writing), Image (inserting), Region (marking a figure, table or equation), then Notes, then ⋯ (Find, Print, Export, Mark as Read, Paper Details). Panes narrower than 600px move the annotation tools into ⋯. AI is in the AI panel, the selection icons and the right-click menu, not the toolbar.
- Highlight and Draw have separate colors, shown as a bar under each icon and remembered across restarts. Click the icon to use the current color (with a selection, Highlight applies it at once); right-click it to pick another color. Right-clicking a tool always shows its options. Comments and text boxes use the highlight color.
- Region marks a figure, table or equation: drag around it. It is kept at once as an outlined area with a faint tint; the nearest `Figure N`/`Table N` caption is stored with it (search finds it). Words inside stay selectable: a region is picked up, moved and resized by its edge, and its comment is written from a double click on the edge or right-click → Edit / Comment…. Right-click → Ask AI about This Region attaches its picture to the AI conversation. Upgrading turns old Captures into annotations: text excerpts into highlights, regions into region annotations (their notes become comments), web clips into notes with their picture.
- For page comments, text boxes and images, activate a tool then click or drag on the page. Images are copied into app storage; position and size can be edited as page percentages. Image editing applies only to app-added images, not embedded PDF content. Draw by dragging; Esc leaves the active tool.
- Right-click an existing annotation to edit its comment/text, replace an added image, change color or remove it. Drawing geometry cannot yet be reshaped. Color is chosen by right-clicking Highlight or Draw, or from an existing annotation's context menu.
- Change Color opens beside the clicked annotation, clamped inside the reader, even after text selection has cleared. The pointer is an I-beam over selectable text and an arrow in blank page space; placement modes and the AI region keep their crosshair.
- Home/Cmd+K Everything search includes highlighted quotes, comments and text-box contents (up to 20 matching annotations). Results verify the original file before navigating. The Notes filter finds annotations and notes together.

## Storage and safety

- Original PDFs are never modified. The local SQLite `highlights` table stores annotation kind, color, body, normalized rectangles, drawing points and image reference alongside source URL, SHA-256, page and quoted text. Existing databases receive additive columns with defaults.
- Saving selected text re-extracts and verifies its quote. Page annotations verify the reader's source fingerprint before saving. Loading verifies the current source off the UI thread; changed/missing PDFs do not receive stale annotations. Same-file relinking updates annotation paths transactionally.
- Added images are copied as PNG (at most 2048 pixels per side); decoding is limited to 25 megapixels. Comments/text are limited to 10,000 characters and strokes to 5,000 points. Replaced image assets are retained locally; automatic pruning is not implemented.
- HEIC/HEIF is accepted, including uppercase extensions. macOS uses ImageIO for bounded, orientation-aware decoding in both asynchronous previews and saved PNGs. On Windows/Linux, HEIC requires an installed Qt-compatible decoder; otherwise a conversion message is shown. Original image files are kept unchanged.
- Removal is soft deletion. An annotation trash UI remains future work.

## Notes beside the page

- The Notes button (toolbar, after the annotation tools) shows a column beside the page with the paper's comments and the highlights that have a note, in page order under page headings. The setting is remembered; the column appears when the pane is at least 560px wide.
- A note is linked to a selection (its quote is shown with the ink) or to a spot on the page (+, then click the page). With the column open, adding a comment or clicking a comment marker on the page writes it in the column instead of a dialog. Cmd+Return saves, Esc cancels, leaving the field saves.
- Hovering a note outlines its place on the page; clicking a note scrolls there. While reading, the column follows the current page. Right-click a note for Go to, Edit, Copy Note and Delete Note.
- Notes are the same comment annotations as on the page: search, export (Markdown, annotated PDF), print markers and undo all include them.

## Undo and redo

- Cmd+Z / Cmd+Shift+Z (Ctrl+Z / Ctrl+Y or Ctrl+Shift+Z on Linux and Windows) undo and redo, per paper, the last changes of this session: new highlights, drawings, comments, text boxes and images, color and note edits, moves and resizes, and removals. A focused text field keeps its own text undo.
- Annotations are never erased by undo: they are soft-deleted, so redo brings back the same annotation.

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
