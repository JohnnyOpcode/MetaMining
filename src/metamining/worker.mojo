"""Branch worker: one full expedition loop per forked child.

Each worker owns a branch: persona-lens prompts, seed chaining,
KDE/lexical/topological novelty, judge-gated coherence, a gold
vault, quantum warp, and energy camps. Reports finding / vec /
tele / status / done lines upstream; obeys order lines
(pause/resume/warp/restart/teleport/persona/tune) downstream.

Implementation notes (all forced by the API or fixed as bugs):
- No sampler access over HTTPS, so repulsion is a prompt-level
  avoid-list of forbidden words.
- The Responses shape takes max_output_tokens (sent as 4096) and no
  top_p, so brevity is enforced by instruction text instead of sampler caps.
- Contrast themes slice the journal (with current step) against the
  trip log (without it) with aligned indexing.
- Per-branch stops (plateau/dry/weeds/incoherent/max-steps) and
  the sim backend are built in.
"""

from metamining.endpoint import MetaCfg, embed_input, meta_embed, meta_respond
from metamining.explorer import (
    BranchState,
    ExpCfg,
    Finding,
    branch_note,
    branch_should_stop,
    buf_find_nl,
    done_json,
    finding_json,
    msg_kind,
    msg_num,
    msg_str,
    msg_strs,
    msg_vec,
    msg_vecs,
    pareto,
    spawn_json,
    status_json,
    tele_json,
    vec_json,
)
from metamining.json import doc_at, doc_find, doc_len, doc_num, doc_root, parse_json
from metamining.libc import (
    child_exit,
    close_fd,
    file_read_all,
    ignore_sigpipe,
    mono_ms,
    msleep,
    pipe_read_some,
    pipe_write_all,
    poll_one,
)
from metamining.linalg import vcos
from metamining.scoring import (
    blend_judge,
    coherence_base,
    composite_novelty,
    count_get,
    is_gold,
    kde_novelty,
    lex_words,
    lexical_novelty,
    median_vote,
    novelty_stationary,
    parse_judge,
    round1,
    vein_nearest,
    vein_repulse_factor,
)
from metamining.sim import sim_embed, sim_gen_text, sim_stream
from metamining.steering import (
    contrast_themes,
    momentum_blend,
    ortho_project,
    pca_subspace,
    topo_steer,
)
from metamining.topo import TopoRes, topo_compute


def personas() -> List[String]:
    var p = List[String]()
    p.append("Mechanistic Systems Biology & Network Medicine")
    p.append("Nonlinear Dynamics & Bifurcation Theory")
    p.append("Information Theory & Algorithmic Complexity")
    p.append("Persistent Homology & Latent Topology")
    p.append("Synthetic Epigenetics & Bio-Computing")
    p.append("Thermodynamics of Complex Adaptive Systems")
    p.append("Surrealist Cybernetics & Cognitive Architecture")
    p.append("Fungal & Mycelial Network Architectures")
    p.append("Quantum Information & Coherence Dynamics")
    p.append("Crystalline Semiotics & Structural Linguistics")
    p.append("Deep-Sea Abyssal Xenobiology")
    p.append("Evolutionary Game Theory & Niche Construction")
    p.append("Non-Euclidean Spatial Morphologies")
    p.append("Material Science & Metamaterial Engineering")
    p.append("Category Theory & Conceptual Translation")
    p.append("Biomimetic Energy Dynamics")
    return p.copy()


def persona_name(idx: Int) -> String:
    var p = personas()
    var i = idx
    if i < 0:
        i = 0
    return p[i % len(p)]


def base_tropes() -> List[String]:
    var t = List[String]()
    t.append("tapestry")
    t.append("cathedral")
    t.append("sentient")
    t.append("whisper")
    t.append("fabric")
    t.append("recesses")
    t.append("symphony")
    t.append("dance")
    t.append("realm")
    t.append("interplay")
    t.append("intricate")
    t.append("woven")
    t.append("nexus")
    t.append("echoes")
    t.append("portal")
    return t.copy()


def _starts_with(s: String, pre: String) -> Bool:
    if s.byte_length() < pre.byte_length():
        return False
    return String(s[byte=0 : pre.byte_length()]) == pre


def craft_sys(concept: String, persona: String) -> String:
    return (
        String("You are an elite, lateral-thinking researcher investigating: '")
        + concept
        + "'. Your current analytical lens is: '"
        + persona
        + "'. Uncover rigorous, highly original, non-obvious cross-disciplinary insights."
    )


def craft_user(
    concept: String, location: String, cues: List[String], repulse: List[String]
) -> String:
    var out = (
        String("Primary Domain: ")
        + concept
        + "\nCurrent Exploration Front: "
        + location
        + "."
    )
    if len(cues) > 0:
        out += " Orthogonally depart from well-trodden themes ("
        for i in range(len(cues)):
            if i > 0:
                out += ", "
            out += cues[i]
        out += ")."
    out += (
        "\n\nGenerate a dense, specific, insightful paragraph connecting this front "
        + "to the primary domain. Avoid conversational filler, questions, and cliché "
        + "metaphors. Write the insight directly."
    )
    if len(repulse) > 0:
        out += "\n\nAvoid these overused words and tropes: "
        for i in range(len(repulse)):
            if i > 0:
                out += ", "
            out += repulse[i]
        out += "."
    return out


def judge_sys() -> String:
    return String("You are a rigorous, critical scientific reviewer.")


def judge_user(location: String, text: String) -> String:
    return (
        String(
            "Assess the logical rigor, conceptual depth, mechanistic plausibility, "
            + "and scientific coherence of the following insight regarding '"
        )
        + location
        + "'.\nRate strictly from 1 to 10 (where 10 is groundbreaking and rigorous, "
        + "1 is vague gibberish or ungrounded buzzwords).\nOutput ONLY a single "
        + "integer between 1 and 10.\n\nText: "
        + text
        + "\n\nScore:"
    )


def extract_sys() -> String:
    return String("You are a precise concept extraction engine.")


def extract_user(concept: String, text: String) -> String:
    return (
        String(
            "Read the following text. Extract the single most novel, highly specific "
            + "mechanism or concept from it that relates to '"
        )
        + concept
        + "'.\nOutput ONLY that concept as a short noun phrase in 1 to 5 words. No "
        + "formatting, no conversational filler.\n\nText: "
        + text
        + "\n\nConcept:"
    )


def synth_sys() -> String:
    return String("You are a scientific concept synthesizer.")


