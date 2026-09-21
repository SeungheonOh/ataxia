"""Actual action bounds, hit tests and inversion, including crowded shell states."""
from pathlib import Path
import itertools
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), __file__, 'exec'))
exec(compile((Path(__file__).parent / 'rmlui-layout.py').read_text(), __file__, 'exec'))
for face in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf']:
    ok(api('load_font', C.c_bool, C.c_char_p)(f'/usr/share/fonts/truetype/dejavu/{face}'.encode()))
text = api('component_set_string', C.c_bool, P, C.c_char_p, C.c_char_p)
register = api('component_register_callback', C.c_bool, P, C.c_char_p)
clear = api('component_clear_callbacks', None, P)
count = api('component_callback_count', C.c_size_t, P)
callback = api('component_callback_name', C.c_char_p, P, C.c_size_t)
motion = api('component_pointer_motion', C.c_bool, P, F, F)
focus = api('component_focus', C.c_bool, P, C.c_bool)
boolean = api('model_boolean', C.c_bool, P, C.c_char_p, C.c_bool)

cases = [
    ('rmlui/status-bar/bar', 18, ['home', 'group', 'assistant', 'audio', 'power']),
    ('rmlui/status-bar/menu', 180, ['close', 'overview', 'power', 'prev', 'next'] + [f'app{i}' for i in range(6)]),
    ('rmlui/status-bar/media', 146, ['close', 'mute', 'player', 'previous', 'play', 'next']),
    ('rmlui/status-bar/power', 210, ['close', 'brightness-down', 'brightness-up', 'sleep']),
    ('rmlui/status-bar/clipboard', 196, ['close', 'prev', 'next', 'clear'] + [f'app{i}' for i in range(6)]),
    ('rmlui/status-bar/workspaces', 260, ['close', 'group0', 'group-prev', 'group-next', 'group-remove', 'workspace1', 'workspace-new', 'overview']),
    ('assistant/settings', 640, ['settings-close', 'fast', 'settings-done']),
    ('screencast/picker', 178, ['region', 'app0', 'app1', 'cancel', 'share']),
    ('screencast/indicator', 18, ['stop']),
    ('assistant/panel', 640, ['scope', 'close', 'pause', 'stop', 'undo', 'settings-open', 'talk', 'send', 'details']),
    ('computer-use/panel', 98, ['pause-all', 'resume0', 'stop0']),
]
for name, height, ids in cases:
    for width in [280, 304, 480, 820]:
        if name == "screencast/picker": height = 178 if width < 400 else 146
        bind_texture(0x0de1, tex)
        tex_image(0x0de1, 0, 0x1908, width, height, 0, 0x1908, 0x1401, None)
        path = root / f'src/world/{name}.rml'
        source = path.read_bytes().replace(b'<!-- sources -->',
            b'<input class="action" type="button" id="app0" value="Firefox - design notes"/>'
            b'<input class="action" type="button" id="app1" value="Terminal - build output"/>')
        c = create(measured_source(source, ids), str(path).encode(), b'', width, height, 1)
        ok(c); ok(attach(c, fbo)); assert not error(), error()
        if name.endswith('/bar'):
            for cls, limit in [('compact', 1050), ('narrow', 680), ('tiny', 380)]:
                ok(set_class(c, b'bar', cls.encode(), width < limit))
            ok(style(c, b'assistant', b'display', b'block'))
            ok(text(c, b'group', b'A very long project name / Workspace 123'))
            ok(text(c, b'power-text', b'100%'))
        if name == 'assistant/panel':
            ok(set_class(c, b'panel', b'small', width < 360))
            ok(style(c, b'controls', b'display', b'flex'))
        if name == 'assistant/settings':
            ok(style(c, b'models-load', b'display', b'none'))
        if name == 'rmlui/status-bar/workspaces':
            ok(set_class(c, b'panel', b'small', width < 480))
            for i in range(1, 6): ok(style(c, f'group{i}'.encode(), b'display', b'none'))
            ok(text(c, b'group-title', b'A very long project name'))
            # Match the World host's definite widths on the stacked layout.
            if width < 480:
                for element in ['body', 'groups', 'workspaces', 'workspace-grid']:
                    ok(style(c, element.encode(), b'width', f'{width-2}dp'.encode()))
        if name == 'computer-use/panel':
            for prop, value in [('width', f'{width}dp'), ('height', f'{height}dp')]:
                ok(style(c, b'panel', prop.encode(), value.encode()))
            for element, value in [('empty', 'none'), ('card0', 'block'), ('pause0', 'none')]:
                ok(style(c, element.encode(), b'display', value.encode()))
            ok(text(c, b'name0', b'A very long agent name'))
        for key in ['audio_disabled', 'player_disabled', 'previous_disabled', 'play_disabled', 'next_disabled', 'brightness_disabled', 'sleep_disabled']:
            ok(boolean(c, key.encode(), False))
        if name == 'screencast/picker':
            ok(api('component_set_attribute', C.c_bool, P, C.c_char_p, C.c_char_p, C.c_char_p, C.c_bool)(c, b'share', b'disabled', b'', False))
        for element in ids: ok(register(c, element.encode()))
        ok(focus(c, False))
        try:
            boxes = {element: element_box(c, element, width, height) for element in ids}
        except AssertionError:
            rendered_image(c,width,height).save(root/'build/action-layout-failure.png')
            raise
        for element, box in boxes.items():
            x0, y0, x1, y1 = box
            assert x0 >= 0 and x1 <= width and y0 >= 1 and y1 <= height, (name, width, element, 'clipped', box)
            assert x1-x0 >= 6 and y1-y0 >= 16, (name, width, element, 'collapsed', box)
        for (a, ab), (b, bb) in itertools.combinations(boxes.items(), 2):
            assert min(ab[2], bb[2]) <= max(ab[0], bb[0]) or min(ab[3], bb[3]) <= max(ab[1], bb[1]), (name, width, a, b, 'overlap', ab, bb)
        for element, box in boxes.items():
            clear(c)
            x, y = box_center(box)
            ok(button(c, x, y, 1, True)); ok(button(c, x, y, 1, False)); ok(render(c))
            assert count(c) == 1 and callback(c, 0) == element.encode(), (name, width, element, 'wrong hit target')
        # Ordinary command text has no frame/fill at rest; hover and keyboard
        # focus invert the text area immediately, without scheduling animation.
        if name.endswith('/menu'):
            ok(motion(c, 0, 0)); ok(focus(c, False))
            box = boxes['overview']
            corner = (box[0], box[1])
            resting = rendered_image(c, width, height)
            assert resting.getpixel(corner)[:3] == (255, 255, 255)
            x, y = box_center(box)
            ok(motion(c, x, y))
            hovered = rendered_image(c, width, height)
            assert hovered.getpixel(corner)[:3] == (22, 22, 22)
            colors = {rgba for _, rgba in hovered.crop(box).getcolors(box[2]*box[3])}
            assert (255,255,255,255) in colors and (22,22,22,255) in colors
            assert element_box(c,'overview',width,height)==box, 'hover changed action geometry'
            ok(button(c, x, y, 1, True)); ok(button(c, x, y, 1, False))
            ok(motion(c, 0, 0))
            focused = rendered_image(c, width, height)
            assert focused.getpixel(corner)[:3] == (22, 22, 22)
            assert delay(c) < 0
        ok(detach(c)); destroy(c)
print('PASS: text actions invert, remain disjoint and hit the correct target at 280/304/480/820 dp, including long labels and assistant controls.')
