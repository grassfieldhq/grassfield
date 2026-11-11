// grassfield-prompter without a bus (bridges/prompter/src, ADR-0035 D-9): the caller's text made plain, the prompter/1 line
// parser and messages, the bound of outstanding requests, the shell's cgroup, the socket peer check, who is trusted as a
// requester (temporary trees stand for the system's root-owned ones), the bus filter that tells a prompt its caller, and
// the GcrPrompt object itself (answers, withdrawals, the password wiped); step 9e: KIO's AuthInfo on the bus, the
// kpasswdserver session cache and its quirks, the server's name, the keyring's protection, the kio prompt; step 10: the BlueZ
// agent's argument checks, the device's name, the passkey's form, the bluetooth prompt and progress lines. The process on a
// private bus: tests/security/prompter_bridge.sh (KIO's: tests/security/kio_passwd.sh; BlueZ's: tests/security/bluez_agent.sh).
#include "Askpass.h"
#include "BtPairing.h"
#include "Filter.h"
#include "Identity.h"
#include "KioAuth.h"
#include "NmSecrets.h"
#include "Peer.h"
#include "Prompt.h"
#include "Protocol.h"
#include "Requests.h"
#include "Text.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <csignal>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <string>
#include <vector>
#include <sys/socket.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <gtest/gtest.h>

using namespace gf::prompter;

namespace {
    // The executable checks need a system where /usr/bin is root's (not so in a user namespace that does not map root).
    bool rootOwnsSystemFiles() {
        struct stat st{};
        return ::stat("/usr/bin/sleep", &st) == 0 && st.st_uid == 0 && ::stat("/usr/bin", &st) == 0 && st.st_uid == 0;
    }

#define BACKSLASH "\\"
    // A string of code points, so that the source stays ASCII (no invisible or directional character in it).
    QString ucs(std::initializer_list<char32_t> codePoints) {
        QString out;
        for (const char32_t c : codePoints)
            out.append(QString::fromUcs4(&c, 1));
        return out;
    }

    // A JSON escape of four hex digits (backslash, u, the digits).
    std::string jsonU(const char* hex) {
        return std::string(BACKSLASH "u") + hex;
    }

    void writeFile(const QString& path, const QByteArray& content, mode_t mode) {
        QFile f(path);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write(content);
        f.close();
        ASSERT_EQ(::chmod(QFile::encodeName(path).constData(), mode), 0);
    }

    ShellLine parsed(const std::string& line, ParseStatus expected) {
        ShellLine out;
        QString   error;
        EXPECT_EQ(parseShellLine(line, &out, &error), expected) << line << " -> " << error.toStdString();
        return out;
    }

    std::string decoded(std::string_view line, const JsonString& raw, std::size_t capacity = 4096) {
        std::string out(capacity, '\0');
        const long  n = decodeJsonString(line.data() + raw.begin, raw.end - raw.begin, out.data(), capacity);
        return n < 0 ? std::string("<invalid>") : out.substr(0, static_cast<std::size_t>(n));
    }

    void spin(int turns = 20) {
        for (int i = 0; i < turns; ++i)
            g_main_context_iteration(nullptr, FALSE);
    }

    QString ownCgroupLeaf() {
        QFile f(QStringLiteral("/proc/self/cgroup"));
        if (!f.open(QIODevice::ReadOnly))
            return {};
        const QString path = unifiedCgroupPath(f.readAll());
        const QStringList parts = path.split(u'/', Qt::SkipEmptyParts);
        return parts.isEmpty() ? QString() : parts.constLast();
    }

    int pidfdOpen(pid_t pid) {
        return static_cast<int>(::syscall(SYS_pidfd_open, pid, 0));
    }
} // namespace

// --- text ---------------------------------------------------------------------------------------------------------------

TEST(PrompterText, ControlsSeparatorsAndRunsOfSpaceBecomeOneSpace) {
    EXPECT_EQ(flatten(QStringLiteral("  Unlock\tthe\n\nkeyring\r\x01now  "), 100), QStringLiteral("Unlock the keyring now"));
    EXPECT_EQ(flatten(ucs({'a', 0x2028, 'b', 0x2029, 'c', 0x85, 'd', 0xA0, 'e'}), 100), QStringLiteral("a b c d e"));
    EXPECT_EQ(flatten(QStringLiteral("\x7f\u0090"), 100), QString());
}

TEST(PrompterText, InvisibleAndDirectionalCharactersAreRemoved) {
    // An override that would make "exe.txt" read "txt.exe", isolates, marks, zero-width characters, a BOM, tags.
    const QString tricky = QStringLiteral("Login") + ucs({0x202E}) + QStringLiteral("txt.exe")
                         + ucs({0x202C, ' ', 0x2066, 'x', 0x2069, 0x200B, 0x200E, 0x061C, 0xFEFF, 0x00AD, 0x034F, 0xE0041, 0xE007F, 'y'});
    EXPECT_EQ(flatten(tricky, 100), QStringLiteral("Logintxt.exe xy"));
    EXPECT_EQ(flatten(ucs({'a', 0xFFFE, 0xFDD0, 0x1FFFF, 'b'}), 100), QStringLiteral("ab"));
}

TEST(PrompterText, LoneSurrogatesBecomeReplacementCharacters) {
    QString lone = QStringLiteral("a");
    lone.append(QChar(0xD800)).append(u'b').append(QChar(0xDC00));
    EXPECT_EQ(flatten(lone, 100), ucs({'a', 0xFFFD, 'b', 0xFFFD}));
    // A real pair stays.
    EXPECT_EQ(flatten(QString::fromUcs4(U"key \U0001F511"), 100), QString::fromUcs4(U"key \U0001F511"));
}

TEST(PrompterText, LongTextIsCutWithAnEllipsisWithinTheCap) {
    const QString cut = flatten(QString(500, u'x'), 32);
    EXPECT_EQ(cut.size(), 32);
    EXPECT_TRUE(cut.endsWith(QChar(0x2026)));
    // Never between the halves of a pair, never a trailing space before the ellipsis.
    const QString pairs = flatten(QString::fromUcs4(U"\U0001F511\U0001F511\U0001F511\U0001F511"), 4);
    EXPECT_LE(pairs.size(), 4);
    EXPECT_FALSE(QChar::isHighSurrogate(pairs.at(pairs.size() - 2).unicode()));
    EXPECT_EQ(flatten(QStringLiteral("abc defgh"), 5), QStringLiteral("abc") + QChar(0x2026));
    EXPECT_EQ(flatten(QStringLiteral("exact"), 5), QStringLiteral("exact"));
    EXPECT_EQ(flatten(QStringLiteral("x"), 0), QString());
    // A huge input costs no more than the cap.
    EXPECT_EQ(flatten(QString(1 << 20, u'y'), caps::kDescription).size(), caps::kDescription);
}

TEST(PrompterText, Utf8InputIsDecodedAndNullIsEmpty) {
    EXPECT_EQ(flattenUtf8("caf\xc3\xa9\n", 10), ucs({'c', 'a', 'f', 0xE9}));
    EXPECT_EQ(flattenUtf8("bad \xff byte", 20), QStringLiteral("bad ") + QChar(0xFFFD) + QStringLiteral(" byte"));
    EXPECT_EQ(flattenUtf8(nullptr, 10), QString());
}

// --- prompter/1: parsing what the shell sends ----------------------------------------------------------------------------

TEST(PrompterProtocol, HelloIsParsed) {
    const ShellLine hello = parsed(R"({"v":"prompter/1","type":"hello","shell":"1.0.0-rc1","kinds":["password","confirm","password"]})", ParseStatus::Ok);
    EXPECT_EQ(hello.type, ShellLine::Type::Hello);
    EXPECT_EQ(hello.kinds, (QStringList{QStringLiteral("password"), QStringLiteral("confirm")}));
    EXPECT_EQ(hello.shell, QStringLiteral("1.0.0-rc1"));
    parsed(R"({"v":"prompter/2","type":"hello","kinds":[]})", ParseStatus::Version);
    parsed(R"({"type":"hello","kinds":[]})", ParseStatus::Malformed);
    parsed(R"({"v":"prompter/1","type":"hello"})", ParseStatus::Malformed);
    parsed(R"({"v":"prompter/1","type":"hello","kinds":[],"extra":true})", ParseStatus::Malformed);
}

TEST(PrompterProtocol, AnswerIsParsedAndThePasswordStaysRaw) {
    const std::string line = R"({"type":"answer","id":"p12","result":"ok","password":"s3cr\"t )" + jsonU("00e9") + jsonU("d83d") + jsonU("dd11")
                           + R"(","choice":true})";
    const ShellLine   a    = parsed(line, ParseStatus::Ok);
    EXPECT_EQ(a.type, ShellLine::Type::Answer);
    EXPECT_EQ(a.id, QStringLiteral("p12"));
    EXPECT_TRUE(a.ok);
    EXPECT_TRUE(a.hasPassword);
    EXPECT_TRUE(a.hasChoice);
    EXPECT_TRUE(a.choice);
    EXPECT_EQ(decoded(line, a.password), std::string("s3cr\"t \xc3\xa9\xf0\x9f\x94\x91"));
    const ShellLine cancel = parsed(R"({"type":"answer","id":"p1","result":"cancel"})", ParseStatus::Ok);
    EXPECT_FALSE(cancel.ok);
    EXPECT_FALSE(cancel.refused);
    EXPECT_FALSE(cancel.hasPassword);
    // The shell's refusal (its bound; opus review of step 9c): not ok, and not the user's cancellation.
    const ShellLine refused = parsed(R"({"type":"answer","id":"p1","result":"refused"})", ParseStatus::Ok);
    EXPECT_FALSE(refused.ok);
    EXPECT_TRUE(refused.refused);
    // An empty password is a password (gnome-keyring asks about storing unencrypted then).
    const ShellLine empty = parsed(R"({"type":"answer","id":"p2","result":"ok","password":""})", ParseStatus::Ok);
    EXPECT_TRUE(empty.hasPassword);
}

TEST(PrompterProtocol, AnswerWithoutAUsableIdCannotBeAttributed) {
    parsed(R"({"type":"answer","result":"ok","password":"x"})", ParseStatus::Malformed);
    parsed(R"({"type":"answer","id":"7","result":"ok"})", ParseStatus::Malformed);
    parsed(R"({"type":"answer","id":"p07","result":"ok"})", ParseStatus::Malformed);
    parsed(R"({"type":"answer","id":true,"result":"ok"})", ParseStatus::Malformed);
}

TEST(PrompterProtocol, WrongFieldsOfAnAttributableAnswerNameTheRequest) {
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"yes"})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"ok","password":true})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"ok","choice":"yes"})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"ok","remember":true})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    // A password over the limit is never cut: the request is cancelled.
    const std::string longPassword = R"({"type":"answer","id":"p3","result":"ok","password":")" + std::string(limits::kPassword + 1, 'a') + "\"}";
    EXPECT_EQ(parsed(longPassword, ParseStatus::Invalid).id, QStringLiteral("p3"));
    const std::string atLimit = R"({"type":"answer","id":"p3","result":"ok","password":")" + std::string(limits::kPassword, 'a') + "\"}";
    parsed(atLimit, ParseStatus::Ok);
}

TEST(PrompterProtocol, MalformedLinesAreRefused) {
    for (const std::string& line : {
             std::string(""),
             std::string("not json"),
             std::string(R"({"type":"answer")"),                          // unterminated
             std::string(R"({"type":"answer"} x)"),                       // trailing bytes
             std::string(R"([{"type":"answer"}])"),                       // not an object
             std::string(R"({"type":"answer","id":"p1","n":1})"),         // a number
             std::string(R"({"type":"answer","id":"p1","o":{}})"),        // nesting
             std::string(R"({"type":"answer","type":"hello"})"),          // duplicate key
             std::string("{\"type\":\"ans\twer\"}"),                       // raw control character
             std::string(R"({"type":"answer","id":"p1","password":"\ud800"})"),       // lone surrogate
             std::string(R"({"type":"answer","id":"p1","password":"\udc00\ud800"})"), // reversed pair
             std::string(R"({"type":"answer","id":"p1","password":"a\u0000b"})"),     // NUL
             std::string(R"({"type":"answer","id":"p1","password":"\x"})"),           // bad escape
             std::string("{\"type\":\"answer\",\"password\":\"\xc0\xaf\"}"),          // overlong UTF-8
             std::string("{\"type\":\"answer\",\"password\":\"\xed\xa0\x80\"}"),      // UTF-8 surrogate
             std::string("{\"type\":\"answer\",\"password\":\"\xf4\x90\x80\x80\"}"),  // above U+10FFFF
             std::string("{\"type\":\"answer\",\"password\":\"\xe2\x82\"}"),          // truncated sequence
             std::string(R"({"type":"answer","1key":"x"})"),              // invalid key
             std::string(R"({"kinds":["a",1]})"),                         // array of non-strings
             std::string(R"({"id":"p1"})"),                               // no type
         }) {
        ShellLine out;
        QString   error;
        EXPECT_EQ(parseShellLine(line, &out, &error), ParseStatus::Malformed) << line;
        EXPECT_FALSE(error.isEmpty());
    }
}

TEST(PrompterProtocol, OversizedLinesAndUnknownTypes) {
    std::string huge = R"({"type":"answer","id":"p1","result":"ok","password":")" + std::string(limits::kShellLine, 'a') + "\"}";
    ShellLine   out;
    QString     error;
    EXPECT_EQ(parseShellLine(huge, &out, &error), ParseStatus::Malformed);
    EXPECT_EQ(error, QStringLiteral("line too long"));
    parsed(R"({"type":"shown","id":"p1"})", ParseStatus::Unknown);
    // Arrays and members are bounded.
    std::string many = R"({"v":"prompter/1","type":"hello","kinds":[)";
    for (int i = 0; i < 17; ++i)
        many += (i ? ",\"k" : "\"k") + std::to_string(i) + "\"";
    many += "]}";
    parsed(many, ParseStatus::Malformed);
}

TEST(PrompterProtocol, DecodingRespectsTheCapacityAndCounts) {
    const std::string raw = std::string("abc") + BACKSLASH "n" + jsonU("00e9");
    char              small[4];
    EXPECT_EQ(decodeJsonString(raw.data(), raw.size(), small, sizeof small), -1);
    EXPECT_EQ(decodeJsonString(raw.data(), raw.size(), nullptr, 64), 6);
    char big[16] = {};
    EXPECT_EQ(decodeJsonString(raw.data(), raw.size(), big, sizeof big), 6);
    EXPECT_EQ(std::string(big, 6), std::string("abc\n\xc3\xa9"));
    const std::string quote = "a\"b";
    EXPECT_EQ(decodeJsonString(quote.data(), quote.size(), big, sizeof big), -1);
}

TEST(PrompterProtocol, RequestIds) {
    EXPECT_TRUE(validRequestId(QStringLiteral("p1")));
    EXPECT_TRUE(validRequestId(QStringLiteral("p1234567890123456789")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p0")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p-1")));
    EXPECT_FALSE(validRequestId(QStringLiteral("q1")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p12345678901234567890")));
}

// --- prompter/1: what the bridge sends ---------------------------------------------------------------------------------

TEST(PrompterProtocol, PromptMessageCarriesTheRequesterAndTheTexts) {
    PromptView p;
    p.id                   = QStringLiteral("p4");
    p.kind                 = QStringLiteral("password");
    p.requester.role       = QStringLiteral("gnupg");
    p.requester.path       = QStringLiteral("/usr/bin/pinentry-gnome3");
    p.requester.identified = true;
    p.requester.onBehalf   = true;
    p.title                = QStringLiteral("Unlock");
    p.passwordNew          = true;
    p.hasChoice            = true;
    p.choiceLabel          = QStringLiteral("Remember");
    const QByteArray line  = promptMessage(p);
    ASSERT_TRUE(line.endsWith('\n'));
    EXPECT_EQ(line.count('\n'), 1);
    const QJsonObject o = QJsonDocument::fromJson(line).object();
    EXPECT_EQ(o.value(QStringLiteral("type")).toString(), QStringLiteral("prompt"));
    EXPECT_EQ(o.value(QStringLiteral("id")).toString(), QStringLiteral("p4"));
    EXPECT_EQ(o.value(QStringLiteral("requester")).toObject().value(QStringLiteral("role")).toString(), QStringLiteral("gnupg"));
    EXPECT_TRUE(o.value(QStringLiteral("requester")).toObject().value(QStringLiteral("onBehalf")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("texts")).toObject().value(QStringLiteral("title")).toString(), QStringLiteral("Unlock"));
    EXPECT_EQ(o.value(QStringLiteral("choice")).toObject().value(QStringLiteral("label")).toString(), QStringLiteral("Remember"));
    EXPECT_TRUE(o.value(QStringLiteral("passwordNew")).toBool());
    EXPECT_TRUE(o.value(QStringLiteral("strength")).toBool());
    p.hasChoice = false;
    p.kind      = QStringLiteral("confirm");
    const QJsonObject c = QJsonDocument::fromJson(promptMessage(p)).object();
    EXPECT_TRUE(c.value(QStringLiteral("choice")).isNull());
    EXPECT_FALSE(c.value(QStringLiteral("passwordNew")).toBool()); // never for a confirmation
    const QJsonObject hello = QJsonDocument::fromJson(helloMessage({QStringLiteral("password")})).object();
    EXPECT_EQ(hello.value(QStringLiteral("v")).toString(), QStringLiteral("prompter/1"));
    EXPECT_EQ(hello.value(QStringLiteral("max")).toInt(), limits::kRequests);
    EXPECT_EQ(QJsonDocument::fromJson(cancelMessage(QStringLiteral("p9"))).object().value(QStringLiteral("id")).toString(), QStringLiteral("p9"));
}

// --- step 9c: NetworkManager's kind and the identity in an answer ----------------------------------------------------------

TEST(PrompterProtocol, NmPromptCarriesTheNetworkOnly) {
    NmPromptView v;
    v.id                 = QStringLiteral("p5");
    v.ssid               = QStringLiteral("Cafe");
    v.security           = QStringLiteral("enterprise");
    v.identity           = QStringLiteral("alice");
    const QByteArray line = nmPromptMessage(v);
    ASSERT_TRUE(line.endsWith('\n'));
    EXPECT_EQ(line.count('\n'), 1);
    const QJsonObject o = QJsonDocument::fromJson(line).object();
    EXPECT_EQ(o.keys(), (QStringList{QStringLiteral("id"), QStringLiteral("kind"), QStringLiteral("network"), QStringLiteral("type")}));
    EXPECT_EQ(o.value(QStringLiteral("kind")).toString(), QStringLiteral("nm"));
    const QJsonObject n = o.value(QStringLiteral("network")).toObject();
    EXPECT_EQ(n.keys(), (QStringList{QStringLiteral("identity"), QStringLiteral("security"), QStringLiteral("ssid")}));
    EXPECT_EQ(n.value(QStringLiteral("ssid")).toString(), QStringLiteral("Cafe"));
    EXPECT_EQ(n.value(QStringLiteral("security")).toString(), QStringLiteral("enterprise"));
    EXPECT_EQ(n.value(QStringLiteral("identity")).toString(), QStringLiteral("alice"));
}

TEST(PrompterProtocol, AnAnswersIdentityStaysRawAndIsBounded) {
    const std::string line = R"({"type":"answer","id":"p6","result":"ok","password":"pw","identity":"bob )" + jsonU("00e9") + R"("})";
    const ShellLine   a    = parsed(line, ParseStatus::Ok);
    EXPECT_TRUE(a.hasIdentity);
    EXPECT_EQ(decoded(line, a.identity), std::string("bob \xc3\xa9"));
    EXPECT_FALSE(parsed(R"({"type":"answer","id":"p6","result":"ok","password":"pw"})", ParseStatus::Ok).hasIdentity);
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p6","result":"ok","identity":true})", ParseStatus::Invalid).id, QStringLiteral("p6"));
    const std::string longName = R"({"type":"answer","id":"p6","result":"ok","password":"pw","identity":")" + std::string(limits::kIdentity + 1, 'a') + "\"}";
    EXPECT_EQ(parsed(longName, ParseStatus::Invalid).id, QStringLiteral("p6"));
}

namespace {
    // A NetworkManager connection as GetSecrets carries it (a{sa{sv}}), from a few settings of strings, an SSID and lists.
    struct Con {
        QByteArray type    = "802-11-wireless";
        QByteArray ssid    = "Home";
        QByteArray keyMgmt = "wpa-psk";
        QByteArray authAlg;
        int        wepIndex = -1;
        QList<QByteArray> eap;
        QByteArray identity;
        bool       wifi = true;

