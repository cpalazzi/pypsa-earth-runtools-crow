# PyPSA-Earth ARC Runner

This repository packages a lightweight set of overrides, scripts, and HPC job templates to run three PyPSA-Earth experiments on the Oxford Advanced Research Computing (ARC) cluster:

1. **Baseline sanity check** – default European electricity-only run with a single snapshot.
2. **Core technology limiter** – layers the `limit_core_technologies` hook on top of the baseline (without changing the snapshot window) to ensure the custom extra-functionality entry points load correctly. This is now our primary “extra hook” test.
3. **Green ammonia stress test** – same setup but with an endogenous green-ammonia supply chain (electrolyser → storage → ammonia-fired CCGT) anchored at a node in southern Spain.

The files in this repo are meant to be layered on top of our patched [`pypsa-earth`](https://github.com/cpalazzi/pypsa-earth) fork (which itself tracks the upstream project). You will copy them into that PyPSA-Earth working tree (or add this repo as a Git submodule) and refer to the supplied config files & scripts via Snakemake.

> **Oxford ARC login**: `engs2523@arc-login.arc.ox.ac.uk`

> **Automation note (SSH)**:
> - The AI agent cannot respond to interactive prompts (including password prompts) when it runs commands.
> - If SSH prompts for a password, run the provided `ssh user@host "<commands>"` command yourself in a terminal, type the password when prompted, then paste the output back into the chat.
> - If you want the agent to run SSH commands end-to-end without you intervening, set up key-based SSH auth (or another non-interactive method supported by your environment) so `ssh -o BatchMode=yes ...` works.
> - Prefer a single SSH command that executes all needed remote commands (e.g., `ssh user@host "<commands>"`) rather than an interactive session, so outputs are easy to capture and share.

> **Lock cleanup note**: If a run fails early (or a previous job was killed), Snakemake may leave a lock in the PyPSA-Earth working directory. Before resubmitting, clear the lock and any stale job outputs:
> 1) Ensure no other Snakemake jobs are running (`squeue -u <user>`). 2) Unlock with the full conda path: `/data/.../envs/pypsa-earth-env/bin/snakemake --unlock` from the repo root. 3) Remove stale `slurm-<jobid>.out` files only if you no longer need them.

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
   rsync -av ../pypsa-earth-runtools-crow/config/ ./config/ &&
   rsync -av ../pypsa-earth-runtools-crow/scripts/extra/ ./scripts/extra/ &&
   rsync -av ../pypsa-earth-runtools-crow/scripts/arc/jobs/ ./jobs/
   ```

3. Create/activate the PyPSA-Earth environment (use the provided conda-based Slurm script so you do not have to babysit a long interactive job).
4. Dry-run Snakemake with the baseline config to confirm the DAG is tiny.
5. Submit the baseline job via the supplied ARC Slurm script.
6. Re-run Snakemake with the **core-technology override** to exercise `scripts/extra/limit_core_technologies.py` (it inherits the timeline from the baseline config).
7. Layer on the green-ammonia override once the limiter test succeeds.

The sections below dive into each step, list the exact commands, and explain how to interpret the results.

## Environments and data prerequisites

### Environment Strategy: venv locally, conda on ARC

**Why two approaches?**
- **Local (`.venv`** with pip): Lightweight, just for analysis. No Gurobi, Snakemake, or heavy GIS dependencies.
- **ARC (conda)**: Full featured, includes Gurobi, Snakemake, and preprocessing tools.

Both pin **PyPSA 0.28.0**.

### Local (laptop/workstation) environment for analysis

For local analysis (e.g., reading and plotting results), use the `.venv` venv with lightweight dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate  # on Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

This installs PyPSA 0.28.0, xarray, geopandas, matplotlib, and other essentials for downloading and analyzing results. No Gurobi, Snakemake, or heavy GIS compilation needed locally.

### ARC remote environment for simulation (conda-based)

On ARC, we use conda to manage the full PyPSA-Earth environment. This includes Snakemake, Gurobi solver, and all preprocessing tools. The environment is built from `envs/environment.yaml` in the PyPSA-Earth repo.

**Key points**:
- **Source of truth**: `envs/environment.yaml` in the PyPSA-Earth repo
- **Build process**: Use `scripts/arc/build-pypsa-earth-env` Slurm script
- **Solver**: Gurobi (module on ARC); HiGHS as fallback
- **Data**: Auto-downloads cutouts if `enable.retrieve_databundle: true`
- **Storage**: Work in `$DATA/<project>/<user>`, not home (~15 GB limit)

## Terminal Workflow: Local vs. ARC Sessions

When working with this project, you will switch between **local (your laptop)** and **ARC (remote HPC)** terminals. Understanding which terminal you're in is critical for knowing whether to use `ssh` wrappers or run commands directly.

### Identifying Your Terminal

Check the shell prompt:
- **Local machine**: Shows your laptop hostname, e.g. `carlopalazzi@macbook ~ %` or `user@laptop:~$`
- **ARC login node**: Shows ARC hostname, e.g. `[engs2523@arc-login04 engs2523]$`

### Working Patterns

**Pattern 1: Running from local terminal (most secure for scripts)**
- Keep your terminal in your local directory: `/Users/carlopalazzi/programming/pypsa_models/pypsa-earth-runtools-crow`
- Use `ssh -n` wrappers to run ARC commands remotely:
  ```bash
  ssh -n engs2523@arc-login.arc.ox.ac.uk 'cd /data/engs-df-green-ammonia/engs2523/pypsa-earth && squeue -u engs2523'
  ```
- **Advantage**: Explicit, reproducible, doesn't depend on session state; good for automation and scripts.
- **Disadvantage**: Requires password for each command (unless key-based auth is set up).

**Pattern 2: Running from ARC terminal (fast for interactive debugging)**
- First, log into ARC once: `ssh engs2523@arc-login.arc.ox.ac.uk`
- Your prompt becomes `[engs2523@arc-login04 ...]$`
- Run commands directly without `ssh` wrappers:
  ```bash
  squeue -u engs2523
  cd /data/engs-df-green-ammonia/engs2523/pypsa-earth
  ```
- To return to local: type `exit`
- **Advantage**: Fast, no repeated password prompts, natural for exploratory work.
- **Disadvantage**: Easy to forget you're on ARC; session ends if connection drops.

### Recommended Workflow

1. **For submission and monitoring**: Use Pattern 2 (ARC terminal session)
   - SSH into ARC once at the start of a session
   - Submit jobs, check `squeue`, tail logs directly
   - Exit when done

2. **For config edits and version control**: Work locally (Pattern 1)
   - Edit configs in your laptop editor
   - Commit/push to GitHub
   - Pull on ARC to sync changes

3. **For automation/CI**: Use Pattern 1 (ssh wrappers)
   - Explicit remote execution
   - Reproducible and debuggable

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
scp -r carlo@your-laptop:~/programming/pypsa_models/pypsa-earth-runtools-crow ./pypsa-earth-runtools-crow
rsync -av pypsa-earth-runtools-crow/config/ pypsa-earth/config/
rsync -av pypsa-earth-runtools-crow/scripts/extra/ pypsa-earth/scripts/extra/
rsync -av pypsa-earth-runtools-crow/scripts/arc/jobs/ pypsa-earth/jobs/
```

