"""Run audio mutation tests on private PipeWire and Pulse sockets with a null sink."""
import os, pathlib, subprocess, tempfile, time
root=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='ataxia-audio-test-') as directory:
    env=os.environ.copy()
    env.update(XDG_RUNTIME_DIR=directory, PIPEWIRE_RUNTIME_DIR=directory,
               PULSE_RUNTIME_PATH=directory+'/pulse', PULSE_SERVER='unix:'+directory+'/pulse/native')
    config=pathlib.Path(directory)/'config/pipewire/pipewire.conf.d'
    config.mkdir(parents=True)
    (config/'10-test-metadata.conf').write_text('context.objects = [ { factory = metadata args = { metadata.name = default } } ]')
    env['XDG_CONFIG_HOME']=directory+'/config'
    processes=[]
    with open(directory+'/servers.log','w+') as log:
        try:
            for executable in ['pipewire','pipewire-pulse']:
                processes.append(subprocess.Popen([executable],env=env,stdout=log,stderr=log))
            for _ in range(100):
                if pathlib.Path(directory+'/pulse/native').exists() and pathlib.Path(directory+'/pipewire-0').exists(): break
                assert all(p.poll() is None for p in processes),'private audio server exited'
                time.sleep(.03)
            # No session manager runs in the fixture; set its default output via
            # Pulse's own public API before starting the observing clients.
            import ctypes as C
            pa=C.CDLL('libpulse.so.0'); P=C.c_void_p
            def fn(name, result, *args):
                f=getattr(pa,name); f.restype=result;f.argtypes=args;return f
            mainloop=fn('pa_mainloop_new',P)()
            api=fn('pa_mainloop_get_api',P,P)(mainloop)
            context=fn('pa_context_new',P,P,C.c_char_p)(api,b'Ataxia test setup')
            assert fn('pa_context_connect',C.c_int,P,C.c_char_p,C.c_int,P)(context,env['PULSE_SERVER'].encode(),1,None)==0
            iterate=fn('pa_mainloop_iterate',C.c_int,P,C.c_int,P)
            state=fn('pa_context_get_state',C.c_int,P)
            while state(context)!=4:
                assert state(context) not in (5,6)
                iterate(mainloop,1,None)
            modules=[]
            index_callback_type=C.CFUNCTYPE(None,P,C.c_uint32,P)
            module_callback=index_callback_type(lambda context,index,data:modules.append(index))
            module_operation=fn('pa_context_load_module',P,P,C.c_char_p,C.c_char_p,index_callback_type,P)(
                context,b'module-null-sink',b'sink_name=ataxia_test_sink channels=2',module_callback,None)
            assert module_operation
            while not modules: iterate(mainloop,1,None)
            assert modules[0]!=0xffffffff, 'private null sink could not be created'
            fn('pa_operation_unref',None,P)(module_operation)
            # PipeWire creates the module's node asynchronously.
            iterate(mainloop,0,None)
            time.sleep(.3)
            completed=[]
            callback_type=C.CFUNCTYPE(None,P,C.c_int,P)
            callback=callback_type(lambda context,success,data:completed.append(success))
            operation=fn('pa_context_set_default_sink',P,P,C.c_char_p,callback_type,P)(context,b'ataxia_test_sink',callback,None)
            assert operation
            while not completed: iterate(mainloop,1,None)
            assert completed[0], 'private null sink could not become the default'
            fn('pa_operation_unref',None,P)(operation)
            subprocess.run(['pw-metadata','-n','default','0','default.audio.sink','{"name":"ataxia_test_sink"}'],env=env,check=True,capture_output=True)
            subprocess.run(['sbcl','--noinform','--eval','(sb-int:set-floating-point-modes :traps nil)',
                            '--script','tests/shell-audio.lisp'],cwd=root,env=env,check=True,timeout=20)
            fn('pa_context_disconnect',None,P)(context);fn('pa_context_unref',None,P)(context)
            fn('pa_mainloop_free',None,P)(mainloop)
        finally:
            for p in reversed(processes):
                p.terminate()
                try: p.wait(timeout=3)
                except subprocess.TimeoutExpired: p.kill();p.wait()
