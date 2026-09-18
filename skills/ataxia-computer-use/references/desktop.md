# Ataxia desktop operations

Use this reference for window placement, floating/tiling, groups, workspaces, shell navigation, and native window controls. CUA pointer/key actions control application content. The `cua.ataxia` desktop methods below operate through World APIs. Synthetic keys bypass World shortcut dispatch; desktop captures do not grant control of shell chrome. Changing `settle` changes observation timing only.

## Native JavaScript runtime

Use these methods through `cua_repl`. Desktop operations are subject to the active session, Pause, Disconnect, expiry, request sequencing, and human-drag checks. `getDesktop()` reports the whole current World, including hidden/minimized windows and each group's local workspaces. Native application `listWindows()` remains the list of eligible input/capture targets; use `getDesktop()` for arrangement.

```javascript
var desktop = await cua.ataxia.getDesktop();
// Select windowId and groupId from that observation for the user's task.
var moved = await cua.ataxia.moveWindow(windowId, { group: groupId, workspace: 2 });
await cua.ataxia.setFloating(windowId, true);
await cua.ataxia.getDesktop();
```

| Intent | `cua.ataxia` method |
| --- | --- |
| Inspect groups, windows, placement, output views and supported operations | `getDesktop({emit?: boolean})` |
| Move or resize a native window | `moveWindow(windowId, {group?, workspace?, floating?, x?, y?, width?, height?})` |
| Float/tile a group member | `setFloating(windowId, true)` / `setFloating(windowId, false)` |
| Close/minimize/restore/maximize/fullscreen | `windowAction(windowId, action)` |
| Show a particular group/workspace on the session's output | `switchWorkspace(groupId, workspaceNumber)` |
| Show the Metaworld overview on that output | `overview()` |
| Apply several group/window operations as one arrangement | `arrange(operations, {revision?})` |
| Validate now, apply later | `previewLayout(operations, {revision?})`, then `applyLayout(plan.plan)` |
| Undo the most recent arrangement | `undoLayout(result.undo)` |

The operations array for `arrange`/`previewLayout` follows the active World's `layout-schema`. Metaworld uses the operation table below. For example, create a group and place windows in it in one transaction:

```javascript
var result = await cua.ataxia.arrange([
  {op: 'create-group', ref: 'destination', name: 'Research', policy: 'niri'},
  {op: 'place-window', window: firstWindowId, group: 'destination', workspace: 1},
  {op: 'place-window', window: secondWindowId, group: 'destination', workspace: 2}
]);
await cua.ataxia.getDesktop();
// Later, only if the task calls for reverting and the desktop has not changed:
// await cua.ataxia.undoLayout(result.undo);
```

`getDesktop` emits by default. Changes return their resulting `desktop` and, for arrangements, `undo`; they do not emit automatically. Each successful change updates the runtime's observed revision, so sequential changes can use their preceding result. If no desktop has been observed in this session, a convenience operation first reads it. Once observed, the runtime rejects intervening layout changes with `desktop-changed`; it never automatically rebases an old plan. Explicit `revision` options use the revision from a relevant `getDesktop` result.

Plans and Undo belong to one native session, expire after 120 seconds, and cannot be replayed. At most eight unapplied plans are retained. Applying a layout validates the whole plan, captures the prior layout, and rolls back on failure. Undo refuses to overwrite later desktop changes. Explicit window controls clear earlier plans and Undo; closing an application cannot be undone. Grouped maximize/fullscreen follows Metaworld's group expansion policy.

`moveWindow(id, {workspace: 2})` preserves the observed group. `group: null` moves to the shared canvas, which has no numbered workspaces. `setFloating` requires group membership. Moving to a hidden workspace does not switch the user's view; call `switchWorkspace` only when the task requests navigation or input requires that workspace to be visible. Desktop operations do not require an application to bind a new input seat.

Use `await cua.ataxia.capabilities()` to check `native.desktop.layout` and
`native.desktop.navigation`. `moveWindow` and `setFloating` require an advertised
`place-window` schema. Workspace limits belong to the World. If a capability is
absent, report that limitation; do not patch the compositor or switch to private
Lisp APIs to perform the action.

## Desktop tools, when exposed

The built-in Ataxia assistant exposes the following tools. They are not methods on `cua.ataxia` and are not automatically available through the `cua_repl` MCP server. Use them only if they are present in the current tool list.

1. Call `ataxia_desktop_snapshot` for window IDs, group IDs, workspace membership, and the current layout revision. It includes minimized windows.
2. Pass that revision and an `operations` array to `ataxia_layout_preview`. For Metaworld, use the operations below. Other Worlds may advertise a different schema.
3. Pass the returned `plan` to `ataxia_layout_apply` once. The preview validates data without changing the desktop; it is not an extra user permission prompt. Apply rejects an intervening layout change and returns an Undo token.
4. Verify the returned snapshot. On a revision conflict, inspect again and replan. `ataxia_layout_undo` accepts the returned `undo` token while no later layout change would be overwritten.

| Intent | Metaworld operation |
| --- | --- |
| Send a window to a workspace | `{"op":"place-window","window":windowId,"group":groupId,"workspace":workspaceNumber}` |
| Float or tile a member | `{"op":"place-window","window":windowId,"group":groupId,"workspace":workspaceNumber,"floating":true}`; use `false` to tile |
| Set floating window geometry | Add `x`, `y`, `width`, `height` to `place-window` with `floating:true` |
| Move a window to the shared canvas | `place-window` with `group:null`; optional geometry applies there |
| Rename or change a group's layout | `{"op":"configure-group","group":groupId,"name":name,"policy":"niri"}`; policies also include `dwindle` and `master` |
| Create a group | `{"op":"create-group","ref":"destination","name":name,"policy":"niri"}`; later operations in that plan can use `"destination"` as `group` |
| Remove a group while keeping its applications | `{"op":"remove-group","group":groupId}`; members return to the shared canvas unless moved first |

These objects are templates: substitute IDs and values from the snapshot. A workspace number is **local to its group**, from 1 through 9. Moving a window and switching the user's visible workspace are separate operations. Free geometry applies to canvas/floating windows; tiled placement follows the group's policy.

For native window controls, call `ataxia_window` with `window` and `action`: `close`, `minimize`, `restore`, `maximize`, or `fullscreen`. Restore exits expanded presentation and unminimizes. Close sends the application's normal close request and may produce a save dialog; inspect the result. Browser `tab.close()` closes a tab, not a native application window.
