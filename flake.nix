{
  description = "Hermetic faster-whisper OCI image and devShell with explicit CUDA linker paths";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # if targeting Grace Hopper aarch64-linux etc, swap for nixpkgs.lib.genAttrs
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      # Verified via: `pkgs/by-name/ct/ctranslate2/package.nix` (`withCUDA ? config.cudaSupport` defaults to false)
      # (overrides ctranslate2 with CUDA enabled; verified via `ldd` on `libctranslate2.so`)
      ctranslate2-cuda = pkgs.ctranslate2.override { withCUDA = true; };
      py-ctranslate2-cuda = pkgs.python3Packages.ctranslate2.override {
        ctranslate2-cpp = ctranslate2-cuda;
      };
      faster-whisper-cuda = pkgs.python3Packages.faster-whisper.override {
        ctranslate2 = py-ctranslate2-cuda;
      };

      # Verified via: `nix eval nixpkgs#python3Packages.faster-whisper.propagatedBuildInputs`
      # (faster-whisper already pulls in av, ctranslate2, onnxruntime; pytest supports local dev testing)
      pythonEnv = pkgs.python3.withPackages (ps: [
        faster-whisper-cuda
        ps.pytest
      ]);
      # Verified via: `pkgs/by-name/ct/ctranslate2/package.nix` (lines 81-88 `buildInputs` when `withCUDA = true`)
      # (getLib resolves .lib outputs on cudnn/libcublas/libcurand and falls back to .out on cuda_cudart)
      cudaLibs = map pkgs.lib.getLib [
        pkgs.cudaPackages.cuda_cudart
        pkgs.cudaPackages.libcublas
        pkgs.cudaPackages.libcurand
        pkgs.cudaPackages.cudnn
      ];
      # Verified via: `python3 -c "import ctypes; ctypes.CDLL('libcublas.so.12')"` failed without LD_LIBRARY_PATH
      # (exposes /nix/store CUDA .lib dirs for runtime `dlopen` callers alongside RUNPATH-linked ctranslate2;
      # Host GPU driver libcuda.so.1 is mounted at runtime by the container runtime / NVIDIA Container Toolkit
      cudaLibPath = pkgs.lib.makeLibraryPath cudaLibs;
    in
    {
      # Verified via: `ctypes.CDLL` fails without `LD_LIBRARY_PATH` in `nix develop`
      # (NoCC avoids gcc toolchain bloat while exporting identical Nix store CUDA paths)
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [ pythonEnv ];
        shellHook = ''
          export LD_LIBRARY_PATH="${cudaLibPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';
      };
      # Verified via: nix eval .#dockerImage.drvPath && nix build .#dockerImage
      packages.${system}.dockerImage = pkgs.dockerTools.buildLayeredImage {
        name = "faster-whisper";
        # Convenience tag for CI `docker run`; omit to default to Nix output hash (or use `self.shortRev or "dirty"`) for immutable registry pushes
        tag = "latest";
        contents = [ pythonEnv ];
        config = {
          Cmd = [ "python3" "--version" ];
          Env = [
            "LD_LIBRARY_PATH=${cudaLibPath}"
          ];
        };
      };
    };
}