        GVariant* build() const {
            GVariantBuilder c;
            g_variant_builder_init(&c, G_VARIANT_TYPE("a{sa{sv}}"));
            GVariantBuilder s;
            g_variant_builder_init(&s, G_VARIANT_TYPE("a{sv}"));
            g_variant_builder_add(&s, "{sv}", "id", g_variant_new_string("A connection"));
            g_variant_builder_add(&s, "{sv}", "type", g_variant_new_string(type.constData()));
            g_variant_builder_add(&c, "{s@a{sv}}", "connection", g_variant_builder_end(&s));
            if (wifi) {
                g_variant_builder_init(&s, G_VARIANT_TYPE("a{sv}"));
                g_variant_builder_add(&s, "{sv}", "ssid", g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, ssid.constData(), static_cast<gsize>(ssid.size()), 1));
                g_variant_builder_add(&c, "{s@a{sv}}", "802-11-wireless", g_variant_builder_end(&s));
            }
            g_variant_builder_init(&s, G_VARIANT_TYPE("a{sv}"));
            g_variant_builder_add(&s, "{sv}", "key-mgmt", g_variant_new_string(keyMgmt.constData()));
            if (!authAlg.isEmpty())
                g_variant_builder_add(&s, "{sv}", "auth-alg", g_variant_new_string(authAlg.constData()));
            if (wepIndex >= 0)
                g_variant_builder_add(&s, "{sv}", "wep-tx-keyidx", g_variant_new_uint32(static_cast<guint32>(wepIndex)));
            g_variant_builder_add(&c, "{s@a{sv}}", "802-11-wireless-security", g_variant_builder_end(&s));
            if (!eap.isEmpty()) {
                g_variant_builder_init(&s, G_VARIANT_TYPE("a{sv}"));
                GVariantBuilder list;
                g_variant_builder_init(&list, G_VARIANT_TYPE("as"));
                for (const QByteArray& m : eap)
                    g_variant_builder_add(&list, "s", m.constData());
                g_variant_builder_add(&s, "{sv}", "eap", g_variant_builder_end(&list));
                if (!identity.isEmpty())
                    g_variant_builder_add(&s, "{sv}", "identity", g_variant_new_string(identity.constData()));
                g_variant_builder_add(&c, "{s@a{sv}}", "802-1x", g_variant_builder_end(&s));
            }
            return g_variant_ref_sink(g_variant_builder_end(&c));
        }
    };

    nm::Ask asked(const Con& con, const char* setting, guint32 flags = nm::kAllowInteraction, const char* const* hints = nullptr) {
        GVariant*     v = con.build();
        const nm::Ask a = nm::evaluate(v, setting, hints, flags);
        g_variant_unref(v);
        return a;
    }
} // namespace

TEST(PrompterNm, PersonalWifiPasswords) {
    Con wpa;
    const nm::Ask a = asked(wpa, "802-11-wireless-security");
    ASSERT_TRUE(a.ask) << a.why.toStdString();
    EXPECT_EQ(a.security, nm::Security::Wpa);
    EXPECT_EQ(nm::securityName(a.security), QStringLiteral("wpa"));
    EXPECT_EQ(a.ssid, QStringLiteral("Home"));
    EXPECT_EQ(a.setting, QByteArray("802-11-wireless-security"));
    EXPECT_EQ(a.key, QByteArray("psk"));
    Con sae;
    sae.keyMgmt = "sae";
    EXPECT_EQ(asked(sae, "802-11-wireless-security").security, nm::Security::Wpa3);
    EXPECT_EQ(asked(sae, "802-11-wireless-security").key, QByteArray("psk"));
    Con wep;
    wep.keyMgmt  = "none";
    wep.wepIndex = 2;
    const nm::Ask w = asked(wep, "802-11-wireless-security");
    ASSERT_TRUE(w.ask);
    EXPECT_EQ(w.security, nm::Security::Wep);
    EXPECT_EQ(w.key, QByteArray("wep-key2"));
    wep.wepIndex = -1; // NetworkManager's default index
    EXPECT_EQ(asked(wep, "802-11-wireless-security").key, QByteArray("wep-key0"));
    // REQUEST_NEW implies interaction.
    EXPECT_TRUE(asked(wpa, "802-11-wireless-security", nm::kRequestNew).ask);
}

TEST(PrompterNm, NothingIsAskedWithoutInteractionOrForOtherSecrets) {
    Con wpa;
    EXPECT_FALSE(nm::interactionAllowed(0));
    EXPECT_FALSE(nm::interactionAllowed(nm::kUserRequested | nm::kWpsPbcActive));
    const nm::Ask none = asked(wpa, "802-11-wireless-security", 0);
    EXPECT_FALSE(none.ask);
    EXPECT_TRUE(none.why.contains(QStringLiteral("no interaction"))) << none.why.toStdString();
    EXPECT_FALSE(asked(wpa, "802-11-wireless-security", nm::kUserRequested).ask);
    const nm::Ask vpn = asked(wpa, "vpn");
    EXPECT_FALSE(vpn.ask);
    EXPECT_TRUE(vpn.why.contains(QStringLiteral("VPN"))) << vpn.why.toStdString();
    EXPECT_FALSE(asked(wpa, "gsm").ask);
    EXPECT_FALSE(asked(wpa, "").ask);
    Con wired = wpa;
    wired.type = "802-3-ethernet";
    wired.wifi = false;
    EXPECT_FALSE(asked(wired, "802-11-wireless-security").ask);
    for (const char* mgmt : {"owe", "wpa-eap", "ieee8021x", "wpa-none", ""}) {
        Con c = wpa;
        c.keyMgmt = mgmt;
        EXPECT_FALSE(asked(c, "802-11-wireless-security").ask) << mgmt;
    }
    Con leap = wpa;
    leap.keyMgmt = "none";
    leap.authAlg = "leap";
    EXPECT_FALSE(asked(leap, "802-11-wireless-security").ask);
    Con badIndex = wpa;
    badIndex.keyMgmt  = "none";
    badIndex.wepIndex = 4;
    EXPECT_FALSE(asked(badIndex, "802-11-wireless-security").ask);
    EXPECT_FALSE(nm::evaluate(nullptr, "802-11-wireless-security", nullptr, nm::kAllowInteraction).ask);
    GVariant* notAConnection = g_variant_ref_sink(g_variant_new_string("x"));
    EXPECT_FALSE(nm::evaluate(notAConnection, "802-11-wireless-security", nullptr, nm::kAllowInteraction).ask);
    g_variant_unref(notAConnection);
}

TEST(PrompterNm, TheSsidIsPlainTextAndMustShowSomething) {
    Con c;
    c.ssid = QByteArray("Caf\xc3\xa9\n\xe2\x80\xae" "evil"); // a line feed, then U+202E (a direction override)
    EXPECT_EQ(asked(c, "802-11-wireless-security").ssid, QStringLiteral("Caf") + ucs({0xe9}) + QStringLiteral(" evil"));
    c.ssid = QByteArray("\xff\xfeok");
    EXPECT_EQ(asked(c, "802-11-wireless-security").ssid, ucs({0xfffd, 0xfffd}) + QStringLiteral("ok"));
    c.ssid = QByteArray("\t \n");
    EXPECT_FALSE(asked(c, "802-11-wireless-security").ask);
    c.ssid = QByteArray();
    EXPECT_FALSE(asked(c, "802-11-wireless-security").ask);
    c.ssid = QByteArray(33, 'a'); // longer than an SSID can be
    EXPECT_FALSE(asked(c, "802-11-wireless-security").ask);
}

TEST(PrompterNm, EnterprisePasswordWithTheStoredUsername) {
    Con c;
    c.keyMgmt  = "wpa-eap";
    c.eap      = {"peap"};
    c.identity = "alice";
    const nm::Ask a = asked(c, "802-1x");
    ASSERT_TRUE(a.ask) << a.why.toStdString();
    EXPECT_EQ(a.security, nm::Security::Enterprise);
    EXPECT_EQ(a.identity, QStringLiteral("alice")) << "shown read-only";
    // NetworkManager keeps only secrets from a reply: without a username stored with the connection nothing useful can be
    // asked (opus review of step 9c, MAJOR).
    Con nameless = c;
    nameless.identity.clear();
    const nm::Ask none = asked(nameless, "802-1x");
    EXPECT_FALSE(none.ask);
    EXPECT_TRUE(none.why.contains(QStringLiteral("no username"))) << none.why.toStdString();
    EXPECT_EQ(a.setting, QByteArray("802-1x"));
    EXPECT_EQ(a.key, QByteArray("password"));
    const char* const passwordHints[] = {"password", "password-raw", nullptr};
    EXPECT_TRUE(asked(c, "802-1x", nm::kAllowInteraction, passwordHints).ask);
    // A certificate's password or a PIN cannot be met with a name and a password.
    const char* const keyHints[] = {"private-key-password", nullptr};
    EXPECT_FALSE(asked(c, "802-1x", nm::kAllowInteraction, keyHints).ask);
    Con tls = c;
    tls.eap = {"tls"};
    EXPECT_FALSE(asked(tls, "802-1x").ask);
    Con both = c;
    both.eap = {"tls", "ttls"};
    EXPECT_TRUE(asked(both, "802-1x").ask);
    Con personal = c;
    personal.keyMgmt = "wpa-psk";
    EXPECT_FALSE(asked(personal, "802-1x").ask);
    Con noEap = c;
    noEap.eap.clear();
    EXPECT_FALSE(asked(noEap, "802-1x").ask);
    EXPECT_FALSE(asked(c, "802-1x", 0).ask);
}

TEST(PrompterNm, TheReplyHoldsTheSecretInItsSetting) {
    Con c;
    nm::Ask a = asked(c, "802-11-wireless-security");
    char* secret = static_cast<char*>(gcr_secure_memory_alloc(16));
    std::memcpy(secret, "c0rrect h0rse", 14);
    GVariant* reply = g_variant_ref_sink(nm::secretsReply(a, secret, 13));
    ASSERT_TRUE(g_variant_is_of_type(reply, G_VARIANT_TYPE("(a{sa{sv}})")));
    {
        // Walked child by child (a lookup would serialise the dictionary into a copy of its own): the reply's string is
        // the secure buffer itself, not a copy.
        GVariant* dict    = g_variant_get_child_value(reply, 0);
        GVariant* entry   = g_variant_get_child_value(dict, 0);
        GVariant* inner   = g_variant_get_child_value(entry, 1);
        GVariant* pair    = g_variant_get_child_value(inner, 0);
        GVariant* boxed   = g_variant_get_child_value(pair, 1);
        GVariant* value   = g_variant_get_variant(boxed);
        EXPECT_EQ(g_variant_get_string(value, nullptr), secret);
        for (GVariant* v : {value, boxed, pair, inner, entry, dict})
            g_variant_unref(v);
    }
    GVariant*    secrets = g_variant_get_child_value(reply, 0);
    GVariant*    setting = g_variant_lookup_value(secrets, "802-11-wireless-security", G_VARIANT_TYPE("a{sv}"));
    ASSERT_NE(setting, nullptr);
    const gchar* psk = nullptr;
    ASSERT_TRUE(g_variant_lookup(setting, "psk", "&s", &psk));
    EXPECT_STREQ(psk, "c0rrect h0rse");
    EXPECT_EQ(g_variant_n_children(setting), 1u);
    g_variant_unref(setting);
    g_variant_unref(secrets);
    g_variant_unref(reply); // zeroes and frees the buffer (ASan would see a double free or a leak)

    Con e;
    e.keyMgmt  = "wpa-eap";
    e.eap      = {"ttls"};
    e.identity = "alice";
    a          = asked(e, "802-1x");
    secret     = static_cast<char*>(gcr_secure_memory_alloc(8));
    std::memcpy(secret, "pw", 3);
    reply   = g_variant_ref_sink(nm::secretsReply(a, secret, 2));
    secrets = g_variant_get_child_value(reply, 0);
    setting = g_variant_lookup_value(secrets, "802-1x", G_VARIANT_TYPE("a{sv}"));
    ASSERT_NE(setting, nullptr);
    const gchar* password = nullptr;
    EXPECT_TRUE(g_variant_lookup(setting, "password", "&s", &password));
    EXPECT_STREQ(password, "pw");
    EXPECT_EQ(g_variant_n_children(setting), 1u) << "the password only: NetworkManager would drop a username";
    g_variant_unref(setting);
    g_variant_unref(secrets);
    g_variant_unref(reply);
}

// --- step 9c: grassfield-askpass's pure parts ------------------------------------------------------------------------------

TEST(PrompterAskpass, TheDiskNameIsPlainText) {
    EXPECT_EQ(gf::askpass::diskName("/dev/sdb1"), QStringLiteral("/dev/sdb1"));
    EXPECT_EQ(gf::askpass::diskName("/dev/sdb1\n\xe2\x80\xae" "gnp.exe"), QStringLiteral("/dev/sdb1 gnp.exe"));
    EXPECT_EQ(gf::askpass::diskName(" \t "), QString());
    EXPECT_EQ(gf::askpass::diskName(nullptr), QString());
    const QString cut = gf::askpass::diskName(std::string(500, 'a').c_str());
    EXPECT_EQ(cut.size(), gf::askpass::kDiskNameCap);
    EXPECT_TRUE(cut.endsWith(ucs({0x2026})));
}

TEST(PrompterAskpass, WritesEverythingOrFails) {
    int fds[2];
    ASSERT_EQ(::pipe(fds), 0);
    EXPECT_TRUE(gf::askpass::writeAll(fds[1], "luks pass\n", 10));
    char buffer[32] = {};
    EXPECT_EQ(::read(fds[0], buffer, sizeof buffer), 10);
    EXPECT_STREQ(buffer, "luks pass\n");
    ::close(fds[0]);
    const auto previous = std::signal(SIGPIPE, SIG_IGN);
    EXPECT_FALSE(gf::askpass::writeAll(fds[1], "x", 1)) << "nobody reads any more: EPIPE";
    std::signal(SIGPIPE, previous);
    ::close(fds[1]);
}

// The integrator's review of PR #95: every line the shell sent is wiped once handled, before the next one is, and so are
// the bytes the incomplete rest leaves behind when it moves to the start.
TEST(PrompterProtocol, LinesAreHandledThenWiped) {
    std::string       buffer = "{\"a\":\"one\"}\n{\"b\":\"two\"}\nrest";
    std::string       copy   = buffer;
    std::vector<std::string> seen;
    bool              earlierWiped = true;
    const std::size_t left = takeLines(buffer.data(), buffer.size(), [&](std::string_view line) {
        for (const char* p = buffer.data(); p < line.data(); ++p)
            earlierWiped = earlierWiped && *p == '\0';
        seen.emplace_back(line);
        return true;
    });
    EXPECT_EQ(seen, (std::vector<std::string>{"{\"a\":\"one\"}", "{\"b\":\"two\"}"}));
    EXPECT_TRUE(earlierWiped) << "a handled line stays in the buffer while the next one is handled";
    ASSERT_EQ(left, 4u);
    EXPECT_EQ(buffer.substr(0, 4), "rest");
    EXPECT_EQ(buffer.substr(4), std::string(copy.size() - 4, '\0')) << "the handled lines and the moved bytes are wiped";
    // No complete line: nothing handled, nothing moved.
    std::string partial = "{\"half";
    EXPECT_EQ(takeLines(partial.data(), partial.size(), [](std::string_view) { return true; }), partial.size());
    EXPECT_EQ(partial, "{\"half");
    // A handler that drops the connection: nothing more is handled, moved or wiped (the dropper wiped the buffer).
    std::string dropped = "x\ny\nz";
    int         calls   = 0;
    EXPECT_EQ(takeLines(dropped.data(), dropped.size(), [&](std::string_view) { return ++calls < 1; }), 0u);
    EXPECT_EQ(calls, 1);
    EXPECT_EQ(dropped, "x\ny\nz");
}

// --- the bound ---------------------------------------------------------------------------------------------------------

TEST(PrompterRequests, AtMostEightAndIdsNeverReused) {
    RequestBook book(limits::kRequests);
    int         owners[10];
    QStringList ids;
    for (int i = 0; i < 8; ++i) {
        const QString id = book.reserve(&owners[i]);
        ASSERT_FALSE(id.isEmpty());
        ids.append(id);
    }
    EXPECT_EQ(book.count(), 8);
    EXPECT_TRUE(book.reserve(&owners[8]).isEmpty()); // the 9th is refused
    EXPECT_TRUE(book.reserve(&owners[0]).isEmpty()); // one request per owner
    EXPECT_EQ(book.ids(), ids);
    EXPECT_EQ(book.owner(ids.at(3)), &owners[3]);
    EXPECT_EQ(book.idOf(&owners[3]), ids.at(3));
    EXPECT_TRUE(book.release(ids.at(3)));
    EXPECT_FALSE(book.release(ids.at(3)));
    EXPECT_EQ(book.owner(ids.at(3)), nullptr);
    const QString next = book.reserve(&owners[8]);
    EXPECT_EQ(next, QStringLiteral("p9")); // a new number, never the released one
    EXPECT_FALSE(ids.contains(next));
    EXPECT_TRUE(book.reserve(nullptr).isEmpty());
}

// --- the shell's cgroup and the socket peer ------------------------------------------------------------------------------

TEST(PrompterPeer, CgroupLineAndUnit) {
    const QByteArray v2 = "0::/user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service\n";
    const QString    path = unifiedCgroupPath(v2);
    EXPECT_EQ(path, QStringLiteral("/user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service"));
    EXPECT_TRUE(cgroupIsUnit(path, QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(path, QStringLiteral("grassfield-shell.service"), 1001, true)); // another user's manager
    EXPECT_FALSE(cgroupIsUnit(path, QStringLiteral("grassfield-security.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(path + QStringLiteral(" (deleted)"), QStringLiteral("grassfield-shell.service (deleted)"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot.scope"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    // A unit of the same name outside the user's manager (the system manager), or a deeper cgroup inside the unit.
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/system.slice/grassfield-shell.service"), QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(path + QStringLiteral("/child"), QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_TRUE(cgroupIsUnit(QStringLiteral("/system.slice/grassfield-shell.service"), QStringLiteral("grassfield-shell.service"), 1000, false));
    // Only slices between the user's manager and the unit: a cgroup nested in a scope or another unit that merely ends
    // with the unit's name is refused (security review of step 9a, NIT-1).
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot.scope/grassfield-shell.service"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/evil.service/x/grassfield-shell.service"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/.slice/grassfield-shell.service"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_TRUE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/grassfield-shell.service"),
                             QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_TRUE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/session.slice/grassfield-shell.service"),
                             QStringLiteral("grassfield-shell.service"), 1000, true));
    // Hybrid hierarchies: only the 0:: line counts; none at all is no cgroup.
    EXPECT_EQ(unifiedCgroupPath("12:pids:/user.slice\n1:name=systemd:/user.slice/x.service\n0::/a/b.service\n"), QStringLiteral("/a/b.service"));
    EXPECT_EQ(unifiedCgroupPath("1:name=systemd:/x.service\n"), QString());
    EXPECT_FALSE(cgroupIsUnit(QString(), QStringLiteral("x.service"), 1000, false));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/"), QStringLiteral("x.service"), 1000, false));
}

TEST(PrompterPeer, PeerUnitNames) {
    EXPECT_TRUE(validPeerUnit(QStringLiteral("grassfield-shell.service"), false));
    EXPECT_TRUE(validPeerUnit(QStringLiteral("grassfield-security.service"), false));
    EXPECT_TRUE(validPeerUnit(QStringLiteral("app@x.service"), false));
    EXPECT_FALSE(validPeerUnit(QStringLiteral("grassfield-shell"), false));
    EXPECT_FALSE(validPeerUnit(QStringLiteral("app-foot.scope"), false));
    EXPECT_FALSE(validPeerUnit(QStringLiteral("a/b.service"), false));
    EXPECT_FALSE(validPeerUnit(QString(), false));
    EXPECT_TRUE(validPeerUnit(QStringLiteral("9d5c228690508d63"), true)); // a container's cgroup, development runs only
    EXPECT_FALSE(validPeerUnit(QStringLiteral(".."), true));
}

TEST(PrompterPeer, FdinfoPid) {
    EXPECT_EQ(pidFromFdinfo("pos:\t0\nflags:\t02000002\nmnt_id:\t15\nino:\t1061\nPid:\t1234\nNSpid:\t1234\n"), 1234);
    EXPECT_EQ(pidFromFdinfo("Pid:\t-1\n"), -1); // exited
    EXPECT_EQ(pidFromFdinfo("Pid:\t0\n"), 0);   // another PID namespace
    EXPECT_EQ(pidFromFdinfo("flags:\t0\n"), 0);
    EXPECT_EQ(pidFromFdinfo("Pid:\tabc\n"), 0);
}

TEST(PrompterPeer, SocketPeerOfOwnCgroupIsAcceptedOthersRefused) {
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty())
        GTEST_SKIP() << "this process sits at the root of its cgroup tree: no unit name to expect";
    int pair[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), 0);
    const PeerCheck ok = checkSocketPeer(pair[0], ::getuid(), leaf, false);
    EXPECT_TRUE(ok.accepted) << ok.reason.toStdString();
    EXPECT_EQ(ok.pid, ::getpid());
    const PeerCheck other = checkSocketPeer(pair[0], ::getuid(), QStringLiteral("grassfield-shell.service"), false);
    EXPECT_FALSE(other.accepted);
    const PeerCheck user = checkSocketPeer(pair[0], ::getuid() + 1, leaf, false);
    EXPECT_FALSE(user.accepted);
    ::close(pair[0]);
    ::close(pair[1]);
    if (!ok.raceFree)
        std::fprintf(stderr, "note: this kernel has no SO_PEERPIDFD; the peer's cgroup was read through SO_PEERCRED's pid\n");
}

