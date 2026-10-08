#!/usr/bin/env bash
set -u

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if xhost +SI:localuser:root >/dev/null 2>&1 && wlr-randr \
    --output HDMI-A-1 --mode 1920x1080@50Hz --pos 0,0 \
    --output HDMI-A-2 --mode 1920x1080@50Hz --pos 1920,0; then
    exit 0
  fi
  sleep 2
done

printf 'Could not configure both HDMI outputs with wlr-randr. Check the active desktop session.\n' >&2
exit 1
