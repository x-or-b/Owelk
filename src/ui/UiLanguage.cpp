#include "UiLanguage.h"
#include "ResearchStore.h"

#include <QCoreApplication>
#include <QFile>

namespace {
const QString hangulFile = QStringLiteral(":/owelk/i18n/owelk_hangul.qm");
}

UiLanguage::UiLanguage(ResearchStore *store, QObject *parent) : QObject(parent), m_store(store)
{
    m_language = m_store->setting("ui.language", "en") == "hangul" && available() ? "hangul" : "en";
    apply();
}

bool UiLanguage::available() const
{
    return QFile::exists(hangulFile);
}

void UiLanguage::choose(const QString &language)
{
    const auto next = language == "hangul" && available() ? QStringLiteral("hangul") : QStringLiteral("en");
    if (next == m_language) return;
    m_language = next;
    m_store->setSetting("ui.language", next);
    apply();
    emit changed();
}

void UiLanguage::apply()
{
    QCoreApplication::removeTranslator(&m_translator);
    if (m_language == "hangul" && m_translator.load(hangulFile)) QCoreApplication::installTranslator(&m_translator);
}
