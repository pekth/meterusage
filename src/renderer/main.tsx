import { createRoot } from "react-dom/client";
import { App } from "./app";
import "./style.css";
async function mount() {
  let bridge = window.meterusage;
  if (!bridge && import.meta.env.MODE === "demo") bridge = await import("./preview").then(m => m.previewBridge());
  createRoot(document.getElementById("root")!).render(bridge ? <App bridge={bridge} /> : <p className="empty">MeterUsage requires its native app bridge.</p>);
}
void mount();
