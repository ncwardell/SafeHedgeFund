{
  description = "SafeHedgeFund — Gnosis Safe hedge fund vault dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Pinned foundry build (forge / cast / anvil / chisel)
    foundry = {
      url = "github:shazow/foundry.nix/monthly";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, foundry }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ foundry.overlay ];
        };

        contractTools = with pkgs; [
          foundry-bin
          solc
          jq
          git
        ];

        portalTools = with pkgs; [
          bun
          nodejs_20
        ];
      in {
        devShells.default = pkgs.mkShell {
          name = "safe-hedgefund";

          packages = contractTools ++ portalTools;

          shellHook = ''
            export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

            cat <<'EOF'
            ┌─ SafeHedgeFund dev shell ─────────────────────────────────────┐
            │                                                                │
            │  Contracts (Foundry):                                          │
            │    forge install        # one-time, fetches OZ deps            │
            │    forge build                                                 │
            │    forge test -vvv                                             │
            │                                                                │
            │  Portal (Bun):                                                 │
            │    cd portal && bun install && bun run dev                     │
            │                                                                │
            └────────────────────────────────────────────────────────────────┘
            EOF
          '';
        };

        # `nix fmt`
        formatter = pkgs.nixpkgs-fmt;
      });
}
