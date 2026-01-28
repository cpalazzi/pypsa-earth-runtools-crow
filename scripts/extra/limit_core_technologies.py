"""Extra-functionality hook that prunes generators and storage to a core tech set."""

from __future__ import annotations

from typing import Any, Dict, Iterable, Optional

try:  # pragma: no cover - executed within PyPSA-Earth runtime
    import pypsa  # type: ignore
except ImportError as exc:  # pragma: no cover
    raise RuntimeError("PyPSA must be available when running the extra functionality") from exc

DEFAULT_GENERATORS = {
    "CCGT",
    "nuclear",
    "onwind",
    "offwind-ac",
    "offwind-dc",
    "solar",
}
DEFAULT_STORAGES = {"PHS", "battery", "gas"}
DEFAULT_LINKS = {"DC", "gas pipeline"}  # Electricity transmission + gas transport

COMPONENT_ATTR = {
    "Generator": "generators",
    "Store": "stores",
    "StorageUnit": "storage_units",
    "Link": "links",
}


def _drop_components(network: "pypsa.Network", component: str, keep_index: Iterable[str]) -> None:
    keep = set(keep_index)
    frame_name = COMPONENT_ATTR.get(component)
    if frame_name is None:
        raise ValueError(f"Unsupported component '{component}' passed to limiter")
    frame = getattr(network, frame_name)
    carriers = frame.get("carrier")
    if carriers is None:
        return
    drop_idx = carriers[~carriers.isin(keep)].index
    if drop_idx.empty:
        return
    try:
        network.mremove(component, drop_idx)
    except AttributeError:  # pragma: no cover - fallback for older PyPSA versions
        for name in drop_idx:
            network.remove(component, name)
    print(f"Removed {len(drop_idx)} {component.lower()}(s) outside the allowed carrier list")


def limit_core_technologies(
    network: "pypsa.Network",
    snapshots,
    config: Optional[Dict[str, Any]] = None,
    **_,
) -> None:
    """Keep only the requested carrier sets for generators, storage, and links."""

    cfg: Dict[str, Any] = config or getattr(network, "config", {})
    custom_cfg: Dict[str, Any] = cfg.get("custom", {}).get("core_technologies", {})
    allowed_generators = set(custom_cfg.get("allow_generators", DEFAULT_GENERATORS))
    allowed_storage = set(custom_cfg.get("allow_storage", DEFAULT_STORAGES))
    allowed_links = set(custom_cfg.get("allow_links", DEFAULT_LINKS))

    _drop_components(network, "Generator", allowed_generators)
    _drop_components(network, "Store", allowed_storage)
    _drop_components(network, "StorageUnit", allowed_storage)
    _drop_components(network, "Link", allowed_links)
    
    # Additionally, drop links with H2 or battery-related carriers that may not be in the allowed list
    # (e.g., "H2 electrolysis", "H2 fuel cell", "battery charger", "battery discharger")
    links = network.links
    h2_batt_links = links[links['carrier'].str.contains('H2|battery', na=False, case=False)]
    if not h2_batt_links.empty:
        drop_idx = h2_batt_links.index
        try:
            network.mremove("Link", drop_idx)
        except AttributeError:  # pragma: no cover - fallback for older PyPSA versions
            for name in drop_idx:
                network.remove("Link", name)
        print(f"Removed {len(drop_idx)} H2/battery-related links outside the allowed tech list")