namespace {
    PidfdAnswer pidfdInvalid(int) {
        return {-1, EINVAL, -1}; // Linux 6.5 to 6.15 for a peer that exited and was reaped
    }
    PidfdAnswer pidfdUnknown(int) {
        return {-1, ENOPROTOOPT, -1}; // a kernel without SO_PEERPIDFD
    }
    PidfdAnswer pidfdDenied(int) {
        return {-1, EPERM, -1};
    }
} // namespace

TEST(PrompterPeer, OnlyAKernelWithoutPidfdsFallsBackToThePid) {
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty())
        GTEST_SKIP() << "this process sits at the root of its cgroup tree: no unit name to expect";
    int pair[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), 0);
    // EINVAL (a reaped peer on Linux 6.5-6.15) and any other error refuse: the PID may belong to another process now.
    const PeerCheck invalid = checkSocketPeer(pair[0], ::getuid(), leaf, false, pidfdInvalid);
    EXPECT_FALSE(invalid.accepted);
    EXPECT_TRUE(invalid.reason.contains(QStringLiteral("no pidfd")));
    EXPECT_FALSE(checkSocketPeer(pair[0], ::getuid(), leaf, false, pidfdDenied).accepted);
    // ENOPROTOOPT (before Linux 6.5): SO_PEERCRED's PID, not race-free.
    const PeerCheck old = checkSocketPeer(pair[0], ::getuid(), leaf, false, pidfdUnknown);
    EXPECT_TRUE(old.accepted) << old.reason.toStdString();
    EXPECT_FALSE(old.raceFree);
    EXPECT_EQ(old.pid, ::getpid());
    ::close(pair[0]);
    ::close(pair[1]);
}

TEST(PrompterPeer, APeerThatExitedAndWasReapedIsRefused) {
    // The review's probe: the connecting process exits and is reaped while a child keeps its socket open. Linux 6.5 to
    // 6.15 answer SO_PEERPIDFD with EINVAL there, later kernels with a pidfd whose PID reads -1: refused either way.
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty())
        GTEST_SKIP() << "this process sits at the root of its cgroup tree: no unit name to expect";
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QByteArray path = QFile::encodeName(dir.path() + QStringLiteral("/p.sock"));
    ASSERT_LT(path.size(), 100);
    const int listener = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.constData(), static_cast<std::size_t>(path.size()));
    ASSERT_EQ(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof address), 0);
    ASSERT_EQ(::listen(listener, 4), 0);
    int keep[2];
    ASSERT_EQ(::pipe(keep), 0);
    const pid_t connector = ::fork();
    if (connector == 0) {
        const int s = ::socket(AF_UNIX, SOCK_STREAM, 0);
        if (::connect(s, reinterpret_cast<sockaddr*>(&address), sizeof address) != 0)
            ::_exit(1);
        if (::fork() == 0) { // the grandchild keeps the socket open until the test is done
            ::close(keep[1]);
            char b;
            (void)!::read(keep[0], &b, 1);
            ::_exit(0);
        }
        ::_exit(0);
    }
    ASSERT_GT(connector, 0);
    ::waitpid(connector, nullptr, 0); // reaped
    const int fd = ::accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
    ASSERT_GE(fd, 0);
    const PeerCheck check = checkSocketPeer(fd, ::getuid(), leaf, false);
    EXPECT_FALSE(check.accepted) << check.reason.toStdString();
    ::close(fd);
    ::close(keep[1]);
    ::close(keep[0]);
    ::close(listener);
}

namespace {
    // A session's check needs this process's cgroup to look like a unit under the user's manager (only slices between).
    bool ownCgroupIsAUserUnit(const QString& leaf) {
        QFile f(QStringLiteral("/proc/self/cgroup"));
        return f.open(QIODevice::ReadOnly) && cgroupIsUnit(unifiedCgroupPath(f.readAll()), leaf, ::getuid(), true);
    }

    // The main-process cases need a user systemd manager. When they skip, they also print "SKIP: <suite>.<case>: <reason>"
    // on a line of its own, so a run without one shows in the output and cannot pass as covered (opus review of #26, NIT).
    std::string announceSkip(const std::string& reason) {
        const ::testing::TestInfo* info = ::testing::UnitTest::GetInstance()->current_test_info();
        std::printf("SKIP: %s.%s: %s\n", info ? info->test_suite_name() : "?", info ? info->name() : "?", reason.c_str());
        std::fflush(stdout);
        return reason;
    }

    // The peer the injected SO_PEERPIDFD names, for the liveness case below.
    pid_t g_childPeer = -1;
    PidfdAnswer pidfdOfChild(int) {
        const int pidfd = pidfdOpen(g_childPeer);
        return pidfd >= 0 ? PidfdAnswer{0, 0, pidfd} : PidfdAnswer{-1, errno, -1};
    }
} // namespace

TEST(PrompterPeer, ASessionPeerMustBeTheUnitsMainProcess) {
    // rc7 security review of R7-SEC-02: the user may write the unit's cgroup.procs, so a process of theirs can move itself
    // into the shell's cgroup; in a session only the unit's main process (systemd's MainPID, asked at check time) passes.
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty() || !ownCgroupIsAUserUnit(leaf))
        GTEST_SKIP() << announceSkip("this process's cgroup is not a unit under the user's manager (no user systemd)");
    int pair[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), 0);
    int asked = 0;
    const auto answer = [&asked](qint64 pid) {
        return [&asked, pid](const QString&) {
            ++asked;
            return pid;
        };
    };
    const PeerCheck ok = checkSocketPeer(pair[0], ::getuid(), leaf, true, nullptr, answer(::getpid()));
    EXPECT_TRUE(ok.accepted) << ok.reason.toStdString();
    EXPECT_EQ(ok.mainPid, ::getpid());
    EXPECT_EQ(asked, 1);
    const PeerCheck other = checkSocketPeer(pair[0], ::getuid(), leaf, true, nullptr, answer(::getpid() + 1));
    EXPECT_FALSE(other.accepted);
    EXPECT_TRUE(other.reason.contains(QStringLiteral("main process"))) << other.reason.toStdString();
    EXPECT_FALSE(checkSocketPeer(pair[0], ::getuid(), leaf, true, nullptr, answer(0)).accepted);  // none (stopped, a scope)
    EXPECT_FALSE(checkSocketPeer(pair[0], ::getuid(), leaf, true, nullptr, answer(-1)).accepted); // systemd not asked
    EXPECT_FALSE(checkSocketPeer(pair[0], ::getuid(), leaf, true).accepted);                      // no query at all
    // Another uid fails first, whatever systemd says.
    asked = 0;
    EXPECT_FALSE(checkSocketPeer(pair[0], ::getuid() + 1, leaf, true, nullptr, answer(::getpid())).accepted);
    EXPECT_EQ(asked, 0);
    // A development run checks the cgroup alone: the query is not consulted.
    asked = 0;
    EXPECT_TRUE(checkSocketPeer(pair[0], ::getuid(), leaf, false, nullptr, answer(0)).accepted);
    EXPECT_EQ(asked, 0);
    ::close(pair[0]);
    ::close(pair[1]);
}

TEST(PrompterPeer, APeerThatExitsDuringTheMainProcessQueryIsRefused) {
    // The pidfd is checked again after systemd's answer: a peer that exits meanwhile (its PID free for another process,
    // which systemd might then name) is refused even though every answer matched its PID.
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty() || !ownCgroupIsAUserUnit(leaf))
        GTEST_SKIP() << announceSkip("this process's cgroup is not a unit under the user's manager (no user systemd)");
    const pid_t child = ::fork();
    if (child == 0) {
        ::pause();
        ::_exit(0);
    }
    ASSERT_GT(child, 0);
    g_childPeer = child;
    int pair[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), 0);
    const auto exitsWhileAsked = [child](const QString&) -> qint64 {
        ::kill(child, SIGKILL);
        ::waitpid(child, nullptr, 0);
        return child;
    };
    const PeerCheck check = checkSocketPeer(pair[0], ::getuid(), leaf, true, pidfdOfChild, exitsWhileAsked);
    EXPECT_EQ(check.pid, child);
    EXPECT_FALSE(check.accepted) << check.reason.toStdString();
    EXPECT_TRUE(check.reason.contains(QStringLiteral("exited"))) << check.reason.toStdString();
    // Control: the same child alive through the query is taken.
    const pid_t live = ::fork();
    if (live == 0) {
        ::pause();
        ::_exit(0);
    }
    ASSERT_GT(live, 0);
    g_childPeer = live;
    const PeerCheck taken = checkSocketPeer(pair[0], ::getuid(), leaf, true, pidfdOfChild, [live](const QString&) -> qint64 { return live; });
    EXPECT_TRUE(taken.accepted) << taken.reason.toStdString();
    ::kill(live, SIGKILL);
    ::waitpid(live, nullptr, 0);
    ::close(pair[0]);
    ::close(pair[1]);
}

TEST(PrompterPeer, TheMainProcessAskedIsTheExpectedUnits) {
    // ADR-0041 S3 moved the secret sheets into the security process: the bridge's --peer-unit names
    // grassfield-security.service, and the main process compared is that unit's, asked for by that name alone. A check that
    // asked another unit (the UI's grassfield-shell.service, the client before S3) would compare the peer with the wrong
    // process. Here systemd names this process for one unit only, and any other unit's main process is another PID.
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty() || !ownCgroupIsAUserUnit(leaf))
        GTEST_SKIP() << announceSkip("this process's cgroup is not a unit under the user's manager (no user systemd)");
    int pair[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), 0);
    QString    asked;
    const auto mainOf = [&asked](const QString& owner) {
        return [&asked, owner](const QString& unit) -> qint64 {
            asked += unit + QLatin1Char(';');
            return unit == owner ? ::getpid() : ::getpid() + 1;
        };
    };
    const PeerCheck ok = checkSocketPeer(pair[0], ::getuid(), leaf, true, nullptr, mainOf(leaf));
    EXPECT_TRUE(ok.accepted) << ok.reason.toStdString();
    EXPECT_EQ(asked.toStdString(), (leaf + QLatin1Char(';')).toStdString());
    for (const QString& other : {QStringLiteral("grassfield-shell.service"), QStringLiteral("grassfield-security.service")}) {
        if (other == leaf)
            continue;
        asked.clear();
        const PeerCheck wrong = checkSocketPeer(pair[0], ::getuid(), leaf, true, nullptr, mainOf(other));
        EXPECT_FALSE(wrong.accepted) << other.toStdString();
        EXPECT_EQ(asked.toStdString(), (leaf + QLatin1Char(';')).toStdString());
    }
    ::close(pair[0]);
    ::close(pair[1]);
}

TEST(PrompterPeer, RefusalsAreLoggedOncePerWindow) {
    LogThrottle throttle(10000);
    qint64      suppressed = -1;
    EXPECT_TRUE(throttle.allow(1000, &suppressed));
    EXPECT_EQ(suppressed, 0);
    for (int i = 0; i < 50; ++i)
        EXPECT_FALSE(throttle.allow(1000 + i * 100, &suppressed));
    EXPECT_TRUE(throttle.allow(11000, &suppressed));
    EXPECT_EQ(suppressed, 50);
    EXPECT_FALSE(throttle.allow(11001, &suppressed));
    EXPECT_TRUE(throttle.allow(30000, &suppressed));
    EXPECT_EQ(suppressed, 1);
}

TEST(PrompterPeer, SocketPathAndDirectory) {
    EXPECT_EQ(socketPath(QString(), QStringLiteral("/run/user/1000")), QStringLiteral("/run/user/1000/grassfield/prompter.sock"));
    EXPECT_EQ(socketPath(QStringLiteral("relative.sock"), QStringLiteral("/run/user/1000")), QString());
    EXPECT_EQ(socketPath(QString(), QString()), QString());
    EXPECT_FALSE(fitsSocketPath(QStringLiteral("/") + QString(120, u'a')));
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString socket = dir.path() + QStringLiteral("/grassfield/prompter.sock");
    EXPECT_TRUE(prepareSocketDirectory(socket).isEmpty());
    struct stat st{};
    ASSERT_EQ(::lstat(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0700u);
    // A symlink in its place is refused.
    const QString link = dir.path() + QStringLiteral("/linked");
    ASSERT_EQ(::symlink(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), QFile::encodeName(link).constData()), 0);
    EXPECT_FALSE(prepareSocketDirectory(link + QStringLiteral("/prompter.sock")).isEmpty());
    // Group and other bits of an existing directory are removed.
    ASSERT_EQ(::chmod(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), 0755), 0);
    EXPECT_TRUE(prepareSocketDirectory(socket).isEmpty());
    ASSERT_EQ(::lstat(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0700u);
    // A missing directory in a parent that others can write is not created.
    const QString open = dir.path() + QStringLiteral("/open");
    ASSERT_TRUE(QDir().mkpath(open));
    ASSERT_EQ(::chmod(QFile::encodeName(open).constData(), 0777), 0);
    EXPECT_FALSE(prepareSocketDirectory(open + QStringLiteral("/grassfield/prompter.sock")).isEmpty());
}

// --- trusted executables and desktop entries (a temporary tree stands for the system: owner = this user, top = the tree) ---

class PrompterTrust : public ::testing::Test {
  protected:
    void SetUp() override {
        ASSERT_TRUE(m_dir.isValid());
        m_top = m_dir.path();
        ASSERT_TRUE(QDir().mkpath(m_top + QStringLiteral("/usr/bin")));
        ASSERT_TRUE(QDir().mkpath(m_top + QStringLiteral("/usr/share/applications")));
        for (const char* d : {"", "/usr", "/usr/bin", "/usr/share", "/usr/share/applications"})
            ASSERT_EQ(::chmod(QFile::encodeName(m_top + QLatin1String(d)).constData(), 0755), 0);
        writeFile(bin(QStringLiteral("editor")), "#!/bin/sh\n", 0755);
        writeFile(bin(QStringLiteral("python9")), "#!/bin/sh\n", 0755);
        writeFile(bin(QStringLiteral("keyringd")), "#!/bin/sh\n", 0755);
    }
    QString bin(const QString& name) const {
        return m_top + QStringLiteral("/usr/bin/") + name;
    }
    QString apps() const {
        return m_top + QStringLiteral("/usr/share/applications");
    }
    void entry(const QString& name, const QByteArray& exec, const QByteArray& extra = {}) {
        writeFile(apps() + u'/' + name, "[Desktop Entry]\nType=Application\nName=" + name.toUtf8().replace(".desktop", "") + "\nName[fr]=Localised\nIcon=icon-"
                                             + name.toUtf8().replace(".desktop", "") + "\nExec=" + exec + "\n" + extra,
                  0644);
    }
    Where where() const {
        Where w;
        w.applications = apps();
        w.programDirs  = {m_top + QStringLiteral("/usr/bin")};
        w.known        = {{bin(QStringLiteral("keyringd")), QStringLiteral("keyring")}};
        w.owner        = ::getuid();
        w.top          = m_top;
        return w;
    }
    ExeFacts facts(const QString& path) const {
        ExeFacts f;
        f.path     = path;
        f.file     = fileIdOf(path);
        f.alive     = true;
        f.sameUser  = true;
        f.traced         = false;
        f.sameNamespaces = true;
        f.codeKnown      = true;
        f.code           = {fileMapping(path, selfMountDevices())};
        return f;
    }

    QTemporaryDir m_dir;
    QString       m_top;
};

TEST_F(PrompterTrust, OwnedNotWritableFilesAndDirectoriesOnly) {
    const uid_t me = ::getuid();
    EXPECT_TRUE(trustedPath(bin(QStringLiteral("editor")), me, m_top));
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor")), me + 1, m_top)); // another owner
    EXPECT_FALSE(trustedPath(QStringLiteral("usr/bin/editor"), me, m_top));  // relative
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/usr/bin/../bin/editor"), me, m_top));
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/usr//bin/editor"), me, m_top));
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor (deleted)")), me, m_top));
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/usr/bin"), me, m_top)); // not a regular file
    EXPECT_FALSE(trustedPath(QStringLiteral("/elsewhere/editor"), me, m_top)); // outside the tree
    // Writable by group or others: the file, then a directory above it.
    ASSERT_EQ(::chmod(QFile::encodeName(bin(QStringLiteral("editor"))).constData(), 0775), 0);
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor")), me, m_top));
    ASSERT_EQ(::chmod(QFile::encodeName(bin(QStringLiteral("editor"))).constData(), 0755), 0);
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr")).constData(), 0757), 0);
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor")), me, m_top));
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr")).constData(), 0755), 0);
    // A symlink, as the file or as a directory on the way.
    ASSERT_EQ(::symlink("editor", QFile::encodeName(bin(QStringLiteral("link"))).constData()), 0);
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("link")), me, m_top));
    ASSERT_EQ(::symlink(QFile::encodeName(m_top + QStringLiteral("/usr/bin")).constData(), QFile::encodeName(m_top + QStringLiteral("/bin")).constData()), 0);
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/bin/editor"), me, m_top));
}

TEST_F(PrompterTrust, ExecLinesThatAreTheProgramItself) {
    EXPECT_EQ(execProgramOnly(QStringLiteral("/usr/bin/editor %U")), QStringLiteral("/usr/bin/editor"));
    EXPECT_EQ(execProgramOnly(QStringLiteral("editor")), QStringLiteral("editor"));
    EXPECT_EQ(execProgramOnly(QStringLiteral("editor %f %i %c %k")), QStringLiteral("editor"));
    EXPECT_EQ(execProgramOnly(QStringLiteral("\"/opt/my app/run\" %F")), QStringLiteral("/opt/my app/run"));
    // Anything that picks something else to run, or a quoting error.
    EXPECT_TRUE(execProgramOnly(QStringLiteral("python9 /usr/share/tool/tool.py")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("editor --new-window")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("env FOO=1 editor")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("FOO=1 editor")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("sh -c editor")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("editor;rm")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("\"unterminated %f")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("%f")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QString()).isEmpty());
}

TEST_F(PrompterTrust, DesktopEntryParsing) {
    const DesktopEntry e = parseDesktopEntry(
        "# comment\n[Desktop Action new]\nName=Wrong\nExec=wrong\n[Desktop Entry]\nType=Application\nName = Text\\sEditor\nName[fr]=\xc3\x89" "diteur\nIcon=accessories-text-editor\n"
        "Exec=editor %U\nHidden=false\n[Other]\nName=Also wrong\n");
    EXPECT_TRUE(e.application);
    EXPECT_FALSE(e.hidden);
    EXPECT_EQ(e.name, QStringLiteral("Text Editor"));
    EXPECT_EQ(e.icon, QStringLiteral("accessories-text-editor"));
    EXPECT_EQ(e.exec, QStringLiteral("editor %U"));
    EXPECT_FALSE(parseDesktopEntry("[Desktop Entry]\nType=Link\n").application);
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nHidden=true\n").hidden);
}

