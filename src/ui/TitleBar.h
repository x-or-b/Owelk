#pragma once

#include <QColor>
#include <QObject>
#include <QVariantList>

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
};
