#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
CYCLES=10
RUNS_PER_CYCLE=5
DELAY_BETWEEN_CYCLES=20
OUTPUT="all-results.csv"
SUMMARY="benchmark-summary.txt"

# Apps to benchmark: "Name|command|process_name"
# Adjust commands/process names for your system
APPS=(
    "Bruno|bruno|bruno"
    "ApiArk|apiark|apiark"
)

# ── Helpers ──────────────────────────────────────────────────────────

# Get total CPU time (in jiffies) for all processes matching a name
get_cpu_time() {
    local pname="$1"
    local total=0
    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir##*/}"
        comm_file="$pid_dir/comm"
        [ -r "$comm_file" ] || continue
        comm="$(cat "$comm_file" 2>/dev/null)" || continue
        if [ "$comm" = "$pname" ]; then
            stat_file="$pid_dir/stat"
            [ -r "$stat_file" ] || continue
            # fields 14 (utime) + 15 (stime)
            read -r utime stime <<< "$(awk '{print $14, $15}' "$stat_file" 2>/dev/null)" || continue
            total=$((total + utime + stime))
        fi
    done
    echo "$total"
}

# Wait until the app's CPU usage drops to idle
wait_for_idle() {
    local pname="$1"
    local max_wait=60
    local interval=0.25
    local waited=0

    while true; do
        local cpu1
        cpu1=$(get_cpu_time "$pname")
        sleep "$interval"
        waited=$(echo "$waited + $interval" | bc)
        local cpu2
        cpu2=$(get_cpu_time "$pname")
        local delta=$((cpu2 - cpu1))
        # delta in jiffies over 0.25s; threshold ~1 jiffy means nearly idle
        if [ "$delta" -le 1 ] || [ "$(echo "$waited >= $max_wait" | bc)" -eq 1 ]; then
            break
        fi
    done
}

# Get total RSS (in KB) for a process tree rooted at a PID
get_process_tree_rss_kb() {
    local root_pid="$1"
    local pids=("$root_pid")
    local idx=0

    while [ "$idx" -lt "${#pids[@]}" ]; do
        local parent="${pids[$idx]}"
        while IFS= read -r child; do
            [ -n "$child" ] && pids+=("$child")
        done < <(pgrep -P "$parent" 2>/dev/null || true)
        idx=$((idx + 1))
    done

    local total=0
    for p in "${pids[@]}"; do
        local rss
        rss=$(ps -o rss= -p "$p" 2>/dev/null || echo 0)
        rss="${rss// /}"
        [ -n "$rss" ] && total=$((total + rss))
    done
    echo "$total"
}

# High-resolution timer (seconds with nanosecond precision)
now_seconds() {
    date +%s.%N
}

# ── Benchmark ────────────────────────────────────────────────────────

run_benchmark() {
    local results_file="$1"
    echo '"App","Run","StartupSeconds","RAM_MB"' > "$results_file"

    for app_entry in "${APPS[@]}"; do
        IFS='|' read -r app_name app_cmd app_process <<< "$app_entry"

        for ((i = 1; i <= RUNS_PER_CYCLE; i++)); do
            echo "Running $app_name test $i..."

            local start
            start=$(now_seconds)

            # Launch the app in background
            nohup $app_cmd >/dev/null 2>&1 &
            local launcher_pid=$!

            # Poll for the process to appear (timeout 30s)
            local wait_ms=0
            local found=0
            while [ "$wait_ms" -lt 30000 ]; do
                if pgrep -x "$app_process" >/dev/null 2>&1; then
                    found=1
                    break
                fi
                sleep 0.1
                wait_ms=$((wait_ms + 100))
            done

            if [ "$found" -eq 0 ]; then
                echo "WARNING: Process not found for $app_name after 30s"
                continue
            fi

            wait_for_idle "$app_process"

            local end
            end=$(now_seconds)
            local elapsed
            elapsed=$(echo "$end - $start" | bc)
            local startup
            startup=$(printf "%.2f" "$elapsed")

            # Measure RAM of the process tree
            local main_pid
            main_pid=$(pgrep -x "$app_process" | head -1)
            local rss_kb
            rss_kb=$(get_process_tree_rss_kb "$main_pid")
            local ram_mb
            ram_mb=$(echo "scale=2; $rss_kb / 1024" | bc)

            echo "\"$app_name\",\"$i\",\"$startup\",\"$ram_mb\"" >> "$results_file"

            # Kill the app
            pkill -x "$app_process" 2>/dev/null || true
            sleep 5
        done
    done
}

