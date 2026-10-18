#pragma once
#include <QDateTime>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>
#include <atomic>

class ResearchStore;
class QNetworkAccessManager;
class QNetworkReply;

// Newer arXiv versions of the papers in the Library, only once the reader turns it on (Settings › Library). Once a
// day it asks arxiv.org (its export API, 100 IDs at a time, three seconds or more apart) for the newest version of
// each paper with an arXiv ID; only those IDs leave the library. Which version a copy is comes from its arXiv ID
// when that has one ("2401.12345v2"), else from the stamp arXiv prints on the first page, read once per paper.
// "Get vN" downloads that version as a paper of its own, linked to the copy, which stays as it is with its
// annotations. Its own JSON file keeps all this out of the library's schema and its sync.
class ArxivVersions final : public QObject {
    Q_OBJECT
    // Settings › Library › Newer arXiv versions.
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)

public:
    struct Entry {
        QString id;
        int version = 0;
    };
    explicit ArxivVersions(ResearchStore *store, QObject *parent = nullptr);
    ~ArxivVersions() override;
    bool enabled() const { return m_enabled; }
    // For a Library row: {arxivVersion (this copy's), arxivLatest (when newer than it), arxivNewer (the newer
    // version's URL once it is in the Library)}; {} when off or not known.
    QVariantMap details(const QString &documentId, const QString &arxiv) const;
    // An arXiv ID without its version ("2401.12345", "hep-th/9901001"); empty when it is none.
    static QString plainId(const QString &arxiv);
    // The version an arXiv ID names ("2401.12345v3": 3), or 0.
    static int versionOf(const QString &arxiv);
    // The version arXiv's stamp on a first page names for that ID ("arXiv:2401.12345v2 [cs.LG] 3 Jan 2024"), or 0.
    static int printedVersion(const QString &text, const QString &id);
    // The entries of an answer from arXiv's API: each paper's ID and its newest version.
    static QList<Entry> parseFeed(const QByteArray &xml);
    // Downloads the newest version of a paper as a paper of its own and links the two.
    Q_INVOKABLE void getLatest(const QUrl &source);
    // Once a day: reads the versions of copies not known yet, then asks arXiv about every paper with an ID.
    void check();

signals:
    void changed();

private:
    // Follows the setting: turned off stops what is on its way.
    void configure();
    void ask();
    void save();
    ResearchStore *m_store;
    QNetworkAccessManager *m_network;
    QPointer<QNetworkReply> m_reply, m_download;
    QThreadPool m_readers;
    QTimer m_timer;
    // By arXiv ID: {latest, fetched}. By document ID: the version of that copy (0: none printed) and the newer
    // version got here.
    QJsonObject m_entries, m_copies, m_newer;
    QDateTime m_checked;
    QStringList m_pending;
    bool m_enabled = false;
    // Turned off or gone: what is on its way (also the first-page reading, on its thread) stops.
    std::atomic_int m_generation{0};
};
