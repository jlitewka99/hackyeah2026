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

## Organizer account

Public registration is disabled. Bootstrap the sole organizer after running the
migrations. Provide credentials through environment variables or your secret
manager; never put them in source files. For an interactive zsh session:

```sh
read 'AI_CONTROL_ORGANIZER_EMAIL?Organizer email: '
read -s 'AI_CONTROL_ORGANIZER_PASSWORD?Organizer password: '
export AI_CONTROL_ORGANIZER_EMAIL AI_CONTROL_ORGANIZER_PASSWORD
mix ai_control.bootstrap_organizer
unset AI_CONTROL_ORGANIZER_EMAIL AI_CONTROL_ORGANIZER_PASSWORD
```

Use a valid email address and a password of at least 12 characters and at most
72 bytes (Bcrypt's limit). The task creates a confirmed account in a transaction.
Repeating it for the same normalized email preserves the account, password, and
sessions. A different organizer email, an ordinary account with that email, or
invalid configuration produces an error without creating an account. A database
constraint also enforces the single-organizer rule.

Sign in at `/users/log-in`. The organizer lands at `/platform/organizations`;
`/users/settings` contains separate email and password forms. Organization
management and invitations are implemented in the next step. Account changes
require recent authentication. Changing a password revokes existing sessions;
the submitting browser receives a fresh session. Remember-me cookies last 14
days, use HttpOnly and SameSite=Lax, and require HTTPS in production.

### Recovering access

Choose **Forgot password?** or open `/users/recover`. An existing account receives
a single-use email link valid for 15 minutes. The response is identical for known
and unknown emails. Consuming the link signs you in to account settings, where
you can set a new password. Email changes require confirmation at the new address.

Development uses Swoosh's local delivery adapter. The `/dev/mailbox` preview is
restricted to an authenticated organizer. Configure `AiControl.Mailer` with a
production delivery adapter and set a real sender in `AiControl.Accounts.UserNotifier`
before relying on email recovery
outside development; the generated local adapter does not send external mail.

Hammer with ETS applies shared limits to password sign-in and recovery requests:
5 attempts per normalized email and 20 per actual peer IP, in a 15-minute window
starting with the first attempt. Token submissions share the IP limit. Rejected
email attempts also count against the IP limit. Exceeding a limit returns HTTP
429 with `Retry-After` in seconds. Forwarded IP headers are not trusted. Counters
are atomic, cleaned periodically, local to one application instance, and reset
on restart. Email counter keys contain hashes rather than raw addresses.

Password and token parameters are filtered from logs; request logging is disabled
for secret-bearing token routes. Theme selection defaults to the system setting
and remembers an explicit choice of system, light, or dark appearance.

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
