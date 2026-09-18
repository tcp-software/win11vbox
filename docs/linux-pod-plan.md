# TimeClock Plus WebEdition on Linux — Migration Plan (VM → Pods)

**Status:** DRAFT for review · **Owner:** _tbd_ · **Last updated:** 2026-09-18

Move the TimeClock Plus **WebEdition** development/host environment off the Windows 11 VirtualBox VM
(`win11vbox` / `build-vm.sh`) and onto **Linux containers/pods** — building the whole stack from
source in a fresh Linux builder image, and hosting the databases and servers as a pod that a
`tcp-tl-70` clock (or a linclock) can connect to.

> This plan is grounded in a code audit of `tcp-we-70` (servers + DB) and `tcp-tl-70` (the clock).
> The headline finding: **the DB and the .NET 10 AppServerApi are Linux-native today; the other
> three servers are .NET Framework 4.7.2 (WCF/`System.Web`) and require a real port.**

---

## 1. Goals & non-goals

**Goals**
- **G1** — The WebEdition **databases** (`Tcp70ProdTest` and the others) are **built from source** —
  SSDT schema project → create DB → deploy scripts → generated test data — and run in a Linux SQL
  Server container/pod. We deliberately do **not** restore the pre-built `.bak`/`.bacpac` snapshots
  the repo ships (they are cached build outputs; keeping them only as an optional dev-only fast path).
- **G2** — The WebEdition **servers** run in the same pod, reachable on their ports
  (8008/8010/8012/8014), with a clock/linclock able to connect to `TerminalHubApi` (8010).
- **G3** — Everything **builds from source in a fresh Linux container** — no Windows, no VM — with
  all packages installed as needed.
- **G4** — Reproducible + publishable: a standardized **`webeditionbuilder`** image (in
  `docker-builder`, per the org pattern) and runtime pod definitions (in `tcp-we-70/docker/`).

**Non-goals**
- Retiring `win11vbox` — the VM stays for anything that can't move off Windows (and as a fallback).
- Porting hardware/telephony device drivers beyond what a dev/linclock scenario needs.
- Production hardening (HA, secrets management, TLS certs) beyond a dev/QA pod — noted as follow-up.

---

## 2. Current state → target state

```mermaid
flowchart TD
    classDef vm   fill:#eceff1,stroke:#455a64,color:#263238;
    classDef data fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c;
    classDef ok   fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20;
    classDef port fill:#ffebee,stroke:#c62828,color:#b71c1c;
    classDef ext  fill:#e3f2fd,stroke:#1565c0,color:#0d47a1;

    subgraph NOW["TODAY — Windows 11 VM (win11vbox)"]
        direction TB
        VM["Windows 11 guest<br/>built by build-vm.sh"]:::vm
        VSQL["SQL Server 2022<br/>Tcp70ProdTest"]:::data
        VS["4 servers 8008/8010/8012/8014<br/>(all on Windows)"]:::vm
        VM --> VSQL
        VM --> VS
    end

    subgraph TGT["TARGET — Linux pod"]
        direction TB
        DB["mssql :1433<br/>Tcp70ProdTest + others"]:::data
        APP["AppServerApi :8008<br/>.NET 10 / Kestrel — runs as-is"]:::ok
        HUB["TerminalHubApi :8010<br/>needs port (.NET Fx → .NET)"]:::port
        ADM["AdmServerApi :8012 — needs port"]:::port
        WS["WorkstationHubApi :8014 — needs port"]:::port
        APP --> DB
        HUB --> APP
        ADM --> APP
        WS --> APP
        HUB --> DB
    end

    NOW ==>|migrate| TGT
    CLK["🕐 tcp-tl-70 / linclock<br/>serverUrl → :8010"]:::ext
    CLK --> HUB
```

---

## 3. Feasibility verdict (from the code audit)

