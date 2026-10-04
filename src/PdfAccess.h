#pragma once

#include <QPdfDocument>
#include <QString>

// Passwords for encrypted PDFs, given by the reader in the viewer. Every place that opens a PDF in the
// background (indexing, captures, annotations, printing, AI) goes through load(): an unencrypted file
// opens as usual; a locked one is retried with the known password. Passwords stay in memory for the
// session, or in the system keyring when the reader asks Owelk to remember them.
namespace PdfAccess {
QPdfDocument::Error load(QPdfDocument &pdf, const QString &path);
// Called after the viewer opened a locked file with this password.
void remember(const QString &path, const QString &password, bool keep, const QString &keyDirectory);
QString password(const QString &path);
void setKeyDirectory(const QString &directory);
void forget(const QString &path);
}
