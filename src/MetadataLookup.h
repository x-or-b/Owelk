#pragma once

#include <QObject>
#include <QUrl>
#include <QVariantMap>

class QNetworkAccessManager;

// Looks up bibliographic details on arXiv or Crossref. Runs only when the user asks; it sends the
// DOI, arXiv ID or title, never file contents. Results fill the details form and are not saved by themselves.
class MetadataLookup final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
public:
    explicit MetadataLookup(QObject *parent = nullptr);
    bool busy() const { return m_pending > 0; }
    // Tests point these at a local server.
    QUrl arxivBase = QUrl("https://export.arxiv.org/api/query");
    QUrl crossrefBase = QUrl("https://api.crossref.org/works");
    // Uses arxiv, then doi, then title from the given details. Returns a request number for lookupFinished.
    Q_INVOKABLE int lookup(const QVariantMap &details);
signals:
    void busyChanged();
    // details holds title, authors, year, doi, arxiv and "source" (arXiv / Crossref) when found.
    void lookupFinished(int request, const QVariantMap &details, const QString &error);

private:
    QNetworkAccessManager *m_network;
    int m_request = 0;
    int m_pending = 0;
};

namespace MetadataParse {
QVariantMap arxivAtom(const QByteArray &xml);
QVariantMap crossrefWork(const QByteArray &json);
}
