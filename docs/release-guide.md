# Release guide: build, check, publish

How to ship a new release, what CI does, and what to do when it fails.
The Pi side (installing, updating, secrets) is in [pi-operations.md](pi-operations.md).

Written against release **v0.1.3** (November 2026). If this and a workflow file disagree, the file is right.

---

## 1. Quick reference

```
branch -> PR -> CI green -> merge to main -> CI green on main -> tag vX.Y.Z -> release workflow
       -> check the feed -> update the Pi when it is online
```

```bash
cd ~/pi
export GIT_SSH_COMMAND='ssh -i ~/.ssh/github.key -o IdentitiesOnly=yes'
REPO=git@github.com:markhowells/elemental-logger.git     # 'origin' is https and has no credentials

git switch main && git pull
git switch -c my-change
# ... edit ...
tests/run.sh
git commit -am "Describe the change"
git push $REPO my-change
# open the PR, wait for green, merge in the browser

git switch main && git pull
git log --oneline -3                     # is HEAD the merge you expect?
git tag -l                               # pick the next number
git tag -a v0.1.3 -m "v0.1.3"
git push $REPO v0.1.3                    # THIS publishes the release
```

| What | Where |
|---|---|
| Repo | https://github.com/markhowells/elemental-logger |
| New PR | `https://github.com/markhowells/elemental-logger/compare/main...<branch>` |
| Workflow runs | https://github.com/markhowells/elemental-logger/actions |
| Releases (every bundle) | https://github.com/markhowells/elemental-logger/releases |
| Pages site | https://markhowells.github.io/elemental-logger/ |
| Update feed | https://markhowells.github.io/elemental-logger/releases/latest.json |
| Image | Docker Hub `seaspray/elemental-signalk` |

The `gh` command line tool is not installed on the devbox, so PRs, re-runs and settings are done in the browser.

### Three things to remember

1. **The release workflow runs no tests.** Tag only a commit on `main` whose `ci` run is green.
2. **Any `v*` tag publishes to the Pi's feed**, including `v0.2.0-rc1`. There is no pre-release channel.
3. **The feed holds one version.** The Pi treats any version different from its own as an update,
   older ones included.

---

## 2. Making a release

### 2.1 Before you start

