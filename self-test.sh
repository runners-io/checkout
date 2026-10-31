#!/usr/bin/env bash
# Self-test for runners-io/checkout (RUN-1729): checkout.sh, against REAL git and
# a local file:// origin for everything that is data, and against a git that
# fails on purpose for everything that is control flow. No network.
#
# WHAT THIS CAN AND CANNOT PROVE. It proves the decisions (who gets the fast
# path, who gets the plain checkout, what is refused), what the mirror and the
# workspace contain afterwards (no credential in the mirror, no alternates after
# `dissociate`), and that a second run transfers only what the origin gained.
# It cannot prove a speedup on GitHub: that was measured by hand against a real
# repository (the pull request records the numbers), and the dispatch-only
# acceptance runs it on a real sticky disk.
#
# THE ONE RULE THIS TEST EXISTS TO HOLD: whatever goes wrong with the mirror, the
# step ends with `fast=false` and exit 0, so the plain actions/checkout runs and
# the job gets its source. A cache must never fail a build.

# The single-quoted $ below are deliberate: the metacharacter cases are literal
# text for the script under test, and the `bash -c` bodies take their arguments.
# shellcheck disable=SC2016,SC2012
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
# SELFTEST_KEEP=1 keeps the scratch directory, with each case's log, for reading.
trap '[ -n "${SELFTEST_KEEP:-}" ] && echo "kept: $work" || rm -rf "$work"' EXIT

