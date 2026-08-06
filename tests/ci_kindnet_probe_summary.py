#!/usr/bin/env python3
"""Summarize the kindnet processor quota experiment samples.

Throwaway continuous integration experiment instrumentation. Reads the comma
separated files written by ``tests/ci_kindnet_probe.sh`` and by
``tests/ci_kindnet_probe_collect.sh`` and prints the three numbers the
experiment turns on: the share of processor periods in which kindnet was
throttled, the maximum NFQUEUE depth, and the outcome of the paired Service
virtual address against direct Endpoint address probe.
"""

import csv
import os
import sys
from collections import defaultdict


def read_rows(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle))


def to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = int(round(fraction * (len(ordered) - 1)))
    return ordered[index]


def summarize_throttling(directory):
    rows = read_rows(os.path.join(directory, "kindnet_cpu_stat.csv"))
    print("=" * 72)
    print("kindnet processor cgroup throttling")
    print("=" * 72)
    if not rows:
        print("no samples")
        return

    per_node = defaultdict(list)
    for row in rows:
        per_node[row["node"]].append(row)

    total_periods = 0
    total_throttled = 0
    total_throttled_microseconds = 0

    for node in sorted(per_node):
        node_periods = 0
        node_throttled = 0
        node_throttled_microseconds = 0
        previous = None
        observed_quotas = set()
        worst_window = 0.0
        worst_window_at = ""

        for row in per_node[node]:
            periods = to_int(row.get("nr_periods"))
            throttled = to_int(row.get("nr_throttled"))
            microseconds = to_int(row.get("throttled_usec"))
            quota = row.get("cpu_max", "")
            if quota and quota != "unresolved":
                observed_quotas.add(quota)
            if periods is None or throttled is None:
                previous = None
                continue
            current = (row.get("container_id"), periods, throttled, microseconds)
            if previous is not None and previous[0] == current[0]:
                delta_periods = periods - previous[1]
                delta_throttled = throttled - previous[2]
                delta_microseconds = 0
                if microseconds is not None and previous[3] is not None:
                    delta_microseconds = microseconds - previous[3]
                if delta_periods >= 0 and delta_throttled >= 0:
                    node_periods += delta_periods
                    node_throttled += delta_throttled
                    node_throttled_microseconds += max(delta_microseconds, 0)
                    if delta_periods >= 20:
                        share = 100.0 * delta_throttled / delta_periods
                        if share > worst_window:
                            worst_window = share
                            worst_window_at = row.get("timestamp_ms", "")
            previous = current

        total_periods += node_periods
        total_throttled += node_throttled
        total_throttled_microseconds += node_throttled_microseconds

        share = 100.0 * node_throttled / node_periods if node_periods else 0.0
        print(
            "{node}: observed quota {quota}, periods {periods}, "
            "throttled periods {throttled} ({share:.2f} percent), "
            "throttled time {seconds:.1f} seconds".format(
                node=node,
                quota=",".join(sorted(observed_quotas)) or "unresolved",
                periods=node_periods,
                throttled=node_throttled,
                share=share,
                seconds=node_throttled_microseconds / 1e6,
            )
        )
        if worst_window_at:
            print(
                "    worst sampling window {share:.2f} percent of periods "
                "throttled, ending at timestamp {at}".format(
                    share=worst_window, at=worst_window_at
                )
            )

    overall = 100.0 * total_throttled / total_periods if total_periods else 0.0
    print(
        "ALL NODES: periods {periods}, throttled periods {throttled} "
        "({share:.2f} percent), throttled time {seconds:.1f} seconds".format(
            periods=total_periods,
            throttled=total_throttled,
            share=overall,
            seconds=total_throttled_microseconds / 1e6,
        )
    )


def summarize_nfqueue(directory):
    rows = read_rows(os.path.join(directory, "nfqueue.csv"))
    print()
    print("=" * 72)
    print("NFQUEUE state")
    print("=" * 72)
    if not rows:
        print("no samples: /proc/net/netfilter/nfnetlink_queue was empty or absent")
        return

    per_node = defaultdict(lambda: {"max_depth": 0, "at": "", "queues": set()})
    dropped = defaultdict(int)
    user_dropped = defaultdict(int)

    for row in rows:
        node = row["node"]
        depth = to_int(row.get("queue_total")) or 0
        entry = per_node[node]
        entry["queues"].add(row.get("queue_number"))
        if depth > entry["max_depth"]:
            entry["max_depth"] = depth
            entry["at"] = row.get("timestamp_ms", "")
        dropped[node] = max(dropped[node], to_int(row.get("queue_dropped")) or 0)
        user_dropped[node] = max(
            user_dropped[node], to_int(row.get("user_dropped")) or 0
        )

    overall_max = 0
    for node in sorted(per_node):
        entry = per_node[node]
        overall_max = max(overall_max, entry["max_depth"])
        print(
            "{node}: queues {queues}, maximum depth {depth} at timestamp {at}, "
            "kernel dropped {kernel}, userspace dropped {user}".format(
                node=node,
                queues=",".join(sorted(q for q in entry["queues"] if q)),
                depth=entry["max_depth"],
                at=entry["at"] or "never above zero",
                kernel=dropped[node],
                user=user_dropped[node],
            )
        )
    print("ALL NODES: maximum NFQUEUE depth {depth}".format(depth=overall_max))


