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
    c = create(measured_source((root/f'src/world/assistant/{source}.rml').read_bytes(), ['heading','scope','close','model-settings','settings-open','settings-done','model-select','effort-select','fast-toggle','talk','mic-mute','send','message','voice-caption']), str(root/f'src/world/assistant/{source}.rml').encode(), b'', width, height, 1)
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

for width, height in [(480, 760), (304, 640)]:
    c = component('panel', width, height)
    ok(model(c,b'message',b'Keep this draft'))
    ok(model(c,b'transcript',fixture.read_bytes()))
    ok(set_class(c,b'panel',b'small',width<360))
    ok(style(c,b'model-settings',b'display',b'block'))
    ok(model(c, b'model_options', '<select id="model-select" data-value="selected_model"><option value="">GPT-6 Astra</option><option value="fixture-main">GPT-5.6 Sol</option><option value="fixture-fast">GPT-5.6 Luna</option></select><div id="model-chevron">▾</div>'.encode()))
    ok(model(c, b'selected_model', b''))
    ok(model(c, b'effort_options', '<select id="effort-select" data-value="selected_effort"><option value="">Auto · X-high</option><option value="low">Low</option><option value="high">High</option></select><div id="effort-chevron">▾</div>'.encode()))
    ok(model(c, b'selected_effort', b''))
    ok(style(c, b'models-load', b'display', b'none'))
    for name in [b'model-field:change', b'effort-field:change', b'settings-done']:
        ok(api('component_register_callback', C.c_bool, P, C.c_char_p)(c, name))
    im = capture(c, width, height, f'assistant-settings-{width}')
    settings_box=element_box(c,'model-settings',width,height)
    message_box=element_box(c,'message',width,height)
    assert settings_box[0]>=16 and settings_box[2]<=width-16, settings_box
    assert settings_box[3]<=message_box[1], (settings_box,message_box)
    assert model_value(c,b'message')==b'Keep this draft'
    # Use rendered bounds: editable rows have no extra vertical padding.
    for variable, field in [(b'selected_model', 'model-select'), (b'selected_effort', 'effort-select')]:
        _, y=box_center(element_box(c,field,width,height))
        ok(button(c, width/2, y, 1, True)); ok(button(c, width/2, y, 1, False)); ok(render(c))
        for symbol in [0xff54,0xff54,0xff0d]:
            ok(key(c,symbol,True,0)); ok(key(c,symbol,False,0)); ok(render(c))
        assert model_value(c,variable)==(b'fixture-fast' if variable==b'selected_model' else b'high'), model_value(c,variable)
    for action in ['settings-done']:
        x,y=box_center(element_box(c,action,width,height))
        ok(button(c,x,y,1,True));ok(button(c,x,y,1,False));ok(render(c))
    names=[api('component_callback_name',C.c_char_p,P,C.c_size_t)(c,i) for i in range(api('component_callback_count',C.c_size_t,P)(c))]
    assert all(n in names for n in [b'model-field:change',b'effort-field:change',b'settings-done']),names
    ok(api('component_focus',C.c_bool,P,C.c_bool)(c,False));ok(render(c))
    assert delay(c)<0, delay(c)
    stable=revision(c)
    for _ in range(8): ok(render(c))
    assert revision(c)==stable, 'Inline settings repainted while idle'
    ok(style(c,b'model-settings',b'display',b'none'))
    assert model_value(c,b'message')==b'Keep this draft'
    ok(api('component_focus',C.c_bool,P,C.c_bool)(c,False));ok(render(c));assert delay(c)<0,delay(c)
    ok(detach(c));destroy(c)
print('PASS: readable assistant and inline model settings, narrow/wide, keyboard selectors, draft preservation, Fast, voice controls and idle rendering.')
