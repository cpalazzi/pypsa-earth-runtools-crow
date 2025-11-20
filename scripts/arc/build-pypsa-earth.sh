#! /bin/bash
#SBATCH --job-name=build-pypsa-earth
#SBATCH --chdir=/data/engs-df-green-ammonia/engs2523/pypsa-earth
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --partition=medium
#SBATCH --time=06:00:00
#SBATCH --clusters=all
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=carlo.palazzi@eng.ox.ac.uk

# Usage notes (also mirrored in README):
#   module load Anaconda3/2023.09 (or export ARC_ANACONDA_MODULE before sbatch)
#   option A: install micromamba under $HOME/bin and add it to PATH
#   option B: create a helper env: conda create -y -p /data/.../envs/conda-tools micromamba; source activate it
#   for interactive shells run: eval "$(micromamba shell hook --shell bash)" before micromamba activate

set -euo pipefail

module purge
ARC_ANACONDA_MODULE=${ARC_ANACONDA_MODULE:-Anaconda3/2023.09}
module load "$ARC_ANACONDA_MODULE"

WORKDIR=/data/engs-df-green-ammonia/engs2523/pypsa-earth
ENV_PREFIX=/data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env
LOGDIR=/data/engs-df-green-ammonia/engs2523/envs/logs
MAMBA_ROOT_PREFIX=/data/engs-df-green-ammonia/engs2523/envs/mamba-root
mkdir -p "$LOGDIR" "$(dirname "$ENV_PREFIX")" "$MAMBA_ROOT_PREFIX"

MICROMAMBA_TAR_URL="https://micro.mamba.pm/api/micromamba/linux-64/latest"
MICROMAMBA_BIN="$TMPDIR/bin/micromamba"
if [ ! -x "$MICROMAMBA_BIN" ]; then
  mkdir -p "$TMPDIR/bin"
  curl -Ls "$MICROMAMBA_TAR_URL" | tar -xvj -C "$TMPDIR/bin" --strip-components=1 bin/micromamba
fi

export MAMBA_ROOT_PREFIX

"$MICROMAMBA_BIN" install -y -n base -c conda-forge conda-lock mamba

rm -rf "$ENV_PREFIX"
"$MICROMAMBA_BIN" run -n base conda-lock install --mamba --prefix "$ENV_PREFIX" "$WORKDIR/envs/linux-64.lock.yaml"

"$MICROMAMBA_BIN" run -p "$ENV_PREFIX" conda list --explicit > "$LOGDIR/pypsa-earth-env-conda.txt"
"$MICROMAMBA_BIN" run -p "$ENV_PREFIX" pip freeze > "$LOGDIR/pypsa-earth-env-pip.txt"

cat <<EONOTE
Environment created. Use the env interactively with:
  module load ${ARC_ANACONDA_MODULE}
  source activate /data/engs-df-green-ammonia/engs2523/envs/conda-tools   # micromamba CLI
  eval "\$(micromamba shell hook --shell bash)"
  micromamba activate /data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env
EONOTE
