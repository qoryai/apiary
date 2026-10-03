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
  The workspace's access keys, as the mock-up of Settings › Access keys lists them: one
  that ten machines share, and one a machine asked for that waits for approval.
  """
  @spec access_keys() :: [map()]
  def access_keys do
    [
      %{
        id: "k1",
        label: "build-fleet",
        key_id: "ak_7Q2M9F4CXKD8B1AH",
        stored_secrets: true,
        machines: 10,
        approved_by: "dana",
        state: :active
      },
      %{
        id: "k2",
        label: "ci-runner",
        key_id: "ak_3XKD8B1AP4N6W2ZE",
        stored_secrets: true,
        machines: 1,
        approved_by: "lee",
        state: :active
      },
      %{
        id: "k3",
        label: "laptop-sam",
        key_id: "ak_P4N6W2ZEH8R5T1QJ",
        stored_secrets: false,
        machines: 1,
        approved_by: "dana",
        state: :active
      },
      %{
        id: "k4",
        label: "nightly",
        key_id: "ak_H8R5T1QJ7Q2M9F4C",
        stored_secrets: false,
        machines: 0,
        approved_by: nil,
        requested_by: "sam",
        state: :pending
      }
    ]
  end

  @doc """
  The machines that posted to the workspace with its keys, as the mock-up of Record ›
  Machines lists them: ten share `build-fleet`, and four are offline. Their last-seen
  times are this minute's.
  """
  @spec machines() :: [map()]
  def machines do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    fleet =
      for {n, id, runs, status, ago} <- [
            {1, "m_4F7KQ2ZD9XW1", 214, :online, 4},
            {2, "m_8C1MV5TR2HJ6", 198, :online, 9},
            {3, "m_2Q9WD7NB4KX3", 187, :online, 12},
            {4, "m_6H3TZ1PF8RM5", 176, :online, 20},
            {5, "m_9K5XR2JC6VD8", 163, :online, 31},
            {6, "m_1N7BW4QG3TZ2", 151, :online, 45},
            {7, "m_5R2HM8KD1XC9", 140, :online, 58},
            {8, "m_3V6JT9WB5QN4", 92, :offline, 3 * 3600},
            {9, "m_7D4QX1HZ6MK2", 61, :offline, 26 * 3600},
            {10, "m_0B8NC3RV7JW5", 12, :offline, 9 * 86_400}
          ] do
        machine(
          id,
          "build-#{String.pad_leading("#{n}", 2, "0")}",
          "k1",
          runs,
          status,
          DateTime.add(now, -ago),
          if(n == 10, do: "0.5.4", else: "0.6.1")
        )
      end

    fleet ++
      [
        machine("m_2T5KW8DQ1HX7", "ci-01", "k2", 388, :online, DateTime.add(now, -2), "0.6.1"),
        machine(
          "m_6X1ZH4NM9BR3",
          "sam-laptop",
          "k3",
          27,
          :offline,
          DateTime.add(now, -2 * 86_400),
          "0.6.0"
        )
      ]
  end

  defp machine(id, host, key, runs, status, seen, version) do
    %{id: id, host: host, key: key, runs: runs, status: status, last_seen: seen, version: version}
  end
end
