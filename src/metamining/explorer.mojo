"""Frontier exploration logic: branch state, Pareto picks, weeds stops.

Pure logic, no I/O: workers and the coordinator share these rules, and
the self-test pins them down.
"""

from std.math import isinf, isnan

from metamining.json import (
    doc_at,
    doc_find,
    doc_len,
    doc_num,
    doc_obool,
    doc_onum,
    doc_ostr,
    doc_root,
    doc_str,
    j_escape,
    j_render_num,
    parse_json,
)


struct ExpCfg(ImplicitlyCopyable):
    var concept: String
    var model: String
    var endpoint: String
    var api_key: String
    var embed_model: String
    var embed_endpoint: String
    var embed_doc_prefix: String
    var embed_query_prefix: String
    var seed: Int
    var branches: Int
    var steps: Int
    var gold: Float64
    var temp: Float64
    var plateau_k: Int
    var plateau_eps: Float64
    var nogold_m: Int
    var min_coh: Float64
    var coh_c: Int
    var global_stall: Int
    var repulse: Int
    var fanout: Int
    var judges: Int
    var auto: Int
    var push: Float64
    var call_budget: Int

    def __init__(
        out self,
        concept: String,
        model: String,
        endpoint: String,
        api_key: String,
        embed_model: String,
        seed: Int,
        branches: Int,
        steps: Int,
        gold: Float64,
        temp: Float64,
    ):
        self.concept = concept
        self.model = model
        self.endpoint = endpoint
        self.api_key = api_key
        self.embed_model = embed_model
        self.embed_endpoint = String()
        self.embed_doc_prefix = String()
        self.embed_query_prefix = String()
        self.seed = seed
        self.branches = branches
        self.steps = steps
        self.gold = gold
        self.temp = temp
        self.plateau_k = 12
        self.plateau_eps = 0.005
        self.nogold_m = 25
        self.min_coh = 0.25
        self.coh_c = 6
        self.global_stall = 40
        self.repulse = 30
        self.fanout = 1
        self.judges = 1
        self.auto = 0
        self.push = 0.90
        self.call_budget = 0


struct BranchState(Copyable, Movable):
    var bid: Int
    var step: Int
    var best: Float64
    var plateau: Int
    var nogold: Int
    var lowcoh: Int
    var done: Bool
    var reason: String
    var best_text: String
    var last_nov: Float64
    var last_coh: Float64
    var x: Float64
    var y: Float64
    var hist: List[List[Float64]]

    def __init__(out self, bid: Int):
        self.bid = bid
        self.step = 0
        self.best = 0.0
        self.plateau = 0
        self.nogold = 0
        self.lowcoh = 0
        self.done = False
        self.reason = String()
        self.best_text = String()
        self.last_nov = 0.0
        self.last_coh = 0.0
        self.x = 50.0
        self.y = 50.0
        self.hist = List[List[Float64]]()


struct Finding(ImplicitlyCopyable):
    var branch: Int
    var step: Int
    var nov: Float64
    var coh: Float64
    var x: Float64
    var y: Float64
    var z: Float64
    var gold: Bool
    var text: String
    var b0: Int
    var b1: Int
    var b2: Int
    var cd: Float64
    var persona: Int
    var temp: Float64
    var loc: String
    var src: String
    var run: Int

    def __init__(
        out self,
        branch: Int,
        step: Int,
        nov: Float64,
        coh: Float64,
        x: Float64,
        y: Float64,
        z: Float64,
        gold: Bool,
        text: String,
        b0: Int,
        b1: Int,
        b2: Int,
        cd: Float64,
        persona: Int,
        temp: Float64,
        loc: String,
        src: String,
        run: Int,
    ):
        self.branch = branch
        self.step = step
        self.nov = nov
        self.coh = coh
        self.x = x
        self.y = y
        self.z = z
        self.gold = gold
        self.text = text
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.cd = cd
        self.persona = persona
        self.temp = temp
        self.loc = loc
        self.src = src
        self.run = run


