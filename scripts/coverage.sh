#!/usr/bin/env bash
# Test coverage using DWARF line tables + debugger breakpoints.
# Linux: readelf + GDB
# macOS: dwarfdump + LLDB (auto-creates dSYM bundles)
#
# Usage: coverage.sh <source-dir> <binary1> [binary2 ...]
set -euo pipefail

SRC_DIR="${1:?Usage: coverage.sh <source-dir> <binary1> [binary2 ...]}"
shift
BINS=("$@")
if [ ${#BINS[@]} -eq 0 ]; then
  echo "Error: at least one binary required" >&2
  exit 1
fi
SRC_DIR_ABS="$(cd "$SRC_DIR" && pwd)"

OS="$(uname -s)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ============================================================
# Section 1: Extract address->file:line from DWARF line tables
# ============================================================
: >"$TMPDIR/addr_map.tsv"

if [ "$OS" = "Linux" ]; then
  # --- Linux: readelf --debug-dump=decodedline ---
  # shellcheck disable=SC2016
  EXTRACT_AWK='
    /^\/.*:$/ {
      path = $0; sub(/:$/, "", path)
      in_src = (index(path, srcdir) == 1)
      if (in_src) { n = split(path, parts, "/"); current_file = parts[n] }
      next
    }
    in_src && /^[a-zA-Z_].*\.zig / {
      file = $1; line = $2; addr = $3
      if (addr == "" || addr == "0x0") next
      gsub(/^0x0+/, "0x", addr)
      if (addr == "0x") next
      if (file == current_file) print addr "\t" file "\t" line
    }
  '
  for i in "${!BINS[@]}"; do
    readelf --debug-dump=decodedline "${BINS[$i]}" 2>/dev/null |
      awk -v srcdir="$SRC_DIR_ABS" "$EXTRACT_AWK" |
      sort -u >"$TMPDIR/addr_map_${i}.tsv"
    cat "$TMPDIR/addr_map_${i}.tsv" >>"$TMPDIR/addr_map.tsv"
  done
else
  # --- macOS: dsymutil + dwarfdump ---
  # DWARF v4: dir_index=0 refers to DW_AT_comp_dir (from .debug_info),
  # not include_directories. We extract comp_dirs per CU first.
  # shellcheck disable=SC2016
  EXTRACT_AWK='
    BEGIN {
      cu = -1
      while ((getline cd < compdir_file) > 0) {
        comp_dirs[++cu] = cd
      }
      cu = -1
    }
    /^debug_line\[/ { cu++; next }
    /include_directories\[/ {
      s = $0; sub(/.*\[[ ]*/, "", s); sub(/\].*/, "", s)
      didx = s + 0
      n = split($0, q, "\"")
      if (n >= 2) inc_dirs[cu, didx] = q[2]
      next
    }
    /^[ \t]*file_names\[/ {
      s = $0; sub(/.*\[[ ]*/, "", s); sub(/\].*/, "", s)
      cur_fidx = s + 0
      next
    }
    /^[ \t]*name:/ {
      n = split($0, q, "\"")
      if (n >= 2) fnames[cu, cur_fidx] = q[2]
      next
    }
    /^[ \t]*dir_index:/ {
      s = $0; sub(/.*dir_index:[ ]*/, "", s); sub(/[^0-9].*/, "", s)
      didx = s + 0
      if (didx == 0)
        fdir_path[cu, cur_fidx] = comp_dirs[cu]
      else
        fdir_path[cu, cur_fidx] = inc_dirs[cu, didx]
      next
    }
    /^0x[0-9a-f]+[ \t]+[0-9]/ {
      addr = $1; line = $2; file_idx = $4
      fname = fnames[cu, file_idx]
      dpath = fdir_path[cu, file_idx]
      if (fname !~ /\.zig$/) next
      if (index(dpath, srcdir) != 1) next
      if (addr == "0x0" || addr == "0x0000000000000000") next
      gsub(/^0x0+/, "0x", addr)
      if (addr == "0x") next
      print addr "\t" fname "\t" line
    }
  '
  for i in "${!BINS[@]}"; do
    BIN_PATH="${BINS[$i]}"
    DSYM="${BIN_PATH}.dSYM"

    # Create dSYM bundle (required for DWARF on macOS)
    echo "Creating dSYM for $(basename "$BIN_PATH")..."
    dsymutil "$BIN_PATH" -o "$DSYM" 2>&1

    # Extract comp_dirs from .debug_info
    dwarfdump --debug-info "$DSYM" 2>/dev/null |
      awk '/DW_AT_comp_dir/ { n = split($0, q, "\""); if (n >= 2) print q[2] }' \
        >"$TMPDIR/comp_dirs_${i}.txt"

    # Extract addr->file:line from .debug_line
    dwarfdump --debug-line "$DSYM" 2>/dev/null |
      awk -v srcdir="$SRC_DIR_ABS" -v compdir_file="$TMPDIR/comp_dirs_${i}.txt" \
        "$EXTRACT_AWK" |
      sort -u >"$TMPDIR/addr_map_${i}.tsv"
    cat "$TMPDIR/addr_map_${i}.tsv" >>"$TMPDIR/addr_map.tsv"
  done
fi

sort -u -o "$TMPDIR/addr_map.tsv" "$TMPDIR/addr_map.tsv"

TOTAL_ADDRS=$(awk '{print $1}' "$TMPDIR/addr_map.tsv" | sort -u | wc -l | tr -d ' ')
echo "Found $TOTAL_ADDRS executable addresses in source files"

if [ "$TOTAL_ADDRS" -eq 0 ]; then
  echo "Error: no addresses found." >&2
  if [ "$OS" = "Linux" ]; then
    echo "Is the binary patched?" >&2
  else
    echo "Does dwarfdump produce line table output for this binary?" >&2
  fi
  exit 1
fi

# ============================================================
# Section 2: Find debugger
# ============================================================
if [ "$OS" = "Linux" ]; then
  DEBUGGER=$(command -v gdb 2>/dev/null || echo "")
  if [ -z "$DEBUGGER" ]; then
    echo "Error: gdb not found. Install gdb or run: nix shell nixpkgs#gdb" >&2
    exit 1
  fi
else
  DEBUGGER=$(command -v lldb 2>/dev/null || echo "")
  if [ -z "$DEBUGGER" ]; then
    echo "Error: lldb not found. Install Xcode Command Line Tools." >&2
    exit 1
  fi
fi

# ============================================================
# Section 3: Run tests under debugger to collect hit addresses
# ============================================================
: >"$TMPDIR/hit_addrs.txt"

for i in "${!BINS[@]}"; do
  BIN="${BINS[$i]}"
  MAP="$TMPDIR/addr_map_${i}.tsv"
  ADDR_FILE="$TMPDIR/addrs_${i}.txt"

  awk '{print $1}' "$MAP" | sort -u >"$ADDR_FILE"
  ADDR_COUNT=$(wc -l <"$ADDR_FILE" | tr -d ' ')

  if [ "$ADDR_COUNT" -eq 0 ]; then continue; fi

  if [ "$OS" = "Linux" ]; then
    # --- GDB ---
    {
      echo "set pagination off"
      echo "set confirm off"
      awk '{print "break *" $1}' "$ADDR_FILE"
      seq 1 "$ADDR_COUNT" | while read -r j; do
        echo "commands $j"
        echo "  silent"
        echo "  continue"
        echo "end"
      done
      echo "run"
      echo "info breakpoints"
      echo "quit"
    } >"$TMPDIR/gdb_script_${i}.gdb"

    echo "Running $(basename "$BIN") under GDB with $ADDR_COUNT breakpoints..."
    "$DEBUGGER" -batch -x "$TMPDIR/gdb_script_${i}.gdb" "$BIN" >"$TMPDIR/debugger_output_${i}.log" 2>&1

    grep -B1 "breakpoint already hit" "$TMPDIR/debugger_output_${i}.log" |
      grep -oE '0x[0-9a-f]+' |
      sed 's/^0x0*/0x/' |
      sort -u >>"$TMPDIR/hit_addrs.txt"
  else
    # --- LLDB ---
    # Breakpoints must be set after the process is loaded (address
    # breakpoints stay unresolved otherwise due to ASLR).  We launch
    # with --stop-at-entry, set breakpoints, then continue.
    {
      echo "settings set auto-confirm true"
      echo "settings set target.disable-aslr true"
      echo "process launch --stop-at-entry"
      awk '{
        printf "breakpoint set -a %s\n", $1
      }
      END {
        printf "breakpoint modify -G true"
        for (i = 1; i <= NR; i++) printf " %d", i
        printf "\n"
      }' "$ADDR_FILE"
      echo "continue"
      echo "breakpoint list"
      echo "quit"
    } >"$TMPDIR/lldb_script_${i}.lldb"

    echo "Running $(basename "$BIN") under LLDB with $ADDR_COUNT breakpoints..."
    "$DEBUGGER" -b -s "$TMPDIR/lldb_script_${i}.lldb" "$BIN" >"$TMPDIR/debugger_output_${i}.log" 2>&1

    # Extract breakpoint numbers with hit count > 0, map back to addresses.
    # lldb breakpoint list format:
    #   N: address = binary[0xADDR], ..., hit count = M
    awk '/^[0-9]+: .*hit count = / {
      bpnum = $0; sub(/:.*/, "", bpnum); gsub(/[ \t]/, "", bpnum)
      s = $0; sub(/.*hit count = /, "", s); sub(/[^0-9].*/, "", s)
      if (s + 0 > 0) print bpnum
    }' "$TMPDIR/debugger_output_${i}.log" >"$TMPDIR/hit_bps_${i}.txt"

    awk 'NR==FNR { hit[$1]=1; next }
        FNR in hit
    ' "$TMPDIR/hit_bps_${i}.txt" "$ADDR_FILE" >>"$TMPDIR/hit_addrs.txt"
  fi
done

sort -u -o "$TMPDIR/hit_addrs.txt" "$TMPDIR/hit_addrs.txt"

HIT_COUNT=$(wc -l <"$TMPDIR/hit_addrs.txt" | tr -d ' ')
echo "Hit $HIT_COUNT / $TOTAL_ADDRS addresses"
echo ""

# ============================================================
# Section 4: Cross-reference hits with addr->file:line map
# ============================================================

# Compute per-file stats (POSIX awk compatible — no asorti)
awk -v hitfile="$TMPDIR/hit_addrs.txt" '
BEGIN {
  while ((getline addr < hitfile) > 0) hit[addr] = 1
}
{
  addr = $1; file = $2; line = $3
  key = file SUBSEP line
  if (!(key in line_file)) {
    line_file[key] = file
    files[file] = 1
  }
  if (addr in hit) covered[key] = 1
}
END {
  for (key in line_file) {
    file = line_file[key]
    total_lines[file]++
    total_all++
    if (key in covered) {
      covered_lines[file]++
      covered_all++
    }
  }
  for (f in files) {
    cov = covered_lines[f] + 0
    tot = total_lines[f] + 0
    pct = (tot > 0) ? cov / tot * 100 : 0
    printf "%s\t%d\t%d\t%.1f\n", f, cov, tot, pct
  }
}
' "$TMPDIR/addr_map.tsv" | sort -t"$(printf '\t')" -k1,1 >"$TMPDIR/file_stats.tsv"

# Print report
printf "\n%-20s %8s %8s %8s\n" "File" "Covered" "Total" "Coverage"
printf "%-20s %8s %8s %8s\n" "----" "-------" "-----" "--------"
awk -F'\t' '{ printf "%-20s %8d %8d %7.1f%%\n", $1, $2, $3, $4 }' "$TMPDIR/file_stats.tsv"
printf "%-20s %8s %8s %8s\n" "----" "-------" "-----" "--------"
awk -F'\t' '{ cov += $2; tot += $3 } END {
  pct = (tot > 0) ? cov / tot * 100 : 0
  printf "%-20s %8d %8d %7.1f%%\n", "TOTAL", cov, tot, pct
}' "$TMPDIR/file_stats.tsv"
