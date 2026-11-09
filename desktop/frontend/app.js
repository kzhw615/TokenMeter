/* TokenMeter Desktop 前端：通过 Tauri sidecar 调用 tokenmeter CLI 渲染面板 */
const { invoke } = window.__TAURI__.core;

const RANGES = [
  { id: "today", label: "今天" }, { id: "yesterday", label: "昨天" },
  { id: "7d", label: "近 7 天" }, { id: "30d", label: "近 30 天" },
  { id: "thisMonth", label: "本月" }, { id: "lastMonth", label: "上月" },
  { id: "all", label: "全部" },
];
const CALIBERS = [{ id: true, label: "含缓存" }, { id: false, label: "不含缓存" }];
const THEMES = {
  teal: { primary: "#14b8a6", palette: ["#14b8a6", "#3b82f6", "#f97316", "#a855f7", "#ec4899", "#34d399", "#eab308", "#6366f1"] },
  blue: { primary: "#3b82f6", palette: ["#3b82f6", "#06b6d4", "#6366f1", "#14b8a6", "#a855f7", "#34d399", "#f97316", "#ec4899"] },
  purple: { primary: "#a855f7", palette: ["#a855f7", "#6366f1", "#ec4899", "#3b82f6", "#14b8a6", "#f97316", "#34d399", "#eab308"] },
  green: { primary: "#22c55e", palette: ["#22c55e", "#34d399", "#14b8a6", "#3b82f6", "#eab308", "#f97316", "#ec4899", "#6366f1"] },
  orange: { primary: "#f97316", palette: ["#f97316", "#eab308", "#ef4444", "#ec4899", "#a855f7", "#3b82f6", "#14b8a6", "#34d399"] },
  pink: { primary: "#ec4899", palette: ["#ec4899", "#a855f7", "#ef4444", "#f97316", "#eab308", "#6366f1", "#3b82f6", "#14b8a6"] },
};
const FLAME_SVG = "data:image/svg+xml;utf8," + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#f97316" d="M12 2c1 4-4 6-4 11a4.5 4.5 0 0 0 9 0c0-2-1-3.5-2-5-.5 1.5-1.5 2-2 2 .5-2 0-5-1-8z"/></svg>');

const state = {
  range: "today", includeCache: true, theme: localStorage.theme || "teal",
  summary: null, burning: false, burnSources: [], rate: null,
  samples: [],
};

// ---------- 格式化 ----------
const fmtTokens = (n) => {
  const v = Number(n);
  if (Math.abs(v) >= 1e8) return (v / 1e8).toFixed(2) + "亿";
  if (Math.abs(v) >= 1e4) return (v / 1e4).toFixed(1) + "万";
  return String(Math.round(v));
};
const fmtCompact = (n) => {
  const v = Number(n);
  if (Math.abs(v) >= 1e8) return (v / 1e8).toFixed(1) + "亿";
  if (Math.abs(v) >= 1e6) return (v / 1e6).toFixed(1) + "M";
  if (Math.abs(v) >= 1e3) return (v / 1e3).toFixed(1) + "K";
  return String(Math.round(v));
};
const fmtCost = (c) => (c >= 1000 ? "$" + c.toFixed(0) : c >= 100 ? "$" + c.toFixed(1) : "$" + c.toFixed(2));
const fmtPct = (p) => (p * 100).toFixed(1) + "%";
const disp = (c) => (state.includeCache ? c.input + c.output + c.cacheRead + c.cacheWrite : c.input + c.output);

// ---------- 选项卡（滑动拇指） ----------
function buildTabs(el, items, current, onPick) {
  el.innerHTML = '<span class="thumb"></span>';
  items.forEach((it) => {
    const b = document.createElement("button");
    b.textContent = it.label;
    b.dataset.on = String(it.id === current);
    if (it.id === current) b.classList.add("on");
    b.onclick = () => onPick(it.id);
    el.appendChild(b);
  });
  moveThumb(el);
}
function moveThumb(el) {
  const on = el.querySelector("button.on");
  const thumb = el.querySelector(".thumb");
  if (!on || !thumb) return;
  thumb.style.left = on.offsetLeft + "px";
  thumb.style.width = on.offsetWidth + "px";
}
function setActive(el, id, items) {
  el.querySelectorAll("button").forEach((b, i) => b.classList.toggle("on", items[i].id === id));
  moveThumb(el);
}

