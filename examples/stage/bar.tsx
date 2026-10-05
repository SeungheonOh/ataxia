// The top bar, drawn by the world itself: a frosted card with the world's own
// controls on the left, the focused window's title in the middle, and what is
// playing, sound, clipboard, battery and the clock on the right. These open
// menus (bar-menu.tsx, one React DOM page kept loaded and hidden while closed).
// The bar also owns the media, volume and brightness keys, showing each change
// briefly. It reserves its strip of every output, so window layouts and
// `workArea` leave it free.
//
// Motion is all one-shot springs: the bar slides in once, one highlight glides
// between the items under the pointer, changing text rolls in, menus spring
// from their item. Nothing loops, text is rasterized only when it changes, and
// every system source is event-driven, so an idle bar wakes the director once a
// minute and the compositor not at all.

import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  changeBrightness, changeVolume, Group, Image, instant, mediaCommand, Rect, Reserve, Screen,
  setBrightness, setPowerProfile, setVolume, Shortcut, spring, Text, toggleMute, useBattery,
  useBrightness, useClipboard, useFocusedWindow, useMedia, useOutputs, usePowerProfile, useTime,
  useVolume, useWindow, Web, type OutputInfo, type Transition,
} from "@ataxia/stage";
import brightnessIcon from "./icons/brightness.svg";
import clipboardIcon from "./icons/clipboard.svg";
import musicIcon from "./icons/music.svg";
import mutedIcon from "./icons/volume-muted.svg";
import volumeIcon from "./icons/volume.svg";

export const ink = "#17171a";
export const paper = "#ecebe6";
export const accent = "#2f6fed";
export const font = "Noto Sans, sans-serif";

export const barHeight = 34;
const margin = 8;
const inset = 8;
/** Height of the strip the bar keeps at the top of each output. */
export const barReserve = margin + barHeight + 6;
/** Text top that centers 13 px text in the bar. */
const baseline = 8;
/** Date and time, right-aligned: "Mon, Oct 5" and "12:47 PM" fit. */
const clockWidth = 96 + 6 + 70;

type Menu = "sound" | "battery" | "clipboard";
const menuSizes: Record<Menu, { width: number; height: number }> = {
  sound: { width: 320, height: 134 }, battery: { width: 320, height: 196 },
  clipboard: { width: 360, height: 280 },
};
/** Extra height of the sound menu while something plays. */
const mediaHeight = 72;

const glide = spring({ duration: 0.34, bounce: 0.14 });
const pop = spring({ duration: 0.26, bounce: 0.08 });
const roll = spring({ duration: 0.42, bounce: 0.06 });
const arrive = spring({ duration: 0.7, bounce: 0.16 });

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });
const dateFormat = new Intl.DateTimeFormat(undefined, { weekday: "short", day: "numeric", month: "short" });

/**
 * Bar text that rolls when IDENTITY changes: the old text slides up and fades
 * while the new one rises in. A change of text under the same identity is in place.
 */
function Rolling({ identity, x, width, align = "start", color = ink, weight = 500, children }: {
  identity: string | number; x: number; width?: number; align?: "start" | "center" | "end";
  color?: string; weight?: number; children: string;
}) {
  return (
    <Text key={identity} x={x} y={baseline} width={width} align={align} maxLines={1} font={font}
          size={13} weight={weight} color={color} originX={0} originY={0} transition={roll}
          initial={{ opacity: 0, y: baseline + 10 }} exit={{ opacity: 0, y: baseline - 10 }}>
      {children}
    </Text>
  );
}

/** A small battery gauge drawn with rectangles; its fill springs to the charge. */
function Gauge({ percent, charging }: { percent: number; charging: boolean }) {
  const color = charging ? accent : percent <= 15 ? "#e0443e" : ink;
  return (
    <Group y={11}>
      <Rect width={21} height={12} radius={3.5} originX={0} originY={0}
            border={{ width: 1.2, color: "#17171aa6" }} />
      <Rect x={21.6} y={4} width={1.8} height={4} radius={0.9} originX={0} originY={0} fill="#17171aa6" />
      <Rect x={2.3} y={2.3} width={Math.max(1.5, 16.4 * percent / 100)} height={7.4} radius={2}
            originX={0} originY={0} fill={color} transition={glide} />
    </Group>
  );
}

interface OpenMenu {
  kind: Menu;
  /** The item that opened it, which it hangs under. */
  slot: string;
  output: string;
  right: number;
  /** Counts openings, so the page replays its entrance each time. */
  opened: number;
}

interface Slot {
  key: string;
  x: number;
  width: number;
  menu: Menu;
  content: ReactNode;
}

