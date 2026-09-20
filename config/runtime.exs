import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/apiary start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :apiary, ApiaryWeb.Endpoint, server: true
end

# PUBLIC_URL is the address people and runners use to reach this instance, for
# example https://apiary.example.com or http://10.0.0.5:4100. The endpoint derives
# its `url` from it so `ApiaryWeb.Endpoint.url/0` returns exactly that address in
# links, emails and the discovery document. Returns a keyword list for `url:` and the
# host, or raises with the reason.
parse_public_url = fn value ->
  uri = URI.parse(value)

  cond do
    uri.scheme not in ["http", "https"] ->
      raise """
      environment variable PUBLIC_URL must start with http:// or https://.
      For example: https://apiary.example.com
      """

    uri.host in [nil, ""] ->
      raise """
      environment variable PUBLIC_URL has no host.
      For example: https://apiary.example.com
      """

    true ->
      path =
        if uri.path in [nil, "", "/"], do: [], else: [path: String.trim_trailing(uri.path, "/")]

      [scheme: uri.scheme, host: uri.host, port: uri.port] ++ path
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :apiary, ApiaryWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/apiary_web/router\.ex$"E,
        ~r"lib/apiary_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]

  # The host links are generated for. A local reverse proxy may serve the dev server
  # under another name: set PHX_HOST (or a full PUBLIC_URL) in mise.local.toml or the
  # shell, so that name stays out of tracked files.
  dev_url =
    case System.get_env("PUBLIC_URL") do
      nil -> [host: System.get_env("PHX_HOST") || "localhost"]
      public_url -> parse_public_url.(public_url)
    end

  config :apiary, ApiaryWeb.Endpoint, url: dev_url
end

if config_env() == :prod do
  # ## Database

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :apiary, Apiary.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # Pending migrations run at boot, before the endpoint serves (an upgrade is a
  # restart). MIGRATE_ON_BOOT=false leaves them to `bin/migrate`.
  config :apiary, migrate_on_boot: System.get_env("MIGRATE_ON_BOOT", "true") not in ~w(false 0 no)

  # ## Secrets

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # CLOAK_KEY encrypts secrets at rest (access key secrets). Changing it makes every
  # stored secret unreadable, so keep it with the database backups.
  cloak_key =
    case System.get_env("CLOAK_KEY") do
      nil ->
        raise """
        environment variable CLOAK_KEY is missing.
        It is 32 random bytes in base64. Generate one with: openssl rand -base64 32
        """

      value ->
        case Base.decode64(value) do
          {:ok, key} when byte_size(key) == 32 ->
            key

          _ ->
            raise """
            environment variable CLOAK_KEY is not 32 bytes in base64 (44 characters).
            Generate one with: openssl rand -base64 32
            """
        end
    end

  config :apiary, Apiary.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: cloak_key}
    ]

  # ## Public address and HTTP

  public_url =
    System.get_env("PUBLIC_URL") ||
      (System.get_env("PHX_HOST") && "https://#{System.get_env("PHX_HOST")}") ||
      raise """
      environment variable PUBLIC_URL is missing.
      It is the address of this instance, for example: https://apiary.example.com
      """

  url = parse_public_url.(public_url)
  public_host = Keyword.fetch!(url, :host)

  config :apiary, :public_url_scheme, Keyword.fetch!(url, :scheme)

  config :apiary, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :apiary, ApiaryWeb.Endpoint,
    url: url,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4100")
    ],
    secret_key_base: secret_key_base

  # TLS is expected to be terminated by a reverse proxy in front of PORT. To serve TLS
  # from the release itself, add an `https:` key here; see `Plug.SSL.configure/1`.

  # ## Mail

  # Every email is sent from MAIL_FROM; `Apiary.Mailer.from/0` reads it.
  config :apiary, :mail_from, System.get_env("MAIL_FROM") || "apiary@#{public_host}"

  case System.get_env("SMTP_RELAY") do
    nil ->
      # No relay configured: emails (magic links, invitations) are written to the log
      # in full at level info, so a single-machine trial still works.
      config :apiary, Apiary.Mailer,
        adapter: Swoosh.Adapters.Logger,
        level: :info,
        log_full_email: true

    relay ->
      smtp_port = String.to_integer(System.get_env("SMTP_PORT") || "587")

      smtp_tls =
        case System.get_env("SMTP_TLS") || "always" do
          "always" -> :always
          "if_available" -> :if_available
          "never" -> :never
          _ -> raise "environment variable SMTP_TLS must be always, if_available or never"
        end

      smtp_username = System.get_env("SMTP_USERNAME")

      # Port 465 means implicit TLS on connect; every other port uses STARTTLS as
      # SMTP_TLS says.
      implicit_tls = smtp_port == 465

      config :apiary, Apiary.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: relay,
        port: smtp_port,
        username: smtp_username,
        password: System.get_env("SMTP_PASSWORD"),
        auth: if(smtp_username, do: :always, else: :never),
        ssl: implicit_tls,
        tls: if(implicit_tls, do: :never, else: smtp_tls),
        retries: 2
  end

  # ## Logs

  # One JSON object per line on stdout, for any log shipper. Metadata is an explicit
  # list so nothing unexpected (and never a header or a body) reaches the log.
  config :apiary, json_logs: true

  config :logger, :default_handler,
    formatter:
      LoggerJSON.Formatters.Basic.new(
        metadata: [
          :request_id,
          :duration_us,
          :application,
          :domain,
          :mfa,
          :module,
          :function,
          :file,
          :line,
          :pid,
          :crash_reason,
          :initial_call,
          :registered_name
        ]
      )
end
