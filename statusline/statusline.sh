#!/bin/bash
# Claude Code status line: [repo] (branch)  [progress bar] NN%
# Colors mirror ~/.zshrc PROMPT: directory blue, git branch red.

input=$(cat)

DIM_BLUE='\033[2;34m'
DIM_RED='\033[2;31m'
DIM_GREEN='\033[2;32m'
DIM_YELLOW='\033[2;33m'
RESET='\033[0m'

BAR_WIDTH=20

# --- left: repo + branch ---------------------------------------------------
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')
[ -z "$dir" ] && dir=$PWD

root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$root" ]; then
  repo=$(basename "$root")
  branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
else
  repo=$(basename "$dir")
  branch=""
fi

# --- context bar -----------------------------------------------------------
pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // 0')
p=$(printf '%.0f' "$pct" 2>/dev/null)
[ -z "$p" ] && p=0
[ "$p" -lt 0 ] && p=0
[ "$p" -gt 100 ] && p=100

filled=$((p * BAR_WIDTH / 100))
[ "$filled" -gt "$BAR_WIDTH" ] && filled=$BAR_WIDTH
empty=$((BAR_WIDTH - filled))
bar=""
i=0; while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i + 1)); done
i=0; while [ "$i" -lt "$empty" ];  do bar="${bar}░"; i=$((i + 1)); done

if   [ "$p" -gt 75 ]; then color=$DIM_RED
elif [ "$p" -gt 50 ]; then color=$DIM_YELLOW
else                       color=$DIM_GREEN
fi

printf "${DIM_BLUE}[%s]${RESET}" "$repo"
[ -n "$branch" ] && printf " ${DIM_RED}(%s)${RESET}" "$branch"
printf "  ${color}[%s] %s%%${RESET}" "$bar" "$p"
