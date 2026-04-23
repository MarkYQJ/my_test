#!/bin/sh
set -e

GITHUB_URL="$1"
GITLAB_URL="$2"
STATE_REF="refs/sync/state"
STATE_BRANCH_FILE="sync-state-branches.txt"
STATE_TAG_FILE="sync-state-tags.txt"

if [ -z "$GITHUB_URL" ] || [ -z "$GITLAB_URL" ]; then
  echo "Usage: $0 <github_url> <gitlab_url>"
  exit 1
fi

mask_credentials() {
  sed -E 's|://[^@]+@|://***@|g'
}

git_push_masked() {
  git push "$@" 2>&1 | mask_credentials
}

git_fetch_masked() {
  git fetch "$@" 2>&1 | mask_credentials
}

list_remote_branches() {
  git ls-remote --heads "$1" 2>/dev/null | awk '{print $2}' | sed 's|^refs/heads/||' | sort
}

list_remote_tags() {
  git ls-remote --tags "$1" 2>/dev/null | grep -v '\^{}$' | awk '{print $2}' | sed 's|^refs/tags/||' | sort
}

load_previous_state() {
  local url="$1"
  local tmpdir
  tmpdir=$(mktemp -d)

  git init --bare "$tmpdir/state-repo" >/dev/null 2>&1
  if git -C "$tmpdir/state-repo" fetch "$url" "$STATE_REF:$STATE_REF" >/dev/null 2>&1; then
    git -C "$tmpdir/state-repo" show "$STATE_REF:$STATE_BRANCH_FILE" > "$tmpdir/prev-branches.txt" 2>/dev/null || true
    git -C "$tmpdir/state-repo" show "$STATE_REF:$STATE_TAG_FILE" > "$tmpdir/prev-tags.txt" 2>/dev/null || true
    echo "  Loaded state from $url"
  else
    echo "  No previous state found (first run)"
  fi
  rm -rf "$tmpdir/state-repo"

  [ -s "$tmpdir/prev-branches.txt" ] || : > "$tmpdir/prev-branches.txt"
  [ -s "$tmpdir/prev-tags.txt" ] || : > "$tmpdir/prev-tags.txt"

  PREV_BRANCHES_FILE="$tmpdir/prev-branches.txt"
  PREV_TAGS_FILE="$tmpdir/prev-tags.txt"
  STATE_TMPDIR="$tmpdir"
}

save_state() {
  local target_url="$1"
  local branches_file="$2"
  local tags_file="$3"

  local tmpdir
  tmpdir=$(mktemp -d)

  (
    git init --bare "$tmpdir/state-repo" >/dev/null 2>&1
    cd "$tmpdir/state-repo"

    branch_blob=$(git hash-object -w "$branches_file")
    tag_blob=$(git hash-object -w "$tags_file")

    tree_hash=$(printf "100644 blob %s\t%s\n100644 blob %s\t%s\n" \
      "$branch_blob" "$STATE_BRANCH_FILE" \
      "$tag_blob" "$STATE_TAG_FILE" | git mktree)

    commit_hash=$(git commit-tree "$tree_hash" -m "sync state $(date -u +%Y-%m-%dT%H:%M:%SZ)")

    git push "$target_url" "$commit_hash:$STATE_REF" --force >/dev/null 2>&1
  ) || echo "  Warning: failed to save state"

  rm -rf "$tmpdir"
}

compute_actions() {
  local prev_file="$1"
  local github_file="$2"
  local gitlab_file="$3"
  local action_file="$4"

  : > "$action_file"

  local all_refs_file
  all_refs_file=$(mktemp)
  cat "$prev_file" "$github_file" "$gitlab_file" | sort -u > "$all_refs_file"

  while IFS= read -r ref || [ -n "$ref" ]; do
    [ -z "$ref" ] && continue

    local in_prev in_gh in_gl
    in_prev=$(grep -Fxc "$ref" "$prev_file" 2>/dev/null || echo 0)
    in_gh=$(grep -Fxc "$ref" "$github_file" 2>/dev/null || echo 0)
    in_gl=$(grep -Fxc "$ref" "$gitlab_file" 2>/dev/null || echo 0)

    if [ "$in_prev" -gt 0 ] && [ "$in_gh" -eq 0 ] && [ "$in_gl" -gt 0 ]; then
      echo "DELETE_FROM_GITLAB $ref" >> "$action_file"
    elif [ "$in_prev" -gt 0 ] && [ "$in_gh" -gt 0 ] && [ "$in_gl" -eq 0 ]; then
      echo "DELETE_FROM_GITHUB $ref" >> "$action_file"
    elif [ "$in_prev" -eq 0 ] && [ "$in_gh" -gt 0 ] && [ "$in_gl" -eq 0 ]; then
      echo "PUSH_TO_GITLAB $ref" >> "$action_file"
    elif [ "$in_prev" -eq 0 ] && [ "$in_gh" -eq 0 ] && [ "$in_gl" -gt 0 ]; then
      echo "PUSH_TO_GITHUB $ref" >> "$action_file"
    elif [ "$in_gh" -gt 0 ] && [ "$in_gl" -gt 0 ]; then
      echo "SYNC $ref" >> "$action_file"
    fi
  done < "$all_refs_file"

  rm -f "$all_refs_file"
}

