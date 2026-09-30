"""Real Chromium pixels, modules, fetch, WebGL, damage, popup input and process-tree idle.
Requires the ordinary sandboxed helper (or an explicitly supplied fixture launcher).
"""
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
surface = create_surface(display, config, (I * 5)(0x3057, 320, 0x3056, 240, 0x3038))
context = create_context(display, config, None, (I * 3)(0x3098, 2, 0x3038))
assert surface and context and current(display, surface, surface, context)
print('GLES renderer:', bind(gl, 'glGetString', C.c_char_p, U)(0x1F01).decode())
import json, select
root=Path(__file__).resolve().parent.parent
native=C.CDLL(str(root/'build/libataxia-web-native.so'))
def api(n,r,*a):return bind(native,'ataxia_web_'+n,r,*a)
S=C.c_char_p;D=C.c_double;Q=C.c_uint64
error=api('error',S)
# Exercise startup with a busy host FD table, including the old IPC target range.
occupied=[]
try:
    while not occupied or occupied[-1]<195:occupied.append(os.open('/dev/null',os.O_RDONLY|os.O_CLOEXEC))
    engine=api('engine_create_for_display',P,S,S)(
        os.environ.get('ATAXIA_WEB_HELPER',str(root/'build/web-native/ataxia-web-helper')).encode(),
        os.environ.get('ATAXIA_WEB_TEST_DISPLAY','').encode())
finally:
    for descriptor in occupied:os.close(descriptor)
assert engine,error()
component=api('create',P,P,I,I,D,S)(engine,320,240,1,(str(root/'tests/web-ui')+'\nataxia://ui/index.html').encode())
assert component,error()
command=api('command',I,P,I,I,I,I,I,D,S)
upload=api('upload',I,P,P);paints=api('paints',Q,P);uploads=api('uploads',Q,P);uploaded=api('uploaded_bytes',Q,P)
imports=api('gpu_imports',Q,P);copies=api('gpu_copies',Q,P);transport=api('transport',I,P)
event=api('event',I,P,P,P);drain=api('engine_drain',None,P);wake=api('engine_fd',I,P)(engine)
events={};rect=(I*4)()
def send(op,a=0,b=0,c=0,d=0,scale=0,text=''):
    assert command(component,op,a,b,c,d,scale,text.encode()),error()
def js(code):send(11,text=code)
def pump(seconds):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        select.select([wake],[],[],max(0,until-time.monotonic()));drain(engine)
        name=C.create_string_buffer(80);value=C.create_string_buffer(8192)
        while event(component,name,value):events[name.value.decode()]=json.loads(value.value)
        assert 'error' not in events,events
        assert upload(component,rect)>=0,error()
def wait(predicate,seconds=10):
    until=time.monotonic()+seconds
    while not predicate():
        assert time.monotonic()<until,(events, {'size':(api('width',I,P)(component),api('height',I,P)(component)),'copies':copies(component),'imports':imports(component),'skipped':api('skipped',Q,P)(component)})
        pump(.05)
def proc_tree(pid):
    # Chromium also forks from non-main threads. /task/PID/children alone misses
    # those subprocesses, so collect parent TGIDs from /proc/*/stat instead.
    records={}
    for path in Path('/proc').iterdir():
        if not path.name.isdecimal():continue
        try:
            fields=(path/'stat').read_text().split(') ',1)[1].split()
            records[int(path.name)]=(int(fields[1]),int(fields[11])+int(fields[12]))
        except (FileNotFoundError,ProcessLookupError,PermissionError):pass
    result={}
    def walk(p):
        if p not in records:return
        result[p]=records[p][1]
        for child,(parent,_) in records.items():
            if parent==p:walk(child)
    walk(pid);return result
get_int=bind(gl,'glGetIntegerv',None,U,P)
def integer(n):v=I();get_int(n,C.byref(v));return v.value
gen_fbo=bind(gl,'glGenFramebuffers',None,I,P);bind_fbo=bind(gl,'glBindFramebuffer',None,U,U)
fbo_texture=bind(gl,'glFramebufferTexture2D',None,U,U,U,U,I)
read=bind(gl,'glReadPixels',None,I,I,I,I,U,U,P)
fbo=U();gen_fbo(1,C.byref(fbo))
def pixels():
    w=api('width',I,P)(component);h=api('height',I,P)(component)
    bind_fbo(0x8d40,fbo);fbo_texture(0x8d40,0x8ce0,0xde1,api('texture',U,P)(component),0)
    data=(C.c_ubyte*(w*h*4))();read(0,0,w,h,0x1908,0x1401,data)
    assert bind(gl,'glGetError',U)()==0
    return Image.frombytes('RGBA',(w,h),bytes(data))
