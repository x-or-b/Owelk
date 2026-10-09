#include "SemanticIndex.h"
#include "Keychain.h"
#include "PaperIndex.h"
#include "ResearchStore.h"
#include "WorkerConnection.h"

#include <QCryptographicHash>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QSet>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QtConcurrent>
#include <algorithm>
#include <cmath>

struct SemanticIndex::Matrix {
    struct Row {
        QString kind, ref, document;
        int page = 0;
    };
    int dims = 0;
    QList<Row> rows;
    QList<float> scales;
    QByteArray values; // rows × dims int8
};

namespace {
constexpr int batchSize = 32;
constexpr int planLimit = 2000; // Embedded per sync run; the next run continues.

QString keyOf(const QString &kind, const QString &ref, int page, int ord)
{
    return kind + '|' + ref + '|' + QString::number(page) + '|' + QString::number(ord);
}

// Passages of about 900 characters, cut at spaces, so one page gives a few vectors.
QStringList passages(const QString &text)
{
    QStringList parts;
    const auto clean = text.simplified();
    for (qsizetype start = 0; start < clean.size();) {
        auto end = std::min<qsizetype>(clean.size(), start + 900);
        if (end < clean.size()) {
            const auto space = clean.lastIndexOf(' ', end);
            if (space > start + 300) end = space;
        }
        const auto part = clean.mid(start, end - start).trimmed();
        if (part.size() >= 40) parts << part;
        start = end + 1;
    }
    return parts;
}

bool createSchema(QSqlDatabase &db)
{
    QSqlQuery query(db);
    return query.exec("PRAGMA journal_mode=WAL")
        && query.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        && query.exec("CREATE TABLE IF NOT EXISTS chunks (kind TEXT NOT NULL, ref TEXT NOT NULL, page INTEGER NOT "
                      "NULL, ord INTEGER NOT NULL, document TEXT NOT NULL, hash TEXT NOT NULL, scale REAL NOT NULL, "
                      "vec BLOB NOT NULL, PRIMARY KEY(kind, ref, page, ord))");
}

struct Plan {
    QList<SemanticIndex::Pending> pending;
    QString error;
    bool changed = false;
};

// Compare what should be embedded with what is stored: drop stale vectors, list the missing ones.
Plan planSync(const QString &path, const QString &libraryPath, const QString &searchPath, const QString &model)
{
    Plan plan;
    WorkerConnection semantic(path);
    if (!semantic.db.isOpen() || !createSchema(semantic.db)) return {{}, "Cannot open the semantic index.", false};
    QSqlQuery query(semantic.db);
    query.exec("SELECT value FROM meta WHERE key='model'");
    if (!query.next() || query.value(0).toString() != model) {
        // A different model makes every stored vector incomparable.
        query.exec("DELETE FROM chunks");
        query.prepare("INSERT OR REPLACE INTO meta VALUES('model', ?)");
        query.addBindValue(model);
        query.exec();
        plan.changed = true;
    }
    QHash<QString, SemanticIndex::Pending> wanted;
    const auto want
        = [&](const QString &kind, const QString &ref, const QString &document, int page, const QString &text) {
              int ord = 0;
              for (const auto &part : passages(text)) {
                  SemanticIndex::Pending item{kind, ref, document,
                      QString::fromLatin1(QCryptographicHash::hash(part.toUtf8(), QCryptographicHash::Sha1).toHex()),
                      part, page, ord};
                  wanted.insert(keyOf(kind, ref, page, ord++), item);
              }
          };
    {
        WorkerConnection search(searchPath, true);
        QSqlQuery pages(search.db);
        if (search.db.isOpen()
            && pages.exec("SELECT p.document_id,p.page,p.text FROM pages p JOIN documents d ON d.id=p.document_id "
                          "WHERE d.state='ready'"))
            while (pages.next())
                want("page", pages.value(0).toString(), pages.value(0).toString(), pages.value(1).toInt(),
                    pages.value(2).toString());
    }
    {
        WorkerConnection library(libraryPath, true);
        QSqlQuery rows(library.db);
        if (rows.exec("SELECT id,title || '. ' || body FROM notes WHERE deleted_at IS NULL"))
            while (rows.next()) want("note", rows.value(0).toString(), {}, 0, rows.value(1).toString());
        if (rows.exec("SELECT id,document_id,page,text || ' ' || body FROM highlights WHERE deleted_at IS NULL"))
            while (rows.next())
                want("highlight", rows.value(0).toString(), rows.value(1).toString(), rows.value(2).toInt(),
                    rows.value(3).toString());
        if (rows.exec("SELECT thread_id,group_concat(substr(content,1,2000),' ') FROM ai_messages WHERE "
                      "role='assistant' AND thread_id IN (SELECT id FROM ai_threads WHERE trashed_at IS NULL) "
                      "GROUP BY thread_id"))
            while (rows.next()) want("ai", rows.value(0).toString(), {}, 0, rows.value(1).toString());
    }
    QSqlQuery stored(semantic.db);
    stored.exec("SELECT kind,ref,page,ord,hash FROM chunks");
    QStringList stale;
    while (stored.next()) {
        const auto key = keyOf(
            stored.value(0).toString(), stored.value(1).toString(), stored.value(2).toInt(), stored.value(3).toInt());
        const auto found = wanted.constFind(key);
        if (found == wanted.cend() || found->hash != stored.value(4).toString())
            stale << key;
        else
            wanted.remove(key);
    }
    if (!stale.isEmpty()) {
        semantic.db.transaction();
        QSqlQuery remove(semantic.db);
        remove.prepare("DELETE FROM chunks WHERE kind=? AND ref=? AND page=? AND ord=?");
        for (const auto &key : stale) {
            const auto parts = key.split('|');
            for (const auto &part : parts) remove.addBindValue(part);
            remove.exec();
        }
        semantic.db.commit();
        plan.changed = true;
    }
    // Papers first, in page order, so a reader sees whole papers become searchable.
    plan.pending = wanted.values();
    std::sort(plan.pending.begin(), plan.pending.end(), [](const auto &a, const auto &b) {
        return std::tie(a.kind, a.document, a.page, a.ord) < std::tie(b.kind, b.document, b.page, b.ord);
    });
    if (plan.pending.size() > planLimit) plan.pending.resize(planLimit);
    return plan;
}

// Unit length, then int8 with one scale per vector: about a quarter of float storage.
QByteArray quantize(QList<float> vector, float *scale)
{
    double norm = 0;
    for (const auto v : vector) norm += double(v) * v;
    norm = std::sqrt(norm);
    float peak = 0;
    for (auto &v : vector) {
        v = norm > 0 ? float(v / norm) : 0;
        peak = std::max(peak, std::abs(v));
    }
    *scale = peak > 0 ? peak / 127.f : 1.f;
    QByteArray bytes(vector.size(), Qt::Uninitialized);
    for (qsizetype i = 0; i < vector.size(); ++i) bytes[i] = char(qRound(vector[i] / *scale));
    return bytes;
}

QList<float> normalized(QList<float> vector)
{
    double norm = 0;
    for (const auto v : vector) norm += double(v) * v;
    norm = std::sqrt(norm);
    if (norm > 0)
        for (auto &v : vector) v = float(v / norm);
    return vector;
}

float similarity(const SemanticIndex::Matrix &m, qsizetype row, const QList<float> &query)
{
    const auto *values = reinterpret_cast<const qint8 *>(m.values.constData()) + row * m.dims;
    float dot = 0;
    for (int i = 0; i < m.dims; ++i) dot += float(values[i]) * query[i];
    return dot * m.scales[row];
}

// Turn matched passages into the same rows keyword search returns.
QVariantList describe(const QList<std::pair<const SemanticIndex::Matrix::Row *, float>> &hits,
    const QString &libraryPath, const QString &searchPath, const QString &needle)
{
    WorkerConnection library(libraryPath, true), search(searchPath, true);
    const auto one = [](QSqlDatabase &db, const QString &sql, const QVariantList &values) {
        QSqlQuery query(db);
        query.prepare(sql);
        for (const auto &value : values) query.addBindValue(value);
        return query.exec() && query.next() ? query.record() : QSqlRecord();
    };
    const auto paper = [&](const QString &document) {
        const auto row = one(search.db, "SELECT url,sha256 FROM documents WHERE id=?", {document});
        const QUrl url(row.value(0).toString());
        auto title = one(library.db, "SELECT title FROM documents WHERE id=?", {document}).value(0).toString();
        if (title.isEmpty()) title = url.isLocalFile() ? QFileInfo(url.toLocalFile()).fileName() : url.toString();
        return std::tuple{url, row.value(1).toString(), title};
    };
    QVariantList rows;
    for (const auto &[row, score] : hits) {
        QVariantMap result{{"semantic", true}, {"similarity", score}};
        if (row->kind == "page") {
            const auto [url, sha, title] = paper(row->document);
            if (url.isEmpty()) continue;
            const auto text
                = one(search.db, "SELECT text FROM pages WHERE document_id=? AND page=?", {row->document, row->page})
                      .value(0)
                      .toString()
                      .simplified();
            const auto at
                = needle.isEmpty() ? -1 : int(text.indexOf(needle.section(' ', 0, 0), 0, Qt::CaseInsensitive));
            result.insert({{"kind", "text"}, {"documentId", row->document}, {"source", url}, {"sha256", sha},
                {"page", row->page}, {"title", title}, {"snippet", text.mid(std::max(0, at - 60), 220)}});
        } else if (row->kind == "note") {
            const auto note = one(library.db, "SELECT title,body FROM notes WHERE id=?", {row->ref});
            result.insert({{"kind", "note"}, {"id", row->ref},
                {"title", "Note · " + (note.value(0).toString().isEmpty() ? "Untitled" : note.value(0).toString())},
                {"snippet", note.value(1).toString().simplified().left(220)}});
        } else if (row->kind == "highlight") {
            const auto mark = one(library.db, "SELECT text || ' ' || body FROM highlights WHERE id=?", {row->ref});
            const auto [url, sha, title] = paper(row->document);
            result.insert({{"kind", "highlight"}, {"id", row->ref}, {"source", url},
                {"title", title + " · p. " + QString::number(row->page + 1)},
                {"snippet", mark.value(0).toString().simplified().left(220)}});
        } else if (row->kind == "ai") {
            const auto thread = one(library.db, "SELECT title FROM ai_threads WHERE id=?", {row->ref});
            result.insert({{"kind", "ai"}, {"id", row->ref}, {"title", "AI · " + thread.value(0).toString()}});
        }
        rows.append(result);
    }
    return rows;
}
}

