#include "Pencil.h"

// Elsewhere than iPadOS there is no Pencil to listen to (PencilIos.mm).
#if !defined(Q_OS_IOS)
Pencil::Pencil(QObject *parent) : QObject(parent) { }

Pencil::~Pencil() = default;

void Pencil::attach(QWindow *window)
{
    m_window = window;
}

QString Pencil::tapAction() const
{
    return QStringLiteral("ignore");
}

QString Pencil::squeezeAction() const
{
    return QStringLiteral("ignore");
}
#endif
