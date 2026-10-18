#pragma once

#include <QHash>
#include <QObject>
#include <QTimer>
#include <QUrl>
#include <functional>

// Time spent reading (QML: researchStore.readingClock). It runs while source names the paper in front of
// Owelk's active window and the reader keeps using it: scrolling, a key or a click at least every two minutes.
// Two minutes without one stop it until the next. What it counts goes out once a minute, by paper and day
// (local time), through counted(). Nothing ticks while nobody reads.
class ReadingClock final : public QObject {
    Q_OBJECT
    // The paper being read; empty when none is in front or Owelk is not the active app.
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY readingChanged)
    Q_PROPERTY(bool reading READ reading NOTIFY readingChanged)
    // Seconds read since the last break; five minutes away from reading start it again.
    Q_PROPERTY(int stretch READ stretch NOTIFY stretchChanged)

public:
    static constexpr qint64 idleMs = 2 * 60 * 1000;
    static constexpr qint64 breakMs = 5 * 60 * 1000;
    explicit ReadingClock(QObject *parent = nullptr);
    QUrl source() const { return m_source; }
    void setSource(const QUrl &source);
    bool reading() const { return m_reading; }
    int stretch() const { return int(m_stretchMs / 1000); }
    // The reader was used (also taken from the application's input events, see eventFilter).
    Q_INVOKABLE void touch();
    // Counts up to now and sends all that was counted (each minute, and at quit).
    Q_INVOKABLE void flush();
    // Tests: the clock read instead of the system's, in milliseconds since the epoch; update() catches up.
    void setClock(std::function<qint64()> now) { m_now = std::move(now); }
    void update();
    // Keys, wheel turns and trackpad scrolling, clicks and gestures in Owelk's windows count as using the reader.
    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    void readingChanged();
    void stretchChanged();
    // seconds read in source on day (yyyy-MM-dd, local time).
    void counted(const QUrl &source, const QString &day, int seconds);

private:
    void start(qint64 now);
    void count(qint64 until);
    void schedule(qint64 now);
    std::function<qint64()> m_now;
    QUrl m_source;
    bool m_reading = false;
    // Counted up to here while reading; the last use; the end of the last time counted.
    qint64 m_from = 0, m_touched = 0, m_lastRead = 0;
    qint64 m_stretchMs = 0;
    // Milliseconds not sent yet, by paper and day.
    QHash<QPair<QUrl, QString>, qint64> m_pending;
    QTimer m_minute, m_wake;
};