if __name__ == '__main__':
    try:
        wait(lambda:'ready' in events and uploads(component)+imports(component)>0)
        assert events['ready']=={'module':42,'fetch':True,'grid':True,'webgl2':True},events
        pump(.5)
        img=pixels();img.save('/tmp/ataxia-web-native.png')
        assert img.getpixel((20,20))==(128,0,0,128),img.getpixel((20,20))
        assert img.getpixel((20,220))==(0,0,255,255)
        assert img.getpixel((300,220))==(0,0,0,0)
        assert img.getpixel((210,40))==(0,255,0,255)
        # Dirty upload, independent of unrelated compositor frames, preserves GL bindings.
        before=uploaded(component);old_paints=paints(component)
        pixel_store=bind(gl,'glPixelStorei',None,U,I)
        pixel_store(0x0cf4,3);pixel_store(0x0cf3,2);pixel_store(0x0cf2,73);pixel_store(0x0cf5,8)
        js("tiny.style.background='#ff00ff'")
        wait(lambda:paints(component)>old_paints)
        assert [integer(n) for n in (0x0cf4,0x0cf3,0x0cf2,0x0cf5)]==[3,2,73,8]
        for n in (0x0cf4,0x0cf3,0x0cf2):pixel_store(n,0)
        pixel_store(0x0cf5,4)
        assert uploaded(component)-before<320*240*4,(uploaded(component)-before)
        if transport(component):assert uploads(component)==0 and uploaded(component)==0 and copies(component)>0
        assert pixels().getpixel((210,40))==(255,0,255,255)
        binding=integer(0x8069);framebuffer=integer(0x8ca6)
        before_upload=uploads(component)
        for _ in range(100):assert not upload(component,rect)
        assert uploads(component)==before_upload and integer(0x8069)==binding and integer(0x8ca6)==framebuffer
        # Native select popup is part of this drawable, and keyboard input selects B.
        send(5,a=1);send(6,a=140,b=110);send(7,a=140,b=110,c=1,d=1);send(7,a=140,b=110,c=1,d=0)
        pump(.3);pixels().save('/tmp/ataxia-web-popup.png')
        send(9,a=40,b=1);send(9,a=40,b=0);send(9,a=13,b=1);send(9,a=13,b=0)
        wait(lambda:events.get('choice')=='B')
        send(5,a=0);js('document.activeElement.blur()');pump(1)
        # No paints or texture uploads at idle, including the browser process tree.
        pid=api('engine_pid',I,P)(engine);before_cpu=proc_tree(pid);before=paints(component);before_upload=uploads(component)
        start=time.monotonic();pump(5);elapsed=time.monotonic()-start;after_cpu=proc_tree(pid)
        cpu=sum(max(0,after_cpu.get(p,t)-t) for p,t in before_cpu.items())/os.sysconf('SC_CLK_TCK')
        print(f'BROWSER-IDLE: seconds={elapsed:.3f} paints={paints(component)-before} uploads={uploads(component)-before_upload} process-tree-cpu-ms={cpu*1000:.3f} processes={len(after_cpu)}')
        if not os.environ.get('ATAXIA_WEB_HELPER'):
            renderers=[]
            for child in after_cpu:
                try:
                    args=Path(f'/proc/{child}/cmdline').read_bytes().replace(b'\0',b' ').split()
                    if b'--type=renderer' in args:
                        status=Path(f'/proc/{child}/status').read_text()
                        assert b'--no-sandbox' not in args
                        assert 'Seccomp:\t2' in status and 'NoNewPrivs:\t1' in status,status
                        renderers.append(child)
                except FileNotFoundError:
                    pass
            assert renderers, 'No sandboxed renderer found'
            print('SANDBOX: renderer seccomp filters and no-new-privileges are active.')
        assert paints(component)==before and uploads(component)==before_upload
        assert cpu<elapsed*.03,f'Idle browser CPU above 3% of one core: {cpu/elapsed:.2%}'
        js("tiny.animate([{transform:'translateX(0)'},{transform:'translateX(50px)'}],{duration:300}).onfinish=()=>ataxia.postMessage('animated',true)")
        wait(lambda:events.get('animated'))
        assert paints(component)>before
        pump(.5)
        # Resize and device pixel ratio are real browser viewport changes.
        send(3,a=240,b=160,scale=1.5)
        wait(lambda:api('width',I,P)(component)==360 and api('height',I,P)(component)==240)
        js("ataxia.postMessage('size',[innerWidth,innerHeight,devicePixelRatio])")
        wait(lambda:'size' in events);assert events['size']==[240,160,1.5],events
        assert pixels().getpixel((100,20))==(128,0,0,128),pixels().getpixel((100,20))
        js("document.addEventListener('pointerdown',e=>ataxia.postMessage('scaled-pointer',[e.clientX,e.clientY]),{once:true})")
        pump(.1);send(6,a=100,b=50);send(7,a=100,b=50,c=1,d=1);send(7,a=100,b=50,c=1,d=0)
        wait(lambda:'scaled-pointer' in events);assert events['scaled-pointer']==[100,50],events
        if transport(component):
            send(3,a=320,b=240,scale=1.5)
            wait(lambda:api('width',I,P)(component)==480)
            send(5,a=1);pump(.1)
            send(6,a=140,b=110);send(7,a=140,b=110,c=1,d=1);send(7,a=140,b=110,c=1,d=0)
            wait(lambda:api('popup_texture',U,P)(component)>0)
            pump(.2)
            assert api('popup_x',I,P)(component)==150
            assert api('popup_y',I,P)(component)==186
            assert api('popup_width',I,P)(component)==240
            send(9,a=27,b=1);send(9,a=27,b=0);pump(.1)
        api('detach',None,P)(component);assert upload(component,rect)
        print(f'TRANSPORT: {"DMA-BUF" if transport(component) else "bitmap"}; GPU copies={copies(component)} imports={imports(component)} CPU-upload-bytes={uploaded(component)}')
        print('PASS: real browser pixels/alpha, modules/fetch/Grid/WebGL2, partial upload, popup input, animations, scale, reattach and idle.')
    finally:
        api('detach',None,P)(component);api('destroy',None,P,I)(component,1);api('engine_destroy',None,P)(engine)