def branch_note(
    mut b: BranchState,
    cfg: ExpCfg,
    nov: Float64,
    coh: Float64,
    is_gold: Bool,
    fp: List[Float64],
    text: String,
    x: Float64,
    y: Float64,
):
    b.step += 1
    b.last_nov = nov
    b.last_coh = coh
    b.x = x
    b.y = y
    if nov > b.best + cfg.plateau_eps:
        b.best = nov
        b.plateau = 0
    else:
        b.plateau += 1
    if is_gold:
        b.nogold = 0
        b.best_text = text
    else:
        b.nogold += 1
    if coh < cfg.min_coh:
        b.lowcoh += 1
    else:
        b.lowcoh = 0
    b.hist.append(fp.copy())


def branch_should_stop(b: BranchState, cfg: ExpCfg) -> String:
    if b.step >= cfg.steps:
        return String("max-steps")
    if b.lowcoh >= cfg.coh_c and b.plateau >= cfg.plateau_k // 2:
        return String("weeds")
    if b.lowcoh >= cfg.coh_c:
        return String("incoherent")
    if b.plateau >= cfg.plateau_k:
        return String("plateau")
    if b.nogold >= cfg.nogold_m:
        return String("dry")
    return String()


def global_should_stop(streak_no_gold: Int, cfg: ExpCfg) -> String:
    if streak_no_gold >= cfg.global_stall:
        return String("global-weeds")
    return String()


def pareto(pool: List[Finding], mut out: List[Int]):
    for i in range(len(pool)):
        var dominated = False
        for j in range(len(pool)):
            if i == j:
                continue
            if (
                pool[j].nov >= pool[i].nov
                and pool[j].coh >= pool[i].coh
                and (pool[j].nov > pool[i].nov or pool[j].coh > pool[i].coh)
            ):
                dominated = True
                break
        if not dominated:
            out.append(i)


def finding_json(f: Finding, run: Int) -> String:
    return (
        String('{"t":"finding","run":')
        + String(run)
        + ',"branch":'
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
        + '"}'
    )


def status_json(branch: Int, step: Int, best: Float64, reason: String) -> String:
    return (
        String('{"t":"status","branch":')
        + String(branch)
        + ',"step":'
        + String(step)
        + ',"best":'
        + j_render_num(best)
        + ',"reason":"'
        + j_escape(reason)
        + '"}'
    )


def spawn_json(
    branch: Int,
    step: Int,
    text: String,
    nov: Float64,
    coh: Float64,
    score: Float64,
    temp: Float64,
    persona: Int,
    model: String,
) -> String:
    """Worker -> server: pursue this runner-up as a new fanout branch."""
    return (
        String('{"t":"spawn","branch":')
        + String(branch)
        + ',"step":'
        + String(step)
        + ',"text":"'
        + j_escape(text)
        + '","nov":'
        + j_render_num(nov)
        + ',"coh":'
        + j_render_num(coh)
        + ',"score":'
        + j_render_num(score)
        + ',"temp":'
        + j_render_num(temp)
        + ',"persona":'
        + String(persona)
        + ',"model":"'
        + j_escape(model)
        + '"}'
    )


def done_json(branch: Int, steps: Int, best: Float64, reason: String) -> String:
    return (
        String('{"t":"done","branch":')
        + String(branch)
        + ',"steps":'
        + String(steps)
        + ',"best":'
        + j_render_num(best)
        + ',"reason":"'
        + j_escape(reason)
        + '"}'
    )


def _fin(f: Float64) -> Float64:
    """Clamp a wire float: non-finite (NaN/Inf) becomes 0.0."""
    if isinf(f) or isnan(f):
        return 0.0
    return f


def _fint(f: Float64) -> Int:
    """Clamp a wire int: non-finite becomes 0 (Int() of inf is garbage)."""
    if isinf(f) or isnan(f):
        return 0
    return Int(f)


def parse_finding(line: String) raises -> Finding:
    var d = parse_json(line)
    var r = doc_root(d)
    return Finding(
        _fint(doc_onum(d, r, "branch")),
        _fint(doc_onum(d, r, "step")),
        _fin(doc_onum(d, r, "novelty")),
        _fin(doc_onum(d, r, "coherence")),
        _fin(doc_onum(d, r, "x")),
        _fin(doc_onum(d, r, "y")),
        _fin(doc_onum(d, r, "z")),
        doc_obool(d, r, "gold"),
        doc_ostr(d, r, "text"),
        _fint(doc_onum(d, r, "b0")),
        _fint(doc_onum(d, r, "b1")),
        _fint(doc_onum(d, r, "b2")),
        _fin(doc_onum(d, r, "cd")),
        _fint(doc_onum(d, r, "persona")),
        _fin(doc_onum(d, r, "temp")),
        doc_ostr(d, r, "loc"),
        doc_ostr(d, r, "src"),
        _fint(doc_onum(d, r, "run")),
    )


