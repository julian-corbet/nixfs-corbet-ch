#
# The NixOS backend: resolve nixfs's selection into environment.systemPackages, entirely from
# nixpkgs.
#
# NixOS has no second package manager to lose a `PATH` race against, so every selected entry --
# including the ones ../lib/catalogue.nix also names an Arch package for -- comes from nixpkgs here,
# unconditionally. That is NOT the same choice ../modules/arch.nix makes: on Arch, installing an
# entry that already has a pacman name would shadow-or-be-shadowed by the distro's own copy (see
# ../lib/catalogue.nix's header for the live evidence), so that backend installs only the entries
# with no Arch package at all. This file has no such hazard to avoid, which is why it stays the
# simpler "everything from nixpkgs" backend it always was.
#
# A MISSING ATTRIBUTE IS A BUILD FAILURE, NOT A WARNING. nixdev warns and continues, correctly:
# some of its entries genuinely have no nixpkgs equivalent, so a warning is the honest report. No
# entry here is optional -- every one was asked for, and nixpkgs does drop packages (ReiserFS
# tooling went when the kernel dropped the filesystem). A recovery tool that silently stopped
# being installed some months ago, discovered while a disk is dying, is the worst outcome this
# module can produce. So it fails at eval, loudly, with the name in the message.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.nixfs;
  path = name: lib.splitString "." name;
  resolves = name: lib.hasAttrByPath (path name) pkgs;
  missing = lib.filter (n: !(resolves n)) cfg.packageNames;
in
{
  imports = [ ./nixfs.nix ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [ ];
        message = ''
          nixfs: ${toString (builtins.length missing)} selected package(s) do not exist in this
          nixpkgs: ${lib.concatStringsSep ", " missing}.

          This is a catalogue problem, not a host problem -- a package was renamed or dropped
          upstream. Fix lib/catalogue.nix so every host gets the correction, rather than pinning
          an older nixpkgs or omitting the entry on one machine.
        '';
      }
    ];

    environment.systemPackages =
      map (n: lib.getAttrFromPath (path n) pkgs) (lib.filter resolves cfg.packageNames);
  };
}
