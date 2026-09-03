# k8s-slo-platform

SLO-based alerting for Kubernetes services. Error budgets instead of CPU
thresholds, burn-rate alerts instead of "pod restarted", and a release gate that
refuses to deploy into a service that has already spent its budget.

The alerting rules are unit tested, so the interesting part runs in CI without a
cluster.

## Layout

```
slos/           one small yaml per service, no promql
rules/          prometheus recording + alerting rules
  tests/        promtool unit tests
manifests/      prometheus, alertmanager, grafana, two demo services
policies/       conftest guardrails + their tests
scripts/        budget-gate.sh, used as a deploy gate
```

## Why burn rate

A threshold alert on error rate is either too sensitive (pages on every blip)
or too loose (misses a slow bleed that eats the month's budget). Burn rate fixes
both by asking a different question: at the current rate, how long until the
budget is gone?

Each alert pairs a long window with a short one:

| Alert | Fires when | Severity |
|---|---|---|
| `SLOBurnRateFast` | 14.4x over 1h **and** 5m, or 6x over 6h **and** 30m | page |
| `SLOBurnRateSlow` | 3x over 1d **and** 2h, or 1x over 3d **and** 6h | ticket |

The long window answers "is this real?". The short window answers "is it still
happening?" - without it an alert hangs around for an hour after the incident
is over, and people learn to ignore it.

14.4x comes from the SRE workbook: burning 14.4 times faster than budgeted spends
a 30 day budget in about two days, which is roughly the point at which someone
should be woken up.

## Tests

The rules are unit tested with `promtool`, which replays synthetic time series
through them:

```bash
make test-rules
```

12 scenarios across two services. The ones worth reading are the cases that
should stay quiet:

- **a three minute blip does not page** - the long window never gets dirty enough
- **the page clears once errors stop**, even though the 1h and 6h windows are
  still dirty, because the short windows are clean
- **0.5% errors raises a ticket but does not page** - above 3x burn, below 14.4x
- **0.4% failures against a 99.5% objective stay silent**, where the same rate
  would page a 99.9% service

Writing these caught a real mistake: the recovery test originally asserted the
alert cleared after 50 minutes, and it failed, because the 30 minute window still
had errors in it. The rule was right and the assertion was wrong.

## Guardrails

`policies/` holds conftest rules that run over every manifest. Missing memory
limits, missing probes, running as root, privilege escalation, `:latest` tags and
undropped capabilities all fail the build. A writable root filesystem and an
unscraped Deployment warn instead, because both are sometimes legitimate.

Each rule has a comment explaining the consequence of not having it, and 13 unit
tests of its own:

```bash
make test-policy   # tests the policies
make policy        # applies them to manifests/
```

The manifests in this repo pass their own policies with no warnings.

## Release gate

```bash
PROM_URL=http://localhost:9090 ./scripts/budget-gate.sh checkout-api availability 0.20
```

Exits 1 when less than 20% of the budget is left, 2 when the budget cannot be
read at all. The two are separate on purpose: a broken Prometheus should not
silently wave deploys through, and it should not block them without saying why.

## Running everything

```bash
make check
```

Needs `promtool`, `kubeconform`, `conftest` and `shellcheck`.

## Deploying

```bash
kubectl apply -f manifests/namespace.yaml
make rules-configmap | kubectl apply -f -
kubectl apply -R -f manifests/
```

Rules live in a ConfigMap built straight from `rules/`, so there is no generated
file to keep in sync.

Then port-forward and look at it:

```bash
kubectl -n observability port-forward svc/prometheus 9090
```

## Status

Rules, policies and manifests are all tested and schema-valid. **Nothing here has
been run in a real cluster.** No Prometheus has scraped these targets, no alert
has reached Alertmanager, and the Grafana dashboard has never been rendered.

So what is proven is that the alerting logic behaves correctly against known
inputs, the manifests are valid Kubernetes, and the guardrails work. What is not
proven is that the pieces talk to each other: service discovery finding the demo
pods, the rules ConfigMap mounting where Prometheus expects it, and Alertmanager
routing by severity.

The demo services are a stand-in image that emits `http_requests_total`, so the
checkout-api SLOs have real data behind them and the payments-worker one does not.

## License

MIT
