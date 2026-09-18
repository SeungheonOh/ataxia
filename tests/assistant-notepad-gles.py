"""Check the shipped notepad's native editing, layout and idle rendering."""
from pathlib import Path
exec(compile((Path(__file__).parent / 'rmlui-gles.py').read_text(), __file__, 'exec'))

callback_count = api('component_callback_count', C.c_size_t, P)
callback_value = api('component_callback_value', C.c_char_p, P, C.c_size_t)
clear_callbacks = api('component_clear_callbacks', None, P)

for width, height in [(640, 480), (320, 360)]:
    bind_texture(0x0de1, tex)
    tex_image(0x0de1, 0, 0x1908, width, height, 0, 0x1908, 0x1401, None)
    path = root / 'examples/assistant/notepad.rml'
    c = create(path.read_bytes(), str(path).encode(), b'', width, height, 1)
    ok(c)
    ok(api('component_register_callback', C.c_bool, P, C.c_char_p)(c, b'editor:change'))
    ok(attach(c, fbo))
    ok(render(c))
    ok(button(c, 60, 125, 1, True))
    ok(button(c, 60, 125, 1, False))

    def press(symbol, modifiers=0):
        ok(key(c, symbol, True, modifiers))
        ok(key(c, symbol, False, modifiers))
        ok(render(c))

    def value():
        count = callback_count(c)
        assert count, 'The textarea did not emit a native change event'
        return callback_value(c, count - 1).decode()

    for character in 'First line': press(ord(character))
    press(0xff0d)  # Return inserts a newline in the native textarea.
    for character in 'Second line': press(ord(character))
    assert value() == 'First line\nSecond line', repr(value())
    press(0xff51)  # Left then Backspace edits inside the second line.
    press(0xff08)
    assert value() == 'First line\nSecond lie', repr(value())

    pixels = (C.c_ubyte * (width * height * 4))()
    bind_fbo(0x8d40, fbo)
    read(0, 0, width, height, 0x1908, 0x1401, pixels)
    im = Image.frombytes('RGBA', (width, height), bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    im.save(root / f'build/assistant-notepad-{width}.png')
    assert im.getpixel((width // 2, 2))[:3] == (255, 255, 255)

    press(ord('a'), 1)  # Control+A uses RmlUi's KM_CTRL modifier.
    press(0xff08)
    assert value() == '', repr(value())
    press(0xff8d)  # Keypad Enter also inserts exactly one newline.
    assert value() == '\n', repr(value())
    press(0xff08)
    for _ in range(24):
        press(ord('x'))
        press(0xff0d)
    assert value() == 'x\n' * 24
    ok(api('component_pointer_motion', C.c_bool, P, F, F)(c, 60, 150))
    ok(api('component_pointer_scroll', C.c_bool, P, F, F, F, F)(c, 60, 150, 0, -120))
    ok(render(c))
    assert value() == 'x\n' * 24
    ok(api('component_focus', C.c_bool, P, C.c_bool)(c, False))
    ok(render(c))
    assert delay(c) < 0, delay(c)
    ok(detach(c))
    destroy(c)

print('PASS: notepad multiline editing, caret movement, selection/deletion, scrolling, light layout at two sizes and idle rendering.')
