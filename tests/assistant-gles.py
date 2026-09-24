"""Exercise the shipping panel using the real native renderer; no model or audio."""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), __file__, 'exec'))
exec(compile((Path(__file__).parent / 'rmlui-layout.py').read_text(), __file__, 'exec'))
for face in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf', 'DejaVuSansMono-Oblique.ttf', 'DejaVuSansMono-BoldOblique.ttf']:
    ok(api('load_font', C.c_bool, C.c_char_p)(f'/usr/share/fonts/truetype/dejavu/{face}'.encode()))
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
    c = create(measured_source((root/f'src/world/assistant/{source}.rml').read_bytes(), ['settings-open','fast','settings-done','model-select','effort-select','fast-toggle','talk','mic-mute','send','message','voice-caption']), str(root/f'src/world/assistant/{source}.rml').encode(), b'', width, height, 1)
    ok(c); ok(attach(c, fbo))
    return c

for width, height in [(480, 760), (304, 640)]:
    c = component('panel', width, height)
    ok(model(c, b'message', b'')); ok(model(c, b'project', b'/home/user/project'))
    ok(set_class(c, b'panel', b'small', width < 360))
    ok(set_text(c, b'state', b'Ready'))
    ok(model(c, b'transcript', fixture.read_bytes()))
    ok(api('component_register_callback', C.c_bool, P, C.c_char_p)(c, b'settings-open'))
    im = capture(c, width, height, f'assistant-panel-{width}')
    assert im.getpixel((width//2, 2))[:3] == (255, 255, 255)
    settings_x,settings_y=box_center(element_box(c,'settings-open',width,height))
    ok(button(c, settings_x, settings_y, 1, True)); ok(button(c, settings_x, settings_y, 1, False)); ok(render(c))
    names = [api('component_callback_name', C.c_char_p, P, C.c_size_t)(c, i) for i in range(api('component_callback_count', C.c_size_t, P)(c))]
    assert b'settings-open' in names, names
    ok(api('model_boolean',C.c_bool,P,C.c_char_p,C.c_bool)(c,b'fast_disabled',False))
    ok(set_text(c,b'settings-open',b'GPT-6 Astra'))
    ok(set_text(c,b'talk',b'End voice'))
    ok(style(c,b'voice-controls',b'display',b'flex'))
    ok(style(c,b'voice-caption',b'display',b'block'))
    ok(set_text(c,b'voice-caption',b'Make the battery panel more compact and keep the current apps open.'))
    for state,label in [('listening','Mute mic'),('muted','Unmute mic')]:
        ok(set_text(c,b'mic-status',b'Microphone on' if state=='listening' else b'Microphone muted'))
        ok(set_text(c,b'mic-mute',label.encode()))
        capture(c,width,height,f'assistant-voice-{state}-{width}')
        bounds={name:element_box(c,name,width,height) for name in ['settings-open','fast-toggle','talk','mic-mute','send','message','voice-caption']}
        for name,a in bounds.items():
            for other,b in bounds.items():
                if name!=other: assert a[2]<=b[0] or b[2]<=a[0] or a[3]<=b[1] or b[3]<=a[1], (state,name,other,a,b)
        for action in ['fast-toggle','talk','mic-mute','send']:
            ok(api('component_register_callback',C.c_bool,P,C.c_char_p)(c,action.encode()))
            x,y=box_center(bounds[action]);ok(button(c,x,y,1,True));ok(button(c,x,y,1,False));ok(render(c))
        names=[api('component_callback_name',C.c_char_p,P,C.c_size_t)(c,i) for i in range(api('component_callback_count',C.c_size_t,P)(c))]
        assert all(action.encode() in names for action in ['fast-toggle','talk','mic-mute','send']), names
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
    # Use rendered bounds: editable rows have no extra vertical padding.
    for variable, field in [(b'selected_model', 'model-select'), (b'selected_effort', 'effort-select')]:
        _, y=box_center(element_box(c,field,width,height))
        ok(button(c, width/2, y, 1, True)); ok(button(c, width/2, y, 1, False)); ok(render(c))
        for symbol in [0xff54,0xff54,0xff0d]:
            ok(key(c,symbol,True,0)); ok(key(c,symbol,False,0)); ok(render(c))
        assert model_value(c,variable)==(b'fixture-fast' if variable==b'selected_model' else b'high'), model_value(c,variable)
    for action in ['fast','settings-done']:
        x,y=box_center(element_box(c,action,width,height))
        ok(button(c,x,y,1,True));ok(button(c,x,y,1,False));ok(render(c))
    ok(button(c,2,2,1,True));ok(button(c,2,2,1,False));ok(render(c))
    names=[api('component_callback_name',C.c_char_p,P,C.c_size_t)(c,i) for i in range(api('component_callback_count',C.c_size_t,P)(c))]
    assert all(n in names for n in [b'model-field:change',b'effort-field:change',b'fast',b'settings-done',b'settings-backdrop']),names
    ok(api('component_focus',C.c_bool,P,C.c_bool)(c,False));ok(render(c));assert delay(c)<0,delay(c)
    ok(detach(c));destroy(c)
print('PASS: workstation assistant and centered settings modal, narrow/wide, keyboard selectors, Fast, dismiss controls and idle rendering.')
