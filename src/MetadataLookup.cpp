#include "MetadataLookup.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QUrlQuery>
#include <QXmlStreamReader>

namespace MetadataParse {
QVariantMap arxivAtom(const QByteArray &xml)
{
    QXmlStreamReader reader(xml);
    QVariantMap result;
    QStringList authors;
    bool entry = false, author = false;
    while (!reader.atEnd()) {
        reader.readNext();
        if (reader.isStartElement()) {
            const auto name = reader.name();
            if (name == QLatin1String("entry"))
                entry = true;
            else if (entry && name == QLatin1String("author"))
                author = true;
            else if (entry && author && name == QLatin1String("name"))
                authors.append(reader.readElementText().simplified());
            else if (entry && !author && name == QLatin1String("title"))
                result.insert("title", reader.readElementText().simplified());
            else if (entry && name == QLatin1String("published"))
                result.insert("year", reader.readElementText().left(4));
            else if (entry && name == QLatin1String("id")) {
                static const QRegularExpression id("abs/(.+?)(v\\d+)?$");
                result.insert("arxiv", id.match(reader.readElementText()).captured(1));
            } else if (entry && name == QLatin1String("doi"))
                result.insert("doi", reader.readElementText().simplified());
        } else if (reader.isEndElement()) {
            if (reader.name() == QLatin1String("author")) author = false;
            if (reader.name() == QLatin1String("entry")) break; // First entry only.
        }
    }
    // arXiv answers an unknown ID with an "Error" entry.
    if (result.value("title").toString().isEmpty() || result.value("title").toString() == QLatin1String("Error"))
        return {};
    result.insert("authors", authors.join(", "));
    result.insert("source", "arXiv");
    return result;
}

QVariantMap crossrefWork(const QByteArray &json)
{
    const auto message = QJsonDocument::fromJson(json).object().value("message").toObject();
    // A /works?query answer lists items; a /works/<doi> answer is the work itself.
    const auto work = message.contains("items") ? message.value("items").toArray().first().toObject() : message;
    const auto title = work.value("title").toArray().first().toString().simplified();
    if (title.isEmpty()) return {};
    QStringList authors;
    for (const auto &value : work.value("author").toArray()) {
        const auto person = value.toObject();
        const auto name = (person.value("given").toString() + ' ' + person.value("family").toString()).simplified();
        if (!name.isEmpty()) authors.append(name);
    }
    QString year;
    for (const auto *key : {"published-print", "published-online", "issued", "created"}) {
        const auto parts = work.value(key).toObject().value("date-parts").toArray().first().toArray();
        if (!parts.isEmpty()) {
            year = QString::number(parts.first().toInt());
            break;
        }
    }
    return {{"title", title}, {"authors", authors.join(", ")}, {"year", year}, {"doi", work.value("DOI").toString()},
        {"source", "Crossref"}};
}
}

MetadataLookup::MetadataLookup(QObject *parent) : QObject(parent), m_network(new QNetworkAccessManager(this)) { }

int MetadataLookup::lookup(const QVariantMap &details)
{
    const int request = ++m_request;
    const auto arxiv = details.value("arxiv").toString().trimmed(), doi = details.value("doi").toString().trimmed(),
               title = details.value("title").toString().simplified();
    QUrl url;
    bool atom = false;
    if (!arxiv.isEmpty()) {
        url = arxivBase;
        url.setQuery(QUrlQuery{{"id_list", arxiv}});
        atom = true;
    } else if (!doi.isEmpty()) {
        url = crossrefBase;
        url.setPath(url.path() + "/" + QString::fromLatin1(QUrl::toPercentEncoding(doi, "/")));
    } else if (title.size() >= 8) {
        url = crossrefBase;
        url.setQuery(QUrlQuery{{"query.bibliographic", title}, {"rows", "1"}});
    } else {
        QMetaObject::invokeMethod(
            this, [this, request] { emit lookupFinished(request, {}, "Add a DOI, arXiv ID or title first."); },
            Qt::QueuedConnection);
        return request;
    }
    QNetworkRequest call(url);
    call.setHeader(QNetworkRequest::UserAgentHeader, "Owelk/0.1 (local research reader)");
    call.setTransferTimeout(15000);
    ++m_pending;
    emit busyChanged();
    auto *reply = m_network->get(call);
    connect(reply, &QNetworkReply::finished, this, [this, reply, request, atom] {
        reply->deleteLater();
        --m_pending;
        emit busyChanged();
        if (reply->error() != QNetworkReply::NoError) {
            emit lookupFinished(request, {}, "Lookup failed: " + reply->errorString());
            return;
        }
        const auto body = reply->readAll();
        const auto details = atom ? MetadataParse::arxivAtom(body) : MetadataParse::crossrefWork(body);
        emit lookupFinished(
            request, details, details.isEmpty() ? QStringLiteral("No matching paper was found.") : QString());
    });
    return request;
}