def synth_user(concept: String, persona: String) -> String:
    return (
        String("Generate a single highly novel concept in 3 to 5 words bridging '")
        + concept
        + "' and '"
        + persona
        + "'. Output ONLY the concept."
    )


def camp_sys() -> String:
    return String("You are a reflective lead scientist.")


def camp_user(concept: String, recent: List[String]) -> String:
    var out = (
        String("Summarize key breakthroughs regarding '")
        + concept
        + "' from these observations in one sentence: "
    )
    for i in range(len(recent)):
        if i > 0:
            out += " | "
        out += recent[i]
    return out


def _filler_marks() -> List[String]:
    var m = List[String]()
    m.append("(Your turn")
    m.append("(Note:")
    m.append("(Please")
    m.append("Let me know")
    m.append("Go ahead")
    m.append("Please respond")
    m.append("Please share")
    m.append("Please provide")
    m.append("How's that?")
    m.append("What do you think?")
    m.append("Would you like")
    m.append("Feel free")
    m.append("I'd love to")
    m.append("Your turn")
    m.append("Now it's your turn")
    m.append("(And, just to clarify")
    m.append("(I've generated")
    m.append("(If I don't")
    m.append("(When I've finished")
    m.append("```python")
    m.append("(optional:")
    m.append("(I chose")
    m.append("Here's my attempt")
    m.append("Here's my response")
    return m.copy()


def strip_filler(text: String) -> String:
    var paras = List[String]()
    var rest = text
    while True:
        var nl = rest.find("\n\n")
        if nl < 0:
            paras.append(rest)
            break
        paras.append(String(rest[byte=0:nl]))
        var tail = String(rest[byte = nl + 2 :])
        rest = tail
    var cleaned = text
    for i in range(len(paras)):
        var p = String(paras[i].strip())
        if p.byte_length() > 50 and not _starts_with(p, "(") and not _starts_with(p, "Note:"):
            cleaned = p
            break
    var marks = _filler_marks()
    for i in range(len(marks)):
        var at = cleaned.find(marks[i])
        if at > 0:
            cleaned = String(String(cleaned[byte=0:at]).strip())
    if cleaned.byte_length() > 30:
        return cleaned
    return text


def clean_seed(raw: String) -> String:
    var s = String(raw.strip())
    var n = s.byte_length()
    if n >= 2:
        var sb = s.as_bytes()
        var f = Int(sb[0])
        var l = Int(sb[n - 1])
        if (f == 34 and l == 34) or (f == 39 and l == 39):
            var inner = String(String(s[byte=1 : n - 1]).strip())
            s = inner
    var nl = s.find("\n")
    if nl >= 0:
        var head = String(String(s[byte=0:nl]).strip())
        s = head
    var low = String(s.lower())
    if _starts_with(low, "concept:"):
        var cut8 = String(String(s[byte=8:]).strip())
        s = cut8
    elif _starts_with(low, "the concept of"):
        var cut14 = String(String(s[byte=14:]).strip())
        s = cut14
        if _starts_with(s, ":"):
            var cut1 = String(String(s[byte=1:]).strip())
            s = cut1
    return s


def seed_ok(s: String) -> Bool:
    var alpha = 0
    var under = 0
    for b in s.bytes():
        var v = Int(b)
        if (v >= 65 and v <= 90) or (v >= 97 and v <= 122):
            alpha += 1
        if v == 95:
            under += 1
    var n = s.byte_length()
    return n >= 3 and alpha >= 3 and n <= 80 and under <= 3


def sim_seed(response: String, jtexts: List[String]) -> String:
    """Deterministic seed analog: rarest-vs-journal words, up to 5.

    The recount covers the trailing 500 texts: recounting the whole
    journal each step is O(steps^2) lexer work, and words older than
    that no longer steer away from the live frontier.
    """
    var counts = Dict[String, Int]()
    var start = len(jtexts) - 500
    if start < 0:
        start = 0
    for i in range(start, len(jtexts)):
        var hw = List[String]()
        lex_words(jtexts[i], 3, hw)
        for j in range(len(hw)):
            counts[hw[j]] = count_get(counts, hw[j]) + 1
    var words = List[String]()
    lex_words(response, 3, words)
    var picked = List[String]()
    for round in range(4):
        var ceil = round
        if round == 3:
            ceil = 1000000000
        for i in range(len(words)):
            if len(picked) >= 5:
                break
            var w = words[i]
            var dup = False
            for k in range(len(picked)):
                if picked[k] == w:
                    dup = True
                    break
            if dup:
                continue
            if count_get(counts, w) <= ceil:
                picked.append(w)
        if len(picked) >= 5:
            break
    if len(picked) == 0:
        return String("untried latent mechanism")
    var out = String("")
    for i in range(len(picked)):
        if i > 0:
            out += " "
        out += picked[i]
    if out.byte_length() <= 80:
        return out
    var cut = 80
    var oraw = out.as_bytes()
    for i in range(80):
        if Int(oraw[i]) == 32:
            cut = i
    if cut == 80:
        while cut > 0 and (Int(oraw[cut]) & 0xC0) == 0x80:
            cut -= 1
    return String(String(out[byte=0:cut]).strip())


def repulse_words(jtexts: List[String]) -> List[String]:
    """Top-15 frequent (4+, seen 3+) journal words plus base tropes."""
    var out = List[String]()
    var counts = Dict[String, Int]()
    var uniq = List[String]()
    var start = len(jtexts) - 10
    if start < 0:
        start = 0
    for i in range(start, len(jtexts)):
        var ws = List[String]()
        lex_words(jtexts[i], 4, ws)
        for j in range(len(ws)):
            counts[ws[j]] = count_get(counts, ws[j]) + 1
            var seen = False
            for k in range(len(uniq)):
                if uniq[k] == ws[j]:
                    seen = True
                    break
            if not seen:
                uniq.append(ws[j])
    var picked = List[Int]()
    for _ in range(len(uniq)):
        picked.append(0)
    for _ in range(15):
        var bi = -1
        var bc = 0
        for i in range(len(uniq)):
            if picked[i] != 0:
                continue
            var c = count_get(counts, uniq[i])
            if c >= 3 and (bi < 0 or c > bc):
                bi = i
                bc = c
        if bi < 0:
            break
        picked[bi] = 1
        out.append(uniq[bi])
    var tropes = base_tropes()
    for i in range(len(tropes)):
        var dup = False
        for k in range(len(out)):
            if out[k] == tropes[i]:
                dup = True
                break
        if not dup:
            out.append(tropes[i])
    return out.copy()


