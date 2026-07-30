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
      packages = [ "dosfstools" "mtools" "fatresize" ];
      tools = "fsck.fat, mkfs.fat, fatresize (the only non-destructive FAT16/FAT32 resizer -- parted dropped filesystem resizing in 3.x, so without this shrinking an ESP means backup/mkfs/restore); plus mtools' mcopy/mdir/mtype to read a FAT volume without mounting it";
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

      # ── THE compression recipe for a slow-flash f2fs volume ────────────────────────────────
      # Field-validated across two independent consumers (a USB-stick Nix store, and a
      # passphrase-only recovery vault) before this moved here, byte-identical between them,
      # so it is ONE recipe, not a choice per consumer. A consumer whose write pattern
      # genuinely differs (a one-shot multi-GiB closure copy vs. a small incremental commit)
      # expresses that in HOW OFTEN it runs the release pass below (`f2fs_io release_cblocks`)
      # -- an operational detail that lives at the call site -- never in a second copy of
      # these flags. If a real divergence in the flags themselves ever shows up, it becomes a
      # parameter here; none exists today, so none is invented.
      #
      # Getting zstd:22 to actually take effect is three separate, make-or-break steps: an
      # mkfs feature bit, mount options that both trigger and tune the compression, and a
      # kernel new enough that the accounting behind it is correct. Skipping any one of them
      # either silently disables compression or corrupts the release accounting.
      compression = {
        # f2fs's release/reserve `i_blocks` accounting -- what actually lets a released
        # (compressed) file's reserved-but-unused blocks come back to the free pool -- is
        # only correct from this kernel on. Two earlier, related fixes are NOT enough by
        # themselves: `f2fs_release_compress_blocks()` was decoupled from the VFS immutable
        # bit back in 5.14 (so GC/unlink/link/rename/read/stat all keep working on a released
        # file -- see `fs/f2fs/file.c`), and a compressed-block SPOR (sudden-power-off-
        # recovery) fix landed around 6.7, but the release/reserve accounting fix this floor
        # names is the ~6.12 one. A consumer checks the kernel it is ACTUALLY about to run
        # these operations under against this floor -- at eval time, as a real assertion, if
        # it owns `boot.kernelPackages` on the backend it targets; at runtime (`uname -r`),
        # immediately before formatting or writing, if it does not (e.g. a module exported to
        # a backend with no kernel-package option surface at all).
        requiredKernel = "6.12";

        # Passed to `mkfs.f2fs -O <mkfsFeatures>`, ONCE, at format time -- never repeated by
        # anything that runs later:
        #   extra_attr     -- required scaffolding the other three features build on
        #   inode_checksum -- per-inode metadata checksum
        #   sb_checksum    -- superblock checksum, same integrity reasoning
        #   compression    -- without this mkfs feature bit, EVERY compress_* mount option
        #                     below is silently ignored -- the single most common way to
        #                     "enable compression" and get none
        mkfsFeatures = "extra_attr,inode_checksum,sb_checksum,compression";

        # Mount options -- the trigger, the tuning, and the flash-friendly / RAM-cache flags.
        # Order matters no more than it does in any other list here, but it is preserved
        # exactly as field-validated so a rendered mount string never has to be re-verified
        # byte-for-byte against what was already proven to work:
        #   compress_algorithm=zstd:22  -- the algorithm and level; ALONE compresses nothing
        #                                  (see compress_extension below, the actual trigger).
        #                                  The level is essentially free here: f2fs compresses
        #                                  per cluster, and zstd's window is capped by the
        #                                  cluster size, so at a small cluster zstd:22 costs
        #                                  nothing extra over a lower level at either write or
        #                                  read time.
        #   compress_log_size=2         -- cluster size (cluster = 4 KiB × (1 << this); 2 ⇒
        #                                  16 KiB). This is the read-amplification FLOOR, not
        #                                  an arbitrary pick: f2fs decompresses the whole
        #                                  cluster on any fault inside it, and a smaller
        #                                  cluster means less wasted read-ahead on a slow,
        #                                  randomly-faulted-into file. Fixed per-inode at file
        #                                  creation -- cannot be changed later for an existing
        #                                  file, so this must be right before anything is
        #                                  ever written under it.
        #   compress_extension=*        -- the actual trigger. Without this, compress_algorithm
        #                                  is inert and nothing at all gets compressed.
        #   compress_chksum             -- checksums compressed clusters, so silent corruption
        #                                  in one is detectable rather than read back as
        #                                  plausible-looking garbage.
        #   nocompress_extension=sqlite -- excludes a SQLite main-DB file from compression: a
        #                                  file that is mmap'd and randomly overwritten in
        #                                  place is a poor fit for it, and if a release pass
        #                                  ever touched such a file it would become
        #                                  write-blocked (`-EIO`/`-EPERM` on in-place writes to
        #                                  a released file) -- a correctness bug, not a
        #                                  performance one. NOTE: f2fs caps extension names at
        #                                  8 characters (`F2FS_EXTENSION_LEN`), so `sqlite-wal`
        #                                  / `sqlite-shm` (10 chars each) CANNOT be excluded
        #                                  the same way -- mounting with either present fails
        #                                  outright ("invalid extension length"). Only the
        #                                  main `.sqlite` file is excludable this way; its
        #                                  WAL/SHM sidecars get ordinary fs-mode compression
        #                                  like any other file. An accepted, documented gap,
        #                                  not an oversight -- and the exact reason the actual
        #                                  flag list below stops at plain `sqlite`.
        #   flush_merge                 -- coalesce concurrent cache-flush commands into fewer
        #                                  flushes to slow flash
        #   checkpoint_merge            -- a kernel daemon merges checkpoint requests, for
        #                                  smoother write bursts instead of one checkpoint per
        #                                  writer
        #   compress_cache              -- cache COMPRESSED blocks in RAM, for a better
        #                                  random-read hit ratio against the underlying flash
        #   fsync_mode=nobarrier        -- fewer write barriers for non-atomic files; safe only
        #                                  because everything written under this recipe is
        #                                  re-derivable or re-creatable from elsewhere, never a
        #                                  reason to reach for the BARE `nobarrier` MOUNT
        #                                  option instead, which assumes the device itself
        #                                  guarantees a cache flush -- untrue of the slow flash
        #                                  this recipe targets
        #   noatime, lazytime           -- skip / defer atime writes: one more class of needless
        #                                  writes to flash that this recipe gets nothing from
        #                                  paying for
        #   nodiscard                   -- no inline TRIM/discard chatter on a slow,
        #                                  poorly-TRIM-supporting USB controller; leaves
        #                                  already-freed blocks un-discarded rather than
        #                                  punched back to sparse holes immediately
        mountOptions = [
          "compress_algorithm=zstd:22"
          "compress_log_size=2"
          "compress_extension=*"
          "compress_chksum"
          "nocompress_extension=sqlite"
          "flush_merge"
          "checkpoint_merge"
          "compress_cache"
          "fsync_mode=nobarrier"
          "noatime"
          "lazytime"
          "nodiscard"
        ];
      };
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
