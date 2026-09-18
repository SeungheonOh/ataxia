#!/usr/bin/env python3
"""Persistent AT-SPI adapter. Every operation is bound to a live Ataxia target.

No arbitrary object path, PID, or executable supplied by a page is accepted: the
PID and window identity come from the authorized compositor session each time.
"""
import json
import os
import shutil
import socket
import sys
import time
import warnings
warnings.filterwarnings('ignore', category=DeprecationWarning)
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib, Gio

Atspi.set_timeout(1500, 2500)
TARGETS = {}
MAX_NODES = 2000
MAX_TEXT = 4096

class Rejected(Exception):
    def __init__(self, code, message): self.code, self.message = code, message

def reject(code, message): raise Rejected(code, message)

def guard(request):
    # Query the server directly, including immediately before a semantic action.
    wire = {'op': 'target', 'token': request['token'], 'window': request['window']}
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect(request['socket'])
        s.sendall((json.dumps(wire) + '\n').encode())
        data = bytearray()
        while b'\n' not in data:
            part = s.recv(16384)
            if not part: reject('disconnected', 'The compositor disconnected before authorization.')
            data.extend(part)
            if len(data) > 1024 * 1024: reject('invalid-response', 'Target metadata is too large.')
    reply = json.loads(data)
    if not reply.get('ok'): reject(reply.get('error', 'not-active'), reply.get('message', 'Session is not active.'))
    window = reply.get('window')
    if not window or not isinstance(window.get('pid'), int) or window['pid'] <= 0:
        reject('accessibility-unavailable', 'This application has no supported process identity')
    return window

def pump():
    context = GLib.MainContext.default()
    for _ in range(100):
        if not context.pending(): break
        context.iteration(False)

def root_for(window):
    pump()
    desktop = Atspi.get_desktop(0)
    if not desktop: reject('accessibility-unavailable', 'AT-SPI is not running')
    candidates = []
    for index in range(min(desktop.get_child_count(), 1024)):
        app = desktop.get_child_at_index(index)
        try:
            if app.get_process_id() != window['pid']: continue
            for i in range(min(app.get_child_count(), 256)):
                child = app.get_child_at_index(i)
                if child and not child.get_state_set().contains(Atspi.StateType.DEFUNCT): candidates.append(child)
        except GLib.Error: continue
    matches = [c for c in candidates if c.get_name() == window.get('title', '')]
    if len(matches) == 1: return matches[0]
    if len(matches) > 1: reject('ambiguous-window', 'Multiple accessibility windows have this title; select a distinct window.')
    # An application can omit the AX window title. A single top-level object is
    # unambiguous, but never silently choose among multiple application windows.
    if len(candidates) == 1: return candidates[0]
    if candidates: reject('ambiguous-window', 'No unique accessibility window matches this compositor window.')
    reject('accessibility-unavailable', 'The application does not expose an AT-SPI tree')

def safe(fn, default=None):
    try: return fn()
    except (GLib.Error, AttributeError, TypeError): return default

def identifier(obj, pid): return f'{pid}:{hash(obj):x}'

def describe(obj, pid, depth):
    states = obj.get_state_set()
    if states.contains(Atspi.StateType.DEFUNCT): return None
    role = obj.get_role_name()
    interfaces = obj.get_interfaces()
    name = obj.get_name() or ''
    result = {'key': identifier(obj, pid), 'role': role, 'name': name[:MAX_TEXT], 'depth': depth, 'states': [], 'actions': []}
    for enum, label in [(Atspi.StateType.FOCUSED, 'focused'), (Atspi.StateType.SELECTED, 'selected'),
                        (Atspi.StateType.CHECKED, 'checked'), (Atspi.StateType.EXPANDED, 'expanded'),
                        (Atspi.StateType.EDITABLE, 'editable'), (Atspi.StateType.MULTI_LINE, 'multiline')]:
        if states.contains(enum): result['states'].append(label)
    if not states.contains(Atspi.StateType.ENABLED): result['states'].append('disabled')
    if 'Action' in interfaces:
        result['actions'] = [obj.get_action_name(i) for i in range(min(obj.get_n_actions(), 20))]
    if 'Text' in interfaces:
        if obj.get_role() == Atspi.Role.PASSWORD_TEXT:
            result['value'] = '<protected>'
        elif 'EditableText' in interfaces or not name:
            result['value'] = safe(lambda: Atspi.Text.get_text(obj, 0, min(obj.get_character_count(), MAX_TEXT)), '')
        if 'EditableText' in interfaces:
            caret = safe(obj.get_caret_offset)
            if caret is not None: result['states'].append(f'caret={caret}')
            if safe(lambda: Atspi.Text.get_n_selections(obj), 0):
                selection = safe(lambda: Atspi.Text.get_selection(obj, 0))
                if selection: result['states'].append(f'selection={selection.start_offset}:{selection.end_offset}')
    elif 'Value' in interfaces:
        result['value'] = str(safe(obj.get_current_value, ''))
    return result

