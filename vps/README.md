# Production host configuration

Everything the VPS runs, kept in the repository. INF-018.

```
vps/
├── caddy/Caddyfile           reverse proxy, TLS, security headers, log redaction
└── systemd/
    ├── gogo-api.service
    └── gogo-worker.service
```

## Why these are files here and not settings there

A change made by hand on the host survives until the next deploy and then vanishes. That is the
worst kind of configuration: it works, nobody can reproduce why, and the reason it stopped
working is invisible.

## Release layout these assume

```
/opt/gogo/
├── releases/<sha>/
├── shared/.env.prod          mode 0600, replaced atomically by the deploy
└── current -> releases/<sha>
```

`WorkingDirectory=/opt/gogo/current` resolves the symlink at start, so a restart picks up the new
release and a rollback picks up the old one without editing the unit.

## What the units do beyond starting a process

- `EnvironmentFile=/opt/gogo/shared/.env.prod` — rendered by the deploy workflow from SSM. The
  host holds no AWS credentials; see `docs/adr/0001`.
- `StartLimitBurst=5` in a minute stops the unit. A crash loop should be visible rather than
  flapping quietly forever.
- `ProtectSystem=strict` with `ReadWritePaths=/opt/gogo/shared` — the application writes nothing
  outside its own shared directory, so a path traversal has nowhere to land.

## Log redaction is in the proxy, not the app

`GOGO_SRS.md` §10.2 forbids tokens and cookies in logs. Caddy sees `Authorization` and `Cookie`
whether or not the application chooses to log them, so the filter belongs where the header
arrives. The application redacting its own logs is a second layer, not the first.

## Installing

Not automated yet — `INF-017` renders the environment file and restarts the units, but a first
install still puts these in place by hand:

```bash
sudo install -m 644 vps/caddy/Caddyfile /etc/caddy/Caddyfile
sudo install -m 644 vps/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gogo-api gogo-worker
sudo systemctl reload caddy
```

`ACME_EMAIL`, `API_DOMAIN` and `CMS_DOMAIN` come from the environment Caddy is started with.

## The deploy user needs exactly two sudo rules

`deploy-vps.sh` runs `systemctl restart gogo-api gogo-worker` and `install` for the env file.
Grant those and nothing else — a deploy account with general sudo is a deploy key that owns the
machine:

```
deploy ALL=(root) NOPASSWD: /bin/systemctl restart gogo-api gogo-worker
deploy ALL=(root) NOPASSWD: /usr/bin/install -m 600 -o gogo -g gogo /opt/gogo/shared/.env.prod.new /opt/gogo/shared/.env.prod
```
