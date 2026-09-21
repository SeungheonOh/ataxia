"""Exercise the public portal, its restricted PipeWire fd, and decoded frames."""
import os
import signal
import sys
import subprocess
import tempfile
from pathlib import Path
import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gio, GLib, Gst

Gst.init(None)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
desktop = 'org.freedesktop.portal.Desktop'
path = '/org/freedesktop/portal/desktop'
interface = 'org.freedesktop.portal.ScreenCast'
answers = {}
loop = GLib.MainLoop()

def response(connection, sender, object_path, iface, signal, args):
    answers[object_path] = args.unpack()
    loop.quit()

bus.signal_subscribe(desktop, 'org.freedesktop.portal.Request', 'Response', None, None,
                     Gio.DBusSignalFlags.NONE, response)

def request(method, signature, values, expected=0):
    handle = bus.call_sync(desktop, path, interface, method, GLib.Variant(signature, values),
                           GLib.VariantType.new('(o)'), Gio.DBusCallFlags.NONE, 10000, None).unpack()[0]
    timeout = GLib.timeout_add_seconds(10, lambda: (loop.quit(), False)[1])
    while handle not in answers:
        loop.run()
        if handle not in answers:
            raise RuntimeError('Portal request timed out: ' + method)
    GLib.source_remove(timeout)
    code, result = answers.pop(handle)
    assert code == expected, (method, code, result)
    return result

