#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QMutex>
#include <QObject>
#include <QQuickImageProvider>
#include <QQuickTextDocument>
#include <QSet>
#include <QStringList>
#include <QThread>
#include <QThreadPool>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>

#include <atomic>

class QProcess;

#include "previewlogic.h"
#include "shortcutstyle.h"

// Backend of Grassfield Preview: the validated file list, per-file inspection (kind, caps, text)
// and appearance. Files are only ever read, never written.
class PreviewApp : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool glance READ glance CONSTANT)
    // The list is the folder of the one file that was opened (browsing with the arrow keys), not what the command line named.
    Q_PROPERTY(bool browsing READ browsing CONSTANT)
    // Index in `files` of the file that was opened.
    Q_PROPERTY(int startIndex READ startIndex NOTIFY filesChanged)
    // Starts as the opened file alone; the folder is listed in a worker thread and replaces it when done.
    Q_PROPERTY(QVariantList files READ files NOTIFY filesChanged)
    // The folder is still being listed (the arrows and "n of N" wait for it).
    Q_PROPERTY(bool listing READ listing NOTIFY listingChanged)
    Q_PROPERTY(QStringList errors READ errors CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    // accessibility.increaseContrast and accessibility.textSize (1 to 1.3) of grassfield.json, as every app reads them.
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    // windows.titlebarDoubleClick of grassfield.json: zoom (default), minimize or none (the toolbar's double-click).
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    // False when the shell says the compositor plugin is absent: the minimize light is greyed (ADR-0015 Q4b, chromecaps.h).
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    // accent.color: multicolor (the Grassfield green), blue, purple, pink, red, orange, yellow, green or graphite.
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    // keyboard.shortcutStyle resolved for this device: "mac" (macOS symbols in menus) or "pc" (text), shortcutstyle.h.
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)
    // preview.textInImages of grassfield.json (default true): Select Text in Images (ADR-0045 OC-2), off when it is false.
    Q_PROPERTY(bool textInImages READ textInImages NOTIFY appearanceChanged)
    // The computer runs on its battery (no power adapter online): Select Text in Images waits longer before it reads an
    // image (ImageText.qml), as tesseract keeps a core busy for seconds. Read again at each recognition.
    Q_PROPERTY(bool onBattery READ onBattery NOTIFY powerChanged)
    // Counts the sidebar snippets read so far (snippetFor): a binding that reads it reads its snippet again.
    Q_PROPERTY(int snippetRevision READ snippetRevision NOTIFY snippetsChanged)

public:
    PreviewApp(const QStringList &paths, const QStringList &errors, bool glance, int startIndex = 0, bool browsing = false, QObject *parent = nullptr);
    ~PreviewApp() override;

    bool listing() const { return m_listing; }
    // List the folder of the only file in a worker thread (GUI thread never blocks); the list replaces the file when ready.
    void startBrowse(preview::BrowseKinds kinds);
    // Stop a running listing (window closing).
    void cancelBrowse();

    bool glance() const { return m_glance; }
    bool browsing() const { return m_browsing; }
    int startIndex() const { return m_startIndex; }
    // [{path, name, url, kind}]
    QVariantList files() const { return m_files; }
    QStringList errors() const { return m_errors; }
    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString shortcutStyle() const { return m_shortcutStyle; }
    bool textInImages() const { return m_textInImages; }
    bool onBattery() const { return m_onBattery; }
    int snippetRevision() const { return m_snippets.size(); }

    // Path of file `index` for the image provider (render thread): empty when out of range.
    QString pathAt(int index) const;
    // A number that stands for this path as long as the app runs (the image provider's URLs carry it: the folder listing
    // changes a file's index, never its token), and the path it stands for. Thread-safe, as pathAt().
    int tokenFor(const QString &path) const;
    QString pathForToken(int token) const;

    // {ok, error, kind, name, url, size(Text), width, height, frames, animated, text, chunks, type, modified, folder}
    // `chunks`: a long text in pieces of whole lines (TextView lays out only the pieces on screen, P7).
    // Synchronous (the tests; Glance's first file before its window is sized).
    Q_INVOKABLE QVariantMap inspect(int index) const;
    // The same on a worker thread (P4 of the 2026-11 audit: content sniffing, an image's size, a whole SVG parsed or a HEIC
    // decoded for it, 2 MiB of text, a slow mount: never on the window's thread any more). Returns its number; the answer
    // comes as inspected(). A request made while an older one waits makes the older one start nothing.
    Q_INVOKABLE int requestInspect(int index);
    // The first lines of a text file for its sidebar thumbnail (at most 12 lines of 40 characters, control characters
    // replaced); "" for any other kind, an unreadable file or an empty one. Synchronous (tests).
    Q_INVOKABLE QString textSnippet(int index) const;
    // The snippet of file `index` read on a worker thread, kept by token: "" until it is in (snippetsChanged() then; the
    // sidebar's delegates read it again). Never reads on the window's thread.
    Q_INVOKABLE QString snippetFor(int index);
    // What the Glance needs to size its window for the file that was opened first (stays that file when the folder list
    // replaces the files): {ok, kind}, and a picture's width and height (its header only). Synchronous, as the window is sized
    // before it maps, so it never reads a text, never renders Markdown and never probes a document's pictures: the content's
    // full inspection runs on the worker (requestInspect, Content.qml; review 2026-11-22).
    Q_INVOKABLE QVariantMap inspectFirst() const;
    // Fits the pictures of a rendered Markdown document in `document` (TextEdit.textDocument) to `maxWidth`, changing only
    // their formats (preview::fitMarkdownImages): a resize never parses the text again and keeps the selection.
    Q_INVOKABLE int fitMarkdownImages(QQuickTextDocument *document, qreal maxWidth) const;
    // Start the full viewer (Glance "Open with Preview"); detached. When the list is the folder of one file (browsing)
    // only file `current` is passed (the viewer browses its folder again); otherwise every file, the viewer starting at
    // `current`.
    Q_INVOKABLE void openInPreview(int current = 0) const;

    // Select Text in Images (ADR-0045 OC-2, docs/specs/preview.md P13). Starts one recognition in the background
    // (preview::recognitionCommand: "languages", "text" with tesseract's -l value, or "qr") and returns its number; the
    // answer comes as recognized(). For "text" and "qr", file `index` (an image of the list) is decoded in a worker thread
    // and handed to the tool on its standard input. 0, and no answer, when nothing starts: the tool is not installed (one
    // journal line per tool and process, nothing on screen), the tool or the languages are refused, or the file is not a
    // regular image file of the list.
    Q_INVOKABLE int recognize(const QString &tool, int index, const QString &languages = QString());
    // Stops recognition `request` (another image is shown, the setting went off): no answer comes for it.
    Q_INVOKABLE void cancelRecognition(int request);
    // Puts `text` on the clipboard. `concealed` adds the password-manager hint (x-kde-passwordManagerHint "secret", what
    // Omarchy's `wl-copy --sensitive` sets): a QR code may hold a one-time-password secret, which the clipboard history
    // (ADR-0034) then never records.
    Q_INVOKABLE void copyText(const QString &text, bool concealed) const;
    // Opens a QR code's link in the user's browser: `xdg-open <link>` (scoped in a real session) for a link that passes
    // preview::isOpenableLink, never from a dev session (ADR-0019). Returns whether it started.
    Q_INVOKABLE bool openLink(const QString &link) const;

    // Tests: how many recognition pictures were decoded (one per image for both tools, P5).
    int recognitionDecodes() const { return m_recognitionDecodes; }

