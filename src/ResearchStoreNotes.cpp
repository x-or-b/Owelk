#include "ResearchStore.h"
#include "MathRenderer.h"
#include <QDir>
#include <QStandardPaths>
#include <QProcess>
#include "PdfAccess.h"
#include <memory>
#include <algorithm>
#include "SemanticIndex.h"
#include "PaperIndex.h"

#include <QColor>
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QImageReader>
#include <QTextDocument>
#include <QRegularExpression>
#include <QSet>
#include <QSqlQuery>
#include <QUuid>

namespace {
QString now()
{
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}
const QStringList linkKinds{"note", "highlight", "document", "ai"};
QString text(const QString &value)
{
    return value.isNull() ? QStringLiteral("") : value;
}
}

QString ResearchStore::createNote(const QString &title, const QString &body)
{
    const auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO notes(id,title,body,created_at,updated_at) VALUES(?,?,?,?,?)");
    query.addBindValue(id);
    query.addBindValue(text(title.simplified().left(200)));
    query.addBindValue(text(body.left(200000)));
    query.addBindValue(now());
    query.addBindValue(now());
    if (!query.exec()) {
        emit message("Cannot create note.");
        return {};
    }
    syncNoteLinks(id, body);
    emit notesChanged();
    return id;
}

QVariantMap ResearchStore::note(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT title,body,created_at,updated_at,deleted_at FROM notes WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    return {{"id", id}, {"title", query.value(0)}, {"body", query.value(1)}, {"createdAt", query.value(2)},
        {"updatedAt", query.value(3)}, {"deleted", !query.value(4).isNull()}};
}

bool ResearchStore::saveNote(const QString &id, const QString &title, const QString &body)
{
    if (body.size() > 200000) {
        emit message("Notes can contain up to 200,000 characters.");
        return false;
    }
    QSqlQuery query(m_database);
    query.prepare("UPDATE notes SET title=?,body=?,updated_at=? WHERE id=? AND deleted_at IS NULL");
    query.addBindValue(text(title.simplified().left(200)));
    query.addBindValue(text(body));
    query.addBindValue(now());
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) {
        emit message("Cannot save note. It may have been deleted.");
        return false;
    }
    syncNoteLinks(id, body);
    emit notesChanged();
    return true;
}

QVariantList ResearchStore::notes(bool trashed) const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    query.exec(QStringLiteral(
        "SELECT id,title,substr(body,1,240),updated_at,deleted_at FROM notes WHERE deleted_at IS %1 NULL "
        "ORDER BY %2 DESC")
            .arg(trashed ? "NOT" : "", trashed ? "deleted_at" : "updated_at"));
    while (query.next())
        rows.append(QVariantMap{{"id", query.value(0)},
            {"title", query.value(1).toString().isEmpty() ? "Untitled note" : query.value(1)},
            {"snippet", query.value(2).toString().simplified()}, {"updatedAt", query.value(3)},
            {"deletedAt", query.value(4)}});
    return rows;
}

bool ResearchStore::deleteNote(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("UPDATE notes SET deleted_at=? WHERE id=? AND deleted_at IS NULL");
    query.addBindValue(now());
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    emit notesChanged();
    emit message("Note moved to trash.");
    return true;
}

bool ResearchStore::restoreNote(const QString &id)
{
    QSqlQuery query(m_database);
    query.prepare("UPDATE notes SET deleted_at=NULL WHERE id=? AND deleted_at IS NOT NULL");
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    emit notesChanged();
    return true;
}

bool ResearchStore::purgeNote(const QString &id)
{
    // Only a note already in trash can be deleted permanently; links from and to it go with it.
    if (!m_database.transaction()) return false;
    QSqlQuery query(m_database);
    query.prepare("DELETE FROM notes WHERE id=? AND deleted_at IS NOT NULL");
    query.addBindValue(id);
    const bool removed = query.exec() && query.numRowsAffected() == 1;
    QSqlQuery links(m_database);
    links.prepare("DELETE FROM links WHERE (from_kind='note' AND from_id=?) OR (to_kind='note' AND to_id=?)");
    links.addBindValue(id);
    links.addBindValue(id);
    if (!removed || !links.exec() || !m_database.commit()) {
        m_database.rollback();
        return false;
    }
    emit notesChanged();
    return true;
}

