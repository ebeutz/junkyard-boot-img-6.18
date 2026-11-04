{
  description = "Pixel Fold (felix / gs201) Debian boot-img build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Cross-capable Rust toolchains for building tools/pixel-bootctl to aarch64.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems
        (s: f (import nixpkgs { system = s; overlays = [ rust-overlay.overlays.default ]; }));

      # Rust toolchain for cross-building tools/pixel-bootctl + tools/pixel-ota to
      # fully static aarch64-musl binaries. Static musl means zero runtime deps, so
      # the binary runs unchanged on the Debian rootfs regardless of its glibc/loader
      # (an earlier glibc cross-build baked a Nix-store ld-linux path and failed to
      # exec on-device with 203/EXEC). `targets` adds the aarch64-musl std lib
      # alongside the host std — the host std is still needed so clap's proc-macro
      # derive compiles for the build machine. No external C cross-linker is
      # required: .build_pixel_bootctl links via the toolchain's bundled rust-lld,
      # so the same `cargo build` line also works on non-Nix hosts that have
      # rustup's aarch64-unknown-linux-musl target installed.
      #
      # ★ This belongs in buildToolsFor, NOT in devShells.default alone. It lived
      # there, and buildToolsFor is the list that BOTH other entry points use — the
      # `nix run .#build` app and the kernel FHS env. So the one-command build ran an
      # hour of kernel, then died several stages later on a bare
      # "sh: line 2: cargo: not found", while `nix develop` built the same tree
      # fine. It only surfaces when a pixel-* submodule gitlink moves and
      # re-triggers the cross-build, which is why it hid for so long.
      rustToolchainFor = pkgs: pkgs.rust-bin.stable.latest.minimal.override {
        targets = [ "aarch64-unknown-linux-musl" ];
      };

      # Everything the build host needs, grouped by build stage.
      buildToolsFor = pkgs: with pkgs; [
        # --- orchestration ---
        just
        gnumake
        git
        git-repo            # `repo` — AOSP kernel manifest sync (just clone_kernel_source)

        # --- rootfs image + debootstrap ---
        debootstrap
        e2fsprogs           # mkfs.ext4  (main / mainline rootfs)
        btrfs-progs         # mkfs.btrfs (feature/btrfs-root)
        dosfstools
        util-linux          # mount/losetup helpers
        rsync
        qemu                # qemu-aarch64 user-mode (foreign-arch 2nd-stage debootstrap; see binfmt note)

        # --- vendor firmware / OTA extraction ---
        curl
        unzip
        xxd
        erofs-utils         # fsck.erofs for the vendor partition
        android-tools       # fastboot, adb, simg2img

        # --- flashing over the network ---
        openssh             # ssh/scp for flash-ssh.sh
        nmap                # host discovery for flash-nmap.sh

        # --- kernel build deps (kbuild host tools; kernel/kbuild.mk) ---
        python3             # tools/bazel2kbuild.py, mkdtboimg.py, modules-load-lists.py
        perl
        bc
        bison
        flex
        openssl
        (pkgs.lib.getDev openssl)
        elfutils            # libelf (resolve_btfids), libdw (gendwarfksyms)
        pahole              # CONFIG_DEBUG_INFO_BTF
        ncurses             # nconfig (just config_kernel)
        pkg-config
        cpio
        kmod                # depmod
        dtc                 # device tree compiler
        lz4
        zstd
        gzip

        # --- on-device A/B + OTA tools (.build_pixel_bootctl / .build_pixel_ota) ---
        (rustToolchainFor pkgs)
      ];

      # The kernel builds with the clang the kernel tree pins
      # (kernel/source-<device>/prebuilts/clang/host/linux-x86/clang-<ver>, see
      # KERNEL_CLANG_VERSION), an AOSP prebuilt for generic Linux: it needs
      # /lib64/ld-linux-x86-64.so.2, and as HOSTCC it compiles kbuild's host
      # programs against headers and libraries in the usual FHS places
      # (/usr/include/openssl, libelf, libdw, ...). A plain nix shell has neither,
      # so the kernel stage runs in this FHS env. (It used to exist for Kleaf's
      # Bazel, which is gone; the prebuilt clang is why it stays.)
      fhsFor = pkgs: pkgs.buildFHSEnv {
        name = "junkyard-kernel-fhs";
        targetPkgs = p: (buildToolsFor p) ++ (with p; [
          coreutils which gnutar gzip xz zip unzip file diffutils
          gcc binutils zlib
          # Headers for kbuild's host programs (sign-file, extract-cert,
          # resolve_btfids, gendwarfksyms, kconfig's nconfig).
          (lib.getDev openssl) (lib.getDev elfutils) (lib.getDev zlib)
          (lib.getDev ncurses) (lib.getDev zstd)
        ]);
        runScript = "bash";
        profile = ''
          export ARCH=arm64
          echo "gs201 kernel FHS shell — run 'just device=<dev> build_kernel' here (then 'just <dev>' in the default shell)"
        '';
      };
    in
    {
      devShells = eachSystem (pkgs:
        let
          # aarch64 Linux cross toolchain for the *mainline* kbuild track
          # (feature/linux-kernel). This branch's kernels use the tree's own
          # prebuilt clang (LLVM=), so they do not need it.
          crossCC = pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc;
          crossPrefix = crossCC.targetPrefix; # "aarch64-unknown-linux-gnu-"
          # (rustToolchainFor now lives in buildToolsFor — see the note there for
          # why keeping it here alone broke `nix run .#build`.)
        in
        {
          # Default: clean shell for the mainline kbuild track, the rootfs
          # stages, image packaging, and flashing.
          default = pkgs.mkShell {
            packages = buildToolsFor pkgs;
            nativeBuildInputs = [ crossCC ];
            shellHook = ''
              export ARCH=arm64
              export CROSS_COMPILE=${crossPrefix}
              echo "junkyard build shell (felix + lynx) — ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE"
              echo
              echo "Build (external sudo-capable terminal):"
              echo "    nix run .#build                  every device"
              echo "    nix run .#build -- felix         one device"
              echo "    nix run .#build -- lynx"
              echo "Kernel alone (the tree's prebuilt clang needs the FHS env):"
              echo "    nix run .#kernel-fhs -- -c 'just device=<dev> build_kernel'"
              echo
              echo "NOTE — system-level prerequisites a flake CANNOT provide (set in your NixOS host / krg-nixos-flakes):"
              echo "  • binfmt for foreign-arch debootstrap:  boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ];"
              echo "  • passwordless sudo for mount_rootfs / systemd-nspawn stages"
              echo "  • udev/plugdev access for fastboot (flash-fastboot.sh)"
            '';
          };

          # Interactive FHS shell for the kernel build:
          #   nix develop .#kernel   then   just device=<dev> build_kernel
          kernel = (fhsFor pkgs).env;
        });

      # Scriptable/non-interactive FHS entry for the kernel build:
      #   nix run .#kernel-fhs -- -c 'just device=<dev> build_kernel'
      #   nix run .#kernel-fhs                       (drops into an FHS bash)
      packages = eachSystem (pkgs: {
        kernel-fhs = fhsFor pkgs;
      });

      # One-command NixOS build. Nix lives ONLY here, so the Makefile/justfile stay
      # portable (non-Nix hosts still build with a plain `just <device>`). The kernel build
      # runs in the FHS env, for the tree's prebuilt clang (see fhsFor). Everything
      # else runs in the normal env where sudo works. Run from an external,
      # sudo-capable terminal (VSCode terminals block sudo):  nix run .#build
      apps = eachSystem (pkgs:
        let
          fhs = fhsFor pkgs;
          # No argument means EVERY device. Naming devices builds those:
          #   nix run .#build                  -> all devices
          #   nix run .#build -- lynx          -> lynx
          #   nix run .#build -- felix         -> felix
          #   nix run .#build -- felix lynx    -> both, explicitly
          #
          # ★ There is deliberately no default device. felix and lynx are equal
          # citizens, and a default is a preference: it decides, silently, which
          # device a bare command operates on. That matters most where the answer
          # is destructive or expensive — a defaulted build is a wasted hour, a
          # defaulted flash is a wrong image on real hardware.
          #
          # The loop is per-device rather than one `just all`, because phase 1 can
          # only put ONE device's kernel through the FHS env; `just all` inside it
          # would run the other device's kernel build in phase 2's normal env,
          # where the prebuilt clang cannot run.
          devices = [ "felix" "lynx" ];
          junkyard-build = pkgs.writeShellApplication {
            name = "junkyard-build";
            runtimeInputs = buildToolsFor pkgs;
            text = ''
              ALL_DEVICES="${pkgs.lib.concatStringsSep " " devices}"
              if [ "$#" -gt 0 ]; then
                TARGETS="$*"
                for d in $TARGETS; do
                  case " $ALL_DEVICES " in
                    *" $d "*) ;;
                    *) echo "unknown device '$d' (known: $ALL_DEVICES)" >&2; exit 2 ;;
                  esac
                done
              else
                TARGETS="$ALL_DEVICES"
              fi
              echo "[junkyard-build] building:$(for d in $TARGETS; do printf ' %s' "$d"; done)"
              for DEVICE in $TARGETS; do
                echo "[junkyard-build] $DEVICE 1/2 — kernel build in FHS env (the tree's prebuilt clang)"
                "${fhs}/bin/junkyard-kernel-fhs" -c "just device=$DEVICE build_kernel"
                echo "[junkyard-build] $DEVICE 2/2 — rootfs/boot in normal env (kernel cached; needs sudo + aarch64 binfmt)"
                # The device recipe re-runs .build_kernel, but phase 1 just touched
                # its sentinel, so make skips it and the FHS-built kernel is used.
                just "$DEVICE"
              done
            '';
          };
        in
        {
          build = {
            type = "app";
            program = "${junkyard-build}/bin/junkyard-build";
          };
        });

      formatter = eachSystem (pkgs: pkgs.nixpkgs-fmt);
    };
}
