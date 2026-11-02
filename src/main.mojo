"""MetaMining entry: CLI, server, and end-to-end self-test."""

from std.os.env import getenv
from std.sys import argv

from metamining.endpoint import (
    MetaCfg,
    load_pricing_file,
    meta_models,
    model_rates_over,
    parse_pricing_json,
)
from metamining.explorer import ExpCfg
from metamining.http import (
    http_get,
    http_post_form,
    http_post_json,
    parse_endpoint_url,
)
from metamining.json import (
    doc_at,
    doc_find,
    doc_len,
    doc_obool,
    doc_onum,
    doc_ostr,
    doc_root,
    parse_json,
)
from metamining.libc import (
    accept_conn,
    bind_listen,
    child_exit,
    close_fd,
    file_read_all,
    file_remove,
    file_write_all,
    fork_child,
    kill_pid,
    msleep,
    pipe_fds,
    pipe_read_some,
    pipe_write_all,
    poll_one,
    socket_port,
    tcp_connect,
    tcp_recv_some,
    tcp_send_all,
    wait_child,
)
from metamining.server import (
    MM_VERSION,
    Server,
    auth_ok,
    journal_victims,
    srv_bind,
    srv_preflight_key,
    srv_route,
    srv_serve,
    srv_start_run,
)
from metamining.worker import parse_models_list


struct MainCfg(ImplicitlyCopyable):
    var host: String
    var webdir: String
    var endpoint: String
    var model: String
    var embed_model: String
    var embed_endpoint: String
    var embed_doc_prefix: String
    var embed_query_prefix: String
    var api_key: String
    var concept: String
    var port: Int
    var seed: Int
    var branches: Int
    var steps: Int
    var gold: Float64
    var temp: Float64
    var repulse: Int
    var fanout: Int
    var judges: Int
    var auto: Int
    var push: Float64
    var models: String
    var call_budget: Int
    var auth_token: String
    var self_test: Bool
    var help: Bool
    var version: Bool

    def __init__(out self):
        self.host = String("127.0.0.1")
        self.webdir = String("web")
        self.endpoint = String()
        self.model = String()
        self.embed_model = String()
        self.embed_endpoint = String()
        self.embed_doc_prefix = String()
        self.embed_query_prefix = String()
        self.api_key = String()
        self.concept = String("The relationship between truth and confabulations")
        self.port = 8000
        self.seed = 7
        self.branches = 4
        self.steps = 100
        self.gold = -1.0
        self.temp = 0.9
        self.repulse = 30
        self.fanout = 1
        self.judges = 1
        self.auto = 0
        self.push = 0.90
        self.models = String()
        self.call_budget = 0
        self.auth_token = String()
        self.self_test = False
        self.help = False
        self.version = False


def usage_text() -> String:
    return """MetaMining: pure-Mojo latent space explorer.

Usage: metamining [options]

  --host H        bind host (default 127.0.0.1)
  --port N        bind port (default 8000)
  --web DIR       web assets dir (default web)
  --endpoint URL  model API base, e.g. https://api.meta.ai/v1
                  (empty = deterministic sim backend)
  --model M       model id for /v1/responses
  --embed-model M embeddings model id (blank = hash vectors)
  --embed-endpoint URL embeddings base, e.g. http://127.0.0.1:8080/v1
                  (blank = chat endpoint; see ./embed-setup.sh)
  --embed-doc-prefix S prefix for finding texts (nomic: "search_document: ")
  --embed-query-prefix S prefix for search queries (nomic: "search_query: ")
  --api-key K     Bearer key (or META_API_KEY / MODEL_API_KEY env)
  --concept "..." seed concept for the expedition
  --seed N        run seed (default 7)
  --branches N    worker branches, 1-16 (default 4)
  --steps N       max steps per branch (default 100)
  --gold F        novelty threshold for gold (default auto: 0.5 sim, 0.8 live; -1 = auto)
  --temp F        sampling temperature (default 0.9)
  --repulse N     repulse word cap, 0-40 (default 30, 0 = off)
  --fanout N      candidates per step, 1-8 (default 1)
  --judges N      judge votes at gold, 1-5 (default 1)
  --auto N        bandit auto-tune temp/push, 0|1 (default 0)
  --push F        topo push strength, 0-2 (default 0.9)
  --models S      comma-separated per-branch models (blank = default)
  --call-budget N max API calls per branch, 0 = unlimited (default 0)
  --auth-token T  require token for /api/*, /frag/*, /events (default open)
  --self-test     run the loopback end-to-end suite and exit
  --version       print the version and exit
  --help          this text
"""


def parse_args() raises -> MainCfg:
    var c = MainCfg()
    var args = argv()
    var i = 1
    while i < len(args):
        var a = String(args[i])
        if a == "--self-test":
            c.self_test = True
        elif a == "--version":
            c.version = True
        elif a == "--help" or a == "-h":
            c.help = True
        elif a == "--host":
            i += 1
            if i >= len(args):
                raise Error("missing value for --host")
            c.host = String(args[i])
        elif a == "--port":
            i += 1
            if i >= len(args):
                raise Error("missing value for --port")
            try:
                c.port = Int(String(args[i]))
            except:
                raise Error("bad --port")
        elif a == "--web":
            i += 1
            if i >= len(args):
                raise Error("missing value for --web")
            c.webdir = String(args[i])
        elif a == "--endpoint":
            i += 1
            if i >= len(args):
                raise Error("missing value for --endpoint")
            c.endpoint = String(args[i])
        elif a == "--model":
            i += 1
            if i >= len(args):
                raise Error("missing value for --model")
            c.model = String(args[i])
        elif a == "--embed-model":
            i += 1
            if i >= len(args):
                raise Error("missing value for --embed-model")
            c.embed_model = String(args[i])
        elif a == "--embed-endpoint":
            i += 1
            if i >= len(args):
                raise Error("missing value for --embed-endpoint")
            c.embed_endpoint = String(args[i])
        elif a == "--embed-doc-prefix":
            i += 1
            if i >= len(args):
                raise Error("missing value for --embed-doc-prefix")
            c.embed_doc_prefix = String(args[i])
        elif a == "--embed-query-prefix":
            i += 1
            if i >= len(args):
                raise Error("missing value for --embed-query-prefix")
            c.embed_query_prefix = String(args[i])
        elif a == "--api-key":
            i += 1
            if i >= len(args):
                raise Error("missing value for --api-key")
            c.api_key = String(args[i])
        elif a == "--concept":
            i += 1
            if i >= len(args):
                raise Error("missing value for --concept")
            c.concept = String(args[i])
        elif a == "--seed":
            i += 1
            if i >= len(args):
                raise Error("missing value for --seed")
            try:
                c.seed = Int(String(args[i]))
            except:
                raise Error("bad --seed")
        elif a == "--branches":
            i += 1
            if i >= len(args):
                raise Error("missing value for --branches")
            try:
                c.branches = Int(String(args[i]))
            except:
                raise Error("bad --branches")
        elif a == "--steps":
            i += 1
            if i >= len(args):
                raise Error("missing value for --steps")
            try:
                c.steps = Int(String(args[i]))
            except:
                raise Error("bad --steps")
        elif a == "--gold":
            i += 1
            if i >= len(args):
                raise Error("missing value for --gold")
            try:
                c.gold = Float64(String(args[i]))
            except:
                raise Error("bad --gold")
        elif a == "--temp":
            i += 1
            if i >= len(args):
                raise Error("missing value for --temp")
            try:
                c.temp = Float64(String(args[i]))
            except:
                raise Error("bad --temp")
        elif a == "--repulse":
            i += 1
            if i >= len(args):
                raise Error("missing value for --repulse")
            try:
                c.repulse = Int(String(args[i]))
            except:
                raise Error("bad --repulse")
        elif a == "--fanout":
            i += 1
            if i >= len(args):
                raise Error("missing value for --fanout")
            try:
                c.fanout = Int(String(args[i]))
            except:
                raise Error("bad --fanout")
        elif a == "--judges":
            i += 1
            if i >= len(args):
                raise Error("missing value for --judges")
            try:
                c.judges = Int(String(args[i]))
            except:
                raise Error("bad --judges")
        elif a == "--auto":
            i += 1
            if i >= len(args):
                raise Error("missing value for --auto")
            try:
                c.auto = Int(String(args[i]))
            except:
                raise Error("bad --auto")
        elif a == "--push":
            i += 1
            if i >= len(args):
                raise Error("missing value for --push")
            try:
                c.push = Float64(String(args[i]))
            except:
                raise Error("bad --push")
        elif a == "--models":
            i += 1
            if i >= len(args):
                raise Error("missing value for --models")
            c.models = String(args[i])
        elif a == "--call-budget":
            i += 1
            if i >= len(args):
                raise Error("missing value for --call-budget")
            try:
                c.call_budget = Int(String(args[i]))
            except:
                raise Error("bad --call-budget")
        elif a == "--auth-token":
            i += 1
            if i >= len(args):
                raise Error("missing value for --auth-token")
            c.auth_token = String(args[i])
        else:
            raise Error("unknown arg: " + a)
        i += 1
    if c.api_key == "":
        c.api_key = getenv("META_API_KEY", "")
    if c.api_key == "":
        c.api_key = getenv("MODEL_API_KEY", "")
    if c.port <= 0 or c.port > 65535:
        raise Error("bad --port range")
    if c.branches < 1 or c.branches > 16:
        raise Error("bad --branches range 1-16")
    if c.steps < 1 or c.steps > 5000:
        raise Error("bad --steps range")
    if c.gold != -1.0 and (c.gold < 0.0 or c.gold > 1.0):
        raise Error("bad --gold range 0-1 (-1 = auto)")
    if c.temp < 0.0 or c.temp > 2.0:
        raise Error("bad --temp range 0-2")
    if c.seed < 0:
        raise Error("bad --seed range")
    if c.repulse < 0 or c.repulse > 40:
        raise Error("bad --repulse range 0-40")
    if c.fanout < 1 or c.fanout > 8:
        raise Error("bad --fanout range 1-8")
    if c.judges < 1 or c.judges > 5:
        raise Error("bad --judges range 1-5")
    if c.auto != 0 and c.auto != 1:
        raise Error("bad --auto range 0|1")
    if c.push < 0.0 or c.push > 2.0:
        raise Error("bad --push range 0-2")
    if c.call_budget < 0:
        raise Error("bad --call-budget range >= 0")
    return c


def e2e_check(ok: Bool, name: String, mut fails: Int):
    if ok:
        print("e2e ok: " + name)
    else:
        fails += 1
        print("e2e FAIL: " + name)


