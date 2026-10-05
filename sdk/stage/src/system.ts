// System state for world UI such as bars: time, battery, sound and power
// profile.
//
// Every source runs only while a component reads it, and is event-driven: the
// clock fires at minute boundaries, sound follows PipeWire's change events
// (pw-mon) and battery follows UPower's (upower --monitor). An idle desktop
// therefore wakes the director once a minute for its clock and otherwise only
// when something actually changes.

import { execFile, spawn, type ChildProcess } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { useSyncExternalStore } from "react";

/** A value shared by every reader, with a feed that runs while anyone reads it. */
class Source<T> {
  private readonly listeners = new Set<() => void>();
  private stop: (() => void) | null = null;

  constructor(public value: T, private readonly feed: (source: Source<T>) => () => void) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (!this.stop) this.stop = this.feed(this);
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0 && this.stop) {
        this.stop();
        this.stop = null;
      }
    };
  };

  read = (): T => this.value;

  set(value: T): void {
    if (JSON.stringify(value) === JSON.stringify(this.value)) return;
    this.value = value;
    for (const listener of this.listeners) listener();
  }
}

/** Run COMMAND for its lifetime, calling ONLINE for each output line; returns a stop function. */
function follow(command: string, args: string[], online: (line: string) => void): () => void {
  let child: ChildProcess | null = null;
  try {
    child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    child.on("error", () => undefined);
    createInterface({ input: child.stdout! }).on("line", online);
  } catch {
    child = null;
  }
  return () => child?.kill();
}

function run(command: string, args: string[]): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(command, args, { timeout: 3000 }, (error, stdout) => resolve(error ? null : stdout));
  });
}

/** Call FUNCTION once, a moment after the last of a burst of calls. */
function debounced(function_: () => void, milliseconds: number): () => void {
  let timer: NodeJS.Timeout | null = null;
  return () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => { timer = null; function_(); }, milliseconds);
  };
}

// Time.

const time = new Source(new Date(), (source) => {
  let timer: NodeJS.Timeout;
  const tick = () => {
    source.set(new Date());
    // One wakeup just after each minute starts, when a clock's text changes.
    timer = setTimeout(tick, 60_000 - (Date.now() % 60_000) + 50);
  };
  tick();
  return () => clearTimeout(timer);
});

/** The current time, updated at the start of every minute. */
export function useTime(): Date {
  return useSyncExternalStore(time.subscribe, time.read);
}

// Battery.

export interface BatteryInfo {
  /** Charge, 0..100. */
  percent: number;
  charging: boolean;
  full: boolean;
  /** On external power, whether or not it is charging. */
  pluggedIn: boolean;
  /** Minutes until empty while discharging, or until full while charging; null if unknown. */
  minutes: number | null;
  /** Current draw or charge rate in watts, when the battery reports it. */
  watts: number | null;
}

function readBattery(): BatteryInfo | null {
  try {
    const name = readdirSync("/sys/class/power_supply").find((entry) => entry.startsWith("BAT"));
    if (!name) return null;
    const field = (key: string) => {
      try {
        return readFileSync(`/sys/class/power_supply/${name}/${key}`, "utf8").trim();
      } catch {
        return null;
      }
    };
    const number = (key: string) => {
      const value = Number(field(key));
      return Number.isFinite(value) ? value : null;
    };
    const status = field("status");
    const now = number("energy_now") ?? number("charge_now");
    const full = number("energy_full") ?? number("charge_full");
    const rate = number("power_now") ?? number("current_now");
    const charging = status === "Charging";
    const adapter = readdirSync("/sys/class/power_supply").find((entry) => {
      try {
        return readFileSync(`/sys/class/power_supply/${entry}/type`, "utf8").trim() === "Mains";
      } catch {
        return false;
      }
    });
    const online = adapter
      ? readFileSync(`/sys/class/power_supply/${adapter}/online`, "utf8").trim() === "1"
      : status !== "Discharging";
    const minutes = rate && rate > 0 && now !== null && full !== null
      ? Math.round(60 * (charging ? full - now : now) / rate)
      : null;
    return {
      percent: Number(field("capacity") ?? 0), charging, full: status === "Full", pluggedIn: online,
      minutes, watts: rate && number("power_now") !== null ? Math.round(rate / 1e5) / 10 : null,
    };
  } catch {
    return null;
  }
}

const battery = new Source(readBattery(), (source) => {
  const refresh = debounced(() => source.set(readBattery()), 200);
  source.set(readBattery());
  // UPower reports charge and power changes; a slow fallback covers systems without it.
  const stop = follow("upower", ["--monitor"], refresh);
  const fallback = setInterval(refresh, 300_000);
  return () => { stop(); clearInterval(fallback); };
});

/** The first battery's state; null without a battery. */
export function useBattery(): BatteryInfo | null {
  return useSyncExternalStore(battery.subscribe, battery.read);
}