def union_words(a: List[String], b: List[String]) -> List[String]:
    var out = List[String]()
    for i in range(len(a)):
        out.append(a[i])
    for i in range(len(b)):
        var dup = False
        for k in range(len(out)):
            if out[k] == b[i]:
                dup = True
                break
        if not dup:
            out.append(b[i])
    return out.copy()


def repulse_cap(words: List[String], cap: Int) -> List[String]:
    """First cap words of the avoid-list; cap <= 0 means off (empty)."""
    var out = List[String]()
    if cap <= 0:
        return out.copy()
    var n = len(words)
    if n > cap:
        n = cap
    for i in range(n):
        out.append(words[i])
    return out.copy()


def parse_models_list(raw: String) -> List[String]:
    """Split a start 'models' comma list. Entries are trimmed and kept
    positionally (blanks stay as '' so branch_model_for can fall back
    to the run default per branch). Blank input yields an empty list."""
    var out = List[String]()
    var s = String(raw.strip())
    if s == "":
        return out.copy()
    var rest = s
    while True:
        var c = rest.find(",")
        if c < 0:
            var last = String(rest.strip())
            out.append(last)
            break
        var head = String(rest[byte=0:c])
        var trimmed = String(head.strip())
        out.append(trimmed)
        var tail = String(rest[byte = c + 1 :])
        rest = tail
    return out.copy()


def branch_model_for(default: String, models: List[String], bid: Int) -> String:
    """Effective model for branch bid: models[bid % len], with blank
    entries (and an empty list) falling back to the run default."""
    if len(models) == 0:
        return default
    var i = bid % len(models)
    if i < 0:
        i += len(models)
    var m = models[i]
    if m == "":
        return default
    return m


struct AutoStep(ImplicitlyCopyable):
    var temp: Float64
    var push: Float64
    var action: Int

    def __init__(out self, temp: Float64, push: Float64, action: Int):
        self.temp = temp
        self.push = push
        self.action = action


def auto_delta(jnov: List[Float64]) -> Float64:
    """Bandit reward: trailing-4 mean novelty minus the prior-4 mean.
    Zero when fewer than 8 samples exist."""
    var n = len(jnov)
    if n < 8:
        return 0.0
    var m1 = 0.0
    for i in range(n - 8, n - 4):
        m1 += jnov[i]
    m1 /= 4.0
    var m2 = 0.0
    for i in range(n - 4, n):
        m2 += jnov[i]
    m2 /= 4.0
    return m2 - m1


def auto_clamp_temp(t: Float64) -> Float64:
    if t < 0.5:
        return 0.5
    if t > 1.3:
        return 1.3
    return t


def auto_clamp_push(p: Float64) -> Float64:
    if p < 0.0:
        return 0.0
    if p > 2.0:
        return 2.0
    return p


def auto_apply(temp: Float64, push: Float64, action: Int) -> AutoStep:
    """Apply bandit nudge 0..3 (temp+/temp-/push+/push-) with clamps."""
    var t = temp
    var p = push
    if action == 0:
        t += 0.05
    elif action == 1:
        t -= 0.05
    elif action == 2:
        p += 0.05
    elif action == 3:
        p -= 0.05
    return AutoStep(auto_clamp_temp(t), auto_clamp_push(p), action)


def auto_argmax(vals: List[Float64], counts: List[Int]) -> Int:
    """Greedy arm: the first untried arm wins (coverage), else the
    best running mean (ties keep the smallest index)."""
    for i in range(4):
        if i >= len(counts) or counts[i] == 0:
            return i
    var bi = 0
    for i in range(1, 4):
        if vals[i] > vals[bi]:
            bi = i
    return bi


def auto_pick(
    vals: List[Float64], counts: List[Int], rand_u: Float64, rand_idx: Int
) -> Int:
    """Epsilon-greedy (0.2) arm pick over the 4 nudges."""
    if rand_u < 0.2:
        var k = rand_idx % 4
        if k < 0:
            k += 4
        return k
    return auto_argmax(vals, counts)


def w_global_lex(text: String, gtexts: List[String]) -> Float64:
    """Novelty vs the hive archive; neutral 1.0 when empty."""
    if len(gtexts) == 0:
        return 1.0
    return lexical_novelty(text, gtexts)


def w_global_kde(vec: List[Float64], gvecs: List[List[Float64]]) -> Float64:
    """KDE novelty vs the hive sample; neutral 1.0 when empty."""
    if len(gvecs) == 0:
        return 1.0
    return kde_novelty(vec, gvecs)


def veins_load_vecs(path: String, mut out: List[List[Float64]]):
    """Read vein vecs from a veins.json file. Missing or bad file
    yields no vecs (the hooks below then act as no-ops)."""
    var raw = file_read_all(path)
    if raw == "":
        return
    try:
        var dd = parse_json(raw)
        var arr = doc_find(dd, doc_root(dd), "veins")
        if arr < 0:
            return
        for i in range(doc_len(dd, arr)):
            var e = doc_at(dd, arr, i)
            var varr = doc_find(dd, e, "vec")
            if varr < 0:
                continue
            var vv = List[Float64]()
            for j in range(doc_len(dd, varr)):
                vv.append(doc_num(dd, doc_at(dd, varr, j)))
            if len(vv) > 0:
                out.append(vv.copy())
    except:
        return


struct GenOut(ImplicitlyCopyable):
    var ok: Bool
    var text: String
    var err: String
    var ms: Int
    var in_tok: Int
    var out_tok: Int

    def __init__(out self, ok: Bool, text: String, err: String, ms: Int, in_tok: Int, out_tok: Int):
        self.ok = ok
        self.text = text
        self.err = err
        self.ms = ms
        self.in_tok = in_tok
        self.out_tok = out_tok


def use_meta_backend(cfg: ExpCfg) -> Bool:
    return cfg.endpoint != "" and cfg.api_key != "" and cfg.model != ""


