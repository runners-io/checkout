#!/usr/bin/env bash
# runners-io/checkout (RUN-1729): decide whether this job can check out from a
# git mirror on the repository's sticky disk, and if it can, do it.
#
# The contract with action.yml is one output, `fast`:
#
#   fast=true   the workspace is complete: the commit is checked out, the
#               credentials are configured as persist-credentials asks, and
#               action.yml skips the upstream actions/checkout step.
#   fast=false  nothing was left behind in the workspace, and action.yml runs the
#               upstream actions/checkout, unchanged, with every input.
#
# THIS SCRIPT NEVER FAILS THE JOB. Every route out of it is `exit 0` with one of
# those two answers. A mirror is a cache: when anything about it is wrong the
# job gets the plain checkout it would have had without us, a warning says what
# happened, and the only cost is the time the mirror would have saved.
#
# WHAT THE MIRROR IS
#
#   $RUNNERSIO_STICKY_DISK/.runners-io/checkout-mirror/<repository id>.git
#
# a bare mirror of THIS job's own repository: git objects and refs, nothing else.
# Keyed by the permanent repository id (RUN-462), never the name, which can be
# renamed or handed to somebody else; the id is also written into the mirror's
# config and checked on every use, so a mirror copied under another repository's
# name is discarded instead of read. The sticky disk is one per repository
# already, so there is no path by which another repository's job reaches it.
#
# THE TOKEN NEVER TOUCHES THE MIRROR. It reaches git through GIT_CONFIG_COUNT in
# the environment of the one fetch that needs it: not in argv, not in a config
# file, not in a remote URL. The mirror's config has no remote at all. (The
# sticky disk's credential scan reads raw bytes and refuses to keep a disk that
# holds a token, so a leak here would also freeze the disk.) The WORKSPACE gets
# the token in its own config when persist-credentials is true, as
# actions/checkout does; the workspace is not on the sticky disk.
#
# WHO MAY BUILD ONE. Only a build the sticky disk would KEEP: a push, schedule or
# dispatch of the default branch (docs/caching/sticky-disk-protection). Every
# other build only USES a mirror that is already there, so a pull request on a
# cold disk is never slowed by a clone of the whole history that would be thrown
# away when the job ends.

set -uo pipefail

