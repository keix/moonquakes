{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zigpkgs.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zigpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [ zigpkgs.overlays.default ];
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.zigpkgs."0.15.2"
      ];
    };
  };
}