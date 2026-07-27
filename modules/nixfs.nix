#
# nixfs -- the filesystem toolchain, declared per host.
#
# THE GAP THIS CLOSES. NixOS installs check/repair userland for the filesystems a host MOUNTS,
# derived from `fileSystems.*`. Nothing installs userland for the filesystems a host MEETS: a USB
# stick, a disk pulled out of a retired machine, an SD card someone hands you. And on a host whose
# own distro is not NixOS, nothing installs either kind -- those tools arrive by hand, at whatever
# version the distro shipped the day somebody remembered, or they never arrive at all.
#
# Both halves of that gap are the same failure: you find out which tools are missing at the moment
# you need them. nixfs makes the answer a declared fact instead, resolved from nixpkgs on every
# host regardless of distro, so the toolchain is pinned and identical everywhere.
#
# PLATFORM-NEUTRAL BY DESIGN. This file declares WHAT is wanted and resolves it to nixpkgs
# attribute names. It installs nothing -- see modules/install.nix, which is imported by both
# backends because, unlike a distro-package module, there is nothing platform-specific left to do.
#
# EVAL SAFETY. `nixfs.media` has no default and may legitimately be null while this module is
# still being evaluated -- a NixOS toplevel build forces most of `config` in one pass, in no
# guaranteed relation to when `assertions` are checked. So no lookup below ever indexes the tier
# table with `cfg.media` directly; `activeTier` falls back to the lowest tier when it is null. That
# fallback is never seen by a real configuration: `config` is gated on `cfg.enable`, and the
# assertion fires whenever enable is true and media is null. It exists only so that forcing an
# unrelated attribute cannot crash before the readable error gets to speak.
#
{ config, lib, ... }:

let
  cfg = config.nixfs;
  catalogue = import ../lib/catalogue.nix { };
  mediaData = import ../media.nix;
  inherit (mediaData) tierOrder adds;

  # The groups, in the order they are reported. Derived from the catalogue rather than written
  # out, so adding a group to lib/catalogue.nix cannot leave this list behind.
  groups = lib.attrNames catalogue;

  activeTierName = if cfg.media != null then cfg.media else lib.head tierOrder;

  # Every tier up to and including the active one. This is where "monotone" stops being a claim
  # in media.nix and becomes arithmetic: a tier can only contribute additions, so a higher tier
  # is necessarily a superset.
  tiersUpTo = name:
    let idx = lib.lists.findFirstIndex (t: t == name) 0 tierOrder;
    in lib.take (idx + 1) tierOrder;

  fromTier = group:
    lib.concatMap (t: adds.${t}.${group} or [ ]) (tiersUpTo activeTierName);

  # "group.key" as written in `nixfs.omit`.
  omitKey = group: key: "${group}.${key}";

  selectedIn = group:
    lib.filter (k: !(lib.elem (omitKey group k) cfg.omit))
      (lib.unique (fromTier group ++ cfg.${group}));

  selected = lib.genAttrs groups selectedIn;

  # What the tier would have given that `omit` took away -- surfaced, never silent.
  omittedFromTier =
    lib.filter (o: lib.elem o (lib.concatMap (g: map (omitKey g) (lib.unique (fromTier g ++ cfg.${g}))) groups))
      cfg.omit;

  allCatalogueKeys =
    lib.concatMap (g: map (omitKey g) (lib.attrNames catalogue.${g})) groups;

  unknownOmissions = lib.filter (o: !(lib.elem o allCatalogueKeys)) cfg.omit;

  mkGroupOption = group: lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames catalogue.${group}));
    default = [ ];
    description = ''
      Additional ${group} entries for this host, on top of whatever `nixfs.media` already
      provides. Additive only; use `nixfs.omit` to take something away.

      Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.${group})}.
    '';
  };
