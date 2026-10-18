#pragma once

#include <QColor>
#include <QObject>
#include <QVariantList>

class QWindow;

// The title bar takes the window's own colour with the theme's light or dark look: macOS (behind the traffic
// lights), Windows 11 (the caption colour; Windows 10 only light or dark). Linux desktops draw their own.
namespace TitleBar {
#if defined(Q_OS_MACOS) || defined(Q_OS_WIN)
void follow(QWindow *window, const QColor &color, bool dark);
#else
inline void follow(QWindow *, const QColor &, bool) { }
#endif
}

// What QML tells the window about its title bar (QML: windowChrome).
class WindowChrome : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    // macOS: a press in the top `height` points of the window, away from `controls` ({x, y, width, height} in
    // window coordinates) and the traffic lights, moves the window as a title bar does, also while another
    // window is in front; a double-click zooms or minimises it as System Settings says. Handled where macOS
    // delivers the press, since a move asked for later is often ignored. Elsewhere nothing happens.
    Q_INVOKABLE void setDragArea(QWindow *window, qreal height, const QVariantList &controls);
    // macOS: the empty toolbar that sizes the title bar shows (false in full screen, where macOS would otherwise keep a
    // blank strip above the window's content). Elsewhere nothing happens.
    Q_INVOKABLE void setToolbarShown(QWindow *window, bool shown);
    // Hides the window. macOS: one in full screen leaves it first and hides once that is over (hidden at once, it
    // would leave an empty full-screen space behind).
    Q_INVOKABLE void hideWindow(QWindow *window);
    // macOS: the window, shown and made active next, comes to the desktop (Space) in front instead of the screen
    // going to the one it is on. Not a full-screen window, which is a desktop of its own. Elsewhere nothing happens.
    Q_INVOKABLE void bringToThisDesktop(QWindow *window);
};
