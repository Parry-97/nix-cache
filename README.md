# nix-cache

A self-hosted [Nix binary cache](https://cache.nixos.org/) backed by
[Attic](https://github.com/zhaofengli/attic) on a NixOS host, exposed to the
internet only over a [Tailscale](https://tailscale.com/) service VIP, with
GitHub Actions CI that builds the packages in this flake and pushes the
results to the cache.

```
GitHub Actions runner ──► $CACHE_HOST (Tailscale Service, svc:nix-cache)
                              │ tailscale ACL grants tag:ci access
                              ▼
                        batman (NixOS)
                        ├── atticd :8081 (SQLite + local storage)
                        ├── Caddy → http://cache.local (LAN alias)
                        └── Tailscale Service svc:nix-cache → 127.0.0.1:8081
```

## What's in the flake

`packages.default` builds the [unsloth](https://unsloth.ai/) desktop app
(`unsloth-desktop.nix`, version `0.1.804-beta`) by unpacking the upstream
Ubuntu `.deb` into an FHS environment. A second expression, `package.nix`,
packages the [GitButler](https://gitbutler.com/) CLI (`but`) as a packaging
exercise. Both unfree/binary-source friendly, CI sets
`NIXPKGS_ALLOW_UNFREE=1` and builds with `--impure`.

## How it works

### Server side (host `batman`)

- `atticd` runs with SQLite metadata and local blob storage.
- `http://127.0.0.1:8081` is exposed over HTTPS as a Tailscale Service
  (`svc:nix-cache`), holding a stable TailVIP any node can dial if its ACL
  grants it access. Its service hostname and IP live in the repo's Actions
  secrets, not in this file or the workflow.
- The cache is named `main`, served **publicly** for reads, with
  `cache.nixos.org-1` configured upstream so substituted fetches
  sign in with upstream headers (see gotchas).
- Public signing key (a verification key, safe to share with CI partners
  but still kept in an Actions secret here so it isn't indexed by
  search/robots on every curl of the repo).
- A Caddy virtual host also serves it on the LAN via `http://cache.local`.

### CI side (Actions runner)

1. `nix-installer-action` installs Nix with `extra-substituters`
   pointing at `https://$CACHE_HOST/main` and `$CACHE_MAIN_KEY` as
   trusted public key — both resolved from Actions secrets.
2. `tailscale/github-action` joins the runtime node with `tag:ci`, which
   is the only tag allowed to reach `svc:nix-cache`.
3. Instead of a `tailscale ping` sanity gate, the workflow pins the VIP's
   `$CACHE_VIP` → `$CACHE_HOST` pair in `/etc/hosts` and polls
   `curl -m 10 https://$CACHE_HOST/main/nix-cache-info` for 150 s — CI
   runners on systemd-resolved don't route `ts.net` MagicDNS, and Service
   VIPs reject ICMP dials.
4. `nix build --impure` resolves the package. `attic push main ./result`
   uses `nixpkgs#attic-client` instead of the flake in the attic repo,
   which used to trigger ~26 min of local cargo rebuilds on each job.

### Gotchas worth knowing

- **"0 already cached, 265 in upstream" summary lines are normal.** Attic
  skips any store path that carries a signature from
  `cache.nixos.org-1` (upstream `extra-trusted-public-keys`) — so a
  `./result` that resolves entirely to upstream substituted paths uploads
  nothing. To force a push for debugging use
  `attic push --ignore-upstream-cache-filter --no-closure main <path>`.
- **Tailnet-only access:** the cache URL is valid only inside the tailnet;
  reaching the VIP requires the `tag:ci` grant in the ACL plus the
  `$CACHE_VIP` → `$CACHE_HOST` `/etc/hosts` pin in the runner's step.

## Secrets used by Actions

| Secret | Purpose |
|---|---|
| `CACHE_HOST` | Attic's service hostname inside the tailnet |
| `CACHE_VIP` | Static TailVIP pinned into `/etc/hosts` on runners |
| `CACHE_MAIN_KEY` | Attic cache's public verification key |
| `ATTIC_TOKEN` | Attic token granting push to `main` |
| `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_CLIENT_SECRET` | Tailscale OAuth join creds |

## Operations

```console
# re-issue a CI token (admin) on batman
attic login local http://127.0.0.1:8081 <admin-token>
attic token ... main --rw

# inspect the cache
attic cache list
attic cache info main

# push something the upstream filter would skip
attic push --ignore-upstream-cache-filter --no-closure main ./result

# rebuild locally (fetches whatever's still upstream)
nix build .#default
```

## Files

```
.github/workflows/nix-ci.yaml   # Tailscale join → curl gate → build → attic push
flake.nix                       # packages.default = unsloth desktop
unsloth-desktop.nix             # .deb → FHS env derivation
package.nix                     # packaging exercise: but (GitButler CLI)
```
