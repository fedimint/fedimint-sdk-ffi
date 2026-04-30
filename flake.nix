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

        fenixPkgs = fenix.packages.${system};
        baseToolchain = fenixPkgs.stable.toolchain;

        mkToolchain =
          targets:
          fenixPkgs.combine ([ baseToolchain ] ++ map (t: fenixPkgs.targets.${t}.stable.rust-std) targets);

        # Keep .c, .toml (uniffi.toml, uniffi-android.toml), and .udl alongside
        # Rust sources. craneLib.cleanCargoSource on its own would strip these.
        mkSrc =
          craneLib:
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

        # Convert `aarch64-linux-android` -> `AARCH64_LINUX_ANDROID` (cargo env-var form)
        upperUnderscore = t: pkgs.lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] t);
        # Convert `aarch64-linux-android` -> `aarch64_linux_android` (cc/bindgen env-var form)
        lowerUnderscore = t: builtins.replaceStrings [ "-" ] [ "_" ] t;

        ##############
        # Android
        ##############

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

        androidRustTargets = [
          "aarch64-linux-android"
          "armv7-linux-androideabi"
          "i686-linux-android"
          "x86_64-linux-android"
        ];

        androidToolchain = mkToolchain androidRustTargets;
        androidCraneLib = (crane.mkLib pkgs).overrideToolchain androidToolchain;
        androidSrc = mkSrc androidCraneLib;

        androidApiLevel = "24";

        # NDK clang is invoked as `<triple><api>-clang`. The armv7 rust target
        # `armv7-linux-androideabi` maps to NDK triple `armv7a-linux-androideabi`.
        ndkClangFor =
          rustTarget:
          let
            ndkTriple =
              if rustTarget == "armv7-linux-androideabi" then "armv7a-linux-androideabi" else rustTarget;
          in
          "${ndkToolchain}/bin/${ndkTriple}${androidApiLevel}-clang";
        ndkClangxxFor = rustTarget: "${ndkClangFor rustTarget}++";

        androidBindgenArgs = ''--sysroot=${ndkToolchain}/sysroot -I${ndkToolchain}/sysroot/usr/include'';

        androidCommonEnv = {
          ANDROID_NDK_ROOT = ndkRoot;
          ANDROID_NDK_HOME = ndkRoot;
          NDK_HOME = ndkRoot;
          ROCKSDB_STATIC = "1";
          SNAPPY_STATIC = "1";
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
          CLANG_PATH = "${ndkToolchain}/bin/clang";
        };

        androidPerTargetEnv =
          rustTarget:
          let
            U = upperUnderscore rustTarget;
            l = lowerUnderscore rustTarget;
            cc = ndkClangFor rustTarget;
          in
          {
            "CARGO_TARGET_${U}_LINKER" = cc;
            "CARGO_TARGET_${U}_AR" = "${ndkToolchain}/bin/llvm-ar";
            "CC_${l}" = cc;
            "CXX_${l}" = ndkClangxxFor rustTarget;
            "AR_${l}" = "${ndkToolchain}/bin/llvm-ar";
            "RANLIB_${l}" = "${ndkToolchain}/bin/llvm-ranlib";
            "BINDGEN_EXTRA_CLANG_ARGS_${l}" = androidBindgenArgs;
          };

        buildAndroidTarget =
          rustTarget:
          androidCraneLib.buildPackage (
            androidCommonEnv
            // (androidPerTargetEnv rustTarget)
            // {
              src = androidSrc;
              pname = "fedimint-client-uniffi-${rustTarget}";
              version = "0.1.0";
              cargoExtraArgs = "--locked --target ${rustTarget} --lib";
              CARGO_BUILD_TARGET = rustTarget;
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
        androidAbiOf = rustTarget:
          {
            "aarch64-linux-android" = "arm64-v8a";
            "armv7-linux-androideabi" = "armeabi-v7a";
            "i686-linux-android" = "x86";
            "x86_64-linux-android" = "x86_64";
          }
          .${rustTarget};

        # Targets we actually ship (matches ubrn.config.yaml). The fenix
        # toolchain has all four wired so adding more is one line below.
        androidShipped = [
          "aarch64-linux-android"
          "x86_64-linux-android"
        ];

        androidPerTargetBuilds = pkgs.lib.genAttrs androidShipped buildAndroidTarget;

        androidJniLibs = pkgs.runCommand "fedimint-uniffi-android-jniLibs" { } ''
          mkdir -p $out/jniLibs
          ${pkgs.lib.concatMapStringsSep "\n" (t: ''
            mkdir -p $out/jniLibs/${androidAbiOf t}
            cp ${androidPerTargetBuilds.${t}}/lib/libfedimint_client_uniffi.so $out/jniLibs/${androidAbiOf t}/
          '') androidShipped}
        '';

        ##############
        # iOS (darwin only)
        #
        # iOS builds require Apple SDKs and Xcode, which Nix cannot redistribute.
        # We mark the derivations `__noChroot = true` so they can read
        # /usr/bin/* and /Applications/Xcode.app from the host. This requires
        # the Nix daemon to allow relaxed sandboxing
        # (`sandbox = relaxed` in nix.conf, or building with
        # `--option sandbox relaxed`). The same pattern is used by the
        # `xcode-wrapper` derivation in fedimint-sdk's flake.nix.
        ##############

        iosRustTargets = [
          "aarch64-apple-ios"
          "aarch64-apple-ios-sim"
          "x86_64-apple-ios"
        ];

        iosToolchain = mkToolchain iosRustTargets;
        iosCraneLib = (crane.mkLib pkgs).overrideToolchain iosToolchain;
        iosSrc = mkSrc iosCraneLib;

        # Shared impure-build env. xcrun is invoked at build time to discover
        # the iPhoneOS / iPhoneSimulator SDK paths so bindgen can find headers.
        iosCommonEnv = {
          __noChroot = true;
          IPHONEOS_DEPLOYMENT_TARGET = "15.0";
          MACOSX_DEPLOYMENT_TARGET = "15.0";
          # Force aws-lc-sys / cc-rs to use system clang, never any Homebrew LLVM.
          CC = "/usr/bin/clang";
          CXX = "/usr/bin/clang++";
          AR = "/usr/bin/ar";
          # Build scripts (build.rs binaries) are compiled and linked for the
          # darwin host arch. On macOS 14+ libiconv ships only inside the
          # Apple SDKs (not /usr/lib), so a bare `cc -liconv` from the Nix
          # sandbox can't find it. Add Nix's libiconv to RUSTFLAGS for the
          # darwin host targets only -- iOS cross-compile targets must NOT
          # see this lib path because Nix's libiconv is darwin Mach-O and
          # would mismatch the iOS arch.
          CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS = "-L${pkgs.libiconv}/lib";
          CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS = "-L${pkgs.libiconv}/lib";
          # Per-target compilers route through xcrun (set in preBuild below).
          # See iosShellHook in fedimint-sdk's flake.nix for the original recipe.
          preBuild = ''
            export PATH=/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
            export CLANG_PATH="$(xcrun --find clang)"

            IOS_SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
            SIM_SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"

            export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="--sysroot=$IOS_SDKROOT"
            export BINDGEN_EXTRA_CLANG_ARGS_x86_64_apple_ios="--sysroot=$SIM_SDKROOT"
            # aws-lc-sys bundles an older bindgen that passes
            # "aarch64-apple-ios-sim" to clang, but clang expects
            # "aarch64-apple-ios-simulator". Override the target explicitly.
            # See: https://github.com/rust-lang/rust-bindgen/pull/3182
            export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="--sysroot=$SIM_SDKROOT --target=arm64-apple-ios-simulator"

            # Per-target CC/CXX so cc-rs invokes the right compiler driver.
            for t in aarch64_apple_ios aarch64_apple_ios_sim x86_64_apple_ios; do
              eval "export CC_$t=/usr/bin/clang"
              eval "export CXX_$t=/usr/bin/clang++"
            done
          '';
        };

        buildIosTarget =
          rustTarget:
          iosCraneLib.buildPackage (
            iosCommonEnv
            // {
              src = iosSrc;
              pname = "fedimint-client-uniffi-${rustTarget}";
              version = "0.1.0";
              cargoExtraArgs = "--locked --target ${rustTarget} --lib";
              CARGO_BUILD_TARGET = rustTarget;
              doCheck = false;
              strictDeps = true;
              nativeBuildInputs = [
                pkgs.cmake
                pkgs.perl
                pkgs.python3
                pkgs.go
              ];
            }
          );

        iosPerTargetBuilds = pkgs.lib.genAttrs iosRustTargets buildIosTarget;

        # Layout matches what `xcodebuild -create-xcframework` consumes:
        #   ios-arm64/                      device slice (aarch64-apple-ios)
        #   ios-arm64_x86_64-simulator/    fat sim slice (aarch64-sim + x86_64-sim)
        # The xcframework wrap itself stays in ubrn so it can include the
        # uniffi-generated module map and headers.
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
          // pkgs.lib.mapAttrs' (t: drv: pkgs.lib.nameValuePair "android-${t}" drv) androidPerTargetBuilds
          // pkgs.lib.optionalAttrs pkgs.stdenv.isDarwin (
            {
              iosBundle = iosBundle;
            }
            // pkgs.lib.mapAttrs' (t: drv: pkgs.lib.nameValuePair "ios-${t}" drv) iosPerTargetBuilds
          );

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
