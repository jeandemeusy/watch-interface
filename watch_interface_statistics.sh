#!/usr/bin/env bash
set -u -o pipefail

# --- constants (never modified after startup) ---
OS_TYPE="$(uname -s)"
RAW_HEADER="timestamp_unix_ms,netstat_interface,netstat_in_packets,netstat_out_packets,wireguard_transfer_received_bytes,wireguard_transfer_sent_bytes,hopr_packets_received,hopr_packets_sent"
GROWTH_HEADER="timestamp_unix_ms,previous_timestamp_unix_ms,interval_seconds,netstat_in_packets_delta,netstat_out_packets_delta,wireguard_transfer_received_bytes_delta,wireguard_transfer_sent_bytes_delta,hopr_packets_received_delta,hopr_packets_sent_delta,netstat_in_packets_rate_per_sec,netstat_out_packets_rate_per_sec,wireguard_transfer_received_bytes_rate_per_sec,wireguard_transfer_sent_bytes_rate_per_sec,hopr_packets_received_rate_per_sec,hopr_packets_sent_rate_per_sec,ratio_hopr_received_to_netstat_in_cumulative,ratio_hopr_sent_to_netstat_out_cumulative,ratio_hopr_received_to_netstat_in_delta,ratio_hopr_sent_to_netstat_out_delta,counter_reset_detected"

# --- cli parameters (defaults, overridable via flags) ---
DATA_DIR="data"
INTERVAL_SECONDS="1"
WINDOW="30"
NO_CLEAR="0"
ONCE="0"
ONCE_TIMESTAMP_UNIX_MS=""
FORMAT="plain"
PACKET_SIZE_FLOOR="0"
IFACE=""
FAIL_FAST="0"

# --- internal state (derived or runtime, not set via flags) ---
SUBCOMMAND=""
INPUT=""
RAW_OUTPUT=""
GROWTH_OUTPUT=""

collect_have_previous="0"
collect_previous_timestamp_unix_ms=""
collect_previous_netstat_in_packets=""
collect_previous_netstat_out_packets=""
collect_previous_wg_received_bytes=""
collect_previous_wg_sent_bytes=""
collect_previous_hopr_received_packets=""
collect_previous_hopr_sent_packets=""

print_usage() {
  cat <<'USAGE'
Usage: watch_interface_statistics.sh <subcommand> [options]

Subcommands:
  trends                  Trend dashboard
  distribution            Packet-size distribution dashboard
  collect                 Collect raw/growth CSV metrics

Options:
  --data DIR               Data directory; collect writes raw.csv and growth.csv there,
                           trends/distribution read growth.csv from there (default: data)
  --interval N             Refresh interval in seconds (default: 1)
  --window N               Number of recent rows to include in selected view (default: 40)
  --no-clear               Do not clear the terminal between refreshes
  --once                   Render one snapshot and exit (trends/distribution); collect one sample and exit (collect)
  --at TIMESTAMP_MS        Treat TIMESTAMP_MS as the latest row cutoff (trends/distribution only)
  --packet-size-floor N    Exclude packet-size values <= N from trend/distribution metrics (default: 0)
  --format plain|md        Table format (default: plain)
  --iface NAME             Interface to monitor (collect; required)
  --fail-fast              Exit immediately on sample failure (collect)
  -h, --help               Show this help
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

is_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_number() {
  [[ "$1" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]
}

is_positive_number() {
  is_number "$1" && awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

is_non_negative_number() {
  is_number "$1" && awk -v value="$1" 'BEGIN { exit !(value >= 0) }'
}

require_option_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "${option} requires a value"
}

collect_now_unix_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000)'
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

collect_unit_factor() {
  case "$1" in
    B) echo "1" ;;
    KiB) echo "1024" ;;
    MiB) echo "1048576" ;;
    GiB) echo "1073741824" ;;
    TiB) echo "1099511627776" ;;
    PiB) echo "1125899906842624" ;;
    *) return 1 ;;
  esac
}

collect_to_bytes() {
  local value="$1"
  local unit="$2"
  local factor
  factor="$(collect_unit_factor "$unit")" || return 1
  awk -v value="$value" -v factor="$factor" 'BEGIN { printf "%.0f", value * factor }'
}

collect_format_rate() {
  local delta="$1"
  local interval="$2"
  awk -v delta="$delta" -v interval="$interval" 'BEGIN { if (interval <= 0) { printf "" } else { printf "%.6f", delta / interval } }'
}

