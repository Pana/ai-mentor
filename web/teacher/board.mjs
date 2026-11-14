import { columnCalc, shown } from './calc.mjs';

// Whiteboard for the voice teacher (mirrors `server/src/board.mjs`). The server validates every op and always
// sends whole elements, so `add` and `update` are both upserts here. Each element is drawn from its meaning
// (a column calculation, a number line …); only the parts that are new since the last update animate in.

const SVG_NS = 'http://www.w3.org/2000/svg';

function h(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
  node.append(...children);
  return node;
}
function s(tag, attrs = {}, ...children) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
  node.append(...children);
  return node;
}
const place = (node, column, row) => { node.style.gridColumn = column; node.style.gridRow = row; return node; };

function renderText(el, prev) {
  const node = h('div', { class: `b-text b-text-${['title', 'answer', 'hint'].includes(el.style) ? el.style : 'body'}` }, el.text);
  if (prev?.text !== el.text) node.classList.add('write');
  return node;
}

/** 竖式: operands right-aligned, carries under the second operand, result digits revealed from the ones column. */
function renderVertical(el, prev) {
  const calc = columnCalc(el.a, el.b, el.operator), columns = calc.width + 1; // one extra on the left for the operator
  const same = prev?.type === 'vertical' && prev.a === el.a && prev.b === el.b && prev.operator === el.operator;
  const before = same ? prev.reveal : 0;
  const node = h('div', { class: 'b-vertical', role: 'img', 'aria-label': `竖式 ${el.a} ${el.operator} ${el.b}` });
  node.style.setProperty('--columns', columns);
  const gridColumn = column => columns - column; // column 0 (ones) is the rightmost grid column
  if (el.focus >= 0 && el.focus < columns - 1) node.append(place(h('div', { class: 'v-focus' }), gridColumn(el.focus), '1 / -1'));
  node.append(place(h('div', { class: 'v-digit v-operator' }, el.operator === '-' ? '−' : el.operator), 1, 3));
  node.append(place(h('div', { class: 'v-line' }), '1 / -1', 5));
  for (let column = 0; column < columns - 1; column++) {
    const x = gridColumn(column);
    const fresh = index => (index >= before ? ' pop' : ''); // written since the last update
    if (calc.borrows.has(column) && column - 1 < el.reveal) node.append(place(h('div', { class: `v-borrow${fresh(column - 1)}` }), x, 1));
    const top = shown(el.a, column), bottom = shown(el.b, column);
    if (top !== null) node.append(place(h('div', { class: 'v-digit' }, String(top)), x, 2));
    if (bottom !== null) node.append(place(h('div', { class: 'v-digit' }, String(bottom)), x, 3));
    if (calc.carries[column] && column - 1 < el.reveal) node.append(place(h('div', { class: `v-carry${fresh(column - 1)}` }, String(calc.carries[column])), x, 4));
    const result = column < el.reveal ? shown(calc.result, column) : null;
    if (result !== null) {
      const cell = place(h('div', { class: `v-digit v-result${fresh(column)}` }, String(result)), x, 6);
      cell.style.animationDelay = `${Math.max(0, column - before) * 0.15}s`;
      node.append(cell);
    }
  }
  return node;
}

