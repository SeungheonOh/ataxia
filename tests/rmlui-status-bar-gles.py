"""Real renderer snapshots and idle/transition checks for the status bar."""
from pathlib import Path
# Reuse the EGL fixture and validated native adapter checks.
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), str(Path(__file__).parent / 'rmlui-gles.py'), 'exec'))
for face in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf', 'DejaVuSansMono-Oblique.ttf', 'DejaVuSansMono-BoldOblique.ttf']:
    ok(api('load_font', C.c_bool, C.c_char_p)(f'/usr/share/fonts/truetype/dejavu/{face}'.encode()))
property_text=api('component_set_string',C.c_bool,P,C.c_char_p,C.c_char_p)
source=(root/'src/world/rmlui/status-bar/bar.rml').read_bytes()
for width,scale in [(1320,1),(820,1),(480,1),(320,1),(820,2)]:
    height=18
    bind_texture(0x0de1,tex)
    tex_image(0x0de1,0,0x1908,width*scale,height*scale,0,0x1908,0x1401,None)
    c=create(source,str(root/'src/world/rmlui/status-bar/bar.rml').encode(),b'',width*scale,height*scale,scale);ok(c)
    ok(attach(c,fbo))
    for name,enabled in [('compact',width<1050),('narrow',width<680),('tiny',width<380)]:
        ok(set_class(c,b'bar',name.encode(),enabled))
    for index in range(4,10): ok(style(c,f'ws{index}'.encode(),b'display',b'none'))
    for name,value in [('group','Studio / Workspace 2 ▾'),('title','Ataxia — a quieter desktop'),('apps','11 apps'),('clock','14:32'),('date','THU, SEP 10'),('power-text','84%')]:
        ok(property_text(c,name.encode(),value.encode()))
    ok(style(c,b'charge',b'width',b'84%'))
    ok(render(c))

    for _ in range(50): time.sleep(.016);ok(render(c))
    assert delay(c)<0,delay(c)
    pixels=(C.c_ubyte*(width*scale*height*scale*4))()
    bind_fbo(0x8d40,fbo);read(0,0,width*scale,height*scale,0x1908,0x1401,pixels)
    im=Image.frombytes('RGBA',(width*scale,height*scale),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root/f'build/status-bar-{width}-{scale}x.png')
    assert im.getpixel((width*scale//2,9*scale))[3]>200
    assert im.getpixel((0,0))[3]==255
    assert im.getpixel((0,height*scale-1))[:3]==(255,255,255)
    # A selection change updates immediately and settles without animation.
    ok(set_class(c,b'ws1',b'selected',False))
    ok(set_class(c,b'ws2',b'selected',True))
    ok(render(c)); assert delay(c)<0
    rev=revision(c)
    for _ in range(8): ok(render(c))
    assert revision(c)==rev
    if width == 1320:
        ok(api('component_register_callback',C.c_bool,P,C.c_char_p)(c,b'group'))
        ok(button(c,150,9,1,True));ok(button(c,150,9,1,False))
        assert api('component_callback_count',C.c_size_t,P)(c)==1
        assert api('component_callback_name',C.c_char_p,P,C.c_size_t)(c,0)==b'group'
        # A stationary hovered button must also return to idle.
        for _ in range(30): time.sleep(.016);ok(render(c))
        assert delay(c)<0
    ok(detach(c));destroy(c)
print('PASS: status bar at 320/480/820/1320 logical pixels, 1x/2x, static selection and settled idle.')
