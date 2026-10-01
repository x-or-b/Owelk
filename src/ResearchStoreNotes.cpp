#include "ResearchStore.h"

#include <QColor>
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
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
const QStringList linkKinds{"note", "capture", "highlight", "document", "ai"};
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
    static const QRegularExpression link("owelk://(note|capture|highlight|document|ai)/([A-Za-z0-9\\-]+)");
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

QString ResearchStore::markdownHtml(const QString &markdown, const QString &linkColor) const
{
    // Markdown rendered as rich text bakes Qt's default link blue into the HTML; use the app accent instead.
    QTextDocument document;
    document.setMarkdown(markdown);
    auto html = document.toHtml();
    static const QRegularExpression blue("color:\\s*#0000ff", QRegularExpression::CaseInsensitiveOption);
    if (QColor::isValidColorName(linkColor)) html.replace(blue, "color:" + linkColor);
    return html;
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
    if (kind == "capture") {
        for (const auto &value : m_captures) {
            const auto capture = value.toMap();
            if (capture["id"].toString() != id) continue;
            const auto excerpt = capture["text"].toString().simplified().left(80);
            return {{"kind", kind}, {"id", id}, {"source", capture["source"]},
                {"title",
                    (excerpt.isEmpty() ? QStringLiteral("Region") : "“" + excerpt + "”") + " · "
                        + capture["name"].toString() + " · p. " + QString::number(capture["page"].toInt() + 1)}};
        }
        return {};
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
                (excerpt.isEmpty() ? query.value(3).toString() : "“" + excerpt + "”") + " · " + displayName(url)
                    + " · p. " + QString::number(query.value(1).toInt() + 1)}};
    }
    if (kind == "ai") {
        query.prepare("SELECT prompt FROM ai_responses WHERE id=?");
        query.addBindValue(id);
        if (!query.exec() || !query.next()) return {};
        return {{"kind", kind}, {"id", id}, {"title", "AI · " + query.value(0).toString().simplified().left(80)}};
    }
    return {};
}

QVariantList ResearchStore::backlinks(const QString &kind, const QString &id) const
{
    // A paper's backlinks include links to its captures and highlights.
    QStringList conditions{"(to_kind=? AND to_id=?)"};
    QVariantList args{kind, id};
    if (kind == "document") {
        conditions << "(to_kind='capture' AND to_id IN (SELECT id FROM captures WHERE document_id=?))"
                   << "(to_kind='highlight' AND to_id IN (SELECT id FROM highlights WHERE document_id=?))";
        args << id << id;
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
    // For the [[ picker: notes, papers, excerpts and annotations matching the text.
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
        } else if (kind == "capture" || kind == "highlight")
            rows.append(QVariantMap{{"kind", kind}, {"id", row["id"]},
                {"title", row["title"].toString() + " · " + row["snippet"].toString().left(60)}});
        if (rows.size() >= 20) break;
    }
    return rows;
}

QString ResearchStore::saveAiResponse(const QVariantMap &response)
{
    const auto answer = response.value("answer").toString();
    if (answer.trimmed().isEmpty() || answer.size() > 400000) return {};
    static const QHash<QString, QString> labels{{"explain", "Explain"}, {"translate", "Translate"},
        {"summarize", "Summarize"}, {"figure", "Explain figure"}, {"ask", "Ask"}};
    const auto question = response.value("question").toString().simplified();
    const auto source = response.value("source").toUrl();
    auto title = labels.value(response.value("action").toString(), "Ask");
    if (!question.isEmpty())
        title += ": " + question.left(120);
    else if (source.isValid() && !source.isEmpty())
        title += " · " + displayName(source);
    const auto id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QJsonObject context{{"prompt", response.value("prompt").toString()}, {"source", source.toString()},
        {"page", response.value("page").toInt()}, {"captureId", response.value("captureId").toString()},
        {"action", response.value("action").toString()}, {"question", question}};
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO ai_responses VALUES(?,?,?,?,?,?,?)");
    for (const QString &value : {id, response.value("provider").toString(), response.value("model").toString(), title,
             answer, QString::fromUtf8(QJsonDocument(context).toJson(QJsonDocument::Compact)), now()})
        query.addBindValue(text(value));
    if (!query.exec()) {
        emit message("Cannot save the AI answer.");
        return {};
    }
    // The answer links back to what it was about.
    const auto document = findDocument(source);
    if (!document.isEmpty()) addLink("ai", id, "document", document);
    if (!response.value("captureId").toString().isEmpty())
        addLink("ai", id, "capture", response.value("captureId").toString());
    emit notesChanged();
    return id;
}

QVariantMap ResearchStore::aiResponse(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT provider,model,prompt,answer,context_json,created_at FROM ai_responses WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    const auto context = QJsonDocument::fromJson(query.value(4).toByteArray()).object();
    return {{"id", id}, {"provider", query.value(0)}, {"model", query.value(1)}, {"title", query.value(2)},
        {"answer", query.value(3)}, {"source", QUrl(context.value("source").toString())},
        {"page", context.value("page").toInt()}, {"action", context.value("action").toString()},
        {"question", context.value("question").toString()}, {"createdAt", query.value(5)}};
}
