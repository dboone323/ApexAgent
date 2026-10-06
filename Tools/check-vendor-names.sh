#!/bin/sh
# Fails if third-party AI product/project names creep back into source or test code.
# Provider API-key formats / wire-protocol names (OpenAI, Anthropic) are intentionally allowed.
cd "$(dirname "$0")/.." || exit 1
hits=$(git grep -niE "grok|hermes|openclaw|openmaus" -- 'ApexAgent/*.swift' 'ApexAgentTests/*.swift' 'ApexAgentUITests/*.swift' 'project.yml')
if [ -n "$hits" ]; then
  echo "Vendor-identifying names found:"; echo "$hits"; exit 1
fi
echo "OK: no vendor-identifying names in code/tests"
