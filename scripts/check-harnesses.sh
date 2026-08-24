#!/usr/bin/env bash
#
# wgm/check-harnesses.sh — deterministic backpressure for the harness capability/evidence contract.
#
# wgm used to claim it runs on "any compatible coding agent". That claim is unfalsifiable: no file
# named the harnesses, no field recorded what had actually been observed, and nothing failed when
# the claim drifted from reality. compatibility/harnesses.json replaces it with a machine-checked
# record — one entry per harness, each carrying its discovery paths, its non-interactive invocation
# contract, its subagent capability, the fallback used when that capability is missing, wgm's
# adapter status, per-OS evidence, and authoritative source URLs.
#
# This gate enforces the contract's shape and its evidence rules:
#   * exactly four statuses — Verified, Expected, Degraded, Unknown — and nothing else;
#   * an allow-listed key set at every level, so a renamed or invented field fails instead of
#     drifting silently (same discipline as scripts/check-evals.sh);
#   * required non-empty values for discovery paths, the invocation command, and source URLs;
#   * Verified requires recorded discovery + non-interactive invocation + end-to-end journey
#     evidence objects — no entry can be Verified on prose alone;
#   * Expected must NOT carry journey evidence (that would make it Verified), Unknown must carry
#     none at all, and Degraded must name the missing capability;
#   * a host with no subagent primitive (`subagents.capability == "none"`) must be Degraded, and a
#     host with no documented discovery path or invocation command (the `none-documented` sentinel)
#     may never be Verified or Expected;
#   * every harness wgm publishes a claim about stays present, so an inconvenient entry cannot be
#     quietly deleted to make the table look better.
#
# It fails closed: a missing file, malformed JSON, a duplicate id, an unsupported value, or a
# missing required key is RED, never a silent pass. No network and no vendor CLI are needed — this
# checks the record, not the harnesses themselves (running them is what produces journey evidence).
#
# Point it at exactly one fixture with $WGM_HARNESSES (scripts/test-check-harnesses.sh uses this to
# probe drift cases). See references/harness-portability.md for the contract in prose.
#
# Exit 0 = green. Exit 1 = red (failures listed). Exit 2 = jq missing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FILE="${WGM_HARNESSES:-compatibility/harnesses.json}"

FAIL=0
note() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
ok()   { printf 'ok:   %s\n' "$*"; }

if ! command -v jq >/dev/null 2>&1; then
  note "jq is required but not found on PATH (see CONTRIBUTING.md's Dev prerequisites)"
  echo "harnesses: RED" >&2
  exit 2
fi

if [[ ! -f "$FILE" ]]; then
  note "$FILE is missing"
  echo "harnesses: RED" >&2
  exit 1
fi

if ! jq empty "$FILE" 2>/dev/null; then
  note "$FILE is not valid JSON"
  echo "harnesses: RED" >&2
  exit 1
fi

# Every harness wgm makes a public claim about. Deleting one is drift, not a fix: an entry that has
# become inconvenient (a Degraded host, an Unknown one) is exactly the entry a reader needs.
REQUIRED_IDS='["aider","claude-code","codex-cli","copilot-cli","cursor","gemini-cli","opencode","pi","windsurf"]'

read -r -d '' JQ_PROGRAM <<'JQ'
def ne: type == "string" and (length > 0);
def nearr: type == "array" and (length > 0) and (all(.[]; ne));
def oneof($allowed): . as $v | ($allowed | index($v)) != null;
def keycheck($allowed; $where):
  ( ((keys_unsorted - $allowed) | map("\($where) has an unexpected key: '\(.)'"))
  + (($allowed - keys_unsorted) | map("\($where) is missing required key: '\(.)'")) )[];

def statuses_allowed: ["Degraded","Expected","Unknown","Verified"];
def entry_allowed: ["adapter","evidence","fallback","id","invocation","missing_capability","name","notes","os_evidence","skill_discovery","sources","status","subagents"];
def discovery_allowed: ["notes","paths","verification"];
def invocation_allowed: ["command","non_interactive","notes","verification"];
def subagents_allowed: ["capability","notes"];
def adapter_allowed: ["notes","status"];
def os_allowed: ["linux","macos","windows"];
def evidence_allowed: ["detail","kind","ref"];
def verification_allowed: ["documented","unverified","verified"];
def capability_allowed: ["host-dispatched","native","none","unknown"];
def adapter_status_allowed: ["adapter-needed","adapter-shipped","kernel-only","unknown"];
def evidence_kind_allowed: ["discovery","invocation","journey"];

