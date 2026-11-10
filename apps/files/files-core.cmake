# The Files library (ADR-0035 D-4, decision 4b-1): Grassfield Files without its main(). grassfield-files links it, and so
# does grassfield-portal, whose Open and Save panels are the Files browser (one code base, not a copy). Included by
# apps/files/CMakeLists.txt and apps/portal/CMakeLists.txt; the one CMake list of Files' sources.
if(TARGET grassfield-files-core)
    return()
endif()

set(KF_MIN_VERSION "6.17") # FileUndoManager::redo()
find_package(ECM ${KF_MIN_VERSION} NO_MODULE)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Qml Quick DBus Network)
# Qt 6.10+ defines the private module targets (Qt6::GuiPrivate, linked below for windowchrome.h) only when asked for.
find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)
# KDE Frameworks are separate CMake packages (there is no umbrella "KF6" package).
find_package(KF6KIO ${KF_MIN_VERSION} REQUIRED)
find_package(KF6CoreAddons ${KF_MIN_VERSION} REQUIRED)
find_package(KF6Service ${KF_MIN_VERSION} REQUIRED)
find_package(KF6Solid ${KF_MIN_VERSION} REQUIRED)
# windowchrome.h (ADR-0015): one Qt private header and the three xdg-toplevel-tag requests on libwayland-client.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)

set(GF_FILES_SRC ${CMAKE_CURRENT_LIST_DIR}/src)
add_library(grassfield-files-core STATIC
    ${GF_FILES_SRC}/filesapp.cpp ${GF_FILES_SRC}/filesapp.h
    ${GF_FILES_SRC}/foldermodel.cpp ${GF_FILES_SRC}/foldermodel.h
    ${GF_FILES_SRC}/placesmodel.cpp ${GF_FILES_SRC}/placesmodel.h
    ${GF_FILES_SRC}/diskprobe.cpp ${GF_FILES_SRC}/diskprobe.h
    ${GF_FILES_SRC}/volumelogic.cpp ${GF_FILES_SRC}/volumelogic.h
    ${GF_FILES_SRC}/imageproviders.cpp ${GF_FILES_SRC}/imageproviders.h
    ${GF_FILES_SRC}/filelogic.cpp ${GF_FILES_SRC}/filelogic.h
    ${GF_FILES_SRC}/launchguard.cpp ${GF_FILES_SRC}/launchguard.h
    ${GF_FILES_SRC}/programlaunch.cpp ${GF_FILES_SRC}/programlaunch.h
    ${GF_FILES_SRC}/taglogic.cpp ${GF_FILES_SRC}/taglogic.h
    ${GF_FILES_SRC}/tagstore.cpp ${GF_FILES_SRC}/tagstore.h
    ${GF_FILES_SRC}/tagsearch.cpp ${GF_FILES_SRC}/tagsearch.h
    ${GF_FILES_SRC}/searchlogic.cpp ${GF_FILES_SRC}/searchlogic.h
    ${GF_FILES_SRC}/navlogic.cpp ${GF_FILES_SRC}/navlogic.h
    ${GF_FILES_SRC}/renamelogic.cpp ${GF_FILES_SRC}/renamelogic.h
    ${GF_FILES_SRC}/archivelogic.cpp ${GF_FILES_SRC}/archivelogic.h
    ${GF_FILES_SRC}/batchops.cpp ${GF_FILES_SRC}/batchops.h
    ${GF_FILES_SRC}/archivejob.cpp ${GF_FILES_SRC}/archivejob.h
    ${GF_FILES_SRC}/permissionlogic.cpp ${GF_FILES_SRC}/permissionlogic.h
    ${GF_FILES_SRC}/filesearch.cpp ${GF_FILES_SRC}/filesearch.h
    ${GF_FILES_SRC}/savedsearches.cpp ${GF_FILES_SRC}/savedsearches.h
    ${GF_FILES_SRC}/applicationslogic.cpp ${GF_FILES_SRC}/applicationslogic.h
    ${GF_FILES_SRC}/appicons.cpp ${GF_FILES_SRC}/appicons.h
    ${GF_FILES_SRC}/folderstylelogic.cpp ${GF_FILES_SRC}/folderstylelogic.h
    ${GF_FILES_SRC}/folderstylestore.cpp ${GF_FILES_SRC}/folderstylestore.h
    ${GF_FILES_SRC}/folderviews.cpp ${GF_FILES_SRC}/folderviews.h
    ${GF_FILES_SRC}/imagerotate.cpp ${GF_FILES_SRC}/imagerotate.h
    ${GF_FILES_SRC}/imagesize.cpp ${GF_FILES_SRC}/imagesize.h
    ${GF_FILES_SRC}/recents.cpp ${GF_FILES_SRC}/recents.h
    ${GF_FILES_SRC}/kioprompts.cpp ${GF_FILES_SRC}/kioprompts.h
    ${GF_FILES_SRC}/applicationchooser.cpp ${GF_FILES_SRC}/applicationchooser.h
    ${GF_FILES_SRC}/kiopromptlogic.cpp ${GF_FILES_SRC}/kiopromptlogic.h
    ${CMAKE_CURRENT_LIST_DIR}/../ongoing.h)
set_target_properties(grassfield-files-core PROPERTIES AUTOMOC ON POSITION_INDEPENDENT_CODE ON)
target_compile_features(grassfield-files-core PUBLIC cxx_std_17)
target_include_directories(grassfield-files-core PUBLIC ${GF_FILES_SRC} ${CMAKE_CURRENT_LIST_DIR}/..
    ${CMAKE_CURRENT_LIST_DIR}/../../ui/i18n)
target_link_libraries(grassfield-files-core PUBLIC Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT
    Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Qml Qt6::Quick Qt6::DBus Qt6::Network
    KF6::KIOCore KF6::KIOGui KF6::KIOWidgets KF6::CoreAddons KF6::Service KF6::Solid)
target_compile_definitions(grassfield-files-core PUBLIC KF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00)