struct WLoop(Copyable, Movable):
    var bid: Int
    var run: Int
    var wfd: Int
    var rfd: Int
    var meta: Bool
    var mcfg: MetaCfg
    var concept: String
    var seed: Int
    var temp: Float64
    var wgold: Float64
    var push: Float64
    var streak: Int
    var persona: Int
    var location: String
    var start_vec: List[Float64]
    var loc_vec: List[Float64]
    var loc_key: String
    var energy: Int
    var fails: Int
    var judges: Int
    var paused: Bool
    var dim: Int
    var b: BranchState
    var jtexts: List[String]
    var jnov: List[Float64]
    var jcoh: List[Float64]
    var locs: List[String]
    var gold_v: List[List[Float64]]
    var contrast: List[String]
    var repulse: List[String]
    var repulse_max: Int
    var fanout: Int
    var judges_n: Int
    var auto: Bool
    var auto_last: Int
    var auto_vals: List[Float64]
    var auto_counts: List[Int]
    var gtexts: List[String]
    var gvecs: List[List[Float64]]
    var ggold: List[Float64]
    var vvecs: List[List[Float64]]
    var r_calls: Int
    var e_calls: Int
    var r_ms: Int
    var e_ms: Int
    var tok_in: Int
    var tok_out: Int
    var obuf: String
    var budget: Int
    var embed_fails: Int
    var embed_fallback: Bool

    def __init__(out self, bid: Int, run: Int, wfd: Int, rfd: Int, cfg: ExpCfg):
        self.bid = bid
        self.run = run
        self.wfd = wfd
        self.rfd = rfd
        self.meta = use_meta_backend(cfg)
        self.mcfg = MetaCfg(
            cfg.endpoint,
            cfg.api_key,
            cfg.model,
            cfg.embed_model,
            cfg.embed_endpoint,
            cfg.embed_doc_prefix,
            cfg.embed_query_prefix,
        )
        self.concept = cfg.concept
        self.seed = cfg.seed
        self.temp = cfg.temp
        self.wgold = cfg.gold
        self.push = cfg.push
        self.streak = 0
        self.persona = bid % 16
        self.location = cfg.concept
        self.start_vec = List[Float64]()
        self.loc_vec = List[Float64]()
        self.loc_key = String()
        self.energy = 100
        self.fails = 0
        self.judges = 0
        self.paused = False
        self.dim = 0
        self.b = BranchState(bid)
        self.jtexts = List[String]()
        self.jnov = List[Float64]()
        self.jcoh = List[Float64]()
        self.locs = List[String]()
        self.gold_v = List[List[Float64]]()
        self.contrast = List[String]()
        self.repulse = List[String]()
        self.repulse_max = cfg.repulse
        self.fanout = cfg.fanout
        if self.fanout < 1 or self.fanout > 8:
            self.fanout = 1
        self.judges_n = cfg.judges
        if self.judges_n < 1 or self.judges_n > 5:
            self.judges_n = 1
        self.auto = cfg.auto != 0
        self.auto_last = -1
        self.auto_vals = List[Float64]()
        self.auto_counts = List[Int]()
        for _ in range(4):
            self.auto_vals.append(0.0)
            self.auto_counts.append(0)
        self.gtexts = List[String]()
        self.gvecs = List[List[Float64]]()
        self.ggold = List[Float64]()
        var vv = List[List[Float64]]()
        veins_load_vecs("veins/veins.json", vv)
        self.vvecs = vv^
        self.r_calls = 0
        self.e_calls = 0
        self.r_ms = 0
        self.e_ms = 0
        self.tok_in = 0
        self.tok_out = 0
        self.obuf = String()
        self.budget = cfg.call_budget
        self.embed_fails = 0
        self.embed_fallback = False


def w_reset(mut w: WLoop, cfg: ExpCfg):
    """Restart reset: expedition state returns to constructor values —
    persona re-spread by bid, push back to cfg.push, vectors cleared,
    the order buffer dropped (orders pipelined after the restart are
    lost). Survives: identity (bid/run/concept/seed), pipe fds, the
    backend connection (base_url/api_key/embed_model; model takes
    cfg.model), and the vein library (vvecs, file-backed, no reload)."""
    w.temp = cfg.temp
    w.wgold = cfg.gold
    w.push = cfg.push
    w.streak = 0
    w.persona = w.bid % 16
    w.location = cfg.concept
    w.start_vec = List[Float64]()
    w.loc_vec = List[Float64]()
    w.loc_key = String()
    w.energy = 100
    w.fails = 0
    w.judges = 0
    w.paused = False
    w.dim = 0
    w.b = BranchState(w.bid)
    w.jtexts = List[String]()
    w.jnov = List[Float64]()
    w.jcoh = List[Float64]()
    w.locs = List[String]()
    w.gold_v = List[List[Float64]]()
    w.contrast = List[String]()
    w.repulse = List[String]()
    w.repulse_max = cfg.repulse
    w.fanout = cfg.fanout
    if w.fanout < 1 or w.fanout > 8:
        w.fanout = 1
    w.judges_n = cfg.judges
    if w.judges_n < 1 or w.judges_n > 5:
        w.judges_n = 1
    w.mcfg.model = cfg.model
    w.meta = w.mcfg.base_url != "" and w.mcfg.api_key != "" and w.mcfg.model != ""
    w.auto = cfg.auto != 0
    w.auto_last = -1
    w.auto_vals = List[Float64]()
    w.auto_counts = List[Int]()
    for _ in range(4):
        w.auto_vals.append(0.0)
        w.auto_counts.append(0)
    w.gtexts = List[String]()
    w.gvecs = List[List[Float64]]()
    w.ggold = List[Float64]()
    w.r_calls = 0
    w.e_calls = 0
    w.r_ms = 0
    w.e_ms = 0
    w.tok_in = 0
    w.tok_out = 0
    w.obuf = String()
    w.budget = cfg.call_budget
    w.embed_fails = 0
    w.embed_fallback = False


def w_budget_hit(w: WLoop) -> Bool:
    return w.budget > 0 and (w.r_calls + w.e_calls) >= w.budget


def w_emit(w: WLoop, line: String) -> Bool:
    return pipe_write_all(w.wfd, line + "\n") >= 0


