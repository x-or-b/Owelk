#include "ResearchStore.h"
#include "UiText.h"
#include "PaperIndex.h"

#include <QDateTime>
#include <QDirIterator>
#include <QFile>
#include <QFutureWatcher>
#include <QtConcurrent>
#include <QFileInfo>
#include <QGuiApplication>
#include <QSet>
#include <QSqlError>
#include <QRegularExpression>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlQuery>
#include <QUuid>

namespace {
QString now()
{
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}
QString newId()
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}
}

// Documents in scope of the library filters. Keys (all optional): text, state (unread|reading|read),
// favorite (bool), unsorted (bool: in no collection), collection (id), tag (id), yearFrom, yearTo, sort
// (opened|added|title|year).
QVariantList ResearchStore::libraryDocuments(const QVariantMap &filter) const
{
    QStringList where{"d.url LIKE 'file:%'", "d.removed_at IS NULL"};
    QVariantList args;
    const auto text = filter.value("text").toString().trimmed();
    if (!text.isEmpty()) {
        where << "(instr(lower(d.title),lower(?))>0 OR instr(lower(d.authors),lower(?))>0 OR "
                 "instr(lower(d.url),lower(?))>0 OR d.year=? OR instr(lower(d.doi),lower(?))>0 OR d.arxiv=?)";
        for (int i = 0; i < 6; ++i) args << text;
    }
    if (filter.contains("state")) {
        where << "d.reading_state=?";
        args << filter.value("state").toString();
    }
    if (filter.value("favorite").toBool()) where << "d.favorite=1";
    if (filter.value("unsorted").toBool()) where << "d.id NOT IN (SELECT document_id FROM collection_documents)";
    if (filter.contains("collection")) {
        // A collection includes the papers of its sub-collections.
        where << "d.id IN (WITH RECURSIVE tree(id) AS (SELECT ? UNION SELECT c.id FROM collections c JOIN tree ON "
                 "c.parent_id=tree.id) SELECT document_id FROM collection_documents WHERE collection_id IN tree)";
        args << filter.value("collection").toString();
    }
    if (filter.contains("tag")) {
        where << "d.id IN (SELECT document_id FROM document_tags WHERE tag_id=?)";
        args << filter.value("tag").toString();
    }
    if (filter.contains("yearFrom")) {
        where << "d.year<>'' AND CAST(d.year AS INTEGER)>=?";
        args << filter.value("yearFrom").toInt();
    }
    if (filter.contains("yearTo")) {
        where << "d.year<>'' AND CAST(d.year AS INTEGER)<=?";
        args << filter.value("yearTo").toInt();
    }
    const auto sort = filter.value("sort").toString();
    const QString order = sort == "title" ? "coalesce(nullif(d.title,''),d.url) COLLATE NOCASE"
        : sort == "year"                  ? "d.year DESC, d.title COLLATE NOCASE"
        : sort == "added"                 ? "d.added_at DESC"
                                          : "r.opened_at IS NULL, r.opened_at DESC, d.added_at DESC";
    QSqlQuery query(m_database);
    query.prepare(
        "SELECT d.id,d.url,d.authors,d.year,d.reading_state,d.favorite,d.excluded_from_index,d.sha256,"
        "(SELECT group_concat(t.name, ', ') FROM document_tags dt JOIN tags t ON t.id=dt.tag_id "
        "WHERE dt.document_id=d.id),"
        "(d.sha256<>'' AND EXISTS(SELECT 1 FROM documents o WHERE o.sha256=d.sha256 AND o.id<>d.id)),p.position "
        "FROM documents d LEFT JOIN recent_documents r ON r.document_id=d.id "
        "LEFT JOIN reading_positions p ON p.document_id=d.id WHERE "
        + where.join(" AND ") + " ORDER BY " + order
        + (filter.contains("limit") ? QStringLiteral(" LIMIT %1").arg(qMax(1, filter.value("limit").toInt()))
                                    : QString()));
    for (const auto &arg : args) query.addBindValue(arg);
    QVariantList rows;
    if (!query.exec()) return rows;
    while (query.next()) {
        const QUrl url(query.value(1).toString());
        rows.append(
            QVariantMap{{"id", query.value(0)}, {"url", url}, {"name", displayName(url)}, {"fileName", fileName(url)},
                {"authors", query.value(2)}, {"year", query.value(3)}, {"readingState", query.value(4)},
                {"favorite", query.value(5).toBool()}, {"excluded", query.value(6).toBool()},
                {"tags", query.value(8).toString()}, {"duplicate", query.value(9).toBool()},
                {"position", QJsonDocument::fromJson(query.value(10).toByteArray()).object().toVariantMap()}});
    }
    return rows;
}