// Sound.

export interface VolumeInfo {
  /** Default output volume, 0..1 (may exceed 1 when amplified). */
  volume: number;
  muted: boolean;
  /** The default output's description, e.g. "Built-in Audio Analog Stereo". */
  device: string;
}

const sink = "@DEFAULT_AUDIO_SINK@";

async function readVolume(): Promise<VolumeInfo | null> {
  const [level, details] = await Promise.all([run("wpctl", ["get-volume", sink]),
                                              run("wpctl", ["inspect", sink])]);
  const match = level?.match(/Volume:\s*([\d.]+)/);
  if (!match) return null;
  return {
    volume: Number(match[1]), muted: level!.includes("[MUTED]"),
    device: details?.match(/node\.description = "([^"]*)"/)?.[1] ?? "Output",
  };
}

const volume = new Source<VolumeInfo | null>(null, (source) => {
  const refresh = debounced(() => void readVolume().then((value) => source.set(value)), 80);
  refresh();
  // pw-mon prints the graph once, then one block per change.
  const stop = follow("pw-mon", ["-N"], (line) => { if (line.startsWith("changed:")) refresh(); });
  return stop;
});

/** The default output's volume; null until known or without PipeWire. */
export function useVolume(): VolumeInfo | null {
  return useSyncExternalStore(volume.subscribe, volume.read);
}

let volumeRequest: Promise<unknown> | null = null;
let volumeWanted: number | null = null;

/** Set the default output's volume, 0..1. Rapid calls (a dragged slider) keep only the latest. */
export function setVolume(level: number): void {
  volumeWanted = Math.min(Math.max(level, 0), 1);
  if (volume.value) volume.set({ ...volume.value, volume: volumeWanted });
  if (volumeRequest) return;
  const send = (): Promise<unknown> | null => {
    if (volumeWanted === null) return null;
    const next = volumeWanted;
    volumeWanted = null;
    return run("wpctl", ["set-volume", sink, next.toFixed(2)]).then(() => { volumeRequest = send(); });
  };
  volumeRequest = send();
}

export function toggleMute(): void {
  if (volume.value) volume.set({ ...volume.value, muted: !volume.value.muted });
  void run("wpctl", ["set-mute", sink, "toggle"]);
}

// Power profile.

export interface PowerProfileInfo {
  /** "power-saver", "balanced" or "performance". */
  current: string;
  available: string[];
}

async function readPowerProfile(): Promise<PowerProfileInfo | null> {
  const [current, list] = await Promise.all([run("powerprofilesctl", ["get"]),
                                             run("powerprofilesctl", ["list"])]);
  if (!current) return null;
  const available = [...(list ?? "").matchAll(/^[* ] ([\w-]+):/gm)].map((match) => match[1]!);
  return { current: current.trim(), available: available.length > 0 ? available.reverse() : [current.trim()] };
}

const powerProfile = new Source<PowerProfileInfo | null>(null, (source) => {
  void readPowerProfile().then((value) => source.set(value));
  return () => undefined;
});

/** The active power profile, from power-profiles-daemon; null without it. */
export function usePowerProfile(): PowerProfileInfo | null {
  return useSyncExternalStore(powerProfile.subscribe, powerProfile.read);
}

export function setPowerProfile(name: string): void {
  if (powerProfile.value) powerProfile.set({ ...powerProfile.value, current: name });
  void run("powerprofilesctl", ["set", name])
    .then(() => readPowerProfile()).then((value) => powerProfile.set(value));
}

/** Change the default output's volume by DELTA (0..1 scale), capped at full volume. */
export function changeVolume(delta: number): void {
  if (volume.value) {
    volume.set({ ...volume.value, muted: false,
                 volume: Math.min(Math.max(volume.value.volume + delta, 0), 1) });
  }
  const step = `${Math.round(Math.abs(delta) * 100)}%${delta >= 0 ? "+" : "-"}`;
  void run("wpctl", ["set-volume", "-l", "1.0", sink, step]);
  if (delta > 0) void run("wpctl", ["set-mute", sink, "0"]);
}

// Media players (MPRIS).

export interface MediaInfo {
  /** Bus name of the player, e.g. "org.mpris.MediaPlayer2.firefox.instance_1_42". */
  player: string;
  /** The player's own name, e.g. "Firefox". */
  identity: string;
  playing: boolean;
  title: string;
  artist: string;
  canNext: boolean;
  canPrevious: boolean;
}

const mprisPrefix = "org.mpris.MediaPlayer2.";
const mprisPath = "/org/mpris/MediaPlayer2";

async function busProperties(name: string, iface: string, properties: string[]): Promise<unknown[] | null> {
  const output = await run("busctl", ["--user", "--json=short", "get-property", name, mprisPath, iface,
                                      ...properties]);
  if (!output) return null;
  try {
    return output.trim().split("\n").map((line) => (JSON.parse(line) as { data: unknown }).data);
  } catch {
    return null;
  }
}

