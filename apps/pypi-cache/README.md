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

The plotlens repo CI does **not** set `PIP_EXTRA_INDEX_URL`. It is tempting to
add `=https://pypi.org/simple/` as an outage fallback, but pip merges candidates
from both indexes and then pulls some wheels straight from `files.pythonhosted.org`
(the pypi index's URLs) — bypassing this cache and re-hitting the exact slow-CDN
read-timeout the proxy exists to avoid. So proxpi is the **only** index; CI keeps
only `PIP_DEFAULT_TIMEOUT` + `PIP_RETRIES` (which also cover proxpi's cold-cache
upstream fetch of a not-yet-seen wheel).

## Rollback

proxpi is pip's sole index, so a proxy outage blocks CI. To roll back, remove the
two runner env vars (`helm upgrade` without them) — pip goes back to direct PyPI.
That is the intended outage lever, **not** an extra-index fallback (see above for
why the extra index is actively harmful).

## Verify

```bash
kubectl -n pypi-cache get pods
kubectl -n arc-runners exec <a-running-plotlens-runner> -c runner -- \
  pip download --dest /tmp/x soupsieve==2.8.4   # first: fetches+caches; repeat: fast
```
