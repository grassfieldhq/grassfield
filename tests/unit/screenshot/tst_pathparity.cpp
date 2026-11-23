// The Screenshot app's local-path rules are Preview's (docs/specs/capture-suite.md B1: "as Preview's"): both functions run over the
// same cases and must answer alike, so that a change to one without the other fails here.
#include "previewlogic.h"
#include "screenshotlogic.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

TEST(PathParity, SameAnswersAsPreview)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QFile f(dir.path() + "/exists.png");
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.close();
    const QString d = dir.path();
    const QStringList cases{"",
                            "   ",
                            "a.png",
                            "../up/a.png",
                            "./sub/../a.png",
                            "exists.png",
                            "/abs/path/x.png",
                            "/abs//double/./dots/../x.png",
                            "file:///abs/x.png",
                            "file://localhost/abs/x.png",
                            "file://remote/abs/x.png",
                            "file:///abs/x.png?q=1",
                            "file:///abs/x.png#f",
                            "file:///",
                            "file://",
                            "FILE:///abs/x.png",
                            "http://example.org/a.png",
                            "https://example.org/a.png",
                            "ftp://h/a.png",
                            "smb://h/s/a.png",
                            "data:image/png;base64,AAAA",
                            "c:foo.png",
                            "x:y",
                            "file:///a%20b/c.png",
                            "file:///bad%zz.png",
                            "exists.png:stream",
                            d + "/exists.png"};
    for (const QString &arg : cases) {
        for (const QString &cwd : {QStringLiteral("/"), d}) {
            QString previewError;
            QString ownError;
            const QString expected = preview::localPathFromArgument(arg, cwd, &previewError);
            const QString got = screenshot::localPathFromArgument(arg, cwd, &ownError);
            EXPECT_EQ(got, expected) << "arg=" << arg.toStdString() << " cwd=" << cwd.toStdString();
            EXPECT_EQ(ownError, previewError) << "arg=" << arg.toStdString();
        }
    }
    for (const char *p : {"/proc", "/proc/self", "/sys/x", "/dev/null", "/devices", "/proc2", "/", ""})
        EXPECT_EQ(screenshot::isSystemPath(QString::fromLatin1(p)), preview::isSystemPath(QString::fromLatin1(p))) << p;
    for (const QSize s : {QSize(1, 1), QSize(16384, 4096), QSize(16385, 1), QSize(16384, 16384), QSize(0, 4), QSize()})
        EXPECT_EQ(screenshot::imageSizeAllowed(s), preview::imageSizeAllowed(s)) << s.width() << "x" << s.height();
}
