#!/usr/bin/env bash
set -euo pipefail
root=/Users/danielstevens/Library/Developer/Xcode/CodingAssistant
files=( "$root/AgentPlugins/PluginsManifest.json" "$root/codex/config.toml" "$root/mcp-servers.json" )
patterns=( 'api\.openai\.com' 'api\.anthropic\.com' )
violations=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  for p in "${patterns[@]}"; do
    c=$(grep -E "$p" "$f" 2>/dev/null | wc -l || true)
    if [ "$c" -gt 0 ]; then
      echo "VIOLATION $f $p $c"
      violations=$((violations+1))
    fi
  done
done
if [ "$violations" -gt 0 ]; then
  echo "FAIL violations=$violations"
  exit 1
fi
echo "OK violations=0 config_files_audited=${#files[@]}"
