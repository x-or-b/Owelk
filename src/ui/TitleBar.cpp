#include "TitleBar.h"

#include <QWindow>

#ifndef Q_OS_MACOS
void WindowChrome::setDragArea(QWindow *, qreal, const QVariantList &) { }
void WindowChrome::setToolbarShown(QWindow *, bool) { }
void WindowChrome::hideWindow(QWindow *window)
{
    if (window) window->hide();
}
#endif
