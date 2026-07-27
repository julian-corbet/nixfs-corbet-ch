#
# nixfs -- the storage toolchain, declared per host.
#
# THE GAP THIS CLOSES. NixOS installs check/repair userland for the filesystems a host MOUNTS,
# derived from `fileSystems.*`. Nothing installs userland for the filesystems a host MEETS: a USB
# stick, a disk pulled from a retired machine, an SD card someone hands you. And on a host whose
# own distro is not NixOS, nothing installs either kind -- those tools arrive by hand, at whatever
# version the distro shipped the day somebody remembered, or they never arrive at all.
#
# Both halves of that gap are the same failure: you find out which tools are missing at the moment
# you need them. nixfs makes the answer a declared fact instead, resolved from nixpkgs on every
# host regardless of distro, so the toolchain is pinned and identical everywhere.
#
# TWO HALVES, BECAUSE THEY ARE TWO DIFFERENT QUESTIONS.
#
#   `filesystems` is a per-host fact and has to be declared. Which on-disk formats this machine
#   deals with cannot be derived: what it mounts is already NixOS's job, and what it MEETS is a
#   property of what people plug into it, which no configuration can see.
#
#   `tools.*` is not a per-host fact. Imaging a failing device, asking a drive for its SMART
#   counters, editing a partition table, watching a long copy move -- none of that is specific to
#   an on-disk format or to a machine's role. It is the generic storage toolkit, so every group
#   defaults ON and a host that genuinely cannot use one turns it off with a reason.
#
# An earlier version of this module collapsed both into a single four-value "media exposure" tier.
# That was wrong: it made "which filesystems" and "which tools" move together when they are
# independent, and it forced a host to describe itself with one word chosen from a taxonomy
# invented here, rather than state the two things it actually knows.
#
# PLATFORM-NEUTRAL BY DESIGN. This file declares WHAT is wanted and resolves it to nixpkgs
# attribute names. It installs nothing -- see modules/install.nix, which is imported by both
# backends because, unlike a distro-package module, there is nothing platform-specific left to do.
#
{ config, lib, ... }:

let
  cfg = config.nixfs;
  catalogue = import ../lib/catalogue.nix { };

  fsNames = lib.attrNames catalogue.filesystems;
  toolGroups = lib.attrNames catalogue.tools;

  selectedFsPackages =
    lib.concatMap (k: catalogue.filesystems.${k}.packages) cfg.filesystems;

  enabledGroups = lib.filter (g: cfg.tools.${g}.enable) toolGroups;

  selectedToolPackages =
    lib.concatMap (g: catalogue.tools.${g}.packages) enabledGroups;

  wanted = lib.unique (selectedFsPackages ++ selectedToolPackages);

  resolved = lib.filter (p: !(lib.elem p cfg.omit)) wanted;

  unknownOmissions = lib.filter (o: !(lib.elem o wanted)) cfg.omit;

  mkToolOption = group: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        ${catalogue.tools.${group}.summary}.

        ${catalogue.tools.${group}.detail}
        Packages: ${lib.concatStringsSep ", " catalogue.tools.${group}.packages}.

        On by default. This is the generic storage toolkit -- it is not specific to any on-disk
        format or to what this machine is for -- so the question a host answers here is not "do I
        want this" but "can I actually use it". Turn it off where the answer is genuinely no (a
        container with no block devices of its own, a guest whose virtual disk has no SMART data
        to report, a machine small enough that the closure matters), and say why in the host's
        config so the next reader does not have to guess.
      '';
    };
  };
in
{
  options.nixfs = {
    enable = lib.mkEnableOption "the storage toolchain -- per-filesystem userland plus the generic recovery/inspection/partitioning toolkit, pinned from nixpkgs on every host regardless of distro";

    filesystems = lib.mkOption {
      type = lib.types.listOf (lib.types.enum fsNames);
      default = [ ];
      example = [ "btrfs" "vfat" "exfat" "ntfs" ];
      description = ''
        Which on-disk formats this host needs userland for.

        Declare what the host MEETS -- media people plug into it, disks pulled from other
        machines -- because nothing can derive that. On NixOS you usually do NOT need to list what
        it mounts: userland for anything in `fileSystems.*` is already installed for you, and nixfs
        does not duplicate it. On a host whose own distro is not NixOS nothing does that either, so
        list what it mounts here as well.

        Empty is a legitimate answer, and it is the right one for a machine that owns no block
        devices: a container sees whatever its host mounted for it, and repair tooling inside it
        would be acting on disks that are not its to touch.

        For every format at once, use the flake's own list rather than copying one:

            nixfs.filesystems = inputs.nixfs.lib.allFilesystems;

        ZFS is deliberately absent from the list and always will be. Its userland must match the
        loaded kernel module, so it can only come from whatever provides that module (`boot.zfs` on
        NixOS, the distro's own packaging elsewhere). A second, independently versioned copy
        installed from here would be a hazard, not a convenience.

        Available: ${lib.concatStringsSep ", " fsNames}.
      '';
    };

    tools = lib.genAttrs toolGroups mkToolOption;

    omit = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "hfsprogs" ];
      description = ''
        Escape hatch: drop specific nixpkgs packages this host would otherwise get.

        Prefer changing `filesystems` or turning off a `tools.*` group -- those say something true
        about the host. This exists for one honest case: a package broken or marked insecure in the
        pinned nixpkgs, where the alternative is that the host cannot build at all. It is reported
        in `warnings` every time, because a host quietly missing part of its toolchain is the exact
        situation nixfs exists to prevent. An entry naming a package this host was not going to get
        anyway is an error, so a stale omission cannot sit in a config looking meaningful.
      '';
    };

    # ── Computed, read-only ────────────────────────────────────────────────────────────────
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
    nixfs.packageNames = resolved;

    assertions = [
      {
        assertion = unknownOmissions == [ ];
        message = ''
          nixfs.omit names ${toString (builtins.length unknownOmissions)} package(s) this host was
          not going to install anyway: ${lib.concatStringsSep ", " unknownOmissions}. An omission
          that removes nothing while looking like it does is worse than no omission at all --
          either the name is a typo, or whatever used to pull it in is gone and the entry should
          be too. Omit takes nixpkgs attribute names, e.g. "hfsprogs".
        '';
      }
    ];

    warnings = lib.optional (cfg.enable && cfg.omit != [ ]) ''
      nixfs: this host omits ${toString (builtins.length cfg.omit)} package(s) it would otherwise
      install: ${lib.concatStringsSep ", " cfg.omit}. Its toolchain is therefore NOT what its own
      declaration says. This warning is deliberate and will not go away on its own -- remove the
      omission once whatever forced it (a broken or insecure package in the pinned nixpkgs) is
      resolved upstream.
    '';
  };
}
