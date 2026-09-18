"""Real native rendering of workspace, media, clipboard and transient feedback."""
from pathlib import Path
exec(compile((Path(__file__).parent/'rmlui-gles.py').read_text(), str(Path(__file__).parent/'rmlui-gles.py'), 'exec'))
set_text=api('component_set_string',C.c_bool,P,C.c_char_p,C.c_char_p)
model=api('model_string',C.c_bool,P,C.c_char_p,C.c_char_p)
boolean=api('model_boolean',C.c_bool,P,C.c_char_p,C.c_bool)
register=api('component_register_callback',C.c_bool,P,C.c_char_p)
count_callbacks=api('component_callback_count',C.c_size_t,P)
callback_name=api('component_callback_name',C.c_char_p,P,C.c_size_t)
clear=api('component_clear_callbacks',None,P)
for kind,width,height in [('workspaces',560,460),('workspaces',304,340),('workspaces',560,320),('workspaces',304,320),('media',380,410),('media',304,300),('clipboard',440,460),('clipboard',304,340),('osd',340,106)]:
    bind_texture(0x0de1,tex);tex_image(0x0de1,0,0x1908,width,height,0,0x1908,0x1401,None)
    c=create((root/f'src/world/rmlui/status-bar/{kind}.rml').read_bytes(),b'controls.rml',b'',width,height,1);ok(c);ok(attach(c,fbo))
    sparse = kind=='workspaces' and height==320
    if kind=='workspaces':
        for number in range(1,10):
            ok(style(c,f'workspace-card{number}'.encode(),b'display',b'block' if not sparse or number==1 else b'none'))
        ok(style(c,b'workspace-new',b'display',b'block' if sparse else b'none'))
        ok(register(c,b'workspace-new'))
        ok(register(c,b'group-remove'))
        for number in range(1,10):
            ok(style(c,f'workspace-remove{number}'.encode(),b'display',b'none' if sparse else b'block'))
            ok(register(c,f'workspace-remove{number}'.encode()))
        ok(set_class(c,b'panel',b'small',width<480))
        if width<480:
            for name in [b'body', b'groups', b'workspaces', b'workspace-grid']:
                ok(style(c,name,b'width',f'{width-34}dp'.encode()))
        ok(set_class(c,b'group0',b'selected',True));ok(set_class(c,b'workspace1' if sparse else b'workspace2',b'selected',True))
        for i,name in enumerate(['Studio','Reading','Side project']): ok(set_text(c,f'group{i}'.encode(),name.encode()))
        for i in range(3,6): ok(style(c,f'group{i}'.encode(),b'display',b'none'))
        ok(style(c,b'group-paging',b'display',b'none'))
        ok(set_text(c,b'location',b'You are in Studio / Workspace 1' if sparse else b'You are in Studio / Workspace 2'))
        ok(set_text(c,b'workspace-detail1' if sparse else b'workspace-detail2',b'Current workspace'))
        ok(set_text(c,b'workspace-preview2',b'Terminal'))
        ok(register(c,b'workspace2'))
    elif kind=='media':
        ok(model(c,b'volume',b'64'))
        for name in ['audio','play','next','previous','player']: ok(boolean(c,f'{name}_disabled'.encode(),False))
        for name,value in [('volume-value','64%'),('device','Built-in Audio Analog Stereo'),('player','Fixture player'),('track','A track with room to breathe'),('artist','An artist · another artist'),('playback','Playing'),('play','Pause')]:
            ok(set_text(c,name.encode(),value.encode()))
        ok(register(c,b'model:volume'));ok(register(c,b'play'));ok(register(c,b'next'))
    elif kind=='clipboard':
        ok(model(c,b'query',b''));ok(register(c,b'model:query'))
        ok(style(c,b'empty',b'display',b'none'));ok(set_text(c,b'count',b'6 recent items'))
        for i,text in enumerate(['A copied sentence with context.','https://example.org/notes','Unicode stays intact: λ · 🙂','Another recent item','A project path','The previous clipboard entry']):
            ok(set_text(c,f'app{i}'.encode(),text.encode()))
        ok(set_class(c,b'app0',b'selected',True))
    else:
        ok(set_text(c,b'label',b'Volume'));ok(set_text(c,b'value',b'64%'))
        ok(set_text(c,b'detail',b'Built-in Audio Analog Stereo'));ok(style(c,b'fill',b'width',b'64%'))
    for _ in range(4): ok(render(c))
    pixels=(C.c_ubyte*(width*height*4))();bind_fbo(0x8d40,fbo);read(0,0,width,height,0x1908,0x1401,pixels)
    im=Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root/f'build/{kind}-{width}-{height}.png')
    if kind=='clipboard':
        ok(key(c,ord('a'),True,0));ok(key(c,ord('a'),False,0));ok(render(c))
        assert model_value(c,b'query')==b'a'
    elif kind=='media' and width==380:
        assert count_callbacks(c)==0
        ok(button(c,150,111,1,True));ok(button(c,150,111,1,False));ok(render(c))
        assert count_callbacks(c)>0,'volume slider did not dispatch'
    elif kind=='workspaces' and width==560 and not sparse:
        ok(button(c,350,140,1,True));ok(button(c,350,140,1,False));ok(render(c))
        assert count_callbacks(c)==1,('workspace selection not clickable',count_callbacks(c))
        assert callback_name(c,0)==b'workspace2'
        clear(c)
        ok(button(c,350,203,1,True));ok(button(c,350,203,1,False));ok(render(c))
        assert count_callbacks(c)==1,'remove also dispatched workspace selection'
        assert callback_name(c,0)==b'workspace-remove2'
        clear(c)
        ok(button(c,490,98,1,True));ok(button(c,490,98,1,False));ok(render(c))
        assert count_callbacks(c)==1,'remove subworld is not clickable'
        assert callback_name(c,0)==b'group-remove'
    if sparse and width==560:
        clear(c)
        ok(button(c,350,140,1,True));ok(button(c,350,140,1,False));ok(render(c))
        assert count_callbacks(c)==1,'new workspace tile is not clickable'
        assert callback_name(c,0)==b'workspace-new'
    if kind=='workspaces' and width==304 and not sparse:
        ok(register(c,b'workspace9'))
        scroll=api('component_pointer_scroll',C.c_bool,P,F,F,F,F)
        ok(scroll(c,150,220,0,3000))
        for _ in range(30): time.sleep(.016);ok(render(c))
        pixels=(C.c_ubyte*(width*height*4))();read(0,0,width,height,0x1908,0x1401,pixels)
        Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM).save(root/'build/workspaces-short-scrolled.png')
        clear(c)
        ok(button(c,80,222,1,True));ok(button(c,80,222,1,False));ok(render(c))
        assert count_callbacks(c)==1,'last workspace is unreachable in the short picker'
        assert callback_name(c,0)==b'workspace9'
    if kind!='clipboard': assert delay(c)<0,(kind,delay(c))
    ok(detach(c));destroy(c)
print('PASS: workspace/media/clipboard/OSD renders, narrow and short layouts, native workspace click, volume slider, clipboard search autofocus and settled idle.')
