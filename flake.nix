{
  description = "The filesystem, block-layer and recovery toolchain as one declared fact per host -- pinned from nixpkgs on NixOS and non-NixOS hosts alike, so the tools you reach for when a disk is failing are the same everywhere.";

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
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ---------------------------------------------------------------
      # Policy only: the option surface and the resolved selection,
      # installing nothing. Import this if you want `nixfs.packageNames`
      # and intend to wire it somewhere yourself.
      # ---------------------------------------------------------------
      nixosModules.policy = ./modules/nixfs.nix;
      systemManagerModules.policy = ./modules/nixfs.nix;

      # ---------------------------------------------------------------
      # The same file on both backends -- not a convenience, the whole
      # point. nixfs resolves to nixpkgs on every host regardless of the
      # host's own distro, so there is no platform-specific installer to
      # write and nothing for the two sides to disagree about. See
      # modules/install.nix and lib/catalogue.nix for why recovery
      # tooling in particular is worth paying a duplicate copy for.
      # ---------------------------------------------------------------
      nixosModules.nixfs = ./modules/install.nix;
      nixosModules.default = self.nixosModules.nixfs;
      systemManagerModules.nixfs = ./modules/install.nix;
      systemManagerModules.default = self.systemManagerModules.nixfs;

      # The catalogue and the tier table, exposed so a consumer can inspect or validate them
      # without re-reading the files.
      lib.catalogue = import ./lib/catalogue.nix { };
      lib.media = import ./media.nix;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixfsModule = self.nixosModules.nixfs;
          systemManagerLib = system-manager.lib;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
