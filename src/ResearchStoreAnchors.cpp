#include "FileFingerprint.h"
#include "PdfAccess.h"
#include "ResearchStore.h"

#include <QFutureWatcher>
#include <QJsonDocument>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRectF>
#include <QSqlQuery>
#include <QtConcurrent>

// DocumentAnchor (spec §29): where an annotation sits, independent of how it is stored.
//   {id, documentId, source, sha256, page, rects: [{x, y, width, height}] (page-relative, from the top
//    left), bounds, quote: {exact}}
// Opening an annotation goes through revealAnchor, which verifies the PDF before moving the reader.
QVariantMap ResearchStore::anchor(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT d.id,d.url,h.sha256,h.page,h.rectangles,h.text FROM highlights h JOIN documents d ON "
                  "d.id=h.document_id WHERE h.id=? AND h.deleted_at IS NULL");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    const auto rects = QJsonDocument::fromJson(query.value(4).toByteArray()).toVariant().toList();
    QRectF bounds;
    for (const auto &value : rects) {
        const auto r = value.toMap();
        bounds = bounds.united(
            QRectF(r["x"].toDouble(), r["y"].toDouble(), r["width"].toDouble(), r["height"].toDouble()));
    }
    return {{"id", id}, {"documentId", query.value(0)}, {"source", QUrl(query.value(1).toString())},
        {"sha256", query.value(2)}, {"page", query.value(3)}, {"rects", rects},
        {"quote", QVariantMap{{"exact", query.value(5)}}},
        {"bounds",
            QVariantMap{{"x", bounds.x()}, {"y", bounds.y()}, {"width", bounds.width()}, {"height", bounds.height()}}}};
}

void ResearchStore::revealAnchor(const QVariantMap &target)
{
    const auto id = target.value("id").toString();
    const auto source = target.value("source").toUrl();
    if (source.isEmpty()) return;
    const auto b = target.value("bounds").toMap();
    const QRectF bounds(b["x"].toDouble(), b["y"].toDouble(), b["width"].toDouble(), b["height"].toDouble());
    if (bounds.isEmpty()) return;
    const auto expected = target.value("sha256").toString();
    const int page = target.value("page").toInt();
    auto *watcher = new QFutureWatcher<QString>(this);
    connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, id, source, expected, page, bounds] {
        const auto hash = watcher->result();
        watcher->deleteLater();
        // The annotation may have been deleted or relinked while the file was being checked.
        const auto now = anchor(id);
        if (now.isEmpty()) return;
        if (now.value("source").toUrl() != source) {
            revealAnchor(now);
            return;
        }
        if (hash.isEmpty()) {
            emit message("Original PDF not found. The saved annotation is preserved.");
            emit relinkRequested(source);
        } else if (hash != expected)
            emit message("The PDF changed, so the annotation's place cannot be verified. It is preserved.");
        else
            emit sourceReady(source, page, bounds);
    });
    watcher->setFuture(
        QtConcurrent::run(&m_verifiers, [source] { return FileFingerprint::sha256(source.toLocalFile()); }));
}

void ResearchStore::openHighlight(const QString &id)
{
    revealAnchor(anchor(id));
}

namespace {
// Lower case, single spaces, no quotes; line-end hyphens and soft hyphens joined. at[i] is where
// flat[i] came from in the original text.
QString flatten(const QString &text, QList<qsizetype> *at)
{
    QString flat;
    bool space = false;
    for (qsizetype i = 0; i < text.size(); ++i) {
        const auto c = text[i];
        if (c == QChar(0x00ad) || c == QChar(0x0002) || c == QChar(0xfffe)) continue;
        // "exam-\nple" is one word.
        if (c == '-' && i + 1 < text.size() && (text[i + 1] == '\n' || text[i + 1] == '\r')) {
            while (i + 1 < text.size() && text[i + 1].isSpace()) ++i;
            continue;
        }
        if (c.isSpace() || c == QChar(0x201c) || c == QChar(0x201d) || c == '"') {
            if (!flat.isEmpty() && !space) {
                flat += ' ';
                if (at) *at << i;
                space = true;
            }
            continue;
        }
        space = false;
        flat += c.toLower();
        if (at) *at << i;
    }
    return flat.trimmed();
}
} // namespace

QRectF ResearchStore::passageRegion(QPdfDocument &pdf, int page, const QString &phrase)
{
    if (page < 0 || page >= pdf.pageCount()) return {};
    const auto text = pdf.getAllText(page).text();
    QList<qsizetype> at;
    const auto flat = flatten(text, &at);
    auto words = flatten(QString(phrase).remove(QChar(0x2026)).remove("..."), nullptr).split(' ', Qt::SkipEmptyParts);
    // The whole quote, else its opening words (a model may shorten or slightly change the end).
    for (const int keep : {int(words.size()), 6, 4}) {
        if (keep > words.size() || keep < 3) continue;
        const auto needle = QStringList(words.mid(0, keep)).join(' ');
        const auto found = flat.indexOf(needle);
        if (found < 0) continue;
        const auto start = at[found], end = at[found + needle.size() - 1] + 1;
        const auto bounds = pdf.getSelectionAtIndex(page, int(start), int(end - start)).boundingRectangle();
        const auto size = pdf.pagePointSize(page);
        if (bounds.isEmpty() || size.isEmpty()) return {};
        return QRectF(bounds.x() / size.width(), bounds.y() / size.height(), bounds.width() / size.width(),
            bounds.height() / size.height())
            .intersected(QRectF(0, 0, 1, 1));
    }
    return {};
}

void ResearchStore::revealPassage(const QUrl &source, int page, const QString &phrase)
{
    const auto url = resolvedSource(source);
    if (!url.isLocalFile() || phrase.trimmed().isEmpty()) return;
    auto *watcher = new QFutureWatcher<QRectF>(this);
    connect(watcher, &QFutureWatcher<QRectF>::finished, this, [this, watcher, url, page] {
        const auto region = watcher->result();
        watcher->deleteLater();
        if (!region.isEmpty()) emit passageReady(url, page, region);
    });
    watcher->setFuture(QtConcurrent::run(&m_verifiers, [path = url.toLocalFile(), page, phrase] {
        QPdfDocument pdf;
        if (PdfAccess::load(pdf, path) != QPdfDocument::Error::None) return QRectF();
        return passageRegion(pdf, page, phrase);
    }));
}
