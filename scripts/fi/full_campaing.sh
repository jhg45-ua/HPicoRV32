make sw APP=vec_sum SIM_FAST=1
python3 scripts/fi/gen_targets.py --all
mkdir -p build/fi_results

W=$(nproc)

{
  # 1. Diseño BASE (TMR=0, ECC=0): 1-SEU y 10-SEU (N=1000)
  python3 -u scripts/fi/launch_questa.py --tmr 0 --ecc 0 --faults 1  --runs 1000 --workers $W --seed 1000 &&
  python3 -u scripts/fi/launch_questa.py --tmr 0 --ecc 0 --faults 10 --runs 1000 --workers $W --seed 2000 &&

  # 2. Diseño PROTEGIDO (TMR=1, ECC=1): 1-SEU y 10-SEU (N=1000)
  python3 -u scripts/fi/launch_questa.py --tmr 1 --ecc 1 --faults 1  --runs 1000 --workers $W --seed 1000 &&
  python3 -u scripts/fi/launch_questa.py --tmr 1 --ecc 1 --faults 10 --runs 1000 --workers $W --seed 2000 &&

  # 3. Solo TMR (TMR=1, ECC=0) y Solo Reg-ECC (TMR=0, ECC=1)
  python3 -u scripts/fi/launch_questa.py --tmr 1 --ecc 0 --faults 1  --runs 1000 --workers $W --seed 1000 &&
  python3 -u scripts/fi/launch_questa.py --tmr 1 --ecc 0 --faults 10 --runs 1000 --workers $W --seed 2000 &&
  python3 -u scripts/fi/launch_questa.py --tmr 0 --ecc 1 --faults 1  --runs 1000 --workers $W --seed 1000 &&
  python3 -u scripts/fi/launch_questa.py --tmr 0 --ecc 1 --faults 10 --runs 1000 --workers $W --seed 2000
} 2>&1 | tee build/fi_results/full_campaing.txt