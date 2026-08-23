# Rebuilding a whole-disk member into a bootable mirror

How to take a two-disk btrfs RAID1 where one member is a **whole disk** and
convert it into one where **both disks can boot independently**.

Written against this layout:

```
nvme0n1   ├─ p1  4G  vfat  ESP, mounted /boot
          └─ p2  1.8T btrfs  devid 1
nvme1n1      whole disk btrfs, no partition table, devid 2
```

Substitute your own device names and UUIDs throughout. `<FS-UUID>` below is
the btrfs filesystem UUID from `btrkeeper status`.

## Why this is necessary

btrfs RAID1 mirrors the filesystem, not the boot path. The ESP holds the
bootloader, kernel images and initramfs, and it exists on one disk only.
There is no safe way to carve an ESP out of a disk that is already a
whole-disk btrfs member: a GPT has to live at the start of the disk, a GPT
partition cannot begin before LBA 34, and btrfs's superblock sits at 64 KiB
from the disk start — so any partition you defined would not itself be a
valid btrfs device. The array has to give the disk back first.

## Choose a path

**Path A — with one spare drive (strongly preferred).** The array never
loses redundancy. Requires a free M.2 slot, or a USB NVMe enclosure.

**Path B — in place, no extra hardware.** Requires running on a single copy
of your data for several hours. Everything is recoverable if nothing fails
during that window, but "if nothing fails" is doing real work in that
sentence.

If you can borrow a drive for an afternoon, take Path A.

---

# Path A — with a spare drive

1. **Partition the spare** exactly as in Phase 3 below (ESP + btrfs).

2. **Replace the whole-disk member with it.** The array stays redundant for
   the entire copy; it reads from the surviving mirror.

   ```sh
   btrkeeper replace /dev/nvme1n1 /dev/<spare>p2
   btrkeeper scrub start
   ```

3. **Set up the second ESP** — Phase 5 below.

4. `nvme1n1` is now free. Keep it as a cold spare, or partition it and swap
   it back in later with another `btrkeeper replace`.

Done. No unredundant window at any point.

---

# Path B — in place

## Phase 0 — preflight (do not skip)

You are about to spend hours with one copy of your data. Establish that the
copy you are keeping is good.

```sh
btrkeeper status          # note the devids; confirm both members present
btrkeeper health          # zero error counters, no SMART warnings
btrkeeper scrub start
btrkeeper scrub status    # wait for completion; must report 0 errors
```

**Stop here if the scrub reports anything, or if `health` shows reallocated
or pending sectors.** Replace the failing drive first — that is a different
procedure, and a safer one.

Have a real backup of anything irreplaceable. A balance is not a backup.

Record, somewhere not on this machine: the output of `btrkeeper status`,
`/etc/fstab`, and `cat /proc/cmdline`.

## Phase 1 — drop to a single-device profile

RAID1 chunks require two devices, so the array will not release one until
nothing depends on the second.

```sh
sudo btrkeeper convert single
btrkeeper balance status        # poll
```

Metadata goes to `dup`, not `single` — two copies on the remaining disk, so
metadata still survives a bad sector. Data is unprotected from here until
Phase 4 completes.

Confirm with `btrkeeper status`: `Data,single` and `Metadata,DUP`.

## Phase 2 — remove the whole-disk member

```sh
sudo btrkeeper remove /dev/nvme1n1
```

Migrates any remaining chunks off it and detaches it. This blocks. Afterwards
`btrkeeper status` shows a single device.

## Phase 3 — partition it

`sfdisk` ships with util-linux, so it is already installed. It is also
declarative, which makes the intended layout easy to check before you commit
to it.

```sh
sudo wipefs -a /dev/nvme1n1

sudo sfdisk /dev/nvme1n1 <<'PARTS'
label: gpt
size=4GiB, type=uefi,  name="EFI system partition"
           type=linux, name="root"
PARTS

sudo partprobe /dev/nvme1n1
sudo mkfs.fat -F32 /dev/nvme1n1p1

lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPE /dev/nvme1n1
```

`type=uefi` resolves to `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`, the EFI
System Partition GUID, and `type=linux` to `0FC63DAF-...`, matching the
existing member. Those are the type codes the Phase 4 check depends on.

If you would rather use `sgdisk`, it lives in the **`gptfdisk`** package
(`sudo pacman -S gptfdisk`) — the binary name is not the package name, which
is why searching for `sgdisk` finds nothing:

```sh
sudo sgdisk -Z /dev/nvme1n1
sudo sgdisk -n1:0:+4G -t1:EF00 -c1:"EFI system partition" \
            -n2:0:0   -t2:8300 -c2:"root" /dev/nvme1n1
```

Match the ESP size to the existing one. The new btrfs partition ends up ~4 GiB
smaller than `nvme0n1p2`; RAID1 is bounded by the smaller member, so a few
GiB at the end of the larger one become unallocatable. Harmless.

## Phase 4 — add it back and re-mirror

```sh
sudo btrkeeper add /dev/nvme1n1p2
sudo btrkeeper convert
btrkeeper balance status        # poll
```

`add` should **not** print an ESP warning this time. If it does, Phase 3 did
not produce a recognised EFI System Partition — stop and check the partition
type GUID before continuing.

When the convert finishes:

```sh
btrkeeper scrub start
btrkeeper scrub status          # must report 0 errors
btrkeeper status                # expect Data,RAID1 and Metadata,RAID1
```

Redundancy is restored at this point.

## Phase 5 — make the second ESP bootable

```sh
sudo mkdir -p /boot2
sudo mount /dev/nvme1n1p1 /boot2
sudo cp -a /boot/. /boot2/

sudo efibootmgr --create --disk /dev/nvme1n1 --part 1 \
     --loader '\EFI\limine\limine_x64.efi' --label 'Limine (nvme1n1)'
```

Add it to `/etc/fstab` so it can be kept in sync:

```
UUID=<esp2-uuid> /boot2 vfat defaults,umask=0077 0 2
```

Then arrange for it to be updated when kernels change — a second hook
alongside `contrib/95-esp-backup` that rsyncs `/boot` to `/boot2`. **An ESP
that is a year out of date may not boot the kernel that is on disk.**

## Phase 6 — prove it

```sh
efibootmgr            # expect two Limine entries
btrkeeper status      # RAID1 both profiles, zero error counters
```

Then reboot and **explicitly select the `nvme1n1` entry** from the firmware
boot menu. An untested second ESP is a hypothesis, not a backup.

---

## Aborting

| Stopped after | State | Way back |
| --- | --- | --- |
| Phase 0 | unchanged | nothing to undo |
| Phase 1 | single/dup, both devices | `btrkeeper convert` |
| Phase 2 | one device, disk detached | `btrkeeper add /dev/nvme1n1` then `btrkeeper convert` |
| Phase 3 | disk wiped and partitioned | continue to Phase 4; the disk was already out of the array |

The only destructive step is Phase 3, and by then the disk holds no data.

## Afterwards

Both disks boot independently, so with the degraded fallback entry in place
either drive can fail and the system still comes up unattended. When one does
fail: `btrkeeper replace <devid> <new-partition>`, then scrub, then copy the
ESP onto the new disk and add its firmware entry.