out() { [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; return 0; }
say() { printf 'runners.io checkout: %s\n' "$*"; }
vlog() { [ "${verbose}" != true ] || printf 'runners.io checkout [%ss]: %s\n' "$SECONDS" "$*"; return 0; }
warn() { printf '::warning title=runners.io checkout::%s\n' "$*"; }

# Answer `fast=false` and stop. `skip` is the ordinary case (this job is not
# eligible); `skip_warn` is a mirror that should have worked and did not.
skip() { say "$1; using a plain checkout."; out fast false; out reason "$1"; exit 0; }
skip_warn() { warn "$1; using a plain checkout."; out fast false; out reason "$1"; exit 0; }

verbose="${INPUT_VERBOSE:-false}"
case "$verbose" in true|TRUE|True) verbose=true ;; *) verbose=false ;; esac
if [ "$verbose" = true ]; then export GIT_TRACE=1; fi
q=(--quiet)
[ "$verbose" != true ] || q=()

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- is this job eligible at all? ---------------------------------------------
# RUN-4188: RUNNERSIO_STICKY_DISK is the name a runners.io runner exports; GHWARP_STICKY_DISK is its old name,
# exported beside it until 2026-12-18 and the only one an image built before that change has. The new name wins.
sticky="${RUNNERSIO_STICKY_DISK:-${GHWARP_STICKY_DISK:-}}"
[ -n "$sticky" ] || skip "no sticky disk on this job"
case "$sticky" in /*) ;; *) skip "the sticky disk path is not absolute" ;; esac
{ [ -d "$sticky" ] && [ -w "$sticky" ]; } || skip "the sticky disk is not a writable directory"

repo_id="${REPOSITORY_ID:-}"
case "$repo_id" in ''|*[!0-9]*) skip "this job has no repository id to key a mirror on" ;; esac

repo="${GITHUB_REPOSITORY:-}"
[ -n "$repo" ] || skip "no repository"
input_repo="${INPUT_REPOSITORY:-}"
if [ -n "$input_repo" ] && [ "$(lc "$input_repo")" != "$(lc "$repo")" ]; then
  skip "it is checking out another repository, and a mirror is only ever of the job's own"
fi

# Anything the mirror path does not reproduce goes to the upstream action, which
# does. Listed in docs/caching/git-checkout-cache.
[ -z "${INPUT_SSH_KEY:-}" ] || skip "an SSH key is set"
case "${INPUT_SUBMODULES:-false}" in false|FALSE|False|'') ;; *) skip "submodules are requested" ;; esac
case "${INPUT_LFS:-false}" in false|FALSE|False|'') ;; *) skip "Git LFS is requested" ;; esac
case "${INPUT_SPARSE_CHECKOUT:-}" in ''|null) ;; *) skip "a sparse checkout is requested" ;; esac
case "${INPUT_FILTER:-}" in ''|null) ;; *) skip "a partial-clone filter is requested" ;; esac
depth="${INPUT_FETCH_DEPTH:-1}"
case "$depth" in 0|1) ;; *) skip "fetch-depth is $depth, and only 0 or 1 is served from the mirror" ;; esac
server="${GITHUB_SERVER_URL:-https://github.com}"
server="${server%/}"
input_server="${INPUT_GITHUB_SERVER_URL:-}"
if [ -n "$input_server" ] && [ "${input_server%/}" != "$server" ]; then skip "github-server-url names another server"; fi
# actions/checkout v7 refuses a fork's code in these two events unless the
# workflow says allow-unsafe-pr-checkout. That refusal is not ours to bypass.
case "${GITHUB_EVENT_NAME:-}" in pull_request_target|workflow_run) skip "the ${GITHUB_EVENT_NAME} event is left to actions/checkout, which guards it" ;; esac
token="${INPUT_TOKEN:-}"
[ -n "$token" ] || skip "no token"

rel="${INPUT_PATH:-}"
case "$rel" in /*) skip "path is absolute" ;; esac
case "/$rel/" in */../*) skip "path leaves the workspace" ;; esac
ws="${GITHUB_WORKSPACE:-}"
[ -n "$ws" ] || skip "no workspace"
[ -z "$rel" ] || ws="${ws%/}/$rel"
ws_created=""
if [ -e "$ws" ]; then
  [ -d "$ws" ] || skip "the target is not a directory"
  [ -z "$(ls -A "$ws" 2>/dev/null)" ] || skip "the target directory is not empty, so it is actions/checkout's to clean"
else
  ws_created=1
fi

root="${sticky%/}/.runners-io/checkout-mirror"
mirror="$root/$repo_id.git"
max_kb="${RUNNERS_IO_CHECKOUT_MIRROR_MAX_KB:-20971520}" # 20 GiB, documented
min_free_kb=1048576                                       # 1 GiB of headroom on the disk
url="$server/$repo"

b64="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
printf '::add-mask::%s\n' "$b64"

mgit() { git --git-dir="$mirror" "$@"; }
# The only place the credential is handed to git: one command's environment.
net_git() {
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.$server/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $b64" git "$@"
}
kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
objects_in_mirror() { mgit count-objects -v 2>/dev/null | awk '/^count:/{c=$2} /^in-pack:/{p=$2} END{print c+p+0}'; }

# --- room, size, and who may build ----------------------------------------------
free_kb="$(df -Pk "$sticky" 2>/dev/null | awk 'NR==2{print $4}')"
case "$free_kb" in ''|*[!0-9]*) free_kb="" ;; esac
if [ -n "$free_kb" ] && [ "$free_kb" -lt "$min_free_kb" ]; then
  skip_warn "the sticky disk has $((free_kb / 1024)) MiB free, under the 1 GiB the mirror needs to be refreshed safely"
fi
if [ -e "$mirror" ]; then
  size_kb="$(kb_of "$mirror")"
  case "$size_kb" in ''|*[!0-9]*) size_kb=0 ;; esac
  if [ "$size_kb" -gt "$max_kb" ]; then
    skip_warn "the checkout mirror is $((size_kb / 1024)) MiB, over its $((max_kb / 1024)) MiB limit, so it is no longer used (reset the sticky disk to start it again)"
  fi
fi

may_build() {
  case "${GITHUB_EVENT_NAME:-}" in
    push|schedule|workflow_dispatch|repository_dispatch|delete|page_build) ;;
    *) return 1 ;;
  esac
  [ -n "${DEFAULT_BRANCH:-}" ] && [ "${GITHUB_REF:-}" = "refs/heads/${DEFAULT_BRANCH}" ]
}

# Best effort, before a first clone of something huge: the API's size for the
# repository, in KiB. No answer means go on.
too_big_for_a_mirror() {
  local api="${GITHUB_API_URL:-}" kb
  [ -n "$api" ] && command -v curl >/dev/null 2>&1 || return 1
  kb="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -fsS --max-time 10 -K - -H 'Accept: application/vnd.github+json' "${api%/}/repos/$repo" 2>/dev/null |
    sed -n 's/^  "size": *\([0-9][0-9]*\).*/\1/p' | head -1)"
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  [ "$kb" -gt "$max_kb" ]
}

