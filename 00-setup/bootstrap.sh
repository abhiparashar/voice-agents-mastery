#!/usr/bin/env bash
#
# Idempotent bench setup for the voice-agents-mastery curriculum.
#
# Installs only what no Python wheel can provide, then verifies every contract
# the curriculum depends on. Safe to run repeatedly: every step checks before
# it acts.
#
#   ./bootstrap.sh            # install what is missing, then verify
#   ./bootstrap.sh --check    # verify only, change nothing
#   ./bootstrap.sh --models   # also pre-download model weights (~2 GB)
#
# Deliberately NOT installed:
#   portaudio  -- the sounddevice wheel bundles PortAudio (verified V19.7.0)
#   python     -- uv manages interpreters; never touch the system Python
#   any wheel  -- every listing declares its own deps via `uv run --with`

set -uo pipefail

PY_VERSION="3.12"
CHECK_ONLY=0
WANT_MODELS=0
for arg in "$@"; do
  case "$arg" in
    --check)  CHECK_ONLY=1 ;;
    --models) WANT_MODELS=1 ;;
    -h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
fails=0; warns=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$YLW" "$RST" "$*"; warns=$((warns+1)); }
bad()  { printf '  %s[fail]%s %s\n' "$RED" "$RST" "$*"; fails=$((fails+1)); }
step() { printf '\n%s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- platform
step "platform"
OS="$(uname -s)"
ARCH="$(uname -m)"
ok "$OS $ARCH"
if [ "$OS" = "Darwin" ]; then
  ok "macOS $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
elif [ "$OS" = "Linux" ]; then
  ok "kernel $(uname -r)"
else
  warn "untested platform: $OS. The curriculum targets macOS and Linux"
fi

# --------------------------------------------------------------- uv
step "uv"
if have uv; then
  ok "uv $(uv --version | awk '{print $2}')"
else
  if [ "$CHECK_ONLY" = 1 ]; then
    bad "uv missing. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
  else
    say "  installing uv..."
    if curl -LsSf https://astral.sh/uv/install.sh | sh; then
      # the installer puts uv in ~/.local/bin; make it visible to this shell
      export PATH="$HOME/.local/bin:$PATH"
      have uv && ok "uv $(uv --version | awk '{print $2}')" \
              || bad "uv installed but not on PATH; add ~/.local/bin"
    else
      bad "uv install failed"
    fi
  fi
fi

# --------------------------------------------------------------- interpreter
step "python $PY_VERSION"
if have uv; then
  if [ "$CHECK_ONLY" = 1 ]; then
    uv python find "$PY_VERSION" >/dev/null 2>&1 \
      && ok "$(uv run --python "$PY_VERSION" python -c 'import platform;print(platform.python_version())' 2>/dev/null)" \
      || bad "Python $PY_VERSION not available. Run without --check to fetch it"
  else
    uv python install "$PY_VERSION" >/dev/null 2>&1 || true
    v="$(uv run --python "$PY_VERSION" python -c 'import platform;print(platform.python_version())' 2>/dev/null)"
    [ -n "$v" ] && ok "$v" || bad "could not provision Python $PY_VERSION"
  fi
  sysv="$(/usr/bin/python3 --version 2>&1 | awk '{print $2}')"
  [ -n "$sysv" ] && say "  ${DIM}system python is $sysv -- never used by this curriculum${RST}"
else
  bad "skipped: uv unavailable"
fi

# --------------------------------------------------------------- binaries
# These two are the ONLY native dependencies no wheel provides.
step "system binaries"
install_pkg() {
  local bin="$1" pkg="$2" why="$3"
  if have "$bin"; then ok "$bin ($(command -v "$bin"))"; return; fi
  if [ "$CHECK_ONLY" = 1 ]; then warn "$bin missing -- needed for $why"; return; fi
  if [ "$OS" = "Darwin" ]; then
    if have brew; then
      say "  installing $pkg via brew..."
      brew install "$pkg" >/dev/null 2>&1
      have "$bin" && ok "$bin installed" || warn "$bin install failed -- needed for $why"
    else
      warn "$bin missing and brew not found. Install Homebrew, or $bin manually ($why)"
    fi
  elif have apt-get; then
    say "  installing $pkg via apt-get (may prompt for sudo)..."
    sudo apt-get install -y "$pkg" >/dev/null 2>&1
    have "$bin" && ok "$bin installed" || warn "$bin install failed -- needed for $why"
  else
    warn "$bin missing; no known package manager. Install manually ($why)"
  fi
}
install_pkg ffmpeg    ffmpeg    "decoding anything that is not WAV"
install_pkg espeak-ng espeak-ng "Piper and Kokoro grapheme-to-phoneme"

# --------------------------------------------------------------- cache dir
step "model cache"
CACHE="${VAM_CACHE:-$HOME/.cache/voice-agents-mastery}"
if [ "$CHECK_ONLY" = 1 ]; then
  [ -d "$CACHE" ] && ok "$CACHE" || warn "$CACHE does not exist yet"
else
  mkdir -p "$CACHE" && ok "$CACHE"
fi
say "  ${DIM}point HF_HOME/TORCH_HOME here to keep one copy of every model${RST}"

# --------------------------------------------------------------- doctor
step "verifying contracts"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHAPTER="$HERE/01-environment.md"
DOCTOR="$(mktemp -t vam-doctor).py"
trap 'rm -f "$DOCTOR"' EXIT

# The doctor lives in the chapter, so there is exactly one copy of it.
# Extract the first fenced python block from 01-environment.md.
if [ ! -f "$CHAPTER" ]; then
  warn "01-environment.md not found next to bootstrap.sh; skipping contract checks"
elif ! have uv; then
  bad "cannot run doctor without uv"
else
  awk '/^```python$/{f=1;next} /^```$/{if(f)exit} f' "$CHAPTER" > "$DOCTOR"
  if [ ! -s "$DOCTOR" ]; then
    bad "could not extract doctor.py from 01-environment.md"
  else
    uv run --python "$PY_VERSION" \
      --with numpy --with torch --with torchaudio --with scipy --with soxr \
      --with sounddevice "$DOCTOR"
    rc=$?
    [ "$rc" -eq 0 ] && ok "doctor passed" || bad "doctor reported failures"
  fi
fi

# --------------------------------------------------------------- models
if [ "$WANT_MODELS" = 1 ] && [ "$CHECK_ONLY" = 0 ] && have uv; then
  step "pre-downloading models (~2 GB)"
  HF_HOME="$CACHE" TORCH_HOME="$CACHE" uv run --python "$PY_VERSION" \
    --with faster-whisper --with silero-vad python - <<'PY'
import os
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
try:
    from faster_whisper import WhisperModel
    WhisperModel("distil-large-v3", device="cpu", compute_type="int8")
    print("  faster-whisper distil-large-v3 int8 cached")
except Exception as e:
    print(f"  faster-whisper download failed: {e}")
try:
    from silero_vad import load_silero_vad
    load_silero_vad()
    print("  silero-vad cached")
except Exception as e:
    print(f"  silero-vad download failed: {e}")
PY
fi

# --------------------------------------------------------------- summary
step "summary"
if [ "$fails" -gt 0 ]; then
  printf '  %s%d failure(s)%s, %d warning(s). Fix failures before chapter 1.\n' \
    "$RED" "$fails" "$RST" "$warns"
  exit 1
elif [ "$warns" -gt 0 ]; then
  printf '  %s%d warning(s)%s, no failures. Core curriculum will run; some\n' \
    "$YLW" "$warns" "$RST"
  printf '  chapters need the warned dependencies.\n'
  exit 0
else
  printf '  %sbench ready%s\n' "$GRN" "$RST"
  exit 0
fi