SemanticIndex::SemanticIndex(ResearchStore *store, PaperIndex *index, QString directory, QObject *parent)
    : QObject(parent), m_store(store), m_index(index), m_directory(std::move(directory)),
      m_path(m_directory + "/semantic.sqlite3")
{
    // One low-priority thread; no thread exists until the feature is used.
    m_pool.setMaxThreadCount(1);
    m_pool.setThreadPriority(QThread::LowPriority);
    m_syncTimer.setSingleShot(true);
    m_syncTimer.setInterval(3000);
    connect(&m_syncTimer, &QTimer::timeout, this, &SemanticIndex::runSync);
    // The vectors held for searching are released when search has not been used for a while.
    m_releaseTimer.setSingleShot(true);
    m_releaseTimer.setInterval(5 * 60 * 1000);
    connect(&m_releaseTimer, &QTimer::timeout, this, &SemanticIndex::dropMatrix);
}

SemanticIndex::~SemanticIndex()
{
    m_cancel->store(true);
    m_pool.waitForDone();
}

QString SemanticIndex::engine() const
{
    const auto value = m_store->setting("semantic.engine");
    return value == "ollama" || value == "openai" ? value : QString();
}

QString SemanticIndex::defaultModel(const QString &engine)
{
    return engine == "openai" ? QStringLiteral("text-embedding-3-small") : QStringLiteral("nomic-embed-text");
}