function renderNumberLine(el, prev) {
  const width = 820, height = 190, left = 28, right = width - 28, axis = height - 46;
  const x = n => left + (right - left) * (n - el.from) / (el.to - el.from);
  const same = prev?.type === 'number_line' && prev.from === el.from && prev.to === el.to;
  const oldMarks = new Set(same ? prev.marks : []), oldJumps = same ? prev.jumps.length : 0;
  const root = s('svg', { class: 'b-number-line', viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': `数轴 ${el.from} 到 ${el.to}` });
  root.append(s('line', { class: 'n-axis', x1: left - 14, y1: axis, x2: right + 14, y2: axis }));
  for (let n = el.from; n <= el.to; n += el.step || 1) {
    root.append(s('line', { class: 'n-tick', x1: x(n), y1: axis - 10, x2: x(n), y2: axis + 10 }));
    root.append(s('text', { class: 'n-label', x: x(n), y: axis + 34 }, String(n)));
  }
  el.jumps.forEach((jump, index) => {
    const from = x(jump.from), to = x(jump.to), y = axis - 12;
    const rise = Math.min(90, Math.max(36, Math.abs(to - from) * 0.45));
    const fresh = index >= oldJumps ? ' draw' : '';
    root.append(s('path', { class: `n-jump${fresh}`, pathLength: 1, d: `M${from} ${y} Q${(from + to) / 2} ${y - rise * 1.6} ${to} ${y}` }));
    const back = to > from ? -1 : 1;
    root.append(s('path', { class: `n-jump n-head${fresh ? ' late' : ''}`, d: `M${to + back * 10} ${y - 10} L${to} ${y} L${to + back * 2} ${y - 14}` }));
    if (jump.label) root.append(s('text', { class: `n-jump-label${fresh ? ' late' : ''}`, x: (from + to) / 2, y: y - rise * 0.8 - 14 }, jump.label));
  });
  for (const n of el.marks) root.append(s('circle', { class: `n-mark${oldMarks.has(n) ? '' : ' pop'}`, cx: x(n), cy: axis, r: 9 }));
  return root;
}

function renderDots(el, prev) {
  const same = prev?.type === 'dots' && prev.groups === el.groups && prev.per === el.per;
  const node = h('div', { class: 'b-dots', role: 'img', 'aria-label': `${el.groups} 组，每组 ${el.per} 个` });
  const groups = h('div', { class: 'd-groups' });
  const columns = Math.min(6, el.per <= 4 ? el.per : Math.ceil(el.per / 2));
  for (let group = 0; group < el.groups; group++) {
    const lit = group < el.highlight;
    const box = h('div', { class: `d-group${lit ? ' lit' : ''}${same ? '' : ' pop'}` });
    box.style.setProperty('--per-row', columns);
    box.style.animationDelay = `${group * 0.08}s`;
    for (let dot = 0; dot < el.per; dot++) box.append(h('span', { class: 'd-dot' }));
    groups.append(box);
  }
  node.append(groups);
  if (el.label) node.append(h('div', { class: 'd-label' }, el.label));
  return node;
}

/** 线段图: every row shares one scale; an unknown part (value null) is drawn dashed with its label. */
function renderBar(el) {
  const known = el.rows.flatMap(row => row.parts).map(part => part.value).filter(value => value != null);
  const unknown = known.length ? known.reduce((sum, value) => sum + value, 0) / known.length : 1;
  const length = part => part.value ?? unknown;
  const longest = Math.max(...el.rows.map(row => row.parts.reduce((sum, part) => sum + length(part), 0)));
  const labelled = el.rows.some(row => row.label);
  const node = h('div', { class: `b-bar${labelled ? ' labelled' : ''}`, role: 'img', 'aria-label': '线段图' });
  if (el.total) node.append(h('div', { class: 'r-total' }, h('span', {}, el.total), h('div', { class: 'r-brace' })));
  el.rows.forEach((row, rowIndex) => {
    const line = h('div', { class: 'r-row' });
    if (labelled) line.append(h('div', { class: 'r-label' }, row.label));
    const track = h('div', { class: 'r-track' });
    row.parts.forEach((part, partIndex) => {
      const box = h('div', { class: `r-part${part.value == null ? ' unknown' : ''} c${(rowIndex + partIndex) % 5}` }, part.label);
      box.style.width = `${length(part) / longest * 100}%`;
      track.append(box);
    });
    line.append(track);
    node.append(line);
  });
  return node;
}

function renderClock(el) {
  const size = 240, c = size / 2, r = c - 6;
  const point = (fraction, length) => {
    const angle = fraction * 2 * Math.PI - Math.PI / 2;
    return [c + Math.cos(angle) * length, c + Math.sin(angle) * length];
  };
  const root = s('svg', { class: 'c-face', viewBox: `0 0 ${size} ${size}` });
  root.append(s('circle', { class: 'c-rim', cx: c, cy: c, r }));
  for (let tick = 0; tick < 60; tick++) {
    const [x1, y1] = point(tick / 60, r - (tick % 5 ? 7 : 14)), [x2, y2] = point(tick / 60, r - 3);
    root.append(s('line', { class: tick % 5 ? 'c-tick' : 'c-tick major', x1, y1, x2, y2 }));
  }
  for (let n = 1; n <= 12; n++) { const [x, y] = point(n / 12, r - 34); root.append(s('text', { class: 'c-number', x, y }, String(n))); }
  const [hx, hy] = point(((el.hour % 12) + el.minute / 60) / 12, r * 0.5), [mx, my] = point(el.minute / 60, r * 0.78);
  root.append(s('line', { class: 'c-hour', x1: c, y1: c, x2: hx, y2: hy }));
  root.append(s('line', { class: 'c-minute', x1: c, y1: c, x2: mx, y2: my }));
  root.append(s('circle', { class: 'c-pin', cx: c, cy: c, r: 7 }));
  const node = h('div', { class: 'b-clock', role: 'img', 'aria-label': `钟面 ${el.hour} 点 ${el.minute} 分` }, root);
  if (el.label) node.append(h('div', { class: 'c-label' }, el.label));
  return node;
}

const renderers = { text: renderText, vertical: renderVertical, number_line: renderNumberLine, dots: renderDots, bar: renderBar, clock: renderClock };

export class Whiteboard {
  #scroller; #content; #items = new Map(); // id → { el, node }

  /** `scroller` scrolls; `content` (inside it) holds the elements. */
  constructor(scroller, content) { this.#scroller = scroller; this.#content = content; }

  get empty() { return this.#items.size === 0; }

  /** Applies one segment's ops and scrolls to the last element they touched. */
  apply(ops) {
    let touched = null;
    for (const op of ops) {
      if (op?.op === 'clear') { this.clear(); touched = null; }
      else if (op?.op === 'remove') { this.#items.get(op.id)?.node.remove(); this.#items.delete(op.id); }
      else if ((op?.op === 'add' || op?.op === 'update') && op.el?.id && renderers[op.el.type]) touched = this.#upsert(op.el) ?? touched;
    }
    if (touched) this.#scrollTo(touched);
  }

  clear() { this.#items.clear(); this.#content.replaceChildren(); }

  #upsert(el) {
    const existing = this.#items.get(el.id);
    let node;
    try { node = renderers[el.type](el, existing?.el); } catch { return null; } // an element this page cannot draw
    const wrapper = h('div', { class: `b-item${existing ? '' : ' enter'}` }, node);
    wrapper.dataset.id = el.id;
    if (existing) existing.node.replaceWith(wrapper); else this.#content.append(wrapper);
    this.#items.set(el.id, { el, node: wrapper });
    return wrapper;
  }

  #scrollTo(node) {
    const top = node.offsetTop - (this.#scroller.clientHeight - node.offsetHeight) / 2;
    const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.#scroller.scrollTo({ top: Math.max(0, top), behavior: reduce ? 'auto' : 'smooth' });
  }
}
