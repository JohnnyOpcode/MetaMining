/* MetaMining claim map: SSE stream, canvas scatter, telemetry. No build step. */
(function () {
  "use strict";

  var BRANCH_COLORS = [
    "#4cc2a8", "#d0684b", "#9dbb65", "#6aa8d8",
    "#d8739b", "#d9b23b", "#8fa0b8", "#c77e3f",
  ];
  var GOLD = "#e8b34e";
  var reducedMotion = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  if (window.htmx) {
    try { htmx.config.selfRequestsOnly = true; } catch (e) {}
  }
  /* Event-driven fragment refresh: SSE findings/state kick a throttled
     mm:poll (morph-swapped); the 12s hx-trigger poll is only a fallback. */
  var FRAGS = ["stats", "threads", "gold"];
  var pollLast = 0, pollTimer = 0, advLast = 0;
  function pollFire() {
    pollLast = Date.now();
    try {
      if (window.htmx) {
        for (var i = 0; i < FRAGS.length; i++) htmx.trigger("#" + FRAGS[i], "mm:poll");
      }
      /* Adv panels (veins/queue/tree) refresh at most every 5s: they are
         slower-moving than the morph fragments and cost 4 fetches. */
      if (Date.now() - advLast >= 5000) {
        advLast = Date.now();
        document.body.dispatchEvent(new CustomEvent("mm:adv"));
      }
    } catch (e) {}
  }
  function pollKick() {
    if (Date.now() - pollLast < 1500) {
      if (!pollTimer) pollTimer = setTimeout(function () { pollTimer = 0; pollFire(); }, 1500);
      return;
    }
    pollFire();
  }

  /* Server auth token (--auth-token): persisted locally, injected into
     every API call. htmx/fetch use the X-MM-Token header; EventSource
     (no custom headers) uses ?token=. */
  function mmToken() {
    try { return localStorage.getItem("mm_token") || ""; } catch (e) { return ""; }
  }
  var authFailAt = 0;
  function authFail() {
    var now = Date.now();
    if (now - authFailAt < 10000) return;
    authFailAt = now;
    toast("Server needs its auth token — enter it in Server token", false, true);
    var f = document.getElementById("server-token");
    if (f && f.focus) { try { f.focus(); } catch (e) {} }
  }
  (function wrapFetch() {
    try {
      if (!window.fetch || window.fetch.__mmWrapped) return;
      var native = window.fetch.bind(window);
      var wrapped = function (url, opts) {
        var t = mmToken();
        var o = opts || {};
        if (t) {
          o = Object.assign({}, o);
          try {
            var h = new Headers(o.headers || {});
            h.set("X-MM-Token", t);
            o.headers = h;
          } catch (e) {}
        }
        return native(url, o).then(function (r) {
          if (r && r.status === 401) authFail();
          return r;
        });
      };
      wrapped.__mmWrapped = true;
      window.fetch = wrapped;
    } catch (e) {}
  })();
  var pings = [];
  var fedKeys = {};
  var fxActive = false;
  var fxLastDraw = 0;
  function fxKick() {
    if (fxActive || reducedMotion) return;
    fxActive = true;
    requestAnimationFrame(fxTick);
  }
  function fxTick() {
    fxActive = false;
    var now = performance.now();
    for (var i = pings.length - 1; i >= 0; i--) {
      if (now - pings[i].t0 >= 950) pings.splice(i, 1);
    }
    var running = !!(lastState && lastState.running);
    if (pings.length === 0 && !running) return;
    if (now - fxLastDraw >= 40) {
      fxLastDraw = now;
      if (isLive()) drawScatter();
      drawTelemetry();
    }
    fxActive = true;
    requestAnimationFrame(fxTick);
  }

  var points = [];
  var teleNov = [];
  var teleCoh = [];
  var teleGold = [];
  var teleB0 = [];
  var teleB1 = [];
  var teleB2 = [];
  var currentRun = -1;
  var goldThreshold = 0.9;
  var branchesSeen = {};
  var viewMode = "2d";
  var cam3 = { yaw: 0.78, pitch: 0.52, zoom: 1.0, dist: 3.8, auto: false };
  var mode3d = "surface";
  var metric3d = "novelty";
  var mapped3 = [];
  var pulse3 = 0;
  var raf3 = 0;
  var showTrails = true;
  var showBalls3d = true;
  var showGold3d = true;
  function ballVisible3d(item) {
    try {
      var g = item.pn && item.pn.data && item.pn.data.p && item.pn.data.p.gold;
      return g ? showGold3d : showBalls3d;
    } catch (e) { return true; }
  }
  var scrubIdx = -1;
  var playing = true;
  var branchHidden = {};
  var goldOnly = false;
  var seenKeys = {};
  var findingByKey = {};
  var sysLines = [];
  var feedSearch = "";
  var feedFilter = "all";
  var lastState = null;
  var tuneDragging = {};
  var modalBranch = -1, modalStep = -1;
  var PERSONAS = [
    "Mechanistic Systems Biology & Network Medicine",
    "Nonlinear Dynamics & Bifurcation Theory",
    "Information Theory & Algorithmic Complexity",
    "Persistent Homology & Latent Topology",
    "Synthetic Epigenetics & Bio-Computing",
    "Thermodynamics of Complex Adaptive Systems",
    "Surrealist Cybernetics & Cognitive Architecture",
    "Fungal & Mycelial Network Architectures",
    "Quantum Information & Coherence Dynamics",
    "Crystalline Semiotics & Structural Linguistics",
    "Deep-Sea Abyssal Xenobiology",
    "Evolutionary Game Theory & Niche Construction",
    "Non-Euclidean Spatial Morphologies",
    "Material Science & Metamaterial Engineering",
    "Category Theory & Conceptual Translation",
    "Biomimetic Energy Dynamics"
  ];

  function personaName(idx) {
    return (typeof idx === "number" && idx >= 0 && idx < PERSONAS.length) ? PERSONAS[idx] : "Persona " + idx;
  }

  var scatter = document.getElementById("scatter");
  var telemetry = document.getElementById("telemetry");
  var tip = document.getElementById("tip");
  var logEl = document.getElementById("log");
  var pill = document.getElementById("run-pill");
  var runLabel = document.getElementById("run-label");
  var backendLabel = document.getElementById("backend-label");
  var legend = document.getElementById("legend");

  function colorFor(branch) {
    return BRANCH_COLORS[branch % BRANCH_COLORS.length];
  }

  function fitCanvas(cv) {
    var r = cv.getBoundingClientRect();
    var dpr = window.devicePixelRatio || 1;
    cv.width = Math.max(1, Math.round(r.width * dpr));
    cv.height = Math.max(1, Math.round(r.height * dpr));
    return dpr;
  }

  function isLive() { return scrubIdx < 0 || scrubIdx >= points.length; }

  function visiblePoints() {
    var end = isLive() ? points.length : Math.min(scrubIdx, points.length);
    var out = [];
    for (var i = 0; i < end; i++) {
      var p = points[i];
      if (goldOnly && !p.gold) continue;
      if (branchHidden[p.branch]) continue;
      out.push(p);
    }
    return out;
  }

  /* ---- W2: 3D topology engine (Canvas2D, perspective) ---- */

  function project3d(wx, wy, wz, W, H, dpr) {
    var cx = wx, cy = wy, cz = wz - 0.45;
    var cosY = Math.cos(cam3.yaw), sinY = Math.sin(cam3.yaw);
    var rx1 = cx * cosY - cy * sinY;
    var ry1 = cx * sinY + cy * cosY;
    var rz1 = cz;
    var cosP = Math.cos(cam3.pitch), sinP = Math.sin(cam3.pitch);
    var rx2 = rx1;
    var ry2 = ry1 * cosP - rz1 * sinP;
    var rz2 = ry1 * sinP + rz1 * cosP;
    var camDist = cam3.dist / cam3.zoom;
    var depth = ry2 + camDist;
    if (depth <= 0.15) return null;
    var fov = 380 * dpr;
    return {
      x: W / 2 + (rx2 * fov) / depth,
      y: H / 2 - (rz2 * fov) / depth,
      depth: depth,
      scale: ((fov / depth) / dpr) / 100
    };
  }

  function zRaw(p) {
    if (metric3d === "pca_z") return num(p.z, 50);
    if (metric3d === "cd") return (typeof p.cd === "number" && !isNaN(p.cd)) ? p.cd : 1.0;
    if (metric3d === "coherence") return num(p.coherence, 0);
    if (metric3d === "density") return num(p._dens, num(p.novelty, 0));
    return num(p.novelty, 0);
  }

  function zNorm(p, zMin, zMax) {
    var v = zRaw(p), w;
    if (metric3d === "pca_z") {
      var span = Math.max(zMax - zMin, 0.001);
      w = ((v - zMin) / span) * 0.86 + 0.08;
    } else if (metric3d === "cd") {
      w = ((v - 1.0) / 2.5) * 0.86 + 0.08;
    } else if (metric3d === "coherence") {
      w = ((v - 1.0) / 9.0) * 0.86 + 0.08;
    } else {
      w = v;
    }
    if (p.gold && metric3d === "novelty" && w < 0.88) w = 0.88;
    if (w < 0.06) w = 0.06;
    if (w > 0.96) w = 0.96;
    return w;
  }

  /* Gaussian KDE over the visible set for the 3D density metric. The shape
     lab computes _dens only for its own view, so the 3D plot ensures it
     here; cached on set identity (count + first/last key) since points
     only append. Without this, density silently plotted novelty. */
  var dens3Key = "";
  function ensureDens3(pts) {
    if (!pts || pts.length === 0) return;
    var key = pts.length + ":" + fkey(pts[0]) + "/" + fkey(pts[pts.length - 1]);
    if (key === dens3Key) return;
    dens3Key = key;
    var n = SHAPE_DN, bw = SHAPE_BW, grid = new Float64Array(n * n);
    var cell = 100 / (n - 1), rad = Math.ceil((bw * 3) / cell);
    var i, gx, gy;
    for (i = 0; i < pts.length; i++) {
      if (typeof pts[i].x !== "number" || typeof pts[i].y !== "number") continue;
      var px = (pts[i].x / 100) * (n - 1), py = (1 - pts[i].y / 100) * (n - 1);
      var x0 = Math.max(0, Math.floor(px - rad)), x1 = Math.min(n - 1, Math.ceil(px + rad));
      var y0 = Math.max(0, Math.floor(py - rad)), y1 = Math.min(n - 1, Math.ceil(py + rad));
      for (gy = y0; gy <= y1; gy++) for (gx = x0; gx <= x1; gx++) {
        var dx = (gx - px) * cell, dy = (gy - py) * cell;
        grid[gy * n + gx] += Math.exp(-(dx * dx + dy * dy) / (2 * bw * bw));
      }
    }
    var mx = 0;
    for (i = 0; i < grid.length; i++) if (grid[i] > mx) mx = grid[i];
    if (mx > 0) for (i = 0; i < grid.length; i++) grid[i] /= mx;
    for (i = 0; i < pts.length; i++) {
      if (typeof pts[i].x !== "number" || typeof pts[i].y !== "number") continue;
      var qx = (pts[i].x / 100) * (n - 1), qy = (1 - pts[i].y / 100) * (n - 1);
      var ix = Math.max(0, Math.min(n - 2, Math.floor(qx))), iy = Math.max(0, Math.min(n - 2, Math.floor(qy)));
      var fx = Math.max(0, Math.min(1, qx - ix)), fy = Math.max(0, Math.min(1, qy - iy));
      pts[i]._dens = grid[iy * n + ix] * (1 - fx) * (1 - fy) + grid[iy * n + ix + 1] * fx * (1 - fy) +
        grid[(iy + 1) * n + ix] * (1 - fx) * fy + grid[(iy + 1) * n + ix + 1] * fx * fy;
    }
  }

  function pal3(metric, t, shade, alpha) {
    var u = Math.max(0, Math.min(1, t)), r = 0, g = 0, b = 0, k;
    function ramp(stops) {
      for (var s = 0; s < stops.length - 1; s++) {
        if (u <= stops[s + 1][0] || s === stops.length - 2) {
          k = (u - stops[s][0]) / Math.max(stops[s + 1][0] - stops[s][0], 0.001);
          if (k < 0) k = 0;
          if (k > 1) k = 1;
          r = Math.round(stops[s][1] + k * (stops[s + 1][1] - stops[s][1]));
          g = Math.round(stops[s][2] + k * (stops[s + 1][2] - stops[s][2]));
          b = Math.round(stops[s][3] + k * (stops[s + 1][3] - stops[s][3]));
          return;
        }
      }
    }
    if (metric === "novelty") ramp([[0, 6, 20, 55], [0.25, 16, 140, 235], [0.6, 136, 210, 200], [0.84, 255, 30, 80], [1, 255, 200, 0]]);
    else if (metric === "pca_z") ramp([[0, 15, 12, 60], [0.25, 20, 92, 180], [0.6, 0, 212, 200], [0.84, 220, 232, 30], [1, 255, 172, 0]]);
    else if (metric === "cd") ramp([[0, 30, 8, 50], [0.25, 80, 28, 180], [0.6, 200, 0, 220], [0.84, 255, 140, 60], [1, 255, 220, 0]]);
    else ramp([[0, 55, 10, 25], [0.25, 75, 70, 135], [0.6, 0, 190, 185], [0.84, 180, 235, 50], [1, 255, 210, 0]]);
    var lr = Math.min(255, Math.max(0, Math.round(r * shade)));
    var lg = Math.min(255, Math.max(0, Math.round(g * shade)));
    var lb = Math.min(255, Math.max(0, Math.round(b * shade)));
    return {
      fill: "rgba(" + lr + "," + lg + "," + lb + "," + alpha + ")",
      stroke: "rgba(" + Math.min(255, lr + 40) + "," + Math.min(255, lg + 40) + "," + Math.min(255, lb + 40) + ",0.28)",
      glow: "rgb(" + lr + "," + lg + "," + lb + ")"
    };
  }

  function drawGrid3(ctx, W, H, dpr, zMin, zMax) {
    var gridLimit = 1.35, gridLines = 10, step = (gridLimit * 2) / gridLines;
    var i, pos, p1, p2, p3, p4;
    ctx.lineWidth = 1 * dpr;
    ctx.strokeStyle = "rgba(76,194,168,0.10)";
    for (i = 0; i <= gridLines; i++) {
      pos = -gridLimit + i * step;
      p1 = project3d(-gridLimit, pos, 0, W, H, dpr);
      p2 = project3d(gridLimit, pos, 0, W, H, dpr);
      if (p1 && p2) { ctx.beginPath(); ctx.moveTo(p1.x, p1.y); ctx.lineTo(p2.x, p2.y); ctx.stroke(); }
      p3 = project3d(pos, -gridLimit, 0, W, H, dpr);
      p4 = project3d(pos, gridLimit, 0, W, H, dpr);
      if (p3 && p4) { ctx.beginPath(); ctx.moveTo(p3.x, p3.y); ctx.lineTo(p4.x, p4.y); ctx.stroke(); }
    }
    if (mode3d === "scatter") {
      ctx.strokeStyle = "rgba(255,255,255,0.06)";
      ctx.lineWidth = 0.75 * dpr;
      var zs, w1, w2;
      for (zs = 0; zs <= 4; zs++) {
        var gz = zs * 0.25;
        w1 = project3d(-gridLimit, gridLimit, gz, W, H, dpr);
        w2 = project3d(gridLimit, gridLimit, gz, W, H, dpr);
        if (w1 && w2) { ctx.beginPath(); ctx.moveTo(w1.x, w1.y); ctx.lineTo(w2.x, w2.y); ctx.stroke(); }
        w1 = project3d(-gridLimit, -gridLimit, gz, W, H, dpr);
        w2 = project3d(-gridLimit, gridLimit, gz, W, H, dpr);
        if (w1 && w2) { ctx.beginPath(); ctx.moveTo(w1.x, w1.y); ctx.lineTo(w2.x, w2.y); ctx.stroke(); }
      }
      var corners = [[-gridLimit, -gridLimit], [gridLimit, -gridLimit], [gridLimit, gridLimit], [-gridLimit, gridLimit]];
      for (i = 0; i < 4; i++) {
        var bPt = project3d(corners[i][0], corners[i][1], 0, W, H, dpr);
        var tPt = project3d(corners[i][0], corners[i][1], 1.05, W, H, dpr);
        if (bPt && tPt) {
          ctx.strokeStyle = "rgba(76,194,168,0.15)";
          ctx.beginPath(); ctx.moveTo(bPt.x, bPt.y); ctx.lineTo(tPt.x, tPt.y); ctx.stroke();
        }
      }
    }
    var origin = project3d(0, 0, 0, W, H, dpr);
    var axX = project3d(gridLimit * 1.08, 0, 0, W, H, dpr);
    var axY = project3d(0, gridLimit * 1.08, 0, W, H, dpr);
    var axZ = project3d(0, 0, 1.15, W, H, dpr);
    if (origin && axX && axY && axZ) {
      ctx.lineWidth = 1.6 * dpr;
      ctx.strokeStyle = "rgba(76,194,168,0.65)";
      ctx.beginPath(); ctx.moveTo(origin.x, origin.y); ctx.lineTo(axX.x, axX.y); ctx.stroke();
      ctx.strokeStyle = "rgba(216,115,155,0.65)";
      ctx.beginPath(); ctx.moveTo(origin.x, origin.y); ctx.lineTo(axY.x, axY.y); ctx.stroke();
      ctx.strokeStyle = "rgba(232,179,78,0.75)";
      ctx.beginPath(); ctx.moveTo(origin.x, origin.y); ctx.lineTo(axZ.x, axZ.y); ctx.stroke();
      ctx.font = "bold " + (10 * dpr) + "px ui-monospace, monospace";
      ctx.fillStyle = "#4cc2a8";
      ctx.fillText("X", axX.x + 5 * dpr, axX.y + 3 * dpr);
      ctx.fillStyle = "#d8739b";
      ctx.fillText("Y", axY.x + 5 * dpr, axY.y + 3 * dpr);
      var zl = "Z: NOVELTY";
      if (metric3d === "pca_z") zl = "Z: PCA-Z";
      else if (metric3d === "cd") zl = "Z: COHOM DIM";
      else if (metric3d === "coherence") zl = "Z: COHERENCE";
      else if (metric3d === "density") zl = "Z: DENSITY";
      ctx.fillStyle = "#e8b34e";
      ctx.fillText(zl, axZ.x - 12 * dpr, axZ.y - 8 * dpr);
    }
    var r0 = project3d(-gridLimit, -gridLimit, 0, W, H, dpr);
    var rMid = project3d(-gridLimit, -gridLimit, 0.5, W, H, dpr);
    var rTop = project3d(-gridLimit, -gridLimit, 1.0, W, H, dpr);
    if (r0 && rMid && rTop) {
      ctx.lineWidth = 1.2 * dpr;
      ctx.strokeStyle = "rgba(232,179,78,0.45)";
      ctx.beginPath(); ctx.moveTo(r0.x, r0.y); ctx.lineTo(rTop.x, rTop.y); ctx.stroke();
      ctx.font = (8.5 * dpr) + "px ui-monospace, monospace";
      ctx.fillStyle = "rgba(255,255,255,0.55)";
      ctx.textAlign = "right";
      var v0 = "0.00", vM = "0.50", vT = "1.00";
      if (metric3d === "pca_z") { v0 = zMin.toFixed(1); vM = ((zMin + zMax) / 2).toFixed(1); vT = zMax.toFixed(1); }
      else if (metric3d === "cd") { v0 = "1.00D"; vM = "2.25D"; vT = "3.50D+"; }
      else if (metric3d === "coherence") { v0 = "1.0"; vM = "5.5"; vT = "10.0"; }
      else if (metric3d === "density") { v0 = "0.00"; vM = "0.50"; vT = "1.00"; }
      ctx.fillText(vT, rTop.x - 6 * dpr, rTop.y + 3 * dpr);
      ctx.fillText(vM, rMid.x - 6 * dpr, rMid.y + 3 * dpr);
      ctx.fillText(v0, r0.x - 6 * dpr, r0.y + 3 * dpr);
      ctx.textAlign = "left";
    }
  }

  function updateHud3(count, zMin, zMax) {
    var yawDeg = Math.round(((cam3.yaw % (Math.PI * 2) + Math.PI * 2) % (Math.PI * 2)) * (180 / Math.PI));
    var pitchDeg = Math.round(cam3.pitch * (180 / Math.PI));
    var modes = { surface: "Surface", wireframe: "Wireframe", manifold: "Manifold", scatter: "Scatter" };
    var mets = { novelty: "Novelty", pca_z: "PCA-Z", cd: "Cohom dim", coherence: "Coherence", density: "Density" };
    setText("hud-combo", (modes[mode3d] || mode3d) + " · " + (mets[metric3d] || metric3d));
    setText("hud-range", "Range: [" + zMin.toFixed(2) + " – " + zMax.toFixed(2) + "]");
    setText("hud-yaw", "Yaw: " + yawDeg + "°");
    setText("hud-pitch", "Pitch: " + pitchDeg + "°");
    setText("hud-zoom", "Zoom: " + cam3.zoom.toFixed(1) + "x");
    setText("hud-points", "Points: " + count);
  }

  function drawHeat(ctx, X, Y, pts, dpr) {
    var step = Math.max(1, Math.floor(pts.length / 400));
    for (var i = 0; i < pts.length; i += step) {
      var p = pts[i], x = X(p.x), y = Y(p.y), r = 16 * dpr;
      var c = p.gold ? "217,161,59" : "76,194,168";
      var g = ctx.createRadialGradient(x, y, 0, x, y, r);
      g.addColorStop(0, "rgba(" + c + ",0.10)");
      g.addColorStop(1, "rgba(" + c + ",0)");
      ctx.fillStyle = g;
      ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill();
    }
  }

  function drawTrails(ctx, pts, PX, PY) {
    var by = {};
    for (var i = 0; i < pts.length; i++) {
      var b = pts[i].branch;
      (by[b] = by[b] || []).push(pts[i]);
    }
    ctx.lineWidth = 1;
    for (var k in by) {
      var arr = by[k];
      if (arr.length < 2) continue;
      ctx.beginPath();
      var q0 = PX(arr[0]);
      ctx.moveTo(q0.x, q0.y);
      for (var i = 1; i < arr.length; i++) {
        var q = PX(arr[i]);
        ctx.lineTo(q.x, q.y);
      }
      ctx.strokeStyle = colorFor(Number(k));
      ctx.globalAlpha = 0.30;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
  }

  function drawScatter() {
    var pts = visiblePoints();
    if (viewMode === "3d") { drawScatter3(pts); drawPings3(); return; }
  function drawPings3() {
    if (pings.length === 0 || reducedMotion) return;
    var r = scatter.getBoundingClientRect();
    if (r.width < 2) return;
    var dpr = scatter.width / r.width;
    var ctx = scatter.getContext("2d");
    var pnow = performance.now();
    for (var i = 0; i < pings.length; i++) {
      var pg = pings[i];
      var prog = (pnow - pg.t0) / 950;
      if (prog < 0 || prog >= 1) continue;
      var fm = findingByKey[pg.key];
      if (!fm || fm._px == null) continue;
      ctx.beginPath();
      ctx.arc(fm._px * dpr, fm._py * dpr, (4 + 20 * prog) * dpr, 0, Math.PI * 2);
      ctx.strokeStyle = pg.gold
        ? "rgba(217,161,59," + (0.85 * (1 - prog)).toFixed(2) + ")"
        : "rgba(233,228,214," + (0.6 * (1 - prog)).toFixed(2) + ")";
      ctx.lineWidth = 1.5 * dpr;
      ctx.stroke();
    }
  }
    var dpr = fitCanvas(scatter);
    var ctx = scatter.getContext("2d");
    var W = scatter.width, H = scatter.height;
    var padL = 34 * dpr, padB = 22 * dpr, padT = 12 * dpr, padR = 12 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    function X(v) { return padL + (v / 100) * pw; }
    function Y(v) { return padT + (1 - v / 100) * ph; }

    ctx.clearRect(0, 0, W, H);
    ctx.strokeStyle = "#1c222d";
    ctx.lineWidth = 1;
    ctx.fillStyle = "#5c6474";
    ctx.font = (10 * dpr) + "px ui-monospace, monospace";
    for (var g = 0; g <= 100; g += 10) {
      ctx.beginPath(); ctx.moveTo(X(g), padT); ctx.lineTo(X(g), padT + ph); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(padL, Y(g)); ctx.lineTo(padL + pw, Y(g)); ctx.stroke();
      if (g % 20 === 0) {
        ctx.fillText(String(g), X(g) - 6 * dpr, H - 6 * dpr);
        ctx.fillText(String(100 - g), 6 * dpr, Y(g) + 3 * dpr);
      }
    }
    ctx.strokeStyle = "#2c3547";
    ctx.strokeRect(padL, padT, pw, ph);
    var fxNow = (!reducedMotion && lastState && lastState.running) ? performance.now() : -1;
    if (fxNow >= 0) {
      var sx = padL + ((fxNow / 4500) % 1) * pw;
      var sw = 70 * dpr;
      var sg = ctx.createLinearGradient(sx - sw, 0, sx + sw, 0);
      sg.addColorStop(0, "rgba(76,194,168,0)");
      sg.addColorStop(0.5, "rgba(76,194,168,0.07)");
      sg.addColorStop(1, "rgba(76,194,168,0)");
      ctx.fillStyle = sg;
      ctx.fillRect(padL, padT, pw, ph);
    }
    drawHeat(ctx, X, Y, pts, dpr);
    try { drawShapeContourOverlay(ctx, X, Y, dpr); } catch (e) {}
    if (showTrails) drawTrails(ctx, pts, function (p) { return { x: X(p.x), y: Y(p.y) }; });

    for (var i = 0; i < pts.length; i++) {
      var p = pts[i];
      var x = X(p.x), y = Y(p.y);
      p._px = x / dpr; p._py = y / dpr;
      if (p.gold) {
        ctx.beginPath();
        ctx.arc(x, y, 6.5 * dpr, 0, Math.PI * 2);
        ctx.strokeStyle = GOLD;
        ctx.lineWidth = 1.6 * dpr;
        ctx.stroke();
      }
      ctx.beginPath();
      ctx.arc(x, y, (p.gold ? 3.6 : 2.6) * dpr, 0, Math.PI * 2);
      var pcol = null;
      if (!p.gold && shapeBasinOn) { try { pcol = shapeBasinColor(fkey(p)); } catch (e) {} }
      ctx.fillStyle = p.gold ? GOLD : (pcol || colorFor(p.branch));
      ctx.globalAlpha = p.gold ? 1 : 0.85;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    if (pts.length > 0) {
      var last = pts[pts.length - 1];
      ctx.beginPath();
      ctx.arc(X(last.x), Y(last.y), 8.5 * dpr, 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(233,228,214,0.75)";
      ctx.lineWidth = 1.2 * dpr;
      if (!reducedMotion && (fxNow >= 0 || pings.length > 0)) {
        ctx.setLineDash([5 * dpr, 4 * dpr]);
        ctx.lineDashOffset = -((fxNow >= 0 ? fxNow : performance.now()) / 45);
      }
      ctx.stroke();
      ctx.setLineDash([]);
    }
    if (pings.length > 0 && !reducedMotion) {
      var pnow = performance.now();
      for (var pi = 0; pi < pings.length; pi++) {
        var pg = pings[pi];
        var prog = (pnow - pg.t0) / 950;
        if (prog < 0 || prog >= 1) continue;
        var fm = findingByKey[pg.key];
        if (!fm) continue;
        ctx.beginPath();
        ctx.arc(X(fm.x), Y(fm.y), (4 + 20 * prog) * dpr, 0, Math.PI * 2);
        ctx.strokeStyle = pg.gold
          ? "rgba(217,161,59," + (0.85 * (1 - prog)).toFixed(2) + ")"
          : "rgba(233,228,214," + (0.6 * (1 - prog)).toFixed(2) + ")";
        ctx.lineWidth = (pg.gold ? 2 : 1.4) * dpr;
        ctx.stroke();
      }
    }
    try { drawDiff2D(ctx, X, Y, dpr); } catch (e) {}
    try { drawShapeLoopOverlay(ctx, X, Y, dpr); } catch (e2) {}
    try { drawShapeProbeOverlay(ctx, X, Y, dpr); } catch (e3) {}
  }

  /* W-adv: second-session diff overlay (points set by the W-adv module). */
  function drawDiff2D(ctx, X, Y, dpr) {
    var D = window.__wadvDiff;
    if (!D || !D.points || D.points.length === 0) return;
    ctx.save();
    for (var i = 0; i < D.points.length; i++) {
      var p = D.points[i];
      var x = X(p.x), y = Y(p.y);
      ctx.beginPath();
      ctx.moveTo(x, y - 4 * dpr);
      ctx.lineTo(x + 4 * dpr, y);
      ctx.lineTo(x, y + 4 * dpr);
      ctx.lineTo(x - 4 * dpr, y);
      ctx.closePath();
      ctx.strokeStyle = "rgba(180,140,255,0.85)";
      ctx.lineWidth = 1.2 * dpr;
      ctx.stroke();
      if (p.gold) {
        ctx.beginPath();
        ctx.arc(x, y, 2 * dpr, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(180,140,255,0.9)";
        ctx.fill();
      }
    }
    ctx.restore();
  }

  function drawScatter3(pts) {
    var dpr = fitCanvas(scatter);
    var ctx = scatter.getContext("2d");
    var W = scatter.width, H = scatter.height;
    ctx.clearRect(0, 0, W, H);
    mapped3 = [];
    for (var ci = 0; ci < pts.length; ci++) { pts[ci]._px = null; pts[ci]._py = null; }
    if (metric3d === "density") ensureDens3(pts);

    var i, zMin = Infinity, zMax = -Infinity, minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (i = 0; i < pts.length; i++) {
      var px = num(pts[i].x, 50), py = num(pts[i].y, 50);
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
      var zv = zRaw(pts[i]);
      if (zv < zMin) zMin = zv;
      if (zv > zMax) zMax = zv;
    }
    if (pts.length === 0) { minX = 0; maxX = 100; minY = 0; maxY = 100; zMin = 0; zMax = 1; }
    if (!(zMax > zMin)) zMax = zMin + 1;
    var spanX = Math.max(maxX - minX, 1), spanY = Math.max(maxY - minY, 1);
    var midX = (minX + maxX) / 2, midY = (minY + maxY) / 2;

    updateHud3(pts.length, zMin, zMax);
    drawGrid3(ctx, W, H, dpr, zMin, zMax);

    if (pts.length === 0) {
      ctx.fillStyle = "rgba(76,194,168,0.6)";
      ctx.font = (13 * dpr) + "px ui-monospace, monospace";
      ctx.textAlign = "center";
      ctx.fillText("Latent topology surface", W / 2, H / 2 - 10 * dpr);
      ctx.fillStyle = "rgba(255,255,255,0.35)";
      ctx.font = (11 * dpr) + "px ui-monospace, monospace";
      ctx.fillText("Awaiting expedition findings to form terrain...", W / 2, H / 2 + 14 * dpr);
      ctx.textAlign = "left";
      return;
    }

    var cap = pts.length > 600 ? pts.slice(pts.length - 600) : pts;
    var norm = [];
    for (i = 0; i < cap.length; i++) {
      var p = cap[i];
      norm.push({
        p: p,
        wx: ((num(p.x, 50) - midX) / spanX) * 2.2,
        wy: ((num(p.y, 50) - midY) / spanY) * 2.2,
        wz: zNorm(p, zMin, zMax)
      });
    }

    /* IDW-interpolated height mesh (gaussian kernel, 24x24) */
    var grid = null;
    if (mode3d !== "scatter") {
      var res = 24, lim = 1.30, mStep = (lim * 2) / res;
      var hb = Math.max(0.28, Math.min(0.55, 1.25 / Math.sqrt(Math.max(norm.length, 1))));
      var twoH2 = 2 * hb * hb, gi, gj, gx, gy, wSum, wH, peak, dx, dy, d2, dd, gk, lp;
      grid = [];
      for (gi = 0; gi <= res; gi++) {
        grid[gi] = [];
        gx = -lim + gi * mStep;
        for (gj = 0; gj <= res; gj++) {
          gy = -lim + gj * mStep;
          wSum = 0; wH = 0; peak = 0;
          for (var n = 0; n < norm.length; n++) {
            dx = gx - norm[n].wx; dy = gy - norm[n].wy;
            d2 = dx * dx + dy * dy;
            gk = Math.exp(-d2 / twoH2);
            wSum += gk;
            wH += norm[n].wz * gk;
            dd = Math.sqrt(d2);
            if (dd < hb * 1.5) {
              lp = norm[n].wz * Math.max(0, 1 - dd / (hb * 1.5));
              if (lp > peak) peak = lp;
            }
          }
          var smooth = wSum > 0.0001 ? wH / wSum : 0.05;
          var dens = Math.min(1.0, wSum * 0.80);
          var elev = 0.04 * (1 - dens) + (0.40 * smooth + 0.60 * peak) * dens;
          var edgeR = Math.max(Math.abs(gx), Math.abs(gy)) / lim;
          var gz = elev * Math.max(0, 1 - Math.pow(edgeR, 4.0)) + 0.04;
          grid[gi][gj] = { gx: gx, gy: gy, gz: gz, proj: project3d(gx, gy, gz, W, H, dpr) };
        }
      }
    }

    /* Painter's queue: facets, per-branch trail segments, nodes */
    var queue = [], a, b2;
    if (grid) {
      for (a = 0; a < 24; a++) {
        for (b2 = 0; b2 < 24; b2++) {
          var v00 = grid[a][b2], v10 = grid[a + 1][b2], v11 = grid[a + 1][b2 + 1], v01 = grid[a][b2 + 1];
          if (!(v00.proj && v10.proj && v11.proj && v01.proj)) continue;
          var mStep2 = (1.30 * 2) / 24;
          var dzdx = (v10.gz - v00.gz + v11.gz - v01.gz) / (2 * mStep2);
          var dzdy = (v01.gz - v00.gz + v11.gz - v01.gz) / (2 * mStep2);
          var nl = Math.sqrt(dzdx * dzdx + dzdy * dzdy + 1.0);
          var dot = ((-dzdx / nl) * -0.40 + (-dzdy / nl) * -0.60 + (1.0 / nl) * 0.75) / Math.sqrt(0.16 + 0.36 + 0.5625);
          var shade = Math.max(0.25, Math.min(1.0, 0.40 + 0.60 * dot));
          queue.push({
            type: "facet",
            depth: (v00.proj.depth + v10.proj.depth + v11.proj.depth + v01.proj.depth) / 4,
            z: (v00.gz + v10.gz + v11.gz + v01.gz) / 4,
            shade: shade,
            pts: [v00.proj, v10.proj, v11.proj, v01.proj]
          });
        }
      }
    }

    var proj = [];
    for (i = 0; i < norm.length; i++) {
      var pr = project3d(norm[i].wx, norm[i].wy, norm[i].wz, W, H, dpr);
      if (!pr) { proj.push(null); continue; }
      var base = project3d(norm[i].wx, norm[i].wy, 0, W, H, dpr);
      proj.push({ proj: pr, base: base, data: norm[i] });
    }
    if (showTrails) {
      var byB = {};
      for (i = 0; i < proj.length; i++) {
        if (!proj[i]) continue;
        var bb = proj[i].data.p.branch;
        (byB[bb] = byB[bb] || []).push(proj[i]);
      }
      for (var k in byB) {
        var arr = byB[k];
        for (var s = 0; s < arr.length - 1; s++) {
          queue.push({
            type: "seg",
            depth: (arr[s].proj.depth + arr[s + 1].proj.depth) / 2,
            pA: arr[s].proj, pB: arr[s + 1].proj,
            branch: Number(k),
            goldSeg: arr[s + 1].data.p.gold
          });
        }
      }
    }
    for (i = 0; i < proj.length; i++) {
      if (proj[i]) queue.push({ type: "node", depth: proj[i].proj.depth, pn: proj[i], idx: i, last: i === proj.length - 1 });
    }
    queue.sort(function (x, y) { return y.depth - x.depth; });

    pulse3 = (pulse3 + 0.05) % (Math.PI * 2);
    var pulseScale = 1 + 0.18 * Math.sin(pulse3);

    for (var q = 0; q < queue.length; q++) {
      var item = queue[q];
      if (item.type === "facet") {
        ctx.beginPath();
        ctx.moveTo(item.pts[0].x, item.pts[0].y);
        ctx.lineTo(item.pts[1].x, item.pts[1].y);
        ctx.lineTo(item.pts[2].x, item.pts[2].y);
        ctx.lineTo(item.pts[3].x, item.pts[3].y);
        ctx.closePath();
        if (mode3d === "surface") {
          var pal = pal3(metric3d, item.z, item.shade, 0.82);
          ctx.fillStyle = pal.fill;
          ctx.fill();
          ctx.strokeStyle = pal.stroke;
          ctx.lineWidth = 0.75 * dpr;
          ctx.stroke();
        } else if (mode3d === "wireframe") {
          ctx.fillStyle = "rgba(4,9,22,0.60)";
          ctx.fill();
          var palW = pal3(metric3d, item.z, 1.0, 1.0);
          ctx.strokeStyle = palW.glow;
          ctx.lineWidth = (item.z > 0.75 ? 1.4 : 0.9) * dpr;
          ctx.stroke();
        } else if (mode3d === "manifold") {
          var band = Math.floor(item.z * 8);
          var palM = pal3(metric3d, Math.min(1.0, band / 7.0), 1.0, 0.88);
          ctx.fillStyle = palM.fill;
          ctx.fill();
          ctx.strokeStyle = "rgba(255,255,255,0.22)";
          ctx.lineWidth = 1.2 * dpr;
          ctx.stroke();
        }
      } else if (item.type === "seg") {
        ctx.beginPath();
        ctx.lineWidth = (item.goldSeg ? 3.0 : 2.0) * dpr;
        ctx.strokeStyle = item.goldSeg ? "rgba(232,179,78,0.90)" : colorFor(item.branch);
        ctx.globalAlpha = item.goldSeg ? 0.9 : 0.7;
        ctx.moveTo(item.pA.x, item.pA.y);
        ctx.lineTo(item.pB.x, item.pB.y);
        ctx.stroke();
        ctx.globalAlpha = 1;
      } else if (ballVisible3d(item)) {
        var pn = item.pn, pp = pn.proj, pt = pn.data, f = pt.p;
        var rad = Math.max(1.9, 3.25 * pp.scale) * dpr;
        mapped3.push({ sx: pp.x, sy: pp.y, branch: f.branch, step: f.step });
        f._px = pp.x / dpr; f._py = pp.y / dpr;
        if (pn.base) {
          ctx.beginPath();
          ctx.strokeStyle = f.gold ? "rgba(232,179,78,0.45)" : "rgba(76,194,168,0.22)";
          ctx.lineWidth = 1 * dpr;
          ctx.setLineDash([2 * dpr, 2 * dpr]);
          ctx.moveTo(pn.base.x, pn.base.y);
          ctx.lineTo(pp.x, pp.y);
          ctx.stroke();
          ctx.setLineDash([]);
          ctx.beginPath();
          ctx.fillStyle = f.gold ? "rgba(232,179,78,0.40)" : "rgba(76,194,168,0.20)";
          ctx.arc(pn.base.x, pn.base.y, 2.8 * dpr, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.beginPath();
        if (f.gold) {
          /* Gold reads as ~2x a normal ball (normal r = rad * 0.9):
             small core, faint glow, close thin ring — no blob. */
          var gr = rad * 1.4 * pulseScale;
          ctx.shadowColor = GOLD;
          ctx.shadowBlur = 4 * dpr;
          ctx.fillStyle = GOLD;
          ctx.arc(pp.x, pp.y, gr, 0, Math.PI * 2);
          ctx.fill();
          ctx.beginPath();
          ctx.strokeStyle = "rgba(232,179,78,0.5)";
          ctx.lineWidth = 1.0 * dpr;
          ctx.arc(pp.x, pp.y, gr * 1.2, 0, Math.PI * 2);
          ctx.stroke();
        } else if (item.last) {
          var lr2 = rad * 1.35;
          ctx.shadowColor = "#4cc2a8";
          ctx.shadowBlur = 14 * dpr;
          ctx.fillStyle = "#4cc2a8";
          ctx.arc(pp.x, pp.y, lr2, 0, Math.PI * 2);
          ctx.fill();
          ctx.beginPath();
          ctx.strokeStyle = "rgba(76,194,168,0.75)";
          ctx.lineWidth = 1.5 * dpr;
          ctx.arc(pp.x, pp.y, lr2 * (1.3 + 0.3 * Math.sin(pulse3)), 0, Math.PI * 2);
          ctx.stroke();
        } else {
          ctx.shadowBlur = 0;
          var palN = pal3(metric3d, pt.wz, 1.0, 1.0);
          ctx.fillStyle = mode3d === "scatter" ? palN.glow : "rgba(255,255,255," + (0.45 + (item.idx / proj.length) * 0.45).toFixed(2) + ")";
          ctx.arc(pp.x, pp.y, rad * 0.9, 0, Math.PI * 2);
          ctx.fill();
          if (mode3d === "scatter") {
            ctx.strokeStyle = "rgba(255,255,255,0.6)";
            ctx.lineWidth = 0.8 * dpr;
            ctx.stroke();
          }
        }
        ctx.shadowBlur = 0;
        if (f.gold || item.last) {
          ctx.font = "bold " + (Math.max(9, 10 * pp.scale) * dpr) + "px ui-monospace, monospace";
          ctx.fillStyle = f.gold ? GOLD : "#4cc2a8";
          ctx.textAlign = "left";
          ctx.fillText("[b" + f.branch + " s" + f.step + "]", pp.x + 10 * dpr, pp.y - 8 * dpr);
        }
      }
    }
    /* Scatter with both marker toggles off is a bare grid that reads as
       "nothing plotted" even with data loaded: say what is hidden. */
    if (mode3d === "scatter" && !showBalls3d && !showGold3d) {
      ctx.fillStyle = "rgba(232,179,78,0.9)";
      ctx.font = (13 * dpr) + "px ui-monospace, monospace";
      ctx.textAlign = "center";
      ctx.fillText(pts.length + " points hidden – enable Balls / Gold to show markers", W / 2, H / 2);
      ctx.textAlign = "left";
    }
    try { drawShapeOverlay3(ctx, W, H, dpr, pts); } catch (e) {}
  }

  function loop3() {
    if (raf3) return;
    function frame() {
      if (viewMode === "3d") {
        if (cam3.auto && !dragging3) {
          cam3.yaw += 0.0035;
          drawScatter();
        } else if (cam3.auto) {
          drawScatter();
        }
      }
      raf3 = requestAnimationFrame(frame);
    }
    raf3 = requestAnimationFrame(frame);
  }

  function setPreset3(name) {
    if (name === "iso") { cam3.yaw = 0.78; cam3.pitch = 0.52; cam3.zoom = 1.0; }
    else if (name === "top") { cam3.yaw = 0.0; cam3.pitch = 1.48; cam3.zoom = 1.05; }
    else if (name === "side") { cam3.yaw = 0.0; cam3.pitch = 0.06; cam3.zoom = 1.0; }
    else if (name === "front") { cam3.yaw = 1.57; cam3.pitch = 0.06; cam3.zoom = 1.0; }
    drawScatter();
  }

  function resetCam3() {
    cam3.yaw = 0.78; cam3.pitch = 0.52; cam3.zoom = 1.0;
    drawScatter();
  }

  var dragging3 = false;

  function drawBettiStrip() {
    var cv = document.getElementById("betti-strip");
    if (!cv) return;
    var dpr = fitCanvas(cv);
    var ctx = cv.getContext("2d");
    var W = cv.width, H = cv.height;
    var padL = 34 * dpr, padB = 14 * dpr, padT = 6 * dpr, padR = 10 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    ctx.clearRect(0, 0, W, H);
    ctx.strokeStyle = "#1c222d";
    ctx.beginPath(); ctx.moveTo(padL, padT); ctx.lineTo(padL + pw, padT); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(padL, padT + ph); ctx.lineTo(padL + pw, padT + ph); ctx.stroke();
    var n = teleB0.length;
    if (n === 0) return;
    var bmax = 1;
    for (var i = 0; i < n; i++) bmax = Math.max(bmax, teleB0[i], teleB1[i], teleB2[i]);
    function PX(j) { return padL + (n === 1 ? 0 : (j / (n - 1)) * pw); }
    function PY(v) { return padT + (1 - v / bmax) * ph; }
    line(ctx, teleB0, "#4cc2a8", PX, PY);
    line(ctx, teleB1, "#e8b34e", PX, PY);
    line(ctx, teleB2, "#b48cff", PX, PY);
    ctx.fillStyle = "#5c6474";
    ctx.font = (10 * dpr) + "px ui-monospace, monospace";
    ctx.fillText(String(bmax), 6 * dpr, padT + 8 * dpr);
  }

  function drawTelemetry() {
    try { drawBettiStrip(); } catch (e) {}
    var dpr = fitCanvas(telemetry);
    var ctx = telemetry.getContext("2d");
    var W = telemetry.width, H = telemetry.height;
    var padL = 34 * dpr, padB = 18 * dpr, padT = 10 * dpr, padR = 10 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    ctx.clearRect(0, 0, W, H);
    ctx.strokeStyle = "#1c222d";
    for (var g = 0; g <= 4; g++) {
      var y = padT + (g / 4) * ph;
      ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(padL + pw, y); ctx.stroke();
    }
    ctx.fillStyle = "#5c6474";
    ctx.font = (10 * dpr) + "px ui-monospace, monospace";
    ctx.fillText("1.0", 6 * dpr, padT + 8 * dpr);
    ctx.fillText("0.0", 6 * dpr, padT + ph);
    var n = teleNov.length;
    if (n === 0) return;
    function PX(i) { return padL + (n === 1 ? 0 : (i / (n - 1)) * pw); }
    function PY(v) { return padT + (1 - v) * ph; }
    ctx.setLineDash([4 * dpr, 4 * dpr]);
    ctx.strokeStyle = "#8a6420";
    ctx.beginPath(); ctx.moveTo(padL, PY(goldThreshold)); ctx.lineTo(padL + pw, PY(goldThreshold)); ctx.stroke();
    ctx.setLineDash([]);
    line(ctx, teleNov, "#d9a13b", PX, PY);
    line(ctx, teleCoh, "#4cc2a8", PX, PY);
    ctx.fillStyle = "#d9a13b";
    for (var k = 0; k < n; k++) {
      if (!teleGold[k]) continue;
      ctx.beginPath();
      ctx.arc(PX(k), PY(teleNov[k]), 2.6 * dpr, 0, Math.PI * 2);
      ctx.fill();
    }
    /* Scrub playhead: when replaying history, a line marks the scrub
       position on the telemetry strip (sweeps during replay). */
    if (!isLive() && points.length > 0) {
      var frac = Math.max(0, Math.min(1, Math.min(scrubIdx, points.length) / points.length));
      var lx = padL + frac * pw;
      ctx.strokeStyle = "rgba(233,228,214,0.55)";
      ctx.lineWidth = 1 * dpr;
      ctx.beginPath(); ctx.moveTo(lx, padT); ctx.lineTo(lx, padT + ph); ctx.stroke();
    }
    if (!reducedMotion && (pings.length > 0 || (lastState && lastState.running)) && n > 0) {
      var hn = n - 1;
      var hp = (performance.now() / 600) % 1;
      ctx.beginPath();
      ctx.arc(PX(hn), PY(teleNov[hn]), (2.6 + 1.8 * hp) * dpr, 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(217,161,59," + (0.9 * (1 - hp)).toFixed(2) + ")";
      ctx.lineWidth = 1.4 * dpr;
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(PX(hn), PY(teleNov[hn]), 2.2 * dpr, 0, Math.PI * 2);
      ctx.fillStyle = "#e8b34e";
      ctx.fill();
    }
  }

  function line(ctx, vs, color, PX, PY) {
    ctx.beginPath();
    for (var i = 0; i < vs.length; i++) {
      if (i === 0) ctx.moveTo(PX(i), PY(vs[i]));
      else ctx.lineTo(PX(i), PY(vs[i]));
    }
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.4;
    ctx.stroke();
  }

  function addLog(text, gold) {
    sysLines.unshift({ text: text, gold: !!gold });
    if (sysLines.length > 20) sysLines.pop();
    renderFeed();
  }

  /* Collapsible legend: fanout cascades can number branches into the
     hundreds, so past LEGEND_MAX pills collapse behind a "+N more" pill
     that expands in place. Toggle-per-branch behavior is unchanged. */
  var legendOrder = [];
  var legendKids = {};
  var legendExpanded = false;
  var legendMore = null;
  var LEGEND_MAX = 12;
  function syncLegend() {
    var extra = legendOrder.length - LEGEND_MAX;
    for (var i = 0; i < legendOrder.length; i++) {
      var el = legendKids[legendOrder[i]];
      if (el) el.style.display = (legendExpanded || i < LEGEND_MAX) ? "" : "none";
    }
    if (extra > 0) {
      if (!legendMore) {
        legendMore = document.createElement("span");
        legendMore.className = "more";
        legendMore.style.cursor = "pointer";
        legendMore.addEventListener("click", function () {
          legendExpanded = !legendExpanded;
          syncLegend();
        });
      }
      legendMore.textContent = legendExpanded ? "\u2212 less" : "+" + extra + " more";
      legendMore.title = legendExpanded ? "collapse branch list" : "show all branches";
      legendMore.style.display = "";
      if (legendMore.parentNode !== legend) legend.appendChild(legendMore);
    } else if (legendMore) {
      legendMore.style.display = "none";
    }
  }
  function noteBranch(branch) {
    if (branchesSeen[branch]) return;
    branchesSeen[branch] = true;
    var s = document.createElement("span");
    s.textContent = "b" + branch;
    s.style.borderColor = colorFor(branch);
    s.style.cursor = "pointer";
    s.title = "click to show/hide branch";
    (function (bb, el) {
      el.addEventListener("click", function () {
        if (branchHidden[bb]) { delete branchHidden[bb]; el.style.opacity = "1"; }
        else { branchHidden[bb] = true; el.style.opacity = "0.35"; }
        drawScatter();
      });
    })(branch, s);
    if (legendMore && legendMore.parentNode === legend) legend.insertBefore(s, legendMore);
    else legend.appendChild(s);
    legendOrder.push(branch);
    legendKids[branch] = s;
    syncLegend();
  }

  function fkey(m) { return m.branch + ":" + m.step; }

  function onFinding(m) {
    if (m.run !== currentRun) resetRun(m.run, null);
    var k = fkey(m);
    if (seenKeys[k]) return;
    seenKeys[k] = true;
    findingByKey[k] = m;
    if (!reducedMotion) {
      pings.push({ key: k, t0: performance.now(), gold: !!m.gold });
      if (pings.length > 40) pings.shift();
      fxKick();
    }
    points.push(m);
    if (points.length > 2000) points.splice(0, points.length - 2000);
    teleNov.push(m.novelty); teleCoh.push(m.coherence / 10); teleGold.push(m.gold);
    teleB0.push(num(m.b0, 0)); teleB1.push(num(m.b1, 0)); teleB2.push(num(m.b2, 0));
    if (teleNov.length > 300) { teleNov.shift(); teleCoh.shift(); teleGold.shift(); teleB0.shift(); teleB1.shift(); teleB2.shift(); }
    noteBranch(m.branch);
    syncScrub();
    if (isLive()) drawScatter();
    drawTelemetry();
    renderFeed();
    renderPareto();
    try { shapeMarkStale(); } catch (e) {}
    pollKick();
  }

  function setText(id, v) {
    var el = document.getElementById(id);
    if (el) el.textContent = v;
  }

  /* One-click starts: on the first state carrying cfg, fill every EMPTY
     start-form field from the server config, so what you see is what the
     Start button will run. Runs once and never clobbers typed text.
     Skipped: gold (blank = backend auto), api_key/server-token (secrets),
     models (per-run), auto (checkbox). Clearing a field restores its
     blank semantics. */
  var startFormPrefilled = false;
  function prefillStartForm(cfg) {
    if (startFormPrefilled || !cfg) return;
    startFormPrefilled = true;
    var form = document.getElementById("start-form");
    if (!form) return;
    var names = [
      "concept", "model", "endpoint", "embed_model", "embed_endpoint",
      "seed", "branches", "steps", "temp", "fanout", "judges", "repulse",
      "call_budget", "push", "plateau_k", "plateau_eps", "nogold_m",
      "min_coh", "coh_c", "global_stall"
    ];
    for (var i = 0; i < names.length; i++) {
      var v = cfg[names[i]];
      if (v === undefined || v === null || v === "") continue;
      var el = form.elements[names[i]];
      if (el && el.value === "") el.value = String(v);
    }
  }

  function onState(m) {
    if (m.run !== currentRun) resetRun(m.run, m);
    if (m.running && m.run !== lastRunSeen) { lastRunSeen = m.run; runT0 = Date.now(); }
    if (!m.running) runT0 = 0;
    if (m.running) fxKick();
    if (startPending > 0) startPending--;
    syncStartButton(m);
    lastState = m;
    prefillStartForm(m.cfg);
    updateBanner(m);
    syncTuneSliders(m);
    if (m.cfg && typeof m.cfg.gold === "number") goldThreshold = m.cfg.gold;
    var label = "run " + m.run + " · ";
    if (m.paused) label += "paused";
    else if (m.running) {
      label += "running";
      if (runT0) {
        var rs = Math.floor((Date.now() - runT0) / 1000);
        label += " " + Math.floor(rs / 60) + ":" + ("0" + (rs % 60)).slice(-2);
      }
      if (m.findings === 0) label += " · waiting for first finding…";
    } else {
      label += (m.stop_reason || "idle");
      if (m.run > 0 && typeof m.run_secs === "number" && m.run_secs > 0) {
        label += " " + fmtDur(m.run_secs);
      }
    }
    runLabel.textContent = label;
    pill.className = "run-pill" + (m.running && !m.paused ? " live" : "") + (m.paused ? " paused" : "") + (!m.running && m.gold > 0 ? " gold" : "");
    var live = (typeof m.live === "boolean") ? m.live : !!(m.cfg && m.cfg.endpoint);
    var be = "sim backend";
    if (live) be = m.cfg.endpoint + (m.cfg.model ? " · " + m.cfg.model : "");
    backendLabel.textContent = be;
    updateSimBadges(!live);
    updateCfgTip(m);
    if (m.topo) {
      setText("topo-b0", String(m.topo.b0));
      setText("topo-b1", String(m.topo.b1));
      setText("topo-b2", String(m.topo.b2));
      setText("topo-cd", Number(m.topo.cd).toFixed(2));
      setText("topo-sheaf", Number(m.topo.sheaf).toFixed(2));
      setText("topo-entropy", Number(m.topo.entropy).toFixed(2));
      setText("topo-src", "b" + m.topo.branch + " s" + m.topo.step);
      markTopo("topo-b1", m.topo.b1 > 0);
      markTopo("topo-b2", m.topo.b2 > 0);
      markTopo("topo-sheaf", m.topo.sheaf > 0.01);
      markTopo("topo-cd", m.topo.cd > 1.5);
    }
    if (m.api) {
      setText("api-calls", String(m.api.calls));
      setText("api-in", String(m.api.tok_in));
      setText("api-out", String(m.api.tok_out));
      setText("api-emb", String(m.api.ecalls));
      setText("api-ms", m.api.calls > 0 ? (m.api.ms / m.api.calls).toFixed(0) : "–");
      setText("api-tps", m.api.ms > 0 ? (1000 * m.api.tok_out / m.api.ms).toFixed(1) : "–");
      setText("api-cost", !m.api.cost_ok ? "n/a" : (m.api.cost > 0 ? "$" + Number(m.api.cost).toFixed(4) : "$0.00"));
    }
    drawTelemetry();
    pollKick();
  }

  var tuneLastTouched = "";
  function wireSlider(id, out, dec) {
    var el = document.getElementById(id), lab = document.getElementById(out);
    if (!el || !lab) return;
    var d = (dec === undefined) ? 2 : dec;
    el.addEventListener("input", function () { tuneLastTouched = id; lab.textContent = Number(el.value).toFixed(d); });
    el.addEventListener("mousedown", function () { tuneDragging[id] = true; });
    el.addEventListener("touchstart", function () { tuneDragging[id] = true; });
    el.addEventListener("mouseup", function () { tuneDragging[id] = false; });
    el.addEventListener("touchend", function () { tuneDragging[id] = false; });
  }

  function setSlider(id, out, v, dec) {
    var el = document.getElementById(id), lab = document.getElementById(out);
    if (!el || !lab || typeof v !== "number" || isNaN(v)) return;
    el.value = String(v);
    lab.textContent = Number(el.value).toFixed((dec === undefined) ? 2 : dec);
  }

  function syncTuneSliders(m) {
    if (!m.cfg) return;
    if (!tuneDragging["tune-temp"]) setSlider("tune-temp", "tune-temp-v", m.cfg.temp);
    if (typeof m.cfg.gold === "number" && m.cfg.gold >= 0 && !tuneDragging["tune-gold"])
      setSlider("tune-gold", "tune-gold-v", m.cfg.gold);
    if (!tuneDragging["tune-push"]) setSlider("tune-push", "tune-push-v", m.cfg.push);
    if (!tuneDragging["tune-repulse"]) setSlider("tune-repulse", "tune-repulse-v", m.cfg.repulse, 0);
  }

  function markTopo(id, on) {
    var el = document.getElementById(id);
    if (el && el.parentElement) el.parentElement.classList.toggle("active", !!on);
  }

  /* F4web: badge the judges/repulse controls while the backend is sim. */
  var SIM_BADGES = ["sim-badge-start-judges", "sim-badge-start-repulse",
    "sim-badge-tune-judges", "sim-badge-tune-repulse", "sim-badge-api"];
  function updateSimBadges(sim) {
    for (var i = 0; i < SIM_BADGES.length; i++) {
      var el = document.getElementById(SIM_BADGES[i]);
      if (el) el.hidden = !sim;
    }
  }

  /* F4web: surface the cfg echo (seed/branches/steps/gold/temp/push/
     repulse/fanout/judges/auto/model/endpoint/embed when present) as a
     tooltip on the run pill. Missing fields hide, never throw. */
  function updateCfgTip(m) {
    if (!pill || !m.cfg) return;
    var c = m.cfg, parts = [];
    function kv(k, v) { if (v !== undefined && v !== null && v !== "") parts.push(k + " " + v); }
    kv("seed", c.seed); kv("branches", c.branches); kv("steps", c.steps);
    kv("gold", (typeof c.gold === "number" && c.gold < 0) ? "auto" : c.gold);
    kv("temp", c.temp); kv("push", c.push);
    kv("repulse", c.repulse); kv("fanout", c.fanout); kv("judges", c.judges);
    if (c.auto !== undefined && c.auto !== null) parts.push("auto " + (c.auto ? "on" : "off"));
    kv("model", c.model); kv("endpoint", c.endpoint); kv("embed", c.embed_model);
    if (parts.length) pill.title = "run cfg: " + parts.join(" · ");
    else pill.removeAttribute("title");
  }
  wireSlider("tune-temp", "tune-temp-v");
  wireSlider("tune-gold", "tune-gold-v");
  wireSlider("tune-push", "tune-push-v");
  wireSlider("tune-repulse", "tune-repulse-v", 0);

  function resetRun(run, state) {
    currentRun = run;
    points = [];
    teleNov = [];
    teleCoh = [];
    teleGold = [];
    teleB0 = [];
    teleB1 = [];
    teleB2 = [];
    branchesSeen = {};
    branchHidden = {};
    seenKeys = {};
    findingByKey = {};
    pings = [];
    fedKeys = {};
    sysLines = [];
    feedSearch = "";
    feedFilter = "all";
    scrubIdx = -1;
    playing = true;
    goldOnly = false;
    var go = document.getElementById("gold-only");
    if (go) go.checked = false;
    var fs = document.getElementById("feed-search");
    if (fs) fs.value = "";
    var pls = document.querySelectorAll(".pill");
    for (var pi = 0; pi < pls.length; pi++)
      pls[pi].classList.toggle("active", pls[pi].getAttribute("data-filter") === "all");
    legend.innerHTML = "";
    legendOrder = [];
    legendKids = {};
    legendExpanded = false;
    legendMore = null;
    logEl.innerHTML = "";
    addLog("run " + run + " opened", false);
    renderPareto();
    syncScrub();
    drawScatter();
    drawTelemetry();
  }

  function nearestPoint(mx, my) {
    var pts = visiblePoints();
    var best = null, bestD = 14;
    for (var i = pts.length - 1; i >= 0; i--) {
      var p = pts[i];
      if (p._px == null) continue;
      var dx = p._px - mx, dy = p._py - my;
      var d = Math.sqrt(dx * dx + dy * dy);
      if (d < bestD) { bestD = d; best = p; }
      if (i < pts.length - 400) break;
    }
    return best;
  }

  var dragging = false, lastMX = 0, lastMY = 0;
  var downX = 0, downY = 0;
  scatter.addEventListener("mousedown", function (ev) {
    dragging = true; lastMX = ev.clientX; lastMY = ev.clientY;
    downX = ev.clientX; downY = ev.clientY;
    if (viewMode === "3d") dragging3 = true;
  });
  window.addEventListener("mouseup", function () { dragging = false; dragging3 = false; });
  scatter.addEventListener("click", function (ev) {
    var moved = Math.sqrt((ev.clientX - downX) * (ev.clientX - downX) + (ev.clientY - downY) * (ev.clientY - downY));
    if (moved > 6) return;
    var r = scatter.getBoundingClientRect();
    var hit = nearestPoint(ev.clientX - r.left, ev.clientY - r.top);
    if (hit) window.openFinding(hit.branch, hit.step);
  });
  scatter.addEventListener("dblclick", function () {
    resetCam3();
  });
  scatter.addEventListener("wheel", function (ev) {
    if (viewMode !== "3d") return;
    ev.preventDefault();
    if (ev.deltaY < 0) cam3.zoom = Math.min(3.2, cam3.zoom * 1.08);
    else cam3.zoom = Math.max(0.45, cam3.zoom / 1.08);
    drawScatter();
  }, { passive: false });
  scatter.addEventListener("mousemove", function (ev) {
    if (dragging && viewMode === "3d") {
      cam3.yaw += (ev.clientX - lastMX) * 0.007;
      cam3.pitch += (ev.clientY - lastMY) * 0.007;
      if (cam3.pitch < 0.06) cam3.pitch = 0.06;
      if (cam3.pitch > 1.48) cam3.pitch = 1.48;
      lastMX = ev.clientX; lastMY = ev.clientY;
      tip.hidden = true;
      drawScatter();
      return;
    }
    var r = scatter.getBoundingClientRect();
    var mx = ev.clientX - r.left, my = ev.clientY - r.top;
    var best = nearestPoint(mx, my);
    if (!best) { tip.hidden = true; return; }
    tip.innerHTML = "";
    var sc = document.createElement("div");
    sc.className = "scores";
    sc.textContent = "b" + best.branch + " s" + best.step + " n=" + best.novelty.toFixed(3) + " c=" + best.coherence.toFixed(1);
    var tx = document.createElement("div");
    tx.textContent = best.text;
    tip.appendChild(sc);
    tip.appendChild(tx);
    tip.style.left = Math.min(mx + 14, r.width - 330) + "px";
    tip.style.top = (my + 12) + "px";
    tip.hidden = false;
  });
  scatter.addEventListener("mouseleave", function () { tip.hidden = true; });

  var esCur = null, esGen = 0;
  function connect() {
    var g = ++esGen;
    try { if (esCur) esCur.close(); } catch (e) {}
    var t = mmToken();
    var es = new EventSource("/events" + (t ? "?token=" + encodeURIComponent(t) : ""));
    esCur = es;
    es.onmessage = function (ev) {
      var m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.t === "finding") onFinding(m);
      else if (m.t === "state") onState(m);
      else if (m.t === "log" && m.msg) addLog(m.msg, m.msg.indexOf("GOLD") === 0);
    };
    es.onerror = function () {
      if (esCur === es) esCur = null;
      es.close();
      try { window.fetch("/api/state").then(function () {}, function () {}); } catch (e) {}
      setTimeout(function () { if (g === esGen) connect(); }, 2500);
    };
  }
  (function wireTokenField() {
    var f = document.getElementById("server-token");
    if (!f) return;
    try { f.value = mmToken(); } catch (e) {}
    f.addEventListener("change", function () {
      try { localStorage.setItem("mm_token", f.value || ""); } catch (e) {}
      if (f.value) toast("Server token saved", false);
      connect();
    });
  })();

  function loadModels() {
    fetch("/api/models").then(function (r) { return r.json(); }).then(function (m) {
      if (!m || !m.models) return;
      var dl = document.getElementById("models");
      dl.innerHTML = "";
      for (var i = 0; i < m.models.length; i++) {
        var o = document.createElement("option");
        o.value = m.models[i];
        dl.appendChild(o);
      }
    }).catch(function () {});
  }

  var scrub = document.getElementById("scrub");
  var scrubLabel = document.getElementById("scrub-label");
  var playBtn = document.getElementById("play-btn");
  function syncScrub() {
    if (!scrub) return;
    scrub.max = String(points.length);
    if (isLive()) scrub.value = String(points.length);
    else scrub.value = String(Math.min(scrubIdx, points.length));
    scrubLabel.textContent = isLive()
      ? ("live · " + points.length)
      : (Math.min(scrubIdx, points.length) + "/" + points.length);
    playBtn.textContent = playing ? "Pause" : "Play";
  }
  if (scrub) {
    scrub.addEventListener("input", function () {
      scrubIdx = Number(scrub.value);
      playing = false;
      syncScrub();
      drawScatter();
    });
  }
  if (playBtn) {
    playBtn.addEventListener("click", function () {
      if (isLive() && playing) {
        scrubIdx = points.length;
        playing = false;
      } else {
        playing = true;
      }
      syncScrub();
      drawScatter();
    });
  }
  var goldBox = document.getElementById("gold-only");
  if (goldBox) {
    goldBox.addEventListener("change", function () {
      goldOnly = goldBox.checked;
      drawScatter();
    });
  }
  var modeBtn = document.getElementById("mode-btn");
  if (modeBtn) {
    modeBtn.addEventListener("click", function () {
      viewMode = viewMode === "2d" ? "3d" : "2d";
      modeBtn.textContent = viewMode === "2d" ? "3D" : "2D";
      scatter.style.cursor = viewMode === "3d" ? "grab" : "crosshair";
      var c3 = document.getElementById("controls-3d");
      if (c3) c3.hidden = viewMode !== "3d";
      var h3 = document.getElementById("hud-3d");
      if (h3) h3.hidden = viewMode !== "3d";
      tip.hidden = true;
      drawScatter();
    });
  }
  /* Demo runs: one click each. SIM fills 10x-relaxed stops and a fresh
     seed (minutes of free action, ends on its own). LIVE fills a short capped
     taste (2x5, standard stops, 20-call budget) and refuses without a
     model rather than guessing one. Concept and embed wiring stay as-is.
     Budget is set explicitly both ways: it counts embeds too, so a stale
     live budget would strangle the next sim run. */
  function demoSubmit(btn, live) {
    var form = document.getElementById("start-form");
    if (!form || btn.disabled) return;
    var set = function (n, v) { var el = form.elements[n]; if (el) el.value = v; };
    if (live) {
      var ep = form.elements["endpoint"], mo = form.elements["model"];
      if (ep && ep.value === "") ep.value = "https://api.meta.ai/v1";
      if (!mo || mo.value.trim() === "") {
        toast("Pick a live model first - the Model field is blank", false, true);
        return;
      }
      set("branches", "2");
      set("steps", "5");
      set("fanout", "1");
      set("call_budget", "20");
      set("min_coh", "0.25");
      set("plateau_k", "12");
      set("nogold_m", "25");
      set("global_stall", "40");
      set("coh_c", "6");
    } else {
      // 10x the rope, not infinity: max stops + fanout measured as
      // runaway (15k findings, still going at 3min). This ends on its
      // own in minutes with a banner.
      set("seed", String(Date.now() % 100000));
      set("branches", "4");
      set("steps", "100");
      set("fanout", "1");
      set("call_budget", "0");
      set("min_coh", "0.125");
      set("plateau_k", "120");
      set("nogold_m", "250");
      set("global_stall", "400");
      set("coh_c", "6");
    }
    if (form.requestSubmit) form.requestSubmit();
    else form.submit();
  }
  var demoSimBtn = document.getElementById("demo-sim-btn");
  if (demoSimBtn) demoSimBtn.addEventListener("click", function () { demoSubmit(demoSimBtn, false); });
  var demoLiveBtn = document.getElementById("demo-live-btn");
  if (demoLiveBtn) demoLiveBtn.addEventListener("click", function () { demoSubmit(demoLiveBtn, true); });
  /* W2: 3D control wiring */
  var mode3dSel = document.getElementById("mode3d");
  if (mode3dSel) mode3dSel.addEventListener("change", function () { mode3d = mode3dSel.value; drawScatter(); });
  var metric3dSel = document.getElementById("metric3d");
  if (metric3dSel) metric3dSel.addEventListener("change", function () { metric3d = metric3dSel.value; drawScatter(); });
  var presets3 = ["iso", "top", "side", "front"];
  for (var p3i = 0; p3i < presets3.length; p3i++) {
    (function (nm) {
      var b = document.getElementById("cam-" + nm);
      if (b) b.addEventListener("click", function () { setPreset3(nm); });
    })(presets3[p3i]);
  }
  var rot3Btn = document.getElementById("rot3d");
  if (rot3Btn) rot3Btn.addEventListener("click", function () {
    cam3.auto = !cam3.auto;
    rot3Btn.className = cam3.auto ? "on" : "";
    rot3Btn.textContent = cam3.auto ? "Orbiting..." : "Auto-orbit";
  });
  var balls3Btn = document.getElementById("balls3d");
  if (balls3Btn) balls3Btn.addEventListener("click", function () {
    showBalls3d = !showBalls3d;
    balls3Btn.className = showBalls3d ? "on" : "";
    drawScatter();
  });
  var gold3Btn = document.getElementById("gold3d");
  if (gold3Btn) gold3Btn.addEventListener("click", function () {
    showGold3d = !showGold3d;
    gold3Btn.className = showGold3d ? "on" : "";
    drawScatter();
  });
  var camResetBtn = document.getElementById("cam-reset");
  if (camResetBtn) camResetBtn.addEventListener("click", resetCam3);
  loop3();
  var trailsBtn = document.getElementById("trails-btn");
  var paths3Btn = document.getElementById("paths3d");
  function setTrails(v) {
    showTrails = !!v;
    if (trailsBtn) trailsBtn.className = showTrails ? "on" : "";
    if (paths3Btn) paths3Btn.className = showTrails ? "on" : "";
    drawScatter();
  }
  if (trailsBtn) {
    trailsBtn.addEventListener("click", function () { setTrails(!showTrails); });
  }
  if (paths3Btn) {
    paths3Btn.addEventListener("click", function () { setTrails(!showTrails); });
  }
  document.body.addEventListener("htmx:configRequest", function (e) {
    if (e.detail.path === "/api/control" && e.detail.verb === "post") {
      var b = document.getElementById("order-bid");
      if (b && !e.detail.parameters["bid"]) e.detail.parameters["bid"] = b.value;
      /* Tune form submits every slider on any drag: strip the untouched
         ones so a temp nudge cannot clobber an auto gold bar (or any
         sibling) with its static placeholder. */
      if (e.detail.parameters["action"] === "tune" && tuneLastTouched) {
        var keep = {"tune-temp": "temp", "tune-gold": "gold", "tune-push": "push",
                    "tune-repulse": "repulse", "tune-fanout": "fanout", "tune-judges": "judges"};
        var names = ["temp", "gold", "push", "repulse", "fanout", "judges"];
        for (var i = 0; i < names.length; i++) {
          if (names[i] !== keep[tuneLastTouched]) delete e.detail.parameters[names[i]];
        }
        tuneLastTouched = "";
      }
    }
    var t = mmToken();
    if (t && e.detail.path && (e.detail.path.indexOf("/api/") === 0 || e.detail.path.indexOf("/frag/") === 0)) {
      try { e.detail.headers["X-MM-Token"] = t; } catch (_) {}
    }
  });
  document.body.addEventListener("htmx:responseError", function (e) {
    try {
      if (e.detail.xhr && e.detail.xhr.status === 401) { authFail(); return; }
    } catch (_) {}
    var msg = "request failed";
    try {
      if (e.detail.xhr) {
        var t = e.detail.xhr.responseText || ("HTTP " + e.detail.xhr.status);
        try {
          var j = JSON.parse(t);
          if (j && j.error) t = j.error;
        } catch (_) {}
        msg = t;
      }
    } catch (_) {}
    toast(String(msg).slice(0, 300), false, true);
  });
  document.body.addEventListener("htmx:sendError", function () {
    toast("Server unreachable — will retry in background", false, true);
  });
  var startPending = 0;
  function syncStartButton(m) {
    var b = document.querySelector("#start-form button.go");
    if (!b) return;
    var ds = document.getElementById("demo-sim-btn");
    var dl = document.getElementById("demo-live-btn");
    function demoDis(x) { if (ds) ds.disabled = x; if (dl) dl.disabled = x; }
    if (!b.dataset.label) b.dataset.label = b.textContent;
    if (startPending) {
      b.disabled = true;
      demoDis(true);
      if (b.textContent !== "Starting…") b.textContent = "Starting…";
      return;
    }
    if (m && m.running) {
      b.disabled = true;
      demoDis(true);
      if (m.paused) {
        if (b.textContent !== "Paused") b.textContent = "Paused";
      } else if (!b.querySelector(".btn-spin")) {
        b.innerHTML = '<span class="btn-spin" aria-hidden="true"></span> Running';
      }
    } else {
      b.disabled = false;
      demoDis(false);
      if (b.textContent !== b.dataset.label) b.textContent = b.dataset.label;
    }
  }
  document.body.addEventListener("htmx:beforeRequest", function (e) {
    if (e.detail.elt && e.detail.elt.id === "start-form") {
      startPending = 2;
      syncStartButton(lastState);
      setTimeout(function () {
        if (startPending > 0) { startPending = 0; syncStartButton(lastState); }
      }, 10000);
    }
    if (e.detail.elt && FRAGS.indexOf(e.detail.elt.id) >= 0) {
      try { e.detail.elt.setAttribute("aria-busy", "true"); } catch (_) {}
    }
    if (e.detail.elt && e.detail.elt.id === "gold") {
      goldOpen = [];
      try {
        var det = e.detail.elt.querySelectorAll(".vein > details[open]");
        for (var i = 0; i < det.length; i++) {
          var v = det[i].parentNode;
          if (v && v.id) goldOpen.push(v.id);
        }
      } catch (_) {}
    }
  });
  document.body.addEventListener("htmx:afterRequest", function (e) {
    if (e.detail.elt && e.detail.elt.id === "start-form") {
      if (!e.detail.successful) startPending = 0;
      syncStartButton(lastState);
    }
    if (e.detail.elt && FRAGS.indexOf(e.detail.elt.id) >= 0) {
      try { e.detail.elt.removeAttribute("aria-busy"); } catch (_) {}
    }
  });
  function updateFreshness() {
    var now = Date.now();
    for (var i = 0; i < FRAGS.length; i++) {
      var f = document.getElementById(FRAGS[i]);
      var lab = document.getElementById("fresh-" + FRAGS[i]);
      if (!f || !lab) continue;
      var t = Number((f.dataset && f.dataset.t) || 0);
      if (!t) { lab.textContent = ""; continue; }
      var s = Math.max(0, Math.round((now - t) / 1000));
      lab.textContent = s < 5 ? "· just now" : "· " + s + "s ago";
      lab.className = "fresh" + (s > 90 ? " stale" : "");
    }
  }
  var goldOpen = [];
  document.body.addEventListener("htmx:afterSwap", function (e) {
    if (e.detail.elt && FRAGS.indexOf(e.detail.elt.id) >= 0) {
      try { e.detail.elt.dataset.t = String(Date.now()); } catch (_) {}
      updateFreshness();
    }
    if (e.detail.elt && e.detail.elt.id === "gold" && goldOpen.length) {
      try {
        for (var i = 0; i < goldOpen.length; i++) {
          var v = document.getElementById(goldOpen[i]);
          var d = v ? v.querySelector("details") : null;
          if (d) d.open = true;
        }
      } catch (_) {}
      goldOpen = [];
    }
  });
  setInterval(updateFreshness, 5000);
  var runT0 = 0;
  var lastRunSeen = -1;
  setInterval(function () {
    if (!playing || isLive()) return;
    scrubIdx += 1;
    if (scrubIdx >= points.length) scrubIdx = -1;
    syncScrub();
    drawScatter();
  }, 80);

  function ingestFindings(d) {
    if (!d || !d.items) return;
    var added = false;
    for (var i = 0; i < d.items.length; i++) {
      var m = d.items[i];
      m.run = currentRun;
      var k = fkey(m);
      if (seenKeys[k]) continue;
      seenKeys[k] = true;
      findingByKey[k] = m;
      points.push(m);
      teleNov.push(m.novelty); teleCoh.push(m.coherence / 10); teleGold.push(m.gold);
      teleB0.push(num(m.b0, 0)); teleB1.push(num(m.b1, 0)); teleB2.push(num(m.b2, 0));
      noteBranch(m.branch);
      added = true;
    }
    if (points.length > 2000) points.splice(0, points.length - 2000);
    while (teleNov.length > 300) { teleNov.shift(); teleCoh.shift(); teleGold.shift(); teleB0.shift(); teleB1.shift(); teleB2.shift(); }
    if (added) { syncScrub(); if (isLive()) drawScatter(); drawTelemetry(); renderFeed(); renderPareto(); }
  }

  /* F4web: server `since` is an absolute findings index and the response
     carries `next` = total, so since=0&limit=500 returns the OLDEST 500.
     Learn `next` first, then fetch the newest-500 window. */
  function backfill() {
    fetch("/api/state")
      .then(function (r) { return r.json(); })
      .then(function (st) {
        if (!st || typeof st.run !== "number") return null;
        if (st.run !== currentRun) resetRun(st.run, st);
        onState(st);
        restoreLogOnce(st.run);
        return fetch("/api/findings?since=0&limit=1").then(function (r) { return r.json(); });
      })
      .then(function (d) {
        if (!d) return null;
        ingestFindings(d);
        var total = (typeof d.next === "number" && !isNaN(d.next)) ? d.next : -1;
        var start = (total > 500) ? total - 500 : 0;
        return fetch("/api/findings?since=" + start + "&limit=500").then(function (r) { return r.json(); });
      })
      .then(function (d) {
        if (!d) return;
        ingestFindings(d);
      })
      .catch(function () {});
  }
  setInterval(backfill, 15000);

  /* F4web: restore the Expedition log from GET /api/log
     ({"t":"log","lines":[...]}, newest last) once per run. */
  var logRestoredRun = -1;
  function restoreLogOnce(run) {
    if (logRestoredRun === run) return;
    logRestoredRun = run;
    fetch("/api/log")
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (!d || !(d.lines instanceof Array)) return;
        for (var i = d.lines.length - 1; i >= 0; i--) {
          var msg = d.lines[i];
          if (typeof msg !== "string" || !msg) continue;
          sysLines.unshift({ text: msg, gold: msg.indexOf("GOLD") === 0 });
        }
        while (sysLines.length > 20) sysLines.pop();
        renderFeed();
      })
      .catch(function () {});
  }

  /* ---- W1a: sharing, rich feed, pareto, banner, guide ---- */

  function toast(msg, gold, sticky) {
    var box = document.getElementById("toasts");
    if (!box) return;
    var t = document.createElement("div");
    t.className = "toast" + (gold ? " gold" : "") + (sticky ? " err" : "");
    t.textContent = msg;
    box.appendChild(t);
    while (box.children.length > 4) box.removeChild(box.firstChild);
    if (sticky) {
      t.title = "click to dismiss";
      t.addEventListener("click", function () { if (t.parentNode) t.parentNode.removeChild(t); });
      return;
    }
    setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 2600);
  }
  window.mmToast = toast;
  document.body.addEventListener("mm-toast", function (e) {
    var d = (e && e.detail !== undefined) ? e.detail : {};
    if (typeof d === "string") toast(d, false);
    else if (d && typeof d === "object") toast(String(d.msg || "done"), !!d.gold);
  });

  function copyFallback(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    ta.style.top = "-9999px";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }

  function copyToClipboard(text, msg, gold) {
    function done(ok) {
      if (ok) toast(msg || "Copied to clipboard", !!gold);
      else toast("Copy failed: select the text manually", false);
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(copyFallback(text)); });
        return;
      }
    } catch (e) { /* fall through to execCommand */ }
    done(copyFallback(text));
  }

  function num(v, d) { return (typeof v === "number" && !isNaN(v)) ? v : d; }

  function formatSocial(p) {
    var metrics = "novelty " + num(p.novelty, 0).toFixed(3) +
      " | coherence " + num(p.coherence, 0).toFixed(1) + "/10";
    if (p.cd > 0) metrics += " | cd " + p.cd.toFixed(1);
    if (p.b1 > 0) metrics += " | b1 " + p.b1;
    if (p.b2 > 0) metrics += " | b2 " + p.b2;
    if (p.loc) metrics += " | " + p.loc;
    if (p.gold) metrics += " | GOLD";
    return "MetaMining find [b" + p.branch + " s" + p.step + "]\n\n" +
      '"' + (p.text || "") + '"\n\n' + metrics + "\n#MetaMining #LatentSurvey";
  }

  function lookupFinding(branch, step) { return findingByKey[branch + ":" + step] || null; }

  function copyFindingRaw(branch, step) {
    var p = lookupFinding(branch, step);
    if (p && p.text) copyToClipboard(p.text, "Copied b" + branch + " s" + step + " raw text", p.gold);
    else toast("Finding b" + branch + " s" + step + " not loaded", false);
  }

  function copyFindingSocial(branch, step) {
    var p = lookupFinding(branch, step);
    if (p) copyToClipboard(formatSocial(p), "Copied b" + branch + " s" + step + " social post", true);
    else toast("Finding b" + branch + " s" + step + " not loaded", false);
  }

  function goldPoints() {
    var out = [];
    for (var i = 0; i < points.length; i++) if (points[i].gold) out.push(points[i]);
    return out;
  }

  function copyGoldThread() {
    var golds = goldPoints();
    if (golds.length === 0) { toast("No gold veins yet", false); return; }
    var concept = (lastState && lastState.cfg && lastState.cfg.concept) ? lastState.cfg.concept : "expedition";
    var parts = ["MetaMining gold thread (" + golds.length + " finds) | " + concept, ""];
    for (var i = 0; i < golds.length; i++) {
      var p = golds[i];
      parts.push("[" + (i + 1) + "/" + golds.length + "] b" + p.branch + " s" + p.step +
        " (nov " + num(p.novelty, 0).toFixed(3) + " | coh " + num(p.coherence, 0).toFixed(1) + ")");
      parts.push('"' + (p.text || "") + '"');
      parts.push("");
    }
    copyToClipboard(parts.join("\n"), "Copied gold thread (" + golds.length + " finds)", true);
  }

  function copyDigest() {
    var st = lastState;
    var steps = st ? st.findings : points.length;
    var golds = goldPoints();
    var concept = (st && st.cfg && st.cfg.concept) ? st.cfg.concept : "expedition";
    var parts = ["METAMINING EXPEDITION DIGEST",
      "Concept: " + concept,
      "Steps: " + steps + " | Gold: " + golds.length,
      ""];
    if (golds.length > 0) {
      parts.push("GOLD FINDS:");
      for (var i = 0; i < golds.length; i++) {
        var p = golds[i];
        parts.push("[b" + p.branch + " s" + p.step + "] nov " + num(p.novelty, 0).toFixed(3) +
          " coh " + num(p.coherence, 0).toFixed(1));
        parts.push('"' + (p.text || "") + '"');
        parts.push("");
      }
    }
    copyToClipboard(parts.join("\n"), "Copied expedition digest", true);
  }

  function userSelecting() {
    var sel = window.getSelection();
    return !!(sel && sel.toString().trim().length > 0);
  }

  function feedMatch(p) {
    if (feedFilter === "gold" && !p.gold) return false;
    if (feedFilter === "loops" && !(p.b1 > 0 || p.b2 > 0)) return false;
    if (feedSearch) {
      var hay = ("b" + p.branch + " s" + p.step + " " + (p.text || "")).toLowerCase();
      if (hay.indexOf(feedSearch.toLowerCase()) < 0) return false;
    }
    return true;
  }

  function tagEl(text, cls) {
    var s = document.createElement("span");
    s.className = "tag" + (cls ? " " + cls : "");
    s.textContent = text;
    return s;
  }

  function findingEntry(p) {
    var li = document.createElement("li");
    li.className = "feed-entry" + (p.gold ? " gold-entry" : "");
    li.setAttribute("data-key", p.branch + ":" + p.step);
    var head = document.createElement("div");
    head.className = "entry-head";
    var id = document.createElement("span");
    id.className = "entry-id";
    id.textContent = "b" + p.branch + " s" + p.step +
      " · nov " + num(p.novelty, 0).toFixed(3) +
      " · coh " + num(p.coherence, 0).toFixed(1);
    head.appendChild(id);
    var btns = document.createElement("span");
    btns.className = "entry-btns";
    var bRaw = document.createElement("button");
    bRaw.type = "button"; bRaw.className = "mini-copy"; bRaw.textContent = "Raw";
    var bSoc = document.createElement("button");
    bSoc.type = "button"; bSoc.className = "mini-copy social"; bSoc.textContent = "Social";
    (function (bb, ss) {
      bRaw.addEventListener("click", function () { copyFindingRaw(bb, ss); });
      bSoc.addEventListener("click", function () { copyFindingSocial(bb, ss); });
    })(p.branch, p.step);
    btns.appendChild(bRaw); btns.appendChild(bSoc);
    head.appendChild(btns);
    li.appendChild(head);
    var tx = document.createElement("div");
    tx.className = "entry-text";
    tx.textContent = p.text || "";
    li.appendChild(tx);
    var tags = document.createElement("div");
    tags.className = "entry-tags";
    var any = false;
    if (p.gold) { tags.appendChild(tagEl("GOLD", "gold-tag")); any = true; }
    if (p.cd > 0) { tags.appendChild(tagEl("cd " + p.cd.toFixed(1), "teal-tag")); any = true; }
    if (p.b1 > 0) { tags.appendChild(tagEl("1-CYCLE", "teal-tag")); any = true; }
    if (p.b2 > 0) { tags.appendChild(tagEl("2-VOID", "gold-tag")); any = true; }
    if (p.loc) { tags.appendChild(tagEl(p.loc, "dim-tag")); any = true; }
    if (p.src) { tags.appendChild(tagEl("src " + p.src, "dim-tag")); any = true; }
    if (typeof p.next === "string" && p.next) { tags.appendChild(tagEl("Next: " + p.next, "dim-tag")); any = true; }
    if (any) li.appendChild(tags);
    (function (bb, ss) {
      li.addEventListener("click", function (e) {
        if (e.target && e.target.closest && e.target.closest("button")) return;
        var sel = window.getSelection();
        if (sel && sel.toString().trim().length > 0) return;
        window.openFinding(bb, ss);
      });
    })(p.branch, p.step);
    return li;
  }

  function renderFeed() {
    if (userSelecting()) return;
    var total = points.length, shown = 0, cap = 120;
    logEl.innerHTML = "";
    var frag = document.createDocumentFragment();
    for (var s = 0; s < sysLines.length && shown < cap; s++) {
      var li = document.createElement("li");
      li.className = "sys-line" + (sysLines[s].gold ? " gold-line" : "");
      li.textContent = sysLines[s].text;
      frag.appendChild(li);
      shown++;
    }
    for (var i = points.length - 1; i >= 0 && shown < cap; i--) {
      if (!feedMatch(points[i])) continue;
      var fe = findingEntry(points[i]);
      var fk = points[i].branch + ":" + points[i].step;
      if (!reducedMotion && !fedKeys[fk]) {
        fedKeys[fk] = 1;
        if (lastState && lastState.running) fe.className += " fresh";
      }
      frag.appendChild(fe);
      shown++;
    }
    if (shown === 0) {
      var em = document.createElement("li");
      em.className = "sys-line";
      em.textContent = total === 0 ? "Waiting for expedition findings..." : "No entries match the current filter.";
      frag.appendChild(em);
    }
    logEl.appendChild(frag);
    var fc = document.getElementById("feed-count");
    if (fc) {
      var matched = 0;
      for (var m2 = 0; m2 < points.length; m2++) if (feedMatch(points[m2])) matched++;
      fc.textContent = matched + " / " + total + " entries";
    }
  }

  function paretoSet() {
    var pool = points.length > 400 ? points.slice(points.length - 400) : points;
    var out = [];
    for (var i = 0; i < pool.length; i++) {
      var p = pool[i], dom = false;
      for (var j = 0; j < pool.length; j++) {
        if (i === j) continue;
        var q = pool[j];
        if (num(q.novelty, 0) >= num(p.novelty, 0) && num(q.coherence, 0) >= num(p.coherence, 0) &&
            (num(q.novelty, 0) > num(p.novelty, 0) || num(q.coherence, 0) > num(p.coherence, 0))) { dom = true; break; }
      }
      if (!dom) out.push(p);
    }
    out.sort(function (a, b) { return num(b.novelty, 0) - num(a.novelty, 0); });
    return out.slice(0, 12);
  }

  function renderPareto() {
    var box = document.getElementById("pareto");
    if (!box || userSelecting()) return;
    var set = paretoSet();
    box.innerHTML = "";
    if (set.length === 0) {
      var em = document.createElement("div");
      em.className = "empty";
      em.textContent = "No frontier yet.";
      box.appendChild(em);
      return;
    }
    for (var i = 0; i < set.length; i++) {
      var p = set[i];
      var card = document.createElement("div");
      card.className = "pareto-card";
      card.setAttribute("data-key", p.branch + ":" + p.step);
      var head = document.createElement("div");
      head.className = "pareto-head";
      var id = document.createElement("span");
      id.className = "pareto-id";
      id.textContent = "b" + p.branch + " s" + p.step;
      var sc = document.createElement("span");
      sc.className = "pareto-scores";
      sc.textContent = "nov " + num(p.novelty, 0).toFixed(3) + " · coh " + num(p.coherence, 0).toFixed(1);
      head.appendChild(id); head.appendChild(sc);
      card.appendChild(head);
      var tx = document.createElement("div");
      tx.className = "pareto-text";
      var t = p.text || "";
      tx.textContent = t.length > 140 ? t.substring(0, 140) + "..." : t;
      card.appendChild(tx);
      (function (bb, ss) { card.addEventListener("click", function () { window.openFinding(bb, ss); }); })(p.branch, p.step);
      box.appendChild(card);
    }
  }

  /* ---- W1b: node detail modal, archive, map hit-test wiring ---- */

  function classifyFinding(p) {
    if (p.gold) return { label: "GOLD", cls: "gold" };
    if (p.novelty > 0.7 && p.coherence < 7) return { label: "Fool's Gold", cls: "fool" };
    return { label: "Standard", cls: "std" };
  }

  function metricTile(val, label, cls) {
    var d = document.createElement("div");
    d.className = "node-metric" + (cls ? " " + cls : "");
    var v = document.createElement("div");
    v.className = "node-metric-val";
    v.textContent = val;
    var l = document.createElement("div");
    l.className = "node-metric-label";
    l.textContent = label;
    d.appendChild(v);
    d.appendChild(l);
    return d;
  }

  function maxCachedStep(branch) {
    var mx = 0;
    for (var i = 0; i < points.length; i++) {
      if (points[i].branch === branch && points[i].step > mx) mx = points[i].step;
    }
    return mx;
  }

  function renderNodeModal(p) {
    modalBranch = p.branch;
    modalStep = p.step;
    var badge = classifyFinding(p);
    var lensName = (typeof p.persona === "number" && p.persona >= 0 && p.persona < PERSONAS.length)
      ? personaName(p.persona) : "unknown lens";
    var tempTxt = (typeof p.temp === "number" && !isNaN(p.temp)) ? p.temp.toFixed(2) : "?";
    setText("modal-title", "b" + p.branch + " s" + p.step + " — " + (p.loc || "Concept"));
    setText("modal-subtitle", "Lens: " + lensName + "  |  Temp: " + tempTxt);
    var box = document.getElementById("modal-metrics");
    box.innerHTML = "";
    box.appendChild(metricTile(num(p.novelty, 0).toFixed(3), "Novelty", "teal"));
    box.appendChild(metricTile(num(p.coherence, 0).toFixed(1) + "/10", "Coherence", "purple"));
    box.appendChild(metricTile((typeof p.cd === "number" && !isNaN(p.cd)) ? p.cd.toFixed(2) : "?", "Cohom dim", ""));
    box.appendChild(metricTile((p.b1 === undefined || p.b1 === null) ? "?" : String(p.b1), "b1 loops", ""));
    box.appendChild(metricTile((p.b2 === undefined || p.b2 === null) ? "?" : String(p.b2), "b2 voids", ""));
    box.appendChild(metricTile(badge.label, "Classification", badge.cls));
    setText("modal-body", p.text || "No response text stored.");
    setText("modal-next", (typeof p.next === "string" && p.next) ? p.next : "Uncharted space");
    var prev = document.getElementById("modal-prev");
    var next = document.getElementById("modal-next-btn");
    var inCache = !!lookupFinding(p.branch, p.step);
    if (prev) prev.disabled = (!inCache || p.step <= 1);
    if (next) next.disabled = (!inCache || p.step >= maxCachedStep(p.branch));
    var raw = document.getElementById("modal-copy-raw");
    var soc = document.getElementById("modal-copy-social");
    if (raw) raw.onclick = function () { copyFindingRaw(p.branch, p.step); };
    if (soc) soc.onclick = function () { copyFindingSocial(p.branch, p.step); };
    modalOpen("node-modal", "node-close");
  }

  var modalOpener = null;
  function modalOpen(id, focusId) {
    try { modalOpener = document.activeElement; } catch (e) { modalOpener = null; }
    var m = document.getElementById(id);
    if (!m) return;
    m.hidden = false;
    var f = document.getElementById(focusId);
    if (f && f.focus) { try { f.focus(); } catch (e) {} }
  }
  function modalClose(id) {
    var m = document.getElementById(id);
    if (m) m.hidden = true;
    if (modalOpener && modalOpener.focus) { try { modalOpener.focus(); } catch (e) {} }
    modalOpener = null;
  }

  function fetchFinding(branch, step, cb) {
    var hit = lookupFinding(branch, step);
    if (hit) { cb(hit); return; }
    fetch("/api/step?branch=" + encodeURIComponent(branch) + "&step=" + encodeURIComponent(step))
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d && !d.error) {
          d.run = currentRun;
          findingByKey[fkey(d)] = d;
          cb(d);
        } else {
          toast("Finding b" + branch + " s" + step + " not found", false);
        }
      })
      .catch(function () { toast("Could not load b" + branch + " s" + step, false); });
  }

  window.openFinding = function (branch, step) {
    fetchFinding(branch, step, renderNodeModal);
  };

  /* F4web: cache-membership probe for the W-adv module (related veins). */
  window.__wadvCached = function (branch, step) {
    return !!lookupFinding(branch, step);
  };

  function strOrEmpty(v) { return (typeof v === "string") ? v : ""; }

  /* F4web: open the modal from an already-cached item (search vein/journal
     hits). Never refetches /api/step; missing fields render as "?". */
  window.openFindingItem = function (it) {
    if (!it || typeof it !== "object") return;
    var p = {
      branch: (typeof it.branch === "number") ? it.branch : -1,
      step: (typeof it.step === "number") ? it.step : -1,
      novelty: it.novelty, coherence: it.coherence, gold: !!it.gold,
      text: (typeof it.text === "string") ? it.text : "",
      b1: it.b1, b2: it.b2, cd: it.cd, persona: it.persona, temp: it.temp,
      loc: (typeof it.loc === "string" && it.loc) ? it.loc : strOrEmpty(it.src),
      src: strOrEmpty(it.src), next: it.next
    };
    renderNodeModal(p);
  };

  /* W-adv: redraw hook for the diff overlay module. */
  window.__wadvRefresh = function () { try { drawScatter(); } catch (e) {} };

  function closeNodeModal() {
    modalClose("node-modal");
  }

  function stepModal(delta) {
    if (modalBranch < 0 || modalStep < 0) return;
    if (!lookupFinding(modalBranch, modalStep)) return;
    var target = modalStep + delta;
    if (target < 1) return;
    fetchFinding(modalBranch, target, renderNodeModal);
  }

  var nodeModal = document.getElementById("node-modal");
  var nodeClose = document.getElementById("node-close");
  if (nodeClose) nodeClose.addEventListener("click", closeNodeModal);
  if (nodeModal) nodeModal.addEventListener("click", function (e) { if (e.target === nodeModal) closeNodeModal(); });
  var modalPrev = document.getElementById("modal-prev");
  var modalNextBtn = document.getElementById("modal-next-btn");
  if (modalPrev) modalPrev.addEventListener("click", function () { stepModal(-1); });
  if (modalNextBtn) modalNextBtn.addEventListener("click", function () { stepModal(1); });
  document.addEventListener("keydown", function (e) {
    var nm = document.getElementById("node-modal");
    if (!nm || nm.hidden) return;
    if (e.key === "Escape") closeNodeModal();
    else if (e.key === "ArrowLeft") stepModal(-1);
    else if (e.key === "ArrowRight") stepModal(1);
  });

  var goldPanel = document.getElementById("gold");
  if (goldPanel) goldPanel.addEventListener("click", function (e) {
    if (e.target && e.target.closest && e.target.closest("details, summary, button, a")) return;
    var vein = (e.target && e.target.closest) ? e.target.closest(".vein") : null;
    var scope = vein || goldPanel;
    var h = scope.querySelector ? scope.querySelector(".vein-h") : null;
    var txt = h ? h.textContent : "";
    var m = /b(\d+)\s+s(\d+)/.exec(txt || "");
    if (m) window.openFinding(Number(m[1]), Number(m[2]));
  });

  /* ---- W1b: journal archive ---- */

  function archiveRow(j) {
    var row = document.createElement("div");
    row.className = "archive-row";
    var info = document.createElement("div");
    info.className = "archive-info";
    var concept = document.createElement("div");
    concept.className = "archive-concept";
    concept.textContent = j.starting_concept || j.filename;
    var meta = document.createElement("div");
    meta.className = "archive-meta";
    meta.textContent = j.filename + " | " + j.step_count + " steps | " + j.size_kb + " KB | " + j.modified_time;
    info.appendChild(concept);
    info.appendChild(meta);
    var btns = document.createElement("div");
    btns.className = "archive-btns";
    var bLoad = document.createElement("button");
    bLoad.type = "button";
    bLoad.className = "mini-copy social";
    bLoad.textContent = "Load";
    bLoad.setAttribute("data-tip", "Replace the live view with this session");
    var bMerge = document.createElement("button");
    bMerge.type = "button";
    bMerge.className = "mini-copy";
    bMerge.textContent = "Merge";
    bMerge.setAttribute("data-tip", "Merge this session into the live view");
    (function (fn) {
      bLoad.addEventListener("click", function () { loadJournalServer(fn, "replace"); });
      bMerge.addEventListener("click", function () { loadJournalServer(fn, "merge"); });
    })(j.filename);
    btns.appendChild(bLoad);
    btns.appendChild(bMerge);
    row.appendChild(info);
    row.appendChild(btns);
    return row;
  }

  function fetchAvailableJournals() {
    var list = document.getElementById("archive-list");
    var badge = document.getElementById("archive-count");
    fetch("/api/journals")
      .then(function (r) { return r.json(); })
      .then(function (d) {
        var journals = (d && d.journals) || [];
        if (badge) badge.textContent = journals.length + " session" + (journals.length === 1 ? "" : "s") + " found";
        if (!list) return;
        list.innerHTML = "";
        if (journals.length === 0) {
          var em = document.createElement("div");
          em.className = "empty";
          em.textContent = "No saved journal files yet. Upload a local JSON file above.";
          list.appendChild(em);
          return;
        }
        for (var i = 0; i < journals.length; i++) list.appendChild(archiveRow(journals[i]));
      })
      .catch(function () {
        if (badge) badge.textContent = "Archive unreachable";
        if (list) {
          list.innerHTML = "";
          var em = document.createElement("div");
          em.className = "empty";
          em.textContent = "Could not reach the journal archive.";
          list.appendChild(em);
        }
      });
  }

  function refreshAfterLoad(mode, loadedCount, label) {
    var am = document.getElementById("archive-modal");
    if (am) am.hidden = true;
    toast("Loaded " + loadedCount + " steps from " + label + " (" + (mode === "merge" ? "merged" : "replaced") + ")", true);
    if (mode === "replace") resetRun(currentRun, lastState);
    backfill();
  }

  function loadJournalServer(filename, mode) {
    fetch("/api/load_journal", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: filename, mode: mode || "replace" })
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res && res.status === "ok") refreshAfterLoad(mode || "replace", res.loaded_count, filename);
        else toast("Load failed: " + ((res && res.error) || "unknown error"), false);
      })
      .catch(function () { toast("Load failed: archive unreachable", false); });
  }

  function handleJournalUpload(ev) {
    var file = ev.target.files ? ev.target.files[0] : null;
    if (!file) return;
    var reader = new FileReader();
    reader.onload = function (e) {
      var parsed;
      try {
        parsed = JSON.parse(e.target.result);
      } catch (err) {
        toast("Invalid JSON file: " + err.message, false);
        return;
      }
      var umode = "replace";
      var usel = document.getElementById("upload-mode");
      if (usel && usel.value === "merge") umode = "merge";
      fetch("/api/load_journal", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ custom_json: parsed, filename: file.name, mode: umode })
      })
        .then(function (r) { return r.json(); })
        .then(function (res) {
          if (res && res.status === "ok") refreshAfterLoad(umode, res.loaded_count, file.name);
          else toast("Upload failed: " + ((res && res.error) || "unknown error"), false);
        })
        .catch(function () { toast("Upload failed: archive unreachable", false); });
    };
    reader.readAsText(file);
    ev.target.value = "";
  }

  function saveCurrentRun() {
    fetch("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "save" })
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res && res.ok) {
          toast("Saved journal: " + (res.journal || "ok"), true);
          fetchAvailableJournals();
        }
        else toast("Save failed: " + ((res && res.error) || "unknown error"), false);
      })
      .catch(function () { toast("Save failed: server unreachable", false); });
  }

  function openArchive() {
    modalOpen("archive-modal", "archive-close");
    fetchAvailableJournals();
  }

  function closeArchive() {
    modalClose("archive-modal");
  }

  var archiveModal = document.getElementById("archive-modal");
  var archiveBtn = document.getElementById("archive-btn");
  var loadJournalsBtn = document.getElementById("load-journals-btn");
  var archiveClose = document.getElementById("archive-close");
  var archiveUploadBtn = document.getElementById("archive-upload-btn");
  var archiveSaveBtn = document.getElementById("archive-save-btn");
  var journalFileInput = document.getElementById("journal-file-input");
  if (archiveSaveBtn) archiveSaveBtn.addEventListener("click", saveCurrentRun);
  if (archiveBtn) archiveBtn.addEventListener("click", openArchive);
  if (loadJournalsBtn) loadJournalsBtn.addEventListener("click", openArchive);
  if (archiveClose) archiveClose.addEventListener("click", closeArchive);
  if (archiveModal) archiveModal.addEventListener("click", function (e) { if (e.target === archiveModal) closeArchive(); });
  if (archiveUploadBtn && journalFileInput) archiveUploadBtn.addEventListener("click", function () { journalFileInput.click(); });
  if (journalFileInput) journalFileInput.addEventListener("change", handleJournalUpload);
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeArchive();
  });

  function fmtDur(s) {
    s = Math.max(0, Math.floor(Number(s) || 0));
    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2);
  }
  function updateBanner(m) {
    var banner = document.getElementById("done-banner");
    if (!banner) return;
    if (!m.running && m.run > 0) {
      banner.hidden = false;
      var err = (m.stop_reason === "backend-error" || m.stop_reason === "budget");
      banner.className = err ? "done-banner err" : "done-banner";
      var title = document.getElementById("done-title");
      if (title) title.textContent = err ? "Expedition failed" : "Expedition complete";
      var dt = document.getElementById("done-text");
      if (dt) {
        var txt = "Run " + m.run + " finished (" + (m.stop_reason || "done") + "): " +
          m.findings + " steps, " + m.gold + " gold";
        if (typeof m.run_secs === "number" && m.run_secs > 0) txt += ", " + fmtDur(m.run_secs);
        if (m.api && (Number(m.api.tok_in) + Number(m.api.tok_out)) > 0) {
          txt += ", " + (Number(m.api.tok_in) + Number(m.api.tok_out)) + " tok";
          txt += m.api.cost_ok ? ", $" + Number(m.api.cost).toFixed(4) : " (cost n/a)";
        }
        var conv = convergedCount(m);
        if (conv !== null) txt += ", " + conv + " converged";
        if (m.stop_reason === "backend-error") {
          txt += ". Workers failed - check the API key/endpoint, then the expedition log";
        } else if (m.stop_reason === "budget") {
          txt += ". Call budget exhausted - raise it or start a new run";
        }
        dt.textContent = txt + ".";
      }
    } else {
      banner.hidden = true;
    }
  }

  /* F4web: converged-branch count when the server reports it (an explicit
     numeric field wins; else count workers that ended "converged"). */
  function convergedCount(m) {
    if (!m || typeof m !== "object") return null;
    if (typeof m.converged_branches === "number" && !isNaN(m.converged_branches)) return m.converged_branches;
    if (typeof m.converged === "number" && !isNaN(m.converged)) return m.converged;
    if (m.workers instanceof Array) {
      var n = 0;
      for (var i = 0; i < m.workers.length; i++) {
        if (m.workers[i] && m.workers[i].reason === "converged") n++;
      }
      if (n > 0) return n;
    }
    return null;
  }

  function handleSelection(e) {
    var pop = document.getElementById("sel-popup");
    if (!pop) return;
    if (e && e.target && e.target.closest && e.target.closest("#sel-popup")) return;
    var sel = window.getSelection();
    var text = sel ? sel.toString().trim() : "";
    if (text.length >= 2 && sel.rangeCount > 0) {
      var r = sel.getRangeAt(0).getBoundingClientRect();
      if (r.width === 0 && r.height === 0) { pop.hidden = true; return; }
      pop.hidden = false;
      pop.style.left = Math.max(10, Math.min(window.innerWidth - 230, r.left + r.width / 2 - 100)) + "px";
      pop.style.top = Math.max(10, r.top - 46) + "px";
      var btn = document.getElementById("sel-copy");
      btn.onclick = function (ev) {
        ev.stopPropagation();
        ev.preventDefault();
        copyToClipboard("MetaMining fragment:\n\n\"" + text + "\"\n\n#MetaMining #LatentSurvey",
          "Copied fragment for social", true);
        pop.hidden = true;
        sel.removeAllRanges();
      };
    } else {
      pop.hidden = true;
    }
  }
  document.addEventListener("mouseup", handleSelection);
  document.addEventListener("keyup", handleSelection);

  var guideModal = document.getElementById("guide-modal");
  var guideBtn = document.getElementById("guide-btn");
  var guideClose = document.getElementById("guide-close");
  if (guideBtn && guideModal) guideBtn.addEventListener("click", function () { modalOpen("guide-modal", "guide-close"); });
  if (guideClose && guideModal) guideClose.addEventListener("click", function () { modalClose("guide-modal"); });
  if (guideModal) guideModal.addEventListener("click", function (e) { if (e.target === guideModal) modalClose("guide-modal"); });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    if (guideModal && !guideModal.hidden) modalClose("guide-modal");
    if (archiveModal && !archiveModal.hidden) modalClose("archive-modal");
  });
  /* Focus trap: Tab cycles inside the open modal instead of escaping. */
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Tab") return;
    var ids = ["node-modal", "archive-modal", "guide-modal"], open = null;
    for (var i = 0; i < ids.length; i++) {
      var m = document.getElementById(ids[i]);
      if (m && !m.hidden) { open = m; break; }
    }
    if (!open) return;
    var all = open.querySelectorAll("button, input, select, textarea, a[href]");
    var vis = [];
    for (var j = 0; j < all.length; j++) {
      if (!all[j].disabled && all[j].offsetParent !== null) vis.push(all[j]);
    }
    if (vis.length === 0) return;
    var first = vis[0], last = vis[vis.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });
  /* Shortcuts: p = pause/resume toggle, / = focus feed search.
     Ignored while typing or while a modal is open. */
  document.addEventListener("keydown", function (e) {
    if (e.key !== "p" && e.key !== "P" && e.key !== "/") return;
    var t = e.target;
    if (t && (t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) return;
    if (t && t.tagName === "INPUT") {
      var ty = (t.type || "text").toLowerCase();
      if (ty === "text" || ty === "password" || ty === "search" || ty === "number" || ty === "url" || ty === "tel") return;
    }
    var nm = document.getElementById("node-modal");
    var am = document.getElementById("archive-modal");
    var gm = document.getElementById("guide-modal");
    if ((nm && !nm.hidden) || (am && !am.hidden) || (gm && !gm.hidden)) return;
    if (e.key === "/") {
      var fs = document.getElementById("feed-search");
      if (fs) { e.preventDefault(); fs.focus(); }
      return;
    }
    if (!lastState || !lastState.running) return;
    var want = (lastState.paused ? "resume" : "pause");
    var btn = document.querySelector("form input[value='" + want + "'] + button");
    if (btn && btn.click) {
      e.preventDefault();
      try { btn.click(); } catch (_) {}
    }
  });

  var feedSearchEl = document.getElementById("feed-search");
  if (feedSearchEl) feedSearchEl.addEventListener("input", function () { feedSearch = feedSearchEl.value; renderFeed(); });
  var pills = document.querySelectorAll(".pill");
  for (var pi2 = 0; pi2 < pills.length; pi2++) {
    (function (pill) {
      pill.addEventListener("click", function () {
        for (var k = 0; k < pills.length; k++) pills[k].classList.remove("active");
        pill.classList.add("active");
        feedFilter = pill.getAttribute("data-filter") || "all";
        renderFeed();
      });
    })(pills[pi2]);
  }
  var cgtBtn = document.getElementById("copy-gold-thread");
  if (cgtBtn) cgtBtn.addEventListener("click", copyGoldThread);
  var digestBtn = document.getElementById("done-digest");
  if (digestBtn) digestBtn.addEventListener("click", copyDigest);

  /* ---- Shape: topological surface views (server topo/* + client density) ---- */
  var shapeView = "merge";
  var shapeMerge = null, shapeBars = null, shapeLoops = null, shapeMapper = null, shapeTime = null;
  var shapeBasinOn = false, shapeLoopsOl = true, shapeContourOl = true, shapeLive = false;
  var shapeBasinMap = {}, shapeBasinOrder = [];
  var shapeDensity = null, shapeStale = false;

  function shapeEls() {
    return {
      view: document.getElementById("shape-view"), note: document.getElementById("shape-note"), cap: document.getElementById("shape-cap"),
      cv: document.getElementById("shape-canvas"), btn: document.getElementById("shape-refresh"),
      basin: document.getElementById("shape-basin"), loopsOl: document.getElementById("shape-loops-ol"),
      contourOl: document.getElementById("shape-contour-ol"), levels: document.getElementById("shape-levels"),
      bins: document.getElementById("shape-bins"), overlap: document.getElementById("shape-overlap"),
      metric: document.getElementById("shape-metric"), conf: document.getElementById("shape-conf"),
      live: document.getElementById("shape-live")
    };
  }

  function shapeNote(t) {
    var e = shapeEls();
    if (e.note) e.note.textContent = t + (shapeStale ? " · stale" : "");
  }

  function shapeCap(t) {
    var e = shapeEls();
    if (e.cap) e.cap.textContent = t;
  }

  function shapeMarkStale() {
    if (shapeMerge || shapeBars || shapeLoops || shapeMapper || shapeDensity) {
      shapeStale = true;
      shapeNote(shapeNoteLast);
    }
  }
  var shapeNoteLast = "";

  function shapeSetNote(t) { shapeNoteLast = t; shapeNote(t); }

  function shapeFetch() {
    var e = shapeEls();
    shapeStale = false;
    if (shapeView === "density") { shapeComputeDensity(); return; }
    var metric = (e.metric && e.metric.value === "euclid") ? "euclid" : "cosine";
    var url = "/api/topo_merge";
    if (shapeView === "bars") {
      url = (e.conf && e.conf.checked ? "/api/topo_conf?metric=" : "/api/topo_bars?metric=") + metric;
    } else if (shapeView === "loops") url = "/api/topo_loops?max=6";
    else if (shapeView === "time") url = "/api/topo_time";
    else if (shapeView === "mapper") {
      var b = e.bins ? Math.max(1, Math.min(24, parseInt(e.bins.value, 10) || 8)) : 8;
      var o = e.overlap ? Math.max(0, Math.min(0.9, parseFloat(e.overlap.value) || 0)) : 0.4;
      url = "/api/topo_mapper?bins=" + b + "&overlap=" + o.toFixed(2);
    }
    shapeSetNote("computing…");
    fetch(url).then(function (r) {
      if (!r.ok) throw new Error("http " + r.status);
      return r.json();
    }).then(function (d) {
      if (shapeView === "merge") { shapeMerge = d; shapeBuildBasin(); }
      else if (shapeView === "bars") shapeBars = d;
      else if (shapeView === "loops") shapeLoops = d;
      else if (shapeView === "mapper") shapeMapper = d;
      else if (shapeView === "time") shapeTime = d;
      var nn = (shapeView === "time") ? d.total : d.n;
      shapeSetNote("n=" + (nn || 0) + ((d.total && shapeView !== "time" && d.total > d.n) ? " of " + d.total : ""));
      drawShape();
      drawScatter();
    }).catch(function () {
      shapeSetNote("failed");
      toast("shape view failed to compute", false, true);
    });
  }

  function shapeBuildBasin() {
    shapeBasinMap = {};
    shapeBasinOrder = [];
    if (!shapeMerge || !shapeMerge.basin) return;
    var n = shapeMerge.n || 0;
    for (var i = 0; i < n; i++) {
      var k = shapeMerge.bi[i] + ":" + shapeMerge.si[i];
      var pk = shapeMerge.basin[i];
      shapeBasinMap[k] = pk;
      if (shapeBasinOrder.indexOf(pk) < 0) shapeBasinOrder.push(pk);
    }
    shapeBasinOrder.sort(function (a, b) { return shapeMerge.nov[b] - shapeMerge.nov[a]; });
    var sel = document.getElementById("shape-basinpick");
    if (sel) {
      while (sel.firstChild) sel.removeChild(sel.firstChild);
      for (var p = 0; p < shapeBasinOrder.length; p++) {
        var o = document.createElement("option");
        o.value = String(shapeBasinOrder[p]);
        o.textContent = (p + 1) + ": b" + shapeMerge.bi[shapeBasinOrder[p]] + "/s" + shapeMerge.si[shapeBasinOrder[p]];
        sel.appendChild(o);
      }
    }
  }

  function shapePostControl(obj) {
    return fetch("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(obj)
    }).then(function (r) {
      if (!r.ok) throw new Error("http " + r.status);
      return r.json();
    });
  }

  function shapeRunCheck() {
    if (lastState && lastState.running) return true;
    toast("start or resume a run first — orders need live workers", false, true);
    return false;
  }

  function shapeTeleportMacro(bid, text, why) {
    if (!shapeRunCheck()) return;
    if (!text) { toast("no claim text for " + why, false, true); return; }
    shapePostControl({ action: "teleport", bid: bid, target: text }).then(function () {
      toast("branch " + bid + " teleported (" + why + ")", false);
    }).catch(function () {
      toast("teleport failed", false, true);
    });
  }

  function shapePeakPick() {
    var sel = document.getElementById("shape-basinpick");
    if (!shapeMerge || !shapeMerge.nov || !sel || sel.value === "") return -1;
    var pk = parseInt(sel.value, 10);
    return isNaN(pk) ? -1 : pk;
  }

  function shapePeakText(pk) {
    if (!shapeMerge || pk < 0) return "";
    var fm = findingByKey[shapeMerge.bi[pk] + ":" + shapeMerge.si[pk]];
    return fm && fm.text ? String(fm.text) : "";
  }

  function shapeCorroborate() {
    var pk = shapePeakPick();
    if (pk < 0) { toast("compute the merge tree first", false, true); return; }
    var raw = document.getElementById("shape-corbranches");
    var bids = [];
    if (raw) {
      var parts = String(raw.value || "").split(",");
      for (var i = 0; i < parts.length && bids.length < 3; i++) {
        var b = parseInt(parts[i], 10);
        if (!isNaN(b) && b >= 0 && bids.indexOf(b) < 0) bids.push(b);
      }
    }
    if (bids.length === 0) { toast("list at least one branch id", false, true); return; }
    if (!shapeRunCheck()) return;
    var text = shapePeakText(pk);
    if (!text) { toast("no claim text for this peak", false, true); return; }
    var lenses = [0, 5, 10];
    var chain = [];
    for (var j = 0; j < bids.length; j++) chain.push([bids[j], lenses[j % lenses.length]]);
    function step(k) {
      if (k >= chain.length) {
        toast("corroboration ordered on " + bids.length + " branches (lenses " +
          chain.map(function (c) { return c[1]; }).join("/") + ")", true);
        return;
      }
      shapePostControl({ action: "teleport", bid: chain[k][0], target: text }).then(function () {
        return shapePostControl({ action: "persona", bid: chain[k][0], idx: chain[k][1] });
      }).then(function () { step(k + 1); }).catch(function () {
        toast("corroboration failed at branch " + chain[k][0], false, true);
      });
    }
    step(0);
  }

  var shapeProbe = null;

  function shapeSuggestProbe() {
    shapeProbe = null;
    var reason = "", cx = 0, cy = 0;
    if (shapeLoops && shapeLoops.has_void) {
      cx = shapeLoops.void_x; cy = shapeLoops.void_y; reason = "void chamber";
    } else if (shapeDensity && shapeDensity.count > 0) {
      var n = shapeDensity.n, grid = shapeDensity.grid;
      var x0 = 100, x1 = 0, y0 = 100, y1 = 0, i;
      for (i = 0; i < points.length; i++) {
        if (points[i].x < x0) x0 = points[i].x;
        if (points[i].x > x1) x1 = points[i].x;
        if (points[i].y < y0) y0 = points[i].y;
        if (points[i].y > y1) y1 = points[i].y;
      }
      var gx0 = Math.max(0, Math.floor((x0 / 100) * (n - 1))), gx1 = Math.min(n - 1, Math.ceil((x1 / 100) * (n - 1)));
      var gy1 = Math.max(0, Math.floor(((100 - y1) / 100) * (n - 1))), gy0 = Math.min(n - 1, Math.ceil(((100 - y0) / 100) * (n - 1)));
      if (gx1 - gx0 > 2) { gx0++; gx1--; }
      if (gy0 - gy1 > 2) { gy1++; gy0--; }
      var best = 2, bx = 0, by = 0;
      for (var gy = gy1; gy <= gy0; gy++) for (var gx = gx0; gx <= gx1; gx++) {
        if (grid[gy * n + gx] < best) { best = grid[gy * n + gx]; bx = gx; by = gy; }
      }
      cx = (bx / (n - 1)) * 100; cy = (1 - by / (n - 1)) * 100;
      reason = "sparsest surveyed gap (density " + best.toFixed(2) + ")";
    } else {
      toast("compute loops or density first", false, true);
      return;
    }
    var nb = -1, ns = -1, bd = 1e30, bt = "";
    for (var k = 0; k < points.length; k++) {
      var dx = points[k].x - cx, dy = points[k].y - cy, dd = dx * dx + dy * dy;
      if (dd < bd) { bd = dd; nb = points[k].branch; ns = points[k].step; bt = String(points[k].text || ""); }
    }
    shapeProbe = { x: cx, y: cy, reason: reason, nb: nb, ns: ns, text: bt };
    shapeCap("probe here next: (" + cx.toFixed(1) + "," + cy.toFixed(1) + ") — " + reason +
      "; nearest b" + nb + "/s" + ns + ".");
    shapeRenderTable();
    drawScatter();
  }

  function drawShapeProbeOverlay(ctx, X, Y, dpr) {
    if (!shapeProbe) return;
    var x = X(shapeProbe.x), y = Y(shapeProbe.y);
    ctx.save();
    ctx.strokeStyle = "rgba(232,179,78,0.95)";
    ctx.lineWidth = 1.6 * dpr;
    ctx.beginPath();
    ctx.arc(x, y, 9 * dpr, 0, Math.PI * 2);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(x - 13 * dpr, y); ctx.lineTo(x - 5 * dpr, y);
    ctx.moveTo(x + 5 * dpr, y); ctx.lineTo(x + 13 * dpr, y);
    ctx.moveTo(x, y - 13 * dpr); ctx.lineTo(x, y - 5 * dpr);
    ctx.moveTo(x, y + 5 * dpr); ctx.lineTo(x, y + 13 * dpr);
    ctx.stroke();
    ctx.fillStyle = "rgba(232,179,78,0.95)";
    ctx.font = "bold " + (10 * dpr) + "px ui-monospace, monospace";
    ctx.fillText("P?", x + 11 * dpr, y - 8 * dpr);
    ctx.restore();
  }

  function shapeBasinColor(key) {
    var pk = shapeBasinMap[key];
    if (pk === undefined) return null;
    return BRANCH_COLORS[shapeBasinOrder.indexOf(pk) % BRANCH_COLORS.length];
  }

  /* Gaussian KDE grid over map coords + per-point density + contours. */
  var SHAPE_DN = 56, SHAPE_BW = 5;

  function shapeComputeDensity() {
    var pts = [];
    for (var i = 0; i < points.length; i++) {
      var p = points[i];
      if (typeof p.x === "number" && typeof p.y === "number") pts.push(p);
    }
    var n = SHAPE_DN, grid = new Float64Array(n * n), bw = SHAPE_BW;
    var i, gx, gy;
    var cell = 100 / (n - 1), rad = Math.ceil((bw * 3) / cell);
    for (i = 0; i < pts.length; i++) {
      var px = (pts[i].x / 100) * (n - 1), py = (1 - pts[i].y / 100) * (n - 1);
      var x0 = Math.max(0, Math.floor(px - rad)), x1 = Math.min(n - 1, Math.ceil(px + rad));
      var y0 = Math.max(0, Math.floor(py - rad)), y1 = Math.min(n - 1, Math.ceil(py + rad));
      for (gy = y0; gy <= y1; gy++) for (gx = x0; gx <= x1; gx++) {
        var dx = (gx - px) * cell, dy = (gy - py) * cell;
        grid[gy * n + gx] += Math.exp(-(dx * dx + dy * dy) / (2 * bw * bw));
      }
    }
    var mx = 0;
    for (i = 0; i < grid.length; i++) if (grid[i] > mx) mx = grid[i];
    if (mx > 0) for (i = 0; i < grid.length; i++) grid[i] /= mx;
    for (i = 0; i < pts.length; i++) {
      var qx = (pts[i].x / 100) * (n - 1), qy = (1 - pts[i].y / 100) * (n - 1);
      var ix = Math.max(0, Math.min(n - 2, Math.floor(qx))), iy = Math.max(0, Math.min(n - 2, Math.floor(qy)));
      var fx = Math.max(0, Math.min(1, qx - ix)), fy = Math.max(0, Math.min(1, qy - iy));
      pts[i]._dens = grid[iy * n + ix] * (1 - fx) * (1 - fy) + grid[iy * n + ix + 1] * fx * (1 - fy) +
        grid[(iy + 1) * n + ix] * (1 - fx) * fy + grid[(iy + 1) * n + ix + 1] * fx * fy;
    }
    shapeDensity = { grid: grid, n: n, count: pts.length };
    shapeSetNote("n=" + pts.length);
    drawShape();
    drawScatter();
  }

  function shapeContourSegs(grid, n, levels) {
    var segs = [];
    for (var li = 0; li < levels.length; li++) {
      var L = levels[li];
      for (var gy = 0; gy < n - 1; gy++) for (var gx = 0; gx < n - 1; gx++) {
        var a = grid[gy * n + gx], b = grid[gy * n + gx + 1];
        var c = grid[(gy + 1) * n + gx + 1], d = grid[(gy + 1) * n + gx];
        var idx = (a > L ? 8 : 0) | (b > L ? 4 : 0) | (c > L ? 2 : 0) | (d > L ? 1 : 0);
        if (idx === 0 || idx === 15) continue;
        var T = [gx + (L - a) / (b - a), gy], R = [gx + 1, gy + (L - b) / (c - b)];
        var B = [gx + (L - d) / (c - d), gy + 1], Lp = [gx, gy + (L - a) / (d - a)];
        var tab = {
          1: [Lp, B], 2: [B, R], 3: [Lp, R], 4: [T, R],
          5: [T, Lp, B, R], 6: [T, B], 7: [T, Lp],
          8: [T, Lp], 9: [T, B], 10: [T, R, Lp, B],
          11: [T, R], 12: [Lp, R], 13: [B, R], 14: [Lp, B]
        }[idx];
        for (var s = 0; s < tab.length; s += 2) segs.push([tab[s], tab[s + 1], L]);
      }
    }
    return segs;
  }

  function shapeLevels() {
    var e = shapeEls();
    var nl = e.levels ? Math.max(2, Math.min(10, parseInt(e.levels.value, 10) || 5)) : 5;
    var out = [];
    for (var i = 1; i <= nl; i++) out.push(i / (nl + 1));
    return out;
  }

  function shapeDrawContours(ctx, segs, n, GX, GY, dpr, color) {
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = 1 * dpr;
    ctx.beginPath();
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i];
      var x1 = GX((s[0][0] / (n - 1)) * 100), y1 = GY((1 - s[0][1] / (n - 1)) * 100);
      var x2 = GX((s[1][0] / (n - 1)) * 100), y2 = GY((1 - s[1][1] / (n - 1)) * 100);
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
    }
    ctx.stroke();
    ctx.restore();
  }

  function shapeLoopMembers(loop) {
    var out = [];
    if (!shapeLoops) return out;
    for (var i = 0; i < loop.length; i++) {
      var fm = findingByKey[shapeLoops.bi[loop[i]] + ":" + shapeLoops.si[loop[i]]];
      if (fm) out.push(fm);
    }
    return out;
  }

  function drawShapeLoopOverlay(ctx, X, Y, dpr) {
    if (!shapeLoopsOl || !shapeLoops || !shapeLoops.loops) return;
    ctx.save();
    for (var i = 0; i < shapeLoops.loops.length; i++) {
      var mem = shapeLoopMembers(shapeLoops.loops[i]);
      if (mem.length < 3) continue;
      ctx.beginPath();
      ctx.moveTo(X(mem[0].x), Y(mem[0].y));
      for (var j = 1; j < mem.length; j++) ctx.lineTo(X(mem[j].x), Y(mem[j].y));
      ctx.closePath();
      ctx.strokeStyle = BRANCH_COLORS[(i + 2) % BRANCH_COLORS.length];
      ctx.globalAlpha = 0.9;
      ctx.lineWidth = 1.8 * dpr;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
    if (shapeLoops.has_void) {
      ctx.beginPath();
      ctx.arc(X(shapeLoops.void_x), Y(shapeLoops.void_y),
        Math.abs(X(shapeLoops.void_x + shapeLoops.void_r) - X(shapeLoops.void_x)), 0, Math.PI * 2);
      ctx.setLineDash([5 * dpr, 4 * dpr]);
      ctx.strokeStyle = "rgba(180,140,255,0.85)";
      ctx.lineWidth = 1.4 * dpr;
      ctx.stroke();
      ctx.setLineDash([]);
    }
    ctx.restore();
  }

  function drawShapeContourOverlay(ctx, X, Y, dpr) {
    if (!shapeContourOl || !shapeDensity || shapeDensity.count === 0) return;
    var segs = shapeContourSegs(shapeDensity.grid, shapeDensity.n, shapeLevels());
    shapeDrawContours(ctx, segs, shapeDensity.n, X, Y, dpr, "rgba(76,194,168,0.55)");
  }

  function drawShapeOverlay3(ctx, W, H, dpr, pts) {
    var wantLoops = shapeLoopsOl && shapeLoops && shapeLoops.loops && shapeLoops.loops.length > 0;
    var wantVoid = shapeLoopsOl && shapeLoops && shapeLoops.has_void;
    var wantPeaks = shapeBasinOn && shapeMerge && shapeMerge.nov && shapeBasinOrder.length > 0;
    if (!wantLoops && !wantVoid && !wantPeaks) return;
    var i, minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity, zMin = Infinity, zMax = -Infinity;
    for (i = 0; i < pts.length; i++) {
      var qx = num(pts[i].x, 50), qy = num(pts[i].y, 50);
      if (qx < minX) minX = qx;
      if (qx > maxX) maxX = qx;
      if (qy < minY) minY = qy;
      if (qy > maxY) maxY = qy;
      var qz = zRaw(pts[i]);
      if (qz < zMin) zMin = qz;
      if (qz > zMax) zMax = qz;
    }
    if (!(zMax > zMin)) zMax = zMin + 1;
    var spanX = Math.max(maxX - minX, 1), spanY = Math.max(maxY - minY, 1);
    var midX = (minX + maxX) / 2, midY = (minY + maxY) / 2;
    function W3(mx, my, mz) {
      return project3d(((mx - midX) / spanX) * 2.2, ((my - midY) / spanY) * 2.2, mz, W, H, dpr);
    }
    ctx.save();
    if (wantLoops) {
      for (var li = 0; li < shapeLoops.loops.length; li++) {
        var mem = shapeLoopMembers(shapeLoops.loops[li]);
        if (mem.length < 3) continue;
        ctx.beginPath();
        var started = false;
        for (var mj = 0; mj <= mem.length; mj++) {
          var fm = mem[mj % mem.length];
          var pp = W3(num(fm.x, 50), num(fm.y, 50), zNorm(fm, zMin, zMax));
          if (!pp) { started = false; continue; }
          if (!started) { ctx.moveTo(pp.x, pp.y); started = true; }
          else ctx.lineTo(pp.x, pp.y);
        }
        ctx.strokeStyle = BRANCH_COLORS[(li + 2) % BRANCH_COLORS.length];
        ctx.globalAlpha = 0.9;
        ctx.lineWidth = 1.8 * dpr;
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
    }
    if (wantVoid) {
      var vc = W3(shapeLoops.void_x, shapeLoops.void_y, 0.5);
      var ve = W3(shapeLoops.void_x + shapeLoops.void_r, shapeLoops.void_y, 0.5);
      if (vc && ve) {
        ctx.beginPath();
        ctx.arc(vc.x, vc.y, Math.abs(ve.x - vc.x), 0, Math.PI * 2);
        ctx.setLineDash([5 * dpr, 4 * dpr]);
        ctx.strokeStyle = "rgba(180,140,255,0.85)";
        ctx.lineWidth = 1.4 * dpr;
        ctx.stroke();
        ctx.setLineDash([]);
      }
    }
    if (wantPeaks) {
      ctx.font = "bold " + (10 * dpr) + "px ui-monospace, monospace";
      for (var pi = 0; pi < shapeBasinOrder.length; pi++) {
        var pk = shapeBasinOrder[pi];
        var fm2 = findingByKey[shapeMerge.bi[pk] + ":" + shapeMerge.si[pk]];
        var mz2 = fm2 ? zNorm(fm2, zMin, zMax) : 0.9;
        var pr = W3(shapeMerge.x[pk], shapeMerge.y[pk], mz2);
        if (!pr) continue;
        var s = 5 * dpr;
        ctx.beginPath();
        ctx.moveTo(pr.x, pr.y - s);
        ctx.lineTo(pr.x + s, pr.y);
        ctx.lineTo(pr.x, pr.y + s);
        ctx.lineTo(pr.x - s, pr.y);
        ctx.closePath();
        ctx.strokeStyle = GOLD;
        ctx.lineWidth = 1.4 * dpr;
        ctx.stroke();
        ctx.fillStyle = GOLD;
        ctx.textAlign = "left";
        ctx.fillText("peak " + (pi + 1), pr.x + 7 * dpr, pr.y - 5 * dpr);
      }
    }
    ctx.restore();
  }

  function drawShape() {
    var e = shapeEls();
    if (!e.cv) return;
    var dpr = fitCanvas(e.cv);
    var ctx = e.cv.getContext("2d");
    var W = e.cv.width, H = e.cv.height;
    ctx.clearRect(0, 0, W, H);
    if (shapeView === "merge") drawShapeMerge(ctx, W, H, dpr);
    else if (shapeView === "bars") drawShapeBars(ctx, W, H, dpr);
    else if (shapeView === "loops") drawShapeLoops(ctx, W, H, dpr);
    else if (shapeView === "density") drawShapeDensity(ctx, W, H, dpr);
    else if (shapeView === "mapper") drawShapeMapper(ctx, W, H, dpr);
    else if (shapeView === "time") drawShapeTime(ctx, W, H, dpr);
    try { shapeRenderTable(); } catch (e) {}
  }

  function shapeEmpty(ctx, W, H, dpr, msg) {
    ctx.fillStyle = "#5c6474";
    ctx.font = (11 * dpr) + "px ui-monospace, monospace";
    ctx.fillText(msg, 14 * dpr, H / 2);
  }

  function drawShapeMerge(ctx, W, H, dpr) {
    var d = shapeMerge;
    if (!d || !d.nov || d.nov.length === 0) {
      shapeEmpty(ctx, W, H, dpr, "no merge tree — run an expedition, then Refresh");
      shapeCap("Merge tree: novelty peaks join downward; gold rings mark peaks.");
      return;
    }
    var padL = 30 * dpr, padR = 10 * dpr, padT = 10 * dpr, padB = 18 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    var nmax = 0.001;
    for (var i = 0; i < d.nov.length; i++) if (d.nov[i] > nmax) nmax = d.nov[i];
    function TX(t) { return padL + t * pw; }
    function NY(v) { return padT + (1 - v / nmax) * ph; }
    ctx.strokeStyle = "#2c3547";
    ctx.strokeRect(padL, padT, pw, ph);
    ctx.fillStyle = "#5c6474";
    ctx.font = (10 * dpr) + "px ui-monospace, monospace";
    ctx.fillText("nov " + nmax.toFixed(2), 4 * dpr, padT + 8 * dpr);
    ctx.fillText("0", 4 * dpr, padT + ph);
    ctx.strokeStyle = "rgba(111,168,216,0.6)";
    ctx.lineWidth = 1 * dpr;
    ctx.beginPath();
    for (var q = 0; q < d.la.length; q++) {
      ctx.moveTo(TX(d.tx[d.la[q]]), NY(d.nov[d.la[q]]));
      ctx.lineTo(TX(d.tx[d.lb[q]]), NY(d.nov[d.lb[q]]));
    }
    ctx.stroke();
    var npeaks = 0;
    for (var m = 0; m < d.nov.length; m++) {
      var r = (1.2 + 2.4 * Math.sqrt(d.size[m] / Math.max(1, d.n))) * dpr;
      ctx.beginPath();
      ctx.arc(TX(d.tx[m]), NY(d.nov[m]), r, 0, Math.PI * 2);
      ctx.fillStyle = m < d.n && d.peak[m] ? GOLD : "#6aa8d8";
      ctx.fill();
      if (m < d.n && d.peak[m]) {
        npeaks++;
        ctx.beginPath();
        ctx.arc(TX(d.tx[m]), NY(d.nov[m]), (r + 2.5 * dpr), 0, Math.PI * 2);
        ctx.strokeStyle = GOLD;
        ctx.lineWidth = 1.2 * dpr;
        ctx.stroke();
      }
    }
    var top = "";
    if (shapeBasinOrder.length > 0) {
      var pk = shapeBasinOrder[0];
      top = "top peak b" + d.bi[pk] + "/s" + d.si[pk] + " nov " + d.nov[pk].toFixed(2) + "; ";
    }
    shapeCap(top + npeaks + " peak(s), " + (d.la.length) + " joins" +
      (shapeBasinOn ? "; map tinted by basin." : "; tick Basin tint to color the map."));
  }

  function drawShapeBars(ctx, W, H, dpr) {
    var d = shapeBars;
    if (!d || !d.dim || d.dim.length === 0) {
      shapeEmpty(ctx, W, H, dpr, "no barcode — run an expedition, then Refresh");
      shapeCap("Persistence barcode over vec-space cosine distance (20-point window).");
      return;
    }
    var cols = ["#4cc2a8", "#e8b34e", "#b48cff"];
    var dmax = 0.001;
    for (var i = 0; i < d.dim.length; i++)
      if (d.death[i] >= 0 && d.death[i] > dmax) dmax = d.death[i];
    var padL = 30 * dpr, padR = 16 * dpr, padT = 8 * dpr;
    var barH = H * 0.58, cvTop = padT + barH + 6 * dpr, cvH = H - cvTop - 16 * dpr;
    var pw = W - padL - padR;
    function BX(v) { return padL + (v / dmax) * pw; }
    var order = [[], [], []];
    for (var j = 0; j < d.dim.length; j++) order[d.dim[j]].push(j);
    var rows = [];
    for (var g = 0; g < 3; g++) {
      var grp = order[g].slice(0, 24);
      for (var k = 0; k < grp.length; k++) rows.push(grp[k]);
    }
    var rh = Math.min(9 * dpr, barH / Math.max(1, rows.length));
    ctx.font = (10 * dpr) + "px ui-monospace, monospace";
    for (var q = 0; q < rows.length; q++) {
      var bi2 = rows[q], y = padT + q * rh + rh / 2;
      var x0 = BX(d.birth[bi2]);
      var x1 = d.death[bi2] < 0 ? padL + pw : BX(d.death[bi2]);
      ctx.strokeStyle = cols[d.dim[bi2]];
      var bold = d.support && d.support[bi2] >= 0.5;
      ctx.lineWidth = Math.max(1, rh * (bold ? 0.8 : 0.45));
      ctx.beginPath();
      ctx.moveTo(x0, y);
      ctx.lineTo(x1, y);
      ctx.stroke();
      if (d.death[bi2] < 0) {
        ctx.fillStyle = cols[d.dim[bi2]];
        ctx.fillText("∞", padL + pw + 3 * dpr, y + 3 * dpr);
      }
      if (q === 0 || d.dim[rows[q - 1]] !== d.dim[bi2]) {
        ctx.fillStyle = "#5c6474";
        ctx.fillText("H" + d.dim[bi2], 4 * dpr, y + 3 * dpr);
      }
    }
    var hasCurves = d.scales && d.b0 && d.scales.length > 0;
    if (hasCurves) {
      var smax = 0.001;
      for (var s = 0; s < d.scales.length; s++) if (d.scales[s] > smax) smax = d.scales[s];
      var bmax = 1;
      for (var t = 0; t < d.b0.length; t++) bmax = Math.max(bmax, d.b0[t], d.b1[t], d.b2[t]);
      var cvTop2 = cvTop, cvH2 = cvH;
      ctx.strokeStyle = "#2c3547";
      ctx.strokeRect(padL, cvTop2, pw, cvH2);
      var series = [d.b0, d.b1, d.b2];
      for (var u = 0; u < 3; u++) {
        ctx.strokeStyle = cols[u];
        ctx.lineWidth = 1.2 * dpr;
        ctx.beginPath();
        for (var v = 0; v < d.scales.length; v++) {
          var xx = padL + (d.scales[v] / smax) * pw, yy = cvTop2 + cvH2 - (series[u][v] / bmax) * cvH2;
          if (v === 0) ctx.moveTo(xx, yy); else ctx.lineTo(xx, yy);
        }
        ctx.stroke();
      }
      ctx.fillStyle = "#5c6474";
      ctx.fillText("b0 b1 b2 vs scale", 4 * dpr, cvTop + cvH + 11 * dpr);
    }
    var nb = [order[0].length, order[1].length, order[2].length];
    var stab = "";
    if (d.support) {
      var ns = 0;
      for (var w = 0; w < order[1].length; w++) if (d.support[order[1][w]] >= 0.5) ns++;
      stab = "; " + ns + "/" + order[1].length + " H1 bars stable (support ≥ 0.5, bold)";
    }
    shapeCap("H0/H1/H2 bars: " + nb[0] + "/" + nb[1] + "/" + nb[2] +
      (d.capped ? " (tri/tet caps hit — sparsified approximation)" : "") + stab +
      "; metric " + (d.metric || "cosine") + "; curves share the H-colors.");
  }

  function drawShapeLoops(ctx, W, H, dpr) {
    var d = shapeLoops;
    var padL = 30 * dpr, padR = 10 * dpr, padT = 8 * dpr, padB = 14 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    function X(v) { return padL + (v / 100) * pw; }
    function Y(v) { return padT + (1 - v / 100) * ph; }
    ctx.strokeStyle = "#2c3547";
    ctx.strokeRect(padL, padT, pw, ph);
    ctx.fillStyle = "rgba(140,150,170,0.4)";
    for (var i = 0; i < points.length; i++) {
      ctx.beginPath();
      ctx.arc(X(points[i].x), Y(points[i].y), 1.6 * dpr, 0, Math.PI * 2);
      ctx.fill();
    }
    if (!d || !d.loops) {
      shapeEmpty(ctx, W, H, dpr, "no loops computed — press Refresh");
      shapeCap("Loop members at the median-distance scale; dashed ring marks a void.");
      return;
    }
    var saved = shapeLoopsOl;
    shapeLoopsOl = true;
    drawShapeLoopOverlay(ctx, X, Y, dpr);
    shapeLoopsOl = saved;
    shapeCap("b1=" + d.b1 + ", " + d.loops.length + " loop(s) drawn" +
      (d.has_void ? "; void at (" + d.void_x.toFixed(1) + "," + d.void_y.toFixed(1) + ")" : "; no void") +
      (d.b1 === 0 ? " — the map has no repetition rings at median scale." : "."));
  }

  function drawShapeDensity(ctx, W, H, dpr) {
    var d = shapeDensity;
    var padL = 30 * dpr, padR = 10 * dpr, padT = 8 * dpr, padB = 14 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    function X(v) { return padL + (v / 100) * pw; }
    function Y(v) { return padT + (1 - v / 100) * ph; }
    if (!d || d.count === 0) {
      shapeEmpty(ctx, W, H, dpr, "no density — run an expedition, then Refresh");
      shapeCap("Gaussian KDE (bandwidth 5 map units); contours at even levels.");
      return;
    }
    var n = d.n, cw = pw / (n - 1), ch = ph / (n - 1);
    for (var gy = 0; gy < n; gy++) for (var gx = 0; gx < n; gx++) {
      var v = d.grid[gy * n + gx];
      if (v <= 0.01) continue;
      ctx.fillStyle = "rgba(76,194,168," + (0.08 + 0.5 * v).toFixed(2) + ")";
      ctx.fillRect(padL + (gx / (n - 1)) * pw - cw / 2, padT + (gy / (n - 1)) * ph - ch / 2, cw + 0.5, ch + 0.5);
    }
    ctx.strokeStyle = "#2c3547";
    ctx.strokeRect(padL, padT, pw, ph);
    shapeDrawContours(ctx, shapeContourSegs(d.grid, n, shapeLevels()), n, X, Y, dpr, "rgba(232,179,78,0.8)");
    shapeCap(d.count + " points, bandwidth 5; per-point density feeds Z: Density in 3D.");
  }

  function drawShapeMapper(ctx, W, H, dpr) {
    var d = shapeMapper;
    var padL = 30 * dpr, padR = 10 * dpr, padT = 8 * dpr, padB = 14 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    function X(v) { return padL + (v / 100) * pw; }
    function Y(v) { return padT + (1 - v / 100) * ph; }
    if (!d || !d.x || d.x.length === 0) {
      shapeEmpty(ctx, W, H, dpr, "no Mapper graph — run an expedition, then Refresh");
      shapeCap("Mapper nerve over the novelty lens: node size = cluster size, color = lens.");
      return;
    }
    ctx.strokeStyle = "#2c3547";
    ctx.strokeRect(padL, padT, pw, ph);
    ctx.strokeStyle = "rgba(111,168,216,0.55)";
    ctx.lineWidth = 1 * dpr;
    ctx.beginPath();
    for (var i = 0; i < d.la.length; i++) {
      ctx.moveTo(X(d.x[d.la[i]]), Y(d.y[d.la[i]]));
      ctx.lineTo(X(d.x[d.lb[i]]), Y(d.y[d.lb[i]]));
    }
    ctx.stroke();
    var lmax = 0.001;
    for (var j = 0; j < d.lens.length; j++) if (d.lens[j] > lmax) lmax = d.lens[j];
    for (var m = 0; m < d.x.length; m++) {
      var t = d.lens[m] / lmax;
      var r = Math.sqrt(d.size[m]), g = Math.round(194 - 32 * t), b = Math.round(168 - 90 * t);
      ctx.beginPath();
      ctx.arc(X(d.x[m]), Y(d.y[m]), (2.5 + 2.2 * r) * dpr, 0, Math.PI * 2);
      ctx.fillStyle = "rgb(76," + g + "," + b + ")";
      ctx.globalAlpha = 0.9;
      ctx.fill();
      ctx.globalAlpha = 1;
    }
    shapeCap(d.x.length + " node(s), " + d.la.length + " link(s); bins=" + d.bins +
      " overlap=" + (typeof d.overlap === "number" ? d.overlap.toFixed(2) : d.overlap) + ".");
  }

  function shapeStamp() {
    var d = new Date();
    function p2(v) { return (v < 10 ? "0" : "") + v; }
    return d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate()) + "-" +
      p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds());
  }

  function shapeRunTag() {
    return "run" + ((typeof currentRun === "number" && currentRun >= 0) ? currentRun : 0);
  }

  function shapeDownload(name, blob) {
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = name;
    document.body.appendChild(a);
    a.click();
    setTimeout(function () {
      try { URL.revokeObjectURL(a.href); } catch (e) {}
      if (a.parentNode) a.parentNode.removeChild(a);
    }, 800);
  }

  function shapeExpCSV() {
    var rows = ["branch,step,novelty,coherence,gold,x,y,z,b0,b1,b2,text"];
    for (var i = 0; i < points.length; i++) {
      var p = points[i];
      var t = String(p.text == null ? "" : p.text).replace(/"/g, '""').replace(/[\r\n]+/g, " ");
      rows.push([p.branch, p.step, num(p.novelty, 0), num(p.coherence, 0),
        p.gold ? 1 : 0, num(p.x, 0), num(p.y, 0), num(p.z, 0),
        (typeof p.b0 === "number" ? p.b0 : ""), (typeof p.b1 === "number" ? p.b1 : ""),
        (typeof p.b2 === "number" ? p.b2 : ""), '"' + t + '"'].join(","));
    }
    shapeDownload("metamining-" + shapeRunTag() + "-" + shapeStamp() + "-findings.csv",
      new Blob([rows.join("\n")], { type: "text/csv" }));
    toast("findings CSV exported (" + points.length + " rows)", false);
  }

  function shapeExpPNG(cvId, kind) {
    var cv = document.getElementById(cvId);
    if (!cv) return;
    try {
      var url = cv.toDataURL("image/png");
      var a = document.createElement("a");
      a.href = url;
      a.download = "metamining-" + shapeRunTag() + "-" + shapeStamp() + "-" + kind + ".png";
      document.body.appendChild(a);
      a.click();
      if (a.parentNode) a.parentNode.removeChild(a);
      toast(kind + " PNG exported", false);
    } catch (e) {
      toast("PNG export failed", false, true);
    }
  }

  function shapeExpBundle() {
    var e = shapeEls();
    var b = e.bins ? Math.max(1, Math.min(24, parseInt(e.bins.value, 10) || 8)) : 8;
    var o = e.overlap ? Math.max(0, Math.min(0.9, parseFloat(e.overlap.value) || 0)) : 0.4;
    var prevNote = shapeNoteLast;
    shapeSetNote("exporting…");
    var m2 = (e.metric && e.metric.value === "euclid") ? "euclid" : "cosine";
    var urls = ["/api/journal", "/api/state", "/api/topo_merge", "/api/topo_bars?metric=" + m2,
      "/api/topo_loops?max=6", "/api/topo_mapper?bins=" + b + "&overlap=" + o.toFixed(2),
      "/api/topo_time", "/api/topo_conf?metric=" + m2];
    var out = {};
    function step(i) {
      if (i >= urls.length) {
        out.manifest = {
          app: "MetaMining", exported_at: new Date().toISOString(),
          app_version: (out.state && out.state.version) || "unknown",
          run: (typeof currentRun === "number" ? currentRun : 0),
          shape_view: shapeView, stale: shapeStale,
          density: shapeDensity ? {
            bandwidth: SHAPE_BW, grid: shapeDensity.n,
            levels: shapeLevels(), count: shapeDensity.count
          } : null
        };
        shapeDownload("metamining-" + shapeRunTag() + "-" + shapeStamp() + "-bundle.json",
          new Blob([JSON.stringify(out)], { type: "application/json" }));
        shapeSetNote(prevNote);
        toast("research bundle exported", false);
        return;
      }
      fetch(urls[i]).then(function (r) {
        if (!r.ok) throw new Error("http " + r.status);
        return r.json();
      }).then(function (d) {
        out[["journal", "state", "merge", "bars", "loops", "mapper", "time", "conf"][i]] = d;
        step(i + 1);
      }).catch(function () {
        shapeSetNote("export failed");
        toast("bundle export failed at " + urls[i], false, true);
      });
    }
    step(0);
  }

  function drawShapeTime(ctx, W, H, dpr) {
    var d = shapeTime;
    var padL = 30 * dpr, padR = 10 * dpr, padT = 8 * dpr, padB = 14 * dpr;
    var pw = W - padL - padR, ph = H - padT - padB;
    if (!d || !d.frac || d.frac.length === 0) {
      shapeEmpty(ctx, W, H, dpr, "no timeline — run an expedition, then Refresh");
      shapeCap("Median-scale Betti numbers over cumulative run deciles (vineyard-lite).");
      return;
    }
    var cols = ["#4cc2a8", "#e8b34e", "#b48cff"];
    var bmax = 1;
    for (var i = 0; i < d.b0.length; i++) bmax = Math.max(bmax, d.b0[i], d.b1[i], d.b2[i]);
    function FX(f) { return padL + f * pw; }
    function FY(v) { return padT + ph - (v / bmax) * ph; }
    ctx.strokeStyle = "#2c3547";
    ctx.strokeRect(padL, padT, pw, ph);
    var series = [d.b0, d.b1, d.b2];
    for (var u = 0; u < 3; u++) {
      ctx.fillStyle = cols[u];
      ctx.globalAlpha = 0.25;
      ctx.beginPath();
      ctx.moveTo(FX(d.frac[0]), FY(0));
      for (var v = 0; v < d.frac.length; v++) ctx.lineTo(FX(d.frac[v]), FY(series[u][v]));
      ctx.lineTo(FX(d.frac[d.frac.length - 1]), FY(0));
      ctx.closePath();
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.strokeStyle = cols[u];
      ctx.lineWidth = 1.4 * dpr;
      ctx.beginPath();
      for (var w = 0; w < d.frac.length; w++) {
        if (w === 0) ctx.moveTo(FX(d.frac[w]), FY(series[u][w]));
        else ctx.lineTo(FX(d.frac[w]), FY(series[u][w]));
      }
      ctx.stroke();
    }
    ctx.fillStyle = "#5c6474";
    ctx.font = (10 * dpr) + "px ui-monospace, monospace";
    ctx.fillText("run time →", padL + pw - 52 * dpr, padT + ph + 11 * dpr);
    var last = d.b0.length - 1;
    shapeCap("deciles of " + d.total + " findings; latest b0/b1/b2 = " +
      d.b0[last] + "/" + d.b1[last] + "/" + d.b2[last] +
      ". Rising amber = loops forming; violet humps = voids opening then closing.");
  }

  function shapeRenderTable() {
    var el = document.getElementById("shape-table");
    if (!el) return;
    function tab(head, rows) {
      var h = "<table><thead><tr>";
      for (var i = 0; i < head.length; i++) h += "<th>" + head[i] + "</th>";
      h += "</tr></thead><tbody>";
      for (var r = 0; r < rows.length; r++) {
        h += "<tr>";
        for (var c = 0; c < rows[r].length; c++) h += "<td>" + rows[r][c] + "</td>";
        h += "</tr>";
      }
      return h + "</tbody></table>";
    }
    if (shapeView === "merge" && shapeMerge && shapeMerge.nov) {
      var rows = [], d = shapeMerge;
      for (var p = 0; p < shapeBasinOrder.length; p++) {
        var pk = shapeBasinOrder[p], cnt = 0;
        for (var i = 0; i < d.basin.length; i++) if (d.basin[i] === pk) cnt++;
        rows.push([p + 1, "b" + d.bi[pk] + "/s" + d.si[pk], d.nov[pk].toFixed(3), cnt]);
      }
      el.innerHTML = tab(["basin", "peak", "novelty", "members"], rows);
    } else if (shapeView === "bars" && shapeBars && shapeBars.dim) {
      var bd = shapeBars, h1 = [];
      for (var j = 0; j < bd.dim.length; j++) {
        if (bd.dim[j] === 1 && bd.death[j] >= 0) h1.push([bd.birth[j], bd.death[j], bd.death[j] - bd.birth[j], bd.support ? bd.support[j].toFixed(2) : "–"]);
      }
      h1.sort(function (a, b) { return b[2] - a[2]; });
      var bq = [];
      for (var k = 0; k < Math.min(8, h1.length); k++) bq.push([k + 1, h1[k][0].toFixed(3), h1[k][1].toFixed(3), h1[k][2].toFixed(3), h1[k][3]]);
      el.innerHTML = tab(["#", "H1 birth", "death", "length", "support"], bq);
    } else if (shapeView === "loops" && shapeLoops && shapeLoops.loops) {
      var lq = [];
      for (var m = 0; m < shapeLoops.loops.length; m++) lq.push([m + 1, shapeLoops.loops[m].length]);
      if (shapeLoops.has_void) lq.push(["void", "r=" + shapeLoops.void_r.toFixed(1) + " @ (" + shapeLoops.void_x.toFixed(1) + "," + shapeLoops.void_y.toFixed(1) + ")"]);
      el.innerHTML = tab(["cycle", "members"], lq);
    } else if (shapeView === "mapper" && shapeMapper && shapeMapper.x) {
      var gq = [];
      for (var q = 0; q < shapeMapper.x.length; q++) gq.push([q, shapeMapper.size[q], shapeMapper.lens[q].toFixed(3)]);
      el.innerHTML = tab(["node", "size", "lens"], gq);
    } else if (shapeView === "time" && shapeTime && shapeTime.frac) {
      var tq = [];
      for (var t = 0; t < shapeTime.frac.length; t++) tq.push([Math.round(shapeTime.frac[t] * 100) + "%", shapeTime.n[t], shapeTime.b0[t], shapeTime.b1[t], shapeTime.b2[t]]);
      el.innerHTML = tab(["run", "n", "b0", "b1", "b2"], tq);
    } else if (shapeView === "density" && shapeDensity) {
      el.innerHTML = tab(["bandwidth", "grid", "levels", "points"], [[SHAPE_BW, shapeDensity.n + "²", shapeLevels().length, shapeDensity.count]]);
    } else {
      el.textContent = "No view computed yet.";
    }
  }

  function shapeExpMethods() {
    function cfg(k, fb) {
      try {
        if (lastState && lastState.cfg && lastState.cfg[k] !== undefined && lastState.cfg[k] !== "") return lastState.cfg[k];
      } catch (e) {}
      return fb;
    }
    function apiv(k) {
      try {
        if (lastState && lastState.api && lastState.api[k] !== undefined) return lastState.api[k];
      } catch (e) {}
      return null;
    }
    var ver = (lastState && lastState.version) || "unknown";
    var live = !!(lastState && lastState.live);
    var model = cfg("model", live ? "unknown-model" : "sim");
    var parts = [];
    parts.push("Latent-space survey with MetaMining " + ver + " (" + (live ? "live backend, model " + model : "deterministic sim backend") + ").");
    parts.push('Seed concept: "' + cfg("concept", "?") + '".');
    parts.push("Protocol: " + cfg("branches", "?") + " branches x " + cfg("steps", "?") +
      " steps (push " + cfg("push", "?") + ", fanout " + cfg("fanout", "?") + ", temp " +
      cfg("temp", "?") + ", seed " + cfg("seed", "?") + "); stop: " +
      ((lastState && lastState.stop_reason) || "?") + ".");
    var nf = (lastState && typeof lastState.findings === "number") ? lastState.findings : points.length;
    var ng = (lastState && typeof lastState.gold === "number") ? lastState.gold : 0;
    parts.push("Yield: " + nf + " findings, " + ng + " gold.");
    var sh = [];
    if (shapeMerge && shapeMerge.nov) sh.push(shapeBasinOrder.length + " merge-tree basins");
    if (shapeBars && shapeBars.dim) {
      var c0 = 0, c1 = 0, c2 = 0, s1 = 0;
      for (var i = 0; i < shapeBars.dim.length; i++) {
        if (shapeBars.dim[i] === 0) c0++;
        else if (shapeBars.dim[i] === 1) { c1++; if (shapeBars.support && shapeBars.support[i] >= 0.5) s1++; }
        else c2++;
      }
      sh.push("barcode H0/H1/H2 " + c0 + "/" + c1 + "/" + c2 +
        (shapeBars.support ? " (" + s1 + " H1 stable)" : "") + " [" + (shapeBars.metric || "cosine") + "]");
    }
    if (shapeLoops && shapeLoops.loops) sh.push("map loops b1=" + shapeLoops.b1 + (shapeLoops.has_void ? " with void" : ", no void"));
    if (shapeMapper && shapeMapper.x) sh.push("Mapper " + shapeMapper.x.length + " nodes/" + shapeMapper.la.length + " links");
    if (shapeTime && shapeTime.frac) {
      var li = shapeTime.b1.length - 1;
      sh.push("timeline latest b0/b1/b2 " + shapeTime.b0[li] + "/" + shapeTime.b1[li] + "/" + shapeTime.b2[li]);
    }
    parts.push(sh.length > 0 ? "Shape: " + sh.join("; ") + "." : "Shape views not computed.");
    var calls = apiv("calls"), tin = apiv("tin"), tout = apiv("tout"), cost = apiv("cost");
    if (calls !== null || tin !== null) {
      parts.push("Cost: " + (calls === null ? "?" : calls) + " calls, " +
        (tin === null ? "?" : tin) + "/" + (tout === null ? "?" : tout) +
        " tokens" + (cost === null ? "" : " (~$" + cost + ")") + ".");
    }
    parts.push("Exported " + new Date().toISOString() + "; run " +
      ((typeof currentRun === "number" && currentRun >= 0) ? currentRun : 0) + ".");
    var text = parts.join(" ");
    function done(ok) { toast(ok ? "methods paragraph copied" : "copy failed — see console", false, !ok); if (!ok) { try { console.log(text); } catch (e2) {} } }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(copyFallback(text)); });
      } else done(copyFallback(text));
    } catch (e) { done(false); }
  }

  function shapeExpSVG() {
    var VW = 640, VH = 150;
    var out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + VW + " " + VH + '">'];
    out.push('<rect width="640" height="150" fill="#0d1117"/>');
    function esc(s) { return String(s); }
    if (shapeView === "merge" && shapeMerge && shapeMerge.nov) {
      var m = shapeMerge, nmax = 0.001, i;
      for (i = 0; i < m.nov.length; i++) if (m.nov[i] > nmax) nmax = m.nov[i];
      for (i = 0; i < m.la.length; i++) {
        out.push('<line x1="' + (30 + m.tx[m.la[i]] * 600).toFixed(1) + '" y1="' + (10 + (1 - m.nov[m.la[i]] / nmax) * 122).toFixed(1) +
          '" x2="' + (30 + m.tx[m.lb[i]] * 600).toFixed(1) + '" y2="' + (10 + (1 - m.nov[m.lb[i]] / nmax) * 122).toFixed(1) + '" stroke="#6aa8d8" stroke-opacity="0.6"/>');
      }
      for (i = 0; i < m.nov.length; i++) {
        var pk = i < m.n && m.peak[i];
        out.push('<circle cx="' + (30 + m.tx[i] * 600).toFixed(1) + '" cy="' + (10 + (1 - m.nov[i] / nmax) * 122).toFixed(1) +
          '" r="' + (1.2 + 2.4 * Math.sqrt(m.size[i] / Math.max(1, m.n))).toFixed(1) + '" fill="' + (pk ? "#e8b34e" : "#6aa8d8") + '"/>');
      }
      out.push('<text x="8" y="145" fill="#5c6474" font-size="9" font-family="monospace">merge tree n=' + m.n + "</text>");
    } else if (shapeView === "bars" && shapeBars && shapeBars.dim) {
      var b = shapeBars, cols = ["#4cc2a8", "#e8b34e", "#b48cff"], dmax = 0.001, j;
      for (j = 0; j < b.dim.length; j++) if (b.death[j] >= 0 && b.death[j] > dmax) dmax = b.death[j];
      var ord = [[], [], []];
      for (j = 0; j < b.dim.length; j++) ord[b.dim[j]].push(j);
      var rows = [];
      for (var g = 0; g < 3; g++) { var grp = ord[g].slice(0, 24); for (var k = 0; k < grp.length; k++) rows.push(grp[k]); }
      var rh = Math.min(9, 84 / Math.max(1, rows.length));
      for (var q = 0; q < rows.length; q++) {
        var bi2 = rows[q], y = 8 + q * rh;
        var x0 = 30 + (b.birth[bi2] / dmax) * 594, x1 = b.death[bi2] < 0 ? 624 : 30 + (b.death[bi2] / dmax) * 594;
        var sw = Math.max(1, rh * ((b.support && b.support[bi2] >= 0.5) ? 0.8 : 0.45));
        out.push('<line x1="' + x0.toFixed(1) + '" y1="' + y.toFixed(1) + '" x2="' + x1.toFixed(1) + '" y2="' + y.toFixed(1) +
          '" stroke="' + cols[b.dim[bi2]] + '" stroke-width="' + sw.toFixed(1) + '"/>');
      }
      out.push('<text x="8" y="145" fill="#5c6474" font-size="9" font-family="monospace">barcode ' + esc(b.metric || "cosine") + " n=" + b.n + "</text>");
    } else if (shapeView === "loops" && shapeLoops && shapeLoops.loops) {
      var lp = shapeLoops;
      function LX(v) { return 30 + (v / 100) * 600; }
      function LY(v) { return 8 + (1 - v / 100) * 124; }
      for (var li2 = 0; li2 < lp.loops.length; li2++) {
        var mem = shapeLoopMembers(lp.loops[li2]), pts = [];
        for (var mj = 0; mj < mem.length; mj++) pts.push(LX(mem[mj].x).toFixed(1) + "," + LY(mem[mj].y).toFixed(1));
        if (pts.length > 2) out.push('<polygon points="' + pts.join(" ") + '" fill="none" stroke="#9dbb65" stroke-width="1.5"/>');
      }
      if (lp.has_void) out.push('<circle cx="' + LX(lp.void_x).toFixed(1) + '" cy="' + LY(lp.void_y).toFixed(1) + '" r="' + (lp.void_r * 6).toFixed(1) + '" fill="none" stroke="#b48cff" stroke-dasharray="4 3"/>');
      out.push('<text x="8" y="145" fill="#5c6474" font-size="9" font-family="monospace">loops b1=' + lp.b1 + "</text>");
    } else if (shapeView === "density" && shapeDensity) {
      var dn = shapeDensity, segs = shapeContourSegs(dn.grid, dn.n, shapeLevels()), dpath = "";
      for (var s = 0; s < segs.length; s++) {
        dpath += "M" + (30 + (segs[s][0][0] / (dn.n - 1)) * 600).toFixed(1) + " " + (8 + (segs[s][0][1] / (dn.n - 1)) * 124).toFixed(1) +
          "L" + (30 + (segs[s][1][0] / (dn.n - 1)) * 600).toFixed(1) + " " + (8 + (segs[s][1][1] / (dn.n - 1)) * 124).toFixed(1);
      }
      out.push('<path d="' + dpath + '" fill="none" stroke="#e8b34e" stroke-opacity="0.8"/>');
      out.push('<text x="8" y="145" fill="#5c6474" font-size="9" font-family="monospace">density contours n=' + dn.count + "</text>");
    } else if (shapeView === "mapper" && shapeMapper && shapeMapper.x) {
      var mp = shapeMapper, lmax = 0.001, a2;
      for (a2 = 0; a2 < mp.lens.length; a2++) if (mp.lens[a2] > lmax) lmax = mp.lens[a2];
      for (a2 = 0; a2 < mp.la.length; a2++) {
        out.push('<line x1="' + (30 + mp.x[mp.la[a2]] * 6).toFixed(1) + '" y1="' + (8 + (1 - mp.y[mp.la[a2]] / 100) * 124).toFixed(1) +
          '" x2="' + (30 + mp.x[mp.lb[a2]] * 6).toFixed(1) + '" y2="' + (8 + (1 - mp.y[mp.lb[a2]] / 100) * 124).toFixed(1) + '" stroke="#6aa8d8" stroke-opacity="0.55"/>');
      }
      for (var nd = 0; nd < mp.x.length; nd++) {
        out.push('<circle cx="' + (30 + mp.x[nd] * 6).toFixed(1) + '" cy="' + (8 + (1 - mp.y[nd] / 100) * 124).toFixed(1) +
          '" r="' + (2.5 + 2.2 * Math.sqrt(mp.size[nd])).toFixed(1) + '" fill="#4cc2a8" fill-opacity="0.9"/>');
      }
      out.push('<text x="8" y="145" fill="#5c6474" font-size="9" font-family="monospace">mapper nodes=' + mp.x.length + "</text>");
    } else if (shapeView === "time" && shapeTime && shapeTime.frac) {
      var tm = shapeTime, tc = ["#4cc2a8", "#e8b34e", "#b48cff"], tmax = 1, ti;
      for (ti = 0; ti < tm.b0.length; ti++) tmax = Math.max(tmax, tm.b0[ti], tm.b1[ti], tm.b2[ti]);
      var tser = [tm.b0, tm.b1, tm.b2];
      for (var tu = 0; tu < 3; tu++) {
        var tpts = [];
        for (var tv = 0; tv < tm.frac.length; tv++) tpts.push((30 + tm.frac[tv] * 600).toFixed(1) + "," + (8 + 124 - (tser[tu][tv] / tmax) * 124).toFixed(1));
        out.push('<polyline points="' + tpts.join(" ") + '" fill="none" stroke="' + tc[tu] + '" stroke-width="1.4"/>');
      }
      out.push('<text x="8" y="145" fill="#5c6474" font-size="9" font-family="monospace">timeline total=' + tm.total + "</text>");
    } else {
      toast("nothing to export — compute a view first", false, true);
      return;
    }
    out.push("</svg>");
    shapeDownload("metamining-" + shapeRunTag() + "-" + shapeStamp() + "-shape-" + shapeView + ".svg",
      new Blob([out.join("\n")], { type: "image/svg+xml" }));
    toast("shape SVG exported (" + shapeView + ")", false);
  }

  function wireShape() {
    var e = shapeEls();
    if (!e.view || !e.cv) return;
    function syncCtls() {
      var ids = ["merge", "bars", "loops", "density", "mapper", "time"];
      for (var i = 0; i < ids.length; i++) {
        var c = document.getElementById("shape-ctls-" + ids[i]);
        if (c) c.hidden = (ids[i] !== shapeView);
      }
    }
    e.view.addEventListener("change", function () {
      shapeView = e.view.value;
      syncCtls();
      shapeFetch();
    });
    if (e.btn) e.btn.addEventListener("click", shapeFetch);
    if (e.basin) e.basin.addEventListener("change", function () {
      shapeBasinOn = e.basin.checked;
      drawShape();
      drawScatter();
    });
    if (e.loopsOl) e.loopsOl.addEventListener("change", function () {
      shapeLoopsOl = e.loopsOl.checked;
      drawScatter();
    });
    if (e.contourOl) e.contourOl.addEventListener("change", function () {
      shapeContourOl = e.contourOl.checked;
      drawScatter();
    });
    if (e.levels) e.levels.addEventListener("change", function () {
      drawShape();
      drawScatter();
    });
    if (e.bins) e.bins.addEventListener("change", shapeFetch);
    if (e.overlap) e.overlap.addEventListener("change", shapeFetch);
    if (e.metric) e.metric.addEventListener("change", function () { if (shapeView === "bars") shapeFetch(); });
    if (e.conf) e.conf.addEventListener("change", function () { if (shapeView === "bars") shapeFetch(); });
    if (e.live) e.live.addEventListener("change", function () {
      shapeLive = e.live.checked;
      if (shapeLive) shapeFetch();
    });
    setInterval(function () { if (shapeLive) { try { shapeFetch(); } catch (e2) {} } }, 12000);
    var xb = document.getElementById("shape-exp-bundle");
    if (xb) xb.addEventListener("click", shapeExpBundle);
    var xc = document.getElementById("shape-exp-csv");
    if (xc) xc.addEventListener("click", shapeExpCSV);
    var xm = document.getElementById("shape-exp-mappng");
    if (xm) xm.addEventListener("click", function () { shapeExpPNG("scatter", "map"); });
    var xs = document.getElementById("shape-exp-shapepng");
    if (xs) xs.addEventListener("click", function () { shapeExpPNG("shape-canvas", "shape"); });
    var xv = document.getElementById("shape-exp-shapesvg");
    if (xv) xv.addEventListener("click", shapeExpSVG);
    var xm2 = document.getElementById("shape-exp-methods");
    if (xm2) xm2.addEventListener("click", shapeExpMethods);
    var st = document.getElementById("shape-teleport");
    if (st) st.addEventListener("click", function () {
      var pk = shapePeakPick();
      if (pk < 0) { toast("compute the merge tree first", false, true); return; }
      var be = document.getElementById("shape-branch");
      var bid = be ? (parseInt(be.value, 10) || 0) : 0;
      shapeTeleportMacro(bid, shapePeakText(pk), "basin peak");
    });
    var sc = document.getElementById("shape-corroborate");
    if (sc) sc.addEventListener("click", shapeCorroborate);
    var sp = document.getElementById("shape-probe");
    if (sp) sp.addEventListener("click", shapeSuggestProbe);
    var sg = document.getElementById("shape-probego");
    if (sg) sg.addEventListener("click", function () {
      if (!shapeProbe) { toast("suggest a probe first", false, true); return; }
      var be2 = document.getElementById("shape-probebranch");
      var bid2 = be2 ? (parseInt(be2.value, 10) || 0) : 0;
      shapeTeleportMacro(bid2, shapeProbe.text, "probe candidate");
    });
    syncCtls();
    try { shapeFetch(); } catch (e2) {}
  }
  try { wireShape(); } catch (err) {}

  window.addEventListener("resize", function () { drawScatter(); drawTelemetry(); try { drawShape(); } catch (e) {} });
  syncScrub();
  drawScatter();
  drawTelemetry();
  connect();
  loadModels();
  backfill();
})();

