# PyPSA-Earth ARC Runner

This repository packages a lightweight set of overrides, scripts, and HPC job templates to run three PyPSA-Earth experiments on the Oxford Advanced Research Computing (ARC) cluster:

1. **Baseline sanity check** – default European electricity-only run with a single snapshot.
2. **Core technology limiter** – layers the `limit_core_technologies` hook on top of the baseline (without changing the snapshot window) to ensure the custom extra-functionality entry points load correctly. This is now our primary “extra hook” test.
3. **Green ammonia stress test** – same setup but with an endogenous green-ammonia supply chain (electrolyser → storage → ammonia-fired CCGT) anchored at a node in southern Spain.

The files in this repo are meant to be layered on top of our patched [`pypsa-earth`](https://github.com/cpalazzi/pypsa-earth) fork (which itself tracks the upstream project). You will copy them into that PyPSA-Earth working tree (or add this repo as a Git submodule) and refer to the supplied config files & scripts via Snakemake.

> **Oxford ARC login**: `engs2523@arc-login.arc.ox.ac.uk`

## PyPSA-Earth fork with built-in fixes

Clone `https://github.com/cpalazzi/pypsa-earth.git` (already ahead of upstream with two commits) so we do not have to keep patch files in this overlay. Those commits do two things:

1. `sitecustomize.py` teaches PyPSA-Earth to handle gzipped Geofabrik MD5 manifests (otherwise `verify_pbf` fails for certain mirrors).
2. `scripts/solve_network.py` loads every entry listed under `solving.options.extra_functionality` and chains them so the limiter + green-ammonia hooks both run.

Keep the fork synced with upstream so we can raise focused PRs later:

```zsh
git clone https://github.com/cpalazzi/pypsa-earth.git
cd pypsa-earth
git remote add upstream https://github.com/pypsa-meets-earth/pypsa-earth.git
git fetch upstream
git merge upstream/main   # or rebase if you prefer
```

Each time you merge upstream changes, run the PyPSA-Earth test suite locally (at least `pytest test/test_gfk_download.py`) and push back to the fork. When Snakemake runs you should still see `Loaded N extra_functionality hook(s): …` in the logs—if that line is missing, double-check that the fork is on `origin/main` and that the override config lists the hooks you expect.

## Quick start overview

1. Clone the patched fork on ARC (or clone locally and sync). **Always work under your `$DATA` quota** (home is tiny and not meant for multi-GB cutouts):

   ```zsh
   git clone https://github.com/cpalazzi/pypsa-earth.git
   cd pypsa-earth
   git remote add upstream https://github.com/pypsa-meets-earth/pypsa-earth.git
   ```

2. Copy this repository next to (or inside) the checkout (again under `$DATA`) and sync the overlay files. Keep the run configs under `config/`, drop helper scripts under `scripts/extra/`, and place the Slurm launcher under PyPSA-Earth’s `jobs/` tree so Snakemake finds it where it expects job scripts:

   ```zsh
   rsync -av ../20251117-pypsa-earth-project/config/ ./config/ &&
   rsync -av ../20251117-pypsa-earth-project/scripts/extra/ ./scripts/extra/ &&
   rsync -av ../20251117-pypsa-earth-project/scripts/arc/jobs/ ./jobs/
   ```

3. Create/activate the PyPSA-Earth environment (use the provided conda-based Slurm script so you do not have to babysit a long interactive job).
4. Dry-run Snakemake with the baseline config to confirm the DAG is tiny.
5. Submit the baseline job via the supplied ARC Slurm script.
6. Re-run Snakemake with the **core-technology override** to exercise `scripts/extra/limit_core_technologies.py` (it inherits the timeline from the baseline config).
7. Layer on the green-ammonia override once the limiter test succeeds.

The sections below dive into each step, list the exact commands, and explain how to interpret the results.

## Environments and data prerequisites

- **Python environment**: PyPSA-Earth currently ships `envs/environment.yaml`. ARC already exposes several Anaconda versions; run `module spider Anaconda3` to see the newest release, then `module load <latest>` before creating the env. If you want the sbatch job to load a specific version automatically, set `ARC_ANACONDA_MODULE=Anaconda3/<version>` before calling `sbatch`.
- **Solver**: Gurobi is available as a module on ARC. The baseline config now uses Gurobi by default; HiGHS remains as a commented fallback.
- **Data**: The baseline config keeps `enable.retrieve_databundle` true so the required (10°×10°) cutouts download automatically. If you already have a populated `resources/` folder on ARC, you may set those flags to false for faster reruns.
- **Storage**: ARC home directories (~15 GB) fill up instantly. Always work in `$DATA/<project>/<user>` (for OXGATE this is `/data/engs-df-green-ammonia/<ox-id>`). Consider creating `$DATA/engs-df-green-ammonia/<ox-id>/pypsa-earth` for the repo and `$DATA/engs-df-green-ammonia/<ox-id>/envs` for conda prefixes.

## Step-by-step instructions

### 1. Log into ARC and stage the repositories

```zsh
ssh engs2523@arc-login.arc.ox.ac.uk
module spider Anaconda3        # note the newest version
cd $DATA/engs-df-green-ammonia/engs2523  # or another project dir with ≥200 GB quota
module load Anaconda3/<latest> # e.g. Anaconda3/2023.09
```

Clone the fork and stage this helper repo next to it:

```zsh
git clone https://github.com/cpalazzi/pypsa-earth.git
cd pypsa-earth
git remote add upstream https://github.com/pypsa-meets-earth/pypsa-earth.git
scp -r carlo@your-laptop:~/programming/pypsa_models/20251117-pypsa-earth-project ./20251117-pypsa-earth-project
rsync -av 20251117-pypsa-earth-project/config/ pypsa-earth/config/
rsync -av 20251117-pypsa-earth-project/scripts/extra/ pypsa-earth/scripts/extra/
rsync -av 20251117-pypsa-earth-project/scripts/arc/jobs/ pypsa-earth/jobs/
```

> Prefer `rsync` over `cp` so the directory structure is preserved. You can also keep this helper repo as a Git submodule inside `pypsa-earth` if you want to version-lock future tweaks.

### 2. Create and activate the environment (conda-only on ARC)

The repo ships `scripts/arc/build-pypsa-earth-gurobi-conda.sh`, a Slurm job that:

- uses the ARC Anaconda module,
- creates a conda environment at `/data/…/envs/pypsa-earth-env-gurobi` from PyPSA-Earth’s `envs/environment.yaml` (including the `gurobi` channel), and
- logs the resulting package set for future diffing.

Submit it any time you need a clean environment:

```bash
cd /data/engs-df-green-ammonia/engs2523/pypsa-earth
sbatch /data/engs-df-green-ammonia/engs2523/20251117-pypsa-earth-project/scripts/arc/build-pypsa-earth-gurobi-conda.sh
squeue -u engs2523                   # watch progress
tail -f /data/engs-df-green-ammonia/engs2523/pypsa-earth/slurm-<jobid>.out
```

Once the build job mails you (or the log stops growing) jump into a short interactive session to verify:

```bash
srun --pty --partition=interactive --time=00:30:00 --cpus-per-task=2 --mem=4G /bin/bash
module load Anaconda3/2024.06-1
## Optional: only load a Gurobi module if you are not using the conda-provided Gurobi.
## For WLS licensing with conda-installed Gurobi, leave this unset.
export ARC_GUROBI_MODULE=""
source $EBROOTANACONDA3/etc/profile.d/conda.sh
conda activate /data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env-gurobi
python -c "import sys; print(sys.version)"
python -c "import gurobipy; print(gurobipy.gurobi.version())"
snakemake --version
```

Each future Snakemake run only needs:

```bash
module load Anaconda3/2024.06-1
## Optional: only load a Gurobi module if you are not using the conda-provided Gurobi.
export ARC_GUROBI_MODULE=""
source $EBROOTANACONDA3/etc/profile.d/conda.sh
conda activate /data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env-gurobi
export GRB_LICENSE_FILE=/data/engs-df-green-ammonia/engs2523/licenses/gurobi.lic
cd /data/engs-df-green-ammonia/engs2523/pypsa-earth
```

### 3. Baseline single-snapshot Europe run

1. Copy `config/default-single-timestep.yaml` into the PyPSA-Earth root (`config/` already exists). It pins:
   - geographic scope to continental Europe,
   - clustering to 37 buses,
   - a single snapshot (`2013-01-01 00:00Z`),
   - Gurobi as the solver (HiGHS remains as a commented fallback),
   - a unique run name: `run.name = europe`.

> First-time runs need to download cutouts, osm extracts, and databundles (tens of GB). To get that out of the way, run `snakemake --cores 8 retrieve_databundle_light download_osm_data build_cutout` (or submit the batch script with `ARC_STAGE_DATA=1`) before attempting the full solve.

2. Perform a lightweight dry-run before the actual execution. Recent PyPSA-Earth releases renamed the master rule to `solve_network`; if you ever hit a `MissingRuleException`, double-check via `snakemake --list` to see the available targets:

   ```zsh
   snakemake -call solve_network -n \
     --configfile config/default-single-timestep.yaml
   ```

3. Once the DAG looks reasonable (≈15 rules thanks to the single snapshot), launch the real job either interactively or via Slurm. With 16 threads the run usually wraps in <30 minutes because all time-series collapse to one hour.

   ```zsh
   snakemake -call solve_network \
     --configfile config/default-single-timestep.yaml \
     -j 16 --resources mem_mb=32000 --keep-going --rerun-incomplete
   ```

4. To run on ARC with Gurobi, submit the job script (it loads the Gurobi module and activates the conda env):

    ```zsh
    sbatch /data/engs-df-green-ammonia/engs2523/20251117-pypsa-earth-project/scripts/arc/jobs/arc_snakemake_gurobi.sh \
       europe config/default-single-timestep.yaml
    ```

5. The solved network will appear at `results/europe/networks/elec_s_37_ec_lcopt_Co2L-3h.nc`. Inspect it via PyPSA or `pypsa-eur/scripts/plotting.py` to verify the objective value and generation mix look sensible.

### 4. Core technology limiter scenario

1. Layer `config/overrides/core-technologies.yaml` on top of `config/default-single-timestep.yaml`. The override reuses whatever snapshot window the baseline config defines, renames the run to `europe-day-core-tech`, adds the `limit_core_technologies` hook, and passes the curated carrier lists via `custom.core_technologies`.
2. Run Snakemake the same way as the baseline but append the override on the command line:

    ```zsh
    snakemake -call solve_all_networks \
       --configfile config/default-single-timestep.yaml \
       --configfile config/overrides/core-technologies.yaml \
       -j 8 --resources mem_mb=24000 --keep-going --rerun-incomplete --printshellcmds
    ```

    Expect to see `Loaded 1 extra_functionality hook(s): scripts.extra.limit_core_technologies.limit_core_technologies` in the log.
3. The solved network lands in `results/europe-day-core-tech/networks/elec_s_140_ec_lcopt_Co2L-3h.nc`, which matches the file path referenced in `notebooks/001_run_analysis_europe.ipynb`. Inspect the `logs/europe-day-core-tech/solve_network/*` files if anything goes wrong.

### 5. Green ammonia scenario

1. The override file `config/overrides/green-ammonia.yaml` switches on a custom extra-functionality hook (`scripts/extra/green_ammonia.py`). The script injects a full hydrogen-to-ammonia chain at the closest Spanish transmission node to Seville (lon = −5.98, lat = 37.41):
   - An **electrolyser link** drawing electricity from the local AC bus into a hydrogen bus.
   - **Hydrogen buffer stores** (pressurised tank and salt cavern variants) sharing that bus.
   - A **Haber-Bosch synthesis link** that converts hydrogen into ammonia with a minimum load of 20%.
   - An **ammonia tank store** sized independently from the hydrogen buffers.
   - An **ammonia-fuelled CCGT link** converting stored ammonia back to electricity.

2. The script reads techno-economic parameters (CAPEX, efficiency limits, standing losses, and build caps) from the config file so you can iterate quickly.

3. Run Snakemake with both config files so the ammonia overrides apply on top of the baseline defaults:

   ```zsh
    snakemake -call solve_network \
     --configfile config/default-single-timestep.yaml \
     --configfile config/overrides/green-ammonia.yaml \
       -j 16 --resources mem_mb=32000 --keep-going
   ```

4. Compare `results/europe-green-ammonia/networks/base_s_37_elec_.nc` with the baseline network. Focus on:
   - `network.links.p_nom_opt` entries containing `NH3` – positive values mean the optimiser built ammonia capacity.
   - `network.stores.e_nom_opt` for the ammonia store.
   - Marginal prices at the Spanish bus to see if ammonia arbitrage affects congestion costs.

### 6. Submitting through ARC Slurm

The helper script `scripts/arc/jobs/arc_snakemake.sh` wraps the Snakemake commands in a Slurm batch job. It now activates the micromamba-managed environment (via the `conda-tools` helper), can optionally pre-stage the large data downloads, and understands a dry-run mode. Submit as follows (override the partition/time on the command line when you expect long data transfers):

```zsh
ARC_STAGE_DATA=1 ARC_SNAKE_DRYRUN=1 \
  sbatch --partition=long --time=24:00:00 scripts/arc/jobs/arc_snakemake.sh 20251205-baseline \
   config/default-single-timestep.yaml
sbatch scripts/arc/jobs/arc_snakemake.sh 20251205-core-tech \
   config/default-single-timestep.yaml config/overrides/core-technologies.yaml
sbatch scripts/arc/jobs/arc_snakemake.sh 20251205-green \
   config/default-single-timestep.yaml config/overrides/green-ammonia.yaml
```

> Need Gurobi? Use `scripts/arc/jobs/arc_snakemake_gurobi.sh` instead. It loads the `Gurobi/10.0.3-GCCcore-12.2.0` module by default (override via `ARC_GUROBI_MODULE`), exports `PYPSA_SOLVER_NAME=gurobi`, and writes stats/logs with a `-gurobi` suffix. Stack your usual config files after the run label: `sbatch scripts/arc/jobs/arc_snakemake_gurobi.sh 20251202-green config/...`

The first positional argument is just a run label for log filenames (pick anything meaningful, e.g. `yyyymmdd-scenario`). All following arguments are forwarded to Snakemake via repeated `--configfile` flags, so stack the baseline config first and any overrides after it.

Environment/module tips for ARC submissions:

- Set `ARC_WORKDIR=/data/engs-df-green-ammonia/engs2523/pypsa-earth` (or similar) before `sbatch` so that the job runs inside the large shared filesystem automatically.
- Set `ARC_ANACONDA_MODULE=Anaconda3/<version>` if you need a newer module than the default (`Anaconda3/2023.09`).
- Set `ARC_CONDA_TOOLS=/data/.../envs/conda-tools` and `ARC_PYPSA_ENV=/data/.../envs/pypsa-earth-env` if your helper environments live in a different directory.
- Set `ARC_STAGE_DATA=1` to have the job run `retrieve_databundle_light`/`download_osm_data` (and `build_cutout` if enabled) *before* solving.
- Set `ARC_SNAKE_DRYRUN=1` to have the final Snakemake call pass `-n` so you can inspect the DAG without running any rules.
- If you need extra solver modules (e.g. `module load Gurobi/11.0.3`), add them near the top of `scripts/arc/jobs/arc_snakemake.sh` just after the Anaconda load.

### 7. Validating outputs

Because the runs only use one snapshot, the quickest sanity checks are:

- **Load coverage**: `network.loads_t.p` vs `network.generators_t.p` summed per snapshot.
- **Capacity build**: inspect `p_nom_opt`/`e_nom_opt` columns for extendable carriers.
- **Shadow prices**: `network.buses_t.marginal_price` for the Spanish node – expect values close to the marginal technology cost (OCGT or ammonia CCGT in the stressed case).

Add a small plotting notebook (e.g. `notebooks/compare_runs.ipynb`) if you want visual confirmation—PyPSA makes it trivial to graph dispatch stacks for a single snapshot.

## Repository contents

| File / Folder | Purpose |
| --- | --- |
| `config/default-single-timestep.yaml` | Baseline overrides for a Europe-wide, single-snapshot PyPSA-Earth run. |
| `config/overrides/core-technologies.yaml` | Layers the core-technology limiter hook on top of the baseline run (`run.name = europe-day-core-tech`). |
| `config/overrides/green-ammonia.yaml` | Layered config that injects the ammonia assets and switches the output directories. |
| `scripts/extra/green_ammonia.py` | Extra-functionality hook loaded by Snakemake to add the electrolyser, store, and ammonia CCGT components. |
| `scripts/extra/limit_core_technologies.py` | Keeps generation/storage carriers to a curated subset for the baseline sanity-check runs. |
| `scripts/arc/jobs/arc_snakemake.sh` | Slurm helper for ARC – wraps module loads, environment activation, and the relevant Snakemake commands. |

Feel free to extend this repo with additional overrides (longer time slices, different nodes, capacity-value sweeps, etc.).

## Troubleshooting tips

- **Download bottlenecks**: First runs spend most time fetching data. Use `snakemake -c retrieve_databundle` to stage inputs before submitting the solver job.
- **Module availability**: If `Anaconda3/2023.09` is missing, run `module avail Anaconda3` and pick the closest version. All that matters is having Python ≥3.10.
- **Solver memory errors**: Increase `mem` in `config/default-single-timestep.yaml` or request more memory in the Slurm script.
- **Ammonia assets not appearing**: Confirm the extra-functionality hook ran (Snakemake log will mention "Injecting green ammonia"), and ensure the override config is listed last so it can overwrite `run.name` and `solving.options.extra_functionality`.

## Next steps

- Scale to more timestamps once the single-hour sanity checks pass.
- Replace hard-coded techno-economic values with references to `data/technology-data`.
- Push results to a tracking folder (`results/arc/yyyymmdd/`) and add a comparison notebook.

Good luck, and ping if you need help extending the ammonia design! 🎯
