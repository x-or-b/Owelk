#pragma once

#include <QColor>

class QWindow;

// macOS: the title bar (traffic lights and title) shows the window's own colour with the theme's light or
// dark look, instead of the system grey. Elsewhere the system draws it.
namespace TitleBar {
#ifdef Q_OS_MACOS
void follow(QWindow *window, const QColor &color, bool dark);
#else
inline void follow(QWindow *, const QColor &, bool) { }
#endif
}
