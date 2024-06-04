{
  inputs = {
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";
    haskell-nix.url = "github:input-output-hk/haskell.nix";
    flake-utils.url = "github:numtide/flake-utils";

    gentle-introduction.url = "http://oleg.fi/gentle-introduction-2022.5.tar.gz";
    gentle-introduction.flake = false;

    warp.url = "https://github.com/phadej/warp-wo-x509/releases/download/v3.3.17/warp-3.3.17.tar.gz";
    warp.flake = false;

    hooglite.url = "https://github.com/phadej/hooglite/releases/download/v0.20211229/hooglite-0.20211229.tar.gz";
    hooglite.flake = false;
  };

  outputs = { self, nixpkgs, haskell-nix, flake-utils, gentle-introduction, warp, hooglite }:
    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; inherit (haskell-nix) config; overlays = [haskell-nix.overlay]; };
      project = pkgs.haskell-nix.cabalProject {
        src = ./.;
        compiler-nix-name = "ghc8107";
        index-state = "2022-07-19T00:00:00Z";
        inputMap = {
          "http://oleg.fi/gentle-introduction-2022.5.tar.gz" = gentle-introduction;
        };
      };
    in {
      packages.default = project.cabal-docspec.components.exes.cabal-docspec;
    });

  nixConfig = {
    extra-substituters = [
      "https://cache.iohk.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
  };
}
