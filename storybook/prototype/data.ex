defmodule ApiaryWeb.Prototype.Data do
  @moduledoc """
  The sample data of the navigation prototype (`ApiaryWeb.Prototype`): one organisation,
  `acme`, with one workspace, `shop`, its repositories, nodes, runs, hosts, rules,
  integrations, secrets, variables and people. Neutral and synthetic, and fixed: times are
  words ("4 min ago"), so every page reads the same on every load.
  """

  @doc "The workspace's runs, newest first."
  def runs do
    [
      run("0191f2a4", "Fix login redirect", :running, "acme/shop", "build-01", "14:02", "4 m", 3),
      run(
        "0191f2b0",
        "Add stock levels to the order page",
        :running,
        "acme/shop",
        "ci-runners",
        "13:58",
        "8 m",
        0
      ),
      run("0191f29c", "Bump lodash", :succeeded, "acme/shop", "ci-runners", "13:40", "2 m", 0),
      run(
        "0191f291",
        "Tidy the button styles",
        :succeeded,
        "acme/shared-ui",
        "spot-runners",
        "13:12",
        "6 m",
        0
      ),
      run("0191f27e", "Add rate limiter", :failed, "acme/shop", "build-01", "12:10", "9 m", 3),
      run(
        "0191f266",
        "Upgrade the payment client",
        :failed,
        "acme/billing",
        "spot-runners",
        "11:47",
        "7 m",
        2
      ),
      run(
        "0191f251",
        "Fix the rounding of order totals",
        :succeeded,
        "acme/shop",
        "ci-runners",
        "10:30",
        "19 m",
        0
      ),
      run(
        "0191f240",
        "Document the release steps",
        :succeeded,
        "acme/docs",
        "mac-mini",
        "Yesterday",
        "5 m",
        0
      )
    ]
  end

  defp run(id, task, state, repo, node, started, took, refused) do
    %{
      id: id,
      task: task,
      state: state,
      repo: repo,
      node: node,
      started: started,
      took: took,
      refused: refused,
      runtime: "claude-code"
    }
  end

  @doc "The run of `id`, or nil."
  def run(id), do: Enum.find(runs(), &(&1.id == id))

  @doc "The words of a run's state."
  def state_label(:running), do: "Running"
  def state_label(:succeeded), do: "Ended well"
  def state_label(:failed), do: "Ended badly"
  def state_label(:pending), do: "Waiting"

  @doc "The repositories runs work in, with their activity and what they set of their own."
  def repositories do
    [
      repo("acme/shop", "4 min ago", :running, 214, "96 %", 2, ["Policy", "Integrations"],
        pinned: true,
        spark: [3, 5, 4, 6, 8, 7, 9, 11, 8, 10, 12, 9, 13, 14]
      ),
      repo("acme/shared-ui", "1 h ago", :succeeded, 61, "100 %", 0, [],
        pinned: true,
        spark: [2, 3, 2, 4, 3, 5, 4, 6, 5, 4, 6, 5, 7, 6]
      ),
      repo("acme/billing", "3 h ago", :failed, 12, "75 %", 2, ["Variables"],
        spark: [0, 1, 0, 1, 1, 2, 1, 0, 1, 2, 1, 1, 0, 1]
      ),
      repo("acme/docs", "Yesterday", :succeeded, 9, "100 %", 0, [],
        spark: [1, 0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1]
      ),
      repo("acme/mobile-app", "4 days ago", :succeeded, 3, "100 %", 0, ["Policy"],
        spark: [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
      )
    ]
  end

  defp repo(path, last, state, runs, well, refused, own, opts) do
    %{
      path: path,
      system: "github.com",
      last: last,
      state: state,
      runs: runs,
      well: well,
      refused: refused,
      own: own,
      pinned: Keyword.get(opts, :pinned, false),
      spark: Keyword.fetch!(opts, :spark)
    }
  end

  @doc "The repository at `path` (`acme/shop`), or nil."
  def repository(path), do: Enum.find(repositories(), &(&1.path == path))

  @doc "The repositories pinned by the reader, in the sidebar's order."
  def pinned, do: Enum.filter(repositories(), & &1.pinned)

  @doc """
  The workspace's nodes and node pools. A node runs one instance at a time; a pool's
  instances appear while they run. `keys` are its access keys, the last the current one.
  """
  def nodes do
    [
      %{
        id: "nd_4f7kq2zd9xw1",
        name: "build-01",
        kind: :node,
        limit: 1,
        state: :running,
        seen: "a few seconds ago",
        made: "dana, 2 Sept",
        runs: 214,
        instances: [instance("build-01.local", "m_4F7KQ2ZD9XW1", "14:02", "0191f2a4")],
        keys: [
          key(
            "ak_4F7KQ2ZD9XW1C8NB",
            :approved,
            "SHA256:Xq3vR8kT1mZp6LwN2bYc9Hs4Jd0Pa7Ue5Gi2Ko8Rt1",
            arrived: "with an enrolment code dana made, 2 Sept",
            approved: "dana, 2 Sept",
            stored: true
          )
        ],
        revoked: []
      },
      %{
        id: "nd_8c1mv5tr2hj6",
        name: "build-02",
        kind: :node,
        limit: 1,
        state: :seen,
        seen: "2 hours ago",
        made: "dana, today",
        runs: 0,
        instances: [],
        keys: [
          key(
            "ak_3XKD8B1AP4N6W2ZE",
            :pending,
            "SHA256:Lm7Tq2Wv9Xc4Bn8Kd1Rf6Hs3Jp0Za5Ye2Gu7Io4Qt9N",
            arrived: "with an enrolment code dana made; used 2 h ago from 203.0.113.7",
            approved: nil,
            stored: true
          )
        ],
        revoked: [
          key("ak_9PL2QX7HC4MZ8V1A", :revoked, "SHA256:Rr2Kp8Ns4Bv6Cx1Zq9Wm3Ty7Ul5Io0Pa2Sd4Fg6Hj",
            arrived: "a pasted public key, today",
            approved: "revoked by dana, today",
            stored: false
          )
        ]
      },
      %{
        id: "nd_6x1zh4nm9br3",
        name: "mac-mini",
        kind: :node,
        limit: 1,
        state: :seen,
        seen: "3 days ago",
        made: "lee, 9 Sept",
        runs: 41,
        instances: [],
        keys: [
          key(
            "ak_6X1ZH4NM9BR3T5QW",
            :approved,
            "SHA256:Bd4Fh8Jk2Lm6Np0Qr4St8Uv2Wx6Yz0Ab4Cd8Ef2Gh",
            arrived: "a pasted public key, 9 Sept",
            approved: "lee, 9 Sept",
            stored: false
          )
        ],
        revoked: []
      },
      %{
        id: "np_2t5kw8dq1hx7",
        name: "ci-runners",
        kind: :pool,
        limit: 10,
        state: :running,
        seen: "a few seconds ago",
        made: "dana, 2 Sept",
        runs: 388,
        instances: [
          instance("runner-a1", "m_2T5KW8DQ1HX7", "20:53", "0191f2b0"),
          instance("runner-a2", "m_9K5XR2JC6VD8", "21:05", "0191f29c"),
          instance("runner-a3", "m_1N7BW4QG3TZ2", "21:10", "0191f251")
        ],
        keys: [
          key(
            "ak_2T5KW8DQ1HX7M3RB",
            :approved,
            "SHA256:Qa1Ws2Ed3Rf4Tg5Yh6Uj7Ik8Ol9Pz0Xc1Vb2Nm3Lk",
            arrived: "with an enrolment code dana made, 2 Sept",
            approved: "dana, 2 Sept",
            stored: true
          )
        ],
        revoked: []
      },
      %{
        id: "np_5r2hm8kd1xc9",
        name: "spot-runners",
        kind: :pool,
        limit: nil,
        state: :running,
        seen: "a few seconds ago",
        made: "lee, 14 Sept",
        runs: 126,
        instances: [
          instance("spot-7f2a", "m_5R2HM8KD1XC9", "19:40", "0191f291"),
          instance("spot-3b9e", "m_3V6JT9WB5QN4", "20:12", "0191f266")
        ],
        keys: [
          key(
            "ak_5R2HM8KD1XC9W4TP",
            :approved,
            "SHA256:Mn8Bv7Cx6Za5Sd4Fg3Hj2Kl1Qw0Er9Ty8Ui7Op6As",
            arrived: "a pasted public key, 14 Sept",
            approved: "lee, 14 Sept",
            stored: false
          )
        ],
        revoked: []
      },
      %{
        id: "np_0b8nc3rv7jw5",
        name: "nightly-checks",
        kind: :pool,
        limit: 4,
        state: :seen,
        seen: "20 hours ago",
        made: "sam, 21 Sept",
        runs: 28,
        instances: [],
        keys: [
          key(
            "ak_0B8NC3RV7JW5H2KD",
            :approved,
            "SHA256:Zx9Cv8Bn7Mq6Wp5Ol4Ik3Uj2Yh1Tg0Rf9Ed8Ws7Qa",
            arrived: "with an enrolment code sam made, 21 Sept",
            approved: "sam, 21 Sept",
            stored: true
          )
        ],
        revoked: []
      }
    ]
  end

  defp instance(name, id, since, run), do: %{name: name, id: id, since: since, run: run}

  defp key(id, state, fingerprint, opts),
    do: Map.merge(%{id: id, state: state, fingerprint: fingerprint}, Map.new(opts))

  @doc "The node of `id`, or nil."
  def node(id), do: Enum.find(nodes(), &(&1.id == id))

  @doc "The node named `name`, or nil."
  def node_named(name), do: Enum.find(nodes(), &(&1.name == name))

  @doc "Whether a node has a key awaiting approval."
  def key_waiting?(node), do: Enum.any?(node.keys, &(&1.state == :pending))

  @doc "How many instances run now, across every node and pool."
  def running_instances, do: nodes() |> Enum.map(&length(&1.instances)) |> Enum.sum()

  @doc "The hosts the runs reached in 14 days, refused first."
  def connections do
    [
      conn("registry.example.com", "/npm/*", :refused, 14, "no rule allows it", "2 min",
        repos: ["acme/shop"]
      ),
      conn("telemetry.example.net", "/*", :refused, 6, "rule: deny *.example.net", "1 h",
        repos: ["acme/shop", "acme/billing"],
        rule: "*.example.net"
      ),
      conn("pay.example.com", "/v2/*", :refused, 2, "no rule allows it", "3 h",
        repos: ["acme/billing"]
      ),
      conn("api.github.com", "/*", :allowed, 1_032, "rule: api.github.com", "1 min",
        repos: ["acme/shop", "acme/shared-ui", "acme/billing"],
        rule: "api.github.com"
      ),
      conn("registry.npmjs.org", "/*", :allowed, 418, "rule: registry.npmjs.org", "4 min",
        repos: ["acme/shop", "acme/shared-ui"],
        rule: "registry.npmjs.org"
      ),
      conn("api.anthropic.com", "/v1/*", :allowed, 2_960, "Anthropic integration", "1 min",
        repos: ["acme/shop", "acme/shared-ui", "acme/billing", "acme/docs"],
        rule: "api.anthropic.com"
      ),
      conn("docs.example.com", "/*", :allowed, 77, "rule: docs.example.com", "1 h",
        repos: ["acme/docs"],
        rule: "docs.example.com"
      )
    ]
  end

  defp conn(host, path, state, count, why, last, opts) do
    %{
      host: host,
      path: path,
      state: state,
      count: count,
      why: why,
      last: last,
      repos: Keyword.fetch!(opts, :repos),
      rule: Keyword.get(opts, :rule)
    }
  end

  @doc "The connections seen in runs of the repository at `path`."
  def connections(path), do: Enum.filter(connections(), &(path in &1.repos))

  @doc "The workspace policy's rules."
  def rules do
    [
      rule("Allow", "api.github.com", "/*", "1,032×", "dana", false, "Workspace"),
      rule("Allow", "registry.npmjs.org", "/*", "418×", "dana", false, "Workspace"),
      rule("Allow", "api.anthropic.com", "/v1/*", "2,960×", "dana", true, "Workspace"),
      rule("Allow", "docs.example.com", "/*", "77×", "sam", false, "Workspace"),
      rule("Deny", "*.example.net", "/*", "6×", "lee", true, "Workspace")
    ]
  end

  @doc "acme/shop's own rules, which narrow the workspace's."
  def repository_rules do
    [
      rule("Allow", "registry.example.com", "/npm/*", "0×", "dana", false, "acme/shop"),
      rule("Deny", "pay.example.com", "/*", "2×", "lee", false, "acme/shop"),
      rule("Allow", "cdn.example.com", "/assets/*", "88×", "dana", false, "acme/shop")
    ]
  end

  defp rule(action, host, path, used, by, locked, source),
    do: %{
      action: action,
      host: host,
      path: path,
      used: used,
      by: by,
      locked: locked,
      source: source
    }

  @doc "The policy's history: each change, newest first."
  def policy_history do
    [
      %{v: 12, what: "Switched the mode to Enforce", by: "lee", when: "28 Sept"},
      %{v: 11, what: "Locked deny *.example.net", by: "dana", when: "21 Sept"},
      %{v: 10, what: "Added allow docs.example.com /*", by: "sam", when: "19 Sept"},
      %{v: 9, what: "Added allow api.anthropic.com /v1/*", by: "dana", when: "9 Sept"},
      %{v: 8, what: "Added allow registry.npmjs.org /*", by: "dana", when: "3 Sept"}
    ]
  end

  @doc "The workspace's integrations, as Settings › Integrations lists them."
  def integrations do
    [
      integration("github", "GitHub", {:release, "qoryai/qory-github", "1.4.0", "github.com"},
        jobs: [:task_source, :service, :output],
        repos: "All repositories",
        ways: [:api, :mcp],
        what: [
          {:task_source, "Turns an issue labelled agent into a run's task."},
          {:service, "Lets the agent work with repositories on github.com."},
          {:output, "Opens a pull request with what the run changed."}
        ],
        settings: [
          {"App ID", :plain, "123456"},
          {"Private key", :secret, "GITHUB_APP_KEY · main-app"},
          {"Issue label", :plain, "agent"}
        ]
      ),
      integration("anthropic", "Anthropic", :built_in,
        jobs: [:model_provider],
        repos: "All repositories",
        ways: [:api],
        what: [{:model_provider, "Serves Claude models to the runs whose runtime asks for them."}],
        settings: [
          {"API key", :secret, "ANTHROPIC_API_KEY"},
          {"API base URL", :plain, "https://api.anthropic.com"}
        ]
      ),
      integration("model-gateway", "Model gateway", :built_in,
        jobs: [:model_provider, :service],
        repos: "2 repositories",
        ways: [:api],
        what: [
          {:model_provider, "Serves the workspace's self-hosted models."},
          {:service, "Lets the agent read model weights from its cache."}
        ],
        settings: [
          {"Client key", :secret, "GATEWAY_KEY"},
          {"Gateway URL", :plain, "https://models.example.com/v1"}
        ]
      ),
      integration("jira", "Jira", {:release, "acme/qory-jira", "1.2.0", "gitlab.example.com"},
        jobs: [:task_source],
        repos: "3 repositories",
        ways: [],
        what: [{:task_source, "Takes the issues a filter finds as tasks."}],
        settings: [
          {"API token", :secret, "JIRA_API_TOKEN"},
          {"Site URL", :plain, "https://acme.example.com"},
          {"Project key", :plain, "SHOP"}
        ]
      ),
      integration("slack", "Slack", {:release, "acme/qory-slack", "0.4.0", "github.com"},
        jobs: [:output],
        repos: "3 repositories",
        ways: [],
        needs_secret: true,
        what: [{:output, "Posts a line to a channel when a run ends."}],
        settings: [
          {"Bot token", :secret, nil},
          {"Channel", :plain, "#shop-builds"}
        ]
      ),
      integration(
        "internal-api",
        "Internal API",
        {:release, "acme/qory-internal-api", "2.1.0", "git.example.com"},
        jobs: [:service],
        repos: "6 repositories",
        ways: [:api],
        what: [{:service, "Gives a run a short-lived, read-only token for the internal API."}],
        settings: [
          {"Client secret", :secret, "INTERNAL_API_SECRET"},
          {"Base URL", :plain, "https://internal.example.com/api"}
        ]
      ),
      integration("registry", "Package registry", :built_in,
        jobs: [:service],
        repos: "All repositories",
        ways: [:api],
        what: [{:service, "Lets a run install the workspace's private packages, read only."}],
        settings: [
          {"Read token", :secret, "REGISTRY_TOKEN"},
          {"Registry URL", :plain, "https://registry.example.com"}
        ]
      ),
      integration(
        "docs-search",
        "Docs search",
        {:url, "https://example.com/docs-mcp/description.json"},
        jobs: [:service],
        repos: "4 repositories",
        ways: [:mcp],
        what: [{:service, "Searches the shop's own documentation, as a tool the agent calls."}],
        settings: [
          {"Read token", :secret, "DOCS_SEARCH_TOKEN"},
          {"Index URL", :plain, "https://docs.example.com/search"}
        ]
      )
    ]
  end

  defp integration(id, name, source, opts) do
    Map.merge(
      %{id: id, name: name, source: source, needs_secret: false},
      Map.new(opts)
    )
  end

  @doc "The integration of `id`, or nil."
  def integration(id), do: Enum.find(integrations(), &(&1.id == id))

  @doc "The words of an integration's job."
  def job_label(:task_source), do: "Task source"
  def job_label(:model_provider), do: "Model provider"
  def job_label(:service), do: "Service"
  def job_label(:output), do: "Output"

  @doc "The workspace's secrets."
  def secrets do
    [
      %{
        name: "GITHUB_APP_KEY",
        values: "2 values: main-app, bot-app",
        used: "GitHub",
        changed: "2 Sept"
      },
      %{name: "ANTHROPIC_API_KEY", values: "1 value", used: "Anthropic", changed: "28 Sept"},
      %{name: "GATEWAY_KEY", values: "1 value", used: "Model gateway", changed: "21 Sept"},
      %{name: "JIRA_API_TOKEN", values: "1 value", used: "Jira", changed: "14 Sept"},
      %{name: "INTERNAL_API_SECRET", values: "1 value", used: "Internal API", changed: "18 Sept"},
      %{name: "REGISTRY_TOKEN", values: "1 value", used: "Package registry", changed: "2 Sept"},
      %{name: "DOCS_SEARCH_TOKEN", values: "1 value", used: "Docs search", changed: "24 Sept"},
      %{name: "SLACK_BOT_TOKEN", values: "1 value", used: nil, changed: "30 Sept"}
    ]
  end

  @doc "The workspace's variables."
  def variables do
    [
      %{
        name: "DEFAULT_BRANCH",
        value: "main",
        note: "Workspace · 1 repository sets its own",
        locked: false
      },
      %{name: "SHOP_API_URL", value: "https://example.com", note: "Workspace", locked: true},
      %{
        name: "TEST_COMMAND",
        value: "make test",
        note: "Workspace · 2 repositories set their own",
        locked: false
      },
      %{name: "NODE_VERSION", value: "22", note: "Workspace", locked: false}
    ]
  end

  @doc "acme/shop's variables: its own and those it inherits."
  def repository_variables do
    [
      %{name: "TEST_COMMAND", value: "npm test", source: "This repository", locked: false},
      %{name: "DEFAULT_BRANCH", value: "trunk", source: "This repository", locked: false},
      %{name: "SHOP_API_URL", value: "https://example.com", source: "Workspace", locked: true},
      %{name: "NODE_VERSION", value: "22", source: "Workspace", locked: false}
    ]
  end

  @doc "The organisation's people."
  def people do
    [
      %{email: "dana@example.com", name: "Dana", level: "Owner", since: "2 Sept 2026"},
      %{email: "lee@example.com", name: "Lee", level: "Admin", since: "3 Sept 2026"},
      %{email: "sam@example.com", name: "Sam", level: "Member", since: "21 Sept 2026"},
      %{email: "kim@example.com", name: "Kim", level: "Member", since: "25 Sept 2026"},
      %{email: "alex@example.com", name: "Alex", level: "Member", since: "1 Oct 2026"}
    ]
  end

  @doc "The organisation's audit log, newest first."
  def audit_log do
    [
      %{
        who: "dana",
        what: "Approved access key ak_4F7KQ2ZD9XW1C8NB of build-01",
        where: "shop",
        when: "2 Sept, 10:14"
      },
      %{
        who: "lee",
        what: "Switched the policy to Enforce",
        where: "shop",
        when: "28 Sept, 16:02"
      },
      %{
        who: "dana",
        what: "Locked the rule deny *.example.net",
        where: "shop",
        when: "21 Sept, 11:40"
      },
      %{who: "sam", what: "Added the integration Slack", where: "shop", when: "30 Sept, 09:12"},
      %{
        who: "dana",
        what: "Invited kim@example.com as a member",
        where: "acme",
        when: "25 Sept, 15:31"
      },
      %{
        who: "lee",
        what: "Made the node pool spot-runners",
        where: "shop",
        when: "14 Sept, 08:55"
      },
      %{
        who: "dana",
        what: "Changed the run history's retention to 90 days",
        where: "shop",
        when: "3 Sept, 12:20"
      }
    ]
  end
end
