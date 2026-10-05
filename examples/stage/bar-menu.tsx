// The bar's menus, rendered by Chromium: sound with what is playing, battery
// with display brightness and power mode, and clipboard history. One page
// serves all three, so opening any menu reuses the same, already loaded page.
// Each opening replays a short staggered entrance; everything else is CSS
// transitions, so the page is still between interactions.

import { useEffect } from "react";
import { send } from "@ataxia/stage/page";

interface Props {
  kind?: "sound" | "battery" | "clipboard" | null;
  /** Counts openings; a new value replays the entrance. */
  opened?: number;
  volume?: { volume: number; muted: boolean; device: string } | null;
  battery?: { percent: number; charging: boolean; full: boolean; pluggedIn: boolean;
              minutes: number | null; watts: number | null } | null;
  profile?: { current: string; available: string[] } | null;
  clipboard?: string[];
  media?: { identity: string; playing: boolean; title: string; artist: string; canNext: boolean;
            canPrevious: boolean } | null;
  brightness?: { percent: number } | null;
}

const css = `
:root { --ink: #17171a; --muted: #17171a8c; --accent: #2f6fed; --line: #17171a12; }
* { box-sizing: border-box; }
body { margin: 0; color: var(--ink); font: 13px "Noto Sans", system-ui, sans-serif;
       -webkit-font-smoothing: antialiased; user-select: none; }
.card { height: 100vh; padding: 14px 16px; display: flex; flex-direction: column; gap: 12px;
        background: linear-gradient(180deg, #ffffffeb, #ffffffd6); }
.row { display: flex; align-items: center; gap: 10px; min-width: 0;
       animation: rise .38s cubic-bezier(.2, .9, .25, 1.05) both; animation-delay: calc(var(--i) * 35ms); }
@keyframes rise { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
.between { justify-content: space-between; }
.title { font-weight: 650; letter-spacing: -.005em; }
.muted { color: var(--muted); }
.ellipsis { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.grow { flex: 1; min-width: 0; }
.divider { height: 1px; background: var(--line); margin: 0 -16px; }

input[type=range] { -webkit-appearance: none; appearance: none; width: 100%; height: 22px; margin: 0;
                    background: transparent; cursor: pointer; }
input[type=range]::-webkit-slider-runnable-track {
  height: 6px; border-radius: 3px;
  background: linear-gradient(90deg, #5b8cff, var(--accent)) 0 / var(--fill) 100% no-repeat, #17171a17; }
input[type=range]::-webkit-slider-thumb {
  -webkit-appearance: none; width: 18px; height: 18px; margin-top: -6px; border-radius: 50%;
  background: #fff; box-shadow: 0 1px 3px #0000003d, 0 0 0 .5px #00000026;
  transition: transform .18s cubic-bezier(.2, .9, .3, 1.3); }
input[type=range]:hover::-webkit-slider-thumb { transform: scale(1.08); }
input[type=range]:active::-webkit-slider-thumb { transform: scale(1.22); }

button { font: inherit; color: inherit; cursor: pointer; border: 1px solid #17171a17; background: #ffffffb3;
         border-radius: 9px; padding: 6px 12px;
         transition: background .16s, border-color .16s, color .16s, transform .12s, box-shadow .16s; }
button:hover { background: #ffffff; box-shadow: 0 1px 3px #0000001a; }
button:active { transform: scale(.96); }
.segment { display: flex; gap: 4px; padding: 3px; border-radius: 11px; background: #17171a0d; }
.segment button { flex: 1; border: none; background: transparent; padding: 6px 0; border-radius: 8px; }
.segment button.on { background: #fff; color: var(--accent); box-shadow: 0 1px 3px #0000001f; }
.round { width: 34px; height: 34px; padding: 0; border-radius: 50%; display: grid; place-items: center; }
.round:disabled { opacity: .35; cursor: default; transform: none; }
.play { width: 38px; height: 38px; border: none; color: #fff;
        background: linear-gradient(180deg, #4a82ff, var(--accent)); box-shadow: 0 3px 10px #2f6fed59; }
.play:hover { background: linear-gradient(180deg, #5a8eff, #3a78f2); box-shadow: 0 4px 14px #2f6fed73; }
.toggle { padding: 5px 12px; }
.toggle.on { color: var(--accent); border-color: #2f6fed59; background: #2f6fed12; }
.big { font-size: 28px; font-weight: 650; letter-spacing: -.02em; }
.badge { padding: 2px 8px; border-radius: 99px; background: #17171a0d; font-size: 12px; }
.badge.charging { background: #2f6fed17; color: var(--accent); }
.entry { padding: 8px 10px; margin: 0 -10px; border-radius: 9px; cursor: pointer;
         font: 12px "Noto Sans Mono", ui-monospace, monospace; transition: background .14s, transform .12s; }
.entry:hover { background: #2f6fed12; }
.entry:active { transform: scale(.985); }
.list { overflow-y: auto; margin-top: -4px; }
.link { color: var(--accent); cursor: pointer; font-weight: 600; }
`;

const profileNames: Record<string, string> = {
  "power-saver": "Saver", balanced: "Balanced", performance: "Performance",
};

function duration(minutes: number) {
  const hours = Math.floor(minutes / 60);
  return hours > 0 ? `${hours} h ${minutes % 60} min` : `${minutes} min`;
}

/** A slider whose filled part follows its value. */
function Slider({ value, onChange, min = 0 }: { value: number; onChange: (value: number) => void; min?: number }) {
  return (
    <input type="range" min={min} max={100} value={value}
           style={{ "--fill": `${(value - min) / (100 - min) * 100}%` } as React.CSSProperties}
           onChange={(event) => onChange(Number(event.target.value))} />
  );
}

