// File probes for the session's Lua configuration (CIO-03, CIO-10): identity, bounded non-blocking reads and plain listings,
// on real files in a private temporary directory.

#include "core/FileProbe.hpp"

#include <gtest/gtest.h>

#include <cstdlib>
#include <fstream>
#include <string>

#include <sys/stat.h>
#include <unistd.h>

using namespace gf::fileprobe;

namespace {
    class FileProbe : public ::testing::Test {
      protected:
        void SetUp() override {
            std::string tmpl = std::string{std::getenv("TMPDIR") ? std::getenv("TMPDIR") : "/tmp"} + "/gf-fileprobe.XXXXXX";
            ASSERT_NE(::mkdtemp(tmpl.data()), nullptr);
            dir = tmpl;
        }
        void TearDown() override {
            std::string cmd = "rm -rf '" + dir + "'";
            (void)std::system(cmd.c_str()); // NOLINT(cert-env33-c): test cleanup of its own directory
        }
        void write(const std::string& name, const std::string& text) const {
            std::ofstream(dir + "/" + name) << text;
        }
        std::string dir;
    };
} // namespace

TEST_F(FileProbe, IdentityChangesWithTheFileNotWithItsDirectoryTimes) {
    write("plugin.so", "one");
    const auto a = identity(dir + "/plugin.so");
    ASSERT_TRUE(a.has_value());
    EXPECT_EQ(a->substr(0, 2), "f:");
    EXPECT_EQ(identity(dir + "/plugin.so"), a) << "stable while nothing changes";
    const auto d = identity(dir);
    ASSERT_TRUE(d.has_value());
    EXPECT_EQ(d->substr(0, 2), "d:");
    write("other", "x"); // the directory's mtime/ctime move
    EXPECT_EQ(identity(dir), d) << "a directory's identity ignores its times (an entry made in $HOME must not re-vet)";
    // Replaced by rename (what the rebuild does): another inode.
    write("new.so", "one");
    ASSERT_EQ(::rename((dir + "/new.so").c_str(), (dir + "/plugin.so").c_str()), 0);
    EXPECT_NE(identity(dir + "/plugin.so"), a);
    // chmod: the ctime and the mode move.
    const auto b = identity(dir + "/plugin.so");
    ASSERT_EQ(::chmod((dir + "/plugin.so").c_str(), 0666), 0);
    EXPECT_NE(identity(dir + "/plugin.so"), b);
    ASSERT_EQ(::chmod(dir.c_str(), 0777), 0);
    EXPECT_NE(identity(dir), d) << "a directory made writable by others has another identity";
}

TEST_F(FileProbe, IdentityLooksAtASymlinkItself) {
    write("target", "t");
    ASSERT_EQ(::symlink((dir + "/target").c_str(), (dir + "/link").c_str()), 0);
    const auto l = identity(dir + "/link");
    ASSERT_TRUE(l.has_value());
    EXPECT_EQ(l->substr(0, 2), "l:");
    EXPECT_FALSE(identity(dir + "/missing").has_value());
    EXPECT_FALSE(identity("relative/path").has_value());
    EXPECT_FALSE(identity(std::string{"/tmp/a\0b", 8}).has_value());
}

TEST_F(FileProbe, ReadRegularIsBoundedAndNeverBlocks) {
    write("wallpaper.json", R"({"ground": "#112233"})");
    EXPECT_EQ(readRegular(dir + "/wallpaper.json", 4096), R"({"ground": "#112233"})");
    EXPECT_EQ(readRegular(dir + "/wallpaper.json", 4), R"({"gr)");
    // A FIFO in the file's place: refused at once (`timeout head` used to guard this; opening it blocking would hang the parse).
    ASSERT_EQ(::mkfifo((dir + "/fifo").c_str(), 0600), 0);
    EXPECT_FALSE(readRegular(dir + "/fifo", 4096).has_value());
    // A symlink, a directory, a missing file: refused.
    ASSERT_EQ(::symlink((dir + "/wallpaper.json").c_str(), (dir + "/link").c_str()), 0);
    EXPECT_FALSE(readRegular(dir + "/link", 4096).has_value());
    EXPECT_FALSE(readRegular(dir, 4096).has_value());
    EXPECT_FALSE(readRegular(dir + "/missing", 4096).has_value());
    // The cap.
    write("big", std::string(kMaxRead + 10, 'x'));
    EXPECT_EQ(readRegular(dir + "/big", kMaxRead * 2)->size(), kMaxRead);
}

TEST_F(FileProbe, ListPlainFilesIsSortedAndPlain) {
    for (const auto* name : {"b.lua", "a.lua", "C.lua", "notes.txt", ".hidden.lua", "bad name.lua", "z-1_x.lua"})
        write(name, "--");
    ASSERT_EQ(::mkdir((dir + "/dir.lua").c_str(), 0700), 0);
    ASSERT_EQ(::symlink((dir + "/a.lua").c_str(), (dir + "/link.lua").c_str()), 0);
    ASSERT_EQ(::mkfifo((dir + "/fifo.lua").c_str(), 0600), 0);
    const auto names = listPlainFiles(dir, ".lua");
    // C collation, as `find ... | sort` gave with LC_ALL=C: uppercase first.
    EXPECT_EQ(names, (std::vector<std::string>{"C.lua", "a.lua", "b.lua", "z-1_x.lua"}));
    EXPECT_TRUE(listPlainFiles(dir + "/missing", ".lua").empty());
    ASSERT_EQ(::symlink(dir.c_str(), (dir + "/dirlink").c_str()), 0);
    EXPECT_TRUE(listPlainFiles(dir + "/dirlink", ".lua").empty()) << "a symlinked directory is not followed";
}

TEST(FileProbeNames, PlainName) {
    EXPECT_TRUE(plainName("terminals.lua", ".lua"));
    EXPECT_FALSE(plainName(".lua", ".lua"));
    EXPECT_FALSE(plainName("a b.lua", ".lua"));
    EXPECT_FALSE(plainName("a.lua.bak", ".lua"));
    EXPECT_FALSE(plainName(std::string(200, 'a') + ".lua", ".lua"));
}