> Prefer `rsync` over `cp` so the directory structure is preserved. You can also keep this helper repo as a Git submodule inside `pypsa-earth` if you want to version-lock future tweaks.

### 2. Create and activate the environment (conda-only on ARC)

The repo ships `scripts/arc/build-pypsa-earth-env`, a Slurm job that:

- uses the ARC Anaconda module,
- creates a conda environment at `/data/…/envs/pypsa-earth-env` from PyPSA-Earth’s `envs/environment.yaml` and installs the Gurobi Python bindings, and
- logs the resulting package set for future diffing.

Submit it any time you need a clean environment:

```bash
cd /data/engs-df-green-ammonia/engs2523/pypsa-earth
sbatch /data/engs-df-green-ammonia/engs2523/pypsa-earth-runtools-crow/scripts/arc/build-pypsa-earth-env
squeue -u engs2523                   # watch progress
tail -f /data/engs-df-green-ammonia/engs2523/pypsa-earth/slurm-<jobid>.out
```

Once the build job mails you (or the log stops growing) jump into a short interactive session to verify:

```bash
srun --pty --partition=interactive --time=00:30:00 --cpus-per-task=2 --mem=4G /bin/bash
module load Anaconda3/2024.06-1
## Optional: only load a Gurobi module if you are not using the conda-provided Gurobi.
## For WLS licensing with conda-installed Gurobi, leave this unset to avoid ABI mismatches.
export ARC_GUROBI_MODULE=""
source $EBROOTANACONDA3/etc/profile.d/conda.sh
conda activate /data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env
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
conda activate /data/engs-df-green-ammonia/engs2523/envs/pypsa-earth-env
export GRB_LICENSE_FILE=/data/engs-df-green-ammonia/engs2523/licenses/gurobi.lic
cd /data/engs-df-green-ammonia/engs2523/pypsa-earth
```