collect_format_ratio() {
  local numerator="$1"
  local denominator="$2"
  awk -v numerator="$numerator" -v denominator="$denominator" 'BEGIN { if (denominator == 0) { printf "" } else { printf "%.6f", numerator / denominator } }'
}

ensure_parent_dir() {
  local path="$1"
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"
}

collect_ensure_raw_header() {
  ensure_parent_dir "$RAW_OUTPUT"
  if [[ ! -s "$RAW_OUTPUT" ]]; then
    printf '%s\n' "$RAW_HEADER" > "$RAW_OUTPUT"
    return 0
  fi
  local existing_header
  existing_header="$(head -n 1 "$RAW_OUTPUT")"
  [[ "$existing_header" == "$RAW_HEADER" ]] || die "Raw CSV header mismatch in $RAW_OUTPUT. Use a fresh file or update it to the current format."
}

collect_ensure_growth_header() {
  ensure_parent_dir "$GROWTH_OUTPUT"
  if [[ ! -s "$GROWTH_OUTPUT" ]]; then
    printf '%s\n' "$GROWTH_HEADER" > "$GROWTH_OUTPUT"
    return 0
  fi
  local existing_header
  existing_header="$(head -n 1 "$GROWTH_OUTPUT")"
  [[ "$existing_header" == "$GROWTH_HEADER" ]] || die "Growth CSV header mismatch in $GROWTH_OUTPUT. Use a fresh file or update it to the current format."
}

collect_load_previous_from_raw() {
  if [[ ! -s "$RAW_OUTPUT" ]]; then
    return 0
  fi
  local last_line
  last_line="$(tail -n 1 "$RAW_OUTPUT")"
  if [[ -z "$last_line" || "$last_line" == timestamp_unix_ms,* ]]; then
    return 0
  fi

  local timestamp_unix_ms iface net_in net_out wg_recv_bytes wg_sent_bytes hopr_recv hopr_sent
  IFS=',' read -r timestamp_unix_ms iface net_in net_out wg_recv_bytes wg_sent_bytes hopr_recv hopr_sent <<< "$last_line"

  if ! is_non_negative_integer "$timestamp_unix_ms" || ! is_non_negative_integer "$net_in" || ! is_non_negative_integer "$net_out" || ! is_non_negative_integer "$wg_recv_bytes" || ! is_non_negative_integer "$wg_sent_bytes" || ! is_non_negative_integer "$hopr_recv" || ! is_non_negative_integer "$hopr_sent"; then
    return 0
  fi

  collect_previous_timestamp_unix_ms="$timestamp_unix_ms"
  collect_previous_netstat_in_packets="$net_in"
  collect_previous_netstat_out_packets="$net_out"
  collect_previous_wg_received_bytes="$wg_recv_bytes"
  collect_previous_wg_sent_bytes="$wg_sent_bytes"
  collect_previous_hopr_received_packets="$hopr_recv"
  collect_previous_hopr_sent_packets="$hopr_sent"
  collect_have_previous="1"
}

collect_netstat_packets() {
  if [[ "$OS_TYPE" == "Linux" ]]; then
    awk -v iface="$IFACE" -F':' '
      {
        key = $1
        sub(/^[[:space:]]+/, "", key)
        if (key == iface) {
          split($2, f)
          # /proc/net/dev fields after colon:
          # rx: bytes(1) packets(2) errs(3) drop(4) fifo(5) frame(6) compressed(7) multicast(8)
          # tx: bytes(9)  packets(10) ...
          print f[2], f[10]
          exit
        }
      }
    ' /proc/net/dev
  else
    netstat -I "$IFACE" -n | awk -v iface="$IFACE" \
      '$1 == iface && $(NF-4) ~ /^[0-9]+$/ && $(NF-2) ~ /^[0-9]+$/ { print $(NF-4), $(NF-2); exit }'
  fi
}

