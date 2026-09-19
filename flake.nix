{
  description = "Hermetic runtime and OCI container for faster-whisper";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = nixpkgs.lib.genAttrs supportedSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
            };
          };

          fasterWhisperPkg = pkgs.python3Packages.buildPythonPackage {
            pname = "faster-whisper";
            version = "local";
            src = self;
            format = "setuptools";
            doCheck = false;

            propagatedBuildInputs = with pkgs.python3Packages; [
              ctranslate2
              huggingface-hub
              tokenizers
              onnxruntime
              av
              tqdm
            ];
          };

          # Core Python environment with local faster-whisper package
          pythonEnv = pkgs.python3.withPackages (ps: with ps; [
            pip
            setuptools
            wheel
            pytest
            virtualenv
            fasterWhisperPkg
          ]);

          # User-space runtime dependencies matching SYSTRAN/faster-whisper requirements
          runtimeLibs = with pkgs; [
            # glibc / gcc
            stdenv.cc.cc.lib
            glibc
            zlib

            # Audio processing
            ffmpeg-headless
            libsndfile

            # CUDA user-space components
            cudaPackages.cudatoolkit
            cudaPackages.cudnn
            cudaPackages.libcublas
            cudaPackages.libcufft
            cudaPackages.libcurand
          ];

          # Fully resolved Nix store LD_LIBRARY_PATH
          libPath = pkgs.lib.makeLibraryPath runtimeLibs;

          # Host driver passthrough fallback directories for NVIDIA Container Toolkit
          hostDriverLibPath = "/usr/lib64:/usr/lib/x86_64-linux-gnu:/usr/local/nvidia/lib:/usr/local/nvidia/lib64";
          fullContainerLibPath = "${libPath}:${hostDriverLibPath}";

          # Container Entrypoint script
          entrypoint = pkgs.writeShellScriptBin "faster-whisper-entrypoint" ''
            export LD_LIBRARY_PATH="${fullContainerLibPath}:$LD_LIBRARY_PATH"
            export PATH="${pythonEnv}/bin:${pkgs.ffmpeg-headless}/bin:$PATH"

            if [ "$#" -eq 0 ]; then
              exec python3 -c "import faster_whisper; print('faster-whisper initialized successfully. Ready for inference.')"
            else
              exec "$@"
            fi
          '';

        in
        {
          devShell = pkgs.mkShell {
            packages = [
              pythonEnv
              pkgs.ffmpeg-headless
              pkgs.pkg-config
            ] ++ runtimeLibs;

            shellHook = ''
              export LD_LIBRARY_PATH="${libPath}:$LD_LIBRARY_PATH"
              export PYTHONUNBUFFERED=1
              echo "[nix-devShell] Environment ready. LD_LIBRARY_PATH configured with CUDA and FFmpeg runtimes."
            '';
          };

          dockerImage = pkgs.dockerTools.buildLayeredImage {
            name = "faster-whisper";
            tag = "latest";
            contents = [
              pythonEnv
              pkgs.ffmpeg-headless
              pkgs.coreutils
              pkgs.bash
              entrypoint
            ] ++ runtimeLibs;

            config = {
              Entrypoint = [ "${entrypoint}/bin/faster-whisper-entrypoint" ];
              WorkingDir = "/app";
              Env = [
                "LD_LIBRARY_PATH=${fullContainerLibPath}"
                "PATH=${pythonEnv}/bin:${pkgs.ffmpeg-headless}/bin:/bin:/usr/bin"
                "NVIDIA_VISIBLE_DEVICES=all"
                "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
              ];
            };
          };
        }
      );
    in
    {
      devShells = nixpkgs.lib.genAttrs supportedSystems (system: {
        default = perSystem.${system}.devShell;
      });

      packages = nixpkgs.lib.genAttrs supportedSystems (system: {
        default = perSystem.${system}.dockerImage;
        dockerImage = perSystem.${system}.dockerImage;
      });
    };
}

