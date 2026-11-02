"""Coordinator: HTTP server + worker herd + run state + SSE fan-out.

One process, one poll loop. Workers are forked children (Mojo 1.2
ships no threads); each owns a frontier branch and reports over a
pipe. The dashboard polls HTML fragments (HTMX) and streams findings
(SSE + JSON).
"""

from std.math import isinf, isnan

from metamining.endpoint import (
    MetaCfg,
    embed_input,
    meta_embed,
    meta_models,
    model_known,
    model_rates,
    model_rates_over,
)
from metamining.explorer import (
    ExpCfg,
    Finding,
    buf_find_nl,
    global_should_stop,
    msg_int,
    msg_kind,
    msg_num,
    msg_str,
    msg_vec,
    pareto,
    parse_finding,
    parse_tele,
    parse_vec,
    tele_int,
)
from metamining.http import (
    hget,
    parse_http_request,
    parse_query,
    read_web_file,
    resp_bytes,
    resp_bytes_h,
    resp_json,
    resp_json_h,
    sse_event,
    sse_headers,
)
from metamining.mcp import (
    mcp_err,
    mcp_has_id,
    mcp_id_json,
    mcp_is_object,
    mcp_negotiate,
    mcp_ok,
    mcp_origin_ok,
    mcp_tool_text,
    mcp_tools_json,
)
from metamining.json import (
    Doc,
    J_ARR,
    J_NUM,
    J_OBJ,
    J_STR,
    doc_at,
    doc_bool,
    doc_find,
    doc_kind,
    doc_len,
    doc_num,
    doc_onum,
    doc_ostr,
    doc_root,
    doc_str,
    j_escape,
    j_render_at,
    j_render_num,
    parse_json,
)


def _blank_field(d: Doc, r: Int, key: String) -> Bool:
    """True when a control field is missing or a blank form string.

    JSON numbers/bools are real values, never blank: only an empty
    string means 'keep the server default'.
    """
    var n = doc_find(d, r, key)
    if n < 0:
        return True
    if doc_kind(d, n) != J_STR:
        return False
    return doc_str(d, n) == ""
from metamining.libc import (
    accept_conn,
    bind_listen,
    close_fd,
    dir_list,
    dir_make,
    file_append_all,
    file_read_all,
    file_remove,
    file_stat,
    file_write_all,
    fork_child,
    format_mtime,
    format_stamp,
    ignore_sigpipe,
    kill_pid,
    mono_ms,
    msleep,
    PipePair,
    pipe_fds,
    pipe_read_some,
    pipe_write_all,
    poll_one,
    set_timeout,
    tcp_recv_some,
    tcp_send_all,
    time_now,
    wait_child,
)
from metamining.linalg import (
    pca_fit,
    pca_project,
    pca_z,
    percentile,
    vcos,
    vdist,
)
from metamining.scoring import round1
from metamining.topo import (
    betti_curve,
    mapper_graph,
    merge_tree,
    persistence_bars,
    topo_loops,
    vr_betti,
    vr_complex,
)
from metamining.sim import sim_embed
from metamining.worker import branch_model_for, parse_models_list, personas, worker_main


comptime MM_VERSION = "0.9.0"
comptime FINDINGS_CAP = 8000
comptime GOLD_AUTO_SIM = 0.5
comptime GOLD_AUTO_LIVE = 0.8
comptime QUEUE_CAP = 100
comptime JOURNAL_CAP = 100
comptime FANOUT_LIVE_CAP = 24
comptime FANOUT_TICK_FORKS = 4
comptime MODELS_TTL_SECS = 60
comptime VEINS_FLUSH_MS = 30000
comptime ACCEPT_BURST = 32
comptime CONNS_CAP = 128


struct Worker(Copyable, Movable):
    var bid: Int
    var pid: Int
    var rfd: Int
    var wfd: Int
    var alive: Bool
    var buf: String
    var step: Int
    var best: Float64
    var reason: String
    var temp: Float64
    var streak: Int
    var persona: Int
    var energy: Int
    var b0: Int
    var b1: Int
    var b2: Int
    var cd: Float64
    var sheaf: Float64
    var entropy: Float64
    var judges: Int
    var model: String
    var auto: Bool
    var mem_step: Int
    var r_calls: Int
    var e_calls: Int
    var r_ms: Int
    var e_ms: Int
    var tok_in: Int
    var tok_out: Int
    var push: Float64
    var line_fails: Int
    var sick: Bool
    var term_at: Int

    def __init__(out self, bid: Int, pid: Int, rfd: Int, wfd: Int):
        self.bid = bid
        self.pid = pid
        self.rfd = rfd
        self.wfd = wfd
        self.alive = True
        self.buf = String()
        self.step = 0
        self.best = 0.0
        self.reason = String()
        self.temp = 0.0
        self.streak = 0
        self.persona = 0
        self.energy = 100
        self.b0 = 0
        self.b1 = 0
        self.b2 = 0
        self.cd = 0.0
        self.sheaf = 0.0
        self.entropy = 0.0
        self.judges = 0
        self.model = String()
        self.auto = False
        self.mem_step = 0
        self.r_calls = 0
        self.e_calls = 0
        self.r_ms = 0
        self.e_ms = 0
        self.tok_in = 0
        self.tok_out = 0
        self.push = 0.0
        self.line_fails = 0
        self.sick = False
        self.term_at = 0


struct Conn(Copyable, Movable):
    var fd: Int
    var buf: String
    var sse: Bool
    var alive: Bool
    var mcp: Bool

    def __init__(out self, fd: Int):
        self.fd = fd
        self.buf = String()
        self.sse = False
        self.alive = True
        self.mcp = False


struct Vein(Copyable, Movable):
    var vid: Int
    var text: String
    var nov: Float64
    var coh: Float64
    var vec: List[Float64]
    var branch: Int
    var step: Int
    var run: Int
    var src: String
    var created: Int
    var model: String
    var endpoint: String

    def __init__(
        out self,
        vid: Int,
        text: String,
        nov: Float64,
        coh: Float64,
        vec: List[Float64],
        branch: Int,
        step: Int,
        run: Int,
        src: String,
        created: Int,
        model: String,
        endpoint: String,
    ):
        self.vid = vid
        self.text = text
        self.nov = nov
        self.coh = coh
        self.vec = vec.copy()
        self.branch = branch
        self.step = step
        self.run = run
        self.src = src
        self.created = created
        self.model = model
        self.endpoint = endpoint


def _src_model(srv: Server) -> String:
    """Model tag for provenance: configured id, or sim when blank."""
    if srv.cfg.model != "":
        return srv.cfg.model.copy()
    return String("sim")


def _src_endpoint(srv: Server) -> String:
    if srv.cfg.endpoint != "":
        return srv.cfg.endpoint.copy()
    return String("sim")


struct QueueItem(Copyable, Movable):
    var qid: Int
    var concept: String
    var model: String
    var branches: Int
    var steps: Int
    var status: String
    var seed: Int
    var gold: Float64
    var temp: Float64
    var repulse: Int
    var fanout: Int
    var judges: Int
    var auto: Int

    def __init__(
        out self,
        qid: Int,
        concept: String,
        model: String,
        branches: Int,
        steps: Int,
        status: String,
        seed: Int,
        gold: Float64,
        temp: Float64,
        repulse: Int,
        fanout: Int,
        judges: Int,
        auto: Int,
    ):
        self.qid = qid
        self.concept = concept
        self.model = model
        self.branches = branches
        self.steps = steps
        self.status = status
        self.seed = seed
        self.gold = gold
        self.temp = temp
        self.repulse = repulse
        self.fanout = fanout
        self.judges = judges
        self.auto = auto


struct TreeNode(Copyable, Movable):
    var bid: Int
    var parent: Int
    var kind: String
    var step: Int

    def __init__(out self, bid: Int, parent: Int, kind: String, step: Int):
        self.bid = bid
        self.parent = parent
        self.kind = kind
        self.step = step


struct SearchCand(Copyable, Movable):
    var branch: Int
    var step: Int
    var text: String
    var nov: Float64
    var coh: Float64
    var gold: Bool
    var src: String
    var score: Float64

    def __init__(
        out self,
        branch: Int,
        step: Int,
        text: String,
        nov: Float64,
        coh: Float64,
        gold: Bool,
        src: String,
        score: Float64,
    ):
        self.branch = branch
        self.step = step
        self.text = text
        self.nov = nov
        self.coh = coh
        self.gold = gold
        self.src = src
        self.score = score


struct Server(Movable):
    var cfg: ExpCfg
    var webdir: String
    var auth_token: String
    var mcp_sid: Int
    var price_over: Dict[String, String]
    var listen_fd: Int
    var run_id: Int
    var running: Bool
    var stop_reason: String
    var run_t0: Int
    var run_t1: Int
    var acc_calls: Int
    var acc_ecalls: Int
    var acc_ms: Int
    var acc_ems: Int
    var acc_tin: Int
    var acc_tout: Int
    var acc_cost: Float64
    var acc_cost_ok: Bool
    var workers: List[Worker]
    var conns: List[Conn]
    var findings: List[Finding]
    var vecs: List[List[Float64]]
    var aired: List[Int]
    var findings_base: Int
    var pca_dirty: Bool
    var pca_pending: Int
    var pca_last_ms: Int
    var paused: Bool
    var topo_branch: Int
    var topo_step: Int
    var topo_b0: Int
    var topo_b1: Int
    var topo_b2: Int
    var topo_cd: Float64
    var topo_sheaf: Float64
    var topo_entropy: Float64
    var auto_pop: Bool
    var spawned: Int
    var respawns: Int
    var spawned_fanout: Int
    var spawn_skipped: Int
    var forks_this_tick: Int
    var mem_rounds: Int
    var next_bid: Int
    var gold_seen: Int
    var pop_cool: Int
    var gold_count: Int
    var streak_no_gold: Int
    var logs: List[String]
    var models: List[String]
    var branch_models: List[String]
    var saved_run: Int
    var veins: List[Vein]
    var vein_next_id: Int
    var veins_error: String
    var autoque: Bool
    var queue: List[QueueItem]
    var queue_next_id: Int
    var tree: List[TreeNode]
    var run_drops: Int
    var journals_cache_json: String
    var journals_cache_fp: Int
    var journals_cache_valid: Bool
    var models_fetched_at: Int
    var models_fetched_ep: String
    var models_fetched_key: String
    var veins_dirty: Bool
    var veins_saved_at: Int

    def __init__(out self, cfg: ExpCfg, webdir: String):
        self.cfg = cfg
        self.webdir = webdir
        self.auth_token = String()
        self.mcp_sid = 0
        self.price_over = Dict[String, String]()
        self.listen_fd = -1
        self.run_id = 0
        self.running = False
        self.stop_reason = String("idle")
        self.run_t0 = 0
        self.run_t1 = 0
        self.acc_calls = 0
        self.acc_ecalls = 0
        self.acc_ms = 0
        self.acc_ems = 0
        self.acc_tin = 0
        self.acc_tout = 0
        self.acc_cost = 0.0
        self.acc_cost_ok = True
        self.workers = List[Worker]()
        self.conns = List[Conn]()
        self.findings = List[Finding]()
        self.vecs = List[List[Float64]]()
        self.aired = List[Int]()
        self.findings_base = 0
        self.pca_dirty = True
        self.pca_pending = 0
        self.pca_last_ms = 0
        self.paused = False
        self.topo_branch = 0
        self.topo_step = 0
        self.topo_b0 = 0
        self.topo_b1 = 0
        self.topo_b2 = 0
        self.topo_cd = 0.0
        self.topo_sheaf = 0.0
        self.topo_entropy = 0.0
        self.auto_pop = True
        self.spawned = 0
        self.respawns = 0
        self.spawned_fanout = 0
        self.spawn_skipped = 0
        self.forks_this_tick = 0
        self.mem_rounds = 0
        self.next_bid = 0
        self.gold_seen = 0
        self.pop_cool = 0
        self.gold_count = 0
        self.streak_no_gold = 0
        self.logs = List[String]()
        self.models = List[String]()
        self.branch_models = List[String]()
        self.saved_run = 0
        self.autoque = False
        self.queue = List[QueueItem]()
        self.queue_next_id = 1
        self.tree = List[TreeNode]()
        self.run_drops = 0
        self.journals_cache_json = String()
        self.journals_cache_fp = 0
        self.journals_cache_valid = False
        self.models_fetched_at = -1
        self.models_fetched_ep = String()
        self.models_fetched_key = String()
        self.veins_dirty = False
        self.veins_saved_at = 0
        var loaded = List[Vein]()
        var verr = String()
        var nxt = veins_load_file("veins/veins.json", loaded, verr)
        self.veins = loaded^
        self.vein_next_id = nxt
        self.veins_error = verr
        if verr != "":
            self.logs.append("veins error: " + verr)


def _push_ascii(mut out: List[UInt8], s: String):
    for b in s.bytes():
        out.append(UInt8(Int(b)))


def html_escape(s: String) -> String:
    var out = List[UInt8]()
    for b in s.bytes():
        var v = Int(b)
        if v == 38:
            _push_ascii(out, "&amp;")
        elif v == 60:
            _push_ascii(out, "&lt;")
        elif v == 62:
            _push_ascii(out, "&gt;")
        elif v == 34:
            _push_ascii(out, "&quot;")
        else:
            out.append(UInt8(v))
    return String(from_utf8_lossy=Span[UInt8](out))


def srv_log(mut srv: Server, line: String):
    srv.logs.append(line)
    if len(srv.logs) > 300:
        var keep = List[String]()
        for i in range(100, len(srv.logs)):
            keep.append(srv.logs[i])
        srv.logs = keep.copy()
    srv_broadcast(srv, String('{"t":"log","msg":"') + j_escape(line) + '"}')


def srv_broadcast(mut srv: Server, msg: String):
    var ev = sse_event(msg)
    for i in range(len(srv.conns)):
        var c = srv.conns[i].copy()
        if not c.alive or not c.sse or c.mcp:
            continue
        if tcp_send_all(c.fd, ev) < 0:
            _ = close_fd(c.fd)
            c.alive = False
            srv.conns[i] = c^


def _line_snip(line: String) -> String:
    """First 120 bytes of a log snippet (lossy, never splits output)."""
    var out = List[UInt8]()
    var n = 0
    for b in line.bytes():
        if n >= 120:
            break
        out.append(UInt8(Int(b)))
        n += 1
    return String(from_utf8_lossy=Span[UInt8](out))


def srv_note_line_fail(mut srv: Server, wi: Int, kind: String, line: String):
    """Log a worker-line decode failure; mark the worker sick after 20
    consecutive failures (flag only, never killed)."""
    var w = srv.workers[wi].copy()
    w.line_fails += 1
    var mark = False
    if w.line_fails >= 20 and not w.sick:
        w.sick = True
        mark = True
    var bid = w.bid
    var fails = w.line_fails
    srv.workers[wi] = w^
    srv_log(
        srv,
        "worker "
        + String(bid)
        + " line decode failed kind="
        + kind
        + " fails="
        + String(fails)
        + " :: "
        + _line_snip(line),
    )
    if mark:
        srv_log(srv, "worker " + String(bid) + " marked sick after 20 line failures")


def srv_note_line_ok(mut srv: Server, wi: Int):
    """A clean line resets the consecutive-failure counter (sick sticks)."""
    var w = srv.workers[wi].copy()
    if w.line_fails != 0:
        w.line_fails = 0
        srv.workers[wi] = w^


def _finite(f: Float64) -> Bool:
    return not (isinf(f) or isnan(f))


def _doc_int_finite(dd: Doc, e: Int, key: String) -> Int:
    """Doc int field: 0 when missing or non-finite (Int() of inf is garbage)."""
    var f = doc_onum(dd, e, key)
    if isinf(f) or isnan(f):
        return 0
    return Int(f)


def srv_set_veins_error(mut srv: Server, err: String):
    """Set the veins error, logging only when it changes."""
    if srv.veins_error == err:
        return
    srv.veins_error = err
    if err != "":
        srv_log(srv, "veins error: " + err)
    else:
        srv_log(srv, "veins error cleared")


def _finding_bad_field(line: String) raises -> String:
    """First non-finite numeric field of a finding line, or ""."""
    var keys = List[String]()
    keys.append("branch")
    keys.append("step")
    keys.append("novelty")
    keys.append("coherence")
    keys.append("x")
    keys.append("y")
    keys.append("z")
    keys.append("b0")
    keys.append("b1")
    keys.append("b2")
    keys.append("cd")
    keys.append("persona")
    keys.append("temp")
    for i in range(len(keys)):
        if not _finite(msg_num(line, keys[i])):
            return keys[i]
    return String()


def _close_unless_kept(fd: Int, k0: Int, k1: Int, k2: Int, k3: Int):
    if fd < 0:
        return
    if fd == k0 or fd == k1 or fd == k2 or fd == k3:
        return
    _ = close_fd(fd)


def srv_close_in_child(srv: Server, up: PipePair, down: PipePair):
    """Close parent-side fds in the forked worker, except this worker's
    own pipe ends. Dead conns are pruned at tick end but forks happen
    mid-tick during routing, so a stale entry can name a number pipe()
    just reused; closing it would stillborn the worker (exit-0, 0 steps)."""
    var k0 = up.read_fd
    var k1 = up.write_fd
    var k2 = down.read_fd
    var k3 = down.write_fd
    _close_unless_kept(srv.listen_fd, k0, k1, k2, k3)
    for i in range(len(srv.workers)):
        _close_unless_kept(srv.workers[i].rfd, k0, k1, k2, k3)
        _close_unless_kept(srv.workers[i].wfd, k0, k1, k2, k3)
    for i in range(len(srv.conns)):
        _close_unless_kept(srv.conns[i].fd, k0, k1, k2, k3)


def veins_load_file(path: String, mut out: List[Vein], mut err: String) -> Int:
    """Load the vein library. Returns the next vein id.

    A missing file yields an empty library starting at id 1 (not an
    error). Anything else that goes wrong lands in err: unreadable
    file, bad JSON, missing veins[], clamped non-finite values.
    """
    var nxt = 1
    err = String()
    if file_stat(path)[0] < 0:
        return nxt
    var raw = file_read_all(path)
    if raw == "":
        err = "veins file unreadable or empty: " + path
        return nxt
    try:
        var dd = parse_json(raw)
        var arr = doc_find(dd, doc_root(dd), "veins")
        if arr < 0 or doc_kind(dd, arr) != J_ARR:
            err = "veins file has no veins[]: " + path
            return nxt
        var start = 0
        if doc_len(dd, arr) > 1000:
            start = doc_len(dd, arr) - 1000
        var clamped = 0
        for i in range(start, doc_len(dd, arr)):
            var e = doc_at(dd, arr, i)
            if doc_kind(dd, e) != J_OBJ:
                continue
            var vv = List[Float64]()
            var varr = doc_find(dd, e, "vec")
            if varr >= 0 and doc_kind(dd, varr) == J_ARR:
                for j in range(doc_len(dd, varr)):
                    var vf = doc_num(dd, doc_at(dd, varr, j))
                    if isinf(vf) or isnan(vf):
                        vf = 0.0
                        clamped += 1
                    vv.append(vf)
            var vid = _doc_int_finite(dd, e, "id")
            if vid <= 0:
                vid = nxt
            var vnov = doc_onum(dd, e, "novelty")
            if isinf(vnov) or isnan(vnov):
                vnov = 0.0
                clamped += 1
            var vcoh = doc_onum(dd, e, "coherence")
            if isinf(vcoh) or isnan(vcoh):
                vcoh = 0.0
                clamped += 1
            out.append(
                Vein(
                    vid,
                    doc_ostr(dd, e, "text"),
                    vnov,
                    vcoh,
                    vv,
                    _doc_int_finite(dd, e, "branch"),
                    _doc_int_finite(dd, e, "step"),
                    _doc_int_finite(dd, e, "run"),
                    doc_ostr(dd, e, "src"),
                    _doc_int_finite(dd, e, "created"),
                    doc_ostr(dd, e, "model"),
                    doc_ostr(dd, e, "endpoint"),
                )
            )
            if vid >= nxt:
                nxt = vid + 1
        if clamped > 0:
            err = String(clamped) + " non-finite values clamped in " + path
    except:
        err = "veins file bad json: " + path
        return nxt
    return nxt


def veins_save_file(mut srv: Server):
    """Persist the vein library to ./veins/veins.json (cap 1000).

    Root meta names every model@endpoint pair that contributed identifiable
    veins, so a shared library stays attributable across runs and models.
    """
    _ = dir_make("veins")
    var models = List[String]()
    for i in range(len(srv.veins)):
        var tag = srv.veins[i].model
        if tag != "":
            tag += "@" + srv.veins[i].endpoint
            var seen = False
            for k in range(len(models)):
                if models[k] == tag:
                    seen = True
            if not seen:
                models.append(tag)
    var out = String('{"meta":{"models":[')
    for i in range(len(models)):
        if i > 0:
            out += ","
        out += String('"') + j_escape(models[i]) + String('"')
    out += (
        String('],"app_version":"')
        + String(MM_VERSION)
        + String('"},"veins":[')
    )
    for i in range(len(srv.veins)):
        var v = srv.veins[i].copy()
        if i > 0:
            out += ","
        out += (
            String('{"id":')
            + String(v.vid)
            + ',"text":"'
            + j_escape(v.text)
            + '","novelty":'
            + j_render_num(v.nov)
            + ',"coherence":'
            + j_render_num(v.coh)
            + ',"vec":['
        )
        for j in range(len(v.vec)):
            if j > 0:
                out += ","
            out += j_render_num(v.vec[j])
        out += (
            String('],"branch":')
            + String(v.branch)
            + ',"step":'
            + String(v.step)
            + ',"run":'
            + String(v.run)
            + ',"src":"'
            + j_escape(v.src)
            + '","created":'
            + String(v.created)
            + ',"model":"'
            + j_escape(v.model)
            + '","endpoint":"'
            + j_escape(v.endpoint)
            + '"}'
        )
    out += "]}"
    if file_write_all("veins/veins.json", out) < 0:
        srv_set_veins_error(srv, "veins save failed: veins/veins.json")
    else:
        srv_set_veins_error(srv, String())


def srv_veins_flush(mut srv: Server):
    """Persist the vein library when dirty. Called on run end, stop
    and explicit save; periodic saves go through maybe_flush."""
    if not srv.veins_dirty:
        return
    veins_save_file(srv)
    srv.veins_dirty = False
    srv.veins_saved_at = mono_ms()


def srv_veins_maybe_flush(mut srv: Server):
    """Persist dirty veins at most every VEINS_FLUSH_MS."""
    if not srv.veins_dirty:
        return
    var now = mono_ms()
    if now < 0 or now - srv.veins_saved_at >= VEINS_FLUSH_MS:
        veins_save_file(srv)
        srv.veins_dirty = False
        srv.veins_saved_at = now


