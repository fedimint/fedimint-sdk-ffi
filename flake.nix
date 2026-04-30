{
  description = "Fedimint SDK FFI - uniffi bindings for fedimint-client";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fenix,
      crane,
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

        ndkVersion = "27.1.12297006";

        androidSdk = pkgs.androidenv.composeAndroidPackages {
          includeNDK = true;
          ndkVersions = [ ndkVersion ];
          buildToolsVersions = [ "36.0.0" ];
          platformVersions = [ "36" ];
          abiVersions = [
            "arm64-v8a"
            "x86_64"
          ];
          cmdLineToolsVersion = "13.0";
          toolsVersion = "26.1.1";
          includeSystemImages = true;
        };

        ndkRoot = "${androidSdk.androidsdk}/libexec/android-sdk/ndk/${ndkVersion}";
        hostTag =
          if pkgs.stdenv.isDarwin then
            (if pkgs.stdenv.isAarch64 then "darwin-arm64" else "darwin-x86_64")
          else
            "linux-x86_64";
        ndkToolchain = "${ndkRoot}/toolchains/llvm/prebuilt/${hostTag}";

        fenixPkgs = fenix.packages.${system};
        baseToolchain = fenixPkgs.stable.toolchain;

        androidRustTargets = [
          "aarch64-linux-android"
          "armv7-linux-androideabi"
          "i686-linux-android"
          "x86_64-linux-android"
        ];

        androidToolchain = fenixPkgs.combine (
          [ baseToolchain ] ++ map (t: fenixPkgs.targets.${t}.stable.rust-std) androidRustTargets
        );

        craneLib = (crane.mkLib pkgs).overrideToolchain androidToolchain;

        # Keep .c, .toml (uniffi.toml, uniffi-android.toml), and .udl alongside Rust sources.
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
              || pkgs.lib.hasSuffix ".udl" path;
            filter = path: type: (keepExtras path type) || (craneLib.filterCargoSources path type);
          in
          pkgs.lib.cleanSourceWith {
            src = crateDir;
            inherit filter;
            name = "source";
          };

        # Android API level to link against
        androidApiLevel = "24";

        # Per-target NDK linker/cc/ar configuration.
        # NDK clang is invoked as `<triple><api>-clang`. Note the armv7 triple is
        # remapped: rust target is `armv7-linux-androideabi` but NDK uses
        # `armv7a-linux-androideabi<api>-clang`.
        ndkClangFor =
          rustTarget:
          let
            ndkTriple =
              if rustTarget == "armv7-linux-androideabi" then "armv7a-linux-androideabi" else rustTarget;
          in
          "${ndkToolchain}/bin/${ndkTriple}${androidApiLevel}-clang";

        # Convert `aarch64-linux-android` -> `AARCH64_LINUX_ANDROID` (cargo env-var form)
        envForTarget = rustTarget: pkgs.lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] rustTarget);

        # Convert `aarch64-linux-android` -> `aarch64_linux_android` (bindgen/cc env-var form)
        ccEnvForTarget = rustTarget: builtins.replaceStrings [ "-" ] [ "_" ] rustTarget;

        # Find the bundled clang headers dir under the toolchain.
        # NDK 27 ships these under lib/clang/<ver>/include.
        bindgenSysrootArgs = ''--sysroot=${ndkToolchain}/sysroot -I${ndkToolchain}/sysroot/usr/include'';

        # Common environment for any android cargo build.
        androidCommonEnv = {
          ANDROID_NDK_ROOT = ndkRoot;
          ANDROID_NDK_HOME = ndkRoot;
          NDK_HOME = ndkRoot;
          ROCKSDB_STATIC = "1";
          SNAPPY_STATIC = "1";
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
          # Ensure bindgen invocations on cross builds use the NDK clang
          CLANG_PATH = "${ndkToolchain}/bin/clang";
        };

        # Per-target env vars cargo expects for cross compilation.
        perTargetEnv =
          rustTarget:
          let
            UPPER = envForTarget rustTarget; # e.g. AARCH64_LINUX_ANDROID
            lower = ccEnvForTarget rustTarget; # e.g. aarch64_linux_android
            cc = ndkClangFor rustTarget;
          in
          {
            "CARGO_TARGET_${UPPER}_LINKER" = cc;
            "CARGO_TARGET_${UPPER}_AR" = "${ndkToolchain}/bin/llvm-ar";
            "CC_${lower}" = cc;
            "CXX_${lower}" = "${ndkToolchain}/bin/${
              if rustTarget == "armv7-linux-androideabi" then "armv7a-linux-androideabi" else rustTarget
            }${androidApiLevel}-clang++";
            "AR_${lower}" = "${ndkToolchain}/bin/llvm-ar";
            "RANLIB_${lower}" = "${ndkToolchain}/bin/llvm-ranlib";
            "BINDGEN_EXTRA_CLANG_ARGS_${lower}" = bindgenSysrootArgs;
          };

        # Build the cdylib for one target.
        buildOne =
          rustTarget:
          let
            env = androidCommonEnv // (perTargetEnv rustTarget);
          in
          craneLib.buildPackage (
            env
            // {
              inherit src;
              pname = "fedimint-client-uniffi-${rustTarget}";
              version = "0.1.0";
              cargoExtraArgs = "--locked --target ${rustTarget} --lib";
              CARGO_BUILD_TARGET = rustTarget;
              # We only want the cdylib output
              doCheck = false;
              strictDeps = true;
              nativeBuildInputs = [
                pkgs.cmake
                pkgs.pkg-config
                pkgs.perl
                pkgs.python3
                pkgs.libclang
                pkgs.go
              ];
            }
          );

        # Map rust target -> Android ABI dir
        abiOf = rustTarget:
          {
            "aarch64-linux-android" = "arm64-v8a";
            "armv7-linux-androideabi" = "armeabi-v7a";
            "i686-linux-android" = "x86";
            "x86_64-linux-android" = "x86_64";
          }
          .${rustTarget};

        # Targets we actually ship binaries for (matches ubrn.config.yaml).
        shippedTargets = [
          "aarch64-linux-android"
          "x86_64-linux-android"
        ];

        perTargetBuilds = pkgs.lib.genAttrs shippedTargets buildOne;

        androidJniLibs = pkgs.runCommand "fedimint-uniffi-android-jniLibs" { } ''
          mkdir -p $out/jniLibs
          ${pkgs.lib.concatMapStringsSep "\n" (t: ''
            mkdir -p $out/jniLibs/${abiOf t}
            cp ${perTargetBuilds.${t}}/lib/libfedimint_client_uniffi.so $out/jniLibs/${abiOf t}/
          '') shippedTargets}
        '';
      in
      {
        packages = {
          androidBundle = androidJniLibs;
        }
        // pkgs.lib.mapAttrs' (
          t: drv: pkgs.lib.nameValuePair "android-${t}" drv
        ) perTargetBuilds;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            androidToolchain
            pkgs.cargo-ndk
            androidSdk.androidsdk
          ];
        };
      }
    );
}
