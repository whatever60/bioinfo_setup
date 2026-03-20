{
  description = "Portable user environment via Home Manager + Miniforge";

  inputs = {
    # -------------------------------------------------------------------------
    # We keep separate nixpkgs inputs for Linux and Darwin.
    #
    # This is not strictly required, but it makes the intent explicit:
    #   - Linux machines use the Linux-oriented branch
    #   - macOS machines use the Darwin-oriented branch
    # -------------------------------------------------------------------------
    nixpkgs-linux.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.05-darwin";

    # Home Manager in standalone mode is the portable user-level layer.
    home-manager.url = "github:nix-community/home-manager/release-25.05";
  };

  outputs = { nixpkgs-linux, nixpkgs-darwin, home-manager, ... }:
    let
      lib = nixpkgs-linux.lib;

      # -----------------------------------------------------------------------
      # Supported target platforms.
      #
      # This covers:
      #   - mainstream Linux on x86_64 and ARM64
      #   - macOS on Intel and Apple Silicon
      #
      # WSL uses one of the Linux systems above, so it does not need a separate
      # system identifier here.
      # -----------------------------------------------------------------------
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      pkgsFor = system:
        import
          (if lib.hasSuffix "darwin" system then nixpkgs-darwin else nixpkgs-linux)
          {
            inherit system;
            config.allowUnfree = true;
          };

      mkHome = system:
        let
          pkgs = pkgsFor system;

          # -------------------------------------------------------------------
          # We deliberately do NOT hardcode a username or home directory.
          #
          # The bootstrap wrapper decides which existing OS user should own the
          # environment, then passes USER and HOME through --impure.
          #
          # This keeps the Nix layer portable instead of assuming:
          #   /home/ubtunu
          #   /home/ubuntu
          #   /Users/ec2-user
          #   etc.
          # -------------------------------------------------------------------
          username =
            let value = builtins.getEnv "USER";
            in if value != "" then value else
              throw "USER must be set; run Home Manager with --impure";

          homeDirectory =
            let value = builtins.getEnv "HOME";
            in if value != "" then value else
              throw "HOME must be set; run Home Manager with --impure";

          # -------------------------------------------------------------------
          # HOST_FAMILY is passed in by bootstrap.sh as a small impure hint.
          #
          # Why this exists:
          #   - Nix knows the platform from `system`
          #   - Nix does not inherently know the Linux distro family
          #
          # We only use this for optional distro-specific extras, such as nala.
          # We intentionally do NOT try to install apt through Nix, because apt
          # is part of the Debian/Ubuntu host OS rather than a portable user
          # environment tool.
          # -------------------------------------------------------------------
          hostFamily = builtins.getEnv "HOST_FAMILY";

          isLinux = builtins.match ".*-linux" system != null;
          isDarwin = builtins.match ".*-darwin" system != null;

          isDebianFamily =
            isLinux && builtins.elem hostFamily [ "debian" "ubuntu" ];

          # -------------------------------------------------------------------
          # Miniforge lives inside the user's home directory so the setup remains
          # user-scoped and portable across Linux/macOS/WSL.
          # -------------------------------------------------------------------
          miniforgeRoot = "${homeDirectory}/miniforge3";

          # Pick the correct Miniforge installer per platform/architecture.
          miniforgeInstaller =
            if system == "x86_64-linux" then "Miniforge3-Linux-x86_64.sh"
            else if system == "aarch64-linux" then "Miniforge3-Linux-aarch64.sh"
            else if system == "x86_64-darwin" then "Miniforge3-MacOSX-x86_64.sh"
            else if system == "aarch64-darwin" then "Miniforge3-MacOSX-arm64.sh"
            else throw "Unsupported system: ${system}";

          # -------------------------------------------------------------------
          # Base scientific environment.
          #
          # This intentionally includes both Python and R in the base conda env,
          # because that is what you asked for. It is convenient, but it is also
          # fairly heavy. Later, you may want to split this into named envs.
          # -------------------------------------------------------------------
          # Install in chunks to avoid OOM on small instances.
          condaCorePackages = [
            "python=3.12"
            "pip"
          ];

          condaSciencePackages = [
            "numpy"
            "pandas"
            "scipy"
            "scikit-learn"
            "matplotlib"
            "seaborn"
            "statsmodels"
            "sympy"
          ];

          condaNotebookPackages = [
            "ipython"
            "ipywidgets"
            "ipykernel"
            "jupyterlab"
            "notebook"
          ];

          condaMlPackages = [
            "pytorch"
          ];

          condaRPackages = [
            "r-base=4.5.*"
            "r-essentials"
            "r-tidyverse"
            "r-data.table"
            "r-irkernel"
          ];

          condaCoreArgs = lib.escapeShellArgs condaCorePackages;
          condaScienceArgs = lib.escapeShellArgs condaSciencePackages;
          condaNotebookArgs = lib.escapeShellArgs condaNotebookPackages;
          condaMlArgs = lib.escapeShellArgs condaMlPackages;
          condaRArgs = lib.escapeShellArgs condaRPackages;

          # -------------------------------------------------------------------
          # Portable substitute for "make fish my default shell".
          #
          # A true login-shell change is an OS-admin task and is not fully
          # portable across Linux/macOS/WSL in standalone Home Manager mode.
          #
          # Instead:
          #   - install fish everywhere
          #   - configure fish properly
          #   - if an interactive bash/zsh session starts, hand off to fish
          #
          # You can disable this per-session by exporting:
          #   DISABLE_FISH_HANDOFF=1
          # -------------------------------------------------------------------
          fishHandoffForBash = ''
            if [[ $- == *i* ]] && command -v fish >/dev/null 2>&1 && [ -z "''${DISABLE_FISH_HANDOFF:-}" ]; then
              exec fish -l
            fi
          '';

          fishHandoffForZsh = ''
            if [[ -o interactive ]] && command -v fish >/dev/null 2>&1 && [[ -z "''${DISABLE_FISH_HANDOFF:-}" ]]; then
              exec fish -l
            fi
          '';

          # -------------------------------------------------------------------
          # Cross-platform package baseline.
          #
          # Notes:
          #   - xargs comes from findutils
          #   - parallel is the GNU parallel package
          #   - jdk is the Java/JDK requirement you asked for
          # -------------------------------------------------------------------
          commonPackages = with pkgs; [
            coreutils
            curl
            findutils
            fish
            git
            gzip
            jdk
            parallel
            wget
            xz
          ];

          # -------------------------------------------------------------------
          # Debian-family optional extras.
          #
          # We add nala only when:
          #   1) the platform is Linux, and
          #   2) bootstrap.sh detected a Debian-family host
          #
          # We intentionally do NOT add apt here. apt belongs to the host OS.
          # -------------------------------------------------------------------
          debianFamilyPackages =
            lib.optionals isDebianFamily (
              lib.optional (pkgs ? nala) pkgs.nala
            );
        in
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          modules = [
            ({ lib, pkgs, ... }: {
              home.username = username;
              home.homeDirectory = homeDirectory;
              home.stateVersion = "25.05";

              programs.home-manager.enable = true;

              home.packages = commonPackages ++ debianFamilyPackages;

              # Ensure Miniforge binaries are visible once installed.
              home.sessionPath = [
                "${miniforgeRoot}/bin"
                "${miniforgeRoot}/condabin"
              ];

              # Minimal conda policy file.
              home.file.".condarc".text = ''
                channels:
                  - conda-forge
                channel_priority: strict
                auto_activate_base: false
              '';

              # -----------------------------------------------------------------
              # Bash configuration
              #
              # Order matters:
              #   1) optionally hand off interactive sessions to fish
              #   2) if we stay in bash, initialize conda/mamba there
              # -----------------------------------------------------------------
              programs.bash.enable = true;
              programs.bash.initExtra = ''
                ${fishHandoffForBash}

                if [ -x "$HOME/miniforge3/bin/conda" ]; then
                  __conda_setup="$("$HOME/miniforge3/bin/conda" shell.bash hook 2>/dev/null)" || true
                  if [ -n "''${__conda_setup:-}" ]; then
                    eval "$__conda_setup"
                  else
                    export PATH="$HOME/miniforge3/condabin:$PATH"
                  fi
                  unset __conda_setup
                fi
              '';

              # -----------------------------------------------------------------
              # Fish configuration
              #
              # This is the real target interactive shell.
              # Conda/mamba are initialized using conda's fish hook.
              # -----------------------------------------------------------------
              programs.fish.enable = true;
              programs.fish.interactiveShellInit = ''
                if test -x "$HOME/miniforge3/bin/conda"
                  $HOME/miniforge3/bin/conda shell.fish hook | source
                end
              '';

              # -----------------------------------------------------------------
              # macOS commonly uses zsh as the login shell.
              #
              # We enable a small zsh layer only on Darwin so interactive zsh
              # sessions also hand off cleanly to fish.
              # -----------------------------------------------------------------
              programs.zsh.enable = isDarwin;
              programs.zsh.initExtraFirst = lib.mkIf isDarwin ''
                ${fishHandoffForZsh}

                if [ -x "$HOME/miniforge3/bin/conda" ]; then
                  eval "$("$HOME/miniforge3/bin/conda" shell.zsh hook 2>/dev/null)" || true
                fi
              '';

              # -----------------------------------------------------------------
              # Miniforge bootstrap + base-env installation.
              #
              # This runs as a Home Manager activation step, so the logic stays in
              # the portable Nix layer instead of in EC2 user-data scripts.
              # -----------------------------------------------------------------
              home.activation.installMiniforge =
                lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                  export HOME="${homeDirectory}"

                  # Provide a predictable tool PATH for the activation script.
                  export PATH="${lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.curl
                    pkgs.findutils
                    pkgs.gawk
                    pkgs.glibc.bin
                    pkgs.gnugrep
                    pkgs.gnused
                    pkgs.gzip
                    pkgs.xz
                  ]}:$PATH"

                  # Always install Miniforge under the effective HOME.
                  miniforge_root="$HOME/miniforge3"
                  installer_url="https://github.com/conda-forge/miniforge/releases/latest/download/${miniforgeInstaller}"

                  mkdir -p "$(dirname "$miniforge_root")"

                  # Install Miniforge only once.
                  if [ ! -x "$miniforge_root/bin/conda" ]; then
                    tmp_dir="$(mktemp -d)"
                    trap 'rm -rf "$tmp_dir"' EXIT

                    curl -fsSL -o "$tmp_dir/miniforge.sh" "$installer_url"
                    "${pkgs.bash}/bin/bash" "$tmp_dir/miniforge.sh" -b -p "$miniforge_root"
                  fi

                  # Keep conda behavior consistent with .condarc.
                  "$miniforge_root/bin/conda" config --set auto_activate_base false
                  "$miniforge_root/bin/conda" config --set channel_priority strict

                  # Install or update the requested scientific stack in base.
                  "$miniforge_root/bin/mamba" install -y -n base ${condaCoreArgs}
                  "$miniforge_root/bin/mamba" install -y -n base ${condaScienceArgs}
                  "$miniforge_root/bin/mamba" install -y -n base ${condaNotebookArgs}
                  "$miniforge_root/bin/mamba" install -y -n base ${condaMlArgs}
                  "$miniforge_root/bin/mamba" install -y -n base ${condaRArgs}
                '';
            })
          ];
        };
    in
    {
      homeConfigurations = lib.listToAttrs (
        map
          (system: {
            name = "portable-${system}";
            value = mkHome system;
          })
          systems
      );
    };
}
