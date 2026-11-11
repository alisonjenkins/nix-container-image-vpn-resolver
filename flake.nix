{
  description = "Leak-proof DNS resolver container: Unbound inside a WireGuard-only network namespace, built with Nix";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux"] (system: let
      pkgs = import inputs.nixpkgs {inherit system;};

      script = name: runtimeInputs: text:
        pkgs.writeShellApplication {inherit name runtimeInputs text;};

      setup = script "vpn-resolver-setup" (with pkgs; [
        coreutils
        gawk
        gnugrep
        iproute2
        nftables
        wireguard-go
        wireguard-tools
      ]) (builtins.readFile ./scripts/setup.sh);

      watchdog = script "vpn-resolver-watchdog" (with pkgs; [
        coreutils
        gawk
        iproute2
        wireguard-tools
      ]) (builtins.readFile ./scripts/watchdog.sh);

      check = script "vpn-resolver-check" (with pkgs; [
        dnsutils
        gnugrep
      ]) (builtins.readFile ./scripts/check.sh);

      entrypoint = script "vpn-resolver-entrypoint" [
        setup
        watchdog
        pkgs.coreutils
        pkgs.iproute2
        pkgs.unbound
      ] (builtins.replaceStrings ["@rootKey@" "@caBundle@"] [
        "${pkgs.dns-root-data}/root.key"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ] (builtins.readFile ./scripts/entrypoint.sh));

      tools = pkgs.buildEnv {
        name = "vpn-resolver-tools";
        paths = [
          setup
          watchdog
          check
          entrypoint
          # Handy for `kubectl exec` debugging inside the pod.
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.dnsutils
          pkgs.iproute2
          pkgs.nftables
          pkgs.unbound
          pkgs.wireguard-tools
        ];
      };

      container = pkgs.dockerTools.buildLayeredImage {
        name = "vpn-resolver";
        tag = "latest";
        contents = [
          tools
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.fakeNss
        ];
        extraCommands = ''
          mkdir -p run tmp var/lib/unbound var/run
          chmod 1777 tmp
        '';
        config = {
          Entrypoint = ["/bin/vpn-resolver-entrypoint"];
          Env = ["PATH=/bin"];
        };
      };

      # End-to-end leak test using network namespaces and userspace WireGuard.
      # Needs root: `nix build .#netns-test && sudo ./result/bin/netns-test`.
      netns-test = script "netns-test" (with pkgs; [
        coreutils
        dnsutils
        gnugrep
        iproute2
        nftables
        procps
        util-linux
        unbound
        wireguard-go
        wireguard-tools
        entrypoint
        check
      ]) (builtins.readFile ./tests/netns-test.sh);
    in {
      packages = {
        inherit container tools netns-test;
        default = container;
      };

      # Building the scripts runs shellcheck over every one of them.
      checks = {inherit setup watchdog check entrypoint netns-test;};

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [just podman skopeo shellcheck];
      };
    });
}
