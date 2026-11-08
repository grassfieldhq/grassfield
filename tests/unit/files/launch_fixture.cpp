// The programs tst_fileslaunch.cpp opens through FilesApp::open, one source built several ways (apps/files/build-direct.sh
// --tests, CMakeLists.txt): FIXTURE_PROBE leaves a file named "<its own name>.launched" in its working folder (Files starts
// programs in the home folder) and ends; FIXTURE_STAY does the same and stays two seconds (past Files' one-second watch); FIXTURE_FUSE says what an AppImage runtime without FUSE 2 says and
// ends with an error; FIXTURE_NEEDS_LIBRARY needs libgflaunchmissing.so (FIXTURE_LIBRARY), which no search path reaches. No
// network, nothing outside the working folder.
#include <fcntl.h>
#include <unistd.h>

#if defined(FIXTURE_LIBRARY)
extern "C" int gf_launch_missing()
{
    return 0;
}
#else
#if defined(FIXTURE_NEEDS_LIBRARY)
extern "C" int gf_launch_missing();
#endif

#include <cstring>
#include <string>

namespace
{
// "<the name it was started as>.launched" in the working folder.
void leaveMark(const char *argv0)
{
    const char *slash = std::strrchr(argv0, '/');
    const std::string mark = std::string(slash ? slash + 1 : argv0) + ".launched";
    const int fd = ::creat(mark.c_str(), 0600);
    if (fd >= 0)
        ::close(fd);
}
} // namespace

int main(int argc, char **argv)
{
    const char *self = argc > 0 && argv[0] ? argv[0] : "unknown";
    (void)self;
#if defined(FIXTURE_PROBE)
    leaveMark(self);
    return 0;
#elif defined(FIXTURE_STAY)
    leaveMark(self);
    ::sleep(2);
    return 0;
#elif defined(FIXTURE_FUSE)
    static const char message[] = "dlopen(): error loading libfuse.so.2\n\nAppImages require FUSE to run. \n";
    (void)!::write(2, message, sizeof message - 1);
    return 1;
#elif defined(FIXTURE_NEEDS_LIBRARY)
    leaveMark(self);
    return gf_launch_missing();
#else
    return 2;
#endif
}
#endif
