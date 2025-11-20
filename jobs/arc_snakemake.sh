#!/bin/bash
#SBATCH --job-name=pypsa-earth
#SBATCH --partition=standard
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=48G
#SBATCH --time=08:00:00
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: sbatch jobs/arc_snakemake.sh <baseline|green-ammonia>" >&2
  exit 2
fi

module restore 2>/dev/null || true
ANACONDA_MODULE=${ARC_ANACONDA_MODULE:-"Anaconda3/2023.09"}
module load "$ANACONDA_MODULE"

TOOLS_ENV=${ARC_CONDA_TOOLS:-"/data/engs-df-green-ammonia/engs2523/envs/conda-tools"}
PYPSA_ENV=${ARC_PYPSA_ENV:-"/data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env"}

source activate "$TOOLS_ENV"
eval "$(micromamba shell hook --shell bash)"
micromamba activate "$PYPSA_ENV"

WORKDIR=${ARC_WORKDIR:-"$SLURM_SUBMIT_DIR"}
cd "$WORKDIR"
mkdir -p logs

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
  snakemake -call solve_network \
    "$@" \
    "${EXTRA_ARGS[@]}" \
    -j "${CPUS}" \
    --resources mem_mb="${MEM_MB}" \
    --keep-going --rerun-incomplete
}

case "$1" in
  baseline)
    run_snakemake --configfile config/default-single-timestep.yaml
    ;;
  green-ammonia)
    run_snakemake \
      --configfile config/default-single-timestep.yaml \
      --configfile config/overrides/green-ammonia.yaml
    ;;
  *)
    echo "Unknown scenario '$1'" >&2
    exit 3
    ;;
esac