def self_test() raises -> Int:
    var fails = 0
    var pair = pipe_fds()
    if not pair.ok:
        print("e2e FAIL: pipe")
        return 1
    var pid = fork_child()
    if pid < 0:
        print("e2e FAIL: fork")
        return 1
    if pid == 0:
        _ = close_fd(pair.read_fd)
        var cfg = ExpCfg("truth and confabulation", "sim", "", "", "", 7, 2, 6, 0.9, 0.9)
        var srv = Server(cfg, "web")
        try:
            srv_bind(srv, "127.0.0.1", 0)
        except:
            _ = pipe_write_all(pair.write_fd, "0\n")
            _ = close_fd(pair.write_fd)
            child_exit(2)
        var port = socket_port(srv.listen_fd)
        _ = pipe_write_all(pair.write_fd, String(port) + "\n")
        _ = close_fd(pair.write_fd)
        srv_start_run(srv, cfg)
        srv_serve(srv, 4800)
        child_exit(0)
    _ = close_fd(pair.write_fd)
    var port_s = String()
    var port: Int
    for _ in range(100):
        if poll_one(pair.read_fd, 100) == 1:
            port_s += pipe_read_some(pair.read_fd, 64)
            if port_s.find("\n") >= 0:
                break
    _ = close_fd(pair.read_fd)
    var nl = port_s.find("\n")
    if nl > 0:
        var bare = String(port_s[byte=0:nl])
        port_s = bare
    try:
        port = Int(String(port_s.strip()))
    except:
        port = 0
    e2e_check(port > 0, "server boot", fails)
    if port <= 0:
        _ = kill_pid(pid, 15)
        _ = wait_child(pid, False)
        return fails
    var url = parse_endpoint_url("http://127.0.0.1:" + String(port))
    var home = http_get(url, "/", "")
    e2e_check(
        home.ok and home.status == 200 and home.body.find("MetaMining") >= 0,
        "GET /",
        fails,
    )
    var css = http_get(url, "/app.css", "")
    e2e_check(css.ok and css.status == 200, "GET /app.css", fails)
    var js = http_get(url, "/app.js", "")
    e2e_check(js.ok and js.status == 200, "GET /app.js", fails)
    var hx = http_get(url, "/htmx.min.js", "")
    var imx = http_get(url, "/idiomorph-ext.min.js", "")
    e2e_check(
        imx.ok
        and imx.status == 200
        and imx.body.find('defineExtension("morph"') >= 0,
        "idiomorph ext served",
        fails,
    )
    e2e_check(hx.ok and hx.status == 200 and hx.body.find("htmx") >= 0, "GET /htmx", fails)
    var nf = http_get(url, "/nope", "")
    e2e_check(nf.ok and nf.status == 404, "GET 404", fails)
    var seen = 0
    var running_seen = False
    for _ in range(60):
        var st = http_get(url, "/api/state", "")
        if st.ok and st.status == 200:
            try:
                var d = parse_json(st.body)
                var r = doc_root(d)
                seen = Int(doc_onum(d, r, "findings"))
                if doc_obool(d, r, "running"):
                    running_seen = True
            except:
                var _e = 0
        if seen >= 4:
            break
        msleep(300)
    e2e_check(running_seen, "run active", fails)
    e2e_check(seen >= 4, "findings flow", fails)
    var fl = http_get(url, "/api/findings?since=0&limit=5", "")
    var shape_ok = False
    if fl.ok and fl.status == 200:
        try:
            var d = parse_json(fl.body)
            var items = doc_find(d, doc_root(d), "items")
            if doc_len(d, items) > 0:
                var it0 = doc_at(d, items, 0)
                var nov = doc_onum(d, it0, "novelty")
                var txt = doc_ostr(d, it0, "text")
                shape_ok = nov >= 0.0 and nov <= 1.0 and txt != ""
        except:
            var _e = 0
    e2e_check(shape_ok, "finding shape", fails)
    var vs = http_get(url, "/api/state", "")
    var vs_ok = False
    if vs.ok and vs.status == 200:
        try:
            var vd = parse_json(vs.body)
            vs_ok = doc_ostr(vd, doc_root(vd), "version") == String(MM_VERSION)
        except:
            var _e = 0
    e2e_check(vs_ok, "state carries version", fails)
    var mo1 = http_get(url, "/api/models", "")
    var mo2 = http_get(url, "/api/models", "")
    e2e_check(
        mo1.ok
        and mo1.status == 200
        and mo1.body.find('"sim":true') >= 0
        and mo2.ok
        and mo2.body == mo1.body,
        "models cached",
        fails,
    )
    var sse_ok = False
    var sfd = tcp_connect("127.0.0.1", port)
    if sfd >= 0:
        if tcp_send_all(sfd, "GET /events HTTP/1.1\r\nHost: x\r\n\r\n") > 0:
            var acc = String()
            for _ in range(12):
                if poll_one(sfd, 500) == 1:
                    acc += tcp_recv_some(sfd, 65536)
                if acc.find("text/event-stream") >= 0 and acc.find("data:") >= 0:
                    break
            sse_ok = acc.find("text/event-stream") >= 0 and acc.find(
                '"t":"finding"'
            ) >= 0
        _ = close_fd(sfd)
    e2e_check(sse_ok, "sse stream", fails)
    var th = http_get(url, "/frag/threads", "")
    e2e_check(
        th.ok
        and th.body.find("<table") >= 0
        and th.body.find('id="th-') >= 0,
        "frag threads morph ids",
        fails,
    )
    var gd = http_get(url, "/frag/gold", "")
    e2e_check(
        gd.ok
        and (
            gd.body.find('id="vg-b') >= 0
            or gd.body.find("no gold struck yet") >= 0
        ),
        "frag gold morph ids",
        fails,
    )
    var frs = http_get(url, "/frag/stats", "")
    e2e_check(
        frs.ok
        and frs.body.find("topo") >= 0
        and frs.body.find('id="st-topo"') >= 0,
        "frag stats morph ids",
        fails,
    )
    var trig_ok = False
    var tfd = tcp_connect("127.0.0.1", port)
    if tfd >= 0:
        var tbody = String("action=pause&bid=-1")
        var treq = (
            String(
                "POST /api/control HTTP/1.1\r\nHost: x\r\n"
                "Content-Type: application/x-www-form-urlencoded\r\n"
                "Content-Length: "
            )
            + String(tbody.byte_length())
            + String("\r\n\r\n")
            + tbody
        )
        if tcp_send_all(tfd, treq) > 0:
            var tacc = String()
            for _ in range(12):
                if poll_one(tfd, 500) == 1:
                    tacc += tcp_recv_some(tfd, 65536)
                if tacc.find("HX-Trigger:") >= 0 and tacc.find(
                    '"ok":true'
                ) >= 0:
                    break
            trig_ok = tacc.find("HX-Trigger:") >= 0 and tacc.find(
                "mm-toast"
            ) >= 0
        _ = close_fd(tfd)
    e2e_check(trig_ok, "control hx-trigger toast", fails)
    var jr = http_get(url, "/api/journal", "")
    e2e_check(
        jr.ok and jr.status == 200 and jr.body.find('"pareto"') >= 0,
        "journal export",
        fails,
    )
    var jr_valid = False
    if jr.ok and jr.status == 200:
        try:
            var jd = parse_json(jr.body)
            var jroot = doc_root(jd)
            jr_valid = doc_ostr(jd, jroot, "t") == "journal" and doc_onum(
                jd, jroot, "total"
            ) >= 0.0
        except:
            var _e = 0
    e2e_check(jr_valid, "journal export parses", fails)
    var tm = http_get(url, "/api/topo_merge", "")
    var tm_ok = False
    if tm.ok and tm.status == 200:
        try:
            var td = parse_json(tm.body)
            var tmr = doc_root(td)
            var tn = Int(doc_onum(td, tmr, "n"))
            tm_ok = tn >= 0 and doc_len(td, doc_find(td, tmr, "basin")) == tn
        except:
            var _e = 0
    e2e_check(tm_ok, "topo merge shape", fails)
    var tb = http_get(url, "/api/topo_bars", "")
    var tb_ok = False
    if tb.ok and tb.status == 200:
        try:
            var bd = parse_json(tb.body)
            var br = doc_root(bd)
            var ndim = doc_len(bd, doc_find(bd, br, "dim"))
            var nbirth = doc_len(bd, doc_find(bd, br, "birth"))
            var ndeath = doc_len(bd, doc_find(bd, br, "death"))
            var nsc = doc_len(bd, doc_find(bd, br, "scales"))
            var nb0 = doc_len(bd, doc_find(bd, br, "b0"))
            tb_ok = ndim == nbirth and nbirth == ndeath and nsc == nb0
        except:
            var _e = 0
    e2e_check(tb_ok, "topo bars shape", fails)
    var tl = http_get(url, "/api/topo_loops?max=2", "")
    var tl_ok = False
    if tl.ok and tl.status == 200:
        try:
            var ld = parse_json(tl.body)
            var lr = doc_root(ld)
            var ln = Int(doc_onum(ld, lr, "n"))
            tl_ok = ln >= 0 and doc_len(ld, doc_find(ld, lr, "bi")) == ln
        except:
            var _e = 0
    e2e_check(tl_ok, "topo loops shape", fails)
    var tg = http_get(url, "/api/topo_mapper?bins=4&overlap=0.5", "")
    var tg_ok = False
    if tg.ok and tg.status == 200:
        try:
            var gmd = parse_json(tg.body)
            var gr = doc_root(gmd)
            var nx = doc_len(gmd, doc_find(gmd, gr, "x"))
            var nsz = doc_len(gmd, doc_find(gmd, gr, "size"))
            var nla = doc_len(gmd, doc_find(gmd, gr, "la"))
            var nlb = doc_len(gmd, doc_find(gmd, gr, "lb"))
            tg_ok = nx == nsz and nla == nlb
        except:
            var _e = 0
    e2e_check(tg_ok, "topo mapper shape", fails)
    var tt = http_get(url, "/api/topo_time", "")
    var tt_ok = False
    if tt.ok and tt.status == 200:
        try:
            var td2 = parse_json(tt.body)
            var troot = doc_root(td2)
            tt_ok = doc_len(td2, doc_find(td2, troot, "frac")) == 10 and doc_len(
                td2, doc_find(td2, troot, "b1")
            ) == 10
        except:
            var _e = 0
    e2e_check(tt_ok, "topo time shape", fails)
    var tc = http_get(url, "/api/topo_conf", "")
    var tc_ok = False
    if tc.ok and tc.status == 200:
        try:
            var cd = parse_json(tc.body)
            var cr = doc_root(cd)
            tc_ok = doc_len(cd, doc_find(cd, cr, "support")) == doc_len(
                cd, doc_find(cd, cr, "dim")
            ) and doc_len(
                cd, doc_find(cd, cr, "scales")
            ) == doc_len(cd, doc_find(cd, cr, "b0"))
        except:
            var _e = 0
    e2e_check(tc_ok, "topo conf shape", fails)
    var bm = http_get(url, "/api/topo_bars?metric=bogus", "")
    e2e_check(bm.ok and bm.status == 400, "topo metric 400", fails)
    e2e_check(
        home.body.find("Live orders") >= 0 and home.body.find("topo-b1") >= 0,
        "dashboard orders+topo",
        fails,
    )
    e2e_check(
        home.body.find("mode-btn") >= 0
        and home.body.find('id="scrub"') >= 0
        and home.body.find("order-bid") >= 0
        and home.body.find("autopop") >= 0
        and home.body.find("/api/journal") >= 0
        and home.body.find("api-tps") >= 0,
        "dashboard 10x markers",
        fails,
    )
    var stop = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(stop.ok and stop.status == 200, "control stop", fails)
    msleep(500)
    var st2 = http_get(url, "/api/state", "")
    var stopped_ok = False
    if st2.ok:
        try:
            var d = parse_json(st2.body)
            stopped_ok = not doc_obool(d, doc_root(d), "running")
        except:
            var _e = 0
    e2e_check(stopped_ok, "run stopped", fails)
    var start = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"restart probe","branches":1,"steps":30}',
        "",
    )
    e2e_check(start.ok and start.status == 200, "control start", fails)
    msleep(1500)
    var st3 = http_get(url, "/api/state", "")
    var restart_ok = False
    if st3.ok:
        try:
            var d = parse_json(st3.body)
            var r = doc_root(d)
            restart_ok = doc_obool(d, r, "running") and doc_onum(d, r, "run") == 2.0
        except:
            var _e = 0
    e2e_check(restart_ok, "run restarted", fails)
    var pause = http_post_json(url, "/api/control", '{"action":"pause"}', "")
    var pause_ok = False
    if pause.ok and pause.status == 200:
        var stp = http_get(url, "/api/state", "")
        if stp.ok:
            try:
                var d = parse_json(stp.body)
                pause_ok = doc_obool(d, doc_root(d), "paused")
            except:
                var _e = 0
    e2e_check(pause_ok, "orders pause", fails)
    var tune = http_post_json(
        url, "/api/control", '{"action":"tune","temp":1.1,"gold":0.85,"push":1.0}', ""
    )
    e2e_check(tune.ok and tune.status == 200, "orders tune", fails)
    var warp = http_post_json(url, "/api/control", '{"action":"warp"}', "")
    e2e_check(warp.ok and warp.status == 200, "orders warp", fails)
    var tele = http_post_json(
        url, "/api/control", '{"action":"teleport","target":"e2e island"}', ""
    )
    e2e_check(tele.ok and tele.status == 200, "orders teleport", fails)
    var per = http_post_json(url, "/api/control", '{"action":"persona","idx":7}', "")
    e2e_check(per.ok and per.status == 200, "orders persona", fails)
    var bad = http_post_json(url, "/api/control", '{"action":"persona","idx":99}', "")
    e2e_check(bad.ok and bad.status == 400, "orders reject bad idx", fails)
    var badbody = http_post_json(url, "/api/control", "{bad json", "")
    var badtrail = http_post_json(
        url, "/api/control", '{"action":"stop"} trailing', ""
    )
    var badplain = http_post_json(url, "/api/control", "hello", "")
    e2e_check(
        badbody.ok
        and badbody.status == 400
        and badtrail.ok
        and badtrail.status == 400
        and badplain.ok
        and badplain.status == 400,
        "control rejects bad body",
        fails,
    )
    var resume = http_post_json(url, "/api/control", '{"action":"resume"}', "")
    var resume_ok = False
    if resume.ok and resume.status == 200:
        var stt = http_get(url, "/api/state", "")
        if stt.ok:
            try:
                var d = parse_json(stt.body)
                resume_ok = not doc_obool(d, doc_root(d), "paused")
            except:
                var _e = 0
    e2e_check(resume_ok, "orders resume", fails)
    msleep(1500)
    var fl2 = http_get(url, "/api/findings?since=0&limit=50", "")
    var coords_ok = False
    if fl2.ok and fl2.status == 200:
        try:
            var d = parse_json(fl2.body)
            var items = doc_find(d, doc_root(d), "items")
            coords_ok = doc_len(d, items) > 0
            for i in range(doc_len(d, items)):
                var it = doc_at(d, items, i)
                var x = doc_onum(d, it, "x")
                var y = doc_onum(d, it, "y")
                var z = doc_onum(d, it, "z")
                if x < 0.0 or x > 100.0 or y < 0.0 or y > 100.0 or z < 0.0 or z > 100.0:
                    coords_ok = False
        except:
            var _e = 0
    e2e_check(coords_ok, "pca coords", fails)
    var st5 = http_get(url, "/api/state", "")
    var topo_ok = False
    var tele_ok = False
    var api_ok = False
    if st5.ok:
        try:
            var d = parse_json(st5.body)
            var r = doc_root(d)
            var topo = doc_find(d, r, "topo")
            topo_ok = topo >= 0 and doc_find(d, topo, "b1") >= 0
            var api = doc_find(d, r, "api")
            api_ok = api >= 0 and doc_find(d, api, "tok_out") >= 0
            var workers = doc_find(d, r, "workers")
            if doc_len(d, workers) > 0:
                var w0 = doc_at(d, workers, 0)
                tele_ok = doc_find(d, w0, "entropy") >= 0 and doc_find(d, w0, "tok_in") >= 0
        except:
            var _e = 0
    e2e_check(topo_ok, "topo readout", fails)
    e2e_check(tele_ok, "worker telemetry", fails)
    e2e_check(api_ok, "api stats", fails)
    var serr = http_get(url, "/api/state", "")
    var serr_ok = False
    if serr.ok and serr.status == 200:
        try:
            var d = parse_json(serr.body)
            var r = doc_root(d)
            var workers = doc_find(d, r, "workers")
            serr_ok = doc_find(d, r, "veins_error") >= 0 and doc_ostr(
                d, r, "veins_error"
            ) == ""
            if doc_len(d, workers) > 0:
                var w0 = doc_at(d, workers, 0)
                serr_ok = (
                    serr_ok
                    and doc_find(d, w0, "sick") >= 0
                    and not doc_obool(d, w0, "sick")
                )
            else:
                serr_ok = False
        except:
            var _e = 0
    e2e_check(serr_ok, "state error fields", fails)
    var form = http_post_form(
        url,
        "/api/control",
        "action=start&concept=form+probe&branches=1&steps=2&call_budget=11",
    )
    var form_ok = False
    if form.ok and form.status == 200:
        msleep(800)
        var st4 = http_get(url, "/api/state", "")
        if st4.ok:
            try:
                var d = parse_json(st4.body)
                var r = doc_root(d)
                var cf = doc_find(d, r, "cfg")
                form_ok = (
                    doc_onum(d, r, "run") == 3.0
                    and doc_ostr(d, cf, "concept") == "form probe"
                    and doc_onum(d, cf, "call_budget") == 11.0
                )
            except:
                var _e = 0
    e2e_check(form_ok, "form-encoded start", fails)
    var blank = http_post_form(
        url, "/api/control", "action=start&concept=&branches=1&steps=1&seed=&temp="
    )
    var blank_ok = False
    if blank.ok and blank.status == 200:
        var stb = http_get(url, "/api/state", "")
        if stb.ok:
            try:
                var d = parse_json(stb.body)
                var r = doc_root(d)
                var c = doc_find(d, r, "cfg")
                # temp 1.1: the earlier "orders tune" persists into the
                # server config, so blank keeps that, not the 0.9 default.
                blank_ok = (
                    doc_onum(d, r, "run") == 4.0
                    and doc_ostr(d, c, "concept") == "form probe"
                    and doc_onum(d, c, "seed") == 7.0
                    and doc_onum(d, c, "temp") == 1.1
                )
            except:
                var _e = 0
    e2e_check(blank_ok, "blank fields keep server values", fails)
    # Max vein id, not count: the library caps at 1000 (oldest dropped),
    # so a saturated library grows ids but never the count.
    var veins0 = 0
    var vpre = http_get(url, "/api/veins", "")
    if vpre.ok and vpre.status == 200:
        try:
            var d = parse_json(vpre.body)
            var apre = doc_find(d, doc_root(d), "veins")
            for i in range(doc_len(d, apre)):
                var vid = Int(doc_onum(d, doc_at(d, apre, i), "id"))
                if vid > veins0:
                    veins0 = vid
        except:
            var _e = 0
    var pop = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"hive probe","branches":2,"steps":60,"gold":0.0}',
        "",
    )
    var spawned_ok = False
    var mem_ok = False
    if pop.ok and pop.status == 200:
        for _ in range(40):
            msleep(500)
            var stp2 = http_get(url, "/api/state", "")
            if stp2.ok:
                try:
                    var d = parse_json(stp2.body)
                    var r = doc_root(d)
                    if Int(doc_onum(d, r, "spawned")) >= 1:
                        spawned_ok = True
                    if Int(doc_onum(d, r, "mem_rounds")) >= 1:
                        mem_ok = True
                except:
                    var _e = 0
            if spawned_ok and mem_ok:
                break
    e2e_check(spawned_ok, "hive spawn-at-gold", fails)
    e2e_check(mem_ok, "hive memory rounds", fails)
    var veins1 = veins0
    for _ in range(20):
        msleep(500)
        var vg = http_get(url, "/api/veins", "")
        if vg.ok and vg.status == 200:
            try:
                var d = parse_json(vg.body)
                var arr = doc_find(d, doc_root(d), "veins")
                for i in range(doc_len(d, arr)):
                    var vid = Int(doc_onum(d, doc_at(d, arr, i), "id"))
                    if vid > veins1:
                        veins1 = vid
            except:
                var _e = 0
        if veins1 > veins0:
            break
    e2e_check(veins1 > veins0, "veins auto-append on gold", fails)
    var vshape_ok = False
    var vfull = http_get(url, "/api/veins", "")
    if vfull.ok and vfull.status == 200 and vfull.body.find('"vec"') < 0:
        try:
            var d = parse_json(vfull.body)
            var arr = doc_find(d, doc_root(d), "veins")
            if doc_len(d, arr) > 0:
                var v0 = doc_at(d, arr, doc_len(d, arr) - 1)
                vshape_ok = (
                    doc_find(d, v0, "id") >= 0
                    and doc_ostr(d, v0, "text") != ""
                    and doc_find(d, v0, "novelty") >= 0
                    and doc_find(d, v0, "coherence") >= 0
                    and doc_find(d, v0, "branch") >= 0
                    and doc_find(d, v0, "step") >= 0
                    and doc_find(d, v0, "run") >= 0
                    and doc_find(d, v0, "src") >= 0
                    and doc_find(d, v0, "created") >= 0
                    and doc_find(d, v0, "vec") < 0
                )
        except:
            var _e = 0
    e2e_check(vshape_ok, "veins shape (no vec)", fails)
    var rel_ok = False
    var rel = http_get(url, "/api/related?branch=0&step=1", "")
    if rel.ok and rel.status == 200 and rel.body.find('"vec"') < 0:
        try:
            var d = parse_json(rel.body)
            var items = doc_find(d, doc_root(d), "items")
            rel_ok = doc_len(d, items) <= 5
            if doc_len(d, items) > 0:
                var it0 = doc_at(d, items, 0)
                rel_ok = (
                    rel_ok
                    and doc_find(d, it0, "id") >= 0
                    and doc_ostr(d, it0, "text") != ""
                    and doc_find(d, it0, "novelty") >= 0
                    and doc_find(d, it0, "coherence") >= 0
                    and doc_find(d, it0, "score") >= 0
                    and doc_find(d, it0, "src") >= 0
                )
        except:
            var _e = 0
    e2e_check(rel_ok, "related shape", fails)
    var rel404 = http_get(url, "/api/related?branch=0&step=999999", "")
    e2e_check(rel404.ok and rel404.status == 404, "related missing", fails)
    var tree_ok = False
    var tr = http_get(url, "/api/tree", "")
    if tr.ok and tr.status == 200:
        try:
            var d = parse_json(tr.body)
            var nodes = doc_find(d, doc_root(d), "nodes")
            var seeds = 0
            var golds = 0
            for i in range(doc_len(d, nodes)):
                var nd = doc_at(d, nodes, i)
                var kind = doc_ostr(d, nd, "kind")
                if kind == "seed" and doc_onum(d, nd, "parent") == -1.0:
                    seeds += 1
                if kind == "gold":
                    golds += 1
            tree_ok = seeds == 2 and golds >= 1
        except:
            var _e = 0
    e2e_check(tree_ok, "tree nodes for spawned workers", fails)
    var apoff = http_post_json(url, "/api/control", '{"action":"autopop","enabled":0}', "")
    var apon = http_post_json(url, "/api/control", '{"action":"autopop","enabled":1}', "")
    e2e_check(
        apoff.ok
        and apoff.status == 200
        and apon.ok
        and apon.status == 200,
        "hive autopop toggle",
        fails,
    )
    var stop2 = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(stop2.ok and stop2.status == 200, "archive stop", fails)
    msleep(500)
    var save = http_post_json(url, "/api/control", '{"action":"save"}', "")
    var journal = String()
    if save.ok and save.status == 200:
        try:
            var d = parse_json(save.body)
            journal = doc_ostr(d, doc_root(d), "journal")
        except:
            var _e = 0
    e2e_check(
        journal.startswith("journal_") and journal.endswith(".json"),
        "archive save",
        fails,
    )
    var jl = http_get(url, "/api/journals", "")
    var jl_ok = False
    var step_count = 0
    if jl.ok and jl.status == 200 and journal != "":
        try:
            var d = parse_json(jl.body)
            var arr = doc_find(d, doc_root(d), "journals")
            for i in range(doc_len(d, arr)):
                var it = doc_at(d, arr, i)
                if doc_ostr(d, it, "filename") == journal:
                    step_count = Int(doc_onum(d, it, "step_count"))
                    jl_ok = (
                        step_count > 0
                        and doc_ostr(d, it, "starting_concept") != ""
                        and doc_find(d, it, "size_kb") >= 0
                        and doc_ostr(d, it, "modified_time") != ""
                        and doc_find(d, it, "mtime_ts") >= 0
                    )
        except:
            var _e = 0
    e2e_check(jl_ok, "archive journals list", fails)
    var jfh = http_get(url, "/api/journal_file?name=" + journal, "")
    var jfh_ok = False
    if jfh.ok and jfh.status == 200 and journal != "":
        try:
            var jhd = parse_json(jfh.body)
            var jhr = doc_root(jhd)
            jfh_ok = (
                doc_ostr(jhd, jhr, "model") != ""
                and doc_ostr(jhd, jhr, "endpoint") != ""
                and doc_ostr(jhd, jhr, "vec_kind") != ""
            )
        except:
            var _e = 0
    e2e_check(jfh_ok, "journal file head meta", fails)
    var va = http_get(url, "/api/veins", "")
    var nveins = 0
    if va.ok and va.status == 200:
        try:
            var vd2 = parse_json(va.body)
            nveins = doc_len(vd2, doc_find(vd2, doc_root(vd2), "veins"))
        except:
            var _e = 0
    var vm_ok = nveins == 0
    if nveins > 0:
        var vraw = file_read_all("veins/veins.json")
        if vraw != "":
            try:
                var vd3 = parse_json(vraw)
                var vr3 = doc_root(vd3)
                var vmn = doc_find(vd3, vr3, "meta")
                var varr3 = doc_find(vd3, vr3, "veins")
                vm_ok = (
                    vmn >= 0
                    and varr3 >= 0
                    and doc_find(vd3, vmn, "models") >= 0
                    and doc_len(vd3, varr3) > 0
                )
            except:
                var _e = 0
    e2e_check(vm_ok, "veins file meta head", fails)
    var jl2 = http_get(url, "/api/journals", "")
    e2e_check(
        jl.ok and jl2.ok and jl2.status == 200 and jl2.body == jl.body,
        "journals cache hit",
        fails,
    )
    var save2 = http_post_json(url, "/api/control", '{"action":"save"}', "")
    var journal2 = String()
    if save2.ok and save2.status == 200:
        try:
            var d = parse_json(save2.body)
            journal2 = doc_ostr(d, doc_root(d), "journal")
        except:
            var _e = 0
    var jl3 = http_get(url, "/api/journals", "")
    var inv_ok = False
    if jl3.ok and jl3.status == 200 and journal2 != "":
        inv_ok = jl3.body.find(journal2) >= 0 and jl3.body != jl.body
    e2e_check(inv_ok, "journals invalidate on save", fails)
    var jf_ok = False
    if journal != "":
        var jf = http_get(url, "/api/journal_file?name=" + journal, "")
        if jf.ok and jf.status == 200:
            try:
                var d = parse_json(jf.body)
                var r = doc_root(d)
                jf_ok = (
                    doc_ostr(d, r, "starting_concept") == "hive probe"
                    and doc_len(d, doc_find(d, r, "entries")) == step_count
                )
            except:
                var _e = 0
    e2e_check(jf_ok, "journal_file roundtrip", fails)
    var jf_trav = http_get(url, "/api/journal_file?name=..%2Fsecret", "")
    var jf_slash = http_get(url, "/api/journal_file?name=a%2Fb", "")
    e2e_check(
        jf_trav.ok
        and jf_trav.status == 400
        and jf_slash.ok
        and jf_slash.status == 400,
        "journal_file traversal reject",
        fails,
    )
    var jf_missing = http_get(url, "/api/journal_file?name=journal_nope.json", "")
    e2e_check(
        jf_missing.ok and jf_missing.status == 404, "journal_file missing", fails
    )
    var jf_other = http_get(url, "/api/journal_file?name=notes.txt", "")
    var jf_suffix = http_get(url, "/api/journal_file?name=journal_nope.txt", "")
    e2e_check(
        jf_other.ok
        and jf_other.status == 400
        and jf_suffix.ok
        and jf_suffix.status == 400,
        "journal_file name restrict",
        fails,
    )
    var stp1 = http_get(url, "/api/step?branch=0&step=1", "")
    var step_ok = False
    if stp1.ok and stp1.status == 200:
        try:
            var d = parse_json(stp1.body)
            var r = doc_root(d)
            step_ok = (
                doc_onum(d, r, "branch") == 0.0
                and doc_onum(d, r, "step") == 1.0
                and doc_find(d, r, "b0") >= 0
                and doc_find(d, r, "b1") >= 0
                and doc_find(d, r, "b2") >= 0
                and doc_find(d, r, "cd") >= 0
                and doc_find(d, r, "persona") >= 0
                and doc_find(d, r, "temp") >= 0
                and doc_find(d, r, "loc") >= 0
                and doc_ostr(d, r, "src") == ""
            )
        except:
            var _e = 0
    e2e_check(step_ok, "archive step fields", fails)
    var stp404 = http_get(url, "/api/step?branch=0&step=999999", "")
    var nf_ok = False
    if stp404.ok:
        try:
            var d = parse_json(stp404.body)
            nf_ok = stp404.status == 404 and doc_ostr(d, doc_root(d), "error") != ""
        except:
            var _e = 0
    e2e_check(nf_ok, "archive step missing", fails)
    var tune_r = http_post_json(
        url, "/api/control", '{"action":"tune","repulse":12}', ""
    )
    var rep_ok = False
    if tune_r.ok and tune_r.status == 200:
        var stt2 = http_get(url, "/api/state", "")
        if stt2.ok:
            try:
                var d = parse_json(stt2.body)
                var c = doc_find(d, doc_root(d), "cfg")
                rep_ok = doc_onum(d, c, "repulse") == 12.0
            except:
                var _e = 0
    e2e_check(rep_ok, "tune repulse echoed", fails)
    var tune_bad = http_post_json(
        url, "/api/control", '{"action":"tune","repulse":99}', ""
    )
    e2e_check(tune_bad.ok and tune_bad.status == 400, "tune repulse reject", fails)
    var tune_fj = http_post_json(
        url, "/api/control", '{"action":"tune","fanout":4,"judges":3}', ""
    )
    var fj_ok = False
    if tune_fj.ok and tune_fj.status == 200:
        var stf = http_get(url, "/api/state", "")
        if stf.ok:
            try:
                var d = parse_json(stf.body)
                var c = doc_find(d, doc_root(d), "cfg")
                fj_ok = doc_onum(d, c, "fanout") == 4.0 and doc_onum(
                    d, c, "judges"
                ) == 3.0
            except:
                var _e = 0
    e2e_check(fj_ok, "tune fanout/judges echoed", fails)
    var tune_fj_bad = http_post_json(
        url, "/api/control", '{"action":"tune","fanout":9}', ""
    )
    e2e_check(
        tune_fj_bad.ok and tune_fj_bad.status == 400, "tune fanout reject", fails
    )
    var tune_j_bad = http_post_json(
        url, "/api/control", '{"action":"tune","judges":6}', ""
    )
    e2e_check(
        tune_j_bad.ok and tune_j_bad.status == 400, "tune judges reject", fails
    )
    var start_fj = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"fanout probe","branches":1,"steps":4,'
        '"fanout":3,"judges":2,"call_budget":7}',
        "",
    )
    var sfj_ok = False
    if start_fj.ok and start_fj.status == 200:
        var sts = http_get(url, "/api/state", "")
        if sts.ok:
            try:
                var d = parse_json(sts.body)
                var c = doc_find(d, doc_root(d), "cfg")
                sfj_ok = (
                    doc_onum(d, c, "fanout") == 3.0
                    and doc_onum(d, c, "judges") == 2.0
                    and doc_onum(d, c, "call_budget") == 7.0
                )
            except:
                var _e = 0
    e2e_check(sfj_ok, "start fanout/judges/budget echoed", fails)
    var stop_fj = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(
        stop_fj.ok and stop_fj.status == 200, "fanout probe stopped", fails
    )
    var cli_help = usage_text()
    var dc = MainCfg()
    e2e_check(
        cli_help.find("--repulse") >= 0
        and cli_help.find("--fanout") >= 0
        and cli_help.find("--judges") >= 0
        and cli_help.find("--auto") >= 0
        and cli_help.find("--push") >= 0
        and cli_help.find("--models") >= 0
        and cli_help.find("--call-budget") >= 0
        and cli_help.find("--auth-token") >= 0
        and dc.repulse == 30
        and dc.fanout == 1
        and dc.judges == 1
        and dc.auto == 0
        and dc.push == 0.90
        and dc.models == ""
        and dc.call_budget == 0
        and dc.auth_token == "",
        "cli knobs help+defaults",
        fails,
    )
    e2e_check(
        auth_ok("", "/api/state", "", "")
        and auth_ok("t", "/", "", "")
        and auth_ok("t", "/app.js", "", "")
        and auth_ok("t", "/api/state", "t", "")
        and auth_ok("t", "/api/control", "", "t")
        and not auth_ok("t", "/api/state", "", "")
        and not auth_ok("t", "/events", "nope", "nope")
        and not auth_ok("t", "/frag/stats", "", ""),
        "auth gate pure",
        fails,
    )
    var acfg = ExpCfg("c", "", "", "", "", 7, 1, 1, 0.9, 0.9)
    var asrv = Server(acfg, "web")
    asrv.auth_token = "s3cret"
    var aq0 = Dict[String, String]()
    var ah0 = Dict[String, String]()
    var r401 = srv_route(asrv, 0, "GET", "/api/state", aq0, ah0, "")
    var aq1 = Dict[String, String]()
    aq1["token"] = "s3cret"
    var r200 = srv_route(asrv, 0, "GET", "/api/state", aq1, ah0, "")
    var rpub = srv_route(asrv, 0, "GET", "/app.js", aq0, ah0, "")
    e2e_check(
        r401.find("401") >= 0
        and r401.find("auth required") >= 0
        and r200.find("200 OK") >= 0
        and rpub.find("200 OK") >= 0,
        "auth gate live",
        fails,
    )
    var pover = parse_pricing_json(
        '[{"model":"muse-spark-1.3","in":9.0,"out":9.5},'
        '{"model":"","in":1.0,"out":1.0},'
        '{"model":"bad-row","in":0.0,"out":1.0},42]'
    )
    var pov_bad = parse_pricing_json("not json")
    var pov_obj = parse_pricing_json('{"model":"x"}')
    e2e_check(
        len(pover) == 1
        and model_rates_over("muse-spark-1.3", pover).inp == 9.0
        and model_rates_over("muse-spark-1.3", pover).out == 9.5
        and model_rates_over("muse-spark-1.2", pover).inp == 1.25
        and len(pov_bad) == 0
        and len(pov_obj) == 0,
        "pricing overrides pure",
        fails,
    )
    var vmt = List[Int]()
    vmt.append(30)
    vmt.append(10)
    vmt.append(20)
    var vic = journal_victims(vmt, 2)
    var vic_none = journal_victims(vmt, 9)
    e2e_check(
        len(vic) == 1 and vic[0] == 1 and len(vic_none) == 0,
        "journal victims oldest-first",
        fails,
    )

    var start_push = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"push probe","branches":1,"steps":30,'
        '"push":1.2,"plateau_k":5,"plateau_eps":0.01,"nogold_m":9,'
        '"min_coh":0.3,"coh_c":3,"global_stall":11,"call_budget":0,'
        '"fanout":1}',
        "",
    )
    var push_ok = False
    var tele_push_ok = False
    if start_push.ok and start_push.status == 200:
        for _ in range(8):
            msleep(500)
            var stp = http_get(url, "/api/state", "")
            if stp.ok:
                try:
                    var d = parse_json(stp.body)
                    var r = doc_root(d)
                    var c = doc_find(d, r, "cfg")
                    if (
                        doc_onum(d, c, "push") == 1.2
                        and doc_onum(d, c, "plateau_k") == 5.0
                        and doc_onum(d, c, "plateau_eps") == 0.01
                        and doc_onum(d, c, "nogold_m") == 9.0
                        and doc_onum(d, c, "min_coh") == 0.3
                        and doc_onum(d, c, "coh_c") == 3.0
                        and doc_onum(d, c, "global_stall") == 11.0
                        and doc_onum(d, c, "call_budget") == 0.0
                        and doc_onum(d, c, "fanout") == 1.0
                    ):
                        push_ok = True
                    var workers = doc_find(d, r, "workers")
                    if doc_len(d, workers) > 0 and doc_onum(
                        d, doc_at(d, workers, 0), "push"
                    ) == 1.2:
                        tele_push_ok = True
                except:
                    var _e = 0
            if push_ok and tele_push_ok:
                break
    e2e_check(push_ok, "start push/stop-knobs echoed", fails)
    e2e_check(tele_push_ok, "worker tele push echoed", fails)
    var tune_tgp = http_post_json(
        url,
        "/api/control",
        '{"action":"tune","temp":1.0,"gold":0.75,"push":0.6}',
        "",
    )
    var tgp_ok = False
    var tele_tgp_ok = False
    if tune_tgp.ok and tune_tgp.status == 200:
        for _ in range(8):
            msleep(500)
            var stt = http_get(url, "/api/state", "")
            if stt.ok:
                try:
                    var d = parse_json(stt.body)
                    var r = doc_root(d)
                    var c = doc_find(d, r, "cfg")
                    if (
                        doc_onum(d, c, "temp") == 1.0
                        and doc_onum(d, c, "gold") == 0.75
                        and doc_onum(d, c, "push") == 0.6
                    ):
                        tgp_ok = True
                    var workers = doc_find(d, r, "workers")
                    if doc_len(d, workers) > 0 and doc_onum(
                        d, doc_at(d, workers, 0), "push"
                    ) == 0.6:
                        tele_tgp_ok = True
                except:
                    var _e = 0
            if tgp_ok and tele_tgp_ok:
                break
    e2e_check(tgp_ok, "tune temp/gold/push persist", fails)
    e2e_check(tele_tgp_ok, "tune push reaches worker", fails)
    var start_bo = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"boost probe","branches":1,"steps":30,'
        '"fanout":1,"judges":1,"call_budget":2,"plateau_k":500,'
        '"nogold_m":5000,"global_stall":10000,"min_coh":0.0}',
        "",
    )
    var bo_dead = False
    var bo_f0 = 0
    if start_bo.ok and start_bo.status == 200:
        for _ in range(20):
            msleep(500)
            var stb = http_get(url, "/api/state", "")
            if stb.ok:
                try:
                    var d = parse_json(stb.body)
                    var r = doc_root(d)
                    var workers = doc_find(d, r, "workers")
                    if doc_len(d, workers) > 0 and doc_ostr(
                        d, doc_at(d, workers, 0), "reason"
                    ) == "budget":
                        bo_dead = True
                        bo_f0 = Int(doc_onum(d, r, "findings"))
                        break
                except:
                    var _e3 = 0
            if bo_dead:
                break
    e2e_check(bo_dead, "boost probe budgeted out", fails)
    var boo = http_post_json(
        url, "/api/control", '{"action":"boost","call_budget":50}', ""
    )
    var bo_cfg = False
    var bo_tree = False
    var bo_grew = False
    if boo.ok and boo.status == 200:
        var trb = http_get(url, "/api/tree", "")
        if trb.ok:
            bo_tree = trb.body.find('"kind":"continue"') >= 0
        for _ in range(10):
            msleep(500)
            var stb2 = http_get(url, "/api/state", "")
            if stb2.ok:
                try:
                    var d2 = parse_json(stb2.body)
                    var r2 = doc_root(d2)
                    var c2 = doc_find(d2, r2, "cfg")
                    if doc_onum(d2, c2, "call_budget") == 50.0:
                        bo_cfg = True
                    if Int(doc_onum(d2, r2, "findings")) > bo_f0:
                        bo_grew = True
                except:
                    var _e4 = 0
            if bo_cfg and bo_grew:
                break
    e2e_check(bo_cfg, "boost budget echoed", fails)
    e2e_check(bo_tree, "boost continuation in tree", fails)
    e2e_check(bo_grew, "boost continuation runs", fails)
    var stop_bo = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(
        stop_bo.ok and stop_bo.status == 200, "boost probe stopped", fails
    )
    var rst_bo = http_post_json(
        url, "/api/control", '{"action":"tune","call_budget":0}', ""
    )
    e2e_check(
        rst_bo.ok and rst_bo.status == 200, "boost budget reset", fails
    )
    var start_fo = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"fanout probe","branches":2,"steps":12,'
        '"fanout":3,"judges":1,"plateau_k":500,"nogold_m":5000,'
        '"global_stall":10000,"min_coh":0.0}',
        "",
    )
    var fo_seen = False
    var fo_max_alive = 0
    if start_fo.ok and start_fo.status == 200:
        for _ in range(30):
            msleep(500)
            var stf = http_get(url, "/api/state", "")
            if stf.ok:
                try:
                    var df = parse_json(stf.body)
                    var rf = doc_root(df)
                    var workers = doc_find(df, rf, "workers")
                    var alive_n = 0
                    for i in range(doc_len(df, workers)):
                        if doc_ostr(df, doc_at(df, workers, i), "reason") == "":
                            alive_n += 1
                    if alive_n > fo_max_alive:
                        fo_max_alive = alive_n
                except:
                    var _e5 = 0
            var trf = http_get(url, "/api/tree", "")
            if trf.ok and trf.body.find('"kind":"fanout"') >= 0:
                fo_seen = True
            if fo_seen and fo_max_alive > 2:
                break
    e2e_check(fo_seen, "fanout spawns branches", fails)
    e2e_check(
        fo_max_alive > 2 and fo_max_alive <= 24, "fanout bounded growth", fails
    )
    var stop_fo = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(
        stop_fo.ok and stop_fo.status == 200, "fanout probe stopped", fails
    )
    # Restore default knobs + fanout 1: later tests were written for
    # best-of-1 selection and natural stops, and cfg inherits forward.
    var rst_fo = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"fanout reset","branches":1,"steps":1,'
        '"fanout":1,"plateau_k":12,"plateau_eps":0.005,"nogold_m":25,'
        '"min_coh":0.25,"coh_c":6,"global_stall":40,"call_budget":0}',
        "",
    )
    e2e_check(
        rst_fo.ok and rst_fo.status == 200, "fanout knobs reset", fails
    )
    var stop_for = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(
        stop_for.ok and stop_for.status == 200, "fanout reset stopped", fails
    )
    var stop_push = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(
        stop_push.ok and stop_push.status == 200, "push probe stopped", fails
    )
    var start_m3 = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"m3 probe","branches":3,"steps":30,'
        '"models":"ma,,mc","auto":1}',
        "",
    )
    var m3_ok = False
    var m3_def = String()
    if start_m3.ok and start_m3.status == 200:
        msleep(1200)
        var stm = http_get(url, "/api/state", "")
        if stm.ok:
            try:
                var d = parse_json(stm.body)
                var r = doc_root(d)
                var c = doc_find(d, r, "cfg")
                m3_def = doc_ostr(d, c, "model")
                var workers = doc_find(d, r, "workers")
                if doc_onum(d, c, "auto") == 1.0 and doc_len(d, workers) >= 3:
                    var w0 = doc_at(d, workers, 0)
                    var w1 = doc_at(d, workers, 1)
                    var w2 = doc_at(d, workers, 2)
                    m3_ok = (
                        doc_ostr(d, w0, "model") == "ma"
                        and doc_ostr(d, w1, "model") == m3_def
                        and doc_ostr(d, w2, "model") == "mc"
                        and doc_obool(d, w0, "auto")
                        and doc_obool(d, w1, "auto")
                        and doc_obool(d, w2, "auto")
                    )
            except:
                var _e = 0
    e2e_check(m3_ok, "m3 start models/auto echoed", fails)
    var sm = http_post_json(
        url, "/api/control", '{"action":"setmodel","bid":1,"model":"mz"}', ""
    )
    var sm_ok = False
    if sm.ok and sm.status == 200:
        msleep(400)
        var sts = http_get(url, "/api/state", "")
        if sts.ok:
            try:
                var d = parse_json(sts.body)
                var workers = doc_find(d, doc_root(d), "workers")
                for i in range(doc_len(d, workers)):
                    var w = doc_at(d, workers, i)
                    if doc_onum(d, w, "branch") == 1.0 and doc_ostr(
                        d, w, "model"
                    ) == "mz":
                        sm_ok = True
            except:
                var _e = 0
    e2e_check(sm_ok, "m3 setmodel switches branch", fails)
    var sm_d = http_post_json(
        url, "/api/control", '{"action":"setmodel","bid":1,"model":""}', ""
    )
    var smd_ok = False
    if sm_d.ok and sm_d.status == 200:
        var sts2 = http_get(url, "/api/state", "")
        if sts2.ok:
            try:
                var d = parse_json(sts2.body)
                var workers = doc_find(d, doc_root(d), "workers")
                for i in range(doc_len(d, workers)):
                    var w = doc_at(d, workers, i)
                    if doc_onum(d, w, "branch") == 1.0 and doc_ostr(
                        d, w, "model"
                    ) == m3_def:
                        smd_ok = True
            except:
                var _e = 0
    e2e_check(smd_ok, "m3 setmodel empty falls back", fails)
    var sm_nobid = http_post_json(
        url, "/api/control", '{"action":"setmodel","model":"mz"}', ""
    )
    e2e_check(
        sm_nobid.ok and sm_nobid.status == 400, "m3 setmodel needs bid", fails
    )
    var ao = http_post_json(url, "/api/control", '{"action":"auto","enabled":0}', "")
    var ao_ok = False
    if ao.ok and ao.status == 200:
        var sta = http_get(url, "/api/state", "")
        if sta.ok:
            try:
                var d = parse_json(sta.body)
                var r = doc_root(d)
                var c = doc_find(d, r, "cfg")
                var workers = doc_find(d, r, "workers")
                ao_ok = doc_onum(d, c, "auto") == 0.0 and doc_len(d, workers) >= 3
                for i in range(doc_len(d, workers)):
                    if doc_obool(d, doc_at(d, workers, i), "auto"):
                        ao_ok = False
            except:
                var _e = 0
    e2e_check(ao_ok, "m3 auto toggle echoed", fails)
    var stop_m3 = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    e2e_check(stop_m3.ok and stop_m3.status == 200, "m3 probe stopped", fails)
    var enj_bad = http_post_json(url, "/api/control", '{"action":"enqueue"}', "")
    var enj_bad2 = http_post_json(
        url, "/api/control", '{"action":"enqueue","concept":"x","branches":99}', ""
    )
    e2e_check(
        enj_bad.ok
        and enj_bad.status == 400
        and enj_bad2.ok
        and enj_bad2.status == 400,
        "queue enqueue rejects bad input",
        fails,
    )
    var enq_a = http_post_json(
        url,
        "/api/control",
        '{"action":"enqueue","concept":"queue probe A","branches":1,"steps":2}',
        "",
    )
    var enq_b = http_post_json(
        url,
        "/api/control",
        '{"action":"enqueue","concept":"queue probe B","branches":1,"steps":2}',
        "",
    )
    var enq_ok = False
    var qid_a = 0
    var qid_b = 0
    if enq_a.ok and enq_a.status == 200 and enq_b.ok and enq_b.status == 200:
        try:
            var da = parse_json(enq_a.body)
            var db = parse_json(enq_b.body)
            qid_a = Int(doc_onum(da, doc_root(da), "id"))
            qid_b = Int(doc_onum(db, doc_root(db), "id"))
            enq_ok = (
                doc_obool(da, doc_root(da), "ok")
                and doc_obool(db, doc_root(db), "ok")
                and qid_a > 0
                and qid_b == qid_a + 1
            )
        except:
            var _e = 0
    e2e_check(enq_ok, "queue enqueue", fails)
    var qlist_ok = False
    var ql = http_get(url, "/api/queue", "")
    if ql.ok and ql.status == 200:
        try:
            var d = parse_json(ql.body)
            var r = doc_root(d)
            var arr = doc_find(d, r, "queue")
            qlist_ok = not doc_obool(d, r, "autoque") and doc_len(d, arr) == 2
            if qlist_ok:
                for i in range(2):
                    var it = doc_at(d, arr, i)
                    if doc_ostr(d, it, "status") != "queued":
                        qlist_ok = False
                    if doc_find(d, it, "id") < 0 or doc_ostr(d, it, "concept") == "":
                        qlist_ok = False
                    if doc_find(d, it, "model") < 0 or doc_find(d, it, "branches") < 0:
                        qlist_ok = False
                    if doc_find(d, it, "steps") < 0:
                        qlist_ok = False
                    if doc_find(d, it, "seed") < 0 or doc_find(d, it, "gold") < 0:
                        qlist_ok = False
                    if doc_find(d, it, "temp") < 0 or doc_find(d, it, "repulse") < 0:
                        qlist_ok = False
                    if doc_find(d, it, "fanout") < 0 or doc_find(d, it, "judges") < 0:
                        qlist_ok = False
                    if doc_find(d, it, "auto") < 0:
                        qlist_ok = False
        except:
            var _e = 0
    e2e_check(qlist_ok, "queue list", fails)
    var aq = http_post_json(
        url, "/api/control", '{"action":"autoque","enabled":1}', ""
    )
    var aq_ok = False
    if aq.ok and aq.status == 200:
        var ql2 = http_get(url, "/api/queue", "")
        if ql2.ok:
            try:
                var d = parse_json(ql2.body)
                aq_ok = doc_obool(d, doc_root(d), "autoque")
            except:
                var _e = 0
    e2e_check(aq_ok, "queue autoque toggle", fails)
    var kick = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"queue kickoff","branches":1,"steps":1}',
        "",
    )
    var adv_a = False
    if kick.ok and kick.status == 200:
        for _ in range(24):
            msleep(500)
            var qlp = http_get(url, "/api/queue", "")
            if qlp.ok:
                try:
                    var d = parse_json(qlp.body)
                    var arr = doc_find(d, doc_root(d), "queue")
                    for i in range(doc_len(d, arr)):
                        var it = doc_at(d, arr, i)
                        if Int(doc_onum(d, it, "id")) == qid_a:
                            if doc_ostr(d, it, "status") != "queued":
                                adv_a = True
                except:
                    var _e = 0
            if adv_a:
                break
    e2e_check(adv_a, "queue auto-advance on natural complete", fails)
    var adv_b = False
    for _ in range(40):
        msleep(500)
        var qlp3 = http_get(url, "/api/queue", "")
        if qlp3.ok:
            try:
                var d = parse_json(qlp3.body)
                var arr = doc_find(d, doc_root(d), "queue")
                var sa = String()
                var sb = String()
                for i in range(doc_len(d, arr)):
                    var it = doc_at(d, arr, i)
                    if Int(doc_onum(d, it, "id")) == qid_a:
                        sa = doc_ostr(d, it, "status")
                    if Int(doc_onum(d, it, "id")) == qid_b:
                        sb = doc_ostr(d, it, "status")
                if sa == "done" and (sb == "running" or sb == "done"):
                    adv_b = True
                    break
            except:
                var _e = 0
    e2e_check(adv_b, "queue auto-advance chain", fails)
    _ = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    msleep(800)
    var drain_ok = False
    var qd = http_get(url, "/api/queue", "")
    var std = http_get(url, "/api/state", "")
    if qd.ok and std.ok:
        try:
            var d = parse_json(qd.body)
            var arr = doc_find(d, doc_root(d), "queue")
            var alldone = doc_len(d, arr) == 2
            for i in range(doc_len(d, arr)):
                if doc_ostr(d, doc_at(d, arr, i), "status") != "done":
                    alldone = False
            var ds = parse_json(std.body)
            drain_ok = alldone and not doc_obool(ds, doc_root(ds), "running")
        except:
            var _e = 0
    e2e_check(drain_ok, "queue drains to idle", fails)
    var clr = http_post_json(url, "/api/control", '{"action":"clearqueue"}', "")
    var clr_ok = False
    if clr.ok and clr.status == 200:
        try:
            var d = parse_json(clr.body)
            clr_ok = Int(doc_onum(d, doc_root(d), "cleared")) == 2
        except:
            var _e = 0
    e2e_check(clr_ok, "queue clear", fails)
    var aqoff = http_post_json(
        url, "/api/control", '{"action":"autoque","enabled":0}', ""
    )
    e2e_check(aqoff.ok and aqoff.status == 200, "queue autoque off", fails)
    var emb_probe = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"emb probe","branches":1,"steps":2}',
        "",
    )
    var emb_ok = False
    var drops_ok = False
    if emb_probe.ok and emb_probe.status == 200:
        for _ in range(20):
            msleep(500)
            var ste = http_get(url, "/api/state", "")
            if ste.ok:
                try:
                    var d = parse_json(ste.body)
                    var r = doc_root(d)
                    var api = doc_find(d, r, "api")
                    if Int(doc_onum(d, api, "ecalls")) >= 1:
                        emb_ok = True
                    if doc_find(d, r, "run_drops") >= 0 and Int(
                        doc_onum(d, r, "run_drops")
                    ) == 0:
                        drops_ok = True
                except:
                    var _e = 0
            if emb_ok and drops_ok:
                break
    e2e_check(emb_ok, "hash embeds counted", fails)
    e2e_check(drops_ok, "run drops field", fails)
    var enq_c = http_post_json(
        url, "/api/control", '{"action":"enqueue","concept":"stop probe C"}', ""
    )
    var cid = 0
    if enq_c.ok and enq_c.status == 200:
        try:
            var d = parse_json(enq_c.body)
            cid = Int(doc_onum(d, doc_root(d), "id"))
        except:
            var _e = 0
    var stoprun = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"stop probe run","branches":1,"steps":30}',
        "",
    )
    if stoprun.ok:
        msleep(1500)
    var manstop = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    var noadv_ok = False
    if manstop.ok and manstop.status == 200 and cid > 0:
        msleep(800)
        var qsc = http_get(url, "/api/queue", "")
        var stsc = http_get(url, "/api/state", "")
        if qsc.ok and stsc.ok:
            try:
                var dq = parse_json(qsc.body)
                var arr = doc_find(dq, doc_root(dq), "queue")
                var cst = String()
                for i in range(doc_len(dq, arr)):
                    var it = doc_at(dq, arr, i)
                    if Int(doc_onum(dq, it, "id")) == cid:
                        cst = doc_ostr(dq, it, "status")
                var ds = parse_json(stsc.body)
                noadv_ok = cst == "queued" and not doc_obool(
                    ds, doc_root(ds), "running"
                )
            except:
                var _e = 0
    e2e_check(noadv_ok, "manual stop idles without advance", fails)
    var clr_c = http_post_json(url, "/api/control", '{"action":"clearqueue"}', "")
    var clr_c_ok = False
    if clr_c.ok and clr_c.status == 200:
        try:
            var d = parse_json(clr_c.body)
            clr_c_ok = Int(doc_onum(d, doc_root(d), "cleared")) == 1
        except:
            var _e = 0
    e2e_check(clr_c_ok, "stop probe queue cleared", fails)
    var qfill_ok = True
    for i in range(100):
        var en = http_post_json(
            url,
            "/api/control",
            '{"action":"enqueue","concept":"cap probe ' + String(i) + '"}',
            "",
        )
        if not (en.ok and en.status == 200):
            qfill_ok = False
    e2e_check(qfill_ok, "queue fill to cap", fails)
    var qover = http_post_json(
        url, "/api/control", '{"action":"enqueue","concept":"cap over"}', ""
    )
    e2e_check(
        qover.ok and qover.status == 400 and qover.body.find("queue full") >= 0,
        "queue cap reject",
        fails,
    )
    _ = http_post_json(url, "/api/control", '{"action":"clearqueue"}', "")
    _ = http_post_json(url, "/api/control", '{"action":"autopop","enabled":0}', "")
    var comp = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"complete probe","branches":1,"steps":1}',
        "",
    )
    var completed = False
    if comp.ok and comp.status == 200:
        for _ in range(30):
            msleep(500)
            var stc = http_get(url, "/api/state", "")
            if stc.ok:
                try:
                    var d = parse_json(stc.body)
                    var r = doc_root(d)
                    if not doc_obool(d, r, "running") and doc_ostr(
                        d, r, "stop_reason"
                    ) == "max-steps":
                        completed = True
                except:
                    var _e = 0
            if completed:
                break
    e2e_check(completed, "tiny run completes", fails)
    var rs = http_post_json(url, "/api/control", '{"action":"restart"}', "")
    # Restart clears findings, so any finding proves a reforked worker
    # emitted again (the steps=1 run may complete between polls, so
    # `running` alone is not a stable signal here).
    var refork_ok = False
    if rs.ok and rs.status == 200:
        for _ in range(20):
            msleep(500)
            var str2 = http_get(url, "/api/state", "")
            if str2.ok:
                try:
                    var d = parse_json(str2.body)
                    var r = doc_root(d)
                    if Int(doc_onum(d, r, "findings")) >= 1:
                        refork_ok = True
                except:
                    var _e = 0
            if refork_ok:
                break
    e2e_check(refork_ok, "restart after complete reforks", fails)
    var tr2 = http_get(url, "/api/tree", "")
    var treefresh_ok = False
    if tr2.ok:
        try:
            var d = parse_json(tr2.body)
            treefresh_ok = doc_len(d, doc_find(d, doc_root(d), "nodes")) == 1
        except:
            var _e = 0
    e2e_check(treefresh_ok, "restart tree fresh", fails)
    var smz = http_post_json(
        url, "/api/control", '{"action":"setmodel","bid":0,"model":"mzkeep"}', ""
    )
    var smkeep_ok = False
    if smz.ok and smz.status == 200:
        var rs2 = http_post_json(url, "/api/control", '{"action":"restart"}', "")
        if rs2.ok and rs2.status == 200:
            msleep(800)
            var stm2 = http_get(url, "/api/state", "")
            if stm2.ok:
                try:
                    var d = parse_json(stm2.body)
                    var workers = doc_find(d, doc_root(d), "workers")
                    for i in range(doc_len(d, workers)):
                        var w = doc_at(d, workers, i)
                        if doc_onum(d, w, "branch") == 0.0 and doc_ostr(
                            d, w, "model"
                        ) == "mzkeep":
                            smkeep_ok = True
                except:
                    var _e = 0
    e2e_check(smkeep_ok, "restart keeps setmodel", fails)
    var budg = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"budget probe","branches":1,"steps":100,'
        '"call_budget":5}',
        "",
    )
    var budg_ok = False
    var budg_cfg_ok = False
    if budg.ok and budg.status == 200:
        for _ in range(30):
            msleep(500)
            var stb = http_get(url, "/api/state", "")
            if stb.ok:
                try:
                    var d = parse_json(stb.body)
                    var r = doc_root(d)
                    var c = doc_find(d, r, "cfg")
                    if doc_onum(d, c, "call_budget") == 5.0:
                        budg_cfg_ok = True
                    if not doc_obool(d, r, "running") and doc_ostr(
                        d, r, "stop_reason"
                    ) == "budget":
                        var workers = doc_find(d, r, "workers")
                        var w0 = doc_at(d, workers, 0)
                        if doc_ostr(d, w0, "reason") == "budget" and Int(
                            doc_onum(d, w0, "step")
                        ) < 100:
                            budg_ok = True
                except:
                    var _e = 0
            if budg_ok and budg_cfg_ok:
                break
    e2e_check(budg_cfg_ok, "budget cfg echoed", fails)
    e2e_check(budg_ok, "budget stops early", fails)
    _ = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    msleep(500)
    _ = http_post_json(url, "/api/control", '{"action":"autoque","enabled":1}', "")
    var enq_d = http_post_json(
        url,
        "/api/control",
        '{"action":"enqueue","concept":"snap probe D","model":"snapmodel",'
        '"branches":2,"steps":2,"seed":4242,"gold":0.55,"temp":1.05,'
        '"repulse":7,"fanout":2,"judges":2,"auto":1}',
        "",
    )
    var did = 0
    if enq_d.ok and enq_d.status == 200:
        try:
            var d = parse_json(enq_d.body)
            did = Int(doc_onum(d, doc_root(d), "id"))
        except:
            var _e = 0
    # Tree bids before the advance: the keep-check below asserts every one
    # of these survives (fanout children may legitimately add more nodes).
    var keep_bids = List[Int]()
    var tr_pre = http_get(url, "/api/tree", "")
    if tr_pre.ok:
        try:
            var dp = parse_json(tr_pre.body)
            var ap = doc_find(dp, doc_root(dp), "nodes")
            for i in range(doc_len(dp, ap)):
                keep_bids.append(Int(doc_onum(dp, doc_at(dp, ap, i), "bid")))
        except:
            var _e9 = 0
    var kick2 = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"snap kickoff","branches":1,"steps":1}',
        "",
    )
    var advd = False
    if kick2.ok and kick2.status == 200 and did > 0:
        for _ in range(30):
            msleep(500)
            var qpd = http_get(url, "/api/queue", "")
            if qpd.ok:
                try:
                    var d = parse_json(qpd.body)
                    var arr = doc_find(d, doc_root(d), "queue")
                    for i in range(doc_len(d, arr)):
                        var it = doc_at(d, arr, i)
                        if Int(doc_onum(d, it, "id")) == did:
                            if doc_ostr(d, it, "status") != "queued":
                                advd = True
                except:
                    var _e = 0
            if advd:
                break
    e2e_check(advd, "queue snapshot advance", fails)
    var snap_ok = False
    var modelall_ok = False
    var treekeep_ok = False
    if advd:
        var sts_d = http_get(url, "/api/state", "")
        var trd = http_get(url, "/api/tree", "")
        if sts_d.ok and trd.ok:
            try:
                var d = parse_json(sts_d.body)
                var r = doc_root(d)
                var c = doc_find(d, r, "cfg")
                snap_ok = (
                    doc_ostr(d, c, "concept") == "snap probe D"
                    and doc_onum(d, c, "seed") == 4242.0
                    and doc_onum(d, c, "gold") == 0.55
                    and doc_onum(d, c, "temp") == 1.05
                    and doc_onum(d, c, "repulse") == 7.0
                    and doc_onum(d, c, "fanout") == 2.0
                    and doc_onum(d, c, "judges") == 2.0
                    and doc_onum(d, c, "auto") == 1.0
                )
                var workers = doc_find(d, r, "workers")
                modelall_ok = doc_len(d, workers) >= 2
                for i in range(doc_len(d, workers)):
                    if doc_ostr(d, doc_at(d, workers, i), "model") != "snapmodel":
                        modelall_ok = False
                var dt = parse_json(trd.body)
                var arr = doc_find(dt, doc_root(dt), "nodes")
                treekeep_ok = len(keep_bids) > 0 and doc_len(dt, arr) > len(
                    keep_bids
                )
                for i in range(len(keep_bids)):
                    var found = False
                    for j in range(doc_len(dt, arr)):
                        if Int(doc_onum(dt, doc_at(dt, arr, j), "bid")) == keep_bids[i]:
                            found = True
                    if not found:
                        treekeep_ok = False
            except:
                var _e = 0
    e2e_check(snap_ok, "queue snapshot applied", fails)
    e2e_check(modelall_ok, "queue model on all branches", fails)
    e2e_check(treekeep_ok, "queue advance preserves tree", fails)
    _ = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    _ = http_post_json(url, "/api/control", '{"action":"autoque","enabled":0}', "")
    _ = http_post_json(url, "/api/control", '{"action":"clearqueue"}', "")
    _ = http_post_json(url, "/api/control", '{"action":"autopop","enabled":1}', "")
    var secd = http_post_json(
        url,
        "/api/load_journal",
        '{"mode":"replace","custom_json":{"starting_concept":"search probe",'
        '"entries":[{"branch":0,"step":1,"novelty":0.8,"coherence":9.0,'
        '"x":10.0,"y":20.0,"z":30.0,"gold":false,'
        '"text":"the zzzquux77 vault mechanism",'
        '"b0":1,"b1":0,"b2":0,"cd":1.0,"persona":0,"temp":0.9,'
        '"loc":"search front"}]}}',
        "",
    )
    var sea_ok = False
    if secd.ok and secd.status == 200:
        var sq = http_get(url, "/api/search?q=zzzquux77+vault+mechanism", "")
        if sq.ok and sq.status == 200:
            try:
                var d = parse_json(sq.body)
                var items = doc_find(d, doc_root(d), "items")
                if doc_len(d, items) > 0:
                    var it0 = doc_at(d, items, 0)
                    sea_ok = (
                        doc_ostr(d, it0, "text").find("zzzquux77") >= 0
                        and doc_find(d, it0, "branch") >= 0
                        and doc_find(d, it0, "step") >= 0
                        and doc_find(d, it0, "novelty") >= 0
                        and doc_find(d, it0, "coherence") >= 0
                        and doc_find(d, it0, "gold") >= 0
                        and doc_find(d, it0, "src") >= 0
                        and doc_find(d, it0, "score") >= 0
                    )
            except:
                var _e = 0
    e2e_check(sea_ok, "search finds seeded text", fails)
    var slim = http_get(url, "/api/search?q=zzzquux77&limit=500", "")
    var slim_ok = False
    if slim.ok and slim.status == 200:
        try:
            var d = parse_json(slim.body)
            slim_ok = doc_len(d, doc_find(d, doc_root(d), "items")) <= 50
        except:
            var _e = 0
    e2e_check(slim_ok, "search limit cap", fails)
    var load = http_post_json(
        url,
        "/api/load_journal",
        '{"filename":"' + journal + '","mode":"replace"}',
        "",
    )
    var load_ok = False
    if load.ok and load.status == 200 and step_count > 0:
        try:
            var d = parse_json(load.body)
            var r = doc_root(d)
            load_ok = (
                doc_ostr(d, r, "status") == "ok"
                and Int(doc_onum(d, r, "loaded_count")) == step_count
                and doc_ostr(d, r, "mode") == "replace"
                and Int(doc_onum(d, r, "total_journal_count")) == step_count
            )
        except:
            var _e = 0
    e2e_check(load_ok, "archive load replace", fails)
    var src_ok = False
    var flm = http_get(url, "/api/findings?since=0&limit=5", "")
    if flm.ok and flm.status == 200 and journal != "":
        try:
            var d = parse_json(flm.body)
            var items = doc_find(d, doc_root(d), "items")
            if doc_len(d, items) > 0:
                src_ok = doc_ostr(d, doc_at(d, items, 0), "src") == journal
        except:
            var _e = 0
    e2e_check(src_ok, "archive loaded src", fails)
    var jtm = http_get(url, "/api/topo_merge", "")
    var jtm_ok = False
    if jtm.ok and jtm.status == 200 and step_count > 0:
        try:
            var jtd = parse_json(jtm.body)
            jtm_ok = Int(doc_onum(jtd, doc_root(jtd), "n")) == step_count
        except:
            var _e = 0
    e2e_check(jtm_ok, "topo survives journal roundtrip", fails)
    var merge = http_post_json(
        url, "/api/load_journal", '{"filename":"' + journal + '","mode":"merge"}', ""
    )
    var merge_ok = False
    if merge.ok and merge.status == 200 and step_count > 0:
        try:
            var d = parse_json(merge.body)
            var r = doc_root(d)
            merge_ok = Int(doc_onum(d, r, "loaded_count")) == step_count and Int(
                doc_onum(d, r, "total_journal_count")
            ) == 2 * step_count
        except:
            var _e = 0
    e2e_check(merge_ok, "archive load merge", fails)
    var badload = http_post_json(
        url,
        "/api/load_journal",
        '{"filename":"journal_nope.json","mode":"replace"}',
        "",
    )
    var badload_ok = False
    if badload.ok and badload.status == 400:
        try:
            var d = parse_json(badload.body)
            badload_ok = doc_ostr(d, doc_root(d), "error") != ""
        except:
            var _e = 0
    e2e_check(badload_ok, "archive load missing file", fails)
    var cust = http_post_json(
        url,
        "/api/load_journal",
        '{"mode":"replace","custom_json":{"starting_concept":"custom probe",'
        '"entries":[{"branch":0,"step":1,"novelty":0.8,"coherence":9.0,'
        '"x":10.0,"y":20.0,"z":30.0,"gold":true,"text":"hello archive",'
        '"b0":1,"b1":2,"b2":0,"cd":1.5,"persona":3,"temp":0.95,'
        '"loc":"front line"}]}}',
        "",
    )
    var cust_ok = False
    if cust.ok and cust.status == 200:
        try:
            var d = parse_json(cust.body)
            var r = doc_root(d)
            cust_ok = Int(doc_onum(d, r, "loaded_count")) == 1 and Int(
                doc_onum(d, r, "total_journal_count")
            ) == 1
        except:
            var _e = 0
    e2e_check(cust_ok, "archive load custom_json", fails)
    var stpc = http_get(url, "/api/step?branch=0&step=1", "")
    var cust_step_ok = False
    if stpc.ok and stpc.status == 200:
        try:
            var d = parse_json(stpc.body)
            var r = doc_root(d)
            cust_step_ok = (
                doc_ostr(d, r, "text") == "hello archive"
                and doc_ostr(d, r, "loc") == "front line"
                and doc_onum(d, r, "b1") == 2.0
                and doc_onum(d, r, "persona") == 3.0
                and doc_ostr(d, r, "src") == "custom_json"
            )
        except:
            var _e = 0
    e2e_check(cust_step_ok, "archive custom fields", fails)
    var probe = String("journals/journal_19990101_000000_f2e2.json")
    _ = file_write_all(probe, "not json {")
    var cj = http_get(url, "/api/journals", "")
    var cj_ok = False
    if cj.ok and cj.status == 200:
        try:
            var d = parse_json(cj.body)
            var arr = doc_find(d, doc_root(d), "journals")
            for i in range(doc_len(d, arr)):
                var it = doc_at(d, arr, i)
                if doc_ostr(d, it, "filename") == "journal_19990101_000000_f2e2.json":
                    cj_ok = (
                        doc_find(d, it, "ok") >= 0
                        and not doc_obool(d, it, "ok")
                        and doc_ostr(d, it, "error") != ""
                    )
        except:
            var _e = 0
    e2e_check(cj_ok, "journals corrupt row", fails)
    var cs = http_get(url, "/api/search?q=zzzquux77&limit=5", "")
    var cs_ok = False
    if cs.ok and cs.status == 200:
        try:
            var d = parse_json(cs.body)
            cs_ok = Int(doc_onum(d, doc_root(d), "skipped")) >= 1
        except:
            var _e = 0
    e2e_check(cs_ok, "search skipped count", fails)
    var stub = bind_listen("127.0.0.1", 0)
    var pre401_ok = False
    if stub >= 0:
        var sport = socket_port(stub)
        var spid = fork_child()
        if spid == 0:
            if poll_one(stub, 15000) == 1:
                var sc = accept_conn(stub)
                var _rq = tcp_recv_some(sc, 4096)
                _ = tcp_send_all(
                    sc,
                    "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                _ = close_fd(sc)
            _ = close_fd(stub)
            child_exit(0)
        var bad = http_post_form(
            url,
            "/api/control",
            "action=start&concept=keyprobe&model=m&endpoint=http%3A%2F%2F127.0.0.1%3A"
            + String(sport)
            + "&api_key=x",
        )
        if bad.ok and bad.status == 400 and bad.body.find("rejected") >= 0:
            pre401_ok = True
        _ = wait_child(spid, False)
        _ = close_fd(stub)
    e2e_check(pre401_ok, "preflight rejects dead key", fails)
    var lv = http_get(url, "/api/state", "")
    e2e_check(lv.ok and lv.body.find('"live":false') >= 0, "state live flag", fails)
    var amb = http_post_form(
        url,
        "/api/control",
        "action=start&concept=ambprobe&model=m&endpoint=http%3A%2F%2F127.0.0.1%3A9&api_key=x&branches=1&steps=1",
    )
    e2e_check(amb.ok and amb.status == 200, "preflight allows ambiguous transport", fails)
    var ustub = bind_listen("127.0.0.1", 0)
    var tok_seen = False
    var cost_seen = False
    var persist = False
    var secs = False
    if ustub >= 0:
        var uport = socket_port(ustub)
        var upid = fork_child()
        if upid == 0:
            var served = 0
            while served < 16:
                if poll_one(ustub, 4000) != 1:
                    break
                var uc = accept_conn(ustub)
                var urq = tcp_recv_some(uc, 8192)
                var ubody = String('{"data":[]}')
                if urq.find("POST") >= 0:
                    ubody = String(
                        '{"output":[{"type":"message","content":[{"type":"output_text",'
                        '"text":"stub vein note"}]}],'
                        '"usage":{"input_tokens":100,"output_tokens":50}}'
                    )
                var uresp = (
                    String(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                    )
                    + String(ubody.byte_length())
                    + "\r\nConnection: close\r\n\r\n"
                    + ubody
                )
                _ = tcp_send_all(uc, uresp)
                _ = close_fd(uc)
                served += 1
            _ = close_fd(ustub)
            child_exit(0)
        var ustart = http_post_json(
            url,
            "/api/control",
            '{"action":"start","concept":"usageprobe","model":"muse-spark-1.3","endpoint":"http://127.0.0.1:'
            + String(uport)
            + '","api_key":"x","branches":1,"steps":1,"call_budget":200,"fanout":1,"judges":1,"auto":0,"models":"muse-spark-1.3"}',
            "",
        )
        var uw = 0
        while uw < 40 and not (tok_seen and cost_seen):
            msleep(500)
            var ust = http_get(url, "/api/state", "")
            if ust.ok:
                if ust.body.find('"tok_in":0,"tok_out":0') < 0 and ust.body.find(
                    '"tok_in":'
                ) >= 0:
                    tok_seen = True
                if ust.body.find('"cost_ok":true') >= 0 and ust.body.find(
                    '"cost":0.0000'
                ) < 0:
                    cost_seen = True
            uw += 1
        _ = http_post_form(url, "/api/control", "action=stop")
        msleep(1500)
        var uend = http_get(url, "/api/state", "")
        persist = (
            uend.ok
            and uend.body.find('"tok_in":0,"tok_out":0') < 0
            and uend.body.find('"cost_ok":true') >= 0
        )
        secs = uend.ok and uend.body.find('"run_secs":') >= 0
        _ = wait_child(upid, False)
        _ = close_fd(ustub)
        _ = ustart
    e2e_check(tok_seen, "usage tokens metered live", fails)
    e2e_check(cost_seen, "run cost computed live", fails)
    e2e_check(persist, "tokens+cost persist after stop", fails)
    e2e_check(secs, "run_secs reported", fails)
    var churn_ok = True
    for rnd in range(3):
        var burst = List[Int]()
        for _ in range(12):
            var bf = tcp_connect("127.0.0.1", port)
            if bf >= 0:
                _ = tcp_send_all(
                    bf,
                    "GET /api/state HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
                )
                burst.append(bf)
        _ = http_post_json(
            url,
            "/api/control",
            '{"action":"start","concept":"burstprobe","model":"","endpoint":"","branches":1,"steps":2,"call_budget":200,"fanout":1,"judges":1,"auto":0}',
            "",
        )
        for i in range(len(burst)):
            _ = tcp_recv_some(burst[i], 65536)
            _ = close_fd(burst[i])
        var bw = 0
        var born = False
        while bw < 20:
            msleep(500)
            var bstt = http_get(url, "/api/state", "")
            if bstt.ok and bstt.body.find('"findings":0') < 0:
                born = True
                break
            bw += 1
        _ = http_post_json(url, "/api/control", '{"action":"stop"}', "")
        if not born:
            churn_ok = False
    e2e_check(churn_ok, "worker survives conn churn x3", fails)
    _ = file_remove(probe)
    # Preflight model validation against a stub /v1/models. Direct calls
    # use an auxiliary Server (own cache); the HTTP legs need the shared
    # server alive, so this block precedes the kill below.
    var mstub = bind_listen("127.0.0.1", 0)
    var mport = socket_port(mstub)
    var mpid = fork_child()
    if mpid == 0:
        for _ in range(2):
            if poll_one(mstub, 15000) != 1:
                break
            var mconn = accept_conn(mstub)
            var mreq = String()
            for _ in range(8):
                mreq += tcp_recv_some(mconn, 4096)
                if mreq.find("\r\n\r\n") >= 0:
                    break
            var mbody = '{"object":"list","data":[{"id":"stub-model"},{"id":"stub-other"}]}'
            var mresp = (
                String(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                )
                + String(mbody.byte_length())
                + "\r\nConnection: close\r\n\r\n"
                + mbody
            )
            _ = tcp_send_all(mconn, mresp)
            _ = close_fd(mconn)
        _ = close_fd(mstub)
        child_exit(0)
    _ = close_fd(mstub)
    var mep = "http://127.0.0.1:" + String(mport)
    var pcfg = ExpCfg("x", "", "", "", "", 7, 1, 1, 0.9, 0.9)
    var psrv = Server(pcfg, "web")
    var nobr = List[String]()
    var badcfg = ExpCfg("x", "nope-model", mep, "k", "", 7, 1, 1, 0.9, 0.9)
    var rej = srv_preflight_key(psrv, badcfg, nobr)
    e2e_check(
        rej.startswith("unknown model 'nope-model'"),
        "preflight rejects unknown model",
        fails,
    )
    e2e_check(
        rej.find("stub-model") >= 0 and rej.find("stub-other") >= 0,
        "preflight names available models",
        fails,
    )
    var okcfg = ExpCfg("x", "stub-model", mep, "k", "", 7, 1, 1, 0.9, 0.9)
    e2e_check(
        srv_preflight_key(psrv, okcfg, nobr) == "",
        "preflight accepts listed model (cache)",
        fails,
    )
    var bms = List[String]()
    bms.append("stub-model")
    bms.append("bogus-branch")
    e2e_check(
        srv_preflight_key(psrv, okcfg, bms).find("'bogus-branch'") >= 0,
        "preflight rejects unknown branch model",
        fails,
    )
    _ = http_post_json(
        url, "/api/control", '{"action":"tune","gold":-1.0}', ""
    )
    var gauto = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"goldauto","branches":1,"steps":1}',
        "",
    )
    var simauto_ok = False
    if gauto.ok and gauto.status == 200:
        var gst = http_get(url, "/api/state", "")
        if gst.ok:
            try:
                var d = parse_json(gst.body)
                simauto_ok = (
                    doc_onum(d, doc_find(d, doc_root(d), "cfg"), "gold")
                    == 0.5
                )
            except:
                var _e = 0
    e2e_check(simauto_ok, "sim blank gold resolves 0.5", fails)
    var hneg = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"neg probe","model":"nope-model","endpoint":"'
        + mep
        + '","api_key":"k","branches":1,"steps":1}',
        "",
    )
    e2e_check(
        hneg.ok
        and hneg.status == 400
        and hneg.body.find("unknown model") >= 0,
        "start 400 on unknown model",
        fails,
    )
    _ = http_post_json(
        url, "/api/control", '{"action":"tune","gold":-1.0}', ""
    )
    var hpos = http_post_json(
        url,
        "/api/control",
        '{"action":"start","concept":"pos probe","model":" stub-model ","models":" stub-other ","endpoint":"'
        + mep
        + '","api_key":"k","branches":1,"steps":1}',
        "",
    )
    var trim_ok = False
    var liveauto_ok = False
    if hpos.ok and hpos.status == 200:
        var pst = http_get(url, "/api/state", "")
        if pst.ok:
            try:
                var d = parse_json(pst.body)
                var r = doc_root(d)
                var cfgn = doc_find(d, r, "cfg")
                var cfgm = doc_ostr(d, cfgn, "model")
                var ws = doc_find(d, r, "workers")
                # Branch 0 takes models[0], so this proves both the run
                # default and the per-branch entry were trimmed.
                trim_ok = cfgm == "stub-model" and doc_len(d, ws) > 0 and doc_ostr(
                    d, doc_at(d, ws, 0), "model"
                ) == "stub-other"
                liveauto_ok = doc_onum(d, cfgn, "gold") == 0.8
            except:
                var _e = 0
    e2e_check(trim_ok, "start trims model ids", fails)
    e2e_check(liveauto_ok, "live blank gold resolves 0.8", fails)
    var mcp_init = http_post_json(
        url,
        "/mcp",
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}',
        "",
    )
    e2e_check(
        mcp_init.ok
        and mcp_init.status == 200
        and mcp_init.body.find("metamining") >= 0,
        "mcp initialize",
        fails,
    )
    var mcp_tools = http_post_json(
        url, "/mcp", '{"jsonrpc":"2.0","id":2,"method":"tools/list"}', ""
    )
    e2e_check(
        mcp_tools.ok
        and mcp_tools.body.find("start_expedition") >= 0
        and mcp_tools.body.find("get_topology") >= 0,
        "mcp tools/list",
        fails,
    )
    var mcp_ping = http_post_json(
        url, "/mcp", '{"jsonrpc":"2.0","id":9,"method":"ping"}', ""
    )
    e2e_check(
        mcp_ping.ok and mcp_ping.body.find('"result":{}') >= 0, "mcp ping", fails
    )
    var mcp_start = http_post_json(
        url,
        "/mcp",
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"start_expedition","arguments":{"concept":"mcp probe","branches":1,"steps":2,"seed":11}}}',
        "",
    )
    e2e_check(
        mcp_start.ok and mcp_start.body.find("Expedition started") >= 0,
        "mcp start",
        fails,
    )
    var mcp_status = http_post_json(
        url,
        "/mcp",
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"expedition_status"}}',
        "",
    )
    e2e_check(
        mcp_status.ok and mcp_status.body.find("findings") >= 0,
        "mcp status",
        fails,
    )
    var mcp_find = http_post_json(
        url,
        "/mcp",
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_findings","arguments":{"limit":5}}}',
        "",
    )
    e2e_check(
        mcp_find.ok and mcp_find.body.find("items") >= 0, "mcp findings", fails
    )
    var mcp_stop = http_post_json(
        url,
        "/mcp",
        '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"stop_expedition"}}',
        "",
    )
    e2e_check(
        mcp_stop.ok and mcp_stop.body.find("Run stopped") >= 0, "mcp stop", fails
    )
    var mcp_bad = http_post_json(
        url,
        "/mcp",
        '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nope"}}',
        "",
    )
    e2e_check(
        mcp_bad.ok and mcp_bad.body.find("-32602") >= 0,
        "mcp unknown tool",
        fails,
    )
    var mcp_badm = http_post_json(
        url, "/mcp", '{"jsonrpc":"2.0","id":8,"method":"bogus"}', ""
    )
    e2e_check(
        mcp_badm.ok and mcp_badm.body.find("-32601") >= 0,
        "mcp unknown method",
        fails,
    )
    var mcp_parse = http_post_json(url, "/mcp", "{oops", "")
    e2e_check(
        mcp_parse.status == 400 and mcp_parse.body.find("-32700") >= 0,
        "mcp parse error",
        fails,
    )
    var mcp_notif = http_post_json(
        url,
        "/mcp",
        '{"jsonrpc":"2.0","method":"notifications/initialized"}',
        "",
    )
    e2e_check(mcp_notif.status == 202, "mcp notification ack", fails)
    _ = http_post_json(url, "/api/control", '{"action":"stop"}', "")
    _ = wait_child(mpid, False)
    _ = kill_pid(pid, 15)
    _ = wait_child(pid, False)
    return fails


