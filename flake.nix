{
  description = "The filesystem, block-layer and recovery toolchain as one declared fact per host -- resolved per platform (nixpkgs on NixOS, pacman/AUR on Arch, nixpkgs only where Arch has nothing) so the tools you reach for when a disk is failing are actually reachable everywhere.";

  inputs = {
    # Used by `checks` only. The modules take `pkgs` from the consuming evaluation and never
    # reference this input, so a consumer that does not follow it pays no second nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    system-manager.url = "github:numtide/system-manager";
    system-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      # ONLY THE SYSTEM THESE CHECKS CAN GENUINELY BE BUILT ON, which is the narrower claim and the
      # honest one. Every check below is a real derivation, and an aarch64-linux derivation cannot
      # be built by an x86_64 runner, so declaring aarch64 bought no coverage whatsoever: a bare
      # `nix flake check` answered with "The check omitted these incompatible systems:
      # aarch64-linux" and exited 0, and CI reported green having evaluated half of what this flake
      # claimed -- including the both-channels guard this repo says CI enforces.
      #
      # Keeping aarch64 and dropping `--all-systems` is the worse trade and the one this family
      # refuses. Narrow the claim, keep the check strict -- see .github/workflows/ci.yml.
      #
      # Nothing else narrows: the modules take `pkgs` from the consuming evaluation and the
      # catalogue is plain data, so a consumer resolves this on whatever platform it runs. Only
      # `checks` and `formatter` were ever system-scoped here.
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # Policy only: the option surface and the resolved selection, installing nothing. Import this
      # if you want `nixfs.packageNames` and intend to wire it somewhere yourself.
      nixosModules.policy = ./modules/nixfs.nix;
      systemManagerModules.policy = ./modules/nixfs.nix;

      # Two different backends now, resolved per platform -- see modules/nixfs.nix's header for
      # why "one file, both backends" was tried first and abandoned.
      nixosModules.nixfs = ./modules/install.nix;
      nixosModules.default = self.nixosModules.nixfs;
      systemManagerModules.nixfs = ./modules/arch.nix;
      systemManagerModules.default = self.systemManagerModules.nixfs;

      # The catalogue and its resolution, exposed so a consumer can inspect or validate them
      # without re-reading the files.
      lib.catalogue = import ./lib/catalogue.nix { };
      lib.resolve = import ./lib/resolve.nix { inherit lib; };

      # Every filesystem the catalogue knows, for the hosts that want the lot. Exported rather
      # than left to each consumer to hand-copy, so a format added here reaches them on the next
      # lock bump instead of silently missing from a list somebody typed once:
      #
      #   nixfs.filesystems = inputs.nixfs.lib.allFilesystems;
      lib.allFilesystems = lib.attrNames (import ./lib/catalogue.nix { }).filesystems;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixosModule = self.nixosModules.nixfs;
          archModule = self.systemManagerModules.nixfs;
          systemManagerLib = system-manager.lib;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