def snapshot(request, window):
    root = root_for(window)
    nodes, objects, stack = [], {}, [(root, 0)]
    started = time.monotonic()
    while stack and len(nodes) < MAX_NODES and time.monotonic() - started < 4:
        obj, depth = stack.pop()
        if depth > 40: continue
        node = safe(lambda: describe(obj, window['pid'], depth))
        if not node: continue
        nodes.append(node); objects[node['key']] = (obj, node)
        count = min(safe(obj.get_child_count, 0), MAX_NODES - len(nodes))
        for i in range(count - 1, -1, -1):
            child = safe(lambda: obj.get_child_at_index(i))
            if child: stack.append((child, depth + 1))
    TARGETS[(request['token'], request['window'])] = {'root': root, 'pid': window['pid'], 'objects': objects}
    guard(request)  # Do not return a tree if the user paused during traversal.
    return {'nodes': nodes, 'truncated': bool(stack)}

def selected(request, window):
    saved = TARGETS.get((request['token'], request['window']))
    if not saved or saved['pid'] != window['pid']: reject('stale-element', 'Get a fresh accessibility tree for this window.')
    pair = saved['objects'].get(request.get('element'))
    if not pair: reject('stale-element', 'The element is not in the latest accessibility tree.')
    obj, node = pair
    if obj.get_state_set().contains(Atspi.StateType.DEFUNCT) or obj.get_role_name() != node['role'] or (obj.get_name() or '')[:MAX_TEXT] != node['name']:
        reject('stale-element', 'The element changed. Get fresh accessibility state before acting.')
    # Validate its ancestry: detached/reparented objects cannot act in another window.
    current = obj
    for _ in range(50):
        if current == saved['root']: return obj, node
        current = safe(current.get_parent)
        if not current: break
    reject('stale-element', 'The element no longer belongs to this window.')

def range_for(content, text, options):
    if not text: reject('invalid-selection', 'Select nonempty text.')
    matches, at = [], content.find(text)
    while at >= 0:
        if (options.get('prefix') is None or content[:at].endswith(options['prefix'])) and (options.get('suffix') is None or content[at + len(text):].startswith(options['suffix'])): matches.append(at)
        at = content.find(text, at + 1)
    if len(matches) != 1: reject('ambiguous-text' if matches else 'text-not-found', 'Text must match exactly once; use prefix and suffix.')
    start, end = matches[0], matches[0] + len(text)
    kind = options.get('selectionType', 'text')
    if kind == 'cursor_before': end = start
    elif kind == 'cursor_after': start = end
    elif kind != 'text': reject('invalid-selection', 'Unknown selection type.')
    return start, end