async function readMedia(): Promise<MediaInfo | null> {
  const listing = await run("busctl", ["--user", "list", "--no-legend"]);
  const players = (listing ?? "").split("\n").map((line) => line.split(/\s+/))
    .filter(([name, pid]) => name?.startsWith(mprisPrefix) && pid !== "-").map(([name]) => name!);
  const states = await Promise.all(players.map(async (player) => {
    const values = await busProperties(player, "org.mpris.MediaPlayer2.Player",
                                       ["PlaybackStatus", "Metadata", "CanGoNext", "CanGoPrevious"]);
    return values ? { player, values } : null;
  }));
  const known = states.filter((state) => state !== null);
  // The player that is playing, else the first one that has something loaded.
  const chosen = known.find((state) => state.values[0] === "Playing") ?? known[0];
  if (!chosen) return null;
  const metadata = (chosen.values[1] ?? {}) as Record<string, { data: unknown }>;
  const identity = await busProperties(chosen.player, "org.mpris.MediaPlayer2", ["Identity"]);
  const artist = metadata["xesam:artist"]?.data;
  return {
    player: chosen.player,
    identity: String(identity?.[0] ?? chosen.player.slice(mprisPrefix.length).split(".")[0]),
    playing: chosen.values[0] === "Playing",
    title: String(metadata["xesam:title"]?.data ?? ""),
    artist: Array.isArray(artist) ? artist.join(", ") : String(artist ?? ""),
    canNext: chosen.values[2] === true, canPrevious: chosen.values[3] === true,
  };
}

const media = new Source<MediaInfo | null>(null, (source) => {
  const refresh = debounced(() => void readMedia().then((value) => source.set(value)), 150);
  refresh();
  // Players announce state and track changes; nothing is polled.
  return follow("dbus-monitor", [
    "--session",
    `type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='${mprisPath}'`,
    "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.mpris.MediaPlayer2'",
  ], (line) => { if (line.startsWith("signal")) refresh(); });
});

/** The media player that is playing, or the first one with a track; null without any. */
export function useMedia(): MediaInfo | null {
  return useSyncExternalStore(media.subscribe, media.read);
}

/** Send a player command; without PLAYER, to the current one. */
export function mediaCommand(command: "PlayPause" | "Next" | "Previous" | "Stop", player?: string): void {
  const target = player ?? media.value?.player;
  if (!target) return;
  if (command === "PlayPause" && media.value) media.set({ ...media.value, playing: !media.value.playing });
  void run("busctl", ["--user", "call", target, mprisPath, "org.mpris.MediaPlayer2.Player", command]);
}

// Display brightness.

export interface BrightnessInfo {
  /** 0..100. */
  percent: number;
  device: string;
}

function readBrightness(): BrightnessInfo | null {
  try {
    const device = readdirSync("/sys/class/backlight")[0];
    if (!device) return null;
    const value = (file: string) => Number(readFileSync(`/sys/class/backlight/${device}/${file}`, "utf8"));
    return { device, percent: Math.round(100 * value("brightness") / Math.max(1, value("max_brightness"))) };
  } catch {
    return null;
  }
}

const brightness = new Source<BrightnessInfo | null>(readBrightness(), (source) => {
  source.set(readBrightness());
  return () => undefined;
});

/** The first backlight's brightness; null without one. */
export function useBrightness(): BrightnessInfo | null {
  return useSyncExternalStore(brightness.subscribe, brightness.read);
}

/** Set the backlight to PERCENT through logind, which allows the session's own user. */
export function setBrightness(percent: number): void {
  const current = brightness.value ?? readBrightness();
  if (!current) return;
  const target = Math.min(Math.max(Math.round(percent), 1), 100);
  brightness.set({ ...current, percent: target });
  let maximum = 0;
  try {
    maximum = Number(readFileSync(`/sys/class/backlight/${current.device}/max_brightness`, "utf8"));
  } catch {
    return;
  }
  brightnessWanted = { device: current.device, value: Math.round(maximum * target / 100) };
  if (!brightnessRequest) brightnessRequest = sendBrightness();
}

let brightnessRequest: Promise<unknown> | null = null;
let brightnessWanted: { device: string; value: number } | null = null;

/** Apply the latest wanted brightness; a dragged slider sends only its newest value. */
function sendBrightness(): Promise<unknown> | null {
  if (!brightnessWanted) return null;
  const { device, value } = brightnessWanted;
  brightnessWanted = null;
  return run("busctl", ["call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
                        "org.freedesktop.login1.Session", "SetBrightness", "ssu", "backlight",
                        device, String(value)])
    .then(() => { brightnessRequest = sendBrightness(); });
}

export function changeBrightness(delta: number): void {
  const current = brightness.value ?? readBrightness();
  if (current) setBrightness(current.percent + delta);
}