/* Stage W-adv: veins, queue, search, per-branch models, fanout/judges/auto, tree, run-diff.
   Defensive: every new endpoint may 404 on older servers; hide its panel, never throw. */
(function () {
  "use strict";

  function $(id) { return document.getElementById(id); }
  function num(v, d) { return (typeof v === "number" && !isNaN(v)) ? v : d; }
  function str(v) { return (typeof v === "string") ? v : ""; }
  function dsp(v) { return (v === undefined || v === null) ? "?" : String(v); }
  function trunc(s, n) { s = str(s); return s.length > n ? s.substring(0, n) + "..." : s; }

  function toast(msg, gold, sticky) {
    try {
      if (typeof window.mmToast === "function") { window.mmToast(msg, gold, sticky); return; }
      var box = $("toasts");
      if (!box) return;
      var t = document.createElement("div");
      t.className = "toast" + (gold ? " gold" : "") + (sticky ? " err" : "");
      t.textContent = msg;
      box.appendChild(t);
      while (box.children.length > 4) box.removeChild(box.firstChild);
      if (sticky) {
        t.addEventListener("click", function () { if (t.parentNode) t.parentNode.removeChild(t); });
        return;
      }
      setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 2600);
    } catch (e) {}
  }

  function hideSection(panelId) {
    try {
      var p = $(panelId);
      if (!p) return;
      p.hidden = true;
      p.style.display = "none";
      var h = p.previousElementSibling;
      if (h && h.tagName === "H2") h.style.display = "none";
    } catch (e) {}
  }

  function emptyBox(el, msg) {
    el.innerHTML = "";
    var em = document.createElement("div");
    em.className = "empty";
    em.textContent = msg;
    el.appendChild(em);
  }

  function getJSON(url, ok, fail) {
    var fb = (typeof fail === "function") ? fail : function () {};
    fetch(url).then(function (r) {
      if (r.status === 404) { try { fb(404); } catch (e) {} return null; }
      if (!r.ok) { try { fb(r.status); } catch (e) {} return null; }
      return r.json();
    }).then(function (d) {
      if (d === null || d === undefined) return;
      try { ok(d); } catch (e) {}
    }).catch(function () { try { fb(-1); } catch (e) {} });
  }

  /* Capability tracking: when every new endpoint 404s the server predates the
     advanced features, so controls that only POST new actions are disabled. */
  var cap404 = {};
  function capMark(name, code) {
    try {
      if (code === 404) cap404[name] = true;
      else if (code !== -1) cap404[name] = false;
      var names = ["veins", "queue", "search", "tree"], i;
      for (i = 0; i < names.length; i++) {
        if (cap404[names[i]] !== true) return;
      }
      var a = $("auto-toggle");
      if (a && !a.disabled) { a.disabled = true; a.title = "Requires a newer server"; }
      var smf0 = $("setmodel-form");
      var sm = smf0 ? smf0.querySelector("button[type=submit]") : null;
      if (sm && !sm.disabled) { sm.disabled = true; sm.title = "Requires a newer server"; }
    } catch (e) {}
  }

  /* ---- (a) vein memory panel ---- */
  var veinsDead = false;
  function refreshVeins() {
    if (veinsDead || !$("veins-panel")) return;
    getJSON("/api/veins", function (d) {
      capMark("veins", 200);
      var list = $("veins-list"), count = $("veins-count");
      var veins = (d && d.veins) || [];
      if (count) count.textContent = veins.length + " vein" + (veins.length === 1 ? "" : "s") + " in memory";
      if (!list) return;
      list.innerHTML = "";
      if (veins.length === 0) { emptyBox(list, "No veins stored yet."); return; }
      var show = veins.slice(-60).reverse();
      for (var i = 0; i < show.length; i++) {
        var v = show[i] || {};
        var card = document.createElement("div");
        card.className = "vein-mem";
        var head = document.createElement("div");
        head.className = "vein-mem-head";
        var id = document.createElement("span");
        id.className = "vein-mem-id";
        id.textContent = "vein " + dsp(v.id);
        var sc = document.createElement("span");
        sc.className = "vein-mem-scores";
        sc.textContent = "nov " + num(v.novelty, 0).toFixed(3) + " · coh " + num(v.coherence, 0).toFixed(1);
        head.appendChild(id); head.appendChild(sc);
        card.appendChild(head);
        var tx = document.createElement("div");
        tx.className = "vein-mem-text";
        tx.textContent = trunc(v.text, 160);
        card.appendChild(tx);
        var meta = document.createElement("div");
        meta.className = "vein-mem-meta";
        meta.textContent = "b" + (v.branch === undefined ? "?" : v.branch) +
          " s" + (v.step === undefined ? "?" : v.step) +
          " · run " + (v.run === undefined ? "?" : v.run) +
          " · src " + str(v.src || "?");
        card.appendChild(meta);
        list.appendChild(card);
      }
    }, function (code) {
      capMark("veins", code);
      if (code === 404) { veinsDead = true; hideSection("veins-panel"); }
    });
  }

  /* ---- (a) related veins in node modal ---- */
  var relatedDead = false, relatedKey = "";
  function loadRelated(branch, step) {
    var box = $("modal-related"), list = $("related-list");
    if (!box || !list) return;
    if (relatedDead) { box.hidden = true; return; }
    /* F4web: the server 404s related-veins for findings outside the live
       cache (vein/journal search hits), so skip the fetch entirely. */
    if (typeof window.__wadvCached === "function") {
      try {
        if (!window.__wadvCached(branch, step)) { box.hidden = true; return; }
      } catch (e) {}
    }
    var key = branch + ":" + step;
    relatedKey = key;
    getJSON("/api/related?branch=" + encodeURIComponent(branch) + "&step=" + encodeURIComponent(step), function (d) {
      if (relatedKey !== key) return;
      var items = (d && d.items) || [];
      list.innerHTML = "";
      if (items.length === 0) { box.hidden = true; return; }
      for (var i = 0; i < items.length; i++) {
        var v = items[i] || {};
        var card = document.createElement("div");
        card.className = "vein-mem";
        var head = document.createElement("div");
        head.className = "vein-mem-head";
        var id = document.createElement("span");
        id.className = "vein-mem-id";
        id.textContent = "vein " + dsp(v.id);
        var sc = document.createElement("span");
        sc.className = "vein-mem-scores";
        sc.textContent = "score " + num(v.score, 0).toFixed(3);
        head.appendChild(id); head.appendChild(sc);
        card.appendChild(head);
        var tx = document.createElement("div");
        tx.className = "vein-mem-text";
        tx.textContent = trunc(v.text, 200);
        card.appendChild(tx);
        var meta = document.createElement("div");
        meta.className = "vein-mem-meta";
        meta.textContent = "nov " + num(v.novelty, 0).toFixed(3) +
          " · coh " + num(v.coherence, 0).toFixed(1) + " · src " + str(v.src || "?");
        card.appendChild(meta);
        list.appendChild(card);
      }
      box.hidden = false;
    }, function (code) {
      if (relatedKey !== key) return;
      box.hidden = true;
      if (code === 404) relatedDead = true;
    });
  }
  try {
    var mtitle = $("modal-title");
    if (mtitle && window.MutationObserver) {
      var obs = new MutationObserver(function () {
        try {
          var m = /b(\d+)\s+s(\d+)/.exec(mtitle.textContent || "");
          var modal = $("node-modal");
          if (m && modal && !modal.hidden) loadRelated(Number(m[1]), Number(m[2]));
        } catch (e) {}
      });
      obs.observe(mtitle, { childList: true, characterData: true, subtree: true });
    }
  } catch (e) {}

  /* ---- (b) run queue panel ---- */
  var queueDead = false, queueSyncing = false;
  function refreshQueue() {
    if (queueDead || !$("queue-panel")) return;
    getJSON("/api/queue", function (d) {
      capMark("queue", 200);
      var q = (d && d.queue) || [];
      var aq = $("queue-autoque");
      if (aq && !queueSyncing) aq.checked = !!(d && d.autoque);
      var count = $("queue-count");
      if (count) count.textContent = q.length + " run" + (q.length === 1 ? "" : "s") + " queued";
      var list = $("queue-list");
      if (!list) return;
      list.innerHTML = "";
      if (q.length === 0) { emptyBox(list, "Queue is empty."); return; }
      for (var i = 0; i < q.length; i++) {
        var it = q[i] || {};
        var card = document.createElement("div");
        card.className = "queue-item " + str(it.status || "queued");
        var head = document.createElement("div");
        head.className = "queue-item-head";
        var id = document.createElement("span");
        id.className = "queue-item-id";
        id.textContent = "run " + dsp(it.id);
        var st = document.createElement("span");
        st.className = "queue-status " + str(it.status || "queued");
        st.textContent = str(it.status || "queued");
        head.appendChild(id); head.appendChild(st);
        card.appendChild(head);
        var cx = document.createElement("div");
        cx.className = "queue-item-concept";
        cx.textContent = trunc(it.concept, 160);
        card.appendChild(cx);
        var meta = document.createElement("div");
        meta.className = "queue-item-meta";
        meta.textContent = "model " + str(it.model || "default") +
          " · branches " + (it.branches === undefined ? "?" : it.branches) +
          " · steps " + (it.steps === undefined ? "?" : it.steps);
        card.appendChild(meta);
        list.appendChild(card);
      }
    }, function (code) {
      capMark("queue", code);
      if (code === 404) { queueDead = true; hideSection("queue-panel"); }
    });
  }
  /* queue-form / autoque / clearqueue post via hx-post; the server answers
     HX-Trigger mm-toast + mm-adv-refresh, so no manual fetch/toast here. */

  /* ---- (c) search ---- */
  var searchDead = false;
  function renderSearch(items, query) {
    var count = $("search-count"), box = $("search-results");
    if (count) count.textContent = items.length + " result" + (items.length === 1 ? "" : "s") + ' for "' + query + '"';
    if (!box) return;
    box.innerHTML = "";
    if (items.length === 0) {
      var em = document.createElement("li");
      em.className = "sys-line";
      em.textContent = "No matches.";
      box.appendChild(em);
      return;
    }
    for (var i = 0; i < items.length; i++) {
      var it = items[i] || {};
      var li = document.createElement("li");
      li.className = "feed-entry" + (it.gold ? " gold-entry" : "");
      var head = document.createElement("div");
      head.className = "entry-head";
      var id = document.createElement("span");
      id.className = "entry-id";
      id.textContent = "b" + (it.branch === undefined ? "?" : it.branch) +
        " s" + (it.step === undefined ? "?" : it.step) +
        " · nov " + num(it.novelty, 0).toFixed(3) +
        " · coh " + num(it.coherence, 0).toFixed(1) +
        " · score " + num(it.score, 0).toFixed(3);
      head.appendChild(id);
      li.appendChild(head);
      var tx = document.createElement("div");
      tx.className = "entry-text";
      tx.textContent = trunc(it.text, 220);
      li.appendChild(tx);
      var tags = document.createElement("div");
      tags.className = "entry-tags";
      var any = false;
      function tag(t, cls) {
        var s = document.createElement("span");
        s.className = "tag" + (cls ? " " + cls : "");
        s.textContent = t;
        tags.appendChild(s);
        any = true;
      }
      if (it.gold) tag("GOLD", "gold-tag");
      if (it.src) tag("src " + it.src, "dim-tag");
      if (any) li.appendChild(tags);
      (function (item) {
        li.addEventListener("click", function () {
          try {
            if (typeof window.openFindingItem === "function") window.openFindingItem(item);
            else if (typeof item.branch === "number" && typeof item.step === "number") window.openFinding(item.branch, item.step);
          } catch (e) {}
        });
      })(it);
      box.appendChild(li);
    }
  }
  function runSearch() {
    if (searchDead) return;
    var q = $("search-q");
    var query = q ? str(q.value).trim() : "";
    if (!query) return;
    getJSON("/api/search?q=" + encodeURIComponent(query) + "&limit=20", function (d) {
      capMark("search", 200);
      renderSearch((d && d.items) || [], query);
    }, function (code) {
      capMark("search", code);
      if (code === 404) { searchDead = true; hideSection("search-panel"); }
      else { var c = $("search-count"); if (c) c.textContent = "Search failed."; }
    });
  }
  var sbtn = $("search-btn"), sipt = $("search-q");
  if (sbtn) sbtn.addEventListener("click", runSearch);
  if (sipt) sipt.addEventListener("keydown", function (e) { if (e.key === "Enter") { e.preventDefault(); runSearch(); } });
  function probeSearch() {
    if (!$("search-panel")) return;
    getJSON("/api/search?q=wadv&limit=1", function () { capMark("search", 200); }, function (code) {
      capMark("search", code);
      if (code === 404) { searchDead = true; hideSection("search-panel"); }
    });
  }

  /* ---- (d) per-branch setmodel order (hx-post; HX-Trigger toast) ---- */

  /* ---- (e) fanout/judges sliders + auto-tune toggle ---- */
  var tuneDrag = {};
  function wireAdvSlider(id, out) {
    var el = $(id), lab = $(out);
    if (!el || !lab) return;
    el.addEventListener("input", function () { lab.textContent = String(Math.round(Number(el.value))); });
    el.addEventListener("mousedown", function () { tuneDrag[id] = true; });
    el.addEventListener("touchstart", function () { tuneDrag[id] = true; });
    el.addEventListener("mouseup", function () { tuneDrag[id] = false; });
    el.addEventListener("touchend", function () { tuneDrag[id] = false; });
  }
  function setAdvSlider(id, out, v) {
    var el = $(id), lab = $(out);
    if (!el || !lab || typeof v !== "number" || isNaN(v)) return;
    el.value = String(Math.round(v));
    lab.textContent = String(Math.round(Number(el.value)));
  }
  wireAdvSlider("tune-fanout", "tune-fanout-v");
  wireAdvSlider("tune-judges", "tune-judges-v");
  var autoDirtyUntil = 0;
  /* auto-toggle + autoque post via hx-post; guard the server-echo syncs
     while their requests are in flight. */
  document.body.addEventListener("htmx:beforeRequest", function (e) {
    try {
      var f = e.detail && e.detail.elt;
      if (!f || !f.querySelector) return;
      if (f.querySelector("#auto-toggle")) autoDirtyUntil = Date.now() + 3000;
      if (f.querySelector("#queue-autoque")) queueSyncing = true;
    } catch (_) {}
  });
  document.body.addEventListener("htmx:afterRequest", function (e) {
    try {
      var f = e.detail && e.detail.elt;
      if (f && f.querySelector && f.querySelector("#queue-autoque")) queueSyncing = false;
    } catch (_) {}
  });
  function renderAutoWorkers(workers) {
    var box = $("auto-workers");
    if (!box) return;
    if (!workers || !workers.length) { box.hidden = true; return; }
    var any = false, i;
    for (i = 0; i < workers.length; i++) {
      if (workers[i] && workers[i].auto !== undefined) { any = true; break; }
    }
    if (!any) { box.hidden = true; return; }
    box.innerHTML = "";
    for (var j = 0; j < workers.length; j++) {
      var w = workers[j] || {};
      var chip = document.createElement("span");
      chip.className = "auto-chip" + (w.auto ? " on" : "");
      var wbr = (w.branch !== undefined) ? w.branch : w.bid;
      chip.textContent = "b" + (wbr === undefined ? j : wbr) + " auto " + (w.auto ? "on" : "off") +
        (w.model ? " · " + w.model : "");
      box.appendChild(chip);
    }
    box.hidden = false;
  }
  function syncAdvState() {
    getJSON("/api/state", function (st) {
      if (!st) return;
      if (st.cfg) {
        if (!tuneDrag["tune-fanout"] && typeof st.cfg.fanout === "number") setAdvSlider("tune-fanout", "tune-fanout-v", st.cfg.fanout);
        if (!tuneDrag["tune-judges"] && typeof st.cfg.judges === "number") setAdvSlider("tune-judges", "tune-judges-v", st.cfg.judges);
        var a = $("auto-toggle");
        if (a && Date.now() > autoDirtyUntil && st.cfg.auto !== undefined) a.checked = !!st.cfg.auto;
      }
      renderAutoWorkers(st.workers);
    });
  }

  /* ---- (f) genealogy tree ---- */
  var treeDead = false;
  function renderTree(nodes) {
    var box = $("tree-view"), count = $("tree-count");
    if (count) count.textContent = nodes.length + " node" + (nodes.length === 1 ? "" : "s");
    if (!box) return;
    box.innerHTML = "";
    if (nodes.length === 0) { emptyBox(box, "No genealogy yet."); return; }
    var byBid = {}, i;
    for (i = 0; i < nodes.length; i++) {
      if (nodes[i] && nodes[i].bid !== undefined) byBid[nodes[i].bid] = nodes[i];
    }
    function depthOf(n) {
      var d = 0, cur = n, seen = {};
      while (cur && cur.parent !== -1 && cur.parent !== undefined && d < 32) {
        if (seen[cur.parent]) break;
        seen[cur.parent] = 1;
        cur = byBid[cur.parent];
        if (!cur) break;
        d++;
      }
      return d;
    }
    for (var k = 0; k < nodes.length; k++) {
      var n = nodes[k] || {};
      var row = document.createElement("div");
      row.className = "tree-node";
      row.style.paddingLeft = String(depthOf(n) * 18) + "px";
      var kind = document.createElement("span");
      var kk = str(n.kind || "seed");
      kind.className = "tree-kind " + (kk === "gold" ? "gold" : kk === "respawn" ? "respawn" : "seed");
      kind.textContent = kk;
      row.appendChild(kind);
      var bid = document.createElement("span");
      bid.className = "tree-bid";
      bid.textContent = "b" + (n.bid === undefined ? "?" : n.bid) +
        (typeof n.step === "number" ? " s" + n.step : "");
      row.appendChild(bid);
      if (n.parent !== -1 && n.parent !== undefined) {
        var par = document.createElement("span");
        par.className = "tree-parent";
        par.textContent = "  <- b" + n.parent;
        row.appendChild(par);
      }
      box.appendChild(row);
    }
  }
  function refreshTree() {
    if (treeDead || !$("tree-panel")) return;
    getJSON("/api/tree", function (d) {
      capMark("tree", 200);
      renderTree((d && d.nodes) || []);
    }, function (code) {
      capMark("tree", code);
      if (code === 404) { treeDead = true; hideSection("tree-panel"); }
    });
  }

  /* ---- (g) run-diff overlay ---- */
  /* F4web: coord-less entries are skipped (never fabricated); the caller
     reports how many lacked coords. */
  function normDiffEntries(entries) {
    var out = [], skipped = 0;
    for (var i = 0; i < entries.length && out.length < 2000; i++) {
      var e = entries[i] || {};
      var x = e.x, y = e.y;
      if (typeof x !== "number" || typeof y !== "number" || isNaN(x) || isNaN(y)) { skipped++; continue; }
      out.push({ x: x, y: y, gold: !!e.gold });
    }
    return { points: out, skipped: skipped };
  }
  function setDiff(name, points, skipped) {
    window.__wadvDiff = (points && points.length) ? { name: name, points: points } : null;
    var leg = $("diff-legend"), st = $("diff-status");
    if (leg && st) {
      if (points && points.length) {
        leg.hidden = false;
        st.textContent = "diff: " + name + " (" + points.length + " pts" +
          ((typeof skipped === "number" && skipped > 0) ? ", " + skipped + " lack coords" : "") + ")";
      } else leg.hidden = true;
    }
    try { if (typeof window.__wadvRefresh === "function") window.__wadvRefresh(); } catch (e) {}
  }
  function updateDiff() {
    var sel = $("diff-journal"), tog = $("diff-toggle");
    var name = sel ? str(sel.value) : "";
    var on = tog ? !!tog.checked : false;
    if (!on || !name) { setDiff(null, null); return; }
    getJSON("/api/journal_file?name=" + encodeURIComponent(name), function (d) {
      var sel2 = $("diff-journal"), tog2 = $("diff-toggle");
      if (!sel2 || str(sel2.value) !== name || !tog2 || !tog2.checked) return;
      var entries = (d && d.entries) || [];
      if (entries.length === 0) { setDiff(null, null); toast("Journal has no entries", false); return; }
      var norm = normDiffEntries(entries);
      if (norm.points.length === 0) {
        setDiff(null, null);
        var leg0 = $("diff-legend"), st0 = $("diff-status");
        if (leg0 && st0) { leg0.hidden = false; st0.textContent = norm.skipped + " entries lack coords"; }
        else toast("Journal entries lack coords", false);
        return;
      }
      setDiff(name, norm.points, norm.skipped);
    }, function () {
      var t = $("diff-toggle");
      if (t) t.checked = false;
      setDiff(null, null);
      var leg = $("diff-legend"), st = $("diff-status");
      if (leg && st) { leg.hidden = false; st.textContent = "run diff not supported by this server"; }
    });
  }
  function loadDiffJournals() {
    getJSON("/api/journals", function (d) {
      var sel = $("diff-journal");
      if (!sel) return;
      var js = (d && d.journals) || [];
      sel.innerHTML = "";
      var none = document.createElement("option");
      none.value = "";
      none.textContent = "-- none --";
      sel.appendChild(none);
      for (var i = 0; i < js.length; i++) {
        var o = document.createElement("option");
        o.value = str(js[i].filename || "");
        o.textContent = str(js[i].starting_concept || js[i].filename || "?") + " (" + str(js[i].filename || "?") + ")";
        sel.appendChild(o);
      }
    });
  }
  var dsel = $("diff-journal"), dtog = $("diff-toggle");
  if (dsel) dsel.addEventListener("change", updateDiff);
  if (dtog) dtog.addEventListener("change", updateDiff);

  function refreshAdv() {
    try { refreshVeins(); } catch (e) {}
    try { refreshQueue(); } catch (e) {}
    try { refreshTree(); } catch (e) {}
    try { syncAdvState(); } catch (e) {}
  }
  document.body.addEventListener("mm-adv-refresh", function () {
    refreshAdv();
    try { loadDiffJournals(); } catch (e) {}
  });
  document.body.addEventListener("mm:adv", refreshAdv);

  /* ---- init + poll ---- */
  try { refreshVeins(); } catch (e) {}
  try { refreshQueue(); } catch (e) {}
  try { refreshTree(); } catch (e) {}
  try { probeSearch(); } catch (e) {}
  try { syncAdvState(); } catch (e) {}
  try { loadDiffJournals(); } catch (e) {}
  setInterval(refreshAdv, 30000);
})();
