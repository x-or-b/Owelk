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
    // What attached images from a paper are: "Figure 3, page 5", "Equation (2), page 3".
    QStringList imageLabels;
    // How the reader wants things explained: "easy" (plain words and examples) or "brief"; and the
    // reader's own standing instructions (Settings → AI).
    QString level, instructions;
};

struct AiPrompt {
    // context: the paper's details and text, the same for every request about that paper, so providers
    // can cache it (it goes first); text: the rest of the material and the task.
    QString system, context, text;
    bool truncated = false;
};

// "Korean" for "ko" and so on; empty for "source" (the paper's own language).
QString aiLanguageName(const QString &language);

// action: ask | translate | library | notation.
// language: ko | en | source. Long material is cut to the character budget (page text first; the paper's
// text has a budget of its own) with a visible marker.
AiPrompt buildAiPrompt(const QString &action, const QString &language, const QString &question,
    const AiMaterials &materials, int budget = 60000);
