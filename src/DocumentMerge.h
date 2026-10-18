#pragma once

#include <QList>
#include <QPair>
#include <QString>
#include <QVariantList>

// Everything that points at a paper by its ID, moved onto another ID when two entries turn out to be one paper:
// Locate Original PDF and Copy into Library folding a duplicate (ResearchStoreRelink.cpp), and sync merging the
// same PDF added on two computers (LibrarySync.cpp). A new table that refers to papers is added here, once.
// Reading positions, recent papers and the paper's details are merged by each caller in its own way.
inline QList<QPair<QString, QVariantList>> movePaperReferences(const QString &from, const QString &to)
{
    QList<QPair<QString, QVariantList>> statements;
    for (const auto *table : {"highlights", "vocabulary", "collection_documents", "document_tags"})
        statements.append(
            {QStringLiteral("UPDATE OR REPLACE %1 SET document_id=? WHERE document_id=?").arg(table), {to, from}});
    statements.append({"UPDATE OR REPLACE links SET from_id=? WHERE from_kind='document' AND from_id=?", {to, from}});
    statements.append({"UPDATE OR REPLACE links SET to_id=? WHERE to_kind='document' AND to_id=?", {to, from}});
    // The paper's own folder of AI chats is named after its ID and goes with it.
    statements.append({"UPDATE OR IGNORE ai_folders SET id='document:'||? WHERE id='document:'||?", {to, from}});
    statements.append({"UPDATE ai_threads SET folder_id='document:'||? WHERE folder_id='document:'||?", {to, from}});
    statements.append({"DELETE FROM ai_folders WHERE id='document:'||?", {from}});
    return statements;
}
