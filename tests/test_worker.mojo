"""Tests for metamining.worker pure helpers + order handling + server ingestion."""

from std.testing import assert_equal, assert_true

from metamining.explorer import ExpCfg, Finding, tele_json
from metamining.json import (
    doc_at,
    doc_find,
    doc_len,
    doc_obool,
    doc_onum,
    doc_ostr,
    doc_root,
    doc_str,
    parse_json,
)
from metamining.libc import (
    close_fd,
    file_read_all,
    file_remove,
    file_write_all,
    ignore_sigpipe,
    mono_ms,
    pipe_fds,
    pipe_read_some,
    pipe_write_all,
    poll_one,
)
from metamining.linalg import vcos
from metamining.scoring import novelty_stationary
from metamining.server import (
    Server,
    Vein,
    Worker,
    journal_pareto,
    srv_control,
    srv_dominant_reason,
    srv_finding_push,
    srv_findings_json,
    srv_handle_line,
    srv_journals_json,
    srv_maybe_send_memory,
    srv_models_json,
    srv_models_should_refresh,
    srv_queue_json,
    srv_reap,
    srv_save_journal,
    srv_search_json,
    srv_send_order,
    srv_set_veins_error,
    srv_state_json,
    srv_vein_append,
    srv_veins_flush,
    veins_load_file,
    veins_save_file,
)
from metamining.sim import sim_embed
from metamining.worker import (
    WLoop,
    auto_apply,
    auto_argmax,
    auto_delta,
    auto_pick,
    branch_model_for,
    clean_seed,
    craft_sys,
    craft_user,
    fanout_picks,
    parse_models_list,
    persona_name,
    personas,
    repulse_cap,
    repulse_words,
    seed_ok,
    sim_seed,
    strip_filler,
    union_words,
    veins_load_vecs,
    w_apply_order,
    w_budget_hit,
    w_drain_orders,
    w_embed_text,
    w_global_kde,
    w_global_lex,
)


def test_personas() raises:
    var p = personas()
    assert_equal(len(p), 16)
    assert_equal(p[0], "Mechanistic Systems Biology & Network Medicine")
    assert_equal(p[15], "Biomimetic Energy Dynamics")
    assert_equal(persona_name(0), p[0])
    assert_equal(persona_name(-1), p[0])
    assert_equal(persona_name(16), p[0])
    print("personas ok")


def test_craft() raises:
    var sys = craft_sys("truth", "Lens X")
    assert_true(sys.find("truth") >= 0)
    assert_true(sys.find("Lens X") >= 0)
    var cues = List[String]()
    cues.append("cue one")
    cues.append("cue two")
    var rep = List[String]()
    rep.append("tapestry")
    var user = craft_user("truth", "front line", cues, rep)
    assert_true(user.find("front line") >= 0)
    assert_true(user.find("cue one") >= 0)
    assert_true(user.find("cue two") >= 0)
    assert_true(user.find("tapestry") >= 0)
    var bare = List[String]()
    var user2 = craft_user("truth", "front line", bare, bare)
    assert_true(user2.find("Orthogonally") < 0)
    assert_true(user2.find("Avoid these") < 0)
    print("craft ok")


def test_strip() raises:
    var sub = String(
        "This is a substantive paragraph with more than fifty characters indeed."
    )
    var text = String("tiny\n\n") + sub + " Let me know what you think?\n\ntail"
    assert_equal(strip_filler(text), sub)
    var noted = String(
        "(Note: this parenthetical aside is long enough to pass fifty characters "
        + "easily but must be skipped)\n\n"
    ) + sub
    assert_equal(strip_filler(noted), sub)
    var plain = String("just a short line")
    assert_equal(strip_filler(plain), plain)
    print("strip ok")


def test_seed() raises:
    assert_equal(clean_seed('  "Quantum foam lattice"  '), "Quantum foam lattice")
    assert_equal(clean_seed("Concept: resonant coupling cascade"), "resonant coupling cascade")
    assert_equal(
        clean_seed("The concept of: mycelial quorum sensing\nExtra line"),
        "mycelial quorum sensing",
    )
    assert_true(seed_ok("ok seed"))
    assert_true(not seed_ok("ab"))
    assert_true(not seed_ok("a__b__c__d__e_f"))
    assert_true(not seed_ok("no"))
    var j = List[String]()
    j.append("quantum foam lattice")
    assert_equal(
        sim_seed("quantum foam lattice vector", j), "vector quantum foam lattice"
    )
    var j2 = List[String]()
    assert_equal(sim_seed("quantum foam", j2), "quantum foam")
    print("seed ok")


def test_repulse() raises:
    var j = List[String]()
    for _ in range(10):
        j.append("alpha beta gamma delta")
    var r = repulse_words(j)
    assert_equal(len(r), 19)
    var has_alpha = False
    var has_tapestry = False
    for i in range(len(r)):
        if r[i] == "alpha":
            has_alpha = True
        if r[i] == "tapestry":
            has_tapestry = True
    assert_true(has_alpha)
    assert_true(has_tapestry)
    var j2 = List[String]()
    j2.append("one two three")
    var r2 = repulse_words(j2)
    assert_equal(len(r2), 15)
    print("repulse ok")


def test_orders() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var w = WLoop(0, 1, -1, -1, cfg)
    assert_equal(w.repulse_max, 30)
    assert_equal(w.fanout, 1)
    assert_equal(w.judges_n, 1)
    assert_true(not w.auto)
    assert_equal(w.mcfg.model, "sim")
    w_apply_order(w, cfg, '{"t":"order","name":"pause"}')
    assert_true(w.paused)
    w_apply_order(w, cfg, '{"t":"order","name":"resume"}')
    assert_true(not w.paused)
    w_apply_order(w, cfg, '{"t":"order","name":"warp"}')
    assert_equal(w.streak, 3)
    w_apply_order(w, cfg, '{"t":"order","name":"teleport","target":"X"}')
    assert_equal(w.location, "X")
    assert_equal(w.streak, 0)
    w_apply_order(w, cfg, '{"t":"order","name":"persona","idx":5}')
    assert_equal(w.persona, 5)
    w_apply_order(w, cfg, '{"t":"order","name":"persona","idx":99}')
    assert_equal(w.persona, 5)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","temp":1.2,"gold":0.8,"push":1.1}')
    assert_equal(w.temp, 1.2)
    assert_equal(w.wgold, 0.8)
    assert_equal(w.push, 1.1)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","temp":9.9}')
    assert_equal(w.temp, 1.2)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","repulse":12}')
    assert_equal(w.repulse_max, 12)
    assert_equal(w.temp, 1.2)
    assert_equal(w.wgold, 0.8)
    assert_equal(w.push, 1.1)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","repulse":99}')
    assert_equal(w.repulse_max, 12)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","repulse":-1}')
    assert_equal(w.repulse_max, 12)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","repulse":0}')
    assert_equal(w.repulse_max, 0)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","fanout":4,"judges":3}')
    assert_equal(w.fanout, 4)
    assert_equal(w.judges_n, 3)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","fanout":9}')
    assert_equal(w.fanout, 4)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","fanout":0}')
    assert_equal(w.fanout, 4)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","judges":6}')
    assert_equal(w.judges_n, 3)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","judges":0}')
    assert_equal(w.judges_n, 3)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","fanout":8,"judges":5}')
    assert_equal(w.fanout, 8)
    assert_equal(w.judges_n, 5)
    w_apply_order(w, cfg, '{"t":"order","name":"setmodel","model":"mz"}')
    assert_equal(w.mcfg.model, "mz")
    w_apply_order(w, cfg, '{"t":"order","name":"setmodel","model":""}')
    assert_equal(w.mcfg.model, "sim")
    w_apply_order(w, cfg, '{"t":"order","name":"auto","enabled":1}')
    assert_true(w.auto)
    w_apply_order(w, cfg, '{"t":"order","name":"auto","enabled":0}')
    assert_true(not w.auto)
    w_apply_order(w, cfg, '{"t":"order","name":"setmodel","model":"mz"}')
    w_apply_order(w, cfg, '{"t":"order","name":"auto","enabled":1}')
    w.energy = 10
    w_apply_order(w, cfg, '{"t":"order","name":"restart"}')
    assert_equal(w.persona, 0)
    assert_equal(w.energy, 100)
    assert_equal(w.location, "concept")
    assert_equal(w.temp, 0.9)
    assert_equal(w.mcfg.model, "sim")
    assert_true(not w.auto)
    assert_equal(w.auto_last, -1)
    w_apply_order(w, cfg, "not json")
    w_apply_order(w, cfg, '{"t":"finding"}')
    w_apply_order(w, cfg, '{"t":"order","name":"bogus"}')
    assert_equal(w.energy, 100)
    print("orders ok")


