#!/usr/bin/env bash
# adminvast.sh — Gemma 4 26B-A4B (con visión) en una VM GPU de 16GB, por SSH.
#
# Corre en tu PC (Linux, macOS o WSL: solo necesita bash 4+, ssh y tar).
# Todo lo pesado pasa en la VM: compila llama.cpp con CUDA (o usa el de la
# plantilla Llama.cpp de Vast), baja el modelo de
# Hugging Face, lanza llama-server + un proxy que inyecta prompts/*.md como
# system prompt, y abre un túnel SSH para usar el webui en tu navegador.
# Nada queda expuesto a internet: todo escucha en 127.0.0.1 de la VM.
#
# Uso:
#   ./adminvast.sh                                         # menú interactivo
#   ./adminvast.sh --connect 'ssh -p PORT root@IP' --setup # todo de una
#   ./adminvast.sh --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
#  Config (todo se puede sobrescribir con variables de entorno)
# ============================================================
MODEL_REPO="${MODEL_REPO:-unsloth/gemma-4-26B-A4B-it-GGUF}"
MODEL_FILE="${MODEL_FILE:-gemma-4-26B-A4B-it-UD-IQ4_XS.gguf}"        # 13.6GB
MMPROJ_SRC="${MMPROJ_SRC:-mmproj-F16.gguf}"                           # 1.2GB, visión
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-gemma-4-26B-A4B-it-f16.gguf}"      # nombre en la VM
NEED_DISK_GB=16

LLAMA_CPP_REPO="${LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp}"
# Commit de master del 2026-10-08, con el que se probó este script.
# LLAMA_CPP_REF=master para lo último (puede romper).
LLAMA_CPP_REF="${LLAMA_CPP_REF:-fc9ce6b9d52a8504edcb262abc92737c2289f96c}"

SERVER_PORT="${SERVER_PORT:-8081}"     # llama-server (VM)
PROXY_PORT="${PROXY_PORT:-8082}"       # proxy con prompts/ (VM)
LOCAL_PORT="${LOCAL_PORT:-8082}"       # puerto en tu PC para el navegador
CTX="${CTX:-32768}"                    # contexto (tokens)

PROMPTS_DIR="${PROMPTS_DIR:-${SCRIPT_DIR}/prompts}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gemma-vast"
LAST_FILE="${CONFIG_DIR}/last_ssh"
CTL_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Estado de la conexión
VM_HOST="" VM_PORT="22" VM_USER="root" VM_KEY="" VM_BASE=""
SSH_STR=""
SSH_OPTS=()

# ============================================================
#  Salida
# ============================================================
if [[ -t 1 ]]; then
  R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' B=$'\e[34m' C=$'\e[36m' M=$'\e[35m' W=$'\e[1m' N=$'\e[0m'
else
  R="" G="" Y="" B="" C="" M="" W="" N=""
fi
ok()    { printf '%s✓ %s%s\n' "$G" "$*" "$N"; }
warn()  { printf '%s⚠ %s%s\n' "$Y" "$*" "$N"; }
err()   { printf '%s✗ %s%s\n' "$R" "$*" "$N" >&2; }
info()  { printf '%s>> %s%s\n' "$B" "$*" "$N"; }
title() { printf '\n%s══ %s ══%s\n' "$M" "$*" "$N"; }
die()   { err "$*"; exit 1; }

# ============================================================
#  SSH
# ============================================================
# Acepta lo que copias de Vast tal cual: 'ssh -p 30115 root@1.2.3.4 -L 8080:localhost:8080'
# (los -L se ignoran, el túnel lo abre este script). También 'root@1.2.3.4 -p 30115'.
parse_ssh() {
  local -a w
  read -ra w <<<"$1"
  VM_HOST="" VM_PORT="22" VM_USER="root"
  local i=0 n=${#w[@]}
  while (( i < n )); do
    case "${w[i]}" in
      ssh) ;;
      -p) VM_PORT="${w[i+1]:-22}"; i=$((i+1)) ;;
      -p*) VM_PORT="${w[i]#-p}" ;;
      -i) VM_KEY="${w[i+1]/#\~/$HOME}"; i=$((i+1)) ;;
      -l) VM_USER="${w[i+1]:-root}"; i=$((i+1)) ;;
      -L|-R|-D|-o|-F|-J|-c|-m|-b|-E|-S|-W|-w) i=$((i+1)) ;;
      -*) ;;
      *@*) VM_USER="${w[i]%@*}"; VM_HOST="${w[i]#*@}" ;;
      *) [[ -z "$VM_HOST" ]] && VM_HOST="${w[i]}" ;;
    esac
    i=$((i+1))
  done
  [[ -n "$VM_HOST" ]] || return 1
  [[ "$VM_PORT" =~ ^[0-9]+$ ]] || return 1
  SSH_STR="$1"
}