in
{
  options.nixfs = {
    enable = lib.mkEnableOption "the filesystem, block-layer and recovery toolchain, pinned from nixpkgs on every host regardless of distro";

    media = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum tierOrder);
      default = null;
      example = "removable";
      description = ''
        What kinds of storage this host is expected to encounter. One of:
        ${lib.concatStringsSep ", " tierOrder}.

        - `none`       : no block devices of its own (a container, or a guest handed one virtual
                         disk it never inspects). Contributes no tools at all; declare
                         `nixfs.filesystems` for whatever it does mount.
        - `fixed`      : owns its disks, never sees foreign media. Drive health, partitioning,
                         and reopening its own encryption.
        - `removable`  : people plug things into it. Adds the formats consumer devices ship with,
                         the block layers a foreign Linux disk hides its filesystem under, and
                         data recovery.
        - `arbitrary`  : media of unknown, possibly ancient format arrives to be ingested.
                         Everything, including the formats nothing creates anymore -- which is
                         precisely why they turn up on old disks.

        Each tier is a strict superset of the one before it, by construction rather than by
        promise -- see media.nix.

        There is NO default. A guess here is silently wrong in the direction that matters: too low
        a tier installs nothing and looks fine right up until the moment the tools are needed. So
        an unset `media` with `enable = true` is a hard evaluation error, not a fallback.
      '';
    };

    filesystems = mkGroupOption "filesystems" // {
      description = ''
        Filesystem userland this host needs beyond its tier -- normally the filesystems it
        actually MOUNTS, which the tier deliberately says nothing about.

        On NixOS this is usually unnecessary: userland for anything in `fileSystems.*` is already
        installed for you, and nixfs does not duplicate that. On a host whose own distro is not
        NixOS nothing does it, so declare them here.

        ZFS is deliberately absent from the list and always will be. Its userland must match the
        loaded kernel module exactly, so it can only come from whatever provides that module
        (`boot.zfs` on NixOS, the distro's own packaging elsewhere). A second, independently
        versioned copy installed from here would be a hazard, not a convenience.

        Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.filesystems)}.
      '';
    };

    volumes = mkGroupOption "volumes";
    recovery = mkGroupOption "recovery";
    inspection = mkGroupOption "inspection";
    partitioning = mkGroupOption "partitioning";
    throughput = mkGroupOption "throughput";

    omit = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "filesystems.hfs" ];
      description = ''
        Escape hatch: drop specific catalogue entries this host would otherwise get, written as
        `"<group>.<key>"`.

        Prefer changing `nixfs.media`, or changing what a tier contains. This exists for one
        honest case -- a package that is broken or marked insecure in the pinned nixpkgs, where
        the alternative is that the host cannot build at all -- and it is reported in `warnings`
        every time, because a host quietly missing part of its recovery toolchain is the exact
        situation nixfs exists to prevent. An entry naming something not in the catalogue is an
        error, so a typo cannot silently omit nothing.
      '';
    };

    # ── Computed, read-only ────────────────────────────────────────────────────────────────
    selected = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      readOnly = true;
      description = "Per group, the catalogue keys resolved for this host (tier + explicit, minus omissions).";
    };

    packageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The resolved selection as nixpkgs attribute names. The contract modules/install.nix
        consumes, and what to read if you want to see what a host will actually get without
        instantiating anything.
      '';
    };
  };

  config = {
    nixfs.selected = selected;
    nixfs.packageNames =
      lib.unique (lib.concatMap
        (g: lib.concatMap (k: catalogue.${g}.${k}.packages) selected.${g})
        groups);

    assertions = [
      {
        assertion = !cfg.enable || cfg.media != null;
        message = ''
          nixfs.media must be set explicitly when nixfs.enable = true. It cannot be inferred:
          what storage a machine encounters is a fact about how it is used, not about its
          hardware or its config. Pick the lowest tier that is still true of this host --
          ${lib.concatStringsSep " < " tierOrder} -- and see media.nix for what each contributes.
        '';
      }
      {
        assertion = unknownOmissions == [ ];
        message = ''
          nixfs.omit names ${toString (builtins.length unknownOmissions)} entr(y/ies) that are not
          in the catalogue: ${lib.concatStringsSep ", " unknownOmissions}. An omission that
          matches nothing removes nothing while looking like it did. Write them as
          "<group>.<key>", e.g. "filesystems.hfs".
        '';
      }
    ];

    warnings = lib.optional (omittedFromTier != [ ]) ''
      nixfs: this host omits ${toString (builtins.length omittedFromTier)} entr(y/ies) its
      media tier "${activeTierName}" would otherwise provide: ${lib.concatStringsSep ", " omittedFromTier}.
      Its toolchain is therefore NOT identical to other hosts at the same tier. This warning is
      deliberate and will not go away on its own -- remove the omission once whatever forced it
      (a broken or insecure package in the pinned nixpkgs) is resolved upstream.
    '';
  };
}
