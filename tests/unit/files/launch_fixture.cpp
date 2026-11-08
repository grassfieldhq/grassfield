// The programs tst_fileslaunch.cpp opens through FilesApp::open, one source built several ways (apps/files/build-direct.sh
// --tests, CMakeLists.txt): FIXTURE_PROBE leaves a file named "launched" in its working folder and ends; FIXTURE_STAY does the
// same and stays two seconds (past Files' one-second watch); FIXTURE_FUSE says what an AppImage runtime without FUSE 2 says and
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

namespace
{
void leaveMark()
{
    const int fd = ::creat("launched", 0600);
    if (fd >= 0)
        ::close(fd);
}
} // namespace

int main()
{
#if defined(FIXTURE_PROBE)
    leaveMark();
    return 0;
#elif defined(FIXTURE_STAY)
    leaveMark();
    ::sleep(2);
    return 0;
#elif defined(FIXTURE_FUSE)
    static const char message[] = "dlopen(): error loading libfuse.so.2\n\nAppImages require FUSE to run. \n";
    (void)!::write(2, message, sizeof message - 1);
    return 1;
#elif defined(FIXTURE_NEEDS_LIBRARY)
    leaveMark();
    return gf_launch_missing();
#else
    return 2;
#endif
}
#endif
