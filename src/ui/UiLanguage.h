#pragma once

#include <QObject>
#include <QTranslator>

class ResearchStore;

// The interface language: English as written, or "hangul" (every word spelled out in Hangul, see
// tools/hangul.py). Chosen in Settings › Appearance and kept as the "ui.language" setting; on a change
// the QML engine is asked to translate again (main.cpp), so it shows at once.
class UiLanguage final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString language READ language NOTIFY changed)
    // False when the build had no Qt Linguist tools (the option is then hidden).
    Q_PROPERTY(bool available READ available CONSTANT)
public:
    UiLanguage(ResearchStore *store, QObject *parent = nullptr);
    QString language() const { return m_language; }
    bool available() const;
    Q_INVOKABLE void choose(const QString &language);

signals:
    void changed();

private:
    void apply();
    ResearchStore *m_store;
    QTranslator m_translator;
    QString m_language;
};
