"""MCP (Model Context Protocol) Streamable-HTTP surface: pure JSON-RPC
helpers plus the tool catalog. Deliberately Server-free (server.mojo owns
execution) so everything here unit-tests without a socket.

Wire shape (spec 2025-06-18, tools-only server):
- POST /mcp takes one JSON-RPC message, answers one JSON response
  (single-message responses are legal; no SSE fan-out needed since the
  server never initiates). Notifications (no id) get 202 + empty body.
- GET /mcp holds an SSE stream open for spec-compliant clients that
  insist on one; the server sends nothing but the prelude comment.
- DELETE /mcp answers 204. Sessions are lenient: the server issues
  Mcp-Session-Id but never rejects a missing or unknown one.
"""

from metamining.http import hget
from metamining.json import (
    J_OBJ,
    Doc,
    doc_find,
    doc_kind,
    doc_len,
    doc_ostr,
    j_escape,
    j_render_at,
    parse_json,
)

comptime MCP_VERSION = "2025-06-18"


def mcp_negotiate(client: String) -> String:
    """Highest protocol version both sides speak. Unknown clients get
    ours; known older ones keep working."""
    if client == "2025-06-18":
        return String("2025-06-18")
    if client == "2025-03-26":
        return String("2025-03-26")
    if client == "2024-11-05":
        return String("2024-11-05")
    return String(MCP_VERSION)


def mcp_origin_ok(headers: Dict[String, String]) -> Bool:
    """DNS-rebinding guard: absent Origin is fine (non-browser clients);
    a present one must be loopback or match Host exactly."""
    var o = hget(headers, "origin")
    if o == "":
        return True
    if o == "null":
        return False
    var hostport = o
    var scheme = o.find("://")
    if scheme >= 0:
        hostport = String(o[byte = scheme + 3 :])
    var hostfull = hostport
    var slash = hostport.find("/")
    if slash >= 0:
        hostfull = String(hostport[byte = 0 : slash])
    var host = hostfull
    var colon = hostfull.find(":")
    if colon >= 0:
        host = String(hostfull[byte = 0 : colon])
    if host == "localhost" or host == "127.0.0.1" or host == "::1" or host == "[::1]":
        return True
    var h = hget(headers, "host")
    var hh = h
    var hc = h.find(":")
    if hc >= 0:
        hh = String(h[byte = 0 : hc])
    return hh != "" and hh == host


def mcp_has_id(d: Doc, r: Int) -> Bool:
    return doc_find(d, r, "id") >= 0


def mcp_id_json(d: Doc, r: Int) -> String:
    """Render the request id verbatim (string, number, or null) so the
    response echoes the client's exact type."""
    var n = doc_find(d, r, "id")
    if n < 0:
        return String("null")
    return j_render_at(d, n)


def mcp_ok(idj: String, result: String) -> String:
    return String('{"jsonrpc":"2.0","id":') + idj + ',"result":' + result + "}"


def mcp_err(idj: String, code: Int, msg: String) -> String:
    return (
        String('{"jsonrpc":"2.0","id":')
        + idj
        + ',"error":{"code":'
        + String(code)
        + ',"message":"'
        + j_escape(msg)
        + '"}}'
    )


def mcp_tool_text(text: String, is_err: Bool) -> String:
    """tools/call result object: one text block, optionally isError."""
    var out = String('{"content":[{"type":"text","text":"') + j_escape(text) + '"}]'
    if is_err:
        out += ',"isError":true'
    return out + "}"


def mcp_is_object(d: Doc, r: Int) -> Bool:
    return doc_kind(d, r) == J_OBJ