# --- the mirror ----------------------------------------------------------------
mirror_ok() {
  [ "$(mgit rev-parse --is-bare-repository 2>/dev/null)" = true ] || return 1
  [ "$(mgit config --get runnersio.repository-id 2>/dev/null)" = "$repo_id" ] || return 1
}

create_mirror() {
  rm -rf "$mirror"
  mkdir -p "$root" || return 1
  git -c init.defaultBranch=main init -q --bare "$mirror" || return 1
  mgit config runnersio.repository-id "$repo_id" || return 1
  # A background gc after the job would still be writing when the disk is saved.
  mgit config gc.autoDetach false || return 1
  mgit config maintenance.auto false || return 1
}

refresh_mirror() {
  net_git --git-dir="$mirror" -c gc.auto=0 -c maintenance.auto=false fetch ${q[@]+"${q[@]}"} --no-tags --prune "$url" \
    '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
  local rc=$?
  rm -f "$mirror/FETCH_HEAD"
  return $rc
}

origin_answers() { net_git ls-remote --exit-code "$url" HEAD >/dev/null 2>&1; }

ensure_mirror() {
  local attempt=1 fresh
  while [ "$attempt" -le 2 ]; do
    if [ -e "$mirror" ] && ! mirror_ok; then
      warn "the checkout mirror on the sticky disk is not usable; rebuilding it"
      rm -rf "$mirror"
    fi
    if [ ! -e "$mirror" ]; then
      may_build || skip "there is no checkout mirror yet, and only a push or schedule on the default branch builds one that the sticky disk keeps"
      if too_big_for_a_mirror; then
        skip_warn "the repository is over the $((max_kb / 1024)) MiB limit for a checkout mirror"
      fi
      vlog "building the mirror"
      create_mirror || { rm -rf "$mirror"; skip_warn "could not create the checkout mirror"; }
      fresh=1
    else
      fresh=""
    fi
    vlog "fetching into the mirror"
    if refresh_mirror; then return 0; fi
    if [ -n "$fresh" ]; then
      rm -rf "$mirror"
      skip_warn "the first fetch into a new checkout mirror failed"
    fi
    if ! origin_answers; then
      skip_warn "could not reach $server to refresh the checkout mirror; it is kept for next time"
    fi
    warn "fetching into the checkout mirror failed although $server answers; deleting the mirror and rebuilding it"
    rm -rf "$mirror"
    attempt=$((attempt + 1))
  done
  skip_warn "the checkout mirror could not be rebuilt"
}

objects_before=0
[ ! -e "$mirror" ] || objects_before="$(objects_in_mirror)"
ensure_mirror

# --- what to check out -----------------------------------------------------------
sha_re='^[0-9a-f]{40}$'
target_ref=""
target_sha=""
input_ref="${INPUT_REF:-}"
lookup_ref() { # lookup_ref <full ref name> -> sets target_sha, or leaves it empty
  target_sha="$(mgit rev-parse --verify -q "$1^{commit}" 2>/dev/null)" || target_sha=""
}
if [ -z "$input_ref" ]; then
  target_ref="${GITHUB_REF:-}"
  target_sha="${GITHUB_SHA:-}"
elif [[ "$input_ref" =~ $sha_re ]]; then
  target_ref="$input_ref"
  target_sha="$input_ref"