QString SemanticIndex::model() const
{
    const auto value = m_store->setting("semantic.model");
    return value.isEmpty() ? defaultModel(engine()) : value;
}

void SemanticIndex::configure(const QString &engine, const QString &model)
{
    if (!engine.isEmpty() && engine != "ollama" && engine != "openai") return;
    m_store->setSetting("semantic.engine", engine);
    m_store->setSetting("semantic.model", model.trimmed().left(120));
    m_error.clear();
    m_progress.clear();
    dropMatrix();
    emit changed();
    if (enabled()) {
        m_syncTimer.stop();
        runSync();
    }
}

void SemanticIndex::sync()
{
    if (enabled()) m_syncTimer.start();
}

void SemanticIndex::clear()
{
    m_syncTimer.stop();
    m_pending.clear();
    dropMatrix();
    QtConcurrent::run(&m_pool, [path = m_path] {
        WorkerConnection db(path);
        if (db.db.isOpen()) QSqlQuery(db.db).exec("DELETE FROM chunks");
    }).waitForFinished();
    m_progress.clear();
    emit changed();
}

int SemanticIndex::storedCount() const
{
    if (!QFileInfo::exists(m_path)) return 0;
    WorkerConnection db(m_path, true);
    QSqlQuery query(db.db);
    return query.exec("SELECT count(*) FROM chunks") && query.next() ? query.value(0).toInt() : 0;
}

