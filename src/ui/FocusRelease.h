#pragma once

#include <QEvent>
#include <QMouseEvent>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>

// A press anywhere outside a text box that asks for it (property releaseFocusOnOutsidePress: true) takes the
// keyboard focus away from it, as clicking elsewhere does in a browser. Presses inside the items it names in
// keepFocusWithin (its results, its buttons) leave it be. Installed on the application.
class FocusRelease : public QObject {
public:
    using QObject::QObject;

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() != QEvent::MouseButtonPress) return false;
        auto *window = qobject_cast<QQuickWindow *>(watched);
        auto *focus = window ? window->activeFocusItem() : nullptr;
        if (!focus || !focus->property("releaseFocusOnOutsidePress").toBool()) return false;
        const auto at = static_cast<QMouseEvent *>(event)->scenePosition();
        const auto inside
            = [&at](QQuickItem *item) { return item && item->isVisible() && item->contains(item->mapFromScene(at)); };
        if (inside(focus)) return false;
        for (const auto &value : focus->property("keepFocusWithin").toList())
            if (inside(value.value<QQuickItem *>())) return false;
        window->contentItem()->forceActiveFocus(Qt::MouseFocusReason);
        return false;
    }
};
