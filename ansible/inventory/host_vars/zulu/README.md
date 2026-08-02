# zulu — /mnt/data drive

`/mnt/data` is a separate ext4 volume (see `/etc/fstab`,
`UUID=528f756f-34f7-42f0-aefa-14901d1ccae2`) mounted with `defaults,nofail`. Since it's
ext4 (not FAT/NTFS), access is controlled by standard Unix ownership/permissions, not
mount-time options like `umask`.

## Identify the drive

```bash
lsblk -f              # device tree with fs type, UUID/label, mountpoint
blkid                 # UUIDs for every block device (what fstab references)
sudo fdisk -l          # partition tables, sizes
findmnt /mnt/data      # confirm what's currently mounted there (if anything)
df -h /mnt/data        # usage, once mounted
```

`lsblk -f` is usually the fastest way to spot which `/dev/sdX`/`/dev/nvmeXnY` a given
mountpoint or UUID corresponds to.

## Manual mount / unmount

```bash
# mount using the fstab entry (device/options come from /etc/fstab)
sudo mount /mnt/data

# or mount explicitly by UUID without touching fstab
sudo mount UUID=528f756f-34f7-42f0-aefa-14901d1ccae2 /mnt/data

# unmount
sudo umount /mnt/data
```

If `umount` reports "target is busy," find what's holding it open before forcing anything:

```bash
sudo lsof +D /mnt/data     # processes with open files under the mountpoint
sudo fuser -vm /mnt/data   # alternative view, also usable with fuser -k to kill holders
```

## fstab: skip fsck check on boot

Current entry:

```text
UUID=528f756f-34f7-42f0-aefa-14901d1ccae2 /mnt/data ext4 defaults,nofail 0 2
```

The last two fields are `dump` and `fsck pass`. `2` means this filesystem gets checked by
`fsck` at boot (after the root filesystem) — if the drive is slow, has errors, or hits its
periodic mandatory-check interval, boot can stall waiting on that check. Set the fsck pass
to `0` to skip the boot-time check entirely:

```text
UUID=528f756f-34f7-42f0-aefa-14901d1ccae2 /mnt/data ext4 defaults,nofail 0 0
```

- `nofail` (already present) — don't fail/block boot if the device is missing entirely.
- `0` fsck pass — don't run `fsck` on it during boot at all.

Together these mean boot never waits on or blocks for this drive. Edit with
`sudo nano /etc/fstab` (or your editor of choice), then verify without rebooting:

```bash
sudo mount -a   # re-mounts everything in fstab, errors out here instead of at boot
```

You can still run `fsck` manually whenever you actually want to check the filesystem:

```bash
sudo umount /mnt/data
sudo fsck /mnt/data
```

## Setup

Create a dedicated group, add members to it, and hand the directory over — no world access.

```bash
# 1. create the group
sudo groupadd data

# 2. add yourself (repeat per user who needs access)
sudo usermod -aG data kitti

# 3. own the directory by the group, rwx for owner+group, setgid so new
#    files/dirs inherit the "data" group automatically, no access for others
sudo chown :data /mnt/data
sudo chmod 2770 /mnt/data
```

`2770` breakdown:

- `2` — setgid: files/dirs created under `/mnt/data` keep the `data` group even if
  the creating user's primary group differs.
- `770` — owner `rwx`, group `rwx`, other `---` (no world read/write/execute).

Group membership changes don't apply to an already-open shell — log out/in, or run
`newgrp data`, to pick it up.

## Optional: default ACLs

Setgid keeps group ownership consistent, but a member's `umask` can still narrow the
write bits on newly created files. To force `rwx` for the group regardless of umask:

```bash
sudo apt install acl   # if not already present
sudo setfacl -d -m g::rwx /mnt/data
```
