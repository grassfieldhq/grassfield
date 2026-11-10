cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-files VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Everything but main() is the Files library (files-core.cmake), shared with grassfield-portal's panels.
include(${CMAKE_CURRENT_SOURCE_DIR}/files-core.cmake)

add_executable(grassfield-files src/main.cpp)
target_link_libraries(grassfield-files PRIVATE grassfield-files-core)
target_compile_definitions(grassfield-files PRIVATE
    GRASSFIELD_FILES_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/files/qml")

install(TARGETS grassfield-files RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/files/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Files.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Files.svg DESTINATION share/icons/hicolor/scalable/apps)

# Unit tests of the pure logic (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(files-unit-tests ../../tests/unit/files/tst_filelogic.cpp ../../tests/unit/files/tst_previewqueue.cpp
        ../../tests/unit/files/tst_appicons.cpp ../../tests/unit/files/tst_imageproviders.cpp ../../tests/unit/files/tst_tags.cpp ../../tests/unit/files/tst_folderstyle.cpp ../../tests/unit/files/tst_folderviews.cpp ../../tests/unit/files/tst_imagerotate.cpp ../../tests/unit/files/tst_imagesize.cpp ../../tests/unit/files/tst_recents.cpp ../../tests/unit/files/tst_appscope.cpp ../../tests/unit/files/tst_runmode.cpp ../../tests/unit/files/tst_applications.cpp ../../tests/unit/files/tst_autoappearance.cpp ../../tests/unit/files/tst_launchguard.cpp ../../tests/unit/files/tst_programlaunch.cpp ../../tests/unit/files/tst_menushortcuts.cpp ../../tests/unit/files/tst_navlogic.cpp ../../tests/unit/files/tst_renamelogic.cpp ../../tests/unit/files/tst_permissionlogic.cpp ../../tests/unit/files/tst_batchops.cpp src/batchops.cpp src/navlogic.cpp src/renamelogic.cpp src/permissionlogic.cpp src/filelogic.cpp src/taglogic.cpp src/tagstore.cpp src/launchguard.cpp src/programlaunch.cpp
        src/applicationslogic.cpp src/appicons.cpp src/imageproviders.cpp src/folderstylelogic.cpp src/folderstylestore.cpp src/folderviews.cpp src/imagerotate.cpp src/imagesize.cpp src/recents.cpp src/recents.h ../../tests/unit/files/tst_volumelogic.cpp src/volumelogic.cpp)
    target_include_directories(files-unit-tests PRIVATE src ..)
    # tst_menushortcuts runs Qt.labs.platform menus offscreen (Qml, Widgets, Test) and includes globalmenu.h (DBus).
    find_package(Qt6 REQUIRED COMPONENTS Test)
    # tst_appicons and tst_imageproviders: the icon providers (Qt Quick); the decoder child is the test binary itself.
    target_link_libraries(files-unit-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Qml Qt6::Quick Qt6::DBus Qt6::Test GTest::gtest GTest::gtest_main)
    add_test(NAME files-unit-tests COMMAND files-unit-tests)
    # Grassfield's KIO dialogs (ADR-0035 D-12 a) and the panels' listings (FolderModel.chooser, D-4): real KIO jobs and
    # listings against the Files library; its own main (a scratch home, offscreen).
    # The programs tst_fileslaunch opens through FilesApp::open (tests/unit/files/launch_fixture.cpp): one that leaves a mark
    # in its working folder, one that fails as an AppImage without FUSE 2 does, one linked to a library that is not there.
    set(GF_LAUNCH_FIXTURES ${CMAKE_CURRENT_BINARY_DIR}/launch-fixtures)
    add_library(gflaunchmissing SHARED ../../tests/unit/files/launch_fixture.cpp)
    target_compile_definitions(gflaunchmissing PRIVATE FIXTURE_LIBRARY)
    set_target_properties(gflaunchmissing PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${GF_LAUNCH_FIXTURES}/lib)
    foreach(fixture probe fuse stay needs-library)
        add_executable(launch-${fixture} ../../tests/unit/files/launch_fixture.cpp)
        string(TOUPPER ${fixture} upper)
        string(REPLACE "-" "_" upper ${upper})
        target_compile_definitions(launch-${fixture} PRIVATE FIXTURE_${upper})
        set_target_properties(launch-${fixture} PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${GF_LAUNCH_FIXTURES} OUTPUT_NAME ${fixture} SKIP_BUILD_RPATH TRUE)
    endforeach()
    target_link_libraries(launch-needs-library PRIVATE gflaunchmissing)
    add_executable(files-kio-tests ../../tests/unit/files/tst_kioprompts.cpp ../../tests/unit/files/tst_kiodialogs.cpp
        ../../tests/unit/files/tst_folderchooser.cpp ../../tests/unit/files/tst_diskprobe.cpp
        ../../tests/unit/files/tst_applicationchooser.cpp ../../tests/unit/files/tst_fileops.cpp ../../tests/unit/files/tst_fileslaunch.cpp)
    add_dependencies(files-kio-tests launch-probe launch-fuse launch-stay launch-needs-library)
    target_compile_definitions(files-kio-tests PRIVATE FILES_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/src" FILES_LAUNCH_FIXTURES="${GF_LAUNCH_FIXTURES}")
    target_link_libraries(files-kio-tests PRIVATE grassfield-files-core GTest::gtest)
    add_test(NAME files-kio-tests COMMAND files-kio-tests)
endif()
