#!/bin/bash
# Self-test for bin/find-artifact: which build artifact publish.yml and
# build-pr.yml may take for a package tree. Only a run of this repository's
# build-pr.yml from one of its own branches vouches for one, or the run the
# caller names, which wins; a fork's run never does. The newest trusted
# artifact wins, every page is read, and an API error exits 2 instead of
# passing as "no artifact". gh is a stub that answers from fixtures.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# gh api, answered from $FAKE_GH: named/<label>.json (the artifacts by name;
# a 502 on the page that named.error names, and one run's share of them, a
# 502 where run-artifacts.error exists) and runinfo/<id>.json (a run). Every
# call is logged in calls, with its query.
mkdir -p "$tmp/bin" "$tmp/gh/named" "$tmp/gh/runinfo"
cat >"$tmp/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
path="" expr="" paginate=0 query=()
while (($#)); do
  case $1 in
    --jq) expr=$2; shift 2 ;;
    --paginate) paginate=1; shift ;;
    api) shift ;;
    --method) shift 2 ;;
    -f | -F) query+=("$2"); shift 2 ;;
    repos/*) path=$1; shift ;;
    *) echo "gh stub: unexpected argument $1" >&2; exit 1 ;;
  esac
done
# A query written into the path reads the way a server decodes it: "+" is
# a space.
if [[ $path == *\?* ]]; then
  IFS='&' read -ra raw <<<"${path#*\?}"
  for q in "${raw[@]}"; do query+=("${q//+/ }"); done
  path=${path%%\?*}
fi
echo "$path ${query[*]}" >>"$FAKE_GH/calls"
case $path in
  */actions/artifacts)
    # Pages the way GitHub does: per_page (default 30) at a time, every page
    # with --paginate, else the first.
    name="" per=30
    for q in "${query[@]}"; do
      case $q in
        name=*) name=${q#name=} ;;
        per_page=*) per=${q#per_page=} ;;
      esac
    done
    file=$FAKE_GH/named/$name.json
    [[ -f $file ]] || file=$FAKE_GH/empty.json
    page=0
    while :; do
      chunk=$(jq -c --argjson p "$page" --argjson n "$per" '{artifacts: .artifacts[$p * $n:($p + 1) * $n]}' "$file")
      [[ $page == 0 || $(jq '.artifacts | length' <<<"$chunk") -gt 0 ]] || break
      if [[ -f $FAKE_GH/named.error && $(cat "$FAKE_GH/named.error") == "$page" ]]; then
        echo "gh: Server Error (HTTP 502)" >&2
        exit 1
      fi
      if [[ -n $expr ]]; then jq -r "$expr" <<<"$chunk"; else echo "$chunk"; fi
      ((paginate)) || break
      page=$((page + 1))
    done
    exit ;;
  */actions/runs/*/artifacts)
    [[ ! -f $FAKE_GH/run-artifacts.error ]] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    name=""
    for q in "${query[@]}"; do [[ $q != name=* ]] || name=${q#name=}; done
    file=$FAKE_GH/named/$name.json
    [[ -f $file ]] || file=$FAKE_GH/empty.json
    chunk=$(jq -c --argjson r "$(cut -d/ -f6 <<<"$path")" '{artifacts: [.artifacts[] | select(.workflow_run.id == $r)]}' "$file")
    if [[ -n $expr ]]; then jq -r "$expr" <<<"$chunk"; else echo "$chunk"; fi
    exit ;;
  */actions/runs/*) file=$FAKE_GH/runinfo/$(cut -d/ -f6 <<<"$path").json ;;
  *) echo "gh stub: unexpected $path" >&2; exit 1 ;;
esac
[[ -f $file ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [[ -n $expr ]]; then jq -r "$expr" "$file"; else cat "$file"; fi
GH
chmod +x "$tmp/bin/gh"
echo '{"artifacts": []}' >"$tmp/gh/empty.json"
export PATH="$tmp/bin:$PATH" FAKE_GH="$tmp/gh" GITHUB_REPOSITORY=omacom/omarchy-pkgs

tree=0123456789abcdef0123456789abcdef01234567
label=hyprland-x86_64-$tree

runinfo() { # runinfo <id> <head repository|null> [path] [event]
  jq -n --arg r "$2" --arg p "${3:-.github/workflows/build-pr.yml}" --arg e "${4:-pull_request}" \
    '{path: $p, event: $e, head_repository: (if $r == "null" then null else {full_name: $r} end)}' >"$tmp/gh/runinfo/$1.json"
}
# artifacts [--label <label>] <artifact id:run id[:expired]>...: the label's
# artifacts in the order the listing returns them; the first is the newest.
artifacts() {
  local name=$label pair list='[]' n=0 id run expired
  if [[ $1 == "--label" ]]; then
    name=$2
    shift 2
  fi
  for pair in "$@"; do
    IFS=: read -r id run expired <<<"$pair"
    list=$(jq -c --arg l "$name" --argjson a "$id" --argjson r "$run" --argjson x "${expired:-false}" \
      --arg t "$(printf '2026-10-18T%02d:%02d:00Z' $((11 - n / 60)) $((59 - n % 60)))" \
      '. + [{name: $l, id: $a, expired: $x, created_at: $t, expires_at: "2026-10-25T00:00:00Z",
        archive_download_url: "https://api.github.com/repos/omacom/omarchy-pkgs/actions/artifacts/\($a)/zip", workflow_run: {id: $r}}]' <<<"$list")
    n=$((n + 1))
  done
  jq -n --argjson a "$list" '{artifacts: $a}' >"$tmp/gh/named/$name.json"
}
find_artifact() { # find_artifact [args]: status in $status, output in stdout and stderr
  : >"$tmp/gh/calls"
  status=0
  "$ROOT/bin/find-artifact" "$@" >"$tmp/stdout" 2>"$tmp/stderr" || status=$?
}
chosen() { cut -d' ' -f1-2 "$tmp/stdout"; }

runinfo 501 omacom/omarchy-pkgs
runinfo 502 omacom/omarchy-pkgs .github/workflows/build-pr.yml workflow_dispatch
runinfo 601 attacker/omarchy-pkgs
runinfo 602 omacom/omarchy-pkgs .github/workflows/evil.yml
runinfo 603 attacker/omarchy-pkgs .github/workflows/evil.yml
runinfo 604 omacom/omarchy-pkgs .github/workflows/publish.yml push
runinfo 605 attacker/omarchy-pkgs .github/workflows/build-pr.yml pull_request_review
runinfo 606 omacom/omarchy-pkgs .github/workflows/build-pr.yml push
runinfo 607 null

find_artifact "$label"
[[ $status == 1 && ! -s $tmp/stdout ]] && grep -q "$label: no artifact" "$tmp/stderr" &&
  pass "no artifact by that name: exit 1, nothing on stdout" || fail "none: $status $(cat "$tmp/stdout" "$tmp/stderr")"

artifacts 12:501
find_artifact "$label"
[[ $status == 0 && $(cat "$tmp/stdout") == "12 501 2026-10-25T00:00:00Z https://api.github.com/repos/omacom/omarchy-pkgs/actions/artifacts/12/zip" ]] &&
  pass "a build-pr.yml run of this repository vouches for its artifact" || fail "own: $status $(cat "$tmp/stdout" "$tmp/stderr")"
artifacts 13:502
find_artifact "$label"
[[ $status == 0 && $(chosen) == "13 502" ]] && pass "so does a dispatched build-pr.yml run" || fail "dispatch: $status $(cat "$tmp/stderr")"

artifacts 99:501:true 12:501
find_artifact "$label"
[[ $status == 0 && $(chosen) == "12 501" ]] && pass "an expired artifact is passed over" || fail "expired: $(cat "$tmp/stdout" "$tmp/stderr")"

# Newer uploads under the same name from runs that cannot vouch: another
# workflow of this repository, a fork's own workflow, a fork's build-pr.yml
# (the plan runs a fork's recipes on the runner), build-pr.yml on another
# event, a fork that no longer exists, or a publish.yml run the caller did
# not name.
artifacts 21:602 22:603 23:601 24:604 25:605 26:606 27:607 12:501
find_artifact "$label"
[[ $status == 0 && $(chosen) == "12 501" ]] || fail "untrusted in front: $status $(cat "$tmp/stdout" "$tmp/stderr")"
for skip in 21:602 22:603 23:601 24:604 25:605 26:606 27:607; do
  grep -qx "$label: artifact ${skip%:*} skipped: run ${skip#*:} cannot vouch for it" "$tmp/stderr" || fail "not logged: $skip: $(cat "$tmp/stderr")"
done
pass "newer artifacts from runs that cannot vouch are skipped and named, the trusted one behind them wins"

artifacts 21:602 23:601 24:604
find_artifact "$label"
[[ $status == 1 && ! -s $tmp/stdout ]] && grep -q "$label: none of its 3 artifact(s) comes from a run that can vouch for it" "$tmp/stderr" &&
  pass "only untrusted artifacts: exit 1, nothing on stdout" || fail "only untrusted: $status $(cat "$tmp/stdout" "$tmp/stderr")"

# The caller's own run (publish.yml's rebuild job) vouches for its uploads
# and wins over newer ones. They are listed on their own, first, so the
# repository-wide listing is never read for them, and neither is any run.
artifacts 21:602 12:501 31:604
find_artifact --run 604 "$label"
[[ $status == 0 && $(chosen) == "31 604" ]] && [[ $(cat "$tmp/gh/calls") == "repos/omacom/omarchy-pkgs/actions/runs/604/artifacts name=$label" ]] &&
  pass "the run named with --run wins, read from its own listing alone" || fail "--run: $status $(cat "$tmp/stdout" "$tmp/stderr" "$tmp/gh/calls")"
echo 0 >"$tmp/gh/named.error"
find_artifact --run 604 "$label"
[[ $status == 0 && $(chosen) == "31 604" ]] && pass "so a repository-wide listing that fails cannot stand between a rebuild and its publish" ||
  fail "--run past a failing listing: $status $(cat "$tmp/stderr")"
rm "$tmp/gh/named.error"
touch "$tmp/gh/run-artifacts.error"
find_artifact --run 604 "$label"
[[ $status == 2 && ! -s $tmp/stdout ]] && grep -q "cannot list run 604's artifacts" "$tmp/stderr" &&
  pass "a run listing that fails fails" || fail "run listing: $status $(cat "$tmp/stdout" "$tmp/stderr")"
rm "$tmp/gh/run-artifacts.error"
find_artifact --run 700 "$label"
[[ $status == 0 && $(chosen) == "12 501" ]] && pass "another publish.yml run does not vouch" || fail "other publish run: $(cat "$tmp/stderr")"

# Every page, newest first across them: 120 untrusted uploads fill more than
# the 100 a page holds, and the listing's own order is not trusted either.
flood=()
for _ in $(seq 1 120); do flood+=("21:602"); done
artifacts "${flood[@]}" 12:501
find_artifact "$label"
[[ $status == 0 && $(chosen) == "12 501" ]] && pass "a trusted artifact behind a page of untrusted ones is still found" || fail "pages: $(tail -n 3 "$tmp/stderr")"
grep -q 'per_page=100' "$tmp/gh/calls" && (( $(grep -c 'actions/runs/' "$tmp/gh/calls") == 2 )) &&
  pass "100 to a page, and each run read once" || fail "calls: $(sort "$tmp/gh/calls" | uniq -c)"
artifacts 12:501 13:502
jq '.artifacts |= reverse' "$tmp/gh/named/$label.json" >"$tmp/listing" && mv "$tmp/listing" "$tmp/gh/named/$label.json"
find_artifact "$label"
[[ $status == 0 && $(chosen) == "12 501" ]] && pass "the newest trusted artifact wins, whatever order the listing has" || fail "newest: $(cat "$tmp/stdout")"

# Each run read spends the repository's shared API budget: past 50 runs in
# front of a trusted one, the lookup stops and the caller rebuilds.
pairs=()
for run in $(seq 1001 1060); do
  runinfo "$run" attacker/omarchy-pkgs .github/workflows/evil.yml
  pairs+=("$run:$run")
done
artifacts "${pairs[@]}" 12:501
find_artifact "$label"
[[ $status == 2 && ! -s $tmp/stdout ]] && grep -q "more than 50 runs uploaded an artifact named $label" "$tmp/stderr" &&
  (( $(grep -c 'actions/runs/' "$tmp/gh/calls") == 50 )) &&
  pass "at most 50 runs are read for one lookup" || fail "budget: $status $(grep -c 'actions/runs/' "$tmp/gh/calls") $(tail -n 2 "$tmp/stderr")"

# makepkg allows "+" in a name; the query must carry it, not a space.
plus=libc++-x86_64-$tree
artifacts --label "$plus" 41:501
find_artifact "$plus"
[[ $status == 0 && $(chosen) == "41 501" ]] && grep -qF "name=$plus" "$tmp/gh/calls" &&
  pass "a name with + is looked up as itself" || fail "plus: $status $(cat "$tmp/stderr" "$tmp/gh/calls")"

# Errors exit 2, never "no artifact" or a pick.
artifacts 51:777 12:501
find_artifact "$label"
[[ $status == 2 && ! -s $tmp/stdout ]] && grep -q "cannot read run 777" "$tmp/stderr" &&
  pass "a run that cannot be read fails" || fail "run read: $status $(cat "$tmp/stderr")"
artifacts "${flood[@]}" 12:501
echo 1 >"$tmp/gh/named.error"
find_artifact "$label"
[[ $status == 2 && ! -s $tmp/stdout ]] && grep -q "cannot look up artifact $label" "$tmp/stderr" &&
  pass "a listing that fails on a later page fails, it does not read as fewer artifacts" || fail "listing: $status $(cat "$tmp/stdout" "$tmp/stderr")"
rm "$tmp/gh/named.error"

# The label: only a package name, an architecture and a tree hash, checked
# before any call. In en_US.UTF-8, where the system has it, [a-z] in a bash
# regex matches "ä".
wide=C.UTF-8
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  wide=en_US.UTF-8
fi
for bad in "a&name=b-x86_64-$tree" "hyprland-x86_64-$tree"$'\n' "hyprland-riscv64-$tree" "hyprland-x86_64-${tree:0:12}" \
  "-hyprland-x86_64-$tree" "hyprländ-x86_64-$tree" "../x-x86_64-$tree"; do
  LC_ALL=$wide find_artifact "$bad"
  [[ $status == 2 && ! -s $tmp/gh/calls ]] || fail "label $(printf %q "$bad"): $status $(cat "$tmp/gh/calls")"
done
for bad in abc "1 2"; do
  find_artifact --run "$bad" "$label"
  [[ $status == 2 && ! -s $tmp/gh/calls ]] || fail "run $(printf %q "$bad"): $status"
done
pass "a label or run id that is not one fails before any call"