else
  case "$input_ref" in
    refs/heads/*|refs/tags/*)
      target_ref="$input_ref"
      lookup_ref "$input_ref" ;;
    refs/*) skip "ref $input_ref is neither a branch nor a tag" ;;
    *)
      target_ref="refs/heads/$input_ref"
      lookup_ref "$target_ref"
      if [ -z "$target_sha" ]; then
        target_ref="refs/tags/$input_ref"
        lookup_ref "$target_ref"
      fi ;;
  esac
fi
[[ "$target_sha" =~ $sha_re ]] || skip "ref '$input_ref' is not in the repository's branches or tags"

wanted_ref=refs/runnersio/wanted
if ! mgit cat-file -e "$target_sha^{commit}" 2>/dev/null; then
  # A pull request's merge commit, or a commit a force-push has since orphaned:
  # on no branch the mirror holds. Ask for it by id, as actions/checkout does.
  vlog "fetching $target_sha by id"
  net_git --git-dir="$mirror" -c gc.auto=0 -c maintenance.auto=false fetch ${q[@]+"${q[@]}"} --no-tags "$url" "+$target_sha:$wanted_ref" >/dev/null 2>&1
  rm -f "$mirror/FETCH_HEAD"
  mgit cat-file -e "$target_sha^{commit}" 2>/dev/null || skip_warn "commit $target_sha is not available from $server"
fi

# --- the workspace ---------------------------------------------------------------
cleanup_ws() {
  if [ -n "$ws_created" ]; then
    rm -rf "$ws"
  elif [ -n "$ws" ] && [ "$ws" != / ]; then
    find "$ws" -mindepth 1 -delete 2>/dev/null
  fi
}

wgit() { git -C "$ws" "$@"; }

build_workspace() {
  local name sha branch=""
  mkdir -p "$ws/.git/objects/info" || return 1
  git -c init.defaultBranch=main init -q "$ws" || return 1
  wgit remote add origin "$url" || return 1
  printf '%s\n' "$mirror/objects" >"$ws/.git/objects/info/alternates" || return 1

  # Refs the way a full-history fetch leaves them (depth 0), or just the one
  # being checked out (depth 1), written straight from the mirror: the objects
  # are already visible through the alternates, so nothing is copied.
  if [ "$depth" = 0 ] || [ "${INPUT_FETCH_TAGS:-false}" = true ]; then
    mgit for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags |
      while read -r sha name; do
        case "$name" in
          refs/heads/*) if [ "$depth" = 0 ]; then printf 'create refs/remotes/origin/%s %s\n' "${name#refs/heads/}" "$sha"; fi ;;
          refs/tags/*) printf 'create %s %s\n' "$name" "$sha" ;;
        esac
      done | wgit update-ref --stdin || return 1
  fi

  export GIT_LFS_SKIP_SMUDGE=1
  case "$target_ref" in
    refs/heads/*)
      branch="${target_ref#refs/heads/}"
      case "$branch" in -*) return 1 ;; esac
      wgit update-ref "refs/remotes/origin/$branch" "$target_sha" || return 1
      wgit checkout ${q[@]+"${q[@]}"} --force -B "$branch" "$target_sha" || return 1
      wgit branch ${q[@]+"${q[@]}"} --set-upstream-to="origin/$branch" >/dev/null 2>&1
      ;;
    refs/pull/*)
      wgit update-ref "refs/remotes/${target_ref#refs/}" "$target_sha" || return 1
      wgit checkout ${q[@]+"${q[@]}"} --force --detach "$target_sha" || return 1
      ;;
    *)
      wgit checkout ${q[@]+"${q[@]}"} --force --detach "$target_sha" || return 1
      ;;
  esac

  if [ "${INPUT_DISSOCIATE:-false}" = true ]; then
    vlog "dissociating the workspace from the mirror"
    wgit repack -a -d -q || return 1
    rm -f "$ws/.git/objects/info/alternates"
    wgit cat-file -e "$target_sha^{tree}" || return 1
  fi

  if [ "${INPUT_PERSIST_CREDENTIALS:-true}" != false ]; then
    wgit config --local "http.$server/.extraheader" "AUTHORIZATION: basic $b64" || return 1
  fi
  if [ "${INPUT_SET_SAFE_DIRECTORY:-true}" != false ]; then
    git config --global --add safe.directory "$ws" 2>/dev/null
  fi
  return 0
}

vlog "building the workspace"
if ! build_workspace; then
  cleanup_ws
  rm -rf "$mirror"
  skip_warn "checking out from the mirror failed, so the mirror was deleted and the next default-branch build will make a new one"
fi
mgit update-ref -d "$wanted_ref" >/dev/null 2>&1

# --- upkeep: git gc, in the foreground, because the disk is saved when the job ends
gc_marker="$mirror/runnersio-last-gc"
mgit -c gc.autoDetach=false gc --auto --quiet >/dev/null 2>&1
if [ ! -e "$gc_marker" ]; then
  : >"$gc_marker"
elif [ -n "$(find "$gc_marker" -mtime +7 2>/dev/null)" ]; then
  vlog "weekly gc"
  if command -v timeout >/dev/null 2>&1; then
    timeout 300 git --git-dir="$mirror" -c gc.autoDetach=false gc --quiet --prune=2.weeks.ago >/dev/null 2>&1
  else
    mgit -c gc.autoDetach=false gc --quiet --prune=2.weeks.ago >/dev/null 2>&1
  fi
  : >"$gc_marker"
fi

objects_after="$(objects_in_mirror)"
size_mib=$(($(kb_of "$mirror") / 1024))
printf '::notice title=runners.io checkout::served from the repository'"'"'s checkout mirror: %s new objects fetched, mirror %s MiB on the sticky disk (counted against the sticky-disk cap)\n' \
  "$((objects_after > objects_before ? objects_after - objects_before : 0))" "$size_mib"
out fast true
out ref "$target_ref"
out commit "$target_sha"
exit 0
