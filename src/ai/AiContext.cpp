#include "AiContext.h"

#include <QHash>

// The reader's preferred language (Settings → AI). "source" keeps the paper's language.
QString aiLanguageName(const QString &language)
{
    static const QHash<QString, QString> names{{"ko", "Korean"}, {"en", "English"}, {"ja", "Japanese"},
        {"zh", "Simplified Chinese"}, {"de", "German"}, {"fr", "French"}, {"es", "Spanish"}};
    if (language == "source") return {};
    return names.value(language, "Korean");
}

namespace {

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
    const auto target = aiLanguageName(language);
    prompt.system = QStringLiteral(
        "You are a research reading assistant inside Owelk, a paper reader. Help the reader understand the paper "
        "from the material provided. Ground answers in that material; when it does not contain the answer, say so "
        "and separate general knowledge from what the paper states. Keep technical terms, symbols and citations "
        "exact. Use concise Markdown. Write math as LaTeX: $...$ inline and $$...$$ on its own line for display.");
    // A typed question is answered in its own language; one-click actions use the preferred language.
    if (!question.trimmed().isEmpty())
        prompt.system += QStringLiteral(" Answer in the language of the reader's request.");
    else if (target.isEmpty())
        prompt.system += QStringLiteral(" Answer in the language of the paper.");
    else
        prompt.system += QStringLiteral(" Answer in %1; keep technical terms in their original form where that is "
                                        "clearer.")
                             .arg(target);

    // The reader's level (Settings → AI): most readers are students meeting the field's notation for the
    // first time.
    if (action != "translate" && action != "notation") {
        if (materials.level == "brief")
            prompt.system += " Be brief, for a reader who knows the basics of the field: the key point first, "
                             "then only what is needed to follow it; define unfamiliar symbols in a few words and "
                             "skip examples unless asked.";
        else
            prompt.system += " Write for a student new to this field (an undergraduate or first-year graduate "
                             "student): plain words and short sentences; define each symbol and technical term the "
                             "first time it appears; give the intuition before the formal statement; and add a "
                             "small concrete example, with simple numbers or an everyday analogy, where it helps. "
                             "Do not assume background the paper does not explain; when you add it, say that it "
                             "is background knowledge.";
    }
    // Paper text comes with page numbers: answers point to their places, which Owelk turns into links.
    if ((!materials.pageText.isEmpty() || !materials.paperText.isEmpty()) && action != "translate")
        prompt.system += " When a statement draws on the paper, cite its place right after it as [p. N: \"exact "
                         "words\"], where N is the page number marked in the material and the words are a short phrase "
                         "(about 4 to 12 words) copied exactly from that page.";
    QStringList parts, context;
    QStringList paper;
    if (!materials.title.isEmpty()) paper << "Title: " + materials.title;
    if (!materials.authors.isEmpty()) paper << "Authors: " + materials.authors;
    if (!materials.year.isEmpty()) paper << "Year: " + materials.year;
    // The paper's details and text open the request and never depend on the rest, so a provider can
    // reuse them for every question about this paper (prompt caching).
    if (!paper.isEmpty())
        (materials.paperText.isEmpty() ? parts : context) << "<paper>\n" + paper.join('\n') + "\n</paper>";
    bool cut = false;
    int paperBudget = budget;
    if (!materials.paperText.isEmpty())
        context << "<paper_text>\n" + clip(materials.paperText, paperBudget, cut) + "\n</paper_text>";

    // The selection is the point of the request, so it is kept before page text.
    int remaining = budget;
    if (!materials.selection.isEmpty())
        parts << "<selection>\n" + clip(materials.selection, remaining, cut) + "\n</selection>";
    if (!materials.quote.isEmpty())
        parts << "<quoted_from_conversation>\n" + clip(materials.quote, remaining, cut)
                + "\n</quoted_from_conversation>";
    for (const auto &note : materials.notes)
        if (!note.trimmed().isEmpty()) parts << "<note>\n" + clip(note, remaining, cut) + "\n</note>";
    if (!materials.pageText.isEmpty())
        parts << QStringLiteral("<page%1>\n")
                     .arg(materials.pageNumber ? QStringLiteral(" number=\"%1\"").arg(materials.pageNumber) : QString())
                + clip(materials.pageText, remaining, cut) + "\n</page>";
    if (!materials.libraryText.isEmpty())
        parts << "<library_passages>\n" + clip(materials.libraryText, remaining, cut) + "\n</library_passages>";
    prompt.truncated = cut;