def test_memory() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var w = WLoop(0, 1, -1, -1, cfg)
    assert_equal(w_global_lex("anything", w.gtexts), 1.0)
    var v = List[Float64]()
    v.append(1.0)
    v.append(0.0)
    assert_equal(w_global_kde(v, w.gvecs), 1.0)
    var a = List[String]()
    a.append("x")
    a.append("y")
    var b = List[String]()
    b.append("y")
    b.append("z")
    var u = union_words(a, b)
    assert_equal(len(u), 3)
    assert_equal(u[2], "z")
    w_apply_order(
        w,
        cfg,
        '{"t":"order","name":"memory","texts":["alpha alpha alpha gamma",'
        '"beta beta beta delta"],"vecs":[[0.5,0.5]],"gold":[1.0,0.0]}',
    )
    assert_equal(len(w.gtexts), 2)
    assert_equal(w.gtexts[0], "alpha alpha alpha gamma")
    assert_equal(len(w.gvecs), 1)
    assert_equal(w.gvecs[0][0], 0.5)
    assert_equal(len(w.ggold), 2)
    assert_true(w_global_lex("alpha beta", w.gtexts) < 0.5)
    assert_equal(w_global_lex("totally fresh words", w.gtexts), 1.0)
    var kg = w_global_kde(v, w.gvecs)
    assert_true(kg > 0.7 and kg < 0.8)
    var big = String('{"t":"order","name":"memory","texts":[')
    for i in range(70):
        if i > 0:
            big += ","
        big += '"w' + String(i) + '"'
    big += "]}"
    w_apply_order(w, cfg, big)
    assert_equal(len(w.gtexts), 60)
    assert_equal(w.gtexts[0], "w10")
    print("memory ok")


def test_repulse_cap() raises:
    var words = List[String]()
    words.append("a")
    words.append("b")
    words.append("c")
    var cut = repulse_cap(words, 2)
    assert_equal(len(cut), 2)
    assert_equal(cut[0], "a")
    assert_equal(cut[1], "b")
    assert_equal(len(repulse_cap(words, 0)), 0)
    assert_equal(len(repulse_cap(words, -1)), 0)
    assert_equal(len(repulse_cap(words, 40)), 3)
    print("repulse cap ok")


def test_converged_input() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var w = WLoop(0, 1, -1, -1, cfg)
    assert_true(not novelty_stationary(w.jnov))
    for _ in range(16):
        w.jnov.append(0.5)
    assert_true(novelty_stationary(w.jnov))
    print("converged input ok")


def test_vein_load() raises:
    var missing = List[List[Float64]]()
    veins_load_vecs("/nonexistent-dir-mm/veins.json", missing)
    assert_equal(len(missing), 0)
    assert_true(file_write_all("/tmp/mm_veins_bad.json", "not json") > 0)
    var bad = List[List[Float64]]()
    veins_load_vecs("/tmp/mm_veins_bad.json", bad)
    assert_equal(len(bad), 0)
    assert_true(file_write_all("/tmp/mm_veins_novec.json", '{"veins":[]}') > 0)
    var novec = List[List[Float64]]()
    veins_load_vecs("/tmp/mm_veins_novec.json", novec)
    assert_equal(len(novec), 0)
    var raw = '{"veins":[{"id":1,"vec":[0.5,0.5]},{"id":2,"vec":[]},{"id":3}]}'
    assert_true(file_write_all("/tmp/mm_veins_ok.json", raw) > 0)
    var got = List[List[Float64]]()
    veins_load_vecs("/tmp/mm_veins_ok.json", got)
    assert_equal(len(got), 1)
    assert_equal(len(got[0]), 2)
    assert_equal(got[0][0], 0.5)
    print("vein load ok")


def test_models() raises:
    var e = parse_models_list("")
    assert_equal(len(e), 0)
    var b = parse_models_list("   ")
    assert_equal(len(b), 0)
    var m = parse_models_list("ma, mb ,,mc")
    assert_equal(len(m), 4)
    assert_equal(m[0], "ma")
    assert_equal(m[1], "mb")
    assert_equal(m[2], "")
    assert_equal(m[3], "mc")
    assert_equal(branch_model_for("d", e, 0), "d")
    assert_equal(branch_model_for("d", b, 5), "d")
    assert_equal(branch_model_for("d", m, 0), "ma")
    assert_equal(branch_model_for("d", m, 1), "mb")
    assert_equal(branch_model_for("d", m, 2), "d")
    assert_equal(branch_model_for("d", m, 3), "mc")
    assert_equal(branch_model_for("d", m, 4), "ma")
    assert_equal(branch_model_for("d", m, 6), "d")
    assert_equal(branch_model_for("d", m, 7), "mc")
    print("models ok")


