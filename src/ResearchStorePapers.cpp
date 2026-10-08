#include "FileFingerprint.h"
#include "PaperIndex.h"
#include "ResearchStore.h"
#include "WorkerConnection.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QSqlQuery>
#include <QtConcurrent>

// "Keep PDFs in Owelk": opened, added and downloaded PDFs get a copy in the data folder's papers/
// (which sync fills too), so the Library does not depend on files scattered over the disk, as in
// note apps. The originals are never moved or deleted.
namespace {
QString uniqueFile(const QString &folder, const QString &suggested)
{
    // Keep only a plain file name; never let a server or another computer choose the folder.
    auto name = QFileInfo(suggested).fileName().remove(QRegularExpression("[\\x00-\\x1f/\\\\:]")).trimmed();
    if (name.isEmpty() || name.startsWith('.')) name = "download.pdf";
    const QFileInfo base(name);
    const auto stem = base.completeBaseName(), suffix = base.suffix().isEmpty() ? QString() : "." + base.suffix();
    for (int n = 1; QFileInfo::exists(folder + "/" + name) && n < 1000; ++n)
        name = QStringLiteral("%1 (%2)%3").arg(stem).arg(n).arg(suffix);
    return folder + "/" + name;
}

bool copyInto(const QString &from, const QString &to)
{
    const auto part = to + ".part";
    QFile::remove(part);
    if (QDir().mkpath(QFileInfo(to).absolutePath()) && QFile::copy(from, part) && QFile::rename(part, to)) return true;
    QFile::remove(part);
    return false;
}

// The Library's file for a PDF: a path the Library already uses stays; identical bytes map to the
// paper that has them; anything else is copied into papers/. The input comes back when nothing
// applies or copying fails, so opening never breaks because of this.
QUrl adoptFile(QSqlDatabase &db, const QString &folder, const QUrl &source, QHash<QString, QUrl> *batch)
{
    const auto path = source.toLocalFile();
    const QFileInfo info(path);
    if (!source.isLocalFile() || !info.isFile() || info.suffix().compare("pdf", Qt::CaseInsensitive)) return source;
    QSqlQuery known(db);
    known.prepare("SELECT 1 FROM documents WHERE url=?");
    known.addBindValue(source.toString());
    if (known.exec() && known.next()) return source;
    const auto hash = FileFingerprint::sha256(path);
    if (hash.isEmpty()) return source;
    if (batch && batch->contains(hash)) return batch->value(hash);
    const bool inside = info.absoluteFilePath().startsWith(folder + "/");
    QSqlQuery same(db);
    same.prepare("SELECT url FROM documents WHERE sha256=? AND kind='pdf' ORDER BY removed_at IS NOT NULL LIMIT 1");
    same.addBindValue(hash);
    if (same.exec() && same.next()) {
        const QUrl existing(same.value(0).toString());
        const auto existingPath = existing.toLocalFile();
        if (QFileInfo::exists(existingPath) && QFileInfo(existingPath) != info) {
            // A fresh download of a paper Owelk already keeps is not kept twice.
            if (inside) QFile::remove(path);
            return existing;
        }
    }
    if (inside) return source;
    const auto target = uniqueFile(folder, info.fileName());
    if (!copyInto(path, target)) return source;
    FileFingerprint::remember(target, FileFingerprint::stamp(target), hash);
    const auto url = QUrl::fromLocalFile(target);
    if (batch) batch->insert(hash, url);
    return url;
}
} // namespace

bool ResearchStore::keepsPdfs() const
{
    return setting("library.keepPdfs", "1") == "1";
}

QString ResearchStore::papersFolder() const
{
    return m_papers;
}

// The usual data folder keeps PDFs in Documents/Owelk, where people look for files; a data folder
// given on the command line (development, tests) keeps them inside itself.
QString ResearchStore::defaultPapersFolder(const QString &directory)
{
    const auto documents = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    if (directory == QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation) && !documents.isEmpty())
        return documents + "/Owelk";
    return directory + "/papers";
}

// PDFs kept before the folder moved to Documents/Owelk follow it: each file moves, then its paper
// switches over the same way Locate Original PDF does (the old path still finds it).
void ResearchStore::relocatePapers()
{
    const auto old = m_directory + "/papers";
    if (old == m_papers || !QFileInfo(old).isDir()) return;
    QSqlQuery query(m_database);
    QList<QPair<QString, QString>> papers;
    if (!query.exec("SELECT url,sha256 FROM documents WHERE url LIKE 'file:%'")) return;
    while (query.next()) {
        const auto path = QUrl(query.value(0).toString()).toLocalFile();
        if (path.startsWith(old + "/")) papers.append({path, query.value(1).toString()});
    }
    query.finish();
    int moved = 0;
    for (const auto &[path, hash] : std::as_const(papers)) {
        const auto target = uniqueFile(m_papers, QFileInfo(path).fileName());
        const bool present = QFileInfo::exists(path);
        if (present && (!QDir().mkpath(m_papers) || !QFile::rename(path, target))) continue;
        const auto from = QUrl::fromLocalFile(path), to = QUrl::fromLocalFile(target);
        QString error;
        if (!applyRelink(from, to, hash, &error)) {
            if (present) QFile::rename(target, path);
            continue;
        }
        m_relinks.insert(from.toString(), to.toString());
        m_index->relocateSource(from, to);
        // A paper still arriving through sync lands in the new place.
        QSqlQuery pending(m_database);
        pending.prepare("UPDATE sync_files SET local=? WHERE local=?");
        pending.addBindValue(target);
        pending.addBindValue(path);
        pending.exec();
        ++moved;
    }
    QDir().rmdir(old); // Only when nothing else is left in it.
    if (moved) m_startupMessage = QString("Owelk's PDFs now live in %1.").arg(QDir::toNativeSeparators(m_papers));
}