function Icon({ path, fill = "currentColor" }: { path: string; fill?: string }) {
  return <svg width="14" height="14" viewBox="0 0 16 16" fill={fill}><path d={path} /></svg>;
}

function NowPlaying({ media, index }: { media: NonNullable<Props["media"]>; index: number }) {
  return (
    <>
      <div className="row" style={{ "--i": index } as React.CSSProperties}>
        <div className="grow">
          <div className="title ellipsis">{media.title}</div>
          <div className="muted ellipsis">{[media.artist, media.identity].filter(Boolean).join(" · ")}</div>
        </div>
        <button className="round" disabled={!media.canPrevious} onClick={() => send("media", "Previous")}>
          <Icon path="M4 3h1.6v10H4zM13 3.2v9.6L6.4 8z" />
        </button>
        <button className="round play" onClick={() => send("media", "PlayPause")}>
          <Icon path={media.playing ? "M4.5 3h2.6v10H4.5zM8.9 3h2.6v10H8.9z" : "M5.2 2.8l8 5.2-8 5.2z"} />
        </button>
        <button className="round" disabled={!media.canNext} onClick={() => send("media", "Next")}>
          <Icon path="M10.4 3H12v10h-1.6zM3 3.2v9.6L9.6 8z" />
        </button>
      </div>
      <div className="divider" />
    </>
  );
}

function Sound({ volume, media }: Pick<Props, "volume" | "media">) {
  if (!volume) return <div className="row muted" style={{ "--i": 0 } as React.CSSProperties}>No sound output</div>;
  const percent = Math.round(volume.volume * 100);
  const offset = media?.title ? 1 : 0;
  return (
    <>
      {media?.title && <NowPlaying media={media} index={0} />}
      <div className="row between" style={{ "--i": offset } as React.CSSProperties}>
        <span className="title">Sound</span>
        <span className="muted">{volume.muted ? "Muted" : `${percent}%`}</span>
      </div>
      <div className="row" style={{ "--i": offset + 1 } as React.CSSProperties}>
        <Slider value={volume.muted ? 0 : percent} onChange={(value) => send("volume", value / 100)} />
      </div>
      <div className="row between" style={{ "--i": offset + 2 } as React.CSSProperties}>
        <span className="muted ellipsis">{volume.device}</span>
        <button className={`toggle${volume.muted ? " on" : ""}`} onClick={() => send("mute")}>
          {volume.muted ? "Unmute" : "Mute"}
        </button>
      </div>
    </>
  );
}

function Battery({ battery, profile, brightness }: Pick<Props, "battery" | "profile" | "brightness">) {
  const state = !battery ? "No battery"
    : battery.full ? "Fully charged"
    : battery.pluggedIn && !battery.charging ? "Plugged in"
    : battery.charging
      ? `Charging${battery.minutes !== null ? ` · ${duration(battery.minutes)} to full` : ""}`
      : `${battery.minutes !== null ? `${duration(battery.minutes)} left` : "On battery"}`;
  let index = 0;
  const next = () => ({ "--i": index++ } as React.CSSProperties);
  return (
    <>
      <div className="row" style={next()}>
        <span className="big">{battery ? `${battery.percent}%` : "—"}</span>
        <span className={`badge${battery?.charging ? " charging" : ""}`}>{state}</span>
        {battery?.watts ? <span className="muted">{battery.watts} W</span> : null}
      </div>
      {brightness && (
        <>
          <div className="row between" style={next()}>
            <span className="title">Display</span>
            <span className="muted">{brightness.percent}%</span>
          </div>
          <div className="row" style={next()}>
            <Slider min={1} value={brightness.percent} onChange={(value) => send("brightness", value)} />
          </div>
        </>
      )}
      {profile && (
        <div className="row" style={next()}>
          <div className="segment grow">
            {profile.available.map((name) => (
              <button key={name} className={name === profile.current ? "on" : ""}
                      onClick={() => send("profile", name)}>{profileNames[name] ?? name}</button>
            ))}
          </div>
        </div>
      )}
    </>
  );
}

function Clipboard({ clipboard = [] }: Pick<Props, "clipboard">) {
  return (
    <>
      <div className="row between" style={{ "--i": 0 } as React.CSSProperties}>
        <span className="title">Clipboard</span>
        {clipboard.length > 0 && <span className="link" onClick={() => send("clear")}>Clear</span>}
      </div>
      {clipboard.length === 0 && (
        <div className="row muted" style={{ "--i": 1 } as React.CSSProperties}>Copied text appears here.</div>
      )}
      <div className="list">
        {clipboard.map((text, index) => (
          <div key={text} className="row entry ellipsis" title={text}
               style={{ "--i": index + 1, display: "block" } as React.CSSProperties}
               onClick={() => send("copy", text)}>
            {text.replace(/\s+/g, " ").slice(0, 200)}
          </div>
        ))}
      </div>
    </>
  );
}

export default function BarMenu(props: Props) {
  useEffect(() => {
    const close = (event: KeyboardEvent) => { if (event.key === "Escape") send("close"); };
    addEventListener("keydown", close);
    return () => removeEventListener("keydown", close);
  }, []);
  return (
    <>
      <style>{css}</style>
      {/* Keyed by opening, so every opening replays the entrance. */}
      <div className="card" key={`${props.kind}:${props.opened}`}>
        {props.kind === "sound" && <Sound volume={props.volume} media={props.media} />}
        {props.kind === "battery" && (
          <Battery battery={props.battery} profile={props.profile} brightness={props.brightness} />
        )}
        {props.kind === "clipboard" && <Clipboard clipboard={props.clipboard} />}
      </div>
    </>
  );
}
