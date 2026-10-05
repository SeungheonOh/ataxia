// The application launcher page for hypr.tsx, rendered by Chromium.
// Type to filter, Up/Down to choose, Enter to launch, Escape to close.

import { useEffect, useRef, useState } from "react";
import { send } from "@ataxia/stage/page";

interface Application { id: string; name: string; detail: string }

export default function Launcher({ applications = [], shown = false }:
                                 { applications?: Application[]; shown?: boolean }) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const matches = applications
    .filter((app) => `${app.name} ${app.detail}`.toLowerCase().includes(query.toLowerCase()))
    .slice(0, 7);

  // Each opening starts from an empty search with the field focused.
  useEffect(() => {
    if (!shown) return;
    setQuery("");
    setSelected(0);
    input.current?.focus();
  }, [shown]);

  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key === "Escape") send("close");
    else if (event.key === "ArrowDown") setSelected((index) => Math.min(index + 1, matches.length - 1));
    else if (event.key === "ArrowUp") setSelected((index) => Math.max(index - 1, 0));
    else if (event.key === "Enter" && matches[selected]) send("launch", matches[selected].id);
    else return;
    event.preventDefault();
  }

  return (
    <div style={{ height: "100%", boxSizing: "border-box", padding: 18, color: "#e6e6f0",
                  background: "rgba(24, 24, 32, 0.72)", font: "15px system-ui, sans-serif" }}>
      <input ref={input} value={query} placeholder="Search applications"
             onChange={(event) => { setQuery(event.target.value); setSelected(0); }} onKeyDown={onKeyDown}
             style={{ width: "100%", boxSizing: "border-box", padding: "12px 14px", fontSize: 18,
                      color: "inherit", background: "rgba(255,255,255,0.08)", outline: "none",
                      border: "1px solid rgba(255,255,255,0.14)", borderRadius: 10 }} />
      <ul style={{ listStyle: "none", margin: "12px 0 0", padding: 0 }}>
        {matches.map((app, index) => (
          <li key={app.id} onMouseEnter={() => setSelected(index)} onClick={() => send("launch", app.id)}
              style={{ padding: "9px 12px", borderRadius: 8, cursor: "pointer",
                       background: index === selected ? "rgba(51, 204, 255, 0.22)" : "transparent" }}>
            <div style={{ fontWeight: 600 }}>{app.name}</div>
            <div style={{ fontSize: 12, opacity: 0.65, whiteSpace: "nowrap", overflow: "hidden",
                          textOverflow: "ellipsis" }}>{app.detail}</div>
          </li>
        ))}
      </ul>
    </div>
  );
}
