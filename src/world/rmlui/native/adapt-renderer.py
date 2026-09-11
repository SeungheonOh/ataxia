"""Adapt pinned upstream renderer without changing its effects implementation.
Generated copies retain the upstream MIT license. Run only at configure time.
"""
from pathlib import Path
import sys
src, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
s = (src / 'RmlUi_Renderer_GL3.cpp').read_text()
s = s.replace('defined RMLUI_PLATFORM_EMSCRIPTEN', 'defined ATAXIA_RMLUI_GLES')
s = s.replace('defined(RMLUI_PLATFORM_EMSCRIPTEN)', 'defined(ATAXIA_RMLUI_GLES)')
s = s.replace('// Draw to backbuffer\n\tglBindFramebuffer(GL_FRAMEBUFFER, 0);', '// Resolve into the World-owned component target.\n\tglBindFramebuffer(GL_FRAMEBUFFER, destination_framebuffer);\n\tglDisable(GL_SCISSOR_TEST);\n\tglDisable(GL_STENCIL_TEST);\n\tglDisable(GL_BLEND);')
assert 'GL_FRAMEBUFFER, destination_framebuffer' in s
h = (src / 'RmlUi_Renderer_GL3.h').read_text().replace('void EndFrame();', 'void EndFrame();\n\tvoid SetDestination(unsigned int framebuffer) { destination_framebuffer = framebuffer; }', 1)
h = h.replace('int viewport_width = 0;', 'unsigned int destination_framebuffer = 0;\n\tint viewport_width = 0;')
s += "\nvoid AtaxiaReleaseFilter(Rml::CompiledFilterHandle h) { delete reinterpret_cast<CompiledFilter*>(h); }\n"
s += "void AtaxiaReleaseShader(Rml::CompiledShaderHandle h) { delete reinterpret_cast<CompiledShader*>(h); }\n"
(out / 'RmlUi_Renderer_GL3.cpp').write_text(s)
(out / 'RmlUi_Renderer_GL3.h').write_text(h)
(out / 'LICENSE.txt').write_text((src.parent / 'LICENSE.txt').read_text())
