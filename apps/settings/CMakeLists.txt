cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-settings VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Gui Qml Quick DBus)
# Qt 6.10+ defines the private module targets (Qt6::GuiPrivate, linked below for windowchrome.h) only when asked for.
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)

add_executable(grassfield-settings src/main.cpp src/backend.cpp src/backend.h src/systemguard.cpp src/systemguard.h src/systembus.cpp src/systembus.h src/busjobs.cpp src/busjobs.h src/qtbuscaller.h src/signalqueue.h src/settingsinstance.h src/iconlookup.h src/iconprovider.h
    # Default Apps writes the session list through Files' writer (DefaultApps::writeSessionDefaults; Qt Core only).
    ../files/src/applicationslogic.cpp ../files/src/applicationslogic.h)
# windowchrome.h (ADR-0015): one Qt private header and the three xdg-toplevel-tag requests on libwayland-client.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(grassfield-settings PRIVATE Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT)
target_link_libraries(grassfield-settings PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus)
target_compile_definitions(grassfield-settings PRIVATE
    GRASSFIELD_SETTINGS_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/settings/qml")

install(TARGETS grassfield-settings RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/settings/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Settings.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Settings.svg DESTINATION share/icons/hicolor/scalable/apps)
target_include_directories(grassfield-settings PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n ${CMAKE_CURRENT_SOURCE_DIR}/..)
