#!/usr/bin/env bash
# Phase 2b: point Argo CD at this Git repo (app of apps).
# 1. fills the repo URL into argocd/root-app.yaml and argocd/apps/*.yaml
# 2. checks everything is committed and pushed (Argo CD reads GitHub, not your Mac)
# 3. private repo only: registers a read-only token with Argo CD
# 4. applies the root Application once
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Repo URL from git, in https form
REPO_URL=$(git remote get-url origin)
REPO_URL=${REPO_URL/git@github.com:/https://github.com/}
[[ "$REPO_URL" == *.git ]] || REPO_URL="$REPO_URL.git"
echo "Repo: $REPO_URL"

if grep -rl "__REPO_URL__" argocd/root-app.yaml argocd/apps >/dev/null 2>&1; then
  grep -rl "__REPO_URL__" argocd/root-app.yaml argocd/apps | xargs sed -i '' "s#__REPO_URL__#${REPO_URL}#g"
  echo "Filled repo URL into the Argo CD manifests. Commit and push them, then run this script again:"
  echo "  git add argocd platform scripts && git commit -m 'Phase 2b: app of apps' && git push"
  exit 0
fi

# 2. Argo CD only sees what is on GitHub
git fetch -q origin
if [[ -n "$(git status --porcelain argocd platform)" || -n "$(git log origin/main..HEAD --oneline)" ]]; then
  echo "Uncommitted or unpushed changes – commit and push first:"
  git status --short argocd platform; git log origin/main..HEAD --oneline
  exit 1
fi

# 3. Private repo → Argo CD needs read access
VISIBILITY=$(gh repo view --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)
echo "Visibility: $VISIBILITY"
if [[ "$VISIBILITY" != "PUBLIC" ]]; then
  echo "Private repo: create a fine-grained token (Contents: Read-only, this repo only), then paste it here."
  read -r -s -p "Token: " TOKEN; echo
  argocd repo add "$REPO_URL" --username "$(gh api user -q .login)" --password "$TOKEN" --upsert
fi

# 4. Root Application – the only thing ever applied by hand
kubectl apply -f argocd/root-app.yaml
echo "Waiting for Argo CD to sync..."
sleep 15
argocd app list
