#!/usr/bin/env bash
# Execute every btrkeeper command against a mocked privileged layer.
#
# The point is coverage of runtime paths, not correctness of btrfs itself:
# 'zsh -n' cannot see a call to a function that no longer exists, and a
# suite that only exercises 'help' will not either. Every command here is
# actually run, and any "command not found" fails the suite.

set -uo pipefail
cd "$(dirname "$0")/.."
BTRKEEPER="./btrkeeper"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/sudo" <<'MOCK'
#!/bin/sh
bin=$1; shift
case "$(basename "$bin")" in
  btrfs)
    case "$1 $2" in
      "filesystem show")
        printf 'Label: none  uuid: aaaa-bbbb\n'
        printf '\tTotal devices 2 FS bytes used 435.40GiB\n'
        if [ "$2" = "--raw" ] || [ "$3" = "--raw" ]; then
          printf '\tdevid    1 size 2000398934016 used 469762048000 path /dev/nvme0n1p2\n'
          printf '\tdevid    2 size 2000398934016 used 469762048000 path /dev/nvme1n1p2\n'
        else
          printf '\tdevid    1 size 1.82TiB used 437.06GiB path /dev/nvme0n1p2\n'
          printf '\tdevid    2 size 1.82TiB used 437.06GiB path /dev/nvme1n1p2\n'
        fi ;;
      "filesystem usage")
        printf 'Overall:\n    Device size:                   3.63TiB\n'
        printf '    Device allocated:            874.12GiB\n'
        printf '    Device unallocated:            2.78TiB\n'
        printf '    Device missing:                  0.00B\n'
        printf '    Multiple profiles:                  no\n\n'
        printf 'Data,RAID1: Size:435.00GiB, Used:433.96GiB (99.76%%)\n'
        printf 'Metadata,RAID1: Size:2.00GiB, Used:1.44GiB (72.16%%)\n' ;;
      "device stats")
        printf '[/dev/nvme0n1p2].write_io_errs     0\n'
        printf '[/dev/nvme1n1p2].corruption_errs  12\n' ;;
      *) printf 'MOCK btrfs %s\n' "$*" ;;
    esac ;;
  smartctl)
    case "$1" in
      -H) echo "SMART overall-health self-assessment test result: PASSED" ;;
      -A) printf 'Percentage Used:                    92%%\n'
          printf 'Available Spare:                    15%%\n'
          printf 'Media and Data Integrity Errors:    4\n'
          printf 'Temperature:                        61 Celsius\n'
          printf 'Power On Hours:                     12,345\n'
          printf '197 Current_Pending_Sector  0x0032   100   100   000    Old_age   Always       -       8\n' ;;
    esac ;;
  wipefs) printf 'MOCK wipefs %s\n' "$*" ;;
esac
MOCK
chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"

pass=0; fail=0
run() {  # run <expected-exit|any> <args...>
    local want="$1"; shift
    local out rc
    out="$("$BTRKEEPER" "$@" 2>&1)"; rc=$?
    if grep -qiE 'command not found|no such file or directory|parse error|bad (option|pattern|substitution)' <<<"$out"; then
        printf 'FAIL  %-34s runtime error\n' "$*"
        sed 's/^/        /' <<<"$out" | head -4
        fail=$(( fail + 1 )); return
    fi
    if [[ "$want" != any && "$rc" != "$want" ]]; then
        printf 'FAIL  %-34s exit=%s want=%s\n' "$*" "$rc" "$want"
        fail=$(( fail + 1 )); return
    fi
    printf 'ok    %-34s exit=%s\n' "$*" "$rc"
    pass=$(( pass + 1 ))
}

echo "── commands ──"
run 0 status
run 0 health
run 0 boot
run 0 scrub status
run 0 scrub start
run 0 scrub run
run 1 scrub bogus
run 0 balance status
run 0 balance quick
run 0 balance full
run 1 balance bogus
run 0 -y convert
run 0 -y convert raid1
run 0 -y convert single
run 1 convert bogus
run 0 -y stats-reset
run 0 -y remove 2
run 1 remove 99
run 1 replace 99 /dev/null
run 1 add /dev/null
run 1 upgrade /dev/null /dev/null

echo "── options ──"
run 0 --raw status
run 0 --no-color health
run 0 -m / status
run 1 -m /proc status
run 1 --frobnicate
run 0 --help

echo "── help ──"
run 0 help
for t in status health scrub balance convert add remove replace upgrade boot \
         stats-reset devices boot sudo; do
    run 0 help "$t"
done
run 1 help nonsense

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