### Important: Configuration alignment for overrides

⚠️ **Keep config overrides in sync with base configs**

When using `--configfile config/overrides/core-technologies.yaml` (or any override), ensure that the **geographic scope** (countries list) and **nodal clustering** (clusters setting) remain **aligned with the base config**. The override files do NOT inherit the base config's countries/clusters settings—they are layered on top and can silently override them.

For example:
- `config/day-core-technologies.yaml` defines a **17-country scope with 70 clusters**.
- `config/overrides/core-technologies.yaml` **must also list those same 17 countries and 70 clusters**.
- If you update the base config's country list but forget to update the override, the override will (unintentionally) expand the scope or mismatch clustering.

**Current alignment** (as of January 2026):
- **day-threehour.yaml**: 17 countries, 70 clusters
- **day-core-technologies.yaml**: 17 countries, 70 clusters (aligned)
- **overrides/core-technologies.yaml**: 17 countries, 70 clusters (aligned)

**If you modify any config's geographic or clustering settings**, search for the same settings in all related override files and update them to match. The comment headers in each override file explicitly state which base config they are paired with and what scope is expected.

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

4. To run on ARC with Gurobi, submit the job script (it uses the conda Gurobi install and WLS license):

    ```zsh
   sbatch /data/engs-df-green-ammonia/engs2523/pypsa-earth-runtools-crow/scripts/arc/jobs/arc_snakemake_gurobi.sh \
       europe config/default-single-timestep.yaml
    ```

5. The solved network will appear at `results/europe/networks/elec_s_140_ec_lcopt_Co2L-3h.nc`. Inspect it via PyPSA or `pypsa-eur/scripts/plotting.py` to verify the objective value and generation mix look sensible.

### 3b. Yearly 3-hour runs

1. **Yearly base (standard CO2 cap preset)**

    ```zsh
   sbatch /data/engs-df-green-ammonia/engs2523/pypsa-earth-runtools-crow/scripts/arc/jobs/arc_snakemake_gurobi.sh \
       europe-yearly-3h config/yearly-threehour.yaml
    ```

2. **Yearly zero-CO2**

    ```zsh
   sbatch /data/engs-df-green-ammonia/engs2523/pypsa-earth-runtools-crow/scripts/arc/jobs/arc_snakemake_gurobi.sh \
       europe-yearly-3h-zero config/yearly-threehour-zero-co2.yaml
    ```

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

### Performance tips

- **Pre-stage data**: run `retrieve_databundle_light`, `download_osm_data`, and `build_cutout` once to avoid repeated downloads.
- **Reduce clustering**: drop `clusters` from 140 to 37 for faster iterations.
- **Keep snapshots coarse**: retain `Co2L-3h` for 3-hour aggregation.
- **Tune solver threads**: set Gurobi `Threads` in solver options if needed.
- **Avoid module mismatches**: keep `ARC_GUROBI_MODULE` unset when using conda-installed Gurobi.

### Troubleshooting notes

- **`retrieve_cost_data` fails with a `FileNotFoundError`**: Root cause is a PyPSA-Earth `Snakefile` bug when moving Snakemake `HTTP.remote(..., keep_local=True)` inputs.
   - Fix is tracked in the separate `pypsa-earth` repo (not this overlay): open a PR from branch `fix/retrieve-cost-data-local-path` in `https://github.com/cpalazzi/pypsa-earth`.
   - Upstream reference (buggy line): `https://github.com/pypsa-meets-earth/pypsa-earth/blob/main/Snakefile#L445-L449`.
   - TODO: submit the local PyPSA-Earth patches from `/Users/carlopalazzi/programming/pypsa_models/pypsa-earth` upstream once validated (including the retrieve_cost_data fix).

- **`cluster_network` fails with an assertion about `n_clusters`**: For the reduced country list in [config/day-threehour.yaml](config/day-threehour.yaml), Snakemake enforces a minimum of 70 clusters. Set `scenario.clusters` to 70+ (50 will fail with “Number of clusters must be 70 <= n_clusters <= …”).

- **Renewable profiles take hours**: Reducing `clusters` speeds the *network size*, but the atlite availability-matrix step can still dominate runtime because it’s upstream of the solve.

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