collect_one_sample() {
  local netstat_packets wg_output hopr_output

  netstat_packets="$(collect_netstat_packets)" || return 1
  wg_output="$(sudo wg show)" || return 1
  hopr_output="$(bash -lc "gnosis_vpn-ctl telemetry")" || return 1

  local netstat_in_packets netstat_out_packets
  read -r netstat_in_packets netstat_out_packets <<< "$netstat_packets"

  local wg_received_value wg_received_unit wg_sent_value wg_sent_unit
  read -r wg_received_value wg_received_unit wg_sent_value wg_sent_unit <<< "$(printf '%s\n' "$wg_output" | awk '/transfer:/ { print $2, $3, $5, $6; exit }')"
  wg_sent_unit="${wg_sent_unit%,}"

  local hopr_received_packets hopr_sent_packets
  hopr_received_packets="$(printf '%s\n' "$hopr_output" | awk '/hopr_packets_count\{type="received"\}/ { print $2; exit }')"
  hopr_sent_packets="$(printf '%s\n' "$hopr_output" | awk '/hopr_packets_count\{type="sent"\}/ { print $2; exit }')"

  [[ -n "$netstat_in_packets" && -n "$netstat_out_packets" ]] || return 1
  [[ -n "$wg_received_value" && -n "$wg_received_unit" && -n "$wg_sent_value" && -n "$wg_sent_unit" ]] || return 1
  [[ -n "$hopr_received_packets" && -n "$hopr_sent_packets" ]] || return 1

  is_non_negative_integer "$netstat_in_packets" || return 1
  is_non_negative_integer "$netstat_out_packets" || return 1
  is_non_negative_integer "$hopr_received_packets" || return 1
  is_non_negative_integer "$hopr_sent_packets" || return 1

  local wg_received_bytes wg_sent_bytes
  wg_received_bytes="$(collect_to_bytes "$wg_received_value" "$wg_received_unit")" || return 1
  wg_sent_bytes="$(collect_to_bytes "$wg_sent_value" "$wg_sent_unit")" || return 1

  is_non_negative_integer "$wg_received_bytes" || return 1
  is_non_negative_integer "$wg_sent_bytes" || return 1

  local timestamp_unix_ms
  timestamp_unix_ms="$(collect_now_unix_ms)" || return 1
  is_non_negative_integer "$timestamp_unix_ms" || return 1

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$timestamp_unix_ms" "$IFACE" "$netstat_in_packets" "$netstat_out_packets" \
    "$wg_received_bytes" "$wg_sent_bytes" "$hopr_received_packets" "$hopr_sent_packets" \
    >> "$RAW_OUTPUT"

  if [[ "$collect_have_previous" == "1" ]]; then
    local interval_ms interval_seconds
    interval_ms=$((timestamp_unix_ms - collect_previous_timestamp_unix_ms))
    interval_seconds="$(awk -v interval_ms="$interval_ms" 'BEGIN { printf "%.3f", interval_ms / 1000 }')"

    local delta_netstat_in delta_netstat_out delta_wg_recv delta_wg_sent delta_hopr_recv delta_hopr_sent
    delta_netstat_in=$((netstat_in_packets - collect_previous_netstat_in_packets))
    delta_netstat_out=$((netstat_out_packets - collect_previous_netstat_out_packets))
    delta_wg_recv=$((wg_received_bytes - collect_previous_wg_received_bytes))
    delta_wg_sent=$((wg_sent_bytes - collect_previous_wg_sent_bytes))
    delta_hopr_recv=$((hopr_received_packets - collect_previous_hopr_received_packets))
    delta_hopr_sent=$((hopr_sent_packets - collect_previous_hopr_sent_packets))

    local counter_reset_detected="no"
    if (( delta_netstat_in < 0 || delta_netstat_out < 0 || delta_wg_recv < 0 || delta_wg_sent < 0 || delta_hopr_recv < 0 || delta_hopr_sent < 0 )); then
      counter_reset_detected="yes"
    fi

    local netstat_in_rate netstat_out_rate wg_recv_rate wg_sent_rate hopr_recv_rate hopr_sent_rate
    local ratio_recv_cum ratio_sent_cum ratio_recv_delta ratio_sent_delta

    netstat_in_rate="$(collect_format_rate "$delta_netstat_in" "$interval_seconds")"
    netstat_out_rate="$(collect_format_rate "$delta_netstat_out" "$interval_seconds")"
    wg_recv_rate="$(collect_format_rate "$delta_wg_recv" "$interval_seconds")"
    wg_sent_rate="$(collect_format_rate "$delta_wg_sent" "$interval_seconds")"
    hopr_recv_rate="$(collect_format_rate "$delta_hopr_recv" "$interval_seconds")"
    hopr_sent_rate="$(collect_format_rate "$delta_hopr_sent" "$interval_seconds")"

    ratio_recv_cum="$(collect_format_ratio "$hopr_received_packets" "$netstat_in_packets")"
    ratio_sent_cum="$(collect_format_ratio "$hopr_sent_packets" "$netstat_out_packets")"
    ratio_recv_delta="$(collect_format_ratio "$delta_hopr_recv" "$delta_netstat_in")"
    ratio_sent_delta="$(collect_format_ratio "$delta_hopr_sent" "$delta_netstat_out")"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$timestamp_unix_ms" "$collect_previous_timestamp_unix_ms" "$interval_seconds" \
      "$delta_netstat_in" "$delta_netstat_out" "$delta_wg_recv" "$delta_wg_sent" \
      "$delta_hopr_recv" "$delta_hopr_sent" "$netstat_in_rate" "$netstat_out_rate" \
      "$wg_recv_rate" "$wg_sent_rate" "$hopr_recv_rate" "$hopr_sent_rate" \
      "$ratio_recv_cum" "$ratio_sent_cum" "$ratio_recv_delta" "$ratio_sent_delta" \
      "$counter_reset_detected" \
      >> "$GROWTH_OUTPUT"
  fi

  collect_previous_timestamp_unix_ms="$timestamp_unix_ms"
  collect_previous_netstat_in_packets="$netstat_in_packets"
  collect_previous_netstat_out_packets="$netstat_out_packets"
  collect_previous_wg_received_bytes="$wg_received_bytes"
  collect_previous_wg_sent_bytes="$wg_sent_bytes"
  collect_previous_hopr_received_packets="$hopr_received_packets"
  collect_previous_hopr_sent_packets="$hopr_sent_packets"
  collect_have_previous="1"

  echo "[${timestamp_unix_ms}] netstat in/out=${netstat_in_packets}/${netstat_out_packets} wg recv/sent bytes=${wg_received_bytes}/${wg_sent_bytes} hopr recv/sent=${hopr_received_packets}/${hopr_sent_packets}"
  return 0
}

