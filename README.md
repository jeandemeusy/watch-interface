# VPN Metrics Capture

This folder captures VPN counters every 10 seconds and computes growth/ratio analytics in CSV.

## Files

- `watch_interface_statistics.sh`: single entrypoint with three subcommands:
  - `collect`: gathers counters from `netstat`, `wg show`, `gnosis_vpn-ctl telemetry`, and writes raw + growth CSV in the same run
  - `trends`: ratio/rate trends + packet-size trend lines
  - `distribution`: packet-size histogram/distribution view (incoming/outgoing)
- `data/`: generated CSV files.

## Capture data every 10s (raw + growth together)

From this directory:

```bash
./watch_interface_statistics.sh collect \
  --interval-seconds 10 \
  --raw-output data/vpn_metrics_raw.csv \
  --growth-output data/vpn_metrics_growth.csv
```

Defaults:

- interface `utun4`
- `sudo wg show`
- telemetry command `gnosis_vpn-ctl telemetry`

Useful options:

```bash
./watch_interface_statistics.sh collect --once
./watch_interface_statistics.sh collect --iface utun4
```

If you already have a raw CSV from a previous format, start with a new file path (or archive/remove the old file) because the collector enforces the current schema.

## Live Terminal Trends

```bash
./watch_interface_statistics.sh trends \
  --input data/vpn_metrics_growth.csv \
  --interval-seconds 2 \
  --window 40
```

Use `--once` to render one snapshot and exit.
Use `--once <timestamp_unix_ms>` to render as if that timestamp were the latest measured row (rows after it are ignored).
Use `--min_packet_size <bytes>` to exclude packet-size values `<=` threshold from packet-size trend/distribution stats.
When filtering is enabled, output includes `min_packet_size_exclusive_gt=<bytes>` for traceability.
Use `--format md` to render the metrics table as Markdown.
The dashboard shows sparkline blocks (`▁▂▃▄▅▆▇█`) per metric.
It also includes:
- `packet_size_received_b_per_wg_packet`: `wireguard_transfer_received_bytes_delta / netstat_in_packets_delta`
- `packet_size_sent_b_per_wg_packet`: `wireguard_transfer_sent_bytes_delta / netstat_out_packets_delta`

## Packet Size Distribution View

```bash
./watch_interface_statistics.sh distribution \
  --input data/vpn_metrics_growth.csv \
  --interval-seconds 2 \
  --window 40
```

This view computes per-step packet sizes from growth deltas and shows histogram bins for:
- `incoming_packet_size_b_per_wg_packet`
- `outgoing_packet_size_b_per_wg_packet`

`--format md` also works in this subcommand and renders each histogram as a Markdown table.
`--min_packet_size <bytes>` also applies in this subcommand.

## Raw CSV columns

- `timestamp_unix_ms`
- `netstat_interface`
- `netstat_in_packets`
- `netstat_out_packets`
- `wireguard_transfer_received_bytes`
- `wireguard_transfer_sent_bytes`
- `hopr_packets_received`
- `hopr_packets_sent`

## Growth CSV columns

- `timestamp_unix_ms`
- `previous_timestamp_unix_ms`
- `interval_seconds`
- `netstat_in_packets_delta`
- `netstat_out_packets_delta`
- `wireguard_transfer_received_bytes_delta`
- `wireguard_transfer_sent_bytes_delta`
- `hopr_packets_received_delta`
- `hopr_packets_sent_delta`
- `netstat_in_packets_rate_per_sec`
- `netstat_out_packets_rate_per_sec`
- `wireguard_transfer_received_bytes_rate_per_sec`
- `wireguard_transfer_sent_bytes_rate_per_sec`
- `hopr_packets_received_rate_per_sec`
- `hopr_packets_sent_rate_per_sec`
- `ratio_hopr_received_to_netstat_in_cumulative`
- `ratio_hopr_sent_to_netstat_out_cumulative`
- `ratio_hopr_received_to_netstat_in_delta`
- `ratio_hopr_sent_to_netstat_out_delta`
- `counter_reset_detected`

If `counter_reset_detected=yes`, at least one counter moved backwards (for example after service restart). Deltas/rates may be negative in that step.