TEST_F(PrompterTrust, TheOneEntryThatRunsTheExecutable) {
    entry(QStringLiteral("org.example.Editor.desktop"), "editor %U");
    entry(QStringLiteral("tool.desktop"), "python9 /usr/share/tool/tool.py"); // an interpreter with a script: never python9's
    const RequesterView editor = requesterFor(facts(bin(QStringLiteral("editor"))), where());
    EXPECT_EQ(editor.role, QStringLiteral("app"));
    EXPECT_TRUE(editor.identified);
    EXPECT_FALSE(editor.onBehalf);
    EXPECT_EQ(editor.name, QStringLiteral("org.example.Editor")); // the unlocalised Name
    EXPECT_EQ(editor.icon, QStringLiteral("icon-org.example.Editor"));
    EXPECT_EQ(editor.desktopId, QStringLiteral("org.example.Editor.desktop"));
    EXPECT_EQ(editor.path, bin(QStringLiteral("editor")));
    const RequesterView python = requesterFor(facts(bin(QStringLiteral("python9"))), where());
    EXPECT_EQ(python.role, QStringLiteral("unidentified"));
    EXPECT_FALSE(python.identified);
    EXPECT_EQ(python.path, bin(QStringLiteral("python9")));
    // A second entry for the same file: neither is shown.
    entry(QStringLiteral("org.example.Editor2.desktop"), editor.path.toUtf8());
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("unidentified"));
}

TEST_F(PrompterTrust, EntriesThatDoNotCount) {
    entry(QStringLiteral("hidden.desktop"), "editor", "Hidden=true\n");
    entry(QStringLiteral("link.desktop"), "editor", "Type=Link\n");
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("unidentified"));
    // A writable entry file is not read.
    entry(QStringLiteral("writable.desktop"), "editor");
    ASSERT_EQ(::chmod(QFile::encodeName(apps() + QStringLiteral("/writable.desktop")).constData(), 0666), 0);
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("unidentified"));
    ASSERT_EQ(::chmod(QFile::encodeName(apps() + QStringLiteral("/writable.desktop")).constData(), 0644), 0);
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("app"));
}

TEST(PrompterIdentityList, KiosWorkerIsTheKioRole) {
    bool found = false;
    for (const KnownCaller& k : knownCallers()) {
        found = found || (k.path == QStringLiteral("/usr/lib/kf6/kioworker") && k.role == QStringLiteral("kio") && k.trustedCodeOnly);
        // The other known callers keep their role with extra code (decision 9-14); only the worker, which loads a plugin
        // from any path, needs trusted code (the security review of step 9e, MINOR-2).
        if (k.role != QStringLiteral("kio")) {
            EXPECT_FALSE(k.trustedCodeOnly) << k.path.toStdString();
        }
    }
    EXPECT_TRUE(found);
}

TEST(PrompterIdentityList, TheAskpassHelperIsTheDiskRole) {
    bool found = false;
    for (const KnownCaller& k : knownCallers())
        found = found || (k.path == QStringLiteral("/usr/lib/grassfield/grassfield-askpass") && k.role == QStringLiteral("disk"));
    EXPECT_TRUE(found);
}

TEST_F(PrompterTrust, KnownCallersAskOnSomeoneElsesBehalf) {
    entry(QStringLiteral("keyring.desktop"), "keyringd"); // the role wins over an entry
    const RequesterView keyring = requesterFor(facts(bin(QStringLiteral("keyringd"))), where());
    EXPECT_EQ(keyring.role, QStringLiteral("keyring"));
    EXPECT_TRUE(keyring.identified);
    EXPECT_TRUE(keyring.onBehalf);
    EXPECT_TRUE(keyring.name.isEmpty()); // the shell names the role in its own words
    // In namespaces of its own, a known program is not named (the integrator's review of PR #95, NIT)...
    ExeFacts elsewhere       = facts(bin(QStringLiteral("keyringd")));
    elsewhere.sameNamespaces = false;
    EXPECT_EQ(requesterFor(elsewhere, where()).role, QStringLiteral("unidentified"));
    // ...save the disk helper, which udiskie's unit runs in namespaces of its own (decision 9-26, amended); its path, its
    // file by device and inode and the trace check still hold.
    Where diskWhere = where();
    diskWhere.known = {{bin(QStringLiteral("keyringd")), QStringLiteral("disk")}};
    const RequesterView disk = requesterFor(elsewhere, diskWhere);
    EXPECT_EQ(disk.role, QStringLiteral("disk"));
    EXPECT_TRUE(disk.identified);
    EXPECT_TRUE(disk.onBehalf);
    ExeFacts otherFile = elsewhere;
    otherFile.file     = fileIdOf(bin(QStringLiteral("editor"))); // the path names another file than the one it runs
    EXPECT_EQ(requesterFor(otherFile, diskWhere).role, QStringLiteral("unidentified"));
    ExeFacts traced = elsewhere;
    traced.traced   = true;
    EXPECT_EQ(requesterFor(traced, diskWhere).role, QStringLiteral("unidentified"));
}

TEST_F(PrompterTrust, AnAppsNameNeedsOnlyTrustedCodeInItsProcess) {
    entry(QStringLiteral("org.example.Editor.desktop"), "editor");
    writeFile(m_top + QStringLiteral("/usr/bin/libtrusted.so"), "\x7f" "ELF", 0644);
    const CodeMapping trusted = fileMapping(m_top + QStringLiteral("/usr/bin/libtrusted.so"), selfMountDevices());
    ASSERT_NE(trusted.inode, 0u);
    ExeFacts clean = facts(bin(QStringLiteral("editor")));
    clean.code.append(trusted);
    EXPECT_EQ(requesterFor(clean, where()).role, QStringLiteral("app"));
    // LD_PRELOAD or LD_LIBRARY_PATH code from the user's files, a library replaced since it was loaded, memfd code:
    // the app's name is not lent (security review of step 9a, MINOR-2, decision 9-14).
    for (const QString& foreign : {QStringLiteral("/home/u/.local/lib/evil.so"), m_top + QStringLiteral("/usr/bin/libtrusted.so (deleted)"),
                                   QStringLiteral("/memfd:code (deleted)")}) {
        ExeFacts preloaded = clean;
        preloaded.code.append(CodeMapping{foreign, trusted.major, trusted.minor, trusted.inode});
        const RequesterView r = requesterFor(preloaded, where());
        EXPECT_EQ(r.role, QStringLiteral("unidentified")) << foreign.toStdString();
        EXPECT_EQ(r.path, bin(QStringLiteral("editor")));
    }
    // A trusted path whose mapping names another file, by inode or by device (a file bind-mounted over the path in
    // another mount namespace: counter-review of step 9a, MINOR-C), or a process in other namespaces.
    ExeFacts otherInode = clean;
    otherInode.code.last().inode += 1;
    EXPECT_EQ(requesterFor(otherInode, where()).role, QStringLiteral("unidentified"));
    ExeFacts otherDevice = clean;
    otherDevice.code.last().minor += 1;
    EXPECT_EQ(requesterFor(otherDevice, where()).role, QStringLiteral("unidentified"));
    ExeFacts elsewhere       = clean;
    elsewhere.sameNamespaces = false;
    EXPECT_EQ(requesterFor(elsewhere, where()).role, QStringLiteral("unidentified"));
    ExeFacts unread = clean;
    unread.codeKnown = false;
    EXPECT_EQ(requesterFor(unread, where()).role, QStringLiteral("unidentified"));
    // A traced process can run anyone's code: unidentified, whatever it runs (a known caller too).
    ExeFacts traced = clean;
    traced.traced   = true;
    EXPECT_EQ(requesterFor(traced, where()).role, QStringLiteral("unidentified"));
    ExeFacts tracedKeyring = facts(bin(QStringLiteral("keyringd")));
    tracedKeyring.traced   = true;
    EXPECT_EQ(requesterFor(tracedKeyring, where()).role, QStringLiteral("unidentified"));
    // A known caller keeps its role with extra code: any program can make it ask anyway (the row names the program that
    // asks, never a guarantee about the text; decision 9-14).
    ExeFacts keyringPlugins = facts(bin(QStringLiteral("keyringd")));
    keyringPlugins.code.append(CodeMapping{QStringLiteral("/home/u/.local/lib/evil.so"), 0, 1, 7});
    EXPECT_EQ(requesterFor(keyringPlugins, where()).role, QStringLiteral("keyring"));
}

// KIO's worker loads whatever plugin its command line names, from any path (KIO 6.31.0 kioworker.cpp:49-65): its row is
// lent only while every file it maps executable is trusted (the security review of step 9e, MINOR-2).
TEST_F(PrompterTrust, KiosWorkerRowNeedsOnlyTrustedCode) {
    writeFile(bin(QStringLiteral("worker")), "#!/bin/sh\n", 0755);
    writeFile(m_top + QStringLiteral("/usr/bin/kio_ftp.so"), "\x7f" "ELF", 0644);
    const CodeMapping plugin = fileMapping(m_top + QStringLiteral("/usr/bin/kio_ftp.so"), selfMountDevices());
    ASSERT_NE(plugin.inode, 0u);
    Where w = where();
    w.known.append(KnownCaller{bin(QStringLiteral("worker")), QStringLiteral("kio"), true});
    ExeFacts worker = facts(bin(QStringLiteral("worker")));
    worker.code.append(plugin);
    const RequesterView kio = requesterFor(worker, w);
    EXPECT_EQ(kio.role, QStringLiteral("kio"));
    EXPECT_TRUE(kio.identified);
    EXPECT_TRUE(kio.onBehalf);
    // A plugin from the user's files, a replaced one, other namespaces, mappings not read: an unidentified program, the
    // worker's executable named.
    ExeFacts foreign = worker;
    foreign.code.append(CodeMapping{QStringLiteral("/home/u/evil.so"), plugin.major, plugin.minor, plugin.inode});
    const RequesterView borrowed = requesterFor(foreign, w);
    EXPECT_EQ(borrowed.role, QStringLiteral("unidentified"));
    EXPECT_FALSE(borrowed.identified);
    EXPECT_EQ(borrowed.path, bin(QStringLiteral("worker")));
    ExeFacts replaced = worker;
    replaced.code.last().inode += 1;
    EXPECT_EQ(requesterFor(replaced, w).role, QStringLiteral("unidentified"));
    ExeFacts elsewhere       = worker;
    elsewhere.sameNamespaces = false;
    EXPECT_EQ(requesterFor(elsewhere, w).role, QStringLiteral("unidentified"));
    ExeFacts unread  = worker;
    unread.codeKnown = false;
    EXPECT_EQ(requesterFor(unread, w).role, QStringLiteral("unidentified"));
}

TEST(PrompterIdentity, MapsAndStatusParsing) {
    bool                     ok   = false;
    const QList<CodeMapping> code = executableMappings("55d4a0e00000-55d4a0e02000 r--p 00000000 00:1f 1234                       /usr/bin/sleep\n"
                                                       "55d4a0e02000-55d4a0e06000 r-xp 00002000 00:1f 1234                       /usr/bin/sleep\n"
                                                       "7f00a0000000-7f00a0028000 r-xp 00028000 fd:01 99                         /usr/lib/libc.so.6\n"
                                                       "7f00a0100000-7f00a0128000 r-xp 00028000 00:2a 99                         /usr/lib/libc.so.6\n"
                                                       "7f00a1000000-7f00a1001000 r-xp 00000000 00:00 0 \n"
                                                       "7f00a2000000-7f00a2001000 r-xp 00000000 00:1f 7                          /home/u/my lib.so (deleted)\n"
                                                       "7f00a3000000-7f00a3001000 rw-p 00000000 00:1f 8                          /usr/lib/data.bin\n"
                                                       "7ffd0a000000-7ffd0a002000 r-xp 00000000 00:00 0                          [vdso]\n",
                                                       &ok);
    EXPECT_TRUE(ok);
    ASSERT_EQ(code.size(), 4); // the same path under another device is another mapping
    EXPECT_EQ(code.at(0), (CodeMapping{QStringLiteral("/usr/bin/sleep"), 0, 0x1f, 1234}));
    EXPECT_EQ(code.at(1), (CodeMapping{QStringLiteral("/usr/lib/libc.so.6"), 0xfd, 1, 99}));
    EXPECT_EQ(code.at(2), (CodeMapping{QStringLiteral("/usr/lib/libc.so.6"), 0, 0x2a, 99}));
    EXPECT_EQ(code.at(3).path, QStringLiteral("/home/u/my lib.so (deleted)"));
    executableMappings("garbage\n", &ok);
    EXPECT_FALSE(ok);
    executableMappings("7f00a0000000-7f00a0028000 r-xp 00028000 zz:01 99 /usr/lib/libc.so.6\n", &ok);
    EXPECT_FALSE(ok);
    const auto devices = mountDevices("22 1 0:21 / /proc rw - proc proc rw\n91 61 254:1 / / rw - btrfs /dev/mapper/root rw,subvol=/@\nbad line\n");
    EXPECT_EQ(devices.value(91), (QPair<quint32, quint32>{254, 1}));
    EXPECT_EQ(devices.value(22), (QPair<quint32, quint32>{0, 21}));
    EXPECT_EQ(devices.size(), 2);
    EXPECT_EQ(tracerPid("Name:\tsleep\nTracerPid:\t0\n"), 0);
    EXPECT_EQ(tracerPid("TracerPid:\t4242\n"), 4242);
    EXPECT_EQ(tracerPid("Name:\tsleep\n"), -1);
    EXPECT_EQ(tracerPid("TracerPid:\tx\n"), -1);
    // gcr-ssh-agent asks on behalf of ssh (security review of step 9a, NIT-4).
    bool ssh = false;
    for (const KnownCaller& k : knownCallers())
        ssh = ssh || (k.path == QLatin1String("/usr/lib/gcr-ssh-agent") && k.role == QLatin1String("ssh"));
    EXPECT_TRUE(ssh);
}

TEST_F(PrompterTrust, EveryFailureIsUnidentified) {
    entry(QStringLiteral("org.example.Editor.desktop"), "editor");
    ExeFacts gone = facts(bin(QStringLiteral("editor")));
    gone.alive    = false;
    EXPECT_EQ(requesterFor(gone, where()).role, QStringLiteral("unidentified"));
    ExeFacts other = facts(bin(QStringLiteral("editor")));
    other.sameUser = false;
    EXPECT_EQ(requesterFor(other, where()).role, QStringLiteral("unidentified"));
    ExeFacts nothing;
    EXPECT_EQ(requesterFor(nothing, where()).path, QString());
    // The name now leads to another file than the one the process runs (replaced since it started).
    ExeFacts replaced = facts(bin(QStringLiteral("editor")));
    replaced.file     = fileIdOf(bin(QStringLiteral("python9")));
    EXPECT_EQ(requesterFor(replaced, where()).role, QStringLiteral("unidentified"));
    // An executable the user could have written (here: group-writable directory).
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr/bin")).constData(), 0775), 0);
    const RequesterView home = requesterFor(facts(bin(QStringLiteral("editor"))), where());
    EXPECT_EQ(home.role, QStringLiteral("unidentified"));
    EXPECT_EQ(home.path, bin(QStringLiteral("editor"))); // shown, in the secondary style
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr/bin")).constData(), 0755), 0);
    // A path with a newline and a direction override is shown flattened.
    ExeFacts weird = facts(QStringLiteral("/home/u/Login") + QChar(0x202E) + QStringLiteral("\nKeychain"));
    EXPECT_EQ(requesterFor(weird, where()).path, QStringLiteral("/home/u/Login Keychain"));
}

