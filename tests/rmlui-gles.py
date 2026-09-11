"""Render the real RmlUi adapter and verify pixels, GL isolation, input, and idle."""
import ctypes as C
import os
from pathlib import Path
import sys
import time
from PIL import Image

os.environ.setdefault('EGL_PLATFORM', 'surfaceless')
egl = C.CDLL('libEGL.so.1')
gl = C.CDLL('libGLESv2.so.2')
I, U, F, P = C.c_int, C.c_uint, C.c_float, C.c_void_p

def bind(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn

get_display = bind(egl, 'eglGetDisplay', P, P)
initialize = bind(egl, 'eglInitialize', U, P, P, P)
choose = bind(egl, 'eglChooseConfig', U, P, P, P, I, P)
create_surface = bind(egl, 'eglCreatePbufferSurface', P, P, P, P)
create_context = bind(egl, 'eglCreateContext', P, P, P, P, P)
current = bind(egl, 'eglMakeCurrent', U, P, P, P, P)
display = get_display(None)
assert initialize(display, None, None)
config, count = P(), I()
attrs = (I * 15)(0x3033, 1, 0x3040, 4, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3025, 0, 0x3038)
assert choose(display, attrs, C.byref(config), 1, C.byref(count)) and count.value
surface = create_surface(display, config, (I * 5)(0x3057, 600, 0x3056, 600, 0x3038))
context = create_context(display, config, None, (I * 3)(0x3098, 2, 0x3038))
assert surface and context and current(display, surface, surface, context)
print('GLES renderer:', bind(gl, 'glGetString', C.c_char_p, U)(0x1F01).decode())
root=Path(__file__).resolve().parent.parent
native=C.CDLL(str(root/'build/libataxia-rmlui-native.so'))
def api(name,result,*args): return bind(native,'ataxia_rmlui_'+name,result,*args)
error=api('last_error',C.c_char_p)
def ok(value): assert value,error().decode()
create=api('component_create',P,C.c_char_p,C.c_char_p,C.c_char_p,U,U,F)
attach=api('component_attach_graphics',C.c_bool,P,U)
render=api('component_render',C.c_bool,P)
detach=api('component_detach_graphics',C.c_bool,P)
destroy=api('component_destroy',None,P)
revision=api('component_revision',C.c_uint64,P)
delay=api('component_next_update',C.c_double,P)
style=api('component_set_style',C.c_bool,P,C.c_char_p,C.c_char_p,C.c_char_p)
set_class=api('component_set_class',C.c_bool,P,C.c_char_p,C.c_char_p,C.c_bool)
reload=api('component_reload',C.c_bool,P,C.c_char_p,C.c_char_p)
get_int=bind(gl,'glGetIntegerv',None,U,P)
def integer(name,n=1):
    values=(I*n)();get_int(name,values);return tuple(values) if n>1 else values[0]
gl_error=bind(gl,'glGetError',U)
gen_texture=bind(gl,'glGenTextures',None,I,P)
bind_texture=bind(gl,'glBindTexture',None,U,U)
tex_image=bind(gl,'glTexImage2D',None,U,I,I,I,I,I,U,U,P)
tex_param=bind(gl,'glTexParameteri',None,U,U,I)
gen_fbo=bind(gl,'glGenFramebuffers',None,I,P)
bind_fbo=bind(gl,'glBindFramebuffer',None,U,U)
fbo_texture=bind(gl,'glFramebufferTexture2D',None,U,U,U,U,I)
viewport=bind(gl,'glViewport',None,I,I,I,I)
read=bind(gl,'glReadPixels',None,I,I,I,I,U,U,P)
tex=U();gen_texture(1,C.byref(tex));bind_texture(0x0de1,tex)
tex_param(0x0de1,0x2801,0x2601);tex_param(0x0de1,0x2800,0x2601)
tex_image(0x0de1,0,0x1908,320,240,0,0x1908,0x1401,None)
fbo=U();gen_fbo(1,C.byref(fbo));bind_fbo(0x8d40,fbo);fbo_texture(0x8d40,0x8ce0,0x0de1,tex,0)
assert bind(gl,'glCheckFramebufferStatus',U,U)(0x8d40)==0x8cd5
ok(api('initialize',C.c_bool)())
source=b'''<rml><head><style>
body { margin:0; width:100%; height:100%; font-family:DejaVu Sans; font-size:16dp; }
#button { position:absolute; left:20dp; top:20dp; width:100dp; height:80dp; background:#ed4040; border-radius:12dp; }
#gradient { position:absolute; left:150dp; top:20dp; width:100dp; height:80dp; decorator:linear-gradient(90deg, #10dd77, #2040ff); }
#shadow { position:absolute; left:150dp; top:140dp; width:80dp; height:40dp; background:#ffffff; box-shadow:#ff8800 0dp 0dp 8dp 5dp; }
#button.fade { animation:0.1s linear 1 fade; }
@keyframes fade { from { opacity:0.2; } to { opacity:1; } }
</style></head><body><div id="button">Click</div><div id="gradient"></div><div id="shadow"></div></body></rml>'''
c=create(source,b'tests/rmlui-gles.rml',b'',320,240,1);ok(c)
# Attach and render must preserve a non-default target, viewport, and texture binding.
viewport(7,9,111,113)
before=(integer(0x8ca6),integer(0x0ba2,4),integer(0x8069),integer(0x8b8d))
ok(attach(c,fbo));ok(render(c))
after=(integer(0x8ca6),integer(0x0ba2,4),integer(0x8069),integer(0x8b8d))
assert before==after,(before,after)
assert gl_error()==0
pixels=(C.c_ubyte*(320*240*4))();read(0,0,320,240,0x1908,0x1401,pixels)
im=Image.frombytes('RGBA',(320,240),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
im.save(root/'build/rmlui-gles.png')
assert im.getpixel((0,0))[3]==0,im.getpixel((0,0))
assert im.getpixel((60,70))[0]>180,im.getpixel((60,70))
assert im.getpixel((20,20))[3]<100,im.getpixel((20,20))
assert im.getpixel((160,60))!=im.getpixel((240,60)),'gradient missing'
assert im.getpixel((146,160))[3]>0,'blurred shadow missing'
# Real native click, with bounded event payloads copied before clearing.
ok(api('component_register_callback',C.c_bool,P,C.c_char_p)(c,b'button'))
button=api('component_pointer_button',C.c_bool,P,F,F,U,C.c_bool)
ok(button(c,60,70,1,True));ok(button(c,60,70,1,False))
assert api('component_callback_count',C.c_size_t,P)(c)==1
assert api('component_callback_name',C.c_char_p,P,C.c_size_t)(c,0)==b'button'
api('component_clear_callbacks',None,P)(c)
ok(render(c));ok(render(c))
assert delay(c)<0,delay(c)
rev=revision(c)
for _ in range(20):ok(render(c))
assert revision(c)==rev,'static component rerendered'
ok(set_class(c,b'button',b'fade',True));ok(render(c));assert delay(c)==0,delay(c)
time.sleep(.15);ok(render(c));ok(render(c));assert delay(c)<0,delay(c)
# Invalid replacement cannot drop the previous bound document.
assert not reload(c,b'<rml><head/><body><div/></body></rml>',b'replacement.rml')
ok(button(c,60,70,1,True));ok(button(c,60,70,1,False))
assert api('component_callback_count',C.c_size_t,P)(c)>=1
ok(detach(c));ok(attach(c,fbo));ok(render(c));ok(detach(c));destroy(c)
# Native scalar data binding, user edits, and model persistence through reload.
model_source=b'''<rml><head><style>
body { margin:0; font-family:DejaVu Sans; font-size:16dp; }
input { position:absolute; left:20dp; top:20dp; width:180dp; height:40dp; background:#ffffff; color:#111111; }
</style></head><body data-model="state"><input id="editor" type="text" data-value="title" /></body></rml>'''
m=create(model_source,b'model.rml',b'',320,240,1);ok(m)
ok(api('model_string',C.c_bool,P,C.c_char_p,C.c_char_p)(m,b'title',b'Hi'))
ok(api('component_register_callback',C.c_bool,P,C.c_char_p)(m,b'model:title'))
ok(attach(m,fbo));ok(render(m))
ok(button(m,80,35,1,True));ok(button(m,80,35,1,False))
key=api('component_key_symbol',C.c_bool,P,U,C.c_bool,I)
ok(key(m,0xff57,True,0));ok(key(m,0xff57,False,0))
ok(key(m,ord('!'),True,0));ok(key(m,ord('!'),False,0));ok(render(m))
model_value=api('model_value',C.c_char_p,P,C.c_char_p)
assert model_value(m,b'title')==b'Hi!',model_value(m,b'title')
assert api('component_callback_count',C.c_size_t,P)(m)>0
assert api('component_callback_name',C.c_char_p,P,C.c_size_t)(m,0)==b'model:title'
ok(reload(m,model_source,b'model.rml'));ok(render(m))
assert model_value(m,b'title')==b'Hi!'
ok(detach(m));destroy(m)
assert gl_error()==0
print('PASS: RmlUi pixels, gradients/shadows, clipping, GL isolation, callbacks, animation-to-idle, reload failure, reattachment, two-way scalar binding.')
