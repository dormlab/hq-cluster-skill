#!/usr/bin/env bash
# install.sh -- symlink the hq-cluster skill into ~/.claude/skills/.
# Follows the dormlab-cli installation pattern.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$REPO_DIR/skills/hq-cluster"
SKILL_DST="$HOME/.claude/skills/hq-cluster"

if [[ ! -d "$SKILL_SRC" ]]; then
  echo "skill source missing: $SKILL_SRC" >&2
  exit 1
fi

# Ensure ~/.claude/skills exists.
mkdir -p "$HOME/.claude/skills"

# Replace any existing symlink/dir at the destination.
if [[ -L "$SKILL_DST" || -e "$SKILL_DST" ]]; then
  rm -rf "$SKILL_DST"
fi
ln -s "$SKILL_SRC" "$SKILL_DST"
echo "linked $SKILL_DST -> $SKILL_SRC"

# Ensure the scripts are executable.
chmod +x "$SKILL_SRC"/scripts/*

# Sanity check.
if ! command -v hq >/dev/null 2>&1; then
  cat <<EOF >&2

WARNING: \`hq\` is not on PATH.
  Install on the Mac (client side):
    brew install cmake
    cargo install --locked --git https://github.com/It4innovations/hyperqueue hyperqueue
  Then bring up the server + workers per SETUP.md.

EOF
fi

echo
echo "done. From a Claude Code session, the skill is now invokable:"
echo "    submit -- python train.py --lr 0.05"
echo
echo "Or via the Skill tool with name 'hq-cluster'."