signals:
    void appearanceChanged();
    void filesChanged();
    void listingChanged();
    // The answer of recognition `request` of `tool`: the tool's exit code (-1 when it could not start, crashed, ran past
    // preview::kRecognitionTimeoutMs, wrote more than preview::kRecognitionOutputMax, or the image could not be decoded)
    // and its standard output as UTF-8.
    void recognized(int request, const QString &tool, int exitCode, const QString &output);
    void inspected(int request, const QVariantMap &info);
    void snippetsChanged();
    void powerChanged();

private:
    QVariantMap inspectPath(const QString &path) const;
    void readAppearance();
    void applyBrowse(const preview::Browse &browse, const QVariantList &files);
    void startTool(int request, const QString &tool, const preview::Recognition &command, const QByteArray &image);
    void decoded(const QString &path, const QByteArray &image);
    void readPower();

    mutable QMutex m_lock; // guards m_paths (written on the GUI thread, read by the image provider) and the tokens
    QStringList m_paths;
    mutable QHash<QString, int> m_tokens;
    mutable QStringList m_tokenPaths;
    QStringList m_errors;
    QVariantList m_files;
    bool m_glance = false;
    bool m_browsing = false;
    int m_startIndex = 0;
    QString m_firstPath;
    bool m_listing = false;
    std::atomic_bool m_cancel{false};
    QThread *m_worker = nullptr;
    bool m_dark = true;
    bool m_autoAppearance = false;
    QTimer m_autoTimer;
    bool m_reduceMotion = false;
    bool m_increaseContrast = false;
    qreal m_textScale = 1;
    QString m_titlebarDoubleClick = QStringLiteral("zoom");
    bool m_canMinimize = true;
    QString m_accentColor = QStringLiteral("multicolor");
    QString m_accentHighlight = QStringLiteral("automatic");
    const bool m_macDevice = grassfield::apps::macDeviceHere();
    QString m_shortcutStyle = QStringLiteral("pc");
    bool m_textInImages = true;
    QFileSystemWatcher m_watcher;
    // Recognitions: the last number given, those whose image a worker is decoding, the tools running, the decoders still
    // alive (joined when the backend goes), and the tools found missing (logged once).
    int m_lastRequest = 0;
    QSet<int> m_decoding;
    QHash<int, QProcess *> m_tools;
    QList<QThread *> m_decoders;
    QSet<QString> m_missingTools;
    // One decode per image for its recognitions (P5): the requests waiting for the picture of each path, and the pictures
    // decoded, kept for the image shown (the last few).
    struct Waiting {
        int request;
        QString tool;
        preview::Recognition command;
    };
    QHash<QString, QList<Waiting>> m_waiting;
    QList<QPair<QString, QByteArray>> m_decodedImages;
    bool m_onBattery = false;
    int m_recognitionDecodes = 0;
    // Inspections and snippets: one worker each (one at a time: the newest inspection is the one that counts), the last
    // inspection asked, the snippets read and those on their way (by token).
    QThreadPool m_inspectPool;
    QThreadPool m_snippetPool;
    std::atomic_int m_lastInspect{0};
    QHash<int, QString> m_snippets;
    QSet<int> m_snippetsAsked;
};

// image://preview/<frame>/<file token>: decoded with the allocation and size caps, EXIF rotation applied.
// image://preview/thumb/<file token>: the same at the requested (source) size, for the sidebar thumbnails.
// The token is PreviewApp::tokenFor(path) (the "token" of inspect() and of each entry of files).
class PreviewImageProvider : public QQuickImageProvider
{
public:
    explicit PreviewImageProvider(const PreviewApp *app);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    const PreviewApp *m_app;
};
