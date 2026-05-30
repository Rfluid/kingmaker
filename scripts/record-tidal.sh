#!/usr/bin/env bash
#
# record-tidal.sh — render a TidalCycles file to an audio file.
#
# Plays a .tidal file through your *already running* SuperDirt and captures
# SuperCollider's output in isolation (no speaker monitor, no microphone),
# then trims, fades and normalizes the result.
#
# It boots its own headless GHCi/Tidal instance, so it does NOT disturb the
# Tidal session you may have open in your editor (nvim, etc.).
#
# Requirements: ghci + TidalCycles, a running SuperDirt (superdirt.start),
#               pw-record + pw-link (PipeWire), ffmpeg.
#
# Usage:
#   scripts/record-tidal.sh -i INPUT.tidal -o OUTPUT.wav [options]
#
# Options:
#   -i, --input FILE     Tidal source file to play            (required)
#   -o, --output FILE    Output audio file; format from ext   (required)
#                        (.wav/.mp3/.ogg/.flac ... ffmpeg decides)
#       --tail SEC       Keep recording SEC after the last line, to catch
#                        release/reverb tails               (default: 5)
#       --leadin SEC     Silence recorded before playback     (default: 0.4)
#       --duration SEC   Hard-cap the output length (atrim); default: keep full
#       --fade SEC       Fade-out length at the end           (default: 0.3)
#       --threshold dB   Silence gate for trimming ends       (default: -50dB)
#       --lufs LUFS      Loudness-normalize target            (default: -16)
#       --gain dB        Apply a fixed dB gain instead of loudnorm
#       --no-normalize   Don't change levels at all
#       --rate HZ        Sample rate                          (default: 48000)
#       --node NAME      scsynth PipeWire node name           (default: SuperCollider)
#       --boot FILE      BootTidal.hs to use
#                        (default: $TIDAL_BOOT or tidal.nvim's bootfile)
#       --port N         SuperDirt OSC port                   (default: 57120)
#       --keep-raw       Also keep the untouched capture next to the output
#   -h, --help           Show this help
#
# Examples:
#   scripts/record-tidal.sh -i experiments/notifications/futuristic-major.tidal \
#                           -o experiments/notifications/futuristic-major.wav
#
#   scripts/record-tidal.sh -i pad.tidal -o pad.mp3 --tail 8 --no-normalize --keep-raw
#
set -uo pipefail
export LC_ALL=C   # force '.' as decimal separator for awk/ffmpeg

# ----------------------------------------------------------------- defaults
INPUT=""
OUTPUT=""
BOOT="${TIDAL_BOOT:-$HOME/.local/share/nvim/lazy/tidal.nvim/bootfiles/BootTidal.hs}"
NODE="SuperCollider"
DIRT_PORT=57120
LEADIN=0.4
TAIL=5
DURATION=""
FADE=0.3
THRESH="-50dB"
LUFS=-16
TP=-1.5
GAIN=""
NORMALIZE=1
KEEP_RAW=0
RATE=48000
GHCI_BIN="${GHCI:-ghci}"
CAPNAME="km-tidalrec"

say(){ printf '\033[36m[record-tidal]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[31m[record-tidal] error:\033[0m %s\n' "$*" >&2; exit 1; }
usage(){ sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'; exit 0; }

# ----------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)     INPUT="$2"; shift 2;;
    -o|--output)    OUTPUT="$2"; shift 2;;
    --tail)         TAIL="$2"; shift 2;;
    --leadin)       LEADIN="$2"; shift 2;;
    --duration)     DURATION="$2"; shift 2;;
    --fade)         FADE="$2"; shift 2;;
    --threshold)    THRESH="$2"; shift 2;;
    --lufs)         LUFS="$2"; shift 2;;
    --gain)         GAIN="$2"; NORMALIZE=0; shift 2;;
    --no-normalize) NORMALIZE=0; LUFS=""; shift;;
    --rate)         RATE="$2"; shift 2;;
    --node)         NODE="$2"; shift 2;;
    --boot)         BOOT="$2"; shift 2;;
    --port)         DIRT_PORT="$2"; shift 2;;
    --keep-raw)     KEEP_RAW=1; shift;;
    -h|--help)      usage;;
    *) die "unknown option: $1 (try --help)";;
  esac
