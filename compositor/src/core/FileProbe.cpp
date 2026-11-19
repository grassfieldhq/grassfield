#include "core/FileProbe.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace gf::fileprobe {

    namespace {
        // An absolute path without NUL, short enough: the only paths the probes look at.
        std::optional<std::string> checkedPath(std::string_view path) {
            if (path.empty() || path.front() != '/' || path.size() >= kMaxPath || path.find('\0') != std::string_view::npos)
                return std::nullopt;
            return std::string{path};
        }

        long long nanos(const struct timespec& ts) {
            return (static_cast<long long>(ts.tv_sec) * 1000000000LL) + ts.tv_nsec;
        }

        // Closes the descriptor on every path out.
        struct SFd {
            int fd = -1;
            ~SFd() {
                if (fd >= 0)
                    ::close(fd);
            }
        };
    } // namespace

    std::optional<std::string> identity(std::string_view path) {
        const auto p = checkedPath(path);
        if (!p)
            return std::nullopt;
        struct stat st{};
        if (::lstat(p->c_str(), &st) != 0)
            return std::nullopt;
        const auto mode = static_cast<unsigned>(st.st_mode & 07777U);
        if (S_ISDIR(st.st_mode))
            return "d:" + std::to_string(st.st_dev) + ":" + std::to_string(st.st_ino) + ":" + std::to_string(mode) + ":" + std::to_string(st.st_uid);
        const char* kind = S_ISREG(st.st_mode) ? "f" : S_ISLNK(st.st_mode) ? "l" : "o";
        return std::string{kind} + ":" + std::to_string(st.st_dev) + ":" + std::to_string(st.st_ino) + ":" + std::to_string(mode) + ":" +
            std::to_string(st.st_uid) + ":" + std::to_string(st.st_size) + ":" + std::to_string(nanos(st.st_mtim)) + ":" + std::to_string(nanos(st.st_ctim));
    }

    std::optional<std::string> readRegular(std::string_view path, size_t max) {
        const auto p = checkedPath(path);
        if (!p)
            return std::nullopt;
        // O_NONBLOCK: opening a FIFO for reading would otherwise wait for a writer; O_NOFOLLOW: a symlink is refused.
        SFd file{::open(p->c_str(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY)};
        if (file.fd < 0)
            return std::nullopt;
        struct stat st{};
        if (::fstat(file.fd, &st) != 0 || !S_ISREG(st.st_mode))
            return std::nullopt;
        const size_t limit = std::min(max, kMaxRead);
        std::string out;
        out.resize(limit);
        size_t got = 0;
        while (got < limit) {
            const auto n = ::read(file.fd, out.data() + got, limit - got);
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0)
                return std::nullopt;
            if (n == 0)
                break;
            got += static_cast<size_t>(n);
        }
        out.resize(got);
        return out;
    }

    bool plainName(std::string_view name, std::string_view suffix) {
        if (name.empty() || name.size() > kMaxNameBytes || name.size() <= suffix.size() || !name.ends_with(suffix) || name.front() == '.')
            return false;
        return std::ranges::all_of(name, [](char c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        });
    }

    std::vector<std::string> listPlainFiles(std::string_view dir, std::string_view suffix) {
        std::vector<std::string> names;
        const auto               p = checkedPath(dir);
        if (!p)
            return names;
        SFd handle{::open(p->c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (handle.fd < 0)
            return names;
        DIR* d = ::fdopendir(handle.fd);
        if (!d)
            return names;
        handle.fd = -1; // owned by the DIR now
        while (const auto* entry = ::readdir(d)) {
            const std::string_view name{entry->d_name};
            if (!plainName(name, suffix))
                continue;
            // Looked at itself, relative to the directory already open (no path is resolved twice).
            struct stat st{};
            if (::fstatat(::dirfd(d), entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(st.st_mode))
                continue;
            names.emplace_back(name);
            if (names.size() > kMaxListed * 4)
                break; // a huge directory: enough to sort and keep the first kMaxListed
        }
        ::closedir(d);
        std::ranges::sort(names);
        if (names.size() > kMaxListed)
            names.resize(kMaxListed);
        return names;
    }

} // namespace gf::fileprobe