def test_auto_bandit() raises:
    var short = List[Float64]()
    short.append(0.5)
    assert_equal(auto_delta(short), 0.0)
    var s = List[Float64]()
    for _ in range(4):
        s.append(0.2)
    for _ in range(4):
        s.append(0.6)
    var d = auto_delta(s)
    assert_true(d > 0.39 and d < 0.41)
    var flat = List[Float64]()
    for _ in range(10):
        flat.append(0.5)
    assert_equal(auto_delta(flat), 0.0)
    var vals = List[Float64]()
    var counts = List[Int]()
    for _ in range(4):
        vals.append(0.0)
        counts.append(0)
    assert_equal(auto_argmax(vals, counts), 0)
    counts[0] = 2
    vals[0] = 0.1
    assert_equal(auto_argmax(vals, counts), 1)
    counts[1] = 1
    vals[1] = 0.5
    counts[2] = 3
    vals[2] = 0.3
    counts[3] = 1
    vals[3] = 0.4
    assert_equal(auto_argmax(vals, counts), 1)
    assert_equal(auto_pick(vals, counts, 0.9, 2), 1)
    assert_equal(auto_pick(vals, counts, 0.05, 2), 2)
    assert_equal(auto_pick(vals, counts, 0.19, 7), 3)
    var up = auto_apply(1.0, 1.0, 0)
    assert_true(up.temp > 1.04 and up.temp < 1.06)
    assert_equal(up.push, 1.0)
    var dn = auto_apply(1.0, 1.0, 3)
    assert_equal(dn.temp, 1.0)
    assert_true(dn.push > 0.94 and dn.push < 0.96)
    assert_equal(auto_apply(1.29, 0.9, 0).temp, 1.3)
    assert_equal(auto_apply(0.51, 0.9, 1).temp, 0.5)
    assert_equal(auto_apply(1.3, 0.9, 0).temp, 1.3)
    assert_equal(auto_apply(0.5, 0.9, 1).temp, 0.5)
    assert_equal(auto_apply(0.9, 0.01, 3).push, 0.0)
    assert_equal(auto_apply(0.9, 1.99, 2).push, 2.0)
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    cfg.auto = 1
    var w = WLoop(3, 1, -1, -1, cfg)
    assert_true(w.auto)
    assert_equal(w.auto_last, -1)
    assert_equal(len(w.auto_vals), 4)
    assert_equal(len(w.auto_counts), 4)
    print("auto bandit ok")


def test_srv_handle_sick() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.workers.append(Worker(0, -1, -1, -1))
    assert_true(not srv.workers[0].sick)
    for _ in range(19):
        srv_handle_line(srv, 0, "garbage{{{")
    assert_true(not srv.workers[0].sick)
    assert_equal(srv.workers[0].line_fails, 19)
    srv_handle_line(srv, 0, "garbage{{{")
    assert_true(srv.workers[0].sick)
    assert_equal(srv.workers[0].line_fails, 20)
    assert_true(srv_state_json(srv).find('"sick":true') >= 0)
    var saw_fail = False
    var saw_sick = False
    for i in range(len(srv.logs)):
        if srv.logs[i].find("line decode failed") >= 0 and srv.logs[i].find(
            "worker 0"
        ) >= 0:
            saw_fail = True
        if srv.logs[i].find("marked sick") >= 0:
            saw_sick = True
    assert_true(saw_fail)
    assert_true(saw_sick)
    var tele = tele_json(
        0, 0, 1, 0.9, 0, 0, 100, 1, 0, 0, 1.0, 0.0, 0.0, 0, 0, 0, 0, 0, 0, 0, 0.9
    )
    srv_handle_line(srv, 0, tele)
    assert_equal(srv.workers[0].line_fails, 0)
    assert_true(srv.workers[0].sick)
    assert_equal(srv.workers[0].energy, 100)
    var long = String("x")
    for _ in range(200):
        long += "A"
    srv_handle_line(srv, 0, long)
    assert_true(srv.logs[len(srv.logs) - 1].byte_length() < 200)
    print("srv handle sick ok")


def test_srv_handle_clamp() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.workers.append(Worker(0, -1, -1, -1))
    srv_handle_line(
        srv,
        0,
        '{"t":"tele","branch":0,"step":1,"temp":1e999,"streak":1e999,'
        '"persona":0,"energy":100,"b0":1,"b1":0,"b2":0,"cd":1.0,'
        '"sheaf":0.0,"entropy":0.0,"judges":0,"r_calls":0,"e_calls":0,'
        '"r_ms":0,"e_ms":0,"tok_in":0,"tok_out":0}',
    )
    assert_equal(srv.workers[0].line_fails, 0)
    assert_equal(srv.workers[0].temp, 0.0)
    assert_equal(srv.workers[0].streak, 0)
    assert_equal(srv.workers[0].energy, 100)
    assert_true(srv.logs[len(srv.logs) - 1].find("non-finite clamped") >= 0)
    srv_handle_line(
        srv,
        0,
        '{"t":"finding","branch":0,"step":1,"novelty":1e999,'
        '"coherence":8.0,"text":"poison"}',
    )
    assert_equal(srv.workers[0].line_fails, 1)
    assert_equal(len(srv.findings), 0)
    srv_handle_line(srv, 0, '{"t":"status","step":3,"best":0.5,"reason":"ok"}')
    assert_equal(srv.workers[0].line_fails, 0)
    assert_equal(srv.workers[0].reason, "ok")
    print("srv handle clamp ok")


def test_veins_errors() raises:
    var out = List[Vein]()
    var err = String()
    assert_equal(veins_load_file("/tmp/mm_f2_nope/veins.json", out, err), 1)
    assert_equal(len(out), 0)
    assert_equal(err, "")
    assert_true(file_write_all("/tmp/mm_f2_veins_bad.json", "not json") > 0)
    var out2 = List[Vein]()
    var err2 = String()
    _ = veins_load_file("/tmp/mm_f2_veins_bad.json", out2, err2)
    assert_true(err2.find("bad json") >= 0)
    assert_true(file_write_all("/tmp/mm_f2_veins_shape.json", '{"x":1}') > 0)
    var out3 = List[Vein]()
    var err3 = String()
    _ = veins_load_file("/tmp/mm_f2_veins_shape.json", out3, err3)
    assert_true(err3.find("no veins") >= 0)
    var raw = (
        '{"veins":[{"id":1,"text":"t","novelty":1e999,"coherence":0.5,'
        '"vec":[1e999,0.5],"branch":0,"step":1,"run":1,"src":"s","created":1}]}'
    )
    assert_true(file_write_all("/tmp/mm_f2_veins_inf.json", raw) > 0)
    var out4 = List[Vein]()
    var err4 = String()
    assert_equal(veins_load_file("/tmp/mm_f2_veins_inf.json", out4, err4), 2)
    assert_equal(len(out4), 1)
    assert_equal(out4[0].nov, 0.0)
    assert_equal(out4[0].coh, 0.5)
    assert_equal(len(out4[0].vec), 2)
    assert_equal(out4[0].vec[0], 0.0)
    assert_equal(out4[0].vec[1], 0.5)
    assert_true(err4.find("clamped") >= 0)
    print("veins errors ok")


def test_veins_error_state() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    assert_equal(srv.veins_error, "")
    assert_true(srv_state_json(srv).find('"veins_error":""') >= 0)
    var n0 = len(srv.logs)
    srv_set_veins_error(srv, "probe failure")
    assert_equal(srv.veins_error, "probe failure")
    assert_equal(len(srv.logs), n0 + 1)
    assert_true(srv.logs[len(srv.logs) - 1].find("probe failure") >= 0)
    srv_set_veins_error(srv, "probe failure")
    assert_equal(len(srv.logs), n0 + 1)
    srv_set_veins_error(srv, String())
    assert_equal(srv.veins_error, "")
    assert_equal(len(srv.logs), n0 + 2)
    srv.veins_error = "stale probe"
    veins_save_file(srv)
    assert_equal(srv.veins_error, "")
    assert_true(srv.logs[len(srv.logs) - 1].find("cleared") >= 0)
    print("veins error state ok")


