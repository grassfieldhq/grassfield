# The plugin's ABI stamp (ADR-0009 "Amendment 2026-10-23"): the string Hyprland compares with its own hash
# (PluginAPI.hpp __hyprland_api_get_client_hash: the commit, then the aquamarine, hyprutils, hyprgraphics, hyprcursor and
# hyprlang versions without their patch number; the same string in 0.56 and 0.57, which builds it with std::format), computed
# from the version.h the plugin is compiled against and written
# next to it, so that a stamp always belongs to its build.
# Usage (CMakeLists.txt runs it): cmake -DVERSION_H=<hyprland/src/version.h> -DOUT=<grassfield-compositor.abi> -P abi-stamp.cmake
# The same formula: packaging/arch/grassfield-compositor-rebuild abi_of, config/hypr/grassfield/compositor.lua M.abi
# (tests/shell/compositor_rebuild.sh checks the three agree).

if(NOT VERSION_H OR NOT OUT)
  message(FATAL_ERROR "abi-stamp.cmake: VERSION_H and OUT are required")
endif()
file(READ "${VERSION_H}" text)

function(gf_define name out)
  string(REGEX MATCH "#define[ \t]+${name}[ \t]+\"([^\"\n]*)\"" found "${text}")
  set(${out} "${CMAKE_MATCH_1}" PARENT_SCOPE)
endfunction()

# What follows the last dot goes ("0.15.0" -> "0.15", "1" -> "1").
function(gf_strip_patch value out)
  string(FIND "${value}" "." dot REVERSE)
  if(dot EQUAL -1)
    set(${out} "${value}" PARENT_SCOPE)
  else()
    string(SUBSTRING "${value}" 0 ${dot} stripped)
    set(${out} "${stripped}" PARENT_SCOPE)
  endif()
endfunction()

gf_define(GIT_COMMIT_HASH commit)
set(abi "${commit}")
foreach(pair "AQUAMARINE_VERSION;aq" "HYPRUTILS_VERSION;hu" "HYPRGRAPHICS_VERSION;hg" "HYPRCURSOR_VERSION;hc" "HYPRLANG_VERSION;hlg")
  list(GET pair 0 name)
  list(GET pair 1 tag)
  gf_define(${name} value)
  if(value STREQUAL "")
    message(FATAL_ERROR "abi-stamp.cmake: ${name} missing in ${VERSION_H}")
  endif()
  gf_strip_patch("${value}" minor)
  string(APPEND abi "_${tag}_${minor}")
endforeach()
if(commit STREQUAL "")
  message(FATAL_ERROR "abi-stamp.cmake: GIT_COMMIT_HASH missing in ${VERSION_H}")
endif()
file(WRITE "${OUT}" "${abi}\n")