collect_run() {
  collect_ensure_raw_header
  collect_ensure_growth_header
  collect_load_previous_from_raw

  echo "Collecting every ${INTERVAL_SECONDS}s"
  echo "raw_csv=$(cd "$(dirname "$RAW_OUTPUT")" && pwd)/$(basename "$RAW_OUTPUT")"
  echo "growth_csv=$(cd "$(dirname "$GROWTH_OUTPUT")" && pwd)/$(basename "$GROWTH_OUTPUT")"
  echo "iface=${IFACE}"

  while true; do
    local started_ms ended_ms elapsed_ms sleep_seconds
    started_ms="$(collect_now_unix_ms)"

    if ! collect_one_sample; then
      echo "Sample collection failed" >&2
      if [[ "$FAIL_FAST" == "1" || "$ONCE" == "1" ]]; then
        exit 1
      fi
    fi

    if [[ "$ONCE" == "1" ]]; then
      exit 0
    fi

    ended_ms="$(collect_now_unix_ms)"
    elapsed_ms=$((ended_ms - started_ms))
    sleep_seconds="$(awk -v interval="$INTERVAL_SECONDS" -v elapsed_ms="$elapsed_ms" 'BEGIN { s = interval - (elapsed_ms / 1000.0); if (s < 0) s = 0; printf "%.3f", s }')"
    sleep "$sleep_seconds"
  done
}

