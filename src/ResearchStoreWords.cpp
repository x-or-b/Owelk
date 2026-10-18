#include "PdfAccess.h"
#include "ReferenceFinder.h"
#include "ResearchStore.h"
#include "UiText.h"

#include <QDateTime>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QSqlQuery>
#include <QUuid>
#include <QtConcurrent>

namespace {
QString now()
{
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}
// Where a saved word was, read from its PDF: the sentence it is in and the selection's box on its page (0..1).
struct WordPlace {
    QString sentence;
    QVariantMap anchor;
};
}

void ResearchStore::saveWord(const QVariantMap &word)
{
    const auto source = resolvedSource(word.value("source").toUrl());
    const auto term = word.value("term").toString().simplified().left(200);
    const auto meaning = word.value("meaning").toString().trimmed().left(4000);
    const int page = word.value("page").toInt();
    if (term.isEmpty() || !source.isLocalFile()) return;
    const auto from = word.value("from").toPointF(), to = word.value("to").toPointF();
    auto *watcher = new QFutureWatcher<WordPlace>(this);
    connect(watcher, &QFutureWatcher<WordPlace>::finished, this, [this, watcher, source, term, meaning, page] {
        const auto place = watcher->result();
        watcher->deleteLater();
        const auto document = ensureDocument(source);
        if (document.isEmpty()) return;
        // The same term in the same paper is one entry: saving it again gives it the newer meaning.
        QSqlQuery query(m_database);
        query.prepare("SELECT id FROM vocabulary WHERE document_id=? AND lower(term)=lower(?) AND removed_at IS NULL");
        query.addBindValue(document);
        query.addBindValue(term);
        const auto stamp = now();
        if (query.exec() && query.next()) {
            const auto id = query.value(0).toString();
            query.finish();
            query.prepare("UPDATE vocabulary SET meaning=?,updated_at=? WHERE id=?");
            for (const QVariant &value : {QVariant(meaning), QVariant(stamp), QVariant(id)}) query.addBindValue(value);
            if (!query.exec()) return;
            emit wordsChanged();
            emit wordSaved(id, true);
            return;
        }
        const auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        query.prepare("INSERT INTO vocabulary(id,term,meaning,sentence,document_id,page,anchor,created_at,updated_at) "
                      "VALUES(?,?,?,?,?,?,?,?,?)");
        for (const QVariant &value : {QVariant(id), QVariant(term), QVariant(meaning), QVariant(place.sentence),
                 QVariant(document), QVariant(page),
                 QVariant(QString::fromUtf8(
                     QJsonDocument(QJsonObject::fromVariantMap(place.anchor)).toJson(QJsonDocument::Compact))),
                 QVariant(stamp), QVariant(stamp)})
            query.addBindValue(value);
        if (!query.exec()) {
            emit message(ui("Cannot save the word."));
            return;
        }
        emit wordsChanged();
        emit wordSaved(id, false);
    });
    watcher->setFuture(QtConcurrent::run(&m_workers, [source, page, from, to] {
        WordPlace place;
        QPdfDocument pdf;
        if (PdfAccess::load(pdf, source.toLocalFile()) != QPdfDocument::Error::None || page < 0
            || page >= pdf.pageCount())
            return place;
        const auto selection = pdf.getSelection(page, from, to);
        const auto size = pdf.pagePointSize(page);
        if (const auto box = selection.boundingRectangle(); !box.isEmpty() && !size.isEmpty())
            place.anchor = {{"x", box.x() / size.width()}, {"y", box.y() / size.height()},
                {"width", box.width() / size.width()}, {"height", box.height() / size.height()}};
        const auto text = pdf.getAllText(page).text();
        const auto [start, end] = ReferenceFinder::sentenceBounds(text, selection.startIndex());
        if (start >= 0) place.sentence = text.mid(start, end - start).simplified().left(1000);
        return place;
    }));
}

QVariantList ResearchStore::words(const QString &query) const
{
    QSqlQuery rows(m_database);
    rows.prepare("SELECT v.id,v.term,v.meaning,v.sentence,v.document_id,v.page,v.created_at,d.url FROM vocabulary v "
                 "LEFT JOIN documents d ON d.id=v.document_id WHERE v.removed_at IS NULL ORDER BY v.created_at DESC");
    QVariantList list;
    if (!rows.exec()) return list;
    const auto needle = query.simplified();
    while (rows.next()) {
        const QUrl url(rows.value(7).toString());
        const auto paper = url.isEmpty() ? QString() : displayName(url);
        QVariantMap word{{"id", rows.value(0)}, {"term", rows.value(1)}, {"meaning", rows.value(2)},
            {"sentence", rows.value(3)}, {"documentId", rows.value(4)}, {"page", rows.value(5).toInt()},
            {"createdAt", rows.value(6)}, {"source", url}, {"paper", paper}};
        // Search: the term, its meaning, its sentence or its paper's name.
        if (!needle.isEmpty()) {
            bool found = false;
            for (const auto *field : {"term", "meaning", "sentence", "paper"})
                found = found || word.value(field).toString().contains(needle, Qt::CaseInsensitive);
            if (!found) continue;
        }
        list.append(word);
    }
    return list;
}

bool ResearchStore::setWordMeaning(const QString &id, const QString &meaning)
{
    QSqlQuery query(m_database);
    query.prepare("UPDATE vocabulary SET meaning=?,updated_at=? WHERE id=? AND removed_at IS NULL");
    query.addBindValue(meaning.trimmed().left(4000));
    query.addBindValue(now());
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    emit wordsChanged();
    return true;
}

int ResearchStore::removeWords(const QVariantList &ids)
{
    return markWords(ids, true);
}

int ResearchStore::restoreWords(const QVariantList &ids)
{
    return markWords(ids, false);
}

int ResearchStore::markWords(const QVariantList &ids, bool removed)
{
    int changed = 0;
    const auto stamp = now();
    QSqlQuery query(m_database);
    query.prepare(removed ? "UPDATE vocabulary SET removed_at=?,updated_at=? WHERE id=? AND removed_at IS NULL"
                          : "UPDATE vocabulary SET removed_at=NULL,updated_at=? WHERE id=? AND removed_at IS NOT NULL");
    for (const auto &id : ids) {
        if (removed) query.addBindValue(stamp);
        query.addBindValue(stamp);
        query.addBindValue(id.toString());
        if (query.exec()) changed += query.numRowsAffected();
    }
    if (changed) emit wordsChanged();
    return changed;
}
