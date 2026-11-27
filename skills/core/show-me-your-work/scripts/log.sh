#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Adapted from pstack skills/show-me-your-work/scripts/log.sh (Copyright (c) poteto).
#
# Append a well-formed row to a show-me-your-work decision log (TSV).
# Usage: log.sh <logfile> <phase> <decision> <why> <evidence> <result>
set -euo pipefail

if [ "$#" -ne 6 ]; then
	printf 'usage: log.sh <logfile> <phase> <decision> <why> <evidence> <result>\n' >&2
	exit 1
fi

logfile="$1"
shift

logdir="$(dirname "$logfile")"
if [ -n "$logdir" ] && [ "$logdir" != "." ] && [ ! -d "$logdir" ]; then
	mkdir -p "$logdir"
fi

# Append with `>>` so concurrent/network-mount checks never clobber prior rows.
if [ ! -s "$logfile" ]; then
	printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' >>"$logfile"
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Flatten tabs/newlines/CR to spaces and neutralize spreadsheet formula prefixes
# (=, +, -, @) with a leading single quote so untrusted evidence cannot execute.
clean() {
	local v
	v=$(printf '%s' "$1" | tr '\t\n\r' '   ')
	case "$v" in
	=* | +* | -* | @*) printf "'%s" "$v" ;;
	*) printf '%s' "$v" ;;
	esac
}

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
	"$ts" "$(clean "$1")" "$(clean "$2")" "$(clean "$3")" "$(clean "$4")" "$(clean "$5")" \
	>>"$logfile"
