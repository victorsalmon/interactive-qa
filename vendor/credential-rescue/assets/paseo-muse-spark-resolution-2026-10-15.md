# What works today — Muse Spark 1.3 Contributor model names (2026-10-15)

Recorded during the `opencode/muse-spark-1.3-contributor ... Model not found` incident.
Paseo daemon log tell: `handleStreamEvent: turn_failed ... "Model not found:
opencode/muse-spark-1.3-contributor. Did you mean: muse-spark-1.3-contributor-free?"`
(`~/.paseo/daemon.log`, provider `opencode`).

## Verified this box, this date (no secret values below)

| Check | Result |
| :--- | :--- |
| `opencode models opencode-go \| Select-String muse-spark` | lists `opencode-go/muse-spark-1.3-contributor` — **exists** |
| `opencode models opencode \| Select-String muse-spark` | lists `opencode/muse-spark-1.2`, `opencode/muse-spark-1.3`, `opencode/muse-spark-1.3-contributor-free` — `opencode/muse-spark-1.3-contributor` **does NOT exist** |
| `opencode run 'reply with the single word pong' --model opencode-go/muse-spark-1.3-contributor --variant default` (User-scope key) | `pong` — **endpoint answers** |
| `paseo provider diagnostic opencode` | `Status: Ready`, 589 models, binary override resolves — binary/PATH healthy, **not** the fault |
| `opencode.jsonc` provider `opencode-go` | `baseURL https://opencode.ai/zen/go/v1`, models `muse-spark-1.3-contributor` + `deepseek-v4.1-flash` |

## Conclusion — the provider prefix IS `opencode-go/`

The failing name `opencode/muse-spark-1.3-contributor` is the Paseo provider id
(`opencode`, the CLI wrapper) glued onto the bare opencode model id. Nothing
by that name exists upstream; the suggestion (`-free`) is a different wallet.
Paseo must pass the full opencode model string **`opencode-go/muse-spark-1.3-contributor`**
through verbatim — that is the name the endpoint answers to. Any Paseo agent
profile / additionalModel entry for this model keeps the `opencode-go/` prefix.

## Quick canary (no inference, no tokens, <15s)

`scripts/Test-PaseoMuseSparkCanary.ps1` asserts the exact name resolves in
`opencode models opencode-go` and explains the `opencode/` mis-prefix when it
does not. `-WithRun` adds the one-word inference proof (needs the User key,
~60s). It is the designed `-PaseoOnly` check for `Switch-OpencodeGoKey.ps1`
(wiring staged in the working copy; run it standalone until that lands).