# ── Summary ──────────────────────────────────────────────────────────

# Sort an array of numbers and print them one per line
sort_numbers() {
    printf '%s\n' "$@" | sort -g
}

# Percentile using linear interpolation
percentile() {
    local p="$1"
    shift
    local -a sorted
    mapfile -t sorted < <(sort_numbers "$@")
    local n=${#sorted[@]}
    local rank
    rank=$(echo "scale=10; ($p / 100) * ($n - 1)" | bc)
    local lower=${rank%%.*}
    [ -z "$lower" ] && lower=0
    local upper=$((lower + 1))
    [ "$upper" -ge "$n" ] && upper=$((n - 1))
    local frac
    frac=$(echo "scale=10; $rank - $lower" | bc)
    local val
    val=$(echo "scale=4; ${sorted[$lower]} * (1 - $frac) + ${sorted[$upper]} * $frac" | bc)
    printf "%.2f" "$val"
}

compute_stats() {
    local label="$1"
    shift
    local -a vals=("$@")
    local n=${#vals[@]}

    local sum=0
    for v in "${vals[@]}"; do
        sum=$(echo "$sum + $v" | bc)
    done
    local mean
    mean=$(echo "scale=4; $sum / $n" | bc)

    local median
    median=$(percentile 50 "${vals[@]}")

    local sum_sq_diff=0
    for v in "${vals[@]}"; do
        sum_sq_diff=$(echo "$sum_sq_diff + ($v - $mean)^2" | bc)
    done
    local stddev
    stddev=$(echo "scale=4; sqrt($sum_sq_diff / ($n - 1))" | bc)

    local cv
    if [ "$(echo "$mean != 0" | bc)" -eq 1 ]; then
        cv=$(echo "scale=2; ($stddev / $mean) * 100" | bc)
    else
        cv="0.00"
    fi

    local -a sorted_vals
    mapfile -t sorted_vals < <(sort_numbers "${vals[@]}")
    local min_val="${sorted_vals[0]}"
    local max_val="${sorted_vals[$((n - 1))]}"

    local p5 p25 p75 p95 iqr
    p5=$(percentile 5 "${vals[@]}")
    p25=$(percentile 25 "${vals[@]}")
    p75=$(percentile 75 "${vals[@]}")
    p95=$(percentile 95 "${vals[@]}")
    iqr=$(echo "scale=2; $p75 - $p25" | bc)

    mean=$(printf "%.2f" "$mean")
    stddev=$(printf "%.3f" "$stddev")
    min_val=$(printf "%.2f" "$min_val")
    max_val=$(printf "%.2f" "$max_val")

    echo "  ${label}:"
    echo "    Mean:    ${mean}"
    echo "    Median:  ${median}"
    echo "    StdDev:  ${stddev}"
    echo "    CV:      ${cv}%"
    echo "    Min:     ${min_val}    Max: ${max_val}"
    echo "    P5:      ${p5}     P95: ${p95}"
    echo "    P25:     ${p25}    P75: ${p75}"
    echo "    IQR:     ${iqr}"
}

generate_summary() {
    local csv="$1"
    local out="$2"

    # Extract unique app names (skip header)
    local -a apps
    mapfile -t apps < <(tail -n +2 "$csv" | cut -d',' -f1 | tr -d '"' | sort -u)

    {
        printf '=%.0s' {1..70}; echo
        echo "  BENCHMARK SUMMARY"
        echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        printf '=%.0s' {1..70}; echo

        for app in "${apps[@]}"; do
            # Extract values for this app
            local -a startup_vals ram_vals
            mapfile -t startup_vals < <(tail -n +2 "$csv" | awk -F',' -v app="\"$app\"" '$1 == app {gsub(/"/, "", $3); print $3}')
            mapfile -t ram_vals < <(tail -n +2 "$csv" | awk -F',' -v app="\"$app\"" '$1 == app {gsub(/"/, "", $4); print $4}')

            local n=${#startup_vals[@]}

            echo
            printf -- '-%.0s' {1..70}; echo
            echo "  $app  (n=$n runs)"
            printf -- '-%.0s' {1..70}; echo
            echo
            compute_stats "Startup Time (seconds)" "${startup_vals[@]}"
            echo
            compute_stats "RAM Usage (MB)" "${ram_vals[@]}"
        done

        # Comparative summary
        if [ "${#apps[@]}" -ge 2 ]; then
            echo
            printf '=%.0s' {1..70}; echo
            echo "  COMPARATIVE SUMMARY"
            printf '=%.0s' {1..70}; echo
            echo

            # Table header
            printf "  %-12s %-16s %-14s %-14s %-12s %s\n" \
                "App" "Startup Median" "Startup P95" "RAM Median" "RAM P95" "Runs"
            printf "  %-12s %-16s %-14s %-14s %-12s %s\n" \
                "---" "--------------" "-----------" "----------" "-------" "----"

            for app in "${apps[@]}"; do
                local -a sv rv
                mapfile -t sv < <(tail -n +2 "$csv" | awk -F',' -v app="\"$app\"" '$1 == app {gsub(/"/, "", $3); print $3}')
                mapfile -t rv < <(tail -n +2 "$csv" | awk -F',' -v app="\"$app\"" '$1 == app {gsub(/"/, "", $4); print $4}')
                local sm sp95 rm rp95
                sm=$(percentile 50 "${sv[@]}")
                sp95=$(percentile 95 "${sv[@]}")
                rm=$(percentile 50 "${rv[@]}")
                rp95=$(percentile 95 "${rv[@]}")
                printf "  %-12s %-16s %-14s %-14s %-12s %s\n" \
                    "$app" "${sm}s" "${sp95}s" "${rm} MB" "${rp95} MB" "${#sv[@]}"
            done

            # Relative comparison
            local base_app="${apps[0]}"
            local -a base_sv base_rv
            mapfile -t base_sv < <(tail -n +2 "$csv" | awk -F',' -v app="\"$base_app\"" '$1 == app {gsub(/"/, "", $3); print $3}')
            mapfile -t base_rv < <(tail -n +2 "$csv" | awk -F',' -v app="\"$base_app\"" '$1 == app {gsub(/"/, "", $4); print $4}')

            local base_startup_sum=0 base_ram_sum=0
            for v in "${base_sv[@]}"; do base_startup_sum=$(echo "$base_startup_sum + $v" | bc); done
            for v in "${base_rv[@]}"; do base_ram_sum=$(echo "$base_ram_sum + $v" | bc); done
            local base_startup_mean base_ram_mean
            base_startup_mean=$(echo "scale=4; $base_startup_sum / ${#base_sv[@]}" | bc)
            base_ram_mean=$(echo "scale=4; $base_ram_sum / ${#base_rv[@]}" | bc)

            echo
            echo "  Relative to $base_app (baseline = 1.00x):"

            for app in "${apps[@]}"; do
                local -a asv arv
                mapfile -t asv < <(tail -n +2 "$csv" | awk -F',' -v app="\"$app\"" '$1 == app {gsub(/"/, "", $3); print $3}')
                mapfile -t arv < <(tail -n +2 "$csv" | awk -F',' -v app="\"$app\"" '$1 == app {gsub(/"/, "", $4); print $4}')

                local as_sum=0 ar_sum=0
                for v in "${asv[@]}"; do as_sum=$(echo "$as_sum + $v" | bc); done
                for v in "${arv[@]}"; do ar_sum=$(echo "$ar_sum + $v" | bc); done

                local as_mean ar_mean
                as_mean=$(echo "scale=4; $as_sum / ${#asv[@]}" | bc)
                ar_mean=$(echo "scale=4; $ar_sum / ${#arv[@]}" | bc)

                local sr rr
                sr=$(printf "%.2f" "$(echo "scale=4; $as_mean / $base_startup_mean" | bc)")
                rr=$(printf "%.2f" "$(echo "scale=4; $ar_mean / $base_ram_mean" | bc)")

                echo "    ${app}: Startup ${sr}x  |  RAM ${rr}x"
            done
        fi

        echo
        printf '=%.0s' {1..70}; echo
    } | tee "$out"

    echo
    echo "Summary saved to $out"
}

# ── Main ─────────────────────────────────────────────────────────────

echo '"App","Run","StartupSeconds","RAM_MB"' > "$OUTPUT"

for ((cycle = 1; cycle <= CYCLES; cycle++)); do
    echo
    echo "===== Benchmark cycle $cycle of $CYCLES ====="

    run_benchmark "benchmark-results.csv"

    # Append data rows (skip header) to the combined CSV
    tail -n +2 "benchmark-results.csv" >> "$OUTPUT"

    if [ "$cycle" -lt "$CYCLES" ]; then
        echo "Waiting $DELAY_BETWEEN_CYCLES seconds before next cycle..."
        sleep "$DELAY_BETWEEN_CYCLES"
    fi
done

echo
echo "Benchmark complete. Raw results saved to $OUTPUT"
echo
echo "Generating summary..."
generate_summary "$OUTPUT" "$SUMMARY"
