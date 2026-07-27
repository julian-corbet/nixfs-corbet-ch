#
# The catalogue: every tool nixfs can install, in the group it belongs to.
#
# ONE COLUMN, NOT TWO. The sibling toolbox module (nixdev) names each tool twice -- once as a
# nixpkgs attribute and once as a distro package -- because dev tooling is fine, often better,
# coming from whatever the host distro ships: you want a current compiler, and a version that
# moved under you between projects is normal.
#
# Recovery tooling is the opposite case. You reach for it when something is already broken, under
# time pressure, usually on media you cannot re-read. That is the worst possible moment to discover
# that this machine's `ddrescue` is two years older than the one you learned the flags on, or that
# `testdisk` is simply absent because nobody thought to install it here. So nixfs resolves to
# nixpkgs on EVERY host, including hosts whose own distro is not NixOS, and accepts the duplicate
# copy as the price of the toolchain being identical and pinned everywhere.
#
# WHAT IS DELIBERATELY NOT HERE:
#
#   * ZFS. Its userland must match the loaded kernel module exactly, so it can only come from
#     whatever provides that module -- `boot.zfs` on NixOS, the distro's own module elsewhere.
#     Installing a second, independently-versioned copy from here is a real hazard, not a
#     convenience, and modules/nixfs.nix asserts against asking for it.
#
#   * Filesystem userland a host gets automatically for the filesystems it MOUNTS. On NixOS that
#     already happens from `fileSystems.*`; nixfs does not duplicate it. On a non-NixOS host
#     nothing does it, which is why `filesystems` is still declarable there -- see
#     modules/nixfs.nix.
#
#   * ReiserFS. Removed from nixpkgs after the kernel dropped support in 6.13; there is no
#     package left to name. Recorded here so its absence reads as a fact rather than an oversight.
#
# Each entry names its packages and says what you actually get, because "install e2fsprogs" is not
# a useful answer to "how do I check this disk" at 3am.
#
{ ... }:
{
  # ── Per-filesystem check / repair / create / label / resize userland ────────────────────────
  filesystems = {
    ext = {
      packages = [ "e2fsprogs" ];
      tools = "e2fsck (fsck.ext2/3/4), mke2fs, dumpe2fs, tune2fs, resize2fs, debugfs";
    };
    vfat = {
      packages = [ "dosfstools" "mtools" ];
      tools = "fsck.fat, mkfs.fat; plus mtools' mcopy/mdir/mtype to read a FAT volume without mounting it";
    };
    exfat = {
      packages = [ "exfatprogs" ];
      tools = "fsck.exfat, mkfs.exfat, exfatlabel, tune.exfat";
    };
    ntfs = {
      packages = [ "ntfs3g" ];
      tools = "ntfsfix, ntfsck, ntfsinfo, mkntfs, ntfsclone, ntfsresize, ntfsundelete, ntfslabel";
    };
    xfs = {
      packages = [ "xfsprogs" ];
      tools = "xfs_repair, xfs_db, xfs_scrub, xfs_admin, mkfs.xfs";
    };
    btrfs = {
      packages = [ "btrfs-progs" ];
      tools = "btrfs check/scrub/balance/restore, btrfstune, mkfs.btrfs";
    };
    f2fs = {
      packages = [ "f2fs-tools" ];
      tools = "fsck.f2fs, mkfs.f2fs, dump.f2fs";
    };
    hfs = {
      packages = [ "hfsprogs" ];
      tools = "fsck.hfsplus, mkfs.hfsplus -- HFS+/HFS, i.e. externally formatted Mac disks";
    };
    udf = {
      packages = [ "udftools" ];
      tools = "mkudffs, udfinfo, udflabel -- optical and UDF-formatted media";
    };
    jfs = {
      packages = [ "jfsutils" ];
      tools = "fsck.jfs, mkfs.jfs -- legacy media only; nothing creates JFS today";
    };
    nilfs = {
      packages = [ "nilfs-utils" ];
      tools = "mkfs.nilfs2, fsck.nilfs2, lscp/mkcp checkpoint tools -- legacy media only";
    };
  };

  # ── Block layers that sit BETWEEN a disk and a filesystem ──────────────────────────────────
  # Separate from `filesystems` because you need these to even FIND the filesystem: a foreign disk
  # whose ext4 lives inside an LVM volume group inside a LUKS container is unreadable until all
  # three are open, and only the last of those three is a filesystem question.
  volumes = {
    lvm = {
      packages = [ "lvm2" ];
      tools = "pvs/vgs/lvs, vgchange -ay to activate a foreign volume group, vgcfgrestore";
    };
    mdraid = {
      packages = [ "mdadm" ];
      tools = "mdadm --examine/--assemble -- inspect and bring up a foreign Linux MD array";
    };
    luks = {
      packages = [ "cryptsetup" ];
      tools = "cryptsetup luksDump/luksOpen, and the header backup you want BEFORE touching anything";
    };
  };

  # ── Data recovery from failing or damaged media ────────────────────────────────────────────
  recovery = {
    ddrescue = {
      packages = [ "ddrescue" ];
      tools = "ddrescue -- image a dying drive sector-by-sector with a resumable mapfile, so a "
        + "second pass retries only what the first could not read";
    };
    testdisk = {
      packages = [ "testdisk" ];
      tools = "testdisk (partition table and boot sector recovery) and photorec (signature-based "
        + "file carving, for when the filesystem itself is gone)";
    };
  };

  # ── Asking the hardware what it thinks ─────────────────────────────────────────────────────
  inspection = {
    smart = {
      packages = [ "smartmontools" ];
      tools = "smartctl -- SMART attributes, self-tests, and the reallocated/pending sector counts "
        + "that decide whether to image a drive before touching it";
    };
    ata = {
      packages = [ "hdparm" ];
      tools = "hdparm -- ATA parameters, write cache, APM/AAM, and a timed-read benchmark";
    };
    scsi = {
      packages = [ "sdparm" "lsscsi" "sg3_utils" ];
      tools = "sdparm (SCSI/USB parameters through SAT passthrough), lsscsi (device topology), "
        + "sg_inq/sg_ses/sg_scan/sg_readcap (direct SCSI and enclosure queries)";
    };
    nvme = {
      packages = [ "nvme-cli" ];
      tools = "nvme id-ctrl / smart-log / namespace management";
    };
    bus = {
      packages = [ "usbutils" "pciutils" ];
      tools = "lsusb and lspci -- what the machine is actually attached to, and at what link speed";
    };
  };

  # ── Partition tables ───────────────────────────────────────────────────────────────────────
  partitioning = {
    gpt = {
      packages = [ "gptfdisk" ];
      tools = "gdisk/sgdisk/cgdisk -- GPT editing, and sgdisk --backup, which is the one command "
        + "worth running before every other command in this list";
    };
    parted = {
      packages = [ "parted" ];
      tools = "parted and partprobe -- scripted partitioning and forcing the kernel to re-read a table";
    };
  };

  # ── Watching a long operation, and proving a disk's real speed ─────────────────────────────
  throughput = {
    pv = {
      packages = [ "pv" ];
      tools = "pv -- progress, rate and ETA for a dd/ddrescue/tar/zfs-send pipe that would "
        + "otherwise print nothing for six hours";
    };
    fio = {
      packages = [ "fio" ];
      tools = "fio -- measure what a drive actually delivers, rather than what its label claims";
    };
  };
}
