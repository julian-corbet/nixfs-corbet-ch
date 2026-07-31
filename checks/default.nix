# checks/default.nix
#
# EVAL-TIME tests. No VM, no build: each test evaluates a real configuration -- through NixOS's own
# eval-config.nix on one side and system-manager's own makeSystemConfig on the other -- and inspects
# what the module RENDERS. Nothing here says anything about a booted machine; the claims under test
# are about selection, and selection is entirely an eval-time property.
#
# The three claims worth failing CI over:
#
#   1. The catalogue still resolves. nixpkgs drops packages (ReiserFS tooling went when the kernel
#      dropped the filesystem). Without this, a tool silently stops being installed and nobody
#      finds out until a disk is dying.
#   2. The defaults are what the module says they are: if `tools.*` ever silently flipped off,
#      hosts would lose their toolkit without a single line of their own config changing.
#   3. Both backends agree. nixfs's reason to exist is that the toolchain is identical regardless
#      of the host's distro. If the NixOS and system-manager evaluations of the same input ever
#      diverge, that claim is false and everything else here is decoration.
#
{ pkgs, lib, nixpkgs, system, nixfsModule, systemManagerLib }:

let
  catalogue = import ../lib/catalogue.nix { };
  fsNames = lib.attrNames catalogue.filesystems;
  toolGroups = lib.attrNames catalogue.tools;

  allFsPackages = lib.unique (lib.concatMap (k: catalogue.filesystems.${k}.packages) fsNames);
  allToolPackages = lib.unique (lib.concatMap (g: catalogue.tools.${g}.packages) toolGroups);
  allCataloguePackages = lib.unique (allFsPackages ++ allToolPackages);

  sorted = lib.sort (a: b: a < b);

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
  # `config.assertions` (a passive list). `seq` reaches the wrapping throw without deep-forcing the
  # whole system closure.
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

  check = name: ok: detail: { inherit name ok detail; };

  # ── Fixtures ─────────────────────────────────────────────────────────────────────────────
  # The bare case: `enable = true` and nothing else. This is the shape every default claim rests
  # on, so it is one fixture reused rather than re-derived per test.
  cfg-bare = evalNixos { };

  cfg-everything = evalNixos {
    nixfs.filesystems = fsNames;
  };

  # The constrained host: one filesystem, no generic toolkit at all.
  cfg-minimal = evalNixos {
    nixfs.filesystems = [ "btrfs" ];
    nixfs.tools = lib.genAttrs toolGroups (_: { enable = false; });
  };

  # The container: no block devices, so no filesystem userland and no toolkit.
  cfg-container = evalNixos {
    nixfs.filesystems = [ ];
    nixfs.tools = lib.genAttrs toolGroups (_: { enable = false; });
  };

  cfg-omit = evalNixos {
    nixfs.filesystems = fsNames;
    nixfs.omit = [ "hfsprogs" ];
  };

  # Turning off exactly one group must remove exactly that group's packages and nothing else.
  singleGroupOffChecks = map
    (g:
      let
        off = evalNixos { nixfs.tools.${g}.enable = false; };
        removed = lib.filter (p: !(lib.elem p off.nixfs.packageNames)) cfg-bare.nixfs.packageNames;
      in
      check "tools/${g}-off-removes-exactly-its-packages"
        (sorted removed == sorted catalogue.tools.${g}.packages)
        "removed: ${builtins.toJSON (sorted removed)}, expected: ${builtins.toJSON (sorted catalogue.tools.${g}.packages)}")
    toolGroups;

  # Both backends, same input, same answer.
  backendParityChecks = map
    (fixture: check "backend-parity/${fixture.name}"
      (
        let sm = (evalSm fixture.config).nixfs.packageNames;
        in sorted sm == sorted (evalNixos fixture.config).nixfs.packageNames
      )
      "the two backends resolved different package sets for the same input")
    [
      { name = "bare-defaults"; config = { }; }
      { name = "everything"; config = { nixfs.filesystems = fsNames; }; }
      {
        name = "minimal";
        config = {
          nixfs.filesystems = [ "btrfs" ];
          nixfs.tools = lib.genAttrs toolGroups (_: { enable = false; });
        };
      }
    ];

  results = [
    # --- 1. the catalogue still resolves ------------------------------------------------
    (check "catalogue/every-package-exists-in-nixpkgs"
      (lib.all (n: lib.hasAttrByPath (lib.splitString "." n) pkgs) allCataloguePackages)
      "missing from this nixpkgs: ${lib.concatStringsSep ", " (lib.filter (n: !(lib.hasAttrByPath (lib.splitString "." n) pkgs)) allCataloguePackages)}")

    # ZFS userland must track the loaded kernel module, so it can only come from whatever provides
    # that module. This check exists so that adding it here later is a deliberate, visible act
    # rather than a plausible-looking one-line addition to the filesystem table.
    (check "catalogue/no-zfs-entry"
      (!(catalogue.filesystems ? "zfs") && !(lib.any (p: lib.hasPrefix "zfs" p) allCataloguePackages))
      "the catalogue names ZFS userland; it must come from whatever provides the kernel module (boot.zfs on NixOS), never from here -- see lib/catalogue.nix")

    # --- 2. the defaults are what the module says ---------------------------------------
    # `tools.*` defaults ON: the generic toolkit is not a per-host judgment call, so a host gets
    # it without asking.
    (check "defaults/bare-enable-gives-the-whole-toolkit"
      (sorted cfg-bare.nixfs.packageNames == sorted allToolPackages)
      "got: ${builtins.toJSON (sorted cfg-bare.nixfs.packageNames)}, expected exactly the tool groups: ${builtins.toJSON (sorted allToolPackages)}")

    # ...and NO filesystem userland, because which formats a host deals with cannot be guessed.
    (check "defaults/bare-enable-gives-no-filesystem-userland"
      (!(lib.any (p: lib.elem p allFsPackages) cfg-bare.nixfs.packageNames))
      "got filesystem packages without any being declared: ${builtins.toJSON (lib.filter (p: lib.elem p allFsPackages) cfg-bare.nixfs.packageNames)}")

    # --- 3. filesystems are additive and exact ------------------------------------------
    (check "filesystems/declared-set-is-added-exactly"
      (
        let extra = lib.filter (p: !(lib.elem p cfg-bare.nixfs.packageNames)) cfg-minimal.nixfs.packageNames;
        in sorted extra == sorted catalogue.filesystems.btrfs.packages
      )
      "got: ${builtins.toJSON (sorted cfg-minimal.nixfs.packageNames)}")

    (check "filesystems/all-of-them-covers-every-catalogue-entry"
      (sorted cfg-everything.nixfs.packageNames == sorted allCataloguePackages)
      "unreachable: ${builtins.toJSON (lib.filter (p: !(lib.elem p cfg-everything.nixfs.packageNames)) allCataloguePackages)}")

    # A multi-package filesystem entry must contribute all of its packages, not just the first --
    # vfat is the only entry with more than one, so it is the only thing standing between the
    # module and silently dropping mtools or fatresize.
    (check "filesystems/multi-package-entry-contributes-all"
      (
        let cfg = evalNixos { nixfs.filesystems = [ "vfat" ]; };
        in lib.all (p: lib.elem p cfg.nixfs.packageNames) [ "dosfstools" "mtools" "fatresize" ]
      )
      "vfat did not contribute all of dosfstools, mtools and fatresize")

    # --- 4. the constrained cases resolve to what they claim ----------------------------
    (check "constrained/one-filesystem-no-toolkit"
      (cfg-minimal.nixfs.packageNames == [ "btrfs-progs" ])
      "got: ${builtins.toJSON cfg-minimal.nixfs.packageNames}")

    (check "constrained/container-gets-nothing"
      (cfg-container.nixfs.packageNames == [ ])
      "got: ${builtins.toJSON cfg-container.nixfs.packageNames}")

    # --- 5. the resolved selection reaches environment.systemPackages -------------------
    # packageNames is a computed contract; this is the check that it is actually WIRED.
    (check "install/packages-reach-environment-systemPackages"
      (lib.all
        (n: lib.elem (lib.getAttrFromPath (lib.splitString "." n) pkgs) cfg-everything.environment.systemPackages)
        cfg-everything.nixfs.packageNames)
      "environment.systemPackages does not contain every resolved package")

    (check "install/disabled-installs-nothing"
      (
        let cfg = evalNixos { nixfs.enable = lib.mkForce false; nixfs.filesystems = fsNames; };
        in !(lib.elem pkgs.ddrescue cfg.environment.systemPackages)
          && !(lib.elem pkgs.hfsprogs cfg.environment.systemPackages)
      )
      "nixfs.enable = false still installed the toolchain")

    # --- 6. omit removes, says so, and cannot rot ---------------------------------------
    (check "omit/removes-the-package"
      (!(lib.elem "hfsprogs" cfg-omit.nixfs.packageNames)
        && lib.elem "udftools" cfg-omit.nixfs.packageNames)
      "got: ${builtins.toJSON cfg-omit.nixfs.packageNames}")

    (check "omit/warns-that-the-host-diverges"
      (lib.any (w: lib.hasInfix "hfsprogs" w) cfg-omit.warnings)
      "warnings: ${builtins.toJSON cfg-omit.warnings}")

    (check "omit/silent-when-empty"
      (cfg-everything.warnings == [ ])
      "warnings: ${builtins.toJSON cfg-everything.warnings}")

    # An omission for something this host was never going to install is a stale or typo'd entry;
    # either way it removes nothing while looking like it does.
    (check "omit/stale-entry-fails-the-build"
      (nixosBuildFails { nixfs.filesystems = [ "btrfs" ]; nixfs.omit = [ "hfsprogs" ]; })
      "expected an omission for a package this host never installs to fail the build, but it succeeded")

    (check "omit/typo-fails-the-build"
      (nixosBuildFails { nixfs.filesystems = fsNames; nixfs.omit = [ "hfsprog" ]; })
      "expected a typo'd omit entry to fail the build, but it succeeded")
  ]
  ++ singleGroupOffChecks
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
