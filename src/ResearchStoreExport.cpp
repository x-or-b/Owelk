#include "ResearchStore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QSqlQuery>

// Plain files for use outside Owelk: Markdown for a paper's reading notes and for standalone notes,
// BibTeX for citing. Exports only write new files in the chosen folder; nothing in the library changes.
namespace {
QString safeName(const QString &text)
{
    auto name = text.simplified();
    name.replace(QRegularExpression("[\\\\/:*?\"<>|\\x00-\\x1f]"), "-");
    name = name.left(80).trimmed();
    while (name.endsWith('.')) name.chop(1);
    return name.isEmpty() ? QStringLiteral("Untitled") : name;
}

// A name not yet taken in the folder ("Name.md", "Name 2.md", …).
QString freePath(const QString &folder, const QString &name, const QString &suffix)
{
    auto path = folder + "/" + name + suffix;
    for (int i = 2; QFileInfo::exists(path); ++i) path = folder + "/" + name + " " + QString::number(i) + suffix;
    return path;
}

bool writeText(const QString &path, const QString &text)
{
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly)) return false;
    file.write(text.toUtf8());
    return file.commit();
}

// owelk:// links mean nothing outside Owelk: keep their text.
QString plainLinks(QString markdown)
{
    static const QRegularExpression link("\\[([^\\]]*)\\]\\(owelk://[^)]*\\)");
    return markdown.replace(link, "\\1");
}

QString quoted(const QString &text)
{
    QStringList lines;
    for (const auto &line : text.trimmed().split('\n')) lines << "> " + line;
    return lines.join('\n');
}

QString bibEscape(QString text)
{
    text = text.simplified();
    for (const auto *special : {"\\", "{", "}"}) text.replace(special, QString("\\") + special);
    for (const auto *special : {"&", "%", "$", "#", "_"}) text.replace(special, QString("\\") + special);
    return text;
}

QString keyPart(const QString &text)
{
    auto ascii = text.normalized(QString::NormalizationForm_KD);
    ascii.remove(QRegularExpression("[^A-Za-z0-9]"));
    return ascii.toLower();
}
}

QString ResearchStore::exportPaperMarkdown(const QUrl &source, const QString &folder)
{
    const auto document = documentLinkId(source);
    const auto directory = QDir::fromNativeSeparators(folder);
    if (document.isEmpty() || !QDir().mkpath(directory)) {
        emit message("Choose a folder to export to.");
        return {};
    }
    const auto details = documentDetails(source);
    const auto title = displayName(source);
    const auto base = safeName(title);
    const auto path = freePath(directory, base, ".md");
    const auto images = QFileInfo(path).completeBaseName() + " images";
    QStringList out{"# " + title, ""};
    QStringList meta;
    for (const auto *field : {"authors", "year"})
        if (!details.value(field).toString().isEmpty()) meta << details.value(field).toString();
    if (!details.value("doi").toString().isEmpty()) meta << "DOI " + details.value("doi").toString();
    if (!details.value("arxiv").toString().isEmpty()) meta << "arXiv " + details.value("arxiv").toString();
    if (!meta.isEmpty()) out << meta.join(" · ") << "";
    out << "File: " + localPath(source) << "";

    QSqlQuery marks(m_database);
    marks.prepare("SELECT page,kind,text,body,color FROM highlights WHERE document_id=? AND deleted_at IS NULL "
                  "ORDER BY page,created_at");
    marks.addBindValue(document);
    QStringList highlights;
    if (marks.exec())
        while (marks.next()) {
            const auto page = "p. " + QString::number(marks.value(0).toInt() + 1);
            const auto kind = marks.value(1).toString(), text = marks.value(2).toString().simplified(),
                       body = marks.value(3).toString().trimmed();
            if (kind == "draw" || kind == "image") {
                highlights << "- " + page + " · " + (kind == "draw" ? "drawing" : "image")
                        + (body.isEmpty() ? "" : ": " + body);
                continue;
            }
            QString entry = "- " + page;
            if (!text.isEmpty()) entry += " · “" + text + "”";
            if (kind == "text") entry += " · text box";
            highlights << entry;
            if (!body.isEmpty()) highlights << "  " + quoted(body).replace("\n", "\n  ");
        }
    if (!highlights.isEmpty()) out << "## Highlights and comments" << "" << highlights << "";

    QStringList captured;
    int copied = 0;
    for (const auto &value : captures()) {
        const auto capture = value.toMap();
        if (!sameSource(capture.value("source").toUrl(), source)) continue;
        const auto page = "p. " + QString::number(capture.value("page").toInt() + 1);
        captured << "### " + page
                + (capture.value("caption").toString().isEmpty()
                        ? ""
                        : " · " + capture.value("caption").toString().simplified());
        if (!capture.value("text").toString().isEmpty()) captured << "" << quoted(capture.value("text").toString());
        const auto image = capture.value("image").toUrl().toLocalFile();
        if (capture.value("imageAvailable").toBool() && QFileInfo::exists(image)) {
            QDir().mkpath(directory + "/" + images);
            const auto copy = images + "/" + QFileInfo(image).fileName();
            if (QFile::exists(directory + "/" + copy) || QFile::copy(image, directory + "/" + copy)) {
                captured << "" << "![" + page + "](" + QString(copy).replace(' ', "%20") + ")";
                ++copied;
            }
        }
        if (!capture.value("note").toString().trimmed().isEmpty())
            captured << "" << "Note: " + capture.value("note").toString().trimmed();
        captured << "";
    }
    if (!captured.isEmpty()) out << "## Captures" << "" << captured;

    QStringList linked;
    for (const auto &value : backlinks("document", document)) {
        const auto link = value.toMap();
        if (link.value("kind") == "note") linked << "- " + link.value("title").toString();
    }
    if (!linked.isEmpty()) out << "## Linked notes" << "" << linked << "";

    if (!writeText(path, out.join('\n'))) {
        emit message("Cannot write " + QDir::toNativeSeparators(path));
        return {};
    }
    emit message("Exported to " + QDir::toNativeSeparators(path));
    return path;
}

