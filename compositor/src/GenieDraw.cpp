#include "GenieDraw.hpp"

#include <hyprland/src/output/Monitor.hpp>

#include "Plugin.hpp"

#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <GLES3/gl32.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <format>
#include <span>
#include <string>
#include <string_view>
#include <utility>

namespace gf::genie {

    namespace {
        // Positions are fractions of the element's pixel box, mapped to clip space by Hyprland's own projection for a box
        // (IHyprRenderer::projectBoxToTarget), exactly like its textured quads (fullVerts). Snapshot textures are
        // premultiplied: the opacity scales every channel.
        constexpr const char* VERTEX_SHADER = R"(#version 300 es
uniform mat3 proj;
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 texcoord;
out vec2 v_texcoord;
void main() {
    gl_Position = vec4(proj * vec3(pos, 1.0), 1.0);
    v_texcoord = texcoord;
}
)";

        constexpr const char* FRAGMENT_SHADER = R"(#version 300 es
precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
uniform float alpha;
layout(location = 0) out vec4 fragColor;
void main() {
    fragColor = texture(tex, v_texcoord) * alpha;
}
)";

        // Dev fault injection (injectShaderFault): a fragment shader that cannot compile, so the real failure path runs.
        constexpr const char* BROKEN_FRAGMENT_SHADER = "#version 300 es\nthis is not a shader (Grassfield dev fault injection)\n";

        constexpr GLsizei FLOATS_PER_VERTEX = 4;

        // glGetError calls per check: enough to drain the usual one or two flags, never a loop on a lost context.
        constexpr int GL_ERROR_CHECK_LIMIT = 8;
        // CIO-13: glGetError is a synchronous driver query; a draw checks it on the first draws of a load (a driver that
        // refuses the funnel does so at once) and then on one draw in kErrorCheckEvery, not on every frame of every genie.
        constexpr uint64_t kErrorCheckFirst = 32;
        constexpr uint64_t kErrorCheckEvery = 60;

        struct SGl {
            bool   failed      = false; // disable() ran: no more funnel draws until the plugin is loaded again
            bool   shaderFault = false; // injectShaderFault(): the next compile uses BROKEN_FRAGMENT_SHADER
            bool   ready       = false;
            GLuint program = 0, vao = 0, vbo = 0, ibo = 0;
            GLint  locProj = -1, locTex = -1, locAlpha = -1;
            int    indexAcross = 0, indexAlong = 0;
            GLsizei indexCount = 0;

            uint64_t drawn        = 0;
            double   maxDrawMicro = 0;
        };

        // Constructed on first use inside a guarded call (R13); release() empties it before dlclose.
        SGl& gl() {
            static SGl s;
            return s;
        }

        // The first pending GL error (GL_NO_ERROR if none); drains at most GL_ERROR_CHECK_LIMIT flags.
        GLenum firstGlError() {
            GLenum first = GL_NO_ERROR;
            for (int i = 0; i < GL_ERROR_CHECK_LIMIT; ++i) {
                const GLenum err = glGetError();
                if (err == GL_NO_ERROR)
                    break;
                if (first == GL_NO_ERROR)
                    first = err;
            }
            return first;
        }

        bool rendererIsGl() {
            return g_pHyprRenderer && g_pHyprRenderer->type() == Render::IHyprRenderer::RT_GL && Render::GL::g_pHyprOpenGL;
        }

        GLuint compile(GLenum kind, const char* source) {
            const GLuint shader = glCreateShader(kind);
            if (shader == 0)
                return 0;
            glShaderSource(shader, 1, &source, nullptr);
            glCompileShader(shader);
            GLint ok = GL_FALSE;
            glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
            if (ok != GL_TRUE) {
                std::array<char, 512> info{};
                glGetShaderInfoLog(shader, static_cast<GLsizei>(info.size()), nullptr, info.data());
                gf::log(Log::ERR, "genie: shader compile failed: {}", info.data());
                glDeleteShader(shader);
                return 0;
            }
            return shader;
        }

        void deleteObjects() {
            auto& s = gl();
            if (s.ibo != 0)
                glDeleteBuffers(1, &s.ibo);
            if (s.vbo != 0)
                glDeleteBuffers(1, &s.vbo);
            if (s.vao != 0)
                glDeleteVertexArrays(1, &s.vao);
            if (s.program != 0)
                glDeleteProgram(s.program);
            s.ibo = s.vbo = s.vao = s.program = 0;
            s.indexAcross = s.indexAlong = 0;
            s.indexCount  = 0;
            s.ready       = false;
        }

        // GL bindings this module changes, restored after each use so that Hyprland's caches stay true.
        class CSavedBindings {
          public:
            CSavedBindings() {
                glGetIntegerv(GL_CURRENT_PROGRAM, &m_program);
                glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &m_vao);
                glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &m_arrayBuffer);
                glGetIntegerv(GL_ACTIVE_TEXTURE, &m_activeTexture);
                glActiveTexture(GL_TEXTURE0);
                glGetIntegerv(GL_TEXTURE_BINDING_2D, &m_texture0);
            }
            ~CSavedBindings() {
                glBindVertexArray(static_cast<GLuint>(m_vao));
                glBindBuffer(GL_ARRAY_BUFFER, static_cast<GLuint>(m_arrayBuffer));
                glActiveTexture(GL_TEXTURE0);
                glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(m_texture0));
                glActiveTexture(static_cast<GLenum>(m_activeTexture));
                glUseProgram(static_cast<GLuint>(m_program));
            }
            CSavedBindings(const CSavedBindings&)            = delete;
            CSavedBindings& operator=(const CSavedBindings&) = delete;
            CSavedBindings(CSavedBindings&&)                 = delete;
            CSavedBindings& operator=(CSavedBindings&&)      = delete;

          private:
            GLint m_program = 0, m_vao = 0, m_arrayBuffer = 0, m_activeTexture = GL_TEXTURE0, m_texture0 = 0;
        };

        // Program, vertex array and buffers; called inside a draw (the EGL context is current, bindings saved).
        bool ensureObjects() {
            auto& s = gl();
            if (s.failed)
                return false;
            if (s.ready)
                return true;
            const GLuint vs = compile(GL_VERTEX_SHADER, VERTEX_SHADER);
            const GLuint fs = vs != 0 ? compile(GL_FRAGMENT_SHADER, s.shaderFault ? BROKEN_FRAGMENT_SHADER : FRAGMENT_SHADER) : 0;
            if (vs == 0 || fs == 0) {
                if (vs != 0)
                    glDeleteShader(vs);
                disable("shader compile failed");
                return false;
            }
            s.program = glCreateProgram();
            glAttachShader(s.program, vs);
            glAttachShader(s.program, fs);
            glLinkProgram(s.program);
            glDetachShader(s.program, vs);
            glDetachShader(s.program, fs);
            glDeleteShader(vs);
            glDeleteShader(fs);
            GLint linked = GL_FALSE;
            glGetProgramiv(s.program, GL_LINK_STATUS, &linked);
            s.locProj  = glGetUniformLocation(s.program, "proj");
            s.locTex   = glGetUniformLocation(s.program, "tex");
            s.locAlpha = glGetUniformLocation(s.program, "alpha");
            if (linked != GL_TRUE || s.locProj < 0 || s.locTex < 0 || s.locAlpha < 0) {
                deleteObjects();
                disable("shader link failed");
                return false;
            }
            glGenVertexArrays(1, &s.vao);
            glGenBuffers(1, &s.vbo);
            glGenBuffers(1, &s.ibo);
            glBindVertexArray(s.vao);
            glBindBuffer(GL_ARRAY_BUFFER, s.vbo);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, FLOATS_PER_VERTEX * sizeof(float), nullptr);
            glEnableVertexAttribArray(1);
            glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, FLOATS_PER_VERTEX * sizeof(float),
                                  reinterpret_cast<const void*>(2 * sizeof(float))); // NOLINT(performance-no-int-to-ptr): GL buffer offset
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, s.ibo); // vertex array state: stays with s.vao
            glBindVertexArray(0);
            s.ready = true;
            gf::log(Log::INFO, "genie: GL objects ready (program {}, GLES 3 custom pass element)", s.program);
            return true;
        }

        // The index buffer for an `across` x `along` mesh (s.vao bound).
        bool ensureIndices(int across, int along) {
            auto& s = gl();
            if (s.indexAcross == across && s.indexAlong == along && s.indexCount > 0)
                return true;
            const auto indices = gf::minimize::meshIndices(across, along);
            if (indices.empty())
                return false;
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, s.ibo);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, static_cast<GLsizeiptr>(indices.size() * sizeof(uint16_t)), indices.data(), GL_STATIC_DRAW);
            s.indexAcross = across;
            s.indexAlong  = along;
            s.indexCount  = static_cast<GLsizei>(indices.size());
            return true;
        }
    } // namespace

    bool available() {
        return !gl().failed && rendererIsGl();
    }

    bool usableOn(const PHLMONITOR& mon) {
        // CIO-14: the funnel's shader writes the snapshot's pixels as they are; on an output whose colour path is not plain
        // sRGB (HDR, wide gamut, an ICC or SDR-brightness transform) Hyprland's own texture shader converts them, so the
        // window would change colour for the animation and snap back. The Scale effect goes through Hyprland's path there.
        return available() && mon && !mon->needsCM();
    }

    void disable(std::string_view why) {
        auto& s = gl();
        if (!s.failed)
            gf::log(Log::ERR, "genie: funnel drawing disabled ({}); minimize uses the shrink effect", why);
        s.failed = true;
    }

    void reset() {
        auto& s        = gl();
        s.failed       = false;
        s.shaderFault  = false;
        s.drawn        = 0;
        s.maxDrawMicro = 0;
    }

    void injectShaderFault() {
        auto& s       = gl();
        s.shaderFault = true;
        // Objects already made: drop them, so that the next funnel draw compiles (and fails) again.
        release();
        gf::log(Log::WARN, "genie: dev fault injection: the next funnel draw compiles a broken shader");
    }

    uint64_t drawnCount() {
        return gl().drawn;
    }

    double takeMaxDrawMicros() {
        return std::exchange(gl().maxDrawMicro, 0.0);
    }

    void release() {
        auto& s = gl();
        if (s.program == 0 && s.vao == 0 && s.vbo == 0 && s.ibo == 0)
            return;
        if (!rendererIsGl()) {
            // No context to delete them with (should not happen: they were made with Hyprland's GL renderer).
            s.ibo = s.vbo = s.vao = s.program = 0;
            s.ready = false;
            return;
        }
        Render::GL::g_pHyprOpenGL->makeEGLCurrent();
        deleteObjects();
    }

    CGenieElement::CGenieElement(SDrawData&& data) : m_data(std::move(data)) {}

    std::vector<UP<IPassElement>> CGenieElement::draw() {
        gf::guarded("genie draw", [this] {
            const auto t0 = std::chrono::steady_clock::now();
            auto&      s  = gl();
            ++s.drawn;
            auto&      d       = m_data;
            const bool checked = s.drawn <= kErrorCheckFirst || s.drawn % kErrorCheckEvery == 0;
            if (!rendererIsGl() || s.failed || !d.tex || d.tex->m_texID == 0 || d.alpha <= 0.F || d.pixelBounds.w < 1 || d.pixelBounds.h < 1)
                return;
            const size_t vertexCount = static_cast<size_t>(gf::minimize::meshVertexCount(d.across, d.along));
            if (d.across < 1 || d.along < 1 || d.vertices.size() != vertexCount * FLOATS_PER_VERTEX)
                return;

            // Damage of this frame (pixels of the monitor, before its transform) inside the mesh's box: nothing is drawn
            // outside it (those pixels are not repainted this frame; anything drawn there would stay on screen).
            CRegion damage = g_pHyprRenderer->m_renderData.damage.copy();
            damage.intersect(CBox{d.pixelBounds}.expand(1.0));
            if (damage.empty())
                return;

            // Error flags left by earlier GL work (not ours) are cleared first, so that the check after the draw sees ours.
            if (checked)
                (void)firstGlError();
            const CSavedBindings saved;
            if (!ensureObjects())
                return;
            glBindVertexArray(s.vao);
            if (!ensureIndices(d.across, d.along))
                return;

            // Positions as fractions of the pixel box, for Hyprland's box projection: made once, in place (the element is this
            // frame's; no copy of the mesh per draw, CIO-13).
            auto& verts = d.vertices;
            if (!m_normalized) {
                const auto bx = static_cast<float>(d.pixelBounds.x), by = static_cast<float>(d.pixelBounds.y);
                const auto bw = static_cast<float>(d.pixelBounds.w), bh = static_cast<float>(d.pixelBounds.h);
                for (size_t i = 0; i < verts.size(); i += FLOATS_PER_VERTEX) {
                    verts[i]     = (verts[i] - bx) / bw;
                    verts[i + 1] = (verts[i + 1] - by) / bh;
                }
                m_normalized = true;
            }
            glBindBuffer(GL_ARRAY_BUFFER, s.vbo);
            glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(verts.size() * sizeof(float)), verts.data(), GL_STREAM_DRAW);

            const auto proj = g_pHyprRenderer->projectBoxToTarget(d.pixelBounds, HYPRUTILS_TRANSFORM_NORMAL).getMatrix();
            glUseProgram(s.program);
            glUniformMatrix3fv(s.locProj, 1, GL_TRUE, proj.data());
            glUniform1i(s.locTex, 0);
            glUniform1f(s.locAlpha, std::clamp(d.alpha, 0.F, 1.F));

            glActiveTexture(GL_TEXTURE0);
            d.tex->bind();
            d.tex->setTexParameter(GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            d.tex->setTexParameter(GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            d.tex->setTexParameter(GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            d.tex->setTexParameter(GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

            Render::GL::g_pHyprOpenGL->blend(true);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); // premultiplied, Hyprland's blend function
            damage.forEachRect([&s](const pixman_box32_t& rect) {
                Render::GL::g_pHyprOpenGL->scissor(&rect);
                glDrawElements(GL_TRIANGLES, s.indexCount, GL_UNSIGNED_SHORT, nullptr);
            });
            g_pHyprRenderer->disableScissor();
            d.tex->unbind();
            // Any GL error raised by this draw disables the funnel for the plugin's life (one line); running funnel
            // animations continue as shrink ones (Minimize.cpp checkFunnelUsable).
            if (const GLenum err = checked ? firstGlError() : GL_NO_ERROR; err != GL_NO_ERROR)
                disable(std::format("GL error 0x{:x} after a funnel draw", err));

            const double micros = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
            s.maxDrawMicro      = std::max(s.maxDrawMicro, micros);
        });
        return {};
    }

    bool CGenieElement::needsLiveBlur() {
        return false;
    }

    bool CGenieElement::needsPrecomputeBlur() {
        return false;
    }

    const char* CGenieElement::passName() {
        return kPassName;
    }

    ePassElementType CGenieElement::type() {
        return EK_CUSTOM;
    }

    std::optional<CBox> CGenieElement::boundingBox() {
        return m_data.logicalBounds;
    }

    CRegion CGenieElement::opaqueRegion() {
        return {};
    }

} // namespace gf::genie