echo "=== Bidirectional Sync Start ==="
echo ""

echo "--- Fetching current refs from GitHub ---"
gh_branches=$(mktemp)
gh_tags=$(mktemp)
list_remote_branches "$GITHUB_URL" > "$gh_branches"
list_remote_tags "$GITHUB_URL" > "$gh_tags"
echo "  Branches: $(wc -l < "$gh_branches" | tr -d ' ')"
echo "  Tags: $(wc -l < "$gh_tags" | tr -d ' ')"

echo ""
echo "--- Fetching current refs from GitLab ---"
gl_branches=$(mktemp)
gl_tags=$(mktemp)
list_remote_branches "$GITLAB_URL" > "$gl_branches"
list_remote_tags "$GITLAB_URL" > "$gl_tags"
echo "  Branches: $(wc -l < "$gl_branches" | tr -d ' ')"
echo "  Tags: $(wc -l < "$gl_tags" | tr -d ' ')"

echo ""
echo "--- Loading previous sync state ---"
load_previous_state "$GITLAB_URL"
echo "  Previous branches: $(wc -l < "$PREV_BRANCHES_FILE" | tr -d ' ')"
echo "  Previous tags: $(wc -l < "$PREV_TAGS_FILE" | tr -d ' ')"

echo ""
echo "--- Computing actions ---"
branch_actions=$(mktemp)
compute_actions "$PREV_BRANCHES_FILE" "$gh_branches" "$gl_branches" "$branch_actions"
tag_actions=$(mktemp)
compute_actions "$PREV_TAGS_FILE" "$gh_tags" "$gl_tags" "$tag_actions"

echo ""
echo "=== Planned Branch Actions ==="
if [ -s "$branch_actions" ]; then
  cat "$branch_actions"
else
  echo "  (none)"
fi

echo ""
echo "=== Planned Tag Actions ==="
if [ -s "$tag_actions" ]; then
  cat "$tag_actions"
else
  echo "  (none)"
fi

workdir=$(mktemp -d)
git init --bare "$workdir/repo" >/dev/null 2>&1
cd "$workdir/repo"
git remote add github "$GITHUB_URL"
git remote add gitlab "$GITLAB_URL"

echo ""
echo "--- Fetching commits from both remotes ---"
git_fetch_masked github '+refs/heads/*:refs/remotes/github/*' '+refs/tags/*:refs/tags/github/*' || true
git_fetch_masked gitlab '+refs/heads/*:refs/remotes/gitlab/*' '+refs/tags/*:refs/tags/gitlab/*' || true

echo ""
echo "--- Processing branch actions ---"

while IFS=' ' read -r action ref || [ -n "$action" ]; do
  [ -z "$action" ] && continue

  case "$action" in
    DELETE_FROM_GITLAB)
      echo "  DELETE '$ref' from GitLab (was deleted on GitHub)"
      git_push_masked gitlab --delete "refs/heads/$ref" || echo "    (already absent)"
      ;;
    DELETE_FROM_GITHUB)
      echo "  DELETE '$ref' from GitHub (was deleted on GitLab)"
      git_push_masked github --delete "refs/heads/$ref" || echo "    (already absent)"
      ;;
    PUSH_TO_GITLAB)
      echo "  PUSH '$ref' to GitLab (new on GitHub)"
      git_push_masked gitlab "refs/remotes/github/$ref:refs/heads/$ref" --force || echo "    (push failed)"
      ;;
    PUSH_TO_GITHUB)
      echo "  PUSH '$ref' to GitHub (new on GitLab)"
      git_push_masked github "refs/remotes/gitlab/$ref:refs/heads/$ref" --force || echo "    (push failed)"
      ;;
    SYNC)
      local_gh=$(git rev-parse "refs/remotes/github/$ref" 2>/dev/null || echo "")
      local_gl=$(git rev-parse "refs/remotes/gitlab/$ref" 2>/dev/null || echo "")

      if [ -z "$local_gh" ] && [ -z "$local_gl" ]; then
        echo "  WARNING: cannot resolve '$ref' on either side, skipping"
      elif [ "$local_gh" = "$local_gl" ]; then
        echo "  SKIP '$ref' (already in sync)"
      elif [ -z "$local_gh" ]; then
        echo "  SYNC '$ref': GitLab -> GitHub"
        git_push_masked github "refs/remotes/gitlab/$ref:refs/heads/$ref" --force || echo "    (push failed)"
      elif [ -z "$local_gl" ]; then
        echo "  SYNC '$ref': GitHub -> GitLab"
        git_push_masked gitlab "refs/remotes/github/$ref:refs/heads/$ref" --force || echo "    (push failed)"
      else
        gh_time=$(git log -1 --format='%ct' "$local_gh" 2>/dev/null || echo "")
        gl_time=$(git log -1 --format='%ct' "$local_gl" 2>/dev/null || echo "")
        if [ -z "$gh_time" ] || [ -z "$gl_time" ]; then
          echo "  WARNING: cannot determine commit time for '$ref', skipping"
        elif [ "$gh_time" -ge "$gl_time" ]; then
          echo "  SYNC '$ref': GitHub -> GitLab (newer commit)"
          git_push_masked gitlab "refs/remotes/github/$ref:refs/heads/$ref" --force || echo "    (push failed)"
        else
          echo "  SYNC '$ref': GitLab -> GitHub (newer commit)"
          git_push_masked github "refs/remotes/gitlab/$ref:refs/heads/$ref" --force || echo "    (push failed)"
        fi
      fi
      ;;
  esac