// Links written into a note body as owelk://<kind>/<id> are the note's outgoing links.
void ResearchStore::syncNoteLinks(const QString &noteId, const QString &body)
{
    static const QRegularExpression link("owelk://(note|highlight|document|ai)/([A-Za-z0-9\\-]+)");
    QSet<QPair<QString, QString>> targets;
    for (auto it = link.globalMatch(body); it.hasNext();) {
        const auto match = it.next();
        if (!(match.captured(1) == "note" && match.captured(2) == noteId))
            targets.insert({match.captured(1), match.captured(2)});
    }
    if (!m_database.transaction()) return;
    QSqlQuery clear(m_database);
    clear.prepare("DELETE FROM links WHERE from_kind='note' AND from_id=?");
    clear.addBindValue(noteId);
    bool ok = clear.exec();
    for (const auto &target : targets) {
        QSqlQuery add(m_database);
        add.prepare("INSERT OR IGNORE INTO links VALUES('note',?,?,?,?)");
        add.addBindValue(noteId);
        add.addBindValue(target.first);
        add.addBindValue(target.second);
        add.addBindValue(now());
        ok = ok && add.exec();
    }
    if (!ok || !m_database.commit())
        m_database.rollback();
    else
        emit linksChanged();
}

bool ResearchStore::addLink(const QString &fromKind, const QString &fromId, const QString &toKind, const QString &toId)
{
    if (!linkKinds.contains(fromKind) || !linkKinds.contains(toKind) || fromId.isEmpty() || toId.isEmpty()
        || (fromKind == toKind && fromId == toId))
        return false;
    QSqlQuery query(m_database);
    query.prepare("INSERT OR IGNORE INTO links VALUES(?,?,?,?,?)");
    for (const auto &value : {fromKind, fromId, toKind, toId, now()}) query.addBindValue(value);
    if (!query.exec()) return false;
    emit linksChanged();
    return true;
}

QString ResearchStore::documentLinkId(const QUrl &source)
{
    return ensureDocument(source);
}

namespace {
struct MathSpan {
    QString latex, original;
    bool display;
};

// Math is taken out before the Markdown is read (its _, * and \\ would turn into emphasis and line
// breaks) and comes back as images. Code blocks and `code` are left alone. The rules follow Pandoc:
// $…$ needs no space just inside and no digit right after (so "$5 and $10" stays text); $$…$$,
// \[…\] and \(…\) always count. An unclosed formula (an answer still streaming) stays text.
QString takeMath(const QString &markdown, QList<MathSpan> *found)
{
    static const QRegularExpression code(R"((?ms)^[ \t]*(```|~~~)[^\n]*\n.*?^[ \t]*\1[ \t]*$|`[^`\n]+`)");
    static const QRegularExpression math(R"(\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\))"
                                         R"(|(?<![\\$\w])\$(?![\s$])((?:\\.|[^$\\\n])+?)(?<![\s\\])\$(?!\d))");
    QList<QPair<qsizetype, qsizetype>> skip;
    for (auto it = code.globalMatch(markdown); it.hasNext();) {
        const auto m = it.next();
        skip.append({m.capturedStart(), m.capturedEnd()});
    }
    QString out;
    qsizetype last = 0;
    for (auto it = math.globalMatch(markdown); it.hasNext();) {
        const auto m = it.next();
        const bool inCode = std::any_of(skip.cbegin(), skip.cend(),
            [&](const auto &range) { return m.capturedStart() < range.second && m.capturedEnd() > range.first; });
        if (inCode || m.capturedStart() < last) continue;
        int group = 1;
        while (group < 4 && m.capturedStart(group) < 0) ++group;
        out += markdown.mid(last, m.capturedStart() - last);
        out += QStringLiteral("OWELKMATH%1X").arg(found->size());
        found->append({m.captured(group), m.captured(), group <= 2});
        last = m.capturedEnd();
    }
    return found->isEmpty() ? markdown : out + markdown.mid(last);
}

// Pictures (![](…)): Qt's Markdown reader leaves them out, so they are taken out first and put back
// after it. Only files on this computer are shown, never fetched from the web; annotations/… is
// relative to the data folder (clips kept with the library).
QString takePictures(const QString &markdown, const QString &directory, QStringList *found)
{
    static const QRegularExpression picture(R"(!\[[^\]\n]*\]\(([^)\s]+)\))");
    QString out;
    qsizetype last = 0;
    for (auto it = picture.globalMatch(markdown); it.hasNext();) {
        const auto m = it.next();
        const auto target = m.captured(1);
        const auto url
            = target.startsWith("annotations/") ? QUrl::fromLocalFile(directory + "/" + target) : QUrl(target);
        if (!url.isLocalFile()) continue;
        out += markdown.mid(last, m.capturedStart() - last) + QStringLiteral("OWELKPICTURE%1X").arg(found->size());
        found->append(url.toString());
        last = m.capturedEnd();
    }
    return found->isEmpty() ? markdown : out + markdown.mid(last);
}
} // namespace