TEST(PrompterIdentity, AMappingIsComparedWithItsFileAndEveryMappingIsRead) {
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString file = dir.path() + QStringLiteral("/code.bin");
    writeFile(file, QByteArray(4096, 'x'), 0644);
    const int fd = ::open(QFile::encodeName(file).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(fd, 0);
    const long page = ::sysconf(_SC_PAGESIZE);
    // Many separate read-only mappings of a system file (guard gaps keep them apart), then the file mapped executable.
    const int sys = ::open("/usr/lib/libc.so.6", O_RDONLY | O_CLOEXEC);
    char*     base = static_cast<char*>(::mmap(nullptr, page * 2 * 6000, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    ASSERT_NE(base, MAP_FAILED);
    if (sys >= 0) {
        for (int i = 0; i < 6000; ++i)
            ::mmap(base + i * 2 * page, page, PROT_READ, MAP_PRIVATE | MAP_FIXED, sys, 0);
    }
    void* code = ::mmap(nullptr, page, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    if (code == MAP_FAILED) {
        ::munmap(base, page * 2 * 6000);
        GTEST_SKIP() << "the temporary directory does not allow executable mappings";
    }
    const int self = pidfdOpen(::getpid());
    ASSERT_GE(self, 0);
    const ExeFacts facts = exeFactsOfPidfd(self);
    ::close(self);
    EXPECT_TRUE(facts.codeKnown);
    EXPECT_TRUE(facts.sameNamespaces);
    const CodeMapping expected = fileMapping(file, selfMountDevices());
    ASSERT_NE(expected.inode, 0u);
    EXPECT_TRUE(facts.code.contains(expected)); // maps' device and inode are the file's, read through statx and mountinfo
    ::munmap(code, page);
    ::munmap(base, page * 2 * 6000);
    ::close(fd);
    if (sys >= 0)
        ::close(sys);
}

TEST(PrompterIdentity, AFileBindMountedOverATrustedPathInAnotherNamespaceIsSeen) {
    // A child in a user and mount namespace of its own maps a file of its own under /usr/lib/libc.so.6's path (the
    // counter-review's case, MINOR-C). The bridge sees other namespaces, and a mapping that is not the path's file.
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString fake = dir.path() + QStringLiteral("/fake.so");
    writeFile(fake, QByteArray(4096, 'y'), 0644);
    int ready[2];
    ASSERT_EQ(::pipe(ready), 0);
    const uid_t uid = ::getuid();
    const gid_t gid = ::getgid();
    const pid_t child = ::fork();
    if (child == 0) {
        ::close(ready[0]);
        auto put = [](const char* path, const std::string& text) {
            const int f = ::open(path, O_WRONLY);
            const bool ok = f >= 0 && ::write(f, text.data(), text.size()) == static_cast<ssize_t>(text.size());
            if (f >= 0)
                ::close(f);
            return ok;
        };
        if (::unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0 || !put("/proc/self/setgroups", "deny")
            || !put("/proc/self/uid_map", "0 " + std::to_string(uid) + " 1") || !put("/proc/self/gid_map", "0 " + std::to_string(gid) + " 1")
            || ::mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr) != 0
            || ::mount(QFile::encodeName(fake).constData(), "/usr/lib/libc.so.6", nullptr, MS_BIND, nullptr) != 0)
            ::_exit(3);
        const int f = ::open("/usr/lib/libc.so.6", O_RDONLY);
        if (f < 0 || ::mmap(nullptr, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, f, 0) == MAP_FAILED)
            ::_exit(4);
        (void)!::write(ready[1], "r", 1);
        ::pause();
        ::_exit(0);
    }
    ASSERT_GT(child, 0);
    ::close(ready[1]);
    char       byte  = 0;
    const bool up    = ::read(ready[0], &byte, 1) == 1;
    ::close(ready[0]);
    if (!up) {
        int status = 0;
        ::waitpid(child, &status, 0);
        GTEST_SKIP() << "no user and mount namespace here (child exit " << WEXITSTATUS(status) << ")";
    }
    const int pidfd = pidfdOpen(child);
    ASSERT_GE(pidfd, 0);
    const ExeFacts facts = exeFactsOfPidfd(pidfd);
    ::close(pidfd);
    ::kill(child, SIGKILL);
    ::waitpid(child, nullptr, 0);
    EXPECT_TRUE(facts.alive);
    EXPECT_FALSE(facts.sameNamespaces);
    const auto     devices = selfMountDevices();
    const auto     real    = fileMapping(QStringLiteral("/usr/lib/libc.so.6"), devices);
    const auto     forged  = fileMapping(fake, devices);
    bool           seen    = false;
    for (const CodeMapping& m : facts.code) {
        if (m.path == QLatin1String("/usr/lib/libc.so.6") && m.inode == forged.inode && m.major == forged.major && m.minor == forged.minor) {
            seen = true;
            EXPECT_FALSE(m == real); // the trusted path names another file than the one mapped
        }
    }
    EXPECT_TRUE(seen) << "the bind-mounted file was not found among the child's mappings";
}

// The integrator's review of PR #95 (NIT): a known caller is named only in the bridge's own mount and user namespaces, as
// an app: a real child in namespaces of its own running a known program reads as unidentified.
TEST(PrompterIdentity, AKnownCallerInNamespacesOfItsOwnIsUnidentifiedSaveTheDiskHelper) {
    if (!rootOwnsSystemFiles())
        GTEST_SKIP() << "/usr/bin is not root's here";
    int ready[2];
    ASSERT_EQ(::pipe2(ready, O_CLOEXEC), 0);
    const uid_t uid   = ::getuid();
    const gid_t gid   = ::getgid();
    const pid_t child = ::fork();
    if (child == 0) {
        ::close(ready[0]);
        auto put = [](const char* path, const std::string& text) {
            const int  f  = ::open(path, O_WRONLY);
            const bool ok = f >= 0 && ::write(f, text.data(), text.size()) == static_cast<ssize_t>(text.size());
            if (f >= 0)
                ::close(f);
            return ok;
        };
        if (::unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0 || !put("/proc/self/setgroups", "deny")
            || !put("/proc/self/uid_map", "0 " + std::to_string(uid) + " 1") || !put("/proc/self/gid_map", "0 " + std::to_string(gid) + " 1"))
            ::_exit(3);
        (void)!::write(ready[1], "r", 1); // the pipe closes at the exec (O_CLOEXEC)
        ::execl("/usr/bin/sleep", "sleep", "5", static_cast<char*>(nullptr));
        ::_exit(127);
    }
    ASSERT_GT(child, 0);
    ::close(ready[1]);
    char       byte = 0;
    const bool up   = ::read(ready[0], &byte, 1) == 1;
    ::close(ready[0]);
    if (!up) {
        int status = 0;
        ::waitpid(child, &status, 0);
        GTEST_SKIP() << "no user and mount namespace here (child exit " << WEXITSTATUS(status) << ")";
    }
    const int pidfd = pidfdOpen(child);
    ASSERT_GE(pidfd, 0);
    ExeFacts facts;
    for (int i = 0; i < 300 && facts.path != QLatin1String("/usr/bin/sleep"); ++i) {
        facts = exeFactsOfPidfd(pidfd);
        ::usleep(10000);
    }
    ::close(pidfd);
    ::kill(child, SIGKILL);
    ::waitpid(child, nullptr, 0);
    ASSERT_EQ(facts.path, QStringLiteral("/usr/bin/sleep"));
    EXPECT_TRUE(facts.alive);
    EXPECT_FALSE(facts.sameNamespaces);
    facts.sameUser = true;
    facts.traced   = false; // whatever the child's status said: only the namespaces differ
    Where w;
    w.applications = QStringLiteral("/nonexistent");
    w.known        = {{QStringLiteral("/usr/bin/sleep"), QStringLiteral("keyring")}};
    const RequesterView r = requesterFor(facts, w);
    EXPECT_EQ(r.role, QStringLiteral("unidentified"));
    EXPECT_EQ(r.path, QStringLiteral("/usr/bin/sleep"));
    // The disk helper is named there all the same (decision 9-26, amended: udiskie's unit runs it in namespaces of its own).
    Where disk = w;
    disk.known = {{QStringLiteral("/usr/bin/sleep"), QStringLiteral("disk")}};
    const RequesterView d = requesterFor(facts, disk);
    EXPECT_EQ(d.role, QStringLiteral("disk"));
    EXPECT_TRUE(d.identified);
    EXPECT_TRUE(d.onBehalf);
    facts.sameNamespaces = true;
    EXPECT_EQ(requesterFor(facts, w).role, QStringLiteral("keyring")) << "the same facts in the bridge's namespaces";
}

// The integrator's review of PR #95: a process that ends after the reads and before the pidfd is checked again reads as
// unidentified (its PID may already be another process's), whatever the reads found.
TEST(PrompterIdentity, AProcessThatEndsBeforeTheRecheckIsForgotten) {
    const pid_t child = ::fork();
    if (child == 0) {
        ::execl("/usr/bin/sleep", "sleep", "5", static_cast<char*>(nullptr));
        ::_exit(127);
    }
    ASSERT_GT(child, 0);
    const int pidfd = pidfdOpen(child);
    if (pidfd < 0) {
        ::kill(child, SIGKILL);
        ::waitpid(child, nullptr, 0);
        GTEST_SKIP() << "no pidfd_open on this kernel";
    }
    ExeFacts before;
    for (int i = 0; i < 300 && before.path != QLatin1String("/usr/bin/sleep"); ++i) {
        before = exeFactsOfPidfd(pidfd);
        ::usleep(10000);
    }
    ASSERT_EQ(before.path, QStringLiteral("/usr/bin/sleep"));
    ASSERT_TRUE(before.alive);
    bool           ended = false;
    const ExeFacts after = exeFactsOfPidfd(pidfd, true, [&] {
        ::kill(child, SIGKILL);
        ::waitpid(child, nullptr, 0);
        ended = true;
    });
    ::close(pidfd);
    ASSERT_TRUE(ended);
    EXPECT_FALSE(after.alive);
    EXPECT_TRUE(after.path.isEmpty());
    EXPECT_FALSE(after.file.valid);
    EXPECT_TRUE(after.code.isEmpty());
    EXPECT_FALSE(after.codeKnown);
    EXPECT_FALSE(after.sameNamespaces);
    EXPECT_TRUE(after.traced);
    ExeFacts asKnown = after;
    asKnown.sameUser = true;
    Where w;
    w.known = {{QStringLiteral("/usr/bin/sleep"), QStringLiteral("gnupg")}};
    EXPECT_EQ(requesterFor(asKnown, w).role, QStringLiteral("unidentified"));
}

TEST(PrompterIdentity, ProcessesThroughTheirPidfd) {
    // This process: its own executable, alive.
    const int self = pidfdOpen(::getpid());
    if (self < 0)
        GTEST_SKIP() << "no pidfd_open on this kernel";
    char          buffer[4096];
    const ssize_t n = ::readlink("/proc/self/exe", buffer, sizeof buffer - 1);
    ASSERT_GT(n, 0);
    const ExeFacts mine = exeFactsOfPidfd(self);
    ::close(self);
    EXPECT_TRUE(mine.alive);
    EXPECT_EQ(mine.path, QFile::decodeName(QByteArray(buffer, n)));
    EXPECT_TRUE(mine.file.valid);
    // A child running a system program, then gone: once it has exited, nothing about it is reported.
    const pid_t child = ::fork();
    if (child == 0) {
        ::execl("/usr/bin/sleep", "sleep", "5", static_cast<char*>(nullptr));
        ::_exit(127);
    }
    ASSERT_GT(child, 0);
    const int pidfd = pidfdOpen(child);
    ASSERT_GE(pidfd, 0);
    // Until the child's exec has finished: the kernel names the new program before it maps it, and the old address space
    // goes in between (slow for a parent built with ASan), so the name alone does not mean the mappings are there yet.
    const CodeMapping sleepFile = fileMapping(QStringLiteral("/usr/bin/sleep"), selfMountDevices());
    ExeFacts          running;
    for (int i = 0; i < 300 && !(running.path == QLatin1String("/usr/bin/sleep") && running.code.contains(sleepFile) && running.code.size() >= 2); ++i) {
        running = exeFactsOfPidfd(pidfd);
        ::usleep(10000);
    }
    EXPECT_EQ(running.path, QStringLiteral("/usr/bin/sleep"));
    EXPECT_TRUE(running.alive);
    EXPECT_FALSE(running.traced);
    EXPECT_TRUE(running.codeKnown);
    EXPECT_TRUE(running.sameNamespaces);
    EXPECT_TRUE(running.code.contains(sleepFile));
    EXPECT_GE(running.code.size(), 2); // the program and at least the C library
    if (rootOwnsSystemFiles()) {
        running.sameUser = true;
        Where w;
        w.applications = QStringLiteral("/nonexistent");
        EXPECT_EQ(requesterFor(running, w).role, QStringLiteral("unidentified")); // trusted, but no entry runs it
        w.known = {{QStringLiteral("/usr/bin/sleep"), QStringLiteral("gnupg")}};
        EXPECT_EQ(requesterFor(running, w).role, QStringLiteral("gnupg"));
    }
    ::kill(child, SIGKILL);
    ::waitpid(child, nullptr, 0);
    const ExeFacts gone = exeFactsOfPidfd(pidfd);
    ::close(pidfd);
    EXPECT_FALSE(gone.alive);
    EXPECT_TRUE(gone.path.isEmpty());
    EXPECT_TRUE(gone.code.isEmpty());
    EXPECT_FALSE(gone.sameNamespaces);
    EXPECT_EQ(requesterFor(gone).role, QStringLiteral("unidentified"));
    // A traced child: TracerPid names this process.
    const pid_t traced = ::fork();
    if (traced == 0) {
        if (::ptrace(PTRACE_TRACEME, 0, nullptr, nullptr) != 0)
            ::_exit(126);
        ::execl("/usr/bin/sleep", "sleep", "5", static_cast<char*>(nullptr));
        ::_exit(127);
    }
    ASSERT_GT(traced, 0);
    int status = 0;
    ASSERT_EQ(::waitpid(traced, &status, 0), traced); // stopped at its exec, or exited when ptrace is not allowed
    if (WIFEXITED(status)) {
        std::fprintf(stderr, "note: ptrace is not allowed here; the traced case was not run\n");
        return;
    }
    const int tracedFd = pidfdOpen(traced);
    ASSERT_GE(tracedFd, 0);
    const ExeFacts underTrace = exeFactsOfPidfd(tracedFd);
    ::close(tracedFd);
    EXPECT_TRUE(underTrace.alive);
    EXPECT_TRUE(underTrace.traced);
    ExeFacts asKnown = underTrace;
    asKnown.sameUser = true;
    Where w;
    w.known = {{QStringLiteral("/usr/bin/sleep"), QStringLiteral("gnupg")}};
    EXPECT_EQ(requesterFor(asKnown, w).role, QStringLiteral("unidentified"));
    ::kill(traced, SIGKILL);
    ::waitpid(traced, nullptr, 0);
}

// --- the bus filter --------------------------------------------------------------------------------------------------------

namespace {
    GVariant* performBody(std::initializer_list<std::pair<const char*, GVariant*>> properties) {
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
        for (const auto& [name, value] : properties)
            g_variant_builder_add(&b, "{sv}", name, value);
        return g_variant_ref_sink(g_variant_new("(osa{sv}s)", "/org/gnome/keyring/Prompt/p1", "password", &b, "[sx-aes-1]\npublic=abc"));
    }

    GVariant* property(GVariant* body, const char* name) {
        GVariant* dict  = g_variant_get_child_value(body, 2);
        GVariant* value = g_variant_lookup_value(dict, name, nullptr);
        g_variant_unref(dict);
        return value;
    }
} // namespace

TEST(PrompterFilter, OnlyGcrPropertiesAndTheBusSender) {
    const std::string longText(kMaxPropertyBytes + 1, 'x');
    GVariant*         body = performBody({
        {"title", g_variant_new_string("Unlock")},
        {"choice-label", g_variant_new_string("Remember")},
        {"password-new", g_variant_new_boolean(TRUE)},
        {"grassfield-caller", g_variant_new_string(":1.666")}, // a caller cannot choose who it is
        {"bogus", g_variant_new_string("x")},
        {"choice-chosen", g_variant_new_string("yes")},          // wrong type
        {"password-strength", g_variant_new_int32(5)},           // the prompter's, not the caller's
        {"message", g_variant_new_string(longText.c_str())},     // too long
    });
    GVariant* clean = g_variant_ref_sink(sanitizePerformPrompt(body, ":1.42"));
    ASSERT_NE(clean, nullptr);
    EXPECT_STREQ(g_variant_get_type_string(clean), "(osa{sv}s)");
    GVariant* dict = g_variant_get_child_value(clean, 2);
    EXPECT_EQ(g_variant_n_children(dict), 4u); // title, choice-label, password-new, grassfield-caller
    g_variant_unref(dict);
    GVariant* caller = property(clean, "grassfield-caller");
    ASSERT_NE(caller, nullptr);
    EXPECT_STREQ(g_variant_get_string(caller, nullptr), ":1.42");
    g_variant_unref(caller);
    for (const char* dropped : {"bogus", "choice-chosen", "password-strength", "message"})
        EXPECT_EQ(property(clean, dropped), nullptr) << dropped;
    // The callback path, the type and the exchange are kept.
    GVariant* exchange = g_variant_get_child_value(clean, 3);
    EXPECT_STREQ(g_variant_get_string(exchange, nullptr), "[sx-aes-1]\npublic=abc");
    g_variant_unref(exchange);
    g_variant_unref(clean);
    g_variant_unref(body);
    // Another shape: nothing.
    GVariant* wrong = g_variant_ref_sink(g_variant_new("(os)", "/x", "password"));
    EXPECT_EQ(sanitizePerformPrompt(wrong, ":1.42"), nullptr);
    g_variant_unref(wrong);
    // No sender: an empty caller, which the bridge shows as unidentified.
    GVariant* anon  = performBody({});
    GVariant* anon2 = g_variant_ref_sink(sanitizePerformPrompt(anon, nullptr));
    GVariant* none  = property(anon2, "grassfield-caller");
    EXPECT_STREQ(g_variant_get_string(none, nullptr), "");
    g_variant_unref(none);
    g_variant_unref(anon2);
    g_variant_unref(anon);
}

namespace {
    GDBusMessage* call(const char* path, const char* member, GVariant* body, const char* sender = ":1.7", const char* iface = kPrompterIface) {
        GDBusMessage* m = g_dbus_message_new_method_call(kPrompterName, path, iface, member);
        g_dbus_message_set_sender(m, sender);
        g_dbus_message_set_serial(m, 42);
        if (body)
            g_dbus_message_set_body(m, body);
        g_dbus_message_lock(m);
        return m;
    }

    GDBusMessage* ownerChanged(const char* name, const char* oldOwner, const char* newOwner, const char* sender = "org.freedesktop.DBus") {
        GDBusMessage* m = g_dbus_message_new_signal("/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged");
        g_dbus_message_set_sender(m, sender);
        g_dbus_message_set_body(m, g_variant_new("(sss)", name, oldOwner, newOwner));
        return m;
    }

    std::string errorName(GDBusMessage* reply) {
        return reply && g_dbus_message_get_message_type(reply) == G_DBUS_MESSAGE_TYPE_ERROR ? std::string(g_dbus_message_get_error_name(reply)) : std::string();
    }
} // namespace

TEST(PrompterFilter, MessagesThroughTheFilter) {
    FilterState   book;
    GDBusMessage* reply    = nullptr;
    GVariant*     body     = performBody({{"grassfield-caller", g_variant_new_string(":1.666")}});
    GDBusMessage* perform  = call(kPrompterPath, "PerformPrompt", body);
    GDBusMessage* filtered = filterIncoming(book, ":1.1", perform, &reply);
    ASSERT_NE(filtered, nullptr);
    EXPECT_EQ(reply, nullptr);
    EXPECT_NE(filtered, perform); // a sanitized copy
    GVariant* caller = property(g_dbus_message_get_body(filtered), "grassfield-caller");
    EXPECT_STREQ(g_variant_get_string(caller, nullptr), ":1.7");
    g_variant_unref(caller);
    g_object_unref(filtered);
    // Without an interface field the call is sanitized all the same (whatever GDBus then does with it).
    GDBusMessage* bare = call(kPrompterPath, "PerformPrompt", body, ":1.8", nullptr);
    filtered           = filterIncoming(book, ":1.1", bare, &reply);
    ASSERT_NE(filtered, nullptr);
    EXPECT_NE(filtered, bare);
    caller = property(g_dbus_message_get_body(filtered), "grassfield-caller");
    EXPECT_STREQ(g_variant_get_string(caller, nullptr), ":1.8");
    g_variant_unref(caller);
    g_object_unref(filtered);
    // Other calls and other interfaces pass untouched; outgoing messages are not even looked at by promptFilter.
    GDBusMessage* other = call(kPrompterPath, "Introspect", nullptr, ":1.7", "org.freedesktop.DBus.Introspectable");
    EXPECT_EQ(filterIncoming(book, ":1.1", other, &reply), other);
    g_object_unref(other);
    GDBusMessage* elsewhere = call("/elsewhere", "PerformPrompt", body);
    EXPECT_EQ(filterIncoming(book, ":1.1", elsewhere, &reply), elsewhere);
    g_object_unref(elsewhere);
    FilterState   state;
    GDBusMessage* outgoing = call(kPrompterPath, "PerformPrompt", body);
    EXPECT_EQ(promptFilter(nullptr, outgoing, FALSE, &state), outgoing);
    g_object_unref(outgoing);
    // A PerformPrompt of another shape never reaches gcr: its caller gets InvalidArgs, as a reply to its own call.
    GDBusMessage* malformed = call(kPrompterPath, "PerformPrompt", g_variant_new("(s)", "x"));
    EXPECT_EQ(filterIncoming(book, ":1.1", malformed, &reply), nullptr);
    ASSERT_NE(reply, nullptr);
    EXPECT_EQ(errorName(reply), "org.freedesktop.DBus.Error.InvalidArgs");
    EXPECT_EQ(g_dbus_message_get_reply_serial(reply), 42u);
    EXPECT_STREQ(g_dbus_message_get_destination(reply), ":1.7");
    g_object_unref(reply);
    g_variant_unref(body);
}

TEST(PrompterFilter, EachCallerHoldsAtMostItsShareOfPrompts) {
    CallerBook book(3);
    EXPECT_TRUE(book.begin(":1.1", "/p/1"));
    EXPECT_TRUE(book.begin(":1.1", "/p/2"));
    EXPECT_TRUE(book.begin(":1.1", "/p/2")); // gcr refuses the repeat itself: not counted twice
    EXPECT_TRUE(book.begin(":1.1", "/p/3"));
    EXPECT_EQ(book.open(":1.1"), 3);
    EXPECT_FALSE(book.begin(":1.1", "/p/4"));
    EXPECT_TRUE(book.begin(":1.2", "/p/1")); // another caller keeps its own share
    book.stop(":1.1", "/p/9");                // a stop for nothing frees nothing
    EXPECT_FALSE(book.begin(":1.1", "/p/4"));
    book.stop(":1.1", "/p/1");
    EXPECT_TRUE(book.begin(":1.1", "/p/4"));
    book.gone(":1.1");
    EXPECT_EQ(book.open(":1.1"), 0);
    EXPECT_EQ(book.callers(), 1);
    book.stop(":1.2", "/p/1");
    EXPECT_EQ(book.callers(), 0); // nothing kept for a caller with nothing open
}

namespace {
    // gcr's own outgoing call to a caller's callback object.
    GDBusMessage* toCallback(const char* member, const char* destination, const char* path, guint32 serial) {
        GDBusMessage* m = g_dbus_message_new_method_call(destination, path, "org.gnome.keyring.internal.Prompter.Callback", member);
        g_dbus_message_set_serial(m, serial);
        return m;
    }
    GDBusMessage* answerTo(guint32 serial, const char* sender, bool error) {
        GDBusMessage* call = g_dbus_message_new_method_call(":1.1", "/x", "x.y", "Z");
        g_dbus_message_set_serial(call, serial);
        g_dbus_message_set_sender(call, ":1.1");
        GDBusMessage* m = error ? g_dbus_message_new_method_error_literal(call, "org.freedesktop.DBus.Error.UnknownMethod", "no object")
                                : g_dbus_message_new_method_reply(call);
        g_dbus_message_set_sender(m, sender);
        g_object_unref(call);
        return m;
    }
    void begin(FilterState& state, int n, const char* sender = ":1.7", const char* iface = kPrompterIface, GDBusMessage** last = nullptr) {
        for (int i = 0; i < n; ++i) {
            const std::string path = "/org/gnome/keyring/Prompt/p" + std::to_string(i);
            GDBusMessage*     reply = nullptr;
            GDBusMessage*     out   = filterIncoming(state, ":1.1", call(kPrompterPath, "BeginPrompting", g_variant_new("(o)", path.c_str()), sender, iface), &reply);
            if (out)
                g_object_unref(out);
            if (last)
                *last = reply;
            else if (reply)
                g_object_unref(reply);
        }
    }
} // namespace

TEST(PrompterFilter, BeginPromptingOverTheShareIsRefusedUntilGcrEndsAPrompt) {
    FilterState   state;
    GDBusMessage* reply = nullptr;
    begin(state, limits::kPromptsPerCaller);
    EXPECT_EQ(state.book.open(":1.7"), limits::kPromptsPerCaller);
    GDBusMessage* over = call(kPrompterPath, "BeginPrompting", g_variant_new("(o)", "/org/gnome/keyring/Prompt/over"));
    EXPECT_EQ(filterIncoming(state, ":1.1", over, &reply), nullptr);
    EXPECT_EQ(errorName(reply), "org.freedesktop.DBus.Error.LimitsExceeded");
    EXPECT_EQ(g_dbus_message_get_reply_serial(reply), 42u);
    g_object_unref(reply);
    // Another connection is not affected.
    begin(state, 1, ":1.9");
    EXPECT_EQ(state.book.open(":1.9"), 1);
    // A StopPrompting frees nothing by itself, with or without the interface (counter-review MINOR-B): gcr's own
    // PromptDone, sent when it ends the prompt, does.
    for (const char* iface : {kPrompterIface, static_cast<const char*>(nullptr)}) {
        GDBusMessage* stop = call(kPrompterPath, "StopPrompting", g_variant_new("(o)", "/org/gnome/keyring/Prompt/p0"), ":1.7", iface);
        EXPECT_EQ(filterIncoming(state, ":1.1", stop, &reply), stop);
        g_object_unref(stop);
    }
    EXPECT_EQ(state.book.open(":1.7"), limits::kPromptsPerCaller);
    GDBusMessage* done = toCallback("PromptDone", ":1.7", "/org/gnome/keyring/Prompt/p0", 100);
    filterOutgoing(state, done);
    g_object_unref(done);
    EXPECT_EQ(state.book.open(":1.7"), limits::kPromptsPerCaller - 1);
    // A failed PromptReady (a caller without the callback object: gcr drops the prompt without PromptDone) frees it;
    // a successful one, or an error from anyone else than the caller, does not.
    GDBusMessage* ready1 = toCallback("PromptReady", ":1.7", "/org/gnome/keyring/Prompt/p1", 101);
    GDBusMessage* ready2 = toCallback("PromptReady", ":1.7", "/org/gnome/keyring/Prompt/p2", 102);
    GDBusMessage* ready3 = toCallback("PromptReady", ":1.7", "/org/gnome/keyring/Prompt/p3", 103);
    filterOutgoing(state, ready1);
    filterOutgoing(state, ready2);
    filterOutgoing(state, ready3);
    for (GDBusMessage* m : {ready1, ready2, ready3})
        g_object_unref(m);
    for (GDBusMessage* m : {answerTo(101, ":1.7", true), answerTo(102, ":1.7", false), answerTo(103, ":1.9", true)}) {
        EXPECT_EQ(filterIncoming(state, ":1.1", m, &reply), m);
        g_object_unref(m);
    }
    EXPECT_EQ(state.book.open(":1.7"), limits::kPromptsPerCaller - 2);
    EXPECT_TRUE(state.readyCalls.isEmpty());
    // An interface-less BeginPrompting passes untouched and counts nothing: GDBus refuses it itself (MINOR-B).
    begin(state, 3, ":1.8", nullptr);
    EXPECT_EQ(state.book.open(":1.8"), 0);
    // A NameOwnerChanged that does not come from the bus daemon changes nothing; the bus's own one forgets the caller.
    GDBusMessage* forged = ownerChanged(":1.7", ":1.7", "", ":1.9");
    EXPECT_EQ(filterIncoming(state, ":1.1", forged, &reply), forged);
    g_object_unref(forged);
    EXPECT_EQ(state.book.open(":1.7"), limits::kPromptsPerCaller - 2);
    GDBusMessage* acquired = ownerChanged("org.example.Name", "", ":1.7"); // a well-known name changing hands: ignored
    EXPECT_EQ(filterIncoming(state, ":1.1", acquired, &reply), acquired);
    g_object_unref(acquired);
    EXPECT_EQ(state.book.open(":1.7"), limits::kPromptsPerCaller - 2);
    GDBusMessage* left = ownerChanged(":1.7", ":1.7", "");
    EXPECT_EQ(filterIncoming(state, ":1.1", left, &reply), left);
    g_object_unref(left);
    EXPECT_EQ(state.book.open(":1.7"), 0);
    EXPECT_EQ(state.book.open(":1.9"), 1);
}

TEST(PrompterFilter, UnansweredPromptReadyCallsGoWithTheirPrompt) {
    // An entry of a PromptReady that is never answered (gcr cancels it itself when it ends the prompt) goes with gcr's
    // PromptDone for the same callback, with a newer PromptReady for it, or with its caller (opus final check of step 9a,
    // NIT): a caller cycling prompts it never answers cannot fill the table and push out other callers' entries.
    FilterState state;
    auto        out = [&state](GDBusMessage* m) {
        filterOutgoing(state, m);
        g_object_unref(m);
    };
    out(toCallback("PromptReady", ":1.7", "/org/gnome/keyring/Prompt/p1", 201));
    out(toCallback("PromptReady", ":1.7", "/org/gnome/keyring/Prompt/p2", 202));
    out(toCallback("PromptReady", ":1.8", "/org/gnome/keyring/Prompt/p1", 203));
    EXPECT_EQ(state.readyCalls.size(), 3);
    out(toCallback("PromptDone", ":1.7", "/org/gnome/keyring/Prompt/p1", 204));
    EXPECT_FALSE(state.readyCalls.contains(201));
    out(toCallback("PromptReady", ":1.7", "/org/gnome/keyring/Prompt/p2", 205));
    EXPECT_FALSE(state.readyCalls.contains(202));
    EXPECT_TRUE(state.readyCalls.contains(205));
    GDBusMessage* reply = nullptr;
    GDBusMessage* left  = ownerChanged(":1.7", ":1.7", "");
    EXPECT_EQ(filterIncoming(state, ":1.1", left, &reply), left);
    g_object_unref(left);
    EXPECT_EQ(state.readyCalls.keys(), QList<quint32>{203});
    for (quint32 i = 0; i < 5000; ++i) {
        out(toCallback("PromptReady", ":1.9", "/org/gnome/keyring/Prompt/cycle", 1000 + 2 * i));
        out(toCallback("PromptDone", ":1.9", "/org/gnome/keyring/Prompt/cycle", 1001 + 2 * i));
    }
    EXPECT_EQ(state.readyCalls.keys(), QList<quint32>{203}); // never filled, never cleared
    EXPECT_EQ(state.readyBySlot.size(), 1);
}

TEST(PrompterFilter, ThePrompterNameLeavingTheBridgeClearsEveryCount) {
    // gcr's clients forget their prompts without stopping them when the prompter's name goes (counter-review MINOR-A).
    FilterState state;
    begin(state, limits::kPromptsPerCaller, ":1.7");
    begin(state, 2, ":1.9");
    GDBusMessage* reply = nullptr;
    // Another owner's change, or the name coming to the bridge, clears nothing.
    for (GDBusMessage* m : {ownerChanged(kPrompterName, ":1.5", ""), ownerChanged(kPrompterName, "", ":1.1")}) {
        EXPECT_EQ(filterIncoming(state, ":1.1", m, &reply), m);
        g_object_unref(m);
    }
    EXPECT_EQ(state.book.open(":1.7"), limits::kPromptsPerCaller);
    // The name leaving the bridge (released, or passed to the next in line) clears every count.
    GDBusMessage* released = ownerChanged(kPrompterName, ":1.1", ":1.5");
    EXPECT_EQ(filterIncoming(state, ":1.1", released, &reply), released);
    g_object_unref(released);
    EXPECT_EQ(state.book.callers(), 0);
    begin(state, limits::kPromptsPerCaller, ":1.7", kPrompterIface, &reply);
    EXPECT_EQ(reply, nullptr); // the long-lived caller is served again
}

// --- the GcrPrompt object ---------------------------------------------------------------------------------------------------

namespace {
    struct FakeSink : PromptSink {
        int        submits = 0, withdrawals = 0, forgotten = 0;
        GfPrompt*  last    = nullptr;
        PromptKind kind    = PromptKind::None;
        void       submit(GfPrompt* prompt) override {
            ++submits;
            last = prompt;
            kind = pendingKind(prompt);
        }
        void withdraw(GfPrompt*) override {
            ++withdrawals;
        }
        void forget(GfPrompt*) override {
            ++forgotten;
        }
    };

    struct Outcome {
        bool        done = false;
        bool        hasPassword = false;
        std::string password;
        int         reply = -1;
        int         errorCode = 0;
    };

    void onPassword(GObject* source, GAsyncResult* result, gpointer data) {
        auto*        out   = static_cast<Outcome*>(data);
        GError*      error = nullptr;
        const gchar* pw    = gcr_prompt_password_finish(GCR_PROMPT(source), result, &error);
        out->done          = true;
        out->hasPassword   = pw != nullptr;
        if (pw)
            out->password = pw;
        out->errorCode = error ? error->code : 0;
        g_clear_error(&error);
    }

    void onConfirm(GObject* source, GAsyncResult* result, gpointer data) {
        auto*   out   = static_cast<Outcome*>(data);
        GError* error = nullptr;
        out->reply    = gcr_prompt_confirm_finish(GCR_PROMPT(source), result, &error);
        out->done     = true;
        out->errorCode = error ? error->code : 0;
        g_clear_error(&error);
    }

    void countNotify(GObject*, GParamSpec*, gpointer data) {
        ++*static_cast<int*>(data);
    }
} // namespace

TEST(PrompterPrompt, PasswordAnsweredThenWiped) {
    FakeSink  sink;
    GfPrompt* prompt = newPrompt(&sink);
    g_object_set(prompt, "title", "Unlock", "choice-label", "Remember", "password-new", TRUE, nullptr);
    int strength = 0, chosen = 0;
    g_signal_connect(prompt, "notify::password-strength", G_CALLBACK(countNotify), &strength);
    g_signal_connect(prompt, "notify::choice-chosen", G_CALLBACK(countNotify), &chosen);
    Outcome out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &out);
    EXPECT_EQ(sink.submits, 1);
    EXPECT_EQ(sink.kind, PromptKind::Password);
    const PromptFields f = promptFields(prompt);
    EXPECT_EQ(f.title, QStringLiteral("Unlock"));
    EXPECT_TRUE(f.passwordNew);
    answerConfirm(prompt, true, -1); // the wrong kind: nothing happens
    spin();
    EXPECT_FALSE(out.done);
    answerPassword(prompt, gcr_secure_memory_strdup("s3cret"), 1);
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    ASSERT_TRUE(out.done);
    EXPECT_TRUE(out.hasPassword);
    EXPECT_EQ(out.password, "s3cret");
    EXPECT_EQ(strength, 1);
    EXPECT_EQ(chosen, 1);
    gint     reportedStrength = -1;
    gboolean reportedChoice   = FALSE;
    g_object_get(prompt, "password-strength", &reportedStrength, "choice-chosen", &reportedChoice, nullptr);
    EXPECT_EQ(reportedStrength, 1);
    EXPECT_TRUE(reportedChoice);
    // Wiped in a later turn (libgcr has encrypted it by then).
    spin();
    EXPECT_FALSE(holdsPassword(prompt));
    EXPECT_EQ(pendingKind(prompt), PromptKind::None);
    g_object_run_dispose(G_OBJECT(prompt));
    EXPECT_EQ(sink.forgotten, 1);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, EmptyPasswordHasStrengthZeroAndCancelIsNoPassword) {
    FakeSink  sink;
    GfPrompt* prompt = newPrompt(&sink);
    Outcome   out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &out);
    answerPassword(prompt, gcr_secure_memory_strdup(""), 1); // no choice was shown: "choice-chosen" stays
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    EXPECT_TRUE(out.hasPassword);
    EXPECT_EQ(out.password, "");
    gint     strength = -1;
    gboolean chosen   = TRUE;
    g_object_get(prompt, "password-strength", &strength, "choice-chosen", &chosen, nullptr);
    EXPECT_EQ(strength, 0);
    EXPECT_FALSE(chosen);
    Outcome cancelled;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &cancelled);
    answerPassword(prompt, nullptr, -1); // the user's Cancel
    for (int i = 0; i < 100 && !cancelled.done; ++i)
        spin(1);
    EXPECT_TRUE(cancelled.done);
    EXPECT_FALSE(cancelled.hasPassword);
    EXPECT_EQ(cancelled.errorCode, 0);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, ConfirmAnswers) {
    FakeSink  sink;
    GfPrompt* prompt = newPrompt(&sink);
    Outcome   yes;
    gcr_prompt_confirm_async(GCR_PROMPT(prompt), nullptr, onConfirm, &yes);
    EXPECT_EQ(sink.kind, PromptKind::Confirm);
    answerPassword(prompt, gcr_secure_memory_strdup("ignored"), -1); // wrong kind: zeroed and freed, nothing answered
    answerConfirm(prompt, true, -1);
    for (int i = 0; i < 100 && !yes.done; ++i)
        spin(1);
    EXPECT_EQ(yes.reply, GCR_PROMPT_REPLY_CONTINUE);
    Outcome no;
    gcr_prompt_confirm_async(GCR_PROMPT(prompt), nullptr, onConfirm, &no);
    answerConfirm(prompt, false, -1);
    for (int i = 0; i < 100 && !no.done; ++i)
        spin(1);
    EXPECT_EQ(no.reply, GCR_PROMPT_REPLY_CANCEL);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, WithdrawnByTheCallerEndsCancelled) {
    FakeSink      sink;
    GfPrompt*     prompt      = newPrompt(&sink);
    GCancellable* cancellable = g_cancellable_new();
    Outcome       out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), cancellable, onPassword, &out);
    EXPECT_EQ(sink.submits, 1);
    g_cancellable_cancel(cancellable); // gcr's StopPrompting, or the caller leaving the bus
    EXPECT_EQ(sink.withdrawals, 1);
    EXPECT_FALSE(out.done); // never inside the caller's own call
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    EXPECT_TRUE(out.done);
    EXPECT_FALSE(out.hasPassword);
    EXPECT_EQ(out.errorCode, G_IO_ERROR_CANCELLED);
    // An answer that comes after it is not taken.
    answerPassword(prompt, gcr_secure_memory_strdup("late"), -1);
    spin();
    EXPECT_FALSE(holdsPassword(prompt));
    // Already cancelled when asked: never handed to the sink.
    Outcome early;
    gcr_prompt_password_async(GCR_PROMPT(prompt), cancellable, onPassword, &early);
    EXPECT_EQ(sink.submits, 1);
    for (int i = 0; i < 100 && !early.done; ++i)
        spin(1);
    EXPECT_EQ(early.errorCode, G_IO_ERROR_CANCELLED);
    g_object_unref(cancellable);
    // Closed while pending (gcr_prompt_close): withdrawn, cancelled.
    Outcome closed;
    gcr_prompt_confirm_async(GCR_PROMPT(prompt), nullptr, onConfirm, &closed);
    gcr_prompt_close(GCR_PROMPT(prompt));
    EXPECT_EQ(sink.withdrawals, 2);
    for (int i = 0; i < 100 && !closed.done; ++i)
        spin(1);
    EXPECT_EQ(closed.reply, GCR_PROMPT_REPLY_CANCEL);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, NoSinkMeansCancelledAndTheCallerPropertyStaysPrivate) {
    GfPrompt* prompt = newPrompt(nullptr);
    Outcome   out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &out);
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    EXPECT_TRUE(out.done);
    EXPECT_FALSE(out.hasPassword);
    g_object_set(prompt, kCallerProperty, ":1.9", nullptr);
    EXPECT_EQ(promptCaller(prompt), QStringLiteral(":1.9"));
    // Not one of GcrPrompt's properties: libgcr never echoes it back to a caller.
    EXPECT_EQ(g_object_interface_find_property(g_type_default_interface_peek(GCR_TYPE_PROMPT), kCallerProperty), nullptr);
    EXPECT_NE(g_object_class_find_property(G_OBJECT_GET_CLASS(prompt), kCallerProperty), nullptr);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, LaterJobsRunOnceAndNeverAfterTheirOwner) {
    // Work left for a later turn runs once, then its references go; what has not run when its owner goes never runs, its
    // references released (opus re-check of step 9a, NIT: the bridge's idle sources outlived it). Built with ASan, a job
    // running after its owner would write freed memory.
    int  gone  = 0;
    auto watch = [&gone](GfPrompt* prompt) {
        g_object_weak_ref(G_OBJECT(prompt), [](gpointer data, GObject*) { ++*static_cast<int*>(data); }, &gone);
        return prompt;
    };
    struct Owner {
        PromptsLater later;
        int          ran = 0;
    };
    // A sink that schedules more work as its prompt goes.
    struct Rescheduling : PromptSink {
        Owner* owner = nullptr;
        int*   runs  = nullptr;
        void   submit(GfPrompt*) override {}
        void   withdraw(GfPrompt*) override {}
        void   forget(GfPrompt*) override {
            Owner* o = owner;
            int*   r = runs;
            o->later.schedule({}, [o, r](const QList<GfPrompt*>&) {
                ++o->ran;
                ++*r;
            });
        }
    };
    int        runs  = 0; // outlives the owner
    auto       owner = std::make_unique<Owner>();
    Owner*     o     = owner.get();
    const auto job   = [o, &runs](const QList<GfPrompt*>& prompts) {
        o->ran += static_cast<int>(prompts.size());
        ++runs;
    };
    owner->later.schedule({watch(newPrompt(nullptr))}, job);
    EXPECT_EQ(owner->later.pending(), 1);
    EXPECT_EQ(runs, 0); // not now
    spin();
    EXPECT_EQ(runs, 1);
    EXPECT_EQ(owner->ran, 1);
    EXPECT_EQ(owner->later.pending(), 0);
    EXPECT_EQ(gone, 1); // its reference went after it ran
    // Left when the owner goes: a prompt held by two jobs, one of them only releasing it, and a prompt whose sink
    // schedules one more job as it goes.
    Rescheduling sink;
    sink.owner     = o;
    sink.runs      = &runs;
    GfPrompt* a    = watch(newPrompt(nullptr));
    GfPrompt* b    = watch(newPrompt(nullptr));
    GfPrompt* c    = watch(newPrompt(&sink));
    owner->later.schedule({a, b}, job);
    owner->later.schedule({GF_PROMPT(g_object_ref(a))}, {});
    owner->later.schedule({c}, job);
    EXPECT_EQ(owner->later.pending(), 3);
    owner.reset();
    EXPECT_EQ(gone, 4); // every reference released with the owner, the one scheduled meanwhile removed too
    spin();
    EXPECT_EQ(runs, 1); // nothing ran after its owner
}

