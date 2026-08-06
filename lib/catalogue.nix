#
# The catalogue, in the two halves a host actually reasons about.
#
# `filesystems` is a per-host fact: which on-disk formats does this machine deal with? Nothing can
# derive it -- what a host MOUNTS is already handled by NixOS, and what it MEETS is a property of
# what people plug into it, which no config can see.
#
# `tools` is not a per-host fact -- ddrescue, smartctl, parted, pv, and fsarchiver are generic
# storage toolkit, not tied to any filesystem or machine role, so groups default ON; a host that
# genuinely cannot use one turns it off and says why.
#
# TWO COLUMNS, NOT ONE. Every entry below names itself twice, `arch` and `nixpkgs`, the same shape
# as the sibling nixdev/nixoffice catalogues -- which this one used to argue against. The header
# here used to read "nixfs resolves to nixpkgs on EVERY host, including non-NixOS ones, and accepts
# the duplicate copy as the price of a toolchain that's identical and pinned everywhere". That
# bargain does not hold, and it failed for a reason that has nothing to do with staleness.
#
# On a live Arch host, `/usr/sbin` precedes the system-manager Nix profile on `PATH`. A package
# installed from here into that profile does not shadow the distro's copy -- it is the one that gets
# shadowed. Confirmed live: `mkfs.xfs`, `smartctl`, `pv`, `lsscsi`, `mkfs.f2fs`, `mcopy`, `mdadm` and
# `hdparm` all resolved to `/usr/sbin` while the pinned nixpkgs copies sat unused in
# `/run/system-manager/sw/bin`, never once reached by an interactive shell or a script that just
# calls the bare command name. The price actually paid was not the duplicate disk space -- it was
# the pin becoming decorative, a copy nobody's `PATH` will ever prefer.
#
# So nixfs now resolves PER PLATFORM, like every other catalogue in this family: a NixOS host has no
# second package manager to lose a `PATH` race against, so nixpkgs remains correct and sufficient
# there, for every entry. An Arch host gets its packages from pacman/AUR instead -- the host's own
# reconciler, already first on `PATH`, already the thing that keeps them current -- and nixpkgs is
# reached for ONLY where Arch has nothing to offer at all (`arch = null`), which is the one case
# where a `PATH` race cannot even arise because there is no second copy to race against.
#
# AUR IS A VALID ARCH SOURCE, NOT A FALLBACK TO NIXPKGS. `aur = true` (the same field nixdev's
# `kind` entry already uses) means the package is real on Arch, just not in an official repo --
# `pacman -S` cannot resolve an AUR name and fails the whole transaction on "target not found", so
# an AUR entry is held back into a separate list (`aurPackages`) for whatever AUR helper the host
# runs, never mixed into the plain pacman one. It is still installed BY Arch, from Arch's own
# ecosystem, not from a Nix profile that a distro copy would shadow.
#
# For THIS catalogue specifically, that leaves no residue: every entry below has a live Arch
# source, 28 from an official repo and one (`hfsprogs`, HFS+ support) from the AUR -- confirmed
# live, `paru -Si hfsprogs` reports `Repository: aur`. So on an Arch host nothing at all is
# installed from nixpkgs today: `archPackages` and `aurPackages` between them cover the entire
# selection. `arch = null` stays a real capability in the entry shape and in the resolution logic
# -- a future filesystem tool may genuinely exist nowhere on Arch, official repo or AUR -- but no
# entry uses it right now, so it is exercised by a fixture in ../checks/, not by a live entry.
#
# DELIBERATELY NOT HERE:
#   * ZFS -- its userland must match the loaded kernel module exactly, so it can only come from
#     whatever provides that module (`boot.zfs` on NixOS, the distro's own elsewhere). A second,
#     independently-versioned copy from here would be a hazard, not a convenience; a check enforces
#     its absence.
#   * ReiserFS -- removed from nixpkgs after the kernel dropped support in 6.13; no package left to
#     name. Recorded here so the absence reads as a fact, not an oversight.
#
{ ... }:
{
  # ── Per-filesystem check / repair / create / label / resize userland ────────────────────────
  # Declared per host. On NixOS the filesystems in `fileSystems.*` are already covered by NixOS
  # itself and nixfs does not duplicate that; declare here what the host MEETS, plus -- on a
  # non-NixOS host, where nothing does it for you -- what it mounts.
  #
  # `packages` is an attrset keyed by nixpkgs attribute name (this catalogue's identity for every
  # entry, since every entry names one), each value naming the SAME thing again for Arch --
  # `arch = null` where Arch has nothing to offer at all.
  filesystems = {
    ext = {
      packages.e2fsprogs = { arch = "e2fsprogs"; nixpkgs = "e2fsprogs"; };
      tools = "e2fsck (fsck.ext2/3/4), mke2fs, dumpe2fs, tune2fs, resize2fs, debugfs";
    };
    vfat = {
      packages = {
        dosfstools = { arch = "dosfstools"; nixpkgs = "dosfstools"; };
        mtools = { arch = "mtools"; nixpkgs = "mtools"; };
        fatresize = { arch = "fatresize"; nixpkgs = "fatresize"; };
      };
      tools = "fsck.fat, mkfs.fat, fatresize (the only non-destructive FAT16/FAT32 resizer -- parted dropped filesystem resizing in 3.x, so without this shrinking an ESP means backup/mkfs/restore); plus mtools' mcopy/mdir/mtype to read a FAT volume without mounting it";
    };
    exfat = {
      packages.exfatprogs = { arch = "exfatprogs"; nixpkgs = "exfatprogs"; };
      tools = "fsck.exfat, mkfs.exfat, exfatlabel, tune.exfat";
    };
    ntfs = {
      # The one name that differs between channels: nixpkgs calls it `ntfs3g`, Arch calls the same
      # package `ntfs-3g`. Kept under the nixpkgs name because that is this catalogue's identity for
      # every entry; the divergence lives entirely in the `arch` field.
      packages.ntfs3g = { arch = "ntfs-3g"; nixpkgs = "ntfs3g"; };
      tools = "ntfsfix, ntfsck, ntfsinfo, mkntfs, ntfsclone, ntfsresize, ntfsundelete, ntfslabel";
    };
    xfs = {
      packages.xfsprogs = { arch = "xfsprogs"; nixpkgs = "xfsprogs"; };
      tools = "xfs_repair, xfs_db, xfs_scrub, xfs_admin, mkfs.xfs";
    };
    btrfs = {
      packages."btrfs-progs" = { arch = "btrfs-progs"; nixpkgs = "btrfs-progs"; };
      tools = "btrfs check/scrub/balance/restore, btrfstune, mkfs.btrfs";
    };
    f2fs = {
      packages."f2fs-tools" = { arch = "f2fs-tools"; nixpkgs = "f2fs-tools"; };
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
      # AUR, not an official repo -- `paru -Si hfsprogs` reports `Repository: aur`. Still a real
      # Arch source: `aur = true` holds it back into aurPackages rather than archPackages, because
      # `pacman -S` cannot resolve an AUR name and fails the whole transaction on "target not
      # found" -- the same reason nixdev's `kind` entry does the same. Nothing is installed from
      # nixpkgs for this entry on an Arch host.
      packages.hfsprogs = { arch = "hfsprogs"; nixpkgs = "hfsprogs"; aur = true; };
      tools = "fsck.hfsplus, mkfs.hfsplus -- HFS+/HFS, i.e. externally formatted Mac disks";
    };
    udf = {
      packages.udftools = { arch = "udftools"; nixpkgs = "udftools"; };
      tools = "mkudffs, udfinfo, udflabel -- optical and UDF-formatted media";
    };
    jfs = {
      packages.jfsutils = { arch = "jfsutils"; nixpkgs = "jfsutils"; };
      tools = "fsck.jfs, mkfs.jfs -- legacy media only; nothing creates JFS today";
    };
    nilfs = {
      packages."nilfs-utils" = { arch = "nilfs-utils"; nixpkgs = "nilfs-utils"; };
      tools = "mkfs.nilfs2, fsck.nilfs2, lscp/mkcp checkpoint tools -- legacy media only";
    };
  };

  # ── The generic toolkit: everything that is NOT specific to one on-disk format ─────────────
  # Each group is one boolean, on by default. A group is the right granularity here because these
  # travel together in practice -- nobody wants smartctl but not nvme-cli on a box that has both
  # kinds of drive, and the packages are small next to the cost of not having one.
  tools = {
    recovery = {
      packages = {
        ddrescue = { arch = "ddrescue"; nixpkgs = "ddrescue"; };
        testdisk = { arch = "testdisk"; nixpkgs = "testdisk"; };
      };
      summary = "get data off failing or damaged media";
      detail = ''
        ddrescue images a dying drive sector-by-sector with a resumable mapfile, so a second pass
        retries only what the first could not read. testdisk recovers partition tables and boot
        sectors; photorec (same package) carves files by signature when the filesystem itself is
        gone. Neither has anything to do with which filesystem is on the device.
      '';
    };

    archiving = {
      packages.fsarchiver = { arch = "fsarchiver"; nixpkgs = "fsarchiver"; };
      summary = "create and restore portable filesystem archives";
      detail = ''
        fsarchiver saves a mounted filesystem as a portable archive and restores it onto another
        filesystem without requiring a block-for-block clone. It complements, rather than replaces,
        native snapshot replication: btrfs and ZFS snapshots remain the right backup transport for
        filesystems those hosts own.
      '';
    };

    inspection = {
      packages = {
        smartmontools = { arch = "smartmontools"; nixpkgs = "smartmontools"; };
        hdparm = { arch = "hdparm"; nixpkgs = "hdparm"; };
        sdparm = { arch = "sdparm"; nixpkgs = "sdparm"; };
        "nvme-cli" = { arch = "nvme-cli"; nixpkgs = "nvme-cli"; };
        lsscsi = { arch = "lsscsi"; nixpkgs = "lsscsi"; };
        sg3_utils = { arch = "sg3_utils"; nixpkgs = "sg3_utils"; };
        pciutils = { arch = "pciutils"; nixpkgs = "pciutils"; };
      };
      summary = "ask the hardware what it thinks";
      detail = ''
        smartctl reads SMART attributes and the reallocated/pending sector counts that decide
        whether to image a drive before touching it. hdparm and sdparm read ATA and SCSI/USB
        parameters; nvme-cli covers NVMe; lsscsi and sg3_utils give device topology and direct
        SCSI/enclosure queries; lspci says what is attached to the PCI bus and at what link speed.

        usbutils (lsusb) moved out to the sibling nixusb repo 2026-08-04: USB device tooling is
        that repo's domain, and it is composed on hosts (the Arch container among them) that
        deliberately do not compose nixfs at all -- see this catalogue's own header and nixfs's
        `filesystems` option doc for why a host with no block devices of its own is right to skip
        this whole module. pciutils stays here: PCI enumeration is genuinely storage-bus-adjacent
        on the hosts that already carry the rest of this group, and nobody has asked for it to move.
      '';
    };

    partitioning = {
      packages = {
        gptfdisk = { arch = "gptfdisk"; nixpkgs = "gptfdisk"; };
        parted = { arch = "parted"; nixpkgs = "parted"; };
      };
      summary = "read, edit and back up partition tables";
      detail = ''
        gdisk/sgdisk/cgdisk for GPT -- including sgdisk --backup, which is the one command worth
        running before every other command in this list. parted and partprobe for scripted
        partitioning and forcing the kernel to re-read a table.
      '';
    };

    volumes = {
      packages = {
        lvm2 = { arch = "lvm2"; nixpkgs = "lvm2"; };
        mdadm = { arch = "mdadm"; nixpkgs = "mdadm"; };
        cryptsetup = { arch = "cryptsetup"; nixpkgs = "cryptsetup"; };
      };
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
      packages = {
        pv = { arch = "pv"; nixpkgs = "pv"; };
        fio = { arch = "fio"; nixpkgs = "fio"; };
      };
      summary = "see a long operation move, and measure what a drive really does";
      detail = ''
        pv gives progress, rate and ETA for a dd/ddrescue/tar/zfs-send pipe that would otherwise
        print nothing for six hours. fio measures what a drive actually delivers rather than what
        its label claims.
      '';
    };
  };
}
