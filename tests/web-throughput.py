"""Compare hardware transport costs; run once per ATAXIA_WEB_TRANSPORT mode.
This is a measurement, not a portable performance budget or CI assertion.
"""
import importlib.util
from pathlib import Path
import os
import time
spec=importlib.util.spec_from_file_location('web_fixture',Path(__file__).with_name('web-gles.py'))
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
try:
    f.wait(lambda:'ready' in f.events and f.imports(f.component)+f.uploads(f.component)>0)
    f.send(3,a=1280,b=720,scale=1)
    f.wait(lambda:f.api('width',f.I,f.P)(f.component)==1280)
    f.js("document.body.innerHTML='<style>html,body{margin:0;background:white}#motion{width:100%;height:100vh;background:linear-gradient(90deg,black 50%,white 50%);background-size:32px 32px}@keyframes move{to{background-position:640px 0}}</style><div id=motion></div>'")
    f.pump(1)
    pid=f.api('engine_pid',f.I,f.P)(f.engine)
    def measure(label):
        before=f.proc_tree(pid);own=time.process_time();beg=time.monotonic()
        frames=f.paints(f.component);data=f.uploaded(f.component);imports=f.imports(f.component)
        f.pump(5)
        elapsed=time.monotonic()-beg;host=time.process_time()-own;after=f.proc_tree(pid)
        browser=sum(max(0,after.get(p,t)-t) for p,t in before.items())/os.sysconf('SC_CLK_TCK')
        print(f'{label}: seconds={elapsed:.3f} frames={f.paints(f.component)-frames} browser_cpu_ms={browser*1000:.1f} '
              f'consumer_cpu_ms={host*1000:.1f} cpu_upload_bytes={f.uploaded(f.component)-data} new_imports={f.imports(f.component)-imports}',flush=True)
    print('TRANSPORT:', 'DMA-BUF' if f.transport(f.component) else 'bitmap',flush=True)
    measure('IDLE')
    f.js("motion.style.animation='move 4s linear infinite'");f.pump(.5)
    measure('ANIMATED-1280x720')
    f.js("motion.style.animation='none'")
finally:
    f.api('detach',None,f.P)(f.component);f.api('destroy',None,f.P,f.I)(f.component,1);f.api('engine_destroy',None,f.P)(f.engine)
