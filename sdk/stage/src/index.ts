export { Background, Camera, GestureBinding, Group, Image, PointerBinding, Rect, Reserve, Screen,
  Shell, Shortcut, Text, WheelBinding, Window } from "./components.js";
export { changeBrightness, changeVolume, mediaCommand, setBrightness, setPowerProfile, setVolume,
  toggleMute, useBattery, useBrightness, useMedia, usePowerProfile, useTime,
  useVolume } from "./system.js";
export type { BatteryInfo, BrightnessInfo, MediaInfo, PowerProfileInfo, VolumeInfo } from "./system.js";
export { useApplications, useCamera, useClipboard, useFocusedWindow, useOutputs, usePersistentState,
  useWindow, useWindows } from "./hooks.js";
export { instant, spring, tween } from "./motion.js";
export { columns, dwindle, grid, inset, masterStack } from "./layouts.js";
export type { Area, ColumnOptions, GapOptions, MasterOptions, Placement } from "./layouts.js";
export { Web } from "./web.js";
export type { WebProps } from "./web.js";
export type { CubicBezier, Easing, Motion, SpringOptions, TweenOptions } from "./motion.js";
export type { Color } from "./color.js";
export type { AnimatedValues, BackgroundProps, BindingAction, Border, CameraProps, DragProps,
  GestureBindingProps, Grid, GroupProps, ImageProps, ModifierName, Paint, PaintValues,
  PointerBindingProps, RectProps, ReserveProps, ScreenProps, Shadow, ShellProps, ShortcutProps,
  TextContent,
  TextProps,
  Transition, WheelBindingProps, WindowProps } from "./props.js";
export type { Modifier, StageDragEvent, StageErrorEvent, StageEvent, StageGestureEvent,
  StageLoadEvent, StageMeasureEvent, StageNavigateEvent, StagePointerEvent, StageRequestEvent,
  StageResizeEvent,
  StageWheelEvent } from "./events.js";
export type { ApplicationInfo, Box, CameraInfo, OutputInfo, WindowInfo } from "./store.js";
export type { CameraMove } from "./session.js";
import type { Motion } from "./motion.js";
import { currentSession, type CameraMove } from "./session.js";

/** Give keyboard focus to WINDOW on the first seat, or clear it with null. */
export function focus(window: number | null): void {
  currentSession().focus(window);
}

/** Ask WINDOW's client to close. */
export function close(window: number): void {
  currentSession().close(window);
}

/** Launch an installed application by its useApplications() id. */
export function launchApplication(id: string): void {
  currentSession().launchApplication(id);
}

/** Start a Wayland client of this compositor; a string runs through /bin/sh. */
export function launch(command: string | readonly string[]): void {
  currentSession().launch(command);
}

/** Move a camera (every output's, unless OUTPUT is given), always, even to where it already was. */
export function moveCamera(move: CameraMove, options?: { output?: string; transition?: Motion }): void {
  currentSession().moveCamera(move, options);
}
