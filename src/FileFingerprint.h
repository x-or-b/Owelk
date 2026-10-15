#pragma once

#include <QString>
#include <atomic>

// Process-wide SHA-256 cache for source verification.
// A file is rehashed only when its size, modification time, status-change time or file identity changes.
// The status-change time cannot be set by ordinary tools, so content rewrites that restore mtime are still detected.
// On Windows the same comes from NTFS (its change time and file index); other file systems may lack them.
namespace FileFingerprint {
struct Stamp {
    qint64 size = -1;
    qint64 modified = 0;
    qint64 changed = 0;
    quint64 device = 0;
    quint64 inode = 0;
    bool isValid() const { return size >= 0; }
    bool operator==(const Stamp &) const = default;
    QString toString() const;
    static Stamp fromString(const QString &text);
};

Stamp stamp(const QString &path);
// Whether two paths name the same file, also when spelled differently (letter case, links).
bool sameFile(const QString &first, const QString &second);
// Empty when the file cannot be read or the hash was cancelled.
QString sha256(const QString &path, const std::atomic_bool *cancel = nullptr);
// The hash already known for this file (unchanged since), without reading it; empty when not known.
QString knownSha256(const QString &path);
// Seed a hash verified earlier; it is used only while the file still has this stamp.
void remember(const QString &path, const Stamp &stamp, const QString &hash);
// Number of full-file reads since process start. Tests use it to prove that cache hits do no I/O.
int hashReads();
// Drop every cached hash, as a new process would start. For tests.
void clearCache();
}
