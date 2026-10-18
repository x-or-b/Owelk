#include "ReadingClock.h"

#include <QDateTime>
#include <QEvent>

ReadingClock::ReadingClock(QObject *parent) : QObject(parent), m_now([] { return QDateTime::currentMSecsSinceEpoch(); })
{
    m_minute.setInterval(60 * 1000);
    connect(&m_minute, &QTimer::timeout, this, &ReadingClock::flush);
    m_wake.setSingleShot(true);
    connect(&m_wake, &QTimer::timeout, this, &ReadingClock::update);
}

void ReadingClock::setSource(const QUrl &source)
{
    if (source == m_source) return;
    update();
    const auto now = m_now();
    m_source = source;
    if (!m_source.isEmpty())
        start(now);
    else
        m_reading = false;
    emit readingChanged();
    schedule(now);
}

void ReadingClock::touch()
{
    if (m_source.isEmpty()) return;
    const auto now = m_now();
    // The usual case, for every key and scroll step: only the time is kept.
    if (m_reading && now - m_touched < idleMs) {
        m_touched = now;
        return;
    }
    update();
    if (!m_reading) {
        start(now);
        emit readingChanged();
    }
    m_touched = now;
    schedule(now);
}

void ReadingClock::update()
{
    const auto now = m_now();
    if (m_reading) {
        const auto idle = m_touched + idleMs;
        count(qMin(now, idle));
        if (now >= idle) {
            m_reading = false;
            emit readingChanged();
        }
    } else if (m_stretchMs && now - m_lastRead >= breakMs) {
        m_stretchMs = 0;
        emit stretchChanged();
    }
    schedule(now);
}

void ReadingClock::flush()
{
    update();
    const QPair<QUrl, QString> current{m_source, QDateTime::fromMSecsSinceEpoch(m_now()).date().toString(Qt::ISODate)};
    for (auto it = m_pending.begin(); it != m_pending.end();) {
        const qint64 seconds = it.value() / 1000;
        if (seconds > 0) emit counted(it.key().first, it.key().second, int(seconds));
        it.value() -= seconds * 1000;
        // Less than a second left: kept only for the paper still being read today.
        if (m_reading && it.key() == current)
            ++it;
        else
            it = m_pending.erase(it);
    }
    schedule(m_now());
}

bool ReadingClock::eventFilter(QObject *watched, QEvent *event)
{
    switch (event->type()) {
    case QEvent::KeyPress:
    case QEvent::Wheel:
    case QEvent::MouseButtonPress:
    case QEvent::TouchBegin:
    case QEvent::NativeGesture:
        // Once per event, as its window receives it (the items it goes on to see it again).
        if (watched->isWindowType()) touch();
        break;
    default:
        break;
    }
    return false;
}

void ReadingClock::start(qint64 now)
{
    // Back after a break (asleep, say, when the timer would have said so): a new stretch.
    if (m_stretchMs && now - m_lastRead >= breakMs) {
        m_stretchMs = 0;
        emit stretchChanged();
    }
    m_reading = true;
    m_from = m_touched = now;
}

void ReadingClock::count(qint64 until)
{
    if (until <= m_from) return;
    const int before = stretch();
    m_stretchMs += until - m_from;
    m_lastRead = until;
    // Split at local midnight, so each day gets its own part.
    while (m_from < until) {
        const auto date = QDateTime::fromMSecsSinceEpoch(m_from).date();
        const auto end = qMin(until, date.addDays(1).startOfDay().toMSecsSinceEpoch());
        m_pending[{m_source, date.toString(Qt::ISODate)}] += end - m_from;
        m_from = end;
    }
    if (stretch() != before) emit stretchChanged();
}

void ReadingClock::schedule(qint64 now)
{
    // Sends once a minute while reading or while something is left to send.
    if (m_reading || !m_pending.isEmpty()) {
        if (!m_minute.isActive()) m_minute.start();
    } else {
        m_minute.stop();
    }
    // Wakes when reading would stop for want of use, or when a break is over.
    const qint64 at = m_reading ? m_touched + idleMs : m_stretchMs ? m_lastRead + breakMs : 0;
    if (at)
        m_wake.start(int(qBound<qint64>(0, at - now, idleMs + breakMs)));
    else
        m_wake.stop();
}
