#include "ArxivVersions.h"
#include "FileFingerprint.h"
#include "PdfAccess.h"
#include "ResearchStore.h"
#include "UiText.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QXmlStreamReader>

namespace {
constexpr qint64 day = 24 * 60 * 60;
QString cachePath(ResearchStore *store)
{
    return QDir(store->dataDirectory()).filePath("arxiv-versions.json");
}
}

ArxivVersions::ArxivVersions(ResearchStore *store, QObject *parent)
    : QObject(parent), m_store(store), m_network(new QNetworkAccessManager(this))
{
    m_readers.setMaxThreadCount(1);
    m_readers.setThreadPriority(QThread::LowPriority);
    QFile file(cachePath(store));
    if (file.open(QIODevice::ReadOnly) && file.size() <= 16 * 1024 * 1024) {
        const auto data = QJsonDocument::fromJson(file.readAll()).object();
        if (data.value("version").toInt() == 1) {
            m_entries = data.value("entries").toObject();
            m_copies = data.value("copies").toObject();
            m_newer = data.value("newer").toObject();
            m_checked = QDateTime::fromString(data.value("checked").toString(), Qt::ISODate);
        }
    }
    m_timer.setSingleShot(true);
    connect(&m_timer, &QTimer::timeout, this, &ArxivVersions::check);
    connect(store, &ResearchStore::settingsChanged, this, &ArxivVersions::configure);
    m_enabled = store->setting("library.arxivVersions") == "1";
    // A little after launch (not while the window opens); at once when turned on.
    if (m_enabled) m_timer.start(10000);
}

ArxivVersions::~ArxivVersions()
{
    ++m_generation;
    m_readers.waitForDone();
}

QString ArxivVersions::plainId(const QString &arxiv)
{
    static const QRegularExpression pattern(
        R"(^(\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?$)", QRegularExpression::CaseInsensitiveOption);
    return pattern.match(arxiv.trimmed()).captured(1);
}

int ArxivVersions::versionOf(const QString &arxiv)
{
    static const QRegularExpression version(R"(v(\d+)$)");
    return plainId(arxiv).isEmpty() ? 0 : version.match(arxiv.trimmed()).captured(1).toInt();
}

int ArxivVersions::printedVersion(const QString &text, const QString &id)
{
    if (id.isEmpty()) return 0;
    const QRegularExpression stamp(
        "arXiv\\s*:\\s*" + QRegularExpression::escape(id) + "v(\\d+)", QRegularExpression::CaseInsensitiveOption);
    return stamp.match(text).captured(1).toInt();
}

QList<ArxivVersions::Entry> ArxivVersions::parseFeed(const QByteArray &xml)
{
    QList<Entry> entries;
    QXmlStreamReader reader(xml);
    bool inEntry = false;
    while (!reader.atEnd()) {
        reader.readNext();
        if (reader.isStartElement() && reader.name() == QLatin1String("entry")) {
            inEntry = true;
        } else if (reader.isEndElement() && reader.name() == QLatin1String("entry")) {
            inEntry = false;
        } else if (inEntry && reader.isStartElement() && reader.name() == QLatin1String("id")
            && reader.namespaceUri() == QLatin1String("http://www.w3.org/2005/Atom")) {
            // http://arxiv.org/abs/2401.12345v3; an error comes as an entry with another kind of ID.
            const auto abs = reader.readElementText().trimmed().section("/abs/", 1);
            const auto id = plainId(abs);
            if (!id.isEmpty() && versionOf(abs) > 0) entries.append({id, versionOf(abs)});
        }
    }
    return entries;
}

QVariantMap ArxivVersions::details(const QString &documentId, const QString &arxiv) const
{
    const auto id = plainId(arxiv);
    if (!m_enabled || id.isEmpty()) return {};
    QVariantMap result;
    const int mine = versionOf(arxiv) ? versionOf(arxiv) : m_copies.value(documentId).toInt();
    if (mine > 0) result["arxivVersion"] = mine;
    const int latest = m_entries.value(id).toObject().value("latest").toInt();
    if (mine > 0 && latest > mine) result["arxivLatest"] = latest;
    const QUrl newer(m_newer.value(documentId).toString());
    if (newer.isLocalFile() && QFileInfo::exists(newer.toLocalFile())) result["arxivNewer"] = newer;
    return result;
}

void ArxivVersions::configure()
{
    const bool on = m_store->setting("library.arxivVersions") == "1";
    if (on == m_enabled) return;
    m_enabled = on;
    ++m_generation;
    m_pending.clear();
    m_timer.stop();
    if (m_reply) {
        auto *reply = m_reply.data();
        m_reply.clear();
        reply->abort();
    }
    emit changed();
    if (on) m_timer.start(0);
}

