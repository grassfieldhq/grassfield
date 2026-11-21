cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-store VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Grassfield Store (ADR-0037). Step 1: the read-only backend (the catalog's fetch, signature, rules and cache; Arch's
# AppStream, installed or fetched; pacman's databases; the merged model and search). Step 2: the window's backend
# (StoreBackend, StoreView) and the app with its QML. Step 3: the plan check, the removal rule and the queue of operations,
# with the root helper and its polkit policy (packaging/store/), installed here and packaged as grassfield-store.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Network Qml Quick DBus)
# Qt 6.10+ defines the private module targets (Qt6::GuiPrivate, linked below for windowchrome.h) only when asked for.
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)
find_package(ZLIB REQUIRED)

add_library(grassfield-store-backend STATIC
    src/appstream.cpp src/appstream.h
    src/appstreamsource.cpp src/appstreamsource.h
    src/aur.cpp src/aur.h
    src/catalog.cpp src/catalog.h
    src/catalogstore.cpp src/catalogstore.h
    src/channel.cpp src/channel.h
    src/childprocess.cpp src/childprocess.h
    src/fetch.cpp src/fetch.h
    src/flatpak.cpp src/flatpak.h
    src/flatpakpermissions.cpp src/flatpakpermissions.h
    src/operations.cpp src/operations.h
    src/pacman.cpp src/pacman.h
    src/plancheck.cpp src/plancheck.h
    src/removal.cpp src/removal.h
    src/signature.cpp src/signature.h
    src/statefile.cpp src/statefile.h
    src/storebackend.cpp src/storebackend.h
    src/storeenv.h
    src/storemodel.cpp src/storemodel.h
    src/storeview.cpp src/storeview.h
    ../ongoing.h)
target_include_directories(grassfield-store-backend PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/..
    ${CMAKE_CURRENT_SOURCE_DIR}/../../ui/i18n)
# Qt6::DBus: the ongoing activity of the running operation (ADR-0052, apps/ongoing.h).
target_link_libraries(grassfield-store-backend PUBLIC Qt6::Core Qt6::Gui Qt6::Network Qt6::DBus ZLIB::ZLIB)

add_executable(grassfield-store src/main.cpp src/screenshotprovider.cpp src/screenshotprovider.h src/storeinstance.h)
# windowchrome.h (ADR-0015): one Qt private header and the three xdg-toplevel-tag requests on libwayland-client.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(grassfield-store PRIVATE grassfield-store-backend Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT
    Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus)
target_compile_definitions(grassfield-store PRIVATE GRASSFIELD_STORE_QML_DIR="${CMAKE_INSTALL_PREFIX}/share/grassfield/store/qml")

install(TARGETS grassfield-store RUNTIME DESTINATION bin)
install(DIRECTORY qml/ DESTINATION share/grassfield/store/qml FILES_MATCHING PATTERN "*.qml" PATTERN "*.js")
install(FILES org.grassfield.Store.desktop DESTINATION share/applications)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../branding/icons/apps/org.grassfield.Store.svg DESTINATION share/icons/hicolor/scalable/apps)
# The root helper of repository installs and removals and its polkit action (ADR-0037 b.1): the only root code of the Store.
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/../../packaging/store/grassfield-store-helper DESTINATION lib/grassfield)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../packaging/store/org.grassfield.store.policy DESTINATION share/polkit-1/actions)
# The script an Omarchy setup runs through in Omarchy's terminal, as the user (ADR-0037 b.2).
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/../../packaging/store/grassfield-store-run DESTINATION lib/grassfield)

# Unit tests (gtest), also run by scripts/dev/test.sh through build-direct.sh --tests.
find_package(GTest)
if(GTest_FOUND)
    enable_testing()
    add_executable(store-unit-tests
        ../../tests/unit/store/tst_appstream.cpp
        ../../tests/unit/store/tst_aur.cpp
        ../../tests/unit/store/tst_catalog.cpp
        ../../tests/unit/store/tst_catalogstore.cpp
        ../../tests/unit/store/tst_channel.cpp
        ../../tests/unit/store/tst_childprocess.cpp
        ../../tests/unit/store/tst_fetch.cpp
        ../../tests/unit/store/tst_flatpak.cpp
        ../../tests/unit/store/tst_flatpakpermissions.cpp
        ../../tests/unit/store/tst_operations.cpp
        ../../tests/unit/store/tst_pacman.cpp
        ../../tests/unit/store/tst_plancheck.cpp
        ../../tests/unit/store/tst_removal.cpp
        ../../tests/unit/store/tst_screenshotprovider.cpp src/screenshotprovider.cpp src/screenshotprovider.h
        ../../tests/unit/store/tst_signature.cpp
        ../../tests/unit/store/tst_storebackend.cpp
        ../../tests/unit/store/tst_storeinstance.cpp src/storeinstance.h
        ../../tests/unit/store/tst_storemodel.cpp
        ../../tests/unit/store/tst_storeview.cpp)
    # Qt6::Quick: the screenshot provider's cancel (tst_screenshotprovider.cpp).
    target_link_libraries(store-unit-tests PRIVATE grassfield-store-backend Qt6::DBus Qt6::Quick GTest::gtest GTest::gtest_main)
    target_compile_definitions(store-unit-tests PRIVATE STORE_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/store")
    add_test(NAME store-unit-tests COMMAND store-unit-tests)
endif()
