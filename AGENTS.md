# Owelk development workflow

- Work in cohesive feature-sized changes. After implementing and verifying a feature, commit its code, tests and relevant documentation. The user explicitly requested ongoing feature-based commits. Do not include unrelated pre-existing edits and do not push without a request.
- Use neutral grayscale, minimal English UI. macOS reading speed and convenient interaction take priority.
- Use the shared controls and the `Theme` singleton (`import Owelk.Ui`, `src/ui/Theme.cpp`) for UI surfaces, sizes and type; preserve PDF page/selection geometry. See `docs/DESIGN.md`. QML colors come only from `Theme` tokens (themes and accents are user choices); format C++ with `.clang-format`.
- Interface text goes through `qsTr("…")` in QML and JS and `ui("…")` (`src/UiText.h`) in C++; text sent to an AI provider or saved as data does not. After adding or changing interface text, run `python3 tools/hangul.py` (Settings › Appearance › Language › 한글 spells the interface in Hangul); add missing words to `tools/hangul_words.tsv`.
- Use `Theme.accent` (default blue, user-selectable) only for state and emphasis: selection, primary buttons, focus, links, progress, matches. Hover is always `Theme.hover`. Keep surfaces neutral; red remains reserved for errors/destructive actions.
- Do not use computer-use MCP tools. Use offscreen automated tests; ask the user for actual desktop/trackpad checks.
- Stop and ask the user when a required decision or external permission cannot be resolved safely within the task.
- Preserve original PDFs, annotations and reading state. Never silently reconnect a different PDF version.
- Build: `cmake --build build --parallel 6`
- Test: `ctest --test-dir build --output-on-failure`
- Update `docs/STATUS.md` and `docs/NEXT.md` when a development stage changes.
