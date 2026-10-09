#pragma once

#include <QString>
#include <QStringList>

// What a reading request sends: the paper's details, the passage or page, and attached notes.
struct AiMaterials {
    QString title, authors, year;
    QString selection; // Selected text or an excerpt.
    QString quote; // A passage the reader quoted from the conversation (Ask About This).
    QString pageText; // The current page.
    QString paperText; // Leading pages of the paper (for "Ask about paper").
    QString libraryText; // Passages from several papers, each marked [n] (for "Ask your library").
    QStringList notes;
    int pageNumber = 0; // 1-based; 0 when unknown.
    bool hasImage = false;
};

struct AiPrompt {
    QString system, text;
    bool truncated = false;
};

// "Korean" for "ko" and so on; empty for "source" (the paper's own language).
QString aiLanguageName(const QString &language);

// action: explain | translate | summarize | ask | figure. language: ko | en | source.
// Long material is cut to the character budget (page and paper text first) with a visible marker.
AiPrompt buildAiPrompt(const QString &action, const QString &language, const QString &question,
    const AiMaterials &materials, int budget = 60000);
