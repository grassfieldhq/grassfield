#include "signature.h"

#include "childprocess.h"

#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QTemporaryDir>

namespace grassfield::store {

namespace {

const QRegularExpression &fingerprintRe()
{
    static const QRegularExpression re(QStringLiteral(R"(\A[0-9A-F]{40}\z)"));
    return re;
}

QByteArray readSmall(const QString &path, bool *ok)
{
    QFile f(path);
    *ok = f.open(QIODevice::ReadOnly) && f.size() <= 1024 * 1024;
    return *ok ? f.readAll() : QByteArray();
}

} // namespace

std::optional<QSet<QString>> readFingerprints(const QByteArray &content)
{
    static const QRegularExpression tail(QStringLiteral(R"(\A(\d+:)?\s*\z)"));
    QSet<QString> out;
    for (const QByteArray &raw : content.split('\n')) {
        const QString line = QString::fromLatin1(raw);
        if (line.trimmed().isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        // Hand-written lists: a lower-case or space-padded entry still counts; anything else refuses the whole list.
        const qsizetype colon = line.indexOf(QLatin1Char(':'));
        const QString fpr = (colon < 0 ? line : line.left(colon)).trimmed().toUpper();
        if (!fingerprintRe().match(fpr).hasMatch() || !tail.match(colon < 0 ? QString() : line.mid(colon + 1)).hasMatch())
            return std::nullopt;
        out.insert(fpr);
    }
    return out;
}

QString validSigner(const QByteArray &status)
{
    QString signer;
    for (const QByteArray &raw : status.split('\n')) {
        const QList<QByteArray> f = raw.trimmed().split(' ');
        if (f.size() >= 12 && f.at(0) == "[GNUPG:]" && f.at(1) == "VALIDSIG") {
            const QString primary = QString::fromLatin1(f.at(11)).toUpper();
            if (!fingerprintRe().match(primary).hasMatch() || (!signer.isEmpty() && signer != primary))
                return {};
            signer = primary;
        }
    }
    return signer;
}

namespace {

bool hasStatus(const QByteArray &status, const QList<QByteArray> &keywords)
{
    for (const QByteArray &raw : status.split('\n')) {
        const QList<QByteArray> f = raw.trimmed().split(' ');
        if (f.size() >= 2 && f.at(0) == "[GNUPG:]" && keywords.contains(f.at(1)))
            return true;
    }
    return false;
}

} // namespace

SignatureCheck judge(int gpgvExit, const QByteArray &status, const QSet<QString> &trusted, const QSet<QString> &revoked)
{
    SignatureCheck check;
    if (trusted.isEmpty()) {
        check.verdict = SignatureVerdict::NoTrustedKey;
        return check;
    }
    check.signer = validSigner(status);
    // gpgv judges no validity: for a signature by an expired or revoked key it still prints VALIDSIG and exits 0, so
    // these lines refuse by themselves (the same list as grassfield-update-check's verify).
    if (gpgvExit != 0 || check.signer.isEmpty()
        || hasStatus(status, {"PLAINTEXT", "EXPKEYSIG", "EXPSIG", "REVKEYSIG", "KEYREVOKED", "BADSIG", "ERRSIG"}))
        check.verdict = SignatureVerdict::Bad;
    else if (revoked.contains(check.signer))
        check.verdict = SignatureVerdict::Revoked;
    else if (!trusted.contains(check.signer))
        check.verdict = SignatureVerdict::Untrusted;
    else
        check.verdict = SignatureVerdict::Good;
    return check;
}

SignatureCheck verifySignature(const QString &gpgv, const QString &keyringDir, const QString &file, const QString &sig)
{
    bool okTrusted = false, okRevoked = false;
    const QString revokedPath = keyringDir + QStringLiteral("/grassfield-revoked");
    const auto trusted = readFingerprints(readSmall(keyringDir + QStringLiteral("/grassfield-trusted"), &okTrusted));
    const auto revoked = readFingerprints(readSmall(revokedPath, &okRevoked));
    const QString keyring = keyringDir + QStringLiteral("/grassfield.gpg");
    // No revoked list is an empty one; a revoked list that is there but cannot be read whole refuses everything.
    if (!okTrusted || !trusted || trusted->isEmpty() || !revoked || (!okRevoked && QFileInfo::exists(revokedPath))
        || QFileInfo(keyring).size() == 0) {
        SignatureCheck none;
        none.verdict = SignatureVerdict::NoTrustedKey;
        return none;
    }
    // An empty home of its own: gpgv reads nothing of the user's ~/.gnupg.
    QTemporaryDir home;
    if (!home.isValid())
        return {};
    ChildOptions options;
    options.maxOut = 64 * 1024;
    options.extraEnv.insert(QStringLiteral("GNUPGHOME"), home.path());
    const ChildResult r = runChild(gpgv, {QStringLiteral("--homedir"), home.path(), QStringLiteral("--keyring"), keyring,
                                          QStringLiteral("--status-fd"), QStringLiteral("1"), sig, file},
                                   options);
    if (!r.started || r.timedOut || r.overflow)
        return {};
    return judge(r.exitCode, r.out, *trusted, *revoked);
}

QString pacmanTrustedSigner(int gpgExit, const QByteArray &status)
{
    if (gpgExit != 0 || hasStatus(status, {"PLAINTEXT", "BADSIG", "ERRSIG", "EXPSIG", "EXPKEYSIG", "REVKEYSIG", "NO_PUBKEY"}))
        return {};
    int validsigs = 0;
    bool trusted = false;
    QString signer;
    for (const QByteArray &raw : status.split('\n')) {
        const QList<QByteArray> f = raw.trimmed().split(' ');
        if (f.size() < 2 || f.at(0) != "[GNUPG:]")
            continue;
        if (f.at(1) == "VALIDSIG") {
            ++validsigs;
            signer = f.size() >= 12 ? QString::fromLatin1(f.at(11)).toUpper() : QString();
        } else if (f.at(1) == "TRUST_FULLY" || f.at(1) == "TRUST_ULTIMATE") {
            trusted = true;
        } else if (f.at(1).startsWith("TRUST_")) {
            return {}; // TRUST_UNDEFINED, TRUST_NEVER, TRUST_MARGINAL: pacman refuses those
        }
    }
    if (validsigs != 1 || !trusted || !fingerprintRe().match(signer).hasMatch())
        return {};
    return signer;
}

bool pacmanKeyUsable(const QByteArray &colons, const QString &fingerprint)
{
    int keys = 0;
    bool usable = false, thatKey = false, expectFpr = false;
    for (const QByteArray &raw : colons.split('\n')) {
        const QList<QByteArray> f = raw.trimmed().split(':');
        if (f.at(0) == "pub") {
            ++keys;
            // Field 2: validity (f full, u ultimate); field 12: capabilities, D when the key is disabled.
            usable = f.size() >= 12 && (f.at(1) == "f" || f.at(1) == "u") && !f.at(11).contains('D');
            expectFpr = true;
        } else if (f.at(0) == "fpr" && expectFpr) {
            thatKey = f.size() >= 10 && QString::fromLatin1(f.at(9)).toUpper() == fingerprint;
            expectFpr = false;
        }
    }
    return keys == 1 && usable && thatKey;
}

bool verifyPacmanSignature(const QString &gpg, const QString &pacmanGnupg, const QString &file, const QString &sig,
                           QString *why)
{
    // A private copy: gpg writes its trust database and lock files, never in /etc.
    QTemporaryDir home;
    if (!home.isValid()) {
        *why = QStringLiteral("no private folder for gpg");
        return false;
    }
    bool keyring = false;
    for (const char *name : {"pubring.gpg", "pubring.kbx", "trustdb.gpg"}) {
        const QString from = pacmanGnupg + QLatin1Char('/') + QLatin1String(name);
        if (!QFileInfo::exists(from))
            continue;
        if (QFileInfo(from).size() > 64 * 1024 * 1024 || !QFile::copy(from, home.filePath(QLatin1String(name)))) {
            *why = QStringLiteral("pacman's keyring cannot be read");
            return false;
        }
        keyring = keyring || QLatin1String(name) != QLatin1String("trustdb.gpg");
    }
    if (!keyring || !QFileInfo::exists(home.filePath(QStringLiteral("trustdb.gpg")))) {
        *why = QStringLiteral("pacman's keyring cannot be read");
        return false;
    }
    ChildOptions options;
    options.timeoutMs = 60000;
    options.maxOut = 256 * 1024;
    options.extraEnv.insert(QStringLiteral("GNUPGHOME"), home.path());
    const QStringList common{QStringLiteral("--homedir"), home.path(), QStringLiteral("--batch"), QStringLiteral("--no-tty"),
                             QStringLiteral("--no-autostart"), QStringLiteral("--no-auto-key-retrieve")};
    const ChildResult verified = runChild(gpg, common + QStringList{QStringLiteral("--status-fd"), QStringLiteral("1"),
                                                                    QStringLiteral("--verify"), sig, file},
                                          options);
    const QString signer = verified.started && !verified.timedOut && !verified.overflow
        ? pacmanTrustedSigner(verified.exitCode, verified.out)
        : QString();
    if (signer.isEmpty()) {
        *why = QStringLiteral("not one good signature by a key pacman trusts fully");
        return false;
    }
    const ChildResult listed = runChild(gpg, common + QStringList{QStringLiteral("--with-colons"), QStringLiteral("--fixed-list-mode"),
                                                                  QStringLiteral("--list-keys"), QStringLiteral("--"), signer},
                                        options);
    if (!listed.ok() || !pacmanKeyUsable(listed.out, signer)) {
        *why = QStringLiteral("the signer's key is disabled or not valid in pacman's keyring");
        return false;
    }
    return true;
}

} // namespace grassfield::store