done < "$branch_actions"

echo ""
echo "--- Processing tag actions ---"

while IFS=' ' read -r action ref || [ -n "$action" ]; do
  [ -z "$action" ] && continue

  case "$action" in
    DELETE_FROM_GITLAB)
      echo "  DELETE tag '$ref' from GitLab (was deleted on GitHub)"
      git_push_masked gitlab --delete "refs/tags/$ref" || echo "    (already absent)"
      ;;
    DELETE_FROM_GITHUB)
      echo "  DELETE tag '$ref' from GitHub (was deleted on GitLab)"
      git_push_masked github --delete "refs/tags/$ref" || echo "    (already absent)"
      ;;
    PUSH_TO_GITLAB)
      echo "  PUSH tag '$ref' to GitLab (new on GitHub)"
      git_push_masked gitlab "refs/tags/github/$ref:refs/tags/$ref" --force || echo "    (push failed)"
      ;;
    PUSH_TO_GITHUB)
      echo "  PUSH tag '$ref' to GitHub (new on GitLab)"
      git_push_masked github "refs/tags/gitlab/$ref:refs/tags/$ref" --force || echo "    (push failed)"
      ;;
    SYNC)
      local_gh=$(git rev-parse "refs/tags/github/$ref" 2>/dev/null || echo "")
      local_gl=$(git rev-parse "refs/tags/gitlab/$ref" 2>/dev/null || echo "")

      if [ "$local_gh" = "$local_gl" ]; then
        echo "  SKIP tag '$ref' (already in sync)"
      elif [ -z "$local_gh" ]; then
        echo "  SYNC tag '$ref': GitLab -> GitHub"
        git_push_masked github "refs/tags/gitlab/$ref:refs/tags/$ref" --force || echo "    (push failed)"
      elif [ -z "$local_gl" ]; then
        echo "  SYNC tag '$ref': GitHub -> GitLab"
        git_push_masked gitlab "refs/tags/github/$ref:refs/tags/$ref" --force || echo "    (push failed)"
      else
        echo "  SYNC tag '$ref': GitHub -> GitLab (GitHub wins for conflicts)"
        git_push_masked gitlab "refs/tags/github/$ref:refs/tags/$ref" --force || echo "    (push failed)"
      fi
      ;;
  esac
done < "$tag_actions"

echo ""
echo "--- Saving sync state ---"
final_branches=$(mktemp)
final_tags=$(mktemp)

list_remote_branches "$GITHUB_URL" > "$final_branches"
list_remote_branches "$GITLAB_URL" >> "$final_branches"
sort -u "$final_branches" -o "$final_branches"

list_remote_tags "$GITHUB_URL" > "$final_tags"
list_remote_tags "$GITLAB_URL" >> "$final_tags"
sort -u "$final_tags" -o "$final_tags"

save_state "$GITLAB_URL" "$final_branches" "$final_tags"
save_state "$GITHUB_URL" "$final_branches" "$final_tags"

echo ""
echo "=== Bidirectional Sync Complete ==="
echo "  Final branches: $(wc -l < "$final_branches" | tr -d ' ')"
echo "  Final tags: $(wc -l < "$final_tags" | tr -d ' ')"

cd /
rm -rf "$workdir" "$STATE_TMPDIR"
rm -f "$gh_branches" "$gh_tags" "$gl_branches" "$gl_tags"
rm -f "$branch_actions" "$tag_actions" "$final_branches" "$final_tags"
