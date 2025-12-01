"""Custom extra functionality hook for PyPSA-Earth.

The ``add_green_ammonia`` entry point is referenced from
``solving.options.extra_functionality``.  When enabled, it injects a full
hydrogen-to-ammonia supply chain near the requested bus:

* Electricity-to-H2 electrolyser link.
* One or more hydrogen buffer stores (e.g. tank + cavern variants).
* Haber-Bosch style H2-to-NH3 synthesis link with a configurable minimum load.
* NH3 tank store.
* NH3-fuelled CCGT back to the AC grid.

All techno-economic assumptions live in
``config/overrides/green-ammonia.yaml`` under ``custom.green_ammonia``.
"""

from __future__ import annotations

from math import inf
from typing import Any, Dict, Optional

import numpy as np
import pandas as pd

try:
    import pypsa  # type: ignore
except ImportError as exc:  # pragma: no cover - only executed inside snakemake
    raise RuntimeError("PyPSA must be installed in the runtime environment") from exc


def _get_cfg(config: Dict[str, Any]) -> Dict[str, Any]:
    """Pull the nested green ammonia dictionary or return an empty dict."""

    return config.get("custom", {}).get("green_ammonia", {})


def _ensure_carrier(network: "pypsa.Network", name: str) -> None:
    """Create a carrier if it does not already exist."""

    if name in network.carriers.index:
        return
    network.add("Carrier", name)


def _closest_bus(
    network: "pypsa.Network",
    country_code: str,
    latitude: Optional[float],
    longitude: Optional[float],
    bus_substring: Optional[str] = None,
) -> str:
    """Pick the closest bus inside ``country_code`` to the provided lat/lon."""

    candidates = network.buses[network.buses.country == country_code]
    if candidates.empty:
        raise ValueError(
            f"No buses found for country '{country_code}'. Did you run add_electricity?"
        )

    if bus_substring:
        narrowed = candidates[candidates.index.str.contains(bus_substring)]
        if not narrowed.empty:
            candidates = narrowed

    if latitude is None or longitude is None:
        return candidates.index[0]

    coords = candidates[["y", "x"]].to_numpy(dtype=float)
    target = np.array([latitude, longitude], dtype=float)
    distances = np.linalg.norm(coords - target, axis=1)
    idx = distances.argmin()
    return candidates.index[idx]


def _add_bus(
    network: "pypsa.Network",
    base_bus: str,
    suffix: str,
    carrier: str,
) -> str:
    base = network.buses.loc[base_bus]
    label = f"{base_bus}-{suffix}"
    if label in network.buses.index:
        return label
    network.add(
        "Bus",
        label,
        x=base.x,
        y=base.y,
        country=base.country,
        carrier=carrier,
        sub_network=base.get("sub_network", "")
        if isinstance(base, pd.Series)
        else None,
    )
    return label


def _ensure_link_timeseries(
    network: "pypsa.Network",
    attr: str,
    snapshots,
) -> pd.DataFrame:
    idx = pd.Index(snapshots)
    if not hasattr(network.links_t, attr):
        setattr(network.links_t, attr, pd.DataFrame(index=idx))
    df = getattr(network.links_t, attr)
    if df.index.empty and len(idx):
        df.index = idx
    elif not df.index.equals(idx):
        df = df.reindex(idx, fill_value=0.0)
        setattr(network.links_t, attr, df)
    return df


def _set_link_min_pu(
    network: "pypsa.Network",
    snapshots,
    label: str,
    min_pu: Optional[float],
) -> None:
    if min_pu is None:
        return
    df = _ensure_link_timeseries(network, "p_min_pu", snapshots)
    df.loc[:, label] = float(min_pu)
    network.links.loc[label, "p_min_pu"] = float(min_pu)


def _add_electrolyser(
    network: "pypsa.Network",
    base_bus: str,
    h2_bus: str,
    cfg: Dict[str, Any],
    carrier_name: str,
) -> None:
    label = f"{base_bus}-Elec-to-H2"
    if label in network.links.index:
        return
    network.add(
        "Link",
        label,
        bus0=base_bus,
        bus1=h2_bus,
        carrier=carrier_name,
        efficiency=cfg.get("efficiency", 0.62),
        capital_cost=cfg.get("capital_cost", 7.5e5),
        marginal_cost=cfg.get("marginal_cost", 1.0),
        lifetime=cfg.get("lifetime", 20),
        p_nom_extendable=cfg.get("p_nom_extendable", True),
        p_nom_min=cfg.get("p_nom_min", 0.0),
        p_nom_max=cfg.get("p_nom_max", inf),
    )


def _add_store(
    network: "pypsa.Network",
    label: str,
    bus: str,
    cfg: Dict[str, Any],
    carrier_default: str,
) -> None:
    if label in network.stores.index:
        return
    carrier = cfg.get("carrier", carrier_default)
    _ensure_carrier(network, carrier)
    network.add(
        "Store",
        label,
        bus=bus,
        carrier=carrier,
        e_cyclic=cfg.get("e_cyclic", True),
        standing_loss=cfg.get("standing_loss", 0.0),
        capital_cost=cfg.get("capital_cost", 1.5e5),
        e_nom_extendable=cfg.get("e_nom_extendable", True),
        e_nom_min=cfg.get("e_nom_min", 0.0),
        e_nom_max=cfg.get("e_nom_max", inf),
        marginal_cost=cfg.get("marginal_cost", 0.0),
    )


