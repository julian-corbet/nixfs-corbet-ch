#
# The media tiers: what a host is expected to MEET, and therefore what it must be able to read.
#
# THE AXIS. Every other way of slicing this turned out to be a proxy for one question: what kinds
# of storage does this machine encounter? Not "is it a server" -- a server that ingests old drives
# and a server that only ever sees its own NVMe want completely different toolchains, and calling
# both "server" hides that. So the tier is named after the exposure itself.
#
# MONOTONE BY CONSTRUCTION. Each tier declares only what it ADDS to the one before it, and the
# cumulative set is computed (modules/nixfs.nix). A higher tier is therefore a strict superset of
# every lower one -- not as a promise in a comment that can rot, but because there is no way to
# express "remove" here. Moving a host up a tier can only ever add tools.
#
# WHAT IS NOT A TIER: the filesystems the host actually mounts. Those are `nixfs.filesystems`,
# declared per host, and they are additive on top of whatever tier is chosen. A container that
# mounts btrfs and meets nothing is `media = "none"` plus `filesystems = [ "btrfs" ]` -- the tier
# says nothing about it, because the tier is about the unknown, and a host's own mounts are known.
#
{
  # Lowest to highest. modules/nixfs.nix accumulates in this order.
  tierOrder = [ "none" "fixed" "removable" "arbitrary" ];

  adds = {
    # ── none ────────────────────────────────────────────────────────────────────────────────
    # No block devices of its own. A container, or a VM guest handed a single virtual disk it
    # never inspects. It can still need filesystem userland -- see `nixfs.filesystems` -- but
    # every tool below would be inspecting hardware it does not have.
    none = {
      filesystems = [ ];
      volumes = [ ];
      recovery = [ ];
      inspection = [ ];
      partitioning = [ ];
      throughput = [ ];
    };

    # ── fixed ───────────────────────────────────────────────────────────────────────────────
    # Owns its disks; nothing foreign is ever plugged into it. It needs to know its drives'
    # health before they fail, and to be able to repartition and reopen its own encryption --
    # nothing more. This is the correct tier for an edge VPS, where closure size is a real cost.
    fixed = {
      filesystems = [ ];
      volumes = [ "luks" ];
      recovery = [ ];
      inspection = [ "smart" "ata" "nvme" "bus" ];
      partitioning = [ "gpt" "parted" ];
      throughput = [ ];
    };

    # ── removable ───────────────────────────────────────────────────────────────────────────
    # A person plugs things into it. That means the three formats consumer devices are actually
    # shipped with -- and it means the day will come when one of them is dying and the data on it
    # exists nowhere else, so recovery belongs here rather than one tier up.
    removable = {
      filesystems = [ "vfat" "exfat" "ntfs" ];
      volumes = [ "lvm" "mdraid" ];
      recovery = [ "ddrescue" "testdisk" ];
      inspection = [ ];
      partitioning = [ ];
      throughput = [ ];
    };

    # ── arbitrary ───────────────────────────────────────────────────────────────────────────
    # Media of unknown and possibly ancient format arrives here to be read into storage: disks
    # pulled from retired machines, drives formatted by an operating system nobody runs anymore.
    # The defining property is that you do not get to choose what shows up, so the only safe
    # answer is everything -- including the formats nothing creates today, which is exactly why
    # they turn up on old media.
    arbitrary = {
      filesystems = [ "ext" "xfs" "btrfs" "f2fs" "hfs" "udf" "jfs" "nilfs" ];
      volumes = [ ];
      recovery = [ ];
      inspection = [ "scsi" ];
      partitioning = [ ];
      throughput = [ "pv" "fio" ];
    };
  };
}
