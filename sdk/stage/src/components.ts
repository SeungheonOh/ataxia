// Host components. Each renders one scene node of the same name.

import type { FC } from "react";
import type { BackgroundProps, CameraProps, GestureBindingProps, GroupProps, HostType,
  ImageProps, PointerBindingProps, RectProps, ReserveProps, ScreenProps, ShellProps, ShortcutProps,
  TextProps,
  WheelBindingProps, WindowProps } from "./props.js";

function host<P>(type: HostType): FC<P> {
  return type as unknown as FC<P>;
}

/** Transform container; children are positioned in its local space. */
export const Group = host<GroupProps>("group");
/** Rounded rectangle with optional border and soft shadow. */
export const Rect = host<RectProps>("rect");
/** Text laid out by Pango; `<Text size={14}>Hello {name}</Text>`. */
export const Text = host<TextProps>("text");
/** Decoded image file, optionally rounded, bordered and shadowed like a Rect. */
export const Image = host<ImageProps>("image");
/** A client window, configured to `width` x `height` when both are given. */
export const Window = host<WindowProps>("window");
/** Infinite plane with an optional dot or line grid; the natural target for canvas gestures. */
export const Background = host<BackgroundProps>("background");
/** Camera of one output, or of every output without its own. */
export const Camera = host<CameraProps>("camera");
/** Children in an output's logical pixels, unaffected by the camera. */
export const Screen = host<ScreenProps>("screen");
/** Screen space kept for this world's own UI; windows' work areas leave it free. */
export const Reserve = host<ReserveProps>("reserve");
/** Workspaces for the shell's status bar; the first one in the tree counts. */
export const Shell = host<ShellProps>("shell");
/** Keyboard shortcut, consumed before the focused window sees it. */
export const Shortcut = host<ShortcutProps>("shortcut");
/** Modifier+button drag anywhere, e.g. Super+drag to move windows. */
export const PointerBinding = host<PointerBindingProps>("pointer-binding");
/** Modifier+wheel anywhere, e.g. Super+wheel to zoom. */
export const WheelBinding = host<WheelBindingProps>("wheel-binding");
/** Touchpad swipe, pinch or hold gesture. */
export const GestureBinding = host<GestureBindingProps>("gesture-binding");
