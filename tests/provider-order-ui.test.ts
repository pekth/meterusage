import { it, expect, vi, beforeEach } from "vite-plus/test";
import { createElement, isValidElement, type ReactNode } from "react";
import { ProviderOrder } from "../src/renderer/provider-order";
import { providers, type Provider } from "../src/domain/models";
const hooks = vi.hoisted(() => ({ cells: [] as unknown[], cursor: 0 }));
vi.mock("react", async original => ({
  ...await original<typeof import("react")>(),
  useRef: (initial: unknown) => { const i = hooks.cursor++; return hooks.cells[i] ??= { current: initial }; },
  useState: (initial: unknown) => { const i = hooks.cursor++; if (!(i in hooks.cells)) hooks.cells[i] = initial; return [hooks.cells[i], (value: unknown) => { hooks.cells[i] = value; }]; },
}));
type Element = { type: unknown; props: Record<string, any> };
function elements(node: ReactNode): Element[] {
  if (Array.isArray(node)) return node.flatMap(elements);
  if (!isValidElement(node)) return [];
  const el = node as Element; return [el, ...elements(el.props.children)];
}
function setup(result: boolean | Promise<boolean> = true) {
  let saved: Provider[] = [...providers]; const focus = vi.fn();
  const save = vi.fn(async (next: Provider[]) => { const ok = await result; if (ok) saved = next; return ok; });
  const render = () => {
    hooks.cursor = 0;
    const tree = ProviderOrder({ order: saved, save, controls: p => createElement("input", { "aria-label": `Collect ${p}` }) });
    for (const el of elements(tree)) if (el.props.ref) el.props.ref({ focus });
    return tree;
  };
  const button = (label: string) => elements(render()).find(e => e.type === "button" && e.props["aria-label"] === label)!;
  const row = (provider: Provider) => elements(render()).find(e => e.props.onDrop && elements(e.props.children).some(child => child.props["aria-label"] === `Collect ${provider}`))!;
  const transfer = { effectAllowed: "", dropEffect: "", setData: vi.fn(), getData: vi.fn(() => { throw new Error("External data must not be read"); }) };
  const event = (y = 0) => ({ preventDefault: vi.fn(), dataTransfer: transfer, clientY: y, currentTarget: { getBoundingClientRect: () => ({ top: 0, height: 40 }) } });
  return { render, button, row, save, focus, event, get saved() { return saved; } };
}
const settle = async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };
beforeEach(() => { hooks.cells = []; hooks.cursor = 0; });
it("moves by keyboard and buttons, respects bounds and restores handle focus", async () => {
  const s = setup(); expect(s.button("Move Codex up").props.disabled).toBe(true); expect(s.button("Move Gemini CLI down").props.disabled).toBe(true);
  s.button("Reorder Codex").props.onKeyDown({ key: "ArrowUp", preventDefault: vi.fn() }); await settle(); expect(s.save).not.toHaveBeenCalled();
  s.button("Reorder Claude").props.onKeyDown({ key: "ArrowUp", preventDefault: vi.fn() }); await settle(); expect(s.saved.slice(4, 6)).toEqual(["claude", "openRouter"]);
  s.button("Move Claude up").props.onClick(); await settle(); expect(s.saved.slice(3, 5)).toEqual(["claude", "openCodeGo"]); expect(s.focus).toHaveBeenCalled();
  expect(elements(s.render()).find(e => e.props.role === "status")?.props.children).toContain("Claude moved to position 4");
});
it("shows a drop cue, saves only on internal drop and keeps accounts outside the payload", async () => {
  const s = setup(), external = s.event(); s.row("codex").props.onDrop(external); expect(external.preventDefault).toHaveBeenCalledOnce(); expect(s.save).not.toHaveBeenCalled();
  s.button("Reorder Claude").props.onDragStart(s.event()); s.row("codex").props.onDragOver(s.event());
  expect(s.row("codex").props.className).toContain("drop-before"); expect(s.save).not.toHaveBeenCalled();
  s.row("codex").props.onDrop(s.event()); await settle(); expect(s.saved[0]).toBe("claude"); expect(s.save).toHaveBeenCalledTimes(1); expect(s.event().dataTransfer.getData).not.toHaveBeenCalled();
  s.button("Reorder Codex").props.onDragStart(s.event()); s.row("grok").props.onDrop(s.event(30)); await settle();
  expect(s.saved.slice(0, 4)).toEqual(["claude", "antigravity", "grok", "codex"]); expect(s.save).toHaveBeenCalledTimes(2);
});
it("cancels with Escape or drag end and ignores a later external drop", async () => {
  const s = setup(); s.button("Reorder Claude").props.onDragStart(s.event()); s.row("codex").props.onDragOver(s.event(30));
  expect(s.row("codex").props.className).toContain("drop-after");
  s.render().props.onKeyDown({ key: "Escape", preventDefault: vi.fn() }); s.row("codex").props.onDrop(s.event()); await settle();
  expect(s.saved).toEqual(providers); expect(s.save).not.toHaveBeenCalled(); expect(s.focus).toHaveBeenCalled();
  s.button("Reorder Claude").props.onDragStart(s.event()); s.button("Reorder Claude").props.onDragEnd(); expect(s.save).not.toHaveBeenCalled();
});
it("keeps the last saved order and focus after a failed save and blocks overlapping moves", async () => {
  let finish!: (ok: boolean) => void; const s = setup(new Promise<boolean>(resolve => { finish = resolve; }));
  s.button("Move Claude up").props.onClick(); expect(s.button("Move Claude up").props.disabled).toBe(true);
  s.button("Reorder Grok").props.onKeyDown({ key: "ArrowUp", preventDefault: vi.fn() }); expect(s.save).toHaveBeenCalledTimes(1); expect(s.saved).toEqual(providers);
  finish(false); await settle(); expect(s.saved).toEqual(providers); expect(s.button("Move Claude up").props.disabled).toBe(false); expect(s.focus).toHaveBeenCalled();
  expect(elements(s.render()).find(e => e.props.role === "status")?.props.children).toBe("");
});
