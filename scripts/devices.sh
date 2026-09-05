#!/usr/bin/env bash
# Device/panel helpers shared by the Linux builder.
# Keep this file dependency-free: make_logo.sh is also invoked standalone.
set -euo pipefail

nr_panel_for_board() {
    case "$1" in
        n841ap) echo "828 1792" ;;
        d321ap) echo "1125 2436" ;;
        d331ap|d331pap) echo "1242 2688" ;;
        n104ap) echo "828 1792" ;;
        d421ap) echo "1125 2436" ;;
        d431ap) echo "1242 2688" ;;
        d79ap) echo "750 1334" ;;
        j210ap|j210aap) echo "1536 2048" ;;
        j217ap|j218ap) echo "1668 2224" ;;
        j320ap|j321ap) echo "1668 2388" ;;
        j417ap|j418ap) echo "2048 2732" ;;
        j307ap|j308ap) echo "1620 2160" ;;
        *) return 1 ;;
    esac
}

nr_logo_mark_for_panel() {
    local width="$1" height="$2" short="$1"
    [[ "$height" -lt "$width" ]] && short="$height"
    local mark=$((short * 35 / 100))
    (( mark < 240 )) && mark=240
    (( mark > 720 )) && mark=720
    mark=$((mark - mark % 2))
    printf '%s\n' "$mark"
}
