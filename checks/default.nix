# checks/default.nix
#
# EVAL-TIME tests, two layers:
#
#   1. ../lib/resolve.nix driven with FIXTURE entry tables -- every branch of the channel
#      resolution, including an `aur = true` entry, which the real catalogue does not happen to
#      have yet. Same reasoning as the sibling nixoffice's version of this split: a resolution
#      tested only through today's real catalogue can only be tested against the entry shapes that
#      catalogue happens to contain.
#
#   2. ../modules/nixfs.nix, ../modules/install.nix and ../modules/arch.nix evaluated for real --
#      through NixOS's own eval-config.nix on one side and system-manager's own makeSystemConfig on
#      the other -- and inspected for what they RENDER. Nothing here says anything about a booted
#      machine; the claims under test are about selection and installation, and both are entirely
#      eval-time properties.
#
# The claims worth failing CI over:
#
#   1. The catalogue still resolves, on BOTH channels. nixpkgs drops packages (ReiserFS tooling
#      went when the kernel dropped the filesystem); an Arch repo can do the same. Without this, a
#      tool silently stops being installed and nobody finds out until a disk is dying.
#   2. The defaults are what the module says they are: if `tools.*` ever silently flipped off,
#      hosts would lose their toolkit without a single line of their own config changing.
#   3. The two backends compute the SAME policy. `nixfs.packageNames`/`archPackages`/
#      `aurPackages`/`unavailableOnArch` are facts about a selection, not about which backend asked
#      -- both import ../modules/nixfs.nix unchanged, and if a NixOS eval and a system-manager eval
#      of the identical `nixfs.*` config ever disagreed about what was WANTED, that would mean the
#      two backends had quietly diverged on policy rather than only on installation.
#   4. NO PACKAGE IS INSTALLED TWICE -- the entire reason this repo stopped resolving to nixpkgs on
#      every host. The NixOS backend installs every selected entry from nixpkgs, unconditionally.
#      The Arch backend must install ONLY the entries with no Arch package at all
#      (`unavailableOnArch`) and never an entry pacman already covers -- see ../lib/catalogue.nix's
#      header for the live PATH-shadowing evidence this guards against. This is the check that was
#      run once with the split deliberately broken (the Arch backend patched to also install every
#      `archPackages` entry from nixpkgs) to confirm it actually fails; see the commit message for
#      that run's `nix flake check` output.
#
{ pkgs, lib, nixpkgs, system, nixosModule, archModule, systemManagerLib }:

let
  catalogue = import ../lib/catalogue.nix { };
  resolve = import ../lib/resolve.nix { inherit lib; };

  withName = table: lib.mapAttrsToList (n: v: v // { name = n; }) table;

  fsNames = lib.attrNames catalogue.filesystems;
  toolGroups = lib.attrNames catalogue.tools;

  allFsEntries = lib.unique (lib.concatMap (k: withName catalogue.filesystems.${k}.packages) fsNames);
  allToolEntries = lib.unique (lib.concatMap (g: withName catalogue.tools.${g}.packages) toolGroups);
  allCatalogueEntries = lib.unique (allFsEntries ++ allToolEntries);

  allFsPackages = lib.unique (map (t: t.nixpkgs) allFsEntries);
  allToolPackages = lib.unique (map (t: t.nixpkgs) allToolEntries);
  allCataloguePackages = lib.unique (map (t: t.nixpkgs) allCatalogueEntries);

  sorted = lib.sort (a: b: a < b);
  outPathOf = n: (lib.getAttrFromPath (lib.splitString "." n) pkgs).outPath;

  check = name: ok: detail: { inherit name ok detail; };

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # Layer 1: ../lib/resolve.nix against fixtures, independent of the real catalogue.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  repoEntry = { name = "repoapp"; arch = "repoapp"; nixpkgs = "repoapp"; };
  aurEntry = { name = "aurapp"; arch = "aurapp"; aur = true; nixpkgs = "aurapp"; };
  # The shape the real catalogue names by the same `nixpkgs`/`arch` string, so a resolve-level
  # fixture needs its own case where they diverge -- ntfs (ntfs3g/ntfs-3g) proves it happens, but
  # only against the real catalogue; this is the fixture proving the RESOLUTION handles it too.
  divergentEntry = { name = "divergentapp"; arch = "divergent-arch-name"; nixpkgs = "divergentapp"; };
  nixpkgsOnlyEntry = { name = "onlyapp"; arch = null; nixpkgs = "onlyapp"; };

  allFixtures = [ repoEntry aurEntry divergentEntry nixpkgsOnlyEntry ];

  resolveChecks = [
    (check "resolve/arch-excludes-aur-and-nixpkgs-only-entries"
      (resolve.archPackages allFixtures == [ "repoapp" "divergent-arch-name" ])
      "got: ${builtins.toJSON (resolve.archPackages allFixtures)}")

    (check "resolve/aur-holds-only-aur-entries"
      (resolve.aurPackages allFixtures == [ "aurapp" ])
      "got: ${builtins.toJSON (resolve.aurPackages allFixtures)}")

    # A null pacman name must never reach a package list -- `pacman -S` would be handed a literal
    # "null" and fail the whole transaction, taking every other package in the converge with it.
    (check "resolve/arch-and-aur-never-emit-a-null"
      (!(builtins.elem null (resolve.archPackages allFixtures))
        && !(builtins.elem null (resolve.aurPackages allFixtures)))
      "arch: ${builtins.toJSON (resolve.archPackages allFixtures)} aur: ${builtins.toJSON (resolve.aurPackages allFixtures)}")

    (check "resolve/unavailable-on-arch-reports-the-nixpkgs-only-entry"
      (resolve.unavailableOnArch allFixtures == [ "onlyapp" ])
      "got: ${builtins.toJSON (resolve.unavailableOnArch allFixtures)}")

    (check "resolve/unavailable-on-arch-reports-the-catalogue-key-not-a-package-name"
      (resolve.unavailableOnArch [ nixpkgsOnlyEntry ] == [ "onlyapp" ])
      "got: ${builtins.toJSON (resolve.unavailableOnArch [ nixpkgsOnlyEntry ])}")

    (check "resolve/unavailable-on-arch-ignores-entries-that-do-have-arch"
      (resolve.unavailableOnArch [ repoEntry aurEntry divergentEntry ] == [ ])
      "got: ${builtins.toJSON (resolve.unavailableOnArch [ repoEntry aurEntry divergentEntry ])}")

    # THE anti-shadowing invariant, at the resolution level: the entries feeding archPackages/
    # aurPackages and the entries feeding unavailableOnArch partition on the same boolean
    # (`arch == null`), so their identities can never intersect.
    (check "resolve/arch-and-nixpkgs-only-partitions-are-disjoint"
      (
        let
          namesWithArch = map (t: t.name) (lib.filter (t: t.arch != null) allFixtures);
        in
        lib.intersectLists namesWithArch (resolve.unavailableOnArch allFixtures) == [ ]
      )
      "arch-covered names and nixpkgs-only names overlapped")

    (check "resolve/empty-selection-resolves-to-empty-everywhere"
      (resolve.archPackages [ ] == [ ] && resolve.aurPackages [ ] == [ ] && resolve.unavailableOnArch [ ] == [ ])
      "one of the resolve functions returned non-empty on an empty selection")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # Layer 2a: ../modules/nixfs.nix (policy only) against the REAL catalogue, via lib.evalModules --
  # cheap enough to run without a full NixOS or system-manager evaluation, for the option-wiring
  # claims that do not depend on either backend's installer.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  # ../modules/nixfs.nix sets `assertions`/`warnings` in its config, options NixOS's own module
  # system declares for it (nixos/modules/misc/assertions.nix) but plain `lib.evalModules` does
  # not. Declared here, inert, purely so the option exists -- none of the policy checks below read
  # either; the real enforcement is exercised through `evalNixos`/`nixosBuildFails` further down,
  # against NixOS's actual assertions machinery.
  assertionOptions = { lib, ... }: {
    options = {
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalPolicy = extraConfig: (lib.evalModules {
    modules = [ ../modules/nixfs.nix assertionOptions extraConfig ];
  }).config;

  policyEverything = evalPolicy { nixfs.filesystems = fsNames; };
  policyEmpty = evalPolicy {
    nixfs.filesystems = [ ];
    nixfs.tools = lib.genAttrs toolGroups (_: { enable = false; });
  };
  policyOmitHfs = evalPolicy { nixfs.filesystems = fsNames; nixfs.omit = [ "hfsprogs" ]; };
  policyOmitNtfs = evalPolicy { nixfs.filesystems = fsNames; nixfs.omit = [ "ntfs3g" ]; };

  policyChecks = [
    # ── the ntfs name divergence, against the real catalogue ────────────────────────────────
    (check "module/ntfs-nixpkgs-name-differs-from-arch-name"
      (lib.elem "ntfs3g" policyEverything.nixfs.packageNames
        && lib.elem "ntfs-3g" policyEverything.nixfs.archPackages
        && !(lib.elem "ntfs3g" policyEverything.nixfs.archPackages)
        && !(lib.elem "ntfs-3g" policyEverything.nixfs.packageNames))
      "packageNames: ${builtins.toJSON policyEverything.nixfs.packageNames}, archPackages: ${builtins.toJSON policyEverything.nixfs.archPackages}")

    # ── hfs: arch = null, so it is nixpkgs-only and absent from archPackages ────────────────
    (check "module/hfs-is-nixpkgs-only-and-absent-from-archPackages"
      (lib.elem "hfsprogs" policyEverything.nixfs.unavailableOnArch
        && !(lib.elem "hfsprogs" policyEverything.nixfs.archPackages))
      "unavailableOnArch: ${builtins.toJSON policyEverything.nixfs.unavailableOnArch}, archPackages: ${builtins.toJSON policyEverything.nixfs.archPackages}")

    # ── a normal entry is the mirror image: in archPackages, never in the nixpkgs-only list ──
    (check "module/an-ordinary-entry-is-arch-covered-not-nixpkgs-only"
      (lib.elem "e2fsprogs" policyEverything.nixfs.archPackages
        && !(lib.elem "e2fsprogs" policyEverything.nixfs.unavailableOnArch))
      "archPackages: ${builtins.toJSON policyEverything.nixfs.archPackages}, unavailableOnArch: ${builtins.toJSON policyEverything.nixfs.unavailableOnArch}")

    # ── the anti-shadowing invariant again, wired through the actual module this time ───────
    (check "module/arch-covered-and-nixpkgs-only-entries-never-overlap"
      (
        let namesWithArch = map (t: t.name) (lib.filter (t: t.arch != null) policyEverything.nixfs.want);
        in lib.intersectLists namesWithArch policyEverything.nixfs.unavailableOnArch == [ ]
      )
      "an entry's name appeared both among arch-covered entries and in unavailableOnArch")

    # ── omit reaches BOTH channels for the entry it names, whichever channel that entry uses ─
    (check "module/omit-removes-a-nixpkgs-only-entry-from-both-its-lists"
      (!(lib.elem "hfsprogs" policyOmitHfs.nixfs.packageNames)
        && !(lib.elem "hfsprogs" policyOmitHfs.nixfs.unavailableOnArch))
      "packageNames: ${builtins.toJSON policyOmitHfs.nixfs.packageNames}, unavailableOnArch: ${builtins.toJSON policyOmitHfs.nixfs.unavailableOnArch}")

    (check "module/omit-removes-an-arch-covered-entry-from-both-its-lists"
      (!(lib.elem "ntfs3g" policyOmitNtfs.nixfs.packageNames)
        && !(lib.elem "ntfs-3g" policyOmitNtfs.nixfs.archPackages))
      "packageNames: ${builtins.toJSON policyOmitNtfs.nixfs.packageNames}, archPackages: ${builtins.toJSON policyOmitNtfs.nixfs.archPackages}")

    # ── selecting nothing yields nothing, on every list this module publishes ────────────────
    (check "module/empty-selection-resolves-to-empty-lists"
      (policyEmpty.nixfs.want == [ ]
        && policyEmpty.nixfs.packageNames == [ ]
        && policyEmpty.nixfs.archPackages == [ ]
        && policyEmpty.nixfs.aurPackages == [ ]
        && policyEmpty.nixfs.unavailableOnArch == [ ])
      "want: ${builtins.toJSON policyEmpty.nixfs.want}")

    # ── the catalogue's own shape, so a future edit cannot silently break the above ─────────
    # Every entry must carry a nixpkgs name -- nixfs has no third channel like nixoffice's
    # Flatpak, so an entry with neither `arch` nor `nixpkgs` would be undeliverable everywhere.
    (check "catalogue/every-entry-has-a-nixpkgs-name"
      (lib.all (t: t.nixpkgs != null) allCatalogueEntries)
      "catalogue has an entry with no nixpkgs name at all")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # Layer 2b: the real backends, evaluated through NixOS's eval-config.nix and system-manager's
  # makeSystemConfig -- what a real `nixos-rebuild` / `nix build .#systemConfigs.<host>` sees.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  # ── NixOS backend ────────────────────────────────────────────────────────────────────────
  evalNixos = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        nixosModule
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
  evalSm = extraConfig:
    (systemManagerLib.makeSystemConfig {
      modules = [
        archModule
        { nixfs.enable = true; }
        extraConfig
        { nixpkgs.hostPlatform = system; }
      ];
    }).config;

  # ── Fixtures ─────────────────────────────────────────────────────────────────────────────
  cfg-bare = evalNixos { };

  cfg-everything = evalNixos {
    nixfs.filesystems = fsNames;
  };

  sm-everything = evalSm {
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
        expected = lib.attrNames catalogue.tools.${g}.packages;
      in
      check "tools/${g}-off-removes-exactly-its-packages"
        (sorted removed == sorted expected)
        "removed: ${builtins.toJSON (sorted removed)}, expected: ${builtins.toJSON (sorted expected)}")
    toolGroups;

  # ── Both backends compute the SAME policy for the same input (claim 3) ──────────────────
  policyParityChecks = map
    (fixture: check "policy-parity/${fixture.name}"
      (
        let
          sm = (evalSm fixture.config).nixfs;
          nixos = (evalNixos fixture.config).nixfs;
        in
        sorted sm.packageNames == sorted nixos.packageNames
        && sorted sm.archPackages == sorted nixos.archPackages
        && sorted sm.aurPackages == sorted nixos.aurPackages
        && sorted sm.unavailableOnArch == sorted nixos.unavailableOnArch
      )
      "the two backends resolved different policy for the same input")
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
    # --- 1. the catalogue still resolves, on both channels ------------------------------
    (check "catalogue/every-nixpkgs-name-exists-in-nixpkgs"
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
        in sorted extra == sorted (lib.attrNames catalogue.filesystems.btrfs.packages)
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

    # --- 5. the NixOS backend installs everything from nixpkgs --------------------------
    # Containment, not exact equality: a real NixOS evaluation carries baseline
    # environment.systemPackages of its own (nano, the installer tools, ...) that have nothing to
    # do with nixfs, so the claim under test is only that nixfs's own resolved set is a subset.
    (check "install/nixos-installs-every-resolved-package"
      (
        let installedOutPaths = map (p: p.outPath) cfg-everything.environment.systemPackages;
        in lib.all (n: lib.elem (outPathOf n) installedOutPaths) cfg-everything.nixfs.packageNames
      )
      "environment.systemPackages does not contain every resolved package")

    (check "install/nixos-disabled-installs-nothing"
      (
        let cfg = evalNixos { nixfs.enable = lib.mkForce false; nixfs.filesystems = fsNames; };
        in !(lib.elem pkgs.ddrescue cfg.environment.systemPackages)
          && !(lib.elem pkgs.hfsprogs cfg.environment.systemPackages)
      )
      "nixfs.enable = false still installed the toolchain")

    # --- 6. THE anti-shadowing property: the Arch backend installs from nixpkgs ONLY the -----
    #        entries Arch has nothing for, and never an entry pacman already covers. This is the
    #        check that fails when the split is broken -- see this file's own header. Containment
    #        for the "installs" half, not exact equality: system-manager's own baseline
    #        (bash-interactive, nologin, ...) is in environment.systemPackages too and has nothing
    #        to do with nixfs.
    (check "install/arch-backend-installs-every-nixpkgs-only-entry"
      (
        let installedOutPaths = map (p: p.outPath) sm-everything.environment.systemPackages;
        in lib.all (n: lib.elem (outPathOf n) installedOutPaths) sm-everything.nixfs.unavailableOnArch
      )
      "arch backend did not install every unavailableOnArch entry")

    (check "install/arch-backend-never-installs-an-entry-pacman-already-has"
      (
        let
          smInstalledOutPaths = map (p: p.outPath) sm-everything.environment.systemPackages;
          archCoveredNixpkgsNames =
            lib.filter (n: !(lib.elem n sm-everything.nixfs.unavailableOnArch)) sm-everything.nixfs.packageNames;
        in
        lib.all (n: !(lib.elem (outPathOf n) smInstalledOutPaths)) archCoveredNixpkgsNames
      )
      "the arch backend installed a package from nixpkgs that pacman also covers")

    (check "install/arch-backend-publishes-archPackages-for-a-normal-entry"
      (lib.elem "e2fsprogs" sm-everything.nixfs.archPackages)
      "archPackages: ${builtins.toJSON sm-everything.nixfs.archPackages}")

    # --- 7. omit removes, says so, and cannot rot ---------------------------------------
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
  ++ resolveChecks
  ++ policyChecks
  ++ singleGroupOffChecks
  ++ policyParityChecks;

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