def main() raises:
    var c = parse_args()
    if c.help:
        print(usage_text())
        return
    if c.version:
        print("MetaMining " + String(MM_VERSION))
        return
    if c.self_test:
        print("MetaMining self-test: full server E2E on loopback")
        var fails = self_test()
        if fails > 0:
            raise Error("self-test failures: " + String(fails))
        print("SELF-TEST PASSED")
        return
    var cfg = ExpCfg(
        c.concept,
        c.model,
        c.endpoint,
        c.api_key,
        c.embed_model,
        c.seed,
        c.branches,
        c.steps,
        c.gold,
        c.temp,
    )
    cfg.embed_endpoint = c.embed_endpoint
    cfg.embed_doc_prefix = c.embed_doc_prefix
    cfg.embed_query_prefix = c.embed_query_prefix
    cfg.repulse = c.repulse
    cfg.fanout = c.fanout
    cfg.judges = c.judges
    cfg.auto = c.auto
    cfg.push = c.push
    cfg.call_budget = c.call_budget
    if c.endpoint != "" and c.api_key != "":
        var ids = List[String]()
        var err = meta_models(MetaCfg(c.endpoint, c.api_key, c.model, c.embed_model), ids)
        if err == "":
            print("endpoint models: " + String(len(ids)))
            if len(ids) > 0:
                print("first model: " + ids[0])
        else:
            print("endpoint warn: " + err)
    elif c.endpoint != "":
        print("endpoint set without api key: sim backend until a key arrives")
    else:
        print("sim backend (no endpoint configured)")
    var srv = Server(cfg, c.webdir)
    srv.branch_models = parse_models_list(c.models)
    srv.auth_token = c.auth_token
    if c.auth_token != "":
        print("auth token required for /api/*, /frag/*, /events")
    srv.price_over = load_pricing_file("pricing.json")
    if len(srv.price_over) > 0:
        print("pricing overrides: " + String(len(srv.price_over)) + " models")
    srv_bind(srv, c.host, c.port)
    print(
        "MetaMining on http://"
        + c.host
        + ":"
        + String(c.port)
        + "  ["
        + c.concept
        + "]"
    )
    srv_serve(srv, 0)
