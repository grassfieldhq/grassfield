#pragma once

#include "appearance.h"
#include "capturehistory.h"
#include "document.h"

#include <QImage>
#include <QMutex>
#include <QQuickImageProvider>
#include <QString>
#include <QStringList>

// The backend of the editor window: one open document, its state for the toolbar and the menus, and Done and Revert. The
// window itself is qml/Editor.qml; everything it may do to a file goes through the two invokables below.
class ScreenshotApp : public AppearanceSettings
{
    Q_OBJECT
    // The picture file, "" when none opened. main.cpp then prints the errors on stderr and exits 2 before any window exists.
    Q_PROPERTY(QString path READ path NOTIFY documentChanged)
    Q_PROPERTY(QString fileName READ fileName NOTIFY documentChanged)
    // The picture's size in device pixels, 0 x 0 without a document.
    Q_PROPERTY(int imageWidth READ imageWidth NOTIFY documentChanged)
    Q_PROPERTY(int imageHeight READ imageHeight NOTIFY documentChanged)
    // image://screenshot/<revision>: the original picture (the provider below); the revision changes when it does.
    Q_PROPERTY(QString imageSource READ imageSource NOTIFY documentChanged)
    // Unsaved changes, and whether Revert has an original to put back.
    Q_PROPERTY(bool dirty READ dirty NOTIFY documentChanged)
    Q_PROPERTY(bool canRevert READ canRevert NOTIFY documentChanged)
    // The messages of the command line's rejected arguments, and the last failure of Done or Revert ("" when none).
    Q_PROPERTY(QStringList errors READ errors CONSTANT)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    // `path` empty with `errors` set: nothing to edit. `historyRoot` empty: the user's own (CaptureHistory::defaultRoot()).
    ScreenshotApp(const QString &path, const QStringList &errors, const QString &historyRoot = QString(), QObject *parent = nullptr);

    QString path() const { return m_document.path(); }
    QString fileName() const;
    int imageWidth() const { return m_document.original().width(); }
    int imageHeight() const { return m_document.original().height(); }
    QString imageSource() const;
    bool dirty() const { return m_document.dirty(); }
    bool canRevert() const { return m_document.canRevert(); }
    QStringList errors() const { return m_errors; }
    QString lastError() const { return m_lastError; }

    // The picture the provider serves (a copy: the document stays on the GUI thread).
    QImage currentImage() const;

    // Done: replaces the file with the edited picture, keeping the original in the history. True when the window may close.
    Q_INVOKABLE bool done();
    // Revert: puts the captured picture back in the file.
    Q_INVOKABLE bool revert();

signals:
    void documentChanged();
    void lastErrorChanged();

private:
    void setLastError(const QString &error);
    void publish();

    QStringList m_errors;
    screenshot::CaptureHistory m_history;
    screenshot::Document m_document;
    mutable QMutex m_imageLock;
    QImage m_image;
    int m_revision = 0;
    QString m_lastError;
};

// image://screenshot/<revision>: the document's original picture at its own size (the Image's sourceSize decides what is
// decoded by the scene graph; the picture itself is already in memory).
class ScreenshotImageProvider : public QQuickImageProvider
{
public:
    explicit ScreenshotImageProvider(ScreenshotApp *app);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    ScreenshotApp *m_app;
};
