#!/usr/bin/env python3
"""Orquestador paralelo de campañas SEU en Questa 2025.2 para HPicoRV32."""

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

RTL_GLOBS = ("rtl/core/*.v", "rtl/mem/*.v", "rtl/periph/*.v", "rtl/top/*.v")


def run_checked(cmd, desc: str):
    print(f"[build] {desc}...")
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if res.returncode != 0:
        print(res.stdout)
        sys.exit(f"ERROR en '{desc}' (exit {res.returncode})")


def prepare_questa_lib(lib_dir: Path, tmr: int, ecc: int):
    if lib_dir.exists():
        shutil.rmtree(lib_dir)
    lib_dir.parent.mkdir(parents=True, exist_ok=True)

    rtl_files = ["tb/tb_fi_soc.v"]
    for pattern in RTL_GLOBS:
        rtl_files.extend(sorted(str(p) for p in Path(".").glob(pattern)))

    run_checked(["vlib", str(lib_dir)], f"vlib {lib_dir}")
    run_checked(["vlog", "-work", str(lib_dir)] + rtl_files, "vlog RTL + tb_fi_soc.v")
    run_checked(
        [
            "vopt", "-work", str(lib_dir), "-L", str(lib_dir),
            "+acc=rn",
            f"-GENABLE_TMR={tmr}",
            f"-GENABLE_REG_ECC={ecc}",
            "tb_fi_soc", "-o", "opt_tb",
        ],
        f"vopt TMR={tmr} ECC={ecc}",
    )


def split_batches(total: int, batch_size: int):
    """Divide 'total' corridas en lotes cortos de 'batch_size' para evitar fugas FD (EMFILE) en Questa."""
    batches = []
    offset = 0
    bid = 0
    while offset < total:
        cnt = min(batch_size, total - offset)
        batches.append((bid, offset, cnt))
        offset += cnt
        bid += 1
    return batches


def run_batch(bid: int, offset: int, cnt: int, tmr: int, ecc: int, k_faults: int,
              seed: int, tag: str, lib_dir: Path, targets_file: Path,
              shards_dir: Path, logs_dir: Path):
    shard_csv = shards_dir / f"part_{bid:03d}.csv"
    log_file = logs_dir / f"batch_{bid:03d}.log"
    wlf_file = Path(f"/tmp/questa_fi_work/wlf_{tag}_{bid:03d}.wlf")

    env = os.environ.copy()
    env.update({
        "FI_TMR": str(tmr),
        "FI_ECC": str(ecc),
        "FI_TARGETS": str(targets_file),
        "FI_OUT_CSV": str(shard_csv),
        "FI_NUM_RUNS": str(cnt),
        "FI_FAULTS_PER_RUN": str(k_faults),
        "FI_SEED": str(seed + bid * 100003),
        "FI_RUN_OFFSET": str(offset),
    })
    cmd = [
        "vsim", "-c", "-lib", str(lib_dir), "opt_tb",
        "-l", str(log_file), "-wlf", str(wlf_file),
        "-do", "scripts/fi/run_questa_fi.tcl",
    ]
    try:
        res = subprocess.run(
            cmd, env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return bid, cnt, res.returncode, log_file, shard_csv
    finally:
        if wlf_file.exists():
            wlf_file.unlink()


def launch_campaign(tmr: int, ecc: int, k_faults: int, num_runs: int,
                    workers: int, batch_size: int, seed: int, out_dir: Path, run_analyze: bool):
    targets_file = Path(f"build/fi_targets/targets_tmr{tmr}_ecc{ecc}.tsv")
    fw_file = Path("build/firmware.hex")
    if not fw_file.exists():
        sys.exit("ERROR: falta build/firmware.hex. Ejecuta antes: make sw APP=vec_sum SIM_FAST=1")
    if not targets_file.exists():
        sys.exit(f"ERROR: falta {targets_file}. Ejecuta antes: python3 scripts/fi/gen_targets.py --all")

    tag = f"tmr{tmr}_ecc{ecc}_{k_faults}seu_n{num_runs}"
    lib_dir = Path(f"/tmp/questa_fi_work/t{tmr}_e{ecc}")
    shards_dir = out_dir / "shards" / tag
    logs_dir = out_dir / "logs" / tag
    if shards_dir.exists():
        shutil.rmtree(shards_dir)
    if logs_dir.exists():
        shutil.rmtree(logs_dir)
    shards_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    prepare_questa_lib(lib_dir, tmr, ecc)
    batches = split_batches(num_runs, batch_size)
    print(f"[run]   TMR={tmr} ECC={ecc} | {k_faults}-SEU | N={num_runs} | "
          f"{len(batches)} lotes de <={batch_size} en {workers} workers...")

    t0 = time.monotonic()
    done_runs = 0
    results = {}

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futs = [
            pool.submit(
                run_batch, bid, offset, cnt, tmr, ecc, k_faults,
                seed, tag, lib_dir, targets_file, shards_dir, logs_dir,
            )
            for bid, offset, cnt in batches
        ]
        for fut in as_completed(futs):
            bid, cnt, rc, log_file, shard_csv = fut.result()
            if rc != 0:
                print(f"ERROR: lote {bid:03d} terminó con exit {rc} (revisa {log_file})")
                sys.exit(1)
            results[bid] = shard_csv
            done_runs += cnt
            el = time.monotonic() - t0
            print(f"  [{done_runs:4d}/{num_runs}] lote {bid:03d} OK ({el:.1f}s)")

    final_csv = out_dir / f"fi_{tag}.csv"
    header = None
    total_rows = 0
    with final_csv.open("w", encoding="utf-8") as fout:
        for bid in sorted(results.keys()):
            with results[bid].open("r", encoding="utf-8") as fin:
                lines = fin.readlines()
            if not lines:
                continue
            if header is None:
                header = lines[0]
                fout.write(header)
            for ln in lines[1:]:
                fout.write(ln)
                total_rows += 1

    elapsed = time.monotonic() - t0
    print(f"[done]  {total_rows}/{num_runs} corridas fusionadas en {final_csv} "
          f"en {elapsed:.1f} s ({elapsed / max(total_rows, 1):.2f} s/corrida efectiva)")

    if run_analyze:
        subprocess.run([sys.executable, "scripts/fi/analyze_fi.py", str(final_csv)], check=False)


def main():
    ap = argparse.ArgumentParser(description="Lanza campañas SEU paralelas en Questa")
    ap.add_argument("--tmr", type=int, choices=(0, 1), required=True)
    ap.add_argument("--ecc", type=int, choices=(0, 1), required=True)
    ap.add_argument("--faults", type=int, default=1, help="Fallos espaciados por corrida (1 o 10)")
    ap.add_argument("--runs", type=int, default=20, help="Número total de corridas N")
    ap.add_argument("--workers", type=int, default=min(os.cpu_count() or 4, 8))
    ap.add_argument("--batch-size", type=int, default=25, help="Corridas por proceso vsim (evita EMFILE)")
    ap.add_argument("--seed", type=int, default=1000)
    ap.add_argument("--out-dir", type=Path, default=Path("build/fi_results"))
    ap.add_argument("--no-analyze", action="store_true")
    args = ap.parse_args()

    launch_campaign(
        args.tmr, args.ecc, args.faults, args.runs,
        args.workers, args.batch_size, args.seed, args.out_dir, not args.no_analyze,
    )

if __name__ == "__main__":
    main()