"""
Private MCP server (FastAPI / FastMCP) for the Foundry data-agent demo.

Runs on Azure Container Apps with internal-only ingress on a subnet delegated to
Microsoft.App/environments. A Foundry Standard Agent (network-injected into the
same VNet) calls this server's tools over MCP streamable-HTTP at /mcp.

Exposes a small "data agent" toolset over an in-memory sample dataset so we can
prove the agent -> private MCP path end to end without any external dependency.
"""
from __future__ import annotations

import os

from mcp.server.fastmcp import FastMCP

# --- Sample dataset ---------------------------------------------------------
# Stands in for a private line-of-business data source the agent must reach
# only over the VNet (never the public internet).
_SALES: dict[str, dict[str, float | int]] = {
    "northeast": {"revenue": 1_284_500.0, "units": 8421, "yoy_growth_pct": 12.4},
    "southeast": {"revenue": 982_300.0, "units": 6310, "yoy_growth_pct": 8.1},
    "midwest": {"revenue": 1_105_900.0, "units": 7044, "yoy_growth_pct": -2.3},
    "west": {"revenue": 1_733_200.0, "units": 10288, "yoy_growth_pct": 19.7},
}

_PRODUCTS: dict[str, dict[str, object]] = {
    "AX-100": {"name": "Atlas Router", "category": "networking", "price": 249.0, "in_stock": 1840},
    "BX-220": {"name": "Beacon Switch", "category": "networking", "price": 489.0, "in_stock": 612},
    "CX-9": {"name": "Cirrus Sensor", "category": "iot", "price": 39.0, "in_stock": 22950},
}

mcp = FastMCP(
    name="askmaya-private-data",
    instructions=(
        "Private data tools for the demo. Use list_regions/get_region_sales for "
        "sales analytics and list_products/get_product for catalog lookups."
    ),
    # Bind to all interfaces; ACA internal ingress terminates in front of this.
    host="0.0.0.0",
    port=int(os.environ.get("PORT", "8080")),
    # Streamable-HTTP path the Foundry MCP tool connects to (server_url + /mcp).
    streamable_http_path="/mcp",
    stateless_http=True,
)


@mcp.tool()
def list_regions() -> list[str]:
    """Return the list of sales regions available in the private dataset."""
    return sorted(_SALES.keys())


@mcp.tool()
def get_region_sales(region: str) -> dict:
    """Return revenue, units, and YoY growth for a single sales region.

    Args:
        region: One of the regions returned by list_regions (case-insensitive).
    """
    key = region.strip().lower()
    if key not in _SALES:
        return {"error": f"unknown region '{region}'", "known_regions": sorted(_SALES)}
    return {"region": key, **_SALES[key]}


@mcp.tool()
def total_revenue() -> dict:
    """Return the total revenue summed across all regions."""
    total = sum(float(r["revenue"]) for r in _SALES.values())
    return {"total_revenue": round(total, 2), "regions": len(_SALES)}


@mcp.tool()
def list_products() -> list[dict]:
    """Return the product catalog (SKU, name, category, price, in_stock)."""
    return [{"sku": sku, **info} for sku, info in _PRODUCTS.items()]


@mcp.tool()
def get_product(sku: str) -> dict:
    """Look up a single product by SKU.

    Args:
        sku: Product SKU, e.g. 'AX-100' (case-insensitive).
    """
    key = sku.strip().upper()
    if key not in _PRODUCTS:
        return {"error": f"unknown sku '{sku}'", "known_skus": sorted(_PRODUCTS)}
    return {"sku": key, **_PRODUCTS[key]}


# ASGI app for uvicorn: exposes the MCP streamable-HTTP transport at /mcp.
app = mcp.streamable_http_app()


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
