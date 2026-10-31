# btrkeeper

A small zsh helper for keeping a two-disk btrfs RAID1 filesystem healthy:
status and SMART reporting, scrubs, balances, and device add/remove/replace —
including a guided swap of both mirror members onto larger drives.

It is a thin wrapper around `btrfs`, `smartctl`, and `wipefs`. It does not
hide what it runs; every destructive action asks for confirmation first, and
refuses outright to touch a device that is mounted, claimed by md/LUKS/LVM,
or already part of the array.

## Install

```sh
install -m 0755 btrkeeper ~/.local/bin/btrkeeper
```

Make sure `~/.local/bin` is on your `PATH`.

### Requirements

- `zsh`
- `btrfs-progs` — `btrfs`
- `smartmontools` — `smartctl`
- `util-linux` — `wipefs`, `lsblk`, `findmnt`

Nothing installs these for you — `make install` copies a single file. Run
`btrkeeper doctor` to see which are present, with paths and versions; every
other command checks the ones it needs first and names what is missing.

The three privileged binaries are looked up in `/usr/bin`, `/usr/sbin`,
`/sbin`, and `/bin`, in that order. Override any of them with
`BTRKEEPER_BTRFS`, `BTRKEEPER_SMARTCTL`, or `BTRKEEPER_WIPEFS` — whatever
path is used has to match your sudoers rule exactly.

### Sudo

The privileged binaries are invoked through `sudo` at their absolute paths, so
the script itself runs unprivileged. To avoid repeated password prompts during
a long maintenance session, add a sudoers rule — e.g. `/etc/sudoers.d/btrkeeper`,
installed with `visudo -f`:

```
%wheel ALL=(root) NOPASSWD: /usr/bin/btrfs, /usr/bin/smartctl
```

`wipefs` is deliberately absent from that example. It is the one binary here
that destroys data outright, and `add` is the only command that calls it, so
leaving it out means routine work runs unprompted while the command that
wipes a drive still asks for a password. Granting it is a decision for whoever
deploys this — not a default this project should hand out.

Even as written the rule is substantial: passwordless `btrfs` can remove
devices and start balances. Scope it to a single user rather than a group if
that matters to you, and drop `NOPASSWD:` entirely if you would rather be
asked every time.

## Usage

```
btrkeeper [options] <command> [args]
```

### Options

| Option | Meaning |
| --- | --- |
| `-m`, `--mount PATH` | Filesystem to operate on (default `/`) |
| `-y`, `--yes` | Assume yes; skip confirmation prompts |
| `-h`, `--help` | Help text |
| `--raw`, `--no-color` | Plain output, no color |

`BTRKEEPER_MOUNT` sets a different default target; `-m` always wins.

```sh
btrkeeper -m /srv/data status
```

`-y` exists for cron and systemd timers. Without it the confirmation prompt
reads the terminal directly and fails closed when there isn't one, so an
unattended run aborts rather than proceeding.

### Color

`status` and `health` are color-coded by default: green healthy, yellow
informational, orange warning, red bad.

In `status`, two numbers grade in **opposite directions**:

- **Allocation pressure** — `Device allocated` against `Device size`, and the
  unallocated headroom. High is bad: green under 70% allocated, yellow to 85%,
  orange to 95%, red past that. The computed percentage is printed alongside.
- **Chunk packing** — the `(NN.NN%)` on a `Data` or `Metadata` line. This is
  `Used/Size` *within already-allocated chunks*, not how full the filesystem
  is, so **low** is bad: it means allocation is spread across half-empty
  chunks. Green at 75%+, yellow 50–75%, orange under 50% — which is precisely
  what `balance quick` (`-dusage=50`) compacts, so those lines get an inline
  hint. A dense 97% is healthy. `System` and `GlobalReserve` chunks are tiny
  and always look sparse, so they are left ungraded.

Everything else in `status`: red for a non-zero error counter, a missing
device, or RAID0; orange for an unmirrored `single`/`DUP` profile or multiple
profiles present; yellow for labels and totals; green for healthy.