void SemanticIndex::runSync()
{
    if (!enabled()) return;
    if (m_syncing) {
        m_again = true;
        return;
    }
    m_syncing = true;
    m_again = false;
    m_error.clear();
    m_progress = "Preparing meaning search…";
    emit changed();
    auto *watcher = new QFutureWatcher<Plan>(this);
    connect(watcher, &QFutureWatcher<Plan>::finished, this, [this, watcher] {
        const auto plan = watcher->result();
        watcher->deleteLater();
        if (plan.changed) dropMatrix();
        if (!plan.error.isEmpty()) return finishSync(plan.error);
        m_pending = plan.pending;
        m_done = 0;
        m_total = m_pending.size();
        embedNext();
    });
    watcher->setFuture(QtConcurrent::run(&m_pool,
        [path = m_path, library = m_store->dataDirectory() + "/owelk.sqlite3", search = m_index->databasePath(),
            model = model()] { return planSync(path, library, search, model); }));
}

void SemanticIndex::embedNext()
{
    if (!enabled()) return finishSync({});
    if (m_pending.isEmpty()) return finishSync({});
    // Reading comes first: wait while the reader scrolls, selects or zooms.
    if (m_index->readerBusyFlag()->load()) {
        QTimer::singleShot(700, this, &SemanticIndex::embedNext);
        return;
    }
    const auto batch = m_pending.mid(0, batchSize);
    QStringList texts;
    for (const auto &item : batch) texts << item.text;
    embed(texts, [this, batch](const QList<QList<float>> &vectors, const QString &error) {
        if (!error.isEmpty() || vectors.size() != batch.size())
            return finishSync(error.isEmpty() ? QStringLiteral("The embedding service returned no vectors.") : error);
        auto *watcher = new QFutureWatcher<bool>(this);
        connect(watcher, &QFutureWatcher<bool>::finished, this, [this, watcher, count = batch.size()] {
            const bool ok = watcher->result();
            watcher->deleteLater();
            if (!ok) return finishSync("Cannot store meaning vectors.");
            m_pending.remove(0, count);
            m_done += int(count);
            m_progress = QStringLiteral("Indexing meaning · %1 / %2").arg(m_done).arg(m_total);
            dropMatrix();
            emit changed();
            embedNext();
        });
        watcher->setFuture(QtConcurrent::run(&m_pool, [path = m_path, batch, vectors] {
            WorkerConnection db(path);
            if (!db.db.isOpen()) return false;
            db.db.transaction();
            QSqlQuery insert(db.db);
            insert.prepare("INSERT OR REPLACE INTO chunks VALUES(?,?,?,?,?,?,?,?)");
            for (qsizetype i = 0; i < batch.size(); ++i) {
                float scale = 1;
                const auto bytes = quantize(vectors[i], &scale);
                const auto &item = batch[i];
                // Notes and AI answers belong to no paper: an empty (not NULL) document.
                const auto document = item.document.isNull() ? QStringLiteral("") : item.document;
                for (const QVariant &value :
                    QVariantList{item.kind, item.ref, item.page, item.ord, document, item.hash, scale, bytes})
                    insert.addBindValue(value);
                if (!insert.exec()) {
                    db.db.rollback();
                    return false;
                }
            }
            return db.db.commit();
        }));
    });
}

