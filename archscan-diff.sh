#!/usr/bin/env bash
#
# archscan-diff.sh: the step behind action.yml. Inputs arrive as INPUT_* variables, the pull request
# as PR_NUMBER and PR_HEAD_REPO, and the token as GH_TOKEN.
#
#   1. the policy: the pull request's archscan.yaml or, with policy: base, the base commit's, which then
#      also decides how the head is scanned, so a pull request cannot narrow the scan through its config
#   2. the baseline: a scan of the base commit (a git worktree, built first), or a committed model.json,
#      read from the base commit when there is one so a pull request cannot change it
#   3. a scan of the head checkout (built first)
#   4. archscan diff of the two snapshots, gated by the policy
#   5. the report into the job summary, and one pull request comment per working-directory and config
#   6. the exit code of archscan diff: 0 passed or disabled, 1 violations, 2 error. A failure of the step
#      itself is an error too: gate: error, with the reason in the annotation, the summary and the comment
#
# Scans and the diff run in the ArchScan image (run-archscan.sh) with the whole checkout mounted; the
# build command runs on the runner.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work=""               # this run's own directory under RUNNER_TEMP, once it exists
base_config_copy=""   # the base commit's config while it sits in the head checkout for the head scan

annotate() { # LEVEL MESSAGE: a workflow annotation, escaped so that MESSAGE cannot end the command early
  local message="${2//'%'/%25}"
  message="${message//$'\r'/%0D}"
  echo "::$1::${message//$'\n'/%0A}"
}
output() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
summary() { cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

failure_report() { # REASON [DETAILS]: the Markdown that stands in for the report when the step fails
  printf '### ArchScan architecture diff\n\nFailed: %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '\n'; printf '%s\n' "$2" | sed 's/^/    /'; fi   # a code block: shown, never rendered
}

die() { # REASON [LOG]: fail the step with exit 2, saying why wherever a verdict would have been
  local message="$1" details=""
  if [ -n "${2:-}" ] && [ -s "$2" ]; then details="$(tail -n 20 "$2")"; message+=$'\n'"$details"; fi
  annotate error "$message"
  output gate error
  output exit-code 2
  failure_report "$1" "$details" | summary
  if [ -n "$work" ] && failure_report "$1" "$details" > "$work/failure.md"; then
    upsert_comment "$work/failure.md" no || true   # an earlier comment must not keep an old verdict
  fi
  exit 2
}

skip() { # REASON: nothing to compare against yet, so the step passes
  annotate notice "Skipped: $1."
  output gate skipped
  output exit-code 0
  printf '### ArchScan architecture diff\n\nSkipped: %s.\n' "$1" | summary
  exit 0
}
first_adoption() { skip "the base commit has no $1 yet, so there is nothing to compare against"; }   # FILE

upsert_comment() { # BODY CREATE: update this config's comment with BODY, or post one when CREATE is yes
  if [ "$comment" = never ] || [ -z "${PR_NUMBER:-}" ]; then return 0; fi
  if [ -n "${PR_HEAD_REPO:-}" ] && [ "$PR_HEAD_REPO" != "${GITHUB_REPOSITORY:-}" ]; then
    annotate warning "No comment: pull requests from forks get a read-only token. The report is in the job summary."
    return 0
  fi
  local comments="repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" id
  { echo "$marker"; cat "$1"; } > "$work/comment.md"
  if ! id="$(gh api --paginate "$comments" | jq -rs --arg m "$marker" \
      '[.[][] | select(.user.type == "Bot" and (.body | startswith($m)))] | .[0].id // empty')"; then
    annotate warning "No comment: the pull request's comments could not be read."
    return 0
  fi
  if [ -n "$id" ]; then
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" -F body=@"$work/comment.md" > /dev/null \
      || annotate warning "The pull request comment could not be updated."
  elif [ "$2" = yes ]; then
    gh api -X POST "$comments" -F body=@"$work/comment.md" > /dev/null \
      || annotate warning "No comment: posting failed (does the job have pull-requests: write?)."
  fi
}

archscan() { # LOG ROOT ARGS…: run the image with the checkout at ROOT mounted; its stderr is also kept in LOG
  local log="$1" root="$2" rc=0
  shift 2
  (cd "$root" && TMPDIR="$RUNNER_TEMP" "$here/run-archscan.sh" "$image" "$@") 2> "$log" || rc=$?
  cat "$log" >&2
  return "$rc"
}

build() { # NAME DIR: run the build command in DIR
  [ -n "${INPUT_BUILD_COMMAND:-}" ] || return 0
  echo "::group::Build $1"
  (cd "$2" && bash -c "$INPUT_BUILD_COMMAND") || die "build-command failed in the $1 checkout"
  echo "::endgroup::"
}

scan() { # NAME ROOT CONFIG: scan with CONFIG, the checkout at ROOT mounted, into $work/NAME
  echo "::group::Scan $1"
  archscan "$work/$1.err" "$2" --config "$3" -o "$work/$1/architecture.dsl" --emit-json --no-ai-enrich --no-cache \
    || die "the $1 scan failed" "$work/$1.err"
  echo "::endgroup::"
  [ -f "$work/$1/model.json" ] || die "the $1 scan wrote no model.json"
}

fetch_base() { # make the base commit available locally (actions/checkout fetches one commit)
  [ -n "$base" ] || die "no base commit to compare against: run on pull_request, or pass base: or baseline-file:"
  git -C "$head_dir" cat-file -e "$base^{commit}" 2> /dev/null \
    || git -C "$head_dir" fetch --quiet --no-tags --depth=1 origin "$base" 2> "$work/git.err" \
    || die "cannot fetch the base commit $base" "$work/git.err"
}

at_base() { # FILE DEST: the base commit's FILE (relative to working-directory) into DEST; 1 when it has none
  git -C "$head_dir" rev-parse -q --verify "$base:./$1" > /dev/null || return 1
  git -C "$head_dir" show "$base:./$1" > "$2" 2> "$work/git.err" \
    || die "cannot read $1 from the base commit $base" "$work/git.err"
}

# 0. the inputs
config="${INPUT_CONFIG:-archscan.yaml}"
policy="${INPUT_POLICY:-head}"
comment="${INPUT_COMMENT:-on-change}"
image="${INPUT_IMAGE:-}"
base="${INPUT_BASE:-}"
case "$policy" in head | base) ;; *) die "policy must be head or base, not '$policy'" ;; esac
case "${INPUT_GATE:-config}" in
  config) gate_flag=() ;;
  on) gate_flag=(--gate) ;;
  off) gate_flag=(--no-gate) ;;
  *) die "gate must be config, on or off, not '$INPUT_GATE'" ;;
