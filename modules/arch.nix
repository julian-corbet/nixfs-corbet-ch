#
# The system-manager backend: publish the pacman/AUR names for the host's own reconciler, and
# install from nixpkgs ONLY the entries Arch has nothing for at all.
#
# THE ANTI-SHADOWING RULE THIS FILE EXISTS TO ENFORCE. On a live Arch host, `/usr/sbin` precedes
# the system-manager Nix profile on `PATH` -- see ../lib/catalogue.nix's header for the live
# evidence (mkfs.xfs, smartctl, pv, lsscsi, mkfs.f2fs, mcopy, mdadm, hdparm all resolving to the
# distro copy while the pinned nixpkgs copies sat unreached). Installing an entry from nixpkgs here
# when pacman ALSO has it does not add redundancy, it adds a copy that is never the one that runs --
# dead weight in every rebuild, and a false sense that the pin means something. So this backend
# draws a hard line: an entry with a pacman name is published for the reconciler and installed from
# NOWHERE here; an entry with none (`unavailableOnArch`) is installed from nixpkgs and published
# NOWHERE else. No entry is ever both.
#
# THE PUBLISHED LISTS ARE NOT WIRED TO A RECONCILER HERE, on purpose -- the same reasoning as the
# sibling nixdev/nixoffice Arch backends: wiring a reconciler in here would couple this general
# flake to one deployment's package module. A host's own config connects it:
#
#   nixarch.packages.pacman = config.nixfs.archPackages;
#   nixarch.packages.aur = config.nixfs.aurPackages;
#
{ config, lib, pkgs, ... }:

let
  cfg = config.nixfs;

  # The only entries this backend may touch with nixpkgs: exactly `unavailableOnArch`, never more.
  # Filtered from `cfg.want` directly (not re-derived from the published name list) so a bug that
  # changed what gets INSTALLED here could not also quietly change what the option reports.
  nixpkgsOnly = lib.filter (t: t.arch == null) cfg.want;

  path = name: lib.splitString "." name;
  resolves = t: lib.hasAttrByPath (path t.nixpkgs) pkgs;
  missing = lib.filter (t: !(resolves t)) nixpkgsOnly;
in
{
  imports = [ ./nixfs.nix ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          nixfs: ${toString (builtins.length missing)} nixpkgs-only package(s) do not exist in this
          nixpkgs: ${lib.concatStringsSep ", " (map (t: t.nixpkgs) missing)}.

          This is a catalogue problem, not a host problem -- a package was renamed or dropped
          upstream. Fix lib/catalogue.nix so every host gets the correction, rather than pinning
          an older nixpkgs or omitting the entry on one machine.
        '';
      }
    ];

    environment.systemPackages =
      map (t: lib.getAttrFromPath (path t.nixpkgs) pkgs) (lib.filter resolves nixpkgsOnly);
  };
}
