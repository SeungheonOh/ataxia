#!/usr/bin/env python3
"""Disposable real GTK/Wayland app; never connects to the user's Wayland socket."""
import gi
import json
import os
import sys
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib
GLib.set_prgname('ataxia.cua-test')
window = Gtk.Window(title='Ataxia CUA fixture')
window.set_default_size(680, 560)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=18)
window.add(box)
entry = Gtk.Entry(); entry.get_accessible().set_name('Name'); entry.set_text('Initial')
box.pack_start(entry, False, False, 0)
notes = Gtk.TextView(); notes.get_accessible().set_name('Notes'); notes.set_size_request(600, 100)
notes.get_buffer().set_text('first hello · λ🙂\nsecond hello end')
box.pack_start(notes, False, False, 0)
status = Gtk.Label(label='Waiting')
button = Gtk.Button(label='Apply')
button.connect('clicked', lambda widget: status.set_text('Applied: ' + entry.get_text()))
box.pack_start(button, False, False, 0)
spin = Gtk.SpinButton.new_with_range(0, 100, 1); spin.get_accessible().set_name('Amount')
box.pack_start(spin, False, False, 0)
expander = Gtk.Expander(label='Details'); expander.add(Gtk.Label(label='Details are visible'))
box.pack_start(expander, False, False, 0)
box.pack_start(status, False, False, 0)
window.connect('destroy', Gtk.main_quit)
window.show_all()
entry.grab_focus()
key_events = 0
ticks = 0
def key_press(widget, event):
    global key_events
    key_events += 1
    return False
window.connect('key-press-event', key_press)
def save():
    global ticks
    ticks += 1
    window.set_title('Ataxia CUA fixture tick ' + str(ticks) if os.path.exists(os.path.join(os.path.dirname(sys.argv[1]), 'animate')) else 'Ataxia CUA fixture')
    buffer = notes.get_buffer()
    state = {'name': entry.get_text(), 'notes': buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True),
             'status': status.get_text(), 'amount': spin.get_value(), 'expanded': expander.get_expanded(), 'keyEvents': key_events}
    with open(sys.argv[1], 'w') as out: json.dump(state, out, ensure_ascii=False)
    return True
GLib.timeout_add(50, save)
Gtk.main()
