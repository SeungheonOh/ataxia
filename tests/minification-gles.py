"""Exercise the production shaders on a surfaceless GLES context.
Run metaworld-minification.lisp with ATAXIA_SHADER_TEST_DIR first, then:
  python3 tests/minification-gles.py /tmp/ataxia-minify-shaders
Requires Pillow and system EGL/GLES libraries; writes a comparison gallery.
"""
import ctypes as C
import math
import os
from pathlib import Path
import statistics
import sys
import time
from PIL import Image, ImageDraw, ImageFont

os.environ.setdefault('EGL_PLATFORM', 'surfaceless')
egl = C.CDLL('libEGL.so.1')
gl = C.CDLL('libGLESv2.so.2')
I, U, F, P = C.c_int, C.c_uint, C.c_float, C.c_void_p

def bind(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn

get_display = bind(egl, 'eglGetDisplay', P, P)
initialize = bind(egl, 'eglInitialize', U, P, P, P)
choose = bind(egl, 'eglChooseConfig', U, P, P, P, I, P)
create_surface = bind(egl, 'eglCreatePbufferSurface', P, P, P, P)
create_context = bind(egl, 'eglCreateContext', P, P, P, P, P)
current = bind(egl, 'eglMakeCurrent', U, P, P, P, P)
display = get_display(None)
assert initialize(display, None, None)
config, count = P(), I()
attrs = (I * 15)(0x3033, 1, 0x3040, 4, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3025, 0, 0x3038)
assert choose(display, attrs, C.byref(config), 1, C.byref(count)) and count.value
surface = create_surface(display, config, (I * 5)(0x3057, 600, 0x3056, 600, 0x3038))
context = create_context(display, config, None, (I * 3)(0x3098, 2, 0x3038))
assert surface and context and current(display, surface, surface, context)
print('GLES renderer:', bind(gl, 'glGetString', C.c_char_p, U)(0x1F01).decode())
shader_create = bind(gl, 'glCreateShader', U, U)
shader_source = bind(gl, 'glShaderSource', None, U, I, P, P)
shader_compile = bind(gl, 'glCompileShader', None, U)
shader_status = bind(gl, 'glGetShaderiv', None, U, U, P)
shader_log = bind(gl, 'glGetShaderInfoLog', None, U, I, P, P)
program_create = bind(gl, 'glCreateProgram', U)
attach = bind(gl, 'glAttachShader', None, U, U)
attribute = bind(gl, 'glBindAttribLocation', None, U, U, C.c_char_p)
link = bind(gl, 'glLinkProgram', None, U)
program_status = bind(gl, 'glGetProgramiv', None, U, U, P)
use = bind(gl, 'glUseProgram', None, U)
location = bind(gl, 'glGetUniformLocation', I, U, C.c_char_p)
u1f = bind(gl, 'glUniform1f', None, I, F)
u2f = bind(gl, 'glUniform2f', None, I, F, F)
u4f = bind(gl, 'glUniform4f', None, I, F, F, F, F)
viewport = bind(gl, 'glViewport', None, I, I, I, I)
read = bind(gl, 'glReadPixels', None, I, I, I, I, U, U, P)
draw = bind(gl, 'glDrawArrays', None, U, I, I)
finish = bind(gl, 'glFinish', None)
error = bind(gl, 'glGetError', U)
root = Path(sys.argv[1])

def compile_shader(kind, text):
    shader = shader_create(kind)
    source = C.c_char_p(text.encode())
    shader_source(shader, 1, C.byref(source), None)
    shader_compile(shader)
    status = I()
    shader_status(shader, 0x8B81, C.byref(status))
    if not status.value:
        log = C.create_string_buffer(32768)
        shader_log(shader, len(log), None, log)
        raise AssertionError(log.value.decode())
    return shader

vertex = compile_shader(0x8B31, (root / 'canvas.vert').read_text())
# Compile both production targets, including imported external client buffers.
programs = []
for filename in ['texture.frag', 'external.frag']:
    fragment = compile_shader(0x8B30, (root / filename).read_text())
    program = program_create()
    attach(program, vertex)
    attach(program, fragment)
    attribute(program, 0, b'a_position')
    attribute(program, 1, b'a_uv')
    link(program)
    status = I()
    program_status(program, 0x8B82, C.byref(status))
    assert status.value, filename
    programs.append(program)
program = programs[0]
use(program)
vertices = (F * 16)(-1, -1, 0, 0, 1, -1, 1, 0, -1, 1, 0, 1, 1, 1, 1, 1)
bind(gl, 'glEnableVertexAttribArray', None, U)(0)
bind(gl, 'glEnableVertexAttribArray', None, U)(1)
vertex_pointer = bind(gl, 'glVertexAttribPointer', None, U, I, U, U, I, P)
vertex_pointer(0, 2, 0x1406, 0, 16, C.addressof(vertices))
vertex_pointer(1, 2, 0x1406, 0, 16, C.addressof(vertices) + 8)
texture = U()
bind(gl, 'glGenTextures', None, I, P)(1, C.byref(texture))
bind(gl, 'glBindTexture', None, U, U)(0x0DE1, texture)
param = bind(gl, 'glTexParameteri', None, U, U, I)
for key, value in [(0x2800, 0x2601), (0x2801, 0x2601), (0x2802, 0x812F), (0x2803, 0x812F)]:
    param(0x0DE1, key, value)
u1f(location(program, b'u_opacity'), 1)
u1f(location(program, b'u_has_alpha'), 1)
u1f(location(program, b'u_effect'), 0)
u4f(location(program, b'u_uv_bounds'), 0, 0, 1, 1)
tex_image = bind(gl, 'glTexImage2D', None, U, I, I, I, I, I, U, U, P)

def upload(image):
    data = image.tobytes()
    tex_image(0x0DE1, 0, 0x1908, image.width, image.height, 0, 0x1908, 0x1401, C.c_char_p(data))

def render(size, filtered, source_size=512, opacity=1):
    footprint = source_size / size
    samples = min(16, max(1, math.ceil(footprint))) if filtered else 1
    spread = math.sqrt(max(0, footprint * footprint - 1)) / source_size if filtered else 0
    u2f(location(program, b'u_filter_count'), samples, samples)
    u2f(location(program, b'u_filter_x'), spread, 0)
    u2f(location(program, b'u_filter_y'), 0, spread)
    u1f(location(program, b'u_opacity'), opacity)
    viewport(0, 0, size, size)
    draw(5, 0, 4)
    pixels = C.create_string_buffer(size * size * 4)
    read(0, 0, size, size, 0x1908, 0x1401, pixels)
    assert error() == 0
    return Image.frombytes('RGBA', (size, size), pixels.raw)

checker = Image.new('RGBA', (512, 512))
checker.putdata([(v, v, v, 255) for y in range(512) for x in range(512) for v in [255 * ((x + y) % 2)]])
upload(checker)
for size in [257, 171, 103, 61, 41, 23]:
    before, after = render(size, False), render(size, True)
    mse = lambda img: statistics.mean((p[0] - 127.5) ** 2 for p in img.get_flattened_data())
    a, b = mse(before), mse(after)
    assert b < a * 0.12, (size, a, b)
    print(f'{size}/512: alias energy {a:.2f} -> {b:.2f}')
assert render(512, False).tobytes() == render(512, True).tobytes(), '1:1 changed'
# Premultiplied transparency remains premultiplied after filtering and opacity.
upload(Image.new('RGBA', (512, 512), (64, 32, 16, 128)))
pixel = render(61, True, opacity=0.5).getpixel((30, 30))
assert all(abs(a-b) <= 1 for a,b in zip(pixel, (32, 16, 8, 64))), pixel

fixture = Image.new('RGBA', (512, 512), '#17202c')
ink = ImageDraw.Draw(fixture)
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 12)
for row in range(36):
    color = ['#c9d7e8', '#79cea1', '#9cb9f5', '#edbf76'][row % 4]
    ink.text((12, 5 + row * 14), f'{row:02}  '+['const window = render(frame);', '  return samples / pixel_area;', '// Smooth previews at any scale', 'if (active) refresh(surface);'][row % 4], fill=color, font=font)
upload(fixture)
gallery = Image.new('RGB', (850, 490), '#dddddd')
label = ImageDraw.Draw(gallery)
label.text((10, 8), 'Bilinear (before)                         Area filtered (after)', fill='black')
for row, size in enumerate([257, 103, 41]):
    y = [30, 305, 430][row]
    for column, filtered in enumerate([False, True]):
        img = render(size, filtered).convert('RGB')
        gallery.paste(img, (10 + column * 420, y))
gallery.save(root / 'comparison.png')
# Warm the driver, then compare GPU-completed batches with six window quads.
for size in [257, 103, 41]:
    timings = []
    for filtered in [False, True]:
        render(size, filtered)
        for _ in range(5):
            draw(5, 0, 4)
        finish()
        start = time.perf_counter()
        for _ in range(120):
            draw(5, 0, 4)
        finish()
        timings.append((time.perf_counter() - start) * 1000 / 20)
    print(f'6 previews at {size}px, GPU-completed ms: {timings}')
print('PASS: both shaders compile/link; alias suppression, 1:1 fidelity, alpha and GLES errors.')