set_ssh_opts() {
  SSH_OPTS=(-p "$VM_PORT"
    -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6
    -o StrictHostKeyChecking=accept-new
    -o ControlMaster=auto -o "ControlPath=${CTL_DIR}/gemma-vast-%C" -o ControlPersist=10m)
  [[ -n "$VM_KEY" ]] && SSH_OPTS+=(-i "$VM_KEY")
  return 0
}

target() { printf '%s@%s' "$VM_USER" "$VM_HOST"; }

# remote 'script' — corre bash en la VM. El script viaja por stdin a un
# archivo temporal y se ejecuta desde ahí con stdin=/dev/null: así ningún
# comando remoto (apt, curl...) se "come" el resto del script, no hay líos de
# comillas, y pkill no se matchea a sí mismo (el cmdline es solo
# "bash /tmp/..."). Las variables de abajo llegan ya definidas.
remote() {
  local hdr
  hdr=$(printf 'BASE=%q MODEL_REPO=%q MODEL_FILE=%q MMPROJ_SRC=%q MMPROJ_FILE=%q LLAMA_CPP_REPO=%q LLAMA_CPP_REF=%q SERVER_PORT=%q PROXY_PORT=%q CTX=%q NEED_DISK_GB=%q' \
    "$VM_BASE" "$MODEL_REPO" "$MODEL_FILE" "$MMPROJ_SRC" "$MMPROJ_FILE" "$LLAMA_CPP_REPO" "$LLAMA_CPP_REF" \
    "$SERVER_PORT" "$PROXY_PORT" "$CTX" "$NEED_DISK_GB")
  ssh "${SSH_OPTS[@]}" "$(target)" \
    'f=$(mktemp); cat >"$f"; bash "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc' <<<"${hdr}
export PATH=\"/usr/local/cuda/bin:\$PATH\"
SUDO=''; [ \"\$(id -u)\" = 0 ] || SUDO=sudo
# llama-server: el compilado por este script o el de la imagen (plantilla Llama.cpp de Vast).
LLAMA_BIN=\"\$BASE/llama.cpp/build/bin/llama-server\"
if [ ! -x \"\$LLAMA_BIN\" ]; then
  for b in /opt/llama.cpp/llama-server \"\$(command -v llama-server 2>/dev/null)\"; do
    [ -n \"\$b\" ] && [ -x \"\$b\" ] && { LLAMA_BIN=\"\$b\"; break; }
  done
fi
# Patrón de nuestro llama-server (no toca el que lance la plantilla por su cuenta).
LLAMA_PAT=\"llama-server -m \$BASE/models/\"
$1"
}

require_connection() {
  [[ -n "$VM_HOST" && -n "$VM_BASE" ]] && return 0
  err "Sin conexión. Conecta primero (opción 1 o --connect)."
  return 1
}

connect() {
  local str="${1:-}"
  if [[ -z "$str" ]]; then
    echo "Pega el comando SSH de tu instancia (ej: ssh -p 30115 root@1.2.3.4):"
    read -rp "> " str
  fi
  parse_ssh "$str" || { err "No entiendo ese comando SSH: $str"; return 1; }
  set_ssh_opts

  info "Conectando a $(target):${VM_PORT}..."
  local out errf
  errf=$(mktemp)
  out=$(remote 'echo GEMMA_OK' 2>"$errf" | tail -1) || true
  if [[ "$out" != "GEMMA_OK" ]]; then
    err "No conecta."
    local hostspec="$VM_HOST"
    [[ "$VM_PORT" == 22 ]] || hostspec="[${VM_HOST}]:${VM_PORT}"
    if grep -q "IDENTIFICATION HAS CHANGED" "$errf"; then
      echo "  Esa IP:puerto ya la usaste con otra instancia y ssh guardó su huella vieja."
      echo "  Bórrala y vuelve a conectar:"
      echo "    ssh-keygen -R '${hostspec}'"
    elif grep -q "Permission denied" "$errf"; then
      echo "  La VM rechazó tu clave SSH."
      echo "  - Sube tu clave pública (~/.ssh/id_ed25519.pub) en Vast → Account → SSH Keys, y recrea la instancia"
      echo "  - Si usas otra clave: --key ~/.ssh/tu_clave"
    elif grep -qiE "refused|timed out|No route|Could not resolve" "$errf"; then
      echo "  La VM no responde en ese puerto."
      echo "  - Si recién la creaste, espera 1-2 min (estado 'Running' en Vast)"
      echo "  - Revisa el puerto: cambia cada vez que se recrea la instancia"
    else
      echo "  Error de ssh:"; sed 's/^/    /' "$errf" | tail -5
    fi
    rm -f "$errf"
    VM_HOST="" VM_BASE=""
    return 1
  fi
  rm -f "$errf"

  # /workspace en Vast; $HOME en cualquier otra VM
  VM_BASE=$(remote 'if [ -d /workspace ] && [ -w /workspace ]; then echo /workspace/gemma; else echo "$HOME/gemma"; fi' 2>/dev/null | tail -1)
  ok "Conectado. Carpeta en la VM: ${VM_BASE}"

  mkdir -p "$CONFIG_DIR"
  { printf '%s\n' "$SSH_STR"; printf '%s\n' "$VM_KEY"; } >"$LAST_FILE"
  gpu_check
}

gpu_check() {
  local line name mem
  line=$(remote 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1' 2>/dev/null | tail -1) || true
  if [[ -z "$line" ]]; then
    warn "nvidia-smi no responde: ¿la VM tiene GPU NVIDIA?"
    return 0
  fi
  name="${line%%,*}"; mem="${line##*, }"; mem="${mem//[^0-9]/}"
  printf '  %sGPU:%s %s (%s MiB)\n' "$C" "$N" "$name" "$mem"
  if [[ -n "$mem" ]] && (( mem < 15000 )); then
    warn "Menos de 16GB de VRAM: funciona, pero llama.cpp manda más capas a CPU (más lento)."
  fi
}

# ============================================================
#  1. Compilar llama.cpp (una vez por VM, ~5-10 min)
# ============================================================
build() {
  require_connection || return 1
  title "Compilando llama.cpp con CUDA"
  echo "  Una sola vez por VM. Tarda ~5-10 min según la CPU."

  # Dependencias + chequeo de CUDA
  remote '
set -e
mkdir -p "$BASE/logs"
if [ -x "$LLAMA_BIN" ]; then exit 0; fi
missing=""
for c in git cmake make g++ curl python3; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
if [ -n "$missing" ]; then
  echo ">> Instalando:$missing"
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git cmake build-essential curl python3 >/dev/null
  elif command -v dnf >/dev/null; then
    $SUDO dnf install -y -q git cmake make gcc-c++ curl python3
  elif command -v pacman >/dev/null; then
    $SUDO pacman -Sy --noconfirm --needed git cmake base-devel curl python
  else
    echo "✗ Instala a mano:$missing"; exit 1
  fi
fi
if ! command -v nvcc >/dev/null 2>&1; then
  echo "✗ No hay CUDA toolkit (nvcc) en esta imagen."
  echo "  Usa la plantilla Llama.cpp de Vast (trae llama-server, no compila) o una imagen CUDA *devel* (ej. nvidia/cuda:12.8.1-devel-ubuntu24.04)."
  exit 1
fi
cuda_ver=$(nvcc --version | grep -oE "release [0-9]+\.[0-9]+" | awk "{print \$2}")
echo "   nvcc $cuda_ver"
if ! ldconfig -p 2>/dev/null | grep -q "libcublas\.so" && ! ls /usr/local/cuda/lib64/libcublas.so* >/dev/null 2>&1; then
  if command -v apt-get >/dev/null; then
    echo ">> Instalando cuBLAS para CUDA $cuda_ver..."
    v=$(echo "$cuda_ver" | tr . -)
    $SUDO apt-get install -y -qq "libcublas-$v" "libcublas-dev-$v" >/dev/null && $SUDO ldconfig
  else
    echo "✗ Falta cuBLAS (libcublas) del CUDA toolkit."; exit 1
  fi
fi
' || { err "Preparación fallida (mira el mensaje de arriba)."; return 1; }

  local have
  have=$(remote '[ -x "$LLAMA_BIN" ] && echo "$LLAMA_BIN"' 2>/dev/null | tail -1) || true
  if [[ -n "$have" ]]; then
    ok "llama-server ya disponible, no hace falta compilar (${have})"
    return 0
  fi

  info "Bajando llama.cpp (${LLAMA_CPP_REF:0:12})..."
  remote '
set -e
if [ ! -f "$BASE/llama.cpp/CMakeLists.txt" ]; then
  rm -rf "$BASE/llama.cpp"; mkdir -p "$BASE/llama.cpp"; cd "$BASE/llama.cpp"
  export GIT_TERMINAL_PROMPT=0
  if ! { git init -q && git fetch -q --depth 1 "$LLAMA_CPP_REPO" "$LLAMA_CPP_REF" && git checkout -q FETCH_HEAD; }; then
    echo "   git falló, probando tarball..."
    cd "$BASE"; rm -rf llama.cpp; mkdir llama.cpp
    curl -fsSL "$LLAMA_CPP_REPO/archive/$LLAMA_CPP_REF.tar.gz" | tar -xz -C llama.cpp --strip-components=1
  fi
fi
' || { err "No se pudo bajar llama.cpp."; return 1; }

  info "Compilando (el % avanza a saltos, es normal)..."
  remote '
cd "$BASE/llama.cpp" || exit 1
LOG="$BASE/logs/build.log"
# Arquitectura exacta de la GPU (8.6 -> 86). "native" necesita CMake 3.24+.
ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ". ")
[ -n "$ARCH" ] || ARCH=native
cmake -S . -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$ARCH" -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release >"$LOG" 2>&1 || { tail -20 "$LOG"; exit 1; }
cmake --build build --config Release -j"$(nproc)" --target llama-server 2>&1 | tee -a "$LOG" | grep --line-buffered -oE "^\[ *[0-9]+%\]"
' | while IFS= read -r pct; do printf '\r   %s' "$pct"; done
  echo

  if remote 'test -x "$LLAMA_BIN"' 2>/dev/null; then
    ok "llama-server compilado"
  else
    err "La compilación falló. Últimas líneas del log:"
    remote 'tail -25 "$BASE/logs/build.log"' 2>/dev/null || true
    echo "  (GPU RTX 50xx necesita CUDA 12.8+ en la imagen)"
    return 1
  fi
}

# ============================================================
#  2. Descargar modelo + visión (Hugging Face, ~15GB)
# ============================================================
pull() {
  require_connection || return 1
  title "Descargando Gemma 4 26B-A4B + visión"
  echo "  ${MODEL_REPO}: ${MODEL_FILE} (13.6GB) + ${MMPROJ_SRC} (1.2GB)"

  remote '
set -e
mkdir -p "$BASE/models"
command -v curl >/dev/null || { echo "✗ Falta curl en la VM (corre Compilar primero)"; exit 1; }
avail_kb=$(df -Pk "$BASE/models" | awk "NR==2{print \$4}")
have=0
for f in "$MODEL_FILE" "$MMPROJ_FILE"; do [ -f "$BASE/models/$f" ] && have=$((have + $(stat -c%s "$BASE/models/$f") / 1024)); done
if [ $(( (avail_kb + have) / 1048576 )) -lt "$NEED_DISK_GB" ]; then
  echo "✗ Poco disco: $((avail_kb / 1048576))GB libres en $BASE, hacen falta ~${NEED_DISK_GB}GB."; exit 1
fi

get() {  # get ARCHIVO_HF NOMBRE_LOCAL
  url="https://huggingface.co/$MODEL_REPO/resolve/main/$1"
  dest="$BASE/models/$2"
  expected=$(curl -sI "$url" | grep -i "^x-linked-size:" | tr -dc "0-9")
  if [ -n "$expected" ] && [ -f "$dest" ] && [ "$(stat -c%s "$dest")" = "$expected" ]; then
    echo "✓ $2 ya está"; return 0
  fi
  echo ">> $2"
  # Los links de HF/Xet son firmados: no se pueden reanudar, siempre desde cero.
  rm -f "$dest.part"
  curl -fL --retry 3 --retry-delay 5 -# -o "$dest.part" "$url" || { echo "✗ Falló la descarga de $2"; return 1; }
  got=$(stat -c%s "$dest.part")
  if [ -n "$expected" ] && [ "$got" != "$expected" ]; then
    echo "✗ $2 incompleto ($got de $expected bytes). Reintenta."; rm -f "$dest.part"; return 1
  fi
  mv "$dest.part" "$dest"
  echo "✓ $2 ($got bytes)"
}
get "$MODEL_FILE" "$MODEL_FILE"
get "$MMPROJ_SRC" "$MMPROJ_FILE"
' || { err "Descarga incompleta."; return 1; }
  ok "Modelo listo"
}

# ============================================================
#  3. Lanzar / detener
# ============================================================
proxy_source() {
  cat <<'PY'
#!/usr/bin/env python3
"""Proxy delante de llama-server: si un /chat/completions no trae mensaje
system, mete uno armado con todos los archivos de PROMPT_DIR (se releen en
cada request, editar = efecto inmediato). Todo lo demás pasa tal cual:
webui, streaming, imágenes."""
import http.client, json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND = int(os.environ.get("BACKEND_PORT", "8081"))
PORT = int(os.environ.get("PROXY_PORT", "8082"))
PROMPT_DIR = os.environ.get("PROMPT_DIR", "")
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade", "content-length"}

def system_prompt():
    try:
        names = sorted(os.listdir(PROMPT_DIR))
    except OSError:
        return ""
    parts = []
    for n in names:
        p = os.path.join(PROMPT_DIR, n)
        if os.path.isfile(p):
            try:
                t = open(p, encoding="utf-8").read().strip()
            except OSError:
                continue
            if t:
                parts.append(f"## {n}\n\n{t}")
    return "\n\n---\n\n".join(parts)

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        if self.command == "POST" and self.path.endswith("/chat/completions") and body:
            try:
                d = json.loads(body)
                msgs = d.get("messages", [])
                sp = system_prompt()
                if sp and not any(m.get("role") == "system" for m in msgs):
                    msgs.insert(0, {"role": "system", "content": sp})
                    d["messages"] = msgs
                    body = json.dumps(d).encode()
            except (ValueError, AttributeError):
                pass
        c = http.client.HTTPConnection("127.0.0.1", BACKEND, timeout=600)
        hd = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        if body is not None:
            hd["Content-Length"] = str(len(body))
        c.request(self.command, self.path, body=body, headers=hd)
        r = c.getresponse()
        self.send_response(r.status, r.reason)
        for k, v in r.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        while True:
            chunk = r.read(4096)
            if not chunk:
                break
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        c.close()
    do_GET = do_POST = do_PUT = do_DELETE = _go
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    print(f"proxy 127.0.0.1:{PORT} -> {BACKEND}, prompts: {PROMPT_DIR}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
}

launch() {
  require_connection || return 1
  title "Lanzando Gemma"

  local state
  state=$(remote '
if [ ! -x "$LLAMA_BIN" ]; then echo NO_BIN
elif [ ! -f "$BASE/models/$MODEL_FILE" ]; then echo NO_MODEL
elif curl -sf "127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then echo RUNNING
elif pgrep -f "$LLAMA_PAT" >/dev/null; then echo LOADING
else echo READY; fi' 2>/dev/null | tail -1)
  case "$state" in
    NO_BIN)   err "No hay llama-server en la VM. Usa Compilar (o --build), o la plantilla Llama.cpp de Vast."; return 1 ;;
    NO_MODEL) err "Falta el modelo. Usa Descargar (o --pull)."; return 1 ;;
    RUNNING)  ok "llama-server ya estaba corriendo" ;;
    READY|LOADING)
      if [[ "$state" == READY ]]; then
        # Otro proceso en la GPU (ComfyUI, o el llama-server propio de la plantilla
        # Llama.cpp si tiene LLAMA_MODEL) le
        # quita VRAM: --fit manda más a CPU y Gemma va más lento.
        local used
        used=$(remote 'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1' 2>/dev/null | tail -1 | tr -dc '0-9') || true
        if [[ -n "$used" ]] && (( used > 2000 )); then
          warn "Ya hay ${used} MiB de VRAM ocupados por otro proceso (¿ComfyUI? ¿LLAMA_MODEL en la plantilla Llama.cpp? → supervisorctl stop llama). Gemma irá más lento. Mira con: --shell → nvidia-smi"
        fi
        info "Cargando el modelo en la GPU (~30-90 s)..."
        remote '
mkdir -p "$BASE/logs"
MM=(); [ -f "$BASE/models/$MMPROJ_FILE" ] && MM=(--mmproj "$BASE/models/$MMPROJ_FILE")
# Sin -ngl: --fit (default de llama.cpp) reparte capas/expertos entre GPU y CPU
# según la VRAM libre, en vez de reventar con out-of-memory.
nohup "$LLAMA_BIN" -m "$BASE/models/$MODEL_FILE" "${MM[@]}" \
  --host 127.0.0.1 --port "$SERVER_PORT" -c "$CTX" >"$BASE/logs/server.log" 2>&1 </dev/null &
' 2>/dev/null
      else
        info "llama-server ya está cargando, esperando..."
      fi
      local i result=""
      for (( i = 0; i < 60; i++ )); do
        result=$(remote '
if curl -sf "127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then echo UP
elif ! pgrep -f "$LLAMA_PAT" >/dev/null; then echo DIED
else echo WAIT; fi' 2>/dev/null | tail -1) || true
        [[ "$result" == "WAIT" || -z "$result" ]] || break
        printf '.'; sleep 3
      done
      echo
      case "$result" in
        UP) ok "llama-server listo" ;;
        DIED)
          err "llama-server se cerró. Últimas líneas:"
          remote 'tail -15 "$BASE/logs/server.log"' 2>/dev/null || true
          echo "  - 'out of memory': cierra lo que use la GPU (ComfyUI, etc.) o baja el contexto: CTX=16384 ./adminvast.sh --restart"
          echo "  - 'bind' / 'address already in use': otro programa usa el puerto ${SERVER_PORT} en la VM: SERVER_PORT=8091 ./adminvast.sh --launch"
          return 1 ;;
        *) warn "Sigue cargando. Revisa con Estado en un minuto." ;;
      esac
      ;;
    *) err "No se pudo consultar la VM."; return 1 ;;
  esac

  # Proxy + prompts (se resuben siempre: tu carpeta local manda)
  info "Subiendo proxy y prompts/..."
  remote 'mkdir -p "$BASE/prompts" "$BASE/logs"' 2>/dev/null
  proxy_source | ssh "${SSH_OPTS[@]}" "$(target)" "cat > '${VM_BASE}/gemma-vast-proxy.py'"
  if [[ -d "$PROMPTS_DIR" ]]; then
    tar -C "$PROMPTS_DIR" -cf - . | ssh "${SSH_OPTS[@]}" "$(target)" "rm -rf '${VM_BASE}/prompts' && mkdir -p '${VM_BASE}/prompts' && tar -xf - -C '${VM_BASE}/prompts'"
    printf '  %sprompts:%s %s\n' "$C" "$N" "$(cd "$PROMPTS_DIR" && ls | tr '\n' ' ')"
  else
    warn "No existe ${PROMPTS_DIR}: el proxy corre sin system prompt."
  fi
  remote '
