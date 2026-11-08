cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-qt-platform-theme VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)

# ADR-0054: a Qt platform-theme plugin (QPA, private API: Qt6::GuiPrivate), installed in Qt's platformthemes directory and
# rebuilt with every Qt minor release (the update hold pins qt6-base's major.minor; BUILD-DEPS records the build's version).
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# The private module is the point of this plugin (QPA): its warning is switched off here, the ADR states the cost.
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui GuiPrivate)

qt_add_plugin(grassfield-qt-theme PLUGIN_TYPE platformthemes CLASS_NAME GrassfieldThemePlugin)
target_sources(grassfield-qt-theme PRIVATE src/GrassfieldThemePlugin.cpp)
target_link_libraries(grassfield-qt-theme PRIVATE Qt6::Core Qt6::Gui Qt6::GuiPrivate)
# Q_PLUGIN_METADATA(FILE ...) is found through the include path.
target_include_directories(grassfield-qt-theme PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# Qt's plugin directory under the install prefix (/usr/lib/qt6/plugins on Arch).
install(TARGETS grassfield-qt-theme LIBRARY DESTINATION lib/qt6/plugins/platformthemes)

# The Qt release this build used, next to the plugin's other files: config/hypr/grassfield/qttheme.lua selects the plugin only
# when the Qt that runs has the same major.minor (QPA is private API; a different minor release can change the classes the
# plugin is built on).
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/qt-version "${Qt6_VERSION}\n")
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/qt-version DESTINATION share/grassfield/qt-platform-theme)
