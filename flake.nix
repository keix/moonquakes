{
  description = "Zig 0.15.2 Dev Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zigpkgs.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zigpkgs }:
    flake-utils.lib.eachSystem [
      "x86_64-linux" "aarch64-linux" "aarch64-darwin"
    ] (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ zigpkgs.overlays.default ];
      };
    in {
      devShells.default = pkgs.mkShell {
        name = "zig-0.15.2-shell";

        packages = [
          pkgs.zigpkgs."0.15.2"
        ];

        shellHook = ''
          echo "Zig DevShell loaded (${system})"
          echo "  zig: $(zig version)"
        '';
      };
    }
  );
}
