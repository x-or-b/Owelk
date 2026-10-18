#include "ResearchStore.h"

#include <QDate>
#include <QSqlQuery>
#include <QSysInfo>
#include <QUuid>

// This computer, as reading_days knows it. A data folder copied to (or restored on) another computer gets a new
// one there, so the two never write the same rows (and their times add up instead of replacing each other).
QString ResearchStore::readingDevice()
{
    if (!m_readingDevice.isEmpty()) return m_readingDevice;
    const auto stored = [this](const QString &key) {
        QSqlQuery query(m_database);
        query.prepare("SELECT value FROM settings WHERE key=?");
        query.addBindValue(key);
        return query.exec() && query.next() ? query.value(0).toString() : QString();
    };
    const auto machine = QString::fromLatin1(QSysInfo::machineUniqueId());
    auto device = stored("reading.device");
    if (device.isEmpty() || (!machine.isEmpty() && stored("reading.machine") != machine)) {
        device = QUuid::createUuid().toString(QUuid::WithoutBraces);
        QSqlQuery save(m_database);
        save.prepare("INSERT OR REPLACE INTO settings(key,value) VALUES('reading.device',?),('reading.machine',?)");
        save.addBindValue(device);
        save.addBindValue(machine);
        if (!save.exec()) return {};
    }
    m_readingDevice = device;
    return device;
}

bool ResearchStore::recordReading(const QUrl &source, const QString &day, int seconds)
{
    if (seconds <= 0 || !QDate::fromString(day, Qt::ISODate).isValid()) return false;
    const auto id = ensureDocument(source), device = readingDevice();
    if (id.isEmpty() || device.isEmpty()) return false;
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO reading_days(device,document_id,day,seconds) VALUES(?,?,?,?) "
                  "ON CONFLICT(device,document_id,day) DO UPDATE SET seconds=seconds+excluded.seconds");
    query.addBindValue(device);
    query.addBindValue(id);
    query.addBindValue(day);
    query.addBindValue(seconds);
    if (!query.exec()) return false;
    ++m_readingRevision;
    emit readingSaved();
    return true;
}

QVariantMap ResearchStore::readingCalendar(int days) const
{
    const auto today = QDate::currentDate();
    days = qBound(1, days, 400);
    const auto first = today.addDays(1 - days);
    QHash<QString, QPair<qint64, int>> read;
    QSqlQuery query(m_database);
    query.prepare("SELECT day,sum(seconds),count(DISTINCT document_id) FROM reading_days WHERE day>=? GROUP BY day");
    query.addBindValue(first.toString(Qt::ISODate));
    if (query.exec())
        while (query.next())
            read.insert(query.value(0).toString(), {query.value(1).toLongLong(), query.value(2).toInt()});
    QVariantList list;
    qint64 week = 0;
    for (int i = 0; i < days; ++i) {
        const auto key = first.addDays(i).toString(Qt::ISODate);
        const auto [seconds, papers] = read.value(key);
        list.append(QVariantMap{{"day", key}, {"seconds", seconds}, {"papers", papers}});
        if (i >= days - 7) week += seconds;
    }
    // Days in a row with a minute or more of reading, up to today; before today's first minute, up to yesterday.
    int streak = 0;
    auto expected = today;
    QSqlQuery daysRead(m_database);
    if (daysRead.exec("SELECT day FROM reading_days GROUP BY day HAVING sum(seconds)>=60 ORDER BY day DESC"))
        while (daysRead.next()) {
            const auto date = QDate::fromString(daysRead.value(0).toString(), Qt::ISODate);
            // Ahead of this computer's date (another computer in a later time zone): not counted.
            if (date > expected) continue;
            if (date == expected || (streak == 0 && expected == today && date == today.addDays(-1))) {
                ++streak;
                expected = date.addDays(-1);
                continue;
            }
            break;
        }
    return {
        {"days", list}, {"streak", streak}, {"today", read.value(today.toString(Qt::ISODate)).first}, {"week", week}};
}

int ResearchStore::readingSeconds(const QUrl &source) const
{
    const auto id = findDocument(source);
    if (id.isEmpty()) return 0;
    QSqlQuery query(m_database);
    query.prepare("SELECT coalesce(sum(seconds),0) FROM reading_days WHERE document_id=?");
    query.addBindValue(id);
    return query.exec() && query.next() ? query.value(0).toInt() : 0;
}
