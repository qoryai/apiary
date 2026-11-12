defmodule ApiaryPro.ClientReadsTest do
  # What the edition answers to `c:Apiary.Edition.client_reads/4`: a person of a client
  # does not read the operator's model provider in a run's records, an operator's person
  # reads everything.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2, order_by: 2]
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Connections, Dispatches, Edition, Features, Repo}
  alias Apiary.Connections.Connection, as: ProviderRow
  alias Apiary.Kinds.Coded
  alias Apiary.Runs.{Connection, Event, Projector, Record, Run}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  @api %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "header", "header" => "x-api-key"}
  }

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    client = client_fixture(operator.scope)

    {:ok, provider} =
      Connections.create_provider(client.owner.scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-fixture-model-key-0123456789"}]
      })

    # The provider moved to the operator's chain, coded again as a save codes it.
    provider =
      ProviderRow
      |> Repo.get!(provider.id)
      |> Ecto.Changeset.change(chain: "operator")
      |> Coded.seal()
      |> Repo.update!()

    Flags.put_operator_infrastructure(true)

    %{
      client: client,
      provider: provider,
      person: client.owner.scope,
      operator_person: client.scope
    }
  end

  # A run of the client's workspace, handed over from its queue as a run with a model
  # provider is, with the provider chosen on `chain`.
  defp run!(ctx, chain \\ "operator", api \\ @api),
    do: run_for!(ctx.person, ctx.provider, chain, api)

  # As a claim stores them, the run's `keys` model keys are named `<public id>-1` and on
  # (`Apiary.Dispatches.RunSettings`). The narrowing reads the names alone, so each key's
  # row id is a fresh UUID.
  defp run_for!(scope, provider, chain, api, keys \\ 1) do
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    run_fixture(scope, %{
      dispatch_run_id: queued.id,
      run_settings: %{"runtime" => "claude"},
      provider_connection_id: provider.id,
      model_keys:
        for(n <- 1..keys//1, do: %{"id" => Ecto.UUID.generate(), "name" => key_name(provider, n)}),
      provider_chain: chain,
      provider_api: api
    })
  end

  # The credential name of the model key `n` of a run of `provider`.
  defp key_name(provider, n \\ 1), do: "#{provider.public_id}-#{n}"

  defp connection!(run, host, credential) do
    Repo.insert!(%Connection{
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      run_id: run.id,
      host: host,
      port: 443,
      attempts: 1,
      allowed: 1,
      last_credential: credential,
      first_seen_at: t0(),
      last_seen_at: t0(),
      last_sequence: 1
    })
  end

  defp egress!(run, sequence, host, credential) do
    data = %{"host" => host, "decision" => "allowed"}
    data = if credential, do: Map.put(data, "credential", credential), else: data
    event_fixture(run, sequence, "run.egress", data)
  end

  defp events_of(scope, run) do
    scope
    |> Edition.client_reads(:run_events, run, from(e in Event, where: e.run_id == ^run.id))
    |> order_by(:sequence)
    |> Repo.all()
    |> Enum.map(&{&1.data["host"], &1.data["credential"]})
  end

  defp run_hosts(scope, run) do
    %{rows: rows, total: total} = Record.connections(scope, run)
    assert total == length(rows)
    hosts_of(rows)
  end

  defp hosts_of(connections), do: connections |> Enum.map(& &1.host) |> Enum.sort()

  describe "the events of a run" do
    setup ctx do
      run = run!(ctx)
      egress!(run, 1, "api.anthropic.com", key_name(ctx.provider))
      egress!(run, 2, "files.example.com", "other-key")
      egress!(run, 3, "docs.example.com", nil)
      %{run: run}
    end

    test "leave out those of the operator's provider for a person of the client", ctx do
      assert events_of(ctx.person, ctx.run) ==
               [{"files.example.com", "other-key"}, {"docs.example.com", nil}]
    end

    test "leave out those named by the provider's public id for a person of the client", ctx do
      # A run claimed when a run kept one key: its credential is the provider's public id.
      run = run!(ctx)
      egress!(run, 1, "first.example.com", ctx.provider.public_id)
      egress!(run, 2, "files.example.com", "other-key")

      assert events_of(ctx.person, run) == [{"files.example.com", "other-key"}]
    end

    test "are all there for a person of the operator", ctx do
      assert length(events_of(ctx.operator_person, ctx.run)) == 3
    end

    test "are all there while operator_infrastructure is off", ctx do
      Flags.put_operator_infrastructure(false)
      assert length(events_of(ctx.person, ctx.run)) == 3
    end

    test "are all there for a run on the organisation's chain", ctx do
      run = run!(ctx, "organisation")
      egress!(run, 1, "api.anthropic.com", key_name(ctx.provider))
      assert length(events_of(ctx.person, run)) == 1
    end
  end

  describe "the connections of a run" do
    setup ctx do
      run = run!(ctx)
      connection!(run, "api.anthropic.com", key_name(ctx.provider))
      connection!(run, "files.example.com", "other-key")
      connection!(run, "docs.example.com", nil)
      %{run: run}
    end

    test "leave out that of the operator's provider for a person of the client", ctx do
      assert run_hosts(ctx.person, ctx.run) ==
               ["docs.example.com", "files.example.com"]
    end

    test "are all there for a person of the operator", ctx do
      assert run_hosts(ctx.operator_person, ctx.run) ==
               ["api.anthropic.com", "docs.example.com", "files.example.com"]
    end

    test "are all there while operator_infrastructure is off", ctx do
      Flags.put_operator_infrastructure(false)
      assert run_hosts(ctx.person, ctx.run) |> length() == 3
    end

    test "are all there for a run on the organisation's chain", ctx do
      run = run!(ctx, "organisation")
      connection!(run, "api.anthropic.com", key_name(ctx.provider))
      assert run_hosts(ctx.person, run) == ["api.anthropic.com"]
    end
  end

  describe "the policy of a run" do
    setup ctx do
      run = run!(ctx)
      name = key_name(ctx.provider)

      event_fixture(run, 1, "run.policy_applied", %{
        "mode" => "enforce",
        "allow" => ["docs.example.com", "api.anthropic.com", "files.example.com"],
        "allow_first" => ["api.anthropic.com", "docs.example.com"],
        "credentials" => [
          %{"name" => name, "hosts" => ["api.anthropic.com"]},
          %{"name" => "other-key", "hosts" => ["files.example.com"]}
        ]
      })

      %{run: run}
    end

    test "leaves out the operator's provider for a person of the client", ctx do
      policy = Record.policy(ctx.person, ctx.run)

      assert policy.allow == ["docs.example.com", "files.example.com"]
      assert policy.allow_count == 2
      assert policy.allow_first == ["docs.example.com"]
      assert policy.allow_first_count == 1
      assert Enum.map(policy.credentials, & &1["name"]) == ["other-key"]
      assert policy.credentials_count == 1
    end

    test "is whole for a person of the operator", ctx do
      policy = Record.policy(ctx.operator_person, ctx.run)

      assert policy.allow_count == 3
      assert policy.allow_first_count == 2
      assert policy.credentials_count == 2
      assert "api.anthropic.com" in policy.allow
    end

    test "is whole while operator_infrastructure is off", ctx do
      Flags.put_operator_infrastructure(false)
      policy = Record.policy(ctx.person, ctx.run)

      assert policy.allow_count == 3
      assert policy.credentials_count == 2
    end

    test "is whole for a run on the organisation's chain", ctx do
      run = run!(ctx, "organisation")

      event_fixture(run, 1, "run.policy_applied", %{
        "allow" => ["api.anthropic.com"],
        "credentials" => [%{"name" => key_name(ctx.provider), "hosts" => ["api.anthropic.com"]}]
      })

      policy = Record.policy(ctx.person, run)

      assert policy.allow == ["api.anthropic.com"]
      assert policy.credentials_count == 1
    end

    test "is nil for a run with no policy event", ctx do
      assert Record.policy(ctx.person, run!(ctx)) == nil
    end
  end

  describe "the hosts a policy terminates and its tools serve" do
    setup ctx do
      run = run!(ctx)

      event_fixture(run, 1, "run.started", started_data())

      event_fixture(run, 2, "run.policy_applied", %{
        "mode" => "enforce",
        "allow" => ["docs.example.com", "api.anthropic.com"],
        "credentials" => [%{"name" => key_name(ctx.provider), "hosts" => ["api.anthropic.com"]}],
        "terminated" => ["api.anthropic.com", "files.example.com", "docs.example.com"],
        "tools" => [
          %{
            "name" => "files",
            "argument" => "acme/shop",
            "hosts" => ["files.example.com", "api.anthropic.com"]
          },
          %{"name" => "models", "hosts" => ["api.anthropic.com"]},
          %{"name" => "bare", "hosts" => []}
        ]
      })

      {:ok, run} = Projector.project(run)
      %{run: run}
    end

    test "leave out the operator's provider for a person of the client", ctx do
      policy = Record.policy(ctx.person, ctx.run)

      assert policy.terminated == ["files.example.com", "docs.example.com"]
      assert policy.terminated_count == 2

      # The tools stay, and so does their count.
      assert [
               %{"name" => "files", "hosts" => ["files.example.com"]},
               %{"name" => "models", "hosts" => []},
               %{"name" => "bare", "hosts" => []}
             ] = policy.tools

      assert policy.tools_count == 3
    end

    test "are all there for a person of the operator", ctx do
      policy = Record.policy(ctx.operator_person, ctx.run)

      assert policy.terminated_count == 3
      assert "api.anthropic.com" in policy.terminated

      assert [%{"hosts" => ["files.example.com", "api.anthropic.com"]}, %{"hosts" => hosts}, _] =
               policy.tools

      assert hosts == ["api.anthropic.com"]
    end

    test "are all there while operator_infrastructure is off", ctx do
      Flags.put_operator_infrastructure(false)
      policy = Record.policy(ctx.person, ctx.run)

      assert policy.terminated_count == 3
      assert "api.anthropic.com" in policy.terminated
      assert [%{"hosts" => ["files.example.com", "api.anthropic.com"]}, _, _] = policy.tools
    end

    # The policy lines of the run's timeline, as `Apiary.Runs.Record.items/4` reads them.
    defp policy_lines(scope, run) do
      index = Record.timeline(scope, run)
      for %{kind: :policy_applied} = line <- Record.items(scope, run, index.items), do: line
    end

    test "are left out of the policy line of the timeline for a person of the client", ctx do
      assert [line] = policy_lines(ctx.person, ctx.run)

      assert line.terminated == ["files.example.com", "docs.example.com"]
      assert line.terminated_count == 2
      assert [%{hosts: ["files.example.com"]}, %{hosts: []}, %{hosts: []}] = line.tools
      refute inspect(line) =~ "api.anthropic.com"
    end

    test "are all in the policy line of the timeline for a person of the operator", ctx do
      assert [line] = policy_lines(ctx.operator_person, ctx.run)

      assert "api.anthropic.com" in line.terminated
      assert line.terminated_count == 3
    end
  end

  describe "the workspace's connections" do
    setup ctx do
      operator_run = run!(ctx)
      connection!(operator_run, "api.anthropic.com", key_name(ctx.provider))
      connection!(operator_run, "files.example.com", "other-key")

      organisation_run = run!(ctx, "organisation")
      connection!(organisation_run, "api.anthropic.com", key_name(ctx.provider))

      none_run = run_fixture(ctx.person)
      connection!(none_run, "docs.example.com", nil)
      :ok
    end

    defp workspace_connections(scope) do
      scope
      |> Edition.client_reads(
        :workspace_connections,
        nil,
        from(c in Connection, join: r in Run, on: r.id == c.run_id)
      )
      |> Repo.all()
      |> hosts_of()
    end

    test "leave out those of the operator's provider for a person of the client", ctx do
      assert workspace_connections(ctx.person) ==
               ["api.anthropic.com", "docs.example.com", "files.example.com"]

      assert ctx.person
             |> Edition.client_reads(
               :workspace_connections,
               nil,
               from(c in Connection, join: r in Run, on: r.id == c.run_id)
             )
             |> Repo.aggregate(:count) == 3
    end

    test "are all there for a person of the operator", ctx do
      assert length(workspace_connections(ctx.operator_person)) == 4
    end

    test "are all there while operator_infrastructure is off", ctx do
      Flags.put_operator_infrastructure(false)
      assert length(workspace_connections(ctx.person)) == 4
    end
  end

  describe "the workspace's events" do
    setup ctx do
      operator_run = run!(ctx)
      egress!(operator_run, 1, "api.anthropic.com", key_name(ctx.provider))
      egress!(operator_run, 2, "files.example.com", "other-key")

      organisation_run = run!(ctx, "organisation")
      egress!(organisation_run, 1, "api.anthropic.com", key_name(ctx.provider))

      none_run = run_fixture(ctx.person)
      egress!(none_run, 1, "docs.example.com", nil)
      :ok
    end

    defp workspace_events(scope) do
      scope
      |> Edition.client_reads(
        :workspace_events,
        nil,
        from(e in Event, join: r in Run, on: r.id == e.run_id)
      )
      |> Repo.all()
      |> Enum.map(& &1.data["host"])
      |> Enum.sort()
    end

    test "leave out those of the operator's provider for a person of the client", ctx do
      assert workspace_events(ctx.person) ==
               ["api.anthropic.com", "docs.example.com", "files.example.com"]
    end

    test "are all there for a person of the operator", ctx do
      assert length(workspace_events(ctx.operator_person)) == 4
    end

    test "are all there while operator_infrastructure is off", ctx do
      Flags.put_operator_infrastructure(false)
      assert length(workspace_events(ctx.person)) == 4
    end
  end

  # A run claimed with two keys of the operator's provider, `<public id>-1` and
  # `<public id>-2`: a connection and an egress event of each key go to a host that is not
  # the provider's, so only the keys' names hide them.
  describe "a run with two model keys" do
    setup ctx do
      run = run_for!(ctx.person, ctx.provider, "operator", @api, 2)

      event_fixture(run, 1, "run.policy_applied", %{
        "mode" => "enforce",
        "allow" => ["api.anthropic.com", "files.example.com"],
        "credentials" => [
          %{"name" => key_name(ctx.provider, 1), "hosts" => ["api.anthropic.com"]},
          %{"name" => key_name(ctx.provider, 2), "hosts" => ["api.anthropic.com"]},
          %{"name" => "other-key", "hosts" => ["files.example.com"]}
        ]
      })

      egress!(run, 2, "first.example.com", key_name(ctx.provider, 1))
      egress!(run, 3, "second.example.com", key_name(ctx.provider, 2))
      egress!(run, 4, "files.example.com", "other-key")
      connection!(run, "first.example.com", key_name(ctx.provider, 1))
      connection!(run, "second.example.com", key_name(ctx.provider, 2))
      connection!(run, "files.example.com", "other-key")
      %{run: run}
    end

    defp workspace_rows(scope, kind, schema) do
      scope
      |> Edition.client_reads(kind, nil, from(r in schema, join: u in Run, on: u.id == r.run_id))
      |> Repo.all()
    end

    test "leave out the credential of each key for a person of the client", ctx do
      policy = Record.policy(ctx.person, ctx.run)
      assert Enum.map(policy.credentials, & &1["name"]) == ["other-key"]
      assert policy.credentials_count == 1
      assert policy.allow == ["files.example.com"]

      assert events_of(ctx.person, ctx.run) == [{nil, nil}, {"files.example.com", "other-key"}]
      assert run_hosts(ctx.person, ctx.run) == ["files.example.com"]

      assert ctx.person |> workspace_rows(:workspace_connections, Connection) |> hosts_of() ==
               ["files.example.com"]

      assert ctx.person
             |> workspace_rows(:workspace_events, Event)
             |> Enum.map(& &1.data["credential"])
             |> Enum.sort() == [nil, "other-key"]
    end

    test "are all there for a person of the operator", ctx do
      assert Record.policy(ctx.operator_person, ctx.run).credentials_count == 3
      assert length(events_of(ctx.operator_person, ctx.run)) == 4
      assert length(run_hosts(ctx.operator_person, ctx.run)) == 3
      assert length(workspace_rows(ctx.operator_person, :workspace_connections, Connection)) == 3
      assert length(workspace_rows(ctx.operator_person, :workspace_events, Event)) == 4
    end
  end

  # The run of two model keys once its provider row is deleted, beside a registry
  # credential. The keys' entries list `api.anthropic.com`, and the run's endpoint is a
  # host that no entry lists, so only the keys' names find the provider's entries: read by
  # its endpoint, every entry would be taken, the registry credential too.
  describe "a run with two model keys and its provider row deleted" do
    @gateway_api %{@api | "endpoint" => "https://gateway.provider.example"}

    setup ctx do
      run = run_for!(ctx.person, ctx.provider, "operator", @gateway_api, 2)

      event_fixture(run, 1, "run.policy_applied", %{
        "mode" => "enforce",
        "allow" => ["api.anthropic.com", "registry.example.com"],
        "credentials" => [
          %{"name" => key_name(ctx.provider, 1), "hosts" => ["api.anthropic.com"]},
          %{"name" => key_name(ctx.provider, 2), "hosts" => ["api.anthropic.com"]},
          %{"name" => "registry", "hosts" => ["registry.example.com"]}
        ]
      })

      egress!(run, 2, "first.example.com", key_name(ctx.provider, 1))
      egress!(run, 3, "second.example.com", key_name(ctx.provider, 2))
      egress!(run, 4, "api.anthropic.com", nil)
      egress!(run, 5, "registry.example.com", "registry")
      connection!(run, "first.example.com", key_name(ctx.provider, 1))
      connection!(run, "second.example.com", key_name(ctx.provider, 2))
      connection!(run, "api.anthropic.com", nil)
      connection!(run, "registry.example.com", "registry")

      run = nilified(ctx, run)
      assert run.provider_connection_id == nil
      %{run: run}
    end

    test "leave out each key and keep the registry credential for a person of the client",
         ctx do
      policy = Record.policy(ctx.person, ctx.run)
      assert Enum.map(policy.credentials, & &1["name"]) == ["registry"]
      assert policy.credentials_count == 1
      assert policy.allow == ["registry.example.com"]

      assert events_of(ctx.person, ctx.run) ==
               [{nil, nil}, {"registry.example.com", "registry"}]

      assert run_hosts(ctx.person, ctx.run) == ["registry.example.com"]

      assert ctx.person |> workspace_rows(:workspace_connections, Connection) |> hosts_of() ==
               ["registry.example.com"]

      assert ctx.person
             |> workspace_rows(:workspace_events, Event)
             |> Enum.map(& &1.data["credential"])
             |> Enum.sort() == [nil, "registry"]
    end

    test "are all there for a person of the operator", ctx do
      assert Record.policy(ctx.operator_person, ctx.run).credentials_count == 3
      assert length(events_of(ctx.operator_person, ctx.run)) == 5
      assert length(run_hosts(ctx.operator_person, ctx.run)) == 4
      assert length(workspace_rows(ctx.operator_person, :workspace_connections, Connection)) == 4
      assert length(workspace_rows(ctx.operator_person, :workspace_events, Event)) == 5
    end
  end

  # What the run recorded of its provider at its claim, in its `policy.applied` events.
  describe "the provider the run recorded" do
    @old_host "old.provider.example"
    @edited_api %{@api | "endpoint" => "https://old.provider.example"}
    @elsewhere_api %{@api | "endpoint" => "https://unlisted.provider.example"}

    defp policy!(run, sequence, credentials, allow) do
      event_fixture(run, sequence, "run.policy_applied", %{
        "mode" => "enforce",
        "allow" => allow,
        "allow_first" => allow,
        "credentials" => credentials
      })
    end

    # A run whose provider the claim recorded on `@old_host`, which the provider's row no
    # longer gives (its address was edited after the claim), beside a registry credential,
    # each with a connection and an egress event that carry no credential. With `keys` 0,
    # the run has no model keys, as a run claimed before model keys whose provider row was
    # deleted.
    defp recorded_run!(ctx, api \\ @api, chain \\ "operator", keys \\ 1) do
      run = run_for!(ctx.person, ctx.provider, chain, api, keys)

      policy!(
        run,
        1,
        [
          %{"name" => key_name(ctx.provider), "hosts" => [@old_host]},
          %{"name" => "registry", "hosts" => ["registry.example.com"]}
        ],
        [@old_host, "registry.example.com", "docs.example.com"]
      )

      for {host, n} <- Enum.with_index([@old_host, "registry.example.com", "docs.example.com"], 2) do
        connection!(run, host, nil)
        egress!(run, n, host, nil)
      end

      run
    end

    # The provider's row deleted: the run's reference to it is set to nil.
    defp nilified(ctx, run) do
      {1, _} = Repo.delete_all(from c in ProviderRow, where: c.id == ^ctx.provider.id)
      Repo.get!(Run, run.id)
    end

    # The hosts of the egress events read; the `policy.applied` event has none, and is read.
    defp event_hosts(scope, run) do
      scope |> events_of(run) |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.sort()
    end

    test "hides a connection to its host that carries no credential", ctx do
      run = recorded_run!(ctx)

      assert run_hosts(ctx.person, run) == ["docs.example.com", "registry.example.com"]
      assert run_hosts(ctx.operator_person, run) |> length() == 3
    end

    test "hides an egress event to its host that carries no credential", ctx do
      run = recorded_run!(ctx)

      assert event_hosts(ctx.person, run) == ["docs.example.com", "registry.example.com"]
      assert length(event_hosts(ctx.operator_person, run)) == 3
    end

    test "takes its hosts from the record, not from the row as it is now", ctx do
      run = recorded_run!(ctx)
      policy = Record.policy(ctx.person, run)

      assert policy.allow == ["registry.example.com", "docs.example.com"]
      assert policy.allow_count == 2
      assert Enum.map(policy.credentials, & &1["name"]) == ["registry"]
    end

    test "narrows each policy map by its own credentials", ctx do
      run = recorded_run!(ctx)
      name = key_name(ctx.provider)

      first = %{
        allow: ["a.example.com", "docs.example.com"],
        allow_count: 2,
        allow_first: [],
        allow_first_count: 0,
        credentials: [%{"name" => name, "hosts" => ["a.example.com"]}],
        credentials_count: 1
      }

      second = %{
        first
        | allow: ["b.example.com", "a.example.com"],
          credentials: [%{"name" => name, "hosts" => ["b.example.com"]}]
      }

      narrowed = fn policy -> Edition.client_reads(ctx.person, :run_policy, run, policy) end

      assert %{allow: ["docs.example.com"], allow_count: 1, credentials: [], credentials_count: 0} =
               narrowed.(first)

      assert %{allow: ["a.example.com"], allow_count: 1, credentials: [], credentials_count: 0} =
               narrowed.(second)
    end

    test "with its row gone and no model keys, is found by the run's endpoint", ctx do
      run = nilified(ctx, recorded_run!(ctx, @edited_api, "operator", 0))

      assert run.provider_connection_id == nil
      assert run_hosts(ctx.person, run) == ["docs.example.com", "registry.example.com"]
      assert event_hosts(ctx.person, run) == ["docs.example.com", "registry.example.com"]

      policy = Record.policy(ctx.person, run)
      assert policy.allow == ["registry.example.com", "docs.example.com"]
      assert Enum.map(policy.credentials, & &1["name"]) == ["registry"]
      assert length(run_hosts(ctx.operator_person, run)) == 3
    end

    test "with its row gone, no model keys and no entry found, hides every entry", ctx do
      run = nilified(ctx, recorded_run!(ctx, @elsewhere_api, "operator", 0))

      policy = Record.policy(ctx.person, run)
      assert policy.credentials == []
      assert policy.credentials_count == 0
      assert policy.allow == ["docs.example.com"]
      assert run_hosts(ctx.person, run) == ["docs.example.com"]
      assert event_hosts(ctx.person, run) == ["docs.example.com"]
    end

    test "with its row gone and no events, hides a connection to the endpoint host", ctx do
      run = nilified(ctx, run!(ctx))
      connection!(run, "api.anthropic.com", "con_gone_row")
      connection!(run, "docs.example.com", nil)

      assert run_hosts(ctx.person, run) == ["docs.example.com"]
      assert run_hosts(ctx.operator_person, run) == ["api.anthropic.com", "docs.example.com"]
    end

    test "with its row and no events, hides a connection to the endpoint host", ctx do
      run = run!(ctx)
      connection!(run, "api.anthropic.com", "other-key")
      connection!(run, "docs.example.com", nil)

      assert run_hosts(ctx.person, run) == ["docs.example.com"]
      assert run_hosts(ctx.operator_person, run) |> length() == 2
    end

    test "takes the hosts of a policy map from the record when the map cut the entry", ctx do
      run = recorded_run!(ctx)

      cut = %{
        allow: [@old_host, "docs.example.com"],
        allow_count: 2,
        allow_first: [@old_host],
        allow_first_count: 1,
        credentials: [],
        credentials_count: 0
      }

      assert %{allow: ["docs.example.com"], allow_count: 1, allow_first: [], allow_first_count: 0} =
               Edition.client_reads(ctx.person, :run_policy, run, cut)
    end
  end

  describe "the workspace's rows once the events are pruned" do
    setup ctx do
      # Retention deletes a run's events and keeps its connections, so a run has rows to
      # the provider's endpoint host and no `policy.applied` event: one with its provider
      # row, one without, and one of the organisation's chain.
      live = pruned_run!(ctx, ctx.provider)
      other = other_provider!(ctx)
      gone = pruned_run!(ctx, other)
      {1, _} = Repo.delete_all(from c in ProviderRow, where: c.id == ^other.id)
      organisation = run!(ctx, "organisation")
      add_rows!(organisation)

      %{live: live, gone: gone, organisation: organisation}
    end

    defp pruned_run!(ctx, provider) do
      run = run_for!(ctx.person, provider, "operator", @api)
      add_rows!(run)
      run
    end

    defp add_rows!(run) do
      connection!(run, "api.anthropic.com", "other-key")
      connection!(run, "docs.example.com", nil)
      egress!(run, 1, "api.anthropic.com", "other-key")
      egress!(run, 2, "docs.example.com", nil)
    end

    test "hide the connections to the endpoint host", ctx do
      seen = rows_by_run(ctx.person, :workspace_connections, Connection, :host)

      assert seen[ctx.live.id] == ["docs.example.com"]
      assert seen[ctx.gone.id] == ["docs.example.com"]
      assert seen[ctx.organisation.id] == ["api.anthropic.com", "docs.example.com"]
    end

    test "hide the egress events to the endpoint host", ctx do
      seen = rows_by_run(ctx.person, :workspace_events, Event, :data)
      seen = Map.new(seen, fn {id, data} -> {id, Enum.map(data, & &1["host"])} end)

      assert seen[ctx.live.id] == ["docs.example.com"]
      assert seen[ctx.gone.id] == ["docs.example.com"]
      assert length(seen[ctx.organisation.id]) == 2
    end
  end

  describe "the workspace's rows by the provider the run recorded" do
    setup ctx do
      # Two runs whose row is live, on the row's endpoint and on an edited one; one whose
      # row is gone, found by its key's name on an endpoint no entry lists; two with no
      # model keys whose row is gone, one found by its endpoint and one not found; and one
      # of the organisation's chain: each with a connection and an egress event to the
      # recorded host that carry no credential.
      live = recorded_run!(ctx)
      found = recorded_run!(ctx, @edited_api)
      organisation = recorded_run!(ctx, @api, "organisation")

      # The provider is the same row for the three, so the runs of a gone row are made
      # with another row, deleted after.
      other = %{ctx | provider: other_provider!(ctx)}
      keyed = recorded_run!(other, @elsewhere_api)
      gone = recorded_run!(other, @edited_api, "operator", 0)
      unfound = recorded_run!(other, @elsewhere_api, "operator", 0)
      {1, _} = Repo.delete_all(from c in ProviderRow, where: c.id == ^other.provider.id)

      %{
        live: live,
        found: found,
        organisation: organisation,
        keyed: keyed,
        gone: gone,
        unfound: unfound
      }
    end

    defp other_provider!(ctx) do
      Flags.put_operator_infrastructure(false)

      {:ok, provider} =
        Connections.create_provider(ctx.client.owner.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-fixture-model-key-9876543210"}]
        })

      Flags.put_operator_infrastructure(true)
      provider
    end

    defp rows_by_run(scope, kind, schema, key) do
      scope
      |> Edition.client_reads(kind, nil, from(r in schema, join: u in Run, on: u.id == r.run_id))
      |> Repo.all()
      |> Enum.group_by(& &1.run_id, &Map.fetch!(&1, key))
      |> Map.new(fn {run_id, hosts} -> {run_id, Enum.sort(hosts)} end)
    end

    test "hide the connections to a recorded host in each way a provider is found", ctx do
      seen = rows_by_run(ctx.person, :workspace_connections, Connection, :host)
      docs = ["docs.example.com"]
      both = ["docs.example.com", "registry.example.com"]

      assert seen[ctx.live.id] == both
      assert seen[ctx.found.id] == both
      assert seen[ctx.keyed.id] == both
      assert seen[ctx.gone.id] == both
      assert seen[ctx.unfound.id] == docs
      assert length(seen[ctx.organisation.id]) == 3

      all = rows_by_run(ctx.operator_person, :workspace_connections, Connection, :host)
      assert Enum.all?(Map.values(all), &(length(&1) == 3))
    end

    test "hide the egress events to a recorded host in each way a provider is found", ctx do
      seen =
        ctx.person
        |> Edition.client_reads(
          :workspace_events,
          nil,
          from(e in Event,
            join: r in Run,
            on: r.id == e.run_id,
            where: e.type == "dev.qory.run.egress"
          )
        )
        |> Repo.all()
        |> Enum.group_by(& &1.run_id, & &1.data["host"])
        |> Map.new(fn {id, hosts} -> {id, Enum.sort(hosts)} end)

      both = ["docs.example.com", "registry.example.com"]

      assert seen[ctx.live.id] == both
      assert seen[ctx.found.id] == both
      assert seen[ctx.keyed.id] == both
      assert seen[ctx.gone.id] == both
      assert seen[ctx.unfound.id] == ["docs.example.com"]
      assert length(seen[ctx.organisation.id]) == 3
    end
  end

  test "an organisation without an operator is read as it is" do
    %{scope: scope, organisation: organisation} = Apiary.OrganisationsFixtures.sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-fixture-model-key-0123456789"}]
      })

    run = run_for!(scope, provider, "operator", @api)
    assert organisation.id == run.organisation_id
    egress!(run, 1, "api.anthropic.com", key_name(provider))
    assert [{"api.anthropic.com", _}] = events_of(scope, run)
  end
end
