#include "PdfAccess.h"
#include "Keychain.h"

#include <QCryptographicHash>
#include <QFileInfo>
#include <QHash>
#include <mutex>

namespace {
std::mutex lock;
QHash<QString, QString> passwords;
QString keyDirectory;

QString canonical(const QString &path)
{
    const QFileInfo info(path);
    return info.canonicalFilePath().isEmpty() ? info.absoluteFilePath() : info.canonicalFilePath();
}

// The keyring entry is named by a hash of the path, so the keyring does not list file names.
QString account(const QString &path)
{
    return "pdf-"
        + QString::fromLatin1(QCryptographicHash::hash(canonical(path).toUtf8(), QCryptographicHash::Sha1).toHex());
}
}

namespace PdfAccess {
void setKeyDirectory(const QString &directory)
{
    std::lock_guard guard(lock);
    keyDirectory = directory;
}

QString password(const QString &path)
{
    const auto key = canonical(path);
    QString directory;
    {
        std::lock_guard guard(lock);
        if (const auto found = passwords.constFind(key); found != passwords.cend()) return *found;
        directory = keyDirectory;
    }
    const auto stored = Keychain::read(account(path), directory);
    if (!stored.isEmpty()) {
        std::lock_guard guard(lock);
        passwords.insert(key, stored);
    }
    return stored;
}

QPdfDocument::Error load(QPdfDocument &pdf, const QString &path)
{
    auto error = pdf.load(path);
    if (error != QPdfDocument::Error::IncorrectPassword) return error;
    const auto known = password(path);
    if (known.isEmpty()) return error;
    pdf.setPassword(known);
    return pdf.load(path);
}

void remember(const QString &path, const QString &password, bool keep, const QString &directory)
{
    if (password.isEmpty()) return;
    {
        std::lock_guard guard(lock);
        passwords.insert(canonical(path), password);
    }
    if (keep) Keychain::write(account(path), password, directory);
}

void forget(const QString &path)
{
    QString directory;
    {
        std::lock_guard guard(lock);
        passwords.remove(canonical(path));
        directory = keyDirectory;
    }
    Keychain::remove(account(path), directory);
}
}
