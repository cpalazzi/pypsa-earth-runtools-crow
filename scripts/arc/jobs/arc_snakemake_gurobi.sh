#!/bin/bash
#SBATCH --job-name=pypsa-earth-gurobi
#SBATCH --partition=short,medium
#SBATCH --clusters=all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=256G
#SBATCH --time=08:00:00
#SBATCH --mail-type=BEGIN,END
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
if ! command -v module >/dev/null 2>&1; then
  source /usr/share/lmod/lmod/init/bash
fi

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: sbatch scripts/arc/jobs/arc_snakemake_gurobi.sh <run-label> <configfile> [configfile ...]" >&2
  echo "Example: sbatch scripts/arc/jobs/arc_snakemake_gurobi.sh 20251202-green config/default-single-timestep.yaml config/overrides/green-ammonia.yaml" >&2
  exit 2
fi

SCENARIO="$1"
shift

CONFIG_FILES=("$@")
CONFIG_ARGS=()
for cfg in "${CONFIG_FILES[@]}"; do
  CONFIG_ARGS+=("--configfile" "$cfg")
done

module restore 2>/dev/null || true
ANACONDA_MODULE=${ARC_ANACONDA_MODULE:-"Anaconda3/2024.06-1"}
module load "$ANACONDA_MODULE"

GUROBI_MODULE=${ARC_GUROBI_MODULE:-""}
if [ -n "$GUROBI_MODULE" ]; then
  module load "$GUROBI_MODULE"
fi

PYPSA_ENV=${ARC_PYPSA_ENV:-"/data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env-gurobi"}

export PATH="$PYPSA_ENV/bin:$PATH"

export PYPSA_SOLVER_NAME=${PYPSA_SOLVER_NAME:-gurobi}
export LINOPY_SOLVER=${LINOPY_SOLVER:-gurobi}
export GRB_LICENSE_FILE=${GRB_LICENSE_FILE:-"/data/engs-df-green-ammonia/engs2523/licenses/gurobi.lic"}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WORKDIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKDIR=${ARC_WORKDIR:-${SLURM_SUBMIT_DIR:-$DEFAULT_WORKDIR}}
cd "$WORKDIR"
mkdir -p logs

LOGFILE="logs/snakemake-${SCENARIO}-$(date +%Y%m%d-%H%M%S)-gurobi.log"
echo "Snakemake log: $LOGFILE"

MEM_MB=${SLURM_MEM_PER_NODE:-256000}
CPUS=${SLURM_CPUS_PER_TASK:-16}
LATENCY_WAIT=${ARC_SNAKE_LATENCY_WAIT:-60}
EXTRA_ARGS=()
if [[ "${ARC_SNAKE_DRYRUN:-0}" == "1" ]]; then
  EXTRA_ARGS+=("-n")
fi

if [[ "${ARC_STAGE_DATA:-0}" == "1" ]]; then
  mapfile -t AVAILABLE_RULES < <(snakemake --list)
  stage_targets=()
  for rule in retrieve_databundle_light download_osm_data build_cutout; do
    if printf '%s\n' "${AVAILABLE_RULES[@]}" | grep -qx "$rule"; then
      stage_targets+=("$rule")
    fi
  done
  if [[ ${#stage_targets[@]} -gt 0 ]]; then
    if [[ " ${stage_targets[*]} " == *" retrieve_databundle_light "* ]]; then
      printf 'all\n\n' | snakemake --cores "$CPUS" "${stage_targets[@]}" \
        --resources mem_mb="$MEM_MB" --keep-going --rerun-incomplete \
        --latency-wait "$LATENCY_WAIT"
    else
      snakemake --cores "$CPUS" "${stage_targets[@]}" \
        --resources mem_mb="$MEM_MB" --keep-going --rerun-incomplete \
        --latency-wait "$LATENCY_WAIT"
    fi
  fi
fi

run_snakemake() {
  snakemake \
    "$@" \
    "${EXTRA_ARGS[@]}" \
    -j "${CPUS}" \
    --resources mem_mb="${MEM_MB}" \
    --latency-wait "${LATENCY_WAIT}" \
    --keep-going --rerun-incomplete --printshellcmds \
    --stats "logs/snakemake-${SCENARIO}-gurobi.stats.json" 2>&1 | tee -a "$LOGFILE"
}

run_snakemake solve_all_networks "${CONFIG_ARGS[@]}"
