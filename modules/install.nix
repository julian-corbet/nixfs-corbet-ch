#
# The backend: resolve nixfs's selection into environment.systemPackages.
#
# ONE BACKEND, BOTH PLATFORMS. The sibling toolbox module (nixdev) needs two backends, because on
# a distro-managed host it has no installer of its own and can only publish a package list for
# that host's reconciler to consume. nixfs has no such split: it resolves to nixpkgs everywhere by
# design (see lib/catalogue.nix for why recovery tooling is the one toolchain worth pinning
# identically across distros), and `environment.systemPackages` is understood by both NixOS and
# system-manager. So this file is exported unchanged as both `nixosModules.default` and
# `systemManagerModules.default`, and a host reads the same either way.
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