void ArxivVersions::check()
{
    if (!m_enabled || m_reply || !m_pending.isEmpty()) return;
    const auto now = QDateTime::currentDateTimeUtc();
    const auto elapsed = m_checked.isValid() ? m_checked.secsTo(now) : day;
    if (elapsed >= 0 && elapsed < day) {
        m_timer.start(int((day - elapsed) * 1000));
        return;
    }
    m_checked = now;
    m_timer.start(int(day * 1000));
    // Papers with an arXiv ID; and those whose copy's version is not known yet, to read from their first page.
    QSet<QString> ids;
    QList<std::tuple<QString, QString, QString>> unread;
    for (const auto &value : m_store->libraryDocuments({})) {
        const auto paper = value.toMap();
        const auto arxiv = paper.value("arxiv").toString(), id = plainId(arxiv);
        if (id.isEmpty()) continue;
        ids.insert(id);
        const auto document = paper.value("id").toString();
        if (!versionOf(arxiv) && !m_copies.contains(document))
            unread.append({document, paper.value("url").toUrl().toLocalFile(), id});
    }
    m_pending = QStringList(ids.cbegin(), ids.cend());
    m_pending.sort();
    if (unread.isEmpty()) {
        save();
        ask();
        return;
    }
    const int generation = m_generation;
    m_readers.start([this, unread, generation] {
        QJsonObject read;
        for (const auto &[document, path, id] : unread) {
            if (generation != m_generation) return;
            int version = printedVersion(QFileInfo(path).completeBaseName(), id);
            if (!version) {
                QPdfDocument pdf;
                if (PdfAccess::load(pdf, path) == QPdfDocument::Error::None && pdf.pageCount() > 0)
                    version = printedVersion(pdf.getAllText(0).text(), id);
            }
            read.insert(document, version);
        }
        QMetaObject::invokeMethod(
            this,
            [this, read, generation] {
                if (generation != m_generation) return;
                for (auto it = read.constBegin(); it != read.constEnd(); ++it) m_copies.insert(it.key(), it.value());
                save();
                emit changed();
                ask();
            },
            Qt::QueuedConnection);
    });
}

void ArxivVersions::ask()
{
    if (!m_enabled || m_reply || m_pending.isEmpty()) return;
    const auto ids = m_pending.mid(0, 100);
    m_pending = m_pending.mid(ids.size());
    const auto base = m_store->setting("arxivVersions.baseUrl", "https://export.arxiv.org/api");
    QNetworkRequest request(
        QUrl(base + "/query?id_list=" + ids.join(',') + "&max_results=" + QString::number(ids.size())));
    request.setHeader(QNetworkRequest::UserAgentHeader, "Owelk/0.1 (local research reader)");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(30000);
    auto *reply = m_network->get(request);
    m_reply = reply;
    const int generation = m_generation;
    connect(reply, &QNetworkReply::readyRead, this, [reply] {
        if (reply->bytesAvailable() > 8 * 1024 * 1024) reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation] {
        reply->deleteLater();
        if (m_reply == reply) m_reply.clear();
        if (generation != m_generation || !m_enabled) return;
        if (reply->error() != QNetworkReply::NoError
            || reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200) {
            m_pending.clear(); // Asked again at the next daily check.
            return;
        }
        const auto stamp = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
        for (const auto &entry : parseFeed(reply->readAll()))
            m_entries[entry.id] = QJsonObject{{"latest", entry.version}, {"fetched", stamp}};
        save();
        emit changed();
        // arXiv asks for three seconds between requests.
        QTimer::singleShot(3000, this, [this, generation] {
            if (generation == m_generation) ask();
        });
    });
}

void ArxivVersions::getLatest(const QUrl &source)
{
    if (!m_enabled || m_download) return;
    const auto paper = m_store->documentDetails(source);
    const auto id = plainId(paper.value("arxiv").toString());
    const auto document = m_store->documentLinkId(source);
    const int latest = m_entries.value(id).toObject().value("latest").toInt();
    if (id.isEmpty() || document.isEmpty() || latest <= 0) return;
    const auto base = m_store->setting("arxivVersions.pdfBaseUrl", "https://arxiv.org/pdf");
    const auto name = QString("%1v%2").arg(id).arg(latest);
    m_store->startTask("arxivGet", QString(ui("Downloading %1")).arg(name));
    QNetworkRequest request(QUrl(base + "/" + name));
    request.setHeader(QNetworkRequest::UserAgentHeader, "Owelk/0.1 (local research reader)");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(90000);
    auto *reply = m_network->get(request);
    m_download = reply;
    connect(reply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64 total) {
        m_store->progressTask("arxivGet", double(received), total > 0 ? double(total) : 0);
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, document, name, latest, paper] {
        reply->deleteLater();
        m_store->finishTask("arxivGet");
        const auto bytes = reply->readAll();
        if (reply->error() != QNetworkReply::NoError || !bytes.startsWith("%PDF")) {
            m_store->notify(QString(ui("Could not get %1 from arXiv.")).arg(name));
            return;
        }
        // A file of its own beside the others (an old-style ID's slash would make a folder).
        const auto file = m_store->downloadTarget(QString(name).replace('/', '_') + ".pdf", true).value("url").toUrl();
        QFile out(file.toLocalFile());
        if (!out.open(QIODevice::WriteOnly) || out.write(bytes) != bytes.size()) {
            m_store->notify(ui("Could not save the PDF."));
            return;
        }
        out.close();
        const auto hash = FileFingerprint::sha256(file.toLocalFile());
        m_store->addDocuments({file}, QString());
        const auto added = m_store->paperWithFile(file, hash);
        const auto addedId = added.isEmpty() ? QString() : m_store->documentLinkId(added);
        if (!addedId.isEmpty()) {
            m_store->addLink("document", document, "document", addedId);
            m_newer.insert(document, added.toString());
            m_copies.insert(addedId, latest);
            save();
            emit changed();
        }
        const auto title = paper.value("title").toString();
        m_store->notify(QString(ui("Added %1 of “%2” to the Library, linked to your copy."))
                .arg("v" + QString::number(latest), title.isEmpty() ? name : title));
    });
}

void ArxivVersions::save()
{
    QSaveFile file(cachePath(m_store));
    if (!file.open(QIODevice::WriteOnly)) return;
    file.write(QJsonDocument(QJsonObject{{"version", 1}, {"checked", m_checked.toString(Qt::ISODate)},
                                 {"entries", m_entries}, {"copies", m_copies}, {"newer", m_newer}})
            .toJson(QJsonDocument::Compact));
    file.commit();
}