// ---------- 渲染 ----------
function rows(container, list, totalDisp, showSub) {
  container.innerHTML = "";
  if (!list.length) { container.innerHTML = '<div class="muted">（无数据）</div>'; return; }
  list.forEach((it, idx) => {
    const color = THEMES[state.theme].palette[idx % 8];
    const share = totalDisp > 0 ? disp(it.counts) / totalDisp : 0;
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML =
      `<span class="name" title="${it.name}">${it.name}</span>` +
      `<span class="bar"><i style="width:${Math.max(1.5, share * 100)}%;background:${color}"></i></span>` +
      `<span class="num">${fmtTokens(disp(it.counts))}</span>` +
      `<span class="pct">${fmtPct(share)}</span>` +
      `<span class="cost">${fmtCost(it.cost)}</span>`;
    container.appendChild(row);
    if (showSub && it.sub) {
      const sub = document.createElement("div");
      sub.className = "sub";
      sub.textContent = it.sub;
      container.appendChild(sub);
    }
  });
}

function chart(container, data, labelFn, valueFn) {
  container.innerHTML = "";
  const max = Math.max(1, ...data.map(valueFn));
  data.forEach((d) => {
    const col = document.createElement("div");
    col.className = "col";
    const v = valueFn(d);
    col.innerHTML = `<i style="height:${(v / max) * 100}%"></i>`;
    col.onmouseenter = (e) => showTip(e, labelFn(d), v, d.cost);
    col.onmousemove = (e) => moveTip(e);
    col.onmouseleave = hideTip;
    container.appendChild(col);
  });
}

const tip = () => document.getElementById("tooltip");
function showTip(e, title, tokens, cost) {
  const t = tip();
  t.innerHTML = `<div class="muted">${title}</div><b>${fmtTokens(tokens)} tokens</b><div class="muted">${fmtCost(cost || 0)}</div>`;
  t.classList.remove("hidden");
  moveTip(e);
}
function moveTip(e) {
  const t = tip();
  t.style.left = Math.min(e.clientX + 12, window.innerWidth - 150) + "px";
  t.style.top = Math.max(4, e.clientY - 70) + "px";
}
function hideTip() { tip().classList.add("hidden"); }

function render() {
  const s = state.summary;
  document.documentElement.style.setProperty("--accent", THEMES[state.theme].primary);
  if (!s) return;
  document.getElementById("card-total-title").textContent = state.includeCache ? "用量（含缓存）" : "用量（不含缓存）";
  document.getElementById("v-total").textContent = fmtTokens(disp(s.counts));
  document.getElementById("s-total").textContent = `输入 ${fmtTokens(s.counts.input)}\n输出 ${fmtTokens(s.counts.output)}`;
  document.getElementById("v-cost").textContent = fmtCost(s.cost);
  document.getElementById("s-cost").textContent = `缓存读 ${fmtTokens(s.counts.cacheRead)}\n缓存写 ${fmtTokens(s.counts.cacheWrite)}`;
  document.getElementById("v-hit").textContent = fmtPct(s.cacheHitRate);
  document.getElementById("s-req").textContent = `${s.requests} 次调用`;

  const tTot = s.tools.reduce((a, t) => a + disp(t.counts), 0);
  rows(document.getElementById("tools"), s.tools.map((t) => ({ name: t.tool, counts: t.counts, cost: t.cost })), tTot, false);
  const mTot = s.models.reduce((a, t) => a + disp(t.counts), 0);
  rows(document.getElementById("models"), s.models.slice(0, 10).map((m) => ({ name: m.model, counts: m.counts, cost: m.cost, sub: m.tools.join(" · ") })), mTot, true);
  const pList = s.projects.slice(0, 8).map((p) => ({ name: p.project === "-" ? "未归属" : p.project, counts: p.counts, cost: p.cost }));
  const pTot = s.projects.reduce((a, t) => a + disp(t.counts), 0);
  rows(document.getElementById("projects"), pList, pTot, false);

  chart(document.getElementById("days"), s.trendDays, (d) => d.day, (d) => disp(d.counts));
  document.getElementById("hours-title").textContent = "逐小时用量 · " + s.hoursMode;
  chart(document.getElementById("hours"), s.hours, (h) => `${String(h.hour).padStart(2, "0")}:00–${String(h.hour).padStart(2, "0")}:59`, (h) => disp(h.counts));

  const burn = document.getElementById("burning");
  if (state.burning) {
    burn.classList.remove("hidden");
    document.getElementById("flame-img").src = FLAME_SVG;
    document.getElementById("burning-src").textContent =
      state.burnSources.join(", ") + (state.rate ? ` · ${fmtCompact(state.rate)}/s` : "");
  } else burn.classList.add("hidden");
  invoke("set_tray_flame", { flame: state.burning }).catch(() => {});
}