    // Translation needs a target: the preferred language, or English when that is "same as paper".
    const auto into = target.isEmpty() ? QStringLiteral("English") : target;
    QString task;
    const auto about = materials.label.isEmpty() ? QString() : " (" + materials.label + ")";
    if (action == "explain")
        task = "Explain the selected passage: what it says, why it matters in this paper, and the terms and notation "
               "it relies on.";
    else if (action == "translate")
        task
            = QStringLiteral("Translate the selected passage into %1. Give only the translation, faithful and natural; "
                             "keep equations, symbols and citation markers unchanged.")
                  .arg(into);
    else if (action == "summarize")
        task = materials.selection.isEmpty()
            ? QStringLiteral("Summarize this material: the main claims, method and results, in a few bullet points.")
            : QStringLiteral("Summarize the selected passage in a few bullet points.");
    else if (action == "library")
        task = "Answer from the passages of the reader's library above. Put the source marker, such as [2], right "
               "after each claim it supports; combine sources where they agree and say where they differ. If the "
               "passages do not answer the question, say so plainly and do not fill the gap from general knowledge "
               "without saying that you are doing so.\n\nQuestion: "
            + question.trimmed();
    else if (action == "figure")
        task = "Explain the attached figure or table" + about
            + ": start with one sentence on what it shows; then how to read it (axes, legend, colours, symbols, "
              "rows and columns); then what it implies for the paper's argument.";
    else if (action == "equation")
        task = "The attached image shows a displayed equation from the paper" + about
            + ". Explain it in this order:\n1. The equation in LaTeX, as a display formula.\n2. In one or two "
              "sentences, what it computes or states, and why the paper needs it.\n3. A table with the columns "
              "Symbol | Meaning | Where defined, with every symbol, operator and special notation in it (also "
              "operators the paper defines itself, such as ⊞, and sets or groups such as SE(3) or ℝⁿ). Under Where "
              "defined, cite the paper's definition as [p. N: \"exact words\"], or write Background when the "
              "paper uses it without defining it.\n4. A short Background section that explains those background "
              "notions.\n5. The equation step by step: what each part does and how the parts combine.";
    else if (action == "algorithm")
        task = "The attached image shows an algorithm or code from the paper" + about
            + ". Explain: its purpose in one or two sentences; its inputs and outputs; then a walk through it in "
              "order (by line number where it has them, grouping simple lines); and where the paper defines the "
              "helper functions, symbols and thresholds it uses, cited as [p. N: \"exact words\"].";
    else if (action == "notation")
        task = QStringLiteral(
            "List the mathematical symbols and notation this paper uses, as JSON only, with no other text:\n"
            "{\"symbols\": [{\"symbol\": \"LaTeX of the symbol\", \"text\": [\"how it appears in the "
            "paper text above, e.g. ωm or ⊞\"], \"meaning\": \"what it means here, in a short phrase in "
            "%1\", \"page\": page number where the paper defines it, or null, \"background\": true when "
            "the paper uses it without defining it}]}\nInclude variables, operators the paper defines, sets, "
            "groups, functions and accents (hats, tildes, bars); at most 80 entries, the most important first.")
                   .arg(target.isEmpty() ? QStringLiteral("the paper's language") : target);
    else
        task = question.trimmed().isEmpty() ? QStringLiteral("Help me understand this material.") : question.trimmed();
    if (action != "ask" && action != "library" && !question.trimmed().isEmpty())
        task += "\n\nAdditional request: " + question.trimmed();
    if (!materials.quote.isEmpty()) task += "\n\nThe request is about the passage quoted from this conversation.";
    if (materials.hasImage && action != "figure" && action != "equation" && action != "algorithm")
        task += "\n\nAn image from the paper is attached.";
    if (cut) task += "\n\n(Some material was shortened to fit; mention it if the answer depends on the missing part.)";
    parts << task;
    prompt.context = context.join("\n\n");
    prompt.text = parts.join("\n\n");
    return prompt;
}
