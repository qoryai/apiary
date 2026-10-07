defmodule Mix.Tasks.Apiary.Demo.Console do
  @shortdoc "Fills an empty database with a whole demo instance for the console (dev and test only)"

  @moduledoc """
  Fills an empty database with an instance to review the whole console against: an
  organisation, its workspaces, people, weeks of runs across about a hundred and fifty
  repositories, nodes, keys, a security policy, secrets, variables and integrations. All
  of it synthetic and neutral. A development tool: it refuses to run in production.

      APIARY_DEV_DATABASE=apiary_redesign_demo mix apiary.demo.console
      mix apiary.demo.console --runs 3000 --days 28

  `--runs` and `--days` size Main's history (below); `--seed` (1) makes it repeatable, and
  `--concurrency` (6) is how many processes write it.

  Point it at a database of its own: `config/dev.exs` reads the database's name from
  `APIARY_DEV_DATABASE`, and a `DATABASE_URL` in the shell replaces it, so unset that
  first. It refuses an instance that has an organisation other than its own, so the
  database you work in is never filled by mistake.

  ## What it makes

  On an empty instance, as the console's pages would, through the contexts:

    * **dana@example.com** signs up first, so she owns the organisation **Acme** (`acme`)
      and runs the instance, with its workspace **Main** (`main`).
    * **Main** gets `mix apiary.demo.history`'s history: `--runs` runs (6,000) over
      `--days` days (56) across 150 repositories on github.com, gitlab.com and
      codeberg.org, of every outcome, with subagents, terminals and network; its access
      keys; a dozen people at every level, one suspended, and two invitations pending;
      and the security policy, with versions, a lock and repositories of their own.
      `acme/shop` is on all three forges and `acme/billing` on two, so a path names more
      than one repository.
    * The six recordings of `priv/demo` are replayed into Main (`mix apiary.demo`), over
      the last day.
    * The nodes **build-01** and **build-02** and the pool **spot-runners**, each with
      keys added by their public keys (one revoked, one replaced), an enrolment code
      cancelled and one outstanding, and instances: the history's runs on the machines
      of those names are placed on them.
    * Secrets, one with two values; variables of the workspace, two locked, and of a few
      repositories; the claude runtime, the npm and Sentry services, and two
      integrations found from releases on github.com, served from here rather than
      fetched, and one release whose fetch failed. Runs do not receive these yet.
    * Dana pins three repositories.
    * Where the edition allows an organisation a second workspace, **Shop ops**
      (`shop-ops`) is made too, with a smaller history of its own; the core's allows
      one.

  Running it again on the instance it filled adds nothing of that. Either way it ends by
  bringing what lives for minutes up to now: it replays the running recording, a run
  alive for about half an hour, and makes build-02 an enrolment code when it has none
  outstanding, which lives fifteen minutes. To fill again from nothing, drop the
  database and create it again.

  ## Signing in

  Open http://localhost:4300/users/log-in (the port the server was started on), choose
  to log in with a password, and enter `dana@example.com` and the password
  `demo-console-acme`. Or ask for a log-in link for that address and open it from the
  development mailbox, http://localhost:4300/dev/mailbox. Every other person of the demo
  signs in by a link from the mailbox too; they have no password.
  """

  use Mix.Task

  import Ecto.Query

  alias Apiary.{AccessKeys, Accounts, Connections, Integrations, Nodes, Organisations}
  alias Apiary.{Repo, Secrets, Targets, Variables}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{Run, Target}
  alias Mix.Tasks.Apiary.Demo
  alias Mix.Tasks.Apiary.Demo.History

  @switches [runs: :integer, days: :integer, seed: :integer, concurrency: :integer]

  @owner "dana@example.com"
  @password "demo-console-acme"
  @organisation "Acme"
  @second {"Shop ops", "shop-ops"}

  # The recordings replayed into Main, by how long before now each ended.
  @replays [
    {"ping-only", 20},
    {"unassigned", 95},
    {"session-with-subagents", 170},
    {"failed-run", 400},
    {"timed-out", 1_300}
  ]

  @runner_version "0.10.0"

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod,
      do: Mix.raise("mix apiary.demo.console is a development tool: not in prod")

    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")
    # The query log of a fill is millions of lines nobody asked for.
    Logger.configure(level: :warning)

    Mix.shell().info("Database #{Repo.config()[:database]}")

    case instance() do
      :empty ->
        fill(opts)

      %User{} = owner ->
        Mix.shell().info("The demo is there already: nothing more is made.")
        owner

      :other ->
        Mix.raise(
          "this instance has an organisation that is not the demo's: fill an empty database"
        )
    end
    |> live()
  end

  # Whether the instance has no organisation in use, is the demo's (its first organisation
  # is Acme, owned by Dana), or is anybody else's.
  defp instance do
    first =
      Repo.one(
        from o in Organisation,
          where: is_nil(o.deletion_marked_at),
          order_by: [asc: o.inserted_at, asc: o.id],
          limit: 1
      )

    case first do
      nil ->
        :empty

      %Organisation{slug: "acme"} = organisation ->
        user = Accounts.get_user_by_email(@owner)

        if user && Repo.exists?(owned(organisation, user)), do: user, else: :other

      %Organisation{} ->
        :other
    end
  end

  defp owned(organisation, user) do
    from m in Organisations.Membership,
      where: m.organisation_id == ^organisation.id and m.user_id == ^user.id and m.level == :owner
  end

  ## The fill

  defp fill(opts) do
    runs = Keyword.get(opts, :runs, 6_000)
    days = Keyword.get(opts, :days, 56)
    seed = Keyword.get(opts, :seed, 1)
    concurrency = ["--concurrency", "#{Keyword.get(opts, :concurrency, 6)}"]

    owner = sign_up!()

    History.run(
      ~w(--workspace acme/main --repositories 150) ++
        ["--runs", "#{runs}", "--days", "#{days}", "--seed", "#{seed}"] ++ concurrency
    )

    main = scope!(owner, "main")
    replays(main)
    nodes(main)

    if Apiary.Features.on?(main, :security) do
      secrets(main)
      variables(main)
      connections(main)
    end

    pins(main)

    second =
      with %Scope{} = scope <- second_workspace(main, owner) do
        History.run(
          ~w(--workspace acme/#{scope.workspace.slug} --repositories 30 --skip-members) ++
            ["--runs", "#{max(div(runs, 7), 10)}", "--days", "#{max(div(days, 2), 2)}"] ++
            ["--seed", "#{seed + 1}"] ++ concurrency
        )

        if Apiary.Features.on?(scope, :security), do: variables_of_second(scope)
        [scope_of_second(owner, scope)]
      end

    counts([main | second || []])
    owner
  end

  # Shop ops, where the edition allows a second workspace; the core's allows one.
  defp second_workspace(main, owner) do
    {name, slug} = @second

    case Organisations.create_workspace(main, %{"name" => name, "slug" => slug}) do
      {:ok, _workspace} ->
        scope!(owner, slug)

      {:error, :limit} ->
        Mix.shell().info("The edition allows acme one workspace: #{slug} is not made")
        nil
    end
  end

  defp scope_of_second(owner, %Scope{workspace: workspace}), do: scope!(owner, workspace.slug)

  # The instance's first sign-up, as the sign-up page makes it, then a log-in link
  # followed, which confirms the address, and a password set, as Settings would.
  defp sign_up!() do
    {:ok, %{user: user}} =
      Organisations.sign_up_user(
        %{"email" => @owner, "organisation_name" => @organisation},
        nil,
        origin: %{worker: "demo"}
      )

    token = capture(&Accounts.deliver_login_instructions(user, &1))
    {:ok, {user, _expired}} = Accounts.login_user_by_magic_link(token)

    {:ok, {user, _expired}} =
      Accounts.update_user_password(user, %{
        password: @password,
        password_confirmation: @password
      })

    user
  end

  defp scope!(%User{} = user, workspace_slug) do
    case Organisations.resolve_scope(Scope.for_user(user), "acme", workspace_slug) do
      {:ok, scope} -> Scope.put_origin(scope, %{worker: "demo"})
      :error -> Mix.raise("#{@owner} does not reach acme/#{workspace_slug}")
    end
  end

  # The token a mail would have carried, handed to the URL function instead of sent.
  defp capture(fun) do
    ref = make_ref()
    parent = self()

    fun.(fn token ->
      send(parent, {ref, token})
      "#{ApiaryWeb.Endpoint.url()}/demo/#{token}"
    end)

    receive do
      {^ref, token} -> token
    after
      0 -> Mix.raise("no token was handed over")
    end
  end

  ## The recordings

  defp replays(scope) do
    key = laptop_key!(scope)
    now = DateTime.utc_now()

    for {name, minutes_ago} <- @replays do
      {:ok, _run} = Demo.replay(key, recording(name), DateTime.add(now, -minutes_ago, :minute))
    end

    Mix.shell().info("#{length(@replays)} recordings replayed")
  end

  # The key Dana's laptop posts with, as a verified request carries it.
  defp laptop_key!(scope) do
    key =
      scope
      |> AccessKeys.list_access_keys()
      |> Enum.find(&(&1.label == "dana-laptop" and is_nil(&1.revoked_at))) ||
        Mix.raise("Main has no key dana-laptop")

    Demo.access_key!(key.key_id)
  end

  defp recording(name), do: Application.app_dir(:apiary, "priv/demo/#{name}/events.jsonl")

  ## Nodes

  defp nodes(scope) do
    {:ok, build_01} = Nodes.create_node(scope, %{"kind" => "node", "name" => "build-01"})
    {:ok, build_02} = Nodes.create_node(scope, %{"kind" => "node", "name" => "build-02"})

    {:ok, pool} =
      Nodes.create_node(scope, %{
        "kind" => "pool",
        "name" => "spot-runners",
        "instance_limit" => 8
      })

    # build-01's first key was replaced: added, then a new one, then the old one revoked.
    old = add_key!(scope, build_01, "build-01-2026-08", false)
    key_01 = add_key!(scope, build_01, "build-01", false)
    {:ok, _revoked} = AccessKeys.revoke_access_key(scope, old)

    key_02 = add_key!(scope, build_02, "build-02", true)
    pool_a = add_key!(scope, pool, "spot-runners-a", false)
    pool_b = add_key!(scope, pool, "spot-runners-b", false)

    {:ok, code, _code} =
      AccessKeys.create_enrolment_code(scope, build_01, %{"label_hint" => "build-01-next"})

    {:ok, _cancelled} = AccessKeys.cancel_code(scope, code)

    placed =
      place(scope, build_01, ["build-01"], [key_01]) +
        place(scope, build_02, ["build-02"], [key_02]) +
        place(scope, pool, ci_runners(), [pool_a, pool_b])

    Mix.shell().info("Nodes build-01, build-02 and spot-runners: #{placed} runs placed on them")
  end

  defp ci_runners, do: for(n <- 1..12, do: "ci-runner-#{String.pad_leading("#{n}", 2, "0")}")

  # A key added by its public key, as an owner pastes one: a fresh Ed25519 key pair whose
  # private half is dropped.
  defp add_key!(scope, node, label, allow_secrets) do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      AccessKeys.add_access_key(scope, node, %{
        "public_key" => Base.url_encode64(public, padding: false),
        "label" => label,
        "allow_secrets" => allow_secrets
      })

    key
  end

  # The history's runs on the machines of `hosts` ran on `node`, each machine one of its
  # instances: the runs say so, and each instance was last seen with its last run.
  defp place(%Scope{workspace: workspace}, node, hosts, keys) do
    {placed, _} =
      Repo.update_all(
        from(r in Run,
          where: r.workspace_id == ^workspace.id and r.host in ^hosts,
          update: [set: [node_id: ^node.id, instance_id: r.host]]
        ),
        []
      )

    last_runs =
      Repo.all(
        from r in Run,
          where: r.workspace_id == ^workspace.id and r.node_id == ^node.id,
          group_by: r.host,
          select: {r.host, min(r.inserted_at), max(r.last_event_at)}
      )

    for {{host, first, last}, i} <- Enum.with_index(last_runs) do
      claim = %{
        instance_id: host,
        name: host,
        access_key_id: Enum.at(keys, rem(i, length(keys))).id,
        runner_version: @runner_version,
        contract_version: 1
      }

      :ok = Nodes.seen(node, claim, first)
      :ok = Nodes.seen(node, claim, last)
    end

    placed
  end

  ## Secrets and variables

  defp secrets(scope) do
    secrets = [
      {"GITHUB_APP_PRIVATE_KEY", "The GitHub App the runs push branches with",
       [{"main-app", "demo-main-app-key"}, {"bot-app", "demo-bot-app-key"}]},
      {"NPM_TOKEN", "Read access to the private packages", [{nil, "demo-npm-token"}]},
      {"SENTRY_AUTH_TOKEN", "Uploads source maps", [{nil, "demo-sentry-token"}]},
      {"DOCS_DEPLOY_TOKEN", "Publishes acme/docs", [{nil, "demo-docs-token"}]}
    ]

    for {name, note, [{value_id, value} | more]} <- secrets do
      {:ok, secret} =
        Secrets.create_secret(scope, %{
          "name" => name,
          "note" => note,
          "value" => value,
          "value_id" => value_id
        })

      for {value_id, value} <- more do
        {:ok, _secret} =
          Secrets.add_value(scope, secret, %{"value_id" => value_id, "value" => value})
      end
    end

    Mix.shell().info("#{length(secrets)} secrets")
  end

  defp variables(scope) do
    workspace = [
      {"TZ", "UTC", true},
      {"CI", "true", true},
      {"LOG_LEVEL", "info", false},
      {"NODE_ENV", "test", false},
      {"GOFLAGS", "-mod=readonly", false},
      {"PIP_INDEX_URL", "https://pypi.example/simple", false}
    ]

    for {name, value, locked} <- workspace do
      {:ok, _variable} =
        Variables.create_variable(scope, :workspace, %{
          "name" => name,
          "value" => value,
          "locked" => locked
        })
    end

    own = [
      {{"github.com", "acme/shop"}, [{"LOG_LEVEL", "debug"}, {"SHOP_CURRENCY", "EUR"}]},
      {{"codeberg.org", "acme/shop"}, [{"NODE_ENV", "development"}]},
      {{"github.com", "acme/billing"}, [{"BILLING_SANDBOX", "true"}]},
      {{"github.com", "acme/docs"}, [{"DOCS_BASE_URL", "https://docs.example.com"}]}
    ]

    count =
      for {{system, path}, variables} <- own,
          target = Targets.get(scope, system, path),
          target != nil,
          {name, value} <- variables,
          reduce: 0 do
        count ->
          {:ok, _variable} =
            Variables.create_variable(scope, target, %{"name" => name, "value" => value})

          count + 1
      end

    Mix.shell().info("#{length(workspace)} variables of the workspace, #{count} of repositories")
  end

  defp variables_of_second(scope) do
    for {name, value, locked} <- [{"TZ", "UTC", true}, {"LOG_LEVEL", "warn", false}] do
      {:ok, _variable} =
        Variables.create_variable(scope, :workspace, %{
          "name" => name,
          "value" => value,
          "locked" => locked
        })
    end
  end

  ## Connections

  # The integrations' releases, as a forge would serve them: this task answers for the
  # forge, so the demo needs no network.
  @releases [
    {"github.com/qoryai/qory-github", "0.1.0", :github},
    {"github.com/acme/tracker-integration", "0.3.0", :tracker}
  ]
  @missing {"github.com/acme/chat-notify", "1.2.0"}

  defp connections(scope) do
    fetch = Application.get_env(:apiary, Apiary.Integrations.Fetch)
    serve_releases()

    try do
      connect(scope)
    after
      if fetch,
        do: Application.put_env(:apiary, Apiary.Integrations.Fetch, fetch),
        else: Application.delete_env(:apiary, Apiary.Integrations.Fetch)
    end
  end

  defp connect(scope) do
    {:ok, _runtime} = Connections.create_runtime(scope, %{"runtime" => "claude"})
    {:ok, _npm} = Connections.create_service(scope, %{"service" => "npm"})

    {:ok, _sentry} =
      Connections.create_service(scope, %{
        "service" => "sentry",
        "applies_to" => "selected",
        "target_ids" =>
          target_ids(scope, [{"github.com", "acme/shop"}, {"github.com", "acme/web"}])
      })

    [github, tracker] =
      for {source, version, _description} <- @releases, do: release!(scope, source, version)

    {:ok, _github} =
      Connections.create_integration(scope, github.id, %{"settings" => %{"app_id" => "120034"}})

    {:ok, _tracker} =
      Connections.create_integration(scope, tracker.id, %{
        "settings" => %{"url" => "https://tracker.example.com"},
        "argument" => "SHOP",
        "applies_to" => "selected",
        "target_ids" =>
          target_ids(scope, [
            {"github.com", "acme/shop"},
            {"gitlab.com", "acme/shop"},
            {"codeberg.org", "acme/shop"}
          ])
      })

    {source, version} = @missing
    %{state: "failed"} = release!(scope, source, version)

    Mix.shell().info(
      "Connections: the claude runtime, npm and Sentry, two integrations; one release failed"
    )
  end

  defp target_ids(scope, pairs) do
    for {system, path} <- pairs,
        target = Targets.get(scope, system, path),
        target != nil,
        do: target.id
  end

  defp release!(scope, source, version) do
    {:ok, release} = Integrations.request_release(scope, %{source: source, version: version})
    {:ok, release} = Integrations.fetch_release(scope, release.id)
    release
  end

  # Every name resolves to a public documentation address, and each release's files are
  # answered from here; anything else is not found.
  defp serve_releases do
    files =
      for {source, version, which} <- @releases, into: %{} do
        [_host, path] = String.split(source, "/", parts: 2)
        bytes = Jason.encode!(description(which))
        hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        base = "/#{path}/releases/download/v#{version}/"

        {base,
         %{
           "description.json" => bytes,
           "checksums.txt" => "#{hash}  description.json\n"
         }}
      end

    Application.put_env(:apiary, Apiary.Integrations.Fetch,
      resolver: fn _host -> {:ok, [{203, 0, 113, 10}]} end,
      req_options: [plug: &answer(&1, files)]
    )
  end

  defp answer(conn, files) do
    base = Path.dirname(conn.request_path) <> "/"
    file = Path.basename(conn.request_path)

    case files do
      %{^base => %{^file => body}} -> Plug.Conn.send_resp(conn, 200, body)
      _ -> Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp description(:github) do
    %{
      "version" => 1,
      "name" => "github",
      "title" => "GitHub",
      "publisher" => %{"name" => "Qory", "url" => "https://qory.dev"},
      "description" => "Mints a GitHub App installation token for a run's repositories.",
      "domains" => ["software"],
      "program_version" => "0.1.0",
      "settings" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "app_id" => %{
            "title" => "App id",
            "type" => ["integer", "string"],
            "pattern" => "^[A-Za-z0-9.]{1,64}$"
          },
          "api_url" => %{"title" => "API", "type" => "string", "pattern" => "^https://"},
          "private_key" => %{
            "title" => "Private key",
            "type" => "string",
            "writeOnly" => true,
            "x-secret-name" => "GITHUB_APP_PRIVATE_KEY"
          },
          "private_key_file" => %{"title" => "Private key file", "type" => "string"}
        }
      },
      "roles" => %{
        "credential" => %{
          "argument" => "[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}",
          "hosts" => ["github.com", "api.github.com"],
          "settings" => ["app_id", "private_key"],
          "required" => ["app_id", "private_key"]
        }
      }
    }
  end

  defp description(:tracker) do
    %{
      "version" => 1,
      "name" => "acme-tracker",
      "title" => "Acme tracker",
      "publisher" => %{"name" => "Acme"},
      "description" => "Opens and updates the tracker's issues for a run.",
      "program_version" => "0.3.0",
      "settings" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{"title" => "Tracker", "type" => "string"},
          "api_key" => %{"title" => "API key", "type" => "string", "writeOnly" => true},
          "api_key_file" => %{"title" => "API key file", "type" => "string"}
        }
      },
      "roles" => %{
        "credential" => %{
          "argument" => "[A-Z]+",
          "hosts" => ["tracker.example.com"],
          "settings" => ["url", "api_key"]
        }
      }
    }
  end

  ## Pins

  defp pins(scope) do
    for {system, path} <- [
          {"github.com", "acme/shop"},
          {"github.com", "acme/billing"},
          {"codeberg.org", "acme/shop"}
        ],
        target = Targets.get(scope, system, path),
        target != nil do
      :ok = Targets.pin(scope, target)
    end
  end

  ## What lives for minutes

  # A run alive now, and an enrolment code outstanding: whatever was filled before, these
  # are brought up to this moment.
  defp live(%User{} = owner) do
    main = scope!(owner, "main")

    {:ok, run} = Demo.replay(laptop_key!(main), recording("running"))

    build_02 = Enum.find(Nodes.list_nodes(main), &(&1.name == "build-02"))

    if build_02 && AccessKeys.list_enrolment_codes(main, build_02) == [] do
      {:ok, _code, _code_text} =
        AccessKeys.create_enrolment_code(main, build_02, %{"label_hint" => "build-02-next"})
    end

    Mix.shell().info("""

    A run alive now: #{ApiaryWeb.Endpoint.url()}/acme/main/runs/#{run.run_id}
    Sign in as #{@owner}: see `mix help apiary.demo.console`.\
    """)
  end

  ## Counts

  defp counts(scopes) do
    for %Scope{workspace: %Workspace{} = workspace} <- scopes do
      targets = Repo.aggregate(from(t in Target, where: t.workspace_id == ^workspace.id), :count)

      systems =
        Repo.all(
          from t in Target,
            where: t.workspace_id == ^workspace.id,
            group_by: t.system,
            order_by: t.system,
            select: {t.system, count()}
        )

      states =
        Repo.all(
          from r in Run,
            where: r.workspace_id == ^workspace.id,
            group_by: r.state,
            order_by: r.state,
            select: {r.state, count()}
        )

      Mix.shell().info("""

      acme/#{workspace.slug}: #{targets} repositories (#{format(systems)})
        runs: #{format(states)}\
      """)
    end
  end

  defp format(pairs), do: Enum.map_join(pairs, ", ", fn {name, count} -> "#{name} #{count}" end)
end
