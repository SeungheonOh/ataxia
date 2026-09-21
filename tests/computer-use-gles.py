"""Agent cards at desktop and narrow widths, with active and paused controls."""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), str(Path(__file__).parent / 'rmlui-gles.py'), 'exec'))
for face in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf', 'DejaVuSansMono-Oblique.ttf', 'DejaVuSansMono-BoldOblique.ttf']:
    ok(api('load_font', C.c_bool, C.c_char_p)(f'/usr/share/fonts/truetype/dejavu/{face}'.encode()))
set_text = api('component_set_string', C.c_bool, P, C.c_char_p, C.c_char_p)
for width, height, paused in [(380, 98, False), (304, 98, True)]:
    bind_texture(0x0de1, tex)
    tex_image(0x0de1, 0, 0x1908, width, height, 0, 0x1908, 0x1401, None)
    c = create((root / 'src/world/computer-use/panel.rml').read_bytes(), str(root/'src/world/computer-use/panel.rml').encode(), b'', width, height, 1)
    ok(c); ok(attach(c, fbo))
    ok(style(c, b'panel', b'box-sizing', b'border-box'))
    ok(style(c, b'panel', b'width', f'{width}dp'.encode()))
    ok(style(c, b'panel', b'height', f'{height}dp'.encode()))
    ok(style(c, b'empty', b'display', b'none'))
    ok(style(c, b'card0', b'display', b'block'))
    ok(style(c, b'resume0' if not paused else b'pause0', b'display', b'none'))
    for key, value in [('name0', 'Atlas'), ('state0', 'PAUSED' if paused else 'ACTIVE'),
                       ('detail0', 'Paused by you' if paused else 'Cursor ready'),
                       ('scope0', 'eDP-1 · view screen and control apps')]:
        ok(set_text(c, key.encode(), value.encode()))
    for _ in range(20):
        time.sleep(.016); ok(render(c))
    pixels = (C.c_ubyte * (width * height * 4))()
    bind_fbo(0x8d40, fbo); read(0, 0, width, height, 0x1908, 0x1401, pixels)
    im = Image.frombytes('RGBA', (width, height), bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root / f'build/agent-panel-{width}.png')
    assert im.getpixel((width - 1, height // 2))[3] == 255, 'panel border missing'
    assert im.getpixel((width - 3, height // 2))[:3] == (255, 255, 255)
    assert delay(c) < 0, 'agent panel must settle'
    ok(detach(c)); destroy(c)
print('PASS: active/narrow paused agent cards, unclipped bounds, settled UI.')
