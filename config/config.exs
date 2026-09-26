# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :apiary, :scopes,
  user: [
    default: true,
    module: Apiary.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Apiary.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :apiary,
  ecto_repos: [Apiary.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :apiary, ApiaryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ApiaryWeb.ErrorHTML, json: ApiaryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Apiary.PubSub,
  live_view: [signing_salt: "vOrlLKDK"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# The surface speaks a domain's words, never the engine's (docs/lingo.md). Each Gettext
# locale is a domain's catalogue in GNU's `language@domain` form. The default is the
# software domain's, so a render outside a request, a mail or an error page, reads it too.
config :gettext, default_locale: "en@software", plural_forms: ApiaryWeb.Gettext.Plural
config :apiary, ApiaryWeb.Gettext, default_locale: "en@software"

# Dates, times and numbers are formatted from the Unicode CLDR (ApiaryWeb.Cldr,
# ApiaryWeb.Format). Times are stored in UTC and shifted into the reader's zone with the
# tz database compiled into the `tz` package, which also checks a person's time zone:
# nothing is downloaded at runtime.
config :ex_cldr, default_backend: ApiaryWeb.Cldr, json_library: Jason
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :apiary, Apiary.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  apiary: [
    args:
      ~w(js/app.js js/terminal.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  apiary: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger. The organisation, workspace and person ids are put into the
# metadata where a request, a LiveView, a contract call or a job begins
# (`Apiary.LogMetadata`), so a log search by any of them finds everything that happened for
# it. Ids only, never a name or an email address.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :organisation_id, :workspace_id, :user_id]

# Parameters the Phoenix logger masks in development request logs. Production logs
# never include parameters at all.
config :phoenix, :filter_parameters, ["password", "secret"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The events endpoint: batches per second and at once, per access key.
config :apiary, Apiary.Runs.RateLimit, rate: 50, burst: 100

# Background work as durable jobs on Postgres; every job is an `Apiary.Job`.
# One queue to start with, `default`, five at a time: a running job holds a connection of
# the repo's pool (POOL_SIZE, 10 by default) while it queries, and the requests keep the
# rest. A kind of work that needs a limit of its own gets a queue of its own when it is
# built. Finished, cancelled and discarded jobs are kept for a week, so a failure can be
# read after a weekend, then pruned. A job still executing after 30 minutes is taken to be
# orphaned by a node that stopped, and made available again (or discarded when it has no
# attempts left). The lifeline goes by time alone and would start a second run of a job
# that is only slow, so every job is stopped before that: after 25 minutes, or the shorter
# `timeout:` its module gives `use Apiary.Job`. A job whose timeout is not shorter than
# `rescue_after` does not compile. Work that needs longer is split.
# Every job is written to be run twice safely all the same. Scheduling among several nodes
# is by the peer in `oban_peers`, one leader.
config :apiary, Oban,
  engine: Oban.Engines.Basic,
  repo: Apiary.Repo,
  queues: [default: 5],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {30, :minutes}]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