// ---------- 数据 ----------
async function load() {
  try {
    const out = await invoke("run_cli", { args: ["report", "--json", "--range", state.range] });
    state.summary = JSON.parse(out);
    render();
    document.getElementById("updated").textContent = "更新 " + new Date().toLocaleTimeString("zh-CN", { hour12: false });
  } catch (e) {
    document.getElementById("updated").textContent = "加载失败: " + e;
  }
}
async function pollActivity() {
  try {
    const out = await invoke("run_cli", { args: ["activity", "--json"] });
    const a = JSON.parse(out);
    state.burning = a.burning;
    state.burnSources = a.sources || [];
    if (a.burning) {
      const today = await invoke("run_cli", { args: ["report", "--json", "--range", "today"] });
      const s = JSON.parse(today);
      const total = s.counts.input + s.counts.output + s.counts.cacheRead + s.counts.cacheWrite;
      const now = Date.now();
      state.samples.push([now, total]);
      state.samples = state.samples.filter((x) => now - x[0] < 150000);
      if (state.samples.length >= 2) {
        const [t0, v0] = state.samples[0];
        const [t1, v1] = state.samples[state.samples.length - 1];
        if (t1 > t0 && t1 - t0 >= 30000) state.rate = Math.max(0, (v1 - v0) / ((t1 - t0) / 1000));
      }
    } else {
      state.samples = [];
      state.rate = null;
    }
    render();
  } catch (_) {}
}

// ---------- 初始化 ----------
buildTabs(document.getElementById("range-tabs"), RANGES, state.range, (id) => {
  state.range = id;
  setActive(document.getElementById("range-tabs"), id, RANGES);
  load();
});
buildTabs(document.getElementById("caliber-tabs"), CALIBERS, state.includeCache, (id) => {
  state.includeCache = id;
  setActive(document.getElementById("caliber-tabs"), id, CALIBERS);
  render();
});
const themesEl = document.getElementById("themes");
Object.entries(THEMES).forEach(([id, t]) => {
  const b = document.createElement("button");
  b.style.background = t.primary;
  b.className = id === state.theme ? "on" : "";
  b.onclick = () => {
    state.theme = id;
    localStorage.theme = id;
    themesEl.querySelectorAll("button").forEach((x) => x.classList.remove("on"));
    b.classList.add("on");
    render();
  };
  themesEl.appendChild(b);
});
document.getElementById("btn-refresh").onclick = load;
document.getElementById("btn-quit").onclick = () => invoke("quit_app").catch(() => window.close());
window.addEventListener("resize", () => {
  moveThumb(document.getElementById("range-tabs"));
  moveThumb(document.getElementById("caliber-tabs"));
});

load();
pollActivity();
setInterval(load, 300000);
setInterval(pollActivity, 15000);