pkill -f "$BASE/gemma-vast-proxy.py" 2>/dev/null; sleep 0.5
BACKEND_PORT="$SERVER_PORT" PROXY_PORT="$PROXY_PORT" PROMPT_DIR="$BASE/prompts" \
  nohup python3 "$BASE/gemma-vast-proxy.py" >"$BASE/logs/proxy.log" 2>&1 </dev/null &
sleep 1
curl -sf "127.0.0.1:$PROXY_PORT/health" >/dev/null && echo PROXY_UP || echo PROXY_DOWN' 2>/dev/null | tail -1 | grep -q PROXY_UP \
    && ok "Proxy en el puerto ${PROXY_PORT}" \
    || { err "El proxy no arrancó (mira ${VM_BASE}/logs/proxy.log)"; return 1; }

  tunnel_start
}

stop() {
  require_connection || return 1
  info "Deteniendo Gemma (libera la VRAM)..."
  remote '
pkill -f "$LLAMA_PAT" && echo "✓ llama-server detenido" || echo "   llama-server no corría"
pkill -f "$BASE/gemma-vast-proxy.py" && echo "✓ proxy detenido" || echo "   proxy no corría"' 2>/dev/null || true
}

restart() { stop || true; sleep 2; launch; }

# ============================================================
#  Túnel SSH (tu PC:LOCAL_PORT -> VM:PROXY_PORT)
# ============================================================
tunnel_pattern() { printf '%s:127.0.0.1:%s' "$LOCAL_PORT" "$PROXY_PORT"; }