with tempfile.TemporaryDirectory(prefix='ataxia-portal-test-') as config:
    portal_config = Path(config) / 'xdg-desktop-portal'
    portal_config.mkdir()
    (portal_config / 'ataxia-portals.conf').write_text('[preferred]\ndefault=ataxia\n')
    env = dict(os.environ, XDG_CURRENT_DESKTOP='Ataxia', XDG_CONFIG_HOME=config,
               XDG_DESKTOP_PORTAL_DIR=str(Path('data/portals').resolve()))
    with open('/tmp/ataxia-portal-frontend.log', 'w') as log:
        frontend = subprocess.Popen(['/usr/libexec/xdg-desktop-portal', '--verbose'], env=env, stdout=log, stderr=log)
    try:
        ready = []
        watch = Gio.bus_watch_name_on_connection(bus, desktop, Gio.BusNameWatcherFlags.NONE,
                                                lambda *args: (ready.append(True), loop.quit()), None)
        timeout = GLib.timeout_add_seconds(10, lambda: (loop.quit(), False)[1])
        loop.run()
        GLib.source_remove(timeout)
        Gio.bus_unwatch_name(watch)
        assert ready, 'Desktop portal did not start'
        # Idle source enumeration must not exhaust the active-stream quota.
        prepared = []
        for index in range(16):
            prepared.append(request('CreateSession', '(a{sv})', ({
                'session_handle_token': GLib.Variant('s', f'prepared_{index}')},))['session_handle'])
        for session in prepared:
            bus.call_sync(desktop, session, 'org.freedesktop.portal.Session', 'Close', None, None, 0, 5000, None)
        print('PASS: sixteen prepared sessions do not consume the stream quota', flush=True)
        streams = []
        for kind in (2, 1, 3):
            result = request('CreateSession', '(a{sv})', ({'session_handle_token': GLib.Variant('s', f'ataxia_test_{kind}')},))
            session = result['session_handle']
            request('SelectSources', '(oa{sv})', (session, {'types': GLib.Variant('u', kind), 'cursor_mode': GLib.Variant('u', 1)}))
            if kind == 3:
                request('Start', '(osa{sv})', (session, '', {}), expected=1)
                print('PASS: cancelled sharing request exports no stream', flush=True)
                continue
            result = request('Start', '(osa{sv})', (session, '', {}))
            node, props = result['streams'][0]
            assert props['source_type'] == kind
            remote, fds = bus.call_with_unix_fd_list_sync(desktop, path, interface, 'OpenPipeWireRemote',
                             GLib.Variant('(oa{sv})', (session, {})), GLib.VariantType.new('(h)'),
                             Gio.DBusCallFlags.NONE, 5000, None, None)
            fd = fds.get(remote.unpack()[0])
            pipeline = Gst.parse_launch(f'pipewiresrc fd={fd} path={node} do-timestamp=true ! video/x-raw,format=RGBA ! appsink name=frames sync=false max-buffers=2 drop=true')
            streams.append((session, pipeline, fd))
            try:
                pipeline.set_state(Gst.State.PLAYING)
                sink = pipeline.get_by_name('frames')
                colored = False
                for _ in range(8):
                    sample = sink.emit('try-pull-sample', 2 * Gst.SECOND)
                    if sample is None:
                        message = pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR)
                        raise RuntimeError(message.parse_error() if message else 'No PipeWire frame')
                    caps = sample.get_caps().get_structure(0)
                    width, height = caps.get_value('width'), caps.get_value('height')
                    buffer = sample.get_buffer()
                    ok, data = buffer.map(Gst.MapFlags.READ)
                    assert ok
                    try:
                        # Fixture is blue/green; an all-black stream cannot pass.
                        for offset in range(0, len(data.data)-4, max(4, (len(data.data)//128)//4*4)):
                            r, g, b, a = data.data[offset:offset+4]
                            colored |= max(r,g,b)-min(r,g,b)>60 and max(r,g,b)>100 and a>240
                    finally:
                        buffer.unmap(data)
                    if colored:
                        break
                assert colored, 'PipeWire delivered no application pixels'
                print(f'PASS: public portal consent, restricted PipeWire fd, and {width}x{height} pixels (source type {kind})', flush=True)
            except Exception:
                for _, stream, stream_fd in streams:
                    stream.set_state(Gst.State.NULL)
                    os.close(stream_fd)
                streams.clear()
                raise
            if kind == 2:
                for _ in range(30):
                    assert sink.emit('try-pull-sample', 2 * Gst.SECOND), 'Cached stream stopped'
                # A fresh client buffer must invalidate the cache even if the
                # window is offscreen and no pointer or camera moves.
                os.kill(int(sys.argv[1]), signal.SIGUSR1)
                updated = False
                for _ in range(12):
                    sample = sink.emit('try-pull-sample', 2 * Gst.SECOND)
                    assert sample
                    buffer = sample.get_buffer()
                    ok, data = buffer.map(Gst.MapFlags.READ)
                    assert ok
                    try:
                        offset = (20 * width + 20) * 4
                        updated = tuple(data.data[offset:offset+4]) == (72, 207, 96, 255)
                    finally:
                        buffer.unmap(data)
                    if updated:
                        break
                assert updated, 'Changed source pixels were hidden by the sharing cache'
                print('PASS: cached stream keeps delivering frames and updates on client repaint', flush=True)
            if len(streams) == 2:
                # Both independent sources must keep producing frames together.
                # Pull beyond appsink's queue so stale buffered frames cannot pass.
                for _ in range(5):
                    for _, stream, _ in streams:
                        assert stream.get_by_name('frames').emit('try-pull-sample', 2 * Gst.SECOND)
                print('PASS: window and canvas-region streams run concurrently', flush=True)
                old_session, old_pipeline, old_fd = streams.pop(0)
                old_pipeline.set_state(Gst.State.NULL)
                os.close(old_fd)
                bus.call_sync(desktop, old_session, 'org.freedesktop.portal.Session', 'Close', None, None, 0, 5000, None)
                for _ in range(5):
                    sample = sink.emit('try-pull-sample', 2 * Gst.SECOND)
                    assert sample, 'Closing one session stopped the other stream'
                print('PASS: closing one share leaves the other producing new frames', flush=True)
        for session, pipeline, fd in streams:
            pipeline.set_state(Gst.State.NULL)
            os.close(fd)
            bus.call_sync(desktop, session, 'org.freedesktop.portal.Session', 'Close', None, None, 0, 5000, None)
        streams.clear()

    finally:
        frontend.terminate()
        frontend.wait(timeout=5)
