"""Render every shipping shell document at laptop, narrow and fractional sizes.

Uses the actual RmlUi/GLES host, catches missing relative stylesheets/fonts and
checks that stationary UI has no recurring rendering. Artifacts go to build/.
"""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), __file__, 'exec'))

for face in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf', 'DejaVuSansMono-Oblique.ttf', 'DejaVuSansMono-BoldOblique.ttf']:
    ok(api('load_font', C.c_bool, C.c_char_p)(f'/usr/share/fonts/truetype/dejavu/{face}'.encode()))
set_text = api('component_set_string', C.c_bool, P, C.c_char_p, C.c_char_p)
focus = api('component_focus', C.c_bool, P, C.c_bool)
model = api('model_string', C.c_bool, P, C.c_char_p, C.c_char_p)
cases = [
    ('rmlui/status-bar/bar', 1280, 18), ('rmlui/status-bar/menu', 400, 180),
    ('rmlui/status-bar/power', 340, 132), ('rmlui/status-bar/media', 380, 84),
    ('rmlui/status-bar/clipboard', 560, 180), ('rmlui/status-bar/workspaces', 560, 260),
    ('rmlui/status-bar/osd', 340, 42), ('assistant/panel', 480, 760),
    ('computer-use/panel', 380, 98),
    ('computer-use/cursor', 180, 34), ('screencast/picker', 540, 178),
    ('screencast/region', 640, 360), ('screencast/indicator', 400, 18),
]
artifacts = {}
for name, normal_width, normal_height in cases:
    for narrow, scale in [(False, 1), (True, 1), (False, 1.5), (False, 2)]:
        width = min(304, normal_width) if narrow else normal_width
        height = (178 if narrow else 146) if name == "screencast/picker" else normal_height
        if name == "rmlui/status-bar/clipboard": height = 228 if narrow else 180
        pw, ph = round(width * scale), round(height * scale)
        bind_texture(0x0de1, tex)
        tex_image(0x0de1, 0, 0x1908, pw, ph, 0, 0x1908, 0x1401, None)
        path = root / f'src/world/{name}.rml'
        source = path.read_bytes().replace(b'<!-- sources -->',
            b'<input class="action" type="button" id="app0" value="Firefox / Design notes"/>'
            b'<input class="action" type="button" id="app1" value="Terminal / build output"/>')
        c = create(source, str(path).encode(), b'', pw, ph, scale)
        ok(c)
        assert not error(), (name, error().decode())
        ok(attach(c, fbo))
        if name.endswith('/bar'):
            for cls, limit in [(b'compact', 1050), (b'narrow', 680), (b'tiny', 380)]:
                ok(set_class(c, b'bar', cls, width < limit))
        if name in ['rmlui/status-bar/menu', 'rmlui/status-bar/workspaces', 'assistant/panel']:
            ok(set_class(c, b'panel', b'small', narrow))
        if name == 'computer-use/panel':
            ok(style(c, b'panel', b'width', f'{width}dp'.encode()))
            ok(style(c, b'panel', b'height', f'{height}dp'.encode()))
            for element, value in [(b'empty', b'none'), (b'card0', b'block'), (b'resume0', b'none')]:
                ok(style(c, element, b'display', value))
            for element, value in [(b'name0', b'Atlas'), (b'state0', b'ACTIVE'),
                                   (b'detail0', b'Ready'), (b'scope0', b'eDP-1 / World view')]:
                ok(set_text(c, element, value))
        if name == 'screencast/region':
            for prop, value in [(b'display', b'block'), (b'left', b'32dp'), (b'top', b'120dp'),
                                (b'width', f'{width-64}dp'.encode()), (b'height', b'160dp')]:
                ok(style(c, b'rectangle', prop, value))
        if name == 'rmlui/status-bar/clipboard':
            ok(set_class(c, b'panel', b'small', narrow))
            ok(set_text(c, b'preview', b'A thought worth keeping.\nA second line to inspect before copying.'))
            for i, text in enumerate(['A thought worth keeping.', 'https://interlisp.org', '(hello world)']):
                ok(set_text(c, f'app{i}'.encode(), text.encode()))
            for i in range(3, 6): ok(style(c, f'app{i}'.encode(), b'display', b'none'))
            ok(style(c, b'empty', b'display', b'none'))
            ok(set_text(c, b'count', b'3 recent items'))
        ok(focus(c, False))
        for _ in range(3): ok(render(c))
        assert delay(c) < 0, (name, delay(c))
        stable = revision(c)
        for _ in range(8): ok(render(c))
        assert revision(c) == stable, (name, 'stationary UI repainted')
        pixels = (C.c_ubyte * (pw * ph * 4))()
        bind_fbo(0x8d40, fbo); read(0, 0, pw, ph, 0x1908, 0x1401, pixels)
        snapshot = Image.frombytes('RGBA', (pw, ph), bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        colors = snapshot.getcolors(pw * ph) or []
        assert any(count > 20 and rgba == (22, 22, 22, 255) for count, rgba in colors), (name, 'theme missing')
        target = root / f'build/theme-{name.replace("/", "-")}-{width}-{scale}x.png'
        snapshot.save(target)
        if not narrow and scale == 1: artifacts[name] = snapshot
        ok(detach(c)); destroy(c)

# Contact sheet of actual native renders, useful for reviewing the whole shell.
from PIL import ImageDraw, ImageFont
sheet = Image.new('RGB', (1504, 1550), (214, 214, 214))
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 13)
def place(name, x, y, label):
    draw.text((x, y), label, fill=(22, 22, 22), font=font)
    im = artifacts[name]
    sheet.paste(im, (x, y+24), im)
place('rmlui/status-bar/bar', 24, 18, 'ATAXIA / WORKSTATION')
place('rmlui/status-bar/menu', 24, 110, 'APPLICATIONS')
place('screencast/picker', 448, 110, 'SHARE A SOURCE')
place('assistant/panel', 1012, 110, 'ASSISTANT')
place('rmlui/status-bar/power', 24, 638, 'POWER')
place('rmlui/status-bar/media', 388, 638, 'SOUND & MEDIA')
place('computer-use/panel', 1012, 936, 'AGENT CONTROLS')
place('rmlui/status-bar/osd', 24, 1202, 'SYSTEM FEEDBACK')
place('screencast/indicator', 388, 1138, 'SHARING INDICATOR')
place('computer-use/cursor', 1012, 1240, 'AGENT LABEL')
sheet.save(root / 'build/workstation-ui.png')
print('PASS: all 13 shell documents, narrow/normal, 1x/1.5x/2x, linked theme and settled idle.')
