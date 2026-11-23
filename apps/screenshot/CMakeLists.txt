cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-screenshot VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Grassfield Screenshot (ADR-0066 D-3): the editor of the capture suite; packaged in grassfield-desktop like Preview.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus)
# Qt 6.10+ defines the private module targets (Qt6::GuiPrivate, linked below for windowchrome.h) only when asked for.
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)

# The argument rules, the layers file, the atomic replacement, the history entry, the document and the backend: shared by the
# app and its tests.
add_library(grassfield-screenshot-core STATIC
    src/appearance.cpp src/appearance.h
    src/atomicfile.cpp src/atomicfile.h
    src/capturehistory.cpp src/capturehistory.h
    src/document.cpp src/document.h
    src/layers.cpp src/layers.h
    src/screenshotapp.cpp src/screenshotapp.h
    src/screenshotlogic.cpp src/screenshotlogic.h)
target_include_directories(grassfield-screenshot-core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_link_libraries(grassfield-screenshot-core PUBLIC Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)

add_executable(grassfield-screenshot src/main.cpp)
target_include_directories(grassfield-screenshot PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n)
# windowchrome.h (ADR-0015): one Qt private header and the three xdg-toplevel-tag requests on libwayland-client.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(grassfield-screenshot PRIVATE grassfield-screenshot-core Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT Qt6::DBus)
target_compile_definitions(grassfield-screenshot PRIVATE
    GRASSFIELD_SCREENSHOT_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/screenshot/qml")

install(TARGETS grassfield-screenshot RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/screenshot/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js" PATTERN "*.svg")
install(FILES org.grassfield.Screenshot.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Screenshot.svg
    DESTINATION share/icons/hicolor/scalable/apps)

# Unit tests (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(screenshot-unit-tests
        ../../tests/unit/screenshot/tst_document.cpp
        ../../tests/unit/screenshot/tst_layers.cpp
        ../../tests/unit/screenshot/tst_main.cpp
        ../../tests/unit/screenshot/tst_pathparity.cpp
        ../../tests/unit/screenshot/tst_screenshotlogic.cpp
        # Preview's own path rules, run beside this app's by tst_pathparity (sources not changed).
        ../preview/src/previewlogic.cpp ../files/src/filelogic.cpp)
    target_include_directories(screenshot-unit-tests PRIVATE ../preview/src ../files/src)
    target_link_libraries(screenshot-unit-tests PRIVATE grassfield-screenshot-core GTest::gtest)
    add_test(NAME screenshot-unit-tests COMMAND screenshot-unit-tests)
endif()
