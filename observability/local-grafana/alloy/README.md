# The Alloy config is not here

The collector runs on the **BE host** (`192.168.68.68`), inside the BE compose
stack, on the network its two scrape targets are on. Its single source is:

```
GoGo-BE/docker/alloy/config.alloy
```

Deployed by the observability overlay, `GoGo-BE/docker/docker-compose.observability.yml`,
which GoGo-Infra adds only when `PROMETHEUS_REMOTE_WRITE_URL` is present in the
rendered env file — so the container and the endpoint arrive together or
neither does.

## Why a pointer instead of a copy

There was a second copy here. It was a working config, which is what made it
dangerous: it named the same job, the same two targets and the same
remote-write block, so it was right enough to follow and wrong the moment
either file changed alone. `vps/README.md` already states the general form of
this — two descriptions of how to run something are worse than one, because
nobody can tell which one is stale until it matters.

Nothing about the collector is configured from this directory. Change
`config.alloy` in GoGo-BE.

## What this host does hold

Prometheus and Grafana, one directory up. See [`../README.md`](../README.md).
