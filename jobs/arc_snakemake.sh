#!/bin/bash
#SBATCH --job-name=pypsa-earth
#SBATCH --partition=short,medium
#SBATCH --clusters=all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=48G
#SBATCH --time=08:00:00
#SBATCH --mail-type=BEGIN,END
#SBATCH --mail-user=carlo.palazzi@eng.ox.ac.uk

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: sbatch jobs/arc_snakemake.sh <baseline|green-ammonia>" >&2
  exit 2
fi

# Scenario name (used for log filenames)
SCENARIO="$1"

module restore 2>/dev/null || true
ANACONDA_MODULE=${ARC_ANACONDA_MODULE:-"Anaconda3/2023.09"}
module load "$ANACONDA_MODULE"

TOOLS_ENV=${ARC_CONDA_TOOLS:-"/data/engs-df-green-ammonia/engs2523/envs/conda-tools"}
PYPSA_ENV=${ARC_PYPSA_ENV:-"/data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env"}

source activate "$TOOLS_ENV"
eval "$(micromamba shell hook --shell bash)"
micromamba activate "$PYPSA_ENV"

# Determine a sensible default working directory: prefer ARC_WORKDIR, then
# SLURM_SUBMIT_DIR (where sbatch was invoked), otherwise fall back to the
# repository root (parent of this `jobs/` script). This makes the job more
# robust if it is submitted from a different location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WORKDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR=${ARC_WORKDIR:-${SLURM_SUBMIT_DIR:-$DEFAULT_WORKDIR}}
cd "$WORKDIR"
mkdir -p logs

# Central logfile for this run
LOGFILE="logs/snakemake-${SCENARIO}-$(date +%Y%m%d-%H%M%S).log"
echo "Snakemake log: $LOGFILE"

MEM_MB=${SLURM_MEM_PER_NODE:-48000}
CPUS=${SLURM_CPUS_PER_TASK:-16}
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
    snakemake --cores "$CPUS" "${stage_targets[@]}" \
      --resources mem_mb="$MEM_MB" --keep-going --rerun-incomplete
  fi
fi

run_snakemake() {
  snakemake \
    "$@" \
    "${EXTRA_ARGS[@]}" \
    -j "${CPUS}" \
    --resources mem_mb="${MEM_MB}" \
    --keep-going --rerun-incomplete --printshellcmds \
    --stats "logs/snakemake-${SCENARIO}.stats.json" 2>&1 | tee -a "$LOGFILE"
}

case "$1" in
  baseline)
    # Use a high-level rule so Snakemake resolves all required outputs per config
    run_snakemake solve_all_networks --configfile config/default-single-timestep.yaml
    ;;
  green-ammonia)
    run_snakemake solve_all_networks \
      --configfile config/default-single-timestep.yaml \
      --configfile config/overrides/green-ammonia.yaml
    ;;
  *)
    echo "Unknown scenario '$1'" >&2
    exit 3
    ;;
esac
