# Owelk development workflow

- Work in cohesive feature-sized changes. After implementing and verifying a feature, commit its code, tests and relevant documentation. The user explicitly requested ongoing feature-based commits. Do not include unrelated pre-existing edits and do not push without a request.
- Use neutral grayscale, minimal English UI. macOS reading speed and convenient interaction take priority.
- Use `UiControls.*` and `UiTheme.js` for UI surfaces (5px corners); preserve PDF page/selection geometry. See `docs/DESIGN.md`.
- Use the Cmd+K blue accent family from `UiTheme.js` for emphasis. Keep surfaces neutral; red remains reserved for errors/destructive actions.
- Do not use computer-use MCP tools. Use offscreen automated tests; ask the user for actual desktop/trackpad checks.
- Stop and ask the user when a required decision or external permission cannot be resolved safely within the task.
- Preserve original PDFs, captures and reading state. Never silently reconnect a different PDF version.
- Build: `cmake --build build --parallel 6`
- Test: `ctest --test-dir build --output-on-failure`
- Update `docs/STATUS.md` and `docs/NEXT.md` when a development stage changes.
