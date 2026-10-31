# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`btrkeeper` is a single zsh script wrapping `btrfs`, `smartctl` and `wipefs` for a two-disk btrfs
RAID1 root filesystem. It adds no capability — it adds sequencing and guardrails: pairing the
operations btrfs makes you remember to do together, and putting a confirmation in front of the ones
that eat a disk. `README.md` is the user-facing documentation; `btrkeeper help <command>` is the
same material scoped per command, and is the copy that gets read at a terminal mid-maintenance.

## Commands

```
make check                  # lint, then test -- run this before committing
make test                   # tests/smoke.sh: every command, against a mocked sudo
make lint                   # zsh -n, bash -n on the hooks, systemd-analyze verify
make install                # ~/.local/bin/btrkeeper
make install-system         # /usr/local/bin/btrkeeper, where the units expect it
make hooks                  # install the contrib boot hooks
make timers                 # install and enable the scrub and audit timers
make status / audit         # run the tool against this machine
```

## Scope

**This is a btrfs tool.** It never writes a partition table, an ESP, a bootloader or a firmware
variable. `btrkeeper boot` audits whether the array is bootable from every member and reports; it
does not fix. That boundary is deliberate and has been raised and settled once already — the
adjacent work (partitioning, Limine, `efibootmgr`, keeping a mirror ESP current) lives in
`contrib/` and `docs/bootable-mirror-rebuild.md`, not in the script.

## Dependencies

Nothing installs them. `make install` copies one file; `btrfs-progs`,
`smartmontools`, `util-linux` and `zsh` are the user's to provide. `resolve_bin`
falls through to `/usr/bin/<name>` when it finds nothing, so without a check the
failure surfaces as `sudo: /usr/bin/btrfs: command not found` several frames
deep. `assert_tools` runs first instead — a core set from `main` for every
command but `help` and `doctor`, plus `smartctl` in `health` and `wipefs` in
`add` — and `btrkeeper doctor` reports the whole picture without asserting
anything.

The smoke suite stubs the three privileged binaries and points
`BTRKEEPER_BTRFS`/`_SMARTCTL`/`_WIPEFS` at the stubs, so it stays runnable on a
host with no filesystem toolchain rather than having CI apt-install one.

## Architecture

### The privilege seam

`btrfs()`, `smartctl()` and `wipefs()` are zsh *functions* that shell out to `command sudo
<abs-path>`. Everything below them reads as though it were root but never is. Paths are probed
across `/usr/bin`, `/usr/sbin`, `/sbin`, `/bin` with `BTRKEEPER_*` overrides, and whatever they
resolve to must match the user's sudoers rule.

The documented sudoers example grants `btrfs` and `smartctl` only. **`wipefs` is omitted on
purpose**: it is the one binary that destroys data outright, `add` is the only caller, and leaving
it out means routine work runs unprompted while the command that wipes a drive still asks. Do not
"fix" the example by completing the set.

### zsh traps that have already bitten

- **`local path` clobbers `PATH`.** `path` is zsh's array form of `$PATH`, so declaring it local
  empties the search path for the rest of the function and every command lookup fails. Cost an hour
  once. The variable is `devpath` throughout for this reason. `status`, `argv` and `prompt` are the
  same class of trap.
- **`errexit` + `pipefail` propagate out of `$( )`.** A helper whose last statement is a pipeline
  will kill the whole run when the left side exits non-zero — `lsblk` returns 32 for a device it
  does not know, which is exactly the degraded-array case these helpers exist to survive. Both
  `parent_disk` and `esp_on` were written this way and both had to be fixed. Any helper that shells
  out to `lsblk`/`findmnt`/`df` must capture with `|| var=""` and end with an explicit `return 0`.
- **`(( x++ ))` returns the *old* value**, so incrementing a counter through zero returns status 1
  and trips `errexit`. Counters use `x=$(( x + 1 ))`.
- Two things that look like bugs and are not, verified: zsh **does** field-split unquoted `$(...)`,
  so `for dev in $(fs_devices)` and `members=($(fs_devices))` are correct; and `(( $# )) && shift`
  is exempt from `errexit` as the non-final command of an AND-list.

### Naming things that move

Nothing user-facing may key on an identifier the system renumbers.