void ResearchStore::markOpened(const QString &kind, const QString &id)
{
    if (!QStringList{"note", "ai", "collection"}.contains(kind) || id.isEmpty()) return;
    QSqlQuery query(m_database);
    query.prepare("INSERT OR REPLACE INTO recent_items(kind,id,opened_at) VALUES(?,?,?)");
    query.addBindValue(kind);
    query.addBindValue(id);
    query.addBindValue(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    query.exec();
}

QVariantList ResearchStore::recentItems(const QString &kind, int limit) const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    if (kind == "note")
        query.prepare("SELECT n.id,n.title FROM notes n LEFT JOIN recent_items r ON r.kind='note' AND r.id=n.id "
                      "WHERE n.deleted_at IS NULL ORDER BY max(coalesce(r.opened_at,''),n.updated_at) DESC LIMIT ?");
    else if (kind == "ai")
        query.prepare("SELECT t.id,t.title,t.source FROM ai_threads t LEFT JOIN recent_items r ON r.kind='ai' AND "
                      "r.id=t.id WHERE t.trashed_at IS NULL ORDER BY max(coalesce(r.opened_at,''),t.updated_at) DESC "
                      "LIMIT ?");
    else if (kind == "collection")
        query.prepare(
            "SELECT c.id,c.name,(SELECT count(*) FROM collection_documents cd JOIN documents d ON d.id=cd.document_id "
            "WHERE cd.collection_id=c.id AND d.removed_at IS NULL),max(coalesce(r.opened_at,''),coalesce((SELECT "
            "max(rd.opened_at) FROM collection_documents cd JOIN recent_documents rd ON rd.document_id=cd.document_id "
            "WHERE cd.collection_id=c.id),'')) AS last FROM collections c LEFT JOIN recent_items r ON "
            "r.kind='collection' AND r.id=c.id ORDER BY last DESC, c.name COLLATE NOCASE LIMIT ?");
    else
        return rows;
    query.addBindValue(limit);
    if (!query.exec()) return rows;
    while (query.next()) {
        if (kind == "note")
            rows.append(QVariantMap{{"id", query.value(0)},
                {"title", query.value(1).toString().isEmpty() ? ui("Untitled note") : query.value(1).toString()}});
        else if (kind == "ai") {
            const QUrl source(query.value(2).toString());
            rows.append(QVariantMap{{"id", query.value(0)}, {"title", query.value(1)},
                {"paper", source.isLocalFile() ? displayName(source) : QString()}});
        } else
            rows.append(QVariantMap{{"id", query.value(0)}, {"name", query.value(1)}, {"count", query.value(2)}});
    }
    return rows;
}

QVariantList ResearchStore::collections() const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    query.exec("SELECT c.id,c.name,coalesce(c.parent_id,''),(SELECT count(*) FROM collection_documents cd "
               "JOIN documents d ON d.id=cd.document_id WHERE cd.collection_id=c.id AND d.removed_at IS NULL) FROM "
               "collections c ORDER BY c.name COLLATE NOCASE");
    QList<QVariantMap> all;
    while (query.next())
        all.append({{"id", query.value(0)}, {"name", query.value(1)}, {"parentId", query.value(2)},
            {"count", query.value(3)}});
    // Depth-first order with depth, ready for an indented list.
    std::function<void(const QString &, int)> add = [&](const QString &parent, int depth) {
        for (auto row : all)
            if (row["parentId"].toString() == parent) {
                row.insert("depth", depth);
                rows.append(row);
                if (depth < 16) add(row["id"].toString(), depth + 1);
            }
    };
    add(QString(), 0);
    return rows;
}