| Component | Port | Today | Linux verdict |
|---|---|---|---|
| **Databases** (`Tcp70ProdTest`, `Tcp70Report`, `Tcp60*`, base `TimeClockPlus70Core`) | 1433 | SQL Server 2022 | ✅ **Native + buildable from source.** SSDT project is SDK-style **`Microsoft.Build.Sql`** (builds on Linux via `dotnet build` — `docker/sql.Dockerfile` already does it); the `ProdTestResourceGenerator` data generator is **`net10.0`** (runs on Linux). Build schema → create DB → deploy → generate (the `stage-dbs` path). No `xp_cmdshell`/FILESTREAM/CLR. (Pre-built LFS `.bak`/`.bacpac` exist but we don't use them.) |
| **AppServerApi** | 8008 | **.NET 10 / Kestrel** | ✅ **Runs as-is** — already has Linux Dockerfiles (`docker/app.Dockerfile`, `AppServerApi/Dockerfile`) |
| **AdmServerApi** | 8012 | .NET Fx 4.7.2 + WCF self-host + Asterisk.NET | ⚠️ **Port required** |
| **TerminalHubApi** | 8010 | .NET Fx 4.7.2 + WCF + native SQLite + device drivers | ⚠️ **Port required** (the clock's endpoint — highest priority) |
| **WorkstationHubApi** | 8014 | .NET Fx 4.7.2 + WCF + native `SQLite.Interop.dll` | ⚠️ **Port required** |
| **Client** (`tcp-core-client`, npm/grunt) | — | Node | ✅ Cross-platform |

**Blockers, precisely:**
- DB: only in *tooling wrappers* — `sqlcmd -E` (Windows/trusted auth) → SQL login; `SqlPackage.exe` →
  the cross-platform `sqlpackage` dotnet tool; a `.bat` + a PowerShell post-step → shell/`pwsh`.
- Legacy servers: **WCF `HttpSelfHostServer`** (in `Common/WebApi`) → replace with Kestrel (the unused
  `Common/WebApiCore` netcoreapp3.1 project is the intended replacement); `System.Web` controllers;
  native `SQLite.Interop.dll` → `Microsoft.Data.Sqlite`; `Asterisk.NET` telephony; a few hardcoded
  `C:\` paths in the net472 libs.
- Full **NAnt/`MSBuild.exe`/Cygwin** build is Windows-only — but **not needed** to build the DB +
  AppServerApi + client on Linux (the existing Dockerfiles prove `dotnet` + `npm` suffice).

---

## 4. Architecture & where each piece lives (Option B)

```mermaid
flowchart TD
    classDef build fill:#fff3e0,stroke:#e65100,color:#bf360c;
    classDef repo  fill:#e0f7fa,stroke:#00838f,color:#006064;
    classDef ok    fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20;
    classDef data  fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c;

    DB1["<b>docker-builder</b> repo<br/>Dockerfile.webedition +<br/>build/publish scripts + workflow"]:::repo
    IMG["Publishes <b>webeditionbuilder</b> image → ghcr<br/>dotnet 10 SDK · Node · git-lfs ·<br/>go-sqlcmd · sqlpackage"]:::build
    DB1 --> IMG

    TW["<b>tcp-we-70/docker</b> repo<br/>docker-compose.yml (+ k8s manifests) ·<br/>app.Dockerfile · DB build/create scripts ·<br/>cfg-docker/TCPCONN.XML (SQL auth)"]:::repo
    IMG -->|build + DB-create run inside it| TW

    MSSQL["runtime: <b>mssql :1433</b><br/>databases built from source"]:::data
    APPC["runtime: <b>AppServerApi :8008</b><br/>(+ ported hubs later)"]:::ok
    TW --> MSSQL
    TW --> APPC
```

- **`docker-builder`** → the **`webeditionbuilder`** toolchain image (new `Dockerfile.webedition`,
  `build-docker-image.sh --build-for-webedition`, `publish-to-ghcr.sh`, a `publish-*.yml` workflow —
  exactly mirroring `clockwarebuilder`/`vmbuilder`/`yoctobuilder`).
- **`tcp-we-70/docker/`** → the **runtime pod**: the `mssql` service (currently absent from the
  compose), the app image (`app.Dockerfile`, base bumped 8.0 → 10.0), the DB build/create scripts, and the
  `cfg` (already SQL-auth). Later, the ported hub images.
- **`win11vbox`** (this repo) → **not** a home for the runtime; it stays the VM builder. This plan
  doc lives here only because the initiative grew out of replacing the VM.

---

## 5. Phased roadmap

```mermaid
flowchart TD
    classDef now  fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20;
    classDef lift fill:#ffebee,stroke:#c62828,color:#b71c1c;
    classDef base fill:#fff3e0,stroke:#e65100,color:#bf360c;

    P0["<b>Phase 0</b> — Groundwork<br/>webeditionbuilder image · Git LFS · compose skeleton"]:::base
    P1["<b>Phase 1</b> — Database pod<br/>mssql + build Tcp70ProdTest from source — ✅ now"]:::now
    P2["<b>Phase 2</b> — AppServerApi pod<br/>.NET 10 / Kestrel — ✅ feasible now"]:::now
    P3["<b>Phase 3</b> — Port legacy servers (dev lift)<br/>TerminalHub → Adm → Workstation"]:::lift
    P4["<b>Phase 4</b> — Pod assembly + clock connectivity<br/>compose → k8s · serverUrl → :8010"]:::now
    P5["<b>Phase 5</b> — CI/CD, publish, docs, cutover"]:::base

    P0 --> P1 --> P2 --> P3 --> P4 --> P5
```

Green = achievable with existing pieces; red = genuine development (the .NET Framework → .NET port).

### Phase 0 — Groundwork
- **Goal:** a standardized Linux build environment and the skeleton to hang everything on.
- **Steps:**
  1. In `docker-builder`: add `Dockerfile.webedition` (base Ubuntu/Debian + **dotnet SDK 10**, **Node
     LTS**, **git + git-lfs**, **go-sqlcmd**/`mssql-tools18`, the **`sqlpackage`** dotnet tool, `pwsh`).
  2. Wire `build-docker-image.sh --build-for-webedition`, `publish-to-ghcr.sh`, and a
     `.github/workflows/publish-webeditionbuilder-ghcr.yml` (mirror the existing three).
  3. Ensure `git lfs` is present for any LFS **build inputs** the build genuinely needs (e.g.
     third-party libs). We do **not** depend on the pre-built `.bak`/`.bacpac` LFS artifacts — Phase 1
     builds the DB from source.
- **Acceptance:** `webeditionbuilder` builds, is on ghcr, and inside it `dotnet --version`, `node -v`,
  `git lfs version`, `sqlcmd`/`go-sqlcmd`, and `sqlpackage` all work.

### Phase 1 — Database pod (built from source) ✅
- **Goal:** the databases **built from source** (schema → create → deploy → generated data) and running
  in Linux SQL Server. **No pre-built `.bak`/`.bacpac` restored.** This is the NAnt `stage-dbs` path,
  ported to Linux.
- **Steps:**
  1. Add an `mcr.microsoft.com/mssql/server:2022-latest` service to `tcp-we-70/docker/docker-compose.yml`
     (accept EULA, set `MSSQL_SA_PASSWORD`, a data volume).
  2. **Build the schema from source** — `dotnet build` the SDK-style `Microsoft.Build.Sql` project
     `TimeClockPlus70Core_StandAlone.sqlproj` → `TimeClockPlus70Core.sql` (`docker/sql.Dockerfile`
     already does this on Linux).
  3. **Create the databases** from that generated schema SQL (`Tcp70ProdTest`, `Tcp70Report`, the
     `Core*` set) — port `__create-db-*` / `create-db-prod.bat` to a shell script driving `go-sqlcmd`.
  4. **Apply deploy/migration scripts** — `Execute_Current_Deploy_Scripts.ps1` under `pwsh` on Linux.
  5. **Generate test data** — run `dotnet Tcp.ProdTestResourceGenerator.dll` (it's `net10.0`) against
     the new DB.
  6. Create the SQL logins (`tcadmin`, `Q3WShUtj8K`); wrapper swaps throughout — `sqlcmd -E` (Windows
     auth) → `go-sqlcmd -U tcadmin -P …`; `.bat`/PowerShell → shell/`pwsh`.
  7. _(Optional)_ `BACKUP DATABASE … .TCB70` to (re)produce the shipped artifact **ourselves** —
     proving the from-source build is authoritative (and refreshing the cached snapshot if we keep one).

```mermaid
flowchart TD
    classDef step fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20;
    classDef data fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c;
    classDef opt  fill:#fff3e0,stroke:#e65100,color:#bf360c;

    B["start mcr.microsoft.com/mssql/server:2022"]:::data
    S1["dotnet build TimeClockPlus70Core.sqlproj<br/>(Microsoft.Build.Sql) → TimeClockPlus70Core.sql"]:::step
    S2["create DBs from schema SQL<br/>Tcp70ProdTest · Tcp70Report · Core*"]:::step
    S3["apply deploy/migration scripts<br/>(Execute_Current_Deploy_Scripts → pwsh)"]:::step
    S4["generate test data<br/>dotnet Tcp.ProdTestResourceGenerator.dll (net10)"]:::step
    S5["create SQL logins<br/>tcadmin · Q3WShUtj8K"]:::step
    F["✅ DB built from source, ready on :1433 (SQL auth)"]:::data
    OPT["(optional) BACKUP DATABASE → .TCB70<br/>reproduce the shipped artifact ourselves"]:::opt

    B --> S1 --> S2 --> S3 --> S4 --> S5 --> F
    F -.-> OPT
```

- **Acceptance:** the DB exists **with no `.bak` restored** — from another container `go-sqlcmd -S
  mssql,1433 -U tcadmin -P … -Q "SELECT name FROM sys.databases"` lists `Tcp70ProdTest`, and a known
  query (e.g. the PIN-only employee check) returns generated rows.

### Phase 2 — AppServerApi pod ✅
- **Goal:** the .NET 10 app server running on Linux, talking to the DB pod.
- **Steps:** use `docker/app.Dockerfile` (Node client build + `dotnet publish`); **bump base images
  8.0 → 10.0** to match `net10.0`; mount `cfg` with `TCPCONN.XML` → `ServerName=mssql`, `Port=1433`,
  `Integrated=false` (already SQL-auth); expose 8008.
- **Acceptance:** `AppServerApi` container is healthy; a request to `:8008/api/v0000/...` succeeds and
  round-trips to the DB.

### Phase 3 — Port the legacy servers ⚠️ (the development lift)
- **Goal:** `TerminalHubApi`, `AdmServerApi`, `WorkstationHubApi` build + run on Linux.
- **Steps (per server; TerminalHubApi first — it's the clock's endpoint):**
  1. Retarget csproj `v4.7.2` → `net8/10`; convert to SDK-style + PackageReference.
  2. Replace **WCF `HttpSelfHostServer`** (`Common/WebApi`) with **Kestrel/ASP.NET Core** — build on
     the existing `Common/WebApiCore` (netcoreapp3.1) scaffold; migrate the `System.Web`-based
     controllers.
  3. Server-specifics: **TerminalHubApi** — port the net472 `TerminalHub` lib, drop
     `System.ServiceModel`/`System.Data.Linq`, resolve/stub the device-driver + `C:\` paths;
     **WorkstationHubApi** — native `SQLite.Interop.dll` → `Microsoft.Data.Sqlite`; **AdmServerApi** —
     `Asterisk.NET`/telephony.
  4. Add each to the compose/pod once green.
- **Acceptance:** each server starts under Kestrel on Linux; **a linclock/clock with `serverUrl =
  https://<pod>:8010` auto-registers and can clock in** (the end-to-end proof for TerminalHubApi).

### Phase 4 — Pod assembly + clock connectivity
- **Goal:** a single deployable pod, reachable by devices.
- **Steps:** finalize `docker-compose.yml` (dev) → **k8s manifests** (mssql + app + hubs, services,
  volumes); expose the ports; document pointing `tcp-tl-70`/linclock `serverUrl` at the pod (bridged
  reachability, TLS: `shouldSkipSslValidation` or a pinned self-signed CA for dev).
- **Acceptance:** `kubectl apply` (or `docker compose up`) brings the whole stack up; a device connects
  through `:8010` end to end.

### Phase 5 — CI/CD, publish, docs, cutover
- **Goal:** repeatable, documented, and the VM demoted to fallback.
- **Steps:** GitHub Actions to build/publish `webeditionbuilder` and the runtime images; a smoke test
  (mirroring `smoke-publish.sh`) for the pod; docs in `tcp-we-70`; update `win11vbox` README to point
  at the pod as the primary path where applicable.
- **Acceptance:** a clean checkout → one command → running pod, in CI.

---

## 6. Risks & open questions

- **R1 (largest):** the .NET Framework → .NET port of three servers (Phase 3) is real, unbounded-until-
  scoped development. WCF self-host has no drop-in Kestrel equivalent; each `System.Web` controller
  needs review. **Mitigation:** `WebApiCore` scaffold exists; do TerminalHubApi first and time-box a
  spike to size the rest.
- **R2:** device-driver / telephony deps (fingerprint readers, Asterisk) are inherently hardware/OS
  bound — may be stubbed for a dev/linclock pod but block a full production terminal server on Linux.
- **R3:** SQL Server on Linux feature gaps (no FILESTREAM, some Agent/Windows-auth features) — audited
  as **not used** by the core build, but re-verify against `DBATools`/report DBs if those are needed.
- **R4:** licensing — SQL Server Developer/Express in a container for dev is fine; confirm terms for
  any shared/CI use.
- **Q1:** do we need **all** databases (report, migration, Tcp60*) or just `Tcp70ProdTest` for the first
  cut? **Q2:** target orchestrator — plain `docker compose` first, then k8s, or straight to k8s?
  **Q3:** is a linclock-against-the-pod (no physical device) an acceptable Phase-3 acceptance proof?

---

## 7. Definition of done

- **Milestone A (quick win):** Phases 0–2 — a Linux pod hosting the **databases + AppServerApi**,
  built by `webeditionbuilder`, reproducible from a clean checkout. _No physical clock yet._
- **Milestone B (clock-capable):** Phase 3 for **TerminalHubApi** — a linclock/clock registers and
  clocks in against the pod on `:8010`.
- **Milestone C (full parity):** Phases 3–5 — all four servers on Linux, pod deployable to k8s,
  CI-published, VM demoted to fallback.

**Recommended first step after approval:** Phase 0 + Phase 1 (the database pod) — lowest risk, highest
immediate value, and it unblocks everything else.