void SemanticIndex::finishSync(const QString &error)
{
    m_syncing = false;
    m_error = error;
    m_progress = error.isEmpty() ? QString() : QStringLiteral("Meaning search paused: %1").arg(error);
    emit changed();
    if (error.isEmpty() && (m_again || !m_pending.isEmpty() || m_total >= planLimit)) {
        m_pending.clear();
        m_syncTimer.start();
    }
}

void SemanticIndex::embed(
    const QStringList &texts, std::function<void(const QList<QList<float>> &, const QString &)> done)
{
    if (!m_network) m_network = new QNetworkAccessManager(this);
    const bool openai = engine() == "openai";
    auto base = m_store->setting(openai ? "semantic.baseUrl.openai" : "semantic.baseUrl.ollama");
    if (base.isEmpty())
        base = m_store->setting(openai ? "ai.baseUrl.openai" : "ai.baseUrl.ollama",
            openai ? "https://api.openai.com/" : "http://127.0.0.1:11434/");
    if (!base.endsWith('/')) base += '/';
    QNetworkRequest request(QUrl(base).resolved(QUrl(openai ? "v1/embeddings" : "api/embed")));
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setTransferTimeout(120000);
    if (openai) {
        const auto key = Keychain::read("openai-api-key", m_store->dataDirectory());
        if (key.isEmpty()) return done({}, "Add an OpenAI API key in Settings → AI.");
        request.setRawHeader("Authorization", "Bearer " + key.toUtf8());
    }
    const QJsonObject body{{"model", model()}, {"input", QJsonArray::fromStringList(texts)}};
    auto *reply = m_network->post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [reply, done, openai] {
        reply->deleteLater();
        const auto json = QJsonDocument::fromJson(reply->readAll()).object();
        if (reply->error() != QNetworkReply::NoError) {
            const auto detail
                = openai ? json.value("error").toObject().value("message").toString() : json.value("error").toString();
            return done(
                {}, detail.isEmpty() ? (openai ? "OpenAI is not reachable." : "Ollama is not running.") : detail);
        }
        QList<QList<float>> vectors;
        const auto list = openai ? json.value("data").toArray() : json.value("embeddings").toArray();
        for (const auto &entry : list) {
            QList<float> vector;
            for (const auto &v : (openai ? entry.toObject().value("embedding").toArray() : entry.toArray()))
                vector << float(v.toDouble());
            vectors << vector;
        }
        done(vectors, {});
    });
}

std::shared_ptr<const SemanticIndex::Matrix> SemanticIndex::matrix()
{
    // Called on the worker thread.
    {
        std::lock_guard lock(m_matrixLock);
        if (m_matrix) return m_matrix;
    }
    auto loaded = std::make_shared<Matrix>();
    WorkerConnection db(m_path, true);
    QSqlQuery query(db.db);
    if (db.db.isOpen() && query.exec("SELECT kind,ref,document,page,scale,vec FROM chunks"))
        while (query.next()) {
            const auto bytes = query.value(5).toByteArray();
            if (loaded->dims == 0) loaded->dims = int(bytes.size());
            if (bytes.size() != loaded->dims) continue;
            loaded->rows.append({query.value(0).toString(), query.value(1).toString(), query.value(2).toString(),
                query.value(3).toInt()});
            loaded->scales.append(query.value(4).toFloat());
            loaded->values += bytes;
        }
    std::lock_guard lock(m_matrixLock);
    m_matrix = loaded;
    return m_matrix;
}

void SemanticIndex::dropMatrix()
{
    std::lock_guard lock(m_matrixLock);
    m_matrix.reset();
}

