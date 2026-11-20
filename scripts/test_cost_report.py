"""Unit tests for scripts/cost_report.py - no AWS access needed."""

import importlib.util
import sys
from pathlib import Path
from typing import ClassVar

SPEC = importlib.util.spec_from_file_location(
    "cost_report", Path(__file__).resolve().parents[1] / "scripts" / "cost_report.py"
)
cost_report = importlib.util.module_from_spec(SPEC)
sys.modules["cost_report"] = cost_report
SPEC.loader.exec_module(cost_report)


class FakePrices:
    """Stands in for PriceLookup: fixed on-demand prices, Spot at 30% of on-demand."""

    PRICES: ClassVar[dict[str, float]] = {"m6i.xlarge": 0.20, "m7g.large": 0.08, "c7g.2xlarge": 0.29}

    def on_demand(self, instance_type):
        return self.PRICES[instance_type]

    def spot(self, instance_type, _az):
        return round(self.PRICES[instance_type] * 0.3, 4)


def node(itype, capacity, pool="general", arch="arm64"):
    prices = FakePrices()
    od = prices.on_demand(itype)
    return cost_report.Node(
        instance_id="i-123",
        instance_type=itype,
        availability_zone="eu-west-2a",
        capacity_type=capacity,
        architecture=arch,
        pool=pool,
        hourly_price=prices.spot(itype, "eu-west-2a") if capacity == "spot" else od,
        on_demand_price=od,
    )


def test_pct_saved_handles_zero_reference():
    assert cost_report.pct_saved(1.0, 0) == 0.0
    assert cost_report.pct_saved(25, 100) == 75.0


def test_summary_maths():
    nodes = [
        node("m7g.large", "on-demand", pool="mng/system"),
        node("m7g.large", "on-demand", pool="mng/system"),
        node("c7g.2xlarge", "spot"),
        node("c7g.2xlarge", "spot"),
    ]
    s = cost_report.summarise(nodes, "m6i.xlarge", 6, FakePrices())
    actual = 0.08 * 2 + 0.087 * 2
    assert s["nodes"] == 4
    assert s["spot_nodes"] == 2 and s["on_demand_nodes"] == 2
    assert s["hourly_actual_usd"] == round(actual, 4)
    assert s["hourly_baseline_usd"] == 1.2
    assert s["savings_vs_baseline_pct"] == round((1 - actual / 1.2) * 100, 1)
    assert s["monthly_actual_usd"] == round(actual * 730, 2)


def test_markdown_contains_every_node_and_caveat():
    nodes = [node("m7g.large", "on-demand", pool="mng/system"), node("c7g.2xlarge", "spot")]
    md = cost_report.to_markdown(nodes, cost_report.summarise(nodes, "m6i.xlarge", 6, FakePrices()))
    assert md.count("| mng/system |") == 1 and md.count("| general |") == 1
    assert "not a billing figure" in md


def test_csv_appends_with_single_header(tmp_path):
    nodes = [node("c7g.2xlarge", "spot")]
    s = cost_report.summarise(nodes, "m6i.xlarge", 6, FakePrices())
    out = tmp_path / "series.csv"
    cost_report.append_csv(out, s)
    cost_report.append_csv(out, s)
    lines = out.read_text().splitlines()
    assert len(lines) == 3 and lines[0].startswith("timestamp,")