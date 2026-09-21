"""Pixel-based layout probes for the native GLES fixture (exec after rmlui-gles).

A temporary class paints one element without changing its geometry. Removing
that class restores every original state, including focus and selection. This
lets input tests use the rendered hit area without a production debug API.
"""
from PIL import ImageChops


def measured_source(source, ids):
    selectors = ','.join(f'body.shell #{name}.layout-probe' for name in ids)
    rule = f'<style>{selectors} {{ background-color:#11cb4d; }}</style>'.encode()
    return source.replace(b'</head>', rule + b'</head>')


def rendered_image(c, width, height):
    for _ in range(3): ok(render(c))
    pixels = (C.c_ubyte * (width * height * 4))()
    bind_fbo(0x8d40, fbo)
    read(0, 0, width, height, 0x1908, 0x1401, pixels)
    return Image.frombytes('RGBA', (width, height), bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM)


def element_box(c, name, width, height):
    name = name.encode() if isinstance(name, str) else name
    ok(set_class(c, name, b'layout-probe', True))
    im = rendered_image(c, width, height).convert('RGB')
    difference = ImageChops.difference(im, Image.new('RGB', im.size, (17, 203, 77)))
    r, g, b = difference.split()
    mask = ImageChops.lighter(ImageChops.lighter(r, g), b).point(lambda v: 255 if v == 0 else 0)
    box = mask.getbbox()
    ok(set_class(c, name, b'layout-probe', False))
    ok(render(c))
    assert box, (name, 'control has no visible area')
    return box


def box_center(box):
    x0, y0, x1, y1 = box
    return ((x0 + x1) / 2, (y0 + y1) / 2)
