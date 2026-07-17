# pypi-cache — proxpi PyPI caching proxy

A [proxpi](https://github.com/EpicWink/proxpi) caching reverse-proxy for PyPI,
serving the homelab GitHub Actions runners (`arc-runners/plotlens-runner`).

## Why

The runners have no local PyPI mirror — pip pulls straight from PyPI. The
homelab → `files.pythonhosted.org` (PyPI's CDN) link is reachable but
erratically slow (a 37 KB wheel took 5 s directly, and >120 s under CI load),
so a dependency bump to a wheel not already on a runner would intermittently
fail `Test Python` with `ReadTimeoutError: files.pythonhosted.org: Read timed
out`. proxpi fetches each wheel from PyPI once, caches it on an NFS-backed
(Retain) volume, and serves every later request locally and fast.

This replaced the earlier stop-gap in the plotlens repo CI (`PIP_EXTRA_INDEX_URL`
+ bumped pip timeout/retries), which fixed *resolution* but not the slow
*download*.

## How runners consume it

`arc-runners/plotlens-runner` (manual Helm release, chart `gha-runner-scale-set`)
sets on the runner container:

```yaml
env:
  - name: PIP_INDEX_URL
    value: http://proxpi.pypi-cache.svc.cluster.local:5000/index/
  - name: PIP_TRUSTED_HOST
    value: proxpi.pypi-cache.svc.cluster.local
```

The plotlens repo CI keeps `PIP_EXTRA_INDEX_URL=https://pypi.org/simple/` as a
**miss/outage fallback**: if proxpi can't serve a package, pip degrades to
direct PyPI instead of hard-failing.

## Rollback

Remove the two runner env vars (`helm upgrade` without them) — pip goes back to
direct PyPI. proxpi being down only matters because it is pip's primary index;
the extra-index fallback covers a proxy *miss* but not a proxy *outage*, so a
prolonged outage warrants the env removal above.

## Verify

```bash
kubectl -n pypi-cache get pods
kubectl -n arc-runners exec <a-running-plotlens-runner> -c runner -- \
  pip download --dest /tmp/x soupsieve==2.8.4   # first: fetches+caches; repeat: fast
```
