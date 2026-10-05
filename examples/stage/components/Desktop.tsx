import type { ComponentType } from "react";
import type { OutputInfo } from "@ataxia/stage";
import { Bar } from "./bar/Bar.js";
import { MediaKeys } from "./MediaKeys.js";
import { Screenshots } from "./Screenshots.js";
import { ShareChooser } from "./ShareChooser.js";

interface DesktopProps {
  /** The world's own controls, drawn at the left of the bar. */
  barStart?: ComponentType<{ output: OutputInfo }>;
}

/** What both example worlds share: the bar, media keys, screen sharing and screenshots. */
export function Desktop({ barStart }: DesktopProps) {
  return (
    <>
      <Bar start={barStart} />
      <MediaKeys />
      <ShareChooser />
      <Screenshots />
    </>
  );
}
