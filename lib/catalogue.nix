#
# The catalogue, in the two halves a host actually reasons about.
#
# `filesystems` is a per-host fact: which on-disk formats does this machine deal with? Nothing can
# derive it -- the filesystems a host MOUNTS are already handled by NixOS, and the ones it MEETS
# are a property of what people plug into it, which no config can see. So it is declared.
#
# `tools` is not a per-host fact. ddrescue images a failing device, smartctl asks a drive how it is
# doing, parted edits a partition table, pv shows you whether a six-hour copy is moving. None of
# that is specific to a filesystem or to a machine's role -- it is the generic storage toolkit, and
# the honest default is that a machine which touches disks at all has it. Groups default ON;
# a host that genuinely cannot use them turns them off and says why.
#
# ONE COLUMN, NOT TWO. The sibling toolbox module (nixdev) names each tool twice -- once as a
# nixpkgs attribute and once as a distro package -- because dev tooling is fine, often better,
# coming from whatever the host distro ships: you want a current compiler, and a version that moved
# under you between projects is normal.
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
#     convenience, and there is a check that keeps it out.
#
#   * ReiserFS. Removed from nixpkgs after the kernel dropped support in 6.13; there is no package
#     left to name. Recorded here so its absence reads as a fact rather than an oversight.
#
# Each entry says what you actually get, because "install e2fsprogs" is not a useful answer to
# "how do I check this disk" at 3am.
#
{ ... }:
{
  # ── Per-filesystem check / repair / create / label / resize userland ────────────────────────
  # Declared per host. On NixOS the filesystems in `fileSystems.*` are already covered by NixOS
  # itself and nixfs does not duplicate that; declare here what the host MEETS, plus -- on a
  # non-NixOS host, where nothing does it for you -- what it mounts.
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

  # ── The generic toolkit: everything that is NOT specific to one on-disk format ─────────────
  # Each group is one boolean, on by default. A group is the right granularity here because these
  # travel together in practice -- nobody wants smartctl but not nvme-cli on a box that has both
  # kinds of drive, and the packages are small next to the cost of not having one.
  tools = {
    recovery = {
      packages = [ "ddrescue" "testdisk" ];
      summary = "get data off failing or damaged media";
      detail = ''
        ddrescue images a dying drive sector-by-sector with a resumable mapfile, so a second pass
        retries only what the first could not read. testdisk recovers partition tables and boot
        sectors; photorec (same package) carves files by signature when the filesystem itself is
        gone. Neither has anything to do with which filesystem is on the device.
      '';
    };

    inspection = {
      packages = [ "smartmontools" "hdparm" "sdparm" "nvme-cli" "lsscsi" "sg3_utils" "usbutils" "pciutils" ];
      summary = "ask the hardware what it thinks";
      detail = ''
        smartctl reads SMART attributes and the reallocated/pending sector counts that decide
        whether to image a drive before touching it. hdparm and sdparm read ATA and SCSI/USB
        parameters; nvme-cli covers NVMe; lsscsi and sg3_utils give device topology and direct
        SCSI/enclosure queries; lsusb and lspci say what is attached and at what link speed.
      '';
    };

    partitioning = {
      packages = [ "gptfdisk" "parted" ];
      summary = "read, edit and back up partition tables";
      detail = ''
        gdisk/sgdisk/cgdisk for GPT -- including sgdisk --backup, which is the one command worth
        running before every other command in this list. parted and partprobe for scripted
        partitioning and forcing the kernel to re-read a table.
      '';
    };

    volumes = {
      packages = [ "lvm2" "mdadm" "cryptsetup" ];
      summary = "open the block layers between a disk and its filesystem";
      detail = ''
        A foreign disk whose ext4 lives inside an LVM volume group inside a LUKS container is
        unreadable until all three are open, and only the last of those three is a filesystem
        question. vgchange -ay activates a foreign volume group, mdadm --assemble brings up a
        foreign MD array, cryptsetup luksDump/luksOpen handles the encryption -- and luksHeaderBackup
        is what you want before touching any of it.
      '';
    };

    throughput = {
      packages = [ "pv" "fio" ];
      summary = "see a long operation move, and measure what a drive really does";
      detail = ''
        pv gives progress, rate and ETA for a dd/ddrescue/tar/zfs-send pipe that would otherwise
        print nothing for six hours. fio measures what a drive actually delivers rather than what
        its label claims.
      '';
    };
  };
}
