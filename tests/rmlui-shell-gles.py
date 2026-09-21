"""Native renders of the application and battery popups, including text search."""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), str(Path(__file__).parent / 'rmlui-gles.py'), 'exec'))
exec(compile((Path(__file__).parent / 'rmlui-layout.py').read_text(), __file__, 'exec'))
for face in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf', 'DejaVuSansMono-Oblique.ttf', 'DejaVuSansMono-BoldOblique.ttf']:
    ok(api('load_font', C.c_bool, C.c_char_p)(f'/usr/share/fonts/truetype/dejavu/{face}'.encode()))
set_text=api('component_set_string',C.c_bool,P,C.c_char_p,C.c_char_p)
for kind,width,height in [('menu',400,180),('menu',304,180),('power',340,210),('power',304,210),('power',304,160)]:
    bind_texture(0x0de1,tex);tex_image(0x0de1,0,0x1908,width,height,0,0x1908,0x1401,None)
    source=(root/f'src/world/rmlui/status-bar/{kind}.rml').read_bytes()
    c=create(measured_source(source,['brightness-up','sleep']),str(root/f'src/world/rmlui/status-bar/{kind}.rml').encode(),b'',width,height,1);ok(c);ok(attach(c,fbo))
    if kind=='menu':
        ok(set_class(c,b'panel',b'small',width<360))
        ok(api('model_string',C.c_bool,P,C.c_char_p,C.c_char_p)(c,b'query',b''))
        ok(api('component_register_callback',C.c_bool,P,C.c_char_p)(c,b'model:query'))
        for index,name in enumerate(['Firefox','Terminal','Emacs','Files','Calculator','Text Editor']):
            ok(set_text(c,f'name{index}'.encode(),name.encode()))
    else:
        model=api('model_string',C.c_bool,P,C.c_char_p,C.c_char_p)
        boolean=api('model_boolean',C.c_bool,P,C.c_char_p,C.c_bool)
        ok(model(c,b'brightness',b'45'))
        ok(boolean(c,b'brightness_disabled',False));ok(boolean(c,b'sleep_disabled',False))
        for name in [b'model:brightness',b'brightness-up',b'brightness-down',b'sleep']:
            ok(api('component_register_callback',C.c_bool,P,C.c_char_p)(c,name))
        for name,value in [('percent','18%'),('state','On battery'),('estimate','About 1h 24m remaining'),('health','84% of design'),('cycles','139'),('source','Battery')]:
            ok(set_text(c,name.encode(),value.encode()))
        for name,value in [('brightness-value','45%'),('brightness-note','Display backlight'),('sleep-note','Suspend to memory. Press the power button to wake.')]:
            ok(set_text(c,name.encode(),value.encode()))
        ok(set_class(c,b'panel',b'low',True))
    for _ in range(30): time.sleep(.016);ok(render(c))
    pixels=(C.c_ubyte*(width*height*4))();bind_fbo(0x8d40,fbo);read(0,0,width,height,0x1908,0x1401,pixels)
    im=Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root/f'build/{kind}-{width}-{height}.png')
    assert im.getpixel((0,0))[3]==255
    if kind=='menu':
        # Autofocus accepts typing immediately, without a synthetic pointer click.
        ok(key(c,ord('f'),True,0));ok(key(c,ord('f'),False,0));ok(render(c))
        assert model_value(c,b'query')==b'f',model_value(c,b'query')
        assert api('component_callback_count',C.c_size_t,P)(c)>0
    else:
        assert delay(c)<0,'battery panel must settle without a periodic animation'
        clear=api('component_clear_callbacks',None,P)
        count_callbacks=api('component_callback_count',C.c_size_t,P)
        callback_name=api('component_callback_name',C.c_char_p,P,C.c_size_t)
        def click(x,y):
            ok(button(c,x,y,1,True));ok(button(c,x,y,1,False));ok(render(c))
        if height==210:
            assert count_callbacks(c)==0,'model initialization must not issue a brightness command'
            up_x,up_y=box_center(element_box(c,'brightness-up',width,height))
            click(up_x,up_y)
            assert callback_name(c,0)==b'brightness-up', (kind,width,[(callback_name(c,i),api('component_callback_value',C.c_char_p,P,C.c_size_t)(c,i)) for i in range(count_callbacks(c))])
            clear(c)
            click(width//2,up_y)
            assert 45<int(float(model_value(c,b'brightness')))<65,model_value(c,b'brightness')
            assert callback_name(c,0)==b'model:brightness'
            clear(c)
            before=int(float(model_value(c,b'brightness')))
            ok(key(c,0xff53,True,0));ok(key(c,0xff53,False,0));ok(render(c))
            assert int(float(model_value(c,b'brightness')))==before+1
            assert callback_name(c,0)==b'model:brightness'
            clear(c)
            sleep_x,sleep_y=box_center(element_box(c,'sleep',width,height))
            click(sleep_x,sleep_y)
            assert callback_name(c,0)==b'sleep'
            clear(c)
            ok(boolean(c,b'sleep_disabled',True));ok(render(c))
            click(sleep_x,sleep_y)
            assert count_callbacks(c)==0,('disabled sleep button dispatched a callback',[(callback_name(c,i),api('component_callback_value',C.c_char_p,P,C.c_size_t)(c,i)) for i in range(count_callbacks(c))])
            ok(boolean(c,b'brightness_disabled',True));ok(render(c))
            click(up_x,up_y)
            assert count_callbacks(c)==0,'disabled brightness button dispatched a callback'
        else:
            # A short output scrolls to the actual Sleep control.
            scroll=api('component_pointer_scroll',C.c_bool,P,F,F,F,F)
            ok(scroll(c,width//2,120,0,3000))
            for _ in range(35): time.sleep(.016);ok(render(c))
            pixels=(C.c_ubyte*(width*height*4))();read(0,0,width,height,0x1908,0x1401,pixels)
            scrolled=Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
            scrolled.save(root/'build/power-short-scrolled.png')
            sleep_box=element_box(c,'sleep',width,height)
            assert sleep_box[3]-sleep_box[1]==16,'Sleep text is clipped on a short panel'
            click(*box_center(sleep_box))
            assert callback_name(c,0)==b'sleep'
    ok(detach(c));destroy(c)
print('PASS: large/narrow/short power panels, brightness slider/buttons, sleep, disabled controls, search autofocus, and idle.')
