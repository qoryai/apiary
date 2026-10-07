defmodule Mix.Tasks.Apiary.Demo.History do
  @shortdoc "Fills a workspace with months of synthetic runs, keys and members (dev and test only)"

  @moduledoc """
  Fills a workspace with a history to review the console against at scale: months of
  synthetic runs across many repositories, the nodes the machines run on with the access
  keys they post with, and people at every level. A development tool: it refuses to run in production.

      mix apiary.demo.history
      mix apiary.demo.history --workspace acme/main --runs 50000 --repositories 300
      mix apiary.demo.history --days 30 --seed 7 --skip-members

  `--workspace` names the workspace as `organisation/workspace`, by their slugs; without it,
  the instance's first workspace. `--runs` (15,000) runs are spread over the last `--days`
  (120) days across `--repositories` (150) repositories: busier towards today, on working
  days and in working hours, with a nightly batch at two. A few repositories take most of
  the runs and most take a handful; some are new this month and some went quiet months
  ago; one run in thirty names no repository. `--seed` (1) makes the plan repeatable: the
  same seed gives the same runs, under new ids every time.

  Each run is a record the runner could have sent: its start, the policy it ran under, an
  agent's session with its tools and subagents, the terminal's output, its connections and
  heartbeats, and its exit. Most succeed; some fail, time out, go silent and are found
  lost, or are closed by a member; a few are still running when the task ends and are found
  lost a minute and a half later, as any run that stops talking is; one in two hundred
  writes tens of thousands of lines. The events are written with the times they happened
  and received a moment later, as the receiver would have stored them, and every run is
  projected by `Apiary.Runs.Projector`, as the receiver's runs are.

  Nodes, keys and people go through the contexts, as the console's pages would, in the
  name of the workspace's first owner, so the audit trail has them: a node per machine
  group (a node pool for a fleet of several machines), each with a key added by its
  Ed25519 public key; a second key added to one pool, as when its key is replaced, one key
  revoked, and one node whose key is never used. Each run is placed on its machine's node,
  as the instance of its host, and each host is recorded as an instance of the node it
  last ran on. A dozen people who joined by invitation,
  owners, admins and members, one suspended, and two invitations pending
  (`--skip-members` leaves the people alone). Last, when the instance serves the security
  feature, the workspace is given `mix apiary.demo`'s policy if nobody has made one, the
  hosts its history reaches, and modes and rules of their own for a few repositories.

  Running it again adds another history beside the first.
  """

  use Mix.Task

  import Ecto.Query

  alias Apiary.{AccessKeys, Accounts, Nodes, Organisations, Policy, Repo, Runs}
  alias Apiary.Nodes.Instance
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias Apiary.Runs.{Event, Liveness, Projector, Run, Target}

  @switches [
    workspace: :string,
    runs: :integer,
    repositories: :integer,
    days: :integer,
    seed: :integer,
    concurrency: :integer,
    skip_members: :boolean
  ]

  @chunk 40
  @insert_rows 1_000
  @log_bytes 3_000
  @long_log_bytes 12_000
  @minute 60_000
  @day 86_400_000

  # The machines that post, by the node they run on and the label of its key, both named
  # `key`; several hosts make a node pool. `weight` is their share of the daytime runs; the
  # nightly machine posts only the nightly batch, and the legacy one only until it was
  # replaced.
  @machines [
    %{
      key: "ci-fleet",
      hosts: for(n <- 1..12, do: "ci-runner-#{String.pad_leading("#{n}", 2, "0")}"),
      wall: "docker",
      weight: 52,
      laptop: false
    },
    %{
      key: "build-eu",
      hosts: ~w(build-eu-01 build-eu-02),
      wall: "docker",
      weight: 18,
      laptop: false
    },
    %{key: "gpu-lab", hosts: ~w(gpu-01 gpu-02), wall: "docker", weight: 5, laptop: false},
    %{
      key: "legacy-ci",
      hosts: ~w(legacy-ci-01),
      wall: "docker",
      weight: 10,
      laptop: false,
      until: 75
    },
    %{key: "dana-laptop", hosts: ~w(dana-mbp), wall: nil, weight: 6, laptop: true},
    %{key: "mirek-laptop", hosts: ~w(mirek-mbp), wall: "docker", weight: 5, laptop: true},
    %{key: "sam-laptop", hosts: ~w(sam-thinkpad), wall: nil, weight: 4, laptop: true}
  ]
  @nightly_machine %{key: "nightly", hosts: ~w(cron-01), wall: "docker", weight: 0, laptop: false}
  @idle_key "staging-bot"

  @people [
    {"dana", :owner},
    {"mirek", :admin},
    {"priya", :admin},
    {"sam", :member},
    {"jonas", :member},
    {"lea", :member},
    {"tomasz", :member},
    {"amara", :member},
    {"kenji", :member},
    {"sofia", :member},
    {"noah", :suspended}
  ]
  @invited ~w(new-hire@example.com contractor@partner.example)

  # The repositories every history has: the recorded demo's, one path on three forges and
  # one on two, so that a path names more than one repository.
  @anchors [
    {"codeberg.org", "acme/shop"},
    {"github.com", "acme/shop"},
    {"gitlab.com", "acme/shop"},
    {"github.com", "acme/billing"},
    {"gitlab.com", "acme/billing"},
    {"github.com", "acme/docs"},
    {"github.com", "acme/api"},
    {"github.com", "acme/web"},
    {"github.com", "acme/tax-service"}
  ]

  @namespaces ~w(acme platform data mobile payments growth ml infra security web)

  @repository_names ~w(
    shop api web checkout-service payments-gateway ledger billing auth-service identity
    notifications search recommendations inventory catalogue cart orders shipping pricing
    tax-service fraud-detection analytics etl-pipelines warehouse dbt-models feature-store
    ml-training model-serving embeddings ios-app android-app mobile-shell design-tokens
    ui-kit storybook docs-site marketing-site blog terraform-modules k8s-manifests
    helm-charts ci-templates dev-containers observability alerting log-shipper gateway
    edge-proxy rate-limiter cache queue-workers cron-jobs admin-console support-tools
    crm-sync email-service sms-service webhooks public-api sdk-js sdk-python sdk-go cli
    migrations schema-registry event-bus search-indexer image-resizer media-service
    cdn-config secrets-rotation access-reviews sso scim audit-log compliance-reports
    status-page incident-bot chatops release-tools changelog monorepo legacy-monolith
    storefront-php batch-jobs rust-core wasm-runtime protobufs graphql-gateway bff-web
    bff-mobile experiments flags-service pricing-engine subscriptions invoicing
    reconciliation data-quality notebooks benchmarks load-tests e2e-tests fixtures
    sandbox playground onboarding referrals loyalty reviews wishlist returns
  )

  @issues [
    "the cart badge shows the wrong count after an item is removed",
    "checkout totals are a cent off when a discount applies",
    "the orders service test times out under -race",
    "the admin users table needs pagination",
    "upgrade to Node 24 and fix the deprecation warnings",
    "retry webhook deliveries with exponential backoff",
    "search results ignore diacritics",
    "the nightly import fails when the partner feed is empty",
    "rotate the signing keys without downtime",
    "tax rules for 2027: the reduced rate for books",
    "the date picker is unreadable in dark mode",
    "add an index for the orders-by-customer query",
    "invoice PDFs cut off long addresses",
    "move the rate limiter to a sliding window",
    "the resizer crashes on images over 20 MB",
    "support SCIM group sync",
    "document the public API's error codes",
    "get the container image under 200 MB",
    "the session cookie is missing SameSite",
    "replace moment.js with date-fns",
    "the feature flag cache never expires",
    "retries double-charge a card when the gateway times out",
    "the export job holds a lock for minutes",
    "the mobile shell leaks a listener on every navigation",
    "the Terraform plan wants to recreate the NAT gateway",
    "alerts fire twice after a deploy",
    "the embeddings job runs out of memory on long documents",
    "the changelog generator skips squashed commits",
    "password reset emails go out in the wrong language",
    "the GraphQL gateway returns 500 on an unknown field",
    "the storefront's sitemap lists deleted products",
    "the loyalty points total is wrong after a refund",
    "returns can be opened after the 30-day window",
    "the status page does not show scheduled maintenance",
    "log lines lose their request id in background jobs",
    "the SDK retries a 400 as if it were a 503"
  ]

  @campaigns [
    {"renovate-deps",
     "Update the dependencies Renovate flagged, run the tests, and summarise anything that needed a code change."},
    {"fix-flaky-tests",
     "Find the flakiest test in the last week of CI for this repository and make it deterministic."},
    {"upgrade-node-24",
     "Move this repository to Node 24: engines, CI images and anything the upgrade breaks."},
    {"migrate-to-pnpm",
     "Replace npm with pnpm, keep the lockfile's versions, and make CI green."},
    {"docs-refresh",
     "Bring the README and the docs folder in line with what the code does today."},
    {"checkout-redesign",
     "Split checkout into address, delivery and payment steps and keep the existing validation."},
    {"tax-rules-2027", "Apply the 2027 VAT changes and add a test per changed rate."},
    {"sbom-export", "Generate a CycloneDX SBOM in CI and attach it to releases."},
    {"license-audit",
     "List every dependency whose licence is not on the allow list; change nothing."},
    {"go-1-26-upgrade", "Upgrade to Go 1.26 and fix what the new vet checks report."}
  ]

  @nightly {"nightly-audit",
            "Audit the repository for leaked secrets, outdated dependencies and failing checks. Report; change nothing."}

  # What the policy allows, with the rule that names each host, and what a locked rule
  # denies in either mode; everything else is denied under enforce and let through under
  # observe.
  @allowed %{
    "api.llm.example" => "api.llm.example",
    "packages.example.com" => "packages.example.com",
    "cdn.packages.example.com" => "*.packages.example.com",
    "registry.example" => "registry.example",
    "codeberg.org" => "codeberg.org",
    "github.com" => "github.com",
    "api.github.com" => "api.github.com",
    "gitlab.com" => "gitlab.com",
    "proxy.golang.example" => "proxy.golang.example",
    "pypi.example" => "pypi.example",
    "files.pypi.example" => "files.pypi.example",
    "crates.example" => "crates.example",
    "static.crates.example" => "static.crates.example",
    "registry.terraform.example" => "registry.terraform.example",
    "releases.hashicorp.example" => "releases.hashicorp.example",
    "repo.packagist.example" => "repo.packagist.example"
  }
  @locked_deny "telemetry.llm.example"
  @baseline_hosts ~w(
    github.com api.github.com gitlab.com proxy.golang.example pypi.example
    files.pypi.example crates.example static.crates.example registry.terraform.example
    releases.hashicorp.example repo.packagist.example
  )

  @noise ~w(
    metrics.example sentry.example fonts.example cdn.jsdelivr.example api.segment.example
    hooks.slack.example storage.cloud.example s3.eu-west-1.example
    raw.githubusercontent.example objects.githubusercontent.example ghcr.example
    docker.registry.example auth.docker.example npm.pkg.github.example
    docs.example.dev developer.mozilla.example pkg.go.example
  )
  @vendors ~w(
    stripe adyen twilio sendgrid mailgun algolia contentful datadog honeycomb launchdarkly
    auth0 okta segment mixpanel amplitude intercom zendesk hubspot salesforce shopify
    mapbox openweather cloudinary imgix fastly akamai pagerduty opsgenie statuspage
    linear jira notion figma miro loom vercel netlify render fly supabase planetscale
  )

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod,
      do: Mix.raise("mix apiary.demo.history is a development tool: not in prod")

    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")
    # The query log of a history is millions of lines nobody asked for.
    Logger.configure(level: :warning)

    runs = Keyword.get(opts, :runs, 15_000)
    repositories = Keyword.get(opts, :repositories, 150)
    days = Keyword.get(opts, :days, 120)
    seed = Keyword.get(opts, :seed, 1)
    concurrency = Keyword.get(opts, :concurrency, 6)

    :rand.seed(:exsss, {seed, 1_234, 5_678})
    now = DateTime.utc_now()
    scope = owner_scope!(opts[:workspace])
    %Scope{organisation: organisation, workspace: workspace} = scope

    Mix.shell().info("Filling #{organisation.slug}/#{workspace.slug}")

    keys = keys!(scope)
    if !opts[:skip_members], do: people(scope)

    catalogue = catalogue(repositories, days)
    plan = plan(runs, days, catalogue, now)
    ctx = %{scope: scope, keys: keys, seed: seed, now: now, days: days}

    Mix.shell().info("Writing #{length(plan)} runs in #{length(catalogue)} repositories")
    started = System.monotonic_time(:millisecond)
    write(plan, ctx, concurrency)
    seconds = div(System.monotonic_time(:millisecond) - started, 1000)
    Mix.shell().info("Written in #{seconds} s")

    settle(ctx, plan)

    if Apiary.Features.on?(scope, :security), do: policy(scope, keys)

    Mix.shell().info("""

    #{ApiaryWeb.Endpoint.url()}/#{organisation.slug}/#{workspace.slug}/runs\
    """)
  end

  ## The workspace and its owner

  defp owner_scope!(nil) do
    workspace =
      Repo.one(
        from w in Workspace,
          where: is_nil(w.deletion_marked_at),
          order_by: [asc: w.inserted_at, asc: w.id],
          limit: 1
      ) || Mix.raise("there is no workspace yet: sign up first")

    owner_scope!(workspace)
  end

  defp owner_scope!(slugs) when is_binary(slugs) do
    with [organisation_slug, workspace_slug] <- String.split(slugs, "/", parts: 2),
         %Organisation{} = organisation <- Repo.get_by(Organisation, slug: organisation_slug),
         %Workspace{} = workspace <-
           Repo.get_by(Workspace, organisation_id: organisation.id, slug: workspace_slug) do
      owner_scope!(workspace)
    else
      _ -> Mix.raise("no workspace #{slugs}: name it organisation/workspace, by their slugs")
    end
  end

  defp owner_scope!(%Workspace{} = workspace) do
    organisation = Repo.get!(Organisation, workspace.organisation_id)

    membership =
      Repo.one(
        from m in Membership,
          where: m.organisation_id == ^organisation.id and m.level == :owner,
          order_by: [asc: m.inserted_at, asc: m.id],
          limit: 1,
          preload: :user
      ) || Mix.raise("#{organisation.slug} has no owner")

    scope_of(membership.user, organisation, workspace) ||
      Mix.raise("the first owner of #{organisation.slug} does not reach #{workspace.slug}")
  end

  defp scope_of(%User{} = user, %Organisation{} = organisation, %Workspace{} = workspace) do
    case Organisations.resolve_scope(Scope.for_user(user), organisation.slug, workspace.slug) do
      {:ok, scope} -> Scope.put_origin(scope, %{worker: "demo"})
      :error -> nil
    end
  end

  ## Nodes and keys

  # Every machine's key, by label, on a node of the same name: the workspace's own node
  # and key when it has them, the key neither revoked nor rejected, new ones otherwise. A
  # machine of several hosts is a node pool. The idle node's key is made and never posted
  # with. A key is added by its public key, as `qory access-key create` prints one; its
  # private half is thrown away, since nothing here signs a request.
  defp keys!(scope) do
    nodes = Map.new(Nodes.list_nodes(scope), &{&1.name, &1})

    held =
      scope
      |> AccessKeys.list_workspace_node_keys()
      |> Map.new(&{{&1.node.name, &1.label}, &1})

    machines = [@nightly_machine | @machines] ++ [%{key: @idle_key, hosts: ["staging-01"]}]

    Map.new(machines, fn %{key: label, hosts: hosts} ->
      node = Map.get_lazy(nodes, label, fn -> node!(scope, label, hosts) end)

      key =
        case held do
          %{{^label, ^label} => key} -> key
          _ -> add_key!(scope, node, label)
        end

      {label, %{key | node: node}}
    end)
  end

  defp node!(scope, name, hosts) do
    kind = if length(hosts) > 1, do: "pool", else: "node"

    case Nodes.create_node(scope, %{"kind" => kind, "name" => name}) do
      {:ok, node} -> node
      {:error, reason} -> Mix.raise("the node #{name} was not made: #{inspect(reason)}")
    end
  end

  defp add_key!(scope, node, label) do
    {public_key, _private} = :crypto.generate_key(:eddsa, :ed25519)

    case AccessKeys.add_access_key(scope, node, %{
           "label" => label,
           "public_key" => Base.url_encode64(public_key, padding: false),
           "allow_secrets" => false
         }) do
      {:ok, key} -> key
      {:error, reason} -> Mix.raise("the key #{label} was not made: #{inspect(reason)}")
    end
  end

  # The instance a host runs as on a node: the same id for the same host and node, in
  # every history, as a runner keeps its instance id.
  defp instance_id(node_id, host) do
    digest = :crypto.hash(:sha256, [node_id, ?/, host])
    "i_" <> Base.url_encode64(binary_part(digest, 0, 16), padding: false)
  end

  ## People

  defp people(scope) do
    made =
      for {name, level} <- @people do
        email = "#{name}@example.com"
        user = Accounts.get_user_by_email(email) || register!(email)

        if member?(scope.organisation, user) do
          :kept
        else
          {:ok, membership} = Organisations.accept_invitation(user, invite!(scope, email))

          case level do
            :member -> {:ok, membership}
            :suspended -> Organisations.suspend_member(scope, membership.id)
            level -> Organisations.set_member_level(scope, membership.id, level)
          end
        end
      end

    pending =
      for email <- @invited, not invited?(scope.organisation, email) do
        invite!(scope, email)
      end

    joined = Enum.count(made, &(&1 != :kept))
    Mix.shell().info("#{joined} people joined, #{length(pending)} invitations pending")
  end

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email})
    token = capture(&Accounts.deliver_login_instructions(user, &1))
    {:ok, {user, _expired}} = Accounts.login_user_by_magic_link(token)
    user
  end

  defp invite!(scope, email) do
    capture(fn url_fun ->
      case Organisations.invite_member(scope, %{"email" => email}, url_fun) do
        {:ok, invitation} -> {:ok, invitation}
        {:error, reason} -> Mix.raise("#{email} was not invited: #{inspect(reason)}")
      end
    end)
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

  defp member?(%Organisation{id: organisation_id}, %User{id: user_id}) do
    Repo.exists?(
      from m in Membership, where: m.organisation_id == ^organisation_id and m.user_id == ^user_id
    )
  end

  defp invited?(%Organisation{id: organisation_id}, email) do
    Repo.exists?(
      from i in Invitation,
        where: i.organisation_id == ^organisation_id and i.email == ^email
    )
  end

  ## The repositories

  # `count` repositories: the anchors, then pairs of a namespace and a name, each path
  # once. Each has a language, a weight that falls with its rank, and the days it was
  # active: most all along, some born lately, some quiet for months.
  defp catalogue(count, days) do
    anchored = MapSet.new(@anchors, fn {_system, path} -> path end)

    generated =
      for namespace <- @namespaces,
          name <- @repository_names,
          path = "#{namespace}/#{name}",
          path not in anchored do
        {pick_forge(), path}
      end
      |> Enum.shuffle()

    (@anchors ++ generated)
    |> Enum.take(count)
    |> Enum.with_index(1)
    |> Enum.map(fn {{system, path}, rank} ->
      [namespace, name] = String.split(path, "/", parts: 2)
      anchor = rank <= length(@anchors)

      {born, quiet} =
        cond do
          anchor -> {days, 0}
          days > 10 and chance(0.15) -> {between(3, min(30, days - 1)), 0}
          days > 30 and chance(0.12) -> {days, between(div(days, 3), days - 10)}
          true -> {days, 0}
        end

      %{
        system: system,
        path: path,
        name: name,
        flavour: flavour(namespace, name),
        weight: 1 / :math.pow(rank, 1.05),
        born: born,
        quiet: quiet,
        issue: between(40, 2_400)
      }
    end)
  end

  defp pick_forge,
    do: weighted([{"github.com", 70}, {"gitlab.com", 20}, {"codeberg.org", 10}])

  defp flavour(namespace, name) do
    cond do
      namespace in ~w(data ml) or
          name =~ ~r/etl|dbt|notebook|model|embedding|feature-store|data-quality|sdk-python/ ->
        "python"

      namespace == "infra" or name =~ ~r/terraform|k8s|helm|cdn-config/ ->
        "terraform"

      name =~ ~r/rust|wasm|protobufs/ ->
        "rust"

      name =~ ~r/php|storefront|legacy-monolith/ ->
        "php"

      name =~ ~r/service|gateway|ledger|proxy|limiter|event-bus|sdk-go|cli|queue|api|cache/ ->
        "go"

      true ->
        "node"
    end
  end

  ## The plan

  # One spec per run, oldest first: when it started, where, on which machine, for what
  # task, by which runtime, and how it ended.
  defp plan(count, days, catalogue, now) do
    now_ms = DateTime.to_unix(now, :millisecond)
    today = div(now_ms, @day) * @day
    alive = min(6, div(count, 100))

    day_weights =
      for d <- 0..(days - 1) do
        start = today - d * @day
        weekday = start |> div(1000) |> DateTime.from_unix!() |> Date.day_of_week()
        weekend = if weekday in [6, 7], do: 0.3, else: 1.0
        {d, :math.exp(1.6 * (1 - d / days)) * weekend}
      end

    hours =
      Enum.zip(0..23, [1, 1, 0, 1, 1, 1, 2, 4, 7, 9, 10, 10, 8, 9, 10, 10, 9, 8, 6, 4, 3, 2, 2, 1])

    starts =
      for _ <- 1..(count - alive) do
        if chance(0.06) do
          d = weighted(day_weights)

          {:nightly,
           today - d * @day + 2 * 3_600_000 + between(0, 40) * @minute + between(0, 59_999)}
        else
          d = weighted(day_weights)
          at = today - d * @day + weighted(hours) * 3_600_000 + between(0, 3_599_999)
          # A time later today than now is the same time yesterday.
          {:day, if(at > now_ms - 20 * @minute, do: at - @day, else: at)}
        end
      end

    live = for _ <- 1..alive//1, do: {:alive, now_ms - between(1, 25) * @minute}

    (starts ++ live)
    |> Enum.sort_by(fn {_kind, at} -> at end)
    |> Enum.with_index(1)
    |> Enum.map_reduce(Map.new(catalogue, &{&1.path <> "@" <> &1.system, &1.issue}), fn
      {{kind, at}, index}, issues ->
        days_ago = div(now_ms - at, @day)
        spec(kind, at, index, days_ago, catalogue, issues, now_ms)
    end)
    |> elem(0)
  end

  defp spec(kind, at, index, days_ago, catalogue, issues, now_ms) do
    active = Enum.filter(catalogue, &(days_ago < &1.born and days_ago >= &1.quiet))

    repository =
      cond do
        kind == :nightly -> Enum.at(catalogue, rem(index, min(40, length(catalogue))))
        chance(0.033) or active == [] -> nil
        true -> weighted(Enum.map(active, &{&1, &1.weight}))
      end

    machine = machine(kind, repository, days_ago)
    {task, prompt, issues} = task(kind, repository, issues)
    runtime = runtime(kind, machine)
    {outcome, duration} = outcome(kind, runtime, at, now_ms)

    {%{
       index: index,
       at: at,
       repository: repository,
       machine: machine,
       host: pick(machine.hosts),
       task: task,
       prompt: prompt,
       runtime: runtime,
       interactive: machine.laptop and runtime == "claude" and chance(0.5),
       outcome: outcome,
       duration: duration,
       long: outcome not in [:alive, :ping] and chance(0.005),
       days_ago: days_ago
     }, issues}
  end

  defp machine(:nightly, _repository, _days_ago), do: @nightly_machine

  defp machine(_kind, repository, days_ago) do
    choices =
      for m <- @machines,
          days_ago >= Map.get(m, :until, 0),
          m.key != "gpu-lab" or (repository && repository.flavour == "python"),
          do: {m, m.weight}

    weighted(choices)
  end

  defp task(:nightly, _repository, issues) do
    {name, prompt} = @nightly
    {name, prompt, issues}
  end

  defp task(_kind, nil, issues) do
    if chance(0.5),
      do:
        {nil,
         pick([
           "tidy up the scratch branch",
           "explain this stack trace",
           "what changed since Friday?"
         ]), issues},
      else:
        {"scratch", "Try the new lint rules on this checkout and tell me what breaks.", issues}
  end

  defp task(_kind, repository, issues) do
    key = repository.path <> "@" <> repository.system

    cond do
      chance(0.12) ->
        {nil, "Look at #{pick(@issues)} and tell me where to start.", issues}

      chance(0.17) ->
        {name, prompt} = pick(@campaigns)
        {name, prompt, issues}

      true ->
        # Mostly the next issue; one in three is another attempt at the last one.
        number = Map.fetch!(issues, key)
        number = if chance(0.33), do: number, else: number + between(1, 6)
        title = Enum.at(@issues, rem(number, length(@issues)))

        {"issue-#{number}",
         "Fix issue ##{number}: #{title}. Keep the existing tests passing and add one for the fix.",
         Map.put(issues, key, number)}
    end
  end

  defp runtime(:nightly, _machine), do: "claude"

  defp runtime(_kind, %{laptop: true}), do: weighted([{"claude", 80}, {"codex", 20}])

  defp runtime(_kind, _machine),
    do: weighted([{"claude", 58}, {"codex", 24}, {:program, 18}])

  defp outcome(:alive, _runtime, at, now_ms), do: {:alive, now_ms - at}

  defp outcome(_kind, runtime, _at, _now_ms) do
    outcome =
      if runtime == :program do
        weighted([{:succeeded, 78}, {:failed, 20}, {:timed_out, 2}])
      else
        weighted([
          {:succeeded, 72},
          {:failed, 16},
          {:timed_out, 3},
          {:lost, 3},
          {:closed, 1.5},
          {:ping, 0.5}
        ])
      end

    duration =
      case {outcome, runtime} do
        {:timed_out, _} -> 3_600_000
        {:ping, _} -> 0
        {_, :program} -> clamp(lognormal(90_000, 0.7), 5_000, 1_200_000)
        {:failed, _} -> clamp(lognormal(240_000, 0.8), 20_000, 3_000_000)
        {_, _} -> clamp(lognormal(420_000, 0.8), 25_000, 3_300_000)
      end

    {outcome, duration}
  end

  ## Writing

  defp write(plan, ctx, concurrency) do
    total = length(plan)

    plan
    |> Enum.chunk_every(@chunk)
    |> Task.async_stream(&write_chunk(&1, ctx),
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(0, fn {:ok, written}, done ->
      done = done + written

      if div(done, 1_000) > div(done - written, 1_000) or done == total,
        do: Mix.shell().info("  #{done} / #{total}")

      done
    end)
  end

  defp write_chunk(specs, ctx) do
    built = Enum.map(specs, &build(&1, ctx))

    Repo.insert_all(Run, Enum.map(built, fn {run, _events} -> run end))

    built
    |> Enum.flat_map(fn {_run, events} -> events end)
    |> Enum.chunk_every(@insert_rows)
    |> Enum.each(&Repo.insert_all(Event, &1, log: false))

    for {run, _events} <- built, do: {:ok, _run} = Projector.project(%Run{id: run.id})

    length(specs)
  end

  # The run's row as the receiver makes it on a first event, and its events as stored.
  defp build(spec, ctx) do
    :rand.seed(:exsss, {ctx.seed, spec.index, 97})
    %Scope{organisation: organisation, workspace: workspace} = ctx.scope
    key = Map.fetch!(ctx.keys, spec.machine.key)
    id = Ecto.UUID.generate()

    events =
      spec
      |> record()
      |> Enum.sort_by(fn {at, n, _type, _data} -> {at, n} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{at, _n, type, data}, sequence} ->
        time = spec.at + at

        %{
          id: Ecto.UUID.generate(),
          organisation_id: organisation.id,
          workspace_id: workspace.id,
          run_id: id,
          sequence: sequence,
          event_id: Ecto.UUID.generate(),
          type: "dev.qory." <> type,
          time: instant(time),
          data: data,
          received_at: instant(time + between(80, 2_500))
        }
      end)

    first = hd(events)
    last = List.last(events)

    run = %{
      id: id,
      organisation_id: organisation.id,
      workspace_id: workspace.id,
      run_id: uuid7(spec.at),
      access_key_id: key.id,
      node_id: key.node_id,
      instance_id: instance_id(key.node_id, spec.host),
      state: "pending",
      runner_version: runner_version(spec),
      contract_version: 1,
      event_count: length(events),
      last_event_at: last.received_at,
      inserted_at: first.received_at,
      updated_at: last.received_at
    }

    {run, events}
  end

  defp instant(ms), do: DateTime.from_unix!(ms * 1000, :microsecond)

  # A version 7 UUID of the run's start, as the runner makes one.
  defp uuid7(ms) do
    <<a::12, b::62, _::6>> = :crypto.strong_rand_bytes(10)
    {:ok, uuid} = Ecto.UUID.load(<<ms::48, 7::4, a::12, 2::2, b::62>>)
    uuid
  end

  defp runner_version(%{machine: %{key: "legacy-ci"}}), do: "0.4.1"

  defp runner_version(%{days_ago: days_ago}) do
    cond do
      days_ago > 80 -> "0.8.4"
      days_ago > 30 -> "0.9.2"
      true -> "0.10.0"
    end
  end

  ## The record of one run

  # `{offset_ms, n, type, data}` items, in no order: the caller sorts them by time, and
  # by the order they were put at one time.
  defp record(%{outcome: :ping} = spec) do
    put(new(), 0, "ping", ping(spec)) |> items()
  end

  defp record(spec) do
    mode = mode(spec)
    ends = ends(spec)

    new()
    |> put(0, "ping", ping(spec))
    |> put(120, "run.started", started(spec))
    |> put(150, "run.policy_applied", policy_applied(spec, mode))
    |> log(200, spec, banner(spec, mode))
    |> work(spec, mode, ends)
    |> heartbeats(ends)
    |> finish(spec, ends)
    |> items()
  end

  defp new, do: %{items: [], n: 0}
  defp items(acc), do: acc.items

  defp put(acc, at, type, data),
    do: %{acc | items: [{at, acc.n, type, data} | acc.items], n: acc.n + 1}

  # Where the record stops: at its exit, or, for a run that went silent, part of the way.
  defp ends(%{outcome: outcome, duration: duration}) when outcome in [:lost, :closed],
    do: round(duration * (0.3 + :rand.uniform() * 0.5))

  defp ends(%{duration: duration}), do: duration

  defp ping(spec) do
    %{
      "runner_version" => runner_version(spec),
      "events" => ["*"],
      "contract_version" => 1,
      "interval_seconds" => 30
    }
  end

  defp started(spec) do
    {command, args} = command(spec)
    repository = spec.repository

    labels =
      %{
        "forge" => repository && repository.system,
        "repository" => repository && repository.path,
        "task" => spec.task,
        "trigger" => trigger(spec)
      }
      |> Enum.reject(fn {_label, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "runtime" => runtime_name(spec),
      "runtime_version" => runtime_version(spec),
      "command" => command,
      "args" => args,
      "dir" => "/work/#{workdir(spec)}",
      "interactive" => spec.interactive,
      "runner_version" => runner_version(spec),
      "host" => spec.host,
      "labels" => labels
    }
    |> put_if(spec.machine.wall, "wall", spec.machine.wall)
    |> put_if(spec.machine.wall, "image", image(spec))
    |> put_if(spec.interactive, "terminal", %{
      "cols" => pick([120, 160, 200]),
      "rows" => pick([40, 48, 56])
    })
  end

  defp trigger(%{machine: %{key: "nightly"}}), do: "schedule"
  defp trigger(%{machine: %{laptop: true}}), do: nil
  defp trigger(%{task: "issue-" <> _}), do: "issue"
  defp trigger(_spec), do: nil

  defp put_if(map, nil, _key, _value), do: map
  defp put_if(map, false, _key, _value), do: map
  defp put_if(map, _condition, key, value), do: Map.put(map, key, value)

  defp workdir(%{repository: nil}), do: "scratch"
  defp workdir(%{repository: repository}), do: repository.name

  defp flavour_of(%{repository: nil}), do: "node"
  defp flavour_of(%{repository: repository}), do: repository.flavour

  defp runtime_name(%{runtime: :program} = spec), do: spec |> command() |> elem(0)
  defp runtime_name(%{runtime: runtime}), do: runtime

  defp runtime_version(%{runtime: "claude", days_ago: d}), do: "2.1.#{300 - div(d, 2)}"
  defp runtime_version(%{runtime: "codex", days_ago: d}), do: "0.#{52 - div(d, 14)}.0"

  defp runtime_version(spec) do
    case flavour_of(spec) do
      "node" -> "11.6.0"
      "go" -> "4.4.1"
      "python" -> "8.4.2"
      "rust" -> "1.90.0"
      "terraform" -> "1.13.3"
      "php" -> "2.8.12"
    end
  end

  defp command(%{runtime: "claude", interactive: true}), do: {"claude", []}
  defp command(%{runtime: "claude"} = spec), do: {"claude", ["-p", spec.prompt, "--verbose"]}
  defp command(%{runtime: "codex"} = spec), do: {"codex", ["exec", spec.prompt]}

  defp command(spec) do
    case flavour_of(spec) do
      "node" -> {"npm", ["test"]}
      "go" -> {"make", ["test"]}
      "python" -> {"pytest", ["-q"]}
      "rust" -> {"cargo", ["test"]}
      "terraform" -> {"terraform", ["plan", "-input=false"]}
      "php" -> {"composer", ["test"]}
    end
  end

  defp image(spec) do
    case {spec.runtime, flavour_of(spec)} do
      {runtime, _} when runtime in ["claude", "codex"] ->
        "registry.example.com/acme/devbox:2026.09"

      {_, "node"} ->
        "registry.example.com/acme/node-build:24"

      {_, "go"} ->
        "registry.example.com/acme/go-build:1.25"

      {_, "python"} ->
        "registry.example.com/acme/python-build:3.13"

      {_, "rust"} ->
        "registry.example.com/acme/rust-build:1.90"

      {_, "terraform"} ->
        "registry.example.com/acme/terraform:1.13"

      {_, "php"} ->
        "registry.example.com/acme/php-build:8.4"
    end
  end

  # The workspace observed until fifty days ago and enforces since; a few repositories
  # keep a mode of their own.
  defp mode(%{repository: %{path: "acme/shop", system: "codeberg.org"}}), do: "observe"
  defp mode(%{repository: %{path: "growth/" <> _}}), do: "observe"
  defp mode(%{days_ago: days_ago}) when days_ago > 50, do: "observe"
  defp mode(_spec), do: "enforce"

  defp policy_applied(spec, mode) do
    managed = spec.days_ago <= 50
    allow = @allowed |> Map.values() |> Enum.uniq() |> Enum.sort()
    epoch = if managed, do: div(spec.days_ago, 9), else: 99

    %{
      "mode" => mode,
      "allow" => allow,
      "deny" => [@locked_deny],
      "source" => if(managed, do: "fetched", else: "config"),
      "digest" => digest("policy#{epoch}#{mode}")
    }
    |> put_if(managed, "url", "#{ApiaryWeb.Endpoint.url()}/v1/run-configuration")
    |> put_if(managed, "run_configuration", "sha256=" <> digest("configuration#{epoch}"))
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp banner(spec, mode) do
    wall =
      if spec.machine.wall,
        do: dim("qory: wall #{spec.machine.wall}, image #{image(spec)}"),
        else: dim("qory: no wall; the session runs on the host")

    wall <> dim("qory: policy #{mode}, #{map_size(@allowed)} allow entries, 1 locked deny")
  end

  ## The work

  defp work(acc, %{runtime: :program} = spec, mode, ends) do
    {command, args} = command(spec)

    acc
    |> log(400, spec, "$ #{Enum.join([command | args], " ")}\n")
    |> fetch(1_000, spec, mode)
    |> test_output(max(ends - 3_000, 2_000), spec, spec.outcome != :failed)
    |> long_output(ends - 1_000, spec)
  end

  defp work(acc, %{runtime: "codex"} = spec, mode, ends) do
    acc
    |> log(
      600,
      spec,
      "OpenAI Codex v#{runtime_version(spec)}\n--------\nworkdir: /work/#{workdir(spec)}\n--------\n#{bold("user")}\n#{spec.prompt}\n\n"
    )
    |> egress(900, spec, mode, "api.llm.example", 443)
    |> steps(spec, mode, ends, :codex)
    |> long_output(ends - 2_000, spec)
    |> then(
      &if(spec.outcome == :succeeded,
        do:
          log(
            &1,
            ends - 1_500,
            spec,
            "#{bold("codex")}\nDone: the change is on the branch and the tests pass.\n"
          ),
        else: &1
      )
    )
  end

  defp work(acc, spec, mode, ends) do
    session = Ecto.UUID.generate()

    model =
      if spec.days_ago > 60,
        do: "claude-sonnet-4-5",
        else: pick(["claude-sonnet-5", "claude-opus-5"])

    acc
    |> put(800, "session.started", %{
      "session_id" => session,
      "source" => "startup",
      "model" => model,
      "cwd" => "/work/#{workdir(spec)}"
    })
    |> put(1_000, "session.prompt_submitted", %{"session_id" => session, "prompt" => spec.prompt})
    |> log(1_000, spec, "#{bold(cyan(">"))} #{spec.prompt}\n")
    |> egress(1_100, spec, mode, "api.llm.example", 443)
    |> then(
      &if(spec.runtime == "claude" and chance(0.12),
        do: egress(&1, 1_300, spec, mode, @locked_deny, 443),
        else: &1
      )
    )
    |> steps(spec, mode, ends, {:claude, session})
    |> long_output(ends - 3_000, spec)
    |> session_end(spec, session, ends)
  end

  defp session_end(acc, %{outcome: outcome}, _session, _ends)
       when outcome in [:lost, :closed, :alive, :timed_out],
       do: acc

  defp session_end(acc, spec, session, ends) do
    ok = spec.outcome == :succeeded

    summary =
      if ok,
        do: "Done. #{sentence(spec)} The tests pass.",
        else: "I could not finish: the last test run still fails. #{sentence(spec)}"

    acc
    |> put(ends - 2_000, "session.turn_finished", %{"session_id" => session, "message" => summary})
    |> log(ends - 2_000, spec, "\n#{summary}\n")
    |> put(ends - 800, "session.result", %{
      "session_id" => session,
      "outcome" => if(ok, do: "success", else: "error"),
      "is_error" => not ok,
      "turns" => between(3, 40),
      "duration_ms" => ends - 1_000,
      "cost_usd" => lognormal(0.45, 0.9) |> max(0.02) |> min(9.0) |> Float.round(4),
      "result" => summary
    })
    |> put(ends - 300, "session.ended", %{"session_id" => session, "reason" => "other"})
  end

  defp sentence(%{task: "issue-" <> number}),
    do: "Issue ##{number} is addressed on the branch qory/issue-#{number}."

  defp sentence(%{task: nil}), do: "Nothing was pushed."
  defp sentence(%{task: task}), do: "The #{task} change is on its branch."

  # The agent's steps between its prompt and its end: tools, some in subagents, some that
  # reach out, the tests run on the way and last.
  defp steps(acc, spec, mode, ends, how) do
    count = min(between(3, 12), div(ends, 15_000) + 2)
    times = for _ <- 1..count, do: 3_000 + :rand.uniform(max(round(ends * 0.85) - 3_000, 1))
    subagent = chance(0.15) and match?({:claude, _}, how)

    acc =
      times
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {at, i}, acc ->
        if subagent and i == 1,
          do: subagents(acc, spec, mode, at, how),
          else: step(acc, spec, mode, at, how, nil)
      end)

    final = max(round(ends * 0.9), 2_500)
    pass = spec.outcome not in [:failed, :timed_out]

    if spec.outcome in [:lost, :closed, :alive],
      do: acc,
      else:
        tool(
          acc,
          spec,
          final,
          how,
          nil,
          "Bash",
          test_input(spec),
          fn acc, at -> test_output(acc, at, spec, pass) end,
          pass
        )
  end

  defp step(acc, spec, mode, at, how, agent) do
    case weighted([
           {"Read", 30},
           {"Grep", 12},
           {"Glob", 6},
           {"Edit", 18},
           {"Bash", 26},
           {"Write", 4},
           {"WebFetch", 4}
         ]) do
      "Bash" ->
        case weighted([{:test, 5}, {:install, 3}, {:git, 2}]) do
          :test ->
            tool(
              acc,
              spec,
              at,
              how,
              agent,
              "Bash",
              test_input(spec),
              fn acc, at -> test_output(acc, at, spec, chance(0.6)) end,
              true
            )

          :install ->
            registry = registry(spec)
            host = if chance(0.2), do: pick(@noise), else: registry
            denied = decision(spec, mode, host) |> elem(0) == "denied"

            tool(
              acc,
              spec,
              at,
              how,
              agent,
              "Bash",
              %{
                "command" => install_command(spec, host),
                "description" => "Install a dependency"
              },
              fn acc, at -> egress(acc, at, spec, mode, host, 443) end,
              not denied
            )

          :git ->
            tool(
              acc,
              spec,
              at,
              how,
              agent,
              "Bash",
              %{
                "command" => "git fetch origin main && git diff --stat origin/main",
                "description" => "Compare with main"
              },
              fn acc, at -> fetch(acc, at, spec, mode) end,
              true
            )
        end

      "WebFetch" ->
        host =
          if chance(0.3),
            do: "api.#{pick(@vendors)}.example",
            else: pick(~w(docs.example.dev developer.mozilla.example pkg.go.example))

        denied = decision(spec, mode, host) |> elem(0) == "denied"

        tool(
          acc,
          spec,
          at,
          how,
          agent,
          "WebFetch",
          %{"url" => "https://#{host}/docs", "prompt" => "What does this say about retries?"},
          fn acc, at -> egress(acc, at, spec, mode, host, 443) end,
          not denied
        )

      name ->
        tool(
          acc,
          spec,
          at,
          how,
          agent,
          name,
          tool_input(name, spec),
          fn acc, _at -> acc end,
          true
        )
    end
  end

  defp subagents(acc, spec, mode, at, {:claude, session} = how) do
    kinds =
      Enum.take(
        Enum.shuffle([
          {"Explore", "Find where this is used"},
          {"general-purpose", "Write the fix and its test"}
        ]),
        between(1, 2)
      )

    kinds
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {{type, description}, i}, acc ->
      id = "agent-#{spec.index}-#{i}"
      start = at + i * 400
      span = between(20_000, 90_000)

      acc =
        acc
        |> put(start, "session.tool_started", %{
          "session_id" => session,
          "tool" => "Task",
          "tool_use_id" => tool_id(spec, start),
          "input" => %{
            "description" => description,
            "subagent_type" => type,
            "prompt" => description <> "."
          }
        })
        |> log(start, spec, "#{cyan("●")} Task(#{type}: #{String.downcase(description)})\n")
        |> put(start + 200, "session.subagent_started", %{
          "session_id" => session,
          "agent_id" => id,
          "agent_type" => type
        })

      acc =
        Enum.reduce(1..between(2, 4), acc, fn k, acc ->
          step(acc, spec, mode, start + div(span * k, 5), how, {id, type})
        end)

      acc
      |> put(start + span, "session.subagent_finished", %{
        "session_id" => session,
        "agent_id" => id,
        "agent_type" => type,
        "message" => "#{description}: done.",
        "background_tasks" => []
      })
      |> put(start + span + 100, "session.tool_finished", %{
        "session_id" => session,
        "tool" => "Task",
        "tool_use_id" => tool_id(spec, start),
        "input" => %{"description" => description, "subagent_type" => type},
        "response" => %{"status" => "completed"},
        "duration_ms" => span + 100
      })
    end)
  end

  # One tool call: its start, what it does to the terminal and the network meanwhile, and
  # its end, failed or finished. Codex has no session hooks: only the terminal shows it.
  defp tool(acc, spec, at, how, agent, name, input, effect, ok) do
    took = if name == "Bash", do: between(1_500, 40_000), else: between(80, 2_500)
    line = "#{cyan("●")} #{name}(#{describe(name, input)})\n"

    case how do
      :codex ->
        acc
        |> log(at, spec, "#{bold("exec")} #{describe(name, input)}\n")
        |> effect.(at + 200)

      {:claude, session} ->
        id = tool_id(spec, at)
        base = %{"session_id" => session, "tool" => name, "tool_use_id" => id, "input" => input}

        base =
          if agent,
            do: Map.merge(base, %{"agent_id" => elem(agent, 0), "agent_type" => elem(agent, 1)}),
            else: base

        acc
        |> put(at, "session.tool_started", base)
        |> log(at, spec, line)
        |> effect.(at + 200)
        |> put(
          at + took,
          if(ok, do: "session.tool_finished", else: "session.tool_failed"),
          if(ok,
            do: Map.merge(base, %{"response" => %{"ok" => true}, "duration_ms" => took}),
            else:
              Map.merge(base, %{
                "error" => "Exit code 1\nthe request was refused by the wall",
                "duration_ms" => took
              })
          )
        )
    end
  end

  defp tool_id(spec, at), do: "toolu_demo_#{spec.index}_#{at}"

  defp describe("Bash", %{"command" => command}), do: command
  defp describe("WebFetch", %{"url" => url}), do: url
  defp describe(_name, %{"file_path" => path}), do: path
  defp describe(_name, %{"pattern" => pattern}), do: pattern
  defp describe(_name, _input), do: ""

  defp tool_input(name, spec) do
    file = "/work/#{workdir(spec)}/#{pick(files(flavour_of(spec)))}"

    case name do
      "Read" ->
        %{"file_path" => file}

      "Grep" ->
        %{
          "pattern" => pick(~w(total retry cursor session_id discount timeout locale)),
          "path" => "/work/#{workdir(spec)}"
        }

      "Glob" ->
        %{"pattern" => pick(~w(**/*_test.go src/**/*.ts tests/**/*.py src/**/*.rs **/*.tf))}

      "Edit" ->
        %{
          "file_path" => file,
          "old_string" => "return total",
          "new_string" => "return round(total)"
        }

      "Write" ->
        %{"file_path" => file, "content" => "// generated\n"}
    end
  end

  defp files("node"),
    do:
      ~w(package.json src/cart/store.ts src/checkout/CheckoutForm.tsx src/api/client.ts src/utils/money.ts test/cart.test.ts)

  defp files("go"),
    do:
      ~w(go.mod internal/checkout/totals.go internal/orders/service.go cmd/api/main.go internal/http/retry.go)

  defp files("python"),
    do:
      ~w(pyproject.toml pipelines/daily.py src/features/build.py tests/test_pipeline.py src/io/partner_feed.py)

  defp files("rust"),
    do: ~w(Cargo.toml src/lib.rs src/parser.rs src/runtime/mod.rs tests/parse.rs)

  defp files("terraform"),
    do: ~w(main.tf variables.tf modules/vpc/main.tf envs/prod/main.tf modules/nat/outputs.tf)

  defp files("php"),
    do:
      ~w(composer.json src/Controller/CartController.php src/Service/Pricing.php tests/CartTest.php)

  defp test_input(spec) do
    {command, args} =
      case flavour_of(spec) do
        "node" -> {"npm", ["test"]}
        "go" -> {"go", ["test", "./..."]}
        "python" -> {"pytest", ["-q"]}
        "rust" -> {"cargo", ["test"]}
        "terraform" -> {"terraform", ["plan"]}
        "php" -> {"composer", ["test"]}
      end

    %{"command" => Enum.join([command | args], " "), "description" => "Run the tests"}
  end

  defp registry(spec) do
    case flavour_of(spec) do
      "node" -> pick(["packages.example.com", "cdn.packages.example.com", "registry.example"])
      "go" -> pick(["proxy.golang.example", "sum.golang.example"])
      "python" -> pick(["pypi.example", "files.pypi.example", "huggingface.example"])
      "rust" -> pick(["crates.example", "static.crates.example"])
      "terraform" -> pick(["registry.terraform.example", "releases.hashicorp.example"])
      "php" -> "repo.packagist.example"
    end
  end

  defp install_command(spec, host) do
    case flavour_of(spec) do
      "node" -> "npm install @acme/ui-steps --registry https://#{host}"
      "go" -> "go get github.com/acme/money@v1.9.0"
      "python" -> "pip install --index-url https://#{host}/simple polars==1.9"
      "rust" -> "cargo add serde_json"
      "terraform" -> "terraform init -upgrade"
      "php" -> "composer require symfony/http-client"
    end
  end

  # The fetch every run starts its work with: the forge, and the language's registries.
  defp fetch(acc, at, spec, mode) do
    forge = (spec.repository && spec.repository.system) || "github.com"

    acc
    |> egress(at, spec, mode, forge, 443)
    |> egress(at + 400, spec, mode, registry(spec), 443)
    |> then(
      &if(flavour_of(spec) == "go",
        do: egress(&1, at + 600, spec, mode, "sum.golang.example", 443),
        else: &1
      )
    )
    |> then(
      &if(chance(0.08),
        do: egress(&1, at + 900, spec, mode, pick(@noise), pick([443, 80])),
        else: &1
      )
    )
    |> then(
      &if(chance(0.03),
        do: egress(&1, at + 1_100, spec, mode, "api.#{pick(@vendors)}.example", 443),
        else: &1
      )
    )
  end

  defp egress(acc, at, spec, mode, host, port) do
    {decision, outcome, rule} = decision(spec, mode, host)

    data = %{
      "host" => host,
      "port" => port,
      "method" => if(port == 80, do: "HTTP", else: "CONNECT"),
      "decision" => decision,
      "outcome" => outcome,
      "mode" => mode,
      "rule" => rule
    }

    acc = put(acc, at, "run.egress", data)

    if decision == "denied",
      do:
        log(
          acc,
          at + 1,
          spec,
          dim(
            "qory: denied #{host}:#{port} (#{if rule == "", do: "no allow entry", else: "deny #{rule}"})"
          )
        ),
      else: acc
  end

  defp decision(_spec, _mode, @locked_deny), do: {"denied", "refused", @locked_deny}

  defp decision(_spec, mode, host) do
    case @allowed do
      %{^host => rule} -> {"allowed", "connected", rule}
      _ when mode == "enforce" -> {"denied", "refused", ""}
      _ -> {"allowed", "connected", ""}
    end
  end

  defp heartbeats(acc, ends) do
    Enum.reduce(1..div(ends, 30_000)//1, acc, fn k, acc ->
      put(acc, k * 30_000, "run.heartbeat", %{
        "elapsed_seconds" => k * 30,
        "interval_seconds" => 30
      })
    end)
  end

  defp finish(acc, %{outcome: outcome}, _ends) when outcome in [:lost, :closed, :alive], do: acc

  defp finish(acc, %{outcome: :timed_out} = spec, ends) do
    acc
    |> log(ends - 5, spec, dim("qory: run timed out after 1 h"))
    |> put(ends, "run.exited", %{
      "state" => "failed",
      "exit_code" => -1,
      "reason" => "timeout",
      "duration_ms" => ends
    })
  end

  defp finish(acc, spec, ends) do
    code = if spec.outcome == :succeeded, do: 0, else: pick([1, 1, 2])
    state = if code == 0, do: "succeeded", else: "failed"

    acc
    |> log(ends - 5, spec, dim("qory: run exited #{code} after #{human(ends)}"))
    |> put(ends, "run.exited", %{"state" => state, "exit_code" => code, "duration_ms" => ends})
  end

  defp human(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp human(ms), do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"

  ## The terminal

  defp log(acc, at, spec, text) do
    stream = if spec.interactive, do: "terminal", else: pick_stream(text)
    text = if stream == "terminal", do: String.replace(text, "\n", "\r\n"), else: text
    size = if byte_size(text) > 50_000, do: @long_log_bytes, else: @log_bytes

    text
    |> slices(size)
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {part, i}, acc ->
      put(acc, at + i, "run.log", %{"stream" => stream, "bytes" => Base.encode64(part)})
    end)
  end

  defp pick_stream("\e[2mqory:" <> _), do: "stderr"
  defp pick_stream(_text), do: "stdout"

  defp slices(text, size) when byte_size(text) <= size, do: [text]

  defp slices(text, size) do
    <<part::binary-size(^size), rest::binary>> = text
    [part | slices(rest, size)]
  end

  defp test_output(acc, at, spec, pass) do
    names = Enum.map(1..between(4, 14), fn _ -> test_name() end)
    failing = if pass, do: nil, else: pick(names)
    log(acc, at, spec, test_text(flavour_of(spec), names, failing, workdir(spec)))
  end

  # One run in two hundred writes a verbose suite of tens of thousands of lines.
  defp long_output(acc, _at, %{long: false}), do: acc

  defp long_output(acc, at, spec) do
    lines = between(5_000, 40_000)

    text =
      Enum.map_join(1..lines, fn i ->
        "  #{green("✓")} #{test_name()} #{dim_inline("(#{rem(i * 7, 90) + 1} ms)")}\n"
      end)

    log(acc, max(at, 2_000), spec, "\n#{bold("Verbose suite")} #{lines} tests\n" <> text)
  end

  defp test_name do
    "#{pick(~w(cart checkout totals orders retry session search export invoice parser import tax refund))} #{pick(~w(handles rejects keeps rounds formats skips retries reports))} #{pick(~w(an\ empty\ basket a\ discount the\ last\ page a\ timeout two\ currencies a\ long\ address a\ missing\ field a\ replay))}"
  end

  defp test_text("node", names, failing, dir) do
    rows =
      Enum.map_join(names, fn name ->
        if name == failing,
          do: " #{red("✗")} #{name} #{dim_inline("#{between(5, 300)}ms")}\n",
          else: " #{green("✓")} #{name} #{dim_inline("#{between(5, 300)}ms")}\n"
      end)

    summary =
      if failing,
        do:
          "#{dim_inline("      Tests")} #{bold(red("1 failed"))} | #{bold(green("#{length(names) - 1} passed"))} (#{length(names)})\n",
        else:
          "#{dim_inline("      Tests")} #{bold(green("#{length(names)} passed"))} (#{length(names)})\n"

    "\n#{bold(" RUN ")} #{cyan("v3.2.4")} #{dim_inline("/work/#{dir}")}\n\n" <>
      rows <> "\n" <> summary
  end

  defp test_text("go", names, failing, dir) do
    Enum.map_join(names, fn name ->
      package = "github.com/acme/#{dir}/internal/#{name |> String.split() |> hd()}"

      if name == failing,
        do:
          "--- FAIL: Test#{Macro.camelize(String.replace(name, " ", "_"))} (0.02s)\n    want 4275, got 4318\n#{red("FAIL")}\t#{package}\t#{between(1, 4)}.#{between(100, 999)}s\n",
        else: "#{green("ok")}  \t#{package}\t#{between(0, 3)}.#{between(100, 999)}s\n"
    end)
  end

  defp test_text("python", _names, failing, _dir) do
    dots = String.duplicate(".", between(40, 300))

    if failing,
      do:
        "#{dots}#{red("F")}#{dots}\n#{red("FAILED")} tests/test_pipeline.py::test_#{String.replace(failing, " ", "_")}\n#{red("1 failed")}, #{green("#{byte_size(dots) * 2} passed")} in #{between(2, 60)}.#{between(10, 99)}s\n",
      else:
        "#{dots}#{dots}\n#{green("#{byte_size(dots) * 2} passed")} in #{between(2, 60)}.#{between(10, 99)}s\n"
  end

  defp test_text("rust", names, failing, _dir) do
    rows =
      Enum.map_join(names, fn name ->
        "test #{String.replace(name, " ", "::")} ... #{if name == failing, do: red("FAILED"), else: green("ok")}\n"
      end)

    result = if failing, do: red("FAILED"), else: green("ok")

    rows <>
      "\ntest result: #{result}. #{length(names) - if(failing, do: 1, else: 0)} passed; #{if failing, do: 1, else: 0} failed\n"
  end

  defp test_text("terraform", _names, failing, _dir) do
    if failing,
      do: "#{red("Error:")} Provider produced inconsistent final plan\n",
      else: "Plan: #{between(0, 6)} to add, #{between(0, 4)} to change, 0 to destroy.\n"
  end

  defp test_text("php", names, failing, _dir) do
    if failing,
      do:
        "PHPUnit 11.4\n\n#{String.duplicate(".", length(names) * 4)}#{red("F")}\n\n#{red("FAILURES!")}\nTests: #{length(names) * 4}, Failures: 1.\n",
      else:
        "PHPUnit 11.4\n\n#{String.duplicate(".", length(names) * 4)}\n\n#{green("OK (#{length(names) * 4} tests)")}\n"
  end

  defp dim(text), do: "\e[2m#{text}\e[0m\n"
  defp dim_inline(text), do: "\e[2m#{text}\e[0m"
  defp bold(text), do: "\e[1m#{text}\e[0m"
  defp cyan(text), do: "\e[36m#{text}\e[0m"
  defp green(text), do: "\e[32m#{text}\e[0m"
  defp red(text), do: "\e[31m#{text}\e[0m"

  ## After the writing

  # What the record implies beyond the runs: the lost ones found, some closed by a member,
  # the repositories dated by their first run, the keys by their last delivery, the hosts
  # recorded as instances of their nodes; a second key added to ci-fleet, as when a key is
  # replaced, and the legacy machine's key revoked.
  defp settle(ctx, plan) do
    %Scope{workspace: workspace} = scope = ctx.scope
    Liveness.check(DateTime.utc_now())

    closable =
      Repo.all(
        from r in Run,
          where: r.workspace_id == ^workspace.id and r.state in ["running", "lost"],
          where: r.inserted_at < ^DateTime.add(ctx.now, -1, :hour),
          select: r
      )

    closers = closers(scope)

    share =
      Enum.count(plan, &(&1.outcome == :closed)) /
        max(Enum.count(plan, &(&1.outcome in [:lost, :closed])), 1)

    closed =
      closable
      |> Enum.filter(fn _run -> :rand.uniform() < share end)
      |> Enum.count(fn run -> match?({:ok, _}, Runs.close_run(pick(closers), run)) end)

    Repo.update_all(
      from(t in Target,
        where: t.workspace_id == ^workspace.id,
        update: [
          set: [
            first_seen_at:
              fragment(
                "LEAST(?, (SELECT min(COALESCE(r.started_at, r.inserted_at)) FROM runs r WHERE r.target_id = ?))",
                t.first_seen_at,
                t.id
              )
          ]
        ]
      ),
      []
    )

    for {label, key} <- ctx.keys, label != @idle_key do
      last =
        Repo.one(
          from r in Run,
            where: r.access_key_id == ^key.id,
            order_by: [desc: r.last_event_at],
            limit: 1,
            select: {r.last_event_at, r.runner_version}
        )

      with {at, version} <- last do
        AccessKeys.touch_delivery(key, %{
          last_used_at: at,
          last_runner_version: version,
          last_contract_version: 1,
          last_heartbeat_at: at
        })
      end
    end

    instances(workspace)

    # A second key beside ci-fleet's, once: a pool holds two approved keys at most.
    fleet = Map.fetch!(ctx.keys, "ci-fleet")

    if length(Enum.reject(AccessKeys.list_for_node(scope, fleet.node), & &1.revoked_at)) < 2,
      do: add_key!(scope, fleet.node, "ci-fleet-next")

    {:ok, _key} = AccessKeys.revoke_access_key(scope, Map.fetch!(ctx.keys, "legacy-ci"))

    Mix.shell().info(
      "#{closed} silent runs closed; ci-fleet has a second key, legacy-ci's is revoked"
    )
  end

  # Each host a run named, an instance of the run's node: first and last seen at the
  # node's first and last run from it, as the receiver records the instances it hears
  # from. A host seen again in a later history keeps its first sighting.
  defp instances(workspace) do
    rows =
      Repo.all(
        from r in Run,
          where: r.workspace_id == ^workspace.id and not is_nil(r.node_id),
          where: not is_nil(r.instance_id) and not is_nil(r.host),
          group_by: [r.node_id, r.instance_id, r.host],
          select: %{
            node_id: r.node_id,
            instance_id: r.instance_id,
            name: r.host,
            first_seen_at: min(r.inserted_at),
            last_seen_at: max(r.last_event_at),
            access_key_id:
              type(
                fragment("(array_agg(? ORDER BY ? DESC))[1]", r.access_key_id, r.inserted_at),
                Ecto.UUID
              ),
            last_runner_version:
              fragment("(array_agg(? ORDER BY ? DESC))[1]", r.runner_version, r.inserted_at)
          }
      )

    now = DateTime.utc_now()

    entries =
      for row <- rows do
        Map.merge(row, %{
          id: Ecto.UUID.generate(),
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
          last_seen_at: row.last_seen_at || now,
          last_contract_version: 1
        })
      end

    Repo.insert_all(Instance, entries,
      on_conflict: {:replace, [:last_seen_at, :access_key_id, :last_runner_version]},
      conflict_target: [:node_id, :instance_id]
    )
  end

  # The owner, and the people who joined, as they would close a run from its page.
  defp closers(%Scope{organisation: organisation, workspace: workspace} = scope) do
    others =
      Repo.all(
        from m in Membership,
          join: u in assoc(m, :user),
          where:
            m.organisation_id == ^organisation.id and
              u.email in ^Enum.map(@people, &"#{elem(&1, 0)}@example.com"),
          select: u
      )
      |> Enum.map(&scope_of(&1, organisation, workspace))
      |> Enum.reject(&is_nil/1)

    [scope | others]
  end

  ## The policy

  defp policy(scope, keys) do
    Mix.Tasks.Apiary.Demo.policy(Map.fetch!(keys, "ci-fleet"))

    added =
      Enum.count(@baseline_hosts, fn host ->
        match?({:ok, _}, Policy.allow(scope, nil, %{host: host}))
      end)

    targets =
      Repo.all(from t in Target, where: t.workspace_id == ^scope.workspace.id, order_by: t.path)

    own =
      for target <- targets, reduce: 0 do
        count ->
          changes =
            cond do
              String.starts_with?(target.path, "growth/") ->
                [&Policy.set_mode(&1, target, "observe")]

              String.starts_with?(target.path, "ml/") ->
                [
                  &Policy.allow(&1, target, %{host: "huggingface.example"}),
                  &Policy.set_mode(&1, target, "enforce")
                ]

              String.starts_with?(target.path, "security/") ->
                [&Policy.deny(&1, target, %{host: "registry.example"})]

              true ->
                []
            end

          count + Enum.count(changes, &match?({:ok, _}, &1.(scope)))
      end

    Mix.shell().info("Policy: #{added} baseline hosts added, #{own} changes to repositories")
  end

  ## Chance

  defp chance(p), do: :rand.uniform() < p
  defp between(low, high), do: low + :rand.uniform(high - low + 1) - 1
  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)
  defp lognormal(median, sigma), do: median * :math.exp(sigma * :rand.normal())
  defp clamp(value, low, high), do: value |> max(low) |> min(high) |> round()

  defp weighted(pairs) do
    total = Enum.reduce(pairs, 0, fn {_item, weight}, sum -> sum + weight end)
    roll = :rand.uniform() * total

    # The items may be numbers themselves: the pick is tagged, so a roll that runs past
    # the last weight by a rounding error is told from a pick.
    Enum.reduce_while(pairs, roll, fn {item, weight}, left ->
      if left <= weight, do: {:halt, {:picked, item}}, else: {:cont, left - weight}
    end)
    |> case do
      {:picked, item} -> item
      _left -> pairs |> List.last() |> elem(0)
    end
  end
end
