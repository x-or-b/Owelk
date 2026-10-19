#include "ResearchStore.h"

#include <QDate>
#include <algorithm>
#include <functional>
#include <QSet>
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

QHash<QString, QString> ResearchStore::mergedPapers() const
{
    QHash<QString, QString> merged;
    QSqlQuery query(m_database);
    // Kept by sync once it has been on (LibrarySync.cpp); none before.
    if (!query.exec("SELECT from_id,to_id FROM sync_alias WHERE kind='document'")) return merged;
    while (query.next()) merged.insert(query.value(0).toString(), query.value(1).toString());
    // Each to the paper it is now, also when it was merged more than once.
    for (auto it = merged.begin(); it != merged.end(); ++it)
        for (int hop = 0; hop < 8 && merged.contains(it.value()); ++hop) it.value() = merged.value(it.value());
    return merged;
}

QHash<QString, QHash<QString, qint64>> ResearchStore::readingByDay(const QString &since) const
{
    // By computer, paper (as merged) and day, one row's seconds: the largest where there are several. A computer's
    // own rows move with a merged paper there, and elsewhere the old row can stay beside the moved one: the same
    // reading twice, never two readings (two copies read the same day were added up where they were read).
    const auto merged = mergedPapers();
    QHash<QString, qint64> rows;
    QSqlQuery query(m_database);
    query.prepare("SELECT device,document_id,day,seconds FROM reading_days WHERE day>=?");
    query.addBindValue(since.isEmpty() ? QStringLiteral("0") : since);
    if (query.exec())
        while (query.next()) {
            const auto id = query.value(1).toString();
            const auto key = query.value(0).toString() + '\n' + merged.value(id, id) + '\n' + query.value(2).toString();
            rows[key] = qMax(rows.value(key), query.value(3).toLongLong());
        }
    QHash<QString, QHash<QString, qint64>> days;
    for (auto it = rows.cbegin(); it != rows.cend(); ++it) {
        const auto parts = it.key().split('\n');
        days[parts[2]][parts[1]] += it.value();
    }
    return days;
}

QHash<QString, qint64> ResearchStore::readingTotals() const
{
    QHash<QString, qint64> totals;
    for (const auto &papers : readingByDay(QString()))
        for (auto it = papers.cbegin(); it != papers.cend(); ++it) totals[it.key()] += it.value();
    return totals;
}

QVariantMap ResearchStore::readingCalendar(int days) const
{
    const auto today = QDate::currentDate();
    days = qBound(1, days, 400);
    const auto first = today.addDays(1 - days);
    const auto read = readingByDay(QString());
    const auto total = [&read](const QString &day) {
        qint64 seconds = 0;
        for (const auto value : read.value(day)) seconds += value;
        return seconds;
    };
    QVariantList list;
    qint64 week = 0;
    for (int i = 0; i < days; ++i) {
        const auto key = first.addDays(i).toString(Qt::ISODate);
        list.append(QVariantMap{{"day", key}, {"seconds", total(key)}, {"papers", read.value(key).size()}});
        if (i >= days - 7) week += total(key);
    }
    // Days in a row with a minute or more of reading, up to today; before today's first minute, up to yesterday.
    int streak = 0;
    auto expected = today;
    QStringList daysRead;
    for (auto it = read.cbegin(); it != read.cend(); ++it)
        if (total(it.key()) >= 60) daysRead << it.key();
    std::sort(daysRead.begin(), daysRead.end(), std::greater<>());
    for (const auto &day : std::as_const(daysRead)) {
        const auto date = QDate::fromString(day, Qt::ISODate);
        // Ahead of this computer's date (another computer in a later time zone): not counted.
        if (date > expected) continue;
        if (date == expected || (streak == 0 && expected == today && date == today.addDays(-1))) {
            ++streak;
            expected = date.addDays(-1);
            continue;
        }
        break;
    }
    qint64 previousWeek = 0;
    for (int ago = 7; ago < 14; ++ago) previousWeek += total(today.addDays(-ago).toString(Qt::ISODate));
    return {{"days", list}, {"streak", streak}, {"today", total(today.toString(Qt::ISODate))}, {"week", week},
        {"previousWeek", previousWeek}};
}

QVariantList ResearchStore::readingPapers(const QString &from, const QString &to) const
{
    QHash<QString, qint64> seconds;
    const auto read = readingByDay(from);
    for (auto day = read.cbegin(); day != read.cend(); ++day)
        if (day.key() <= to)
            for (auto it = day.value().cbegin(); it != day.value().cend(); ++it) seconds[it.key()] += it.value();
    QVariantList papers;
    QSqlQuery query(m_database);
    query.prepare("SELECT url FROM documents WHERE id=? AND removed_at IS NULL AND trashed_at IS NULL");
    for (auto it = seconds.cbegin(); it != seconds.cend(); ++it) {
        query.addBindValue(it.key());
        const QUrl url = query.exec() && query.next() ? QUrl(query.value(0).toString()) : QUrl();
        query.finish();
        papers.append(QVariantMap{{"documentId", it.key()}, {"seconds", it.value()}, {"source", url},
            {"name", url.isEmpty() ? QString() : displayName(url)}});
    }
    std::sort(papers.begin(), papers.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap().value("seconds").toLongLong() > b.toMap().value("seconds").toLongLong();
    });
    return papers;
}

int ResearchStore::readingSeconds(const QUrl &source) const
{
    const auto id = findDocument(source);
    return id.isEmpty() ? 0 : int(readingTotals().value(id));
}
