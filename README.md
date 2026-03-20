# bioinfo_setup

Portable, reproducible user-level setup for Linux/macOS/WSL using:

- EC2 user data wrappers (`ec2_*_user_data.sh`)
- A generic bootstrap (`bootstrap.sh`)
- Home Manager + Nix flake (`flake.nix`)

The Linux path is designed for bare EC2 images (Ubuntu, Debian) without image-specific hand tuning.

## Flow

Linux EC2 launch flow:

1. EC2 runs `ec2_linux_user_data.sh` as root.
2. `ec2_linux_user_data.sh` detects a login user and downloads `bootstrap.sh` from this repo.
3. `bootstrap.sh` installs Nix if missing, loads Nix, detects host family (`debian` vs `other`), then runs Home Manager for the target user.
4. `flake.nix` applies the user environment:
   - installs Nix-managed CLI tools
   - installs/configures fish/bash/zsh integration
   - installs Miniforge at `$HOME/miniforge3` if it is not already present there
   - installs/updates the conda `base` environment packages via `mamba`

## What Gets Installed

From Nix (`home.packages`):

- coreutils, curl, findutils, fish, git, gzip, jdk, parallel, wget, xz
- `nala` only when Linux host family is Debian/Ubuntu and `pkgs.nala` exists

From Miniforge `base` environment (`mamba install`):

- Python: python 3.12, pip, numpy, pandas, scipy, scikit-learn, matplotlib, seaborn, statsmodels, sympy
- Notebook: ipython, ipywidgets, ipykernel, jupyterlab, notebook
- ML: pytorch
- R: r-base 4.5.*, r-essentials, r-tidyverse, r-data.table, r-irkernel

## Linux EC2 Test (Ubuntu + Debian)

Use a small-but-sufficient instance for the full package set (including heavy R packages): `t3.medium` with a 32 GiB root volume.

1. Prepare environment variables:

```bash
export AWS_DEFAULT_OUTPUT=json
export AWS_REGION=us-east-1
export KEY_NAME=Yiming_Qu
export KEY_PATH="$HOME/.ssh/Yiming_Qu.pem"
```

2. Resolve latest AMIs:

```bash
UBUNTU_AMI=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

DEBIAN_AMI=$(aws ec2 describe-images \
  --owners 136693071363 \
  --filters "Name=name,Values=debian-12-amd64-*" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
```

3. Launch each image with user data:

```bash
aws ec2 run-instances \
  --image-id "$UBUNTU_AMI" \
  --instance-type t3.medium \
  --key-name "$KEY_NAME" \
  --security-group-ids <sg_id> \
  --subnet-id <subnet_id> \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":32,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bioinfo-ubuntu-test}]' \
  --user-data file://ec2_linux_user_data.sh

aws ec2 run-instances \
  --image-id "$DEBIAN_AMI" \
  --instance-type t3.medium \
  --key-name "$KEY_NAME" \
  --security-group-ids <sg_id> \
  --subnet-id <subnet_id> \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":32,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bioinfo-debian-test}]' \
  --user-data file://ec2_linux_user_data.sh
```

4. Validate from SSH:

```bash
ssh -i "$KEY_PATH" ubuntu@<ubuntu_public_ip>
ssh -i "$KEY_PATH" admin@<debian_public_ip>

# On instance
nix --version
fish --version
$HOME/miniforge3/bin/conda --version
$HOME/miniforge3/bin/mamba list | head
```

5. Always terminate test instances after validation.

## Notes

- Repo defaults are wired to `github:whatever60/bioinfo_setup` and `main` branch raw bootstrap URL.
- For testing another branch/repo, override `REPO_REF` and `BOOTSTRAP_URL` in user data.
- `nala` is best-effort optional from Nix (`pkgs.nala`) and may be absent depending on nixpkgs availability.
