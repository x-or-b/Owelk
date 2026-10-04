#include "AiContext.h"

#include <QHash>

namespace {
// The reader's preferred language (Settings → AI). "source" keeps the paper's language.
QString languageName(const QString &language)
{
    static const QHash<QString, QString> names{{"ko", "Korean"}, {"en", "English"}, {"ja", "Japanese"},
        {"zh", "Simplified Chinese"}, {"de", "German"}, {"fr", "French"}, {"es", "Spanish"}};
    if (language == "source") return {};
    return names.value(language, "Korean");
}

QString clip(const QString &text, int &budget, bool &truncated)
{
    if (budget <= 0) {
        if (!text.isEmpty()) truncated = true;
        return {};
    }
    if (text.size() <= budget) {
        budget -= text.size();
        return text;
    }
    truncated = true;
    const auto kept = text.left(budget);
    budget = 0;
    return kept + "\n[…truncated]";
}
}

AiPrompt buildAiPrompt(
    const QString &action, const QString &language, const QString &question, const AiMaterials &materials, int budget)
{
    AiPrompt prompt;
    const auto target = languageName(language);
    prompt.system = QStringLiteral(
        "You are a research reading assistant inside Owelk, a paper reader. Help the reader understand the paper "
        "from the material provided. Ground answers in that material; when it does not contain the answer, say so "
        "and separate general knowledge from what the paper states. Keep technical terms, symbols and citations "
        "exact. Use concise Markdown.");
    // A typed question is answered in its own language; one-click actions use the preferred language.
    if (!question.trimmed().isEmpty())
        prompt.system += QStringLiteral(" Answer in the language of the reader's request.");
    else if (target.isEmpty())
        prompt.system += QStringLiteral(" Answer in the language of the paper.");
    else
        prompt.system += QStringLiteral(" Answer in %1; keep technical terms in their original form where that is "
                                        "clearer.")
                             .arg(target);

    QStringList parts;
    QStringList paper;
    if (!materials.title.isEmpty()) paper << "Title: " + materials.title;
    if (!materials.authors.isEmpty()) paper << "Authors: " + materials.authors;
    if (!materials.year.isEmpty()) paper << "Year: " + materials.year;
    if (!paper.isEmpty()) parts << "<paper>\n" + paper.join('\n') + "\n</paper>";

    // The selection is the point of the request, so it is kept before page and paper text.
    int remaining = budget;
    bool cut = false;
    if (!materials.selection.isEmpty())
        parts << "<selection>\n" + clip(materials.selection, remaining, cut) + "\n</selection>";
    for (const auto &note : materials.notes)
        if (!note.trimmed().isEmpty()) parts << "<note>\n" + clip(note, remaining, cut) + "\n</note>";
    if (!materials.pageText.isEmpty())
        parts << QStringLiteral("<page%1>\n")
                     .arg(materials.pageNumber ? QStringLiteral(" number=\"%1\"").arg(materials.pageNumber) : QString())
                + clip(materials.pageText, remaining, cut) + "\n</page>";
    if (!materials.paperText.isEmpty())
        parts << "<paper_text>\n" + clip(materials.paperText, remaining, cut) + "\n</paper_text>";
    prompt.truncated = cut;

    // Translation needs a target: the preferred language, or English when that is "same as paper".
    const auto into = target.isEmpty() ? QStringLiteral("English") : target;
    QString task;
    if (action == "explain")
        task = "Explain the selected passage: what it says, why it matters in this paper, and any terms or notation a "
               "graduate student might need.";
    else if (action == "translate")
        task
            = QStringLiteral("Translate the selected passage into %1. Give only the translation, faithful and natural; "
                             "keep equations, symbols and citation markers unchanged.")
                  .arg(into);
    else if (action == "summarize")
        task = materials.selection.isEmpty()
            ? QStringLiteral("Summarize this material: the main claims, method and results, in a few bullet points.")
            : QStringLiteral("Summarize the selected passage in a few bullet points.");
    else if (action == "figure")
        task = "Explain the attached figure or table: what it shows, how to read it, and what it implies for the "
               "paper's argument.";
    else
        task = question.trimmed().isEmpty() ? QStringLiteral("Help me understand this material.") : question.trimmed();
    if (action != "ask" && !question.trimmed().isEmpty()) task += "\n\nAdditional request: " + question.trimmed();
    if (materials.hasImage && action != "figure") task += "\n\nAn image from the paper is attached.";
    if (cut) task += "\n\n(Some material was shortened to fit; mention it if the answer depends on the missing part.)";
    parts << task;
    prompt.text = parts.join("\n\n");
    return prompt;
}