| Thing | Stable key | Why not the obvious one |
| --- | --- | --- |
| Array members | btrfs **devid** | A dead drive has no `/dev` node, so `replace`/`remove` accept a devid — the failure the tool exists for |
| Device arguments | resolved through `readlink -f` | `/dev/disk/by-id/...` is what people are told to use, and string-comparing it against btrfs's kernel names silently fails |
| Firmware boot entries | **partition GUID** | Bootnums are volatile: this machine's BBS entries renumbered across a single reboot |
| An ESP | partition type GUID `c12a7328-…` | Present on every UEFI machine; it is a type, not an identity, and is the one UUID in this repo |

### Colour is information, and two scales run opposite ways

`status` and `health` grade numbers, and **the direction is not uniform**:

- *Allocation pressure* — `Device allocated` against `Device size`, and unallocated headroom. High
  is bad. The computed percentage is printed next to the value so the colour is not opaque.
- *Chunk packing* — the `(NN.NN%)` on a `Data`/`Metadata` line. This is `Used/Size` **within
  already-allocated chunks**, not fullness. **Low is bad**: it means allocation is spread across
  half-empty chunks, which is what `balance quick` (`-dusage=50`) compacts. A dense 99.76% is
  healthy. Grading this as fullness was the original implementation and it painted a healthy array
  red; the thresholds now mirror `-dusage=50` so orange means that command would actually reclaim
  something. `System` and `GlobalReserve` are excluded — they are tiny and always look sparse.
- SMART *Available Spare* is likewise inverted, and a SATA `WHEN_FAILED` marker overrides the raw
  value entirely. CRC errors are orange rather than red: they usually indicate a cable, and should
  not compete visually with a pending sector.

Colour auto-disables when stdout is not a terminal; `--raw`/`--no-color`/`NO_COLOR` force it off.
Values are painted by substring offset, never by rebuilding `$0` in awk, so smartctl's column
alignment survives.

## Decisions not to re-litigate

- **`upgrade` scrubs between its two replaces, blocking, and stops if that scrub finds errors.**
  Replacing both members back to back leaves a window where a latent bad block on the second
  original is the only copy of some data. The wait is the point of the command.
- **`convert single`** exists so a device can be freed — RAID1 chunks require two devices, so the
  array will not release one until nothing depends on the second. Metadata goes to `dup`, not
  `single`: still two copies, and losing metadata loses the filesystem rather than a file.
- **`scrub run` blocks; `scrub start` does not.** The timer uses `run`, because a unit calling
  `start` would report success the instant the kernel accepted the request, whatever the scrub went
  on to find. A monitoring job that cannot fail is worse than none.
- **`add`/`replace`/`upgrade` refuse a device that is mounted, held by md/LUKS/LVM, or already a
  member**, and warn when consuming a whole disk would leave a member unable to boot. The guards
  run before any prompt.
- Prompts read the terminal directly and fail closed with no tty, so `-y` is the only way to run
  unattended. That is deliberate.

## Testing

`make check` is lint **and** test. `zsh -n` only parses: it cannot see a call to a function that no
longer exists, which is precisely how `color_smart_health` went missing — a refactor replaced a
file slice and deleted two functions that happened to lie inside it, `zsh -n` stayed clean, and the
regression suite of the day only exercised `help`. `tests/smoke.sh` runs **every** command and
fails on `command not found`.

It mocks the privileged layer by putting a fake `sudo` first on `PATH`, so nothing touches a real
filesystem and no root is needed. When adding a command, add it to the suite; when changing output
that another target parses, check the mock still produces something representative.

**When editing this script, prefer anchored string replacement over index slicing.** The one
regression in its history came from `s[:start] + new + s[end:]` silently deleting what sat between.

## Conventions

Comments explain *why* — a btrfs behaviour, a zsh trap, or a decision that looks arbitrary without
its reason. Do not add comments that restate the line below them.

Help pages are per-command (`btrkeeper help <command>`), not one wall on the root page. Each
carries the caveats for that command: what blocks, what gets wiped, what to run next. The root page
is an index. Two topic pages, `devices` and `sudo`, cover what genuinely spans commands. When a
command grows a behaviour worth knowing, it goes on that command's page.

Commit messages: **a subject line, and nothing else.** No body unless the change is genuinely
inexplicable without one, which is rare. Durable reasoning belongs here or in a code comment —
somewhere it will be read again — not in a git log nobody wants to scroll.
