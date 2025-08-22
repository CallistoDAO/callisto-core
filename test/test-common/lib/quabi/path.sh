#!/usr/bin/env bash

set -euo pipefail

for FOLDER in ./out/*; do
  # Skip if no directories match
  [ -d "$FOLDER" ] || continue
  for FILE in "$FOLDER"/*; do
    # Skip if no files match
    [ -f "$FILE" ] || continue
    NAME=$(basename "$FILE")
    if [ "$NAME" == "$1" ]; then
      cast abi-encode "result(string)" "$FILE"
      exit 0
    fi
  done
done