def test_journals_corrupt() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var probe = String("journals/journal_19990101_000000_f2probe.json")
    assert_true(file_write_all(probe, "not json {") > 0)
    # Hermetic: the suite must pass on an empty journals/ dir, so plant
    # the one valid file the ok:true assertion needs (and remove both).
    var good = String("journals/journal_19990101_000001_f2probe.json")
    assert_true(file_write_all(good, '{"starting_concept":"ok probe"}') > 0)
    var body = srv_journals_json(srv)
    _ = file_remove(probe)
    _ = file_remove(good)
    assert_true(body.find('"ok":true') >= 0)
    var d = parse_json(body)
    var arr = doc_find(d, doc_root(d), "journals")
    var found = False
    for i in range(doc_len(d, arr)):
        var it = doc_at(d, arr, i)
        if doc_ostr(d, it, "filename") == "journal_19990101_000000_f2probe.json":
            found = (
                doc_find(d, it, "ok") >= 0
                and not doc_obool(d, it, "ok")
                and doc_ostr(d, it, "error") != ""
            )
    assert_true(found)
    print("journals corrupt ok")


def test_search_skipped() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var probe = String("journals/journal_19990101_000000_f2probe.json")
    assert_true(file_write_all(probe, "not json {") > 0)
    var body = srv_search_json(srv, "zzzqqq-nomatch-f2", 5)
    _ = file_remove(probe)
    var d = parse_json(body)
    var r = doc_root(d)
    assert_true(doc_find(d, r, "skipped") >= 0)
    assert_true(Int(doc_onum(d, r, "skipped")) >= 1)
    print("search skipped ok")


def test_control_bad_body() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    assert_true(srv_control(srv, "{bad json").find("400") >= 0)
    assert_true(srv_control(srv, '{"action":"stop"} trailing').find("400") >= 0)
    assert_true(srv_control(srv, "hello").find("400") >= 0)
    print("control bad body ok")


def test_order_decode_notes() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var pair = pipe_fds()
    assert_true(pair.ok)
    var w = WLoop(0, 1, pair.write_fd, -1, cfg)
    w_apply_order(w, cfg, "not json")
    assert_equal(poll_one(pair.read_fd, 1000), 1)
    var note = pipe_read_some(pair.read_fd, 4096)
    assert_true(note.find('"t":"status"') >= 0)
    assert_true(note.find("order error") >= 0)
    w_apply_order(w, cfg, '{"t":"finding"}')
    assert_equal(poll_one(pair.read_fd, 1000), 1)
    assert_true(pipe_read_some(pair.read_fd, 4096).find("order error") >= 0)
    w_apply_order(w, cfg, '{"t":"order","name":"bogus"}')
    assert_equal(poll_one(pair.read_fd, 1000), 1)
    assert_true(pipe_read_some(pair.read_fd, 4096).find("order error") >= 0)
    w_apply_order(w, cfg, '{"t":"order","name":"pause"}')
    assert_true(w.paused)
    assert_equal(poll_one(pair.read_fd, 200), 0)
    _ = close_fd(pair.read_fd)
    _ = close_fd(pair.write_fd)
    print("order decode notes ok")


