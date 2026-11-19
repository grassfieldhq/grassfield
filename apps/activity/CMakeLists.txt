cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-activity VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Activity Monitor (ADR-0038). Step 1: the sampler (plain C++17 and POSIX, no Qt; step 2c's signal path and step 2d's
# Inspect reader with it), its unit tests and its bench (tests/apps/activity_cost.sh). Step 2: the window's backend (Qt
# Core, Gui and DBus) and the app with its QML, its desktop entry and its icon, packaged in grassfield-desktop (AD2).
add_library(grassfield-activity-sampler STATIC
    src/inspect.cpp src/inspect.h
    src/machine.cpp src/machine.h
    src/netdiag.cpp src/netdiag.h
    src/procparse.cpp src/procparse.h
    src/sampler.cpp src/sampler.h
    src/signals.cpp src/signals.h
    src/textclean.cpp src/textclean.h
    src/units.cpp src/units.h)
target_include_directories(grassfield-activity-sampler PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)

# A dev and test tool, never installed.
add_executable(activity-sampler-bench src/bench.cpp)
target_link_libraries(activity-sampler-bench PRIVATE grassfield-activity-sampler pthread)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus)
# Qt 6.10+ defines the private module targets (Qt6::GuiPrivate, linked below for windowchrome.h) only when asked for.
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)

add_library(grassfield-activity-window STATIC
    src/actions.cpp src/actions.h
    src/activityapp.cpp src/activityapp.h
    src/apphistory.cpp src/apphistory.h
    src/activitystate.cpp src/activitystate.h
    src/battery.cpp src/battery.h
    src/columns.cpp src/columns.h
    src/desktopapps.cpp src/desktopapps.h
    src/efficiency.cpp src/efficiency.h
    src/format.cpp src/format.h
    src/graphgeometry.cpp src/graphgeometry.h
    src/inhibitors.cpp src/inhibitors.h
    src/inspection.cpp src/inspection.h src/shownwatch.h
    src/performance.cpp src/performance.h
    src/processtable.cpp src/processtable.h
    src/runtimefiles.cpp src/runtimefiles.h
    src/samplerworker.cpp src/samplerworker.h
    src/summary.cpp src/summary.h)
target_include_directories(grassfield-activity-window PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n)
target_link_libraries(grassfield-activity-window PUBLIC grassfield-activity-sampler Qt6::Core Qt6::Gui Qt6::DBus pthread)

add_executable(grassfield-activity src/main.cpp src/iconprovider.h src/shownwatch.h src/graphitem.cpp src/graphitem.h)
# windowchrome.h (ADR-0015): one Qt private header and the three xdg-toplevel-tag requests on libwayland-client.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(grassfield-activity PRIVATE grassfield-activity-window Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT
    Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus)
target_compile_definitions(grassfield-activity PRIVATE
    GRASSFIELD_ACTIVITY_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/activity/qml")

install(TARGETS grassfield-activity RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/activity/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Activity.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Activity.svg
    DESTINATION share/icons/hicolor/scalable/apps)

find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(activity-unit-tests
        ../../tests/unit/activity/tst_inspect.cpp
        ../../tests/unit/activity/tst_machine.cpp
        ../../tests/unit/activity/tst_memory.cpp
        ../../tests/unit/activity/tst_netdiag.cpp
        ../../tests/unit/activity/tst_procparse.cpp
        ../../tests/unit/activity/tst_sampler.cpp
        ../../tests/unit/activity/tst_signals.cpp
        ../../tests/unit/activity/tst_textclean.cpp
        ../../tests/unit/activity/tst_units.cpp)
    target_link_libraries(activity-unit-tests PRIVATE grassfield-activity-sampler GTest::gtest GTest::gtest_main)
    add_test(NAME activity-unit-tests COMMAND activity-unit-tests)

    # The window's backend: its own main (a QCoreApplication around the cases).
    find_package(Qt6 REQUIRED COMPONENTS Test)
    add_executable(activity-window-tests
        ../../tests/unit/activity/window/tst_actions.cpp
        ../../tests/unit/activity/window/tst_activityapp.cpp
        ../../tests/unit/activity/window/tst_apphistory.cpp
        ../../tests/unit/activity/window/tst_efficiency.cpp
        ../../tests/unit/activity/window/tst_format.cpp
        ../../tests/unit/activity/window/tst_inspection.cpp
        ../../tests/unit/activity/window/tst_main.cpp
        ../../tests/unit/activity/window/tst_performance.cpp
        ../../tests/unit/activity/window/tst_processtable.cpp
        ../../tests/unit/activity/window/tst_runtimefiles.cpp
        ../../tests/unit/activity/window/tst_summary.cpp)
    target_include_directories(activity-window-tests PRIVATE ../../tests/unit/activity)
    target_link_libraries(activity-window-tests PRIVATE grassfield-activity-window Qt6::Test GTest::gtest)
    add_test(NAME activity-window-tests COMMAND activity-window-tests)

    # A-W1: the window with its real backend on a fixture tree, offscreen (its own main).
    add_executable(activity-window-qml-tests ../../tests/unit/activity/qml/tst_window.cpp
        ../../tests/unit/activity/qml/tst_keywindow.cpp ../../tests/unit/activity/qml/tst_graph.cpp src/graphitem.cpp src/graphitem.h)
    # tst_keywindow: apps/keywindow.h, shared by the five apps (the focus taken away through Qt's window-system API).
    target_include_directories(activity-window-qml-tests PRIVATE ../../tests/unit/activity)
    target_compile_definitions(activity-window-qml-tests PRIVATE ACTIVITY_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/../..")
    target_link_libraries(activity-window-qml-tests PRIVATE grassfield-activity-window Qt6::Gui Qt6::GuiPrivate Qt6::Qml
        Qt6::Quick Qt6::Test GTest::gtest)
    add_test(NAME activity-window-qml-tests COMMAND activity-window-qml-tests)
endif()
