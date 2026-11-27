{
  description = "zmux: tmux-style PTY session multiplexer with JSON-RPC over UNIX sockets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      zmuxVersion = "0.4.0";

      mkPackages =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          src = lib.cleanSourceWith {
            src = ./.;
            filter =
              path: type:
              let
                base = baseNameOf (toString path);
              in
              !(
                base == ".git"
                || base == ".jj"
                || base == ".zig-cache"
                || base == "zig-out"
                || base == "dist"
                || base == "node_modules"
              );
          };

          commonMeta = {
            homepage = "https://github.com/smithersai/zmux";
            license = lib.licenses.mit;
            platforms = supportedSystems;
          };

          zmuxBundle = pkgs.stdenv.mkDerivation {
            pname = "zmux";
            version = zmuxVersion;
            inherit src;

            nativeBuildInputs = [ pkgs.zig ];

            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
              zig build -Doptimize=ReleaseSafe --prefix "$out"
              runHook postBuild
            '';

            doCheck = false;

            meta = commonMeta // {
              description = "tmux-style PTY session multiplexer with JSON-RPC over UNIX sockets";
              mainProgram = "zmux";
            };
          };

          zmuxdPkg = pkgs.runCommand "zmuxd-${zmuxVersion}" {
            meta = commonMeta // {
              description = "zmux long-lived PTY session multiplexer daemon";
              mainProgram = "zmuxd";
            };
          } ''
            mkdir -p "$out/bin"
            ln -s "${zmuxBundle}/bin/zmuxd" "$out/bin/zmuxd"
            if [ -e "${zmuxBundle}/bin/smithers-session-daemon" ]; then
              ln -s "${zmuxBundle}/bin/smithers-session-daemon" "$out/bin/smithers-session-daemon"
            fi
          '';

          zmuxConnectPkg = pkgs.runCommand "zmux-connect-${zmuxVersion}" {
            meta = commonMeta // {
              description = "zmux terminal attachment client";
              mainProgram = "zmux-connect";
            };
          } ''
            mkdir -p "$out/bin"
            ln -s "${zmuxBundle}/bin/zmux-connect" "$out/bin/zmux-connect"
            if [ -e "${zmuxBundle}/bin/smithers-session-connect" ]; then
              ln -s "${zmuxBundle}/bin/smithers-session-connect" "$out/bin/smithers-session-connect"
            fi
          '';
        in
        {
          default = zmuxBundle;
          zmux = zmuxBundle;
          zmuxd = zmuxdPkg;
          zmux-connect = zmuxConnectPkg;
        };
    in
    {
      packages = forAllSystems mkPackages;

      apps = forAllSystems (
        system:
        let
          pkgsForSystem = self.packages.${system};
        in
        {
          default = {
            type = "app";
            program = "${pkgsForSystem.zmux}/bin/zmux";
          };
          zmux = {
            type = "app";
            program = "${pkgsForSystem.zmux}/bin/zmux";
          };
          zmuxd = {
            type = "app";
            program = "${pkgsForSystem.zmuxd}/bin/zmuxd";
          };
          zmux-connect = {
            type = "app";
            program = "${pkgsForSystem.zmux-connect}/bin/zmux-connect";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            name = "zmux-dev";
            packages = [
              pkgs.zig
              pkgs.jujutsu
              pkgs.python3
              pkgs.nodejs
              pkgs.pkg-config
            ]
            ++ pkgs.lib.optionals (pkgs ? bun) [ pkgs.bun ];

            shellHook = ''
              echo "zmux devShell ready (zig $(zig version), requires Zig 0.17.x)"
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
