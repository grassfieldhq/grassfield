#pragma once

// File probes for the session's Lua configuration (CIO-03, CIO-10): what a config parse used to ask of a shell (`stat`, `test -f`
// then `timeout head`, `find | sort`) on Hyprland's main thread, done in-process without a fork. Plain POSIX, no Hyprland
// includes (compositor/tests/FileProbeTest.cpp); the Lua glue is src/Ipc.cpp (hl.plugin.grassfield.file_identity, read_file,
// list_files). Read only: every path is looked at itself (lstat, O_NOFOLLOW), nothing ever blocks (O_NONBLOCK: a FIFO in a
// file's place is refused, not waited on), every read is bounded.

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gf::fileprobe {

    inline constexpr size_t kMaxPath      = 4096;
    inline constexpr size_t kMaxRead      = 65536; // read_file: the largest size a caller may ask for
    inline constexpr size_t kMaxListed    = 256;   // list_files: at most this many names
    inline constexpr size_t kMaxNameBytes = 128;

    // The identity of `path` itself (lstat, a symlink is not followed): "<kind>:<dev>:<ino>:<mode>:<uid>" for a directory
    // ("d") and "<kind>:<dev>:<ino>:<mode>:<uid>:<size>:<mtime ns>:<ctime ns>" for anything else ("f" a regular file, "l" a
    // symlink, "o" other). A file replaced (rename, new inode), rewritten (size, mtime) or whose owner or mode changed (ctime)
    // has another identity. A directory's times move with every entry made in it, so they are left out: its owner and mode
    // decide. nullopt: no such path, or not an absolute path without NUL.
    std::optional<std::string> identity(std::string_view path);

    // The contents of a regular file, at most `max` bytes (capped at kMaxRead): nullopt when `path` is a symlink, not a regular
    // file, cannot be opened without blocking, or is not an absolute path.
    std::optional<std::string> readRegular(std::string_view path, size_t max);

    // The names in directory `dir` (not followed when it is a symlink) of the regular files whose name has `suffix` and is made
    // of letters, digits, '.', '_' and '-' only (at most kMaxNameBytes), sorted bytewise (C collation, as `sort` with
    // LC_ALL=C), at most kMaxListed. Empty when the directory cannot be read.
    std::vector<std::string> listPlainFiles(std::string_view dir, std::string_view suffix);

    // A name listPlainFiles accepts (pure, for the tests).
    bool plainName(std::string_view name, std::string_view suffix);

} // namespace gf::fileprobe
