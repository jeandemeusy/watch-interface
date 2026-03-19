# watch-interface

A shell script tool for capturing GnosisVPN / HOPR interface counters at a configurable interval and computing growth, rate, and packet-size analytics — all written to CSV for further analysis or live terminal dashboards.

## Overview

`watch_interface_statistics.sh` is a single entrypoint with three subcommands:

| Subcommand | Description |
|---|---|
| `collect` | Gathers counters from `netstat`, `wg show`, and `gnosis_vpn-ctl telemetry`; writes raw + growth CSVs in one run |
| `trends` | Live terminal dashboard with sparklines for rate/ratio metrics and derived packet sizes |
| `distribution` | Packet-size histogram (incoming / outgoing) from growth deltas |

All subcommands share a single `--data DIR` flag pointing to the data directory. `collect` writes `DIR/raw.csv` and `DIR/growth.csv` there; `trends` and `distribution` read `DIR/growth.csv` from it.

## Requirements

- macOS or Linux with `bash`
- `wg` (`wireguard-tools`) — `sudo` access required
- `gnosis_vpn-ctl` with a working `telemetry` subcommand
- macOS: `netstat` (BSD) for interface stats
- Linux: `/proc/net/dev` (available on all Linux kernels)

## Usage

### Collect — capture counters every 10 s

```bash
./watch_interface_statistics.sh collect \
  --data data/ \
  --iface utun4 \
  --interval 10
```

Defaults: `--data data`, `sudo wg show`, `gnosis_vpn-ctl telemetry`. `--iface` is required.

Useful flags:

```bash
./watch_interface_statistics.sh collect --data data/ --iface utun4 --once   # single snapshot (macOS)
./watch_interface_statistics.sh collect --data data/ --iface wg0 --once     # single snapshot (Linux)
```

> If you already have a raw CSV from a previous format, point `--data` to a fresh directory — the collector enforces the current schema and will reject mismatches.

### Trends — live terminal dashboard

```bash
./watch_interface_statistics.sh trends \
  --data data/ \
  --interval 2 \
  --window 40
```

Key flags:

| Flag | Description |
|---|---|
| `--once` | Render one snapshot and exit |
| `--at <timestamp_unix_ms>` | Render as of a specific timestamp (rows after it are ignored) |
| `--packet-size-floor <bytes>` | Exclude packet-size values `<=` this threshold from stats |
| `--format md` | Render the metrics table as Markdown |

The dashboard shows sparkline blocks (`▁▂▃▄▅▆▇█`) per metric and includes derived columns:
- `packet_size_received_b_per_wg_packet` = `wireguard_transfer_received_bytes_delta / netstat_in_packets_delta`
- `packet_size_sent_b_per_wg_packet` = `wireguard_transfer_sent_bytes_delta / netstat_out_packets_delta`

### Distribution — packet-size histogram

```bash
./watch_interface_statistics.sh distribution \
  --data data/ \
  --interval 2 \
  --window 40
```

Computes per-step packet sizes from growth deltas and shows histogram bins for `incoming_packet_size_b_per_wg_packet` and `outgoing_packet_size_b_per_wg_packet`.

`--format md` and `--packet-size-floor` also apply here.

## CSV Schema

### Raw CSV

| Column | Description |
|---|---|
| `timestamp_unix_ms` | Unix timestamp in milliseconds |
| `netstat_interface` | Network interface name |
| `netstat_in_packets` | Cumulative inbound packet count |
| `netstat_out_packets` | Cumulative outbound packet count |
| `wireguard_transfer_received_bytes` | Cumulative WireGuard received bytes |
| `wireguard_transfer_sent_bytes` | Cumulative WireGuard sent bytes |
| `hopr_packets_received` | Cumulative HOPR packets received |
| `hopr_packets_sent` | Cumulative HOPR packets sent |

### Growth CSV

| Column | Description |
|---|---|
| `timestamp_unix_ms` | Unix timestamp in milliseconds |
| `previous_timestamp_unix_ms` | Timestamp of the previous row |
| `interval_seconds` | Elapsed seconds between rows |
| `netstat_in_packets_delta` | Inbound packet count delta |
| `netstat_out_packets_delta` | Outbound packet count delta |
| `wireguard_transfer_received_bytes_delta` | WireGuard received bytes delta |
| `wireguard_transfer_sent_bytes_delta` | WireGuard sent bytes delta |
| `hopr_packets_received_delta` | HOPR received packets delta |
| `hopr_packets_sent_delta` | HOPR sent packets delta |
| `netstat_in_packets_rate_per_sec` | Inbound packet rate |
| `netstat_out_packets_rate_per_sec` | Outbound packet rate |
| `wireguard_transfer_received_bytes_rate_per_sec` | WireGuard received bytes rate |
| `wireguard_transfer_sent_bytes_rate_per_sec` | WireGuard sent bytes rate |
| `hopr_packets_received_rate_per_sec` | HOPR received packet rate |
| `hopr_packets_sent_rate_per_sec` | HOPR sent packet rate |
| `ratio_hopr_received_to_netstat_in_cumulative` | Cumulative HOPR-to-netstat received ratio |
| `ratio_hopr_sent_to_netstat_out_cumulative` | Cumulative HOPR-to-netstat sent ratio |
| `ratio_hopr_received_to_netstat_in_delta` | Per-interval HOPR-to-netstat received ratio |
| `ratio_hopr_sent_to_netstat_out_delta` | Per-interval HOPR-to-netstat sent ratio |
| `counter_reset_detected` | `yes` if any counter moved backwards (e.g. after service restart) |

> When `counter_reset_detected=yes`, deltas and rates in that row may be negative.

## License

MIT