int main(int argc, char** argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}

// --- step 9e: KIO's password server (KioAuth.h) ---------------------------------------------------------------------------

namespace {
    // An AuthInfo as KIO marshals it (authinfo.cpp:210-217): version 1, the URL as QUrl::toString(), the strings, the four
    // flags and the extra fields.
    GVariant* kioAuthInfo(const char* url, const char* user, const char* password, bool keep = false, GVariant* extra = nullptr,
                          const char* realm = "", bool verifyPath = false, bool readOnly = false) {
        if (!extra)
            extra = g_variant_new_array(G_VARIANT_TYPE("{s(siv)}"), nullptr, 0);
        return g_variant_ref_sink(g_variant_new("(ysssssssssbbbb@a{s(siv)})", guchar(1), url, user, password, "prompt", "caption", "comment",
                                                "Site:", realm, "digest", gboolean(verifyPath), gboolean(readOnly), gboolean(keep), FALSE, extra));
    }

    GVariant* extras(std::initializer_list<std::pair<const char*, GVariant*>> fields) {
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("a{s(siv)}"));
        for (const auto& [name, value] : fields)
            g_variant_builder_add(&b, "{s(siv)}", name, "", gint32(2), value);
        return g_variant_builder_end(&b);
    }

    kio::AuthInfo parsedInfo(GVariant* v) {
        kio::AuthInfo info;
        QString       why;
        EXPECT_TRUE(kio::parseAuthInfo(v, &info, &why)) << why.toStdString();
        g_variant_unref(v);
        return info;
    }

    qint64 g_now = 1000;
    qint64 fakeClock() {
        return g_now;
    }

    kio::AuthInfo infoFor(const char* url, const char* user = "", const char* realm = "", bool keep = false) {
        kio::AuthInfo info;
        info.url          = QString::fromUtf8(url);
        info.parsed       = QUrl(info.url);
        info.username     = QString::fromUtf8(user);
        info.password     = kio::Secret("pw", 2);
        info.realm        = QString::fromUtf8(realm);
        info.keepPassword = keep;
        return info;
    }
} // namespace

