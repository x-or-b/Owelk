# Third-party code

Copied in (not fetched at build time) so builds work offline and stay the same.

| Folder | Project | Version | License | Used for |
| --- | --- | --- | --- | --- |
| `microtex/` | [MicroTeX](https://github.com/NanoMichael/MicroTeX) | `0e3707f` (2024-08-06); `src/` without the samples and the Cairo, GDI and Skia back ends, plus `res/fonts` | MIT (`microtex/LICENSE`); fonts: Knuth, OFL (`microtex/res/fonts/licences`) | LaTeX math in AI answers and note previews (`src/MathRenderer.cpp`) |
| `tinyxml2/` | [TinyXML-2](https://github.com/leethomason/tinyxml2) | `8224e42` | zlib (`tinyxml2/LICENSE.txt`) | MicroTeX's resource parsers |

The fonts are compiled into the app as Qt resources (`:/res/fonts/...`, where MicroTeX looks when the files are not on disk).
