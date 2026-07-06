#!/usr/bin/env bash
#
# wgm/harvest-hive.sh — anonymize a local memories file and, once consented, report one lesson upstream.
#
# This script reads a memories file (default: .wgm/memories.md), applies a first-pass deterministic
# scrub, checks the project's Hive Growth Loop consent file (default: .github/wgm-hive.yml), and
# either prints the sanitized draft locally or files/comments on a `learning` issue upstream.
#
# Usage:
#   scripts/harvest-hive.sh [--dry-run] [--memories FILE] [--consent-file FILE] [--repo OWNER/REPO]
#
# Flags:
#   --dry-run           do everything except gh network/mutation calls; print the anonymized draft
#   --memories FILE     override the memories source (default: .wgm/memories.md)
#   --consent-file FILE override the consent file path (default: .github/wgm-hive.yml)
#   --repo OWNER/REPO   override the target repo (default: agent-frontier/wgm)
#   -h | --help         show this help
#
# Notes:
#   * Consent is opt-in by default and recorded once per project in .github/wgm-hive.yml.
#   * Anonymization is always on. It is a best-effort deterministic scrub, not a redaction guarantee.
#   * Dry run never calls `gh`; it only prints what would be written/filed.

set -euo pipefail

MEMORIES_FILE=".wgm/memories.md"
CONSENT_FILE=".github/wgm-hive.yml"
REPO="agent-frontier/wgm"
DRY_RUN=0
CONSENT=""
AUTO_REPORT=""
RAW_MEMORIES=""
DUPLICATE_NUMBER=""
TEMPLATE_HINT="assets/wgm-hive.template.yml"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --memories) [[ $# -ge 2 ]] || { echo "--memories requires a file" >&2; exit 2; }; MEMORIES_FILE="$2"; shift 2 ;;
    --consent-file) [[ $# -ge 2 ]] || { echo "--consent-file requires a file" >&2; exit 2; }; CONSENT_FILE="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { echo "--repo requires OWNER/REPO" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

consent_yaml() {
  local consent_value="$1"
  local auto_value="$2"
  cat <<EOF
consent: ${consent_value}
auto_report: ${auto_value}
sources:
  - dogfood
  - swarm
  - issues
  - cross-pollinate
EOF
}

write_or_preview_consent() {
  local file="$1"
  local consent_value="$2"
  local auto_value="$3"
  local body

  body="$(consent_yaml "$consent_value" "$auto_value")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Would write consent file %s:\n%s\n' "$file" "$body"
    return
  fi

  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$body" > "$file"
  printf 'Wrote consent file: %s\n' "$file"
}

read_yaml_bool() {
  local file="$1"
  local key="$2"
  awk -F: -v wanted="$key" '
    $1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
      value=$2
      gsub(/[[:space:]]/, "", value)
      print tolower(value)
      exit
    }
  ' "$file"
}

prompt_for_consent() {
  local question
  local answer

  question="wgm can automatically anonymize and report lessons from this build upstream to ${REPO}. Enable this for this project? [y/N]"
  printf '%s\n' "$question"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Dry run: not waiting for input; treating this run as declined.\n'
    printf 'To enable later, copy %s to %s and edit consent/auto_report there.\n' "$TEMPLATE_HINT" "$CONSENT_FILE"
    CONSENT="false"
    AUTO_REPORT="false"
    write_or_preview_consent "$CONSENT_FILE" "$CONSENT" "$AUTO_REPORT"
    return
  fi

  if [[ ! -t 0 ]]; then
    printf 'stdin is not interactive; treating this run as declined.\n'
    printf 'To enable later, copy %s to %s and edit consent/auto_report there.\n' "$TEMPLATE_HINT" "$CONSENT_FILE"
    CONSENT="false"
    AUTO_REPORT="false"
    write_or_preview_consent "$CONSENT_FILE" "$CONSENT" "$AUTO_REPORT"
    return
  fi

  read -r answer
  case "$answer" in
    y|Y|yes|YES|Yes) CONSENT="true"; AUTO_REPORT="true" ;;
    *) CONSENT="false"; AUTO_REPORT="false" ;;
  esac
  write_or_preview_consent "$CONSENT_FILE" "$CONSENT" "$AUTO_REPORT"
}