def srv_vein_append(mut srv: Server, f: Finding, vec: List[Float64]):
    """Record a gold finding in the vein library (drop oldest past 1000).

    Persistence is debounced: the write lands at most every 30s, plus
    always on run end, stop and explicit save (see srv_veins_flush).
    """
    srv.veins.append(
        Vein(
            srv.vein_next_id,
            f.text,
            f.nov,
            f.coh,
            vec,
            f.branch,
            f.step,
            srv.run_id,
            f.src,
            time_now(),
            _src_model(srv),
            _src_endpoint(srv),
        )
    )
    srv.vein_next_id += 1
    if len(srv.veins) > 1000:
        var keep = List[Vein]()
        var drop = len(srv.veins) - 1000
        for i in range(drop, len(srv.veins)):
            keep.append(srv.veins[i].copy())
        srv.veins = keep.copy()
    srv.veins_dirty = True
    srv_veins_maybe_flush(srv)


def srv_veins_json(srv: Server) -> String:
    """Vein library without vec payloads (those stay server-side)."""
    var out = String('{"veins":[')
    for i in range(len(srv.veins)):
        var v = srv.veins[i].copy()
        if i > 0:
            out += ","
        out += (
            String('{"id":')
            + String(v.vid)
            + ',"text":"'
            + j_escape(v.text)
            + '","novelty":'
            + j_render_num(v.nov)
            + ',"coherence":'
            + j_render_num(v.coh)
            + ',"branch":'
            + String(v.branch)
            + ',"step":'
            + String(v.step)
            + ',"run":'
            + String(v.run)
            + ',"src":"'
            + j_escape(v.src)
            + '","created":'
            + String(v.created)
            + ',"model":"'
            + j_escape(v.model)
            + '","endpoint":"'
            + j_escape(v.endpoint)
            + '"}'
        )
    out += "]}"
    return out


def srv_related_json(srv: Server, branch: Int, step: Int) -> String:
    """Top-5 veins by cosine to one finding's vec. Empty when the
    finding is unknown (the route maps that to 404)."""
    var idx = -1
    var k = len(srv.findings) - 1
    while k >= 0:
        var f = srv.findings[k]
        if f.branch == branch and f.step == step:
            idx = k
            break
        k -= 1
    if idx < 0:
        return String()
    var base = srv.vecs[idx].copy()
    var order = List[Int]()
    var scores = List[Float64]()
    if len(base) > 0:
        for i in range(len(srv.veins)):
            var v = srv.veins[i].copy()
            if v.branch == branch and v.step == step and v.run == srv.run_id:
                continue
            if len(v.vec) == 0:
                continue
            order.append(i)
            scores.append(vcos(base, v.vec))
        var n = 0
        for a in range(len(order)):
            var bi = a
            for b in range(a + 1, len(order)):
                if scores[b] > scores[bi]:
                    bi = b
            if bi != a:
                var ti = order[a]
                order[a] = order[bi]
                order[bi] = ti
                var ts = scores[a]
                scores[a] = scores[bi]
                scores[bi] = ts
            n += 1
            if n >= 5:
                break
        if len(order) > n:
            var cut_o = List[Int]()
            var cut_s = List[Float64]()
            for q in range(n):
                cut_o.append(order[q])
                cut_s.append(scores[q])
            order = cut_o.copy()
            scores = cut_s.copy()
    var out = String('{"items":[')
    for q in range(len(order)):
        var v = srv.veins[order[q]].copy()
        if q > 0:
            out += ","
        out += (
            String('{"id":')
            + String(v.vid)
            + ',"text":"'
            + j_escape(v.text)
            + '","novelty":'
            + j_render_num(v.nov)
            + ',"coherence":'
            + j_render_num(v.coh)
            + ',"score":'
            + j_render_num(scores[q])
            + ',"src":"'
            + j_escape(v.src)
            + '"}'
        )
    out += "]}"
    return out


def srv_queue_json(srv: Server) -> String:
    var out = String('{"autoque":') + (
        String("true") if srv.autoque else String("false")
    )
    out += ',"queue":['
    for i in range(len(srv.queue)):
        var q = srv.queue[i].copy()
        if i > 0:
            out += ","
        out += (
            String('{"id":')
            + String(q.qid)
            + ',"concept":"'
            + j_escape(q.concept)
            + '","model":"'
            + j_escape(q.model)
            + '","branches":'
            + String(q.branches)
            + ',"steps":'
            + String(q.steps)
            + ',"status":"'
            + j_escape(q.status)
            + '","seed":'
            + String(q.seed)
            + ',"gold":'
            + j_render_num(q.gold)
            + ',"temp":'
            + j_render_num(q.temp)
            + ',"repulse":'
            + String(q.repulse)
            + ',"fanout":'
            + String(q.fanout)
            + ',"judges":'
            + String(q.judges)
            + ',"auto":'
            + String(q.auto)
            + "}"
        )
    out += "]}"
    return out


def srv_queue_finish_running(mut srv: Server):
    """Mark running queue items done without starting anything."""
    for i in range(len(srv.queue)):
        var q = srv.queue[i].copy()
        if q.status == "running":
            q.status = String("done")
            srv.queue[i] = q^


def srv_queue_advance(mut srv: Server):
    """Natural-complete hook: finish the running item, then auto-start
    the next queued item when autoque is on. The tree is preserved
    across the advance (old nodes stay, new seeds append); the item's
    model applies to every branch and its enqueue-time snapshot of
    seed/gold/temp/repulse/fanout/judges/auto becomes the run config."""
    srv_queue_finish_running(srv)
    if not srv.autoque:
        return
    var ni = -1
    for i in range(len(srv.queue)):
        if srv.queue[i].status == "queued":
            ni = i
            break
    if ni < 0:
        return
    var q = srv.queue[ni].copy()
    var cfg = srv.cfg.copy()
    cfg.concept = q.concept
    if q.model != "":
        cfg.model = q.model
    if q.branches > 0:
        cfg.branches = q.branches
    if q.steps > 0:
        cfg.steps = q.steps
    cfg.seed = q.seed
    cfg.gold = q.gold
    cfg.temp = q.temp
    cfg.repulse = q.repulse
    cfg.fanout = q.fanout
    cfg.judges = q.judges
    cfg.auto = q.auto
    srv_log(srv, "autoque starting #" + String(q.qid) + " [" + q.concept + "]")
    srv.branch_models = List[String]()
    srv.branch_models.append(q.model)
    var keep_tree = srv.tree.copy()
    srv_start_run(srv, cfg)
    var merged = keep_tree.copy()
    for i in range(len(srv.tree)):
        merged.append(srv.tree[i].copy())
    srv.tree = merged^
    var q2 = srv.queue[ni].copy()
    q2.status = String("running")
    srv.queue[ni] = q2^
    srv_broadcast(srv, srv_state_json(srv))


def srv_tree_json(srv: Server) -> String:
    var out = String('{"nodes":[')
    for i in range(len(srv.tree)):
        var t = srv.tree[i].copy()
        if i > 0:
            out += ","
        out += (
            String('{"bid":')
            + String(t.bid)
            + ',"parent":'
            + String(t.parent)
            + ',"kind":"'
            + j_escape(t.kind)
            + '","step":'
            + String(t.step)
            + "}"
        )
    out += "]}"
    return out


def _topo_dim(srv: Server) -> Int:
    var i = len(srv.vecs) - 1
    while i >= 0:
        if len(srv.vecs[i]) > 0:
            return len(srv.vecs[i])
        i -= 1
    return 0


def _topo_idx(srv: Server, cap: Int) -> List[Int]:
    """Vec-backed finding indices at the live dim, stride-sampled to cap."""
    var dim = _topo_dim(srv)
    var all_idx = List[Int]()
    if dim == 0:
        return all_idx.copy()
    for k in range(len(srv.findings)):
        if k < len(srv.vecs) and len(srv.vecs[k]) == dim:
            all_idx.append(k)
    if len(all_idx) <= cap:
        return all_idx.copy()
    var out = List[Int]()
    var step = Float64(len(all_idx)) / Float64(cap)
    var pos = 0.0
    for _ in range(cap):
        out.append(all_idx[Int(pos)])
        pos += step
    return out.copy()


def _topo_total(srv: Server) -> Int:
    var dim = _topo_dim(srv)
    var n = 0
    for k in range(len(srv.findings)):
        if k < len(srv.vecs) and len(srv.vecs[k]) == dim and dim > 0:
            n += 1
    return n


def _j_floats(vals: List[Float64]) -> String:
    var out = String("[")
    for i in range(len(vals)):
        if i > 0:
            out += ","
        out += j_render_num(vals[i])
    out += "]"
    return out


def _j_ints(vals: List[Int]) -> String:
    var out = String("[")
    for i in range(len(vals)):
        if i > 0:
            out += ","
        out += String(vals[i])
    out += "]"
    return out


def srv_topo_merge_json(mut srv: Server) -> String:
    """Merge tree of the novelty field over the displayed map."""
    srv_refresh_pca(srv)
    var idx = _topo_idx(srv, 400)
    var xs = List[Float64]()
    var ys = List[Float64]()
    var novs = List[Float64]()
    var bi = List[Int]()
    var si = List[Int]()
    for t in range(len(idx)):
        var f = srv.findings[idx[t]]
        xs.append(f.x)
        ys.append(f.y)
        novs.append(f.nov)
        bi.append(f.branch)
        si.append(f.step)
    var mt = merge_tree(xs, ys, novs, bi, si, 4)
    var sampled = "false"
    if _topo_total(srv) > len(idx):
        sampled = "true"
    return (
        String('{"n":')
        + String(len(idx))
        + ',"total":'
        + String(_topo_total(srv))
        + ',"sampled":'
        + sampled
        + ',"nov":'
        + _j_floats(mt.nov)
        + ',"x":'
        + _j_floats(mt.x)
        + ',"y":'
        + _j_floats(mt.y)
        + ',"tx":'
        + _j_floats(mt.tx)
        + ',"size":'
        + _j_ints(mt.size)
        + ',"peak":'
        + _j_ints(mt.peak)
        + ',"bi":'
        + _j_ints(mt.bi)
        + ',"si":'
        + _j_ints(mt.si)
        + ',"la":'
        + _j_ints(mt.la)
        + ',"lb":'
        + _j_ints(mt.lb)
        + ',"basin":'
        + _j_ints(mt.basin)
        + "}"
    )


def _topo_dm(srv: Server, idx: List[Int], metric: String) -> List[List[Float64]]:
    """Pairwise vec-space distances: cosine (1 - cos) or euclidean."""
    var n = len(idx)
    var dm = List[List[Float64]]()
    for a in range(n):
        var row = List[Float64]()
        for b in range(n):
            var d = 0.0
            if a != b:
                if metric == "euclid":
                    d = vdist(srv.vecs[idx[a]], srv.vecs[idx[b]])
                else:
                    d = 1.0 - vcos(srv.vecs[idx[a]], srv.vecs[idx[b]])
                    if d < 0.0:
                        d = 0.0
            row.append(d)
        dm.append(row^)
    return dm.copy()


def srv_topo_bars_json(mut srv: Server, metric: String) raises -> String:
    """Persistence barcode + Betti curves over vec-space distances."""
    srv_refresh_pca(srv)
    var idx = _topo_idx(srv, 20)
    var n = len(idx)
    var dm = _topo_dm(srv, idx, metric)
    var bars = persistence_bars(dm, n)
    var bc = betti_curve(dm, n, 12)
    var capped = "false"
    if bars.capped:
        capped = "true"
    return (
        String('{"n":')
        + String(n)
        + ',"metric":"'
        + metric
        + '"'
        + ',"capped":'
        + capped
        + ',"dim":'
        + _j_ints(bars.dim)
        + ',"birth":'
        + _j_floats(bars.birth)
        + ',"death":'
        + _j_floats(bars.death)
        + ',"scales":'
        + _j_floats(bc.scales)
        + ',"b0":'
        + _j_ints(bc.b0)
        + ',"b1":'
        + _j_ints(bc.b1)
        + ',"b2":'
        + _j_ints(bc.b2)
        + "}"
    )


def srv_topo_loops_json(mut srv: Server, max_loops: Int) raises -> String:
    """Loop members + void ball over the displayed map."""
    srv_refresh_pca(srv)
    var idx = _topo_idx(srv, 400)
    var xs = List[Float64]()
    var ys = List[Float64]()
    for t in range(len(idx)):
        var f = srv.findings[idx[t]]
        xs.append(f.x)
        ys.append(f.y)
    var lp = topo_loops(xs, ys, max_loops)
    var lj = String("[")
    for i in range(len(lp.loops)):
        if i > 0:
            lj += ","
        lj += _j_ints(lp.loops[i])
    lj += "]"
    var bi = List[Int]()
    var si = List[Int]()
    for t in range(len(idx)):
        var f = srv.findings[idx[t]]
        bi.append(f.branch)
        si.append(f.step)
    var hv = "false"
    if lp.has_void:
        hv = "true"
    var sampled = "false"
    if _topo_total(srv) > len(idx):
        sampled = "true"
    return (
        String('{"n":')
        + String(len(idx))
        + ',"total":'
        + String(_topo_total(srv))
        + ',"sampled":'
        + sampled
        + ',"b1":'
        + String(lp.b1)
        + ',"loops":'
        + lj
        + ',"bi":'
        + _j_ints(bi)
        + ',"si":'
        + _j_ints(si)
        + ',"has_void":'
        + hv
        + ',"void_x":'
        + j_render_num(lp.void_x)
        + ',"void_y":'
        + j_render_num(lp.void_y)
        + ',"void_r":'
        + j_render_num(lp.void_r)
        + "}"
    )


def srv_topo_mapper_json(
    mut srv: Server, bins: Int, overlap: Float64
) -> String:
    """Mapper nerve over the novelty lens on the displayed map."""
    srv_refresh_pca(srv)
    var idx = _topo_idx(srv, 400)
    var xs = List[Float64]()
    var ys = List[Float64]()
    var lens = List[Float64]()
    for t in range(len(idx)):
        var f = srv.findings[idx[t]]
        xs.append(f.x)
        ys.append(f.y)
        lens.append(f.nov)
    var g = mapper_graph(xs, ys, lens, bins, overlap, 0.0)
    var sampled = "false"
    if _topo_total(srv) > len(idx):
        sampled = "true"
    return (
        String('{"n":')
        + String(len(idx))
        + ',"total":'
        + String(_topo_total(srv))
        + ',"sampled":'
        + sampled
        + ',"bins":'
        + String(bins)
        + ',"overlap":'
        + j_render_num(overlap)
        + ',"x":'
        + _j_floats(g.x)
        + ',"y":'
        + _j_floats(g.y)
        + ',"size":'
        + _j_ints(g.size)
        + ',"lens":'
        + _j_floats(g.lens)
        + ',"la":'
        + _j_ints(g.la)
        + ',"lb":'
        + _j_ints(g.lb)
        + "}"
    )


def srv_topo_time_json(mut srv: Server) raises -> String:
    """Median-scale Betti numbers over cumulative run deciles (vec space).

    Decile d covers the first (d+1)*10% of vec-backed findings, stride-capped
    at 24 points: a vineyard-lite showing loops forming and voids closing.
    """
    srv_refresh_pca(srv)
    var dim = _topo_dim(srv)
    var all_idx = List[Int]()
    if dim > 0:
        for k in range(len(srv.findings)):
            if k < len(srv.vecs) and len(srv.vecs[k]) == dim:
                all_idx.append(k)
    var fracs = List[Float64]()
    var ns = List[Int]()
    var b0s = List[Int]()
    var b1s = List[Int]()
    var b2s = List[Int]()
    var total = len(all_idx)
    for dd in range(10):
        var frac = (Float64(dd) + 1.0) / 10.0
        fracs.append(frac)
        var take = Int(Float64(total) * frac)
        if take > 24:
            take = 24
        var sub = List[Int]()
        if total > 0 and take > 0:
            var step = Float64(total) / Float64(take)
            var pos = 0.0
            for _ in range(take):
                sub.append(all_idx[Int(pos)])
                pos += step
        ns.append(len(sub))
        if len(sub) < 2:
            b0s.append(len(sub))
            b1s.append(0)
            b2s.append(0)
            continue
        var dm = _topo_dm(srv, sub, "cosine")
        var dists = List[Float64]()
        for a in range(len(sub)):
            for b in range(a + 1, len(sub)):
                dists.append(dm[a][b])
        var c = vr_complex(dm, len(sub), percentile(dists, 50.0))
        var bt = vr_betti(len(sub), c, True)
        b0s.append(bt.b0)
        b1s.append(bt.b1)
        b2s.append(bt.b2)
    return (
        String('{"total":')
        + String(total)
        + ',"frac":'
        + _j_floats(fracs)
        + ',"n":'
        + _j_ints(ns)
        + ',"b0":'
        + _j_ints(b0s)
        + ',"b1":'
        + _j_ints(b1s)
        + ',"b2":'
        + _j_ints(b2s)
        + "}"
    )


def srv_topo_conf_json(mut srv: Server, metric: String) raises -> String:
    """Persistence bars with resampling support (deterministic 8-fold).

    Each fold drops every 5th point (rotated); a full-window bar is supported
    when a same-dim bar lands within 5% of max distance. support = fraction.
    """
    srv_refresh_pca(srv)
    var idx = _topo_idx(srv, 20)
    var n = len(idx)
    var dm = _topo_dm(srv, idx, metric)
    var full = persistence_bars(dm, n)
    var bc = betti_curve(dm, n, 12)
    var maxd = 0.0
    for a in range(n):
        for b in range(a + 1, n):
            if dm[a][b] > maxd:
                maxd = dm[a][b]
    var tol = maxd * 0.05
    var sup = List[Float64]()
    for _ in range(len(full.dim)):
        sup.append(0.0)
    var folds = 8
    for r in range(folds):
        var sub = List[Int]()
        for i in range(n):
            if (i + r) % 5 != 0:
                sub.append(idx[i])
        var sdm = _topo_dm(srv, sub, metric)
        var pb = persistence_bars(sdm, len(sub))
        for f in range(len(full.dim)):
            var hit = False
            for g in range(len(pb.dim)):
                if pb.dim[g] != full.dim[f]:
                    continue
                if full.death[f] < 0.0:
                    if pb.death[g] < 0.0:
                        hit = True
                        break
                else:
                    if pb.death[g] < 0.0:
                        continue
                    var db = pb.birth[g] - full.birth[f]
                    if db < 0.0:
                        db = -db
                    var dd = pb.death[g] - full.death[f]
                    if dd < 0.0:
                        dd = -dd
                    if db < tol and dd < tol:
                        hit = True
                        break
            if hit:
                sup[f] += 1.0
    for f in range(len(sup)):
        sup[f] = sup[f] / Float64(folds)
    var capped = "false"
    if full.capped:
        capped = "true"
    return (
        String('{"n":')
        + String(n)
        + ',"metric":"'
        + metric
        + '"'
        + ',"resamples":'
        + String(folds)
        + ',"capped":'
        + capped
        + ',"dim":'
        + _j_ints(full.dim)
        + ',"birth":'
        + _j_floats(full.birth)
        + ',"death":'
        + _j_floats(full.death)
        + ',"support":'
        + _j_floats(sup)
        + ',"scales":'
        + _j_floats(bc.scales)
        + ',"b0":'
        + _j_ints(bc.b0)
        + ',"b1":'
        + _j_ints(bc.b1)
        + ',"b2":'
        + _j_ints(bc.b2)
        + "}"
    )


