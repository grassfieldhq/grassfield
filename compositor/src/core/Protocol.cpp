#include "Protocol.hpp"

#include <format>

#include <array>
#include <cstdint>
#include <string>

namespace gf::gfc {

    std::string jsonEscape(std::string_view in) {
        static constexpr std::array<char, 16> HEX = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};

        std::string out;
        out.reserve(in.size() + 2);
        for (const char c : in) {
            switch (c) {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\b': out += "\\b"; break;
                case '\f': out += "\\f"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default: {
                    const auto u = static_cast<uint8_t>(c);
                    if (u < 0x20) {
                        out += "\\u00";
                        out += HEX[u >> 4];
                        out += HEX[u & 0xF];
                    } else
                        out += c; // UTF-8 bytes >= 0x80 pass through unchanged
                }
            }
        }
        return out;
    }

    namespace {
        void appendHeader(std::string& out, std::string_view type) {
            out += R"({"v":")";
            out += jsonEscape(kVersion);
            out += R"(","type":")";
            out += jsonEscape(type);
            out += '"';
        }
    } // namespace

    std::string capabilitiesJson(std::span<const std::string_view> features) {
        std::string out;
        appendHeader(out, "capabilities");
        out += R"(,"features":[)";
        bool first = true;
        for (const auto& f : features) {
            if (!first)
                out += ',';
            first = false;
            out += '"';
            out += jsonEscape(f);
            out += '"';
        }
        out += "]}";
        return out;
    }

    namespace {
        std::string windowEventJson(std::string_view type, std::string_view windowAddress) {
            std::string out;
            appendHeader(out, type);
            out += R"(,"address":")";
            out += jsonEscape(windowAddress);
            out += "\"}";
            return out;
        }
    } // namespace

    std::string minimizeRequestJson(std::string_view windowAddress) {
        return windowEventJson("minimize-request", windowAddress);
    }

    std::string minimizedJson(std::string_view windowAddress) {
        return windowEventJson("minimized", windowAddress);
    }

    std::string restoredJson(std::string_view windowAddress) {
        return windowEventJson("restored", windowAddress);
    }

    std::string appmenuJson(std::string_view windowAddress, std::string_view service, std::string_view path, int pid) {
        std::string out;
        appendHeader(out, "appmenu");
        out += R"(,"address":")";
        out += jsonEscape(windowAddress);
        out += R"(","service":")";
        out += jsonEscape(service);
        out += R"(","path":")";
        out += jsonEscape(path);
        out += R"(","pid":)";
        out += std::to_string(pid > 0 ? pid : 0);
        out += '}';
        return out;
    }

    std::string keyboardFocusJson(std::string_view windowAddress) {
        return windowEventJson("keyboard-focus", windowAddress);
    }

    std::string titlebarRevealJson(std::string_view output, bool revealed) {
        std::string out;
        appendHeader(out, "titlebar-reveal");
        out += R"(,"output":")";
        out += jsonEscape(output);
        out += std::format(R"(","revealed":{}}})", revealed);
        return out;
    }

    std::vector<std::string_view> features(bool minimize, bool config, bool appmenu, bool overview, bool desktopFocus, bool stagesAvailable, bool stagesEnabled,
                                           bool cursorRefresh, bool overviewFocus, bool minimizeEffect, bool windowTiling, bool layerPointer, bool appearance,
                                           bool clientChrome, bool frameTimes, bool keyboardFocus, bool tilingArrange, bool tileHover, bool tilingGroups,
                                           bool sharedEdge, bool split, bool toplevelDrag) {
        std::vector<std::string_view> out{kFeatureDecorations};
        if (minimize)
            out.push_back(kFeatureMinimize);
        if (config)
            out.push_back(kFeatureConfig);
        if (appmenu)
            out.push_back(kFeatureAppmenu);
        if (overview)
            out.push_back(kFeatureOverview);
        if (desktopFocus) {
            out.push_back(kFeatureDesktopFocus);
            out.push_back(kFeatureDesktopFocusV2);
        }
        if (stagesAvailable) {
            out.push_back(kFeatureStagesAvailable);
            if (stagesEnabled)
                out.push_back(kFeatureStages);
        }
        if (cursorRefresh)
            out.push_back(kFeatureCursorRefresh);
        if (overviewFocus)
            out.push_back(kFeatureOverviewFocus);
        if (minimizeEffect)
            out.push_back(kFeatureMinimizeEffect);
        if (windowTiling) {
            out.push_back(kFeatureWindowTiling);
            out.push_back(kFeatureZoomFill);
        }
        if (layerPointer)
            out.push_back(kFeatureLayerPointer);
        if (appearance)
            out.push_back(kFeatureAppearance);
        if (clientChrome)
            out.push_back(kFeatureClientChrome);
        if (frameTimes)
            out.push_back(kFeatureFrameTimes);
        if (keyboardFocus)
            out.push_back(kFeatureKeyboardFocus);
        if (windowTiling && tilingArrange) {
            out.push_back(kFeatureTilingArrange);
            out.push_back(kFeatureTilingLayouts);
        }
        if (windowTiling && tileHover)
            out.push_back(kFeatureTileHover);
        if (windowTiling && tilingArrange && tilingGroups)
            out.push_back(kFeatureTilingGroups);
        if (windowTiling && tilingArrange && sharedEdge)
            out.push_back(kFeatureTilingSharedEdge);
        if (windowTiling && tilingArrange && split) {
            out.push_back(kFeatureTilingSplit);
            out.push_back(kFeatureTilingSplitRows);
            out.push_back(kFeatureTilingSplitTitles);
        }
        if (toplevelDrag)
            out.push_back(kFeatureToplevelDrag);
        return out;
    }

    std::optional<theme::Appearance> parseAppearance(std::string_view key, std::string_view value) {
        if (key != kConfigAppearance)
            return std::nullopt;
        if (value == "dark")
            return theme::Appearance::Dark;
        if (value == "light")
            return theme::Appearance::Light;
        return std::nullopt;
    }

    std::optional<DoubleClickAction> parseDoubleClickAction(std::string_view key, std::string_view value) {
        if (key != kConfigTitlebarDoubleClick)
            return std::nullopt;
        if (value == "zoom")
            return DoubleClickAction::Zoom;
        if (value == "minimize")
            return DoubleClickAction::Minimize;
        if (value == "none")
            return DoubleClickAction::None;
        if (value == "fill")
            return DoubleClickAction::Fill;
        return std::nullopt;
    }

    std::string luaDispatchRequest(std::string_view verb) {
        std::string out{"hl.plugin."};
        out += kLuaNamespace;
        out += '.';
        out += verb;
        out += "()";
        return out;
    }

    std::string socket2Line(std::string_view json) {
        std::string out{kEventName};
        out += ">>";
        out += json;
        return out;
    }

} // namespace gf::gfc