QString ResearchStore::markdownHtml(
    const QString &markdown, const QString &linkColor, const QString &textColor, int pixelSize) const
{
    QList<MathSpan> math;
    QStringList pictures;
    const auto prepared = takePictures(takeMath(markdown, &math), m_directory, &pictures);
    // Markdown rendered as rich text bakes Qt's default link blue into the HTML; use the app accent instead.
    QTextDocument document;
    document.setMarkdown(prepared);
    auto html = document.toHtml();
    static const QRegularExpression blue("color:\\s*#0000ff", QRegularExpression::CaseInsensitiveOption);
    if (QColor::isValidColorName(linkColor)) html.replace(blue, "color:" + linkColor);
    for (qsizetype i = 0; i < pictures.size(); ++i) {
        // At its own size, up to a column's width; the height follows.
        const auto size = QImageReader(QUrl(pictures[i]).toLocalFile()).size();
        html.replace(QStringLiteral("OWELKPICTURE%1X").arg(i),
            QStringLiteral("<img src=\"%1\" width=\"%2\" />")
                .arg(pictures[i].toHtmlEscaped())
                .arg(size.isValid() ? std::min(size.width(), 480) : 320));
    }
    if (math.isEmpty()) return html;
    const QColor ink = QColor::isValidColorName(textColor) ? QColor(textColor) : QColor("#1d1d1f");
    const int size = pixelSize > 0 ? pixelSize : 14;
    const auto image = [&](int index, bool display) {
        const auto &span = math[index];
        QSize shown;
        const auto key = MathRenderer::render(span.latex, display, size, ink, &shown);
        if (key.isEmpty()) return span.original.toHtmlEscaped(); // Unreadable: shown as written.
        return QStringLiteral("<img src=\"image://math/%1\" width=\"%2\" height=\"%3\" align=\"middle\" />")
            .arg(key)
            .arg(shown.width())
            .arg(shown.height());
    };
    // A display formula alone in its paragraph is centred; anywhere else it sits in the line.
    static const QRegularExpression alone(R"(<p([^>]*)>\s*OWELKMATH(\d+)X\s*</p>)");
    QString centred;
    qsizetype last = 0;
    for (auto it = alone.globalMatch(html); it.hasNext();) {
        const auto m = it.next();
        const int index = m.captured(2).toInt();
        if (index >= math.size() || !math[index].display) continue;
        // Qt does not centre a paragraph holding only an image; spaces on both sides fix that.
        centred += html.mid(last, m.capturedStart() - last) + "<p align=\"center\"" + m.captured(1) + ">&nbsp;"
            + image(index, true) + "&nbsp;</p>";
        last = m.capturedEnd();
    }
    html = centred + html.mid(last);
    static const QRegularExpression token("OWELKMATH(\\d+)X");
    QString out;
    last = 0;
    for (auto it = token.globalMatch(html); it.hasNext();) {
        const auto m = it.next();
        const int index = m.captured(1).toInt();
        out += html.mid(last, m.capturedStart() - last)
            + (index < math.size() ? image(index, math[index].display) : m.captured());
        last = m.capturedEnd();
    }
    return out + html.mid(last);
}

