cmake_minimum_required(VERSION 3.21)
include(${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/GrassfieldVersion.cmake) # VERSION at the repository root
project(grassfield-i18n VERSION ${GF_VERSION_NUMERIC} LANGUAGES CXX)
add_compile_definitions(GRASSFIELD_VERSION="${GF_VERSION}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml LinguistTools)
qt_policy(SET QTP0001 NEW)

# Backing library STATIC (linked into the plugin, so the plugin .so is the only file to install); the
# plugin class lives in the PLUGIN target: qs loads that .so, which must carry the Qt plugin metadata.
qt_add_library(grassfield_i18n STATIC)
qt_add_plugin(grassfield_i18nplugin SHARED CLASS_NAME GrassfieldI18nPlugin)
qt_add_qml_module(grassfield_i18n
    URI Grassfield.I18n
    VERSION 1.0
    PLUGIN_TARGET grassfield_i18nplugin
    CLASS_NAME GrassfieldI18nPlugin
    NO_GENERATE_PLUGIN_SOURCE
    OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/Grassfield/I18n
    SOURCES translator.h translator.cpp timezones.h timezones.cpp translationloader.h iconsearchpaths.h)
set_target_properties(grassfield_i18n PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_link_libraries(grassfield_i18n PRIVATE Qt6::Core Qt6::Qml)
target_sources(grassfield_i18nplugin PRIVATE plugin.cpp)
target_include_directories(grassfield_i18nplugin PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(grassfield_i18nplugin PRIVATE Qt6::Core Qt6::Gui Qt6::Qml)

# Catalogs: translations/grassfield_<lang>.ts -> grassfield_<lang>.qm
file(GLOB GRASSFIELD_TS ${CMAKE_CURRENT_SOURCE_DIR}/../../translations/grassfield_*.ts)
qt_add_lrelease(grassfield_i18n TS_FILES ${GRASSFIELD_TS} QM_FILES_OUTPUT_VARIABLE GRASSFIELD_QM)

install(TARGETS grassfield_i18nplugin LIBRARY DESTINATION lib/qt6/qml/Grassfield/I18n)
install(DIRECTORY ${CMAKE_BINARY_DIR}/Grassfield/I18n/ DESTINATION lib/qt6/qml/Grassfield/I18n
        FILES_MATCHING PATTERN "qmldir" PATTERN "*.qmltypes")
install(FILES ${GRASSFIELD_QM} DESTINATION share/grassfield/translations)
