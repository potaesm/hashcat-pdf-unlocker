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
  HASHCAT_MODE=10500                  Force a specific hashcat mode
  HASHCAT_STATUS_TIMER=30             Print hashcat status every N seconds
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
	1 | true | TRUE | yes | YES | on | ON) return 0 ;;
	*) return 1 ;;
	esac
}

detect_hashcat_modes_from_hash() {
	local hash_file="$1"
	local signature
	local v
	local r
	local length

	signature="$(head -n 1 "$hash_file")"
	if [[ -z "$signature" ]]; then
		echo "Hash file is empty: $hash_file" >&2
		exit 1
	fi

	IFS='*' read -r v r length _ <<<"${signature#\$pdf\$}"

	case "$v:$r:$length" in
	1:2:40)
		printf '10400\n'
		;;
	1:3:40)
		printf '10510\n'
		;;
	2:3:128 | 2:4:128)
		printf '25400\n10500\n'
		;;
	5:5:256)
		printf '10600\n'
		;;
	5:6:256)
		printf '10700\n'
		;;
	*)
		echo "Unsupported or unknown pdf2hashcat signature: $signature" >&2
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

	if truthy "${GSG_LOWERCASE:-}"; then
		out_ref+=("--lowercase")
	fi
	if truthy "${GSG_UPPERCASE:-}"; then
		out_ref+=("--uppercase")
	fi
	if truthy "${GSG_DIGITS:-}"; then
		out_ref+=("--digits")
	fi
}

run_hashcat_gsg() {
	local hash_file="$1"
	local mode="$2"
	shift 2
	local extra_args=("$@")
	local -a gsg_args
	local status
	local status_timer

	build_gsg_args gsg_args
	status_timer="${HASHCAT_STATUS_TIMER:-30}"

	set +e
	set +o pipefail
	gpu-scatter-gather "${gsg_args[@]}" "${GSG_MASK}" |
		hashcat \
			--potfile-path "$POTFILE_PATH" \
			--backend-ignore-hip \
			--outfile-autohex-disable \
			--status \
			--status-timer "$status_timer" \
			--stdin-timeout-abort=5 \
			-m "$mode" \
			-a 0 \
			"$hash_file" \
			"${extra_args[@]}"
	status=$?
	set -o pipefail
	set -e

	if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
		exit "$status"
	fi
}

require_cmd hashcat
require_cmd python3
require_cmd gpu-scatter-gather
require_cmd qpdf

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

HASH_FILE="$WORK_DIR/$(basename "${PDF_PATH%.*}").hash"
python3 /opt/pdf2hashcat/pdf2hashcat.py "$PDF_PATH" >"$HASH_FILE"

if [[ ! -s "$HASH_FILE" ]]; then
	echo "Failed to extract a crackable hash from $PDF_PATH" >&2
	exit 1
fi

if [[ -n "${HASHCAT_MODE:-}" ]]; then
	MODES=("$HASHCAT_MODE")
else
	mapfile -t MODES < <(detect_hashcat_modes_from_hash "$HASH_FILE")
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

echo "Extracted hash file: $HASH_FILE"
echo "Candidate hashcat modes: ${MODES[*]}"

if [[ -n "${GSG_MASK:-}" ]]; then
	echo "Cracking with gpu-scatter-gather mask: $GSG_MASK"
	echo "Hashcat status timer: ${HASHCAT_STATUS_TIMER:-30}s"
else
	echo "Set GSG_MASK before running the container." >&2
	exit 1
fi

for MODE in "${MODES[@]}"; do
	echo "Trying hashcat mode: $MODE"
	run_hashcat_gsg "$HASH_FILE" "$MODE" "${HASHCAT_EXTRA_ARGS[@]}"

	PASSWORD="$(extract_password "$HASH_FILE" "$MODE")"
	if [[ -z "$PASSWORD" ]]; then
		continue
	fi

	if qpdf --password="$PASSWORD" --decrypt "$PDF_PATH" "$OUTPUT_PDF"; then
		echo "Password found: $PASSWORD"
		echo "Unlocked PDF: $OUTPUT_PDF"
		exit 0
	fi

	echo "Recovered password did not decrypt the PDF for mode $MODE; trying next candidate mode." >&2
done

echo "Password was not found." >&2
exit 1
