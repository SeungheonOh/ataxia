"""Private-session MPRIS fixture; never connects to the user's media players."""
import sys
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
status = 'Paused'
track = 'First track'
can_next = True
xml = '''<node>
<interface name="org.mpris.MediaPlayer2"><property name="Identity" type="s" access="read"/></interface>
<interface name="org.mpris.MediaPlayer2.Player">
<method name="PlayPause"/><method name="Next"/><method name="Previous"/><method name="Stop"/>
<property name="PlaybackStatus" type="s" access="read"/>
<property name="Metadata" type="a{sv}" access="read"/>
<property name="CanControl" type="b" access="read"/><property name="CanPlay" type="b" access="read"/>
<property name="CanPause" type="b" access="read"/><property name="CanGoNext" type="b" access="read"/>
<property name="CanGoPrevious" type="b" access="read"/>
</interface>
<interface name="org.ataxia.Test"><method name="Update"/><method name="Quit"/></interface>
</node>'''
def value(name):
    if name == 'Identity': return GLib.Variant('s', 'Fixture player')
    if name == 'PlaybackStatus': return GLib.Variant('s', status)
    if name == 'Metadata': return GLib.Variant('a{sv}', {
        'xesam:title': GLib.Variant('s', track),
        'xesam:artist': GLib.Variant('as', ['Test artist · λ']),
        'mpris:trackid': GLib.Variant('o', '/track/one'),
        'mpris:length': GLib.Variant('x', 120000000)})
    return GLib.Variant('b', can_next if name == 'CanGoNext' else True)
def changed(*names):
    bus.emit_signal(None, '/org/mpris/MediaPlayer2', 'org.freedesktop.DBus.Properties',
                    'PropertiesChanged', GLib.Variant('(sa{sv}as)',
                    ('org.mpris.MediaPlayer2.Player', {n: value(n) for n in names}, [])))
def method(connection, sender, path, interface, name, parameters, invocation):
    global status, track, can_next
    if name == 'PlayPause':
        status = 'Paused' if status == 'Playing' else 'Playing'
        changed('PlaybackStatus')
    elif name == 'Next':
        track = 'Next track'; changed('Metadata')
    elif name == 'Previous':
        invocation.return_dbus_error('org.mpris.MediaPlayer2.Error.Failed', 'Fixture transport failure')
        return
    elif name == 'Stop':
        status = 'Stopped'; changed('PlaybackStatus')
    elif name == 'Update':
        track = 'Externally changed'; can_next = False
        changed('Metadata', 'CanGoNext')
    invocation.return_value(GLib.Variant('()', ()))
    if name == 'Quit': GLib.idle_add(loop.quit)
info = Gio.DBusNodeInfo.new_for_xml(xml)
for interface in info.interfaces:
    bus.register_object('/org/mpris/MediaPlayer2', interface, method,
                        lambda connection, sender, path, interface, prop: value(prop), None)
bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
              'RequestName', GLib.Variant('(su)', ('org.mpris.MediaPlayer2.ataxia_fixture', 0)),
              GLib.VariantType.new('(u)'), Gio.DBusCallFlags.NONE, -1, None)
print('READY', flush=True)
loop.run()