def _add_synthesis(
    network: "pypsa.Network",
    h2_bus: str,
    nh3_bus: str,
    cfg: Dict[str, Any],
    carrier_name: str,
    snapshots,
) -> None:
    label = f"{nh3_bus}-synthesis"
    if label in network.links.index:
        return
    network.add(
        "Link",
        label,
        bus0=h2_bus,
        bus1=nh3_bus,
        carrier=carrier_name,
        efficiency=cfg.get("efficiency", 0.9),
        capital_cost=cfg.get("capital_cost", 1.1e6),
        marginal_cost=cfg.get("marginal_cost", 1.5),
        lifetime=cfg.get("lifetime", 25),
        p_nom_extendable=cfg.get("p_nom_extendable", True),
        p_nom_min=cfg.get("p_nom_min", 0.0),
        p_nom_max=cfg.get("p_nom_max", inf),
    )
    _set_link_min_pu(network, snapshots, label, cfg.get("min_pu"))


def _add_ccgt(
    network: "pypsa.Network",
    base_bus: str,
    nh3_bus: str,
    cfg: Dict[str, Any],
    carrier_name: str,
) -> None:
    label = f"{base_bus}-NH3-CCGT"
    if label in network.links.index:
        return
    network.add(
        "Link",
        label,
        bus0=nh3_bus,
        bus1=base_bus,
        carrier=carrier_name,
        efficiency=cfg.get("efficiency", 0.55),
        capital_cost=cfg.get("capital_cost", 9e5),
        marginal_cost=cfg.get("marginal_cost", 2.5),
        lifetime=cfg.get("lifetime", 25),
        p_nom_extendable=cfg.get("p_nom_extendable", True),
        p_nom_min=cfg.get("p_nom_min", 0.0),
        p_nom_max=cfg.get("p_nom_max", inf),
    )


def add_green_ammonia(
    network: "pypsa.Network",
    snapshots,
    config: Dict[str, Any],
    **_,
) -> None:
    """Entry point expected by Snakemake's ``extra_functionality`` hook."""

    ga_cfg = _get_cfg(config)
    if not ga_cfg.get("enable", False):
        return

    country = ga_cfg.get("country_code", "ES")
    location = ga_cfg.get("location", {})
    base_bus = _closest_bus(
        network,
        country,
        location.get("latitude"),
        location.get("longitude"),
        location.get("bus_substring"),
    )

    carriers = ga_cfg.get("carriers", {})
    carrier_h2 = carriers.get("hydrogen", "H2")
    carrier_h2_store_default = carriers.get("hydrogen_store", f"{carrier_h2}-store")
    carrier_elec_to_h2 = carriers.get("elec_to_h2", "Elec->H2")
    carrier_synthesis = carriers.get("h2_to_nh3", "H2->NH3")
    carrier_nh3 = carriers.get("ammonia", "NH3")
    carrier_nh3_store = carriers.get("ammonia_store", "NH3-tank")
    carrier_ccgt = carriers.get("nh3_to_power", "NH3->power")

    for name in (
        carrier_h2,
        carrier_h2_store_default,
        carrier_elec_to_h2,
        carrier_synthesis,
        carrier_nh3,
        carrier_nh3_store,
        carrier_ccgt,
    ):
        _ensure_carrier(network, name)

    suffixes = ga_cfg.get("bus_suffixes", {})
    h2_bus = _add_bus(network, base_bus, suffixes.get("hydrogen", "H2"), carrier_h2)
    nh3_bus = _add_bus(network, base_bus, suffixes.get("ammonia", "NH3"), carrier_nh3)

    _add_electrolyser(
        network,
        base_bus,
        h2_bus,
        ga_cfg.get("electrolyser", {}),
        carrier_elec_to_h2,
    )
    hydrogen_multi = ga_cfg.get("hydrogen_storages")
    if isinstance(hydrogen_multi, dict) and hydrogen_multi:
        for suffix, storage_cfg in hydrogen_multi.items():
            _add_store(
                network,
                f"{h2_bus}-{suffix}",
                h2_bus,
                storage_cfg,
                carrier_h2_store_default,
            )
    else:
        hydrogen_cfg = ga_cfg.get("hydrogen_storage", {})
        if hydrogen_cfg:
            _add_store(
                network,
                f"{h2_bus}-store",
                h2_bus,
                hydrogen_cfg,
                carrier_h2_store_default,
            )
    _add_synthesis(
        network,
        h2_bus,
        nh3_bus,
        ga_cfg.get("synthesis", {}),
        carrier_synthesis,
        snapshots,
    )
    _add_store(
        network,
        f"{nh3_bus}-{ga_cfg.get('ammonia_storage_suffix', 'tank')}",
        nh3_bus,
        ga_cfg.get("ammonia_storage", ga_cfg.get("storage", {})),
        carrier_nh3_store,
    )
    _add_ccgt(network, base_bus, nh3_bus, ga_cfg.get("ccgt", {}), carrier_ccgt)

    print(  # pragma: no cover - informational log inside snakemake
        "Injected green-ammonia chain at"
        f" {base_bus}: electrolyser, H2 store, synthesis, NH3 store, CCGT"
    )