TEST(PrompterKio, AnAuthInfoIsReadAndWrittenAsKioMarshalsIt) {
    const kio::AuthInfo info = parsedInfo(kioAuthInfo("sftp://alice@example.org:2222/home", "alice", "s3cret", true, nullptr, "Staff"));
    EXPECT_EQ(info.url, QStringLiteral("sftp://alice@example.org:2222/home"));
    EXPECT_EQ(info.parsed.host(), QStringLiteral("example.org"));
    EXPECT_EQ(info.username, QStringLiteral("alice"));
    EXPECT_EQ(std::string(info.password.data(), info.password.size()), "s3cret");
    EXPECT_EQ(info.commentLabel, QStringLiteral("Site:"));
    EXPECT_EQ(info.realm, QStringLiteral("Staff"));
    EXPECT_TRUE(info.keepPassword);
    EXPECT_FALSE(info.modified);
    kio::AuthInfo answered = info;
    answered.modified      = true;
    GVariant* out          = g_variant_ref_sink(kio::authInfoVariant(answered));
    EXPECT_STREQ(g_variant_get_type_string(out), "(ysssssssssbbbba{s(siv)})");
    guchar       version  = 0;
    const gchar *url = nullptr, *user = nullptr, *password = nullptr, *prompt = nullptr, *caption = nullptr, *comment = nullptr, *label = nullptr,
                *realm = nullptr, *digest = nullptr;
    gboolean   verifyPath = TRUE, readOnly = TRUE, keep = FALSE, modified = FALSE;
    GVariant*  extra      = nullptr;
    g_variant_get(out, "(y&s&s&s&s&s&s&s&s&sbbbb@a{s(siv)})", &version, &url, &user, &password, &prompt, &caption, &comment, &label, &realm, &digest,
                  &verifyPath, &readOnly, &keep, &modified, &extra);
    EXPECT_EQ(version, 1);
    EXPECT_STREQ(url, "sftp://alice@example.org:2222/home");
    EXPECT_STREQ(user, "alice");
    EXPECT_STREQ(password, "s3cret");
    EXPECT_STREQ(prompt, "prompt");
    EXPECT_STREQ(caption, "caption");
    EXPECT_STREQ(comment, "comment");
    EXPECT_STREQ(label, "Site:");
    EXPECT_STREQ(realm, "Staff");
    EXPECT_STREQ(digest, "digest");
    EXPECT_FALSE(verifyPath);
    EXPECT_FALSE(readOnly);
    EXPECT_TRUE(keep);
    EXPECT_TRUE(modified);
    EXPECT_EQ(g_variant_n_children(extra), 0u);
    g_variant_unref(extra);
    g_variant_unref(out);
}

TEST(PrompterKio, AnAuthInfoOverItsBoundsIsRefused) {
    QString       why;
    kio::AuthInfo info;
    const std::string longUrl = "sftp://example.org/" + std::string(kio::kUrlBytes, 'a');
    GVariant*         v       = kioAuthInfo(longUrl.c_str(), "", "");
    EXPECT_FALSE(kio::parseAuthInfo(v, &info, &why));
    g_variant_unref(v);
    const std::string longName(limits::kIdentity + 1, 'n');
    v = kioAuthInfo("sftp://h/", longName.c_str(), "");
    EXPECT_FALSE(kio::parseAuthInfo(v, &info, &why));
    g_variant_unref(v);
    const std::string longPassword(limits::kPassword + 1, 'p');
    v = kioAuthInfo("sftp://h/", "", longPassword.c_str());
    EXPECT_FALSE(kio::parseAuthInfo(v, &info, &why));
    g_variant_unref(v);
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{s(siv)}"));
    for (int i = 0; i <= static_cast<int>(kio::kExtraFields); ++i)
        g_variant_builder_add(&b, "{s(siv)}", QByteArray::number(i).constData(), "", gint32(0), g_variant_new_boolean(TRUE));
    v = kioAuthInfo("sftp://h/", "", "", false, g_variant_builder_end(&b));
    EXPECT_FALSE(kio::parseAuthInfo(v, &info, &why)) << "17 extra fields";
    g_variant_unref(v);
    const std::string bigValue(kio::kExtraEntryBytes, 'v');
    v = kioAuthInfo("sftp://h/", "", "", false, extras({{"domain", g_variant_new_string(bigValue.c_str())}}));
    EXPECT_FALSE(kio::parseAuthInfo(v, &info, &why)) << "an extra field over its bound";
    g_variant_unref(v);
    GVariant* other = g_variant_ref_sink(g_variant_new("(s)", "x"));
    EXPECT_FALSE(kio::parseAuthInfo(other, &info, &why));
    g_variant_unref(other);
    // At the bounds: accepted.
    const std::string urlAtBound = "s://h/" + std::string(kio::kUrlBytes - 6, 'a');
    v                            = kioAuthInfo(urlAtBound.c_str(), "", std::string(limits::kPassword, 'p').c_str());
    EXPECT_TRUE(kio::parseAuthInfo(v, &info, &why)) << why.toStdString();
    g_variant_unref(v);
}

TEST(PrompterKio, ExtraFieldsAreBooleansAndTheAnonymousOneIsTurnedOff) {
    kio::AuthInfo info = parsedInfo(kioAuthInfo("ftp://h/", "", "", false,
                                                extras({{"anonymous", g_variant_new_boolean(TRUE)}, {"domain", g_variant_new_string("WORKGROUP")},
                                                        {"skip-caching-on-query", g_variant_new_boolean(TRUE)}, {"hide-username-line", g_variant_new_string("true")}})));
    bool present = false;
    EXPECT_TRUE(kio::extraBool(info, kio::kExtraAnonymous, &present));
    EXPECT_TRUE(present);
    EXPECT_TRUE(kio::extraBool(info, kio::kExtraSkipCaching));
    EXPECT_FALSE(kio::extraBool(info, kio::kExtraHideUsername, &present)) << "a string is not a boolean";
    EXPECT_TRUE(present);
    EXPECT_FALSE(kio::extraBool(info, kio::kExtraBypassCache, &present));
    EXPECT_FALSE(present);
    kio::setExtraBool(&info, kio::kExtraAnonymous, false);
    EXPECT_FALSE(kio::extraBool(info, kio::kExtraAnonymous, &present));
    EXPECT_TRUE(present);
    kio::setExtraBool(&info, kio::kExtraBypassCache, true); // absent: nothing added
    EXPECT_FALSE(kio::extraBool(info, kio::kExtraBypassCache, &present));
    EXPECT_FALSE(present);
    // The other fields, their titles and flags, unchanged.
    GVariant* domain = g_variant_lookup_value(info.extra.get(), "domain", G_VARIANT_TYPE("(siv)"));
    ASSERT_NE(domain, nullptr);
    const gchar* title = nullptr;
    gint32       flags = 0;
    GVariant*    value = nullptr;
    g_variant_get(domain, "(&siv)", &title, &flags, &value);
    EXPECT_EQ(flags, 2);
    EXPECT_STREQ(g_variant_get_string(value, nullptr), "WORKGROUP");
    g_variant_unref(value);
    g_variant_unref(domain);
}

TEST(PrompterKio, APasswordThatIsNotValidTextNeverGoesOnTheBus) {
    kio::AuthInfo info = infoFor("sftp://h/");
    info.password      = kio::Secret("a\xff\xfe", 3);
    GVariant* out      = g_variant_ref_sink(kio::authInfoVariant(info));
    const gchar* password = nullptr;
    g_variant_get_child(out, 3, "&s", &password);
    EXPECT_STREQ(password, "");
    g_variant_unref(out);
    info.password = kio::Secret("a\0b", 3);
    out           = g_variant_ref_sink(kio::authInfoVariant(info));
    g_variant_get_child(out, 3, "&s", &password);
    EXPECT_STREQ(password, "");
    g_variant_unref(out);
}

TEST(PrompterKio, SecretsAreDeepCopiesInSecureMemory) {
    kio::Secret a("pass", 4);
    kio::Secret b = a;
    EXPECT_NE(a.data(), b.data());
    EXPECT_TRUE(a == b);
    kio::Secret c = std::move(b);
    EXPECT_TRUE(b.empty());
    EXPECT_EQ(std::string(c.data(), c.size()), "pass");
    EXPECT_TRUE(gcr_secure_memory_is_secure(const_cast<char*>(c.data())));
    char* out = c.copyOut();
    EXPECT_STREQ(out, "pass");
    kio::wipeAndFree(out);
}

TEST(PrompterKio, TheCacheKeyIsKpasswdserversWithItsPortQuirk) {
    EXPECT_EQ(kio::cacheKey(QUrl(QStringLiteral("sftp://example.org/home"))), QStringLiteral("sftp-example.org:-1"));
    EXPECT_EQ(kio::cacheKey(QUrl(QStringLiteral("ftp://alice@Example.ORG:2121/x"))), QStringLiteral("ftp-alice@example.org:2121"));
    EXPECT_EQ(kio::cacheKey(QUrl(QStringLiteral("smb://bob%20b@nas/share"))), QStringLiteral("smb-bob b@nas:-1"));
    EXPECT_EQ(kio::cacheKey(QUrl(QStringLiteral("ftp://h:0/"))), QStringLiteral("ftp-h")) << "port 0: no port at all, as kpasswdserver writes it";
    EXPECT_TRUE(kio::cacheKey(QUrl(QStringLiteral("http://exa mple.org/"))).isEmpty());
    EXPECT_EQ(kio::directoryOf(QUrl(QStringLiteral("sftp://h/a/b/c"))), QStringLiteral("/")) << "up to the FIRST slash (kpasswdserver.cpp:678)";
    EXPECT_EQ(kio::directoryOf(QUrl(QStringLiteral("sftp://h"))), QString());
}

TEST(PrompterKio, TheServerShownIsAHostNameOnly) {
    EXPECT_EQ(kio::serverLabel(QUrl(QStringLiteral("sftp://alice@Example.org/home"))), QStringLiteral("example.org"));
    EXPECT_EQ(kio::serverLabel(QUrl(QStringLiteral("ftp://127.0.0.1:2121/"))), QStringLiteral("127.0.0.1:2121"));
    EXPECT_EQ(kio::serverLabel(QUrl(QStringLiteral("sftp://[::1]:22/"))), QStringLiteral("[::1]:22"));
    EXPECT_EQ(kio::serverLabel(QUrl(QStringLiteral("smb://MY_NAS/share"))), QStringLiteral("my_nas"));
    EXPECT_EQ(kio::serverLabel(QUrl(QStringLiteral("sftp://host.example./"))), QStringLiteral("host.example."));
    // An international name in its ASCII form: never a look-alike character.
    EXPECT_EQ(kio::serverLabel(QUrl(QStringLiteral("sftp://b\u00fccher.example/"))), QStringLiteral("xn--bcher-kva.example"));
    EXPECT_EQ(kio::serverLabel(QUrl(QStringLiteral("sftp://\u0430pple.com/"))), QStringLiteral("xn--pple-43d.com"));
    EXPECT_TRUE(kio::serverLabel(QUrl(QStringLiteral("smb:///"))).isEmpty());
    EXPECT_TRUE(kio::serverLabel(QUrl(QStringLiteral("file:///etc/passwd"))).isEmpty());
    EXPECT_TRUE(kio::serverLabel(QUrl(QStringLiteral("sftp://a..b/"))).isEmpty());
    EXPECT_TRUE(kio::serverLabel(QUrl(QStringLiteral("sftp://[fe80::1%25eth0]/"))).isEmpty()) << "no zone index";
    EXPECT_TRUE(kio::serverLabel(QUrl(QStringLiteral("sftp://") + QString(64, u'a') + QStringLiteral(".example/"))).isEmpty()) << "a label over 63";
}

TEST(PrompterKio, TheKeyringItemsAttributesAndLabel) {
    const kio::AuthInfo info = infoFor("ftp://alice@example.org:2121/", "alice", "Staff");
    const QString       key  = kio::cacheKey(info.parsed);
    using Pairs              = QList<QPair<QString, QString>>;
    EXPECT_EQ(kio::storeAttributes(key, info), (Pairs{{QStringLiteral("key"), QStringLiteral("ftp-alice@example.org:2121")},
                                                      {QStringLiteral("realm"), QStringLiteral("Staff")},
                                                      {QStringLiteral("user"), QStringLiteral("alice")},
                                                      {QStringLiteral("protocol"), QStringLiteral("ftp")},
                                                      {QStringLiteral("server"), QStringLiteral("example.org")},
                                                      {QStringLiteral("port"), QStringLiteral("2121")}}));
    EXPECT_EQ(kio::searchAttributes(key, info),
              (Pairs{{QStringLiteral("key"), key}, {QStringLiteral("realm"), QStringLiteral("Staff")}, {QStringLiteral("user"), QStringLiteral("alice")}}));
    EXPECT_EQ(kio::searchAttributes(key, infoFor("ftp://example.org/")), (Pairs{{QStringLiteral("key"), key}, {QStringLiteral("realm"), QString()}}))
        << "no user: any remembered login of that key and realm";
    EXPECT_EQ(kio::itemLabel(info), QStringLiteral("ftp://alice@example.org:2121"));
}

TEST(PrompterKio, TheKeyringsProtectionFromGnomeKeyringsFile) {
    EXPECT_EQ(kio::protectionOfHeader(QByteArray("GnomeKeyring\n\r\0\n\0\0\0\0", 20)), kio::Protection::Protected);
    EXPECT_EQ(kio::protectionOfHeader("[keyring]\ndisplay-name=Default keyring\n"), kio::Protection::Unprotected);
    EXPECT_EQ(kio::protectionOfHeader("GnomeKeyring\n"), kio::Protection::Unknown);
    EXPECT_EQ(kio::protectionOfHeader(""), kio::Protection::Unknown);
    EXPECT_EQ(kio::protectionName(kio::Protection::Unprotected), QStringLiteral("unprotected"));
    EXPECT_EQ(kio::collectionFileName(QStringLiteral("/org/freedesktop/secrets/collection/login")), QStringLiteral("login"));
    EXPECT_EQ(kio::collectionFileName(QStringLiteral("/org/freedesktop/secrets/collection/Default_5fkeyring")), QStringLiteral("Default_keyring"));
    EXPECT_TRUE(kio::collectionFileName(QStringLiteral("/org/freedesktop/secrets/collection/a_2fb")).isEmpty()) << "a slash";
    EXPECT_TRUE(kio::collectionFileName(QStringLiteral("/org/freedesktop/secrets/collection/_2e_2e")).isEmpty()) << "..";
    EXPECT_TRUE(kio::collectionFileName(QStringLiteral("/org/freedesktop/secrets/collection/x_zz")).isEmpty()) << "not hex";
    EXPECT_TRUE(kio::collectionFileName(QStringLiteral("/org/freedesktop/secrets/collection/x_2")).isEmpty()) << "cut short";
    EXPECT_TRUE(kio::collectionFileName(QStringLiteral("/org/freedesktop/secrets/aliases/default")).isEmpty());
    EXPECT_TRUE(kio::collectionFileName(QStringLiteral("/")).isEmpty());
    EXPECT_EQ(kio::keyringDirectory(QStringLiteral("/x/data"), QStringLiteral("/home/u")), QStringLiteral("/x/data/keyrings"));
    EXPECT_EQ(kio::keyringDirectory(QString(), QStringLiteral("/home/u")), QStringLiteral("/home/u/.local/share/keyrings"));
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const auto write = [&](const char* name, const QByteArray& bytes) {
        QFile f(dir.path() + u'/' + QLatin1String(name));
        EXPECT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(bytes);
    };
    write("plain.keyring", "[keyring]\ndisplay-name=Default keyring\n");
    write("login.keyring", QByteArray("GnomeKeyring\n\r\0\n\0\0", 18));
    EXPECT_EQ(kio::fileProtection(dir.path() + QStringLiteral("/plain.keyring"), ::getuid()), kio::Protection::Unprotected);
    EXPECT_EQ(kio::fileProtection(dir.path() + QStringLiteral("/login.keyring"), ::getuid()), kio::Protection::Protected);
    EXPECT_EQ(kio::fileProtection(dir.path() + QStringLiteral("/login.keyring"), ::getuid() + 1), kio::Protection::Unknown) << "another owner";
    ASSERT_EQ(::symlink("plain.keyring", QFile::encodeName(dir.path() + QStringLiteral("/link.keyring")).constData()), 0);
    EXPECT_EQ(kio::fileProtection(dir.path() + QStringLiteral("/link.keyring"), ::getuid()), kio::Protection::Unknown) << "a symlink";
    ASSERT_EQ(::mkfifo(QFile::encodeName(dir.path() + QStringLiteral("/fifo.keyring")).constData(), 0600), 0);
    EXPECT_EQ(kio::fileProtection(dir.path() + QStringLiteral("/fifo.keyring"), ::getuid()), kio::Protection::Unknown) << "not a regular file";
    EXPECT_EQ(kio::fileProtection(dir.path() + QStringLiteral("/missing.keyring"), ::getuid()), kio::Protection::Unknown);
}

TEST(PrompterKio, TheCacheFindsByRealmAndUser) {
    g_now = 1000;
    kio::Cache    cache(fakeClock);
    const QString key = QStringLiteral("sftp-h:-1");
    cache.add(key, infoFor("sftp://h/", "alice", "", true), 0, 1, false);
    cache.add(key, infoFor("sftp://h/", "bob", "Staff", true), 0, 2, false);
    EXPECT_EQ(cache.size(), 2);
    kio::CacheEntry* e = cache.find(key, infoFor("sftp://h/x", "", ""));
    ASSERT_NE(e, nullptr);
    EXPECT_EQ(e->info.username, QStringLiteral("alice"));
    EXPECT_EQ(e->seqNr, 1);
    EXPECT_EQ(cache.find(key, infoFor("sftp://h/", "bob", "")), nullptr) << "another user for that realm";
    e = cache.find(key, infoFor("sftp://h/", "", "Staff"));
    ASSERT_NE(e, nullptr);
    EXPECT_EQ(e->info.username, QStringLiteral("bob"));
    EXPECT_EQ(cache.find(QStringLiteral("sftp-h:22"), infoFor("sftp://h:22/")), nullptr) << "another key";
    // verifyPath: the directory is always "/" (kpasswdserver's quirk), so any path matches, whatever the realm.
    kio::AuthInfo byPath = infoFor("sftp://h/elsewhere/deep", "", "Other");
    byPath.verifyPath    = true;
    EXPECT_NE(cache.find(key, byPath), nullptr);
    // The same realm replaces its entry.
    cache.add(key, infoFor("sftp://h/", "carol", "", true), 0, 3, false);
    EXPECT_EQ(cache.size(), 2);
    EXPECT_EQ(cache.find(key, infoFor("sftp://h/"))->info.username, QStringLiteral("carol"));
    cache.remove(key, QStringLiteral("Staff"));
    EXPECT_EQ(cache.size(), 1);
}

TEST(PrompterKio, HowLongAnEntryLives) {
    g_now = 1000;
    kio::Cache    cache(fakeClock);
    const QString key = QStringLiteral("ftp-h:-1");
    // Neither kept nor tied to a window: 10 s after its last use.
    cache.add(key, infoFor("ftp://h/", "a", "plain"), 0, 1, false);
    // Kept (keepPassword) without a window: for the session.
    cache.add(key, infoFor("ftp://h/", "b", "kept", true), 0, 1, false);
    // Tied to a window: until the window closes, which nothing reports in a Grassfield session.
    cache.add(key, infoFor("ftp://h/", "c", "window"), 42, 1, false);
    g_now = 1009;
    kio::CacheEntry* plain = cache.find(key, infoFor("ftp://h/", "", "plain"));
    ASSERT_NE(plain, nullptr);
    cache.touch(plain, 0, false); // a use: 10 s more
    g_now = 1015;
    EXPECT_NE(cache.find(key, infoFor("ftp://h/", "", "plain")), nullptr);
    g_now = 1020;
    EXPECT_EQ(cache.find(key, infoFor("ftp://h/", "", "plain")), nullptr) << "expired";
    g_now = 1000000;
    EXPECT_NE(cache.find(key, infoFor("ftp://h/", "", "kept")), nullptr);
    kio::CacheEntry* window = cache.find(key, infoFor("ftp://h/", "", "window"));
    ASSERT_NE(window, nullptr);
    EXPECT_EQ(window->expire, kio::CacheEntry::Expire::WindowClose);
    EXPECT_EQ(window->windows, QList<qint64>{42});
    // A cancelled entry is never kept, whatever keepPassword says.
    cache.add(key, infoFor("ftp://h/", "d", "cancelled", true), 0, 9, true);
    kio::CacheEntry* cancelled = cache.find(key, infoFor("ftp://h/", "", "cancelled"));
    ASSERT_NE(cancelled, nullptr);
    EXPECT_TRUE(cancelled->canceled);
    EXPECT_EQ(cancelled->expire, kio::CacheEntry::Expire::Time);
    g_now += 11;
    EXPECT_EQ(cache.find(key, infoFor("ftp://h/", "", "cancelled")), nullptr);
}