QUrl ResearchStore::papersFolderUrl() const
{
    QDir().mkpath(papersFolder());
    return QUrl::fromLocalFile(papersFolder());
}

QUrl ResearchStore::adoptPdf(const QUrl &source)
{
    return adoptPdf(source, nullptr);
}

QUrl ResearchStore::adoptPdf(const QUrl &source, QHash<QString, QUrl> *batch)
{
    const auto url = resolvedSource(source);
    return keepsPdfs() ? adoptFile(m_database, papersFolder(), url, batch) : url;
}

QStringList ResearchStore::adoptPdfFiles(
    const QString &directory, const QString &papers, const QHash<QString, QString> &relinks, const QStringList &paths)
{
    // Runs on a worker: its own read-only connection; relinked paths resolve like resolvedSource.
    WorkerConnection db(directory + "/owelk.sqlite3", true);
    QHash<QString, QUrl> batch;
    QStringList adopted;
    for (const auto &path : paths) {
        auto url = QUrl::fromLocalFile(path).toString();
        for (int hop = 0; hop < 16 && relinks.contains(url); ++hop) url = relinks.value(url);
        adopted << adoptFile(db.db, papers, QUrl(url), &batch).toLocalFile();
    }
    return adopted;
}

int ResearchStore::outsidePdfCount() const
{
    QSqlQuery query(m_database);
    int count = 0;
    if (!query.exec("SELECT url FROM documents WHERE kind='pdf' AND removed_at IS NULL")) return 0;
    while (query.next()) {
        const auto path = QUrl(query.value(0).toString()).toLocalFile();
        if (!path.isEmpty() && !path.startsWith(papersFolder() + "/") && QFileInfo::exists(path)) ++count;
    }
    return count;
}

void ResearchStore::copyPdfsIntoLibrary()
{
    if (m_copyingPdfs || m_relinking || busy()) return;
    struct Move {
        QUrl from, to;
        QString hash;
    };
    QList<Move> moves;
    QSqlQuery query(m_database);
    if (query.exec("SELECT url FROM documents WHERE kind='pdf' AND removed_at IS NULL"))
        while (query.next()) {
            const QUrl url(query.value(0).toString());
            const auto path = url.toLocalFile();
            if (!path.isEmpty() && !path.startsWith(papersFolder() + "/") && QFileInfo::exists(path))
                moves.append({url, {}, {}});
        }
    if (moves.isEmpty()) return;
    m_copyingPdfs = true;
    emit copyingPdfsChanged();
    auto *watcher = new QFutureWatcher<QList<Move>>(this);
    connect(watcher, &QFutureWatcher<QList<Move>>::finished, this, [this, watcher] {
        const auto done = watcher->result();
        watcher->deleteLater();
        // The same one-URL change as Locate Original PDF, for each paper whose copy matched byte for byte.
        int copied = 0;
        for (const auto &move : done) {
            QString error;
            if (move.to.isEmpty()) continue;
            if (!applyRelink(move.from, move.to, move.hash, &error)) {
                QFile::remove(move.to.toLocalFile());
                continue;
            }
            m_relinks.insert(move.from.toString(), move.to.toString());
            m_index->relocateSource(move.from, move.to);
            emit sourceRelinked(move.from, move.to);
            ++copied;
        }
        loadDocumentNames();
        announceDocumentsChanged();
        emit highlightsChanged();
        m_copyingPdfs = false;
        emit copyingPdfsChanged();
        emit message(copied == done.size()
                ? QString("Copied %1 PDFs into the Library. The originals were left where they were.").arg(copied)
                : QString("Copied %1 of %2 PDFs into the Library; the rest stay where they are.")
                      .arg(copied)
                      .arg(done.size()));
    });
    const auto folder = papersFolder();
    watcher->setFuture(QtConcurrent::run(&m_metadataWorkers, [moves, folder]() mutable {
        for (auto &move : moves) {
            const auto path = move.from.toLocalFile();
            const auto target = uniqueFile(folder, QFileInfo(path).fileName());
            const auto hash = FileFingerprint::sha256(path);
            if (hash.isEmpty() || !copyInto(path, target)) continue;
            // Only a byte-for-byte copy replaces the original in the Library.
            if (FileFingerprint::sha256(target) != hash) {
                QFile::remove(target);
                continue;
            }
            move.to = QUrl::fromLocalFile(target);
            move.hash = hash;
        }
        return moves;
    }));
}
