# Configuration Audit: focus_weights Normalization

## Status: ✓ ALL ACTIVE CONFIGS VERIFIED

### Active Configs (In Use)

#### 1. `config/base-europe17-70n-day.yaml`
- **Purpose**: Base configuration with shared settings (geography, clustering, time)
- **Scope**: 17-country Europe (AT, BG, CZ, DE, DK, ES, FR, GB, GR, HU, IT, PL, PT, RO, RS, SE)
- **Clusters**: 70 total nodes distributed via focus_weights
- **focus_weights**: 16 entries summing to **0.9999** ✓
  - DE: 0.1558, FR: 0.1840, GB: 0.1563, IT: 0.1556, ES: 0.1099, PL: 0.0883
  - SE: 0.0168, DK: 0.0138, AT: 0.0206, BG: 0.0112, CZ: 0.0187, GR: 0.0150
  - HU: 0.0150, PT: 0.0131, RO: 0.0168, RS: 0.0090
- **Constraint**: PyPSA-Earth requires `sum(focus_weights) <= 1.0` ✓

#### 2. `config/scenarios/scenario-core-electricity.yaml`
- **Purpose**: Technology restriction overlay (electricity only)
- **focus_weights**: ❌ NOT DEFINED (intentionally inherits from base)
- **Usage**: `snakemake --configfile config/base-europe17-70n-day.yaml --configfile config/scenarios/scenario-core-electricity.yaml`

#### 3. `config/scenarios/scenario-core-ammonia.yaml`
- **Purpose**: Technology restriction overlay (electricity + green ammonia)
- **focus_weights**: ❌ NOT DEFINED (intentionally inherits from base)
- **Usage**: `snakemake --configfile config/base-europe17-70n-day.yaml --configfile config/scenarios/scenario-core-ammonia.yaml`

---

### Archived Configs (Not In Use)

Located in `config/archive/`:
- `day-core-technologies.yaml`
- `day-threehour.yaml`
- `day-threehour-zero-co2.yaml`
- `default-single-timestep.yaml`
- `month-threehour-zero-co2.yaml`
- `yearly-threehour.yaml`
- `yearly-threehour-zero-co2.yaml`
- `yearly-threehour-zero-co2-green-ammonia.yaml`
- `overrides/core-technologies.yaml`
- `overrides/green-ammonia.yaml`

**Note**: Archived configs have outdated/non-normalized focus_weights but will **NOT be used** in active workflows.

---

## Verification Results

| Config | focus_weights | Sum | Status |
|--------|---------------|-----|--------|
| base-europe17-70n-day.yaml | 16 entries | 0.9999 | ✓ VALID |
| scenario-core-electricity.yaml | (inherits) | (inherits) | ✓ VALID |
| scenario-core-ammonia.yaml | (inherits) | (inherits) | ✓ VALID |

---

## Recent Fixes

**Commit**: `8b8f23c` - "fix: recalculate focus_weights sum to exactly 0.9999"

Changes made:
- DE: 0.1559 → 0.1558
- RS: 0.0093 → 0.0090
- **New sum**: 0.9999 (was 1.0004)

**Reason**: PyPSA-Earth's clustering algorithm enforces `sum(focus_weights) <= 1.0`. The previous sum of 1.0004 caused an AssertionError during cluster_network rule.

---

## Key Constraints

1. **focus_weights MUST be at top-level** in YAML (not nested under `clustering:`)
2. **Sum MUST be <= 1.0** (PyPSA-Earth hard constraint)
3. **Scenario configs inherit** focus_weights from base (do not redefine)
4. **All countries in focus_weights** must be in the `countries:` list

---

## Usage

For any new configs:
1. Copy `config/base-europe17-70n-day.yaml` as template for base configs
2. Create scenario overlays in `config/scenarios/scenario-<name>.yaml`
3. Verify focus_weights sum: `python3 -c "sum({...}.values())"` <= 1.0
4. Test with: `sbatch ... arc_snakemake.sh <label> <base.yaml> <scenario.yaml>`