QString ResearchStore::createCollection(const QString &name, const QString &parentId)
{
    const auto trimmed = name.simplified();
    if (trimmed.isEmpty() || trimmed.size() > 120) {
        emit message(ui("Enter a collection name (1–120 characters)."));
        return {};
    }
    const auto id = newId();
    QSqlQuery query(m_database);
    query.prepare("INSERT INTO collections(id,name,parent_id,created_at) "
                  "SELECT ?,?,?,? WHERE ? IS NULL OR EXISTS(SELECT 1 FROM collections WHERE id=?)");
    const QVariant parent = parentId.isEmpty() ? QVariant() : QVariant(parentId);
    query.addBindValue(id);
    query.addBindValue(trimmed);
    query.addBindValue(parent);
    query.addBindValue(now());
    query.addBindValue(parent);
    query.addBindValue(parent);
    if (!query.exec() || query.numRowsAffected() != 1) return {};
    announceDocumentsChanged();
    return id;
}

bool ResearchStore::renameCollection(const QString &id, const QString &name)
{
    const auto trimmed = name.simplified();
    if (trimmed.isEmpty() || trimmed.size() > 120) return false;
    QSqlQuery query(m_database);
    query.prepare("UPDATE collections SET name=? WHERE id=?");
    query.addBindValue(trimmed);
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    announceDocumentsChanged();
    return true;
}

bool ResearchStore::deleteCollection(const QString &id)
{
    // Only the grouping is removed; papers stay in the library and sub-collections move up one level.
    if (!m_database.transaction()) return false;
    const auto run = [&](const QString &sql) {
        QSqlQuery query(m_database);
        query.prepare(sql);
        query.addBindValue(id);
        return query.exec();
    };
    QSqlQuery reparent(m_database);
    reparent.prepare(
        "UPDATE collections SET parent_id=(SELECT parent_id FROM collections WHERE id=?) WHERE parent_id=?");
    reparent.addBindValue(id);
    reparent.addBindValue(id);
    // Its own folder of AI chats keeps the name it showed.
    const bool ok = reparent.exec() && run("DELETE FROM collection_documents WHERE collection_id=?")
        && run("UPDATE ai_folders SET name=(SELECT c.name FROM collections c WHERE c.id=substr(ai_folders.id,12)) "
               "WHERE id='collection:'||? AND name=''")
        && run("DELETE FROM collections WHERE id=?");
    if (!ok || !m_database.commit()) {
        m_database.rollback();
        return false;
    }
    announceDocumentsChanged();
    return true;
}

bool ResearchStore::setDocumentCollection(const QUrl &source, const QString &collectionId, bool member)
{
    const auto document = ensureDocument(source);
    if (document.isEmpty()) return false;
    QSqlQuery query(m_database);
    query.prepare(member
            ? "INSERT OR IGNORE INTO collection_documents(collection_id,document_id) SELECT ?,? WHERE EXISTS(SELECT 1 "
              "FROM collections WHERE id=?)"
            : "DELETE FROM collection_documents WHERE collection_id=? AND document_id=?");
    query.addBindValue(collectionId);
    query.addBindValue(document);
    if (member) query.addBindValue(collectionId);
    if (!query.exec()) return false;
    announceDocumentsChanged();
    return true;
}

QVariantList ResearchStore::tags() const
{
    QVariantList rows;
    QSqlQuery query(m_database);
    query.exec("SELECT t.id,t.name,count(d.id) FROM tags t LEFT JOIN document_tags dt ON dt.tag_id=t.id "
               "LEFT JOIN documents d ON d.id=dt.document_id AND d.removed_at IS NULL "
               "GROUP BY t.id ORDER BY t.name COLLATE NOCASE");
    while (query.next())
        rows.append(QVariantMap{{"id", query.value(0)}, {"name", query.value(1)}, {"count", query.value(2)}});
    return rows;
}