/** One highlight for all of an output's items: it glides to the item hovered or open. */
function Highlight({ slot, active }: { slot: Slot | null; active: boolean }) {
  // Appearing from nothing it jumps to its item; between items it glides.
  const last = useRef<Slot | null>(null);
  const shownBefore = useRef(false);
  const target = slot ?? last.current;
  const transition: Transition = shownBefore.current
    ? glide : { default: glide, x: instant, width: instant };
  useEffect(() => {
    shownBefore.current = slot !== null;
    if (slot) last.current = slot;
  });
  if (!target) return null;
  return (
    <Rect x={target.x} y={4} width={target.width} height={barHeight - 8} radius={9}
          originX={0} originY={0} opacity={slot ? 1 : 0} transition={transition}
          fill={active ? "#2f6fed1f" : "#17171a0f"} />
  );
}

export function Bar({ left }: {
  /** The world's controls for OUTPUT, laid out from the bar's left edge, 34 px tall. */
  left?: (output: OutputInfo) => ReactNode;
}) {
  const outputs = useOutputs();
  const focused = useFocusedWindow();
  const window = useWindow(focused ?? -1);
  const time = useTime();
  const battery = useBattery();
  const volume = useVolume();
  const profile = usePowerProfile();
  const clipboard = useClipboard();
  const media = useMedia();
  const brightness = useBrightness();
  const [menu, setMenu] = useState<OpenMenu | null>(null);
  const [hovered, setHovered] = useState<{ output: string; key: string } | null>(null);
  const opened = useRef(0);
  const [osd, flash] = useOsd();
  const toggle = (slot: Slot, output: string) =>
    setMenu((open) => open?.slot === slot.key && open.output === output ? null : {
      kind: slot.menu, slot: slot.key, output, right: margin + slot.x + slot.width,
      opened: ++opened.current,
    });

  return (
    <>
      <Reserve top={barReserve} />
      {outputs.map((output) => {
        const width = output.width - 2 * margin;
        // Right-hand items, laid out leftwards from the clock.
        const clockRight = width - inset - 6;
        const clockLeft = clockRight - clockWidth;
        const batteryX = clockLeft - 16 - 72;
        const clipboardX = batteryX - 36;
        const soundX = clipboardX - 72;
        const mediaX = soundX - 240;
        const slots: Slot[] = [
          ...(media?.title ? [{
            key: "media", x: mediaX, width: 236, menu: "sound" as const,
            content: (
              <>
                <Image src={musicIcon} x={10} y={9} width={16} height={16} originX={0} originY={0}
                       opacity={media.playing ? 0.85 : 0.4} transition={pop} />
                <Rolling identity={media.title} x={32} width={196}
                         color={media.playing ? "#17171acc" : "#17171a80"}>
                  {media.artist ? `${media.title} · ${media.artist}` : media.title}
                </Rolling>
              </>
            ),
          }] : []),
          ...(volume ? [{
            key: "sound", x: soundX, width: 68, menu: "sound" as const,
            content: (
              <>
                <Image src={volume.muted ? mutedIcon : volumeIcon} x={10} y={9} width={16} height={16}
                       originX={0} originY={0} opacity={0.85} />
                <Text x={31} y={baseline} font={font} size={13} weight={500} color="#17171acc"
                      originX={0} originY={0}>
                  {volume.muted ? "Off" : `${Math.round(volume.volume * 100)}%`}
                </Text>
              </>
            ),
          }] : []),
          {
            key: "clipboard", x: clipboardX, width: 34, menu: "clipboard",
            content: <Image src={clipboardIcon} x={9} y={9} width={16} height={16} originX={0} originY={0}
                            opacity={0.85} />,
          },
          ...(battery ? [{
            key: "battery", x: batteryX, width: 72, menu: "battery" as const,
            content: (
              <>
                <Group x={10}><Gauge percent={battery.percent} charging={battery.charging} /></Group>
                <Text x={39} y={baseline} font={font} size={13} weight={500} color="#17171acc"
                      originX={0} originY={0}>{`${battery.percent}%`}</Text>
              </>
            ),
          }] : []),
        ];
        // The title stays centered on the bar while that leaves the right-hand
        // items clear, and otherwise centers in the space left of them.
        const regionLeft = 180;
        const regionRight = (slots[0]?.x ?? clockLeft - 16) - 12;
        const half = Math.min(260, width / 2 - regionLeft, regionRight - width / 2);
        const [titleX, titleWidth] = half >= 120
          ? [width / 2 - half, 2 * half] : [regionLeft, Math.max(0, regionRight - regionLeft)];
        const open = menu?.output === output.name
          ? slots.find((slot) => slot.key === menu.slot) ?? null : null;
        const pointed = hovered?.output === output.name
          ? slots.find((slot) => slot.key === hovered.key) ?? null : null;

        return (
          <Screen key={output.name} output={output.name}>
            {/* The shadow sits under the bar, outside its clip. */}
            <Rect layoutId={`bar-shadow:${output.name}`} x={margin} y={margin} width={width} height={barHeight}
                  radius={12} originX={0} originY={0} shadow={{ color: "#00000024", blur: 26, y: 6 }}
                  initial={{ opacity: 0, y: margin - 18 }} transition={arrive} />
            <Group layoutId={`bar:${output.name}`} x={margin} y={margin} width={width} height={barHeight}
                   clip initial={{ opacity: 0, y: margin - 18 }} transition={arrive}>
              <Rect width={width} height={barHeight} radius={12} originX={0} originY={0}
                    fill="#ffffffc7" blur={22}
                    border={{ width: 1, color: { from: "#ffffffee", to: "#00000017", angle: 90 } }} />
              <Group x={inset + 6}>{left?.(output)}</Group>
              <Rolling identity={focused ?? "desktop"} x={titleX} width={titleWidth} align="center"
                       weight={600} color={window ? ink : "#17171a80"}>
                {window?.title || "Desktop"}
              </Rolling>

              <Highlight slot={open ?? pointed} active={open !== null} />
              {slots.map((slot) => (
                <Group key={slot.key} x={slot.x}>
                  {slot.content}
                  <Rect width={slot.width} height={barHeight} originX={0} originY={0} fill="#00000000"
                        onPointerEnter={() => setHovered({ output: output.name, key: slot.key })}
                        onPointerLeave={() => setHovered((now) => now?.key === slot.key ? null : now)}
                        onPointerDown={() => toggle(slot, output.name)} />
                </Group>
              ))}

              <Rect x={clockLeft - 8} y={10} width={1} height={barHeight - 20} originX={0} originY={0}
                    fill="#17171a1a" />
              <Rolling identity={dateFormat.format(time)} x={clockLeft} width={96} align="end"
                       color="#17171a99">{dateFormat.format(time)}</Rolling>
              <Rolling identity={timeFormat.format(time)} x={clockRight - 70} width={70} align="end"
                       weight={600}>{timeFormat.format(time)}</Rolling>
            </Group>

            {menu?.output === output.name && (
              // Clicking anywhere outside the menu closes it.
              <Rect width={output.width} height={output.height} originX={0} originY={0}
                    fill="#00000000" onPointerDown={() => setMenu(null)} />
            )}
          </Screen>
        );
      })}
      <BarMenu menu={menu} close={() => setMenu(null)} outputs={outputs} volume={volume}
               battery={battery} profile={profile} clipboard={clipboard} media={media}
               brightness={brightness} />
      <Indicator osd={osd} outputs={outputs} />

      <Shortcut keys="XF86AudioRaiseVolume" repeat onPress={() => flash("volume", () => changeVolume(0.05))} />
      <Shortcut keys="XF86AudioLowerVolume" repeat onPress={() => flash("volume", () => changeVolume(-0.05))} />
      <Shortcut keys="XF86AudioMute" onPress={() => flash("volume", toggleMute)} />
      <Shortcut keys="XF86AudioPlay" onPress={() => mediaCommand("PlayPause")} />
      <Shortcut keys="XF86AudioPause" onPress={() => mediaCommand("PlayPause")} />
      <Shortcut keys="XF86AudioNext" onPress={() => mediaCommand("Next")} />
      <Shortcut keys="XF86AudioPrev" onPress={() => mediaCommand("Previous")} />
      <Shortcut keys="XF86AudioStop" onPress={() => mediaCommand("Stop")} />
      <Shortcut keys="XF86MonBrightnessUp" repeat
                onPress={() => flash("brightness", () => changeBrightness(5))} />
      <Shortcut keys="XF86MonBrightnessDown" repeat
                onPress={() => flash("brightness", () => changeBrightness(-5))} />
    </>
  );
}