local_port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; }

tunnel_start() {
  require_connection || return 1
  # Se recrea siempre: un túnel viejo puede apuntar a una VM anterior o muerta.
  if pkill -f -- "$(tunnel_pattern)" 2>/dev/null; then sleep 1; fi
  if local_port_open; then
    err "El puerto ${LOCAL_PORT} de tu PC ya está en uso. Usa otro: LOCAL_PORT=8090 ./adminvast.sh"
    return 1
  fi
  # Sin ControlMaster: el túnel vive solo, independiente de este script.
  local -a opts=(-p "$VM_PORT" -o ControlPath=none -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new)
  [[ -n "$VM_KEY" ]] && opts+=(-i "$VM_KEY")
  if ssh "${opts[@]}" -f -N -L "$(tunnel_pattern)" "$(target)" 2>/dev/null && sleep 1 && local_port_open; then
    ok "Túnel abierto. Abre en tu navegador: ${W}http://localhost:${LOCAL_PORT}${N}"
  else
    err "No se pudo abrir el túnel."
    return 1
  fi
}

tunnel_stop() {
  if pkill -f -- "$(tunnel_pattern)" 2>/dev/null; then ok "Túnel cerrado"; else echo "   No había túnel abierto"; fi
}

open_browser() {
  local url="http://localhost:${LOCAL_PORT}"
  if command -v xdg-open >/dev/null; then
    xdg-open "$url" >/dev/null 2>&1 &
    ok "Abriendo ${url}"
  elif command -v open >/dev/null; then   # macOS
    open "$url"
    ok "Abriendo ${url}"
  else
    echo "Abre ${url} en tu navegador."
  fi
}

