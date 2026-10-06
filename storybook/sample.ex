defmodule ApiaryWeb.Storybook.Sample do
  @moduledoc """
  The data the component storybook's stories draw (`ApiaryWeb.Storybook`): neutral and
  synthetic, an organisation `acme` with a workspace `shop`, hosts under `example.com`
  and `git.example.com`, people by short name. Built in the shapes the pages build, so a
  story renders the real component the page renders.
  """
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}

  @doc "The scope of a page of the workspace acme/shop, for the components that build links."
  @spec scope() :: Scope.t()
  def scope do
    %Scope{
      organisation: %Organisation{name: "Acme", slug: "acme"},
      workspace: %Workspace{name: "shop", slug: "shop"}
    }
  end

  @doc """
  Host rules of the workspace's policy, as `ApiaryWeb.PolicyLive.Common.workspace_rules/3`
  builds them for `ApiaryWeb.PolicyComponents.rule_line/1`: allowed with paths and
  without, denied, locked, and one not in force.
  """
  @spec rules() :: [map()]
  def rules do
    [
      rule("r1", "deny", "*.tracking.example.com", nil,
        locked: true,
        by: "dana",
        at: ~U[2026-07-02 09:12:00Z]
      ),
      rule("r2", "allow", "git.example.com", ["/acme/shop/**", "/acme/shared-ui/**"],
        locked: true,
        by: "dana",
        at: ~U[2026-08-19 14:40:00Z]
      ),
      rule("r3", "deny", "paste.example.com", nil, by: "lee", at: ~U[2026-09-03 11:05:00Z]),
      rule("r4", "allow", "registry.example.com", nil, by: "lee", at: ~U[2026-09-10 08:30:00Z]),
      rule("r5", "allow", "api.example.com", ["/v2/orders", "/v2/stock/*"],
        by: "dana",
        at: ~U[2026-09-21 16:02:00Z]
      ),
      rule("r6", "allow", "cdn.tracking.example.com", nil,
        in_force: false,
        off: "Not in force: shop's locked *.tracking.example.com holds",
        by: "sam",
        at: ~U[2026-09-28 10:18:00Z]
      )
    ]
  end

  @doc "The use of `rules/0` in the last 14 days, as `Apiary.Policy.rule_activity/3` counts it."
  @spec activity() :: %{String.t() => %{allowed: non_neg_integer(), denied: non_neg_integer()}}
  def activity do
    %{
      "r1" => %{allowed: 0, denied: 37},
      "r2" => %{allowed: 1_284, denied: 0},
      "r3" => %{allowed: 0, denied: 2},
      "r4" => %{allowed: 412, denied: 0},
      "r5" => %{allowed: 96, denied: 3}
    }
  end

  defp rule(id, action, host, paths, opts) do
    %{
      id: id,
      action: action,
      host: host,
      paths: paths,
      locked: Keyword.get(opts, :locked, false),
      source: %{key: "shop", label: "shop", rank: 2},
      own: true,
      in_force: Keyword.get(opts, :in_force, true),
      off: Keyword.get(opts, :off),
      by: Keyword.get(opts, :by),
      at: Keyword.get(opts, :at),
      locked_tip: "Locked: only an owner changes it, and a target cannot override it.",
      can_change: true,
      act: :remove,
      view: nil
    }
  end

  @doc """
  Runs of the workspace, as the runs list holds them (`ApiaryWeb.RunComponents.runs_table/1`):
  running, succeeded, failed with denials, and pending. Their times are this minute's.
  """
  @spec runs() :: [map()]
  def runs do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    [
      run(1, "running", "Add stock levels to the order page", now, -240,
        elapsed_seconds: 236,
        last_heartbeat_at: DateTime.add(now, -4)
      ),
      run(2, "succeeded", "Fix the rounding of order totals", now, -3_600,
        duration_ms: 1_122_000
      ),
      run(3, "failed", "Upgrade the payment client", now, -9_000,
        duration_ms: 431_000,
        denied_count: 3
      ),
      run(4, "pending", nil, now, -20, [])
    ]
  end

  defp run(n, state, task, now, offset, opts) do
    at = DateTime.add(now, offset)

    Map.merge(
      %{
        id: n,
        run_id: "8f3c2a#{n}e0-5b1d-4c7e-9a10-2f6d0c4b7e1#{n}",
        state: state,
        task: task,
        target_system: "git.example.com",
        target_path: if(rem(n, 2) == 0, do: "acme/shared-ui", else: "acme/shop"),
        runtime: "claude",
        runtime_version: "2.4.1",
        host: "build-0#{n}",
        started_at: at,
        inserted_at: at,
        closed_at: nil,
        duration_ms: nil,
        elapsed_seconds: nil,
        last_heartbeat_at: nil,
        heartbeat_interval_seconds: 30,
        denied_count: 0
      },
      Map.new(opts)
    )
  end

  @doc """
  The integrations of the workspace, as the mock-ups of Settings › Integrations draw them
  (`storybook/screens/`): a proposal, so no context builds them yet. Each has its source
  (`nil` for one built in, an LLM provider or a service that ships inside Apiary; else the
  release it was added from: the forge, the publisher's repository, the version it was added
  at and the latest), its roles, the ways it connects (`:api`, `:mcp` or both), and the settings it declares, each
  plain, with its value, or secret, linked to a workspace secret by its name, and by a value
  ID when that secret holds several values, or `nil` while it needs one.
  """
  @spec integrations() :: [map()]
  def integrations do
    [
      integration(
        "github",
        "GitHub",
        release(:github, "qoryai/qory-github", "0.1.0", latest: "0.1.0"),
        [:task_source, :output, :service],
        [:api, :mcp],
        about:
          "Reads issues as tasks, opens a change request with what a run did, and gives each run a token for the repositories it works on.",
        settings: [
          setting("app_id", "App ID", "104231"),
          setting("base_url", "API base URL", "https://api.github.com",
            hint: "Another for GitHub Enterprise Server."
          ),
          secret(
            "private_key",
            "The GitHub App's private key.",
            "GITHUB_APP_PRIVATE_KEY",
            "main-app"
          ),
          secret(
            "webhook_secret",
            "Checks that an event came from GitHub.",
            "GITHUB_WEBHOOK_SECRET"
          ),
          setting("branch_prefix", "Branch prefix", "qory/",
            hint: "A run's branch starts with it."
          ),
          setting("drafts", "Open change requests as drafts", true, type: "checkbox")
        ],
        targets: 12,
        added: "dana, 2 Sept 2026"
      ),
      integration("anthropic", "Anthropic", nil, [:llm_provider], [:api],
        about: "Claude models, for the runs whose runtime asks for them.",
        settings: [
          secret("api_key", "An API key of the Anthropic console.", "ANTHROPIC_API_KEY"),
          setting("base_url", "API base URL", "https://api.anthropic.com"),
          setting("budget", "Tokens a run may use", "2,000,000")
        ],
        targets: 9,
        added: "dana, 2 Sept 2026"
      ),
      integration("openai", "OpenAI", nil, [:llm_provider], [:api],
        about: "OpenAI's models, for the runs whose runtime asks for them.",
        settings: [
          secret("api_key", "A project API key.", "OPENAI_API_KEY"),
          setting("base_url", "API base URL", "https://api.openai.com/v1"),
          setting("project", "Project", "proj_shop")
        ],
        targets: 3,
        added: "lee, 9 Sept 2026"
      ),
      integration(
        "model_gateway",
        "Model gateway",
        release(:github, "acme/qory-model-gateway", "0.4.0"),
        [:llm_provider, :service],
        [:api],
        about:
          "The workspace's own gateway to self-hosted models, and the cache runs read its weights from.",
        settings: [
          secret("gateway_key", "The gateway's client key.", "GATEWAY_KEY"),
          setting("base_url", "Gateway URL", "https://models.example.com/v1"),
          setting("model", "Default model", "gateway-default")
        ],
        targets: 2,
        added: "sam, 21 Sept 2026"
      ),
      integration(
        "jira",
        "Jira",
        release(:github, "acme/qory-jira", "1.4.0"),
        [:task_source],
        [:api],
        about:
          "Takes the issues of a project, by a filter, as tasks, and comments on each when its run ends.",
        settings: [
          secret("api_token", "An API token of a Jira account.", "JIRA_API_TOKEN"),
          setting("site", "Site URL", "https://acme.example.com"),
          setting("project", "Project key", "SHOP"),
          setting("filter", "Filter", "labels = qory AND status = \"To do\"",
            hint: "Only the issues it finds become tasks."
          )
        ],
        targets: 4,
        added: "lee, 14 Sept 2026"
      ),
      integration(
        "slack",
        "Slack",
        release(:github, "acme/qory-slack", "0.9.2"),
        [:output],
        [:api],
        about:
          "Posts a line to a channel when a run ends, with its state and its change request.",
        settings: [
          secret(
            "signing_secret",
            "Checks that a button press came from Slack.",
            "SLACK_SIGNING_SECRET"
          ),
          secret("bot_token", "The bot token of the workspace's Slack app.", nil),
          setting("channel", "Channel", "#shop-builds"),
          setting("only_bad", "Only runs that ended badly", false, type: "checkbox")
        ],
        targets: 0,
        added: "sam, 30 Sept 2026"
      ),
      integration(
        "webhook",
        "Webhook",
        release(:gitlab, "acme/tools/qory-webhook", "1.1.0"),
        [:output],
        [:api],
        about: "Posts each run's summary as JSON to a URL, signed with a shared secret.",
        settings: [
          secret("signing_secret", "Signs each request's body.", "WEBHOOK_SIGNING_SECRET"),
          setting("url", "URL", "https://hooks.example.com/qory")
        ],
        targets: 5,
        added: "dana, 3 Sept 2026"
      ),
      integration(
        "internal_api",
        "Internal API",
        release(:forgejo, "acme/qory-internal-api", "2.1.0", host: "git.example.com"),
        [:service],
        [:api, :mcp],
        about: "Gives a run a short-lived token for the shop's internal API, scoped to read.",
        settings: [
          secret("client_secret", "The API's client secret.", "INTERNAL_API_SECRET"),
          setting("base_url", "Base URL", "https://internal.example.com/api"),
          setting("scope", "Scope", "orders:read stock:read")
        ],
        targets: 6,
        added: "lee, 18 Sept 2026"
      ),
      integration("registry", "Package registry", nil, [:service], [:api],
        about: "Lets a run install the workspace's private packages, read only.",
        settings: [
          secret("token", "A read token of the registry.", "REGISTRY_TOKEN"),
          setting("url", "Registry URL", "https://registry.example.com"),
          setting("scope", "Package scope", "@acme")
        ],
        targets: 11,
        added: "dana, 2 Sept 2026"
      ),
      integration(
        "docs_search",
        "Docs search",
        release(:github, "acme/qory-docs-search", "0.3.1"),
        [:tool],
        [:mcp],
        about:
          "Searches the shop's own documentation, a tool the agent of a run calls as it works.",
        settings: [
          secret("api_token", "A read token of the documentation's index.", "DOCS_SEARCH_TOKEN"),
          setting("index_url", "Index URL", "https://docs.example.com/search"),
          setting("results", "Results per search", "8")
        ],
        targets: 7,
        added: "sam, 24 Sept 2026"
      )
    ]
  end

  defp integration(id, name, source, roles, ways, opts) do
    Map.merge(%{id: id, name: name, source: source, roles: roles, ways: ways}, Map.new(opts))
  end

  # A release on `forge` (`:github`, `:gitlab` or `:forgejo`, whose server is `host`) of the
  # repository `repo`, its publisher the owner, added at `version`. Its latest is the next
  # minor unless `latest` says otherwise.
  defp release(forge, repo, version, opts \\ []) do
    [publisher | _] = String.split(repo, "/")
    [major, minor | _] = String.split(version, ".")

    %{
      forge: forge,
      host: Keyword.get(opts, :host),
      publisher: publisher,
      repo: repo,
      version: version,
      latest: Keyword.get(opts, :latest, "#{major}.#{String.to_integer(minor) + 1}.0")
    }
  end

  # A secret setting, linked to the workspace secret `linked`, to its value `value_id` when
  # it holds several, or to none.
  defp secret(id, about, linked, value_id \\ nil),
    do: %{id: id, kind: :secret, about: about, linked: linked, value_id: value_id}

  defp setting(id, label, value, opts \\ []) do
    %{
      id: id,
      kind: :plain,
      label: label,
      value: value,
      type: Keyword.get(opts, :type, "text"),
      hint: Keyword.get(opts, :hint)
    }
  end

  @doc """
  What can be added from Add integration › Built in: what ships inside Apiary, LLM providers
  and services, each with its roles, the ways it connects and whether the workspace has it
  already. Everything else comes from a release.
  """
  @spec built_in() :: [map()]
  def built_in do
    [
      built_in("anthropic", "Anthropic", [:llm_provider], [:api], true),
      built_in("openai", "OpenAI", [:llm_provider], [:api], true),
      built_in("registry", "Package registry", [:service], [:api], true),
      built_in("api_service", "API service", [:service], [:api], false)
    ]
  end

  defp built_in(id, name, roles, ways, added),
    do: %{id: id, name: name, roles: roles, ways: ways, added: added}

  @doc """
  What Add integration › From a release found in a release's `description.json`, as its
  preview shows it: the integration it describes, its version and publisher, the ways it
  connects, the settings it declares, secret and plain, and the file itself. The release is
  the same one wherever it is published: on GitHub as `repo`, on GitLab as `project`, on the
  Forgejo or Gitea server `host` as `repo`, or at `url`.
  """
  @spec described() :: map()
  def described do
    %{
      publisher: "acme",
      repo: "acme/qory-ticket-desk",
      project: "acme/tools/qory-ticket-desk",
      host: "git.example.com",
      url: "https://downloads.example.com/qory-ticket-desk/0.6.0/description.json",
      version: "0.6.0",
      name: "Ticket desk",
      roles: [:task_source, :output],
      ways: [:api, :mcp],
      about: "Takes the tickets of a queue as tasks, and replies on each with what its run did.",
      secrets: ["api_token"],
      settings: ["Base URL", "Queue"],
      json: """
      {
        "name": "Ticket desk",
        "version": "0.6.0",
        "roles": ["task_source", "output"],
        "connects": ["api", "mcp"],
        "settings": [
          {"name": "api_token", "label": "API token", "secret": true, "required": true},
          {"name": "base_url", "label": "Base URL", "type": "url"},
          {"name": "queue", "label": "Queue", "type": "string"}
        ]
      }
      """
    }
  end

  @doc """
  The integrations Add integration › From a release suggests: Qory's own, each on GitHub at
  its latest version, with what its `description.json` holds, in the shape of `described/0`.
  Choosing one fills its repository and version.
  """
  @spec suggested() :: [map()]
  def suggested do
    [
      %{
        id: "github",
        publisher: "qoryai",
        repo: "qoryai/qory-github",
        version: "0.1.0",
        name: "GitHub",
        roles: [:task_source, :output, :service],
        ways: [:api, :mcp],
        about:
          "Reads issues as tasks, opens a change request with what a run did, and gives each run a token for the repositories it works on.",
        secrets: ["private_key", "webhook_secret"],
        settings: ["App ID", "API base URL", "Branch prefix", "Open change requests as drafts"],
        json: """
        {
          "name": "GitHub",
          "version": "0.1.0",
          "roles": ["task_source", "output", "service"],
          "connects": ["api", "mcp"],
          "settings": [
            {"name": "app_id", "label": "App ID", "type": "string", "required": true},
            {"name": "base_url", "label": "API base URL", "type": "url"},
            {"name": "private_key", "label": "Private key", "secret": true, "required": true},
            {"name": "webhook_secret", "label": "Webhook secret", "secret": true},
            {"name": "branch_prefix", "label": "Branch prefix", "type": "string"},
            {"name": "drafts", "label": "Open change requests as drafts", "type": "boolean"}
          ]
        }
        """
      }
    ]
  end

  @doc """
  The workspace's secrets and variables, as Settings › Secrets and variables lists them. A
  secret is a name and one value, or several values, each under a value ID its maker named
  (`values`, `nil` for one), with the integrations that link it and, for one of several
  values, which. A variable is a name and a plain value at a level: the workspace, or one
  repository, whose value wins for that repository.
  """
  @spec workspace_secrets() :: %{secrets: [map()], variables: [map()]}
  def workspace_secrets do
    %{
      secrets: [
        secret_of("GITHUB_APP_PRIVATE_KEY", [{"github", "main-app"}], "2 Sept 2026",
          values: ["main-app", "bot-app"]
        ),
        secret_of("GITHUB_WEBHOOK_SECRET", [{"github", nil}], "2 Sept 2026"),
        secret_of("ANTHROPIC_API_KEY", [{"anthropic", nil}], "28 Sept 2026"),
        secret_of("OPENAI_API_KEY", [{"openai", nil}], "9 Sept 2026"),
        secret_of("GATEWAY_KEY", [{"model_gateway", nil}], "21 Sept 2026"),
        secret_of("JIRA_API_TOKEN", [{"jira", nil}], "14 Sept 2026"),
        secret_of("WEBHOOK_SIGNING_SECRET", [{"webhook", nil}], "3 Sept 2026"),
        secret_of("INTERNAL_API_SECRET", [{"internal_api", nil}], "18 Sept 2026"),
        secret_of("REGISTRY_TOKEN", [{"registry", nil}], "2 Sept 2026"),
        secret_of("DOCS_SEARCH_TOKEN", [{"docs_search", nil}], "24 Sept 2026")
      ],
      variables: [
        %{name: "DEFAULT_BRANCH", value: "main", repository: nil},
        %{name: "SHOP_API_URL", value: "https://internal.example.com/api", repository: nil},
        %{name: "TEST_COMMAND", value: "make test", repository: nil},
        %{name: "TEST_COMMAND", value: "npm test", repository: "acme/shared-ui"}
      ]
    }
  end

  defp secret_of(name, used_by, updated, opts \\ []),
    do: %{name: name, values: opts[:values], used_by: used_by, updated: updated}

  @doc """
  The workspace's nodes, as the mock-ups of Nodes draw them (`storybook/screens/`): a
  proposal, so no context builds them yet. Each is a node, permanent with one instance at a
  time, or a node pool, whose ephemeral instances share its key, at most `limit` at once
  (`nil` for no limit); its kind is fixed when it is made. `instances` are those running
  now, by the instance id the runner reports: a pool's appear only while they run, and a
  node's one is kept as `last` once it stops. `keys` are its access keys, `seen` when it
  last posted and `runs` its runs of 14 days. Its times are this minute's.

    * build-01, running, its key approved;
    * build-02, last seen 2 hours ago, its first key awaiting approval;
    * mac-mini, last seen 3 days ago, its key revoked;
    * ci-runners, a pool of at most 10 with 3 running;
    * spot-runners, a pool without a limit with 5 running;
    * nightly-checks, a pool of at most 4 with none running.
  """
  @spec nodes() :: [map()]
  def nodes do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ago = &DateTime.add(now, -&1)

    [
      node("build_01", "build-01", :node,
        instances: [instance("i_4F7KQ2ZD9XW11wx9dz2qk7", 37, "0.6.1", ago.(5 * 3600 + 1_260))],
        keys: [
          key(
            "ak_7q2m9f4cxkd8b1ah",
            :approved,
            "Xq3vR8kT1mZp6LwN2bYc9H",
            stored_secrets: true,
            by: "dana",
            on: "2 Sept 2026"
          )
        ],
        seen: ago.(4),
        runs: 214,
        created: "dana, 2 Sept 2026"
      ),
      node("build_02", "build-02", :node,
        last: instance("i_8C1MV5TR2HJ66jh2rt5vm1", 0, "0.6.1", ago.(2 * 3600)),
        keys: [
          key(
            "ak_3xkd8b1ap4n6w2ze",
            :pending,
            "Lm7Tq2Wv9Xc4Bn8Kd1Rf6H",
            stored_secrets: true,
            by: "dana",
            on: "today",
            asked: ago.(2 * 3600)
          )
        ],
        seen: ago.(2 * 3600),
        runs: 0,
        created: "dana, today"
      ),
      node("mac_mini", "mac-mini", :node,
        last: instance("i_6X1ZH4NM9BR33rb9mn4hz1", 41, "0.6.0", ago.(3 * 86_400)),
        keys: [
          key(
            "ak_p4n6w2zeh8r5t1qj",
            :revoked,
            "Bd4Fh8Jk2Lm6Np0Qr4St8U",
            stored_secrets: false,
            by: "lee",
            on: "30 Sept 2026"
          )
        ],
        seen: ago.(3 * 86_400),
        runs: 41,
        created: "lee, 9 Sept 2026"
      ),
      node("ci_runners", "ci-runners", :pool,
        limit: 10,
        instances: [
          instance("i_2T5KW8DQ1HX77xh1qd8wk5", 2, "0.6.1", ago.(1_140)),
          instance("i_9K5XR2JC6VD88dv6cj2rx5", 1, "0.6.1", ago.(420)),
          instance("i_1N7BW4QG3TZ22zt3gq4wb7", 1, "0.6.1", ago.(95))
        ],
        keys: [
          key(
            "ak_h8r5t1qj7q2m9f4c",
            :approved,
            "Qa1Ws2Ed3Rf4Tg5Yh6Uj7I",
            stored_secrets: true,
            by: "dana",
            on: "3 Sept 2026"
          )
        ],
        seen: ago.(2),
        runs: 388,
        created: "dana, 3 Sept 2026"
      ),
      node("spot_runners", "spot-runners", :pool,
        limit: nil,
        instances: [
          instance("i_5R2HM8KD1XC99cx1dk8mh2", 3, "0.6.1", ago.(2 * 3600 + 600)),
          instance("i_3V6JT9WB5QN44nq5bw9tj6", 2, "0.6.1", ago.(3_300)),
          instance("i_7D4QX1HZ6MK22km6zh1xq4", 1, "0.6.1", ago.(1_500)),
          instance("i_0B8NC3RV7JW55wj7vr3cn8", 1, "0.6.0", ago.(600)),
          instance("i_6H3TZ1PF8RM55mr8fp1zt3", 1, "0.6.1", ago.(140))
        ],
        keys: [
          key(
            "ak_2q9wd7nb4kx3v6jt",
            :approved,
            "Mn8Bv7Cx6Za5Sd4Fg3Hj2K",
            stored_secrets: false,
            by: "lee",
            on: "14 Sept 2026"
          )
        ],
        seen: ago.(9),
        runs: 126,
        created: "lee, 14 Sept 2026"
      ),
      node("nightly_checks", "nightly-checks", :pool,
        limit: 4,
        keys: [
          key(
            "ak_9f4cxkd8b1ah7q2m",
            :approved,
            "Zx9Cv8Bn7Mq6Wp5Ol4Ik3U",
            stored_secrets: true,
            by: "sam",
            on: "21 Sept 2026"
          )
        ],
        seen: ago.(20 * 3600),
        runs: 28,
        created: "sam, 21 Sept 2026"
      )
    ]
  end

  @doc """
  The key a node enrols to replace its own, as the mock-up of a replacement draws it: it
  arrived with an enrolment code a minute ago and awaits approval.
  """
  @spec replacement_key() :: map()
  def replacement_key do
    key("ak_w2ze3xkd8b1ap4n6", :pending, "Ty5Rn3Vb8Xk1Mq7Lp2Wd9H",
      stored_secrets: true,
      by: "dana",
      on: "today",
      asked: DateTime.add(DateTime.utc_now(), -60)
    )
  end

  defp node(id, name, kind, opts) do
    Map.merge(
      %{id: id, name: name, kind: kind, limit: nil, instances: [], last: nil},
      Map.new(opts)
    )
  end

  defp instance(id, runs, version, since),
    do: %{id: id, runs: runs, version: version, since: since}

  # `by` and `on` are who approved the key and when, who revoked it for a revoked one, and
  # who made its enrolment code for one awaiting approval, which arrived `asked`.
  defp key(id, state, fingerprint, opts) do
    Map.merge(%{id: id, state: state, fingerprint: fingerprint, asked: nil}, Map.new(opts))
  end
end
