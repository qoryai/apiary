defmodule ApiaryWeb.Contract.SecretsAcrossTest do
  # A run's model key and the gateway's organisation (`Apiary.Runs.ProviderCredential`):
  # a key of a provider of the organisation's chain goes only to a gateway of the run's
  # organisation or to the instance's gateway, and a key of a provider of an operator's
  # chain only to a gateway of an operator that serves the run's organisation or to the
  # instance's gateway, at the claim and at the secrets request. A run's work credential
  # goes to the run's gateway as a key of the organisation's chain does, and also to the
  # gateway of an organisation that serves the run's (`Apiary.Runs.WorkCredential`). The
  # edition's seams are `Apiary.EditionStubs.ServesAcrossWithChain`: the
  # operator's organisation-level gateways serve the client's workspaces. Not async, as the
  # other contract tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{
    AccessKeys,
    Connections,
    Dispatches,
    Edition,
    EditionStubs,
    ModelChoices,
    Repo,
    WorkCredentialStub
  }

  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Runs.{Attach, Registration, Run, Sender}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  # Without the `registry` feature, whose credential `ApiaryWeb.RegistryTokenTest`
  # covers: the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  @api %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "header", "header" => "x-api-key"}
  }

  setup do
    %{scope: client} = sign_up_fixture()
    %{scope: operator} = sign_up_fixture()
    :ok = Edition.put_test_stub(EditionStubs.ServesAcrossWithChain)
    EditionStubs.ServesAcross.put([{operator.organisation.id, client.organisation.id}])

    {:ok, provider} =
      Connections.create_provider(client, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: model_key()}]
      })

    %{client: client, operator: operator, provider: provider}
  end

  # A gateway with one key allowed stored secrets, as a verified request carries it, and
  # the key's seed.
  defp keyed(scope, gateway) do
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, gateway, %{allow_secrets: true})
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    {key, pair.secret}
  end

  defp operator_gateway(ctx), do: keyed(ctx.operator, organisation_gateway_fixture(ctx.operator))
  defp client_gateway(ctx), do: keyed(ctx.client, gateway_fixture(ctx.client))

  # The instance's gateway, the default of every workspace that has no other default, with
  # one key allowed stored secrets.
  defp instance_gateway do
    %{access_key: key, pair: pair} =
      installed_key_fixture(instance_gateway_fixture(), allow_secrets: true)

    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    {key, pair.secret}
  end

  # A pool of the client's workspace, made after its gateway, whose choice is the default,
  # and an explore run of a fresh work item claimed by its key: `{:ok, %{run: run,
  # run_key: run_key}}`, the registered run and the run key its code was redeemed for, or
  # `{:error, :gone}` for a run the claim ended; and the run of the queue.
  #
  # With `apply`, the work item's adapter declares those apply items and its ticket's
  # collection can change its target (`Apiary.WorkItemsFixtures.target_candidate!/1`), so
  # the run has the work entry `work-1`, and the map also has `adapter_seed`, to sign the stub adapter's
  # answers with (`Apiary.SealedRunsFixtures.callable_adapter_fixture/2`).
  defp hand_over(ctx_or_scope, apply \\ nil)

  defp hand_over(%{client: client}, apply), do: hand_over(client, apply)

  defp hand_over(scope, apply) do
    pool = pool_fixture(scope)
    :default = pool.gateway_choice
    %{access_key: pool_key} = enrolled_key_fixture(scope, pool)
    work_item = work_item_fixture(scope)
    adapter = if apply, do: callable_adapter_fixture(work_item.adapter_id, apply), else: %{}
    if apply, do: target_candidate!(work_item)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    case Dispatches.claim(pool_key, Dispatches.now()) do
      {:ok, :none} ->
        {{:error, :gone}, queued}

      {:ok, claimed} ->
        run_key = redeemed_run_key!(claimed.run_code)
        handed = %{run: claimed.registered, run_key: run_key}
        {{:ok, Map.merge(handed, Map.take(adapter, [:adapter_seed]))}, queued}
    end
  end

  defp attach!({key, _seed}, handed) do
    {:ok, attach} = Attach.parse(attach_body(handed.run_key))

    {:ok, _attached} =
      Attach.attach(key, handed.run.node_run_id, attach, %{
        forager_version: "0.7.0",
        instance_id: instance_id()
      })

    Repo.get!(Run, handed.run.id)
  end

  # The provider written on the run past the claim, as a run whose claim set it would keep
  # it.
  defp set_provider!(%Run{id: id}, provider, chain) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [
          provider_connection_id: provider.id,
          provider_secret_id: provider.secret_id,
          provider_value_id: "main",
          provider_chain: chain,
          provider_api: @api
        ]
      )

    Repo.get!(Run, id)
  end

  # A provider of the operator's chain, made in the operator's organisation, with the
  # operator's choice of that chain for its clients (unless `choose?` is false); the edition
  # then returns "operator" for every organisation, and the operator serves the client.
  defp operator_chain!(ctx, choose? \\ true) do
    EditionStubs.ServesAcrossWithChain.writer(true)

    {:ok, provider} =
      Connections.create_provider(ctx.operator, %{
        provider: "anthropic",
        chain: "operator",
        keys: [%{value_id: "main", value: model_key()}]
      })

    if choose? do
      {:ok, %ModelChoice{}} =
        ModelChoices.put_choice(
          ctx.operator,
          :organisation,
          %{provider: provider.public_id},
          "operator"
        )
    end

    EditionStubs.ServesAcrossWithChain.chain("operator")
    provider
  end

  # The digest a reload of `run` by `key` returns now.
  defp digest({key, _seed}, run) do
    {:ok, %{digest: digest}} = Registration.fetch(key, run.node_run_id, instance_id())
    digest
  end

  defp post_secrets({key, seed}, run, digest, provider) do
    body = secrets_request(run, digest, [provider.public_id], SignedRequest.now())

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp seals, do: Repo.all(from e in Entry, where: e.action == "secret.seal")

  defp seals_of(scope),
    do: Enum.filter(seals(), &(&1.organisation_id == scope.organisation.id))

  defp ended!(queued) do
    assert %DispatchRun{state: :ended, end_cause: :secrets_not_allowed, result_outcome: :error} =
             Repo.get!(DispatchRun, queued.id)

    assert Repo.aggregate(from(r in Run, where: r.dispatch_run_id == ^queued.id), :count) == 0
  end

  describe "a provider of the organisation's chain" do
    test "ends the run at the claim through an operator's gateway", ctx do
      operator_gateway(ctx)

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.client, :workspace, %{provider: ctx.provider.public_id})

      {answer, queued} = hand_over(ctx)
      assert answer == {:error, :gone}
      ended!(queued)
    end

    test "is not sealed for an operator's gateway that serves the client", ctx do
      gateway_key = operator_gateway(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = gateway_key |> attach!(handed) |> set_provider!(ctx.provider, "organisation")

      {conn, log} =
        with_log(fn -> post_secrets(gateway_key, run, digest(gateway_key, run), ctx.provider) end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert signed_answer?(conn)
      assert log =~ "#{ctx.provider.public_id} may not be sealed for its gateway (gateway)"
      refute log =~ model_key()
      assert seals() == []
    end
  end

  describe "a provider of an operator's chain" do
    test "is sealed for the operator's gateway, in the operator's trail", ctx do
      gateway_key = operator_gateway(ctx)
      provider = operator_chain!(ctx)

      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      assert run.provider_chain == "operator"

      conn = post_secrets(gateway_key, run, digest(gateway_key, run), provider)
      assert conn.status == 200
      assert signed_answer?(conn)
      # In the operator's trail, about its gateway, with the run's id.
      {key, _seed} = gateway_key
      assert [%Entry{} = entry] = seals()
      assert entry.organisation_id == ctx.operator.organisation.id
      assert {entry.subject_kind, entry.subject_id} == {"node", key.node_id}
      assert entry.details["run_id"] == run.node_run_id
    end

    test "is refused once the organisation's chain is no longer the operator's", ctx do
      gateway_key = operator_gateway(ctx)
      provider = operator_chain!(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)

      EditionStubs.ServesAcrossWithChain.chain("organisation")

      {conn, log} = with_log(fn -> post_secrets(gateway_key, run, digest, provider) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "may not be sealed for its gateway (gateway)"
      assert seals() == []
    end

    test "410 workspace_not_served once the operator no longer serves the client", ctx do
      gateway_key = operator_gateway(ctx)
      provider = operator_chain!(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)

      EditionStubs.ServesAcross.switch(:off)

      conn = post_secrets(gateway_key, run, digest, provider)
      assert conn.status == 410
      assert code(conn) == "workspace_not_served"
      assert signed_answer?(conn)
      assert seals() == []
    end

    test "ends the run at the claim through the client's gateway", ctx do
      client_gateway(ctx)
      operator_chain!(ctx)

      {answer, queued} = hand_over(ctx)
      assert answer == {:error, :gone}
      ended!(queued)
    end

    test "is not sealed for the client's gateway", ctx do
      gateway_key = client_gateway(ctx)
      # No choice of the operator's chain: the run is claimed with the runtime alone.
      provider = operator_chain!(ctx, false)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = gateway_key |> attach!(handed) |> set_provider!(provider, "operator")

      {conn, log} =
        with_log(fn -> post_secrets(gateway_key, run, digest(gateway_key, run), provider) end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{provider.public_id} may not be sealed for its gateway (gateway)"
      assert seals() == []
    end
  end

  # A provider made in `scope`'s organisation, on `chain`; the edition lets any scope write
  # the operator's chain.
  defp provider_in(scope, chain) do
    EditionStubs.ServesAcrossWithChain.writer(true)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        chain: chain,
        keys: [%{value_id: "main", value: model_key()}]
      })

    provider
  end

  # The secrets request of a run that kept `provider` on `chain`, through the operator's
  # gateway: the answer and the log.
  defp refused_organisation(ctx, provider, chain) do
    gateway_key = operator_gateway(ctx)
    operator_chain!(ctx, false)
    {{:ok, handed}, _queued} = hand_over(ctx)
    run = gateway_key |> attach!(handed) |> set_provider!(provider, chain)

    with_log(fn -> post_secrets(gateway_key, run, digest(gateway_key, run), provider) end)
  end

  describe "a provider that is not a row of the organisation its chain is made of" do
    test "of an operator's chain, in an organisation other than the operator's", ctx do
      %{scope: stranger} = sign_up_fixture()
      provider = provider_in(stranger, "operator")

      {conn, log} = refused_organisation(ctx, provider, "operator")
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{provider.public_id} may not be sealed for its gateway (organisation)"
      refute log =~ model_key()
      assert seals() == []
    end

    test "of an operator's chain, in the client's organisation", ctx do
      provider = provider_in(ctx.client, "operator")

      {conn, log} = refused_organisation(ctx, provider, "operator")
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{provider.public_id} may not be sealed for its gateway (organisation)"
      assert seals() == []
    end

    test "of the organisation's chain, in the operator's organisation", ctx do
      provider = provider_in(ctx.operator, "organisation")

      {conn, log} = refused_organisation(ctx, provider, "organisation")
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{provider.public_id} may not be sealed for its gateway (organisation)"
      assert seals() == []
    end
  end

  @apply [
    %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/{target.path}/*"]}
  ]
  @entry_apply [
    %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/acme/shop/*"]}
  ]
  @token "fixture-work-token-across-0001"

  defp issues, do: Repo.all(from e in Entry, where: e.action == "run_credential.issue")

  # The secrets request for the run's work entry alone, its credential issued by the stub
  # adapter.
  defp post_work({key, seed}, handed, run, digest) do
    WorkCredentialStub.issue(
      handed.adapter_seed,
      WorkCredentialStub.credential(@token, @entry_apply)
    )

    body = secrets_request(run, digest, ["work-1"], SignedRequest.now())

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  describe "a run's work credential" do
    test "is sealed for an operator's gateway that serves the client, in the client's trail",
         ctx do
      gateway_key = operator_gateway(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx, @apply)
      run = attach!(gateway_key, handed)

      conn = post_work(gateway_key, handed, run, digest(gateway_key, run))
      assert conn.status == 200, conn.resp_body
      assert signed_answer?(conn)

      # In the run's organisation's trail, about the run, by the operator's gateway's key.
      {key, _seed} = gateway_key
      assert [%Entry{} = entry] = issues()
      assert entry.organisation_id == ctx.client.organisation.id
      assert {entry.subject_kind, entry.subject_id} == {"run", run.id}
      assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
      assert entry.details["outcome"] == "issued"
      assert seals() == []
    end

    test "is sealed for the instance's gateway, in the run's organisation's trail", ctx do
      gateway_key = instance_gateway()
      {{:ok, handed}, _queued} = hand_over(ctx, @apply)
      run = attach!(gateway_key, handed)

      conn = post_work(gateway_key, handed, run, digest(gateway_key, run))
      assert conn.status == 200, conn.resp_body

      {key, _seed} = gateway_key
      assert [%Entry{} = entry] = issues()
      assert entry.organisation_id == ctx.client.organisation.id
      assert entry.workspace_id == ctx.client.workspace.id
      assert {entry.subject_kind, entry.subject_id} == {"run", run.id}
      assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
    end

    test "is refused once the operator no longer serves the client, before any call", ctx do
      gateway_key = operator_gateway(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx, @apply)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)

      EditionStubs.ServesAcross.switch(:off)

      conn = post_work(gateway_key, handed, run, digest)
      assert conn.status == 410
      assert code(conn) == "workspace_not_served"
      assert WorkCredentialStub.calls() == []
      assert issues() == []
    end
  end

  describe "the instance's gateway" do
    test "is sealed a key of each organisation's chain, in each run's organisation's trail",
         ctx do
      gateway_key = instance_gateway()

      {:ok, theirs} =
        Connections.create_provider(ctx.operator, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: model_key()}]
        })

      for {scope, provider} <- [{ctx.client, ctx.provider}, {ctx.operator, theirs}] do
        {:ok, _choice} =
          ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

        {{:ok, handed}, _queued} = hand_over(scope)
        run = attach!(gateway_key, handed)
        assert run.organisation_id == scope.organisation.id
        assert run.provider_chain == "organisation"

        conn = post_secrets(gateway_key, run, digest(gateway_key, run), provider)
        assert conn.status == 200
        assert signed_answer?(conn)

        # In the run's organisation's trail, about the run, by the gateway's key.
        {key, _seed} = gateway_key
        assert [%Entry{} = entry] = seals_of(scope)
        assert {entry.subject_kind, entry.subject_id} == {"run", run.id}
        assert entry.workspace_id == scope.workspace.id
        assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
        assert entry.details["provider_id"] == provider.public_id
      end

      assert length(seals()) == 2
    end

    test "is sealed a key of an operator's chain, in the operator's trail only", ctx do
      gateway_key = instance_gateway()
      provider = operator_chain!(ctx)

      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      assert run.provider_chain == "operator"

      conn = post_secrets(gateway_key, run, digest(gateway_key, run), provider)
      assert conn.status == 200
      assert signed_answer?(conn)

      # The client's people read nothing of the operator's provider: the entry is in the
      # operator's trail, about the instance's gateway, with the run's id.
      {key, _seed} = gateway_key
      assert seals_of(ctx.client) == []
      assert [%Entry{} = entry] = seals_of(ctx.operator)
      assert {entry.subject_kind, entry.subject_id} == {"node", key.node_id}
      assert entry.workspace_id == nil
      assert entry.details["run_id"] == run.node_run_id
      assert entry.details["provider_id"] == provider.public_id
    end

    test "is refused a key of an operator's chain when the edition names no operator", ctx do
      gateway_key = instance_gateway()
      provider = operator_chain!(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)

      EditionStubs.ServesAcrossWithChain.operator(nil)

      {conn, log} = with_log(fn -> post_secrets(gateway_key, run, digest, provider) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "may not be sealed for its gateway (gateway)"
      assert seals() == []
    end

    test "the instance pool's key is never sealed the key of a run it claimed", ctx do
      gateway_key = instance_gateway()

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.client, :workspace, %{provider: ctx.provider.public_id})

      %{access_key: pool_key, pair: pair} =
        installed_key_fixture(instance_pool_fixture(), allow_secrets: true)

      {:ok, pool_key} = AccessKeys.fetch_for_verification(pool_key.key_id)

      # The client's workspace has no pool in use: the instance's pool claims its run,
      # which goes through the instance's gateway.
      work_item = work_item_fixture(ctx.client)
      {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      {:ok, claimed} = Dispatches.claim(pool_key, Dispatches.now())
      handed = %{run: claimed.registered, run_key: redeemed_run_key!(claimed.run_code)}
      run = attach!(gateway_key, handed)
      assert run.node_id == pool_key.node_id
      digest = digest(gateway_key, run)

      # The pool's key reads the run, as its pool claimed it: the refusal is of the key,
      # which the run key does not list among the gateway's keys.
      assert %Run{id: id} = Repo.one(Sender.run_query(pool_key, run.node_run_id))
      assert id == run.id

      conn = post_secrets({pool_key, pair.secret}, run, digest, ctx.provider)
      assert conn.status == 404
      assert code(conn) == "not_found"
      assert seals() == []
    end
  end
end