load_consent_state() {
  if [[ ! -f "$CONSENT_FILE" ]]; then
    prompt_for_consent
    return
  fi

  CONSENT="$(read_yaml_bool "$CONSENT_FILE" "consent")"
  AUTO_REPORT="$(read_yaml_bool "$CONSENT_FILE" "auto_report")"

  if [[ -z "$CONSENT" ]]; then
    CONSENT="false"
  fi
  if [[ -z "$AUTO_REPORT" ]]; then
    AUTO_REPORT="$CONSENT"
  fi
}

load_memories() {
  if ! RAW_MEMORIES="$(cat "$MEMORIES_FILE" 2>/dev/null)"; then
    printf 'Nothing to harvest: %s does not exist or is unreadable.\n' "$MEMORIES_FILE"
    return 1
  fi

  if [[ -z "$RAW_MEMORIES" ]]; then
    printf 'Nothing to harvest: %s is empty.\n' "$MEMORIES_FILE"
    return 1
  fi
}

anonymize_content() {
  # Best-effort deterministic scrub only; it lowers risk but is not a redaction guarantee.
  printf '%s' "$1" | sed -E \
    -e 's#https?://[^[:space:]]+#<redacted-url>#g' \
    -e 's#(^|[^[:alnum:]_])([[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,})([^[:alnum:]_]|$)#\1<redacted-email>\3#g' \
    -e 's#(^|[[:space:](])(/home/[^[:space:]]+/[^[:space:]]+(/[^\t[:space:])]+)*)([[:space:]),.;:!?)]|$)#\1<redacted-path>\4#g' \
    -e 's#(^|[[:space:](])(/Users/[^[:space:]]+/[^[:space:]]+(/[^\t[:space:])]+)*)([[:space:]),.;:!?)]|$)#\1<redacted-path>\4#g' \
    -e 's#(^|[[:space:](])(~[^[:space:]]*/[^[:space:]]+(/[^\t[:space:])]+)+)([[:space:]),.;:!?)]|$)#\1<redacted-path>\4#g' \
    -e 's#(ghp_[A-Za-z0-9_]+|gho_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)#<redacted-credential>#g' \
    -e 's#([Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])=[^[:space:]]+#<redacted-credential>#g' \
    -e 's#(^|[^[:alnum:]_])([A-Za-z0-9+/=_-]{20,})([^[:alnum:]_]|$)#\1<redacted-credential>\3#g' \
    -e 's#agent-frontier/wgm#<wgm-self-repo>#g' \
    -e 's#(^|[^[:alnum:]_/-])([a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9_-]*)([^[:alnum:]_/-]|$)#\1<redacted-repo>\3#g' \
    -e 's#<wgm-self-repo>#agent-frontier/wgm#g'
}

