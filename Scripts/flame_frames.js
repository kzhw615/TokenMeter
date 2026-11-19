// Canvas artwork used only to export the native PNG sequences.
// warm, hot and inferno adapt Chirag's Fire flame. See Assets/Flame-LICENSE.txt.
const tau = Math.PI * 2;
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
const celPoses = [
  { at: 0.0, knots: [
    [-0.476, -0.267, 0.0686, 0.1246, -0.1126, -0.2046],
    [-0.3025, -0.7424, 0.3149, 0.3487, -0.0691, -0.0765],
    [-0.0286, -0.9509, -0.0042, 0.137, 0.2354, 0.0923],
    [0.2019, -0.541, -0.6167, -0.2408, 0.1298, 0.0507],
    [0.4101, -0.2818, -0.2359, -0.1134, 0.2089, 0.1004],
    [0.4388, -0.0812, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 0.120974, knots: [
    [-0.3797, -0.2398, -0.0152, 0.0272, 0.2977, -0.1545],
    [-0.1683, -0.6542, -0.2824, 0.131, 0.1547, -0.0568],
    [-0.1803, -0.8682, 0.1222, 0.1114, 0.5285, 0.188],
    [0.1231, -0.5226, -0.2558, -0.1142, 0.202, 0.111],
    [0.4407, -0.2677, -0.0723, -0.0992, 0.0555, 0.0984],
    [0.4188, -0.0789, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2531, 0.0032],
  ] },
  { at: 0.201613, knots: [
    [-0.3286, -0.2099, 0.0588, 0.1419, -0.099, -0.2389],
    [-0.0529, -0.5963, 0.0636, 0.1156, -0.0434, -0.0788],
    [-0.1531, -0.797, -0.1471, 0.0782, -0.0203, 0.1222],
    [0.1998, -0.4231, 0.2486, -0.1866, -0.0816, 0.0612],
    [0.3855, -0.2503, -0.0968, -0.0646, 0.1656, 0.1106],
    [0.4388, -0.0812, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 0.322587, knots: [
    [-0.3484, -0.2286, -0.092, 0.1026, 0.357, -0.189],
    [-0.1693, -0.5417, -0.022, 0.0943, -0.0199, -0.1046],
    [0.0013, -0.6902, -0.0824, 0.057, 0.0184, 0.1176],
    [0.3047, -0.3646, -0.4453, -0.1969, 0.0306, 0.0346],
    [0.4176, -0.2109, -0.0352, -0.0378, 0.0352, 0.0378],
    [0.4159, -0.0754, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 0.403226, knots: [
    [-0.2538, -0.2328, -0.0806, 0.1514, -0.0308, -0.1572],
    [-0.0107, -0.481, -0.0791, 0.0801, -0.0043, -0.1217],
    [-0.1232, -0.6891, -0.0392, 0.0429, 0.0443, 0.1146],
    [0.2246, -0.3069, 0.0321, -0.2562, 0.0115, 0.0191],
    [0.3786, -0.1828, -0.1319, -0.0769, 0.0896, 0.0638],
    [0.4007, -0.0716, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 0.5242, knots: [
    [-0.2861, -0.2205, -0.1853, 0.034, 0.3598, -0.0881],
    [-0.1272, -0.5751, 0.0065, 0.1014, 0.0003, -0.0602],
    [-0.0117, -0.755, 0.012, 0.1099, 0.1017, 0.0569],
    [0.2654, -0.4749, -0.3795, -0.1062, 0.2455, 0.075],
    [0.3827, -0.2233, -0.1109, -0.0696, 0.1352, 0.0919],
    [0.4111, -0.077, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 0.604838, knots: [
    [-0.2774, -0.2132, 0.032, 0.1428, -0.0408, -0.1826],
    [-0.0496, -0.6424, 0.0636, 0.1156, -0.0434, -0.0788],
    [-0.0882, -0.874, -0.1471, 0.0782, -0.0107, 0.1611],
    [0.2212, -0.4767, 0.2064, -0.1403, -0.0787, 0.0535],
    [0.3855, -0.2503, -0.0968, -0.0646, 0.1656, 0.1106],
    [0.4181, -0.0806, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 0.725813, knots: [
    [-0.418, -0.2599, -0.0565, 0.1343, 0.1968, -0.1558],
    [-0.2461, -0.5783, -0.0622, 0.0576, 0.2372, -0.1595],
    [-0.1774, -0.9524, 0.3185, 0.2239, 0.6046, 0.2324],
    [0.1334, -0.5554, -0.1541, -0.1807, 0.0802, 0.1014],
    [0.5067, -0.2958, -0.1179, -0.072, 0.12, 0.0825],
    [0.4076, -0.0752, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1806, -0.0132, -0.233, -0.0128],
  ] },
  { at: 0.806451, knots: [
    [-0.4717, -0.3236, -0.1155, 0.1286, 0.3776, -0.212],
    [-0.1611, -0.724, 0.0057, 0.0964, 0.0455, -0.1147],
    [-0.089, -0.9836, 0.147, 0.1329, 0.3049, 0.0941],
    [0.2645, -0.5453, -0.3945, -0.2077, 0.1861, 0.1333],
    [0.4299, -0.2816, -0.1319, -0.0769, 0.0896, 0.0638],
    [0.4007, -0.0716, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 0.927426, knots: [
    [-0.2188, -0.2771, -0.2256, 0.1683, 0.1257, -0.105],
    [-0.1525, -0.6326, -0.1572, 0.1905, 0.1055, -0.1501],
    [-0.1898, -0.9146, 0.1215, 0.0899, 0.4458, 0.0888],
    [0.1638, -0.5117, -0.3064, -0.1094, 0.1509, 0.0817],
    [0.4647, -0.2405, 0.0136, -0.1126, 0.0029, 0.0788],
    [0.4245, -0.0776, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
  { at: 1.0, knots: [
    [-0.476, -0.267, 0.0686, 0.1246, -0.1126, -0.2046],
    [-0.3025, -0.7424, 0.3149, 0.3487, -0.0691, -0.0765],
    [-0.0286, -0.9509, -0.0042, 0.137, 0.2354, 0.0923],
    [0.2019, -0.541, -0.6167, -0.2408, 0.1298, 0.0507],
    [0.4101, -0.2818, -0.2359, -0.1134, 0.2089, 0.1004],
    [0.4388, -0.0812, 0.0759, -0.0391, -0.1551, 0.08],
    [-0.0025, -0.0016, 0.1483, -0.0149, -0.2294, 0.0138],
  ] },
];

function paint(ctx, path, top, bottom, stops) {
  const gradient = ctx.createLinearGradient(0, top, 0, bottom);
  for (const [offset, color] of stops) gradient.addColorStop(offset, color);
  ctx.fillStyle = gradient;
  ctx.fill(path);
}

// All four larger silhouettes share the same two colour ramps.
const shellColours = [[0, "#ffc55a"], [0.47, "#ff862d"], [0.8, "#f44b21"], [1, "#c82920"]];
const coreColours = [[0, "#ffe88e"], [0.42, "#ffc24d"], [0.82, "#ff912d"], [1, "#ff6e25"]];

function drawCalm(ctx, t) {
  const s = Math.sin(t);
  const base = 86;
  const tipX = 54 + s * 3;
  const tipY = 23;
  const p = new Path2D();
  p.moveTo(51, base);
  p.bezierCurveTo(36, base + 1, 26, base - 10, 30, base - 23);
  p.bezierCurveTo(33, base - 36, tipX - 8, tipY + 19, tipX, tipY);
  p.bezierCurveTo(tipX - 2, tipY + 18, 68, base - 46, 70, base - 26);
  p.bezierCurveTo(69, base - 8, 66, base + 1, 51, base);
  p.closePath();
  paint(ctx, p, tipY, base, [[0, "#ffc052"], [0.48, "#ff822c"], [0.79, "#f44b21"], [1, "#c32721"]]);
  const rise = Math.sin(t - 0.85);
  const coreTop = base - 30;
  const coreTip = 50 + (tipX - 50) * 0.65 + rise * 3;
  ctx.save();
  ctx.clip(p);
  paint(ctx, innerFlame(base - 3, coreTop, 51, coreTip, 12), coreTop, base,
    [[0, "#ffe682"], [0.52, "#ffbe4a"], [1, "#ff752c"]]);
  ctx.restore();
}

function innerFlame(base, top, middle, tip, width) {
  const height = base - top;
  const p = new Path2D();
  p.moveTo(middle, base);
  p.bezierCurveTo(middle - width * 0.85, base, middle - width, base - height * 0.17,
    middle - width * 0.91, base - height * 0.34);
  p.bezierCurveTo(middle - width * 0.72, base - height * 0.59, tip - width * 0.25, top + height * 0.23,
    tip, top);
  p.bezierCurveTo(tip - width * 0.06, top + height * 0.27, middle + width, base - height * 0.56,
    middle + width, base - height * 0.29);
  p.bezierCurveTo(middle + width, base - height * 0.11, middle + width * 0.5, base, middle, base);
  p.closePath();
  return p;
}

const warmOutline = [[-0.52381,-0.37209,-0.07143,0.21705,0.03929,-0.11938],[-0.2493,-0.69154,-0.12391,0.10648,0.10138,-0.08712],[0.04762,-1.0,-0.08571,0.12558,-0.01143,0.12651],[0.23123,-0.70427,-0.10224,-0.08379,0.11076,0.09077],[0.47619,-0.3876,-0.01238,-0.13705,0.0219,0.12124],[0.36739,-0.11094,0.08208,-0.0637,-0.09636,0.07478],[0.0,0.0,0.12857,0.0,-0.35714,0.0]];

// Warm's original four cubics, split at three points to correspond to the animated
// shoulder and tip. The lower knots keep their exact rounded contour.
const knotMotion = [0, 0.48, 0.54, 0.33, 0, 0, 0];

function familyKnots(phase) {
  const t = (phase % 1 + 1) % 1;
  const end = celPoses.findIndex(pose => pose.at > t);
  const a = celPoses[end - 1];
  const b = celPoses[end];
  const f = (t - a.at) / (b.at - a.at);
  return warmOutline.map((knot, j) => knot.map((v, k) => {
    if (k % 2 === 1) return v;
    const animated = a.knots[j][k] + (b.knots[j][k] - a.knots[j][k]) * f;
    return v + knotMotion[j] * (animated - v);
  }));
}

// A rolling swing followed by two broad sweeps in the fierce tier.
const lashBeats = [
  [[0, -0.82], [0.32, 1], [0.64, -1], [0.80, -0.53], [1, -0.82]],
  [[0, -0.96], [0.24, 1], [0.50, -0.92], [0.74, 0.85], [1, -0.96]],
];

function crosswind(tier, phase) {
  if (tier === 1) return Math.sin(phase * tau);
  const u = (phase % 1 + 1) % 1;
  const beats = lashBeats[tier - 2];
  const next = beats.findIndex(beat => beat[0] > u);
  const [t0, x0] = beats[next - 1];
  const [t1, x1] = beats[next];
  const p = (u - t0) / (t1 - t0);
  return x0 + (x1 - x0) * p * p * (3 - 2 * p);
}

// The bend travels from the shoulder to the tip. Both coordinates and tangent
// handles pass through the same horizontal warp; the base stays anchored.
function bend(tier, phase, level, amplitude) {
  const h = clamp((level - 0.16) / 0.84, 0, 1);
  const delay = tier === 3 ? 0.14 : 0.24;
  return amplitude * h * h * crosswind(tier, phase - delay * h);
}

// Each knot stores the vertex and its incoming and outgoing tangent offsets.
// Keep a common winding direction so overlapping tongues form one connected fill.
function flamePath(x, base, width, height, points, lean, tier, phase, amplitude) {
  const reverse = width < 0;
  const step = reverse ? -1 : 1;
  const incoming = reverse ? 4 : 2;
  const outgoing = reverse ? 2 : 4;
  const path = new Path2D();
  const screenX = (px, py) => x + width * px - lean * py + bend(tier, phase, -py, amplitude);
  path.moveTo(screenX(points[0][0], points[0][1]), base + height * points[0][1]);
  let j = 0;
  for (let k = 0; k < points.length; k++) {
    const next = (j + step + points.length) % points.length;
    const a = points[j];
    const b = points[next];
    path.bezierCurveTo(
      screenX(a[0] + a[outgoing], a[1] + a[outgoing + 1]), base + height * (a[1] + a[outgoing + 1]),
      screenX(b[0] + b[incoming], b[1] + b[incoming + 1]), base + height * (b[1] + b[incoming + 1]),
      screenX(b[0], b[1]), base + height * b[1]
    );
    j = next;
  }
  path.closePath();
  return path;
}

// The fierce tongues also supply the release point for each spark.
const fierceJets = [
  { x: 44, base: 82, width: -32, height: 60, shapePhase: 0.23, lean: -15, swingPhase: 0.14, amplitude: 10, release: 0.34 },
  { x: 56, base: 83, width: -28, height: 54, shapePhase: 0.18, lean: 17, swingPhase: 0.23, amplitude: 9, release: 0.67 },
];

function drawCartoon(ctx, tier, u) {
  const single = tier === 1;
  const triple = tier === 3;
  const height = single ? 72 : triple ? 82 : 77;
  const width = single ? 50 : triple ? 62 : 55;
  const amplitude = single ? 8 : triple ? 26 : 19;
  const base = single ? 89 : triple ? 91 : 90;
  const flow = u + (triple ? 0.56 : single ? 0.59 : 0.70);
  const main = familyKnots(flow);
  const top = base + height * main[2][1];
  const shell = flamePath(51, base, width, height, main, 0, tier, u, amplitude);
  if (tier === 2) {
    shell.addPath(flamePath(44, base - 9, -32, 50, familyKnots(u + 0.23), -15,
      tier, u + 0.14, 8));
  }
  if (triple) {
    for (const jet of fierceJets) {
      shell.addPath(flamePath(jet.x, jet.base, jet.width, jet.height, familyKnots(u + jet.shapePhase),
        jet.lean, tier, u + jet.swingPhase, jet.amplitude));
    }
  }

  paint(ctx, shell, top, base, shellColours);
  ctx.save();
  ctx.clip(shell);
  const coreTop = base - height * (triple ? 0.58 : 0.54);
  const coreTip = 52 + amplitude * 0.46 * crosswind(tier, u - 0.08);
  const coreWidth = width * 0.253;
  paint(ctx, innerFlame(base - 4, coreTop, 50.5, coreTip, coreWidth), coreTop, base, coreColours);
  ctx.restore();
}

// Each curl is born on the shoulder and travels up the same continuous outline.
const curls = [
  { born: 0.00, life: 0.66, side: -1, span: 0.23, force: 1.18, flakes: 5 },
  { born: 0.18, life: 0.65, side:  1, span: 0.20, force: 0.94, flakes: 2 },
  { born: 0.40, life: 0.51, side: -1, span: 0.17, force: 0.78, flakes: 3 },
  { born: 0.68, life: 0.62, side: -1, span: 0.21, force: 1.07, flakes: 2 },
  { born: 0.79, life: 0.59, side:  1, span: 0.23, force: 1.06, flakes: 5 },
];
const wrap = phase => phase - Math.floor(phase);
function smoothUnit(n) {
  const t = clamp(n, 0, 1);
  return t * t * (3 - 2 * t);
}
function risingCurls(u) {
  const active = [];
  for (const curl of curls) {
    const age = wrap(u - curl.born) / curl.life;
    if (age >= 1) continue;
    const level = -0.14 + 1.30 * age;
    const strength = curl.force * smoothUnit((level + 0.04) / 0.25)
      * smoothUnit((0.94 - level) / 0.34);
    active.push({ ...curl, level, strength });
  }
  return active;
}

// Cubic offsets across one fold: full outer lip, pointed crest, hollow behind it.
const foldShape = [
  [-1, -0.14, [0, 0], [0.02, 0], [0.52, -0.42], [0.45, -1.18]],
  [-0.14, 0.36, [0.45, -1.18], [0.42, -0.70], [-0.57, 0.46], [-0.73, 0.22]],
  [0.36, 1, [-0.73, 0.22], [-0.70, 0], [-0.10, 0], [0, 0]],
];
function contourPoint(h, side, u, active, relief) {
  const drift = 14 * h * h + h * (5 * Math.sin(tau * (3 * u - h * 0.85))
    + 2.4 * Math.sin(tau * (u - h * 0.64)));
  let x = 49 + drift + side * 31 * Math.cos(h * Math.PI / 2) ** 1.35;
  let y = 64 - 53 * h;
  for (const curl of active) {
    if (curl.side !== side) continue;
    const r = (h - curl.level) / curl.span;
    if (r <= -1 || r >= 1) continue;
    const [lo, hi, a, b, c, d] = foldShape.find(part => r <= part[1]);
    const t = (r - lo) / (hi - lo), v = 1 - t;
    const amp = curl.strength * relief * smoothUnit(h / 0.15) * smoothUnit((1 - h) / 0.14);
    const cubic = k => v*v*v*a[k] + 3*v*v*t*b[k] + 3*v*t*t*c[k] + t*t*t*d[k];
    const lift = amp * cubic(1);
    x += side * 10 * amp * cubic(0) - 3.7 * lift;
    y += 13 * lift;
  }
  return [x, y];
}

function plumePath(u, relief) {
  const active = risingCurls(u);
  const shell = new Path2D();
  shell.moveTo(18, 64);
  for (const side of [-1, 1]) {
    // Include the exact crease knots to keep small travelling points crisp.
    const levels = Array.from({length: 45}, (_, i) => i / 44);
    for (const curl of active) {
      if (curl.side !== side) continue;
      for (const knot of [-1, -0.14, 0.36, 1]) {
        const h = curl.level + curl.span * knot;
        if (h > 0 && h < 1) levels.push(h);
      }
    }
    levels.sort((a, b) => -side * (a - b));
    for (const h of levels) shell.lineTo(...contourPoint(h, side, u, active, relief));
  }
  shell.bezierCurveTo(80, 81, 68, 92, 49, 92);
  shell.bezierCurveTo(31, 92, 18, 82, 18, 64);
  shell.closePath();
  return shell;
}

// Ember positions come from the crest at release, even if travel crosses the loop boundary.
const sparkFan = [
  { delay: 0, life: 0.27, dx: 21, rise: 16, size: 2.6 },
  { delay: 0.018, life: 0.31, dx: 10, rise: 25, size: 2.0 },
  { delay: 0.042, life: 0.23, dx: 25, rise: 10, size: 1.45 },
  { delay: 0.10, life: 0.29, dx: 6, rise: 19, size: 1.7 },
  { delay: 0.14, life: 0.21, dx: 15, rise: 8, size: 1.3 },
];
function makeSpark(born, x, y, side, flake, index) {
  return { born, x, y, index, life: flake.life, size: flake.size,
    dx: clamp(x + side * flake.dx + 3, 8, 92) - x, rise: Math.min(y - 8, flake.rise) };
}
const fierceSparks = fierceJets.flatMap(jet => sparkFan.slice(0, 3).map((flake, index) => {
  const born = wrap(jet.release + flake.delay);
  const [px, py] = familyKnots(born + jet.shapePhase)[2];
  const x = jet.x + jet.width * px - jet.lean * py + bend(3, born + jet.swingPhase, -py, jet.amplitude);
  return makeSpark(born, x, jet.base + jet.height * py, Math.sign(jet.lean), flake, index);
}));
const burstSparks = curls.flatMap(curl => sparkFan.slice(0, curl.flakes).map((flake, index) => {
  const age = 0.48 + flake.delay;
  const born = wrap(curl.born + age * curl.life);
  const h = -0.14 + 1.30 * age - 0.14 * curl.span;
  const [x, y] = contourPoint(h, curl.side, born, risingCurls(born), 1);
  return makeSpark(born, x, y, curl.side, flake, index);
}));

function drawSparks(ctx, u, sizePt, sparks) {
  const limit = sizePt <= 13 ? 3 : sizePt <= 32 ? 4 : sparkFan.length;
  for (const s of sparks) {
    const age = wrap(u - s.born) / s.life;
    if (age < 0 || age >= 1 || s.index >= limit) continue;
    const travel = 1 - (1 - age) ** 2.7;
    const lift = 2.3 * age - 1.3 * age * age;
    const x = s.x + s.dx * travel, y = s.y - s.rise * lift;
    const angle = Math.atan2(-s.rise * (2.3 - 2.6 * age), s.dx * 2.7 * (1 - age) ** 1.7);
    const fade = Math.min(1, (1 - age) / 0.34);
    const radius = s.size * (sizePt <= 13 ? 1.48 : 1) * (0.62 + 0.38 * fade);
    const length = radius * (1.45 + 1.45 * (1 - age));
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(angle);
    ctx.globalAlpha = fade;
    ctx.fillStyle = s.index === 0 || s.index === 3 ? "#ffb441" : "#ffdb74";
    ctx.beginPath();
    ctx.moveTo(-length, 0);
    ctx.quadraticCurveTo(length * 0.35, -radius * 1.7, length * 0.8, -radius * 0.48);
    ctx.quadraticCurveTo(length * 1.35, radius * 0.9, -length, 0);
    ctx.fill();
    ctx.restore();
  }
}

function drawBurst(ctx, u) {
  const shell = plumePath(u, 1);
  paint(ctx, shell, 11, 92, shellColours);
  ctx.save();
  ctx.clip(shell);
  ctx.translate(49, 88);
  ctx.scale(0.58, 0.60);
  ctx.translate(-49, -92);
  paint(ctx, plumePath(wrap(u + 0.044), 0.30), 11, 92, coreColours);
  ctx.restore();
}

function renderFlameFrame(canvas, tier, phase, sizePt) {
  const ctx = canvas.getContext("2d");
  ctx.resetTransform();
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.scale(canvas.width / 100, canvas.height / 100);
  if (tier === 0) drawCalm(ctx, phase * tau);
  else if (tier === 4) drawBurst(ctx, phase);
  else drawCartoon(ctx, tier, phase);
  if (tier >= 3) {
    drawSparks(ctx, phase, sizePt, tier === 3 ? fierceSparks : burstSparks);
  }
}