type Osd = "volume" | "brightness";

/** Which level to show briefly, and a function running a change and showing its level. */
function useOsd(): [Osd | null, (kind: Osd, change: () => void) => void] {
  const [osd, setOsd] = useState<Osd | null>(null);
  const timer = useRef<NodeJS.Timeout | null>(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  return [osd, (kind, change) => {
    change();
    setOsd(kind);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setOsd(null), 1300);
  }];
}

/** A level indicator rising from the bottom of each output after a volume or brightness key. */
function Indicator({ osd, outputs }: { osd: Osd | null; outputs: readonly OutputInfo[] }) {
  const volume = useVolume();
  const brightness = useBrightness();
  const shown = useRef<Osd>("volume");
  if (osd) shown.current = osd;
  const level = shown.current === "volume"
    ? (volume?.muted ? 0 : volume?.volume ?? 0) : (brightness?.percent ?? 0) / 100;
  const icon = shown.current === "brightness" ? brightnessIcon : volume?.muted ? mutedIcon : volumeIcon;
  return outputs.map((output) => (
    <Screen key={output.name} output={output.name}>
      <Group x={(output.width - 260) / 2} y={output.height - (osd ? 100 : 76)} width={260} height={48}
             opacity={osd ? 1 : 0} scale={osd ? 1 : 0.92} transition={pop}>
        <Rect width={260} height={48} radius={24} originX={0} originY={0} fill="#ffffffd9" blur={22}
              border={{ width: 1, color: { from: "#ffffffee", to: "#00000017", angle: 90 } }}
              shadow={{ color: "#00000029", blur: 28, y: 10 }} />
        <Image src={icon} x={20} y={16} width={16} height={16} originX={0} originY={0} opacity={0.85} />
        <Rect x={50} y={21} width={160} height={6} radius={3} originX={0} originY={0} fill="#17171a17" />
        <Rect x={50} y={21} width={Math.max(6, 160 * Math.min(level, 1))} height={6} radius={3}
              originX={0} originY={0} fill={{ from: "#5b8cff", to: accent, angle: 0 }} transition={glide} />
        <Text x={218} y={15} width={26} align="end" font={font} size={13} weight={600} color={ink}
              originX={0} originY={0}>{`${Math.round(level * 100)}`}</Text>
      </Group>
    </Screen>
  ));
}

