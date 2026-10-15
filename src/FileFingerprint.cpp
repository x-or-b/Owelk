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
#elif defined(Q_OS_WIN)
#include <QDir>
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
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

    QString key(const QString &path)
    {
        return QFileInfo(path).absoluteFilePath();
    }
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
#elif defined(Q_OS_WIN)
    // NTFS keeps a change time of its own (FILE_BASIC_INFO.ChangeTime, which ordinary tools cannot set back) and
    // a file identity (volume serial and file index), as Unix does with ctime, device and inode. Times are in
    // 100 ns units.
    const auto native = QDir::toNativeSeparators(QFileInfo(path).absoluteFilePath());
    const HANDLE file = CreateFileW(reinterpret_cast<const wchar_t *>(native.utf16()), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return result;
    BY_HANDLE_FILE_INFORMATION info{};
    FILE_BASIC_INFO basic{};
    const bool ok = GetFileInformationByHandle(file, &info) && !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
        && GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof basic);
    CloseHandle(file);
    if (!ok) return result;
    result.size = qint64((quint64(info.nFileSizeHigh) << 32) | info.nFileSizeLow);
    result.modified = basic.LastWriteTime.QuadPart;
    result.changed = basic.ChangeTime.QuadPart;
    result.device = info.dwVolumeSerialNumber;
    result.inode = (quint64(info.nFileIndexHigh) << 32) | info.nFileIndexLow;
#else
    const QFileInfo info(path);
    if (!info.isFile()) return result;
    result.size = info.size();
    result.modified = info.lastModified().toMSecsSinceEpoch();
    result.changed = info.metadataChangeTime().toMSecsSinceEpoch();
#endif
    return result;
}

bool sameFile(const QString &first, const QString &second)
{
    const QFileInfo a(first), b(second);
    if (a.absoluteFilePath() == b.absoluteFilePath()) return true;
    const auto canonical = a.canonicalFilePath();
    if (!canonical.isEmpty() && canonical == b.canonicalFilePath()) return true;
    // Another spelling of the same file (letter case on macOS and Windows disks, a hard link).
    const auto x = stamp(first), y = stamp(second);
    return x.isValid() && y.isValid() && x.inode != 0 && x.device == y.device && x.inode == y.inode;
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

QString knownSha256(const QString &path)
{
    const auto id = key(path);
    const auto now = stamp(id);
    if (!now.isValid()) return {};
    QMutexLocker lock(&mutex);
    const auto it = entries.constFind(id);
    return it != entries.cend() && it->stamp == now ? it->hash : QString();
}

void remember(const QString &path, const Stamp &stamp, const QString &hash)
{
    if (!stamp.isValid() || hash.isEmpty()) return;
    QMutexLocker lock(&mutex);
    entries.insert(key(path), {stamp, hash});
}

int hashReads()
{
    return reads.load();
}

void clearCache()
{
    QMutexLocker lock(&mutex);
    entries.clear();
}
}
