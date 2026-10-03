# AiControl

Phoenix 1.8 application. Run all commands from the repository root.

## Setup

Install the versions of Elixir, Erlang/OTP, and Node.js pinned in `.tool-versions`:

```sh
asdf install
```

Start PostgreSQL 17 on `localhost:5432` with a `postgres` role, password
`postgres`, and permission to create databases. Development and tests use
separate databases: `ai_control_dev` and `ai_control_test`.

To use a different PostgreSQL port, set `PGPORT` when running Mix commands:

```sh
export PGPORT=55432
```

Install dependencies, create and migrate the development database, and build assets:

```sh
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000). The server can also run inside IEx
with `iex -S mix phx.server`.

## Tests and quality checks

```sh
mix test          # Create/migrate the test database and run ExUnit
mix format        # Format Elixir with Quokka and templates with the HEEx formatter
mix check         # Check formatting, compilation warnings, lockfile, Credo, and tests
mix precommit     # Format first, then run mix check
mix dialyzer      # Analyze types; the first run builds PLTs and takes longer
mix security      # Scan Phoenix with Sobelow and audit dependencies with MixAudit
mix check.all     # Run mix check, Dialyzer, and security checks
```

`check`, `precommit`, `dialyzer`, `security`, and `check.all` select `MIX_ENV=test`
automatically. Tests require PostgreSQL; standalone formatting, Credo, Dialyzer,
and security scans do not. `mix security` needs network access to fetch the
current vulnerability database. Credo runs in strict mode. Sobelow fails for
findings with medium or high confidence. Dialyzer stores its ignored PLTs in
`priv/plts/`; generated files and tools are excluded from Git and the tools are
not runtime dependencies of production releases.

Quokka's configuration reordering is disabled to preserve configuration order
and the placement of comments in Phoenix config files.

Build frontend assets separately with:

```sh
mix assets.setup
mix assets.build
```

## Continuous integration

GitHub Actions runs on pull requests, pushes to `main`, and manual dispatches.
The four checks are Quality, Tests, Dialyzer, and Security. CI uses Ubuntu 24.04,
reads the pinned BEAM versions from `.tool-versions`, starts PostgreSQL 17 for
tests, and builds frontend assets. The Tests job also installs the pinned Node.js
version. Dependencies, compiled files, and PLTs are cached per platform and tool
version; a run without a cache builds them from scratch. Actions are pinned to
commit SHAs.

Dependabot checks Mix dependencies and GitHub Actions every Monday at 09:00
Europe/Warsaw. Minor and patch updates are grouped separately for each ecosystem;
major updates remain separate. Each ecosystem has a limit of five open update
pull requests.

## Phoenix documentation

- [Phoenix guides](https://phoenix.hexdocs.pm/overview.html)
- [Phoenix deployment guides](https://phoenix.hexdocs.pm/deployment.html)
