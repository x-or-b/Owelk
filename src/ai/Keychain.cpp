#include "Keychain.h"

#include <QDir>
#include <QFile>
#include <QSaveFile>

#ifdef Q_OS_MACOS
#include <Security/Security.h>
#endif

namespace Keychain {
QString service()
{
    const auto override = qEnvironmentVariable("OWELK_KEYCHAIN_SERVICE");
    return override.isEmpty() ? QStringLiteral("org.owelk.reader") : override;
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
#else
namespace {
    QString path(const QString &account, const QString &directory)
    {
        return directory + "/keys/" + service() + "." + QString(account).replace('/', '_');
    }
}

bool write(const QString &account, const QString &secret, const QString &directory)
{
    if (!QDir().mkpath(directory + "/keys")) return false;
    QSaveFile file(path(account, directory));
    if (!file.open(QIODevice::WriteOnly)) return false;
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    file.write(secret.toUtf8());
    return file.commit();
}

QString read(const QString &account, const QString &directory)
{
    QFile file(path(account, directory));
    return file.open(QIODevice::ReadOnly) ? QString::fromUtf8(file.readAll()) : QString();
}

bool remove(const QString &account, const QString &directory)
{
    const auto file = path(account, directory);
    return !QFile::exists(file) || QFile::remove(file);
}
#endif
}
