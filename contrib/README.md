# contrib

Things that live outside btrkeeper itself, because they are system
configuration rather than btrfs operations — but that a mirrored root
filesystem wants anyway.

## 95-esp-backup

A Limine post-install hook that mirrors the EFI System Partition onto the
btrfs array after every kernel update.

btrfs RAID1 protects the root filesystem. It does not protect the ESP, which
on a typical single-ESP layout lives on exactly one disk and holds the
bootloader, the kernel images and the initramfs. Losing that disk therefore
costs you the boot path even though the data survives. This keeps a current
copy on the mirror, so recovery is "format an ESP and copy a directory"
rather than "reconstruct a boot environment".

It writes a `RESTORE-INFO.txt` alongside the copy recording the ESP and root
UUIDs, the kernel cmdline, and the restore procedure — the values you need
precisely when the machine that knows them is the one that died.

### Install

```sh
# A dedicated subvolume keeps ~1 GB of kernel images out of every snapshot.
# Substitute your own filesystem UUID and subvolume naming.
sudo mount -o subvolid=5 UUID=<fs-uuid> /mnt
sudo btrfs subvolume create /mnt/@bootbak
sudo umount /mnt

sudo mkdir -p /var/lib/boot-backup
echo 'UUID=<fs-uuid> /var/lib/boot-backup btrfs subvol=/@bootbak,defaults,noatime,compress=zstd:1 0 0' \
    | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /var/lib/boot-backup

sudo install -m 0755 contrib/95-esp-backup /etc/boot/hooks/post.d/95-esp-backup
sudo /etc/boot/hooks/post.d/95-esp-backup      # take the first copy now
```

A plain directory works too if you would rather skip the subvolume; it just
means each kernel update pins another copy of the ESP in the pre-transaction
snapshot.

## 96-esp2-sync

Keeps a second ESP on the *other* disk in step with the live one.

The bootloader tooling only writes to the ESP it manages. A mirror ESP is
what lets the machine boot when the first disk is gone — but it is worth only
as much as it is current, and an ESP months behind may not boot the kernel
that is actually on disk. This syncs it on every kernel update.

It syncs with no exclusions, so `sudo diff -rq /boot /boot2` stays a valid
one-command check that the arrangement still works.

### Install

```sh
sudo install -m 0755 contrib/96-esp2-sync /etc/boot/hooks/post.d/96-esp2-sync
sudo /etc/boot/hooks/post.d/96-esp2-sync
```

Runs after `95-esp-backup` by filename order. Edit `DEST` at the top if your
mirror ESP is mounted somewhere other than `/boot2`.

### Notes

- Mounts the destination if it is absent — `/boot2` is normally mounted
  `nofail`, so it legitimately may not be — and unmounts it again afterwards
  only if it mounted it.
- Refuses to sync into a path that is not a mountpoint. Without that check a
  sync into an unmounted `/boot2` would quietly fill the root filesystem with
  a copy that can never be booted from.
- Warns if both ESPs turn out to be on the same physical disk, which would
  protect against nothing.

## systemd/

Two timers: a monthly scrub, and a weekly audit that every member disk can
still boot.

### Install

The units call `/usr/local/bin/btrkeeper`. Install it there rather than
pointing a root unit at `~/.local/bin` — a root service executing a binary
out of a user's home directory means anything able to write to that home
directory can run code as root.

```sh
sudo install -m 0755 btrkeeper /usr/local/bin/btrkeeper
sudo install -m 0644 contrib/systemd/*.service contrib/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now btrkeeper-scrub.timer btrkeeper-boot-audit.timer
```

Check them with:

```sh
systemctl list-timers 'btrkeeper*'
systemctl status btrkeeper-scrub.service
journalctl -u btrkeeper-boot-audit.service
```

### Choices worth knowing

- The scrub unit runs `scrub run`, not `scrub start`. `start` returns the
  instant the kernel accepts the request, so a unit using it would report
  success whatever the scrub went on to find. `run` blocks and exits
  non-zero on errors, which is what makes the unit's status meaningful.
- `TimeoutStartSec=infinity` on the scrub: it is expected to take hours, and
  systemd would otherwise kill it.
- `Nice=19` with idle IO and CPU scheduling, so a scrub does not fight the
  desktop for the disk.
- `Persistent=true` on both timers: a desktop is not always on, and a missed
  run fires after the next boot rather than being skipped.
- The audit runs weekly rather than monthly. What it catches is a mirror ESP
  that quietly stopped being updated, and the interval that matters there is
  "since the last kernel update", not "since the last scrub".
- The audit runs as root, so it compares ESP contents rather than only their
  sizes.
- Failures persist in `systemctl --failed` until acknowledged, so a scrub
  that found errors will not scroll past unnoticed.

## Both hooks

### Notes

- Requires the Limine hook framework (`limine-mkinitcpio-hook`), which runs
  everything executable in `/etc/boot/hooks/post.d` as root after updating
  the ESP. For other bootloaders, a pacman hook in `/etc/pacman.d/hooks/`
  triggering on kernel packages does the same job.
- Exits 1 rather than >=100 on failure, so the hook runner reports a warning
  and a failed backup never blocks a kernel install.
- Refuses to run if the destination turns out to be on the same filesystem as
  the ESP, which would protect nothing.
- Once both disks have their own ESP, syncing directly to the second ESP is
  the stronger arrangement; this copy remains useful as an offline record.
