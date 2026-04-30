{
  description = "Fedimint SDK FFI - uniffi bindings for fedimint-client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flakebox = {
      url = "github:rustshop/flakebox";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.fenix.follows = "fenix";
    };
    android-nixpkgs = {
      url = "github:tadfisher/android-nixpkgs/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fenix,
      flakebox,
      android-nixpkgs,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };
        lib = pkgs.lib;
        stdenv = pkgs.stdenv;

        # Android SDK + NDK 27.1 (matching what fedimint-sdk's dev shell uses).
        androidSdk = android-nixpkgs.sdk."${system}" (
          sdkPkgs: with sdkPkgs; [
            cmdline-tools-latest
            build-tools-36-0-0
            platform-tools
            platforms-android-36
            ndk-27-1-12297006
          ]
        );

        flakeboxLib = flakebox.lib.mkLib pkgs {
          config = {
            toolchain.channel = "stable";
            github.ci.enable = false;
            typos.pre-commit.enable = false;
          };
        };

        # `mkStdTargets` provides target descriptors (mkIOSTarget for ios-*,
        # mkAndroidTarget for android-*, etc.) that wire up the right
        # CC/AR/LINKER/RUSTFLAGS env vars per cargo target triple.
        # Each entry is a lambda; calling it with `{}` materialises
        # `{ args, componentTargets }`.
        stdTargets = flakeboxLib.mkStdTargets {
          inherit androidSdk;
        };

        # Fenix toolchain combining all the cross-compile std libraries we
        # need (host + android + ios on darwin).
        toolchain = flakeboxLib.mkFenixToolchain {
          components = [
            "rustc"
            "cargo"
            "rust-src"
          ];
          targets = lib.getAttrs (
            [
              "default"
              "aarch64-android"
              "armv7-android"
              "i686-android"
              "x86_64-android"
            ]
            ++ lib.optionals stdenv.isDarwin [
              "aarch64-ios"
              "aarch64-ios-sim"
              "x86_64-ios"
            ]
          ) stdTargets;
        };

        craneLib = toolchain.craneLib;

        # Keep .c, .toml (uniffi.toml, uniffi-android.toml), and .udl alongside
        # Rust sources. craneLib.cleanCargoSource on its own would strip these.
        src =
          let
            crateDir = ./fedimint-client-uniffi;
            keepExtras =
              path: _type:
              let
                base = baseNameOf path;
              in
              base == "sdallocx_stub.c"
              || base == "uniffi.toml"
              || base == "uniffi-android.toml"
              || lib.hasSuffix ".udl" path;
            filter = path: type: (keepExtras path type) || (craneLib.filterCargoSources path type);
          in
          lib.cleanSourceWith {
            src = crateDir;
            inherit filter;
            name = "source";
          };

        # Symlink-only derivation that exposes /usr/bin/* and the
        # Xcode.app dirs to the Nix build sandbox. Same pattern fedi uses
        # for their `nix develop .#xcode` shell. `__noChroot = true` so
        # the symlink targets are accessible at build time; this requires
        # the Nix daemon to allow relaxed sandboxing
        # (`sandbox = relaxed` in nix.conf or `--option sandbox relaxed`).
        xcode-wrapper = pkgs.runCommand "xcode-wrapper-impure" { __noChroot = true; } ''
          mkdir -p $out/bin
          ln -s /usr/bin/ld $out/bin/ld
          ln -s /usr/bin/clang $out/bin/clang
          ln -s /usr/bin/clang++ $out/bin/clang++
          ln -s /usr/bin/cc $out/bin/cc
          ln -s /usr/bin/c++ $out/bin/c++
          ln -s /usr/bin/ar $out/bin/ar
          ln -s /usr/bin/xcrun $out/bin/xcrun
          ln -s /usr/bin/xcode-select $out/bin/xcode-select
          ln -s /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild $out/bin/xcodebuild
        '';

        # Build the crate for a single (rustTarget, targetKey) pair.
        # `targetKey` is the flakebox-stdTargets key (e.g. `aarch64-ios`),
        # `rustTarget` is the Cargo triple (e.g. `aarch64-apple-ios`).
        buildOne =
          {
            targetKey,
            rustTarget,
            isIos ? false,
          }:
          let
            target = stdTargets.${targetKey} { };
          in
          craneLib.buildPackage (
            target.args
            // (lib.optionalAttrs stdenv.isDarwin {
              # nixpkgs' stdenv walks `buildInputs` and adds each `/lib` to
              # the cc-wrapper's NIX_LDFLAGS. Putting libiconv here is what
              # makes `cc -liconv` resolve in the host build-script link
              # step on macOS 14+ (where iconv lives only in the Apple SDK).
              # iOS cross-compile linker invocations also see this path but
              # harmlessly skip the wrong-arch Mach-O lib (with a warning)
              # and resolve via the SDK paths supplied by mkIOSTarget.
              buildInputs = [ pkgs.libiconv ];
            })
            // (lib.optionalAttrs isIos {
              # iOS cross-compile reads /Applications/Xcode.app and /usr/bin
              # via the xcode-wrapper symlinks; this requires relaxed
              # sandboxing.
              __noChroot = true;
              IPHONEOS_DEPLOYMENT_TARGET = "15.0";
              MACOSX_DEPLOYMENT_TARGET = "15.0";

              # nixpkgs' darwin stdenv sets SDKROOT to its bundled
              # apple-sdk-11 (a macOS SDK) and points DEVELOPER_DIR into
              # the Nix store. When cc-rs's build script runs
              # `xcrun --sdk iphoneos --show-sdk-path` to find the
              # iPhoneOS SDK, those Nix-store paths confuse xcrun and it
              # exits 255. Reset to the real /Applications/Xcode.app so
              # xcrun resolves SDKs via xcode-select.
              #
              # Mirrors fedimint-sdk's iosShellHook + fedi's xcode dev shell.
              preBuild = ''
                unset SDKROOT
                unset NIX_CFLAGS_COMPILE
                unset NIX_LDFLAGS
                export PATH=/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH
                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
              '';
            })
            // {
              inherit src;
              pname = "fedimint-client-uniffi-${rustTarget}";
              version = "0.1.0";
              cargoExtraArgs = "--locked --target ${rustTarget} --lib";
              CARGO_BUILD_TARGET = rustTarget;
              doCheck = false;
              strictDeps = true;
              # rocksdb needs cmake; aws-lc-sys needs cmake + perl + go.
              # python3 is needed by some ring/aws-lc generation scripts.
              nativeBuildInputs =
                (target.args.nativeBuildInputs or [ ])
                ++ [
                  pkgs.cmake
                  pkgs.pkg-config
                  pkgs.perl
                  pkgs.python3
                  pkgs.go
                ]
                ++ lib.optionals isIos [ xcode-wrapper ];
            }
          );

        ##############
        # Android
        ##############

        # Targets we actually ship .so files for (matches ubrn.config.yaml
        # in fedimint-sdk). The toolchain has more wired up so adding more
        # is one entry per row below.
        androidShipped = [
          {
            targetKey = "aarch64-android";
            rustTarget = "aarch64-linux-android";
            abi = "arm64-v8a";
          }
          {
            targetKey = "x86_64-android";
            rustTarget = "x86_64-linux-android";
            abi = "x86_64";
          }
        ];

        androidPerTargetBuilds = lib.listToAttrs (
          map (t: lib.nameValuePair t.rustTarget (buildOne {
            inherit (t) targetKey rustTarget;
          })) androidShipped
        );

        androidJniLibs = pkgs.runCommand "fedimint-uniffi-android-jniLibs" { } ''
          mkdir -p $out/jniLibs
          ${lib.concatMapStringsSep "\n" (t: ''
            mkdir -p $out/jniLibs/${t.abi}
            cp ${androidPerTargetBuilds.${t.rustTarget}}/lib/libfedimint_client_uniffi.so \
               $out/jniLibs/${t.abi}/
          '') androidShipped}
        '';

        ##############
        # iOS (darwin only)
        ##############

        iosShipped = [
          {
            targetKey = "aarch64-ios";
            rustTarget = "aarch64-apple-ios";
          }
          {
            targetKey = "aarch64-ios-sim";
            rustTarget = "aarch64-apple-ios-sim";
          }
          {
            targetKey = "x86_64-ios";
            rustTarget = "x86_64-apple-ios";
          }
        ];

        iosPerTargetBuilds = lib.listToAttrs (
          map (t: lib.nameValuePair t.rustTarget (buildOne {
            inherit (t) targetKey rustTarget;
            isIos = true;
          })) iosShipped
        );

        # Layout matches what `xcodebuild -create-xcframework` consumes:
        #   ios-arm64/                      device slice (aarch64-apple-ios)
        #   ios-arm64_x86_64-simulator/    fat sim slice (lipo'd)
        # The xcframework wrap stays in ubrn so the uniffi-generated
        # module map and headers can be folded in there.
        iosBundle = pkgs.runCommand "fedimint-uniffi-ios-libs" {
          __noChroot = true;
        } ''
          export PATH=/usr/bin:$PATH
          mkdir -p $out/ios-arm64
          cp ${iosPerTargetBuilds."aarch64-apple-ios"}/lib/libfedimint_client_uniffi.a \
             $out/ios-arm64/

          mkdir -p $out/ios-arm64_x86_64-simulator
          /usr/bin/lipo -create \
            ${iosPerTargetBuilds."aarch64-apple-ios-sim"}/lib/libfedimint_client_uniffi.a \
            ${iosPerTargetBuilds."x86_64-apple-ios"}/lib/libfedimint_client_uniffi.a \
            -output $out/ios-arm64_x86_64-simulator/libfedimint_client_uniffi.a
        '';

      in
      {
        packages =
          {
            androidBundle = androidJniLibs;
          }
          // lib.mapAttrs' (t: drv: lib.nameValuePair "android-${t}" drv) androidPerTargetBuilds
          // lib.optionalAttrs stdenv.isDarwin (
            { iosBundle = iosBundle; }
            // lib.mapAttrs' (t: drv: lib.nameValuePair "ios-${t}" drv) iosPerTargetBuilds
          );

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            toolchain.toolchain
            androidSdk
          ];
        };
      }
    );
}
