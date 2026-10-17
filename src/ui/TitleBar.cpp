#include "TitleBar.h"

#ifndef Q_OS_MACOS
void WindowChrome::setDragArea(QWindow *, qreal, const QVariantList &) { }
void WindowChrome::setToolbarShown(QWindow *, bool) { }
#endif
