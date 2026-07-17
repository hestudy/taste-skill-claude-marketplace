#!/usr/bin/env bash
# Merge Leonxlnx/taste-skill into the current branch while preserving this
# fork's Claude Code marketplace expansion and README overlay blocks.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/Leonxlnx/taste-skill.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

# README regions that must survive upstream merges (name without wrappers).
README_MARKERS=(
  "CLAUDE-FORK-NOTE"
  "CLAUDE-MARKETPLACE-INSTALL"
  "CLAUDE-FORK-DOCS"
)

PRESERVE_DIR=""
BLOCKS_DIR=""

log() { printf '%s\n' "$*"; }

cleanup() {
  # Use if/fi (not `[[ ]] &&`) so an empty dir does not make the EXIT trap
  # return 1 under `set -e` and flip a successful sync into a failed job.
  if [[ -n "${PRESERVE_DIR}" && -d "${PRESERVE_DIR}" ]]; then
    rm -rf "${PRESERVE_DIR}"
  fi
  if [[ -n "${BLOCKS_DIR}" && -d "${BLOCKS_DIR}" ]]; then
    rm -rf "${BLOCKS_DIR}"
  fi
  return 0
}
trap cleanup EXIT

require_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    log "Working tree is not clean; aborting sync."
    git status --porcelain
    exit 1
  fi
}

marker_start() { printf '<!-- %s:START -->' "$1"; }
marker_end() { printf '<!-- %s:END -->' "$1"; }

extract_marked_block() {
  local file="$1"
  local name="$2"
  local start end
  start="$(marker_start "$name")"
  end="$(marker_end "$name")"
  awk -v start="$start" -v end="$end" '
    $0 == start { printing = 1 }
    printing { print }
    $0 == end { printing = 0 }
  ' "$file"
}

replace_or_insert_block() {
  local file="$1"
  local name="$2"
  local block_file="$3"
  local start end tmp
  start="$(marker_start "$name")"
  end="$(marker_end "$name")"
  tmp="$(mktemp)"

  if grep -Fq "$start" "$file" && grep -Fq "$end" "$file"; then
    awk -v start="$start" -v end="$end" -v block="$block_file" '
      $0 == start {
        while ((getline line < block) > 0) print line
        close(block)
        skipping = 1
        next
      }
      skipping && $0 == end { skipping = 0; next }
      !skipping { print }
    ' "$file" >"$tmp"
  else
    case "$name" in
      CLAUDE-FORK-NOTE)
        awk -v block="$block_file" '
          !inserted && $0 ~ /^Portable \*\*Agent Skills\*\*/ {
            while ((getline line < block) > 0) print line
            close(block)
            print ""
            inserted = 1
          }
          { print }
          END {
            if (!inserted) {
              print ""
              while ((getline line < block) > 0) print line
              close(block)
            }
          }
        ' "$file" >"$tmp"
        ;;
      CLAUDE-MARKETPLACE-INSTALL)
        awk -v block="$block_file" '
          !inserted && $0 == "### Updating from the previous version" {
            while ((getline line < block) > 0) print line
            close(block)
            print ""
            inserted = 1
          }
          { print }
          END {
            if (!inserted) {
              print ""
              while ((getline line < block) > 0) print line
              close(block)
            }
          }
        ' "$file" >"$tmp"
        ;;
      CLAUDE-FORK-DOCS)
        awk -v block="$block_file" '
          !inserted && ($0 == "## Common Questions" || $0 == "## License") {
            while ((getline line < block) > 0) print line
            close(block)
            print ""
            inserted = 1
          }
          { print }
          END {
            if (!inserted) {
              print ""
              while ((getline line < block) > 0) print line
              close(block)
            }
          }
        ' "$file" >"$tmp"
        ;;
      *)
        log "ERROR: unknown marker ${name} and no insertion rule"
        rm -f "$tmp"
        exit 1
        ;;
    esac
  fi

  mv "$tmp" "$file"
}

save_readme_blocks() {
  local name block_file
  mkdir -p "${BLOCKS_DIR}"
  for name in "${README_MARKERS[@]}"; do
    block_file="${BLOCKS_DIR}/${name}.md"
    extract_marked_block README.md "$name" >"$block_file"
    if [[ ! -s "$block_file" ]]; then
      log "ERROR: README marker block missing: ${name}"
      exit 1
    fi
  done
}

restore_readme_blocks() {
  local name
  for name in "${README_MARKERS[@]}"; do
    replace_or_insert_block README.md "$name" "${BLOCKS_DIR}/${name}.md"
  done
}

