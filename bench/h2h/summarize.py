#!/usr/bin/env python3
"""Summarize a bench/h2h/run.sh TSV: median over rounds, then memkv against
pg_kv, and each against the UNLOGGED table on its own server."""
import csv
import statistics
import sys
from collections import defaultdict

rows = defaultdict(list)
with open(sys.argv[1]) as f:
    for r in csv.DictReader(f, delimiter="\t"):
        if r["tps"] == "FAILED":
            continue
        rows[(r["system"], r["op"], int(r["clients"]))].append(
            (float(r["tps"]), float(r["avg_ms"]), float(r["p99_us"])))


def med(system, op, clients, i):
    v = rows.get((system, op, clients))
    return statistics.median(x[i] for x in v) if v else None


def fmt(x, nd=0):
    return "-" if x is None else f"{x:,.{nd}f}"


def ratio(a, b):
    return "-" if a is None or not b else f"{a / b:.2f}x"


clients = sorted({k[2] for k in rows})
print()
print("Throughput, ops/s (median over rounds; a get x100 op is one statement with a hundred")
print("gets). The UNLOGGED columns are the same table on each server: 19 is memkv's server,")
print("18 is pg_kv's.")
print(f"{'op':8} {'clients':>7} {'memkv':>10} {'pg_kv':>10} {'memkv/pg_kv':>12} {'unl 19':>10} {'unl 18':>10} {'memkv/unl':>10} {'pg_kv/unl':>10}")
LABEL = {"batch": "get x100"}
for c in clients:
    for op in ("get", "set", "incr", "batch"):
        m, p = med("memkv", op, c, 0), med("pg_kv", op, c, 0)
        u19, u18 = med("unlogged_19", op, c, 0), med("unlogged_18", op, c, 0)
        print(f"{LABEL.get(op, op):8} {c:>7} {fmt(m):>10} {fmt(p):>10} {ratio(m, p):>12} {fmt(u19):>10} {fmt(u18):>10} {ratio(m, u19):>10} {ratio(p, u18):>10}")
    m, u19 = med("memkv", "mget", c, 0), med("unlogged_19", "batch", c, 0)
    print(f"{'mget100':8} {c:>7} {fmt(m):>10} {'':>10} {'':>12} {fmt(u19):>10} {'':>10} {ratio(m, u19):>10} {'':>10}   (memkv's own batch call, against the table's batch)")
    t19, t18 = med("unlogged_19", "get_ttl", c, 0), med("unlogged_18", "get_ttl", c, 0)
    m, p = med("memkv", "get", c, 0), med("pg_kv", "get", c, 0)
    print(f"{'get+ttl':8} {c:>7} {'':>10} {'':>10} {'':>12} {fmt(t19):>10} {fmt(t18):>10} {ratio(m, t19):>10} {ratio(p, t18):>10}   (table with pg_kv's TTL check)")
print()
print("Latency, p99 in microseconds (median over rounds)")
print(f"{'op':8} {'clients':>7} {'memkv':>10} {'pg_kv':>10} {'unl 19':>10} {'unl 18':>10}")
for c in clients:
    for op in ("get", "set", "incr", "batch"):
        print(f"{LABEL.get(op, op):8} {c:>7} {fmt(med('memkv', op, c, 2)):>10} {fmt(med('pg_kv', op, c, 2)):>10} "
              f"{fmt(med('unlogged_19', op, c, 2)):>10} {fmt(med('unlogged_18', op, c, 2)):>10}")
