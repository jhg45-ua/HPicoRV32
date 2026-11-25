#!/usr/bin/env python3
"""Orquestador paralelo de campañas SEU en Questa 2025.2 para HPicoRV32."""

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

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


def split_runs(total: int, workers: int):
    """Reparte 'total' corridas equilibradamente entre 'workers' -> [(offset, count), ...]."""
    workers = max(1, min(workers, total))
    base, rem = divmod(total, workers)
    chunks = []
    offset = 0
    for i in range(workers):
        cnt = base + (1 if i < rem else 0)
        chunks.append((offset, cnt))
        offset += cnt
    return chunks

def launch_campaign(tmr: int, ecc: int, k_faults: int, num_runs: int,
                    workers: int, seed: int, out_dir: Path, run_analyze: bool):
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
    shards_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    prepare_questa_lib(lib_dir, tmr, ecc)
    chunks = split_runs(num_runs, workers)
    print(f"[run]   TMR={tmr} ECC={ecc} | {k_faults}-SEU | N={num_runs} | {len(chunks)} workers en paralelo...")

    t0 = time.monotonic()
    procs = []
    shard_paths = []
    wlf_paths = []

    for wid, (offset, cnt) in enumerate(chunks):
        shard_csv = shards_dir / f"part_{wid:02d}.csv"
        log_file = logs_dir / f"worker_{wid:02d}.log"
        wlf_file = Path(f"/tmp/questa_fi_work/wlf_{tag}_{wid:02d}.wlf")
        shard_paths.append(shard_csv)
        wlf_paths.append(wlf_file)

        env = os.environ.copy()
        env.update({
            "FI_TMR": str(tmr),
            "FI_ECC": str(ecc),
            "FI_TARGETS": str(targets_file),
            "FI_OUT_CSV": str(shard_csv),
            "FI_NUM_RUNS": str(cnt),
            "FI_FAULTS_PER_RUN": str(k_faults),
            "FI_SEED": str(seed + wid * 100003),
            "FI_RUN_OFFSET": str(offset),
        })
        cmd = [
            "vsim", "-c", "-lib", str(lib_dir), "opt_tb",
            "-l", str(log_file), "-wlf", str(wlf_file),
            "-do", "scripts/fi/run_questa_fi.tcl",
        ]
        procs.append((wid, log_file, subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)))

    failed = []
    for wid, log_file, p in procs:
        rc = p.wait()
        if rc != 0:
            failed.append((wid, rc, log_file))
        else:
            print(f"  worker {wid:02d} OK")

    for wlf in wlf_paths:
        if wlf.exists():
            wlf.unlink()

    if failed:
        for wid, rc, lf in failed:
            print(f"ERROR: worker {wid:02d} terminó con exit {rc} (revisa {lf})")
        sys.exit(1)

    # Fusión ordenada de todos los shards en el CSV final
    final_csv = out_dir / f"fi_{tag}.csv"
    header = None
    total_rows = 0
    with final_csv.open("w", encoding="utf-8") as fout:
        for sp in shard_paths:
            with sp.open("r", encoding="utf-8") as fin:
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
    ap.add_argument("--seed", type=int, default=1000)
    ap.add_argument("--out-dir", type=Path, default=Path("build/fi_results"))
    ap.add_argument("--no-analyze", action="store_true")
    args = ap.parse_args()

    launch_campaign(
        args.tmr, args.ecc, args.faults, args.runs,
        args.workers, args.seed, args.out_dir, not args.no_analyze,
    )


if __name__ == "__main__":
    main()