int ResearchStore::exportNotesMarkdown(const QString &folder)
{
    const auto directory = QDir::fromNativeSeparators(folder);
    if (!QDir().mkpath(directory)) return 0;
    QSqlQuery query(m_database);
    query.exec("SELECT title,body FROM notes WHERE deleted_at IS NULL ORDER BY updated_at DESC");
    int written = 0;
    while (query.next()) {
        const auto title = query.value(0).toString();
        const auto body = plainLinks(query.value(1).toString());
        const auto text = (title.isEmpty() ? QString() : "# " + title + "\n\n") + body;
        written += writeText(freePath(directory, safeName(title), ".md"), text);
    }
    emit message(QStringLiteral("Exported %1 notes to %2").arg(written).arg(QDir::toNativeSeparators(directory)));
    return written;
}

QString ResearchStore::bibtex(const QVariantList &sources) const
{
    QStringList entries;
    QSet<QString> keys;
    for (const auto &value : sources) {
        const QUrl source(value.toString());
        const auto details = documentDetails(source);
        const auto title = displayName(source);
        const auto authors = details.value("authors").toString();
        const auto year = details.value("year").toString();
        const auto doi = details.value("doi").toString(), arxiv = details.value("arxiv").toString();
        // Key: first author's family name, year, first long word of the title (unique in this file).
        const auto first = authors.section(',', 0, 0).simplified();
        auto key = keyPart(first.section(' ', -1)) + year;
        for (const auto &word : title.split(' ', Qt::SkipEmptyParts))
            if (keyPart(word).size() > 3) {
                key += keyPart(word);
                break;
            }
        if (key.isEmpty()) key = "paper";
        auto unique = key;
        for (char suffix = 'a'; keys.contains(unique) && suffix <= 'z'; ++suffix) unique = key + suffix;
        keys.insert(unique);
        QStringList fields{"  title = {" + bibEscape(title) + "}"};
        if (!authors.isEmpty()) {
            QStringList names;
            for (const auto &name : authors.split(',', Qt::SkipEmptyParts)) names << bibEscape(name);
            fields << "  author = {" + names.join(" and ") + "}";
        }
        if (!year.isEmpty()) fields << "  year = {" + bibEscape(year) + "}";
        if (!doi.isEmpty()) fields << "  doi = {" + bibEscape(doi) + "}";
        if (!arxiv.isEmpty())
            fields << "  eprint = {" + bibEscape(arxiv) + "}" << "  archivePrefix = {arXiv}"
                   << "  url = {https://arxiv.org/abs/" + arxiv + "}";
        // A DOI usually means a published article; an arXiv-only paper is a preprint.
        const auto type = !doi.isEmpty() ? QStringLiteral("article") : QStringLiteral("misc");
        entries << "@" + type + "{" + unique + ",\n" + fields.join(",\n") + "\n}";
    }
    return entries.join("\n\n") + (entries.isEmpty() ? "" : "\n");
}

bool ResearchStore::exportBibTeX(const QVariantList &sources, const QString &file)
{
    const auto path = QDir::fromNativeSeparators(file);
    const bool ok = !sources.isEmpty() && writeText(path, bibtex(sources));
    emit message(ok
            ? QStringLiteral("Exported %1 entries to %2").arg(sources.size()).arg(QDir::toNativeSeparators(path))
            : QStringLiteral("Cannot write the BibTeX file."));
    return ok;
}
