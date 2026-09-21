"""Render the actual RmlUi picker and indicator with the GLES adapter."""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), str(Path(__file__).parent / 'rmlui-gles.py'), 'exec'))
for face in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf', 'DejaVuSansMono-Oblique.ttf', 'DejaVuSansMono-BoldOblique.ttf']:
    ok(api('load_font', C.c_bool, C.c_char_p)(f'/usr/share/fonts/truetype/dejavu/{face}'.encode()))
set_text=api('component_set_string',C.c_bool,P,C.c_char_p,C.c_char_p)
attribute=api('component_set_attribute',C.c_bool,P,C.c_char_p,C.c_char_p,C.c_char_p,C.c_bool)
register=api('component_register_callback',C.c_bool,P,C.c_char_p)
callback_count=api('component_callback_count',C.c_size_t,P)
clear_callbacks=api('component_clear_callbacks',None,P)
for kind,width,height in [('picker',540,478),('picker',304,478),('picker',304,340),('indicator',400,52)]:
    bind_texture(0x0de1,tex);tex_image(0x0de1,0,0x1908,width,height,0,0x1908,0x1401,None)
    path=root/f'src/world/screencast/{kind}.rml'
    source=path.read_bytes().replace(b'<!-- sources -->',b'<input class="action" type="button" id="app0" value="Terminal - build output"/><input class="action" type="button" id="app1" value="Browser - Design notes"/>')
    c=create(source,str(path).encode(),b'',width,height,1);ok(c);ok(attach(c,fbo))
    if kind=='picker':
        ok(register(c,b'app0'));ok(register(c,b'app1'));ok(register(c,b'share'));ok(set_text(c,b'app',b'Browser wants to share your screen'))
    for _ in range(3):ok(render(c))
    pixels=(C.c_ubyte*(width*height*4))();bind_fbo(0x8d40,fbo);read(0,0,width,height,0x1908,0x1401,pixels)
    im=Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root/f'build/qol-{kind}-{width}-{height}.png')
    assert len(im.getcolors(width*height) or [])>20, 'Expected rendered text and controls'
    if kind=='picker':
        ok(button(c,120,155,1,True));ok(button(c,120,155,1,False));ok(render(c))
        callback_name=api('component_callback_name',C.c_char_p,P,C.c_size_t)
        assert callback_count(c)==1 and callback_name(c,0)==b'app0', 'First window row must be clickable'
        clear_callbacks(c)
        if height < 400:
            # The panel scrolls when even its minimum source list cannot fit.
            # Scroll over its heading, outside the independently scrollable list.
            scroll=api('component_pointer_scroll',C.c_bool,P,F,F,F,F)
            ok(scroll(c,40,30,0,3000))
            for _ in range(35): time.sleep(.016);ok(render(c))
        read(0,0,width,height,0x1908,0x1401,pixels)
        im=Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        im.save(root/f'build/qol-{kind}-{width}-{height}-actions.png')
        # Find the disabled action's visible fill. This proves the entire action
        # remains reachable after reflow instead of assuming a screen coordinate.
        share_x=width-40
        rows=[y for y in range(height) if im.getpixel((share_x,y))[:3]==(238,238,234)]
        bands=[]
        for y in rows:
            if not bands or y > bands[-1][-1]+1: bands.append([])
            bands[-1].append(y)
        bands=[band for band in bands if len(band)==30]
        assert len(bands)==1, (width,height,'Share is clipped',rows)
        share_y=(bands[0][0]+bands[0][-1])/2
        ok(button(c,share_x,share_y,1,True));ok(button(c,share_x,share_y,1,False));ok(render(c))
        assert callback_count(c)==0,'Share must stay disabled before selection'
        ok(attribute(c,b'share',b'disabled',b'',False));ok(render(c))
        ok(button(c,share_x,share_y,1,True));ok(button(c,share_x,share_y,1,False));ok(render(c))
        assert callback_count(c)==1 and callback_name(c,0)==b'share','An explicit Share click must dispatch after selection'
    ok(detach(c));destroy(c)
print('PASS: normal/narrow/short RmlUi chooser, sharing indicator, and disabled-until-selected Share control.')
