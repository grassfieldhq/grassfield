cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-preview VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus)
# Qt 6.10+ defines the private module targets (Qt6::GuiPrivate, linked below for windowchrome.h) only when asked for.
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)
# QtPdf/QtPdfQuick (qt6-webengine) and QtMultimedia are QML modules used at run time.
find_package(Qt6 COMPONENTS Pdf PdfQuick Multimedia)

add_executable(grassfield-preview
    src/main.cpp
    src/previewapp.cpp src/previewapp.h
    src/previewlogic.cpp src/previewlogic.h
    # Same sort order as Grassfield Files for the files of a folder (pure Qt Core logic, shared source).
    ../files/src/filelogic.cpp ../files/src/filelogic.h)
target_include_directories(grassfield-preview PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n ${CMAKE_CURRENT_SOURCE_DIR}/.. ${CMAKE_CURRENT_SOURCE_DIR}/../files/src)
# windowchrome.h (ADR-0015): one Qt private header and the three xdg-toplevel-tag requests on libwayland-client.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(grassfield-preview PRIVATE Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT)
target_link_libraries(grassfield-preview PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus)
target_compile_definitions(grassfield-preview PRIVATE
    GRASSFIELD_PREVIEW_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/preview/qml")

install(TARGETS grassfield-preview RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/preview/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js" PATTERN "*.svg")
install(FILES org.grassfield.Preview.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Preview.svg DESTINATION share/icons/hicolor/scalable/apps)

# Unit tests of the pure logic (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    # tst_previewapp: the backend's worker-thread inspections, snippets and recognitions (offscreen QGuiApplication).
    add_executable(preview-unit-tests ../../tests/unit/preview/tst_previewlogic.cpp ../../tests/unit/preview/tst_shortcutstyle.cpp
                   ../../tests/unit/preview/tst_previewapp.cpp src/previewlogic.cpp src/previewapp.cpp src/previewapp.h
                   ../files/src/filelogic.cpp)
    target_include_directories(preview-unit-tests PRIVATE src ../files/src ..)
    target_link_libraries(preview-unit-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick GTest::gtest GTest::gtest_main)
    add_test(NAME preview-unit-tests COMMAND preview-unit-tests)
endif()
