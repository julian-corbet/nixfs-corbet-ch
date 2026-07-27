# checks/default.nix
#
# EVAL-TIME tests. No VM, no build: each test evaluates a real configuration -- through NixOS's
# own eval-config.nix on one side and system-manager's own makeSystemConfig on the other -- and
# inspects what the module RENDERS. Nothing here says anything about a booted machine; the claims
# under test are about selection, not behaviour, and selection is entirely an eval-time property.
#
# The three claims worth failing CI over:
#
#   1. The catalogue still resolves. nixpkgs drops packages (ReiserFS tooling went when the kernel
#      dropped the filesystem). Without this, a tool silently stops being installed and nobody
#      finds out until a disk is dying.
#   2. The tiers are monotone. media.nix claims each tier is a strict superset of the one below.
#      That claim is load-bearing -- it is why moving a host up a tier is a safe edit -- so it is
#      checked rather than asserted in prose.
#   3. Both backends agree. nixfs's whole reason to exist is that the toolchain is identical
#      regardless of the host's distro. If the NixOS and system-manager evaluations of the same
#      input ever diverge, that claim is false and everything else here is decoration.
#
{ pkgs, lib, nixpkgs, system, nixfsModule, systemManagerLib }:

let
  catalogue = import ../lib/catalogue.nix { };
  mediaData = import ../media.nix;
  inherit (mediaData) tierOrder;

  groups = lib.attrNames catalogue;

  # Every package the catalogue can ever name, regardless of tier.
  allCataloguePackages =
    lib.unique (lib.concatMap
      (g: lib.concatMap (k: catalogue.${g}.${k}.packages) (lib.attrNames catalogue.${g}))
      groups);

  # ── NixOS backend ────────────────────────────────────────────────────────────────────────
  evalNixos = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        nixfsModule
        { nixfs.enable = true; }
        extraConfig
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          system.stateVersion = "25.05";
        }
      ];
    }).config;

  # NixOS enforces assertions when `system.build.toplevel` is forced, not on a bare read of
  # `config.assertions` (a passive list). `seq` reaches the wrapping throw without deep-forcing
  # the whole system closure.
  nixosBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalNixos extraConfig).system.build.toplevel true)).success;

  # ── system-manager backend ───────────────────────────────────────────────────────────────
  # makeSystemConfig gates its entire return value on assertions passing, so `.config` is
  # unreachable when one fails and the call throws first -- a faithful match for what a real
  # `nix build .#systemConfigs.<host>` does.
  evalSm = extraConfig:
    (systemManagerLib.makeSystemConfig {
      modules = [
        nixfsModule
        { nixfs.enable = true; }
        extraConfig
        { nixpkgs.hostPlatform = system; }
      ];
    }).config;

  smEvalFails = extraConfig:
    !(builtins.tryEval (builtins.deepSeq (evalSm extraConfig) true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # ── Fixtures ─────────────────────────────────────────────────────────────────────────────
  nixosByTier = lib.genAttrs tierOrder (t: evalNixos { nixfs.media = t; });
  smByTier = lib.genAttrs tierOrder (t: evalSm { nixfs.media = t; });

  namesAt = t: nixosByTier.${t}.nixfs.packageNames;

  # A container: no tier contribution at all, but it still mounts something.
  cfg-container = evalNixos {
    nixfs.media = "none";
    nixfs.filesystems = [ "btrfs" ];
  };

  cfg-omit = evalNixos {
    nixfs.media = "arbitrary";
    nixfs.omit = [ "filesystems.hfs" ];
  };

  # Consecutive tier pairs, for the monotonicity check.
  tierPairs = lib.zipListsWith (lower: higher: { inherit lower higher; })
    (lib.init tierOrder)
    (lib.tail tierOrder);

  monotonicityChecks = map
    (p:
      let
        lowerNames = namesAt p.lower;
        higherNames = namesAt p.higher;
        lost = lib.filter (n: !(lib.elem n higherNames)) lowerNames;
      in
      check "tiers-monotone/${p.lower}-subset-of-${p.higher}"
        (lost == [ ])
        "moving up a tier DROPPED: ${lib.concatStringsSep ", " lost}")
    tierPairs;

  # Both backends, same input, same answer -- once per tier.
  backendParityChecks = map
    (t: check "backend-parity/${t}"
      (smByTier.${t}.nixfs.packageNames == nixosByTier.${t}.nixfs.packageNames)
      ''
        NixOS:          ${builtins.toJSON nixosByTier.${t}.nixfs.packageNames}
        system-manager: ${builtins.toJSON smByTier.${t}.nixfs.packageNames}
      '')
    tierOrder;

  results = [
    # --- 1. the catalogue still resolves ------------------------------------------------
    (check "catalogue/every-package-exists-in-nixpkgs"
      (lib.all (n: lib.hasAttrByPath (lib.splitString "." n) pkgs) allCataloguePackages)
      "missing from this nixpkgs: ${lib.concatStringsSep ", " (lib.filter (n: !(lib.hasAttrByPath (lib.splitString "." n) pkgs)) allCataloguePackages)}")

    # ZFS userland must track the loaded kernel module, so it can only come from whatever
    # provides that module. This check exists so that adding it here later is a deliberate,
    # visible act rather than a plausible-looking one-line addition to the filesystem table.
    (check "catalogue/no-zfs-entry"
      (!(catalogue.filesystems ? "zfs")
        && !(lib.elem "zfs" allCataloguePackages)
        && !(lib.elem "zfstools" allCataloguePackages))
      "the catalogue names ZFS userland; it must come from whatever provides the kernel module (boot.zfs on NixOS), never from here -- see lib/catalogue.nix")

    # --- 2. the tiers are monotone ------------------------------------------------------
    # (per-pair checks appended below)

    # The top tier is the whole catalogue. Without this, an entry could be added to
    # lib/catalogue.nix and reachable from no tier at all -- selectable in principle,
    # installed nowhere, and never noticed.
    (check "tiers/arbitrary-covers-the-whole-catalogue"
      (lib.sort (a: b: a < b) (namesAt "arbitrary") == lib.sort (a: b: a < b) allCataloguePackages)
      "unreachable from any tier: ${lib.concatStringsSep ", " (lib.filter (n: !(lib.elem n (namesAt "arbitrary"))) allCataloguePackages)}")

    (check "tiers/none-contributes-nothing"
      (namesAt "none" == [ ])
      "got: ${builtins.toJSON (namesAt "none")}")

    # A container declares what it mounts and gets exactly that -- the archetypal `none` host,
    # and the case that motivated making `filesystems` additive on top of the tier rather than
    # part of it.
    (check "tiers/none-plus-explicit-filesystem"
      (cfg-container.nixfs.packageNames == [ "btrfs-progs" ])
      "got: ${builtins.toJSON cfg-container.nixfs.packageNames}")

    (check "tiers/fixed-has-drive-health-but-no-recovery"
      (lib.elem "smartmontools" (namesAt "fixed")
        && !(lib.elem "ddrescue" (namesAt "fixed"))
        && !(lib.elem "testdisk" (namesAt "fixed")))
      "got: ${builtins.toJSON (namesAt "fixed")}")

    # Recovery sits at `removable`, not `arbitrary`, on the reasoning in media.nix: the moment
    # someone hands you a dying stick is the moment you need ddrescue, and that happens on any
    # machine people plug things into -- not only on an ingest host.
    (check "tiers/removable-has-recovery"
      (lib.all (n: lib.elem n (namesAt "removable")) [ "ddrescue" "testdisk" "ntfs3g" "exfatprogs" "dosfstools" ])
      "got: ${builtins.toJSON (namesAt "removable")}")

    (check "tiers/arbitrary-has-the-legacy-formats"
      (lib.all (n: lib.elem n (namesAt "arbitrary")) [ "hfsprogs" "udftools" "jfsutils" "nilfs-utils" ])
      "got: ${builtins.toJSON (namesAt "arbitrary")}")

    # --- 3. the resolved selection reaches environment.systemPackages -------------------
    # packageNames is a computed contract; this is the check that it is actually WIRED, on the
    # backend where a mistake would be least visible.
    (check "install/packages-reach-environment-systemPackages"
      (lib.all
        (n: lib.elem (lib.getAttrFromPath (lib.splitString "." n) pkgs) nixosByTier.arbitrary.environment.systemPackages)
        (namesAt "arbitrary"))
      "environment.systemPackages does not contain every resolved package")

    (check "install/disabled-installs-nothing"
      (
        let cfg = evalNixos { nixfs.enable = lib.mkForce false; nixfs.media = "arbitrary"; };
        in !(lib.elem pkgs.ddrescue cfg.environment.systemPackages)
      )
      "nixfs.enable = false still installed the toolchain")

    # --- 4. the failure modes actually fail --------------------------------------------
    (check "media-unset/nixos-build-fails"
      (nixosBuildFails { nixfs.media = null; })
      "expected forcing system.build.toplevel to fail with media unset, but it succeeded")

    (check "media-unset/system-manager-eval-fails"
      (smEvalFails { nixfs.media = null; })
      "expected makeSystemConfig to throw with media unset, but it succeeded")

    (check "omit-unknown-key/build-fails"
      (nixosBuildFails { nixfs.media = "fixed"; nixfs.omit = [ "filesystems.hfsplus" ]; })
      "expected a typo'd omit key to fail the build, but it succeeded")

    (check "omit-unknown-key/group-typo-also-fails"
      (nixosBuildFails { nixfs.media = "fixed"; nixfs.omit = [ "filesystem.hfs" ]; })
      "expected a typo'd omit GROUP to fail the build, but it succeeded")

    # --- 5. omit removes, and says so ---------------------------------------------------
    (check "omit/removes-the-package"
      (!(lib.elem "hfsprogs" cfg-omit.nixfs.packageNames)
        && lib.elem "udftools" cfg-omit.nixfs.packageNames)
      "got: ${builtins.toJSON cfg-omit.nixfs.packageNames}")

    (check "omit/warns-that-the-host-diverges"
      (lib.any (w: lib.hasInfix "filesystems.hfs" w) cfg-omit.warnings)
      "warnings: ${builtins.toJSON cfg-omit.warnings}")

    (check "omit/silent-when-empty"
      (nixosByTier.arbitrary.warnings == [ ])
      "warnings: ${builtins.toJSON nixosByTier.arbitrary.warnings}")
  ]
  ++ monotonicityChecks
  ++ backendParityChecks;

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixfs eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
    ${report}
  ''
else {
  # Depending on `passedCount` forces `results`, so the tests genuinely run under
  # `nix flake check` rather than merely being defined.
  eval-tests = pkgs.runCommand "nixfs-eval-tests"
    { passedCount = toString (builtins.length results); }
    ''
      echo "all $passedCount nixfs eval tests passed"
      touch $out
    '';
}
