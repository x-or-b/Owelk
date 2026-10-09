#pragma once
#include "ResearchStore.h"
#include <QSignalSpy>

// A marked region on a page of the PDF as it is now, saved through the store; its id (empty if it was
// not saved).
inline QString markRegion(
    ResearchStore &store, const QUrl &source, int page = 0, const QRectF &region = {.1, .1, .4, .2})
{
    QSignalSpy loaded(&store, &ResearchStore::highlightsLoaded), done(&store, &ResearchStore::annotationFinished);
    store.loadHighlights(source);
    if (!loaded.wait(10000)) return {};
    store.saveAnnotation(source, page,
        {{"kind", "area"}, {"sha256", loaded.last()[4]},
            {"rectangles",
                QVariantList{QVariantMap{
                    {"x", region.x()}, {"y", region.y()}, {"width", region.width()}, {"height", region.height()}}}}});
    if (!done.wait(10000) || !done.last()[0].toBool()) return {};
    return done.last()[1].toString();
}