/** The menu page: always loaded, springing open under the item that opened it. */
function BarMenu({ menu, close, outputs, volume, battery, profile, clipboard, media, brightness }: {
  menu: OpenMenu | null;
  close: () => void;
  outputs: readonly OutputInfo[];
  volume: ReturnType<typeof useVolume>;
  battery: ReturnType<typeof useBattery>;
  profile: ReturnType<typeof usePowerProfile>;
  clipboard: ReturnType<typeof useClipboard>;
  media: ReturnType<typeof useMedia>;
  brightness: ReturnType<typeof useBrightness>;
}) {
  // A closing menu keeps its size and place while it fades out.
  const last = useRef(menu);
  if (menu) last.current = menu;
  const shown = last.current;
  const output = outputs.find((candidate) => candidate.name === shown?.output) ?? outputs[0];
  if (!output) return null;
  // The clipboard menu grows with its history, up to six entries before it scrolls.
  const size = shown?.kind === "clipboard"
    ? { ...menuSizes.clipboard, height: 80 + 36 * Math.min(Math.max(clipboard.history.length, 1), 6) }
    : shown?.kind === "sound" && media?.title
      ? { ...menuSizes.sound, height: menuSizes.sound.height + mediaHeight }
      : menuSizes[shown?.kind ?? "sound"];
  const x = Math.min(Math.max(8, (shown?.right ?? output.width - 8) - size.width), output.width - size.width - 8);
  return (
    <Screen output={output.name}>
      <Web src="./bar-menu.tsx" autoFocus x={x} y={menu ? barReserve : barReserve - 10}
           width={size.width} height={size.height} radius={14} originX={1} originY={0}
           interactive={menu !== null} opacity={menu ? 1 : 0} scale={menu ? 1 : 0.94} blur={24}
           transition={pop} border={{ width: 1, color: { from: "#ffffffee", to: "#00000017", angle: 90 } }}
           shadow={{ color: "#0000002e", blur: 34, y: 12 }}
           props={{ kind: shown?.kind ?? null, opened: shown?.opened ?? 0, volume, battery, profile,
                    media, brightness, clipboard: clipboard.history.slice(0, 12) }}
           onMessage={(name, value) => {
             if (name === "volume") setVolume(value as number);
             else if (name === "mute") toggleMute();
             else if (name === "media") mediaCommand(value as "PlayPause" | "Next" | "Previous");
             else if (name === "brightness") setBrightness(value as number);
             else if (name === "profile") setPowerProfile(value as string);
             else if (name === "clear") clipboard.clear();
             else if (name === "copy") { clipboard.copy(value as string); close(); }
             else if (name === "close") close();
           }} />
    </Screen>
  );
}

/** Muted left-hand text for worlds without other controls. */
export function BarLabel({ children }: { children: string }) {
  return (
    <Text y={baseline} font={font} size={13} weight={600} color="#17171a99" originX={0} originY={0}>
      {children}
    </Text>
  );
}
