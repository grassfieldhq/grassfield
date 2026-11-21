#pragma once

// Text a secret sheet shows that does not come from Grassfield: the caller's title, message, description, warning and
// labels, a desktop entry's name, an executable's path (ADR-0035 D-9: plain text, flattened and capped, under the fixed
// rows). Pure logic (QtCore only), unit-tested in tests/unit/prompter/.

#include <QString>

namespace gf::prompter {

    namespace caps {
        inline constexpr int kTitle       = 128;  // UTF-16 code units, the ellipsis included
        inline constexpr int kMessage     = 256;
        inline constexpr int kDescription = 1024;
        inline constexpr int kWarning     = 256;
        inline constexpr int kChoice      = 128;  // the check box's label
        inline constexpr int kButton      = 32;   // continue and cancel labels
        inline constexpr int kName        = 128;  // a desktop entry's Name
        inline constexpr int kIcon        = 256;  // a desktop entry's Icon (a theme name or an absolute path)
        inline constexpr int kDesktopId   = 256;
        inline constexpr int kPath        = 512;  // an executable's path
    } // namespace caps

    // One line of plain text, at most `cap` UTF-16 code units:
    // - C0 and C1 control characters (tab, line feed and carriage return included), DEL, and the line and paragraph
    //   separators U+2028 and U+2029 become spaces;
    // - characters that change how other text is shown and show nothing themselves are removed: bidirectional marks,
    //   embeddings, overrides and isolates (U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069), zero-width and invisible
    //   formatting characters (U+00AD, U+034F, U+180E, U+200B, U+2060-U+2064, U+FEFF), the joiners U+200C and U+200D
    //   except between two letters, marks or symbols (emoji ZWJ sequences, Persian and Indic text: B-19), interlinear annotation
    //   (U+FFF9-U+FFFB), tag characters (U+E0000-U+E007F) and noncharacters;
    // - an unpaired surrogate becomes U+FFFD;
    // - every run of white space becomes one space, and the ends are trimmed;
    // - text longer than `cap` is cut on a code point boundary and ends with the ellipsis U+2026, the whole within `cap`.
    QString flatten(const QString& text, int cap);

    // flatten() of UTF-8 bytes (invalid sequences become U+FFFD); nullptr reads as empty.
    QString flattenUtf8(const char* text, int cap);

} // namespace gf::prompter
