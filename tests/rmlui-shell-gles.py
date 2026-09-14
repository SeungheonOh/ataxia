"""Native renders of the application and battery popups, including text search."""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), str(Path(__file__).parent / 'rmlui-gles.py'), 'exec'))
set_text=api('component_set_string',C.c_bool,P,C.c_char_p,C.c_char_p)
for kind,width,height in [('menu',590,630),('menu',304,630),('power',390,410),('power',304,410)]:
    bind_texture(0x0de1,tex);tex_image(0x0de1,0,0x1908,width,height,0,0x1908,0x1401,None)
    source=(root/f'src/world/rmlui/status-bar/{kind}.rml').read_bytes()
    c=create(source,b'shell.rml',b'',width,height,1);ok(c);ok(attach(c,fbo))
    if kind=='menu':
        ok(set_class(c,b'panel',b'small',width<460))
        ok(api('model_string',C.c_bool,P,C.c_char_p,C.c_char_p)(c,b'query',b''))
        ok(api('component_register_callback',C.c_bool,P,C.c_char_p)(c,b'model:query'))
        for index,name in enumerate(['Firefox','Terminal','Emacs','Files','Calculator','Text Editor']):
            ok(set_text(c,f'name{index}'.encode(),name.encode()));ok(set_text(c,f'icon{index}'.encode(),name[0].encode()))
    else:
        for name,value in [('percent','18%'),('state','On battery'),('estimate','About 1h 24m remaining'),('health','84% of design'),('cycles','139'),('source','Battery')]:
            ok(set_text(c,name.encode(),value.encode()))
        ok(style(c,b'fill',b'width',b'18%'));ok(set_class(c,b'panel',b'low',True))
    for _ in range(30): time.sleep(.016);ok(render(c))
    pixels=(C.c_ubyte*(width*height*4))();bind_fbo(0x8d40,fbo);read(0,0,width,height,0x1908,0x1401,pixels)
    im=Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root/f'build/{kind}-{width}.png')
    assert im.getpixel((0,0))[3]==0
    if kind=='menu':
        # Autofocus accepts typing immediately, without a synthetic pointer click.
        ok(key(c,ord('f'),True,0));ok(key(c,ord('f'),False,0));ok(render(c))
        assert model_value(c,b'query')==b'f',model_value(c,b'query')
        assert api('component_callback_count',C.c_size_t,P)(c)>0
    else:
        assert delay(c)<0,'battery panel must settle without a periodic animation'
    ok(detach(c));destroy(c)
print('PASS: large/narrow app menu and battery panels, autofocus, two-way search input, settled power panel.')