def w_apply_order(mut w: WLoop, cfg: ExpCfg, line: String):
    var kind: String
    try:
        kind = msg_kind(line)
    except:
        _ = w_emit(w, status_json(w.bid, w.b.step, w.b.best, "order error: bad json"))
        return
    if kind != "order":
        _ = w_emit(w, status_json(w.bid, w.b.step, w.b.best, "order error: not an order"))
        return
    var name: String
    try:
        name = msg_str(line, "name")
    except:
        _ = w_emit(w, status_json(w.bid, w.b.step, w.b.best, "order error: missing name"))
        return
    if name == "pause":
        w.paused = True
    elif name == "resume":
        w.paused = False
    elif name == "warp":
        w.streak = 3
    elif name == "restart":
        w_reset(w, cfg)
    elif name == "teleport":
        try:
            var target = msg_str(line, "target")
            if target != "":
                w.location = target
                w.streak = 0
                w.loc_key = String()
        except:
            pass
    elif name == "persona":
        try:
            var idx = Int(msg_num(line, "idx"))
            if idx >= 0 and idx < 16:
                w.persona = idx
        except:
            pass
    elif name == "tune":
        # Only present keys apply: a partial tune must not zero the rest.
        var has_temp = False
        var has_gold = False
        var has_push = False
        var has_repulse = False
        var has_fanout = False
        var has_judges = False
        var has_budget = False
        var has_addr = False
        var has_adde = False
        try:
            var dd = parse_json(line)
            var rr = doc_root(dd)
            has_temp = doc_find(dd, rr, "temp") >= 0
            has_gold = doc_find(dd, rr, "gold") >= 0
            has_push = doc_find(dd, rr, "push") >= 0
            has_repulse = doc_find(dd, rr, "repulse") >= 0
            has_fanout = doc_find(dd, rr, "fanout") >= 0
            has_judges = doc_find(dd, rr, "judges") >= 0
            has_budget = doc_find(dd, rr, "call_budget") >= 0
            has_addr = doc_find(dd, rr, "add_r") >= 0
            has_adde = doc_find(dd, rr, "add_e") >= 0
        except:
            pass
        if has_temp:
            try:
                var t = msg_num(line, "temp")
                if t >= 0.0 and t <= 2.0:
                    w.temp = t
            except:
                pass
        if has_gold:
            try:
                var g = msg_num(line, "gold")
                if g >= 0.0 and g <= 1.0:
                    w.wgold = g
            except:
                pass
        if has_push:
            try:
                var p = msg_num(line, "push")
                if p >= 0.0 and p <= 2.0:
                    w.push = p
            except:
                pass
        if has_repulse:
            try:
                var rp = Int(msg_num(line, "repulse"))
                if rp >= 0 and rp <= 40:
                    w.repulse_max = rp
            except:
                pass
        if has_fanout:
            try:
                var fo = Int(msg_num(line, "fanout"))
                if fo >= 1 and fo <= 8:
                    w.fanout = fo
            except:
                pass
        if has_judges:
            try:
                var nj = Int(msg_num(line, "judges"))
                if nj >= 1 and nj <= 5:
                    w.judges_n = nj
            except:
                pass
        if has_budget:
            try:
                var cb = Int(msg_num(line, "call_budget"))
                if cb >= 0:
                    w.budget = cb
            except:
                pass
        if has_addr:
            try:
                var ar = Int(msg_num(line, "add_r"))
                if ar > 0:
                    w.r_calls += ar
            except:
                pass
        if has_adde:
            try:
                var ae = Int(msg_num(line, "add_e"))
                if ae > 0:
                    w.e_calls += ae
            except:
                pass
    elif name == "setmodel":
        try:
            var m = msg_str(line, "model")
            if m == "":
                m = cfg.model
            w.mcfg.model = m
            w.meta = w.mcfg.base_url != "" and w.mcfg.api_key != "" and w.mcfg.model != ""
        except:
            pass
    elif name == "auto":
        try:
            var e = Int(msg_num(line, "enabled"))
            w.auto = e != 0
        except:
            pass
    elif name == "memory":
        try:
            var gt = List[String]()
            msg_strs(line, "texts", gt)
            if len(gt) > 0:
                var keep = List[String]()
                var start_t = 0
                if len(gt) > 60:
                    start_t = len(gt) - 60
                for i in range(start_t, len(gt)):
                    keep.append(gt[i])
                w.gtexts = keep.copy()
        except:
            pass
        try:
            var gv = List[List[Float64]]()
            msg_vecs(line, "vecs", gv)
            if len(gv) > 0:
                var keepv = List[List[Float64]]()
                var start_v = 0
                if len(gv) > 32:
                    start_v = len(gv) - 32
                for i in range(start_v, len(gv)):
                    keepv.append(gv[i].copy())
                w.gvecs = keepv.copy()
        except:
            pass
        try:
            var gm = List[Float64]()
            msg_vec(line, "gold", gm)
            if len(gm) > 0:
                w.ggold = gm.copy()
        except:
            pass
    else:
        _ = w_emit(
            w, status_json(w.bid, w.b.step, w.b.best, "order error: unknown name " + name)
        )


def w_cap_obuf(mut w: WLoop):
    """Same 1MB cap as the server read buffer: complete lines are
    consumed by the caller, so any remainder is a partial tail. Past
    1MB it is a runaway line: drop it (never fuse it) and say so."""
    if w.obuf.byte_length() > 1048576:
        w.obuf = String()
        _ = w_emit(
            w,
            status_json(
                w.bid,
                w.b.step,
                w.b.best,
                "order error: order buffer over 1MB, dropped partial line",
            ),
        )


def w_drain_orders(mut w: WLoop, cfg: ExpCfg) -> Bool:
    """Process pending order lines. False when the server is gone."""
    while poll_one(w.rfd, 0) == 1:
        var chunk = pipe_read_some(w.rfd, 65536)
        if chunk == "":
            return False
        w.obuf += chunk
        # Cursor split: one slice per line, one trim at the end.
        # A restart order may clear w.obuf mid-chunk; the guard after
        # w_apply_order drops the rest, as the old code did.
        var cur = 0
        while True:
            var nl = buf_find_nl(w.obuf, cur)
            if nl < 0:
                break
            var raw = String(w.obuf[byte=cur:nl])
            cur = nl + 1
            var line = String(raw.strip())
            if line == "":
                continue
            w_apply_order(w, cfg, line)
            if w.obuf.byte_length() < cur:
                # A restart order cleared the buffer mid-chunk; drop
                # the rest of the chunk, as the old code did.
                cur = 0
                break
        if cur > 0:
            var tail = String(w.obuf[byte=cur:])
            w.obuf = tail
        w_cap_obuf(w)
    return True


def w_wait_paused(mut w: WLoop, cfg: ExpCfg) -> Bool:
    while w.paused:
        if poll_one(w.rfd, 500) != 1:
            continue
        var chunk = pipe_read_some(w.rfd, 65536)
        if chunk == "":
            return False
        w.obuf += chunk
        # Cursor split: one slice per line, one trim at the end.
        var cur = 0
        while True:
            var nl = buf_find_nl(w.obuf, cur)
            if nl < 0:
                break
            var raw = String(w.obuf[byte=cur:nl])
            cur = nl + 1
            var line = String(raw.strip())
            if line == "":
                continue
            w_apply_order(w, cfg, line)
            if w.obuf.byte_length() < cur:
                # A restart order cleared the buffer mid-chunk; drop
                # the rest of the chunk, as the old code did.
                cur = 0
                break
        if cur > 0:
            var tail = String(w.obuf[byte=cur:])
            w.obuf = tail
        w_cap_obuf(w)
    return True


