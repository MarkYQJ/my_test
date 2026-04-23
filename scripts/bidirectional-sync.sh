#!/bin/sh
set -e

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-sync-bot}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sync-bot@noreply}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-sync-bot}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sync-bot@noreply}"

GITHUB_URL="$1"
GITLAB_URL="$2"
GITHUB_API_TOKEN="$3"
GITLAB_API_TOKEN="$4"
GITHUB_REPO="$5"
GITLAB_PROJECT_ID="$6"
GITLAB_BASE_URL="$7"

GITLAB_API_URL="${GITLAB_BASE_URL}/api/v4"
GITHUB_API_URL="https://api.github.com"
BRANCH="main"

if [ -z "$GITHUB_URL" ] || [ -z "$GITLAB_URL" ] || [ -z "$GITHUB_API_TOKEN" ] || \
   [ -z "$GITLAB_API_TOKEN" ] || [ -z "$GITHUB_REPO" ] || [ -z "$GITLAB_PROJECT_ID" ] || \
   [ -z "$GITLAB_BASE_URL" ]; then
  echo "Usage: $0 <github_url> <gitlab_url> <github_api_token> <gitlab_api_token> <github_repo> <gitlab_project_id> <gitlab_base_url>"
  exit 1
fi

case "$GITHUB_REPO" in
  */*)
    GITHUB_OWNER=$(echo "$GITHUB_REPO" | cut -d'/' -f1)
    ;;
  *)
    echo "ERROR: GITHUB_REPO must be in 'owner/repo' format, got: $GITHUB_REPO"
    exit 1
    ;;
esac

SYNC_RESULT="success"
workdir=""
gh_tags=""
gl_tags=""

cleanup() {
  [ -n "$workdir" ] && rm -rf "$workdir"
  rm -f "$gh_tags" "$gl_tags"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

mask_credentials() {
  sed -E 's|://[^@]+@|://***@|g'
}

git_push_masked() {
  _tmp=$(mktemp)
  _rc=0
  git push "$@" >"$_tmp" 2>&1 || _rc=$?
  mask_credentials < "$_tmp"
  rm -f "$_tmp"
  return $_rc
}

git_fetch_masked() {
  _tmp=$(mktemp)
  _rc=0
  git fetch "$@" >"$_tmp" 2>&1 || _rc=$?
  mask_credentials < "$_tmp"
  rm -f "$_tmp"
  return $_rc
}

# ---------------------------------------------------------------------------
# GitHub PR helpers
# ---------------------------------------------------------------------------

github_api() {
  _method="$1"; shift
  _endpoint="$1"; shift
  curl -s -X "$_method" \
    -H "Authorization: token ${GITHUB_API_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@" \
    "${GITHUB_API_URL}${_endpoint}"
}

check_existing_github_pr() {
  _source_branch="$1"
  _response=$(github_api GET "/repos/${GITHUB_REPO}/pulls?state=open&head=${GITHUB_OWNER}:${_source_branch}&base=${BRANCH}")
  _count=$(echo "$_response" | jq 'if type == "array" then length else 0 end')
  if [ "$_count" -gt 0 ]; then
    _pr_url=$(echo "$_response" | jq -r '.[0].html_url')
    echo "$_pr_url"
    return 0
  fi
  return 1
}

create_github_pr() {
  _source_branch="$1"
  _title="$2"
  _body="$3"
  _payload=$(jq -n \
    --arg title "$_title" \
    --arg body "$_body" \
    --arg head "$_source_branch" \
    --arg base "$BRANCH" \
    '{title: $title, body: $body, head: $head, base: $base}')
  _response=$(github_api POST "/repos/${GITHUB_REPO}/pulls" -H "Content-Type: application/json" -d "$_payload")
  _pr_url=$(echo "$_response" | jq -r '.html_url // empty')
  if [ -n "$_pr_url" ] && [ "$_pr_url" != "null" ]; then
    echo "$_pr_url"
    return 0
  fi
  _error=$(echo "$_response" | jq -r '.message // "unknown error"')
  echo "  ERROR creating GitHub PR: $_error" >&2
  return 1
}

# ---------------------------------------------------------------------------
# GitLab MR helpers
# ---------------------------------------------------------------------------

gitlab_api() {
  _method="$1"; shift
  _endpoint="$1"; shift
  curl -s -X "$_method" \
    -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    "$@" \
    "${GITLAB_API_URL}${_endpoint}"
}

check_existing_gitlab_mr() {
  _source_branch="$1"
  _encoded_source=$(printf '%s' "$_source_branch" | jq -sRr @uri)
  _encoded_target=$(printf '%s' "$BRANCH" | jq -sRr @uri)
  _response=$(gitlab_api GET "/projects/${GITLAB_PROJECT_ID}/merge_requests?state=opened&source_branch=${_encoded_source}&target_branch=${_encoded_target}")
  _count=$(echo "$_response" | jq 'if type == "array" then length else 0 end')
  if [ "$_count" -gt 0 ]; then
    _mr_url=$(echo "$_response" | jq -r '.[0].web_url')
    echo "$_mr_url"
    return 0
  fi
  return 1
}

create_gitlab_mr() {
  _source_branch="$1"
  _title="$2"
  _description="$3"
  _response=$(gitlab_api POST "/projects/${GITLAB_PROJECT_ID}/merge_requests" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg source "$_source_branch" \
      --arg target "$BRANCH" \
      --arg title "$_title" \
      --arg desc "$_description" \
      '{source_branch: $source, target_branch: $target, title: $title, description: $desc}')")
  _mr_url=$(echo "$_response" | jq -r '.web_url // empty')
  if [ -n "$_mr_url" ] && [ "$_mr_url" != "null" ]; then
    echo "$_mr_url"
    return 0
  fi
  _error=$(echo "$_response" | jq -r '.message // .error // "unknown error"')
  echo "  ERROR creating GitLab MR: $_error" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Tag sync helpers
# ---------------------------------------------------------------------------

list_remote_tags() {
  git ls-remote --tags "$1" 2>/dev/null | grep -v '\^{}$' | awk '{print $2}' | sed 's|^refs/tags/||' | sort
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

echo "=== Main-Branch Sync Start ==="
echo ""

echo "--- Pre-flight: validating API tokens ---"

_gh_check=$(github_api GET "/repos/${GITHUB_REPO}" 2>/dev/null || true)
_gh_name=$(echo "$_gh_check" | jq -r '.full_name // empty' 2>/dev/null || true)
if [ -z "$_gh_name" ]; then
  echo "  ERROR: GitHub API token cannot access repo ${GITHUB_REPO}"
  exit 1
fi
echo "  GitHub: OK (${_gh_name})"

_gl_check=$(gitlab_api GET "/projects/${GITLAB_PROJECT_ID}" 2>/dev/null || true)
_gl_name=$(echo "$_gl_check" | jq -r '.path_with_namespace // empty' 2>/dev/null || true)
if [ -z "$_gl_name" ]; then
  echo "  ERROR: GitLab API token cannot access project ${GITLAB_PROJECT_ID}"
  exit 1
fi
echo "  GitLab: OK (${_gl_name})"

# ---------------------------------------------------------------------------
# Fetch main from both remotes
# ---------------------------------------------------------------------------

echo ""
echo "--- Fetching main branch from both remotes ---"

workdir=$(mktemp -d)
git init "$workdir/repo" >/dev/null 2>&1
cd "$workdir/repo"
git remote add github "$GITHUB_URL"
git remote add gitlab "$GITLAB_URL"

gh_fetch_ok=1
gl_fetch_ok=1
git_fetch_masked github "+refs/heads/${BRANCH}:refs/remotes/github/${BRANCH}" || gh_fetch_ok=0
git_fetch_masked gitlab "+refs/heads/${BRANCH}:refs/remotes/gitlab/${BRANCH}" || gl_fetch_ok=0

if [ "$gh_fetch_ok" -eq 0 ]; then
  echo "  WARNING: '${BRANCH}' branch not found on GitHub, nothing to sync"
  exit 0
fi
if [ "$gl_fetch_ok" -eq 0 ]; then
  echo "  WARNING: '${BRANCH}' branch not found on GitLab, nothing to sync"
  exit 0
fi

gh_sha=$(git rev-parse "refs/remotes/github/${BRANCH}")
gl_sha=$(git rev-parse "refs/remotes/gitlab/${BRANCH}")

echo "  GitHub ${BRANCH}: ${gh_sha}"
echo "  GitLab ${BRANCH}: ${gl_sha}"

# ---------------------------------------------------------------------------
# Compare and determine sync direction
# ---------------------------------------------------------------------------

echo ""
echo "--- Comparing main branches ---"

NEED_PR_TO_GITHUB=0
NEED_MR_TO_GITLAB=0

if [ "$gh_sha" = "$gl_sha" ]; then
  echo "  main is identical on both sides, nothing to do"
elif git merge-base --is-ancestor "$gh_sha" "$gl_sha" 2>/dev/null; then
  echo "  GitLab main is ahead of GitHub main"
  NEED_PR_TO_GITHUB=1
elif git merge-base --is-ancestor "$gl_sha" "$gh_sha" 2>/dev/null; then
  echo "  GitHub main is ahead of GitLab main"
  NEED_MR_TO_GITLAB=1
else
  echo "  main has diverged on both sides"
  NEED_PR_TO_GITHUB=1
  NEED_MR_TO_GITLAB=1
fi

# ---------------------------------------------------------------------------
# Create PR on GitHub (GitLab -> GitHub)
# ---------------------------------------------------------------------------

if [ "$NEED_PR_TO_GITHUB" -eq 1 ]; then
  echo ""
  echo "--- Creating PR on GitHub (GitLab -> GitHub) ---"

  SYNC_BRANCH="sync/gitlab-to-github"

  remote_sync_sha=$(git ls-remote github "refs/heads/${SYNC_BRANCH}" 2>/dev/null | awk '{print $1}')
  if [ "$remote_sync_sha" = "$gl_sha" ]; then
    echo "  Sync branch already up to date (${gl_sha})"
  else
    echo "  Pushing ${SYNC_BRANCH} to GitHub..."
    git_push_masked github "+refs/remotes/gitlab/${BRANCH}:refs/heads/${SYNC_BRANCH}" || {
      echo "  ERROR: failed to push sync branch to GitHub"
      SYNC_RESULT="partial_failure"
      NEED_PR_TO_GITHUB=0
    }
  fi

  if [ "$NEED_PR_TO_GITHUB" -eq 1 ]; then
    existing_pr=$(check_existing_github_pr "$SYNC_BRANCH" || true)
    if [ -n "$existing_pr" ]; then
      echo "  Open PR already exists: ${existing_pr}"
      echo "  Sync branch updated via force-push, PR will reflect latest changes"
    else
      pr_title="sync: Update main from GitLab"
      pr_body="Automated sync from GitLab main branch.

**GitLab SHA:** \`${gl_sha}\`
**GitHub SHA:** \`${gh_sha}\`
**Sync time:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

> This branch is auto-updated by the sync pipeline. Force-pushes are expected."

      pr_url=$(create_github_pr "$SYNC_BRANCH" "$pr_title" "$pr_body" || true)
      if [ -n "$pr_url" ]; then
        echo "  PR created: ${pr_url}"
      else
        echo "  WARNING: failed to create PR on GitHub"
        SYNC_RESULT="partial_failure"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Create MR on GitLab (GitHub -> GitLab)
# ---------------------------------------------------------------------------

if [ "$NEED_MR_TO_GITLAB" -eq 1 ]; then
  echo ""
  echo "--- Creating MR on GitLab (GitHub -> GitLab) ---"

  SYNC_BRANCH="sync/github-to-gitlab"

  remote_sync_sha=$(git ls-remote gitlab "refs/heads/${SYNC_BRANCH}" 2>/dev/null | awk '{print $1}')
  if [ "$remote_sync_sha" = "$gh_sha" ]; then
    echo "  Sync branch already up to date (${gh_sha})"
  else
    echo "  Pushing ${SYNC_BRANCH} to GitLab..."
    git_push_masked gitlab "+refs/remotes/github/${BRANCH}:refs/heads/${SYNC_BRANCH}" || {
      echo "  ERROR: failed to push sync branch to GitLab"
      SYNC_RESULT="partial_failure"
      NEED_MR_TO_GITLAB=0
    }
  fi

  if [ "$NEED_MR_TO_GITLAB" -eq 1 ]; then
    existing_mr=$(check_existing_gitlab_mr "$SYNC_BRANCH" || true)
    if [ -n "$existing_mr" ]; then
      echo "  Open MR already exists: ${existing_mr}"
      echo "  Sync branch updated via force-push, MR will reflect latest changes"
    else
      mr_title="sync: Update main from GitHub"
      mr_description="Automated sync from GitHub main branch.

**GitHub SHA:** \`${gh_sha}\`
**GitLab SHA:** \`${gl_sha}\`
**Sync time:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

> This branch is auto-updated by the sync pipeline. Force-pushes are expected."

      mr_url=$(create_gitlab_mr "$SYNC_BRANCH" "$mr_title" "$mr_description" || true)
      if [ -n "$mr_url" ]; then
        echo "  MR created: ${mr_url}"
      else
        echo "  WARNING: failed to create MR on GitLab"
        SYNC_RESULT="partial_failure"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Tag sync (direct push, same as before)
# ---------------------------------------------------------------------------

echo ""
echo "--- Syncing tags ---"

git_fetch_masked github '+refs/tags/*:refs/tags/github/*' || true
git_fetch_masked gitlab '+refs/tags/*:refs/tags/gitlab/*' || true

gh_tags=$(mktemp)
gl_tags=$(mktemp)
list_remote_tags "$GITHUB_URL" > "$gh_tags"
list_remote_tags "$GITLAB_URL" > "$gl_tags"

tag_synced=0

while IFS= read -r tag || [ -n "$tag" ]; do
  [ -z "$tag" ] && continue
  in_gl=$(grep -Fxc "$tag" "$gl_tags" 2>/dev/null || echo 0)
  if [ "$in_gl" -eq 0 ]; then
    echo "  PUSH tag '${tag}' to GitLab (new on GitHub)"
    git_push_masked gitlab "refs/tags/github/${tag}:refs/tags/${tag}" || echo "    (push failed)"
    tag_synced=$((tag_synced + 1))
  fi
done < "$gh_tags"

while IFS= read -r tag || [ -n "$tag" ]; do
  [ -z "$tag" ] && continue
  in_gh=$(grep -Fxc "$tag" "$gh_tags" 2>/dev/null || echo 0)
  if [ "$in_gh" -eq 0 ]; then
    echo "  PUSH tag '${tag}' to GitHub (new on GitLab)"
    git_push_masked github "refs/tags/gitlab/${tag}:refs/tags/${tag}" || echo "    (push failed)"
    tag_synced=$((tag_synced + 1))
  fi
done < "$gl_tags"

if [ "$tag_synced" -eq 0 ]; then
  echo "  Tags are in sync"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Main-Branch Sync Complete ==="
echo "  GitHub main: ${gh_sha}"
echo "  GitLab main: ${gl_sha}"
if [ "$gh_sha" = "$gl_sha" ]; then
  echo "  Status: in sync"
elif [ "$SYNC_RESULT" = "partial_failure" ]; then
  echo "  Status: PARTIAL FAILURE - some PR/MR operations failed, check logs above"
else
  echo "  Status: diverged, PR/MR created for review"
fi

cd /

if [ "$SYNC_RESULT" = "partial_failure" ]; then
  exit 1
fi
