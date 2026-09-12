{
  description = "Unsloth Desktop packaging experiment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import nixpkgs {
              inherit system;
            };
          }
        );
    in
    {
      formatter = forAllSystems ({ pkgs }: pkgs.nixfmt-tree);
      packages = forAllSystems (
        { pkgs }: {
          default = pkgs.callPackage ./unsloth-desktop.nix { };
        }
      );
    };
}
