#!/usr/bin/env bash
# Local embedding backend for MetaMining: downloads a prebuilt llama.cpp
# server plus the Nomic v1.5 Q8_0 embedding model (GGUF), then serves
# OpenAI-compatible /v1/embeddings on 127.0.0.1:8080.
#
# Usage:
#   ./embed-setup.sh          download server + model into ./tools ./models
#   ./embed-setup.sh serve    run the embedding server (foreground)
#
# GPU: an NVIDIA card (nvidia-smi working, driver CUDA runtime 12.8+)
# auto-selects the CUDA build and full layer offload; otherwise the CPU
# build is used. Override with EMBED_FLAVOR=cpu|cuda. An RTX 4060 embeds
# at memory bandwidth with ~1GB of its 8GB VRAM.
#
# Then point MetaMining at it (chat stays sim or Meta, your choice):
#   ./run.sh --embed-model nomic-embed-text-v1.5 \
#            --embed-endpoint http://127.0.0.1:8080/v1 \
#            --embed-doc-prefix "search_document: " \
#            --embed-query-prefix "search_query: "
# Or set Embed model / Embed endpoint in the web start form.
set -euo pipefail
cd "$(dirname "$0")"

GGUF_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf"
GGUF_FILE="models/nomic-embed-text-v1.5.Q8_0.gguf"
TOOLS_DIR="tools/llama.cpp"
PORT="${EMBED_PORT:-8080}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "need $1 on PATH" >&2; exit 1; }; }

pick_server() {
  for b in "$TOOLS_DIR/llama-server" "$TOOLS_DIR/build/bin/llama-server" \
           "$TOOLS_DIR/server" tools/llama-server; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  return 1
}

cuda_max_runtime() {
  # Highest CUDA runtime the driver supports, from the nvidia-smi header
  # ("CUDA Version: 12.8"), empty when unknown.
  nvidia-smi 2>/dev/null | grep -o 'CUDA Version: [0-9]*\.[0-9]*' \
    | head -1 | awk '{print $3}'
}

want_flavor() {
  # EMBED_FLAVOR wins; otherwise CUDA needs a working GPU whose driver
  # supports runtime 12.8+ (else the server would silently serve on CPU).
  if [ -n "${EMBED_FLAVOR:-}" ]; then
    echo "$EMBED_FLAVOR"
    return
  fi
  command -v nvidia-smi >/dev/null 2>&1 || { echo "cpu"; return; }
  nvidia-smi -L >/dev/null 2>&1 || { echo "cpu"; return; }
  var_rt=$(cuda_max_runtime)
  if [ -z "$var_rt" ]; then
    echo "cuda"
    return
  fi
  var_maj=${var_rt%%.*}
  var_min=${var_rt#*.}
  var_min=${var_min%%.*}
  if [ "$var_maj" -gt 12 ] 2>/dev/null \
    || { [ "$var_maj" -eq 12 ] 2>/dev/null && [ "$var_min" -ge 8 ] 2>/dev/null; }; then
    echo "cuda"
  else
    echo "driver CUDA runtime $var_rt < 12.8: update the NVIDIA driver for GPU; using CPU" >&2
    echo "cpu"
  fi
}

latest_llama_tag() {
  # Newest per-commit bNNNN tag (the "latest" marker has no binaries).
  local api tag
  api=$(curl -fsSL --retry 2 --max-time 30 \
    'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5') && {
    tag=$(printf '%s' "$api" | python3 -c "
import json, re, sys
for r in json.load(sys.stdin):
    t = r.get('tag_name', '')
    if re.fullmatch(r'b\d+', t):
        print(t)
        raise SystemExit
" 2>/dev/null) || tag=""
    [ -n "$tag" ] && { echo "$tag"; return 0; }
  }
  echo "GitHub API lookup failed, scraping the release list..." >&2
  curl -fsSL --retry 2 --max-time 30 \
    https://github.com/ggml-org/llama.cpp/releases \
    | grep -o '/ggml-org/llama.cpp/releases/tag/b[0-9]*' | head -1 \
    | sed 's|.*/tag/||'
}

system_cuda() {
  # True when the loader already finds the CUDA runtime libs, making
  # the 566MB cudart bundle redundant.
  ldconfig -p 2>/dev/null | grep -q 'libcudart\.so' \
    && ldconfig -p 2>/dev/null | grep -q 'libcublas\.so'
}

latest_llama_urls() {
  # One tarball URL per line for $1 (cpu|cuda). CUDA pins 12.8 for broad
  # driver support: the binary tarball always, plus the cudart runtime
  # bundle unless the system already provides it.
  local flavor="$1" tag base
  tag=$(latest_llama_tag)
  [ -n "$tag" ] || return 1
  base="https://github.com/ggml-org/llama.cpp/releases/download/$tag"
  if [ "$flavor" = "cuda" ]; then
    echo "$base/llama-$tag-bin-ubuntu-cuda-12.8-x64.tar.gz"
    if system_cuda; then
      echo "system CUDA runtime found, skipping the cudart bundle" >&2
    else
      echo "$base/cudart-llama-$tag-bin-ubuntu-cuda-12.8-x64.tar.gz"
    fi
  else
    echo "$base/llama-$tag-bin-ubuntu-x64.tar.gz"
  fi
}

do_setup() {
  [ "$(uname -s)" = "Linux" ] || echo "warning: not Linux, the ubuntu binary may not run" >&2
  [ "$(uname -m)" = "x86_64" ] || echo "warning: not x86_64, the binary may not run" >&2
  need curl
  mkdir -p tools models
  FLAVOR=$(want_flavor)
  case "$FLAVOR" in
    cpu | cuda) ;;
    *) echo "EMBED_FLAVOR must be cpu or cuda, got: $FLAVOR" >&2; exit 1 ;;
  esac
  # Missing stamp means cpu (all pre-flavor installs were CPU builds).
  INSTALLED=$(cat "$TOOLS_DIR/.flavor" 2>/dev/null || echo cpu)
  if [ -x "$TOOLS_DIR/llama-server" ] && [ "$INSTALLED" != "$FLAVOR" ]; then
    echo "--- installed build is $INSTALLED, want $FLAVOR: re-fetching"
    rm -rf "$TOOLS_DIR"
  fi
  if ! SRV=$(pick_server); then
    echo "--- llama.cpp: fetching latest $FLAVOR ubuntu-x64 release"
    URLS=$(latest_llama_urls "$FLAVOR")
    [ -n "$URLS" ] || { echo "could not find a llama.cpp $FLAVOR ubuntu-x64 tarball" >&2; exit 1; }
    rm -rf "$TOOLS_DIR" && mkdir -p "$TOOLS_DIR"
    n=0
    while IFS= read -r ZIP_URL; do
      [ -n "$ZIP_URL" ] || continue
      n=$((n + 1))
      echo "archive $n: $ZIP_URL"
      case "$ZIP_URL" in
        *.zip)
          curl -fSL --retry 3 -o /tmp/llama-bin.zip "$ZIP_URL"
          if command -v unzip >/dev/null 2>&1; then
            unzip -q -o /tmp/llama-bin.zip -d "$TOOLS_DIR"
          else
            python3 -c "import zipfile; zipfile.ZipFile('/tmp/llama-bin.zip').extractall('$TOOLS_DIR')"
          fi
          rm -f /tmp/llama-bin.zip
          ;;
        *)
          curl -fSL --retry 3 -o /tmp/llama-bin.tgz "$ZIP_URL"
          tar xzf /tmp/llama-bin.tgz -C "$TOOLS_DIR"
          rm -f /tmp/llama-bin.tgz
          ;;
      esac
    done <<EOF