# ============================================================
#  Estado / prueba / shell
# ============================================================
status() {
  require_connection || return 1
  title "Estado ($(target):${VM_PORT})"
  remote '
yn() { if eval "$1"; then echo "✓ $2"; else echo "✗ $3"; fi; }
yn "[ -x \"$LLAMA_BIN\" ]" "llama-server: $LLAMA_BIN" "llama-server no instalado (usa --build)"
for f in "$MODEL_FILE" "$MMPROJ_FILE"; do
  yn "[ -f \"$BASE/models/$f\" ]" "$f ($(du -h "$BASE/models/$f" 2>/dev/null | cut -f1))" "$f no descargado"
done
yn "curl -sf 127.0.0.1:$SERVER_PORT/health >/dev/null 2>&1" "llama-server respondiendo (:$SERVER_PORT)" "llama-server apagado"
yn "curl -sf 127.0.0.1:$PROXY_PORT/health >/dev/null 2>&1" "proxy respondiendo (:$PROXY_PORT)" "proxy apagado"
echo "   GPU: $(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo N/A)"
d="$BASE"; [ -d "$d" ] || d=$(dirname "$d")
echo "   Disco: $(df -h "$d" 2>/dev/null | awk "NR==2{print \$4\" libres de \"\$2}")"' 2>/dev/null || err "No se pudo consultar la VM"
  if pgrep -f -- "$(tunnel_pattern)" >/dev/null 2>&1; then
    ok "Túnel local abierto: http://localhost:${LOCAL_PORT}"
  else
    echo "✗ Túnel local cerrado"
  fi
}