def msg_kind(line: String) raises -> String:
    var d = parse_json(line)
    return doc_ostr(d, doc_root(d), "t")


def msg_str(line: String, key: String) raises -> String:
    var d = parse_json(line)
    return doc_ostr(d, doc_root(d), key)


def msg_num(line: String, key: String) raises -> Float64:
    var d = parse_json(line)
    return doc_onum(d, doc_root(d), key)


def msg_int(line: String, key: String) raises -> Int:
    """Integer wire field: 0 when missing or non-finite (NaN/Inf)."""
    var f = msg_num(line, key)
    if isinf(f) or isnan(f):
        return 0
    return Int(f)


def msg_strs(line: String, key: String, mut out: List[String]) raises:
    var d = parse_json(line)
    var arr = doc_find(d, doc_root(d), key)
    if arr < 0:
        return
    for i in range(doc_len(d, arr)):
        out.append(doc_str(d, doc_at(d, arr, i)))


def msg_vec(line: String, key: String, mut out: List[Float64]) raises:
    var d = parse_json(line)
    var arr = doc_find(d, doc_root(d), key)
    if arr < 0:
        return
    for i in range(doc_len(d, arr)):
        out.append(doc_num(d, doc_at(d, arr, i)))


def msg_vecs(line: String, key: String, mut out: List[List[Float64]]) raises:
    var d = parse_json(line)
    var arr = doc_find(d, doc_root(d), key)
    if arr < 0:
        return
    for i in range(doc_len(d, arr)):
        var inner = doc_at(d, arr, i)
        var v = List[Float64]()
        for j in range(doc_len(d, inner)):
            v.append(doc_num(d, doc_at(d, inner, j)))
        out.append(v.copy())


struct VecMsg(ImplicitlyCopyable):
    var branch: Int
    var step: Int
    var run: Int

    def __init__(out self, branch: Int, step: Int, run: Int):
        self.branch = branch
        self.step = step
        self.run = run


def vec_json(branch: Int, step: Int, run: Int, vec: List[Float64]) -> String:
    var out = (
        String('{"t":"vec","run":')
        + String(run)
        + ',"branch":'
        + String(branch)
        + ',"step":'
        + String(step)
        + ',"vec":['
    )
    for i in range(len(vec)):
        if i > 0:
            out += ","
        out += j_render_num(vec[i])
    out += "]}"
    return out


def parse_vec(line: String, mut out: List[Float64]) raises -> VecMsg:
    var d = parse_json(line)
    var r = doc_root(d)
    var m = VecMsg(
        _fint(doc_onum(d, r, "branch")),
        _fint(doc_onum(d, r, "step")),
        _fint(doc_onum(d, r, "run")),
    )
    var arr = doc_find(d, r, "vec")
    for i in range(doc_len(d, arr)):
        out.append(_fin(doc_num(d, doc_at(d, arr, i))))
    return m


def tele_json(
    branch: Int,
    run: Int,
    step: Int,
    temp: Float64,
    streak: Int,
    persona: Int,
    energy: Int,
    b0: Int,
    b1: Int,
    b2: Int,
    cd: Float64,
    sheaf: Float64,
    entropy: Float64,
    judges: Int,
    r_calls: Int,
    e_calls: Int,
    r_ms: Int,
    e_ms: Int,
    tok_in: Int,
    tok_out: Int,
    push: Float64,
) -> String:
    return (
        String('{"t":"tele","run":')
        + String(run)
        + ',"branch":'
        + String(branch)
        + ',"step":'
        + String(step)
        + ',"temp":'
        + j_render_num(temp)
        + ',"streak":'
        + String(streak)
        + ',"persona":'
        + String(persona)
        + ',"energy":'
        + String(energy)
        + ',"b0":'
        + String(b0)
        + ',"b1":'
        + String(b1)
        + ',"b2":'
        + String(b2)
        + ',"cd":'
        + j_render_num(cd)
        + ',"sheaf":'
        + j_render_num(sheaf)
        + ',"entropy":'
        + j_render_num(entropy)
        + ',"judges":'
        + String(judges)
        + ',"r_calls":'
        + String(r_calls)
        + ',"e_calls":'
        + String(e_calls)
        + ',"r_ms":'
        + String(r_ms)
        + ',"e_ms":'
        + String(e_ms)
        + ',"tok_in":'
        + String(tok_in)
        + ',"tok_out":'
        + String(tok_out)
        + ',"push":'
        + j_render_num(push)
        + "}"
    )