def test_obuf_cap() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var pair = pipe_fds()
    assert_true(pair.ok)
    var w = WLoop(0, 1, -1, pair.read_fd, cfg)
    var cell = String("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    var chunk = String()
    for _ in range(1024):
        chunk += cell
    assert_equal(chunk.byte_length(), 65536)
    for _ in range(17):
        assert_true(pipe_write_all(pair.write_fd, chunk) > 0)
        assert_true(w_drain_orders(w, cfg))
    assert_equal(w.obuf, "")
    assert_true(pipe_write_all(pair.write_fd, '{"t":"order","name":"pause"}\n') > 0)
    assert_true(w_drain_orders(w, cfg))
    assert_true(w.paused)
    _ = close_fd(pair.read_fd)
    _ = close_fd(pair.write_fd)
    print("obuf cap ok")


def test_run_validation() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.run_id = 1
    srv.workers.append(Worker(0, -1, -1, -1))
    assert_equal(srv.run_drops, 0)
    srv_handle_line(
        srv,
        0,
        '{"t":"finding","run":2,"branch":0,"step":1,"novelty":0.5,'
        '"coherence":8.0,"text":"stale"}',
    )
    assert_equal(len(srv.findings), 0)
    assert_equal(srv.run_drops, 1)
    assert_true(srv.logs[len(srv.logs) - 1].find("dropped stale finding") >= 0)
    srv_handle_line(
        srv,
        0,
        '{"t":"finding","run":1,"branch":0,"step":1,"novelty":0.5,'
        '"coherence":8.0,"text":"fresh"}',
    )
    assert_equal(len(srv.findings), 1)
    assert_equal(srv.run_drops, 1)
    srv_handle_line(
        srv, 0, '{"t":"vec","run":2,"branch":0,"step":1,"vec":[0.5,0.5]}'
    )
    assert_equal(srv.run_drops, 2)
    assert_equal(len(srv.vecs[0]), 0)
    srv_handle_line(
        srv, 0, '{"t":"vec","run":1,"branch":0,"step":1,"vec":[0.5,0.5]}'
    )
    assert_equal(srv.run_drops, 2)
    assert_equal(len(srv.vecs[0]), 2)
    var stale_tele = tele_json(
        0, 2, 9, 0.9, 0, 0, 100, 1, 0, 0, 1.0, 0.0, 0.0, 0, 0, 0, 0, 0, 0, 0, 0.9
    )
    srv_handle_line(srv, 0, stale_tele)
    assert_equal(srv.run_drops, 3)
    assert_equal(srv.workers[0].step, 1)
    var fresh_tele = tele_json(
        0, 1, 9, 0.9, 0, 0, 100, 1, 0, 0, 1.0, 0.0, 0.0, 0, 0, 0, 0, 0, 0, 0, 1.2
    )
    srv_handle_line(srv, 0, fresh_tele)
    assert_equal(srv.run_drops, 3)
    assert_equal(srv.workers[0].step, 9)
    assert_true(srv_state_json(srv).find('"run_drops":3') >= 0)
    print("run validation ok")


def test_w_reset_persona() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var w = WLoop(3, 1, -1, -1, cfg)
    assert_equal(w.persona, 3)
    w.persona = 9
    w.push = 1.5
    w.temp = 1.1
    w.location = "drifted"
    w.start_vec.append(0.1)
    w.loc_vec.append(0.2)
    w.loc_key = "x"
    w.obuf = "junk"
    w_apply_order(w, cfg, '{"t":"order","name":"restart"}')
    assert_equal(w.persona, 3)
    assert_equal(w.push, 0.90)
    assert_equal(w.temp, 0.9)
    assert_equal(w.location, "concept")
    assert_equal(len(w.start_vec), 0)
    assert_equal(len(w.loc_vec), 0)
    assert_equal(w.loc_key, "")
    assert_equal(w.obuf, "")
    assert_equal(w.seed, 7)
    assert_equal(w.concept, "concept")
    assert_equal(w.bid, 3)
    assert_equal(w.run, 1)
    print("w reset persona ok")


def test_send_order_epipe() raises:
    ignore_sigpipe()
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var pair = pipe_fds()
    assert_true(pair.ok)
    _ = close_fd(pair.read_fd)
    var w = Worker(0, -1, -1, pair.write_fd)
    srv.workers.append(w^)
    assert_true(srv.workers[0].alive)
    srv_send_order(srv, 0, '{"t":"order","name":"pause"}')
    assert_true(not srv.workers[0].alive)
    assert_equal(srv.workers[0].wfd, -1)
    assert_true(srv.logs[len(srv.logs) - 1].find("order write failed") >= 0)
    print("send order epipe ok")


def test_reap_sigkill_grace() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var w = Worker(0, 99999999, -1, -1)
    w.alive = False
    w.term_at = mono_ms() - 5000
    srv.workers.append(w^)
    var n0 = len(srv.logs)
    srv_reap(srv)
    assert_equal(len(srv.logs), n0 + 1)
    assert_true(srv.logs[n0].find("SIGKILL") >= 0)
    assert_equal(srv.workers[0].term_at, 0)
    print("reap sigkill ok")


def test_setmodel_persists() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.workers.append(Worker(0, -1, -1, -1))
    srv.workers.append(Worker(1, -1, -1, -1))
    var r = srv_control(srv, '{"action":"setmodel","bid":1,"model":"mz"}')
    assert_true(r.find("200") >= 0)
    assert_equal(srv.workers[1].model, "mz")
    assert_equal(len(srv.branch_models), 2)
    assert_equal(srv.branch_models[0], "")
    assert_equal(srv.branch_models[1], "mz")
    print("setmodel persists ok")


def test_enqueue_snapshot() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var r = srv_control(
        srv,
        '{"action":"enqueue","concept":"snap","model":"mm","branches":2,'
        '"steps":9,"seed":42,"gold":0.5,"temp":1.1,"repulse":5,'
        '"fanout":3,"judges":2,"auto":1}',
    )
    assert_true(r.find("200") >= 0)
    assert_equal(len(srv.queue), 1)
    var q = srv.queue[0].copy()
    assert_equal(q.concept, "snap")
    assert_equal(q.model, "mm")
    assert_equal(q.seed, 42)
    assert_equal(q.gold, 0.5)
    assert_equal(q.temp, 1.1)
    assert_equal(q.repulse, 5)
    assert_equal(q.fanout, 3)
    assert_equal(q.judges, 2)
    assert_equal(q.auto, 1)
    var r2 = srv_control(srv, '{"action":"enqueue","concept":"snap2"}')
    assert_true(r2.find("200") >= 0)
    var q2 = srv.queue[1].copy()
    assert_equal(q2.seed, 7)
    assert_equal(q2.gold, 0.9)
    assert_equal(q2.temp, 0.9)
    assert_equal(q2.repulse, 30)
    assert_equal(q2.fanout, 1)
    assert_equal(q2.judges, 1)
    assert_equal(q2.auto, 0)
    assert_equal(q2.branches, 2)
    assert_equal(q2.steps, 100)
    var bad = srv_control(srv, '{"action":"enqueue","concept":"x","fanout":9}')
    assert_true(bad.find("400") >= 0)
    assert_equal(len(srv.queue), 2)
    var jq = srv_queue_json(srv)
    assert_true(jq.find('"seed":42') >= 0)
    assert_true(jq.find('"fanout":3') >= 0)
    assert_true(jq.find('"auto":1') >= 0)
    print("enqueue snapshot ok")


def test_cfg_push_worker() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    assert_equal(cfg.push, 0.90)
    cfg.push = 1.3
    var w = WLoop(1, 1, -1, -1, cfg)
    assert_equal(w.push, 1.3)
    w.push = 0.2
    w_apply_order(w, cfg, '{"t":"order","name":"restart"}')
    assert_equal(w.push, 1.3)
    print("cfg push worker ok")


def test_tune_persists() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var r = srv_control(
        srv, '{"action":"tune","temp":1.1,"gold":0.8,"push":1.2,"repulse":9}'
    )
    assert_true(r.find("200") >= 0)
    assert_equal(srv.cfg.temp, 1.1)
    assert_equal(srv.cfg.gold, 0.8)
    assert_equal(srv.cfg.push, 1.2)
    assert_equal(srv.cfg.repulse, 9)
    assert_true(srv_state_json(srv).find('"push":1.2') >= 0)
    var bad = srv_control(srv, '{"action":"tune","push":9.9}')
    assert_true(bad.find("400") >= 0)
    assert_equal(srv.cfg.push, 1.2)
    print("tune persists ok")


def test_tele_push() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.workers.append(Worker(0, -1, -1, -1))
    var line = tele_json(
        0, 0, 3, 0.9, 0, 0, 100, 1, 0, 0, 1.0, 0.0, 0.0, 0, 0, 0, 0, 0, 0, 0, 1.4
    )
    srv_handle_line(srv, 0, line)
    assert_equal(srv.workers[0].push, 1.4)
    assert_true(srv_state_json(srv).find('"push":1.4') >= 0)
    srv_handle_line(
        srv,
        0,
        '{"t":"tele","run":0,"branch":0,"step":4,"temp":0.9,"streak":0,'
        '"persona":0,"energy":100,"b0":1,"b1":0,"b2":0,"cd":1.0,'
        '"sheaf":0.0,"entropy":0.0,"judges":0,"r_calls":0,"e_calls":0,'
        '"r_ms":0,"e_ms":0,"tok_in":0,"tok_out":0}',
    )
    assert_equal(srv.workers[0].push, 0.0)
    assert_equal(srv.workers[0].line_fails, 0)
    print("tele push ok")


def _f5_finding(step: Int, text: String) -> Finding:
    return Finding(
        0,
        step,
        0.5,
        8.0,
        50.0,
        50.0,
        50.0,
        False,
        text,
        1,
        0,
        0,
        1.0,
        0,
        0.9,
        "loc",
        "src",
        0,
    )


def test_findings_cap() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    for i in range(8100):
        srv_finding_push(srv, _f5_finding(i + 1, "cap probe " + String(i)), 0)
    assert_true(len(srv.findings) <= 8000)
    assert_equal(srv.findings_base + len(srv.findings), 8100)
    assert_equal(srv.findings_base, 1001)
    assert_equal(len(srv.findings), 7099)
    assert_equal(len(srv.vecs), len(srv.findings))
    assert_equal(len(srv.aired), len(srv.findings))
    var end = srv_findings_json(srv, 8100, False, 500)
    var de = parse_json(end)
    assert_equal(Int(doc_onum(de, doc_root(de), "next")), 8100)
    assert_equal(doc_len(de, doc_find(de, doc_root(de), "items")), 0)
    var head = srv_findings_json(srv, 0, False, 1)
    var dh = parse_json(head)
    var items = doc_find(dh, doc_root(dh), "items")
    assert_equal(doc_len(dh, items), 1)
    assert_equal(doc_ostr(dh, doc_at(dh, items, 0), "text"), "cap probe 1001")
    assert_equal(Int(doc_onum(dh, doc_at(dh, items, 0), "step")), 1002)
    var stale = srv_findings_json(srv, 500, False, 1)
    var ds = parse_json(stale)
    var sitems = doc_find(ds, doc_root(ds), "items")
    assert_equal(doc_len(ds, sitems), 1)
    assert_equal(doc_ostr(ds, doc_at(ds, sitems, 0), "text"), "cap probe 1001")
    var tail = srv_findings_json(srv, 8099, False, 500)
    var dt = parse_json(tail)
    var titems = doc_find(dt, doc_root(dt), "items")
    assert_equal(doc_len(dt, titems), 1)
    assert_equal(doc_ostr(dt, doc_at(dt, titems, 0), "text"), "cap probe 8099")
    assert_true(srv_state_json(srv).find('"findings":8100') >= 0)
    print("findings cap ok")


def test_enqueue_cap() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    for i in range(100):
        var r = srv_control(srv, '{"action":"enqueue","concept":"cap ' + String(i) + '"}')
        assert_true(r.find("200") >= 0)
    assert_equal(len(srv.queue), 100)
    var full = srv_control(srv, '{"action":"enqueue","concept":"over"}')
    assert_true(full.find("400") >= 0)
    assert_true(full.find("queue full") >= 0)
    assert_equal(len(srv.queue), 100)
    var clr = srv_control(srv, '{"action":"clearqueue"}')
    assert_true(clr.find("200") >= 0)
    assert_equal(len(srv.queue), 0)
    var again = srv_control(srv, '{"action":"enqueue","concept":"after clear"}')
    assert_true(again.find("200") >= 0)
    assert_equal(len(srv.queue), 1)
    print("enqueue cap ok")


def test_journals_cache() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    assert_true(not srv.journals_cache_valid)
    var a = srv_journals_json(srv)
    assert_true(srv.journals_cache_valid)
    assert_true(a.find('"journals":[') >= 0)
    var b = srv_journals_json(srv)
    assert_equal(a, b)
    var probe = String("journals/journal_19990101_000000_f5probe.json")
    assert_true(
        file_write_all(probe, '{"starting_concept":"f5","entries":[]}') > 0
    )
    var c = srv_journals_json(srv)
    assert_true(c.find("f5probe") >= 0)
    assert_true(c != a)
    _ = file_remove(probe)
    var e = srv_journals_json(srv)
    assert_true(e.find("f5probe") < 0)
    assert_equal(e, a)
    print("journals cache ok")


def test_models_ttl() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.models.append("m1")
    var body = srv_models_json(srv)
    assert_true(body.find('"sim":true') >= 0)
    assert_true(body.find("m1") >= 0)
    assert_equal(srv.models_fetched_at, -1)
    assert_true(srv_models_should_refresh(srv, 1000))
    srv.cfg.endpoint = "https://ep.example"
    srv.cfg.api_key = "k1"
    srv.models_fetched_at = 1000
    srv.models_fetched_ep = "https://ep.example"
    srv.models_fetched_key = "k1"
    assert_true(not srv_models_should_refresh(srv, 1059))
    assert_true(srv_models_should_refresh(srv, 1060))
    srv.cfg.api_key = "k2"
    assert_true(srv_models_should_refresh(srv, 1001))
    srv.cfg.api_key = "k1"
    srv.cfg.endpoint = "https://other.example"
    assert_true(srv_models_should_refresh(srv, 1001))
    assert_true(srv_models_should_refresh(srv, -1))
    print("models ttl ok")


def test_veins_debounce() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var orig = file_read_all("veins/veins.json")
    assert_true(not srv.veins_dirty)
    var v1 = List[Float64]()
    v1.append(0.5)
    srv_vein_append(srv, _f5_finding(1, "f5 vein one"), v1)
    assert_true(not srv.veins_dirty)
    var after1 = file_read_all("veins/veins.json")
    assert_true(after1.find("f5 vein one") >= 0)
    var v2 = List[Float64]()
    v2.append(0.6)
    srv_vein_append(srv, _f5_finding(2, "f5 vein two"), v2)
    assert_true(srv.veins_dirty)
    assert_equal(file_read_all("veins/veins.json"), after1)
    srv_veins_flush(srv)
    assert_true(not srv.veins_dirty)
    assert_true(file_read_all("veins/veins.json").find("f5 vein two") >= 0)
    _ = file_write_all("veins/veins.json", orig)
    print("veins debounce ok")


def test_journal_stream_save() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    for i in range(600):
        srv_finding_push(srv, _f5_finding(i + 1, "stream entry " + String(i)), 1)
    var name = srv_save_journal(srv)
    assert_true(name.startswith("journal_"))
    assert_true(not srv.journals_cache_valid)
    var raw = file_read_all("journals/" + name)
    var d = parse_json(raw)
    assert_equal(doc_ostr(d, doc_root(d), "starting_concept"), "concept")
    var arr = doc_find(d, doc_root(d), "entries")
    assert_equal(doc_len(d, arr), 600)
    assert_equal(doc_ostr(d, doc_at(d, arr, 0), "text"), "stream entry 0")
    assert_equal(doc_ostr(d, doc_at(d, arr, 599), "text"), "stream entry 599")
    _ = file_remove("journals/" + name)
    print("journal stream save ok")


def test_call_budget() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    assert_equal(cfg.call_budget, 0)
    cfg.call_budget = 5
    var w = WLoop(0, 1, -1, -1, cfg)
    assert_equal(w.budget, 5)
    assert_true(not w_budget_hit(w))
    w.r_calls = 2
    w.e_calls = 2
    assert_true(not w_budget_hit(w))
    w.e_calls = 3
    assert_true(w_budget_hit(w))
    var cfg0 = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var w0 = WLoop(0, 1, -1, -1, cfg0)
    w0.r_calls = 1000
    w0.e_calls = 1000
    assert_true(not w_budget_hit(w0))
    w_apply_order(w, cfg, '{"t":"order","name":"tune","call_budget":9}')
    assert_equal(w.budget, 9)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","call_budget":-1}')
    assert_equal(w.budget, 9)
    w_apply_order(w, cfg, '{"t":"order","name":"restart"}')
    assert_equal(w.budget, 5)
    print("call budget ok")


def test_tune_budget() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var r = srv_control(srv, '{"action":"tune","call_budget":7}')
    assert_true(r.find("200") >= 0)
    assert_equal(srv.cfg.call_budget, 7)
    assert_true(srv_state_json(srv).find('"call_budget":7') >= 0)
    var bad = srv_control(srv, '{"action":"tune","call_budget":-1}')
    assert_true(bad.find("400") >= 0)
    assert_equal(srv.cfg.call_budget, 7)
    print("tune budget ok")


def test_fanout_picks() raises:
    var scores = List[Float64]()
    scores.append(1.0)
    scores.append(0.8)
    scores.append(0.3)
    scores.append(0.9)
    var v0 = List[Float64]()
    v0.append(1.0)
    v0.append(0.0)
    var v1 = List[Float64]()
    v1.append(0.0)
    v1.append(1.0)
    var v2 = List[Float64]()
    v2.append(0.0)
    v2.append(1.0)
    var v3 = List[Float64]()
    v3.append(1.0)
    v3.append(0.01)
    var vecs = List[List[Float64]]()
    vecs.append(v0.copy())
    vecs.append(v1.copy())
    vecs.append(v2.copy())
    vecs.append(v3.copy())
    var picks = fanout_picks(scores, vecs, 0)
    assert_equal(len(picks), 1)
    assert_equal(picks[0], 1)
    var bad = fanout_picks(scores, vecs, 9)
    assert_equal(len(bad), 0)
    print("fanout picks ok")


def test_tune_add_calls() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var w = WLoop(0, 1, -1, -1, cfg)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","add_r":7,"add_e":3}')
    assert_equal(w.r_calls, 7)
    assert_equal(w.e_calls, 3)
    w_apply_order(w, cfg, '{"t":"order","name":"tune","add_r":-5,"add_e":0}')
    assert_equal(w.r_calls, 7)
    assert_equal(w.e_calls, 3)
    print("tune add calls ok")


def test_boost_idle() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    var r = srv_control(srv, '{"action":"boost","call_budget":50}')
    assert_true(r.find("200") >= 0)
    assert_equal(srv.cfg.call_budget, 50)
    assert_true(r.find("no budget-dead") >= 0)
    assert_true(not srv.running)
    var blank = srv_control(srv, '{"action":"boost"}')
    assert_true(blank.find("400") >= 0)
    var neg = srv_control(srv, '{"action":"boost","call_budget":-1}')
    assert_true(neg.find("400") >= 0)
    assert_equal(srv.cfg.call_budget, 50)
    print("boost idle ok")


def test_dominant_reason() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    assert_equal(srv_dominant_reason(srv), "")
    var w0 = Worker(0, -1, -1, -1)
    w0.reason = "backend-error"
    srv.workers.append(w0^)
    var w1 = Worker(1, -1, -1, -1)
    w1.reason = "max-steps"
    srv.workers.append(w1^)
    var w2 = Worker(2, -1, -1, -1)
    w2.reason = "backend-error"
    srv.workers.append(w2^)
    assert_equal(srv_dominant_reason(srv), "backend-error")
    print("dominant reason ok")


def test_embed_fallback() raises:
    var cfg = ExpCfg("concept", "m", "::::", "k", "e", 7, 1, 100, 0.9, 0.9)
    var pair = pipe_fds()
    assert_true(pair.ok)
    var w = WLoop(0, 1, pair.write_fd, -1, cfg)
    assert_true(w.meta)
    assert_true(not w.embed_fallback)
    for i in range(2):
        var out = List[Float64]()
        assert_true(not w_embed_text(w, "probe text " + String(i), out))
        assert_true(not w.embed_fallback)
    var out3 = List[Float64]()
    assert_true(not w_embed_text(w, "probe text third fail", out3))
    assert_true(w.embed_fallback)
    assert_equal(poll_one(pair.read_fd, 1000), 1)
    var note = pipe_read_some(pair.read_fd, 4096)
    assert_true(note.find("fallback") >= 0)
    var out4 = List[Float64]()
    assert_true(w_embed_text(w, "after fallback", out4))
    assert_true(w.embed_fallback)
    assert_equal(len(out4), 64)
    _ = close_fd(pair.read_fd)
    _ = close_fd(pair.write_fd)
    print("embed fallback ok")


def test_sim_seed_window() raises:
    # 501 texts: the discriminating word sits outside the trailing-500
    # window, so it counts as unseen (picked first).
    var j = List[String]()
    j.append("quux")
    for _ in range(500):
        j.append("aaa bbb ccc")
    assert_equal(sim_seed("quux wxyz", j), "quux wxyz")
    # Inside the window the old recount still applies: quux seen once
    # loses round 0 to the unseen wxyz.
    var j2 = List[String]()
    for _ in range(499):
        j2.append("aaa bbb ccc")
    j2.append("quux")
    assert_equal(sim_seed("quux wxyz", j2), "wxyz quux")
    print("sim seed window ok")


def test_search_reuse() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.veins = List[Vein]()
    var t1 = String("quuxzalfon vaultban hammerwick")
    srv_finding_push(
        srv,
        Finding(0, 1, 0.5, 8.0, 0.0, 0.0, 0.0, False, t1, 0, 0, 0, 0.0, 0, 0.9, "", "live", 1),
        0,
    )
    var v1 = List[Float64]()
    sim_embed(t1, v1)
    srv.vecs[0] = v1^
    var t2 = String("quuxzalfon vaultban hammerwick unrelated filler")
    srv_finding_push(
        srv,
        Finding(0, 2, 0.5, 8.0, 0.0, 0.0, 0.0, False, t2, 0, 0, 0, 0.0, 0, 0.9, "", "live", 1),
        0,
    )
    var meta_dim = List[Float64]()
    meta_dim.append(0.5)
    meta_dim.append(0.5)
    meta_dim.append(0.5)
    srv.vecs[1] = meta_dim^
    var t3 = String("quuxzalfon vaultban hammerwick and more")
    srv_finding_push(
        srv,
        Finding(0, 3, 0.5, 8.0, 0.0, 0.0, 0.0, False, t3, 0, 0, 0, 0.0, 0, 0.9, "", "live", 1),
        0,
    )
    var tv = String("quuxzalfon vaultban")
    var vv = List[Float64]()
    sim_embed(tv, vv)
    srv.veins.append(Vein(1, tv, 0.9, 9.0, vv, 0, 1, 1, "live", 1, "sim", "sim"))
    # Long shared-vocabulary texts: single-word signals drown in hash
    # collisions once journals/ holds thousands of entries (top-50 cut).
    var tv2 = String("quuxzalfon vaultban hammerwick quuxzalfon")
    var mv = List[Float64]()
    for _ in range(5):
        mv.append(0.2)
    srv.veins.append(Vein(2, tv2, 0.9, 9.0, mv, 0, 1, 1, "live", 1, "sim", "sim"))
    var body = srv_search_json(srv, t1, 50)
    var d = parse_json(body)
    var items = doc_find(d, doc_root(d), "items")
    assert_true(doc_len(d, items) >= 5)
    var it0 = doc_at(d, items, 0)
    assert_equal(doc_ostr(d, it0, "text"), t1)
    # Reused in-memory vec scores exactly like a fresh embed.
    var qv = List[Float64]()
    sim_embed(t1, qv)
    var dv = List[Float64]()
    sim_embed(t1, dv)
    var want = vcos(qv, dv)
    var got = doc_onum(d, it0, "score")
    var diff = got - want
    if diff < 0.0:
        diff = -diff
    assert_true(diff < 1e-9)
    var seen2 = False
    var seen3 = False
    var seenv = False
    var seenv2 = False
    for i in range(doc_len(d, items)):
        var tx = doc_ostr(d, doc_at(d, items, i), "text")
        if tx == t2:
            seen2 = True
        if tx == t3:
            seen3 = True
        if tx == tv:
            seenv = True
        if tx == tv2:
            seenv2 = True
    assert_true(seen2)
    assert_true(seen3)
    assert_true(seenv)
    assert_true(seenv2)
    print("search reuse ok")


def test_journal_pareto() raises:
    var pool = List[Finding]()
    pool.append(Finding(0, 0, 0.1, 0.1, 0.0, 0.0, 0.0, False, "a", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(0, 1, 0.9, 0.1, 0.0, 0.0, 0.0, False, "b", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(0, 2, 0.5, 0.5, 0.0, 0.0, 0.0, False, "c", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(0, 3, 0.2, 0.9, 0.0, 0.0, 0.0, False, "d", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(0, 4, 0.3, 0.3, 0.0, 0.0, 0.0, False, "e", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    pool.append(Finding(0, 5, 0.8, 0.8, 0.0, 0.0, 0.0, False, "f", 0, 0, 0, 0.0, 0, 0.0, "", "", 1))
    var full = List[Int]()
    journal_pareto(pool, 0, full)
    assert_equal(len(full), 3)
    assert_equal(full[0], 1)
    assert_equal(full[1], 3)
    assert_equal(full[2], 5)
    # Window-relative: the old leader (index 1) is out of frame, and
    # the survivors are indexed from the window start.
    var win = List[Int]()
    journal_pareto(pool, 2, win)
    assert_equal(len(win), 2)
    assert_equal(win[0], 1)
    assert_equal(win[1], 3)
    print("journal pareto ok")


def test_memory_window() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.run_id = 1
    srv.running = True
    var pair = pipe_fds()
    assert_true(pair.ok)
    var wk = Worker(0, -1, -1, pair.write_fd)
    wk.step = 8
    srv.workers.append(wk^)
    for i in range(250):
        var gold = i == 0 or i >= 240
        srv_finding_push(
            srv,
            Finding(
                1 + (i % 3),
                i + 1,
                0.5,
                8.0,
                0.0,
                0.0,
                0.0,
                gold,
                "mem text " + String(i),
                0,
                0,
                0,
                0.0,
                0,
                0.9,
                "",
                "t",
                1,
            ),
            0,
        )
        var vv = List[Float64]()
        var mag = 2.0
        if i == 0:
            mag = 100.0
        for _ in range(4):
            vv.append(mag)
        srv.vecs[i] = vv^
    srv_maybe_send_memory(srv, 0)
    assert_equal(srv.mem_rounds, 1)
    assert_equal(poll_one(pair.read_fd, 1000), 1)
    var line = pipe_read_some(pair.read_fd, 65536)
    var d = parse_json(line)
    var r = doc_root(d)
    var texts = doc_find(d, r, "texts")
    assert_equal(doc_len(d, texts), 30)
    assert_equal(doc_str(d, doc_at(d, texts, 0)), "mem text 249")
    var vecs = doc_find(d, r, "vecs")
    assert_equal(doc_len(d, vecs), 20)
    # The index-0 gold ([100..]) is outside the trailing-200 window:
    # the mean is the ten trailing [2..] golds only.
    assert_true(line.find('"gold":[2,2,2,2]') >= 0)
    _ = close_fd(pair.read_fd)
    _ = close_fd(pair.write_fd)
    print("memory window ok")


def test_drain_cursor() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var pair = pipe_fds()
    assert_true(pair.ok)
    var w = WLoop(0, 1, -1, pair.read_fd, cfg)
    # Several lines in one chunk: all apply, nothing left over.
    assert_true(
        pipe_write_all(
            pair.write_fd,
            '{"t":"order","name":"pause"}\n'
            '{"t":"order","name":"tune","temp":1.2}\n'
            '{"t":"order","name":"resume"}\n',
        )
        > 0
    )
    assert_true(w_drain_orders(w, cfg))
    assert_true(not w.paused)
    assert_equal(w.temp, 1.2)
    assert_equal(w.obuf, "")
    # A partial line waits for its tail across reads.
    assert_true(pipe_write_all(pair.write_fd, '{"t":"order","name":"pa') > 0)
    assert_true(w_drain_orders(w, cfg))
    assert_true(not w.paused)
    assert_true(w.obuf.byte_length() > 0)
    assert_true(pipe_write_all(pair.write_fd, 'use"}\n') > 0)
    assert_true(w_drain_orders(w, cfg))
    assert_true(w.paused)
    assert_equal(w.obuf, "")
    assert_true(pipe_write_all(pair.write_fd, '{"t":"order","name":"resume"}\n') > 0)
    assert_true(w_drain_orders(w, cfg))
    assert_true(not w.paused)
    # A restart mid-chunk drops the rest of the chunk, as before.
    assert_true(
        pipe_write_all(
            pair.write_fd,
            '{"t":"order","name":"restart"}\n{"t":"order","name":"pause"}\n',
        )
        > 0
    )
    assert_true(w_drain_orders(w, cfg))
    assert_equal(w.temp, 0.9)
    assert_true(not w.paused)
    assert_equal(w.obuf, "")
    _ = close_fd(pair.read_fd)
    _ = close_fd(pair.write_fd)
    print("drain cursor ok")


def test_pca_cadence() raises:
    var cfg = ExpCfg("concept", "sim", "", "", "", 7, 2, 100, 0.9, 0.9)
    var srv = Server(cfg, "web")
    srv.run_id = 1
    srv.workers.append(Worker(0, -1, -1, -1))
    for i in range(1, 6):
        srv_handle_line(
            srv,
            0,
            '{"t":"finding","run":1,"branch":0,"step":'
            + String(i)
            + ',"novelty":0.5,"coherence":8.0,"text":"cadence"}',
        )
        srv_handle_line(
            srv,
            0,
            '{"t":"vec","run":1,"branch":0,"step":'
            + String(i)
            + ',"vec":['
            + String(Float64(i))
            + ","
            + String(Float64(i) * 2.0)
            + ",1.0,0.5]}",
        )
    # First vec refits (cold stamp); the next four defer.
    assert_equal(srv.pca_pending, 4)
    assert_true(srv.pca_dirty)
    for i in range(6, 12):
        srv_handle_line(
            srv,
            0,
            '{"t":"finding","run":1,"branch":0,"step":'
            + String(i)
            + ',"novelty":0.5,"coherence":8.0,"text":"cadence"}',
        )
        srv_handle_line(
            srv,
            0,
            '{"t":"vec","run":1,"branch":0,"step":'
            + String(i)
            + ',"vec":['
            + String(Float64(i))
            + ","
            + String(Float64(i) * 2.0)
            + ",1.0,0.5]}",
        )
    # The 10th pending vec refits; coords converge into range.
    assert_equal(srv.pca_pending, 0)
    assert_true(not srv.pca_dirty)
    for k in range(len(srv.findings)):
        var f = srv.findings[k]
        assert_true(f.x >= 0.0 and f.x <= 100.0)
        assert_true(f.y >= 0.0 and f.y <= 100.0)
        assert_true(f.z >= 0.0 and f.z <= 100.0)
    print("pca cadence ok")


def main() raises:
    test_personas()
    test_craft()
    test_strip()
    test_seed()
    test_repulse()
    test_repulse_cap()
    test_orders()
    test_memory()
    test_converged_input()
    test_vein_load()
    test_models()
    test_auto_bandit()
    test_srv_handle_sick()
    test_srv_handle_clamp()
    test_veins_errors()
    test_veins_error_state()
    test_journals_corrupt()
    test_search_skipped()
    test_control_bad_body()
    test_order_decode_notes()
    test_obuf_cap()
    test_run_validation()
    test_w_reset_persona()
    test_send_order_epipe()
    test_reap_sigkill_grace()
    test_setmodel_persists()
    test_enqueue_snapshot()
    test_cfg_push_worker()
    test_tune_persists()
    test_tele_push()
    test_findings_cap()
    test_enqueue_cap()
    test_journals_cache()
    test_models_ttl()
    test_veins_debounce()
    test_journal_stream_save()
    test_call_budget()
    test_tune_budget()
    test_tune_add_calls()
    test_fanout_picks()
    test_boost_idle()
    test_dominant_reason()
    test_embed_fallback()
    test_sim_seed_window()
    test_search_reuse()
    test_journal_pareto()
    test_memory_window()
    test_drain_cursor()
    test_pca_cadence()
    print("ALL WORKER TESTS PASSED")