trim_spaces() {
  printf '%s' "$1" | awk '
    {
      gsub(/^[[:space:]]+/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      gsub(/[[:space:]]+/, " ", $0)
      print
    }
  '
}

derive_title() {
  local line
  local title=""

  while IFS= read -r line; do
    line="$(trim_spaces "$line")"
    if [[ -z "$line" ]]; then
      continue
    fi
    if [[ "$line" == '<!--'* ]]; then
      continue
    fi
    line="$(printf '%s' "$line" | sed -E 's/^[-*][[:space:]]+//; s/^[0-9]+[.)][[:space:]]+//')"
    title="$line"
    break
  done <<< "$1"

  if [[ -z "$title" ]]; then
    title="sanitized lesson from harvest-hive"
  fi

  title="${title#lesson: }"
  title="${title#Lesson: }"
  title="$(trim_spaces "$title")"
  if [[ ${#title} -gt 72 ]]; then
    title="${title:0:72}"
    title="$(trim_spaces "$title")"
    title="${title}..."
  fi
  printf '%s' "$title"
}

normalize_for_match() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g; s/^ +//; s/ +$//; s/ +/ /g'
}

shared_keyword_count() {
  local left="$1"
  local right="$2"
  local word
  local count=0
  local padded_right=" ${right} "

  for word in $left; do
    if [[ ${#word} -lt 4 ]]; then
      continue
    fi
    case "$word" in
      this|that|with|from|have|what|were|when|would|should|into|about|after|before|where|while|there|their|them|then|than|your|ours|ourselves|report|learn|wgm)
        continue
        ;;
    esac
    if [[ "$padded_right" == *" ${word} "* ]]; then
      count=$((count + 1))
    fi
  done

  printf '%s' "$count"
}

find_duplicate_issue() {
  local title="$1"
  local wanted
  local issue_rows
  local issue_number
  local issue_title
  local normalized_issue
  local shared

  DUPLICATE_NUMBER=""
  wanted="$(normalize_for_match "$title")"
  if [[ -z "$wanted" ]]; then
    return 1
  fi

  if ! issue_rows="$(gh issue list --repo "$REPO" --label learning --state open --json number,title --jq '.[] | [.number, .title] | @tsv')"; then
    return 2
  fi

  while IFS=$'\t' read -r issue_number issue_title; do
    normalized_issue="$(normalize_for_match "$issue_title")"
    if [[ -z "$normalized_issue" ]]; then
      continue
    fi
    if [[ "$normalized_issue" == *"$wanted"* ]]; then
      DUPLICATE_NUMBER="$issue_number"
      return 0
    fi
    if [[ "$wanted" == *"$normalized_issue"* ]]; then
      DUPLICATE_NUMBER="$issue_number"
      return 0
    fi
    shared="$(shared_keyword_count "$wanted" "$normalized_issue")"
    if [[ "$shared" -ge 3 ]]; then
      DUPLICATE_NUMBER="$issue_number"
      return 0
    fi
  done <<< "$issue_rows"

  return 1
}

print_draft() {
  local title="$1"
  local body="$2"

  printf 'Would file to %s with title: [learn]: %s\n' "$REPO" "$title"
  printf '%s\n' "$body"
}

ensure_gh_ready() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required for non-dry-run reporting." >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not authenticated; run 'gh auth login' before real reporting." >&2
    exit 1
  fi
}

load_consent_state
if ! load_memories; then
  exit 0
fi
ANONYMIZED_BODY="$(anonymize_content "$RAW_MEMORIES")"
TITLE="$(derive_title "$ANONYMIZED_BODY")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  print_draft "$TITLE" "$ANONYMIZED_BODY"
  printf 'Dry run: no gh network or mutation calls were made.\n'
  exit 0
fi

if [[ "$CONSENT" != "true" || "$AUTO_REPORT" != "true" ]]; then
  print_draft "$TITLE" "$ANONYMIZED_BODY"
  printf 'Reporting is disabled for this project. Edit %s to enable consent/auto_report.\n' "$CONSENT_FILE"
  exit 0
fi

ensure_gh_ready
dup_status=0
if find_duplicate_issue "$TITLE"; then
  COMMENT_BODY=$'Harvested another anonymized lesson that appears related:\n\n'"$ANONYMIZED_BODY"
  gh issue comment "$DUPLICATE_NUMBER" --repo "$REPO" --body "$COMMENT_BODY" >/dev/null
  printf 'Updated existing learning issue #%s in %s.\n' "$DUPLICATE_NUMBER" "$REPO"
  exit 0
else
  dup_status=$?
fi
if [[ "$dup_status" -eq 2 ]]; then
  echo "Failed to query existing learning issues from ${REPO}." >&2
  exit 1
fi

gh issue create --repo "$REPO" --title "[learn]: $TITLE" --body "$ANONYMIZED_BODY" --label learning >/dev/null
printf 'Created new learning issue in %s: [learn]: %s\n' "$REPO" "$TITLE"