test_chat() {
  require_connection || return 1
  title "Prueba: texto + imagen"
  remote '
python3 - <<EOF
import base64, json, struct, time, urllib.request, zlib
def png(w, h):  # cuadrado rojo, sin dependencias
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
    ch = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b"")
img = "data:image/png;base64," + base64.b64encode(png(64, 64)).decode()
def ask(content):
    body = {"messages": [{"role": "user", "content": content}], "max_tokens": 1000}
    req = urllib.request.Request("http://127.0.0.1:$PROXY_PORT/v1/chat/completions",
        json.dumps(body).encode(), {"Content-Type": "application/json"})
    t = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=300))
    tps = r.get("timings", {}).get("predicted_per_second", 0)
    return r["choices"][0]["message"]["content"].strip(), tps, time.time() - t
try:
    a, tps, s = ask("Di hola en 5 palabras.")
    print(f"Texto:  {a!r}  ({tps:.0f} tok/s, {s:.1f}s)")
    a, tps, s = ask([{"type": "text", "text": "¿De qué color es esta imagen? Una palabra."},
                     {"type": "image_url", "image_url": {"url": img}}])
    print(f"Imagen: {a!r}  ({tps:.0f} tok/s, {s:.1f}s)")
except Exception as e:
    print(f"✗ {e} — ¿está lanzado? (opción Lanzar)")
