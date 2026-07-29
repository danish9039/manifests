#!/usr/bin/env python3
"""Summarize the throwaway latency probe samples into phase statistics.

This file is part of a temporary continuous integration experiment and is not
intended for merge into the upstream repository.
"""

import csv
import sys
from pathlib import Path

LATENCY_COLUMNS = ["inject_ms", "readyz_ms", "ping_ms", "control_ms"]


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return ordered[index]


def number(row, column):
    raw = row.get(column, "")
    if raw in ("", None):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def load_marks(path):
    marks = []
    if not path.exists():
        return marks
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        parts = line.split(",", 1)
        if len(parts) != 2:
            continue
        try:
            marks.append((int(parts[0]), parts[1]))
        except ValueError:
            continue
    return sorted(marks)


def phase_for(elapsed_seconds, start_seconds, marks):
    label = "before-first-marker"
    for mark_ms, name in marks:
        if (mark_ms - start_seconds) / 1000.0 <= elapsed_seconds:
            label = name
        else:
            break
    return label


def describe(rows, label):
    print("")
    print("phase: %s   samples: %d" % (label, len(rows)))
    print(
        "  %-12s %8s %8s %8s %8s %8s"
        % ("quantity", "min", "median", "p95", "max", "failures")
    )
    for column in LATENCY_COLUMNS:
        values = [number(row, column) for row in rows]
        values = [value for value in values if value is not None]
        return_code_column = column.replace("_ms", "_rc")
        failures = sum(
            1 for row in rows if (row.get(return_code_column) or "0") not in ("0", "")
        )
        if not values:
            continue
        print(
            "  %-12s %8.0f %8.0f %8.0f %8.0f %8d"
            % (
                column,
                min(values),
                percentile(values, 0.5),
                percentile(values, 0.95),
                max(values),
                failures,
            )
        )
    for column in [
        "istiod_cpu_cores",
        "istiod_cgroup_cores",
        "runner_busy_pct",
        "loadavg1",
        "apf_inqueue",
        "webhook_mean_ms",
    ]:
        values = [number(row, column) for row in rows]
        values = [value for value in values if value is not None]
        if not values:
            continue
        print(
            "  %-12s median %8.3f   p95 %8.3f   max %8.3f"
            % (column, percentile(values, 0.5), percentile(values, 0.95), max(values))
        )


def main():
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else "probe")
    samples_path = directory / "samples.csv"
    if not samples_path.exists():
        print("no samples file at %s" % samples_path)
        return 1

    with samples_path.open() as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        print("samples file is empty")
        return 1

    marks = load_marks(directory / "marks.csv")
    start_seconds = marks[0][0] if marks else 0
    if marks:
        # The probe writes elapsed seconds relative to its own start. Recover
        # that origin from the first marker, which the workflow writes at the
        # moment the probe is launched.
        start_seconds = marks[0][0] - int(float(rows[0]["elapsed_s"]) * 1000)

    print("total samples: %d" % len(rows))
    print("markers:")
    for mark_ms, name in marks:
        print("  %+7.1fs  %s" % ((mark_ms - start_seconds) / 1000.0, name))

    grouped = {}
    order = []
    for row in rows:
        label = phase_for(float(row["elapsed_s"]), start_seconds, marks)
        if label not in grouped:
            grouped[label] = []
            order.append(label)
        grouped[label].append(row)

    for label in order:
        describe(grouped[label], label)

    describe(rows, "whole run")

    print("")
    print("samples where inject_ms exceeded 2000 milliseconds:")
    for row in rows:
        value = number(row, "inject_ms")
        if value is not None and value > 2000:
            print(
                "  t=%ss inject=%sms rc=%s readyz=%sms control=%sms "
                "istiod_cores=%s runner_busy=%s%%"
                % (
                    row["elapsed_s"],
                    row["inject_ms"],
                    row["inject_rc"],
                    row["readyz_ms"],
                    row["control_ms"],
                    row["istiod_cpu_cores"],
                    row["runner_busy_pct"],
                )
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
