#include "SwipeNavigation.h"
#include <QWheelEvent>
#include <cmath>

#ifdef Q_OS_MACOS
bool swipeTrackingEnabled();
#endif

bool SwipeNavigation::systemSwipes()
{
#ifdef Q_OS_MACOS
    return swipeTrackingEnabled();
#else
    return false;
#endif
}

void SwipeNavigation::setWindow(QWindow *window)
{
    if (m_window == window) return;
    if (m_window) m_window->removeEventFilter(this);
    m_window = window;
    m_state = State::Idle;
    setProgress(0);
    if (window) window->installEventFilter(this);
    emit windowChanged();
}

void SwipeNavigation::setProgress(qreal progress)
{
    if (qFuzzyCompare(m_progress, progress)) return;
    m_progress = progress;
    emit progressChanged();
}

void SwipeNavigation::finish()
{
    const bool go = std::abs(m_progress) >= 1;
    m_state = State::Done;
    setProgress(0);
    if (go) {
        if (m_back)
            emit back();
        else
            emit forward();
    }
}

bool SwipeNavigation::eventFilter(QObject *watched, QEvent *event)
{
    if (watched != m_window) return false;
    if (event->type() == QEvent::WindowDeactivate || event->type() == QEvent::Hide) {
        m_state = State::Idle;
        setProgress(0);
    }
    if (event->type() != QEvent::Wheel) return false;
    auto *wheel = static_cast<QWheelEvent *>(event);
    const auto phase = wheel->phase();
    if (phase == Qt::NoScrollPhase) return false;
    if (phase == Qt::ScrollBegin) {
        m_state = m_enabled ? State::Undecided : State::Passing;
        m_moved = {};
        m_travel = 0;
        m_start = wheel->position();
        setProgress(0);
    }
    if (m_state == State::Done) return true; // Including momentum and its final ScrollEnd.
    if (!m_enabled || wheel->modifiers() != Qt::NoModifier) {
        m_state = State::Passing;
        setProgress(0);
    }
    if (m_state == State::Idle || m_state == State::Passing) return false;
    if (phase == Qt::ScrollEnd || phase == Qt::ScrollMomentum) {
        if (m_state != State::Swiping) {
            m_state = State::Passing;
            return false;
        }
        finish();
        return true;
    }
    const auto delta = wheel->pixelDelta();
    m_moved += delta;
    if (m_state == State::Undecided) {
        if (std::hypot(m_moved.x(), m_moved.y()) < 10) return false;
        m_back = fingersGoRight(m_moved.x(), wheel->inverted());
        if (std::abs(m_moved.x()) < 2 * std::abs(m_moved.y())
            || (m_allowed.isCallable()
                && !m_allowed.call({m_start.x(), m_start.y(), m_back, m_moved.x() > 0}).toBool())) {
            m_state = State::Passing;
            return false;
        }
        m_state = State::Swiping;
        m_travel = std::abs(m_moved.x());
    } else {
        const qreal fingers = wheel->inverted() ? delta.x() : -delta.x();
        m_travel += m_back ? fingers : -fingers;
    }
    setProgress((m_back ? -1 : 1) * qBound(0.0, m_travel / distance, 1.0));
    return true;
}
