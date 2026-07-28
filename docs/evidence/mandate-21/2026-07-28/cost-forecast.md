# Cost Forecast Evidence — 2026-07-28

## Cost Explorer window

- Window: `2026-07-21` through `2026-07-27` (`End=2026-07-28`, exclusive).
- Data status: Estimated.
- Unblended cost total: `$377.548091`, displayed as `$377.55`.

| Service | Cost (USD) |
|---|---:|
| EC2 Compute | 81.6460566479 |
| CloudTrail | 74.7455530000 |
| VPC | 60.2857983988 |
| EC2 Other | 44.2061761188 |
| MSK | 30.1729959737 |
| RDS | 23.7063762216 |
| CloudWatch | 18.3196251444 |
| EKS | 16.8000000000 |
| Other | 27.9651304954 |
| **Total** | **377.5480910000** |

## Forecast

`normalized_7d = raw Cost Explorer estimate - documented one-offs + full-week normalization of permanent resources`

No one-off removal or savings has current evidence, so normalized estimate remains `$377.55`. NAT is already included and receives no additional adjustment. Reverted CloudTrail selector work receives `$0.00` savings credit.

`drill_week_forecast = $377.548091 + $4.30 conservative two-AZ FIS allowance = $381.85`

- Estimated-period gate: **FAIL** — `$377.55 > $300.00`.
- Forecast gate: **FAIL** — `$381.85 > $300.00`.

<!-- Change trail: @hungxqt - 2026-07-28 - Replaced unsupported savings with the current Cost Explorer estimate and conservative forecast. -->