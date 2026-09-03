# k8s-slo-platform

Burn-rate alerting for Kubernetes services. Error budgets instead of CPU
thresholds, and a release gate that won't deploy into a service that's already
spent its budget.

The alerting rules are unit tested, so the interesting part runs in CI without a
cluster.

## Layout

```
slos/           one yaml per service, no promql
rules/          prometheus recording + alerting rules
  tests/        promtool unit tests
manifests/      prometheus, alertmanager, grafana, two demo services
policies/       conftest guardrails
scripts/        budget-gate.sh
```

## Why burn rate

A threshold on error rate is either too twitchy (pages on every blip) or too
loose (misses a slow bleed). Burn rate asks a different question: at this rate,
how long until the budget is gone?

Each alert pairs a long window with a short one.

| Alert | Fires when | Severity |
|---|---|---|
| `SLOBurnRateFast` | 14.4x over 1h and 5m, or 6x over 6h and 30m | page |
| `SLOBurnRateSlow` | 3x over 1d and 2h, or 1x over 3d and 6h | ticket |

Long window: is this real? Short window: is it still happening? Without the
short one the alert hangs around for an hour after the incident is over and
people learn to ignore it.

14.4x is from the SRE workbook. Burning 14.4 times faster than budgeted spends a
30 day budget in about two days, which is roughly when someone should be woken
up.

## Tests

```bash
make test-rules
```

12 scenarios across two services, run through promtool with synthetic series.
The useful ones are the cases that should stay quiet:

- a three minute blip doesn't page
- the page clears once errors stop, even though the 1h and 6h windows are still
  dirty, because the short windows are clean
- 0.5% errors raises a ticket but doesn't page
- 0.4% failures against a 99.5% objective stays silent, where the same rate
  would page a 99.9% service

The recovery test originally asserted the alert cleared at 50 minutes and
failed, because the 30 minute window still had errors in it. The rule was right
and the assertion was wrong.

## Guardrails

`policies/` holds conftest rules that run over the manifests. Missing limits,
missing probes, running as root, privilege escalation, `:latest` and undropped
capabilities fail. A writable root filesystem and an unscraped Deployment warn
instead, since both are sometimes fine.

```bash
make test-policy   # 13 tests of the policies themselves
make policy        # apply them to manifests/
```

The manifests here pass their own policies with no warnings.

## Release gate

```bash
PROM_URL=http://localhost:9090 ./scripts/budget-gate.sh checkout-api availability 0.20
```

Exit 1 when under 20% budget left, exit 2 when the budget can't be read. Those
are separate on purpose: a broken Prometheus shouldn't wave deploys through, and
it shouldn't block them without saying why either.

## Running it

```bash
make check
```

Needs promtool, kubeconform, conftest and shellcheck.

## Deploying

```bash
kubectl apply -f manifests/namespace.yaml
make rules-configmap | kubectl apply -f -
kubectl apply -R -f manifests/
kubectl -n observability port-forward svc/prometheus 9090
```

Rules come from a ConfigMap built straight out of `rules/`, so there's no
generated file to keep in sync.

## Status

Rules, policies and manifests are tested and schema-valid. **Not yet run in a
real cluster** - no Prometheus has scraped these targets and no alert has reached
Alertmanager.

So the alerting logic is proven against known inputs and the manifests are valid
Kubernetes. What isn't proven is the wiring: service discovery finding the demo
pods, the rules ConfigMap mounting where Prometheus expects it, and Alertmanager
routing by severity.

The demo image emits `http_requests_total`, so checkout-api has real data behind
it and payments-worker doesn't.

## License

MIT