QString ResearchStore::plainTextWithMath(const QString &html) const
{
    // Formula images become their LaTeX before the HTML turns into text (an image alone would vanish).
    static const QRegularExpression image(R"re(<img[^>]*src="image://math/(\w+)"[^>]*/?>)re");
    QString withMath;
    qsizetype last = 0;
    for (auto it = image.globalMatch(html); it.hasNext();) {
        const auto m = it.next();
        withMath += html.mid(last, m.capturedStart() - last) + MathRenderer::source(m.captured(1)).toHtmlEscaped();
        last = m.capturedEnd();
    }
    QTextDocument document;
    document.setHtml(withMath + html.mid(last));
    return document.toPlainText().replace(QChar(0x2029), '\n').replace(QChar(0xa0), ' ').trimmed();
}

QString ResearchStore::markdownLink(const QString &kind, const QString &id) const
{
    const auto target = linkTarget(kind, id);
    if (target.isEmpty()) return {};
    auto title = target["title"].toString();
    title.replace('[', '(').replace(']', ')');
    return QStringLiteral("[%1](owelk://%2/%3)").arg(title, kind, id);
}

bool ResearchStore::appendNoteLink(const QString &noteId, const QString &kind, const QString &id)
{
    const auto row = note(noteId);
    const auto link = markdownLink(kind, id);
    if (row.isEmpty() || row["deleted"].toBool() || link.isEmpty()) return false;
    auto body = row["body"].toString();
    if (body.contains("owelk://" + kind + "/" + id)) return true; // Already linked.
    if (!body.isEmpty() && !body.endsWith('\n')) body += '\n';
    body += "- " + link + '\n';
    if (!saveNote(noteId, row["title"].toString(), body)) return false;
    emit message("Linked in note.");
    return true;
}

QVariantMap ResearchStore::linkTarget(const QString &kind, const QString &id) const
{
    QSqlQuery query(m_database);
    if (kind == "note") {
        const auto row = note(id);
        if (row.isEmpty()) return {};
        return {{"kind", kind}, {"id", id},
            {"title", row["title"].toString().isEmpty() ? "Untitled note" : row["title"]}, {"deleted", row["deleted"]}};
    }
    if (kind == "document") {
        query.prepare("SELECT url FROM documents WHERE id=?");
        query.addBindValue(id);
        if (!query.exec() || !query.next()) return {};
        const QUrl url(query.value(0).toString());
        return {{"kind", kind}, {"id", id}, {"title", displayName(url)}, {"source", url}};
    }
    if (kind == "highlight") {
        query.prepare("SELECT d.url,h.page,h.text,h.kind FROM highlights h JOIN documents d ON d.id=h.document_id "
                      "WHERE h.id=? AND h.deleted_at IS NULL");
        query.addBindValue(id);
        if (!query.exec() || !query.next()) return {};
        const QUrl url(query.value(0).toString());
        const auto excerpt = query.value(2).toString().simplified().left(80);
        return {{"kind", kind}, {"id", id}, {"source", url},
            {"title",
                (excerpt.isEmpty() ? annotationName(query.value(3).toString()) : "“" + excerpt + "”") + " · "
                    + displayName(url) + " · p. " + QString::number(query.value(1).toInt() + 1)}};
    }
    if (kind == "ai") {
        query.prepare("SELECT title FROM ai_threads WHERE id=?");
        query.addBindValue(id);
        if (!query.exec() || !query.next()) return {};
        return {{"kind", kind}, {"id", id}, {"title", "AI · " + query.value(0).toString().simplified().left(80)}};
    }
    return {};
}

QVariantList ResearchStore::backlinks(const QString &kind, const QString &id) const
{
    // A paper's backlinks include links to its annotations.
    QStringList conditions{"(to_kind=? AND to_id=?)"};
    QVariantList args{kind, id};
    if (kind == "document") {
        conditions << "(to_kind='highlight' AND to_id IN (SELECT id FROM highlights WHERE document_id=?))";
        args << id;
    }
    QSqlQuery query(m_database);
    query.prepare("SELECT DISTINCT from_kind,from_id,to_kind,to_id FROM links WHERE " + conditions.join(" OR ")
        + " ORDER BY created_at DESC");
    for (const auto &arg : args) query.addBindValue(arg);
    QVariantList rows;
    if (!query.exec()) return rows;
    QSet<QString> seen;
    while (query.next()) {
        const auto key = query.value(0).toString() + "/" + query.value(1).toString();
        if (seen.contains(key)) continue;
        seen.insert(key);
        auto target = linkTarget(query.value(0).toString(), query.value(1).toString());
        if (target.isEmpty() || target.value("deleted").toBool()) continue;
        target.insert("via", query.value(2).toString());
        rows.append(target);
    }
    return rows;
}

QVariantList ResearchStore::linkCandidates(const QString &queryText) const
{
    // For the [[ picker: notes, papers and annotations matching the text.
    QVariantList rows;
    const auto needle = queryText.trimmed();
    for (const auto &value : notes(false)) {
        const auto row = value.toMap();
        if (needle.isEmpty() || row["title"].toString().contains(needle, Qt::CaseInsensitive))
            rows.append(QVariantMap{{"kind", "note"}, {"id", row["id"]}, {"title", row["title"]}});
        if (rows.size() >= 8) break;
    }
    if (needle.isEmpty()) return rows;
    for (const auto &value : searchKnowledge(needle)) {
        const auto row = value.toMap();
        const auto kind = row["kind"].toString();
        if (kind == "paper") {
            const auto document = findDocument(row["source"].toUrl());
            if (!document.isEmpty())
                rows.append(QVariantMap{{"kind", "document"}, {"id", document}, {"title", row["title"]}});
        } else if (kind == "highlight")
            rows.append(QVariantMap{{"kind", kind}, {"id", row["id"]},
                {"title", row["title"].toString() + " · " + row["snippet"].toString().left(60)}});
        if (rows.size() >= 20) break;
    }
    return rows;
}

// --- Related papers and notes ---------------------------------------------------------------

namespace {
QStringList noteTerms(const QString &text, int count)
{
    static const QSet<QString> common{"this", "that", "with", "from", "which", "these", "their", "there", "where",
        "have", "were", "been", "also", "such", "into", "than", "then", "they", "them", "when", "each", "more", "most",
        "other", "some", "only", "over", "both", "between", "using", "used", "based", "while", "however", "about",
        "would", "could", "should", "note", "notes", "paper", "page"};
    QHash<QString, int> frequency;
    for (const auto &word : text.toLower().split(QRegularExpression("[^\\p{L}\\p{N}]+"), Qt::SkipEmptyParts))
        if (word.size() >= 4 && !common.contains(word) && !word.front().isDigit()) ++frequency[word];
    QList<std::pair<int, QString>> ranked;
    for (auto it = frequency.cbegin(); it != frequency.cend(); ++it) ranked.append({it.value(), it.key()});
    std::sort(ranked.begin(), ranked.end(),
        [](const auto &a, const auto &b) { return a.first != b.first ? a.first > b.first : a.second < b.second; });
    QStringList terms;
    for (const auto &entry : ranked)
        if (terms.size() < count) terms << entry.second;
    return terms;
}
}

QVariantList ResearchStore::notesSharing(const QStringList &terms, const QString &exceptNote) const
{
    if (terms.isEmpty()) return {};
    // A note is related when it uses at least two of the words (one when only a couple are known).
    const int needed = terms.size() >= 3 ? 2 : 1;
    QList<std::pair<int, QVariantMap>> scored;
    QSqlQuery query(m_database);
    query.exec("SELECT id,title,body FROM notes WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT 2000");
    while (query.next()) {
        if (query.value(0).toString() == exceptNote) continue;
        const auto text = query.value(1).toString() + ' ' + query.value(2).toString();
        int shared = 0;
        for (const auto &term : terms) shared += text.contains(term, Qt::CaseInsensitive);
        if (shared < needed) continue;
        const auto title = query.value(1).toString();
        scored.append({shared,
            QVariantMap{{"kind", "note"}, {"id", query.value(0)},
                {"title", title.isEmpty() ? QStringLiteral("Untitled") : title}}});
    }
    std::stable_sort(scored.begin(), scored.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    QVariantList notes;
    for (const auto &entry : scored)
        if (notes.size() < 5) notes.append(entry.second);
    return notes;
}

QVariantList ResearchStore::relatedNotes(const QString &noteId) const
{
    const auto row = note(noteId);
    if (row.isEmpty()) return {};
    return notesSharing(noteTerms(row["title"].toString() + ' ' + row["body"].toString(), 8), noteId);
}

int ResearchStore::relatedTo(const QUrl &source)
{
    const int request = ++m_relatedRequest;
    const auto document = documentLinkId(source);
    struct Pending {
        int waiting = 1;
        QVariantList keywordPapers, meaningPapers;
        QStringList terms;
        QMetaObject::Connection index, meaning;
    };
    auto pending = std::make_shared<Pending>();
    const auto finish = [this, request, pending] {
        if (--pending->waiting > 0) return;
        disconnect(pending->index);
        disconnect(pending->meaning);
        // Meaning beats shared words when it is available; notes always come from the words.
        const auto papers = pending->meaningPapers.isEmpty() ? pending->keywordPapers : pending->meaningPapers;
        emit relatedFound(request, papers, notesSharing(pending->terms, {}));
    };
    if (document.isEmpty()) {
        QMetaObject::invokeMethod(this, [this, request] { emit relatedFound(request, {}, {}); }, Qt::QueuedConnection);
        return request;
    }
    const int indexRequest = m_index->related(document);
    pending->index = connect(m_index, &PaperIndex::searchFinished, this,
        [pending, indexRequest, finish](int id, const QVariantList &rows, const QString &) {
            if (id != indexRequest) return;
            for (const auto &value : rows) {
                const auto row = value.toMap();
                if (row["kind"] == "terms")
                    pending->terms = row["terms"].toStringList();
                else
                    pending->keywordPapers.append(row);
            }
            finish();
        });
    if (m_semantic && m_semantic->enabled()) {
        ++pending->waiting;
        const int meaningRequest = m_semantic->relatedPapers(source);
        pending->meaning = connect(m_semantic, &SemanticIndex::found, this,
            [pending, meaningRequest, finish](int id, const QVariantList &rows, const QString &) {
                if (id != meaningRequest) return;
                pending->meaningPapers = rows;
                finish();
            });
    }
    return request;
}

void ResearchStore::rememberPdfPassword(const QUrl &source, const QString &password, bool keep)
{
    if (!source.isLocalFile() || password.isEmpty()) return;
    PdfAccess::remember(source.toLocalFile(), password, keep, m_directory);
    // A paper skipped as locked can be indexed now.
    m_index->retry(source);
}

QString ResearchStore::pdfPassword(const QUrl &source) const
{
    return source.isLocalFile() ? PdfAccess::password(source.toLocalFile()) : QString();
}

QString ResearchStore::paperOpening(const QUrl &source, int characters)
{
    const auto document = documentLinkId(source);
    return document.isEmpty() ? QString() : m_index->openingText(document, qBound(0, characters, 2000));
}

QVariantList ResearchStore::libraryPassages(const QStringList &terms, int limit, const QString &collection)
{
    QStringList documents;
    if (!collection.isEmpty()) {
        QSqlQuery members(m_database);
        members.prepare("WITH RECURSIVE tree(id) AS (SELECT ? UNION SELECT c.id FROM collections c JOIN tree ON "
                        "c.parent_id=tree.id) SELECT DISTINCT document_id FROM collection_documents WHERE "
                        "collection_id IN tree");
        members.addBindValue(collection);
        if (members.exec())
            while (members.next()) documents << members.value(0).toString();
        if (documents.isEmpty()) return {};
    }
    QVariantList passages;
    QHash<QString, int> perPaper;
    for (const auto &value : m_index->matchingPages(terms, limit * 6, documents)) {
        const auto row = value.toMap();
        const auto document = row["documentId"].toString();
        if (perPaper.value(document) >= 2) continue;
        // Papers removed from the Library are not asked.
        QSqlQuery query(m_database);
        query.prepare("SELECT url FROM documents WHERE id=? AND removed_at IS NULL");
        query.addBindValue(document);
        if (!query.exec() || !query.next()) continue;
        const QUrl source(query.value(0).toString());
        // About 1,400 characters around the first term found on the page.
        const auto text = row["text"].toString().simplified();
        qsizetype at = -1;
        for (const auto &term : terms) {
            const auto found = text.indexOf(term.simplified(), 0, Qt::CaseInsensitive);
            if (found >= 0 && (at < 0 || found < at)) at = found;
        }
        qsizetype start = std::max<qsizetype>(0, (at < 0 ? 0 : at) - 500);
        if (start > 0) {
            const auto space = text.indexOf(' ', start);
            if (space > 0 && space - start < 40) start = space + 1;
        }
        auto excerpt = text.mid(start, 1400);
        if (start > 0) excerpt.prepend("… ");
        if (start + 1400 < text.size()) excerpt += " …";
        perPaper[document] += 1;
        passages.append(QVariantMap{{"n", passages.size() + 1}, {"documentId", document}, {"source", source},
            {"title", displayName(source)}, {"year", documentDetails(source).value("year")}, {"page", row["page"]},
            {"excerpt", excerpt}});
        if (passages.size() >= limit) break;
    }
    return passages;
}

QVariantMap ResearchStore::paperExcerpt(const QUrl &source, int opening, int closing)
{
    const auto document = documentLinkId(source);
    if (document.isEmpty()) return {};
    return {{"opening", m_index->openingText(document, qBound(0, opening, 8000))},
        {"closing", m_index->closingText(document, qBound(0, closing, 4000))}};
}

// --- OCR (Tesseract) -----------------------------------------------------------------------

namespace {
QString findTesseract()
{
    const auto override = qEnvironmentVariable("OWELK_TESSERACT");
    if (!override.isEmpty()) return override;
    auto found = QStandardPaths::findExecutable("tesseract");
    if (found.isEmpty())
        found = QStandardPaths::findExecutable("tesseract",
            {"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "C:/Program Files/Tesseract-OCR",
                "C:/Program Files (x86)/Tesseract-OCR"});
    return found;
}
}

void ResearchStore::configureOcr()
{
    m_ocrProgram = findTesseract();
    m_ocrInstalled.clear();
    emit ocrChanged();
    if (m_ocrProgram.isEmpty() || setting("ocr.enabled", "1") != "1") {
        m_index->setOcr({});
        return;
    }
    // Which language data is installed decides the default (English, plus Korean when present).
    auto *process = new QProcess(this);
    connect(process, &QProcess::finished, this, [this, process] {
        process->deleteLater();
        const auto lines = QString::fromUtf8(process->readAllStandardOutput()).split('\n', Qt::SkipEmptyParts);
        for (const auto &line : lines)
            if (!line.contains(' ') && !line.trimmed().isEmpty() && line.trimmed() != "osd")
                m_ocrInstalled << line.trimmed();
        auto languages = setting("ocr.languages");
        if (languages.isEmpty()) {
            QStringList chosen;
            for (const auto *language : {"eng", "kor"})
                if (m_ocrInstalled.contains(language)) chosen << language;
            languages = chosen.isEmpty() ? QStringLiteral("eng") : chosen.join('+');
        }
        m_index->setOcr({m_ocrProgram, languages});
        emit ocrChanged();
    });
    connect(process, &QProcess::errorOccurred, process, &QObject::deleteLater);
    if (m_ocrProgram.endsWith(".py"))
        process->start(
            QStandardPaths::findExecutable("python3").isEmpty() ? "python" : "python3", {m_ocrProgram, "--list-langs"});
    else
        process->start(m_ocrProgram, {"--list-langs"});
}

QVariantMap ResearchStore::ocrStatus() const
{
    const auto active = m_index->ocr();
    return {{"found", !m_ocrProgram.isEmpty()}, {"program", QDir::toNativeSeparators(m_ocrProgram)},
        {"enabled", setting("ocr.enabled", "1") == "1"}, {"languages", active.languages},
        {"installed", m_ocrInstalled}};
}

void ResearchStore::setOcr(bool enabled, const QString &languages)
{
    setSetting("ocr.enabled", enabled ? "1" : "0");
    static const QRegularExpression valid("^[A-Za-z_]+(\\+[A-Za-z_]+)*$");
    setSetting("ocr.languages", valid.match(languages.trimmed()).hasMatch() ? languages.trimmed() : QString());
    m_index->setOcr({});
    configureOcr();
}