render_dashboard() {
  if [[ ! -f "$INPUT" ]]; then
    echo "Waiting for growth CSV: $INPUT"
    return 0
  fi

  awk -F',' -v window="$WINDOW" -v source="$INPUT" -v cutoff_ts="$ONCE_TIMESTAMP_UNIX_MS" -v output_format="$FORMAT" -v packet_size_floor="$PACKET_SIZE_FLOOR" '
  function abs(x) {
    return x < 0 ? -x : x
  }

  function clamp(v, lo, hi) {
    if (v < lo) return lo
    if (v > hi) return hi
    return v
  }

  function spark_level(v, lo, hi,    level) {
    if (hi <= lo) {
      return 3
    }
    level = int(((v - lo) / (hi - lo)) * 7 + 0.5)
    level = clamp(level, 0, 7)
    return level
  }

  function spark_char(level) {
    if (level <= 0) return "\342\226\201"
    if (level == 1) return "\342\226\202"
    if (level == 2) return "\342\226\203"
    if (level == 3) return "\342\226\204"
    if (level == 4) return "\342\226\205"
    if (level == 5) return "\342\226\206"
    if (level == 6) return "\342\226\207"
    return "\342\226\210"
  }

  function print_table_header() {
    if (output_format == "md") {
      print "| metric | latest | avg | min | max | graph |"
      print "| --- | ---: | ---: | ---: | ---: | --- |"
      return
    }
    printf "%-45s %10s %10s %10s %10s %s\n", "metric", "latest", "avg", "min", "max", "graph"
    printf "%-45s %10s %10s %10s %10s %s\n", "---------------------------------------------", "----------", "----------", "----------", "----------", "----------------------------------------"
  }

  function draw_metric(label, arr, start, end,    i, n, v, vi, last, sum, win_min, win_max, avg, sparkline, plot_lo, plot_hi, span, pad) {
    n = 0
    sum = 0
    sparkline = ""
    for (i = start; i <= end; i++) {
      if (arr[i] == "") {
        continue
      }
      v = arr[i] + 0
      n++
      values[n] = v
      sum += v
      if (n == 1 || v < win_min) win_min = v
      if (n == 1 || v > win_max) win_max = v
    }

    if (n == 0) {
      if (output_format == "md") {
        printf "| %s |  |  |  |  |  |\n", label
        return
      }
      printf "%-45s %10s %10s %10s %10s %s\n", label, "-", "-", "-", "-", "-"
      return
    }

    last = values[n]
    avg = sum / n

    plot_lo = win_min
    plot_hi = win_max
    span = plot_hi - plot_lo
    if (span == 0) {
      pad = abs(plot_hi) * 0.05
      if (pad < 1) {
        pad = 1
      }
    } else {
      pad = span * 0.10
    }
    plot_lo = plot_lo - pad
    if (plot_lo < 0) {
      plot_lo = 0
    }
    plot_hi = plot_hi + pad
    if (plot_hi <= plot_lo) {
      plot_hi = plot_lo + 1
    }

    vi = 0
    for (i = start; i <= end; i++) {
      if (arr[i] == "") {
        sparkline = sparkline "_"
      } else {
        vi++
        sparkline = sparkline spark_char(spark_level(values[vi], plot_lo, plot_hi))
      }
    }

    if (output_format == "md") {
      printf "| %s | %.4f | %.4f | %.4f | %.4f | %s |\n", label, last, avg, win_min, win_max, sparkline
      return
    }

    printf "%-45s %10.4f %10.4f %10.4f %10.4f %s\n", label, last, avg, win_min, win_max, sparkline
  }

  NR == 1 {
    for (i = 1; i <= NF; i++) {
      col[$i] = i
    }
    next
  }

  {
    current_ts = $(col["timestamp_unix_ms"])
    if (cutoff_ts != "" && (current_ts + 0) > (cutoff_ts + 0)) {
      next
    }

    rows++
    ts[rows] = current_ts
    interval[rows] = $(col["interval_seconds"])
    ratio_recv_delta[rows] = $(col["ratio_hopr_received_to_netstat_in_delta"])
    ratio_sent_delta[rows] = $(col["ratio_hopr_sent_to_netstat_out_delta"])
    hopr_recv_rate[rows] = $(col["hopr_packets_received_rate_per_sec"])
    hopr_sent_rate[rows] = $(col["hopr_packets_sent_rate_per_sec"])

    wg_recv_delta = $(col["wireguard_transfer_received_bytes_delta"])
    wg_sent_delta = $(col["wireguard_transfer_sent_bytes_delta"])
    wg_in_packets_delta = $(col["netstat_in_packets_delta"])
    wg_out_packets_delta = $(col["netstat_out_packets_delta"])
    if (wg_recv_delta != "" && wg_in_packets_delta != "") {
      if ((wg_in_packets_delta + 0) > 0) {
        packet_size_value = (wg_recv_delta + 0) / (wg_in_packets_delta + 0)
        if (packet_size_floor == "" || packet_size_value > (packet_size_floor + 0)) {
          packet_size_received[rows] = packet_size_value
        }
      }
    }
    if (wg_sent_delta != "" && wg_out_packets_delta != "") {
      if ((wg_out_packets_delta + 0) > 0) {
        packet_size_value = (wg_sent_delta + 0) / (wg_out_packets_delta + 0)
        if (packet_size_floor == "" || packet_size_value > (packet_size_floor + 0)) {
          packet_size_sent[rows] = packet_size_value
        }
      }
    }
  }

  END {
    required[1] = "timestamp_unix_ms"
    required[2] = "interval_seconds"
    required[3] = "ratio_hopr_received_to_netstat_in_delta"
    required[4] = "ratio_hopr_sent_to_netstat_out_delta"
    required[5] = "hopr_packets_received_rate_per_sec"
    required[6] = "hopr_packets_sent_rate_per_sec"
    required[7] = "wireguard_transfer_received_bytes_delta"
    required[8] = "wireguard_transfer_sent_bytes_delta"
    required[9] = "netstat_in_packets_delta"
    required[10] = "netstat_out_packets_delta"

    missing = ""
    for (i = 1; i <= 10; i++) {
      if (!(required[i] in col)) {
        missing = missing " " required[i]
      }
    }
    if (missing != "") {
      print "Missing required columns in growth CSV:" missing > "/dev/stderr"
      exit 2
    }

    if (rows == 0) {
      if (cutoff_ts != "") {
        printf "No growth rows at or before cutoff timestamp %s in %s\n", cutoff_ts, source
        exit 0
      }
      print "No growth rows yet in " source
      exit 0
    }

    start = rows - window + 1
    if (start < 1) {
      start = 1
    }

    print "VPN Growth Trend Dashboard"
    printf "source=%s\n", source
    if (cutoff_ts != "") {
      printf "as_of_timestamp_unix_ms=%s\n", cutoff_ts
    }
    if (packet_size_floor != "") {
      printf "packet_size_floor_exclusive_gt=%s\n", packet_size_floor
    }
    printf "rows=%d window_rows=%d latest_timestamp_unix_ms=%s latest_interval_seconds=%s\n", rows, rows - start + 1, ts[rows], interval[rows]
    print ""
    print_table_header()

    draw_metric("ratio_hopr_received_to_netstat_in_delta", ratio_recv_delta, start, rows)
    draw_metric("ratio_hopr_sent_to_netstat_out_delta", ratio_sent_delta, start, rows)
    draw_metric("packet_size_received_b_per_wg_packet", packet_size_received, start, rows)
    draw_metric("packet_size_sent_b_per_wg_packet", packet_size_sent, start, rows)
    draw_metric("hopr_packets_received_rate_per_sec", hopr_recv_rate, start, rows)
    draw_metric("hopr_packets_sent_rate_per_sec", hopr_sent_rate, start, rows)
  }
  ' "$INPUT"
}