def _order_mtime_desc(mt: List[Int], mut order: List[Int]):
    """Stable mergesort of order[] by mt[] descending, in place.

    The one shared journal ordering: replaces the O(J^2) selection
    sorts that journal_newest and the journals listing each carried.
    """
    var n = len(order)
    if n < 2:
        return
    var tmp = List[Int]()
    for i in range(n):
        tmp.append(order[i])
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = lo + width
            if mid > n:
                mid = n
            var hi = lo + 2 * width
            if hi > n:
                hi = n
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if mt[order[j]] > mt[order[i]]:
                    tmp[k] = order[j]
                    j += 1
                else:
                    tmp[k] = order[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = order[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = order[j]
                j += 1
                k += 1
            for t in range(lo, hi):
                order[t] = tmp[t]
            lo += 2 * width
        width *= 2


def _journal_scan(mut names: List[String], mut mtime: List[Int], mut size: List[Int]):
    """journal_*.json basenames under journals/ with stat. No parsing."""
    var raw = dir_list("journals")
    for i in range(len(raw)):
        var nm = raw[i]
        if not nm.startswith("journal_"):
            continue
        if not nm.endswith(".json"):
            continue
        var st = file_stat("journals/" + nm)
        if st[0] < 0:
            continue
        names.append(nm)
        mtime.append(st[1])
        size.append(st[0])


def _journal_fp(names: List[String], mtime: List[Int], size: List[Int]) -> Int:
    """Small rolling hash over the listing. Any add/remove/rename,
    mtime or size change flips it; readdir order is stable while the
    directory itself is untouched, so a matching fingerprint means an
    unchanged listing (same-second same-size rewrites excepted). All
    math stays under 2^39, far from Int overflow."""
    var fp = len(names)
    for i in range(len(names)):
        var nh = 0
        for b in names[i].bytes():
            nh = (nh * 33 + Int(b)) & 0xFFFFFFFF
        fp = (fp * 131 + nh + mtime[i] + size[i]) & 0xFFFFFFFF
    return fp


def journal_newest(limit: Int, mut out: List[String]):
    """Journal basenames newest-first (mtime desc), at most limit."""
    var fl = List[String]()
    var mt = List[Int]()
    var sz = List[Int]()
    _journal_scan(fl, mt, sz)
    var order = List[Int]()
    for i in range(len(fl)):
        order.append(i)
    _order_mtime_desc(mt, order)
    var n = 0
    for k in range(len(order)):
        if n >= limit:
            break
        out.append(fl[order[k]])
        n += 1


def _search_vault_gold(dd: Doc, rr: Int, text: String) -> Bool:
    var garr = doc_find(dd, rr, "gold_vault")
    if garr < 0 or doc_kind(dd, garr) != J_ARR:
        return False
    for gi in range(doc_len(dd, garr)):
        if doc_str(dd, doc_at(dd, garr, gi)) == text:
            return True
    return False


def srv_search_json(mut srv: Server, q: String, limit: Int) -> String:
    """Search over live findings, the vein library and the 20 newest
    journal files, ranked by cosine to the query. Two vector spaces:

    - embed: the query is embedded through the configured embed
      backend (query prefix applied) and compared against stored
      vecs. Rows whose vec dim does not match the query vec are
      skipped and counted in dim_skipped, never silently rescored.
      This is a true semantic search and works in sim mode too when
      a local embed endpoint (./embed-setup.sh) is configured.
    - hash: hash-BOW-64 for everything. Hash vectors only see shared
      words (lexical overlap), not meaning, so paraphrases score low
      and rare shared tokens dominate. Used when no embed model is
      configured, and as the fallback when the embed call fails.

    The response names the space actually used.
    """
    var lim = limit
    if lim <= 0:
        lim = 20
    if lim > 50:
        lim = 50
    var cands = List[SearchCand]()
    var skipped = 0
    var dim_skipped = 0
    var space = String("hash")
    if q != "":
        var qv = List[Float64]()
        if srv.cfg.embed_model != "":
            var texts = List[String]()
            texts.append(embed_input(srv.cfg.embed_query_prefix, q))
            var tmp = List[List[Float64]]()
            var t0 = mono_ms()
            var err = meta_embed(
                MetaCfg(
                    srv.cfg.endpoint,
                    srv.cfg.api_key,
                    srv.cfg.model,
                    srv.cfg.embed_model,
                    srv.cfg.embed_endpoint,
                    srv.cfg.embed_doc_prefix,
                    srv.cfg.embed_query_prefix,
                ),
                texts,
                tmp,
            )
            var t1 = mono_ms()
            srv.acc_ecalls += 1
            if t0 >= 0 and t1 >= t0:
                srv.acc_ems += t1 - t0
            if err == "" and len(tmp) == 1 and len(tmp[0]) > 0:
                qv = tmp[0].copy()
                space = "embed"
            else:
                srv_log(srv, "search embed failed, hash fallback: " + err)
        if len(qv) == 0:
            sim_embed(q, qv)
        var semantic = space == "embed"
        for k in range(len(srv.findings)):
            var f = srv.findings[k]
            if semantic:
                # Stored vecs only: re-embedding every row through
                # the API per keystroke would be absurdly costly.
                if len(qv) > 0 and len(srv.vecs[k]) == len(qv):
                    cands.append(
                        SearchCand(
                            f.branch,
                            f.step,
                            f.text,
                            f.nov,
                            f.coh,
                            f.gold,
                            f.src,
                            vcos(qv, srv.vecs[k]),
                        )
                    )
                else:
                    dim_skipped += 1
                continue
            var score = 0.0
            if len(srv.vecs[k]) == 64:
                score = vcos(qv, srv.vecs[k])
            else:
                var dv = List[Float64]()
                sim_embed(f.text, dv)
                score = vcos(qv, dv)
            cands.append(
                SearchCand(
                    f.branch, f.step, f.text, f.nov, f.coh, f.gold, f.src, score
                )
            )
        for i in range(len(srv.veins)):
            var v = srv.veins[i].copy()
            if semantic:
                if len(qv) > 0 and len(v.vec) == len(qv):
                    cands.append(
                        SearchCand(
                            v.branch,
                            v.step,
                            v.text,
                            v.nov,
                            v.coh,
                            True,
                            v.src,
                            vcos(qv, v.vec),
                        )
                    )
                else:
                    dim_skipped += 1
                continue
            var vscore = 0.0
            if len(v.vec) == 64:
                vscore = vcos(qv, v.vec)
            else:
                var dv = List[Float64]()
                sim_embed(v.text, dv)
                vscore = vcos(qv, dv)
            cands.append(
                SearchCand(
                    v.branch, v.step, v.text, v.nov, v.coh, True, v.src, vscore
                )
            )
        var jfiles = List[String]()
        journal_newest(20, jfiles)
        for fi in range(len(jfiles)):
            var raw = file_read_all("journals/" + jfiles[fi])
            if raw == "":
                skipped += 1
                continue
            try:
                var dd = parse_json(raw)
                var rr = doc_root(dd)
                var arr = _journal_entries_node(dd, rr)
                if arr < 0:
                    skipped += 1
                    continue
                for i in range(doc_len(dd, arr)):
                    var e = doc_at(dd, arr, i)
                    var ek = doc_kind(dd, e)
                    if ek != J_OBJ and ek != J_STR:
                        continue
                    var text = String()
                    var branch = 0
                    var step = i + 1
                    var nov = 0.75
                    var coh = 8.0
                    var gold = False
                    if ek == J_STR:
                        text = doc_str(dd, e)
                        gold = _search_vault_gold(dd, rr, text)
                    else:
                        branch = _doc_int_finite(dd, e, "branch")
                        var st0 = _doc_int_finite(dd, e, "step")
                        if st0 > 0:
                            step = st0
                        nov = _jnum2(dd, e, "novelty", "novelty_score")
                        if not _finite(nov):
                            nov = 0.0
                        coh = _jnum2(dd, e, "coherence", "coherence_score")
                        if not _finite(coh):
                            coh = 0.0
                        gold = _jbool2(dd, e, "gold", "is_gold")
                        text = _jstr2(dd, e, "text", "response")
                    if semantic:
                        var dv = List[Float64]()
                        var vn = doc_find(dd, e, "vec")
                        if (
                            ek == J_OBJ
                            and vn >= 0
                            and doc_kind(dd, vn) == J_ARR
                            and doc_len(dd, vn) == len(qv)
                        ):
                            for j in range(doc_len(dd, vn)):
                                var vf = doc_num(dd, doc_at(dd, vn, j))
                                if isinf(vf) or isnan(vf):
                                    vf = 0.0
                                dv.append(vf)
                        if len(dv) == len(qv) and len(qv) > 0:
                            cands.append(
                                SearchCand(
                                    branch,
                                    step,
                                    text,
                                    nov,
                                    coh,
                                    gold,
                                    jfiles[fi],
                                    vcos(qv, dv),
                                )
                            )
                        else:
                            dim_skipped += 1
                    else:
                        var hv = List[Float64]()
                        sim_embed(text, hv)
                        cands.append(
                            SearchCand(
                                branch,
                                step,
                                text,
                                nov,
                                coh,
                                gold,
                                jfiles[fi],
                                vcos(qv, hv),
                            )
                        )
            except:
                skipped += 1
                continue
    var total = len(cands)
    var want = lim
    if want > total:
        want = total
    for a in range(want):
        var bi = a
        for b in range(a + 1, total):
            if cands[b].score > cands[bi].score:
                bi = b
        if bi != a:
            var t = cands[a].copy()
            cands[a] = cands[bi].copy()
            cands[bi] = t^
    var out = String('{"items":[')
    for i in range(want):
        var c = cands[i].copy()
        if i > 0:
            out += ","
        out += (
            String('{"branch":')
            + String(c.branch)
            + ',"step":'
            + String(c.step)
            + ',"text":"'
            + j_escape(c.text)
            + '","novelty":'
            + j_render_num(c.nov)
            + ',"coherence":'
            + j_render_num(c.coh)
            + ',"gold":'
            + (String("true") if c.gold else String("false"))
            + ',"src":"'
            + j_escape(c.src)
            + '","score":'
            + j_render_num(c.score)
            + "}"
        )
    out += (
        '],"skipped":'
        + String(skipped)
        + ',"space":"'
        + space
        + '","dim_skipped":'
        + String(dim_skipped)
        + "}"
    )
    return out


def srv_reap(mut srv: Server):
    var now = mono_ms()
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if w.pid <= 0:
            continue
        var r = wait_child(w.pid, True)
        if r.pid == w.pid:
            w.pid = -1
            if w.alive:
                w.alive = False
                if w.reason == "":
                    if r.status & 127 == 0:
                        w.reason = "exit-" + String((r.status >> 8) & 0xFF)
                    else:
                        w.reason = "signal-" + String(r.status & 127)
            if w.rfd >= 0:
                _ = close_fd(w.rfd)
                w.rfd = -1
            if w.wfd >= 0:
                _ = close_fd(w.wfd)
                w.wfd = -1
            srv.workers[i] = w^
            continue
        # A SIGTERMed worker still alive past the 1.5s grace gets
        # SIGKILLed so it can neither linger as a zombie nor keep
        # burning API budget. term_at is cleared so this logs once.
        if w.term_at > 0 and now >= 0 and now - w.term_at > 1500:
            _ = kill_pid(w.pid, 9)
            w.term_at = 0
            var b = w.bid
            srv.workers[i] = w^
            srv_log(srv, "worker " + String(b) + " SIGKILLed after 1.5s grace")


def srv_worker_cost(w: Worker, over: Dict[String, String]) -> Float64:
    """This worker's spend in dollars, or -1.0 when its model has no rate."""
    if w.tok_in + w.tok_out <= 0:
        return 0.0
    var rt = model_rates_over(w.model, over)
    if rt.inp < 0.0:
        return -1.0
    return (Float64(w.tok_in) * rt.inp + Float64(w.tok_out) * rt.out) / 1000000.0


def srv_latch_api(mut srv: Server):
    """Fold live worker counters into the run accumulators before the
    workers are cleared or zeroed (stop, restart), so expedition totals
    survive. Cost uses each worker's own model rate."""
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        srv.acc_calls += w.r_calls
        srv.acc_ecalls += w.e_calls
        srv.acc_ms += w.r_ms
        srv.acc_ems += w.e_ms
        srv.acc_tin += w.tok_in
        srv.acc_tout += w.tok_out
        var wc = srv_worker_cost(w, srv.price_over)
        if wc < 0.0:
            srv.acc_cost_ok = False
        else:
            srv.acc_cost += wc


struct ApiTotals(ImplicitlyCopyable):
    var calls: Int
    var ecalls: Int
    var ms: Int
    var ems: Int
    var tin: Int
    var tout: Int
    var cost: Float64
    var cost_ok: Bool

    def __init__(
        out self,
        calls: Int,
        ecalls: Int,
        ms: Int,
        ems: Int,
        tin: Int,
        tout: Int,
        cost: Float64,
        cost_ok: Bool,
    ):
        self.calls = calls
        self.ecalls = ecalls
        self.ms = ms
        self.ems = ems
        self.tin = tin
        self.tout = tout
        self.cost = cost
        self.cost_ok = cost_ok


def srv_api_totals(srv: Server) -> ApiTotals:
    var t = ApiTotals(
        srv.acc_calls,
        srv.acc_ecalls,
        srv.acc_ms,
        srv.acc_ems,
        srv.acc_tin,
        srv.acc_tout,
        srv.acc_cost,
        srv.acc_cost_ok,
    )
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        t.calls += w.r_calls
        t.ecalls += w.e_calls
        t.ms += w.r_ms
        t.ems += w.e_ms
        t.tin += w.tok_in
        t.tout += w.tok_out
        var wc = srv_worker_cost(w, srv.price_over)
        if wc < 0.0:
            t.cost_ok = False
        else:
            t.cost += wc
    return t


def srv_run_secs(srv: Server) -> Int:
    if srv.run_t0 <= 0:
        return 0
    if srv.running:
        var now = time_now()
        if now > srv.run_t0:
            return now - srv.run_t0
        return 0
    if srv.run_t1 > srv.run_t0:
        return srv.run_t1 - srv.run_t0
    return 0


def fmt_money4(x: Float64) -> String:
    var c = Int(x * 10000.0 + 0.5)
    if c < 0:
        c = 0
    var frac = String(c % 10000)
    while frac.byte_length() < 4:
        frac = String("0") + frac
    return String(c // 10000) + "." + frac


def fmt_mmss(s: Int) -> String:
    var ss = s
    if ss < 0:
        ss = 0
    var mm = ss // 60
    var rr = String(ss % 60)
    if rr.byte_length() < 2:
        rr = String("0") + rr
    return String(mm) + ":" + rr


def srv_stop_workers(mut srv: Server, reason: String):
    """Forced stop: the server always idles. Running queue items are
    marked done but the queue never advances here — only a natural
    completion (all workers done on their own) starts the next item."""
    srv_flush_all(srv)
    srv_latch_api(srv)
    srv.running = False
    srv.paused = False
    srv.stop_reason = reason
    srv.run_t1 = time_now()
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if w.alive:
            if w.pid > 0:
                _ = kill_pid(w.pid, 15)
                w.term_at = mono_ms()
            w.alive = False
            if w.reason == "":
                w.reason = reason
            srv.workers[i] = w^
    srv_autosave(srv)
    srv_veins_flush(srv)
    srv_log(srv, "run " + String(srv.run_id) + " stopped: " + reason)
    if reason != "shutdown":
        srv_queue_finish_running(srv)


def srv_fork_worker(
    mut srv: Server,
    bid: Int,
    cfg: ExpCfg,
    start_loc: String,
    start_temp: Float64,
    start_seed: Int,
    parent: Int,
    kind: String,
    at_step: Int,
):
    var up = pipe_fds()
    var down = pipe_fds()
    if not up.ok or not down.ok:
        if up.ok:
            _ = close_fd(up.read_fd)
            _ = close_fd(up.write_fd)
        if down.ok:
            _ = close_fd(down.read_fd)
            _ = close_fd(down.write_fd)
        srv_log(srv, "pipe failed for branch " + String(bid))
        return
    var pid = fork_child()
    if pid < 0:
        _ = close_fd(up.read_fd)
        _ = close_fd(up.write_fd)
        _ = close_fd(down.read_fd)
        _ = close_fd(down.write_fd)
        srv_log(srv, "fork failed for branch " + String(bid))
        return
    if pid == 0:
        srv_close_in_child(srv, up, down)
        _ = close_fd(up.read_fd)
        _ = close_fd(down.write_fd)
        worker_main(
            bid, srv.run_id, up.write_fd, down.read_fd, cfg, start_loc, start_temp, start_seed
        )
    _ = close_fd(up.write_fd)
    _ = close_fd(down.read_fd)
    var w = Worker(bid, pid, up.read_fd, down.write_fd)
    w.model = cfg.model
    w.auto = cfg.auto != 0
    srv.workers.append(w^)
    srv.tree.append(TreeNode(bid, parent, kind, at_step))


def srv_start_run(mut srv: Server, mut cfg: ExpCfg):
    # Auto gold bar: blank (or -1) resolves by backend. Measured novelty
    # clusters low on sim (~0.2-0.55) and high on live (~0.4-0.85), so one
    # default weeds one backend or floods the other. Explicit values
    # always win. Lives here (not the start route) so queue advances,
    # which bypass the route, resolve identically.
    if cfg.gold < 0.0:
        var sim = cfg.endpoint == "" or cfg.model == "" or cfg.api_key == ""
        cfg.gold = GOLD_AUTO_SIM if sim else GOLD_AUTO_LIVE
    # Sync cleanup of any previous generation (no zombies, no stray fds).
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if w.pid > 0:
            _ = kill_pid(w.pid, 15)
    for _ in range(30):
        var pending = False
        for i in range(len(srv.workers)):
            var w = srv.workers[i].copy()
            if w.pid <= 0:
                continue
            var r = wait_child(w.pid, True)
            if r.pid == w.pid:
                w.pid = -1
                srv.workers[i] = w^
            else:
                pending = True
        if not pending:
            break
        msleep(50)
    # Survivors past the 1.5s grace get SIGKILLed. Logs are emitted
    # after the reset below (srv.logs is cleared there).
    var killed = List[String]()
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if w.pid > 0:
            var r = wait_child(w.pid, True)
            if r.pid == w.pid:
                w.pid = -1
            else:
                _ = kill_pid(w.pid, 9)
                var r2 = wait_child(w.pid, True)
                if r2.pid == w.pid:
                    w.pid = -1
                killed.append("worker " + String(w.bid) + " SIGKILLed after 1.5s grace")
            srv.workers[i] = w^
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if w.rfd >= 0:
            _ = close_fd(w.rfd)
        if w.wfd >= 0:
            _ = close_fd(w.wfd)
    srv.workers = List[Worker]()
    srv.findings = List[Finding]()
    srv.vecs = List[List[Float64]]()
    srv.aired = List[Int]()
    srv.findings_base = 0
    srv.pca_dirty = True
    srv.pca_pending = 0
    srv.pca_last_ms = 0
    srv.paused = False
    srv.topo_branch = 0
    srv.topo_step = 0
    srv.topo_b0 = 0
    srv.topo_b1 = 0
    srv.topo_b2 = 0
    srv.topo_cd = 0.0
    srv.topo_sheaf = 0.0
    srv.topo_entropy = 0.0
    srv.logs = List[String]()
    srv.gold_count = 0
    srv.streak_no_gold = 0
    srv.spawned = 0
    srv.respawns = 0
    srv.spawned_fanout = 0
    srv.spawn_skipped = 0
    srv.forks_this_tick = 0
    srv.mem_rounds = 0
    srv.next_bid = 0
    srv.gold_seen = 0
    srv.pop_cool = 0
    srv.tree = List[TreeNode]()
    for i in range(len(srv.queue)):
        var q = srv.queue[i].copy()
        if q.status == "running":
            q.status = String("done")
            srv.queue[i] = q^
    srv.stop_reason = String("running")
    srv.cfg = cfg
    srv.run_id += 1
    srv.running = True
    srv.run_t0 = time_now()
    srv.run_t1 = 0
    srv.acc_calls = 0
    srv.acc_ecalls = 0
    srv.acc_ms = 0
    srv.acc_ems = 0
    srv.acc_tin = 0
    srv.acc_tout = 0
    srv.acc_cost = 0.0
    srv.acc_cost_ok = True
    var n = cfg.branches
    if n < 1:
        n = 1
    if n > 16:
        n = 16
    for bid in range(n):
        var bcfg = cfg.copy()
        bcfg.model = branch_model_for(cfg.model, srv.branch_models, bid)
        srv_fork_worker(
            srv, bid, bcfg, cfg.concept, cfg.temp, cfg.seed, -1, "seed", 0
        )
    srv.next_bid = n
    for k in range(len(killed)):
        srv_log(srv, killed[k])
    srv_log(
        srv,
        "run "
        + String(srv.run_id)
        + " started: "
        + String(n)
        + " branches on ["
        + cfg.concept
        + "]",
    )
    srv_broadcast(srv, srv_state_json(srv))


def finding_fields_json(f: Finding) -> String:
    """Inner key/value list shared by events, items, step and journal."""
    return (
        String('"branch":')
        + String(f.branch)
        + ',"step":'
        + String(f.step)
        + ',"novelty":'
        + j_render_num(f.nov)
        + ',"coherence":'
        + j_render_num(f.coh)
        + ',"x":'
        + j_render_num(f.x)
        + ',"y":'
        + j_render_num(f.y)
        + ',"z":'
        + j_render_num(f.z)
        + ',"gold":'
        + (String("true") if f.gold else String("false"))
        + ',"text":"'
        + j_escape(f.text)
        + '","b0":'
        + String(f.b0)
        + ',"b1":'
        + String(f.b1)
        + ',"b2":'
        + String(f.b2)
        + ',"cd":'
        + j_render_num(f.cd)
        + ',"persona":'
        + String(f.persona)
        + ',"temp":'
        + j_render_num(f.temp)
        + ',"loc":"'
        + j_escape(f.loc)
        + '","src":"'
        + j_escape(f.src)
        + '"'
    )


def finding_item_json(f: Finding) -> String:
    return String("{") + finding_fields_json(f) + "}"


def finding_event(run: Int, f: Finding) -> String:
    return (
        String('{"t":"finding","run":')
        + String(run)
        + ","
        + finding_fields_json(f)
        + "}"
    )


def journal_entry_json(f: Finding, vec: List[Float64]) -> String:
    """Archive entry shape: finding fields without the live src tag.

    The vec rides along so reloads restore full geometry (topo, PCA,
    search); loaders recompute hash vecs from text when it is absent.
    """
    var out = (
        String('{"branch":')
        + String(f.branch)
        + ',"step":'
        + String(f.step)
        + ',"novelty":'
        + j_render_num(f.nov)
        + ',"coherence":'
        + j_render_num(f.coh)
        + ',"x":'
        + j_render_num(f.x)
        + ',"y":'
        + j_render_num(f.y)
        + ',"z":'
        + j_render_num(f.z)
        + ',"gold":'
        + (String("true") if f.gold else String("false"))
        + ',"text":"'
        + j_escape(f.text)
        + '","b0":'
        + String(f.b0)
        + ',"b1":'
        + String(f.b1)
        + ',"b2":'
        + String(f.b2)
        + ',"cd":'
        + j_render_num(f.cd)
        + ',"persona":'
        + String(f.persona)
        + ',"temp":'
        + j_render_num(f.temp)
        + ',"loc":"'
        + j_escape(f.loc)
        + '","vec":['
    )
    for j in range(len(vec)):
        if j > 0:
            out += ","
        out += j_render_num(vec[j])
    out += "]}"
    return out


def srv_center_missing(mut srv: Server):
    for k in range(len(srv.findings)):
        var f = srv.findings[k]
        if f.x == 0.0 and f.y == 0.0:
            f.x = 50.0
            f.y = 50.0
            f.z = 50.0
            srv.findings[k] = f^


def srv_refresh_pca(mut srv: Server):
    """Fit 3-comp PCA on the last <=200 vecs, project all, scale 0..100."""
    if not srv.pca_dirty:
        return
    srv.pca_dirty = False
    srv.pca_pending = 0
    srv.pca_last_ms = mono_ms()
    var dim = 0
    var i = len(srv.vecs) - 1
    while i >= 0:
        if len(srv.vecs[i]) > 0:
            dim = len(srv.vecs[i])
            break
        i -= 1
    if dim == 0:
        srv_center_missing(srv)
        return
    var win = List[List[Float64]]()
    var j = len(srv.vecs) - 1
    while j >= 0 and len(win) < 200:
        if len(srv.vecs[j]) == dim:
            win.append(srv.vecs[j].copy())
        j -= 1
    if len(win) < 2:
        srv_center_missing(srv)
        return
    var comps = List[List[Float64]]()
    var mean = List[Float64]()
    pca_fit(win, 3, comps, mean)
    if len(comps) == 0:
        srv_center_missing(srv)
        return
    var n = 0
    var minx = 1e30
    var maxx = -1e30
    var miny = 1e30
    var maxy = -1e30
    var minz = 1e30
    var maxz = -1e30
    for k in range(len(srv.findings)):
        if len(srv.vecs[k]) != dim:
            continue
        var p = pca_project(srv.vecs[k], mean, comps)
        var pz = pca_z(srv.vecs[k], mean, comps)
        var f = srv.findings[k]
        f.x = p.x
        f.y = p.y
        f.z = pz
        srv.findings[k] = f^
        if p.x < minx:
            minx = p.x
        if p.x > maxx:
            maxx = p.x
        if p.y < miny:
            miny = p.y
        if p.y > maxy:
            maxy = p.y
        if pz < minz:
            minz = pz
        if pz > maxz:
            maxz = pz
        n += 1
    if n == 0:
        srv_center_missing(srv)
        return
    var sx = maxx - minx
    var sy = maxy - miny
    var sz = maxz - minz
    for k in range(len(srv.findings)):
        if len(srv.vecs[k]) != dim:
            continue
        var f = srv.findings[k]
        if sx <= 1e-12:
            f.x = 50.0
        else:
            f.x = (f.x - minx) / sx * 100.0
        if sy <= 1e-12:
            f.y = 50.0
        else:
            f.y = (f.y - miny) / sy * 100.0
        if sz <= 1e-12:
            f.z = 50.0
        else:
            f.z = (f.z - minz) / sz * 100.0
        srv.findings[k] = f^
    srv_center_missing(srv)


def srv_broadcast_finding(mut srv: Server, idx: Int):
    if idx < 0 or idx >= len(srv.findings):
        return
    if srv.aired[idx] != 0:
        return
    srv.aired[idx] = 1
    var f = srv.findings[idx]
    # Between cadenced refits a finding may air before its first
    # projection; center it like the flush paths so SSE coords stay
    # present (the next refit overwrites with fitted values).
    if f.x == 0.0 and f.y == 0.0:
        f.x = 50.0
        f.y = 50.0
        f.z = 50.0
        srv.findings[idx] = f^
    var g = srv.findings[idx]
    srv_broadcast(srv, finding_event(srv.run_id, g))


def srv_flush_branch(mut srv: Server, bid: Int):
    for k in range(len(srv.findings)):
        var f = srv.findings[k]
        if f.branch != bid or srv.aired[k] != 0:
            continue
        if f.x == 0.0 and f.y == 0.0:
            f.x = 50.0
            f.y = 50.0
            f.z = 50.0
            srv.findings[k] = f^
        srv.aired[k] = 1
        var g = srv.findings[k]
        srv_broadcast(srv, finding_event(srv.run_id, g))


def srv_flush_all(mut srv: Server):
    for k in range(len(srv.findings)):
        if srv.aired[k] != 0:
            continue
        var f = srv.findings[k]
        if f.x == 0.0 and f.y == 0.0:
            f.x = 50.0
            f.y = 50.0
            f.z = 50.0
            srv.findings[k] = f^
        srv.aired[k] = 1
        var g = srv.findings[k]
        srv_broadcast(srv, finding_event(srv.run_id, g))


def srv_finding_push(mut srv: Server, f: Finding, aired: Int):
    """Append one finding plus its vec slot and aired flag, enforcing
    the FINDINGS_CAP drop-oldest-front bound on all three lists.

    Index-shift safety: every consumer is tail-relative (the 64-scan
    vec match, the last-50 SSE prelude, the last-5000 journal window)
    or keyed by (branch, step) (/api/step, /api/related; pareto indices
    are relative to the same response) except /api/findings, whose
    since=/next contract is absolute. findings_base keeps that
    contract: next = base + len, and since= translates by -base, so a
    client holding a pre-drop `next` still lands on the right window
    (clamped to the oldest retained row). Drops over-trim by 1000 so
    a sustained ingest pays O(CAP) only once per 1000 appends."""
    srv.findings.append(f)
    var empty = List[Float64]()
    srv.vecs.append(empty^)
    srv.aired.append(aired)
    if len(srv.findings) > FINDINGS_CAP:
        var drop = len(srv.findings) - (FINDINGS_CAP - 1000)
        var kf = List[Finding]()
        var kv = List[List[Float64]]()
        var ka = List[Int]()
        for i in range(drop, len(srv.findings)):
            kf.append(srv.findings[i])
            kv.append(srv.vecs[i].copy())
            ka.append(srv.aired[i])
        srv.findings = kf.copy()
        srv.vecs = kv.copy()
        srv.aired = ka.copy()
        srv.findings_base += drop
    srv.pca_dirty = True


def srv_handle_line(mut srv: Server, wi: Int, line: String):
    var kind: String
    try:
        kind = msg_kind(line)
    except:
        srv_note_line_fail(srv, wi, "?", line)
        return
    if kind == "finding":
        var f: Finding
        try:
            var bad = _finding_bad_field(line)
            if bad != "":
                srv_note_line_fail(srv, wi, kind + " non-finite " + bad, line)
                return
            f = parse_finding(line)
        except:
            srv_note_line_fail(srv, wi, kind, line)
            return
        if f.run != srv.run_id:
            srv.run_drops += 1
            srv_log(
                srv,
                "dropped stale finding run="
                + String(f.run)
                + " want="
                + String(srv.run_id),
            )
            return
        srv_note_line_ok(srv, wi)
        var w = srv.workers[wi].copy()
        w.step = f.step
        if f.nov > w.best:
            w.best = f.nov
        srv.workers[wi] = w^
        if f.gold:
            srv.gold_count += 1
            srv.streak_no_gold = 0
            srv_log(
                srv,
                "GOLD b"
                + String(f.branch)
                + " s"
                + String(f.step)
                + " nov="
                + j_render_num(f.nov),
            )
        else:
            srv.streak_no_gold += 1
        srv_finding_push(srv, f, 0)
        if len(srv.vecs) > 4000:
            var drop = List[Float64]()
            srv.vecs[len(srv.vecs) - 4000] = drop^
        var gstop = global_should_stop(srv.streak_no_gold, srv.cfg)
        if gstop != "" and srv.running:
            srv_stop_workers(srv, gstop)
    elif kind == "vec":
        var vv = List[Float64]()
        try:
            var raw_vv = List[Float64]()
            msg_vec(line, "vec", raw_vv)
            var vbad = False
            for j in range(len(raw_vv)):
                if not _finite(raw_vv[j]):
                    vbad = True
                    break
            if not _finite(msg_num(line, "branch")) or not _finite(
                msg_num(line, "step")
            ):
                vbad = True
            if vbad:
                srv_note_line_fail(srv, wi, kind + " non-finite vec", line)
                return
            var m = parse_vec(line, vv)
            if m.run != srv.run_id:
                srv.run_drops += 1
                srv_log(
                    srv,
                    "dropped stale vec run="
                    + String(m.run)
                    + " want="
                    + String(srv.run_id),
                )
                return
            var idx = -1
            var k = len(srv.findings) - 1
            var scanned = 0
            while k >= 0 and scanned < 64:
                var f = srv.findings[k]
                if f.branch == m.branch and f.step == m.step:
                    idx = k
                    break
                k -= 1
                scanned += 1
            if idx < 0:
                return
            var gf = srv.findings[idx]
            if gf.gold:
                srv_vein_append(srv, gf, vv)
            srv.vecs[idx] = vv^
            srv.pca_dirty = True
            # A refit costs ~15ms (JIT, 200x64) and old code paid it per
            # vec. Cadence: refit after 10 landed vecs or 2s, whichever
            # comes first; read paths (/api/findings, /api/journal,
            # /events) refresh on demand so coords still converge.
            srv.pca_pending += 1
            var pnow = mono_ms()
            if srv.pca_pending >= 10 or (
                pnow >= 0 and pnow - srv.pca_last_ms >= 2000
            ):
                srv_refresh_pca(srv)
            srv_broadcast_finding(srv, idx)
        except:
            srv_note_line_fail(srv, wi, kind, line)
            return
        srv_note_line_ok(srv, wi)
    elif kind == "tele":
        try:
            # One JSON parse into all fields (was ~25 msg_num/msg_int
            # parses); clamp order and log text unchanged.
            var tm = parse_tele(line)
            if tm.run != srv.run_id:
                srv.run_drops += 1
                srv_log(
                    srv,
                    "dropped stale tele run="
                    + String(tm.run)
                    + " want="
                    + String(srv.run_id),
                )
                return
            var cfields = String()
            if not _finite(tm.temp):
                cfields += " temp"
            if not _finite(tm.streak):
                cfields += " streak"
            if not _finite(tm.persona):
                cfields += " persona"
            if not _finite(tm.energy):
                cfields += " energy"
            if not _finite(tm.b0):
                cfields += " b0"
            if not _finite(tm.b1):
                cfields += " b1"
            if not _finite(tm.b2):
                cfields += " b2"
            if not _finite(tm.cd):
                cfields += " cd"
            if not _finite(tm.sheaf):
                cfields += " sheaf"
            if not _finite(tm.entropy):
                cfields += " entropy"
            if not _finite(tm.judges):
                cfields += " judges"
            if not _finite(tm.r_calls):
                cfields += " r_calls"
            if not _finite(tm.e_calls):
                cfields += " e_calls"
            if not _finite(tm.r_ms):
                cfields += " r_ms"
            if not _finite(tm.e_ms):
                cfields += " e_ms"
            if not _finite(tm.tok_in):
                cfields += " tok_in"
            if not _finite(tm.tok_out):
                cfields += " tok_out"
            if not _finite(tm.push):
                cfields += " push"
            if not _finite(tm.step):
                cfields += " step"
            var w = srv.workers[wi].copy()
            w.temp = 0.0
            if _finite(tm.temp):
                w.temp = tm.temp
            w.cd = 0.0
            if _finite(tm.cd):
                w.cd = tm.cd
            w.sheaf = 0.0
            if _finite(tm.sheaf):
                w.sheaf = tm.sheaf
            w.entropy = 0.0
            if _finite(tm.entropy):
                w.entropy = tm.entropy
            w.push = 0.0
            if _finite(tm.push):
                w.push = tm.push
            w.streak = tele_int(tm.streak)
            w.persona = tele_int(tm.persona)
            w.energy = tele_int(tm.energy)
            w.b0 = tele_int(tm.b0)
            w.b1 = tele_int(tm.b1)
            w.b2 = tele_int(tm.b2)
            w.judges = tele_int(tm.judges)
            w.r_calls = tele_int(tm.r_calls)
            w.e_calls = tele_int(tm.e_calls)
            w.r_ms = tele_int(tm.r_ms)
            w.e_ms = tele_int(tm.e_ms)
            w.tok_in = tele_int(tm.tok_in)
            w.tok_out = tele_int(tm.tok_out)
            w.step = tele_int(tm.step)
            var tblog = w.bid
            srv.workers[wi] = w^
            srv_note_line_ok(srv, wi)
            if cfields != "":
                srv_log(
                    srv, "worker " + String(tblog) + " tele non-finite clamped:" + cfields
                )
            var t = srv.workers[wi].copy()
            srv.topo_branch = t.bid
            srv.topo_step = t.step
            srv.topo_b0 = t.b0
            srv.topo_b1 = t.b1
            srv.topo_b2 = t.b2
            srv.topo_cd = t.cd
            srv.topo_sheaf = t.sheaf
            srv.topo_entropy = t.entropy
            srv_maybe_send_memory(srv, wi)
            srv_broadcast(srv, srv_state_json(srv))
        except:
            srv_note_line_fail(srv, wi, kind, line)
            return
    elif kind == "status":
        var step: Int
        var best: Float64
        var reason: String
        var cbest = False
        try:
            step = msg_int(line, "step")
            var rbest = msg_num(line, "best")
            best = 0.0
            if _finite(rbest):
                best = rbest
            else:
                cbest = True
            reason = msg_str(line, "reason")
        except:
            srv_note_line_fail(srv, wi, kind, line)
            return
        var w = srv.workers[wi].copy()
        w.step = step
        w.best = best
        if reason != "":
            w.reason = reason
        var sblog = w.bid
        srv.workers[wi] = w^
        srv_note_line_ok(srv, wi)
        if cbest:
            srv_log(srv, "worker " + String(sblog) + " status non-finite best clamped")
        # Log every report except routine camp notes: backend failures
        # ("tcp connect failed", "unauthorized - ...") do not contain the
        # word "error", and a silent log is an expedition that looks stuck.
        if reason != "" and not reason.startswith("camp:"):
            srv_log(srv, "worker " + String(sblog) + " status: " + _line_snip(reason))
    elif kind == "spawn":
        # Fanout pursue: a healthy parent offers a runner-up for its own
        # branch. Fork subject to live + per-tick caps; skips are counted,
        # never logged (volume), and visible in state counters.
        var pbid = -1
        var pstep = -1
        try:
            pbid = msg_int(line, "branch")
            pstep = msg_int(line, "step")
        except:
            pbid = -1
        var pi = -1
        for i in range(len(srv.workers)):
            if srv.workers[i].bid == pbid:
                pi = i
                break
        var pok = False
        var pw = Worker(-1, -1, -1, -1)
        if pi >= 0:
            pw = srv.workers[pi].copy()
            pok = pw.alive and pw.step == pstep
        if not pok:
            srv.spawn_skipped += 1
        else:
            var alive_n = 0
            for i in range(len(srv.workers)):
                if srv.workers[i].alive:
                    alive_n += 1
            if alive_n >= FANOUT_LIVE_CAP or srv.forks_this_tick >= FANOUT_TICK_FORKS:
                srv.spawn_skipped += 1
            else:
                var stext = String()
                var smodel = String()
                var stemp = 0.0
                var spersona = -1
                try:
                    stext = msg_str(line, "text")
                    smodel = msg_str(line, "model")
                    stemp = msg_num(line, "temp")
                    spersona = msg_int(line, "persona")
                except:
                    stext = String()
                if stext == "":
                    srv.spawn_skipped += 1
                else:
                    if smodel == "":
                        smodel = pw.model
                    if not (stemp > 0.0):
                        stemp = pw.temp
                    if stemp <= 0.0:
                        stemp = srv.cfg.temp
                    if spersona < 0 or spersona > 15:
                        spersona = pw.persona
                    var bcfg = srv.cfg.copy()
                    bcfg.model = smodel
                    var nid = srv.next_bid
                    srv_fork_worker(
                        srv,
                        nid,
                        bcfg,
                        stext,
                        stemp,
                        srv.cfg.seed + 2097593 * (nid + 1),
                        pbid,
                        "fanout",
                        pstep,
                    )
                    srv.next_bid += 1
                    while len(srv.branch_models) <= nid:
                        srv.branch_models.append(String())
                    srv.branch_models[nid] = smodel
                    if spersona != nid % 16:
                        srv_send_order(
                            srv,
                            nid,
                            '{"t":"order","name":"persona","idx":'
                            + String(spersona)
                            + "}",
                        )
                    if srv.paused:
                        srv_send_order(srv, nid, '{"t":"order","name":"pause"}')
                    srv.forks_this_tick += 1
                    srv.spawned_fanout += 1
                    srv_log(
                        srv,
                        "fanout b"
                        + String(pbid)
                        + "s"
                        + String(pstep)
                        + " -> b"
                        + String(nid),
                    )
    elif kind == "done":
        var steps: Int
        var best: Float64
        var reason: String
        var cbest = False
        try:
            steps = msg_int(line, "steps")
            var rbest = msg_num(line, "best")
            best = 0.0
            if _finite(rbest):
                best = rbest
            else:
                cbest = True
            reason = msg_str(line, "reason")
        except:
            srv_note_line_fail(srv, wi, kind, line)
            return
        var w = srv.workers[wi].copy()
        w.step = steps
        w.best = best
        w.alive = False
        if reason != "":
            w.reason = reason
        var blog = w.bid
        srv.workers[wi] = w^
        srv_note_line_ok(srv, wi)
        if cbest:
            srv_log(srv, "worker " + String(blog) + " done non-finite best clamped")
        srv_flush_branch(srv, blog)
        srv_log(srv, "branch " + String(blog) + " done: " + reason)
        srv_broadcast(srv, srv_state_json(srv))
    else:
        srv_note_line_fail(srv, wi, kind, line)
        return


def srv_drain_workers(mut srv: Server):
    for wi in range(len(srv.workers)):
        var w = srv.workers[wi].copy()
        if w.rfd < 0:
            continue
        while True:
            if poll_one(w.rfd, 0) != 1:
                break
            var chunk = pipe_read_some(w.rfd, 65536)
            if chunk == "":
                break
            w.buf += chunk
            # Cursor split: one slice per line, one trim at the end.
            # (The old per-line remainder re-copy was O(lines^2) per
            # chunk.) Line handlers never touch w.buf, so the cursor
            # stays valid across the store-back below.
            var cur = 0
            while True:
                var nl = buf_find_nl(w.buf, cur)
                if nl < 0:
                    break
                var raw = String(w.buf[byte=cur:nl])
                cur = nl + 1
                var line = String(raw.strip())
                if line == "":
                    continue
                srv.workers[wi] = w^
                srv_handle_line(srv, wi, line)
                w = srv.workers[wi].copy()
                if w.buf.byte_length() < cur:
                    # A handler truncated the buffer mid-chunk; drop
                    # the rest rather than slicing past the end.
                    cur = 0
                    break
            if cur > 0:
                var tail = String(w.buf[byte=cur:])
                w.buf = tail
            # Bound the buffer at the last newline: complete lines are
            # consumed above, so any remainder is a partial tail. Past
            # 1MB it is a runaway line: drop it (never fuse it into a
            # later line) and say so.
            if w.buf.byte_length() > 1048576:
                w.buf = String()
                srv.workers[wi] = w^
                srv_log(
                    srv,
                    "worker "
                    + String(srv.workers[wi].bid)
                    + " dropped >1MB partial line",
                )
                w = srv.workers[wi].copy()
        srv.workers[wi] = w^


def srv_state_json(srv: Server) -> String:
    var out = (
        String('{"t":"state","run":')
        + String(srv.run_id)
        + ',"version":"'
        + String(MM_VERSION)
        + '"'
        + ',"running":'
        + (String("true") if srv.running else String("false"))
        + ',"stop_reason":"'
        + j_escape(srv.stop_reason)
        + '","veins_error":"'
        + j_escape(srv.veins_error)
        + '","findings":'
        + String(srv.findings_base + len(srv.findings))
        + ',"gold":'
        + String(srv.gold_count)
        + ',"streak":'
        + String(srv.streak_no_gold)
        + ',"run_drops":'
        + String(srv.run_drops)
        + ',"paused":'
        + (String("true") if srv.paused else String("false"))
        + ',"run_secs":'
        + String(srv_run_secs(srv))
        + ',"live":'
        + (
            String("true")
            if srv.cfg.endpoint != ""
            and srv.cfg.model != ""
            and srv.cfg.api_key != ""
            else String("false")
        )
        + ',"auto_pop":'
        + (String("true") if srv.auto_pop else String("false"))
        + ',"spawned":'
        + String(srv.spawned)
        + ',"respawns":'
        + String(srv.respawns)
        + ',"spawned_fanout":'
        + String(srv.spawned_fanout)
        + ',"spawn_skipped":'
        + String(srv.spawn_skipped)
        + ',"mem_rounds":'
        + String(srv.mem_rounds)
        + ',"cfg":{"concept":"'
        + j_escape(srv.cfg.concept)
        + '","model":"'
        + j_escape(srv.cfg.model)
        + '","endpoint":"'
        + j_escape(srv.cfg.endpoint)
        + '","embed_model":"'
        + j_escape(srv.cfg.embed_model)
        + '","embed_endpoint":"'
        + j_escape(srv.cfg.embed_endpoint)
        + '","seed":'
        + String(srv.cfg.seed)
        + ',"branches":'
        + String(srv.cfg.branches)
        + ',"steps":'
        + String(srv.cfg.steps)
        + ',"gold":'
        + j_render_num(srv.cfg.gold)
        + ',"temp":'
        + j_render_num(srv.cfg.temp)
        + ',"repulse":'
        + String(srv.cfg.repulse)
        + ',"fanout":'
        + String(srv.cfg.fanout)
        + ',"judges":'
        + String(srv.cfg.judges)
        + ',"auto":'
        + String(srv.cfg.auto)
        + ',"push":'
        + j_render_num(srv.cfg.push)
        + ',"plateau_k":'
        + String(srv.cfg.plateau_k)
        + ',"plateau_eps":'
        + j_render_num(srv.cfg.plateau_eps)
        + ',"nogold_m":'
        + String(srv.cfg.nogold_m)
        + ',"min_coh":'
        + j_render_num(srv.cfg.min_coh)
        + ',"coh_c":'
        + String(srv.cfg.coh_c)
        + ',"global_stall":'
        + String(srv.cfg.global_stall)
        + ',"call_budget":'
        + String(srv.cfg.call_budget)
        + '},"workers":['
    )
    var ac = srv.acc_calls
    var ae = srv.acc_ecalls
    var am = srv.acc_ms
    var aem = srv.acc_ems
    var ain = srv.acc_tin
    var aout = srv.acc_tout
    var acost = srv.acc_cost
    var acost_ok = srv.acc_cost_ok
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        ac += w.r_calls
        ae += w.e_calls
        am += w.r_ms
        aem += w.e_ms
        ain += w.tok_in
        aout += w.tok_out
        var wc = srv_worker_cost(w, srv.price_over)
        if wc < 0.0:
            acost_ok = False
        else:
            acost += wc
        if i > 0:
            out += ","
        out += (
            String('{"branch":')
            + String(w.bid)
            + ',"alive":'
            + (String("true") if w.alive else String("false"))
            + ',"step":'
            + String(w.step)
            + ',"best":'
            + j_render_num(w.best)
            + ',"reason":"'
            + j_escape(w.reason)
            + '","temp":'
            + j_render_num(w.temp)
            + ',"streak":'
            + String(w.streak)
            + ',"persona":'
            + String(w.persona)
            + ',"energy":'
            + String(w.energy)
            + ',"b0":'
            + String(w.b0)
            + ',"b1":'
            + String(w.b1)
            + ',"b2":'
            + String(w.b2)
            + ',"cd":'
            + j_render_num(w.cd)
            + ',"sheaf":'
            + j_render_num(w.sheaf)
            + ',"entropy":'
            + j_render_num(w.entropy)
            + ',"judges":'
            + String(w.judges)
            + ',"model":"'
            + j_escape(w.model)
            + '","auto":'
            + (String("true") if w.auto else String("false"))
            + ',"r_calls":'
            + String(w.r_calls)
            + ',"e_calls":'
            + String(w.e_calls)
            + ',"r_ms":'
            + String(w.r_ms)
            + ',"e_ms":'
            + String(w.e_ms)
            + ',"tok_in":'
            + String(w.tok_in)
            + ',"tok_out":'
            + String(w.tok_out)
            + ',"push":'
            + j_render_num(w.push)
            + ',"sick":'
            + (String("true") if w.sick else String("false"))
            + "}"
        )
    out += (
        String('],"topo":{"branch":')
        + String(srv.topo_branch)
        + ',"step":'
        + String(srv.topo_step)
        + ',"b0":'
        + String(srv.topo_b0)
        + ',"b1":'
        + String(srv.topo_b1)
        + ',"b2":'
        + String(srv.topo_b2)
        + ',"cd":'
        + j_render_num(srv.topo_cd)
        + ',"sheaf":'
        + j_render_num(srv.topo_sheaf)
        + ',"entropy":'
        + j_render_num(srv.topo_entropy)
        + '},"api":{"calls":'
        + String(ac)
        + ',"ecalls":'
        + String(ae)
        + ',"ms":'
        + String(am)
        + ',"ems":'
        + String(aem)
        + ',"tok_in":'
        + String(ain)
        + ',"tok_out":'
        + String(aout)
        + ',"cost":'
        + fmt_money4(acost)
        + ',"cost_ok":'
        + (String("true") if acost_ok else String("false"))
        + "}}"
    )
    return out


def srv_findings_json(srv: Server, since: Int, gold_only: Bool, limit: Int) -> String:
    var out = (
        String('{"t":"findings","next":')
        + String(srv.findings_base + len(srv.findings))
    )
    out += ',"items":['
    var shown = 0
    var i = since - srv.findings_base
    if i < 0:
        i = 0
    while i < len(srv.findings) and shown < limit:
        var f = srv.findings[i]
        if gold_only and not f.gold:
            i += 1
            continue
        if shown > 0:
            out += ","
        out += finding_item_json(f)
        shown += 1
        i += 1
    out += "]}"
    return out


def srv_send_order(mut srv: Server, bid: Int, line: String):
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if not w.alive or w.wfd < 0:
            continue
        if bid >= 0 and w.bid != bid:
            continue
        if pipe_write_all(w.wfd, line + "\n") < 0:
            # EPIPE: the worker is gone. Mark it dead at once so the
            # herd sends no orders at a corpse and restart reforks it.
            var b = w.bid
            _ = close_fd(w.wfd)
            w.wfd = -1
            w.alive = False
            if w.reason == "":
                w.reason = String("order-epipe")
            srv.workers[i] = w^
            srv_log(srv, "worker " + String(b) + " order write failed: marked dead")


def srv_restart(mut srv: Server):
    """Soft restart for live workers plus refork of the dead so the run
    always has the full branch complement again. Also valid after a
    natural completion (nothing is alive then, so everything reforks).
    The tree is rebuilt fresh like at start; setmodel switches survive
    because they persist into branch_models."""
    srv_send_order(srv, -1, '{"t":"order","name":"restart"}')
    srv_latch_api(srv)
    # Drop dead workers (done / EPIPE / respawn stubs): SIGTERM any
    # lingering pid, reap what exits, SIGKILL the rest, close fds.
    var keep = List[Worker]()
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if w.alive:
            keep.append(w^)
            continue
        if w.pid > 0:
            _ = kill_pid(w.pid, 15)
            var reaped = False
            for _ in range(10):
                var r = wait_child(w.pid, True)
                if r.pid == w.pid:
                    reaped = True
                    break
                msleep(50)
            if not reaped:
                _ = kill_pid(w.pid, 9)
                var r2 = wait_child(w.pid, True)
                if r2.pid == w.pid:
                    reaped = True
                srv_log(srv, "worker " + String(w.bid) + " SIGKILLed on restart")
            if reaped:
                w.pid = -1
        if w.rfd >= 0:
            _ = close_fd(w.rfd)
        if w.wfd >= 0:
            _ = close_fd(w.wfd)
    srv.workers = keep.copy()
    srv.findings = List[Finding]()
    srv.vecs = List[List[Float64]]()
    srv.aired = List[Int]()
    srv.findings_base = 0
    srv.pca_dirty = True
    srv.pca_pending = 0
    srv.pca_last_ms = 0
    srv.paused = False
    srv.topo_branch = 0
    srv.topo_step = 0
    srv.topo_b0 = 0
    srv.topo_b1 = 0
    srv.topo_b2 = 0
    srv.topo_cd = 0.0
    srv.topo_sheaf = 0.0
    srv.topo_entropy = 0.0
    srv.gold_count = 0
    srv.streak_no_gold = 0
    srv.gold_seen = 0
    srv.pop_cool = 0
    srv.tree = List[TreeNode]()
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        w.step = 0
        w.best = 0.0
        w.reason = String()
        w.temp = 0.0
        w.streak = 0
        w.persona = 0
        w.energy = 100
        w.b0 = 0
        w.b1 = 0
        w.b2 = 0
        w.cd = 0.0
        w.sheaf = 0.0
        w.entropy = 0.0
        w.judges = 0
        w.line_fails = 0
        w.sick = False
        w.term_at = 0
        w.mem_step = 0
        w.buf = String()
        w.model = branch_model_for(srv.cfg.model, srv.branch_models, w.bid)
        w.auto = srv.cfg.auto != 0
        w.r_calls = 0
        w.e_calls = 0
        w.r_ms = 0
        w.e_ms = 0
        w.tok_in = 0
        w.tok_out = 0
        w.push = 0.0
        var kbid = w.bid
        srv.workers[i] = w^
        srv.tree.append(TreeNode(kbid, -1, "seed", 0))
    # Nothing survived (restart after completion, or first boot): reuse
    # start-like numbering so branches are 0..n-1 again.
    if len(srv.workers) == 0:
        srv.next_bid = 0
    var n = srv.cfg.branches
    if n < 1:
        n = 1
    if n > 16:
        n = 16
    var rconcept = srv.cfg.concept
    var rtemp = srv.cfg.temp
    var rseed = srv.cfg.seed
    while len(srv.workers) < n:
        var bcfg = srv.cfg.copy()
        bcfg.model = branch_model_for(srv.cfg.model, srv.branch_models, srv.next_bid)
        var nbid = srv.next_bid
        srv_fork_worker(srv, nbid, bcfg, rconcept, rtemp, rseed, -1, "seed", 0)
        srv.next_bid += 1
    srv.stop_reason = String("running")
    srv.running = True
    srv.saved_run = 0
    srv_log(srv, "run " + String(srv.run_id) + " restarted")
    srv_broadcast(srv, srv_state_json(srv))


def srv_maybe_send_memory(mut srv: Server, wi: Int):
    """Hive memory: every 4th step, share others' texts/vecs/gold mean.

    One pass over findings/vecs; the gold mean covers the trailing
    <=200 rows (older gold has decayed out of relevance anyway).
    """
    if not srv.running or srv.paused:
        return
    if len(srv.findings) < 4:
        return
    var w = srv.workers[wi].copy()
    if w.step - w.mem_step < 4:
        return
    w.mem_step = w.step
    var bid = w.bid
    srv.workers[wi] = w^
    # Single pass over findings/vecs (was: tail scan for texts plus a
    # full scan for vecs plus a full scan for the gold mean). Texts
    # keep newest-first order, the vec stride sees ascending indices
    # as before, and the gold mean covers the trailing <=200 window.
    var n = len(srv.findings)
    var gstart = n - 200
    if gstart < 0:
        gstart = 0
    var tidx = List[Int]()
    var cands = List[Int]()
    var gsum = List[Float64]()
    var gdim = 0
    var gn = 0
    for j in range(n):
        var f = srv.findings[j]
        var vl = len(srv.vecs[j])
        if f.branch != bid:
            tidx.append(j)
            if vl > 0:
                cands.append(j)
        if j >= gstart and f.gold and vl > 0:
            if gdim == 0:
                gdim = vl
                for d in range(gdim):
                    gsum.append(0.0)
            if vl != gdim:
                continue
            for d in range(gdim):
                gsum[d] = gsum[d] + srv.vecs[j][d]
            gn += 1
    if len(tidx) == 0:
        return
    var line = String('{"t":"order","name":"memory","texts":[')
    var tfirst = len(tidx) - 30
    if tfirst < 0:
        tfirst = 0
    var ti = len(tidx) - 1
    var tn = 0
    while ti >= tfirst:
        if tn > 0:
            line += ","
        line += '"' + j_escape(srv.findings[tidx[ti]].text) + '"'
        tn += 1
        ti -= 1
    line += '],"vecs":['
    var nv = 0
    if len(cands) > 0:
        var stride = len(cands) // 20
        if stride < 1:
            stride = 1
        var q = 0
        while q < len(cands) and nv < 20:
            var vv = srv.vecs[cands[q]].copy()
            if nv > 0:
                line += ","
            line += "["
            for d in range(len(vv)):
                if d > 0:
                    line += ","
                line += j_render_num(vv[d])
            line += "]"
            nv += 1
            q += stride
    line += "]"
    if gn > 0:
        line += ',"gold":['
        for d in range(gdim):
            if d > 0:
                line += ","
            line += j_render_num(gsum[d] / Float64(gn))
        line += "]"
    line += "}"
    srv_send_order(srv, bid, line)
    srv.mem_rounds += 1


def srv_population(mut srv: Server):
    """Dynamic population: vein-miners at gold, fresh blood for the cold."""
    srv.forks_this_tick = 0
    if not srv.running or not srv.auto_pop or srv.paused:
        return
    if srv.pop_cool > 0:
        srv.pop_cool -= 1
        return
    var pcfg = srv.cfg
    if srv.gold_count > srv.gold_seen:
        srv.gold_seen = srv.gold_count
        var alive = 0
        for i in range(len(srv.workers)):
            if srv.workers[i].alive:
                alive += 1
        if alive < 16 and len(srv.findings) > 0:
            var gloc = pcfg.concept
            var gbranch = -1
            var gstep = 0
            var k = len(srv.findings) - 1
            while k >= 0:
                var f = srv.findings[k]
                if f.gold:
                    gloc = f.text
                    gbranch = f.branch
                    gstep = f.step
                    break
                k -= 1
            var scfg = pcfg.copy()
            scfg.model = branch_model_for(srv.cfg.model, srv.branch_models, srv.next_bid)
            srv_fork_worker(
                srv,
                srv.next_bid,
                scfg,
                gloc,
                pcfg.temp,
                pcfg.seed + 7919 * (srv.spawned + 1),
                gbranch,
                "gold",
                gstep,
            )
            srv.next_bid += 1
            srv.spawned += 1
            srv_log(srv, "spawned vein-miner at gold strike")
            srv.pop_cool = 30
            return
    var worst = -1
    var wbest = 0.45
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if not w.alive or w.pid <= 0:
            continue
        if w.step >= 12 and w.best < wbest:
            wbest = w.best
            worst = i
    if worst >= 0:
        var w = srv.workers[worst].copy()
        _ = kill_pid(w.pid, 15)
        w.term_at = mono_ms()
        if w.rfd >= 0:
            _ = close_fd(w.rfd)
            w.rfd = -1
        if w.wfd >= 0:
            _ = close_fd(w.wfd)
            w.wfd = -1
        w.alive = False
        if w.reason == "":
            w.reason = "respawned"
        # Dead workers are never drained again (rfd < 0), so drop the
        # line buffer here: it is the only unbounded tail a dead Worker
        # could otherwise retain (up to the 1MB runaway-line cap).
        # Workers/tree stay otherwise unbounded by design: a dead Worker
        # is ~30 scalars + short strings (<1KB), a TreeNode is 3 ints +
        # a short kind (<100B), growth is cooldown-bound to <=1 respawn
        # per 150 ticks (~400/hr sustained, only while a cold branch
        # exists; spawns need a gold strike), and both lists are
        # cleared on start/restart. Worst case ~= 400KB/hr, and the
        # tree keeps no positional indices (nodes key by bid), so a
        # future cap could drop oldest nodes without shifting refs.
        w.buf = String()
        var old_bid = w.bid
        var old_step = w.step
        srv.workers[worst] = w^
        srv_flush_branch(srv, old_bid)
        var rcfg = pcfg.copy()
        rcfg.model = branch_model_for(srv.cfg.model, srv.branch_models, srv.next_bid)
        srv_fork_worker(
            srv,
            srv.next_bid,
            rcfg,
            pcfg.concept,
            pcfg.temp,
            pcfg.seed + 104729 * (srv.respawns + 1),
            old_bid,
            "respawn",
            old_step,
        )
        srv.next_bid += 1
        srv.respawns += 1
        srv_log(srv, "respawned cold branch " + String(old_bid))
        srv.pop_cool = 150


def journal_pareto(findings: List[Finding], start: Int, mut out: List[Int]):
    """Pareto over findings[start:], indices relative to the window.

    The /api/journal entries array holds the same window, so indices
    line up with the entries they ship next to.
    """
    var pool = List[Finding]()
    var s = start
    if s < 0:
        s = 0
    for i in range(s, len(findings)):
        pool.append(findings[i])
    pareto(pool, out)


def srv_journal_json(srv: Server) -> String:
    var total = len(srv.findings)
    var start = 0
    if total > 5000:
        start = total - 5000
    var out = (
        String('{"t":"journal","run":')
        + String(srv.run_id)
        + ',"concept":"'
        + j_escape(srv.cfg.concept)
        + '","model":"'
        + j_escape(srv.cfg.model)
        + '","total":'
        + String(total)
        + ',"truncated":'
        + (String("true") if start > 0 else String("false"))
        + ',"entries":['
    )
    for i in range(start, total):
        var f = srv.findings[i]
        if i > start:
            out += ","
        out += finding_item_json(f)
    out += "],"
    # Pareto runs over the exported 5000-window, not all findings:
    # O(window^2) instead of O(total^2), and indices match entries[].
    var pf = List[Int]()
    journal_pareto(srv.findings, start, pf)
    out += '"pareto":['
    for i in range(len(pf)):
        if i > 0:
            out += ","
        out += String(pf[i])
    out += "]}"
    return out


def srv_save_journal(mut srv: Server) -> String:
    """Write findings to ./journals/journal_STAMP.json. Filename or "".

    Streams the file in ~64KB chunks (one truncate-write plus
    appends) so a big run never builds the whole multi-MB body as one
    transient String. Byte-identical to the old single-write layout.
    """
    _ = dir_make("journals")
    var stamp = format_stamp(time_now())
    if stamp == "":
        return String()
    var name = "journal_" + stamp + ".json"
    var first = file_stat("journals/" + name)
    if first[0] >= 0:
        var n = 2
        var done = False
        while n <= 100 and not done:
            var cand = "journal_" + stamp + "_" + String(n) + ".json"
            var stc = file_stat("journals/" + cand)
            if stc[0] < 0:
                name = cand
                done = True
            n += 1
        if not done:
            return String()
    srv.journals_cache_valid = False
    var path = "journals/" + name
    var vkind = String("hash")
    if srv.cfg.embed_model != "":
        vkind = String("embed")
    var head = (
        String('{"starting_concept":"')
        + j_escape(srv.cfg.concept)
        + '","vec_kind":"'
        + vkind
        + '","model":"'
        + j_escape(_src_model(srv))
        + '","endpoint":"'
        + j_escape(_src_endpoint(srv))
        + '","embed_model":"'
        + j_escape(srv.cfg.embed_model)
        + '","embed_endpoint":"'
        + j_escape(srv.cfg.embed_endpoint)
        + '","app_version":"'
        + String(MM_VERSION)
        + '","entries":['
    )
    if file_write_all(path, head) < 0:
        return String()
    var chunk = String()
    for i in range(len(srv.findings)):
        if i > 0:
            chunk += ","
        var vv = List[Float64]()
        if i < len(srv.vecs):
            vv = srv.vecs[i].copy()
        chunk += journal_entry_json(srv.findings[i], vv)
        if chunk.byte_length() >= 65536:
            if file_append_all(path, chunk) < 0:
                return String()
            chunk = String()
    chunk += "]}"
    if file_append_all(path, chunk) < 0:
        return String()
    var pruned = journal_prune()
    if pruned > 0:
        srv_log(srv, "journals pruned: " + String(pruned))
    return name


def journal_victims(mtimes: List[Int], cap: Int) -> List[Int]:
    """Indices of the oldest entries to delete so the listing fits cap.

    Oldest-first insertion sort on mtime (n is small: one scan per save,
    past cap only). Pure: unit-testable; the caller unlinks the victims.
    """
    var idx = List[Int]()
    for i in range(len(mtimes)):
        idx.append(i)
    for i in range(1, len(idx)):
        var key = idx[i]
        var j = i - 1
        while j >= 0 and mtimes[idx[j]] > mtimes[key]:
            idx[j + 1] = idx[j]
            j -= 1
        idx[j + 1] = key
    var out = List[Int]()
    var excess = len(idx) - cap
    if excess < 0:
        excess = 0
    for k in range(excess):
        out.append(idx[k])
    return out.copy()


def journal_prune() -> Int:
    """Delete oldest journal_*.json files past JOURNAL_CAP. Returns count."""
    var names = List[String]()
    var mtimes = List[Int]()
    var raw = dir_list("journals")
    for i in range(len(raw)):
        var nm = raw[i]
        if not nm.startswith("journal_") or not nm.endswith(".json"):
            continue
        var st = file_stat("journals/" + nm)
        if st[0] < 0:
            continue
        names.append(nm)
        mtimes.append(st[1])
    var n = 0
    var victims = journal_victims(mtimes, JOURNAL_CAP)
    for k in range(len(victims)):
        if file_remove("journals/" + names[victims[k]]) == 0:
            n += 1
    return n


def srv_autosave(mut srv: Server):
    """Persist once per run when the run ends with at least one finding."""
    if len(srv.findings) == 0:
        return
    if srv.run_id == srv.saved_run or srv.run_id <= 0:
        return
    var name = srv_save_journal(srv)
    if name != "":
        srv.saved_run = srv.run_id
        srv_log(srv, "journal saved: " + name)


def _journal_entries_node(dd: Doc, rr: Int) -> Int:
    """Native entries[] first, then legacy roadtrip_log aliases."""
    var arr = doc_find(dd, rr, "entries")
    if arr >= 0 and doc_kind(dd, arr) == J_ARR:
        return arr
    arr = doc_find(dd, rr, "roadtrip_log")
    if arr >= 0 and doc_kind(dd, arr) == J_ARR:
        return arr
    arr = doc_find(dd, rr, "journal_history")
    if arr >= 0 and doc_kind(dd, arr) == J_ARR:
        return arr
    arr = doc_find(dd, rr, "journal_entries")
    if arr >= 0 and doc_kind(dd, arr) == J_ARR:
        return arr
    return -1


def _journal_concept(dd: Doc, rr: Int) -> String:
    var sc = doc_ostr(dd, rr, "starting_concept")
    if sc != "":
        return sc
    return doc_ostr(dd, rr, "concept")


def srv_journals_json(mut srv: Server) -> String:
    """Archive listing, newest first, with the parsed listing cached.

    Each request re-scans names+mtimes+sizes (cheap, no JSON re-parse)
    and returns the cached bytes when the fingerprint matches. The
    cache is invalidated explicitly on journal save/load; there is no
    journal-drop endpoint (journals/ is append-only from the server),
    and any external add/remove/edit flips the fingerprint anyway.
    """
    var fl = List[String]()
    var mt = List[Int]()
    var sz = List[Int]()
    _journal_scan(fl, mt, sz)
    var fp = _journal_fp(fl, mt, sz)
    if srv.journals_cache_valid and fp == srv.journals_cache_fp:
        return srv.journals_cache_json
    var sc = List[String]()
    var stc = List[Int]()
    var skb = List[Float64]()
    var sok = List[Bool]()
    var serr = List[String]()
    var smo = List[String]()
    var sep = List[String]()
    for i in range(len(fl)):
        var raw = file_read_all("journals/" + fl[i])
        var concept = String("Historical Run")
        var nsteps = 0
        var ok = True
        var emsg = String()
        var fmo = String()
        var fep = String()
        try:
            var dd = parse_json(raw)
            var rr = doc_root(dd)
            var c0 = _journal_concept(dd, rr)
            if c0 != "":
                concept = c0
            fmo = doc_ostr(dd, rr, "model")
            fep = doc_ostr(dd, rr, "endpoint")
            var arr = _journal_entries_node(dd, rr)
            if arr >= 0:
                nsteps = doc_len(dd, arr)
        except:
            ok = False
            emsg = String("bad journal json")
        sc.append(concept)
        stc.append(nsteps)
        skb.append(round1(Float64(sz[i]) / 1024.0))
        sok.append(ok)
        serr.append(emsg)
        smo.append(fmo)
        sep.append(fep)
    var order = List[Int]()
    for i in range(len(fl)):
        order.append(i)
    _order_mtime_desc(mt, order)
    var out = String('{"journals":[')
    for k in range(len(order)):
        var i = order[k]
        if k > 0:
            out += ","
        out += (
            String('{"filename":"')
            + j_escape(fl[i])
            + '","starting_concept":"'
            + j_escape(sc[i])
            + '","model":"'
            + j_escape(smo[i])
            + '","endpoint":"'
            + j_escape(sep[i])
            + '","step_count":'
            + String(stc[i])
            + ',"size_kb":'
            + j_render_num(skb[i])
            + ',"modified_time":"'
            + format_mtime(mt[i])
            + '","mtime_ts":'
            + j_render_num(Float64(mt[i]))
            + ',"ok":'
            + (String("true") if sok[i] else String("false"))
            + ',"error":"'
            + j_escape(serr[i])
            + '"}'
        )
    out += "]}"
    srv.journals_cache_json = out
    srv.journals_cache_fp = fp
    srv.journals_cache_valid = True
    return out


def _jnum2(dd: Doc, e: Int, k1: String, k2: String) -> Float64:
    var n1 = doc_find(dd, e, k1)
    if n1 >= 0:
        return doc_num(dd, n1)
    var n2 = doc_find(dd, e, k2)
    if n2 >= 0:
        return doc_num(dd, n2)
    return 0.0


def _jstr2(dd: Doc, e: Int, k1: String, k2: String) -> String:
    var n1 = doc_find(dd, e, k1)
    if n1 >= 0:
        return doc_str(dd, n1)
    var n2 = doc_find(dd, e, k2)
    if n2 >= 0:
        return doc_str(dd, n2)
    return String()


def _jbool2(dd: Doc, e: Int, k1: String, k2: String) -> Bool:
    var n1 = doc_find(dd, e, k1)
    if n1 >= 0:
        return doc_bool(dd, n1)
    var n2 = doc_find(dd, e, k2)
    if n2 >= 0:
        return doc_bool(dd, n2)
    return False


def _jcoord(dd: Doc, e: Int, k: String) -> Float64:
    var n = doc_find(dd, e, k)
    if n >= 0:
        return doc_num(dd, n)
    var pc = doc_find(dd, e, "pca_coord")
    if pc >= 0:
        var m = doc_find(dd, pc, k)
        if m >= 0:
            return doc_num(dd, m)
    return 50.0


def _jpersona(dd: Doc, e: Int) -> Int:
    var n = doc_find(dd, e, "persona")
    if n < 0:
        return 0
    if doc_kind(dd, n) == J_NUM:
        var f = doc_num(dd, n)
        if isinf(f) or isnan(f):
            return 0
        var v = Int(f)
        if v < 0:
            v = 0
        if v > 15:
            v = 15
        return v
    if doc_kind(dd, n) == J_STR:
        var nm = doc_str(dd, n)
        var plist = personas()
        for i in range(len(plist)):
            if plist[i] == nm:
                return i
    return 0


def _apply_journal_data(
    mut srv: Server, dd: Doc, rr: Int, mode: String, label: String
) -> Tuple[Int, String]:
    """Load entries into memory. Returns (loaded_count, error)."""
    var arr = _journal_entries_node(dd, rr)
    if arr < 0:
        return (0, String("no entries in journal data"))
    var vkind = doc_ostr(dd, rr, "vec_kind")
    if vkind == "":
        vkind = String("hash")
    var ob = List[Int]()
    var os = List[Int]()
    if mode == "merge":
        for k in range(len(srv.findings)):
            var f = srv.findings[k]
            var oi = -1
            for q in range(len(ob)):
                if ob[q] == f.branch:
                    oi = q
                    break
            if oi < 0:
                ob.append(f.branch)
                os.append(f.step)
            elif f.step > os[oi]:
                os[oi] = f.step
    else:
        srv.findings = List[Finding]()
        srv.vecs = List[List[Float64]]()
        srv.aired = List[Int]()
        srv.findings_base = 0
        srv.gold_count = 0
        srv.streak_no_gold = 0
        srv.pca_dirty = True
        srv.pca_pending = 0
        srv.pca_last_ms = 0
        var sc = _journal_concept(dd, rr)
        if sc == "":
            sc = "Historical Expedition"
        srv.cfg.concept = sc
    var loaded = 0
    var lgold = 0
    var clamped = 0
    for i in range(doc_len(dd, arr)):
        var e = doc_at(dd, arr, i)
        var ek = doc_kind(dd, e)
        if ek != J_OBJ and ek != J_STR:
            continue
        var branch = 0
        var step = i + 1
        var nov: Float64
        var coh: Float64
        var x = 50.0
        var y = 50.0
        var z = 50.0
        var gold = False
        var text: String
        var b0: Int
        var b1 = 0
        var b2 = 0
        var cd: Float64
        var pers = 0
        var temp: Float64
        var loc: String
        var vv = List[Float64]()
        if ek == J_STR:
            text = doc_str(dd, e)
            loc = "Step " + String(i + 1)
            nov = 0.75
            coh = 8.0
            b0 = 1
            cd = 1.0
            temp = 0.9
            var garr = doc_find(dd, rr, "gold_vault")
            if garr >= 0 and doc_kind(dd, garr) == J_ARR:
                for gi in range(doc_len(dd, garr)):
                    if doc_str(dd, doc_at(dd, garr, gi)) == text:
                        gold = True
                        break
        else:
            branch = _doc_int_finite(dd, e, "branch")
            if not _finite(doc_onum(dd, e, "branch")):
                clamped += 1
            var st0 = _doc_int_finite(dd, e, "step")
            if not _finite(doc_onum(dd, e, "step")):
                clamped += 1
            if st0 > 0:
                step = st0
            nov = _jnum2(dd, e, "novelty", "novelty_score")
            if not _finite(nov):
                nov = 0.0
                clamped += 1
            coh = _jnum2(dd, e, "coherence", "coherence_score")
            if not _finite(coh):
                coh = 0.0
                clamped += 1
            x = _jcoord(dd, e, "x")
            if not _finite(x):
                x = 50.0
                clamped += 1
            y = _jcoord(dd, e, "y")
            if not _finite(y):
                y = 50.0
                clamped += 1
            z = _jcoord(dd, e, "z")
            if not _finite(z):
                z = 50.0
                clamped += 1
            gold = _jbool2(dd, e, "gold", "is_gold")
            text = _jstr2(dd, e, "text", "response")
            b0 = _doc_int_finite(dd, e, "b0")
            if not _finite(doc_onum(dd, e, "b0")):
                clamped += 1
            b1 = _doc_int_finite(dd, e, "b1")
            if not _finite(doc_onum(dd, e, "b1")):
                clamped += 1
            b2 = _doc_int_finite(dd, e, "b2")
            if not _finite(doc_onum(dd, e, "b2")):
                clamped += 1
            cd = _jnum2(dd, e, "cd", "cohomological_dim")
            if not _finite(cd):
                cd = 0.0
                clamped += 1
            pers = _jpersona(dd, e)
            temp = _jnum2(dd, e, "temp", "temperature")
            if not _finite(temp):
                temp = 0.0
                clamped += 1
            loc = _jstr2(dd, e, "loc", "location")
            var varr = doc_find(dd, e, "vec")
            if varr >= 0 and doc_kind(dd, varr) == J_ARR:
                var vlen = doc_len(dd, varr)
                if vlen > 4096:
                    vlen = 0
                    clamped += 1
                for j in range(vlen):
                    var vf = doc_num(dd, doc_at(dd, varr, j))
                    if isinf(vf) or isnan(vf):
                        vf = 0.0
                        clamped += 1
                    vv.append(vf)
            if len(vv) == 0 and vkind != "embed" and text != "":
                sim_embed(text, vv)
        if mode == "merge":
            var off = 0
            for q in range(len(ob)):
                if ob[q] == branch:
                    off = os[q]
                    break
            step += off
        srv_finding_push(
            srv,
            Finding(
                branch,
                step,
                nov,
                coh,
                x,
                y,
                z,
                gold,
                text,
                b0,
                b1,
                b2,
                cd,
                pers,
                temp,
                loc,
                label,
                0,
            ),
            1,
        )
        if len(vv) > 0 and len(srv.vecs) > 0:
            srv.vecs[len(srv.vecs) - 1] = vv.copy()
        if gold:
            lgold += 1
        loaded += 1
    if mode == "merge":
        srv.gold_count += lgold
    else:
        srv.gold_count = lgold
    srv.gold_seen = srv.gold_count
    srv.pca_dirty = True
    srv.pca_pending = 0
    srv.pca_last_ms = 0
    srv.saved_run = 0
    if clamped > 0:
        srv_log(
            srv,
            "journal load [" + label + "]: clamped " + String(clamped) + " non-finite values",
        )
    return (loaded, String())


def _basename(p: String) -> String:
    var rest = p
    while True:
        var sl = rest.find("/")
        if sl < 0:
            break
        var tail = String(rest[byte = sl + 1 :])
        rest = tail
    return rest


def srv_load_journal(mut srv: Server, body: String) -> String:
    # A load only touches memory, but invalidate the journals cache
    # anyway: a load usually follows an external look at the archive,
    # and one re-parse per load is cheap insurance against staleness.
    srv.journals_cache_valid = False
    var d: Doc
    try:
        d = parse_json(body)
    except:
        return resp_bytes(400, "application/json", '{"error":"bad json"}')
    var r = doc_root(d)
    var mode = doc_ostr(d, r, "mode")
    if mode == "":
        mode = "replace"
    if mode != "replace" and mode != "merge":
        return resp_bytes(
            400, "application/json", '{"error":"bad mode (want replace|merge)"}'
        )
    var filename = doc_ostr(d, r, "filename")
    var cust = doc_find(d, r, "custom_json")
    var loaded: Int
    var err: String
    if cust >= 0 and doc_kind(d, cust) == J_OBJ:
        var label = String("custom_json")
        if filename != "":
            var bl = _basename(filename)
            if bl != "" and bl != "." and bl != "..":
                label = bl
        var res = _apply_journal_data(srv, d, cust, mode, label)
        loaded = res[0]
        err = res[1]
    elif filename != "":
        var label = _basename(filename)
        if label == "" or label == "." or label == "..":
            return resp_bytes(400, "application/json", '{"error":"bad filename"}')
        var st = file_stat("journals/" + label)
        if st[0] < 0:
            return resp_bytes(
                400,
                "application/json",
                '{"error":"journal not found: ' + j_escape(label) + '"}',
            )
        var raw = file_read_all("journals/" + label)
        var d2: Doc
        try:
            d2 = parse_json(raw)
        except:
            return resp_bytes(400, "application/json", '{"error":"bad journal json"}')
        var res2 = _apply_journal_data(srv, d2, doc_root(d2), mode, label)
        loaded = res2[0]
        err = res2[1]
    else:
        return resp_bytes(
            400, "application/json", '{"error":"filename or custom_json required"}'
        )
    if err != "":
        return resp_bytes(400, "application/json", '{"error":"' + j_escape(err) + '"}')
    srv_broadcast(srv, srv_state_json(srv))
    return resp_json(
        String('{"status":"ok","loaded_count":')
        + String(loaded)
        + ',"mode":"'
        + mode
        + '","total_journal_count":'
        + String(len(srv.findings))
        + "}"
    )


def srv_journal_file(name: String) -> String:
    """Read-only journal fetch by basename. Only journal_*.json names;
    rejects path traversal."""
    if name == "":
        return resp_bytes(400, "application/json", '{"error":"name required"}')
    if name.find("/") >= 0 or name.find("..") >= 0:
        return resp_bytes(400, "application/json", '{"error":"bad name"}')
    if not name.startswith("journal_") or not name.endswith(".json"):
        return resp_bytes(400, "application/json", '{"error":"bad name"}')
    var st = file_stat("journals/" + name)
    if st[0] < 0:
        return resp_bytes(404, "application/json", '{"error":"journal not found"}')
    var raw = file_read_all("journals/" + name)
    var dd: Doc
    try:
        dd = parse_json(raw)
    except:
        return resp_bytes(400, "application/json", '{"error":"bad journal json"}')
    var rr = doc_root(dd)
    var arr = _journal_entries_node(dd, rr)
    if arr < 0:
        return resp_bytes(
            400, "application/json", '{"error":"no entries in journal data"}'
        )
    var out = (
        String('{"starting_concept":"')
        + j_escape(_journal_concept(dd, rr))
        + '","vec_kind":"'
        + j_escape(doc_ostr(dd, rr, "vec_kind"))
        + '","model":"'
        + j_escape(doc_ostr(dd, rr, "model"))
        + '","endpoint":"'
        + j_escape(doc_ostr(dd, rr, "endpoint"))
        + '","embed_model":"'
        + j_escape(doc_ostr(dd, rr, "embed_model"))
        + '","embed_endpoint":"'
        + j_escape(doc_ostr(dd, rr, "embed_endpoint"))
        + '","app_version":"'
        + j_escape(doc_ostr(dd, rr, "app_version"))
        + '","entries":'
        + j_render_at(dd, arr)
        + "}"
    )
    return resp_bytes(200, "application/json", out)


def auth_ok(token: String, path: String, qtoken: String, htoken: String) -> Bool:
    """Pure gate for --auth-token. Empty token = open server (default).

    The dashboard shell (/, /index.html, css/js assets) stays public so
    the token field itself is reachable; every /api/*, /frag/* and
    /events route needs the token via ?token= (EventSource) or the
    X-MM-Token header (htmx/fetch). Pure primitives: unit-testable.
    """
    if token == "":
        return True
    if (
        path == "/"
        or path == "/index.html"
        or path == "/app.css"
        or path == "/app.js"
        or path == "/htmx.min.js"
        or path == "/idiomorph-ext.min.js"
    ):
        return True
    if qtoken != "" and qtoken == token:
        return True
    return htoken != "" and htoken == token


def _mcp_http_body(resp: String) -> String:
    var i = resp.find("\r\n\r\n")
    if i < 0:
        return String()
    return String(resp[byte = i + 4 :])


def _mcp_ctrl_msg(resp: String) -> String:
    """Toast message out of a control response's HX-Trigger header JSON.
    Escape-aware: stops at the first unescaped quote."""
    var k = resp.find('"msg":"')
    if k < 0:
        return String()
    var bs = resp.as_bytes()
    var i = k + 7
    var start = i
    while i < len(bs):
        if Int(bs[i]) == 92:
            i += 2
            continue
        if Int(bs[i]) == 34:
            break
        i += 1
    return String(resp[byte = start:i])


def _mcp_arg(mut out: String, mut first: Bool, d: Doc, a: Int, key: String):
    """Copy one MCP argument into a control JSON body, type-preserving
    (j_render_at quotes strings, passes numbers/bools/objects through)."""
    var n = doc_find(d, a, key)
    if n < 0:
        return
    if not first:
        out += ","
    first = False
    out += '"' + key + '":' + j_render_at(d, n)


def srv_mcp_tool(mut srv: Server, name: String, d: Doc, a: Int) -> String:
    """Execute one MCP tool, returning the tools/call result object JSON.
    Unknown tool -> empty string (caller maps to -32602). Engine errors
    become isError results, never bare 500s, so the JSON-RPC envelope
    always survives."""
    if name == "expedition_status":
        return mcp_tool_text(srv_state_json(srv), False)
    if name == "get_findings":
        var since = 0
        var sn = doc_find(d, a, "since")
        if sn >= 0:
            since = Int(doc_num(d, sn))
        var lim = 500
        var ln = doc_find(d, a, "limit")
        if ln >= 0:
            lim = Int(doc_num(d, ln))
        if lim < 1:
            lim = 1
        if lim > 2000:
            lim = 2000
        var gn = doc_find(d, a, "gold_only")
        var gold_only = gn >= 0 and doc_bool(d, gn)
        srv_refresh_pca(srv)
        return mcp_tool_text(srv_findings_json(srv, since, gold_only, lim), False)
    if name == "search_claims":
        var q = doc_ostr(d, a, "q")
        if q == "":
            return mcp_tool_text("missing required argument: q", True)
        var lim = 20
        var ln = doc_find(d, a, "limit")
        if ln >= 0:
            lim = Int(doc_num(d, ln))
        if lim < 1:
            lim = 1
        if lim > 50:
            lim = 50
        return mcp_tool_text(srv_search_json(srv, q, lim), False)
    if name == "stop_expedition":
        try:
            var r = srv_control(srv, '{"action":"stop"}')
            if not r.startswith("HTTP/1.1 200"):
                return mcp_tool_text(_mcp_http_body(r), True)
        except:
            return mcp_tool_text("stop failed: internal error", True)
        return mcp_tool_text(
            "Run stopped (run " + String(srv.run_id) + ").", False
        )
    if name == "start_expedition":
        var cbody = String('{"action":"start"')
        var first = False
        var keys = List[String]()
        keys.append("concept")
        keys.append("model")
        keys.append("models")
        keys.append("endpoint")
        keys.append("api_key")
        keys.append("embed_model")
        keys.append("embed_endpoint")
        keys.append("seed")
        keys.append("branches")
        keys.append("steps")
        keys.append("gold")
        keys.append("temp")
        keys.append("fanout")
        keys.append("judges")
        keys.append("repulse")
        keys.append("push")
        keys.append("call_budget")
        keys.append("plateau_k")
        keys.append("plateau_eps")
        keys.append("nogold_m")
        keys.append("min_coh")
        keys.append("coh_c")
        keys.append("global_stall")
        for i in range(len(keys)):
            _mcp_arg(cbody, first, d, a, keys[i])
        cbody += "}"
        var r = String()
        try:
            r = srv_control(srv, cbody)
        except:
            return mcp_tool_text("start failed: internal error", True)
        if not r.startswith("HTTP/1.1 200"):
            return mcp_tool_text(_mcp_http_body(r), True)
        var msg = _mcp_ctrl_msg(r)
        if msg == "":
            msg = "Expedition started"
        var live = (
            srv.cfg.endpoint != ""
            and srv.cfg.model != ""
            and srv.cfg.api_key != ""
        )
        var tag = String("sim")
        if live:
            tag = String("live")
        return mcp_tool_text(
            msg + " (run " + String(srv.run_id) + ", " + tag + ").", False
        )
    if name == "list_journals":
        return mcp_tool_text(srv_journals_json(srv), False)
    if name == "get_journal":
        var jfile = doc_ostr(d, a, "filename")
        if jfile == "":
            return mcp_tool_text("missing required argument: filename", True)
        var r = srv_journal_file(jfile)
        if not r.startswith("HTTP/1.1 200"):
            return mcp_tool_text(_mcp_http_body(r), True)
        return mcp_tool_text(_mcp_http_body(r), False)
    if name == "save_journal":
        var r = String()
        try:
            r = srv_control(srv, '{"action":"save"}')
        except:
            return mcp_tool_text("save failed: internal error", True)
        if not r.startswith("HTTP/1.1 200"):
            return mcp_tool_text(_mcp_http_body(r), True)
        var fname = String()
        try:
            var dd = parse_json(_mcp_http_body(r))
            fname = doc_ostr(dd, doc_root(dd), "journal")
        except:
            fname = String()
        if fname == "":
            fname = "journal saved"
        return mcp_tool_text("Saved " + fname, False)
    if name == "load_journal":
        var lbody = String("{")
        var first = True
        _mcp_arg(lbody, first, d, a, "filename")
        _mcp_arg(lbody, first, d, a, "custom_json")
        _mcp_arg(lbody, first, d, a, "mode")
        lbody += "}"
        var r = srv_load_journal(srv, lbody)
        if not r.startswith("HTTP/1.1 200"):
            return mcp_tool_text(_mcp_http_body(r), True)
        return mcp_tool_text(_mcp_http_body(r), False)
    if name == "get_topology":
        var surface = doc_ostr(d, a, "surface")
        var metric = doc_ostr(d, a, "metric")
        if metric == "":
            metric = "cosine"
        if metric != "cosine" and metric != "euclid":
            return mcp_tool_text("metric must be cosine or euclid", True)
        try:
            if surface == "merge":
                return mcp_tool_text(srv_topo_merge_json(srv), False)
            if surface == "bars":
                return mcp_tool_text(srv_topo_bars_json(srv, metric), False)
            if surface == "conf":
                return mcp_tool_text(srv_topo_conf_json(srv, metric), False)
            if surface == "loops":
                var ml = 6
                var mn = doc_find(d, a, "max_loops")
                if mn >= 0:
                    ml = Int(doc_num(d, mn))
                return mcp_tool_text(srv_topo_loops_json(srv, ml), False)
            if surface == "mapper":
                var bins = 8
                var bn = doc_find(d, a, "bins")
                if bn >= 0:
                    bins = Int(doc_num(d, bn))
                var ov = 0.4
                var on = doc_find(d, a, "overlap")
                if on >= 0:
                    ov = doc_num(d, on)
                return mcp_tool_text(srv_topo_mapper_json(srv, bins, ov), False)
            if surface == "time":
                return mcp_tool_text(srv_topo_time_json(srv), False)
        except:
            return mcp_tool_text("topology failed: internal error", True)
        return mcp_tool_text(
            "unknown surface (want merge|bars|conf|loops|mapper|time)", True
        )
    if name == "list_models":
        return mcp_tool_text(srv_models_json(srv), False)
    return String()


def srv_mcp_post(
    mut srv: Server, headers: Dict[String, String], body: String
) -> String:
    """One Streamable-HTTP POST: exactly one JSON-RPC message in, one
    JSON response (or 202 ack) out. Session ids are issued but never
    enforced; unknown notifications are acked and ignored."""
    var sid = String("mm-") + String(srv.mcp_sid if srv.mcp_sid > 0 else 1)
    if srv.mcp_sid == 0:
        srv.mcp_sid = 1
    var shdr = String("Mcp-Session-Id: ") + sid
    if not mcp_origin_ok(headers):
        return resp_bytes_h(
            403,
            "application/json",
            mcp_err("null", -32000, "origin not allowed"),
            shdr,
        )
    var d: Doc
    try:
        d = parse_json(body)
    except:
        return resp_bytes_h(
            400, "application/json", mcp_err("null", -32700, "parse error"), shdr
        )
    var r = doc_root(d)
    if not mcp_is_object(d, r):
        return resp_bytes_h(
            400,
            "application/json",
            mcp_err("null", -32600, "invalid request: not an object"),
            shdr,
        )
    var method = doc_ostr(d, r, "method")
    var has_id = mcp_has_id(d, r)
    var idj = mcp_id_json(d, r)
    if method == "":
        if not has_id:
            return resp_bytes(202, "application/json", "")
        return resp_bytes_h(
            400,
            "application/json",
            mcp_err(idj, -32600, "invalid request: missing method"),
            shdr,
        )
    if (
        method == "notifications/initialized"
        or method == "notifications/cancelled"
        or method == "notifications/roots_list_changed"
    ):
        return resp_bytes(202, "application/json", "")
    if not has_id:
        return resp_bytes(202, "application/json", "")
    if method == "initialize":
        srv.mcp_sid += 1
        var nsid = String("mm-") + String(srv.mcp_sid)
        var pn = String()
        var pnode = doc_find(d, r, "params")
        if pnode >= 0 and doc_kind(d, pnode) == J_OBJ:
            pn = doc_ostr(d, pnode, "protocolVersion")
        var ver = mcp_negotiate(pn)
        var result = (
            String('{"protocolVersion":"')
            + ver
            + '","capabilities":{"tools":{}},"serverInfo":{"name":"metamining","version":"'
            + String(MM_VERSION)
            + '"}}'
        )
        return resp_bytes_h(
            200,
            "application/json",
            mcp_ok(idj, result),
            "Mcp-Session-Id: " + nsid,
        )
    if method == "ping":
        return resp_bytes_h(200, "application/json", mcp_ok(idj, "{}"), shdr)
    if method == "tools/list":
        return resp_bytes_h(
            200, "application/json", mcp_ok(idj, mcp_tools_json()), shdr
        )
    if method == "tools/call":
        var pnode = doc_find(d, r, "params")
        if pnode < 0 or doc_kind(d, pnode) != J_OBJ:
            return resp_bytes_h(
                200,
                "application/json",
                mcp_err(idj, -32602, "invalid params: params must be an object"),
                shdr,
            )
        var tname = doc_ostr(d, pnode, "name")
        if tname == "":
            return resp_bytes_h(
                200,
                "application/json",
                mcp_err(idj, -32602, "invalid params: missing tool name"),
                shdr,
            )
        var anode = doc_find(d, pnode, "arguments")
        var a = pnode
        if anode >= 0:
            if doc_kind(d, anode) != J_OBJ:
                return resp_bytes_h(
                    200,
                    "application/json",
                    mcp_err(
                        idj, -32602, "invalid params: arguments must be an object"
                    ),
                    shdr,
                )
            a = anode
        var res = srv_mcp_tool(srv, tname, d, a)
        if res == "":
            return resp_bytes_h(
                200, "application/json", mcp_err(idj, -32602, "unknown tool"), shdr
            )
        return resp_bytes_h(200, "application/json", mcp_ok(idj, res), shdr)
    return resp_bytes_h(
        200, "application/json", mcp_err(idj, -32601, "method not found"), shdr
    )


def srv_route(
    mut srv: Server,
    ci: Int,
    method: String,
    path: String,
    query: Dict[String, String],
    headers: Dict[String, String],
    body: String,
) raises -> String:
    if not auth_ok(
        srv.auth_token, path, hget(query, "token"), hget(headers, "x-mm-token")
    ):
        return resp_bytes(401, "application/json", '{"error":"auth required"}')
    if method == "GET" and path == "/events":
        # Cadenced refits leave coords dirty between fits; converge them
        # for the prelude (no-op once clean).
        srv_refresh_pca(srv)
        var c = srv.conns[ci].copy()
        c.sse = True
        srv.conns[ci] = c^
        var prelude = sse_headers()
        var start = len(srv.findings) - 50
        if start < 0:
            start = 0
        var i = start
        while i < len(srv.findings):
            var f = srv.findings[i]
            prelude += sse_event(finding_event(srv.run_id, f))
            i += 1
        prelude += sse_event(srv_state_json(srv))
        return prelude
    if method == "POST" and path == "/mcp":
        return srv_mcp_post(srv, headers, body)
    if method == "GET" and path == "/mcp":
        var c = srv.conns[ci].copy()
        c.sse = True
        c.mcp = True
        srv.conns[ci] = c^
        return sse_headers() + ": connected\n\n"
    if method == "DELETE" and path == "/mcp":
        return resp_bytes(204, "application/json", "")
    if method == "GET" and path == "/api/state":
        return resp_json(srv_state_json(srv))
    if method == "GET" and path == "/api/findings":
        srv_refresh_pca(srv)
        var since = 0
        var lim = 500
        var gold_only = False
        var s = hget(query, "since")
        if s != "":
            try:
                since = Int(s)
            except:
                since = 0
        var l = hget(query, "limit")
        if l != "":
            try:
                lim = Int(l)
            except:
                lim = 500
        if hget(query, "gold") == "1":
            gold_only = True
        if lim < 1:
            lim = 1
        if lim > 2000:
            lim = 2000
        return resp_json(srv_findings_json(srv, since, gold_only, lim))
    if method == "GET" and path == "/api/journal":
        srv_refresh_pca(srv)
        return resp_bytes(200, "application/json", srv_journal_json(srv))
    if method == "GET" and path == "/api/journals":
        return resp_json(srv_journals_json(srv))
    if method == "GET" and path == "/api/journal_file":
        return srv_journal_file(hget(query, "name"))
    if method == "GET" and path == "/api/veins":
        return resp_json(srv_veins_json(srv))
    if method == "GET" and path == "/api/related":
        var bs = hget(query, "branch")
        var ss = hget(query, "step")
        if bs == "" or ss == "":
            return resp_bytes(
                400, "application/json", '{"error":"branch and step required"}'
            )
        var bb: Int
        var stp: Int
        try:
            bb = Int(bs)
            stp = Int(ss)
        except:
            return resp_bytes(
                400, "application/json", '{"error":"branch and step must be integers"}'
            )
        var rel = srv_related_json(srv, bb, stp)
        if rel == "":
            return resp_bytes(404, "application/json", '{"error":"not found"}')
        return resp_json(rel)
    if method == "GET" and path == "/api/queue":
        return resp_json(srv_queue_json(srv))
    if method == "GET" and path == "/api/tree":
        return resp_json(srv_tree_json(srv))
    if method == "GET" and path == "/api/topo_merge":
        return resp_json(srv_topo_merge_json(srv))
    if method == "GET" and path == "/api/topo_bars":
        var metric = hget(query, "metric")
        if metric == "":
            metric = "cosine"
        if metric != "cosine" and metric != "euclid":
            return resp_bytes(
                400,
                "application/json",
                '{"error":"metric must be cosine or euclid"}',
            )
        return resp_json(srv_topo_bars_json(srv, metric))
    if method == "GET" and path == "/api/topo_time":
        return resp_json(srv_topo_time_json(srv))
    if method == "GET" and path == "/api/topo_conf":
        var cmetric = hget(query, "metric")
        if cmetric == "":
            cmetric = "cosine"
        if cmetric != "cosine" and cmetric != "euclid":
            return resp_bytes(
                400,
                "application/json",
                '{"error":"metric must be cosine or euclid"}',
            )
        return resp_json(srv_topo_conf_json(srv, cmetric))
    if method == "GET" and path == "/api/topo_loops":
        var ml = 6
        var ms = hget(query, "max")
        if ms != "":
            try:
                ml = Int(ms)
            except:
                ml = 6
        return resp_json(srv_topo_loops_json(srv, ml))
    if method == "GET" and path == "/api/topo_mapper":
        var bins = 8
        var bs = hget(query, "bins")
        if bs != "":
            try:
                bins = Int(bs)
            except:
                bins = 8
        var ov = 0.4
        var os = hget(query, "overlap")
        if os != "":
            try:
                ov = Float64(os)
            except:
                ov = 0.4
        return resp_json(srv_topo_mapper_json(srv, bins, ov))
    if method == "GET" and path == "/api/search":
        var lim = 20
        var ls = hget(query, "limit")
        if ls != "":
            try:
                lim = Int(ls)
            except:
                lim = 20
        return resp_json(srv_search_json(srv, hget(query, "q"), lim))
    if method == "GET" and path == "/api/step":
        srv_refresh_pca(srv)
        var bs = hget(query, "branch")
        var ss = hget(query, "step")
        if bs == "" or ss == "":
            return resp_bytes(
                400, "application/json", '{"error":"branch and step required"}'
            )
        var bb: Int
        var stp: Int
        try:
            bb = Int(bs)
            stp = Int(ss)
        except:
            return resp_bytes(
                400, "application/json", '{"error":"branch and step must be integers"}'
            )
        for k in range(len(srv.findings)):
            var f = srv.findings[k]
            if f.branch == bb and f.step == stp:
                return resp_json(finding_item_json(f))
        return resp_bytes(404, "application/json", '{"error":"not found"}')
    if method == "GET" and path == "/api/models":
        return resp_json(srv_models_json(srv))
    if method == "GET" and path == "/api/log":
        var out = String('{"t":"log","lines":[')
        var start = len(srv.logs) - 100
        if start < 0:
            start = 0
        var first = True
        for i in range(start, len(srv.logs)):
            if not first:
                out += ","
            first = False
            out += '"' + j_escape(srv.logs[i]) + '"'
        out += "]}"
        return resp_json(out)
    if method == "GET" and path == "/frag/threads":
        return resp_bytes(200, "text/html; charset=utf-8", srv_frag_threads(srv))
    if method == "GET" and path == "/frag/gold":
        return resp_bytes(200, "text/html; charset=utf-8", srv_frag_gold(srv))
    if method == "GET" and path == "/frag/stats":
        return resp_bytes(200, "text/html; charset=utf-8", srv_frag_stats(srv))
    if method == "POST" and path == "/api/control":
        return srv_control(srv, body)
    if method == "POST" and path == "/api/load_journal":
        return srv_load_journal(srv, body)
    if method == "GET":
        var name = path
        if name == "/":
            name = "/index.html"
        var wf = read_web_file(srv.webdir, name)
        if wf.found:
            return resp_bytes(200, wf.ctype, wf.body)
        return resp_bytes(404, "text/plain", "not found")
    return resp_bytes(405, "text/plain", "method not allowed")


def srv_models_should_refresh(srv: Server, now: Int) -> Bool:
    """True when /api/models must refetch: never fetched, endpoint or
    key changed since the last fetch, clock broken, or TTL expired."""
    if srv.models_fetched_at < 0:
        return True
    if srv.cfg.endpoint != srv.models_fetched_ep:
        return True
    if srv.cfg.api_key != srv.models_fetched_key:
        return True
    if now < 0:
        return True
    return now - srv.models_fetched_at >= MODELS_TTL_SECS


def _models_preview(ids: List[String]) -> String:
    """First ids for a 400 message, capped so a huge catalog stays readable."""
    var out = String()
    var n = len(ids)
    if n > 12:
        n = 12
    for i in range(n):
        if i > 0:
            out += ", "
        var e = ids[i]
        out += e
    if len(ids) > 12:
        out += ", ..."
    return out


def _preflight_check_models(
    srv: Server, cfg: ExpCfg, brmodels: List[String]
) -> String:
    """Reject ids the endpoint does not list. "" to proceed.

    Only called with a fresh list in srv.models (probe or cache hit); an
    empty list skips validation. Without this a typo'd model starts a
    doomed run that burns a minute and ends backend-error with 0 findings.
    """
    if len(srv.models) == 0:
        return String()
    if not model_known(srv.models, cfg.model):
        return (
            String("unknown model '")
            + cfg.model
            + "' - endpoint lists: "
            + _models_preview(srv.models)
        )
    for i in range(len(brmodels)):
        var m = brmodels[i]
        if m != "" and not model_known(srv.models, m):
            return (
                String("unknown model '")
                + m
                + "' in models - endpoint lists: "
                + _models_preview(srv.models)
            )
    return String()


def srv_preflight_key(
    mut srv: Server, cfg: ExpCfg, brmodels: List[String]
) -> String:
    """Reject a live start fast when the key is dead or the model unknown.

    Returns "" to proceed, else a human message for a 400. A fresh
    models-cache hit for the same endpoint+key skips the probe; transport
    and non-auth errors allow the start (ambiguous offline) and log it.
    """
    if cfg.endpoint == "" or cfg.model == "":
        if cfg.endpoint != "":
            srv_log(srv, "start: endpoint set but model blank - sim backend")
        return String()
    if cfg.api_key == "":
        srv_log(srv, "start: live endpoint but no api key - sim backend")
        return String()
    var now = time_now()
    if (
        cfg.endpoint == srv.models_fetched_ep
        and cfg.api_key == srv.models_fetched_key
        and srv.models_fetched_at >= 0
        and now >= 0
        and now - srv.models_fetched_at < MODELS_TTL_SECS
    ):
        return _preflight_check_models(srv, cfg, brmodels)
    var ids = List[String]()
    var err = meta_models(
        MetaCfg(cfg.endpoint, cfg.api_key, cfg.model, cfg.embed_model), ids
    )
    if err.startswith("unauthorized"):
        return (
            String("api key rejected by ")
            + cfg.endpoint
            + " (401) - check the key"
        )
    if err == "":
        srv.models = ids.copy()
        srv.models_fetched_at = now
        srv.models_fetched_ep = cfg.endpoint
        srv.models_fetched_key = cfg.api_key
        return _preflight_check_models(srv, cfg, brmodels)
    else:
        srv_log(srv, "preflight probe inconclusive (" + err + ") - starting anyway")
    return String()


def srv_models_json(mut srv: Server) -> String:
    var out = String('{"t":"models","sim":')
    if srv.cfg.endpoint == "":
        out += "true"
    else:
        out += "false"
    out += ',"models":['
    var ids = srv.models.copy()
    if srv.cfg.endpoint != "" and srv.cfg.api_key != "":
        if srv_models_should_refresh(srv, time_now()):
            var fresh = List[String]()
            var err = meta_models(
                MetaCfg(
                    srv.cfg.endpoint, srv.cfg.api_key, srv.cfg.model, srv.cfg.embed_model
                ),
                fresh,
            )
            if err == "":
                srv.models = fresh.copy()
                ids = fresh.copy()
                srv.models_fetched_at = time_now()
                srv.models_fetched_ep = srv.cfg.endpoint
                srv.models_fetched_key = srv.cfg.api_key
            else:
                srv_log(srv, "models refresh failed: " + err)
    for i in range(len(ids)):
        if i > 0:
            out += ","
        out += '"' + j_escape(ids[i]) + '"'
    out += "]}"
    return out


def _qcomma(mut out: String, mut first: Bool):
    if not first:
        out += ","
    first = False


def _qstr(mut out: String, mut first: Bool, d: Dict[String, String], k: String):
    # Emit present-but-empty fields as "": clearing back to sim.
    # Missing keys stay absent so the server default inherits.
    # Consumers use doc_find for clear-semantics or _blank_field
    # for inherit; teleport/setmodel/concept all handle "" safely.
    var v = String()
    try:
        v = d[k]
    except:
        return
    _qcomma(out, first)
    out += '"' + k + '":"' + j_escape(v) + '"'


def _qint(mut out: String, mut first: Bool, d: Dict[String, String], k: String):
    var v = hget(d, k)
    if v == "":
        return
    try:
        var n = Int(v)
        _qcomma(out, first)
        out += '"' + k + '":' + String(n)
    except:
        return


def _qfloat(mut out: String, mut first: Bool, d: Dict[String, String], k: String):
    var v = hget(d, k)
    if v == "":
        return
    try:
        var n = Float64(v)
        _qcomma(out, first)
        out += '"' + k + '":' + j_render_num(n)
    except:
        return


def query_to_json(q: String) -> String:
    var d = parse_query(q)
    var out = String("{")
    var first = True
    _qstr(out, first, d, "action")
    _qstr(out, first, d, "target")
    _qint(out, first, d, "idx")
    _qint(out, first, d, "bid")
    _qstr(out, first, d, "concept")
    _qstr(out, first, d, "model")
    _qstr(out, first, d, "models")
    _qstr(out, first, d, "endpoint")
    _qstr(out, first, d, "embed_model")
    _qstr(out, first, d, "embed_endpoint")
    _qstr(out, first, d, "embed_doc_prefix")
    _qstr(out, first, d, "embed_query_prefix")
    _qstr(out, first, d, "api_key")
    _qint(out, first, d, "seed")
    _qint(out, first, d, "branches")
    _qint(out, first, d, "steps")
    _qfloat(out, first, d, "gold")
    _qfloat(out, first, d, "temp")
    _qfloat(out, first, d, "push")
    _qint(out, first, d, "repulse")
    _qint(out, first, d, "fanout")
    _qint(out, first, d, "judges")
    _qint(out, first, d, "auto")
    _qint(out, first, d, "plateau_k")
    _qfloat(out, first, d, "plateau_eps")
    _qint(out, first, d, "nogold_m")
    _qfloat(out, first, d, "min_coh")
    _qint(out, first, d, "coh_c")
    _qint(out, first, d, "global_stall")
    _qint(out, first, d, "call_budget")
    _qint(out, first, d, "enabled")
    out += "}"
    return out


def ctrl_ok(srv: Server, msg: String, gold: Int, extra: String, adv: Bool) -> String:
    """200 control-ok JSON plus an HX-Trigger toast header for htmx forms.

    Non-htmx (fetch) callers ignore the header and keep their own toasts,
    so this never double-toasts. `extra` is raw JSON appended after
    "ok":true (e.g. ',"id":3'). `adv` also fires mm-adv-refresh so the
    queue/veins/tree panels re-pull. Toast text must stay header-safe:
    static strings plus server-formatted ints only, JSON-escaped.
    """
    var body = (
        String('{"t":"control","run":')
        + String(srv.run_id)
        + ',"ok":true'
        + extra
        + "}"
    )
    var trig = (
        String('{"mm-toast":{"msg":"')
        + j_escape(msg)
        + '","gold":'
        + String(gold)
        + "}"
        + (',"mm-adv-refresh":{}}' if adv else "}")
    )
    return resp_json_h(body, trig)


def srv_control(mut srv: Server, body: String) raises -> String:
    var js = body
    var trimmed = String(body.strip())
    if not trimmed.startswith("{"):
        js = query_to_json(body)
    var d: Doc
    try:
        d = parse_json(js)
    except:
        return resp_bytes(400, "application/json", '{"error":"bad json"}')
    var r = doc_root(d)
    var action = doc_ostr(d, r, "action")
    var bid = -1
    if doc_find(d, r, "bid") >= 0:
        bid = Int(doc_onum(d, r, "bid"))
    if action == "stop":
        if srv.running:
            srv_stop_workers(srv, "stopped")
        return ctrl_ok(srv, "Run stopped", 0, "", False)
    if action == "start":
        var cfg = srv.cfg.copy()
        if not _blank_field(d, r, "concept"):
            cfg.concept = doc_ostr(d, r, "concept")
        if doc_find(d, r, "model") >= 0:
            cfg.model = String(doc_ostr(d, r, "model").strip())
        if doc_find(d, r, "endpoint") >= 0:
            cfg.endpoint = String(doc_ostr(d, r, "endpoint").strip())
        if doc_find(d, r, "embed_model") >= 0:
            cfg.embed_model = String(doc_ostr(d, r, "embed_model").strip())
        if doc_find(d, r, "embed_endpoint") >= 0:
            cfg.embed_endpoint = String(doc_ostr(d, r, "embed_endpoint").strip())
        if doc_find(d, r, "embed_doc_prefix") >= 0:
            cfg.embed_doc_prefix = doc_ostr(d, r, "embed_doc_prefix")
        if doc_find(d, r, "embed_query_prefix") >= 0:
            cfg.embed_query_prefix = doc_ostr(d, r, "embed_query_prefix")
        if not _blank_field(d, r, "api_key"):
            cfg.api_key = doc_ostr(d, r, "api_key")
        if not _blank_field(d, r, "seed"):
            var v = Int(doc_onum(d, r, "seed"))
            if v >= 0:
                cfg.seed = v
        if not _blank_field(d, r, "branches"):
            var v = Int(doc_onum(d, r, "branches"))
            if v >= 1 and v <= 16:
                cfg.branches = v
        if not _blank_field(d, r, "steps"):
            var v = Int(doc_onum(d, r, "steps"))
            if v >= 1 and v <= 5000:
                cfg.steps = v
        if not _blank_field(d, r, "gold"):
            var v = doc_onum(d, r, "gold")
            if v >= 0.0 and v <= 1.0:
                cfg.gold = v
        if not _blank_field(d, r, "temp"):
            var v = doc_onum(d, r, "temp")
            if v >= 0.0 and v <= 2.0:
                cfg.temp = v
        if not _blank_field(d, r, "repulse"):
            var v = Int(doc_onum(d, r, "repulse"))
            if v >= 0 and v <= 40:
                cfg.repulse = v
        if not _blank_field(d, r, "fanout"):
            var v = Int(doc_onum(d, r, "fanout"))
            if v >= 1 and v <= 8:
                cfg.fanout = v
        if not _blank_field(d, r, "judges"):
            var v = Int(doc_onum(d, r, "judges"))
            if v >= 1 and v <= 5:
                cfg.judges = v
        if not _blank_field(d, r, "auto"):
            var v = Int(doc_onum(d, r, "auto"))
            if v == 0 or v == 1:
                cfg.auto = v
        if not _blank_field(d, r, "push"):
            var v = doc_onum(d, r, "push")
            if v >= 0.0 and v <= 2.0:
                cfg.push = v
        if not _blank_field(d, r, "plateau_k"):
            var v = Int(doc_onum(d, r, "plateau_k"))
            if v >= 1 and v <= 500:
                cfg.plateau_k = v
        if not _blank_field(d, r, "plateau_eps"):
            var v = doc_onum(d, r, "plateau_eps")
            if v >= 0.0 and v <= 1.0:
                cfg.plateau_eps = v
        if not _blank_field(d, r, "nogold_m"):
            var v = Int(doc_onum(d, r, "nogold_m"))
            if v >= 1 and v <= 5000:
                cfg.nogold_m = v
        if not _blank_field(d, r, "min_coh"):
            var v = doc_onum(d, r, "min_coh")
            if v >= 0.0 and v <= 1.0:
                cfg.min_coh = v
        if not _blank_field(d, r, "coh_c"):
            var v = Int(doc_onum(d, r, "coh_c"))
            if v >= 1 and v <= 500:
                cfg.coh_c = v
        if not _blank_field(d, r, "global_stall"):
            var v = Int(doc_onum(d, r, "global_stall"))
            if v >= 1 and v <= 10000:
                cfg.global_stall = v
        if not _blank_field(d, r, "call_budget"):
            var v = Int(doc_onum(d, r, "call_budget"))
            if v >= 0:
                cfg.call_budget = v
        if cfg.concept == "":
            return resp_bytes(400, "text/plain", "concept required")
        # Only a start that names models replaces the per-branch list,
        # so CLI --models (and earlier starts) survive model-less starts.
        # Parsed before preflight so per-branch ids are validated too.
        var brmodels = srv.branch_models.copy()
        if doc_find(d, r, "models") >= 0:
            brmodels = parse_models_list(doc_ostr(d, r, "models"))
        var pre = srv_preflight_key(srv, cfg, brmodels)
        if pre != "":
            return resp_bytes(400, "text/plain", pre)
        srv.branch_models = brmodels.copy()
        srv_start_run(srv, cfg)
        var live = cfg.endpoint != "" and cfg.model != "" and cfg.api_key != ""
        var stag = (
            String("Expedition started (live)")
            if live
            else String("Expedition started (sim)")
        )
        # Partial live config is the classic "I thought I was live": any
        # live field set without all three silently means sim. Say so in
        # the log (naming the gap) and the toast (static, header-safe).
        var partial = (
            cfg.endpoint != ""
            or cfg.model != ""
            or cfg.api_key != ""
            or len(brmodels) > 0
        )
        if not live and partial:
            var miss = String()
            if cfg.model == "":
                miss += "model "
            if cfg.endpoint == "":
                miss += "endpoint "
            if cfg.api_key == "":
                miss += "key"
            srv_log(
                srv,
                "run "
                + String(srv.run_id)
                + ": live config incomplete (missing "
                + miss.strip()
                + ") - running sim, live fields ignored",
            )
            stag = String("Expedition started (sim; live config incomplete)")
        return ctrl_ok(srv, stag, 0, "", False)
    if action == "pause":
        if srv.running:
            srv.paused = True
            srv_send_order(srv, -1, '{"t":"order","name":"pause"}')
            srv_log(srv, "run " + String(srv.run_id) + " paused")
            srv_broadcast(srv, srv_state_json(srv))
        return ctrl_ok(srv, "Paused", 0, "", False)
    if action == "resume":
        if srv.running:
            srv.paused = False
            srv_send_order(srv, -1, '{"t":"order","name":"resume"}')
            srv_log(srv, "run " + String(srv.run_id) + " resumed")
            srv_broadcast(srv, srv_state_json(srv))
        return ctrl_ok(srv, "Resumed", 0, "", False)
    if action == "warp":
        if srv.running:
            srv_send_order(srv, bid, '{"t":"order","name":"warp"}')
            srv_log(srv, "warp ordered")
        return ctrl_ok(srv, "Warp ordered", 0, "", False)
    if action == "restart":
        srv_restart(srv)
        return ctrl_ok(srv, "Run restarted", 0, "", False)
    if action == "teleport":
        if doc_find(d, r, "target") < 0 or doc_ostr(d, r, "target") == "":
            return resp_bytes(400, "text/plain", "target required")
        if srv.running:
            var line = (
                String('{"t":"order","name":"teleport","target":"')
                + j_escape(doc_ostr(d, r, "target"))
                + '"}'
            )
            srv_send_order(srv, bid, line)
            srv_log(srv, "teleport ordered")
        return ctrl_ok(srv, "Teleported", 0, "", False)
    if action == "persona":
        if doc_find(d, r, "idx") < 0:
            return resp_bytes(400, "text/plain", "idx required")
        var pidx = Int(doc_onum(d, r, "idx"))
        if pidx < 0 or pidx > 15:
            return resp_bytes(400, "text/plain", "bad idx")
        if srv.running:
            srv_send_order(
                srv, bid, '{"t":"order","name":"persona","idx":' + String(pidx) + "}"
            )
            srv_log(srv, "persona switch ordered")
        return ctrl_ok(srv, "Lens switched", 0, "", False)
    if action == "setmodel":
        if bid < 0:
            return resp_bytes(400, "text/plain", "bid required")
        var m = doc_ostr(d, r, "model")
        if m == "":
            m = srv.cfg.model
        if srv.running:
            var line = (
                String('{"t":"order","name":"setmodel","model":"')
                + j_escape(m)
                + '"}'
            )
            srv_send_order(srv, bid, line)
            srv_log(srv, "setmodel ordered")
        for i in range(len(srv.workers)):
            var w = srv.workers[i].copy()
            if w.bid == bid:
                w.model = m
                srv.workers[i] = w^
        # Persist into branch_models so a later restart re-applies the
        # switch (blank slots fall back to the run default).
        while len(srv.branch_models) <= bid:
            srv.branch_models.append(String())
        srv.branch_models[bid] = m
        var smmsg = String("Branch ") + String(bid) + String(" model switched")
        return ctrl_ok(srv, smmsg, 0, "", False)
    if action == "tune":
        var line = String('{"t":"order","name":"tune"')
        var n = 0
        if doc_find(d, r, "temp") >= 0:
            var v = doc_onum(d, r, "temp")
            if v < 0.0 or v > 2.0:
                return resp_bytes(400, "text/plain", "bad temp")
            line += ',"temp":' + j_render_num(v)
            n += 1
            srv.cfg.temp = v
        if doc_find(d, r, "gold") >= 0:
            var v = doc_onum(d, r, "gold")
            if v != -1.0 and (v < 0.0 or v > 1.0):
                return resp_bytes(400, "text/plain", "bad gold")
            # -1 resets the default to auto; running workers get the
            # resolved value for the current backend, never the sentinel.
            var wv = v
            if v == -1.0:
                var rsim = (
                    srv.cfg.endpoint == ""
                    or srv.cfg.model == ""
                    or srv.cfg.api_key == ""
                )
                wv = GOLD_AUTO_SIM if rsim else GOLD_AUTO_LIVE
            line += ',"gold":' + j_render_num(wv)
            n += 1
            srv.cfg.gold = v
        if doc_find(d, r, "push") >= 0:
            var v = doc_onum(d, r, "push")
            if v < 0.0 or v > 2.0:
                return resp_bytes(400, "text/plain", "bad push")
            line += ',"push":' + j_render_num(v)
            n += 1
            srv.cfg.push = v
        if doc_find(d, r, "repulse") >= 0:
            var v = Int(doc_onum(d, r, "repulse"))
            if v < 0 or v > 40:
                return resp_bytes(400, "text/plain", "bad repulse")
            line += ',"repulse":' + String(v)
            n += 1
            srv.cfg.repulse = v
        if doc_find(d, r, "fanout") >= 0:
            var v = Int(doc_onum(d, r, "fanout"))
            if v < 1 or v > 8:
                return resp_bytes(400, "text/plain", "bad fanout")
            line += ',"fanout":' + String(v)
            n += 1
            srv.cfg.fanout = v
        if doc_find(d, r, "judges") >= 0:
            var v = Int(doc_onum(d, r, "judges"))
            if v < 1 or v > 5:
                return resp_bytes(400, "text/plain", "bad judges")
            line += ',"judges":' + String(v)
            n += 1
            srv.cfg.judges = v
        if doc_find(d, r, "call_budget") >= 0:
            var v = Int(doc_onum(d, r, "call_budget"))
            if v < 0:
                return resp_bytes(400, "text/plain", "bad call_budget")
            line += ',"call_budget":' + String(v)
            n += 1
            srv.cfg.call_budget = v
        if n == 0:
            return resp_bytes(400, "text/plain", "nothing to tune")
        line += "}"
        if srv.running:
            srv_send_order(srv, bid, line)
            srv_log(srv, "tune ordered")
        return resp_json(
            String('{"t":"control","run":') + String(srv.run_id) + ',"ok":true}'
        )
    if action == "boost":
        if _blank_field(d, r, "call_budget"):
            return resp_bytes(400, "text/plain", "call_budget required")
        var nb = Int(doc_onum(d, r, "call_budget"))
        if nb < 0:
            return resp_bytes(400, "text/plain", "bad call_budget")
        srv.cfg.call_budget = nb
        if srv.running:
            var tline = (
                String('{"t":"order","name":"tune","call_budget":') + String(nb) + "}"
            )
            srv_send_order(srv, bid, tline)
        # Revive budget-dead branches as continuations (new bid, parented
        # to the dead branch like respawns): same model/lens/temp, seeded
        # at the dead branch's best finding, spent calls carried over so
        # the budget stays a branch-total allowance, not a per-leg one.
        var revived = 0
        var skipped = 0
        for i in range(len(srv.workers)):
            var w = srv.workers[i].copy()
            if w.alive:
                continue
            if w.reason != "budget":
                continue
            if bid >= 0 and w.bid != bid:
                continue
            var spent = w.r_calls + w.e_calls
            if nb > 0 and spent >= nb:
                skipped += 1
                continue
            var seed_text = srv.cfg.concept
            var seed_best = -1.0
            for j in range(len(srv.findings)):
                var f = srv.findings[j]
                if f.branch == w.bid and f.nov > seed_best:
                    seed_best = f.nov
                    seed_text = f.text
            var bcfg = srv.cfg.copy()
            bcfg.model = w.model
            var wtemp = w.temp
            if wtemp <= 0.0:
                wtemp = srv.cfg.temp
            var nid = srv.next_bid
            srv_fork_worker(
                srv,
                nid,
                bcfg,
                seed_text,
                wtemp,
                srv.cfg.seed + 1299709 * (nid + 1),
                w.bid,
                "continue",
                w.step,
            )
            srv.next_bid += 1
            while len(srv.branch_models) <= nid:
                srv.branch_models.append(String())
            srv.branch_models[nid] = w.model
            if spent > 0:
                var aline = (
                    String('{"t":"order","name":"tune","add_r":')
                    + String(w.r_calls)
                    + ',"add_e":'
                    + String(w.e_calls)
                    + "}"
                )
                srv_send_order(srv, nid, aline)
            if w.persona != nid % 16:
                srv_send_order(
                    srv,
                    nid,
                    '{"t":"order","name":"persona","idx":' + String(w.persona) + "}",
                )
            if srv.paused:
                srv_send_order(srv, nid, '{"t":"order","name":"pause"}')
            revived += 1
        var was_running = srv.running
        if revived > 0 and not srv.running:
            srv.running = True
            srv.stop_reason = String("running")
            srv.saved_run = 0
            srv.streak_no_gold = 0
            if srv.run_t0 > 0 and srv.run_t1 > srv.run_t0:
                var now = time_now()
                if now > srv.run_t1:
                    srv.run_t0 += now - srv.run_t1
            srv.run_t1 = 0
            srv_broadcast(srv, srv_state_json(srv))
        if revived > 0:
            srv_log(srv, "boost continued " + String(revived) + " branches")
        var bnum = String("unlimited") if nb == 0 else String("-> ") + String(nb)
        var bmsg = String("Budget ") + bnum
        if revived > 0:
            bmsg += " - continued " + String(revived)
            if revived == 1:
                bmsg += " branch"
            else:
                bmsg += " branches"
            if not was_running:
                bmsg += " (run resumed)"
        elif skipped > 0:
            bmsg += " - " + String(skipped) + " still capped, raise higher"
        else:
            bmsg += " - no budget-dead branches"
        return ctrl_ok(srv, bmsg, 0, "", True)
    if action == "auto":
        var on = False
        if doc_find(d, r, "enabled") >= 0:
            on = Int(doc_onum(d, r, "enabled")) != 0
        srv.cfg.auto = 1 if on else 0
        if srv.running:
            var line = String('{"t":"order","name":"auto","enabled":') + (
                String("1") if on else String("0")
            ) + "}"
            srv_send_order(srv, bid, line)
            srv_log(srv, String("auto on") if on else String("auto off"))
        for i in range(len(srv.workers)):
            var w = srv.workers[i].copy()
            if bid >= 0 and w.bid != bid:
                continue
            w.auto = on
            srv.workers[i] = w^
        var amsg = String("Auto-tune on") if on else String("Auto-tune off")
        return ctrl_ok(srv, amsg, 0, "", False)
    if action == "autopop":
        var on = False
        if doc_find(d, r, "enabled") >= 0:
            on = Int(doc_onum(d, r, "enabled")) != 0
        srv.auto_pop = on
        srv_log(srv, String("autopop on") if on else String("autopop off"))
        var apmsg = (
            String("Auto-population on") if on else String("Auto-population off")
        )
        return ctrl_ok(srv, apmsg, 0, "", False)
    if action == "enqueue":
        var concept = doc_ostr(d, r, "concept")
        if concept == "":
            return resp_bytes(
                400, "application/json", '{"error":"concept required"}'
            )
        var branches = srv.cfg.branches
        if not _blank_field(d, r, "branches"):
            var v = Int(doc_onum(d, r, "branches"))
            if v < 1 or v > 16:
                return resp_bytes(
                    400, "application/json", '{"error":"bad branches (want 1-16)"}'
                )
            branches = v
        var steps = srv.cfg.steps
        if not _blank_field(d, r, "steps"):
            var v = Int(doc_onum(d, r, "steps"))
            if v < 1 or v > 5000:
                return resp_bytes(
                    400, "application/json", '{"error":"bad steps (want 1-5000)"}'
                )
            steps = v
        var seed = srv.cfg.seed
        if not _blank_field(d, r, "seed"):
            var v = Int(doc_onum(d, r, "seed"))
            if v < 0:
                return resp_bytes(
                    400, "application/json", '{"error":"bad seed (want >= 0)"}'
                )
            seed = v
        var gold = srv.cfg.gold
        if not _blank_field(d, r, "gold"):
            var v = doc_onum(d, r, "gold")
            if v < 0.0 or v > 1.0:
                return resp_bytes(
                    400, "application/json", '{"error":"bad gold (want 0-1)"}'
                )
            gold = v
        var temp = srv.cfg.temp
        if not _blank_field(d, r, "temp"):
            var v = doc_onum(d, r, "temp")
            if v < 0.0 or v > 2.0:
                return resp_bytes(
                    400, "application/json", '{"error":"bad temp (want 0-2)"}'
                )
            temp = v
        var repulse = srv.cfg.repulse
        if not _blank_field(d, r, "repulse"):
            var v = Int(doc_onum(d, r, "repulse"))
            if v < 0 or v > 40:
                return resp_bytes(
                    400, "application/json", '{"error":"bad repulse (want 0-40)"}'
                )
            repulse = v
        var fanout = srv.cfg.fanout
        if not _blank_field(d, r, "fanout"):
            var v = Int(doc_onum(d, r, "fanout"))
            if v < 1 or v > 8:
                return resp_bytes(
                    400, "application/json", '{"error":"bad fanout (want 1-8)"}'
                )
            fanout = v
        var judges = srv.cfg.judges
        if not _blank_field(d, r, "judges"):
            var v = Int(doc_onum(d, r, "judges"))
            if v < 1 or v > 5:
                return resp_bytes(
                    400, "application/json", '{"error":"bad judges (want 1-5)"}'
                )
            judges = v
        var auto = srv.cfg.auto
        if not _blank_field(d, r, "auto"):
            var v = Int(doc_onum(d, r, "auto"))
            if v != 0 and v != 1:
                return resp_bytes(
                    400, "application/json", '{"error":"bad auto (want 0|1)"}'
                )
            auto = v
        if len(srv.queue) >= QUEUE_CAP:
            return resp_bytes(
                400, "application/json", '{"error":"queue full (cap 100)"}'
            )
        var qid = srv.queue_next_id
        srv.queue_next_id += 1
        srv.queue.append(
            QueueItem(
                qid,
                concept,
                doc_ostr(d, r, "model"),
                branches,
                steps,
                "queued",
                seed,
                gold,
                temp,
                repulse,
                fanout,
                judges,
                auto,
            )
        )
        srv_log(srv, "enqueued #" + String(qid) + " [" + concept + "]")
        var emsg = String("Enqueued as #") + String(qid)
        return ctrl_ok(srv, emsg, 1, String(',"id":') + String(qid), True)
    if action == "autoque":
        var on = False
        if doc_find(d, r, "enabled") >= 0:
            on = Int(doc_onum(d, r, "enabled")) != 0
        srv.autoque = on
        srv_log(srv, String("autoque on") if on else String("autoque off"))
        var aqmsg = (
            String("Queue auto-start on")
            if on
            else String("Queue auto-start off")
        )
        return ctrl_ok(srv, aqmsg, 0, "", True)
    if action == "clearqueue":
        var keep = List[QueueItem]()
        var cleared = 0
        for i in range(len(srv.queue)):
            var q = srv.queue[i].copy()
            if q.status == "running":
                keep.append(q^)
            else:
                cleared += 1
        srv.queue = keep.copy()
        srv_log(srv, "queue cleared: " + String(cleared))
        var cmsg = String("Queue already empty")
        if cleared == 1:
            cmsg = String("Cleared 1 run")
        elif cleared > 1:
            cmsg = String("Cleared ") + String(cleared) + String(" runs")
        return ctrl_ok(
            srv, cmsg, 0, String(',"cleared":') + String(cleared), True
        )
    if action == "save":
        if len(srv.findings) == 0:
            return resp_bytes(
                400, "application/json", '{"error":"no findings to save"}'
            )
        var name = srv_save_journal(srv)
        if name == "":
            return resp_bytes(500, "application/json", '{"error":"save failed"}')
        srv.saved_run = srv.run_id
        srv_veins_flush(srv)
        srv_log(srv, "journal saved: " + name)
        var jextra = String(',"journal":"') + j_escape(name) + String('"')
        return ctrl_ok(srv, "Journal saved", 1, jextra, True)
    return resp_bytes(400, "text/plain", "unknown action")


def srv_frag_stats(srv: Server) -> String:
    var state = "running" if srv.running else "idle"
    if not srv.running and srv.stop_reason != "" and srv.stop_reason != "idle":
        state = srv.stop_reason
    var t = srv_api_totals(srv)
    return (
        String('<div class="stat" id="st-run"><span class="k">run</span><span class="v">')
        + String(srv.run_id)
        + '</span></div><div class="stat" id="st-state"><span class="k">state</span><span class="v">'
        + html_escape(state)
        + '</span></div><div class="stat" id="st-findings"><span class="k">findings</span><span class="v">'
        + String(srv.findings_base + len(srv.findings))
        + '</span></div><div class="stat" id="st-gold"><span class="k">gold</span><span class="v gold-n">'
        + String(srv.gold_count)
        + '</span></div><div class="stat" id="st-dry"><span class="k">dry streak</span><span class="v">'
        + String(srv.streak_no_gold)
        + '</span></div><div class="stat" id="st-topo"><span class="k">topo b0/b1/b2</span><span class="v">'
        + String(srv.topo_b0)
        + "/"
        + String(srv.topo_b1)
        + "/"
        + String(srv.topo_b2)
        + '</span></div><div class="stat" id="st-hive"><span class="k">hive sp/rs/mm</span><span class="v">'
        + String(srv.spawned)
        + "/"
        + String(srv.respawns)
        + "/"
        + String(srv.mem_rounds)
        + '</span></div><div class="stat" id="st-time"><span class="k">time</span><span class="v">'
        + fmt_mmss(srv_run_secs(srv))
        + '</span></div><div class="stat" id="st-tokens"><span class="k">tokens</span><span class="v">'
        + String(t.tin + t.tout)
        + '</span></div><div class="stat" id="st-cost"><span class="k">cost</span><span class="v">'
        + (String("$") + fmt_money4(t.cost) if t.cost_ok else String("n/a"))
        + "</span></div>"
    )


def srv_frag_threads(srv: Server) -> String:
    if len(srv.workers) == 0:
        return String('<div class="empty">no threads yet — start a run</div>')
    var out = String(
        '<table class="threads"><thead><tr><th>th</th><th>step</th>'
        "<th>best</th><th>temp</th><th>strk</th><th>prs</th><th>nrg</th>"
        "<th>reason</th></tr></thead><tbody>"
    )
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        var bs = j_render_num(w.best)
        if bs.byte_length() > 5:
            var cut = String(bs[byte=0:5])
            bs = cut
        var ts = j_render_num(w.temp)
        if ts.byte_length() > 5:
            var cut2 = String(ts[byte=0:5])
            ts = cut2
        var rs = html_escape(w.reason)
        out += (
            String('<tr id="th-')
            + String(w.bid)
            + String('"><td>')
            + String(w.bid)
            + "</td><td>"
            + String(w.step)
            + "</td><td>"
            + bs
            + "</td><td>"
            + ts
            + "</td><td>"
            + String(w.streak)
            + "</td><td>"
            + String(w.persona)
            + "</td><td>"
            + String(w.energy)
            + '</td><td title="'
            + rs
            + '">'
            + rs
            + "</td></tr>"
        )
    out += "</tbody></table>"
    return out


def srv_frag_gold(srv: Server) -> String:
    var n = 0
    var out = String()
    var i = len(srv.findings) - 1
    while i >= 0 and n < 20:
        var f = srv.findings[i]
        if f.gold:
            out += (
                String('<div class="vein" id="vg-b')
                + String(f.branch)
                + "-s"
                + String(f.step)
                + String('"><div class="vein-h">b')
                + String(f.branch)
                + " s"
                + String(f.step)
                + " · "
                + j_render_num(f.nov)
                + "</div><details><summary>read insight</summary><div>"
                + html_escape(f.text)
                + "</div></details></div>"
            )
            n += 1
        i -= 1
    if n == 0:
        return String('<div class="empty">no gold struck yet</div>')
    return out


def srv_dominant_reason(srv: Server) -> String:
    """Most frequent non-empty worker reason (first-seen wins ties)."""
    var best = String()
    var best_n = 0
    for i in range(len(srv.workers)):
        var r = srv.workers[i].reason
        if r == "":
            continue
        var n = 0
        for j in range(len(srv.workers)):
            if srv.workers[j].reason == r:
                n += 1
        if n > best_n:
            best_n = n
            best = r
    return best


def srv_tick(mut srv: Server):
    var got = poll_one(srv.listen_fd, 60)
    var accepted = 0
    while got == 1 and accepted < ACCEPT_BURST and len(srv.conns) < CONNS_CAP:
        var fd = accept_conn(srv.listen_fd)
        if fd < 0:
            break
        _ = set_timeout(fd, 15)
        srv.conns.append(Conn(fd))
        accepted += 1
        got = poll_one(srv.listen_fd, 0)
    srv_drain_workers(srv)
    srv_reap(srv)
    srv_population(srv)
    if srv.running:
        var any_alive = False
        for i in range(len(srv.workers)):
            if srv.workers[i].alive:
                any_alive = True
                break
        if not any_alive and len(srv.workers) > 0:
            srv.running = False
            if srv.stop_reason == "running":
                var dom = srv_dominant_reason(srv)
                if dom != "":
                    srv.stop_reason = dom
                else:
                    srv.stop_reason = String("complete")
            srv.run_t1 = time_now()
            srv_autosave(srv)
            srv_veins_flush(srv)
            srv_log(srv, "run " + String(srv.run_id) + " complete: " + srv.stop_reason)
            srv_queue_advance(srv)
    for ci in range(len(srv.conns)):
        var c = srv.conns[ci].copy()
        if not c.alive:
            continue
        if c.sse:
            # Reap half-closed subscribers: FIN shows as readable+empty.
            if poll_one(c.fd, 0) == 1:
                var probe = tcp_recv_some(c.fd, 64)
                if probe == "":
                    _ = close_fd(c.fd)
                    c.alive = False
                    srv.conns[ci] = c^
            continue
        if poll_one(c.fd, 0) != 1:
            continue
        var chunk = tcp_recv_some(c.fd, 65536)
        if chunk == "":
            _ = close_fd(c.fd)
            c.alive = False
            srv.conns[ci] = c^
            continue
        c.buf += chunk
        if c.buf.byte_length() > 1048576:
            _ = tcp_send_all(c.fd, resp_bytes(400, "text/plain", "request too large"))
            _ = close_fd(c.fd)
            c.alive = False
            srv.conns[ci] = c^
            continue
        var req = parse_http_request(c.buf)
        if not req.complete:
            srv.conns[ci] = c^
            continue
        var is_sse = req.method == "GET" and (
            req.path == "/events" or req.path == "/mcp"
        )
        var answered: Bool
        try:
            var body = srv_route(
                srv, ci, req.method, req.path, req.query, req.headers, req.body
            )
            if tcp_send_all(c.fd, body) < 0:
                _ = close_fd(c.fd)
                c.alive = False
                srv.conns[ci] = c^
                continue
            answered = True
        except:
            answered = False
        if is_sse and answered:
            var c2 = srv.conns[ci].copy()
            c2.buf = String()
            srv.conns[ci] = c2^
        else:
            if not answered:
                _ = tcp_send_all(c.fd, resp_bytes(500, "text/plain", "route failed"))
            _ = close_fd(c.fd)
            c.alive = False
            srv.conns[ci] = c^
    if len(srv.conns) > 0:
        # Drop dead entries WITHOUT closing: every death site already
        # closed its fd, and a mid-tick fork may have reused the number
        # for a worker pipe (closing it EPIPEs the worker at birth).
        var keep = List[Conn]()
        for i in range(len(srv.conns)):
            if srv.conns[i].alive:
                keep.append(srv.conns[i].copy())
        srv.conns = keep.copy()


def srv_bind(mut srv: Server, host: String, port: Int) raises:
    ignore_sigpipe()
    var fd = bind_listen(host, port)
    if fd < 0:
        raise Error(String("bind failed on ") + host + ":" + String(port))
    srv.listen_fd = fd


def srv_serve(mut srv: Server, budget: Int):
    var ticks = 0
    while budget <= 0 or ticks < budget:
        srv_tick(srv)
        ticks += 1
    if srv.running:
        srv_stop_workers(srv, "shutdown")
    # Bounded shutdown: poll ~5s for exits, then SIGKILL stragglers.
    # Never a blocking wait — exit must not hang on a stuck worker.
    for _ in range(50):
        var pending = False
        for i in range(len(srv.workers)):
            var w = srv.workers[i].copy()
            if w.pid <= 0:
                continue
            var r = wait_child(w.pid, True)
            if r.pid == w.pid:
                w.pid = -1
                srv.workers[i] = w^
            else:
                pending = True
        if not pending:
            break
        msleep(100)
    for i in range(len(srv.workers)):
        var w = srv.workers[i].copy()
        if w.pid > 0:
            var r = wait_child(w.pid, True)
            if r.pid == w.pid:
                w.pid = -1
            else:
                _ = kill_pid(w.pid, 9)
                var r2 = wait_child(w.pid, True)
                if r2.pid == w.pid:
                    w.pid = -1
                srv_log(srv, "worker " + String(w.bid) + " SIGKILLed on shutdown")
            srv.workers[i] = w^
    if srv.listen_fd >= 0:
        _ = close_fd(srv.listen_fd)
    for i in range(len(srv.conns)):
        if srv.conns[i].fd >= 0:
            _ = close_fd(srv.conns[i].fd)