esac
case "$comment" in on-change | always | never) ;; *) die "comment must be on-change, always or never, not '$comment'" ;; esac
if [ -z "$image" ] || [[ "$image" == *__ARCHSCAN_VERSION__* ]]; then
  die "no image: this copy of the action was not published by an ArchScan release, so pass image:"
fi
if [ "${GITHUB_EVENT_NAME:-}" = pull_request_target ]; then
  die "pull_request_target would build the pull request's code with a write token: run on pull_request"
fi

head_dir="$(cd "${INPUT_WORKING_DIRECTORY:-.}" 2> /dev/null && pwd)" \
  || die "working-directory '${INPUT_WORKING_DIRECTORY:-.}' does not exist"
prefix="$(git -C "$head_dir" rev-parse --show-prefix 2> /dev/null)" || die "$head_dir is not a git checkout"
prefix="${prefix%/}"                 # working-directory relative to the repository root, empty at the root
repo_root="${head_dir%/"$prefix"}"   # what the head's scans mount: the whole checkout, as the base's do
[ -f "$head_dir/$config" ] || die "no $config in $head_dir"
marker="<!-- archscan-diff ${prefix:+$prefix/}$config -->"   # one comment per working-directory and config
if [[ "$base" =~ ^0+$ ]]; then   # github.event.before of a push that created the branch
  skip "the push created the branch, so there is no earlier commit to compare against"
fi