EOF' 2>/dev/null || err "No se pudo correr la prueba"
}

remote_shell() {
  require_connection || return 1
  ssh "${SSH_OPTS[@]}" -t "$(target)"
}

setup_all() { build && pull && launch; }

# ============================================================
#  Menú
# ============================================================
try_last() {
  [[ -f "$LAST_FILE" ]] || return 1
  local str key
  { IFS= read -r str; IFS= read -r key || true; } <"$LAST_FILE"
  [[ -n "$str" ]] || return 1
  read -rp "¿Reconectar a la última VM (${str})? [S/n] " a
  [[ "${a:-s}" =~ ^[Nn] ]] && return 1
  VM_KEY="$key"
  connect "$str"
}

menu() {
  try_last || true
  while true; do
    echo
    printf '%s═══ Gemma 4 26B-A4B (visión) — VM 16GB ═══%s\n' "$C" "$N"
    if [[ -n "$VM_HOST" ]]; then printf '  VM: %s:%s\n' "$(target)" "$VM_PORT"; else printf '  %sSin conexión%s\n' "$Y" "$N"; fi
    cat <<EOF
  1) Conectar a una VM
  2) Setup completo (compilar + descargar + lanzar + túnel)
  3) Compilar llama.cpp        4) Descargar modelo
  5) Lanzar                    6) Detener (libera GPU)
  7) Reiniciar                 8) Estado
  9) Probar (texto + imagen)
  t) Abrir túnel   c) Cerrar túnel   o) Abrir navegador
  s) Shell en la VM            q) Salir
