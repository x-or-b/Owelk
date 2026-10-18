#pragma once

#include <QJSValue>
#include <QObject>
#include <QPointer>
#include <QPointF>
#include <QWindow>

// Two fingers swiped sideways on a trackpad go back and forward, as in a browser. A sideways scroll that starts
// where nothing can scroll that way brings an arrow in from the edge; letting go once it is full goes. Scrolls
// the gesture does not take reach the window untouched; a mouse wheel is never taken.
class SwipeNavigation final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    Q_PROPERTY(bool enabled MEMBER m_enabled NOTIFY enabledChanged)
    // While a swipe is under way: below 0 back, above 0 forward; at ±1 the arrow is full and letting go goes.
    Q_PROPERTY(qreal progress READ progress NOTIFY progressChanged)
    // function(x, y, back, towardLeft): whether a swipe may start at that point of the window (there is somewhere to
    // go, and nothing there scrolls sideways that way). Without it, every swipe may start.
    Q_PROPERTY(QJSValue allowed READ allowed WRITE setAllowed)
public:
    using QObject::QObject;
    QJSValue allowed() const { return m_allowed; }
    Q_INVOKABLE void setAllowed(const QJSValue &value) { m_allowed = value; }
    QWindow *window() const { return m_window; }
    void setWindow(QWindow *window);
    qreal progress() const { return m_progress; }
    // macOS: "Swipe between pages" is set to two fingers in System Settings. Elsewhere false.
    Q_INVOKABLE static bool systemSwipes();
    // Whether fingers moving this way (a sideways scroll of dx) go right: the sign of dx follows the
    // fingers when the system scrolls "naturally" (inverted), and is the opposite otherwise.
    static bool fingersGoRight(qreal dx, bool inverted) { return inverted ? dx > 0 : dx < 0; }
    // How far the fingers travel, in points, for a full arrow.
    static constexpr qreal distance = 140;

signals:
    void windowChanged();
    void enabledChanged();
    void progressChanged();
    void back();
    void forward();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    enum class State { Idle, Undecided, Swiping, Done, Passing };
    void setProgress(qreal progress);
    void finish();
    QPointer<QWindow> m_window;
    bool m_enabled = false;
    QJSValue m_allowed;
    State m_state = State::Idle;
    QPointF m_moved, m_start;
    bool m_back = false;
    qreal m_travel = 0, m_progress = 0;
};