def w_embed_text(mut w: WLoop, text: String, mut out: List[Float64]) -> Bool:
    if w_budget_hit(w):
        return False
    # The embed backend is independent of the chat backend: sim chat
    # with a local embed endpoint yields true semantic vecs for free.
    if w.mcfg.embed_model != "" and not w.embed_fallback:
        var texts = List[String]()
        texts.append(embed_input(w.mcfg.embed_doc_prefix, text))
        var tmp = List[List[Float64]]()
        var t0 = mono_ms()
        var err = meta_embed(w.mcfg, texts, tmp)
        var t1 = mono_ms()
        if w.mcfg.embed_model != "":
            w.e_calls += 1
            if t0 >= 0 and t1 >= t0:
                w.e_ms += t1 - t0
        if err == "" and len(tmp) == 1:
            var v = tmp[0].copy()
            if len(v) > 0:
                if w.dim == 0:
                    w.dim = len(v)
                if len(v) == w.dim:
                    for i in range(len(v)):
                        out.append(v[i])
                    w.embed_fails = 0
                    return True
        if w.mcfg.embed_model != "":
            w.embed_fails += 1
            if w.embed_fails >= 3:
                w.embed_fallback = True
                w.embed_fails = 0
                _ = w_emit(
                    w,
                    status_json(
                        w.bid,
                        w.b.step,
                        w.b.best,
                        "embed fallback to hash-BOW after 3 failures",
                    ),
                )
            return False
    var t0 = mono_ms()
    sim_embed(text, out)
    var t1 = mono_ms()
    w.e_calls += 1
    if t0 >= 0 and t1 >= t0:
        w.e_ms += t1 - t0
    if w.dim == 0:
        w.dim = len(out)
    if w.embed_fallback:
        return len(out) > 0
    return len(out) == w.dim


def w_call(mut w: WLoop, sys: String, user: String, temp: Float64) -> GenOut:
    """One metered Responses call: accumulates calls/ms/tokens."""
    if w_budget_hit(w):
        return GenOut(False, "", "budget", 0, 0, 0)
    var r = meta_respond(w.mcfg, sys, user, temp)
    w.r_calls += 1
    w.r_ms += r.ms
    w.tok_in += r.in_tok
    w.tok_out += r.out_tok
    return GenOut(r.ok, r.text, r.err, r.ms, r.in_tok, r.out_tok)


def fanout_picks(
    scores: List[Float64], vecs: List[List[Float64]], best: Int
) -> List[Int]:
    """Runner-up candidate indices worth pursuing as fanout branches.

    Score-descending, excluding best: within half of best's score (margin
    keeps weak splits home) and cosine-dissimilar to everything already
    picked (dup bar keeps near-clones home). Pure: unit-testable.
    """
    var out = List[Int]()
    if best < 0 or best >= len(scores) or len(vecs) != len(scores):
        return out.copy()
    var bar = scores[best] * 0.5
    if bar < 0.0:
        bar = 0.0
    var order = List[Int]()
    for i in range(len(scores)):
        if i != best:
            order.append(i)
    for i in range(1, len(order)):
        var key = order[i]
        var j = i - 1
        while j >= 0 and scores[order[j]] < scores[key]:
            order[j + 1] = order[j]
            j -= 1
        order[j + 1] = key
    var chosen = List[List[Float64]]()
    chosen.append(vecs[best].copy())
    for k in range(len(order)):
        var idx = order[k]
        if scores[idx] < bar:
            break
        var dup = False
        for c in range(len(chosen)):
            if vcos(vecs[idx], chosen[c]) > 0.92:
                dup = True
                break
        if dup:
            continue
        out.append(idx)
        chosen.append(vecs[idx].copy())
    return out.copy()


def w_gen_candidate(
    mut w: WLoop, sys: String, user: String, step: Int, cand: Int
) -> GenOut:
    """One candidate generation. Sim varies the seed per candidate so
    fanout samples differ; candidate 0 uses the base seed."""
    if not w.meta:
        return GenOut(
            True,
            sim_gen_text(
                w.concept,
                w.location,
                w.persona,
                w.bid,
                step,
                w.temp,
                w.seed + cand * 7919,
            ),
            "",
            0,
            0,
            0,
        )
    return w_call(w, sys, user, w.temp)


def w_note_fail(mut w: WLoop, step: Int, best: Float64, err: String) -> Bool:
    """Count a backend failure. True means keep going."""
    w.fails += 1
    if w.fails > 8:
        _ = w_emit(w, done_json(w.bid, step, best, "backend-error"))
        return False
    _ = w_emit(w, status_json(w.bid, step, best, err))
    msleep(2000)
    return True


def w_camp(mut w: WLoop, cfg: ExpCfg):
    var recent = List[String]()
    var start = len(w.jtexts) - 3
    if start < 0:
        start = 0
    for i in range(start, len(w.jtexts)):
        recent.append(w.jtexts[i])
    if w.meta and len(recent) > 0:
        var r = w_call(w, camp_sys(), camp_user(w.concept, recent), 0.5)
        var note = r.text if r.ok else String("field synthesis unavailable")
        if note.byte_length() > 300:
            var nb = note.as_bytes()
            var cut = 300
            while cut > 0 and (Int(nb[cut]) & 0xC0) == 0x80:
                cut -= 1
            var nhead = String(note[byte=0:cut])
            note = nhead
        _ = w_emit(w, status_json(w.bid, w.b.step, w.b.best, "camp: " + note))
    else:
        _ = w_emit(w, status_json(w.bid, w.b.step, w.b.best, "camp: energy renewed"))
    w.energy = 100


def w_next_seed(mut w: WLoop, cfg: ExpCfg, response: String) -> String:
    if not w.meta:
        var s = sim_seed(response, w.jtexts)
        if seed_ok(s):
            return s
        return String("untried latent mechanism")
    var r = w_call(w, extract_sys(), extract_user(w.concept, response), 0.3)
    var raw = r.text if r.ok else String("")
    var s = clean_seed(raw)
    if seed_ok(s):
        return s
    var q = w_call(
        w, synth_sys(), synth_user(w.concept, persona_name(w.persona)), 0.9
    )
    var s2 = clean_seed(q.text if q.ok else String(""))
    if seed_ok(s2):
        return s2
    return String("untried latent mechanism")


