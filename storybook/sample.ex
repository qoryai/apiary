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
  (`nil` for one built in, else the GitHub repository and the version it was added at), its
  roles, the secrets it declares, each linked to a workspace secret by name and
  environment or `nil` while it needs one, and its settings.
  """
  @spec integrations() :: [map()]
  def integrations do
    [
      integration("github", "GitHub", nil, [:task_source, :output, :service],
        about:
          "Reads issues as tasks, opens a change request with what a run did, and gives each run a token for the repositories it works on.",
        secrets: [
          secret("private_key", "The GitHub App's private key.", "GITHUB_APP_KEY"),
          secret(
            "webhook_secret",
            "Checks that an event came from GitHub.",
            "GITHUB_WEBHOOK_SECRET"
          )
        ],
        settings: [
          setting("app_id", "App ID", "104231"),
          setting("installation", "Installation", "acme"),
          setting("branch_prefix", "Branch prefix", "qory/",
            hint: "A run's branch starts with it."
          ),
          setting("drafts", "Open change requests as drafts", true, type: "checkbox")
        ],
        targets: 12,
        added: "dana, 2 Sept 2026"
      ),
      integration("anthropic", "Anthropic", nil, [:llm_provider],
        about: "Claude models, for the runs whose runtime asks for them.",
        secrets: [secret("api_key", "An API key of the Anthropic console.", "ANTHROPIC_API_KEY")],
        settings: [
          setting("base_url", "API base URL", "https://api.anthropic.com"),
          setting("budget", "Tokens a run may use", "2,000,000")
        ],
        targets: 9,
        added: "dana, 2 Sept 2026"
      ),
      integration("openai", "OpenAI", nil, [:llm_provider],
        about: "OpenAI's models, for the runs whose runtime asks for them.",
        secrets: [secret("api_key", "A project API key.", "OPENAI_API_KEY")],
        settings: [
          setting("base_url", "API base URL", "https://api.openai.com/v1"),
          setting("project", "Project", "proj_shop")
        ],
        targets: 3,
        added: "lee, 9 Sept 2026"
      ),
      integration(
        "model_gateway",
        "Model gateway",
        %{repo: "acme/qory-model-gateway", version: "0.4.0"},
        [:llm_provider, :service],
        about:
          "The workspace's own gateway to self-hosted models, and the cache runs read its weights from.",
        secrets: [secret("gateway_key", "The gateway's client key.", "GATEWAY_KEY")],
        settings: [
          setting("base_url", "Gateway URL", "https://models.example.com/v1"),
          setting("model", "Default model", "gateway-default")
        ],
        targets: 2,
        added: "sam, 21 Sept 2026"
      ),
      integration("jira", "Jira", %{repo: "acme/qory-jira", version: "1.4.0"}, [:task_source],
        about:
          "Takes the issues of a project, by a filter, as tasks, and comments on each when its run ends.",
        secrets: [secret("api_token", "An API token of a Jira account.", "JIRA_API_TOKEN")],
        settings: [
          setting("site", "Site URL", "https://acme.example.com"),
          setting("project", "Project key", "SHOP"),
          setting("filter", "Filter", "labels = qory AND status = \"To do\"",
            hint: "Only the issues it finds become tasks."
          )
        ],
        targets: 4,
        added: "lee, 14 Sept 2026"
      ),
      integration("slack", "Slack", %{repo: "acme/qory-slack", version: "0.9.2"}, [:output],
        about:
          "Posts a line to a channel when a run ends, with its state and its change request.",
        secrets: [
          secret(
            "signing_secret",
            "Checks that a button press came from Slack.",
            "SLACK_SIGNING_SECRET"
          ),
          secret("bot_token", "The bot token of the workspace's Slack app.", nil)
        ],
        settings: [
          setting("channel", "Channel", "#shop-builds"),
          setting("only_bad", "Only runs that ended badly", false, type: "checkbox")
        ],
        targets: 0,
        added: "sam, 30 Sept 2026"
      ),
      integration("webhook", "Webhook", nil, [:output],
        about: "Posts each run's summary as JSON to a URL, signed with a shared secret.",
        secrets: [
          secret("signing_secret", "Signs each request's body.", "WEBHOOK_SIGNING_SECRET")
        ],
        settings: [setting("url", "URL", "https://hooks.example.com/qory")],
        targets: 5,
        added: "dana, 3 Sept 2026"
      ),
      integration(
        "internal_api",
        "Internal API",
        %{repo: "acme/qory-internal-api", version: "2.1.0"},
        [:service],
        about: "Gives a run a short-lived token for the shop's internal API, scoped to read.",
        secrets: [secret("client_secret", "The API's client secret.", "INTERNAL_API_SECRET")],
        settings: [
          setting("base_url", "Base URL", "https://internal.example.com/api"),
          setting("scope", "Scope", "orders:read stock:read")
        ],
        targets: 6,
        added: "lee, 18 Sept 2026"
      ),
      integration("registry", "Package registry", nil, [:service],
        about: "Lets a run install the workspace's private packages, read only.",
        secrets: [secret("token", "A read token of the registry.", "REGISTRY_TOKEN")],
        settings: [
          setting("url", "Registry URL", "https://registry.example.com"),
          setting("scope", "Package scope", "@acme")
        ],
        targets: 11,
        added: "dana, 2 Sept 2026"
      )
    ]
  end

  defp integration(id, name, source, roles, opts) do
    Map.merge(%{id: id, name: name, source: source, roles: roles}, Map.new(opts))
  end

  defp secret(name, about, nil), do: %{name: name, about: about, secret: nil, environment: nil}

  defp secret(name, about, secret),
    do: %{name: name, about: about, secret: secret, environment: "production"}

  defp setting(id, label, value, opts \\ []) do
    %{
      id: id,
      label: label,
      value: value,
      type: Keyword.get(opts, :type, "text"),
      hint: Keyword.get(opts, :hint)
    }
  end

  @doc """
  What can be added from Add integration › Built in: each integration Qory ships, with its
  roles and whether the workspace has it already.
  """
  @spec built_in() :: [map()]
  def built_in do
    [
      %{id: "github", name: "GitHub", roles: [:task_source, :output, :service], added: true},
      %{id: "gitlab", name: "GitLab", roles: [:task_source, :output, :service], added: false},
      %{id: "anthropic", name: "Anthropic", roles: [:llm_provider], added: true},
      %{id: "openai", name: "OpenAI", roles: [:llm_provider], added: true},
      %{id: "webhook", name: "Webhook", roles: [:output], added: true},
      %{id: "email", name: "Email", roles: [:output], added: false},
      %{id: "registry", name: "Package registry", roles: [:service], added: true}
    ]
  end

  @doc """
  What Add integration › From GitHub found in a repository's `description.json`: the
  integration it describes, the secrets it declares and its settings, and the file itself.
  """
  @spec described() :: map()
  def described do
    %{
      repo: "acme/qory-ticket-desk",
      version: "0.6.0",
      name: "Ticket desk",
      roles: [:task_source, :output],
      about: "Takes the tickets of a queue as tasks, and replies on each with what its run did.",
      secrets: ["api_token"],
      settings: ["Base URL", "Queue"],
      json: """
      {
        "name": "Ticket desk",
        "version": "0.6.0",
        "roles": ["task_source", "output"],
        "secrets": [{"name": "api_token", "required": true}],
        "settings": [
          {"name": "base_url", "label": "Base URL", "type": "url"},
          {"name": "queue", "label": "Queue", "type": "string"}
        ]
      }
      """
    }
  end

  @doc """
  The workspace's secrets, each a name in an environment, and what uses it; and its
  variables, which are not secret, as Settings › Secrets and variables lists them.
  """
  @spec workspace_secrets() :: %{secrets: [map()], variables: [map()]}
  def workspace_secrets do
    %{
      secrets: [
        %{
          name: "GITHUB_APP_KEY",
          environment: "production",
          used_by: ["github"],
          updated: "2 Sept 2026"
        },
        %{name: "GITHUB_APP_KEY", environment: "staging", used_by: [], updated: "2 Sept 2026"},
        %{
          name: "ANTHROPIC_API_KEY",
          environment: "production",
          used_by: ["anthropic"],
          updated: "28 Sept 2026"
        },
        %{
          name: "OPENAI_API_KEY",
          environment: "production",
          used_by: ["openai"],
          updated: "9 Sept 2026"
        },
        %{
          name: "GATEWAY_KEY",
          environment: "production",
          used_by: ["model_gateway"],
          updated: "21 Sept 2026"
        },
        %{
          name: "JIRA_API_TOKEN",
          environment: "production",
          used_by: ["jira"],
          updated: "14 Sept 2026"
        },
        %{
          name: "WEBHOOK_SIGNING_SECRET",
          environment: "production",
          used_by: ["webhook"],
          updated: "3 Sept 2026"
        },
        %{
          name: "INTERNAL_API_SECRET",
          environment: "production",
          used_by: ["internal_api"],
          updated: "18 Sept 2026"
        },
        %{
          name: "REGISTRY_TOKEN",
          environment: "production",
          used_by: ["registry"],
          updated: "2 Sept 2026"
        }
      ],
      variables: [
        %{name: "DEFAULT_BRANCH", value: "main", environment: "every environment"},
        %{name: "NODE_ENV", value: "production", environment: "production"},
        %{name: "NODE_ENV", value: "staging", environment: "staging"},
        %{
          name: "SHOP_API_URL",
          value: "https://internal.example.com/api",
          environment: "production"
        }
      ]
    }
  end

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
    * preview-envs, a pool without a limit with 5 running;
    * nightly-checks, a pool of at most 4 with none running.
  """
  @spec nodes() :: [map()]
  def nodes do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ago = &DateTime.add(now, -&1)

    [
      node("build_01", "build-01", :node,
        instances: [instance("m_4F7KQ2ZD9XW1", 37, "0.6.1", ago.(5 * 3600 + 1_260))],
        keys: [
          key(
            "ak_7Q2M9F4CXKD8B1AH",
            :approved,
            "SHA256:Xq3vR8kT1mZp6LwN2bYc9HdJ4sFa7Ue0GiOt5QrKx2M",
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
        last: instance("m_8C1MV5TR2HJ6", 0, "0.6.1", ago.(2 * 3600)),
        keys: [
          key(
            "ak_3XKD8B1AP4N6W2ZE",
            :pending,
            "SHA256:Lm7Tq2Wv9Xc4Bn8Kd1Rf6Hs3Jp0Za5Ye2Gu7Io4Qt9N",
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
        last: instance("m_6X1ZH4NM9BR3", 41, "0.6.0", ago.(3 * 86_400)),
        keys: [
          key(
            "ak_P4N6W2ZEH8R5T1QJ",
            :revoked,
            "SHA256:Bd4Fh8Jk2Lm6Np0Qr4St8Uv2Wx6Yz0Ac4Eg8Ik2Mo6Q",
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
          instance("m_2T5KW8DQ1HX7", 2, "0.6.1", ago.(1_140)),
          instance("m_9K5XR2JC6VD8", 1, "0.6.1", ago.(420)),
          instance("m_1N7BW4QG3TZ2", 1, "0.6.1", ago.(95))
        ],
        keys: [
          key(
            "ak_H8R5T1QJ7Q2M9F4C",
            :approved,
            "SHA256:Qa1Ws2Ed3Rf4Tg5Yh6Uj7Ik8Ol9Pz0Xc1Vb2Nm3Lk4J",
            stored_secrets: true,
            by: "dana",
            on: "3 Sept 2026"
          )
        ],
        seen: ago.(2),
        runs: 388,
        created: "dana, 3 Sept 2026"
      ),
      node("preview_envs", "preview-envs", :pool,
        limit: nil,
        instances: [
          instance("m_5R2HM8KD1XC9", 3, "0.6.1", ago.(2 * 3600 + 600)),
          instance("m_3V6JT9WB5QN4", 2, "0.6.1", ago.(3_300)),
          instance("m_7D4QX1HZ6MK2", 1, "0.6.1", ago.(1_500)),
          instance("m_0B8NC3RV7JW5", 1, "0.6.0", ago.(600)),
          instance("m_6H3TZ1PF8RM5", 1, "0.6.1", ago.(140))
        ],
        keys: [
          key(
            "ak_2Q9WD7NB4KX3V6JT",
            :approved,
            "SHA256:Mn8Bv7Cx6Za5Sd4Fg3Hj2Kl1Qw0Er9Ty8Ui7Op6As5D",
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
            "ak_9F4CXKD8B1AH7Q2M",
            :approved,
            "SHA256:Zx9Cv8Bn7Mq6Wp5Ol4Ik3Uj2Yh1Tg0Rf9Ed8Ws7Qa6Z",
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
    key("ak_W2ZE3XKD8B1AP4N6", :pending, "SHA256:Ty5Rn3Vb8Xk1Mq7Lp2Wd9Hs4Jc6Fa0Ze3Gu8Io1Qt5K",
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