done

[[ -n "$INPUT"  ]] || die "missing --input (try --help)"
[[ -n "$OUTPUT" ]] || die "missing --output (try --help)"
[[ -f "$INPUT"  ]] || die "input file not found: $INPUT"
[[ -f "$BOOT"   ]] || die "BootTidal.hs not found: $BOOT (set --boot or \$TIDAL_BOOT)"
for bin in "$GHCI_BIN" pw-record pw-link ffmpeg awk; do
  command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

# SuperDirt / scsynth must be up and exposing output ports
mapfile -t SC_OUTS < <(pw-link -o 2>/dev/null | grep -E "^${NODE}:out" | sort -V)
[[ ${#SC_OUTS[@]} -ge 1 ]] || die "no '${NODE}:out*' ports found — is scsynth/SuperDirt running? (superdirt.start)"

# ----------------------------------------------------------------- temp + cleanup
TMP="$(mktemp -d /tmp/record-tidal.XXXXXX)"
FIFO="$TMP/in.fifo"; LOG="$TMP/ghci.log"; RAW="$TMP/raw.wav"; BOOT2="$TMP/boot.hs"
GHCI_PID=""; REC_PID=""
cleanup(){
  [[ -n "$REC_PID"  ]] && kill "$REC_PID"  2>/dev/null
  [[ -n "$GHCI_PID" ]] && kill "$GHCI_PID" 2>/dev/null
  exec 3>&- 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# Disable the external-control listener so we never fight the editor's Tidal
# instance over port 6010.
if grep -q 'cCtrlListen' "$BOOT"; then
  cp "$BOOT" "$BOOT2"
else
  sed 's/defaultConfig {\([^}]*\)}/defaultConfig {\1, cCtrlListen = False}/' "$BOOT" > "$BOOT2" 2>/dev/null \
    || cp "$BOOT" "$BOOT2"
fi
# Point the boot at the requested SuperDirt port if it differs.
sed -i "s/oPort = [0-9]\+/oPort = ${DIRT_PORT}/" "$BOOT2" 2>/dev/null || true

mkfifo "$FIFO"

# ----------------------------------------------------------------- boot Tidal
say "booting headless Tidal ($GHCI_BIN) ..."
"$GHCI_BIN" -ghci-script="$BOOT2" < "$FIFO" > "$LOG" 2>&1 &
GHCI_PID=$!
exec 3>"$FIFO"   # hold stdin open

# wait for "Connected to SuperDirt"
connected=0
for _ in $(seq 1 200); do
  grep -q 'Connected to SuperDirt' "$LOG" 2>/dev/null && { connected=1; break; }
  kill -0 "$GHCI_PID" 2>/dev/null || break
  sleep 0.2
done
[[ $connected -eq 1 ]] || { say "ghci output:"; cat "$LOG" >&2; die "Tidal never connected to SuperDirt"; }
say "connected to SuperDirt on port $DIRT_PORT"

# ----------------------------------------------------------------- start capture
say "starting isolated capture of '${NODE}' output ..."
pw-record --properties "{ node.autoconnect = false node.name = ${CAPNAME} }" \
          --rate "$RATE" --channels 2 "$RAW" &
REC_PID=$!

# wait for the capture node's input ports, then wire ONLY scsynth -> capture
cap_ready=0
for _ in $(seq 1 50); do
  pw-link -i 2>/dev/null | grep -q "^${CAPNAME}:" && { cap_ready=1; break; }
  sleep 0.1
done
[[ $cap_ready -eq 1 ]] || die "capture node '${CAPNAME}' never appeared"

mapfile -t CAP_INS < <(pw-link -i 2>/dev/null | grep -E "^${CAPNAME}:" | sort -V)
n=${#SC_OUTS[@]}; [[ ${#CAP_INS[@]} -lt $n ]] && n=${#CAP_INS[@]}
linked=0
for ((k=0;k<n;k++)); do
  pw-link "${SC_OUTS[$k]}" "${CAP_INS[$k]}" 2>/dev/null && linked=$((linked+1))
done
[[ $linked -ge 1 ]] || die "failed to link ${NODE} output to capture"
say "linked $linked channel(s): ${SC_OUTS[*]} -> ${CAPNAME}"

# ----------------------------------------------------------------- play
sleep "$LEADIN"
say "playing $INPUT ..."
# Split the file into blank-line-delimited paragraphs and send each as a
# GHCi multiline block (:{ ... :}). A paragraph is further split at every
# top-level `let` so that several `let`s in one paragraph become separate
# statements (GHCi can't parse multiple `let`s in one block). Paragraphs that
# are only comments/blank are skipped.
awk 'BEGIN{RS="";FS="\n"}
{
  code=0
  for(i=1;i<=NF;i++){ l=$i; sub(/^[ \t]+/,"",l); if(l!="" && l!~/^--/) code=1 }
  if(!code) next
  print ":{"
  for(i=1;i<=NF;i++){
    if(i>1 && $i ~ /^let /){ print ":}"; print ":{" }
    print $i
  }
  print ":}"
}' "$INPUT" >&3

say "holding ${TAIL}s for release tails ..."
sleep "$TAIL"

# ----------------------------------------------------------------- stop
kill "$REC_PID" 2>/dev/null; wait "$REC_PID" 2>/dev/null; REC_PID=""
printf ':quit\n' >&3 2>/dev/null
exec 3>&-
wait "$GHCI_PID" 2>/dev/null; GHCI_PID=""

[[ -s "$RAW" ]] || die "capture file is empty — nothing was recorded"

# ----------------------------------------------------------------- post-process
# Pass A: strip the leading silence (boot/lead-in) before the note onset.
TRIM="$TMP/trim.wav"
ffmpeg -hide_banner -loglevel error -y -i "$RAW" \
  -af "silenceremove=start_periods=1:start_duration=0.05:start_threshold=${THRESH}:detection=rms" \
  "$TRIM" || die "ffmpeg (trim) failed"

D="$(ffprobe -hide_banner -v error -show_entries format=duration -of csv=p=0 "$TRIM" 2>/dev/null)"
[[ -n "$D" ]] || die "could not read trimmed duration (empty capture?)"

# Optional hard cap on length.
if [[ -n "$DURATION" ]]; then
  EFF="$(awk -v d="$D" -v c="$DURATION" 'BEGIN{printf "%.3f",(c<d?c:d)}')"
else
  EFF="$D"
fi

# Pass B: tiny fade-in (declick) + computed fade-out + optional cap + normalize.
FILT="afade=t=in:st=0:d=0.03"
if [[ -n "$FADE" && "$FADE" != "0" && "$FADE" != "0.0" ]]; then
  FOUT="$(awk -v d="$EFF" -v f="$FADE" 'BEGIN{x=d-f; if(x<0)x=0; printf "%.3f",x}')"
  FILT="${FILT},afade=t=out:st=${FOUT}:d=${FADE}"
fi
if [[ -n "$DURATION" ]]; then
  FILT="atrim=0:${EFF},asetpts=PTS-STARTPTS,${FILT}"
fi
if [[ $NORMALIZE -eq 1 && -n "$LUFS" ]]; then
  FILT="${FILT},loudnorm=I=${LUFS}:TP=${TP}:LRA=11"
elif [[ -n "$GAIN" ]]; then
  FILT="${FILT},volume=${GAIN}dB"
fi

mkdir -p "$(dirname "$OUTPUT")"
say "rendering -> $OUTPUT  (length ${EFF}s)"
ffmpeg -hide_banner -loglevel error -y -i "$TRIM" -af "$FILT" -ar "$RATE" -ac 2 "$OUTPUT" \
  || die "ffmpeg failed"

if [[ $KEEP_RAW -eq 1 ]]; then
  RAWOUT="${OUTPUT%.*}.raw.wav"
  cp "$RAW" "$RAWOUT"
  say "kept raw capture -> $RAWOUT"
fi

say "done:"
ffmpeg -hide_banner -nostats -i "$OUTPUT" -af volumedetect -f null - 2>&1 \
  | grep -E 'Duration|mean_volume|max_volume' | sed 's/^/    /' >&2