- [ ] Read the open known issues in [pi-operations.md](pi-operations.md#9-known-issues).
- [ ] `git switch main && git pull`, with a clean `git status`.
- [ ] If it has been months: expect to deal with expired tokens, retired GitHub runner images or action
      versions (section 5).

### 2.2 Check locally

```bash
tests/run.sh          # needs python3 and node; no Docker, root or network
```

Optional, closer to CI (needs shellcheck installed):

```bash
shellcheck -x -S warning deploy/marine-apply deploy/marine-doctor deploy/marine-update deploy/install.sh \
    images/signalk/docker-entrypoint.sh tools/*.sh tests/run.sh setup.sh
```

If you changed the image, build it and run the end-to-end test on the **devbox only**:

```bash
set -a; . images/signalk/plugin.version; set +a
docker build -f images/signalk/Dockerfile --build-arg SIGNALK_BASE --build-arg PLUGIN_REPO \
    --build-arg PLUGIN_REF -t elemental-signalk:dev images/signalk
SIGNALK_IMAGE=elemental-signalk:dev tools/smoke-test.sh      # needs sudo, can-utils, vcan module
```

The test needs a machine with **no marine install**. It refuses to start if it finds `marine.env`, any
`pi_*` volume, a `signalk`, `influxdb` or `caddy` container, or a real `can0`, and it uses its own `smoke_*`
volumes and network. Keep those checks: versions up to v0.1.2 could delete the real data volumes.

### 2.3 Pull request, merge, tag

Use the commands in section 1. After merging, wait for the `ci` run **on main** before tagging.

Version numbers are `vMAJOR.MINOR.PATCH`. The bundle version is the tag without the `v`.
You do not edit a version file: CI writes `VERSION` into the bundle.

### 2.4 Watch the release

Actions tab, workflow `release`. Three stages: `image` (build and push), `bundle`, `deploy`.

### 2.5 Verify what was published

```bash
V=0.1.3
cd "$(mktemp -d)"
curl -s https://markhowells.github.io/elemental-logger/releases/latest.json; echo
curl -sO https://markhowells.github.io/elemental-logger/releases/marine-$V.tar.gz
sha256sum marine-$V.tar.gz                                   # must equal bundle_sha256 in the feed
tar -xzOf marine-$V.tar.gz VERSION
tar -xzOf marine-$V.tar.gz deploy/images.env | grep SIGNALK  # seaspray/elemental-signalk@sha256:...
docker buildx imagetools inspect seaspray/elemental-signalk:v$V   # lists linux/arm64 and linux/amd64
```

Pages is cached, so the feed can lag by about ten minutes.

Then update the Pi: [pi-operations.md, section 5](pi-operations.md#5-upgrading-an-existing-installation).

---

## 3. How the CI system works

### 3.1 Workflows

| File | Runs when | Purpose |
|---|---|---|
| `ci.yml` | every pull request; every push to `main` | checks, image build, smoke test (PRs only) |
| `build-image.yml` | called by `ci.yml` and `release.yml` | builds the SignalK image, optionally pushes it |
| `release.yml` | push of a tag `v*` | image, bundle, GitHub Release, Pages |
| `plugin-sync.yml` | Mondays 06:17 UTC, or by hand | reports whether the plugin fork has fallen behind upstream |
| `dependabot.yml` (config) | weekly | opens PRs that bump GitHub Actions versions only |

| Event | Lint and tests | Build | Push to Docker Hub | Smoke test | Release and Pages |
|---|---|---|---|---|---|
| Pull request | yes | amd64 + arm64 | no | yes | no |
| Push/merge to `main` | yes | amd64 + arm64 | `sha-<7 chars>` | no | no |
| Tag `v*` | **no** | amd64 + arm64 | `vX.Y.Z`, `latest`, `sha-…` | **no** | yes |

`main` has no branch protection, so GitHub will not stop you merging a red PR or pushing straight to `main`.

### 3.2 Checks (job `lint-and-test`)

**shellcheck** (`-x -S warning`: errors and warnings fail; style and info are ignored). Covers
`deploy/marine-apply`, `marine-doctor`, `marine-update`, `install.sh`, `docker-entrypoint.sh`,
`tools/*.sh`, `tests/run.sh`, `setup.sh`. The Python and JavaScript files are not linted. A new shell
script must be added to the list in `ci.yml`.

**hadolint** on `images/signalk/Dockerfile`. Ignored rules: `DL3006` (base image is tagged through a build
argument), `DL3008` (apt versions not pinned), `DL3059` (consecutive `RUN` lines).

**Unit tests** (`tests/run.sh`, 43 at v0.1.3):

| Group | What is proved |
|---|---|
| Renderer | plugin config equals the expected file `tests/fixtures/plugin-config.expected.json`; anonymous read is off by default; special characters in secrets survive; no placeholder left unresolved; secret files are not world-readable; SignalK files are readable by the container user; `--check` works without `--out`; HTTP mode and DNS wildcard by default; optional settings take effect; `CAN_INTERFACE` reaches the SignalK settings |
| Rejections | bad `CAN_INTERFACE`, `changeme`, short token, bad `TLS_MODE`, bad `DOMAIN`, negative resolution, `$` in a Compose value: each fails and writes nothing |
| Settings merge | fresh file created; managed keys corrected and others preserved; second run changes nothing |
| Updater (fake feed, no Docker) | offline is quiet; update detected; staging without applying; apply; up to date; tampered bundle refused; failed apply rolls back; failed release not retried |
| Doctor and apply | each doctor check is reported once; apply and update use the same installed-version file; volatile or missing journal fails; boots counted correctly; `fake-hwclock` recognised offline; journal setting sorts after Raspberry Pi OS's |
| Smoke-test safety (stubbed Docker) | refuses where a real install, volume or container exists, touching nothing; every pinned volume and network name is overridden |

**Compose validation:** renders with `tests/fixtures/test.env`, then `docker compose config -q` on both
`docker-compose.yml` and `portainer.yml`.

### 3.3 Image build (`build-image.yml`)

- Reads the pins in `images/signalk/plugin.version` and passes them as build arguments.
- Builds natively, no emulation: `linux/amd64` on `ubuntu-latest`, `linux/arm64` on `ubuntu-24.04-arm`.
- Layer cache: GitHub Actions cache, one scope per platform.
- When pushing: each platform is pushed by digest, then job `merge` joins them into one multi-arch
  manifest, applies the tags, and returns the manifest digest.
- When not pushing: the amd64 image is saved as a file for the smoke test. The arm64 build only proves
  that it builds.

What goes into the image: SignalK server base image, the plugin built from the pinned commit, `can-utils`,
the CAN helper scripts, `merge-settings`, and the entrypoint. **No configuration and no secrets.**

Not reproducible: the plugin has no lockfile and apt packages are not pinned. A rebuild of the same commit
can pull newer dependencies, so the released image is not byte-for-byte the one the PR tested.

### 3.4 Smoke test (job `smoke`, PRs only)

`tools/smoke-test.sh` tests the whole data path on amd64:

0. refuses to run on a machine with a marine install, and gives volumes and network `smoke_*` names;
1. creates a virtual CAN interface called `can0`;
2. renders config with throw-away credentials, using the image just built;
3. starts the stack (SignalK, InfluxDB, Caddy);
4. waits for InfluxDB and SignalK, then checks the landing page and the Caddy proxy to SignalK;
5. sends water-depth frames (PGN 128267) until a point appears in the `instruments` measurement;
6. on failure prints logs, settings, plugin config (token masked) and CAN traffic;
7. removes the stack and volumes.

**Not tested anywhere in CI:** `install.sh` on a real system, systemd units, hostapd, dnsmasq, real CAN
hardware, Portainer start-up, arm64 at run time, upgrading existing data volumes, and TLS mode on a running
Caddy.

### 3.5 Release pipeline (`release.yml`)

| Job | Permissions | Steps |
|---|---|---|
| `image` | read | calls `build-image.yml` with `push: true` |
| `bundle` | `contents: write` | rewrites `SIGNALK_IMAGE` in `deploy/images.env` to the new digest; writes `VERSION`; builds the tarball; writes the feed and index page; creates the GitHub Release; uploads the Pages artifact |
| `deploy` | `pages: write`, `id-token: write` | publishes the Pages artifact (environment `github-pages`) |

`deploy` is separate so a failed Pages publish can be re-run alone. The `image` digest is the only thing
the repo does not already contain: in git, `SIGNALK_IMAGE` stays `marine-signalk:latest`.

### 3.6 Artifacts

| Artifact | Contents | Where it lives | Lifetime |
|---|---|---|---|
| Docker image | multi-arch SignalK image | Docker Hub | until deleted |
| `marine-X.Y.Z.tar.gz` | `deploy/`, `config/`, `images/signalk/plugin.version`, `marine.env.example`, `VERSION` | GitHub Release **and** Pages | Release: permanent. Pages: **only the newest** |
| `releases/latest.json` | `version`, `bundle_url`, `bundle_sha256` | Pages | replaced by each release |
| `index.html` | download link, SHA-256, prerequisites (written inline in `release.yml`) | Pages | replaced |
| `docs/` | a copy of this directory, served as raw Markdown | Pages | replaced |
| `image-amd64` | image file for the smoke test | Actions run | GitHub default retention |
| `digests-linux-*` | per-platform digests | Actions run | GitHub default retention |
| `github-pages` | the site | Actions run | about 1 day |

The bundle does **not** contain `tools/`, `tests/` or `docs/`. A new top-level file that the Pi needs must be
added to the `tar` command in `release.yml`.

Everything in this repo, on Pages and on Docker Hub is **public**, these documents included.

---

## 4. GitHub setup (once, or if recreating the repo)

| Setting | Location | Value |
|---|---|---|
| Actions secret `DOCKERHUB_USERNAME` | Settings → Secrets and variables → Actions | Docker Hub namespace; also sets the image name |
| Actions secret `DOCKERHUB_TOKEN` | same | Docker Hub access token with read and write |
| Pages | Settings → Pages | Source: **GitHub Actions** |
| Tag rule | Settings → Environments → `github-pages` → Deployment branches and tags | add a **tag** rule `v*` (default allows only `main`) |

`GITHUB_TOKEN` is provided automatically. No GitHub secret ever reaches the Pi; the Pi downloads
everything anonymously.

**Rotating the Docker Hub token:** create a new token in Docker Hub (Account settings → Personal access
tokens), update `DOCKERHUB_TOKEN`, re-run the latest `ci` run on `main` to prove it works, then delete the
old token.

**Changing the Docker Hub namespace:** update both secrets and release again. The bundle picks up the new
name. Keep the old repository until the Pi has moved to the new release.

---

## 5. When things fail

**Re-run buttons** (open the run, top right):
- *Re-run failed jobs* repeats only what failed, using the same commit.
- *Re-run all jobs* repeats everything. For a release this builds a **new image and bundle** under the same
  version, and replaces the Release asset and feed.

A re-run uses the workflow files **of that commit or tag**. A fix to a workflow needs a new commit (and, for
a release, a new tag).

### 5.1 CI failures

| Symptom | Likely cause | Action |
|---|---|---|
| shellcheck fails | new warning | Fix it. Do not lower the severity: one such warning once hid a real doctor bug |
| hadolint fails | Dockerfile rule | fix, or add the rule to `ignore` with a reason |
| `plugin config equals golden` fails | template or defaults changed | if intended, update `tests/fixtures/plugin-config.expected.json` |
| Compose validation fails | new `${VAR}` not provided | add it to `compose_env` in `deploy/lib/render.py` |
| Build fails at `npm install` | plugin ref missing, GitHub/npm outage, or a dependency moved | check `PLUGIN_REF`; re-run; if a dependency broke, fix in the fork and bump the ref |
| Build fails pulling the base image | Docker Hub rate limit or removed tag | re-run later; check `SIGNALK_BASE` |
| arm64 job stays queued or says runner unknown | `ubuntu-24.04-arm` label retired | update the label in `build-image.yml` |
| `docker/login-action` fails | token expired or secrets missing | section 4. Dependabot and fork PRs get no secrets, but they do not push |
| Smoke test: no point in InfluxDB | image, plugin or config regression | read the diagnostics in the log; reproduce on the devbox |
| Passes on PR, fails on `main` | the push step only runs on `main` | usually Docker Hub credentials |

### 5.2 Release failures

| Symptom | Action |
|---|---|
| `image` fails | Nothing was published to the feed. Fix, then *Re-run all jobs* (transient) or fix on `main` and tag the next number |
| `bundle` fails | Image tags exist but the feed is unchanged. Same as above |
| `deploy` fails with a 502 or similar server error | **First check the feed**: it has published despite the error before. If not, *Re-run failed jobs* |
| `deploy` rejected: tag not allowed to deploy | add the `v*` tag rule (section 4), then re-run |
| `deploy`: no artifacts named `github-pages` | the Pages artifact expired (about a day). *Re-run all jobs* |
| Feed still shows the old version | wait ten minutes; check the `deploy` job actually ran |
| Release created but wrong | publish a fixed, higher version (below) |

### 5.3 Withdrawing a bad release

**Preferred: roll forward.** Revert or fix on `main`, then tag the next number.

```bash
git switch -c revert-bad main
git revert -m 1 <merge-commit>      # or fix it by hand
```

Then the normal PR, merge and tag steps.

While that is in progress, stop the Pi taking the bad version (on the Pi):
`sudo mkdir -p /var/lib/marine/failed && sudo touch /var/lib/marine/failed/<version>`.

**Reusing a tag** is only for a release that no Pi has downloaded:

```bash
git push $REPO :refs/tags/v0.1.3
git tag -d v0.1.3
```

Also delete the GitHub Release in the browser. A Pi that already installed that number will not see the
replacement.

**Do not re-run an old release run** to "go back": it moves `latest` and the feed to the old version.

---

## 6. Changing things

| To change | Edit | Also |
|---|---|---|
| Plugin code | commit in the fork `markhowells/signalk-to-influxdb2` (branch `tag-consolidated`), push, put the **full commit SHA** in `PLUGIN_REF` | PR so the smoke test runs |
| SignalK version | `SIGNALK_BASE` (tag **and** digest) in `images/signalk/plugin.version` | read its release notes |
| InfluxDB, Caddy, Portainer | `deploy/images.env` (tag and digest) | back up before an InfluxDB change; Portainer needs a manual apply on the Pi |
| A config template | `config/` | update tests and the expected plugin config |
| A new setting | `render.py` (`DEFAULTS` or `REQUIRED`, plus `typed_values` / `compose_env` as needed), `marine.env.example` | document it in `pi-operations.md`. A new **required** value makes the Pi's update fail and roll back until `marine.env` has it |
| Host packages or unit enablement | `deploy/install.sh` | `marine-update` does **not** run it; run it on the Pi after updating |
| Pages front page | the `cat > site/index.html` block in `release.yml` | |

Find a digest with `docker buildx imagetools inspect <image>:<tag>` (the top `Digest:` line, which is the
multi-arch one).

### Dependabot PRs

They bump GitHub Actions only. Image pins are never bumped automatically.
CI on a PR does not exercise `release.yml`, so a green bump of `deploy-pages`, `upload-pages-artifact` or
`action-gh-release` is only proved by the next release. Merge major bumps one at a time, then release.

### Plugin sync

`plugin-sync.yml` merges upstream `tkurki/signalk-to-influxdb2` `main` into the pinned commit and opens or
comments on an issue labelled `plugin-sync` if it conflicts or fails to build. It never pushes.

- When written, the fork was 29 commits behind with a conflict in `src/influx.ts`.
- The fork has no lockfile, so the workflow's `npm ci` step is expected to report a failed build even
  after a clean merge. It does not run the plugin's tests.
- GitHub disables scheduled workflows in a public repo after about 60 days without activity. Re-enable it
  in the Actions tab.