In `health` — red for a FAILED verdict, an attribute marked failing, any
reallocated/pending/offline-uncorrectable sector, any media integrity error,
wear over 95%, spare under 10%, or 70 °C and up; orange for CRC errors
(usually a cable, not the drive), wear 85–95%, spare 10–20%, 60–70 °C, or a
drive that returns no SMART data at all; yellow for power-on hours and other
neutral counters; green for a healthy drive. Run `btrkeeper help health` for
the full grading.

Color turns itself off when output is not a terminal, so pipes and redirects
give plain text. Force it off with `--raw` (or `--no-color`), or `NO_COLOR=1`.

### Commands

| Command | What it does |
| --- | --- |
| `status` | Filesystem layout, allocation/usage, and per-device error counters |
| `health` | SMART health and wear indicators for each member disk, plus btrfs counters |
| `scrub start\|status\|cancel` | Verify checksums and repair from the good mirror |
| `balance full\|quick\|status\|cancel` | Rewrite chunks; `quick` only compacts chunks under 50% used |
| `convert [raid1\|single]` | Convert profiles; `raid1` mirrors, `single` frees a device for removal |
| `add <dev>` | Wipe a drive and add it to the pool |
| `remove <dev\|devid>` | Migrate data off a drive and detach it |
| `replace <old\|devid> <new>` | Swap one member for a new drive, then grow into its full size |
| `upgrade <new1> <new2>` | Swap both members for bigger drives, scrubbing in between |
| `boot` | Audit that every member disk can actually boot the system |
| `doctor` | Report required tools, the target filesystem, privileges and install state |
| `stats-reset` | Zero the per-device error counters |
| `help` | Command summary |

`scrub` and `balance` default to `status` when given no action. Running
`btrkeeper` with no arguments prints the command index.

Every command has its own help page, carrying the caveats that matter for
that command — what blocks, what gets wiped, what to run next:

```sh
btrkeeper help upgrade
btrkeeper replace --help    # same thing
```

Two topic pages cover what spans commands: `btrkeeper help devices` (by-id
paths, devids, naming a drive that is already dead) and `btrkeeper help sudo`
(privileges, binary paths, unattended runs).

### Naming devices

Devices may be given as `/dev/sdX` or as stable `/dev/disk/by-id/...` paths;
symlinks are resolved before anything is matched against the array.

`remove` and `replace` also accept a bare devid, which is how you name a drive
that has already disappeared — `btrkeeper status` lists them. Replacing a
missing device requires the filesystem to be mounted `-o degraded`.

## Common tasks

### Routine check

```sh
btrkeeper status     # capacity and error counters
btrkeeper health     # SMART wear, media errors, temperature
btrkeeper scrub start
btrkeeper scrub status
```

A scrub runs in the background; re-run `scrub status` to follow it.

### Adding a second disk and mirroring onto it

```sh
btrkeeper add /dev/disk/by-id/nvme-WD_BLACK_SN850X_2TB_1234
btrkeeper convert
```

`add` shows you the device and its existing signatures, then wipes it. It
refuses a device that is mounted, held by md/LUKS/LVM, or already a member —
but everything past those checks is fair game, so read the prompt. `convert`
rewrites every chunk as RAID1 and can take hours on a full filesystem.

`convert single` is the inverse: it drops data to one copy and metadata to
`DUP`, which is what frees a device for `remove`. It is the only command here
that deliberately removes redundancy, and it says so plainly before it runs.

### Replacing a failing disk

```sh
btrkeeper health                              # identify the bad member
btrkeeper replace /dev/nvme1n1 /dev/nvme2n1
btrkeeper scrub start                         # verify the rebuilt mirror
```

If the drive is already gone, name it by devid instead:

```sh
btrkeeper status                              # find the devid
btrkeeper replace 2 /dev/nvme2n1
```

`replace` runs `btrfs replace start -B -f`, so it blocks until the copy
finishes, then resizes the new device to its maximum size. A drive smaller
than the member it has to hold is rejected before anything is wiped;
equal-sized is fine.

### Growing the array onto larger drives

With both new drives attached:

```sh
btrkeeper upgrade /dev/nvme2n1 /dev/nvme3n1
```

It prints the plan — with the old and new size of each member — asks once,
then: replaces member 1, resizes, **scrubs and waits**, replaces member 2, resizes, and kicks off a final scrub. The
filesystem stays online throughout, and it requires exactly two existing
members.

