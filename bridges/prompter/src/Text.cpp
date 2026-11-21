#include "Text.h"

namespace gf::prompter {

    namespace {
        // Shows nothing itself and changes how the text around it is shown, or is not a character at all.
        bool removed(char32_t c) {
            return c == 0x00AD || c == 0x034F || c == 0x061C || c == 0x180E || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E)
                || (c >= 0x2060 && c <= 0x2064) || (c >= 0x2066 && c <= 0x2069) || c == 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB)
                || (c >= 0xE0000 && c <= 0xE007F) || (c >= 0xFDD0 && c <= 0xFDEF) || (c & 0xFFFE) == 0xFFFE;
        }

        // A zero-width joiner or non-joiner between these is part of the text (B-19): emoji ZWJ sequences (a family, a
        // profession with its skin tone, a flag with U+FE0F), and the joiners Persian, Arabic and the Indic scripts need.
        bool joinable(char32_t c) {
            if (QChar::isLetter(c) || QChar::isMark(c))
                return true;
            const QChar::Category cat = QChar::category(c);
            return cat == QChar::Symbol_Other || cat == QChar::Symbol_Modifier || (c >= 0x1F000 && c <= 0x1FAFF);
        }

        bool joiner(char32_t c) {
            return c == 0x200C || c == 0x200D;
        }

        // The code point at `i` (a pair read whole), 0 past the end.
        char32_t at(const QString& text, qsizetype i) {
            if (i >= text.size())
                return 0;
            const char32_t c = text.at(i).unicode();
            if (QChar::isHighSurrogate(c) && i + 1 < text.size() && QChar::isLowSurrogate(text.at(i + 1).unicode()))
                return QChar::surrogateToUcs4(text.at(i), text.at(i + 1));
            return c;
        }

        // The last code point of `out`, 0 when empty.
        char32_t last(const QString& out) {
            if (out.isEmpty())
                return 0;
            const qsizetype n = out.size();
            if (n >= 2 && QChar::isLowSurrogate(out.at(n - 1).unicode()) && QChar::isHighSurrogate(out.at(n - 2).unicode()))
                return QChar::surrogateToUcs4(out.at(n - 2), out.at(n - 1));
            return out.at(n - 1).unicode();
        }

        bool space(char32_t c) {
            return c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 || QChar::isSpace(c);
        }

        void append(QString& out, char32_t c) {
            if (QChar::requiresSurrogates(c)) {
                out.append(QChar(QChar::highSurrogate(c)));
                out.append(QChar(QChar::lowSurrogate(c)));
            } else {
                out.append(QChar(static_cast<char16_t>(c)));
            }
        }
    } // namespace

    QString flatten(const QString& text, int cap) {
        if (cap <= 0)
            return {};
        QString out;
        out.reserve(qMin<qsizetype>(text.size(), cap + 1));
        bool pendingSpace = false;
        // Every input code point adds at most 3 UTF-16 units (a space, then a pair): stop once the result cannot get shorter
        // than the cap again, so a huge input costs no more than the cap.
        for (qsizetype i = 0; i < text.size() && out.size() <= cap + 2; ++i) {
            char32_t        c = text.at(i).unicode();
            if (QChar::isHighSurrogate(c) && i + 1 < text.size() && QChar::isLowSurrogate(text.at(i + 1).unicode())) {
                c = QChar::surrogateToUcs4(text.at(i), text.at(i + 1));
                ++i;
            } else if (QChar::isSurrogate(c)) {
                c = 0xFFFD;
            }
            if (space(c)) {
                pendingSpace = !out.isEmpty();
                continue;
            }
            if (joiner(c)) {
                // Kept only between two joinable characters of the same word: alone, doubled or at a word's edge it
                // shows nothing and could make one name look like another.
                if (pendingSpace || !joinable(last(out)) || !joinable(at(text, i + 1)))
                    continue;
            } else if (removed(c))
                continue;
            if (pendingSpace) {
                out.append(u' ');
                pendingSpace = false;
            }
            append(out, c);
        }
        if (out.size() <= cap)
            return out;
        // Cut within cap - 1 units, never between the halves of a pair, without a trailing space, then the ellipsis.
        qsizetype cut = cap - 1;
        if (cut > 0 && QChar::isHighSurrogate(out.at(cut - 1).unicode()))
            --cut;
        out.truncate(cut);
        while (!out.isEmpty() && out.back() == u' ')
            out.chop(1);
        out.append(QChar(0x2026));
        return out;
    }

    QString flattenUtf8(const char* text, int cap) {
        return text ? flatten(QString::fromUtf8(text), cap) : QString();
    }

} // namespace gf::prompter
