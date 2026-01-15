#!/bin/bash
#SBATCH --job-name=build-pypsa-earth-gurobi
#SBATCH --chdir=/data/engs-df-green-ammonia/engs2523/pypsa-earth
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --partition=medium
#SBATCH --time=06:00:00
#SBATCH --clusters=all
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=carlo.palazzi@eng.ox.ac.uk

if [ -f /etc/profile ]; then
  source /etc/profile
fi
if [ -f /etc/profile.d/modules.sh ]; then
  source /etc/profile.d/modules.sh
fi
if [ -f /etc/profile.d/lmod.sh ]; then
  source /etc/profile.d/lmod.sh
fi

set -euo pipefail

module purge
ARC_ANACONDA_MODULE=${ARC_ANACONDA_MODULE:-Anaconda3/2024.06-1}
module load "$ARC_ANACONDA_MODULE"

if [ -n "${EBROOTANACONDA3:-}" ] && [ -f "$EBROOTANACONDA3/etc/profile.d/conda.sh" ]; then
  source "$EBROOTANACONDA3/etc/profile.d/conda.sh"
fi

WORKDIR=/data/engs-df-green-ammonia/engs2523/pypsa-earth
ENV_PREFIX=/data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env-gurobi
LOGDIR=/data/engs-df-green-ammonia/engs2523/envs/logs
mkdir -p "$LOGDIR" "$(dirname "$ENV_PREFIX")"

rm -rf "$ENV_PREFIX"
conda env create -y -p "$ENV_PREFIX" -f "$WORKDIR/envs/environment.yaml" python=3.10
conda install -y -p "$ENV_PREFIX" -c gurobi gurobi

conda list -p "$ENV_PREFIX" > "$LOGDIR/pypsa-earth-env-gurobi-packages.txt"
"$ENV_PREFIX/bin/python" -c "import sys; print(sys.version)"

echo "Environment created at $ENV_PREFIX"
