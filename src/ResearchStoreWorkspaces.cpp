#include "ResearchStore.h"
#include "PaperIndex.h"
#include <QDateTime>
#include <QJsonDocument>
#include <QSet>
#include <QSqlQuery>

QVariantMap ResearchStore::workspaceDetails(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT name FROM workspaces WHERE id=? AND id NOT IN (SELECT id FROM deleted_workspaces)");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    const auto name = query.value(0).toString();
    query.prepare("SELECT d.url FROM workspace_documents w JOIN documents d ON d.id=w.document_id "
                  "WHERE w.workspace_id=? ORDER BY d.url");
    query.addBindValue(id);
    if (!query.exec()) return {};
    QVariantList documents, captures;
    while (query.next()) {
        const QUrl source(query.value(0).toString());
        documents.append(
            QVariantMap{{"source", source}, {"name", displayName(source)}, {"position", readingPosition(source)}});
    }
    query.prepare("SELECT capture_id FROM workspace_captures WHERE workspace_id=?");
    query.addBindValue(id);
    if (!query.exec()) return {};
    QSet<QString> linked;
    while (query.next()) linked.insert(query.value(0).toString());
    for (const auto &entry : m_captures)
        if (linked.contains(entry.toMap()["id"].toString())) captures.append(entry);
    return {{"id", id}, {"name", name}, {"documents", documents}, {"captures", captures}};
}

bool ResearchStore::setWorkspaceDocument(const QString &id, const QUrl &input, bool linked)
{
    const auto source = resolvedSource(input);
    if (!source.isLocalFile() || workspaceDetails(id).isEmpty()) return false;
    const auto document = ensureDocument(source);
    if (document.isEmpty() || !m_database.transaction()) return false;
    const auto run = [&](const QString &sql) {
        QSqlQuery query(m_database);
        query.prepare(sql);
        query.addBindValue(id);
        query.addBindValue(document);
        return query.exec();
    };
    // A tab can remain open after unlinking. Session autosaves must not recreate that link.
    const bool ok = linked
        ? run("DELETE FROM workspace_document_exclusions WHERE workspace_id=? AND document_id=?")
            && run("INSERT OR IGNORE INTO workspace_documents(workspace_id,document_id) VALUES(?,?)")
        : run("INSERT OR IGNORE INTO workspace_document_exclusions(workspace_id,document_id) VALUES(?,?)")
            && run("DELETE FROM workspace_documents WHERE workspace_id=? AND document_id=?");
    if (!ok || !m_database.commit()) {
        m_database.rollback();
        emit message("Cannot update workspace document links.");
        return false;
    }
    if (linked) m_index->enqueue(source);
    emit homeChanged();
    return true;
}

bool ResearchStore::setWorkspaceCapture(const QString &id, const QString &captureId, bool linked)
{
    if (workspaceDetails(id).isEmpty()) return false;
    if (linked) {
        bool exists = false;
        for (const auto &entry : m_captures)
            if (entry.toMap()["id"] == captureId) {
                exists = true;
                break;
            }
        if (!exists) return false;
    }
    QSqlQuery query(m_database);
    query.prepare(linked ? "INSERT OR IGNORE INTO workspace_captures VALUES(?,?)"
                         : "DELETE FROM workspace_captures WHERE workspace_id=? AND capture_id=?");
    query.addBindValue(id);
    query.addBindValue(captureId);
    if (!query.exec()) {
        emit message("Cannot update workspace capture links.");
        return false;
    }
    emit homeChanged();
    return true;
}

bool ResearchStore::renameWorkspace(const QString &id, const QString &name)
{
    const auto trimmed = name.trimmed();
    if (trimmed.isEmpty() || trimmed.size() > 120) {
        emit message("Enter a workspace name (1–120 characters).");
        return false;
    }
    if (!m_database.transaction()) return false;
    QSqlQuery query(m_database);
    query.prepare("UPDATE workspaces SET name=? WHERE id=? AND id NOT IN (SELECT id FROM deleted_workspaces)");
    query.addBindValue(trimmed);
    query.addBindValue(id);
    bool ok = query.exec() && query.numRowsAffected() == 1;
    auto saved = session();
    if (saved.value("workspace").toString() == id) {
        saved["workspaceName"] = trimmed;
        query.prepare("UPDATE settings SET value=? WHERE key='session'");
        query.addBindValue(QString::fromUtf8(QJsonDocument::fromVariant(saved).toJson(QJsonDocument::Compact)));
        ok = ok && query.exec();
    }
    if (!ok || !m_database.commit()) {
        m_database.rollback();
        emit message("Cannot rename workspace.");
        return false;
    }
    emit workspaceRenamed(id, trimmed);
    emit homeChanged();
    return true;
}

bool ResearchStore::deleteWorkspace(const QString &id)
{
    if (workspaceDetails(id).isEmpty() || !m_database.transaction()) return false;
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO deleted_workspaces VALUES(?,?)");
    query.addBindValue(id);
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    bool ok = query.exec();
    auto saved = session();
    if (saved.value("workspace").toString() == id) {
        saved["workspace"] = "";
        saved["workspaceName"] = "";
        query.prepare("UPDATE settings SET value=? WHERE key='session'");
        query.addBindValue(QString::fromUtf8(QJsonDocument::fromVariant(saved).toJson(QJsonDocument::Compact)));
        ok = ok && query.exec();
    }
    if (!ok || !m_database.commit()) {
        m_database.rollback();
        emit message("Cannot remove workspace.");
        return false;
    }
    // Archive the layout and associations; never delete files, captures, notes or reading positions.
    emit workspaceDeleted(id);
    emit homeChanged();
    return true;
}