def dispatch(request):
    if request['op'] == 'desktop-info':
        # Read installed application metadata only. Never execute a supplied path.
        result = []
        for app_id in request.get('ids', [])[:2048]:
            entry = Gio.DesktopAppInfo.new(app_id if app_id.endswith('.desktop') else app_id + '.desktop')
            if entry:
                executable = shutil.which(entry.get_executable() or '')
                result.append({'id': app_id, 'filename': entry.get_filename(), 'executable': os.path.realpath(executable) if executable else None,
                               'runtimeIds': [v for v in [app_id.removesuffix('.desktop'), entry.get_startup_wm_class(), os.path.basename(executable) if executable else None] if v]})
        return result
    window = guard(request)
    op = request['op']
    if op == 'snapshot': return snapshot(request, window)
    obj, node = selected(request, window)
    if op == 'point':
        if 'Component' not in obj.get_interfaces(): reject('unsupported-action', 'This element has no coordinate bounds.')
        rect = obj.get_extents(Atspi.CoordType.WINDOW)
        if rect.width <= 0 or rect.height <= 0 or abs(rect.x) > 100000 or abs(rect.y) > 100000: reject('element-not-visible', 'The element has no usable bounds; scroll it into view.')
        return {'x': rect.x + rect.width / 2 - window.get('origin-x', 0), 'y': rect.y + rect.height / 2 - window.get('origin-y', 0)}
    guard(request)
    if op in ('click', 'secondary'):
        actions = node['actions']
        if op == 'secondary':
            action = request['action']
            if action not in actions: reject('unsupported-action', 'This action was not exposed in the accessibility tree.')
        else:
            action = None if 'editable' in node['states'] else next((a for a in actions if a.lower() in ('click', 'press', 'activate', 'jump', 'open', 'toggle')), None)
            if action is None: reject('coordinate-required', 'This element has no primary accessibility action.')
        current = [obj.get_action_name(i) for i in range(obj.get_n_actions())]
        if action not in current: reject('stale-element', 'The accessible action changed.')
        if not obj.do_action(current.index(action)): reject('action-failed', 'The application rejected the accessibility action.')
    elif op == 'set-value':
        interfaces = obj.get_interfaces()
        if 'Value' in interfaces:
            try: value = float(request['value'])
            except ValueError: reject('invalid-value', 'This control needs a numeric value.')
            if not obj.get_minimum_value() <= value <= obj.get_maximum_value(): reject('invalid-value', 'Value is outside the control’s range.')
            if not obj.set_current_value(value): reject('action-failed', 'The application rejected the value.')
        elif 'EditableText' in interfaces:
            if not obj.set_text_contents(request['value']): reject('action-failed', 'The application rejected the new text.')
        else: reject('unsupported-action', 'This element exposes neither EditableText nor Value.')
    elif op == 'select-text':
        if 'Text' not in obj.get_interfaces() or not obj.get_state_set().contains(Atspi.StateType.EDITABLE): reject('unsupported-action', 'Select text in an editable element.')
        if obj.get_role() == Atspi.Role.PASSWORD_TEXT: reject('unsupported-action', 'Protected text cannot be searched through accessibility.')
        length = obj.get_character_count()
        if length > 1_000_000: reject('text-too-large', 'The editable text exceeds the selection limit.')
        obj.grab_focus()
        start, end = range_for(Atspi.Text.get_text(obj, 0, length), request['text'], request.get('options', {}))
        while Atspi.Text.get_n_selections(obj):
            if not Atspi.Text.remove_selection(obj, 0): reject('action-failed', 'Could not clear the previous selection.')
        if start == end:
            if not obj.set_caret_offset(start): reject('action-failed', 'Could not position the caret.')
        elif not Atspi.Text.add_selection(obj, start, end): reject('action-failed', 'Could not select the text.')
    else: reject('unsupported-action', 'Unknown accessibility operation.')
    pump()
    guard(request)
    return {}

for line in sys.stdin:
    request = {}
    try:
        if len(line) > 4 * 1024 * 1024: reject('request-too-large', 'Accessibility request exceeded its size limit.')
        request = json.loads(line)
        result = dispatch(request)
        reply = {'id': request.get('id'), 'ok': True, 'result': result}
    except Rejected as error:
        reply = {'id': request.get('id'), 'ok': False, 'error': error.code, 'message': error.message}
    except Exception as error:
        reply = {'id': request.get('id'), 'ok': False, 'error': 'accessibility-error', 'message': str(error)}
    print(json.dumps(reply, ensure_ascii=False), flush=True)