restore_fork_overlay() {
  rm -rf .claude-plugin
  mkdir -p .claude-plugin .github/workflows scripts
  cp -a "${PRESERVE_DIR}/.claude-plugin/." .claude-plugin/
  [[ -f "${PRESERVE_DIR}/.github/workflows/sync-upstream.yml" ]] && \
    cp -a "${PRESERVE_DIR}/.github/workflows/sync-upstream.yml" .github/workflows/
  [[ -f "${PRESERVE_DIR}/scripts/sync-upstream.sh" ]] && \
    cp -a "${PRESERVE_DIR}/scripts/sync-upstream.sh" scripts/
  chmod +x scripts/sync-upstream.sh
  restore_readme_blocks
}

write_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${key}=${value}" >>"${GITHUB_OUTPUT}"
  fi
}

unmerged_paths() {
  git ls-files -u | awk '{print $4}' | sort -u
}

main() {
  require_clean_worktree

  if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_REPO"
  else
    git remote set-url upstream "$UPSTREAM_REPO"
  fi

  git fetch upstream "$UPSTREAM_BRANCH" --tags
  git fetch origin

  local base_ref="${BASE_REF:-$(git rev-parse --abbrev-ref HEAD)}"
  if [[ "$base_ref" == "HEAD" ]]; then
    base_ref="${GITHUB_BASE_REF:-main}"
    git checkout "$base_ref"
  fi

  local ahead
  ahead="$(git rev-list --count "HEAD..upstream/${UPSTREAM_BRANCH}")"
  if [[ "$ahead" -eq 0 ]]; then
    log "Already up to date with upstream/${UPSTREAM_BRANCH}."
    write_output changed false
    return 0
  fi

  log "Found ${ahead} new commit(s) on upstream/${UPSTREAM_BRANCH}."

  PRESERVE_DIR="$(mktemp -d)"
  BLOCKS_DIR="$(mktemp -d)"

  mkdir -p "${PRESERVE_DIR}/.claude-plugin" "${PRESERVE_DIR}/.github/workflows" "${PRESERVE_DIR}/scripts"
  cp -a .claude-plugin/. "${PRESERVE_DIR}/.claude-plugin/"
  [[ -f .github/workflows/sync-upstream.yml ]] && \
    cp -a .github/workflows/sync-upstream.yml "${PRESERVE_DIR}/.github/workflows/"
  [[ -f scripts/sync-upstream.sh ]] && \
    cp -a scripts/sync-upstream.sh "${PRESERVE_DIR}/scripts/"
  save_readme_blocks

  local conflict=false
  if git merge "upstream/${UPSTREAM_BRANCH}" --no-edit -m "chore(sync): merge upstream/${UPSTREAM_BRANCH}"; then
    log "Merge completed cleanly."
  else
    conflict=true
    log "Merge reported conflicts; taking upstream README and restoring fork overlay."

    if unmerged_paths | grep -Fxq 'README.md'; then
      git checkout --theirs -- README.md
    fi
    if unmerged_paths | grep -Eq '^\.claude-plugin/'; then
      git checkout --ours -- .claude-plugin
    fi
    if unmerged_paths | grep -Fxq '.github/workflows/sync-upstream.yml'; then
      git checkout --ours -- .github/workflows/sync-upstream.yml
    fi
    if unmerged_paths | grep -Fxq 'scripts/sync-upstream.sh'; then
      git checkout --ours -- scripts/sync-upstream.sh
    fi

    local unresolved path
    unresolved="$(unmerged_paths || true)"
    if [[ -n "${unresolved}" ]]; then
      while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        git checkout --theirs -- "${path}" || git rm -f -- "${path}" || true
      done <<<"${unresolved}"
    fi

    git add -A
    GIT_EDITOR=true git commit --no-edit \
      -m "chore(sync): merge upstream/${UPSTREAM_BRANCH} (conflicts resolved by sync script)"
  fi

  restore_fork_overlay

  if grep -rqE '^(<<<<<<<|=======|>>>>>>>)' README.md .claude-plugin 2>/dev/null; then
    log "ERROR: conflict markers remain after sync restore"
    grep -rnE '^(<<<<<<<|=======|>>>>>>>)' README.md .claude-plugin || true
    exit 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    git add .claude-plugin README.md .github/workflows/sync-upstream.yml scripts/sync-upstream.sh
    git commit -m "chore(sync): restore Claude marketplace overlay after upstream merge"
  fi

  write_output changed true
  write_output conflict "${conflict}"
  write_output commit_count "${ahead}"
  write_output upstream_sha "$(git rev-parse "upstream/${UPSTREAM_BRANCH}")"

  log "Sync merge complete (conflict=${conflict})."
}

main "$@"