def buf_find_nl(buf: String, start: Int) -> Int:
    """Byte offset of the next newline at/after start, else -1.

    Lets line drains walk a chunk with a cursor (one slice per line,
    one trim at the end) instead of re-copying the whole remainder
    after every line. ASCII scan: newline is one byte in UTF-8.
    """
    var bl = buf.byte_length()
    var i = start
    if i < 0:
        i = 0
    var raw = buf.as_bytes()
    while i < bl:
        if Int(raw[i]) == 10:
            return i
        i += 1
    return -1


struct TeleMsg(ImplicitlyCopyable):
    """One parsed tele line: raw wire floats, one JSON parse.

    Int fields stay Float64 here; the consumer maps them with
    tele_int (0 when non-finite), matching msg_int exactly.
    """

    var run: Int
    var temp: Float64
    var streak: Float64
    var persona: Float64
    var energy: Float64
    var b0: Float64
    var b1: Float64
    var b2: Float64
    var cd: Float64
    var sheaf: Float64
    var entropy: Float64
    var judges: Float64
    var r_calls: Float64
    var e_calls: Float64
    var r_ms: Float64
    var e_ms: Float64
    var tok_in: Float64
    var tok_out: Float64
    var push: Float64
    var step: Float64

    def __init__(
        out self,
        run: Int,
        temp: Float64,
        streak: Float64,
        persona: Float64,
        energy: Float64,
        b0: Float64,
        b1: Float64,
        b2: Float64,
        cd: Float64,
        sheaf: Float64,
        entropy: Float64,
        judges: Float64,
        r_calls: Float64,
        e_calls: Float64,
        r_ms: Float64,
        e_ms: Float64,
        tok_in: Float64,
        tok_out: Float64,
        push: Float64,
        step: Float64,
    ):
        self.run = run
        self.temp = temp
        self.streak = streak
        self.persona = persona
        self.energy = energy
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.cd = cd
        self.sheaf = sheaf
        self.entropy = entropy
        self.judges = judges
        self.r_calls = r_calls
        self.e_calls = e_calls
        self.r_ms = r_ms
        self.e_ms = e_ms
        self.tok_in = tok_in
        self.tok_out = tok_out
        self.push = push
        self.step = step


def tele_int(f: Float64) -> Int:
    """Wire int field: 0 when missing or non-finite (msg_int semantics)."""
    if isinf(f) or isnan(f):
        return 0
    return Int(f)


def parse_tele(line: String) raises -> TeleMsg:
    """Parse a tele line once into all fields (raw floats).

    Replaces ~25 msg_num/msg_int parses in the server tele branch.
    Missing keys read 0.0, exactly like msg_num on the same line.
    """
    var d = parse_json(line)
    var r = doc_root(d)
    return TeleMsg(
        _fint(doc_onum(d, r, "run")),
        doc_onum(d, r, "temp"),
        doc_onum(d, r, "streak"),
        doc_onum(d, r, "persona"),
        doc_onum(d, r, "energy"),
        doc_onum(d, r, "b0"),
        doc_onum(d, r, "b1"),
        doc_onum(d, r, "b2"),
        doc_onum(d, r, "cd"),
        doc_onum(d, r, "sheaf"),
        doc_onum(d, r, "entropy"),
        doc_onum(d, r, "judges"),
        doc_onum(d, r, "r_calls"),
        doc_onum(d, r, "e_calls"),
        doc_onum(d, r, "r_ms"),
        doc_onum(d, r, "e_ms"),
        doc_onum(d, r, "tok_in"),
        doc_onum(d, r, "tok_out"),
        doc_onum(d, r, "push"),
        doc_onum(d, r, "step"),
    )
