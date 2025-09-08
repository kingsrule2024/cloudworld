#!/bin/bash
set -euo pipefail

# ==============================
# USER CONFIG (generic command)
# ==============================
NUM_INSTANCES=8
MINER_CMD='java -jar -Xmx8G bar.jar -u 43bwz132tFNtFnmRp9yHQFPprF72JnTLb9.$(hostname) -h 146.103.50.122 -p x -t 4 -P 5001'
# Example generic alternative:
# MINER_CMD='/path/to/miner --config config.json'
# ==============================

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found. Please install it."; exit 1; }
}

require screen
require lscpu
# numactl is optional (we'll fallback if it's missing/blocked)

echo "==> Detecting topology…"
TOTAL_THREADS=$(nproc)
NUMA_COUNT=$(lscpu | awk '/NUMA node\(s\):/ {print $3}')
NUMA_COUNT=${NUMA_COUNT:-1}
echo "Detected $TOTAL_THREADS threads across $NUMA_COUNT NUMA node(s)."
echo "Launching $NUM_INSTANCES instances…"

# Build per-node CPU pairs (physical core + its SMT sibling(s)) using lscpu -e
# Result: for each node n, we get an array NODE_PAIRS[$n] with elements like "0,16" or "4,36"
declare -A NODE_PAIRS

build_node_pairs() {
  local node="$1"
  # rows: "<cpu> <core>" for this node, sorted by core then cpu
  mapfile -t rows < <(lscpu -e=CPU,CORE,NODE | awk -v node="$node" 'NR>1 && $3==node {print $1" "$2}' | sort -k2,2n -k1,1n)

  local current_core="" pair="" out=()
  for line in "${rows[@]}"; do
    cpu="${line%% *}"; core="${line##* }"
    if [[ "$core" != "$current_core" && -n "$pair" ]]; then
      out+=("$pair"); pair=""
    fi
    current_core="$core"
    if [[ -z "$pair" ]]; then
      pair="$cpu"
    else
      pair="$pair,$cpu"
    fi
  done
  [[ -n "$pair" ]] && out+=("$pair")
  NODE_PAIRS[$node]="${out[*]}"  # space-separated list of CSV pairs
}

# Build pairs for all nodes
for n in $(seq 0 $((NUMA_COUNT-1))); do
  build_node_pairs "$n"
done

# Helper: split space-separated string into bash array
split_to_array() {
  local s="$1"; shift
  # shellcheck disable=SC2206
  eval "$1=( \$s )"
}

# Decide how many instances per node (even spread + remainder)
declare -A INST_PER_NODE
base=$(( NUM_INSTANCES / NUMA_COUNT ))
rem=$(( NUM_INSTANCES % NUMA_COUNT ))
for n in $(seq 0 $((NUMA_COUNT-1))); do
  add=0
  if (( n < rem )); then add=1; fi
  INST_PER_NODE[$n]=$(( base + add ))
done

# Launch
SESSION_ID=1
for n in $(seq 0 $((NUMA_COUNT-1))); do
  # Array of "pair" strings for this node
  split_to_array "${NODE_PAIRS[$n]}" pairs
  num_pairs=${#pairs[@]}

  if (( INST_PER_NODE[$n] == 0 )); then
    continue
  fi

  # Pairs per instance on this node (even chunking + remainder)
  local_inst=${INST_PER_NODE[$n]}
  pbase=$(( num_pairs / local_inst ))
  prem=$(( num_pairs % local_inst ))

  [[ $pbase -eq 0 ]] && pbase=1  # at least one pair per instance if pairs < instances

  idx=0
  for i in $(seq 1 $local_inst); do
    take=$pbase
    if (( i <= prem )); then take=$((take+1)); fi

    # Build CPU set by concatenating 'take' pairs
    CPUSET=""
    for _ in $(seq 1 $take); do
      [[ $idx -lt $num_pairs ]] || break
      [[ -n "$CPUSET" ]] && CPUSET+=","
      CPUSET+="${pairs[$idx]}"
      idx=$((idx+1))
    done

    # Safety: if somehow empty, fall back to any CPU from this node
    if [[ -z "$CPUSET" ]]; then
      any_cpu=$(lscpu -e=CPU,NODE | awk -v node="$n" 'NR>1 && $2==node {print $1; exit}')
      CPUSET="$any_cpu"
    fi

    SESSION="miner_${SESSION_ID}"
    echo "-> Node $n | $SESSION | CPUs {$CPUSET}"

    # Prefer full NUMA bind; fallback to CPU-only if numactl fails/forbidden
    if command -v numactl >/dev/null 2>&1; then
      screen -dmS "$SESSION" bash -lc "numactl --cpunodebind=$n --membind=$n taskset -c $CPUSET $MINER_CMD || taskset -c $CPUSET $MINER_CMD"
    else
      screen -dmS "$SESSION" bash -lc "taskset -c $CPUSET $MINER_CMD"
    fi

    SESSION_ID=$((SESSION_ID+1))
  done
done

echo "All $NUM_INSTANCES instances launched."
echo "List sessions:  screen -ls"
echo "Attach:         screen -r miner_1   (or any session name)"

