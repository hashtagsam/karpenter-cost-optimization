#!/usr/bin/env python3
"""Node-level cost report for an EKS cluster running Karpenter.

Answers the question an engineering manager actually asks:
"What are we paying per hour for compute right now, and how does that
compare with the static node group we used to run?"

For every running node in the cluster it looks up the *live* price:
  - Spot nodes      -> current Spot price in that AZ (EC2 DescribeSpotPriceHistory)
  - On-demand nodes -> public on-demand price (AWS Price List API)

and compares the total with:
  - the same instances bought on-demand (=> value of Spot), and
  - a static baseline fleet sized for peak (=> value of right-sizing +
    consolidation), configurable with --baseline-*.

Scope: EC2 compute only. EBS, NAT, data transfer and the EKS control-plane
fee are the same in both designs and are excluded.

Read-only. Required IAM permissions (see docs/cost-report-iam-policy.json):
  ec2:DescribeInstances, ec2:DescribeSpotPriceHistory, pricing:GetProducts
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

HOURS_PER_MONTH = 730
# The Price List API is only served from a few regions; us-east-1 works for all.
PRICING_REGION = "us-east-1"
BOTO_CONFIG = Config(retries={"max_attempts": 8, "mode": "adaptive"}, connect_timeout=5, read_timeout=20)

log = logging.getLogger("cost_report")


@dataclass(frozen=True)
class Node:
    instance_id: str
    instance_type: str
    availability_zone: str
    capacity_type: str  # "spot" | "on-demand"
    architecture: str
    pool: str  # Karpenter NodePool name, or "mng/<nodegroup>"
    hourly_price: float
    on_demand_price: float


class PriceLookup:
    """Cached price lookups (prices don't change within a report run)."""

    def __init__(self, region: str) -> None:
        self.region = region
        self.ec2 = boto3.client("ec2", region_name=region, config=BOTO_CONFIG)
        self.pricing = boto3.client("pricing", region_name=PRICING_REGION, config=BOTO_CONFIG)
        self._on_demand: dict[str, float] = {}
        self._spot: dict[tuple[str, str], float] = {}

    def on_demand(self, instance_type: str) -> float:
        if instance_type not in self._on_demand:
            self._on_demand[instance_type] = self._fetch_on_demand(instance_type)
        return self._on_demand[instance_type]

    def spot(self, instance_type: str, availability_zone: str) -> float:
        key = (instance_type, availability_zone)
        if key not in self._spot:
            self._spot[key] = self._fetch_spot(instance_type, availability_zone)
        return self._spot[key]

    def _fetch_on_demand(self, instance_type: str) -> float:
        filters = [
            {"Type": "TERM_MATCH", "Field": field, "Value": value}
            for field, value in (
                ("instanceType", instance_type),
                ("regionCode", self.region),
                ("operatingSystem", "Linux"),
                ("tenancy", "Shared"),
                ("preInstalledSw", "NA"),
                ("capacitystatus", "Used"),
                ("licenseModel", "No License required"),
            )
        ]
        resp = self.pricing.get_products(ServiceCode="AmazonEC2", Filters=filters, MaxResults=10)
        for raw in resp.get("PriceList", []):
            product = json.loads(raw)
            for term in product.get("terms", {}).get("OnDemand", {}).values():
                for dim in term.get("priceDimensions", {}).values():
                    usd = float(dim.get("pricePerUnit", {}).get("USD", "0"))
                    if usd > 0:
                        return usd
        raise LookupError(f"No on-demand price found for {instance_type} in {self.region}")

    def _fetch_spot(self, instance_type: str, availability_zone: str) -> float:
        resp = self.ec2.describe_spot_price_history(
            InstanceTypes=[instance_type],
            ProductDescriptions=["Linux/UNIX"],
            AvailabilityZone=availability_zone,
            StartTime=datetime.now(timezone.utc),
            MaxResults=1,
        )
        history = resp.get("SpotPriceHistory", [])
        if not history:
            raise LookupError(f"No Spot price for {instance_type} in {availability_zone}")
        return float(history[0]["SpotPrice"])


# ---
def tag(instance: dict, key: str) -> str | None:
    for t in instance.get("Tags", []):
        if t["Key"] == key:
            return t["Value"]
    return None


def list_cluster_nodes(cluster: str, prices: PriceLookup) -> list[Node]:
    """All running EC2 instances owned by the cluster (Karpenter + managed node groups)."""
    paginator = prices.ec2.get_paginator("describe_instances")
    pages = paginator.paginate(
        Filters=[
            {"Name": f"tag:kubernetes.io/cluster/{cluster}", "Values": ["owned"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    nodes: list[Node] = []
    for page in pages:
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                itype = inst["InstanceType"]
                az = inst["Placement"]["AvailabilityZone"]
                capacity = "spot" if inst.get("InstanceLifecycle") == "spot" else "on-demand"
                pool = tag(inst, "karpenter.sh/nodepool")
                if pool is None:
                    pool = f"mng/{tag(inst, 'eks:nodegroup-name') or 'unknown'}"
                od = prices.on_demand(itype)
                hourly = prices.spot(itype, az) if capacity == "spot" else od
                nodes.append(
                    Node(
                        instance_id=inst["InstanceId"],
                        instance_type=itype,
                        availability_zone=az,
                        capacity_type=capacity,
                        architecture=inst.get("Architecture", "unknown"),
                        pool=pool,
                        hourly_price=hourly,
                        on_demand_price=od,
                    )
                )
    return sorted(nodes, key=lambda n: (n.pool, n.capacity_type, n.instance_type))


def pct_saved(actual: float, reference: float) -> float:
    return 0.0 if reference <= 0 else (1 - actual / reference) * 100


def summarise(nodes: list[Node], baseline_type: str, baseline_count: int, prices: PriceLookup) -> dict:
    actual = sum(n.hourly_price for n in nodes)
    all_on_demand = sum(n.on_demand_price for n in nodes)
    baseline = prices.on_demand(baseline_type) * baseline_count
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "nodes": len(nodes),
        "spot_nodes": sum(n.capacity_type == "spot" for n in nodes),
        "on_demand_nodes": sum(n.capacity_type == "on-demand" for n in nodes),
        "arm64_nodes": sum(n.architecture == "arm64" for n in nodes),
        "hourly_actual_usd": round(actual, 4),
        "hourly_if_all_on_demand_usd": round(all_on_demand, 4),
        "spot_savings_pct": round(pct_saved(actual, all_on_demand), 1),
        "baseline": f"{baseline_count} x {baseline_type} on-demand",
        "hourly_baseline_usd": round(baseline, 4),
        "savings_vs_baseline_pct": round(pct_saved(actual, baseline), 1),
        "monthly_actual_usd": round(actual * HOURS_PER_MONTH, 2),
        "monthly_baseline_usd": round(baseline * HOURS_PER_MONTH, 2),
    }


def to_markdown(nodes: list[Node], summary: dict) -> str:
    lines = [
        f"## Compute cost snapshot - {summary['timestamp']}",
        "",
        "| Pool | Instance | AZ | Capacity | Arch | $/hr | On-demand $/hr |",
        "|---|---|---|---|---|---:|---:|",
    ]
    lines += [
        f"| {n.pool} | {n.instance_type} | {n.availability_zone} | {n.capacity_type} | "
        f"{n.architecture} | {n.hourly_price:.4f} | {n.on_demand_price:.4f} |"
        for n in nodes
    ]
    lines += [
        "",
        "| Metric | Value |",
        "|---|---:|",
        (
            f"| Nodes (spot / on-demand / arm64) | {summary['nodes']} "
            f"({summary['spot_nodes']} / {summary['on_demand_nodes']} / {summary['arm64_nodes']}) |"
        ),
        f"| Compute $/hr (actual) | ${summary['hourly_actual_usd']:.4f} |",
        f"| Same nodes, all on-demand | ${summary['hourly_if_all_on_demand_usd']:.4f} |",
        f"| Saving from Spot | {summary['spot_savings_pct']}% |",
        f"| Baseline: {summary['baseline']} | ${summary['hourly_baseline_usd']:.4f} |",
        f"| Saving vs static baseline | {summary['savings_vs_baseline_pct']}% |",
        (
            f"| Projected monthly (actual vs baseline) | ${summary['monthly_actual_usd']:,.2f} vs "
            f"${summary['monthly_baseline_usd']:,.2f} |"
        ),
        "",
        "_EC2 compute only, list prices, point-in-time. Lab measurement, not a billing figure._",
    ]
    return "\n".join(lines)


def append_csv(path: Path, summary: dict) -> None:
    new_file = not path.exists()
    with path.open("a", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(summary))
        if new_file:
            writer.writeheader()
        writer.writerow(summary)


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--cluster", required=True, help="EKS cluster name")
    p.add_argument("--region", required=True, help="AWS region of the cluster")
    p.add_argument(
        "--baseline-instance-type",
        default="m6i.xlarge",
        help="Instance type of the static, peak-sized node group being replaced",
    )
    p.add_argument("--baseline-count", type=int, default=6, help="Node count of that static node group")
    p.add_argument("--markdown", type=Path, help="Write a Markdown report to this file")
    p.add_argument("--csv", type=Path, help="Append a summary row to this CSV (for time series during a load test)")
    p.add_argument("--json", action="store_true", help="Print the summary as JSON instead of Markdown")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args(argv)
    if args.baseline_count < 1:
        p.error("--baseline-count must be >= 1")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING, format="%(levelname)s %(message)s")

    try:
        prices = PriceLookup(args.region)
        nodes = list_cluster_nodes(args.cluster, prices)
        if not nodes:
            log.error("No running instances tagged kubernetes.io/cluster/%s=owned in %s", args.cluster, args.region)
            return 2
        summary = summarise(nodes, args.baseline_instance_type, args.baseline_count, prices)
    except (BotoCoreError, ClientError, LookupError) as exc:
        log.error("Cost lookup failed: %s", exc)
        return 1

    report = to_markdown(nodes, summary)
    if args.markdown:
        args.markdown.write_text(report + "\n", encoding="utf-8")
    if args.csv:
        append_csv(args.csv, summary)

    if args.json:
        print(json.dumps({"summary": summary, "nodes": [asdict(n) for n in nodes]}, indent=2))
    else:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
