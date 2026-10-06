export type Selection = true | { [key: string]: Selection };

// Walk syntax without decoding values outside the declared selection. In
// particular, Claude identity fields and transcript content are never passed
// to JSON.parse or materialized as JavaScript values.
export function selectJSON(source: string, selection: Selection, onScalar?: (raw: string) => void): unknown {
  let i = 0;
  const scalar = /(?:null|true|false|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/y;
  const bad = (): never => { throw new Error("Invalid selected JSON"); };
  const ws = () => { while (i < source.length && /[\t\r\n ]/.test(source[i])) i++; };
  function stringEnd(): number {
    if (source[i++] !== '"') return bad();
    while (i < source.length) {
      const c = source[i++];
      if (c === '"') return i;
      if (c.charCodeAt(0) < 32) return bad();
      if (c === "\\") {
        const e = source[i++];
        if (e === "u") { if (!/^[0-9a-fA-F]{4}$/.test(source.slice(i, i + 4))) return bad(); i += 4; }
        else if (!e || !'"\\/bfnrt'.includes(e)) return bad();
      }
    }
    return bad();
  }
  function value(shape: Selection | undefined, depth: number): unknown {
    if (depth > 256) return bad();
    ws();
    const start = i, c = source[i];
    if (c === "{" || c === "[") {
      i++;
      const object = c === "{", end = object ? "}" : "]";
      const selected = typeof shape === "object";
      const result: Record<string, unknown> | unknown[] | undefined = selected ? object ? Object.create(null) : [] : undefined;
      ws(); if (source[i] === end) { i++; return result; }
      while (true) {
        ws(); let key: string | undefined;
        if (object) {
          const keyStart = i; stringEnd();
          // Object keys describe the selection; unknown values are skipped.
          key = selected ? JSON.parse(source.slice(keyStart, i)) as string : undefined;
          ws(); if (source[i++] !== ":") return bad();
        }
        const child = selected ? object ? Object.hasOwn(shape, key!) ? shape[key!] : shape["*"] : shape["*"] : undefined;
        const v = value(child, depth + 1);
        if (result && child !== undefined && v !== undefined) {
          if (Array.isArray(result)) result.push(v); else result[key!] = v;
        }
        ws(); const next = source[i++];
        if (next === end) return result;
        if (next !== ",") return bad();
      }
    }
    if (c === '"') stringEnd();
    else {
      scalar.lastIndex = i;
      const m = scalar.exec(source);
      if (!m) return bad(); i += m[0].length;
    }
    if (shape !== true) return;
    const raw = source.slice(start, i); onScalar?.(raw);
    return JSON.parse(raw) as unknown;
  }
  const result = value(selection, 0); ws(); if (i !== source.length) return bad(); return result;
}