def mcp_tools_json() -> String:
    """The tools/list catalog. Descriptions carry the semantics an agent
    needs: cost, units, and which fields are live-only."""
    var num = String('{"type":"number"}')
    var integer = String('{"type":"integer"}')
    var str = String('{"type":"string"}')
    var out = String('{"tools":[')
    # 1. start_expedition
    out += (
        '{"name":"start_expedition","description":"Start a latent-space expedition. '
        + "Sim (no model/endpoint/key) is free and deterministic; live bills Meta per token. "
        + 'Returns immediately; poll expedition_status. Partial live config warns and runs sim.",'
        + '"inputSchema":{"type":"object","properties":{"concept":'
        + str
        + ',"model":'
        + str
        + ',"models":'
        + str
        + ',"endpoint":'
        + str
        + ',"api_key":'
        + str
        + ',"embed_model":'
        + str
        + ',"embed_endpoint":'
        + str
        + ',"seed":'
        + integer
        + ',"branches":'
        + integer
        + ',"steps":'
        + integer
        + ',"gold":'
        + num
        + ',"temp":'
        + num
        + ',"fanout":'
        + integer
        + ',"judges":'
        + integer
        + ',"repulse":'
        + integer
        + ',"push":'
        + num
        + ',"call_budget":'
        + integer
        + ',"plateau_k":'
        + integer
        + ',"plateau_eps":'
        + num
        + ',"nogold_m":'
        + integer
        + ',"min_coh":'
        + num
        + ',"coh_c":'
        + integer
        + ',"global_stall":'
        + integer
        + "}}}"
    )
    # 2. expedition_status
    out += (
        ',{"name":"expedition_status","description":"Run state: running flag, findings/gold counts, '
        + 'stop reason, backend, API totals (calls, tokens, cost). Poll this while a run is active.",'
        + '"inputSchema":{"type":"object","properties":{}}}'
    )
    # 3. get_findings
    out += (
        ',{"name":"get_findings","description":"Claim findings newest-windowed: branch, step, text, '
        + 'novelty, coherence, gold, map coords. since is an absolute index; next is the total.",'
        + '"inputSchema":{"type":"object","properties":{"since":'
        + integer
        + ',"limit":'
        + integer
        + ',"gold_only":{"type":"boolean"}}}}'
    )
    # 4. search_claims
    out += (
        ',{"name":"search_claims","description":"Search live findings, vein memory, and journals, '
        + 'ranked by vector cosine. Semantic in embed space, lexical in hash space (see space field).",'
        + '"inputSchema":{"type":"object","properties":{"q":'
        + str
        + ',"limit":'
        + integer
        + '},"required":["q"]}}'
    )
    # 5. stop_expedition
    out += (
        ',{"name":"stop_expedition","description":"Stop the active run immediately (reason stopped). '
        + 'Safe to call when idle.",'
        + '"inputSchema":{"type":"object","properties":{}}}'
    )
    # 6. list_journals
    out += (
        ',{"name":"list_journals","description":"Saved expedition journals newest-first with concept, '
        + 'model, endpoint, size, and step counts.",'
        + '"inputSchema":{"type":"object","properties":{}}}'
    )
    # 7. get_journal
    out += (
        ',{"name":"get_journal","description":"One saved journal: provenance head plus entries with '
        + "vectors. Large runs return large payloads; slice client-side."
        + '","inputSchema":{"type":"object","properties":{"filename":'
        + str
        + '},"required":["filename"]}}'
    )
    # 8. save_journal
    out += (
        ',{"name":"save_journal","description":"Persist the live findings as a journal file and flush '
        + 'veins. Returns the filename.",'
        + '"inputSchema":{"type":"object","properties":{}}}'
    )
    # 9. load_journal
    out += (
        ',{"name":"load_journal","description":"Load a journal into memory (replace or merge mode) so '
        + 'shape views and search cover archived runs. Pass filename or custom_json.",'
        + '"inputSchema":{"type":"object","properties":{"filename":'
        + str
        + ',"custom_json":{"type":"object"},"mode":'
        + str
        + "}}}"
    )
    # 10. get_topology
    out += (
        ',{"name":"get_topology","description":"Topological surfaces over the finding cloud: merge '
        + "(tree+basins), bars (barcode+Betti), conf (resampling confidence), loops (H1 rings+void), "
        + 'mapper (nerve graph), time (run timeline). metric is cosine|euclid; max_loops/bins/overlap '
        + "tune loops and mapper."
        + '","inputSchema":{"type":"object","properties":{"surface":'
        + str
        + ',"metric":'
        + str
        + ',"max_loops":'
        + integer
        + ',"bins":'
        + integer
        + ',"overlap":'
        + num
        + '},"required":["surface"]}}'
    )
    # 11. list_models
    out += (
        ',{"name":"list_models","description":"Model ids the live endpoint offers (for the model '
        + 'field). Empty in sim.",'
        + '"inputSchema":{"type":"object","properties":{}}}'
    )
    out += "]}"
    return out