[ -n "${RUNNER_TEMP:-}" ] || die "RUNNER_TEMP is not set: run the action in a GitHub Actions job"
work="$(mktemp -d "$RUNNER_TEMP/archscan-diff.XXXXXX")" \
  || die "cannot create a directory under RUNNER_TEMP"   # one per run: two runs in a job keep both reports
cleanup() {
  git -C "$head_dir" worktree remove --force "$work/base-src" > /dev/null 2>&1 || true
  if [ -n "$base_config_copy" ]; then rm -f "$base_config_copy"; fi
}
trap cleanup EXIT

# 1. the policy
if [ "$policy" = base ]; then
  fetch_base
  policy_file="$work/policy.yaml"
  at_base "$config" "$policy_file" || first_adoption "$config"
  cmp -s "$policy_file" "$head_dir/$config" || annotate warning \
    "$config changed in this pull request; policy: base scans and gates with the base commit's copy until it merges."
else
  policy_file="$head_dir/$config"
fi

# 2. the baseline
if [ -n "${INPUT_BASELINE_FILE:-}" ] && [ -n "$base" ]; then   # the base commit's copy, never the head's
  fetch_base
  base_json="$work/baseline.json"
  if ! at_base "$INPUT_BASELINE_FILE" "$base_json"; then
    [ -f "$head_dir/$INPUT_BASELINE_FILE" ] \
      || die "baseline-file '$INPUT_BASELINE_FILE' is neither in the base commit nor in $head_dir"
    first_adoption "$INPUT_BASELINE_FILE"
  fi
elif [ -n "${INPUT_BASELINE_FILE:-}" ]; then   # no base commit (e.g. a push): the checkout's file
  base_json="$head_dir/$INPUT_BASELINE_FILE"
  [ -f "$base_json" ] || die "baseline-file '$INPUT_BASELINE_FILE' not found in $head_dir"
else
  fetch_base
  git -C "$head_dir" worktree add --quiet --detach "$work/base-src" "$base" 2> "$work/git.err" \
    || die "cannot check out the base commit $base" "$work/git.err"
  base_dir="$work/base-src${prefix:+/$prefix}"
  [ -f "$base_dir/$config" ] || first_adoption "$config"
  build base "$base_dir"
  scan base "$work/base-src" "$base_dir/$config"
  base_json="$work/base/model.json"
fi

# 3. the head, scanned with the policy's config: under policy: base a copy of the base commit's, placed
#    next to the head's own for the scan so its relative paths still name the head's sources
build head "$head_dir"
if [ "$policy" = base ]; then
  if ! base_config_copy="$(mktemp "$(dirname "$head_dir/$config")/.archscan-base-policy.XXXXXX")" \
      || ! cp "$policy_file" "$base_config_copy"; then
    die "cannot place the base commit's $config in the checkout"
  fi
  scan head "$repo_root" "$base_config_copy"
  rm -f "$base_config_copy" && base_config_copy=""
else
  scan head "$repo_root" "$head_dir/$config"
fi

# 4. the diff
rc=0
archscan "$work/diff.err" "$repo_root" diff "$base_json" "$work/head/model.json" -c "$policy_file" \
  --report "$work/diff.md" --output-json "$work/diff.json" ${gate_flag[@]+"${gate_flag[@]}"} || rc=$?
case "$rc" in 0 | 1) ;; *) die "archscan diff failed with exit code $rc" "$work/diff.err" ;; esac
if [ ! -f "$work/diff.md" ] || [ ! -f "$work/diff.json" ]; then die "archscan diff wrote no report"; fi
output exit-code "$rc"
output report "$work/diff.md"
output json "$work/diff.json"
output gate "$(jq -r .gate.status "$work/diff.json")"

# 5. the report
summary < "$work/diff.md"
create=no   # a new comment only for a diff with changes, unless comment: always
if [ "$comment" = always ] || [ "$(jq '.changes | length' "$work/diff.json")" -gt 0 ]; then create=yes; fi
upsert_comment "$work/diff.md" "$create"

# 6. the verdict
if [ "$rc" -eq 1 ]; then annotate error "$(jq -r .gate.statusLine "$work/diff.json")"; exit 1; fi