def entrycheck($i):
  . as $e
  | ("harnesses[\($i)] (id=\($e.id // "?"))") as $w
  | if ($e | type) != "object" then "\($w) must be a JSON object"
    else
      ( $e | keycheck(entry_allowed; $w) ),
      ( if ($e.id | ne) and ($e.id | test("^[a-z0-9][a-z0-9-]*$")) then empty
        else "\($w) 'id' must be a non-empty lowercase slug" end ),
      ( if ($e.name | ne) then empty else "\($w) 'name' must be a non-empty string" end ),
      ( if ($e.notes | ne) then empty else "\($w) 'notes' must be a non-empty string" end ),
      ( if ($e.fallback | ne) then empty
        else "\($w) 'fallback' must name the behavior used when a capability is missing" end ),
      ( if ($e.missing_capability | type) == "string" then empty
        else "\($w) 'missing_capability' must be a string (empty when nothing is missing)" end ),
      ( if ($e.status | oneof(statuses_allowed)) then empty
        else "\($w) has an unsupported status: '\($e.status // "")' (allowed: Verified, Expected, Degraded, Unknown)" end ),

      ( if ($e.skill_discovery | type) != "object" then "\($w) 'skill_discovery' must be an object"
        else
          ( $e.skill_discovery | keycheck(discovery_allowed; "\($w) skill_discovery") ),
          ( if ($e.skill_discovery.paths | nearr) then empty
            else "\($w) 'skill_discovery.paths' must be a non-empty array of non-empty paths (use \"none-documented\" when a host documents none)" end ),
          ( if ($e.skill_discovery.verification | oneof(verification_allowed)) then empty
            else "\($w) 'skill_discovery.verification' must be one of verified/documented/unverified" end ),
          ( if ($e.skill_discovery.notes | ne) then empty
            else "\($w) 'skill_discovery.notes' must be a non-empty string" end )
        end ),

      ( if ($e.invocation | type) != "object" then "\($w) 'invocation' must be an object"
        else
          ( $e.invocation | keycheck(invocation_allowed; "\($w) invocation") ),
          ( if ($e.invocation.command | ne) then empty
            else "\($w) 'invocation.command' must be a non-empty command (use \"none-documented\" when a host documents none)" end ),
          ( if ($e.invocation.non_interactive | type) == "boolean" then empty
            else "\($w) 'invocation.non_interactive' must be a boolean" end ),
          ( if ($e.invocation.verification | oneof(verification_allowed)) then empty
            else "\($w) 'invocation.verification' must be one of verified/documented/unverified" end ),
          ( if ($e.invocation.notes | ne) then empty
            else "\($w) 'invocation.notes' must be a non-empty string" end ),
          ( if ($e.invocation.command == "none-documented") and ($e.invocation.non_interactive == true)
            then "\($w) claims a non-interactive mode but documents no command" else empty end )
        end ),

      ( if ($e.subagents | type) != "object" then "\($w) 'subagents' must be an object"
        else
          ( $e.subagents | keycheck(subagents_allowed; "\($w) subagents") ),
          ( if ($e.subagents.capability | oneof(capability_allowed)) then empty
            else "\($w) 'subagents.capability' must be one of native/host-dispatched/none/unknown" end ),
          ( if ($e.subagents.notes | ne) then empty
            else "\($w) 'subagents.notes' must be a non-empty string" end ),
          ( if ($e.subagents.capability == "none") and ($e.status != "Degraded")
            then "\($w) has no subagent primitive, so its status must be Degraded with a named fallback (found '\($e.status // "")')"
            else empty end )
        end ),

      ( if ($e.adapter | type) != "object" then "\($w) 'adapter' must be an object"
        else
          ( $e.adapter | keycheck(adapter_allowed; "\($w) adapter") ),
          ( if ($e.adapter.status | oneof(adapter_status_allowed)) then empty
            else "\($w) 'adapter.status' must be one of adapter-shipped/adapter-needed/kernel-only/unknown" end ),
          ( if ($e.adapter.notes | ne) then empty
            else "\($w) 'adapter.notes' must be a non-empty string" end )
        end ),

      ( if ($e.os_evidence | type) != "object" then "\($w) 'os_evidence' must be an object"
        else
          ( $e.os_evidence | keycheck(os_allowed; "\($w) os_evidence") ),
          ( $e.os_evidence | to_entries[] | select((.value | ne) | not)
            | "\($w) 'os_evidence.\(.key)' must be a non-empty statement of what is (or is not) evidenced" )
        end ),

      ( if ($e.sources | nearr) then empty
        else "\($w) 'sources' must be a non-empty array of authoritative URLs" end ),
      ( ($e.sources // []) | if type == "array" then .[] else empty end
        | select((type == "string" and startswith("https://")) | not)
        | "\($w) has a source that is not an https:// URL: '\(. | tostring)'" ),

      ( if ($e.evidence | type) != "array" then "\($w) 'evidence' must be an array (empty when nothing is recorded)"
        else
          ( $e.evidence | to_entries[] | .key as $j | .value as $ev
            | ( if ($ev | type) != "object" then "\($w) evidence[\($j)] must be an object"
                else
                  ( $ev | keycheck(evidence_allowed; "\($w) evidence[\($j)]") ),
                  ( if ($ev.kind | oneof(evidence_kind_allowed)) then empty
                    else "\($w) evidence[\($j)] 'kind' must be one of discovery/invocation/journey" end ),
                  ( if ($ev.ref | ne) then empty
                    else "\($w) evidence[\($j)] 'ref' must be a non-empty reference" end ),
                  ( if ($ev.detail | ne) then empty
                    else "\($w) evidence[\($j)] 'detail' must be a non-empty description" end )
                end ) )
        end ),

      # Status-specific evidence rules — the part that makes the statuses falsifiable.
      ( ( ($e.evidence // []) | if type == "array" then map(.kind // "") else [] end ) as $kinds
        | if $e.status == "Verified" then
            ( ["discovery","invocation","journey"] - $kinds
              | map("\($w) is Verified without \(.) evidence")
              | .[] ),
            ( if ($e.skill_discovery.verification == "verified") then empty
              else "\($w) is Verified but 'skill_discovery.verification' is not 'verified'" end ),
            ( if ($e.invocation.verification == "verified") then empty
              else "\($w) is Verified but 'invocation.verification' is not 'verified'" end ),
            ( if ($e.invocation.non_interactive == true) then empty
              else "\($w) is Verified but records no non-interactive invocation" end ),
            ( if ($e.skill_discovery.paths | index("none-documented")) == null then empty
              else "\($w) is Verified but documents no discovery path" end )
          elif $e.status == "Expected" then
            ( if ($kinds | index("journey")) == null then empty
              else "\($w) is Expected but carries journey evidence — record it as Verified instead" end ),
            ( if (($e.skill_discovery.paths | index("none-documented")) == null)
                 and ($e.invocation.command != "none-documented") then empty
              else "\($w) is Expected but has no documented discovery path or invocation command — Degraded or Unknown is the honest status" end )
          elif $e.status == "Degraded" then
            ( if ($e.missing_capability | ne) then empty
              else "\($w) is Degraded but names no missing capability" end )
          elif $e.status == "Unknown" then
            ( if (($e.evidence // []) | length) == 0 then empty
              else "\($w) is Unknown but carries evidence — record the status the evidence supports" end )
          else empty end )
    end;

if type != "object" then "top level must be a JSON object"
else
  keycheck(["_see","contract_version","harnesses","statuses"]; "top level"),
  ( if (._see | ne) then empty else "top-level '_see' must point at the prose contract" end ),
  ( if (.contract_version | ne) then empty else "top-level 'contract_version' must be a non-empty string" end ),
  ( if (.statuses | type) != "object" then "top-level 'statuses' must be an object"
    else
      ( .statuses | keycheck(statuses_allowed; "statuses") ),
      ( .statuses | to_entries[] | select((.value | ne) | not)
        | "statuses.\(.key) must carry a non-empty definition" )
    end ),
  ( if (.harnesses | type) != "array" or ((.harnesses | length) == 0)
    then "top-level 'harnesses' must be a non-empty array"
    else
      ( .harnesses | to_entries[] | .key as $i | .value | entrycheck($i) ),
      ( .harnesses | map(.id // "") | group_by(.) | map(select(length > 1)) | .[]
        | "duplicate harness id: '\(.[0])'" ),
      ( ($required_ids - (.harnesses | map(.id // ""))) | .[]
        | "required harness entry is missing: '\(.)'" )
    end )
end
JQ

PROBLEMS="$(jq -r --argjson required_ids "$REQUIRED_IDS" "$JQ_PROGRAM" "$FILE" 2>&1)"
JQ_RC=$?

if (( JQ_RC != 0 )); then
  note "$FILE could not be evaluated: $PROBLEMS"
  echo "harnesses: RED" >&2
  exit 1
fi

while IFS= read -r problem; do
  [[ -z "$problem" ]] && continue
  note "$FILE $problem"
done <<< "$PROBLEMS"

if (( FAIL == 0 )); then
  count=$(jq '.harnesses | length' "$FILE")
  verified=$(jq '[.harnesses[] | select(.status == "Verified")] | length' "$FILE")
  ok "$FILE contract valid (${count} harness(es), ${verified} Verified with full evidence)"
  echo "harnesses: GREEN"
  exit 0
fi

echo "harnesses: RED" >&2
exit 1