bool ResearchStore::setDocumentTags(const QUrl &source, const QStringList &names)
{
    const auto document = ensureDocument(source);
    if (document.isEmpty() || !m_database.transaction()) return false;
    const auto fail = [this] {
        m_database.rollback();
        emit message(ui("Cannot save tags."));
        return false;
    };
    QSqlQuery clear(m_database);
    clear.prepare("DELETE FROM document_tags WHERE document_id=?");
    clear.addBindValue(document);
    if (!clear.exec()) return fail();
    QSet<QString> seen;
    for (const auto &raw : names) {
        const auto name = raw.simplified();
        if (name.isEmpty() || name.size() > 60 || seen.contains(name.toLower())) continue;
        seen.insert(name.toLower());
        QSqlQuery tag(m_database);
        tag.prepare("INSERT OR IGNORE INTO tags(id,name) VALUES(?,?)");
        tag.addBindValue(newId());
        tag.addBindValue(name);
        QSqlQuery link(m_database);
        link.prepare("INSERT OR IGNORE INTO document_tags(document_id,tag_id) SELECT ?,id FROM tags WHERE name=?");
        link.addBindValue(document);
        link.addBindValue(name);
        if (!tag.exec() || !link.exec()) return fail();
    }
    // Tags nobody uses any more disappear from the list.
    QSqlQuery orphans(m_database);
    if (!orphans.exec("DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM document_tags)") || !m_database.commit())
        return fail();
    announceDocumentsChanged();
    return true;
}

QVariantMap ResearchStore::documentOrganization(const QUrl &source) const
{
    const auto document = findDocument(source);
    QStringList tagNames, collectionIds;
    QSqlQuery query(m_database);
    query.prepare(
        "SELECT t.name FROM document_tags dt JOIN tags t ON t.id=dt.tag_id WHERE dt.document_id=? ORDER BY t.name");
    query.addBindValue(document);
    if (query.exec())
        while (query.next()) tagNames << query.value(0).toString();
    query.prepare("SELECT collection_id FROM collection_documents WHERE document_id=?");
    query.addBindValue(document);
    if (query.exec())
        while (query.next()) collectionIds << query.value(0).toString();
    return {{"tags", tagNames}, {"collections", collectionIds}};
}

bool ResearchStore::setExcludedFromIndex(const QUrl &source, bool excluded)
{
    const auto document = ensureDocument(source);
    QSqlQuery query(m_database);
    query.prepare("UPDATE documents SET excluded_from_index=? WHERE id=?");
    query.addBindValue(excluded ? 1 : 0);
    query.addBindValue(document);
    if (document.isEmpty() || !query.exec() || query.numRowsAffected() != 1) return false;
    if (excluded)
        m_index->remove(resolvedSource(source));
    else
        m_index->enqueue(resolvedSource(source));
    emit message(excluded ? ui("Removed from the text index. Its pages no longer appear in PDF text search.")
                          : ui("Added back to the text index."));
    announceDocumentsChanged();
    return true;
}

bool ResearchStore::excludedFromIndex(const QUrl &source) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT excluded_from_index FROM documents WHERE url=?");
    query.addBindValue(resolvedSource(source).toString());
    return query.exec() && query.next() && query.value(0).toBool();
}

int ResearchStore::unsortedCount() const
{
    QSqlQuery query(m_database);
    query.exec("SELECT count(*) FROM documents WHERE url LIKE 'file:%' AND removed_at IS NULL AND id NOT IN (SELECT "
               "document_id FROM collection_documents)");
    return query.next() ? query.value(0).toInt() : 0;
}

bool ResearchStore::setDocumentsCollection(const QVariantList &sources, const QString &collectionId, bool member)
{
    if (sources.isEmpty() || !m_database.transaction()) return false;
    for (const auto &value : sources) {
        const auto document = ensureDocument(value.toUrl());
        if (document.isEmpty()) continue;
        QSqlQuery query(m_database);
        query.prepare(member ? "INSERT OR IGNORE INTO collection_documents(collection_id,document_id) SELECT ?,? WHERE "
                               "EXISTS(SELECT 1 FROM "
                               "collections WHERE id=?)"
                             : "DELETE FROM collection_documents WHERE collection_id=? AND document_id=?");
        query.addBindValue(collectionId);
        query.addBindValue(document);
        if (member) query.addBindValue(collectionId);
        if (!query.exec()) {
            m_database.rollback();
            return false;
        }
    }
    if (!m_database.commit()) return false;
    announceDocumentsChanged();
    return true;
}