EOF
    read -rp "> " opt
    case "$opt" in
      1) connect || true ;;
      2) setup_all || true ;;
      3) build || true ;;
      4) pull || true ;;
      5) launch || true ;;
      6) stop || true ;;
      7) restart || true ;;
      8) status || true ;;
      9) test_chat || true ;;
      t|T) tunnel_start || true ;;
      c|C) tunnel_stop || true ;;
      o|O) open_browser || true ;;
      s|S) remote_shell || true ;;
      q|Q) echo "El túnel (si está abierto) sigue activo. Ciérralo con: $0 --tunnel-stop"; exit 0 ;;
      *) err "Opción inválida" ;;
    esac
  done
}

usage() {
  cat <<EOF
adminvast.sh — Gemma 4 26B-A4B con visión en una VM GPU de 16GB (Vast.ai, RunPod, etc.)

Sin argumentos: menú interactivo.

Conexión:
  --connect 'SSH'     Comando SSH de la VM, tal cual (ej. 'ssh -p 30115 root@1.2.3.4')
                      Sin --connect usa la última VM guardada.
  --key ARCHIVO       Clave SSH (si no es la que ssh usa por defecto)

Pasos (se ejecutan en el orden en que los escribes):
  --setup             --build + --pull + --launch (todo de una)
  --build             Compila llama.cpp con CUDA (una vez por VM)
  --pull              Descarga modelo + visión de Hugging Face (~15GB)
  --launch            Lanza llama-server + proxy + túnel
  --stop              Detiene todo en la VM (libera la VRAM)
  --restart           --stop + --launch
  --status            Estado de la VM, modelo, procesos y túnel
  --test              Prueba de texto + imagen
  --tunnel            Abre el túnel (http://localhost:${LOCAL_PORT})
  --tunnel-stop       Cierra el túnel
  --open              Abre el navegador
  --shell             Shell en la VM

Variables de entorno: LOCAL_PORT (${LOCAL_PORT}), CTX (${CTX}), PROMPTS_DIR,
  MODEL_FILE, LLAMA_CPP_REF (master = lo último).

Ejemplo:
  $0 --connect 'ssh -p 30115 root@1.2.3.4' --setup --test --open
EOF
}

# ============================================================
#  main
# ============================================================
(( BASH_VERSINFO[0] >= 4 )) || die "Necesitas bash 4 o más nuevo (en macOS: brew install bash)."
for c in ssh tar mktemp pgrep pkill; do
  command -v "$c" >/dev/null || die "Falta '$c' en tu PC. Instálalo con el gestor de paquetes de tu distro (pgrep/pkill vienen en 'procps')."
done

if (( $# == 0 )); then
  menu
  exit 0
fi

steps=()
conn=""
while (( $# )); do
  case "$1" in
    --connect)     conn="${2:?--connect necesita el comando SSH}"; shift 2 ;;
    --key)         VM_KEY="${2:?--key necesita un archivo}"; VM_KEY="${VM_KEY/#\~/$HOME}"
                   [[ -f "$VM_KEY" ]] || die "No existe la clave: $VM_KEY"; shift 2 ;;
    --setup)       steps+=(setup_all); shift ;;
    --build)       steps+=(build); shift ;;
    --pull)        steps+=(pull); shift ;;
    --launch)      steps+=(launch); shift ;;
    --stop)        steps+=(stop); shift ;;
    --restart)     steps+=(restart); shift ;;
    --status)      steps+=(status); shift ;;
    --test)        steps+=(test_chat); shift ;;
    --tunnel)      steps+=(tunnel_start); shift ;;
    --tunnel-stop) steps+=(tunnel_stop); shift ;;
    --open)        steps+=(open_browser); shift ;;
    --shell)       steps+=(remote_shell); shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "Opción desconocida: $1"; usage; exit 1 ;;
  esac
done

# Pasos que no tocan la VM no necesitan conexión
needs_vm=false
for s in "${steps[@]}"; do [[ "$s" == tunnel_stop || "$s" == open_browser ]] || needs_vm=true; done

if [[ "$needs_vm" == true ]]; then
  if [[ -z "$conn" && -f "$LAST_FILE" ]]; then
    { IFS= read -r conn; IFS= read -r k || true; } <"$LAST_FILE"
    [[ -n "$VM_KEY" ]] || VM_KEY="${k:-}"
    info "Usando la última VM: ${conn}"
  fi
  [[ -n "$conn" ]] || die "Falta --connect 'ssh -p PORT root@IP'"
  connect "$conn" || exit 1
fi

for s in "${steps[@]}"; do
  "$s" || die "Falló el paso: ${s}"
done