$URLS
EOF
    # Flatten one level: each archive wraps a versioned dir.
    [ -x "$TOOLS_DIR/build/bin/llama-server" ] && mv "$TOOLS_DIR"/build/bin/* "$TOOLS_DIR"/
    for sub in "$TOOLS_DIR"/*/; do
      [ -d "$sub" ] || continue
      mv "$sub"* "$TOOLS_DIR"/ 2>/dev/null && rmdir "$sub" 2>/dev/null || true
    done
    SRV=$(pick_server) || { echo "archive had no llama-server binary" >&2; exit 1; }
    echo "$FLAVOR" >"$TOOLS_DIR/.flavor"
    echo "server: $SRV ($FLAVOR)"
  else
    echo "--- llama.cpp already present: $SRV (delete $TOOLS_DIR to re-fetch)"
    [ -f "$TOOLS_DIR/.flavor" ] || echo "$FLAVOR" >"$TOOLS_DIR/.flavor"
  fi
  if [ -s "$GGUF_FILE" ]; then
    echo "--- model already present: $GGUF_FILE ($(du -h "$GGUF_FILE" | cut -f1))"
  else
    echo "--- model: downloading Q8_0 (~140MB, resumable)"
    curl -fSL --retry 3 -C - -o "$GGUF_FILE" "$GGUF_URL"
  fi
  [ -s "$GGUF_FILE" ] || { echo "model download failed" >&2; exit 1; }
  echo "--- smoke: $($SRV --version 2>&1 | head -1)"
  echo
  echo "ready. 1) ./embed-setup.sh serve"
  echo "       2) ./run.sh --embed-model nomic-embed-text-v1.5 \\"
  echo "             --embed-endpoint http://127.0.0.1:$PORT/v1 \\"
  echo "             --embed-doc-prefix \"search_document: \" \\"
  echo "             --embed-query-prefix \"search_query: \""
}

do_serve() {
  SRV=$(pick_server) || { echo "run ./embed-setup.sh first" >&2; exit 1; }
  [ -s "$GGUF_FILE" ] || { echo "missing $GGUF_FILE, run ./embed-setup.sh first" >&2; exit 1; }
  HOST="${EMBED_HOST:-127.0.0.1}"
  # Nomic v1.5 wants mean pooling over 768 dims; 2048 ctx is plenty
  # for findings and keeps memory modest (~1GB with the Q8_0 weights).
  # A CUDA build offloads every layer: the whole 137M-param model fits
  # in ~1GB VRAM, so even an 8GB card never notices it.
  NGL=""
  if [ "$(cat "$TOOLS_DIR/.flavor" 2>/dev/null)" = "cuda" ] \
    || ls "$TOOLS_DIR"/libggml-cuda*.so >/dev/null 2>&1; then
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
      NGL="-ngl 99"
      echo "embedding server on http://$HOST:$PORT (nomic v1.5 Q8_0, CUDA, full offload)"
    else
      echo "warning: CUDA build but no working GPU, serving on CPU anyway" >&2
    fi
  fi
  [ -z "$NGL" ] && echo "embedding server on http://$HOST:$PORT (nomic v1.5 Q8_0, mean pooling)"
  # shellcheck disable=SC2086
  exec "$SRV" -m "$GGUF_FILE" --host "$HOST" --port "$PORT" \
    -c 2048 --embedding --pooling mean $NGL
}

case "${1:-setup}" in
  setup) do_setup ;;
  serve) do_serve ;;
  *) echo "usage: $0 [setup|serve]" >&2; exit 1 ;;
esac
