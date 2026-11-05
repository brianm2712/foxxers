# Deploying Foxxers

Foxxers is Node standard library only: no npm install, no build step. A deploy
is moving a git checkout to a commit and restarting a systemd unit.

## What production is

Proxmox (`ssh -i ~/.ssh/proxmox root@100.102.227.73`):

- **`foxxers.service`**: plain systemd, `User=fenris`,
  `node /opt/fenris/foxxers/server/index.js`, bound to `127.0.0.1:8120`.
  Sandboxed (`ProtectSystem=strict`, writes only `data/`). Drop-ins add a
  restart limit and `ExecStartPre=-/usr/local/sbin/foxxers-store-preflight`,
  which moves a corrupt `foxxers.json` aside instead of crash-looping (NOC-54).
- **`/opt/fenris/foxxers`**: a git clone of GitHub, owned by `fenris`. The
  deploy runs git there as `fenris`.
- **`/opt/fenris/foxxers/data`** (0700, gitignored): the whole database
  (`foxxers.json`) and `.session-key`. Lose the key and everyone is signed out
  and every customer `/j/<ref>?t=…` link stops working. A checkout never
  touches this directory.
- Configuration is `Environment=` lines in the unit, not an env file. Right now
  that is only `FOXXERS_PORT`, `FOXXERS_HOST` and `FOXXERS_DATA`.

There is **no Docker** in production. The `Dockerfile` in this repo is not
what serves foxxers.com. An earlier `deploy.sh` assumed a container and would
have rsynced this folder over the live source (Plane CHG-5 has the audit).

## Deploying

From this repo, on the Mac, **outside any sandbox** (the suite binds localhost
ports and fails with `listen EPERM` under one, which looks like a broken test
and is not):

```bash
./scripts/deploy.sh --check      # preflight; changes nothing anywhere
./scripts/deploy.sh              # deploy HEAD
./scripts/deploy.sh <commit>     # deploy a specific commit
```

The commit must be **pushed**: the server fetches from GitHub, so the script
refuses anything origin does not have. Uncommitted edits in this folder are
never deployed.

In order, it:

1. runs every `tests/*.test.js` against the target commit in a throwaway
   worktree, and stops if any fail;
2. on the server, fetches and **refuses** if the live tree has untracked files
   or edits that the target commit does not already contain. Edits that are
   already in the target are stashed, not discarded. A fix made by hand on the
   server has to be committed here before the next deploy, which is the point;
3. checks out the commit (detached), restarts `foxxers.service`, and waits for
   `/api/v1/health` to answer and keep answering;
4. if it does not, checks the previous commit back out, restores any stash,
   restarts, and exits non-zero with the last journal lines.

## Rolling back

Every successful deploy prints the commit it replaced. Deploy that commit:

```bash
./scripts/deploy.sh <previous-sha>
```

## Checking it worked

```bash
ssh -i ~/.ssh/proxmox root@100.102.227.73 'curl -fsS http://127.0.0.1:8120/api/v1/health'
curl -fsS https://foxxers.com/api/v1/health
```

The first answering and the second not means the app is fine and the tunnel
(or the WAF in front of it) is not. For anything else:
`journalctl -u foxxers.service`.

## Before real customers

- **`FOXXERS_PUBLIC_URL=https://foxxers.com`** is not set in the unit yet. It
  is where Stripe sends people back to. Add it as an `Environment=` line (or a
  drop-in) before payments go on.
- **Payments stay off** until `FOXXERS_PAYMENTS=stripe` is set with a key. The
  default is `manual`, which records what would have happened and moves no
  money. Stripe secrets belong in a root-owned drop-in or
  `EnvironmentFile=` with mode 0600, not in this repo.
- **The webhook endpoint** becomes `https://foxxers.com/api/v1/webhooks/stripe`
  once payments are live. See the dashboard half of `go-live.md`.
- **Seed data is demo data.** Do not run `scripts/seed.js` against the live
  data directory; it writes six fictional tradespeople into the database.
- **The platform agreement has not been reviewed by a solicitor.** It is wired
  into onboarding and a foxxer cannot get a Stripe account without accepting
  it. See the top of `go-live.md`.

## Ports on that box

8120 is foxxers. Others in use include 8080 (portfolio), 8091 (ai-siem), 8093
(fenris-auth), 8097 (bjj-app), 8099 (dj-site), 8100–8104 and 8121. A second
instance needs its own port in a second unit.
