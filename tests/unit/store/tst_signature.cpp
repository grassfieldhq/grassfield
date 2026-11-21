// The catalog's signature (ADR-0037 g, as ADR-0033 d.8): VALIDSIG's argument 10 in grassfield-trusted and not in
// grassfield-revoked; and pacman's rule for Arch's AppStream package (c, SD4, S19). Here gpgv and gpg are fakes or recorded
// status lines; tests/integration/store_catalog.sh runs the real ones against throwaway keys in a throwaway container
// (RealGpgv and RealPacmanKeyring below, given STORE_TEST_REAL_GPGV and STORE_TEST_PACMAN_KEYRINGS).
#include "signature.h"
#include "storetest.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

const QString kGood = QStringLiteral("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
const QString kOld = QStringLiteral("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
const QString kRogue = QStringLiteral("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC");
const QString kSub = QStringLiteral("DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD");

QByteArray validsig(const QString &primary)
{
    // Argument 1 is the signing (sub)key, argument 10 the primary key.
    return QStringLiteral("[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG 1234 Test\n[GNUPG:] VALIDSIG %1 2026-10-27 1793095200 0 4 0 22 10 00 %2\n")
        .arg(kSub, primary)
        .toLatin1();
}

struct Keyring {
    QTemporaryDir dir;
    Keyring(const QByteArray &trusted, const QByteArray &revoked, const QByteArray &keys = "not empty")
    {
        storetest::writeFile(dir.filePath(QStringLiteral("grassfield.gpg")), keys);
        storetest::writeFile(dir.filePath(QStringLiteral("grassfield-trusted")), trusted);
        storetest::writeFile(dir.filePath(QStringLiteral("grassfield-revoked")), revoked);
    }
};

} // namespace

TEST(Signature, Fingerprints)
{
    EXPECT_EQ(readFingerprints(("# comment\n" + kGood + ":4:\n" + kOld + ":4: \n\n").toLatin1()), (QSet<QString>{kGood, kOld}));
    EXPECT_EQ(readFingerprints((kOld + "\r\n").toLatin1()), QSet<QString>{kOld});
    EXPECT_EQ(readFingerprints(QByteArray()), QSet<QString>{});
    // Hand-written lists: a lower-case or space-padded entry still counts, so a revoked key never slips through.
    EXPECT_EQ(readFingerprints(("  " + kRogue.toLower() + "  :4:\n" + kOld.toLower() + " \n").toLatin1()), (QSet<QString>{kRogue, kOld}));
    const QSet<QString> trusted{kGood, kOld};
    EXPECT_EQ(judge(0, validsig(kOld), trusted, *readFingerprints((kOld.toLower() + "  \n").toLatin1())).verdict, SignatureVerdict::Revoked);
    EXPECT_EQ(validSigner(validsig(kGood.toLower())), kGood);
    // Any other line refuses the whole list (the same rule as tools/catalog.py): a grouped fingerprint, a 0x prefix, a
    // trailing comment, 39 digits, a word, a field after pacman's, an indented comment.
    QString grouped;
    for (int i = 0; i < 40; i += 4)
        grouped += kOld.mid(i, 4) + (i < 36 ? QStringLiteral(" ") : QString());
    for (const QString &line : {grouped, QString(QStringLiteral("0x") + kOld), QString(kOld + QStringLiteral(" # the old key")),
                                kOld.left(39), QStringLiteral("not-a-key:4:"), QString(kOld + QStringLiteral(":4:x")),
                                QStringLiteral("  # indented")})
        EXPECT_FALSE(readFingerprints((kGood + "\n" + line + "\n").toLatin1())) << line.toStdString();
}

TEST(Signature, ValidSignerIsArgumentTen)
{
    EXPECT_EQ(validSigner(validsig(kGood)), kGood);
    EXPECT_EQ(validSigner("[GNUPG:] GOODSIG 1234 Test\n"), QString());
    EXPECT_EQ(validSigner("[GNUPG:] VALIDSIG " + kGood.toLatin1() + " 2026-10-27\n"), QString()); // too short
    // Two signatures by two keys: neither is taken.
    EXPECT_EQ(validSigner(validsig(kGood) + validsig(kRogue)), QString());
    EXPECT_EQ(validSigner(validsig(kGood) + validsig(kGood)), kGood);
}

TEST(Signature, Judge)
{
    const QSet<QString> trusted{kGood, kOld}, revoked{kOld};
    EXPECT_EQ(judge(0, validsig(kGood), trusted, revoked).verdict, SignatureVerdict::Good);
    EXPECT_EQ(judge(0, validsig(kOld), trusted, revoked).verdict, SignatureVerdict::Revoked);
    EXPECT_EQ(judge(0, validsig(kRogue), trusted, revoked).verdict, SignatureVerdict::Untrusted);
    EXPECT_EQ(judge(1, validsig(kGood), trusted, revoked).verdict, SignatureVerdict::Bad); // gpgv's exit wins
    EXPECT_EQ(judge(0, "", trusted, revoked).verdict, SignatureVerdict::Bad);
    EXPECT_EQ(judge(0, validsig(kGood), {}, revoked).verdict, SignatureVerdict::NoTrustedKey);
    // A signed message given as the .sig (not a detached signature): refused whatever else gpgv says.
    EXPECT_EQ(judge(0, "[GNUPG:] PLAINTEXT 62 0 \n" + validsig(kGood), trusted, revoked).verdict, SignatureVerdict::Bad);
    // gpgv exits 0 and prints VALIDSIG for an expired or revoked key's signature: its own status line refuses it.
    for (const char *bad : {"EXPKEYSIG 1 X", "EXPSIG 1 X", "REVKEYSIG 1 X", "KEYREVOKED", "BADSIG 1 X", "ERRSIG 1 22 10 00 1 9"}) {
        EXPECT_EQ(judge(0, QByteArray("[GNUPG:] ") + bad + "\n" + validsig(kGood), trusted, revoked).verdict, SignatureVerdict::Bad) << bad;
        EXPECT_EQ(judge(0, validsig(kGood) + "[GNUPG:] " + bad + "\n", trusted, revoked).verdict, SignatureVerdict::Bad) << bad;
    }
    // KEYEXPIRED alone (an old subkey of the keyring) refuses nothing.
    EXPECT_EQ(judge(0, "[GNUPG:] KEYEXPIRED 1700000000\n" + validsig(kGood), trusted, revoked).verdict, SignatureVerdict::Good);
}

TEST(Signature, PacmansRule)
{
    // A good signature by a key pacman's keyring trusts fully or ultimately, and nothing else (S19).
    const QByteArray good = validsig(kGood) + "[GNUPG:] TRUST_FULLY 0 pgp\n";
    EXPECT_EQ(pacmanTrustedSigner(0, good), kGood);
    EXPECT_EQ(pacmanTrustedSigner(0, validsig(kGood) + "[GNUPG:] TRUST_ULTIMATE 0 pgp\n"), kGood);
    for (const char *trust : {"TRUST_UNDEFINED", "TRUST_NEVER", "TRUST_MARGINAL"})
        EXPECT_EQ(pacmanTrustedSigner(0, validsig(kGood) + "[GNUPG:] " + trust + " 0 pgp\n"), QString()) << trust;
    EXPECT_EQ(pacmanTrustedSigner(0, validsig(kGood)), QString());                    // no trust line at all
    EXPECT_EQ(pacmanTrustedSigner(1, good), QString());                               // gpg's exit wins
    EXPECT_EQ(pacmanTrustedSigner(0, good + validsig(kOld) + "[GNUPG:] TRUST_FULLY 0 pgp\n"), QString()); // two signatures
    for (const char *bad : {"PLAINTEXT 62 0", "BADSIG 1 X", "ERRSIG 1 22 10 00 1 9", "EXPSIG 1 X", "EXPKEYSIG 1 X", "REVKEYSIG 1 X",
                            "NO_PUBKEY 1"})
        EXPECT_EQ(pacmanTrustedSigner(0, QByteArray("[GNUPG:] ") + bad + "\n" + good), QString()) << bad;
    EXPECT_EQ(pacmanTrustedSigner(0, "[GNUPG:] VALIDSIG " + kGood.toLatin1() + " 2026-10-27\n[GNUPG:] TRUST_FULLY 0 pgp\n"), QString());

    // The key listing: that one key, valid, not disabled (gpg still says TRUST_FULLY for a disabled key, S19).
    const QByteArray fpr = "fpr:::::::::" + kGood.toLatin1() + ":\n";
    EXPECT_TRUE(pacmanKeyUsable("pub:f:255:22:1:1:::-:::scSC::::::23::0:\n" + fpr, kGood));
    EXPECT_TRUE(pacmanKeyUsable("pub:u:255:22:1:1:::-:::scSC::::::23::0:\n" + fpr, kGood));
    EXPECT_FALSE(pacmanKeyUsable("pub:f:255:22:1:1:::-:::scSCD::::::23::0:\n" + fpr, kGood)); // disabled
    EXPECT_FALSE(pacmanKeyUsable("pub:-:255:22:1:1:::-:::scSC::::::23::0:\n" + fpr, kGood));  // not valid
    EXPECT_FALSE(pacmanKeyUsable("pub:f:255:22:1:1:::-:::scSC::::::23::0:\n" + fpr, kOld));   // another key
    EXPECT_FALSE(pacmanKeyUsable("pub:f:255:22:1:1:::-:::scSC::::::23::0:\n" + fpr + "pub:f:255:22:1:1:::-:::scSC::::::23::0:\n" + fpr, kGood));
    EXPECT_FALSE(pacmanKeyUsable("", kGood));
}

TEST(Signature, RunsGpgvWithItsOwnEmptyHomeAndTheKeyringFolder)
{
    Keyring keyring((kGood + ":4:\n").toLatin1(), "");
    QTemporaryDir bin;
    // The fake records its arguments and GNUPGHOME, then answers like a good gpgv.
    const QString args = bin.filePath(QStringLiteral("args"));
    const QString gpgv = storetest::script(bin.filePath(QStringLiteral("gpgv")),
                                           "printf '%s\\n' \"$@\" > '" + args.toLatin1() + "'; echo \"GNUPGHOME=$GNUPGHOME LC_ALL=$LC_ALL\" >> '" + args.toLatin1()
                                               + "'\nprintf '" + validsig(kGood).replace("\n", "\\n") + "'");
    storetest::writeFile(bin.filePath(QStringLiteral("file")), "data");
    storetest::writeFile(bin.filePath(QStringLiteral("file.sig")), "sig");
    const SignatureCheck c = verifySignature(gpgv, keyring.dir.path(), bin.filePath(QStringLiteral("file")), bin.filePath(QStringLiteral("file.sig")));
    EXPECT_EQ(c.verdict, SignatureVerdict::Good);
    EXPECT_EQ(c.signer, kGood);
    QFile f(args);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QStringList lines = QString::fromUtf8(f.readAll()).split(u'\n');
    ASSERT_GE(lines.size(), 9);
    EXPECT_EQ(lines.at(0), QStringLiteral("--homedir"));
    EXPECT_TRUE(lines.at(1).startsWith(QDir::tempPath())) << lines.at(1).toStdString();
    EXPECT_NE(lines.at(1), QDir::homePath() + QStringLiteral("/.gnupg"));
    EXPECT_EQ(lines.at(2), QStringLiteral("--keyring"));
    EXPECT_EQ(lines.at(3), keyring.dir.filePath(QStringLiteral("grassfield.gpg")));
    EXPECT_EQ(lines.mid(4, 2), (QStringList{QStringLiteral("--status-fd"), QStringLiteral("1")}));
    EXPECT_EQ(lines.at(6), bin.filePath(QStringLiteral("file.sig")));
    EXPECT_EQ(lines.at(7), bin.filePath(QStringLiteral("file")));
    EXPECT_EQ(lines.at(8), QStringLiteral("GNUPGHOME=%1 LC_ALL=C").arg(lines.at(1)));
}

TEST(Signature, NoKeyMeansNoCatalog)
{
    QTemporaryDir bin;
    const QString gpgv = storetest::script(bin.filePath(QStringLiteral("gpgv")), "printf '" + validsig(kGood).replace("\n", "\\n") + "'");
    // The keyless grassfield-keyring of ADR-0033 O20: an empty keyring and an empty trusted list.
    Keyring empty("", "", "");
    EXPECT_EQ(verifySignature(gpgv, empty.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    Keyring keysButNoTrust("", "", "keys");
    EXPECT_EQ(verifySignature(gpgv, keysButNoTrust.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    EXPECT_EQ(verifySignature(gpgv, QStringLiteral("/nonexistent"), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    // A revoked list written another way: nothing is trusted, so the revoked key it meant never slips through.
    Keyring badRevoked((kGood + ":4:\n").toLatin1(), ("0x" + kGood + "\n").toLatin1());
    EXPECT_EQ(verifySignature(gpgv, badRevoked.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    Keyring badTrusted((kGood + ":4: # ours\n").toLatin1(), "");
    EXPECT_EQ(verifySignature(gpgv, badTrusted.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    // A revoked list that is there but cannot be read (over 1 MiB, or not a file): refused, never taken as empty.
    Keyring bigRevoked((kGood + ":4:\n").toLatin1(), QByteArray(1024 * 1024 + 1, '#'));
    EXPECT_EQ(verifySignature(gpgv, bigRevoked.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    Keyring dirRevoked((kGood + ":4:\n").toLatin1(), "");
    QFile::remove(dirRevoked.dir.filePath(QStringLiteral("grassfield-revoked")));
    QDir().mkdir(dirRevoked.dir.filePath(QStringLiteral("grassfield-revoked")));
    EXPECT_EQ(verifySignature(gpgv, dirRevoked.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::NoTrustedKey);
    // No revoked list at all is an empty one.
    Keyring noRevoked((kGood + ":4:\n").toLatin1(), "");
    QFile::remove(noRevoked.dir.filePath(QStringLiteral("grassfield-revoked")));
    EXPECT_EQ(verifySignature(gpgv, noRevoked.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::Good);
    // gpgv missing or hanging: Bad, never Good.
    Keyring keyring((kGood + ":4:\n").toLatin1(), "");
    EXPECT_EQ(verifySignature(QStringLiteral("/nonexistent/gpgv"), keyring.dir.path(), QStringLiteral("/dev/null"), QStringLiteral("/dev/null")).verdict, SignatureVerdict::Bad);
}

// The real gpgv, against throwaway keys made in the test container (tests/integration/store_catalog.sh). The folder holds
// grassfield.gpg, grassfield-trusted (the good key), grassfield-revoked (the revoked key), and catalog.json signed by
// each of: good.sig, revoked.sig, rogue.sig, plus changed.json (the catalog with one byte changed) under good.sig.
TEST(Signature, RealGpgv)
{
    const QString dir = qEnvironmentVariable("STORE_TEST_REAL_GPGV");
    if (dir.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    auto verify = [&](const char *file, const char *sig) {
        return verifySignature(QStringLiteral("/usr/bin/gpgv"), dir, dir + QLatin1Char('/') + QLatin1String(file), dir + QLatin1Char('/') + QLatin1String(sig)).verdict;
    };
    EXPECT_EQ(verify("catalog.json", "good.sig"), SignatureVerdict::Good);
    EXPECT_EQ(verify("catalog.json", "revoked.sig"), SignatureVerdict::Revoked);
    EXPECT_EQ(verify("catalog.json", "rogue.sig"), SignatureVerdict::Untrusted);
    EXPECT_EQ(verify("changed.json", "good.sig"), SignatureVerdict::Bad);
    EXPECT_EQ(verify("catalog.json", "catalog.json"), SignatureVerdict::Bad);
    // The catalog signed as a message of its own (gpg --sign, not --detach-sign) given as its .sig: refused.
    EXPECT_EQ(verify("catalog.json", "inline.sig"), SignatureVerdict::Bad);
}

// The real gpg against pacman's keyring as pacman-key leaves it (tests/integration/store_catalog.sh): a throwaway packager
// key added but not locally signed (untrusted/), locally signed (trusted/), then disabled (disabled/); pkg signed by it,
// changed (pkg with one byte more), inline.sig (pkg signed as a message of its own). pacman-key --verify exits 0 for the
// untrusted case (S19): only this check refuses it.
TEST(Signature, RealPacmanKeyring)
{
    const QString dir = qEnvironmentVariable("STORE_TEST_PACMAN_KEYRINGS");
    if (dir.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    auto verify = [&](const char *keyring, const char *file, const char *sig) {
        QString why;
        return verifyPacmanSignature(QStringLiteral("/usr/bin/gpg"), dir + QLatin1Char('/') + QLatin1String(keyring),
                                     dir + QLatin1Char('/') + QLatin1String(file), dir + QLatin1Char('/') + QLatin1String(sig), &why);
    };
    const auto listing = [&] {
        return QDir(dir + QStringLiteral("/trusted")).entryList(QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot);
    };
    const QStringList before = listing();
    EXPECT_TRUE(verify("trusted", "pkg", "pkg.sig"));
    EXPECT_FALSE(verify("untrusted", "pkg", "pkg.sig"));
    EXPECT_FALSE(verify("disabled", "pkg", "pkg.sig"));
    EXPECT_FALSE(verify("trusted", "changed", "pkg.sig"));
    EXPECT_FALSE(verify("trusted", "pkg", "inline.sig"));
    EXPECT_FALSE(verify("missing", "pkg", "pkg.sig"));
    EXPECT_EQ(listing(), before); // the keyring folder is never written: gpg works on a private copy
}
