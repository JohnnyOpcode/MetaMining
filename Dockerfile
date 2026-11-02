# MetaMining: pure-Mojo latent space explorer.
#
#   docker build -t metamining .
#   docker run --rm -p 8000:8000 metamining
#   # then open http://127.0.0.1:8000 and press Demo run (SIM)
#
# Add -d to run detached (logs via `docker logs`); Ctrl+C stops a
# foreground run. The server inside listens on 0.0.0.0:8000, so the
# -p 8000:8000 mapping is what makes the GUI reachable.
#
# Persist runs across restarts (else journals/veins die with the
# container):
#   docker run --rm -p 8000:8000 \
#     -v mm-journals:/app/journals -v mm-veins:/app/veins metamining
#
# The image builds the binary from source (Mojo 1.2 via pip). It is
# server-only: no embedding sidecar ships inside, so runs use hash
# vectors — sim works fully, but search is lexical until you point
# Embed endpoint at a llama.cpp server (see ./embed-setup.sh).
# No API key is baked in: sim runs work as-is; pass
# -e META_API_KEY=... for live runs.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip ca-certificates libssl3 build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN python3 -m venv .venv \
 && .venv/bin/pip install --no-cache-dir "mojo==1.2.0"
COPY . .
RUN ./build.sh

EXPOSE 8000
CMD ["./run.sh", "--host", "0.0.0.0", "--port", "8000"]
