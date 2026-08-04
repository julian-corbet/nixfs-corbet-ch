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
# you need them. nixfs makes the answer a declared fact instead, resolved PER PLATFORM so it is
# actually reachable on every host regardless of distro -- see ../lib/catalogue.nix's header for
# why "resolve to nixpkgs everywhere" was tried first and abandoned: on a live Arch host, the distro
# copy on `PATH` wins over anything installed into a Nix profile, so a nixpkgs-only pin there is
# never actually reached.
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
# PLATFORM-NEUTRAL BY DESIGN, in the sense that matters now: this file declares WHAT is wanted and
# resolves EVERY entry to BOTH a pacman name and a nixpkgs attribute name (../lib/resolve.nix). It
# installs nothing itself -- see ../modules/install.nix (the NixOS backend: nixpkgs for everything,
# because NixOS has no second package manager to lose a PATH race against) and
# ../modules/arch.nix (the system-manager backend: pacman/AUR for everything Arch has, nixpkgs ONLY
# for the entries Arch does not).
#
{ config, lib, ... }:

let
  cfg = config.nixfs;
  catalogue = import ../lib/catalogue.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  fsNames = lib.attrNames catalogue.filesystems;
  toolGroups = lib.attrNames catalogue.tools;

  # Attaches each package's own attrset key as `name` -- the catalogue's identity for that entry,
  # since every entry names one (see ../lib/catalogue.nix's header). Without it, an entry has only
  # its per-channel package names to be reported by, and `arch` is nullable -- exactly how the
  # sibling nixoffice's `unavailableOnNixos` once failed to report a channel-less entry. See
  # ../lib/resolve.nix's own header for the analogous case here.
  withName = table: lib.mapAttrsToList (n: v: v // { name = n; }) table;

  selectedFsEntries =
    lib.concatMap (k: withName catalogue.filesystems.${k}.packages) cfg.filesystems;

  enabledGroups = lib.filter (g: cfg.tools.${g}.enable) toolGroups;

  selectedToolEntries =
    lib.concatMap (g: withName catalogue.tools.${g}.packages) enabledGroups;

  wantedEntries = lib.unique (selectedFsEntries ++ selectedToolEntries);

  # `omit` names nixpkgs attributes, and every entry's `name` IS its nixpkgs attribute (see
  # ../lib/catalogue.nix), so filtering by `name` here removes an omitted entry from BOTH channels
  # at once -- there is no way for an omission to reach one channel and miss the other.
  selectedEntries = lib.filter (t: !(lib.elem t.name cfg.omit)) wantedEntries;

  unknownOmissions =
    lib.filter (o: !(lib.elem o (map (t: t.name) wantedEntries))) cfg.omit;

  mkToolOption = group: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        ${catalogue.tools.${group}.summary}.

        ${catalogue.tools.${group}.detail}
        Packages: ${lib.concatStringsSep ", " (lib.attrNames catalogue.tools.${group}.packages)}.

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
    enable = lib.mkEnableOption "the storage toolchain -- per-filesystem userland plus the generic recovery/inspection/partitioning toolkit, resolved per platform so it is actually reachable on every host regardless of distro";

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

        Named by nixpkgs attribute name, and applies to BOTH channels at once: the same entry is
        dropped from `archPackages`/`aurPackages` as from `packageNames`, since a package a host
        should not have does not become acceptable on the other platform.
      '';
    };

    # ── Computed, read-only ────────────────────────────────────────────────────────────────
    want = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "Resolved entries; the contract a platform backend consumes.";
    };

    packageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The resolved selection as nixpkgs attribute names. The contract ../modules/install.nix
        consumes, and what to read if you want to see what a NixOS host will actually get without
        instantiating anything.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The selected tools as pacman package names, for the host's own reconciler:

          nixarch.packages.pacman = config.nixfs.archPackages;

        This module cannot install them on Arch: see ../modules/arch.nix, which publishes this list
        rather than installing from it, and installs from nixpkgs only the entries Arch has nothing
        for (`unavailableOnArch` below) -- so a package present in both never gets installed twice.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that live in the AUR rather than an official repo, kept SEPARATE because
        `pacman -S` cannot resolve them -- it fails the whole transaction with "target not found",
        which takes the rest of the converge down with it. Wire them to the AUR side:

          nixarch.packages.aur = config.nixfs.aurPackages;

        AUR is a real Arch source here, not a fallback to nixpkgs: `hfsprogs` is AUR-only
        (`paru -Si hfsprogs` -> `Repository: aur`) and is installed from the AUR on an Arch host,
        never from nixpkgs -- the same `aur = true` mechanism the sibling nixdev catalogue's `kind`
        entry already uses.
      '';
    };

    unavailableOnArch = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selected entries with no Arch package at all -- neither an official repo nor the AUR --
        named by nixpkgs attribute name (this catalogue's identity for every entry). Surfaced
        rather than silently handled, so it is visible which entries a non-NixOS host still gets
        from nixpkgs and why: see ../modules/arch.nix, which installs exactly this list from
        nixpkgs and nothing more.

        Empty for the current catalogue: every entry today has a live Arch source, official repo
        or AUR (see ../lib/catalogue.nix's header). The mechanism stays -- a future filesystem tool
        may genuinely exist nowhere on Arch -- but nothing exercises it today outside a test
        fixture.
      '';
    };
  };

  config = {
    nixfs.want = selectedEntries;
    nixfs.packageNames = map (t: t.nixpkgs) selectedEntries;
    nixfs.archPackages = resolve.archPackages selectedEntries;
    nixfs.aurPackages = resolve.aurPackages selectedEntries;
    nixfs.unavailableOnArch = resolve.unavailableOnArch selectedEntries;

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
