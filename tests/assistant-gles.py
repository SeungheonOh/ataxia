"""Exercise the shipping panel using the real native renderer; no model or audio."""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), __file__, 'exec'))
set_text = api('component_set_string', C.c_bool, P, C.c_char_p, C.c_char_p)
model = api('model_string', C.c_bool, P, C.c_char_p, C.c_char_p)
import subprocess
fixture = root/'build/assistant-formatted-transcript.rml'
if not fixture.exists() or fixture.stat().st_mtime < (root/'src/world/assistant/format.lisp').stat().st_mtime:
    subprocess.run(['sbcl', '--noinform', '--disable-debugger', '--script', 'tests/assistant-format.lisp'], cwd=root, check=True)
for font in ['dejavu/DejaVuSans-Bold.ttf', 'dejavu/DejaVuSansMono.ttf', 'liberation/LiberationSans-Italic.ttf']:
    path = Path('/usr/share/fonts/truetype')/font
    if path.exists(): ok(api('load_font', C.c_bool, C.c_char_p)(str(path).encode()))
def capture(c, width, height, name):
    for _ in range(3): ok(render(c))
    pixels = (C.c_ubyte * (width*height*4))()
    bind_fbo(0x8d40, fbo); read(0, 0, width, height, 0x1908, 0x1401, pixels)
    im = Image.frombytes('RGBA', (width, height), bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root/f'build/{name}.png')
    return im

def component(source, width, height):
    bind_texture(0x0de1, tex)
    tex_image(0x0de1, 0, 0x1908, width, height, 0, 0x1908, 0x1401, None)
    c = create((root/f'src/world/assistant/{source}.rml').read_bytes(), b'assistant.rml', b'', width, height, 1)
    ok(c); ok(attach(c, fbo))
    return c

for width, height in [(480, 760), (304, 640)]:
    c = component('panel', width, height)
    ok(model(c, b'message', b'')); ok(model(c, b'project', b'/home/user/project'))
    ok(set_class(c, b'panel', b'small', width < 360))
    ok(set_text(c, b'state', b'Ready'))
    ok(model(c, b'transcript', fixture.read_bytes()))
    ok(style(c, b'empty', b'display', b'none'))
    ok(api('component_register_callback', C.c_bool, P, C.c_char_p)(c, b'settings-open'))
    im = capture(c, width, height, f'assistant-panel-{width}')
    assert im.getpixel((width//2, 2))[:3] == (255, 255, 255)
    ok(button(c, 75, height - 69, 1, True)); ok(button(c, 75, height - 69, 1, False)); ok(render(c))
    names = [api('component_callback_name', C.c_char_p, P, C.c_size_t)(c, i) for i in range(api('component_callback_count', C.c_size_t, P)(c))]
    assert b'settings-open' in names, names
    ok(api('component_focus', C.c_bool, P, C.c_bool)(c, False))
    ok(render(c)); assert delay(c) < 0, delay(c)
    ok(detach(c)); destroy(c)

for width, height in [(800, 600), (304, 640)]:
    c = component('settings', width, height)
    ok(set_class(c, b'dialog', b'small', width < 400))
    ok(model(c, b'model_options', '<select id="model-select" data-value="selected_model"><option value="">GPT-6 Astra</option><option value="fixture-main">GPT-5.6 Sol</option><option value="fixture-fast">GPT-5.6 Luna</option></select><div id="model-chevron">▾</div>'.encode()))
    ok(model(c, b'selected_model', b''))
    ok(model(c, b'effort_options', '<select id="effort-select" data-value="selected_effort"><option value="">Auto · X-high</option><option value="low">Low</option><option value="high">High</option></select><div id="effort-chevron">▾</div>'.encode()))
    ok(model(c, b'selected_effort', b''))
    ok(set_text(c, b'fast', b'Fast on')); ok(set_class(c, b'fast', b'enabled', True))
    ok(style(c, b'models-load', b'display', b'none'))
    for name in [b'model-field:change', b'effort-field:change', b'fast', b'settings-done', b'settings-backdrop']:
        ok(api('component_register_callback', C.c_bool, P, C.c_char_p)(c, name))
    im = capture(c, width, height, f'assistant-settings-{width}')
    white = [(x, y) for y in range(height) for x in range(width) if im.getpixel((x,y)) == (255,255,255,255)]
    x0, x1 = min(p[0] for p in white), max(p[0] for p in white)
    y0, y1 = min(p[1] for p in white), max(p[1] for p in white)
    assert abs((x0+x1+1)/2 - width/2) <= 1, (x0,x1,width)
    assert abs((y0+y1+1)/2 - height/2) <= 1, (y0,y1,height)
    # Locate the two full-width field fills, independent of the display size.
    field_x = x0 + 15 if width >= 400 else x0 + 12
    field_x += 10
    bands=[]
    for y in range(y0,y1):
        if im.getpixel((field_x,y))[:3] == (247,248,249):
            if not bands or y > bands[-1][-1]+1: bands.append([])
            bands[-1].append(y)
    bands=[b for b in bands if len(b)>20]
    assert len(bands)==2, [len(b) for b in bands]
    for variable, band in [(b'selected_model', bands[0]), (b'selected_effort', bands[1])]:
        y=(band[0]+band[-1])/2
        ok(button(c, width/2, y, 1, True)); ok(button(c, width/2, y, 1, False)); ok(render(c))
        for symbol in [0xff54,0xff54,0xff0d]:
            ok(key(c,symbol,True,0)); ok(key(c,symbol,False,0)); ok(render(c))
        assert model_value(c,variable)==(b'fixture-fast' if variable==b'selected_model' else b'high'), model_value(c,variable)
    # Fast button is opposite its copy, above the bottom action row.
    ok(button(c,x1-55,y1-110,1,True));ok(button(c,x1-55,y1-110,1,False));ok(render(c))
    ok(button(c,x1-50,y1-35,1,True));ok(button(c,x1-50,y1-35,1,False));ok(render(c))
    ok(button(c,2,2,1,True));ok(button(c,2,2,1,False));ok(render(c))
    names=[api('component_callback_name',C.c_char_p,P,C.c_size_t)(c,i) for i in range(api('component_callback_count',C.c_size_t,P)(c))]
    assert all(n in names for n in [b'model-field:change',b'effort-field:change',b'fast',b'settings-done',b'settings-backdrop']),names
    ok(api('component_focus',C.c_bool,P,C.c_bool)(c,False));ok(render(c));assert delay(c)<0,delay(c)
    ok(detach(c));destroy(c)
print('PASS: light assistant and centered settings modal, narrow/wide, keyboard selectors, Fast, dismiss controls and idle rendering.')
