#pragma once
#include <QDateTime>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantMap>

class ResearchStore;
class QNetworkAccessManager;
class QNetworkReply;

// Summaries (TL;DR) and citation counts for Library rows from Semantic Scholar, only once the reader turns them on
// (Settings › Library). Only DOI or arXiv IDs leave the library. Its own JSON file in the data folder keeps them
// out of the library's schema and its sync.
class LibraryInsights final : public QObject {
    Q_OBJECT
    // Settings › Library › Summaries and citation counts.
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
public:
    explicit LibraryInsights(ResearchStore *store, QObject *parent = nullptr);
    bool enabled() const;
    // {tldr, citationCount} known for that paper; {} when off or not known.
    QVariantMap details(const QString &doi, const QString &arxiv) const;
    // "DOI:…" or "ARXIV:…" (no version), as Semantic Scholar takes them; empty without either.
    static QString identifier(const QString &doi, const QString &arxiv);
    // Once a day: asks, 500 at a time, for the papers not asked about in the last 30 days.
    void check();
signals:
    void changed();

private:
    // Follows the setting: turned off stops the request on its way.
    void configure();
    void next();
    void save();
    ResearchStore *m_store;
    QNetworkAccessManager *m_network;
    QPointer<QNetworkReply> m_reply;
    QTimer m_timer;
    QJsonObject m_entries;
    QDateTime m_checked;
    QStringList m_pending;
    bool m_enabled = false;
    int m_generation = 0;
};