def worker_main(
    bid: Int,
    run: Int,
    wfd: Int,
    rfd: Int,
    cfg: ExpCfg,
    start_loc: String,
    start_temp: Float64,
    start_seed: Int,
):
    ignore_sigpipe()
    var w = WLoop(bid, run, wfd, rfd, cfg)
    w.location = start_loc
    w.temp = start_temp
    w.seed = start_seed
    if w.meta:
        var sv = List[Float64]()
        if w_embed_text(w, cfg.concept, sv):
            w.start_vec = sv.copy()
    while True:
        if not w_drain_orders(w, cfg):
            break
        if w.paused:
            if not w_wait_paused(w, cfg):
                break
            continue
        if w_budget_hit(w):
            _ = w_emit(w, done_json(w.bid, w.b.step, w.b.best, "budget"))
            break
        if w.energy <= 0:
            w_camp(w, cfg)
        if w.meta:
            var ro = repulse_words(w.jtexts)
            var rg = repulse_words(w.gtexts)
            var full = union_words(ro, rg)
            w.repulse = repulse_cap(full, w.repulse_max)
        var loc = w.location
        if w.loc_key != loc:
            var lv0 = List[Float64]()
            if w_embed_text(w, loc, lv0):
                w.loc_vec = lv0.copy()
                w.loc_key = loc
        var sys_p = craft_sys(w.concept, persona_name(w.persona))
        var user_p = craft_user(w.concept, loc, w.contrast, w.repulse)
        var nfan = w.fanout
        if nfan < 1:
            nfan = 1
        if nfan > 8:
            nfan = 8
        var text = String()
        var vec = List[Float64]()
        var topo = TopoRes()
        var tok = False
        var nov = 0.5
        var base = 0.0
        var best_score = -1.0
        var best_idx = -1
        var ctexts = List[String]()
        var cvecs = List[List[Float64]]()
        var cscores = List[Float64]()
        var cnovs = List[Float64]()
        var ccohs = List[Float64]()
        var last_err = String("gen failed")
        var gone = False
        var budgeted = False
        for c in range(nfan):
            # Bounded order drain between candidates: a pause or tune
            # lands within one generation instead of after the fanout.
            if not w_drain_orders(w, cfg):
                gone = True
                break
            if w_budget_hit(w):
                _ = w_emit(w, done_json(w.bid, w.b.step, w.b.best, "budget"))
                budgeted = True
                break
            var g = w_gen_candidate(w, sys_p, user_p, w.b.step, c)
            if not g.ok:
                if g.err == "budget" or w_budget_hit(w):
                    _ = w_emit(w, done_json(w.bid, w.b.step, w.b.best, "budget"))
                    budgeted = True
                    break
                last_err = g.err
                continue
            var ctext = strip_filler(g.text)
            var cvec = List[Float64]()
            if not w_embed_text(w, ctext, cvec):
                if w_budget_hit(w):
                    _ = w_emit(w, done_json(w.bid, w.b.step, w.b.best, "budget"))
                    budgeted = True
                    break
                last_err = String("embed failed")
                continue
            var cpts = List[List[Float64]]()
            for i in range(len(w.b.hist)):
                cpts.append(w.b.hist[i].copy())
            cpts.append(cvec.copy())
            var ctopo = TopoRes()
            var ctok = True
            try:
                ctopo = topo_compute(cpts)
            except:
                ctok = False
            var cnov = 0.5
            var kown = 1.0
            var lown = 1.0
            var has_own = False
            if len(w.b.hist) > 0:
                kown = kde_novelty(cvec, w.b.hist)
                lown = lexical_novelty(ctext, w.jtexts)
                has_own = True
            elif len(w.start_vec) > 0:
                var sv = List[List[Float64]]()
                sv.append(w.start_vec.copy())
                var st = List[String]()
                st.append(w.concept)
                kown = kde_novelty(cvec, sv)
                lown = lexical_novelty(ctext, st)
                has_own = True
            if has_own:
                var cn = ctopo.nov if ctok else 0.5
                var kk = kown
                var kg = w_global_kde(cvec, w.gvecs)
                if kg < kk:
                    kk = kg
                var ll = lown
                var lg = w_global_lex(ctext, w.gtexts)
                if lg < ll:
                    ll = lg
                cnov = composite_novelty(kk, ll, cn)
            cnov = cnov * vein_repulse_factor(cvec, w.vvecs)
            var cbase = coherence_base(ctext, vcos(cvec, w.loc_vec))
            var cscore = cnov * round1(cbase)
            ctexts.append(ctext)
            cvecs.append(cvec.copy())
            cscores.append(cscore)
            cnovs.append(cnov)
            ccohs.append(round1(cbase))
            if cscore > best_score:
                best_score = cscore
                best_idx = len(ctexts) - 1
                text = ctext
                vec = cvec.copy()
                topo = ctopo.copy()
                tok = ctok
                nov = cnov
                base = cbase
        if gone:
            break
        if budgeted:
            break
        if best_score < 0.0:
            if not w_note_fail(w, w.b.step, w.b.best, last_err):
                break
            continue
        w.fails = 0
        if nov < 0.35:
            w.temp = w.temp + 0.08
            if w.temp > 1.25:
                w.temp = 1.25
            w.streak += 1
        elif nov > 0.65:
            w.temp = w.temp - 0.05
            if w.temp < 0.65:
                w.temp = 0.65
            w.streak = 0
        else:
            w.streak = 0
            if w.temp > 0.85:
                w.temp = w.temp - 0.03
                if w.temp < 0.85:
                    w.temp = 0.85
        var coh = round1(base)
        if nov >= w.wgold and w.meta:
            var nj = w.judges_n
            if nj < 1:
                nj = 1
            if nj > 5:
                nj = 5
            var votes = List[Float64]()
            for _ in range(nj):
                # Same bounded drain between judge votes.
                if not w_drain_orders(w, cfg):
                    gone = True
                    break
                if w_budget_hit(w):
                    _ = w_emit(w, done_json(w.bid, w.b.step, w.b.best, "budget"))
                    budgeted = True
                    break
                var jr = w_call(w, judge_sys(), judge_user(loc, text), 0.1)
                if jr.ok:
                    votes.append(parse_judge(jr.text))
                    w.judges += 1
                elif jr.err == "budget" or w_budget_hit(w):
                    _ = w_emit(w, done_json(w.bid, w.b.step, w.b.best, "budget"))
                    budgeted = True
                    break
            if gone:
                break
            if budgeted:
                break
            if len(votes) > 0:
                coh = blend_judge(base, median_vote(votes))
            else:
                coh = round1(base)
        var gold = is_gold(nov, coh, w.wgold)
        if gold:
            w.gold_v.append(vec.copy())
            w.temp = w.temp - 0.10
            if w.temp < 0.65:
                w.temp = 0.65
        branch_note(w.b, cfg, nov, coh / 10.0, gold, vec, text, 0.0, 0.0)
        w.jtexts.append(text)
        w.jnov.append(nov)
        w.jcoh.append(coh)
        w.locs.append(loc)
        if w.auto and w.b.step % 4 == 0 and len(w.jnov) >= 8:
            var reward = auto_delta(w.jnov)
            if w.auto_last >= 0 and w.auto_last < 4:
                var ac = w.auto_counts[w.auto_last]
                w.auto_vals[w.auto_last] = (
                    w.auto_vals[w.auto_last] * Float64(ac) + reward
                ) / Float64(ac + 1)
                w.auto_counts[w.auto_last] = ac + 1
            var arng = sim_stream(w.seed + 999983, w.bid, w.b.step)
            var act = auto_pick(w.auto_vals, w.auto_counts, arng.next_unit(), arng.pick(4))
            var nx = auto_apply(w.temp, w.push, act)
            w.temp = nx.temp
            w.push = nx.push
            w.auto_last = act
        var f = Finding(
            w.bid,
            w.b.step,
            nov,
            coh,
            0.0,
            0.0,
            0.0,
            gold,
            text,
            topo.b0,
            topo.b1,
            topo.b2,
            topo.cd,
            w.persona,
            w.temp,
            loc,
            "",
            w.run,
        )
        if not w_emit(w, finding_json(f, w.run)):
            break
        if not w_emit(w, vec_json(w.bid, w.b.step, w.run, vec)):
            _ = w_emit(w, status_json(w.bid, w.b.step, w.b.best, "emit error: vec failed"))
            break
        if not w_emit(
            w,
            tele_json(
                w.bid,
                w.run,
                w.b.step,
                w.temp,
                w.streak,
                w.persona,
                w.energy,
                topo.b0,
                topo.b1,
                topo.b2,
                topo.cd,
                topo.sheaf,
                topo.entropy,
                w.judges,
                w.r_calls,
                w.e_calls,
                w.r_ms,
                w.e_ms,
                w.tok_in,
                w.tok_out,
                w.push,
            ),
        ):
            _ = w_emit(w, status_json(w.bid, w.b.step, w.b.best, "emit error: tele failed"))
            break
        var seed = w_next_seed(w, cfg, text)
        var svec = List[Float64]()
        if w_embed_text(w, seed, svec):
            var comps = List[List[Float64]]()
            pca_subspace(w.b.hist, 3, comps)
            var ovec = List[Float64]()
            ortho_project(svec, comps, ovec)
            var tvec = List[Float64]()
            topo_steer(
                ovec,
                topo.cycle,
                tok and len(topo.cycle) == len(ovec),
                topo.void,
                tok and len(topo.void) == len(ovec),
                w.push,
                tvec,
            )
            var bvec = List[Float64]()
            var pu = List[List[Float64]]()
            for i in range(len(w.gold_v)):
                pu.append(w.gold_v[i].copy())
            if len(w.ggold) == len(tvec) and len(tvec) > 0:
                pu.append(w.ggold.copy())
            momentum_blend(tvec, pu, 0.25, bvec)
            var steer = bvec.copy()
            var vn = List[Float64]()
            if vein_nearest(bvec, w.vvecs, vn):
                var vp = List[List[Float64]]()
                vp.append(vn.copy())
                var ab = List[Float64]()
                momentum_blend(bvec, vp, 0.10, ab)
                steer = ab.copy()
            var cues = List[String]()
            contrast_themes(steer, w.b.hist, w.locs, 2, cues)
            w.contrast = cues.copy()
        if w.streak >= 3:
            w.streak = 0
            w.temp = 0.90
            w.persona = (w.persona + 1) % 16
            var pool = List[Finding]()
            for i in range(len(w.jtexts)):
                pool.append(
                    Finding(
                        w.bid,
                        i + 1,
                        w.jnov[i],
                        w.jcoh[i],
                        0.0,
                        0.0,
                        0.0,
                        False,
                        "",
                        0,
                        0,
                        0,
                        0.0,
                        0,
                        0.0,
                        "",
                        "",
                        w.run,
                    )
                )
            var pf = List[Int]()
            pareto(pool, pf)
            var base_loc = w.concept
            if len(pf) > 0 and pf[0] < len(w.locs):
                base_loc = w.locs[pf[0]]
            w.location = (
                base_loc + " (cross-mapped through " + persona_name(w.persona) + ")"
            )
        elif nov < 0.45 or w.b.step % 3 == 0:
            w.persona = (w.persona + 1) % 16
            w.location = seed + " [" + persona_name(w.persona) + "]"
        else:
            w.location = seed
        w.energy -= 34
        # Fanout pursue: runners-up worth covering become spawn requests
        # (server forks them subject to live/tick caps). Healthy parents
        # only: a half-plateaued branch multiplies stuck legs, so it keeps
        # best-of-N selection instead. Lines precede any done line below,
        # so the server sees the parent alive.
        if nfan > 1 and best_idx >= 0 and w.b.plateau * 2 < cfg.plateau_k:
            var picks = fanout_picks(cscores, cvecs, best_idx)
            for k in range(len(picks)):
                var ci = picks[k]
                if not w_emit(
                    w,
                    spawn_json(
                        w.bid,
                        w.b.step,
                        ctexts[ci],
                        cnovs[ci],
                        ccohs[ci],
                        cscores[ci],
                        w.temp,
                        w.persona,
                        w.mcfg.model,
                    ),
                ):
                    gone = True
                    break
            if gone:
                break
        var reason = String()
        if w_budget_hit(w):
            reason = String("budget")
        else:
            reason = branch_should_stop(w.b, cfg)
            if reason == "" and novelty_stationary(w.jnov):
                reason = String("converged")
        if reason != "":
            _ = w_emit(w, done_json(w.bid, w.b.step, w.b.best, reason))
            break
        if not w.meta:
            msleep(120)
    _ = close_fd(wfd)
    _ = close_fd(rfd)
    child_exit(0)
