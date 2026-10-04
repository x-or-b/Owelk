#include "Keychain.h"

#include <QDir>
#include <QFile>
#include <QSaveFile>

#ifdef Q_OS_MACOS
#include <Security/Security.h>
#elif defined(Q_OS_WIN)
#include <string>
#include <windows.h>
#include <wincred.h>
#elif defined(OWELK_HAVE_LIBSECRET)
#include <libsecret/secret.h>
#endif

namespace Keychain {
QString storageName()
{
#if defined(Q_OS_MACOS)
    return QStringLiteral("the macOS Keychain");
#elif defined(Q_OS_WIN)
    return QStringLiteral("Windows Credential Manager");
#elif defined(OWELK_HAVE_LIBSECRET)
    return QStringLiteral("the system keyring");
#else
    return QStringLiteral("a file only you can read in Owelk's data folder");
#endif
}

QString service()
{
    const auto override = qEnvironmentVariable("OWELK_KEYCHAIN_SERVICE");
    return override.isEmpty() ? QStringLiteral("org.owelk.reader") : override;
}

namespace {
    // No keyring available: a file only the user can read, in a folder only the user can open.
    [[maybe_unused]] QString keyPath(const QString &account, const QString &directory)
    {
        return directory + "/keys/" + service() + "." + QString(account).replace('/', '_');
    }
    [[maybe_unused]] bool fileWrite(const QString &account, const QString &secret, const QString &directory)
    {
        if (directory.isEmpty() || !QDir().mkpath(directory + "/keys")) return false;
        QFile::setPermissions(
            directory + "/keys", QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
        QSaveFile file(keyPath(account, directory));
        if (!file.open(QIODevice::WriteOnly)) return false;
        file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        file.write(secret.toUtf8());
        return file.commit();
    }
    [[maybe_unused]] QString fileRead(const QString &account, const QString &directory)
    {
        QFile file(keyPath(account, directory));
        return file.open(QIODevice::ReadOnly) ? QString::fromUtf8(file.readAll()) : QString();
    }
    [[maybe_unused]] bool fileRemove(const QString &account, const QString &directory)
    {
        const auto file = keyPath(account, directory);
        return !QFile::exists(file) || QFile::remove(file);
    }
}

#ifdef Q_OS_MACOS
namespace {
    CFStringRef cf(const QString &text)
    {
        return text.toCFString();
    }

    CFMutableDictionaryRef query(const QString &account)
    {
        auto *dictionary
            = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const auto serviceName = cf(service()), accountName = cf(account);
        CFDictionarySetValue(dictionary, kSecClass, kSecClassGenericPassword);
        CFDictionarySetValue(dictionary, kSecAttrService, serviceName);
        CFDictionarySetValue(dictionary, kSecAttrAccount, accountName);
        CFRelease(serviceName);
        CFRelease(accountName);
        return dictionary;
    }
}

bool write(const QString &account, const QString &secret, const QString &)
{
    remove(account, {});
    auto *item = query(account);
    const auto bytes = secret.toUtf8();
    auto *data = CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(bytes.constData()), bytes.size());
    CFDictionarySetValue(item, kSecValueData, data);
    // Readable only while the Mac is unlocked, and never synced to other devices.
    CFDictionarySetValue(item, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
    const auto status = SecItemAdd(item, nullptr);
    CFRelease(data);
    CFRelease(item);
    return status == errSecSuccess;
}

QString read(const QString &account, const QString &)
{
    auto *item = query(account);
    CFDictionarySetValue(item, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(item, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef result = nullptr;
    const auto status = SecItemCopyMatching(item, &result);
    CFRelease(item);
    if (status != errSecSuccess || !result) return {};
    const auto *data = static_cast<CFDataRef>(result);
    const auto secret
        = QString::fromUtf8(reinterpret_cast<const char *>(CFDataGetBytePtr(data)), CFDataGetLength(data));
    CFRelease(result);
    return secret;
}

bool remove(const QString &account, const QString &)
{
    auto *item = query(account);
    const auto status = SecItemDelete(item);
    CFRelease(item);
    return status == errSecSuccess || status == errSecItemNotFound;
}
#elif defined(Q_OS_WIN)
// Windows Credential Manager: generic credentials named "<service>/<account>", per user.
namespace {
    std::wstring target(const QString &account)
    {
        return (service() + "/" + account).toStdWString();
    }
}

bool write(const QString &account, const QString &secret, const QString &)
{
    const auto name = target(account);
    const auto bytes = secret.toUtf8();
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<LPWSTR>(name.c_str());
    credential.CredentialBlobSize = DWORD(bytes.size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char *>(bytes.constData()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&credential, 0);
}

QString read(const QString &account, const QString &)
{
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target(account).c_str(), CRED_TYPE_GENERIC, 0, &credential)) return {};
    const auto secret = QString::fromUtf8(
        reinterpret_cast<const char *>(credential->CredentialBlob), int(credential->CredentialBlobSize));
    CredFree(credential);
    return secret;
}

bool remove(const QString &account, const QString &)
{
    return CredDeleteW(target(account).c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
}
#elif defined(OWELK_HAVE_LIBSECRET)
// Linux desktop keyring (GNOME Keyring, KWallet through the Secret Service API).
namespace {
    const SecretSchema *schema()
    {
        static const SecretSchema value{"org.owelk.reader.Key", SECRET_SCHEMA_NONE,
            {{"service", SECRET_SCHEMA_ATTRIBUTE_STRING}, {"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {nullptr, {}}}};
        return &value;
    }
}

bool write(const QString &account, const QString &secret, const QString &directory)
{
    GError *error = nullptr;
    const auto label = ("Owelk " + account).toUtf8();
    const bool ok = secret_password_store_sync(schema(), SECRET_COLLECTION_DEFAULT, label.constData(),
        secret.toUtf8().constData(), nullptr, &error, "service", service().toUtf8().constData(), "account",
        account.toUtf8().constData(), nullptr);
    if (error) g_error_free(error);
    // No Secret Service running (minimal desktops, CI): keep the key in the owner-only file instead.
    return ok || fileWrite(account, secret, directory);
}

QString read(const QString &account, const QString &directory)
{
    GError *error = nullptr;
    gchar *value = secret_password_lookup_sync(schema(), nullptr, &error, "service", service().toUtf8().constData(),
        "account", account.toUtf8().constData(), nullptr);
    if (error) g_error_free(error);
    if (!value) return fileRead(account, directory);
    const auto secret = QString::fromUtf8(value);
    secret_password_free(value);
    return secret;
}

bool remove(const QString &account, const QString &directory)
{
    fileRemove(account, directory);
    GError *error = nullptr;
    secret_password_clear_sync(schema(), nullptr, &error, "service", service().toUtf8().constData(), "account",
        account.toUtf8().constData(), nullptr);
    if (error) g_error_free(error);
    return true;
}
#else
bool write(const QString &account, const QString &secret, const QString &directory)
{
    return fileWrite(account, secret, directory);
}
QString read(const QString &account, const QString &directory)
{
    return fileRead(account, directory);
}
bool remove(const QString &account, const QString &directory)
{
    return fileRemove(account, directory);
}
#endif
}
