#!/bin/bash
# End-to-end check: run the hook against real git repos and synthetic
# transcripts, assert what it reports. Exit 0 always; the output is the result.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/commit-log.mjs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_COMMIT_LOG_STATE="$WORK/state"
export HOME="$WORK/home"
mkdir -p "$HOME"

SINCE=$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)
OLD=$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)

newrepo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name Test
}

commit() {
  local dir="$WORK/$1" subject=$2 when=${3:-}
  echo "$RANDOM" > "$dir/f-$RANDOM"
  git -C "$dir" add -A
  if [ -n "$when" ]; then
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$dir" commit -qm "$subject"
  else
    git -C "$dir" commit -qm "$subject"
  fi
}

# A transcript is a jsonl file; the hook needs a timestamp, a cwd, and any
# tool calls it should mine for directories.
transcript() {
  local file="$WORK/$1.jsonl" cwd=$2 extra=${3:-}
  printf '{"type":"user","timestamp":"%s","cwd":"%s","message":{"role":"user","content":"hi"}}\n' \
    "$SINCE" "$cwd" > "$file"
  [ -n "$extra" ] && printf '%s\n' "$extra" >> "$file"
  printf '%s' "$file"
}

run() {
  local name=$1 tpath=$2 cwd=$3
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$name" "$tpath" "$cwd" \
    | node "$HOOK" 2>/dev/null
}

fail=0
want() { # want <label> <output> <substring>
  if printf '%s' "$2" | grep -q -- "$3"; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s (no %s in: %s)\n' "$1" "$3" "$2"; fail=1; fi
}
wantnot() {
  if printf '%s' "$2" | grep -q -- "$3"; then printf 'FAIL  %s (found %s)\n' "$1" "$3"; fail=1
  else printf 'ok    %s\n' "$1"; fi
}
silent() {
  if [ -z "$2" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s (expected nothing, got: %s)\n' "$1" "$2"; fail=1; fi
}
code() {
  printf '%s' "$3" | node "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$2" ]; then printf 'ok    %-14s exit %s\n' "$1" "$got"
  else printf 'FAIL  %-14s exit %s, wanted %s\n' "$1" "$got" "$2"; fail=1; fi
}

newrepo alpha
newrepo beta
commit alpha "before the session" "$OLD"
commit alpha "first landed"
commit alpha "second landed"

echo "reporting"
T=$(transcript alpha "$WORK/alpha")
out=$(run s1 "$T" "$WORK/alpha")
want   "reports new commits"    "$out" "first landed"
want   "reports both"           "$out" "second landed"
want   "names the repo"         "$out" "in alpha"
wantnot "excludes pre-session"  "$out" "before the session"
want   "uses systemMessage"     "$out" "systemMessage"

echo "state"
out=$(run s1 "$T" "$WORK/alpha")
silent "second run is quiet" "$out"
commit alpha "third landed"
out=$(run s1 "$T" "$WORK/alpha")
want    "reports only the new one" "$out" "third landed"
wantnot "does not repeat"          "$out" "first landed"

echo "scope"
commit beta "beta work"
# cwd is alpha; beta is reached only through a git -C in a Bash command.
BASH_CALL=$(printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"git -C %s/beta commit -m x"}}]}}' "$SINCE" "$WORK/alpha" "$WORK")
T2=$(transcript multi "$WORK/alpha" "$BASH_CALL")
out=$(run s2 "$T2" "$WORK/alpha")
want    "finds repo via git -C"    "$out" "beta work"
want    "still finds cwd repo"     "$out" "first landed"
want    "labels rows by repo"      "$out" "beta  "
wantnot "drops the single-repo in" "$out" "new in"

commit beta "via file path"
WRITE_CALL=$(printf '{"type":"assistant","timestamp":"%s","cwd":"/","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/beta/x.txt"}}]}}' "$SINCE" "$WORK")
T3=$(transcript write "/" "$WRITE_CALL")
out=$(run s3 "$T3" "/")
want "finds repo via file_path" "$out" "via file path"

echo "quiet paths"
mkdir -p "$WORK/plain"
T4=$(transcript plain "$WORK/plain")
silent "no repo, no output"  "$(run s4 "$T4" "$WORK/plain")"
silent "disabled by env"     "$(CLAUDE_COMMIT_LOG_DISABLE=1 run s5 "$T" "$WORK/alpha")"

echo "fails open"
code nostdin   0 ''
code badinput  0 'not json'
code nofile    0 '{"session_id":"x","transcript_path":"/no/such/file","cwd":"/"}'
code notime    0 "$(printf '{"session_id":"y","transcript_path":"%s","cwd":"%s"}' "$(printf '{"type":"user"}\n' > "$WORK/nots.jsonl"; printf '%s' "$WORK/nots.jsonl")" "$WORK/alpha")"

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
