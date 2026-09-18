"""Render the assistant design with the actual RmlUi engine; no agent or audio.
Run from a session with EGL/GLES render-device access. Requires Pillow.
"""
from pathlib import Path
__file__=str(Path(__file__).resolve().parents[2] / 'tests/assistant-preview.py')
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(),__file__,'exec'))
set_text=api('component_set_string',C.c_bool,P,C.c_char_p,C.c_char_p)
for width,height,state in [(440,600,'working'),(304,640,'working'),(440,600,'listening')]:
 bind_texture(0x0de1,tex);tex_image(0x0de1,0,0x1908,width,height,0,0x1908,0x1401,None)
 c=create((root/'examples/assistant/activity.rml').read_bytes(),b'assistant.rml',b'',width,height,1);ok(c);ok(attach(c,fbo))
 ok(api('model_string',C.c_bool,P,C.c_char_p,C.c_char_p)(c,b'message',b''))
 ok(set_class(c,b'panel',b'small',width<360))
 if state=='listening':
  ok(set_class(c,b'panel',b'listening',True));ok(set_text(c,b'state',b'Listening'))
  ok(set_text(c,b'mic-status',b'Microphone on'));ok(set_text(c,b'talk',b'Stop mic'))
  ok(set_text(c,b'target',b'Agent paused while you give a correction'))
 for _ in range(3):ok(render(c))
 pixels=(C.c_ubyte*(width*height*4))();bind_fbo(0x8d40,fbo);read(0,0,width,height,0x1908,0x1401,pixels)
 im=Image.frombytes('RGBA',(width,height),bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
 im.save(root/f'build/assistant-{state}-{width}.png')
 ok(detach(c));destroy(c)
print('PASS: assistant design preview, wide/narrow, working/listening; no network or audio.')
