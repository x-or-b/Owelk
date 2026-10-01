#include "FileFingerprint.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QMutex>
#include <QStringList>

#ifdef Q_OS_UNIX
#include <sys/stat.h>
#endif

namespace FileFingerprint {
namespace {
struct Entry {
    Stamp stamp;
    QString hash;
};
QMutex mutex;
QHash<QString, Entry> entries;
std::atomic_int reads = 0;

QString key(const QString &path) { return QFileInfo(path).absoluteFilePath(); }
}

QString Stamp::toString() const
{
    return QStringLiteral("%1:%2:%3:%4:%5").arg(size).arg(modified).arg(changed).arg(device).arg(inode);
}

Stamp Stamp::fromString(const QString &text)
{
    const auto parts = text.split(':');
    if (parts.size() != 5) return {};
    Stamp result;
    bool ok[5] = {};
    result.size = parts[0].toLongLong(&ok[0]);
    result.modified = parts[1].toLongLong(&ok[1]);
    result.changed = parts[2].toLongLong(&ok[2]);
    result.device = parts[3].toULongLong(&ok[3]);
    result.inode = parts[4].toULongLong(&ok[4]);
    for (bool part : ok)
        if (!part) return {};
    return result;
}

Stamp stamp(const QString &path)
{
    Stamp result;
#ifdef Q_OS_UNIX
    struct stat info;
    if (::stat(QFile::encodeName(path).constData(), &info) != 0 || !S_ISREG(info.st_mode)) return result;
    result.size = info.st_size;
#ifdef Q_OS_DARWIN
    result.modified = qint64(info.st_mtimespec.tv_sec) * 1000000000 + info.st_mtimespec.tv_nsec;
    result.changed = qint64(info.st_ctimespec.tv_sec) * 1000000000 + info.st_ctimespec.tv_nsec;
#else
    result.modified = qint64(info.st_mtim.tv_sec) * 1000000000 + info.st_mtim.tv_nsec;
    result.changed = qint64(info.st_ctim.tv_sec) * 1000000000 + info.st_ctim.tv_nsec;
#endif
    result.device = quint64(info.st_dev);
    result.inode = quint64(info.st_ino);
#else
    const QFileInfo info(path);
    if (!info.isFile()) return result;
    result.size = info.size();
    result.modified = info.lastModified().toMSecsSinceEpoch();
    result.changed = info.metadataChangeTime().toMSecsSinceEpoch();
#endif
    return result;
}

QString sha256(const QString &path, const std::atomic_bool *cancel)
{
    const auto id = key(path);
    const auto before = stamp(id);
    if (!before.isValid()) return {};
    {
        QMutexLocker lock(&mutex);
        const auto it = entries.constFind(id);
        if (it != entries.cend() && it->stamp == before) return it->hash;
    }
    QFile file(id);
    if (!file.open(QIODevice::ReadOnly)) return {};
    ++reads;
    QCryptographicHash hash(QCryptographicHash::Sha256);
    while (!file.atEnd()) {
        if (cancel && cancel->load()) return {};
        const auto chunk = file.read(1024 * 1024);
        if (chunk.isEmpty() && file.error() != QFile::NoError) return {};
        hash.addData(chunk);
    }
    const auto result = QString::fromLatin1(hash.result().toHex());
    // A file written during hashing yields a hash of mixed content; return it for comparison but never cache it.
    if (stamp(id) == before) remember(id, before, result);
    return result;
}

void remember(const QString &path, const Stamp &stamp, const QString &hash)
{
    if (!stamp.isValid() || hash.isEmpty()) return;
    QMutexLocker lock(&mutex);
    entries.insert(key(path), {stamp, hash});
}

int hashReads() { return reads.load(); }

void clearCache()
{
    QMutexLocker lock(&mutex);
    entries.clear();
}
}