int ResearchStore::suggestCollections(const QUrl &source)
{
    const int request = ++m_suggestRequest;
    const auto document = findDocument(source);
    const auto answer = [this, request, source](const QVariantList &list) {
        QMetaObject::invokeMethod(
            this, [=, this] { emit collectionsSuggested(request, source, list); }, Qt::QueuedConnection);
    };
    if (document.isEmpty()) {
        answer({});
        return request;
    }
    if (m_suggestions.contains(document)) {
        answer(m_suggestions.value(document));
        return request;
    }
    // Nothing to suggest without collections.
    QSqlQuery any(m_database);
    if (!any.exec("SELECT 1 FROM collections LIMIT 1") || !any.next()) {
        answer({});
        return request;
    }
    const int related = relatedTo(source);
    auto connection = std::make_shared<QMetaObject::Connection>();
    *connection = connect(this, &ResearchStore::relatedFound, this,
        [this, related, request, source, document, connection](
            int id, const QVariantList &papers, const QVariantList &) {
            if (id != related) return;
            disconnect(*connection);
            QSet<QString> mine;
            QSqlQuery own(m_database);
            own.prepare("SELECT collection_id FROM collection_documents WHERE document_id=?");
            own.addBindValue(document);
            if (own.exec())
                while (own.next()) mine.insert(own.value(0).toString());
            // Each similar paper votes for its collections; closer papers count more.
            QHash<QString, double> score;
            QHash<QString, QString> names;
            for (int i = 0; i < papers.size() && i < 10; ++i) {
                const auto other = findDocument(papers[i].toMap().value("source").toUrl());
                if (other.isEmpty() || other == document) continue;
                QSqlQuery query(m_database);
                query.prepare("SELECT c.id,c.name FROM collection_documents cd JOIN collections c ON "
                              "c.id=cd.collection_id WHERE cd.document_id=?");
                query.addBindValue(other);
                if (!query.exec()) continue;
                while (query.next()) {
                    const auto collection = query.value(0).toString();
                    if (mine.contains(collection)) continue;
                    score[collection] += 1.0 / (1 + i);
                    names[collection] = query.value(1).toString();
                }
            }
            QList<QPair<double, QString>> ranked;
            for (auto it = score.cbegin(); it != score.cend(); ++it)
                if (it.value() >= .3) ranked.append({it.value(), it.key()});
            std::sort(ranked.begin(), ranked.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
            QVariantList list;
            for (const auto &entry : ranked)
                if (list.size() < 2)
                    list.append(QVariantMap{{"id", entry.second}, {"name", names.value(entry.second)}});
            m_suggestions.insert(document, list);
            emit collectionsSuggested(request, source, list);
        });
    return request;
}

int ResearchStore::keyboardModifiers() const
{
    return int(QGuiApplication::keyboardModifiers());
}

int ResearchStore::addDocuments(const QVariantList &sources, const QString &collectionId)
{
    QVariantList added;
    QHash<QString, QUrl> batch; // Two files with the same bytes become one paper.
    for (const auto &value : sources) {
        const QFileInfo info(value.toUrl().toLocalFile());
        if (!value.toUrl().isLocalFile() || !info.isFile() || !info.isReadable()
            || info.suffix().compare("pdf", Qt::CaseInsensitive))
            continue;
        const auto url = adoptPdf(value.toUrl(), &batch);
        const auto document = ensureDocument(url);
        if (document.isEmpty()) continue;
        QSqlQuery restore(m_database);
        restore.prepare("UPDATE documents SET removed_at=NULL,trashed_at=NULL WHERE id=?");
        restore.addBindValue(document);
        restore.exec();
        refreshMetadata(document, resolvedSource(url), false, true);
        m_index->enqueue(url);
        added.append(url);
    }
    if (!collectionId.isEmpty() && !added.isEmpty()) setDocumentsCollection(added, collectionId, true);
    announceDocumentsChanged();
    emit homeChanged();
    if (m_quietAdd) return int(added.size());
    if (!added.isEmpty())
        emit message(added.size() == 1 ? ui("Added 1 PDF to the Library.")
                                       : QString(ui("Added %1 PDFs to the Library.")).arg(added.size()));
    else
        emit message(ui("No PDFs were added. Choose PDF files."));
    return int(added.size());
}

int ResearchStore::removeFromLibrary(const QVariantList &sources)
{
    int removed = 0;
    const auto now = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
    for (const auto &value : sources) {
        const auto url = value.toUrl();
        const auto document = findDocument(url);
        if (document.isEmpty()) continue;
        QSqlQuery hide(m_database);
        hide.prepare("UPDATE documents SET removed_at=? WHERE id=? AND removed_at IS NULL");
        hide.addBindValue(now);
        hide.addBindValue(document);
        if (!hide.exec() || hide.numRowsAffected() != 1) continue;
        for (const auto *sql :
            {"DELETE FROM recent_documents WHERE document_id=?", "DELETE FROM collection_documents WHERE document_id=?",
                "DELETE FROM document_tags WHERE document_id=?"}) {
            QSqlQuery query(m_database);
            query.prepare(sql);
            query.addBindValue(document);
            query.exec();
        }
        m_index->remove(resolvedSource(url));
        ++removed;
    }
    if (!removed) return 0;
    announceDocumentsChanged();
    emit recentDocumentsChanged();
    emit homeChanged();
    emit message(removed == 1
            ? ui("Removed from the Library. The PDF file was kept.")
            : QString(ui("Removed %1 papers from the Library. The PDF files were kept.")).arg(removed));
    return removed;
}

int ResearchStore::importFolder(const QUrl &folder, const QString &parentCollection, bool foldersAsCollections)
{
    const int request = ++m_importRequest;
    const auto root = folder.toLocalFile();
    if (!folder.isLocalFile() || !QFileInfo(root).isDir()) {
        QMetaObject::invokeMethod(
            this, [=, this] { emit folderImported(request, 0, 0, "Choose a folder."); }, Qt::QueuedConnection);
        return request;
    }
    struct Found {
        QString path, relativeDir;
    };
    // Shown with its progress in the status bar: looking (files found so far), then copying (n of all).
    const auto task = QStringLiteral("import:%1").arg(request);
    const auto name = QFileInfo(root).fileName();
    startTask(task, ui("Looking for PDFs in ") + name + "…");
    const auto report = [this, task](double done, double total, const QString &label) {
        QMetaObject::invokeMethod(this, [=, this] { progressTask(task, done, total, label); }, Qt::QueuedConnection);
    };
    auto *watcher = new QFutureWatcher<QList<Found>>(this);
    connect(watcher, &QFutureWatcher<QList<Found>>::finished, this, [=, this] {
        const auto found = watcher->result();
        watcher->deleteLater();
        finishTask(task);
        // Files by folder; each folder is filed into its collection (created on first use).
        QMap<QString, QVariantList> byFolder;
        for (const auto &f : found) byFolder[f.relativeDir].append(QUrl::fromLocalFile(f.path));
        int added = 0, made = 0;
        const auto childNamed = [&](const QString &parent, const QString &name) {
            for (const auto &value : collections()) {
                const auto c = value.toMap();
                if (c["parentId"].toString() == parent && c["name"].toString().compare(name, Qt::CaseInsensitive) == 0)
                    return c["id"].toString();
            }
            ++made;
            return createCollection(name, parent);
        };
        for (auto it = byFolder.cbegin(); it != byFolder.cend(); ++it) {
            QString target = parentCollection;
            if (foldersAsCollections) {
                target = childNamed(parentCollection, QFileInfo(root).fileName());
                for (const auto &part : it.key().split('/', Qt::SkipEmptyParts)) target = childNamed(target, part);
            }
            m_quietAdd = true; // One summary at the end, not one message per folder.
            added += addDocuments(it.value(), target);
            m_quietAdd = false;
        }
        const auto message = found.isEmpty() ? QStringLiteral("No PDFs in that folder.") : QString();
        emit folderImported(request, added, made, message);
        if (!found.isEmpty())
            emit this->message(QString("Added %1 PDFs from %2%3.")
                    .arg(added)
                    .arg(QFileInfo(root).fileName())
                    .arg(made ? QString(" into %1 new collections").arg(made) : QString()));
    });
    const bool keep = keepsPdfs();
    // Its own pool: the details reader's one-at-a-time queue may hold every paper still to be read. The store
    // waits for it at quit (report reaches this object), and it stops after the file it is on.
    watcher->setFuture(QtConcurrent::run(&m_fileWorkers,
        [root, keep, report, name, directory = m_directory, papers = m_papers, relinks = m_relinks,
            stopping = m_stopping] {
            QList<Found> found;
            QDirIterator it(root, {"*.pdf", "*.PDF"}, QDir::Files | QDir::Readable | QDir::NoSymLinks,
                QDirIterator::Subdirectories);
            const QDir base(root);
            while (it.hasNext() && found.size() < 10000 && !stopping->load()) {
                const auto path = it.next();
                const QFileInfo info(path);
                if (info.isHidden() || path.contains("/.")) continue;
                found.append({path,
                    base.relativeFilePath(info.absolutePath()) == "." ? QString()
                                                                      : base.relativeFilePath(info.absolutePath())});
                if (found.size() % 25 == 0)
                    report(0, 0, QString(ui("Looking for PDFs in %1… %2 found")).arg(name).arg(found.size()));
            }
            // Kept PDFs are copied here, off the UI thread; the folder's own files stay where they are.
            if (keep) {
                QStringList paths;
                for (const auto &f : found) paths << f.path;
                const auto total = double(paths.size());
                const auto label = QString(ui("Adding PDFs from %1")).arg(name);
                report(0, total, label);
                const auto adopted = adoptPdfFiles(
                    directory, papers, relinks, paths, [&](int done) { report(done, total, label); }, stopping.get());
                for (int i = 0; i < found.size(); ++i) found[i].path = adopted[i];
            }
            return found;
        }));
    return request;
}

QUrl ResearchStore::paperUrlFor(const QString &arxiv, const QString &doi) const
{
    const auto id = QString(arxiv).trimmed().remove(QRegularExpression("v\\d+$"));
    if (id.isEmpty() && doi.trimmed().isEmpty()) return {};
    QSqlQuery query(m_database);
    query.prepare("SELECT url FROM documents WHERE removed_at IS NULL AND ((?<>'' AND (arxiv=? OR arxiv GLOB ?)) OR "
                  "(?<>'' AND lower(doi)=lower(?))) LIMIT 1");
    for (const auto &value : {id, id, id + "v*", doi.trimmed(), doi.trimmed()}) query.addBindValue(value);
    return query.exec() && query.next() ? QUrl(query.value(0).toString()) : QUrl();
}

QStringList ResearchStore::collectionPaperKeys(const QString &collectionId, int limit) const
{
    QStringList keys;
    QSqlQuery query(m_database);
    query.prepare("SELECT d.arxiv,d.doi FROM collection_documents c JOIN documents d ON d.id=c.document_id "
                  "WHERE c.collection_id=? AND d.removed_at IS NULL ORDER BY d.added_at DESC");
    query.addBindValue(collectionId);
    if (!query.exec()) return keys;
    while (query.next() && keys.size() < limit) {
        const auto arxiv = query.value(0).toString().trimmed().remove(QRegularExpression("v\\d+$"));
        const auto doi = query.value(1).toString().trimmed();
        if (!arxiv.isEmpty())
            keys << "ArXiv:" + arxiv;
        else if (!doi.isEmpty())
            keys << "DOI:" + doi;
    }
    return keys;
}

QUrl ResearchStore::paperWithFile(const QUrl &file, const QString &sha256) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT url FROM documents WHERE removed_at IS NULL AND (url=? OR (?<>'' AND sha256=?)) "
                  "ORDER BY url=? DESC LIMIT 1");
    for (const auto &value : {file.toString(), sha256, sha256, file.toString()}) query.addBindValue(value);
    return query.exec() && query.next() ? QUrl(query.value(0).toString()) : QUrl();
}