fails=0
checks=0
pass() { checks=$((checks + 1)); printf 'ok    %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
expect() { # expect <description> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}
eq() { # eq <description> <got> <want>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

real_git="$(command -v git)"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# --- the origin: a bare repository at <server>/org/repo ----------------------
server="$work/server"
origin="$server/org/repo"
mkdir -p "$origin"
"$real_git" init -q --bare -b main "$origin"
seed="$work/seed"
"$real_git" init -q -b main "$seed"
g() { "$real_git" -C "$seed" -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
i=0
while [ "$i" -lt 60 ]; do
  printf 'line %s\n' "$i" >"$seed/file-$((i % 7)).txt"
  g add -A && g commit -q -m "base $i"
  i=$((i + 1))
done
g tag v1.0
metabranch='fix-$(touch${IFS}PWNED)'
g branch -q "$metabranch"
g push -q "file://$origin" main "$metabranch" v1.0
main_sha="$(g rev-parse main)"
meta_sha="$(g rev-parse "$metabranch")"
# A pull request's merge ref, as GitHub keeps it.
g checkout -q -b feature
printf 'feature\n' >"$seed/feature.txt"; g add -A; g commit -q -m feature
feature_sha="$(g rev-parse feature)"
g push -q "file://$origin" feature
"$real_git" -C "$origin" update-ref refs/pull/7/merge "$feature_sha"
"$real_git" -C "$origin" config uploadpack.allowAnySHA1InWant true
# A merge commit that is on no branch: only refs/pull/8/merge reaches it.
g checkout -q --detach main
printf 'merge only\n' >"$seed/merge-only.txt"; g add -A; g commit -q -m "merge only"
pr_only_sha="$(g rev-parse HEAD)"
g push -q "file://$origin" "HEAD:refs/pull/8/merge"
g checkout -q main

# A second repository with a different id and different history: B must never
# see A's objects.
other="$server/org/other"
mkdir -p "$other"
"$real_git" init -q --bare -b main "$other"
oseed="$work/oseed"
"$real_git" init -q -b main "$oseed"
printf 'only in B\n' >"$oseed/b-only.txt"
"$real_git" -C "$oseed" add -A
"$real_git" -C "$oseed" -c commit.gpgsign=false commit -q -m "B's only commit"
"$real_git" -C "$oseed" push -q "file://$other" main
other_sha="$("$real_git" -C "$oseed" rev-parse main)"

token='ghs_PLANTEDTOKEN0123456789abcdefghij'
b64="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"

# --- running checkout.sh ------------------------------------------------------
# run_co <case> [NAME=value ...]: a fresh job in $work/<case>. A later NAME wins;
# NAME=__unset__ removes it. The script runs with the case directory as its
# working directory, so a command injected through an input leaves a file there.
run_co() {
  local d="$work/$1"; shift
  [ -n "${KEEP_WS:-}" ] || rm -rf "$d/ws"
  rm -rf "$d/out" "$d/log"
  mkdir -p "$d/sticky" "$d/ws" "$d/home"
  : >"$d/out"
  local -a vars=(
    "PATH=$PATH" "HOME=$d/home" "GIT_CONFIG_NOSYSTEM=1"
    "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.com" "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.com"
    "GITHUB_OUTPUT=$d/out" "GITHUB_WORKSPACE=$d/ws" "RUNNER_TEMP=$d/home"
    "GITHUB_REPOSITORY=org/repo" "REPOSITORY_ID=1001" "GITHUB_SERVER_URL=file://$server" "GITHUB_API_URL="
    "GITHUB_REF=refs/heads/main" "GITHUB_SHA=$main_sha" "GITHUB_EVENT_NAME=push" "DEFAULT_BRANCH=main"
    "GHWARP_STICKY_DISK=$d/sticky"
    "INPUT_TOKEN=$token" "INPUT_FETCH_DEPTH=1" "INPUT_PERSIST_CREDENTIALS=true" "INPUT_SET_SAFE_DIRECTORY=true"
  )
  local kv n j found
  for kv in "$@"; do
    n="${kv%%=*}"; found=""
    j=0
    while [ "$j" -lt "${#vars[@]}" ]; do
      if [ "${vars[$j]%%=*}" = "$n" ]; then vars[$j]="$kv"; found=1; fi
      j=$((j + 1))
    done
    [ -n "$found" ] || vars+=("$kv")
  done
  local -a args=()
  for kv in "${vars[@]}"; do
    case "$kv" in *=__unset__) ;; *) args+=("$kv") ;; esac
  done
  (cd "$d" && env -i "${args[@]}" bash "$here/checkout.sh" >"$d/log" 2>&1)
  last_rc=$?
}
out_of() { sed -n "s/^$2=//p" "$work/$1/out" | tail -1; }
said_in() { grep -qF -- "$2" "$work/$1/log"; }
mirror_of() { printf '%s/sticky/.runners-io/checkout-mirror/%s.git' "$work/$1" "${2:-1001}"; }
gws() { "$real_git" -C "$work/$1/ws${2:+/$2}" "${@:3}"; }
objects_in() { # objects_in <git dir>: loose + packed
  "$real_git" -C "$1" count-objects -v | awk '/^count:/{c=$2} /^in-pack:/{p=$2} END{print c+p}'
}

if [ ! -f "$here/checkout.sh" ]; then
  fail "checkout.sh exists"
  printf '%s checks, %s failed\n' "$checks" "$fails"
  exit 1
fi

# A git that must never be called: for the cases that must not touch git at all.
mkdir -p "$work/nogit"
cat >"$work/nogit/git" <<'FAKE'
#!/usr/bin/env bash
echo "git $*" >>"$NOGIT_LOG"
exit 99
FAKE
chmod +x "$work/nogit/git"
export NOGIT_LOG="$work/nogit.log"

echo "== (a) no sticky disk: a plain checkout, success, git never run"
: >"$NOGIT_LOG"
run_co a "PATH=$work/nogit:/usr/bin:/bin" "GHWARP_STICKY_DISK=__unset__"
eq "unset: exits 0" "$last_rc" 0
eq "unset: fast=false" "$(out_of a fast)" false
expect "unset: says why in one line" said_in a "no sticky disk"
expect "unset: git was never run" test ! -s "$NOGIT_LOG"
run_co a2 "PATH=$work/nogit:/usr/bin:/bin" "GHWARP_STICKY_DISK="
eq "empty: fast=false" "$(out_of a2 fast)" false
run_co a3 "PATH=$work/nogit:/usr/bin:/bin" "GHWARP_STICKY_DISK=$work/does-not-exist"
eq "a path that is not a directory: fast=false, exit 0" "$(out_of a3 fast)/$last_rc" "false/0"
expect "a path that is not a directory: git never run" test ! -s "$NOGIT_LOG"
run_co a4 "PATH=$work/nogit:/usr/bin:/bin" "REPOSITORY_ID=__unset__"
eq "no repository id to key the mirror on: fast=false" "$(out_of a4 fast)" false
expect "no repository id: nothing created on the disk" test ! -e "$work/a4/sticky/.runners-io"
expect "no repository id: git never run" test ! -s "$NOGIT_LOG"

echo "== the happy path, and what each input makes ineligible"
run_co h1
eq "cold default-branch push: exits 0" "$last_rc" 0
eq "cold default-branch push builds the mirror and uses it" "$(out_of h1 fast)" true
eq "commit output" "$(out_of h1 commit)" "$main_sha"
expect "the mirror is where the design says" test -d "$(mirror_of h1)"
eq "the workspace is at the commit" "$(gws h1 "" rev-parse HEAD)" "$main_sha"
eq "on the branch, as actions/checkout leaves it" "$(gws h1 "" symbolic-ref --short HEAD)" main
expect "the workspace has the files" test -f "$work/h1/ws/file-0.txt"
expect "the workspace shares the mirror's objects" test -f "$work/h1/ws/.git/objects/info/alternates"
expect "the workspace remote is the plain URL" test "$(gws h1 "" remote get-url origin)" = "file://$server/org/repo"
expect "a notice carries the mirror's size" said_in h1 "::notice title=runners.io checkout::"

for case_ in \
  "repository|INPUT_REPOSITORY=org/elsewhere" \
  "ssh-key|INPUT_SSH_KEY=-----BEGIN-----" \
  "submodules|INPUT_SUBMODULES=recursive" \
  "lfs|INPUT_LFS=true" \
  "sparse-checkout|INPUT_SPARSE_CHECKOUT=src" \
  "filter|INPUT_FILTER=blob:none" \
  "fetch-depth 5|INPUT_FETCH_DEPTH=5" \
  "github-server-url|INPUT_GITHUB_SERVER_URL=https://ghe.example.com" \
  "pull_request_target|GITHUB_EVENT_NAME=pull_request_target" \
  "workflow_run|GITHUB_EVENT_NAME=workflow_run" \
  "path escaping the workspace|INPUT_PATH=../outside" \
  "absolute path|INPUT_PATH=/etc" ; do
  name="${case_%%|*}"; var="${case_#*|}"
  run_co inel "$var"
  eq "$name: plain checkout, exit 0" "$(out_of inel fast)/$last_rc" "false/0"
  expect "$name: the mirror is not even created" test ! -e "$work/inel/sticky/.runners-io"
done

echo "== a pull request or a feature branch never BUILDS a mirror it cannot keep"
run_co cold-pr "GITHUB_EVENT_NAME=pull_request" "GITHUB_REF=refs/pull/7/merge" "GITHUB_SHA=$feature_sha"
eq "PR on a cold disk: plain checkout" "$(out_of cold-pr fast)" false
expect "PR on a cold disk: no mirror was built" test ! -e "$(mirror_of cold-pr)"
run_co cold-feat "GITHUB_REF=refs/heads/feature" "GITHUB_SHA=$feature_sha"
eq "push to a feature branch on a cold disk: plain checkout" "$(out_of cold-feat fast)" false
run_co cold-sched "GITHUB_EVENT_NAME=schedule"
eq "a scheduled default-branch build does build it" "$(out_of cold-sched fast)" true

echo "== a PR starts warm from the default branch's mirror and changes nothing it can keep"
for w in warm-pr warm-pr2; do
  mkdir -p "$work/$w"
  cp -R "$work/h1/sticky" "$work/$w/sticky"
done
run_co warm-pr "GITHUB_EVENT_NAME=pull_request" "GITHUB_REF=refs/pull/7/merge" "GITHUB_SHA=$feature_sha"
eq "PR with a warm mirror: fast path" "$(out_of warm-pr fast)" true
eq "PR: detached at the merge commit" "$(gws warm-pr "" rev-parse HEAD)" "$feature_sha"
expect "PR: HEAD is detached" test -z "$("$real_git" -C "$work/warm-pr/ws" symbolic-ref -q HEAD)"
eq "PR: the checkout has the PR's file" "$(cat "$work/warm-pr/ws/feature.txt")" feature

run_co warm-pr2 "GITHUB_EVENT_NAME=pull_request" "GITHUB_REF=refs/pull/8/merge" "GITHUB_SHA=$pr_only_sha"
eq "a merge commit on no branch is fetched by its sha into the mirror and served" "$(out_of warm-pr2 fast)/$(gws warm-pr2 "" rev-parse HEAD)" "true/$pr_only_sha"

echo "== (b) the mirror cannot be refreshed: a plain checkout, a warning, success"
run_co b-net "GITHUB_SERVER_URL=file://$work/no-such-server"
eq "origin unreachable, no mirror: fast=false, exit 0" "$(out_of b-net fast)/$last_rc" "false/0"
expect "origin unreachable: a warning, not an error" said_in b-net "::warning title=runners.io checkout::"
expect "origin unreachable: says it is using a plain checkout" said_in b-net "plain checkout"
# An existing mirror survives an outage: the network is to blame, not the mirror.
run_co b-keep
before="$(objects_in "$(mirror_of b-keep)")"
run_co b-keep "GITHUB_SERVER_URL=file://$work/no-such-server"
eq "outage with a healthy mirror: fast=false, exit 0" "$(out_of b-keep fast)/$last_rc" "false/0"
expect "outage with a healthy mirror: the mirror is NOT deleted" test -d "$(mirror_of b-keep)"
eq "outage with a healthy mirror: the mirror is untouched" "$(objects_in "$(mirror_of b-keep)")" "$before"
# Fetch fails while the origin answers: the mirror is the suspect, so it goes.
mkdir -p "$work/shim"
cat >"$work/shim/git" <<FAKE
#!/usr/bin/env bash
# A git whose fetch into a mirror fails while everything else is real.
for a in "\$@"; do [ "\$a" = fetch ] && [ -n "\${SHIM_FETCH_FAILS:-}" ] && case " \$* " in *checkout-mirror*) echo "fatal: shim" >&2; exit 128 ;; esac; done
exec "$real_git" "\$@"
FAKE
chmod +x "$work/shim/git"
run_co b-fetch
run_co b-fetch "PATH=$work/shim:$PATH" "SHIM_FETCH_FAILS=1"
eq "fetch fails, origin answers: fast=false, exit 0" "$(out_of b-fetch fast)/$last_rc" "false/0"
expect "fetch fails, origin answers: the suspect mirror was deleted" test ! -e "$(mirror_of b-fetch)"
expect "fetch fails, origin answers: a warning" said_in b-fetch "::warning title=runners.io checkout::"
run_co b-fetch
eq "and the next run rebuilds it" "$(out_of b-fetch fast)" true
# No room on the disk.
mkdir -p "$work/fakedf"
printf '#!/usr/bin/env bash\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/x 100 99 1 99%% /\\n"\n' >"$work/fakedf/df"
chmod +x "$work/fakedf/df"
run_co b-space "PATH=$work/fakedf:$PATH"
eq "no space on the disk: fast=false, exit 0" "$(out_of b-space fast)/$last_rc" "false/0"
expect "no space: says so" said_in b-space "free"
expect "no space: no mirror was started" test ! -e "$(mirror_of b-space)"
# Over the size limit.
run_co b-big
run_co b-big "RUNNERS_IO_CHECKOUT_MIRROR_MAX_KB=1"
eq "mirror over the limit: fast=false, exit 0" "$(out_of b-big fast)/$last_rc" "false/0"
expect "mirror over the limit: says so" said_in b-big "limit"
expect "mirror over the limit: the mirror is left alone, not deleted" test -d "$(mirror_of b-big)"

# A repository the API says is over the limit is not cloned into a mirror at all,
# and the token that asked reaches curl on stdin, never in its argv.
mkdir -p "$work/fakecurl"
cat >"$work/fakecurl/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_CURL_ARGV"
cat >"$FAKE_CURL_STDIN"
printf '{\n  "id": 1,\n  "owner": {\n    "size": 1\n  },\n  "size": 99999999,\n  "name": "repo"\n}\n'
FAKE
chmod +x "$work/fakecurl/curl"
run_co b-api "PATH=$work/fakecurl:$PATH" "GITHUB_API_URL=https://api.example.test" \
  "FAKE_CURL_ARGV=$work/curl.argv" "FAKE_CURL_STDIN=$work/curl.stdin"
eq "the API says the repository is huge: fast=false, exit 0" "$(out_of b-api fast)/$last_rc" "false/0"
expect "the API says huge: no mirror was started" test ! -e "$(mirror_of b-api)"
expect "the API size is the top-level one, not a nested object's" said_in b-api "limit"
expect "the token reached curl on stdin" grep -qF -- "$token" "$work/curl.stdin"
expect "and not in curl's argv" bash -c '! grep -qF -- "$1" "$2"' _ "$token" "$work/curl.argv"

echo "== (c) a corrupt mirror is deleted and rebuilt"
run_co c
printf 'garbage\n' >"$(mirror_of c)/HEAD"
run_co c
eq "a mirror that is not a repository: rebuilt and used" "$(out_of c fast)/$last_rc" "true/0"
expect "rebuilt mirror is a repository" "$real_git" -C "$(mirror_of c)" rev-parse --is-bare-repository
expect "says it rebuilt" said_in c "rebuil"
run_co c2
for p in "$(mirror_of c2)"/objects/pack/*.pack; do head -c 100 "$p" >"$p.cut" && mv "$p.cut" "$p"; done
run_co c2
eq "truncated packs: exit 0 whatever happens" "$last_rc" 0
case "$(out_of c2 fast)" in
  true) expect "truncated packs, served: the workspace is complete" "$real_git" -C "$work/c2/ws" fsck --connectivity-only ;;
  *) expect "truncated packs, plain checkout: the broken mirror is gone" test ! -e "$(mirror_of c2)" ;;
esac
run_co c2
eq "after truncated packs the next run has a working mirror" "$(out_of c2 fast)" true
expect "and it is whole" "$real_git" -C "$(mirror_of c2)" fsck --connectivity-only

echo "== (d) no token in the mirror, anywhere"
run_co d
mirror="$(mirror_of d)"
expect "the run used the mirror" test "$(out_of d fast)" = true
leaks=0
for needle in "$token" "$b64" "x-access-token"; do
  if grep -rqaF -- "$needle" "$mirror"; then leaks=$((leaks + 1)); echo "      found '$needle' under the mirror"; fi
done
eq "grep for the planted token, its base64 header and the user name over every file in the mirror" "$leaks" 0
eq "the mirror's config names no remote at all" "$("$real_git" -C "$mirror" config --get-regexp '^(remote|url|http)\.' | wc -l | tr -d ' ')" 0
expect "CONTROL: the same grep does find it where it is meant to be (the workspace config)" grep -qaF -- "$b64" "$work/d/ws/.git/config"
expect "CONTROL: and the credential scan's own raw-bytes read of the mirror sees plain text (config)" grep -qa "bare = true" "$mirror/config"
run_co d2 "INPUT_PERSIST_CREDENTIALS=false"
expect "persist-credentials: false leaves no token in the workspace either" bash -c '! grep -rqaF -- "$1" "$2"' _ "$b64" "$work/d2/ws/.git"
expect "the token is never in the log" bash -c '! grep -qF -- "$1" "$2"' _ "$token" "$work/d/log"

echo "== (e) a second run transfers only what the origin gained"
run_co e
m="$(mirror_of e)"
base_objects="$(objects_in "$m")"
j=0
while [ "$j" -lt 3 ]; do
  printf 'new %s\n' "$j" >"$seed/new-$j.txt"; g add -A; g commit -q -m "new $j"; j=$((j + 1))
done
g push -q "file://$origin" main
new_sha="$(g rev-parse main)"
run_co e "GITHUB_SHA=$new_sha"
eq "second run is served" "$(out_of e fast)" true
eq "second run checked out the new commit" "$(gws e "" rev-parse HEAD)" "$new_sha"
after_objects="$(objects_in "$m")"
delta=$((after_objects - base_objects))
echo "      mirror objects: $base_objects -> $after_objects (delta $delta)"
expect "three new commits, three new trees, three new blobs: nine objects arrived, not the history" test "$delta" -gt 0 -a "$delta" -le 12
expect "the base history was $base_objects objects; the delta is a small fraction of it" test "$delta" -lt $((base_objects / 4))
expect "second run's workspace owns almost nothing itself" test "$(objects_in "$work/e/ws/.git")" -le 12

echo "== (f) a mirror belongs to ONE repository id"
run_co f
mirror_a="$(mirror_of f 1001)"
run_co f "REPOSITORY_ID=2002" "GITHUB_REPOSITORY=org/other" "GITHUB_SHA=$other_sha"
eq "repository B is served" "$(out_of f fast)" true
mirror_b="$(mirror_of f 2002)"
expect "B has a mirror of its own, at its own path" test -d "$mirror_b" -a "$mirror_a" != "$mirror_b"
expect "A's mirror was not touched by B (no B commit in it)" bash -c '! "$1" -C "$2" cat-file -e "$3" 2>/dev/null' _ "$real_git" "$mirror_a" "$other_sha"
expect "B's workspace has no commit of A's history" bash -c '! "$1" -C "$2" cat-file -e "$3" 2>/dev/null' _ "$real_git" "$work/f/ws" "$main_sha"
# Somebody puts A's mirror where B's belongs: it is recognised as A's and replaced.
rm -rf "$mirror_b"
cp -R "$mirror_a" "$mirror_b"
run_co f "REPOSITORY_ID=2002" "GITHUB_REPOSITORY=org/other" "GITHUB_SHA=$other_sha"
eq "A's mirror under B's name: B is still served" "$(out_of f fast)" true
expect "A's mirror under B's name: it was discarded, A's history is not in B's workspace" bash -c '! "$1" -C "$2" cat-file -e "$3" 2>/dev/null' _ "$real_git" "$work/f/ws" "$main_sha"
expect "A's mirror under B's name: what is there now holds no A commit" bash -c '! "$1" -C "$2" cat-file -e "$3" 2>/dev/null' _ "$real_git" "$mirror_b" "$main_sha"

echo "== (g) dissociate"
run_co g1 "INPUT_DISSOCIATE=true"
eq "dissociate: served" "$(out_of g1 fast)" true
expect "dissociate: no alternates file" test ! -e "$work/g1/ws/.git/objects/info/alternates"
expect "dissociate: the repository stands alone" "$real_git" -C "$work/g1/ws" fsck --connectivity-only
rm -rf "$work/g1/sticky"
expect "dissociate: and still works with the mirror gone" "$real_git" -C "$work/g1/ws" log -1 --format=%H
run_co g2
expect "CONTROL: without dissociate the alternates file is there" test -f "$work/g2/ws/.git/objects/info/alternates"

echo "== (h) nothing in an input is interpreted"
run_co h2 "INPUT_PATH=my dir/sub dir"
eq "a path with spaces: served" "$(out_of h2 fast)/$last_rc" "true/0"
expect "a path with spaces: the checkout is there" test -f "$work/h2/ws/my dir/sub dir/file-0.txt"
run_co h3
run_co h3 "GITHUB_REF=refs/heads/$metabranch" "GITHUB_SHA=$meta_sha"
eq "a branch named with shell syntax: served" "$(out_of h3 fast)/$last_rc" "true/0"
eq "a branch named with shell syntax: checked out under that name" "$("$real_git" -C "$work/h3/ws" symbolic-ref --short HEAD)" "$metabranch"
expect "a branch named with shell syntax: nothing ran" test ! -e "$work/h3/PWNED" -a ! -e "$work/PWNED"
run_co h4 "INPUT_REF=x; touch PWNED"
eq "a ref that is shell syntax and no ref: plain checkout, exit 0" "$(out_of h4 fast)/$last_rc" "false/0"
expect "a ref that is shell syntax: nothing ran" test ! -e "$work/h4/PWNED"
run_co h5 "INPUT_REF=\$(touch PWNED)"
expect "a command substitution as a ref: nothing ran" test ! -e "$work/h5/PWNED"
run_co h6 "INPUT_PATH=a\$(touch PWNED)b;c"
expect "a command substitution in a path: nothing ran" test ! -e "$work/h6/PWNED" -a ! -e "$work/h6/ws/PWNED"
eq "a command substitution in a path: the directory is literal" "$(ls "$work/h6/ws" | head -1)" 'a$(touch PWNED)b;c'

echo "== refs: depth 0, a tag, an explicit ref"
run_co r0 "INPUT_FETCH_DEPTH=0"
eq "depth 0: served" "$(out_of r0 fast)" true
eq "depth 0: the whole history" "$("$real_git" -C "$work/r0/ws" rev-list --count HEAD)" 60
expect "depth 0: every branch is there" "$real_git" -C "$work/r0/ws" rev-parse --verify -q refs/remotes/origin/feature
expect "depth 0: and the tags" "$real_git" -C "$work/r0/ws" rev-parse --verify -q refs/tags/v1.0
run_co r1 "INPUT_REF=feature" "GITHUB_SHA=$main_sha"
eq "ref: feature (a branch name): that branch" "$("$real_git" -C "$work/r1/ws" rev-parse HEAD)" "$feature_sha"
run_co r2 "INPUT_REF=v1.0"
eq "ref: a tag: detached at the tag" "$("$real_git" -C "$work/r2/ws" rev-parse HEAD)" "$("$real_git" -C "$origin" rev-parse 'v1.0^{commit}')"
run_co r3 "INPUT_REF=$meta_sha"
eq "ref: a full sha: that commit" "$("$real_git" -C "$work/r3/ws" rev-parse HEAD)" "$meta_sha"
run_co r4 "INPUT_REF=no-such-branch"
eq "ref that does not exist: plain checkout (actions/checkout gives the real error)" "$(out_of r4 fast)" false
run_co r5 "INPUT_FETCH_TAGS=true"
expect "fetch-tags at depth 1: the tags are there" "$real_git" -C "$work/r5/ws" rev-parse --verify -q refs/tags/v1.0

echo "== an existing checkout in the target is not ours to touch"
mkdir -p "$work/x/ws/.git"
KEEP_WS=1 run_co x
eq "a workspace that already has .git: plain checkout" "$(out_of x fast)" false
mkdir -p "$work/y/ws"
printf 'precious\n' >"$work/y/ws/mine.txt"
KEEP_WS=1 run_co y
expect "a non-empty target: the file is still there" test -f "$work/y/ws/mine.txt"
eq "a non-empty target: plain checkout" "$(out_of y fast)" false

echo
printf '%s checks, %s failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
