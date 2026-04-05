#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  unlock-pdf <pdf-path> [additional hashcat args...]

Environment:
  GSG_MASK='?1?1?1?1?1?1'             Use gpu-scatter-gather over stdin
  GSG_CHARSET1=abc123                 Custom charset for -1
  GSG_CHARSET2=...                    Custom charset for -2
  GSG_CHARSET3=...                    Custom charset for -3
  GSG_CHARSET4=...                    Custom charset for -4
  GSG_LOWERCASE=true                  Use built-in lowercase charset
  GSG_UPPERCASE=true                  Use built-in uppercase charset
  GSG_DIGITS=true                     Use built-in digits charset
  HASHCAT_MODE=10500                  Override auto-detected PDF mode
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

detect_hashcat_mode() {
  local pdf_path="$1"
  local encryption
  local revision

  encryption="$(qpdf --show-encryption "$pdf_path" 2>&1 || true)"

  revision="$(printf '%s\n' "$encryption" | sed -n 's/.*R = \([0-9][0-9]*\).*/\1/p' | head -n 1)"
  if [[ -z "$revision" ]]; then
    echo "Could not detect the PDF encryption revision from qpdf output." >&2
    printf '%s\n' "$encryption" >&2
    exit 1
  fi

  case "$revision" in
    2)
      printf '10400\n'
      ;;
    3|4)
      if printf '%s\n' "$encryption" | grep -qi 'AES'; then
        printf '25400\n'
      else
        printf '10500\n'
      fi
      ;;
    5)
      printf '10600\n'
      ;;
    6)
      printf '10700\n'
      ;;
    *)
      echo "Unsupported or unknown PDF encryption revision: $revision" >&2
      printf '%s\n' "$encryption" >&2
      exit 1
      ;;
  esac
}

extract_password() {
  local hash_file="$1"
  local mode="$2"
  local password_line

  password_line="$(
    hashcat \
      --potfile-path "$POTFILE_PATH" \
      --show \
      --outfile-format 2 \
      -m "$mode" \
      "$hash_file" 2>/dev/null | tail -n 1
  )"

  printf '%s\n' "$password_line"
}

build_gsg_args() {
  local -n out_ref="$1"

  out_ref=()

  [[ -n "${GSG_CHARSET1:-}" ]] && out_ref+=("-1" "${GSG_CHARSET1}")
  [[ -n "${GSG_CHARSET2:-}" ]] && out_ref+=("-2" "${GSG_CHARSET2}")
  [[ -n "${GSG_CHARSET3:-}" ]] && out_ref+=("-3" "${GSG_CHARSET3}")
  [[ -n "${GSG_CHARSET4:-}" ]] && out_ref+=("-4" "${GSG_CHARSET4}")

  truthy "${GSG_LOWERCASE:-}" && out_ref+=("--lowercase")
  truthy "${GSG_UPPERCASE:-}" && out_ref+=("--uppercase")
  truthy "${GSG_DIGITS:-}" && out_ref+=("--digits")
}

run_hashcat_gsg() {
  local hash_file="$1"
  local mode="$2"
  shift 2
  local extra_args=("$@")
  local -a gsg_args
  local status

  build_gsg_args gsg_args

  set +e
  gpu-scatter-gather "${gsg_args[@]}" "${GSG_MASK}" \
    | hashcat \
        --potfile-path "$POTFILE_PATH" \
        --backend-ignore-cuda \
        --backend-ignore-hip \
        --outfile-autohex-disable \
        --stdin-timeout-abort=5 \
        -m "$mode" \
        -a 0 \
        "$hash_file" \
        "${extra_args[@]}"
  status=$?
  set -e

  if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
    exit "$status"
  fi
}

require_cmd hashcat
require_cmd python3
require_cmd qpdf
require_cmd gpu-scatter-gather

if [[ "$#" -lt 1 ]]; then
  usage >&2
  exit 1
fi

PDF_ARG="$1"
shift
HASHCAT_EXTRA_ARGS=("$@")

INPUT_DIR="${INPUT_DIR:-/data/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/data/output}"
WORK_DIR="${WORK_DIR:-/work}"
POTFILE_PATH="${POTFILE_PATH:-$WORK_DIR/hashcat.potfile}"
OUTPUT_SUFFIX="${OUTPUT_SUFFIX:-}"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

PDF_PATH="$(readlink -f "$PDF_ARG")"
if [[ ! -f "$PDF_PATH" ]]; then
  echo "PDF file not found: $PDF_ARG" >&2
  exit 1
fi

if [[ -n "${HASHCAT_MODE:-}" ]]; then
  MODE="$HASHCAT_MODE"
else
  MODE="$(detect_hashcat_mode "$PDF_PATH")"
fi

HASH_FILE="$WORK_DIR/$(basename "${PDF_PATH%.*}").hash"
python3 /opt/pdf2hashcat/pdf2hashcat.py "$PDF_PATH" > "$HASH_FILE"

if [[ ! -s "$HASH_FILE" ]]; then
  echo "Failed to extract a crackable hash from $PDF_PATH" >&2
  exit 1
fi

if [[ "$PDF_PATH" == "$INPUT_DIR/"* ]]; then
  RELATIVE_PDF_PATH="${PDF_PATH#"$INPUT_DIR"/}"
else
  RELATIVE_PDF_PATH="$(basename "$PDF_PATH")"
fi

OUTPUT_REL_DIR="$(dirname "$RELATIVE_PDF_PATH")"
OUTPUT_BASENAME="$(basename "$RELATIVE_PDF_PATH")"

if [[ -n "$OUTPUT_SUFFIX" ]]; then
  OUTPUT_BASENAME="${OUTPUT_BASENAME%.*}${OUTPUT_SUFFIX}.${OUTPUT_BASENAME##*.}"
fi

mkdir -p "$OUTPUT_DIR/$OUTPUT_REL_DIR"
OUTPUT_PDF="$OUTPUT_DIR/$OUTPUT_REL_DIR/$OUTPUT_BASENAME"

echo "Detected hashcat mode: $MODE"
echo "Extracted hash file: $HASH_FILE"

if [[ -n "${GSG_MASK:-}" ]]; then
  echo "Cracking with gpu-scatter-gather mask: $GSG_MASK"
  run_hashcat_gsg "$HASH_FILE" "$MODE" "${HASHCAT_EXTRA_ARGS[@]}"
else
  echo "Set GSG_MASK before running the container." >&2
  exit 1
fi

PASSWORD="$(extract_password "$HASH_FILE" "$MODE")"
if [[ -z "$PASSWORD" ]]; then
  echo "Password was not found." >&2
  exit 1
fi

qpdf --password="$PASSWORD" --decrypt "$PDF_PATH" "$OUTPUT_PDF"

echo "Password found: $PASSWORD"
echo "Unlocked PDF: $OUTPUT_PDF"
