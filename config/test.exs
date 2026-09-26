import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :apiary, Apiary.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "apiary_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # The read budgets ask the database for a few hundred MiB in one statement, which a
  # CI machine answers in more than the 15 s default. ExUnit's own limit still holds.
  timeout: 120_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :apiary, ApiaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "giGpqWKm7Gc+jLkx/fMtGY31GLJixgd7irXSVlxl2zqhd7NGxckjtkYdU3pBR8I/",
  server: false

# A second domain beside the software one, so the tests see a workspace's domain read
# from its row (`Apiary.Lingo.Domain`). Defined in test/support; no instance has it.
config :apiary, Apiary.Lingo.Domain, test_domains: %{"example" => Apiary.Lingo.Domain.Example}

# In test we don't send emails
config :apiary, Apiary.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The encryption key for secrets at rest in test. Not a secret: local databases only.
config :apiary, Apiary.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("dGVzdDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA=")}
  ]

# Projections run in the caller's process, inside its sandbox connection, and the
# lost-run check runs only when a test calls it.
config :apiary, Apiary.Runs.Projector, async: false
config :apiary, Apiary.Runs.Liveness, enabled: false
config :apiary, Apiary.Retention.Scheduler, enabled: false