TEST(PrompterKio, RemoveAuthInfoAndTheBound) {
    g_now = 1000;
    kio::Cache cache(fakeClock, 3);
    cache.add(QStringLiteral("sftp-h:-1"), infoFor("sftp://h/", "alice", "", true), 0, 1, false);
    cache.add(QStringLiteral("sftp-alice@h:-1"), infoFor("sftp://alice@h/", "alice", "", true), 0, 1, false);
    cache.add(QStringLiteral("ftp-h:-1"), infoFor("ftp://h/", "alice", "", true), 0, 1, false);
    EXPECT_EQ(cache.removeMatching(QStringLiteral("h"), QStringLiteral("sftp"), QStringLiteral("bob")), 0);
    EXPECT_EQ(cache.removeMatching(QStringLiteral("h"), QStringLiteral("sftp"), QString()), 2) << "any user, both sftp keys";
    EXPECT_EQ(cache.size(), 1);
    // At the bound: expired entries go first, then the oldest.
    cache.add(QStringLiteral("a:-1"), infoFor("a://h/", "x"), 0, 1, false); // expires at 1010
    cache.add(QStringLiteral("b:-1"), infoFor("b://h/", "x", "", true), 0, 1, false);
    EXPECT_EQ(cache.size(), 3);
    g_now = 1011;
    cache.add(QStringLiteral("c:-1"), infoFor("c://h/", "x", "", true), 0, 1, false);
    EXPECT_EQ(cache.size(), 3);
    EXPECT_EQ(cache.find(QStringLiteral("a:-1"), infoFor("a://h/")), nullptr);
    cache.add(QStringLiteral("d:-1"), infoFor("d://h/", "x", "", true), 0, 1, false);
    EXPECT_EQ(cache.size(), 3);
    EXPECT_EQ(cache.find(QStringLiteral("ftp-h:-1"), infoFor("ftp://h/")), nullptr) << "the oldest went";
    EXPECT_NE(cache.find(QStringLiteral("d:-1"), infoFor("d://h/")), nullptr);
}

TEST(PrompterProtocol, AKioPromptCarriesTheServerTheLoginAndTheRequester) {
    KioPromptView v;
    v.id                   = QStringLiteral("p9");
    v.requester.role       = QStringLiteral("kio");
    v.requester.path       = QStringLiteral("/usr/lib/kf6/kioworker");
    v.requester.identified = true;
    v.requester.onBehalf   = true;
    v.server               = QStringLiteral("example.org:2222");
    v.name                 = QStringLiteral("alice");
    v.nameMode             = QStringLiteral("edit");
    v.realm                = QStringLiteral("Staff");
    v.retry                = true;
    v.remember             = QStringLiteral("on");
    v.keyring              = QStringLiteral("unprotected");
    const QByteArray line  = kioPromptMessage(v);
    ASSERT_TRUE(line.endsWith('\n'));
    EXPECT_EQ(line.count('\n'), 1);
    const QJsonObject o = QJsonDocument::fromJson(line).object();
    EXPECT_EQ(o.keys(), (QStringList{QStringLiteral("id"), QStringLiteral("kind"), QStringLiteral("login"), QStringLiteral("requester"), QStringLiteral("server"),
                                     QStringLiteral("type")}));
    EXPECT_EQ(o.value(QStringLiteral("kind")).toString(), QStringLiteral("kio"));
    EXPECT_EQ(o.value(QStringLiteral("server")).toString(), QStringLiteral("example.org:2222"));
    const QJsonObject r = o.value(QStringLiteral("requester")).toObject();
    EXPECT_EQ(r.keys().size(), 7);
    EXPECT_EQ(r.value(QStringLiteral("role")).toString(), QStringLiteral("kio"));
    EXPECT_TRUE(r.value(QStringLiteral("onBehalf")).toBool());
    const QJsonObject l = o.value(QStringLiteral("login")).toObject();
    EXPECT_EQ(l.keys(), (QStringList{QStringLiteral("keyring"), QStringLiteral("name"), QStringLiteral("nameMode"), QStringLiteral("realm"), QStringLiteral("remember"),
                                     QStringLiteral("retry")}));
    EXPECT_EQ(l.value(QStringLiteral("name")).toString(), QStringLiteral("alice"));
    EXPECT_TRUE(l.value(QStringLiteral("retry")).toBool());
    EXPECT_EQ(l.value(QStringLiteral("remember")).toString(), QStringLiteral("on"));
    EXPECT_EQ(l.value(QStringLiteral("keyring")).toString(), QStringLiteral("unprotected"));
}

// --- step 10: the BlueZ pairing agent (BtPairing.h) -------------------------------------------------------------------------

TEST(PrompterBluetooth, OnlyADevicePathOfBluetoothdIsAccepted) {
    QString address;
    EXPECT_TRUE(bt::validDevicePath("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01", &address));
    EXPECT_EQ(address, QStringLiteral("AA:BB:CC:DD:EE:01"));
    EXPECT_TRUE(bt::validDevicePath("/org/bluez/hci12/dev_00_1A_7D_DA_71_13", &address));
    EXPECT_EQ(address, QStringLiteral("00:1A:7D:DA:71:13"));
    for (const char* bad : {"", "/", "/org/bluez", "/org/bluez/hci0", "/org/bluez/hci0/dev_AA_BB_CC_DD_EE", "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01/sep1",
                            "/org/bluez/hci0/dev_aa_bb_cc_dd_ee_01", "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_0G", "/org/bluez/hci0/dev_AA-BB-CC-DD-EE-01",
                            "/org/bluez/hciX/dev_AA_BB_CC_DD_EE_01", "/org/bluez/hci01/dev_AA_BB_CC_DD_EE_01", "/org/bluez/hci1000/dev_AA_BB_CC_DD_EE_01",
                            "/org/bluez/hci/dev_AA_BB_CC_DD_EE_01", "/org/freedesktop/NetworkManager/Devices/1", "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01_02",
                            "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_01\n"}) {
        EXPECT_FALSE(bt::validDevicePath(bad, &address)) << bad;
    }
    EXPECT_FALSE(bt::validDevicePath(nullptr, &address));
}

TEST(PrompterBluetooth, APasskeyIsShownAsSixDigits) {
    EXPECT_EQ(bt::formatPasskey(0), QStringLiteral("000000"));
    EXPECT_EQ(bt::formatPasskey(7), QStringLiteral("000007"));
    EXPECT_EQ(bt::formatPasskey(123456), QStringLiteral("123456"));
    EXPECT_EQ(bt::formatPasskey(999999), QStringLiteral("999999"));
    EXPECT_TRUE(bt::formatPasskey(1000000).isEmpty());
    EXPECT_TRUE(bt::formatPasskey(0xFFFFFFFFu).isEmpty());
}

TEST(PrompterBluetooth, TheCodesTypedAreChecked) {
    EXPECT_TRUE(bt::validPin("0", 1));
    EXPECT_TRUE(bt::validPin("0000", 4));
    EXPECT_TRUE(bt::validPin("Ab12Cd34Ef56Gh78", 16));
    EXPECT_FALSE(bt::validPin("", 0));
    EXPECT_FALSE(bt::validPin("Ab12Cd34Ef56Gh789", 17)) << "BlueZ refuses more than 16 bytes";
    for (const char* bad : {"12-34", "12 34", "1234\n", "caf\xc3\xa9", "12;34"})
        EXPECT_FALSE(bt::validPin(bad, std::strlen(bad))) << bad;
    EXPECT_FALSE(bt::validPin("12\0" "34", 5)) << "a NUL";
    guint32 passkey = 1;
    EXPECT_TRUE(bt::parsePasskey("000000", 6, &passkey));
    EXPECT_EQ(passkey, 0u);
    EXPECT_TRUE(bt::parsePasskey("012345", 6, &passkey));
    EXPECT_EQ(passkey, 12345u);
    EXPECT_TRUE(bt::parsePasskey("999999", 6, &passkey));
    EXPECT_EQ(passkey, 999999u);
    for (const char* bad : {"", "12345", "1234567", "12345a", "-12345", "+12345", " 12345", "1e5000"})
        EXPECT_FALSE(bt::parsePasskey(bad, std::strlen(bad), &passkey)) << bad;
}

TEST(PrompterBluetooth, AServiceIsNamedByItsProfileOrOther) {
    QString uuid;
    EXPECT_EQ(bt::serviceKey("0000110B-0000-1000-8000-00805F9B34FB", &uuid), QStringLiteral("audio"));
    EXPECT_EQ(uuid, QStringLiteral("0000110b-0000-1000-8000-00805f9b34fb"));
    EXPECT_EQ(bt::serviceKey("0000110e-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("remote-control"));
    EXPECT_EQ(bt::serviceKey("0000111e-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("hands-free"));
    EXPECT_EQ(bt::serviceKey("00001108-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("headset"));
    EXPECT_EQ(bt::serviceKey("00001105-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("object-push"));
    EXPECT_EQ(bt::serviceKey("00001106-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("file-transfer"));
    EXPECT_EQ(bt::serviceKey("00001116-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("network"));
    EXPECT_EQ(bt::serviceKey("00001124-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("input"));
    EXPECT_EQ(bt::serviceKey("00001812-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("input"));
    EXPECT_EQ(bt::serviceKey("0000112f-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("phonebook"));
    EXPECT_EQ(bt::serviceKey("00001132-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("messages"));
    EXPECT_EQ(bt::serviceKey("00001101-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("serial"));
    EXPECT_EQ(bt::serviceKey("00001103-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("dial-up"));
    EXPECT_EQ(bt::serviceKey("0000ffff-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("other"));
    EXPECT_EQ(bt::serviceKey("03b80e5a-ede8-4b33-a751-6ce34ec4c700", &uuid), QStringLiteral("other")) << "outside the base UUID";
    EXPECT_EQ(uuid, QStringLiteral("03b80e5a-ede8-4b33-a751-6ce34ec4c700"));
    EXPECT_EQ(bt::serviceKey("1000110b-0000-1000-8000-00805f9b34fb", &uuid), QStringLiteral("other")) << "not 0000xxxx";
    for (const char* bad : {"", "0000110b", "0000110b-0000-1000-8000-00805f9b34f", "0000110b-0000-1000-8000-00805f9b34fbb", "0000110b00000-1000-8000-00805f9b34fb",
                            "0000110g-0000-1000-8000-00805f9b34fb", "{0000110b-0000-1000-8000-00805f9b34}", "0000110b-0000-1000-8000-00805f9b34f\n"})
        EXPECT_TRUE(bt::serviceKey(bad, &uuid).isEmpty()) << bad;
    EXPECT_TRUE(bt::serviceKey(nullptr, &uuid).isEmpty());
}

TEST(PrompterBluetooth, TheModes) {
    EXPECT_EQ(bt::modeName(bt::Mode::Pin), QStringLiteral("pin"));
    EXPECT_EQ(bt::modeName(bt::Mode::Passkey), QStringLiteral("passkey"));
    EXPECT_EQ(bt::modeName(bt::Mode::DisplayPin), QStringLiteral("display-pin"));
    EXPECT_EQ(bt::modeName(bt::Mode::DisplayPasskey), QStringLiteral("display-passkey"));
    EXPECT_EQ(bt::modeName(bt::Mode::Confirm), QStringLiteral("confirm"));
    EXPECT_EQ(bt::modeName(bt::Mode::Authorize), QStringLiteral("authorize"));
    EXPECT_EQ(bt::modeName(bt::Mode::AuthorizeService), QStringLiteral("authorize-service"));
    EXPECT_TRUE(bt::isDisplay(bt::Mode::DisplayPin));
    EXPECT_TRUE(bt::isDisplay(bt::Mode::DisplayPasskey));
    EXPECT_FALSE(bt::isDisplay(bt::Mode::Confirm));
    EXPECT_TRUE(bt::asksCode(bt::Mode::Pin));
    EXPECT_TRUE(bt::asksCode(bt::Mode::Passkey));
    EXPECT_FALSE(bt::asksCode(bt::Mode::DisplayPasskey));
    EXPECT_FALSE(bt::asksCode(bt::Mode::Authorize));
}

TEST(PrompterBluetooth, TheDeviceIsNamedByItsAliasFlattenedElseItsNameElseItsAddress) {
    const QString address = QStringLiteral("AA:BB:CC:DD:EE:01");
    auto props            = [](std::initializer_list<std::pair<const char*, GVariant*>> entries) {
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
        for (const auto& [k, v] : entries)
            g_variant_builder_add(&b, "{sv}", k, v);
        return g_variant_ref_sink(g_variant_builder_end(&b));
    };
    GVariant* full = props({{"Alias", g_variant_new_string("Desk Keyboard")}, {"Name", g_variant_new_string("MK-7")},
                            {"Address", g_variant_new_string("11:22:33:44:55:66")}, {"Icon", g_variant_new_string("input-keyboard")}});
    bt::DeviceView v = bt::deviceView(full, address);
    EXPECT_EQ(v.name, QStringLiteral("Desk Keyboard"));
    EXPECT_EQ(v.address, address) << "the path's address, never the property's";
    EXPECT_EQ(v.icon, QStringLiteral("keyboard"));
    g_variant_unref(full);
    GVariant* hostile = props({{"Alias", g_variant_new_string("Key\n\xe2\x80\xae" "eno\t" "board")}, {"Icon", g_variant_new_string("../../evil")}});
    v                 = bt::deviceView(hostile, address);
    EXPECT_EQ(v.name, QStringLiteral("Key eno board")) << "a line feed and a direction override flattened";
    EXPECT_EQ(v.icon, QString()) << "an icon that is not one of the list";
    g_variant_unref(hostile);
    GVariant* longName = props({{"Alias", g_variant_new_string(std::string(300, 'x').c_str())}});
    v                  = bt::deviceView(longName, address);
    EXPECT_EQ(v.name.size(), bt::kNameCap);
    EXPECT_TRUE(v.name.endsWith(QChar(0x2026)));
    g_variant_unref(longName);
    GVariant* nameOnly = props({{"Alias", g_variant_new_string(" ​ ")}, {"Name", g_variant_new_string("Speaker")}, {"Icon", g_variant_new_string("audio-card")}});
    v                  = bt::deviceView(nameOnly, address);
    EXPECT_EQ(v.name, QStringLiteral("Speaker")) << "an alias that shows nothing";
    EXPECT_EQ(v.icon, QStringLiteral("speaker"));
    g_variant_unref(nameOnly);
    GVariant* wrongType = props({{"Alias", g_variant_new_uint32(7)}, {"Icon", g_variant_new_uint32(1)}});
    v                   = bt::deviceView(wrongType, address);
    EXPECT_EQ(v.name, address);
    EXPECT_EQ(v.icon, QString());
    g_variant_unref(wrongType);
    v = bt::deviceView(nullptr, address);
    EXPECT_EQ(v.name, address) << "no properties: the address";
    GVariant* notADict = g_variant_ref_sink(g_variant_new_string("Alias"));
    EXPECT_EQ(bt::deviceView(notADict, address).name, address);
    g_variant_unref(notADict);
    const std::pair<const char*, const char*> icons[] = {{"input-keyboard", "keyboard"}, {"input-mouse", "mouse"},        {"input-tablet", "mouse"},
                                                         {"input-gaming", "gamecontroller"}, {"audio-headset", "headphones"}, {"audio-headphones", "headphones"},
                                                         {"audio-card", "speaker"},       {"phone", "phone"},             {"computer", "laptop"},
                                                         {"video-display", "display"},    {"printer", "printer"},         {"camera-photo", "camera"},
                                                         {"camera-video", "camera"},      {"modem", ""},                  {"network-wireless", ""},
                                                         {"Phone", ""}};
    for (const auto& [in, out] : icons)
        EXPECT_EQ(bt::iconKey(QString::fromLatin1(in)), QString::fromLatin1(out)) << in;
}

TEST(PrompterProtocol, ABluetoothPromptAndItsProgress) {
    BtPromptView v;
    v.id                  = QStringLiteral("p4");
    v.mode                = QStringLiteral("display-passkey");
    v.name                = QStringLiteral("Desk Keyboard");
    v.address             = QStringLiteral("AA:BB:CC:DD:EE:01");
    v.icon                = QStringLiteral("keyboard");
    v.code                = QStringLiteral("000042");
    v.entered             = 2;
    const QByteArray line = btPromptMessage(v);
    ASSERT_TRUE(line.endsWith('\n'));
    EXPECT_EQ(line.count('\n'), 1);
    const QJsonObject o = QJsonDocument::fromJson(line).object();
    EXPECT_EQ(o.keys(), (QStringList{QStringLiteral("device"), QStringLiteral("id"), QStringLiteral("kind"), QStringLiteral("pairing"), QStringLiteral("type")}));
    EXPECT_EQ(o.value(QStringLiteral("kind")).toString(), QStringLiteral("bluetooth"));
    const QJsonObject dev = o.value(QStringLiteral("device")).toObject();
    EXPECT_EQ(dev.keys(), (QStringList{QStringLiteral("address"), QStringLiteral("icon"), QStringLiteral("name")}));
    EXPECT_EQ(dev.value(QStringLiteral("name")).toString(), QStringLiteral("Desk Keyboard"));
    const QJsonObject pairing = o.value(QStringLiteral("pairing")).toObject();
    EXPECT_EQ(pairing.keys(), (QStringList{QStringLiteral("code"), QStringLiteral("entered"), QStringLiteral("mode"), QStringLiteral("service"), QStringLiteral("uuid")}));
    EXPECT_EQ(pairing.value(QStringLiteral("mode")).toString(), QStringLiteral("display-passkey"));
    EXPECT_EQ(pairing.value(QStringLiteral("code")).toString(), QStringLiteral("000042")) << "a string: the leading zeros stay";
    EXPECT_TRUE(pairing.value(QStringLiteral("entered")).isDouble());
    EXPECT_EQ(pairing.value(QStringLiteral("entered")).toInt(), 2);
    EXPECT_EQ(progressMessage(QStringLiteral("p4"), 5), QByteArray("{\"entered\":5,\"id\":\"p4\",\"type\":\"progress\"}\n"));
}

TEST(PrompterProtocol, ABluetoothAnswerCarriesTheCodeAsAPassword) {
    ShellLine m;
    QString   error;
    const std::string pin = R"({"type":"answer","id":"p3","result":"ok","password":"12ab34"})";
    ASSERT_EQ(parseShellLine(pin, &m, &error), ParseStatus::Ok) << qPrintable(error);
    EXPECT_TRUE(m.ok);
    EXPECT_TRUE(m.hasPassword);
    char buffer[32]{};
    const long n = decodeJsonString(pin.data() + m.password.begin, m.password.end - m.password.begin, buffer, sizeof(buffer));
    ASSERT_EQ(n, 6);
    EXPECT_TRUE(bt::validPin(buffer, static_cast<std::size_t>(n)));
    guint32 passkey = 0;
    EXPECT_FALSE(bt::parsePasskey(buffer, static_cast<std::size_t>(n), &passkey)) << "letters are not a passkey";
    const std::string escaped = R"({"type":"answer","id":"p3","result":"ok","password":"123456"})";
    ASSERT_EQ(parseShellLine(escaped, &m, &error), ParseStatus::Ok);
    const long e = decodeJsonString(escaped.data() + m.password.begin, m.password.end - m.password.begin, buffer, sizeof(buffer));
    ASSERT_EQ(e, 6);
    EXPECT_TRUE(bt::parsePasskey(buffer, static_cast<std::size_t>(e), &passkey));
    EXPECT_EQ(passkey, 123456u);
}