The middle scrub is the point of the command. Replacing both members
back-to-back would leave a window where a latent bad block on the second
original is the only copy of some data — the scrub proves the first new mirror
before the second original is destroyed, and the upgrade stops if it finds
anything. On a large filesystem this is the slow part, by design.

### Checking the mirror is bootable, not just redundant

```sh
btrkeeper boot
```

RAID1 mirrors the filesystem, not the boot path. `boot` checks that every
member disk carries an EFI System Partition, that each is named by a firmware
boot entry present in `BootOrder`, and that the ESPs have not drifted apart.
It is read-only — it never writes a partition table, an ESP, or a firmware
variable.

Boot entries are matched by partition GUID rather than bootnum, because some
firmwares renumber their BBS entries on every boot. Run it as root to compare
ESP contents; unprivileged it can only compare sizes and will say so. Exit
status is 1 if any member disk cannot boot.

The failure it exists to catch is the quiet one: a mirror ESP that went stale
months ago and is only discovered when the live one is gone. See
`btrkeeper help boot`, and `contrib/` for hooks that keep the copies current.

### After investigating errors

```sh
btrkeeper stats-reset
```

Only zero the counters once you know why they went up. They are cumulative
since the last reset, not since boot.

## Notes

### Behavior

- `set -euo pipefail` is on: the script stops at the first failing command.
- Confirmation prompts read a single key and default to *no*. They read the
  terminal directly and fail closed when there isn't one, so an unattended run
  aborts unless you pass `-y`.
- `scrub` and `balance` (including `convert`, which is a balance) return
  immediately and run in the kernel — poll them with `scrub status` and
  `balance status`. `remove`, `replace`, and `upgrade` block until the copy or
  migration finishes.
- The filesystem stays online and usable during `replace` and `upgrade`; the
  copy is read from the surviving mirror.

### Safety checks

- `add`, `replace`, and `upgrade` refuse a device that is mounted (itself or
  any of its partitions), claimed by md/LUKS/LVM, or already a member of the
  target filesystem. Anything past those checks *will* be wiped — `add` prints
  the device and its existing signatures before asking.
- `replace` and `upgrade` compare the new drive against the btrfs-recorded size
  of the member it replaces (`btrfs filesystem show --raw`) and refuse a
  smaller one up front. Equal-sized is fine. If either size can't be read they
  warn and let btrfs make the call, rather than blocking a legitimate replace.
- `upgrade` requires exactly two members and two distinct new drives, and
  scrubs between the two replaces — stopping if that scrub finds errors, rather
  than destroying your last good copy.
- `convert raid1` refuses to run on a single-device filesystem; `convert single`
  is allowed there, since it removes no redundancy that exists.
- Device paths are resolved through symlinks before anything is matched against
  the array, so `/dev/disk/by-id/...` names work everywhere a path is accepted.

### Reporting

- `health` resolves each btrfs member to its parent disk, so it reports SMART
  data correctly whether the filesystem sits on whole disks or partitions. The
  attribute filter covers NVMe wear (percentage used, available spare, media
  and data integrity errors) and the SATA attributes that actually predict
  failure (reallocated, current pending, offline uncorrectable, UDMA CRC), plus
  temperature and power-on hours. A member whose drive is missing or unreadable
  is skipped rather than aborting the run.
- Error counters are cumulative since the last `stats-reset`, not since boot, so
  a non-zero value may be years old. Investigate before zeroing them.
- `status` and `health` group their output under headings in both color and
  `--raw` modes; only the color differs.
- `health` reports a drive that returns no SMART data instead of silently
  skipping it, and its health-verdict line now also matches the SAS-style
  `SMART Health Status: OK`.
- `filesystem usage`, included in `status`, is what answers "why is it full" —
  it separates allocated from used, which `df` cannot show you.

### Environment

- `BTRKEEPER_MOUNT` sets the default target filesystem; `-m` overrides it.
- `BTRKEEPER_BTRFS`, `BTRKEEPER_SMARTCTL`, `BTRKEEPER_WIPEFS` override the
  probed binary paths. Whatever is used must match your sudoers rule exactly.

Each of these is also on the relevant command's own help page, next to the
command it applies to — `btrkeeper help <command>`.

## License

MIT.