int SemanticIndex::search(const QString &text, int limit)
{
    const int request = ++m_request;
    const auto needle = text.simplified();
    if (!enabled() || needle.isEmpty()) {
        QMetaObject::invokeMethod(this, [this, request] { emit found(request, {}, {}); }, Qt::QueuedConnection);
        return request;
    }
    m_releaseTimer.start();
    embed({needle}, [this, request, needle, limit](const QList<QList<float>> &vectors, const QString &error) {
        if (request != m_request) return; // A newer query replaced this one.
        if (!error.isEmpty() || vectors.isEmpty()) return emit found(request, {}, error);
        auto *watcher = new QFutureWatcher<QVariantList>(this);
        connect(watcher, &QFutureWatcher<QVariantList>::finished, this, [this, watcher, request] {
            const auto rows = watcher->result();
            watcher->deleteLater();
            if (request == m_request) emit found(request, rows, {});
        });
        watcher->setFuture(QtConcurrent::run(&m_pool,
            [this, query = normalized(vectors.first()), limit, needle,
                library = m_store->dataDirectory() + "/owelk.sqlite3", search = m_index->databasePath()] {
                const auto m = matrix();
                if (!m || m->dims != query.size()) return QVariantList();
                // Best passage per item (one row per page, note, annotation…), then the top few.
                QHash<QString, std::pair<qsizetype, float>> best;
                for (qsizetype row = 0; row < m->rows.size(); ++row) {
                    const auto &r = m->rows[row];
                    const auto key = r.kind + '|' + r.ref + '|' + QString::number(r.page);
                    const auto score = similarity(*m, row, query);
                    auto found = best.find(key);
                    if (found == best.end())
                        best.insert(key, {row, score});
                    else if (score > found->second)
                        *found = {row, score};
                }
                QList<std::pair<const Matrix::Row *, float>> hits;
                for (const auto &[row, score] : std::as_const(best)) hits.append({&m->rows[row], score});
                std::sort(hits.begin(), hits.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
                if (hits.size() > limit) hits.resize(limit);
                return describe(hits, library, search, needle);
            }));
    });
    return request;
}

int SemanticIndex::relatedPapers(const QUrl &source, int limit)
{
    const int request = ++m_request;
    if (!enabled()) {
        QMetaObject::invokeMethod(this, [this, request] { emit found(request, {}, {}); }, Qt::QueuedConnection);
        return request;
    }
    m_releaseTimer.start();
    const auto document = m_store->documentLinkId(source);
    auto *watcher = new QFutureWatcher<QVariantList>(this);
    connect(watcher, &QFutureWatcher<QVariantList>::finished, this, [this, watcher, request] {
        const auto rows = watcher->result();
        watcher->deleteLater();
        emit found(request, rows, {});
    });
    watcher->setFuture(QtConcurrent::run(&m_pool,
        [this, document, limit, library = m_store->dataDirectory() + "/owelk.sqlite3",
            search = m_index->databasePath()] {
            const auto m = matrix();
            if (!m || m->dims == 0) return QVariantList();
            // A paper's direction is the mean of its page passages.
            QHash<QString, QList<float>> means;
            QHash<QString, int> counts;
            for (qsizetype row = 0; row < m->rows.size(); ++row) {
                const auto &r = m->rows[row];
                if (r.kind != "page") continue;
                auto &mean = means[r.document];
                if (mean.isEmpty()) mean.resize(m->dims);
                const auto *values = reinterpret_cast<const qint8 *>(m->values.constData()) + row * m->dims;
                for (int i = 0; i < m->dims; ++i) mean[i] += values[i] * m->scales[row];
                ++counts[r.document];
            }
            if (!means.contains(document)) return QVariantList();
            const auto target = normalized(means.value(document));
            QList<std::pair<QString, float>> scored;
            for (auto it = means.cbegin(); it != means.cend(); ++it) {
                if (it.key() == document) continue;
                const auto other = normalized(it.value());
                float dot = 0;
                for (int i = 0; i < m->dims; ++i) dot += target[i] * other[i];
                scored.append({it.key(), dot});
            }
            std::sort(scored.begin(), scored.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
            if (scored.size() > limit) scored.resize(limit);
            QList<Matrix::Row> rows;
            for (const auto &[id, score] : scored) rows.append({"page", id, id, 0});
            QList<std::pair<const Matrix::Row *, float>> hits;
            for (qsizetype i = 0; i < rows.size(); ++i) hits.append({&rows[i], scored[i].second});
            auto result = describe(hits, library, search, {});
            for (auto &value : result) {
                auto row = value.toMap();
                row["kind"] = "paper";
                row.remove("snippet");
                value = row;
            }
            return result;
        }));
    return request;
}