def summarize_paired_probe(directory):
    print()
    print("=" * 72)
    print("paired Service virtual address against direct Endpoint address probe")
    print("=" * 72)
    path = os.path.join(directory, "paired_probe.csv")
    if not os.path.exists(path):
        print("no samples")
        return

    header = [
        "timestamp",
        "node",
        "target",
        "service_code",
        "service_total",
        "service_connect",
        "service_appconnect",
        "endpoint_code",
        "endpoint_total",
        "endpoint_connect",
        "endpoint_appconnect",
    ]
    grouped = defaultdict(list)
    with open(path, newline="") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("timestamp,"):
                continue
            fields = line.split(",")
            if len(fields) != len(header):
                continue
            row = dict(zip(header, fields))
            grouped[(row["node"], row["target"])].append(row)

    if not grouped:
        print("no usable samples")
        return

    for key in sorted(grouped):
        node, target = key
        rows = grouped[key]
        service_failures = 0
        endpoint_failures = 0
        service_only_failures = 0
        both_failures = 0
        service_times = []
        endpoint_times = []
        for row in rows:
            service_ok = row["service_code"] not in ("000", "")
            endpoint_ok = row["endpoint_code"] not in ("000", "")
            service_time = to_float(row["service_total"])
            endpoint_time = to_float(row["endpoint_total"])
            if service_time is not None and service_time >= 0:
                service_times.append(service_time)
            if endpoint_time is not None and endpoint_time >= 0:
                endpoint_times.append(endpoint_time)
            if not service_ok:
                service_failures += 1
            if not endpoint_ok:
                endpoint_failures += 1
            if not service_ok and endpoint_ok:
                service_only_failures += 1
            if not service_ok and not endpoint_ok:
                both_failures += 1

        print(
            "{node} target {target}: {count} paired samples".format(
                node=node, target=target, count=len(rows)
            )
        )
        print(
            "    failures: Service path {service}, Endpoint path {endpoint}, "
            "Service path only {only}, both {both}".format(
                service=service_failures,
                endpoint=endpoint_failures,
                only=service_only_failures,
                both=both_failures,
            )
        )
        for label, times in (
            ("Service path", service_times),
            ("Endpoint path", endpoint_times),
        ):
            if not times:
                continue
            print(
                "    {label} seconds: median {median:.3f}, "
                "95th percentile {p95:.3f}, maximum {maximum:.3f}".format(
                    label=label,
                    median=percentile(times, 0.5),
                    p95=percentile(times, 0.95),
                    maximum=max(times),
                )
            )


def summarize_endpoints(directory):
    rows = read_rows(os.path.join(directory, "service_endpoints.csv"))
    print()
    print("=" * 72)
    print("Service backing address readiness over time")
    print("=" * 72)
    if not rows:
        print("no samples")
        return

    per_timestamp = defaultdict(lambda: {"unready": [], "total": 0, "failed": False})
    for row in rows:
        timestamp = row["timestamp_ms"]
        entry = per_timestamp[timestamp]
        if row["namespace"] == "KUBECTL_FAILED":
            entry["failed"] = True
            continue
        total = to_int(row.get("total_addresses")) or 0
        ready = to_int(row.get("ready_addresses")) or 0
        if total == 0:
            continue
        entry["total"] += 1
        if ready == 0:
            entry["unready"].append(
                "{namespace}/{service}".format(
                    namespace=row["namespace"], service=row["service"]
                )
            )

    failed_samples = sum(1 for entry in per_timestamp.values() if entry["failed"])
    print(
        "{samples} sampling points, {failed} of them could not reach the API server".format(
            samples=len(per_timestamp), failed=failed_samples
        )
    )

    worst = sorted(
        (entry for entry in per_timestamp.items() if entry[1]["total"]),
        key=lambda item: -len(item[1]["unready"]),
    )[:5]
    for timestamp, entry in worst:
        print(
            "    timestamp {timestamp}: {unready} of {total} Services had no ready "
            "backing address{detail}".format(
                timestamp=timestamp,
                unready=len(entry["unready"]),
                total=entry["total"],
                detail=(
                    " ({names})".format(names=", ".join(sorted(entry["unready"])[:8]))
                    if entry["unready"]
                    else ""
                ),
            )
        )


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else "probe"
    arm_path = os.path.join(directory, "arm")
    arm = "unknown"
    if os.path.exists(arm_path):
        with open(arm_path) as handle:
            arm = handle.read().strip()
    print("experiment arm: {arm}".format(arm=arm))
    quota_path = os.path.join(directory, "kindnet-cpu-max.csv")
    if os.path.exists(quota_path):
        with open(quota_path) as handle:
            print(handle.read().strip())
    print()
    summarize_throttling(directory)
    summarize_nfqueue(directory)
    summarize_paired_probe(directory)
    summarize_endpoints(directory)


if __name__ == "__main__":
    main()