render_distribution() {
  if [[ ! -f "$INPUT" ]]; then
    echo "Waiting for growth CSV: $INPUT"
    return 0
  fi

  awk -F',' -v window="$WINDOW" -v source="$INPUT" -v cutoff_ts="$ONCE_TIMESTAMP_UNIX_MS" -v output_format="$FORMAT" -v packet_size_floor="$PACKET_SIZE_FLOOR" '
  function repeat_char(ch, n,    i, out) {
    out = ""
    for (i = 0; i < n; i++) {
      out = out ch
    }
    return out
  }

  function build_bar(count, max_count, width,    len) {
    if (max_count <= 0 || count <= 0) {
      return ""
    }
    len = int((count / max_count) * width + 0.5)
    if (len < 1) {
      len = 1
    }
    return repeat_char("\342\226\210", len)
  }

  function draw_distribution(title, arr, start, end, bins,    i, j, samples, v, vmin, vmax, width, idx, lower, upper, max_count, count, pct, bar) {
    samples = 0
    vmin = 0
    vmax = 0
    for (i = start; i <= end; i++) {
      if (arr[i] == "") {
        continue
      }
      v = arr[i] + 0
      samples++
      values[samples] = v
      if (samples == 1 || v < vmin) vmin = v
      if (samples == 1 || v > vmax) vmax = v
    }

    if (output_format == "md") {
      print ""
      print "### " title
    } else {
      print ""
      printf "%s (samples=%d min=%.4f max=%.4f)\n", title, samples, vmin, vmax
    }

    if (samples == 0) {
      if (output_format == "md") {
        print "| bin_from_bytes | bin_to_bytes | count | pct | bar |"
        print "| ---: | ---: | ---: | ---: | --- |"
        print "|  |  | 0 | 0.00% |  |"
      } else {
        print "no data in selected window"
      }
      return
    }

    for (i = 1; i <= bins; i++) {
      hist[i] = 0
    }

    if (vmax == vmin) {
      hist[1] = samples
      used_bins = 1
    } else {
      width = (vmax - vmin) / bins
      used_bins = bins
      for (j = 1; j <= samples; j++) {
        idx = int((values[j] - vmin) / width) + 1
        if (idx < 1) idx = 1
        if (idx > bins) idx = bins
        hist[idx]++
      }
    }

    max_count = 0
    for (i = 1; i <= used_bins; i++) {
      if (hist[i] > max_count) {
        max_count = hist[i]
      }
    }

    if (output_format == "md") {
      print "| bin_from_bytes | bin_to_bytes | count | pct | bar |"
      print "| ---: | ---: | ---: | ---: | --- |"
    } else {
      printf "%-23s %8s %8s %s\n", "bin(bytes)", "count", "pct", "bar"
    }

    if (used_bins == 1) {
      pct = 100.0
      bar = build_bar(samples, max_count, 28)
      if (output_format == "md") {
        printf "| %.4f | %.4f | %d | %.2f%% | %s |\n", vmin, vmax, samples, pct, bar
      } else {
        printf "%10.4f-%10.4f %8d %7.2f%% %s\n", vmin, vmax, samples, pct, bar
      }
      return
    }

    width = (vmax - vmin) / bins
    for (i = 1; i <= bins; i++) {
      lower = vmin + ((i - 1) * width)
      upper = vmin + (i * width)
      if (i == bins) {
        upper = vmax
      }
      count = hist[i]
      pct = (count * 100.0) / samples
      bar = build_bar(count, max_count, 28)
      if (output_format == "md") {
        printf "| %.4f | %.4f | %d | %.2f%% | %s |\n", lower, upper, count, pct, bar
      } else {
        printf "%10.4f-%10.4f %8d %7.2f%% %s\n", lower, upper, count, pct, bar
      }
    }
  }

  NR == 1 {
    for (i = 1; i <= NF; i++) {
      col[$i] = i
    }
    next
  }

  {
    current_ts = $(col["timestamp_unix_ms"])
    if (cutoff_ts != "" && (current_ts + 0) > (cutoff_ts + 0)) {
      next
    }

    rows++
    ts[rows] = current_ts
    interval[rows] = $(col["interval_seconds"])

    wg_recv_delta = $(col["wireguard_transfer_received_bytes_delta"])
    wg_sent_delta = $(col["wireguard_transfer_sent_bytes_delta"])
    wg_in_packets_delta = $(col["netstat_in_packets_delta"])
    wg_out_packets_delta = $(col["netstat_out_packets_delta"])
    if (wg_recv_delta != "" && wg_in_packets_delta != "") {
      if ((wg_in_packets_delta + 0) > 0) {
        packet_size_value = (wg_recv_delta + 0) / (wg_in_packets_delta + 0)
        if (packet_size_floor == "" || packet_size_value > (packet_size_floor + 0)) {
          packet_size_received[rows] = packet_size_value
        }
      }
    }
    if (wg_sent_delta != "" && wg_out_packets_delta != "") {
      if ((wg_out_packets_delta + 0) > 0) {
        packet_size_value = (wg_sent_delta + 0) / (wg_out_packets_delta + 0)
        if (packet_size_floor == "" || packet_size_value > (packet_size_floor + 0)) {
          packet_size_sent[rows] = packet_size_value
        }
      }
    }
  }

  END {
    required[1] = "timestamp_unix_ms"
    required[2] = "interval_seconds"
    required[3] = "wireguard_transfer_received_bytes_delta"
    required[4] = "wireguard_transfer_sent_bytes_delta"
    required[5] = "netstat_in_packets_delta"
    required[6] = "netstat_out_packets_delta"

    missing = ""
    for (i = 1; i <= 6; i++) {
      if (!(required[i] in col)) {
        missing = missing " " required[i]
      }
    }
    if (missing != "") {
      print "Missing required columns in growth CSV:" missing > "/dev/stderr"
      exit 2
    }

    if (rows == 0) {
      if (cutoff_ts != "") {
        printf "No growth rows at or before cutoff timestamp %s in %s\n", cutoff_ts, source
        exit 0
      }
      print "No growth rows yet in " source
      exit 0
    }

    start = rows - window + 1
    if (start < 1) {
      start = 1
    }

    print "VPN Packet Size Distribution Dashboard"
    printf "source=%s\n", source
    if (cutoff_ts != "") {
      printf "as_of_timestamp_unix_ms=%s\n", cutoff_ts
    }
    if (packet_size_floor != "") {
      printf "packet_size_floor_exclusive_gt=%s\n", packet_size_floor
    }
    printf "rows=%d window_rows=%d latest_timestamp_unix_ms=%s latest_interval_seconds=%s\n", rows, rows - start + 1, ts[rows], interval[rows]

    draw_distribution("incoming_packet_size_b_per_wg_packet", packet_size_received, start, rows, 10)
    draw_distribution("outgoing_packet_size_b_per_wg_packet", packet_size_sent, start, rows, 10)
  }
  ' "$INPUT"
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    print_usage
    die "Missing subcommand: trends|distribution|collect"
  fi

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print_usage
    exit 0
  fi

  if [[ "$1" == -* ]]; then
    print_usage
    die "Subcommand must be first argument: trends|distribution|collect"
  fi

  case "$1" in
    trends|distribution|collect)
      SUBCOMMAND="$1"
      shift
      ;;
    *)
      die "Unknown subcommand: $1"
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data)
        require_option_value "$1" "${2:-}"
        DATA_DIR="${2:-}"
        shift 2
        ;;
      --interval)
        require_option_value "$1" "${2:-}"
        INTERVAL_SECONDS="${2:-}"
        shift 2
        ;;
      --window)
        require_option_value "$1" "${2:-}"
        WINDOW="${2:-}"
        shift 2
        ;;
      --no-clear)
        NO_CLEAR="1"
        shift
        ;;
      --once)
        ONCE="1"
        shift
        ;;
      --at)
        require_option_value "$1" "${2:-}"
        ONCE_TIMESTAMP_UNIX_MS="${2:-}"
        shift 2
        ;;
      --format)
        require_option_value "$1" "${2:-}"
        FORMAT="${2:-}"
        shift 2
        ;;
      --packet-size-floor)
        require_option_value "$1" "${2:-}"
        PACKET_SIZE_FLOOR="${2:-}"
        shift 2
        ;;
      --iface)
        require_option_value "$1" "${2:-}"
        IFACE="${2:-}"
        shift 2
        ;;
      --fail-fast)
        FAIL_FAST="1"
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  is_positive_number "$INTERVAL_SECONDS" || die "--interval must be > 0"

  INPUT="$DATA_DIR/growth.csv"
  RAW_OUTPUT="$DATA_DIR/raw.csv"
  GROWTH_OUTPUT="$DATA_DIR/growth.csv"

  case "$SUBCOMMAND" in
    trends|distribution)
      is_positive_integer "$WINDOW" || die "--window must be a positive integer"
      case "$FORMAT" in
        plain|md) ;;
        *) die "--format must be one of: plain, md" ;;
      esac
      if [[ -n "${PACKET_SIZE_FLOOR:-}" ]]; then
        is_non_negative_number "$PACKET_SIZE_FLOOR" || die "--packet-size-floor must be a non-negative number"
      fi
      if [[ -n "$ONCE_TIMESTAMP_UNIX_MS" ]]; then
        is_non_negative_integer "$ONCE_TIMESTAMP_UNIX_MS" || die "--at must be a non-negative integer (unix ms)"
      fi
      ;;
    collect)
      [[ -n "$IFACE" ]] || die "--iface requires a value"
      ;;
  esac
}

main() {
  parse_args "$@"

  if [[ "$SUBCOMMAND" == "collect" ]]; then
    collect_run
    exit 0
  fi

  while true; do
    if [[ "$NO_CLEAR" == "0" ]]; then
      printf '\033[H\033[2J'
    fi

    if [[ "$SUBCOMMAND" == "distribution" ]]; then
      if ! render_distribution; then
        echo "Unable to render packet-size distribution from $INPUT" >&2
      fi
    elif ! render_dashboard; then
      echo "Unable to render trends from $INPUT" >&2
    fi

    if [[ "$ONCE" == "1" ]]; then
      exit 0
    fi

    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
