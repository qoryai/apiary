defmodule ApiaryPro.OperatorChainSecretsTest do
  # A run's model key through the edition (`Apiary.Runs.ProviderCredential`,
  # `Apiary.Runs.SecretsRequest`): a client whose switch is the operator's
  # (`ApiaryPro.Operators.set_model_chain/3`) resolves the operator's providers and
  # choices, and the key is sealed for a gateway of the operator, in the operator's trail;
  # a client on the default, a client of another operator and a client that was dropped
  # get none. Not async: an operator is made by an instance admin, an owner of the suite's
  # one instance organisation, the flag is set per test process, and the features are the
  # whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.SealedRunsFixtures
  import Apiary.WorkItemsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{AccessKeys, Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Runs.{Attach, ProviderCredential, Registration, Run}
  alias ApiaryPro.{Edition, Flags, Transfers}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag with_features: Apiary.Features.all()
  # Without the `registry` feature, whose credential `ApiaryWeb.RegistryTokenTest`
  # covers: the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  @api %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "header", "header" => "x-api-key"}
  }

  # An operator with three clients (the first on its switch, the second on the default,
  # the third dropped later), and another operator with a client whose switch is its
  # operator's, all made while the flag is off, then the flag on. Each operator has an
  # organisation-level gateway with one key allowed stored secrets.
  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    on = client_fixture(operator.scope)
    off = client_fixture(operator.scope)
    dropped = client_fixture(operator.scope)

    elsewhere = operator_fixture()
    other_client = client_fixture(elsewhere.scope)

    Flags.put_operator_infrastructure(true)

    on = model_chain_fixture(operator.scope, on, :operator)
    dropped = model_chain_fixture(operator.scope, dropped, :operator)
    other_client = model_chain_fixture(elsewhere.scope, other_client, :operator)

    %{
      operator: operator,
      on: on,
      off: off,
      dropped: dropped,
      elsewhere: elsewhere,
      other_client: other_client
    }
  end

  # An organisation-level gateway of the operator, with one key allowed stored secrets, as
  # a verified request carries it, and the key's seed.
  defp gateway_of(operator) do
    gateway = organisation_gateway_fixture(operator.scope)

    %{access_key: key, pair: pair} =
      enrolled_key_fixture(operator.scope, gateway, %{allow_secrets: true})

    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    {gateway, {key, pair.secret}}
  end

  # The operator's provider of its chain, with its choice (unless `choose?` is false).
  defp operator_chain!(operator, choose? \\ true) do
    {:ok, provider} =
      Connections.create_provider(operator.scope, %{
        provider: "anthropic",
        chain: "operator",
        keys: [%{value_id: "main", value: model_key()}]
      })

    if choose? do
      {:ok, _choice} =
        ModelChoices.put_choice(
          operator.scope,
          :organisation,
          %{provider: provider.public_id},
          "operator"
        )
    end

    provider
  end

  # A pool of the client's workspace, made by its operator's person after the operator's
  # gateway, whose choice is the default, and an explore run of a fresh work item of the
  # client's owner, claimed by the pool's key once its harness walk is resolved
  # (`Apiary.DispatchedRunsFixtures.walked_claim/3`): the registered run and the run key
  # its code was redeemed for, or `:gone` for a run the claim ended.
  defp hand_over(client) do
    pool = pool_fixture(client.scope)
    :default = pool.gateway_choice
    %{access_key: pool_key} = enrolled_key_fixture(client.scope, pool)
    work_item = work_item_fixture(client.owner.scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    case walked_claim(pool_key, Dispatches.now()) do
      {:ok, :none} ->
        :gone

      {:ok, claimed} ->
        {:ok, %{run: claimed.registered, run_key: redeemed_run_key!(claimed.run_code)}}
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
  # it: its key `main`, the credential `<public id>-1`.
  defp set_provider!(%Run{id: id}, provider, chain) do
    value_id =
      Repo.one!(
        from v in Apiary.Secrets.Value,
          where: v.secret_id == ^provider.secret_id and v.value_id == "main",
          select: v.id
      )

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [
          provider_connection_id: provider.id,
          provider_secret_id: provider.secret_id,
          model_keys: [%{"id" => value_id, "name" => "#{provider.public_id}-1"}],
          provider_chain: chain,
          provider_api: @api
        ]
      )

    Repo.get!(Run, id)
  end

  defp digest({key, _seed}, run) do
    {:ok, %{digest: digest}} = Registration.fetch(key, run.node_run_id, instance_id())
    digest
  end

  defp post_secrets({key, seed}, run, digest, provider) do
    body = secrets_request(run, digest, ["#{provider.public_id}-1"], SignedRequest.now())

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp seals, do: Repo.all(from e in Entry, where: e.action == "secret.seal")

  defp seals_in(%{organisation: %{id: id}}), do: Enum.filter(seals(), &(&1.organisation_id == id))

  describe "a client whose switch is the operator's" do
    test "resolves the operator's provider and choice at the claim", ctx do
      {_gateway, gateway_key} = gateway_of(ctx.operator)
      provider = operator_chain!(ctx.operator)

      assert {:ok, handed} = hand_over(ctx.on)
      run = attach!(gateway_key, handed)

      assert run.organisation_id == ctx.on.organisation.id
      assert run.provider_chain == "operator"
      assert run.provider_connection_id == provider.id
    end

    test "is sealed the key for the operator's gateway, in the operator's trail only", ctx do
      {_gateway, gateway_key} = gateway_of(ctx.operator)
      provider = operator_chain!(ctx.operator)

      assert {:ok, handed} = hand_over(ctx.on)
      run = attach!(gateway_key, handed)

      conn = post_secrets(gateway_key, run, digest(gateway_key, run), provider)
      assert conn.status == 200
      assert signed_answer?(conn)

      {key, _seed} = gateway_key
      assert [%Entry{} = entry] = seals()
      assert entry.organisation_id == ctx.operator.organisation.id
      assert {entry.subject_kind, entry.subject_id} == {"node", key.node_id}
      assert entry.details["run_id"] == run.node_run_id
      assert entry.details["provider_id"] == provider.public_id
      assert seals_in(ctx.on) == []
      assert seals_in(ctx.off) == []
    end

    test "is refused the key once its switch is the organisation's", ctx do
      {_gateway, gateway_key} = gateway_of(ctx.operator)
      provider = operator_chain!(ctx.operator)
      assert {:ok, handed} = hand_over(ctx.on)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)

      set_switch(ctx, :organisation)

      {conn, log} = with_log(fn -> post_secrets(gateway_key, run, digest, provider) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "may not be sealed for its gateway (gateway)"
      refute log =~ model_key()
      assert seals() == []
    end
  end

  # The client `ctx.on` set to `chain` by its operator's owner.
  defp set_switch(ctx, chain) do
    {:ok, client} =
      ApiaryPro.Operators.set_model_chain(ctx.operator.scope, ctx.on.organisation.id, chain)

    client
  end

  describe "a client whose switch is the organisation's" do
    test "gets no operator provider at the claim, and no key is sealed", ctx do
      {_gateway, gateway_key} = gateway_of(ctx.operator)
      provider = operator_chain!(ctx.operator)

      assert {:ok, handed} = hand_over(ctx.off)
      run = attach!(gateway_key, handed)
      assert run.provider_connection_id == nil

      # A run that kept the operator's provider all the same is refused its key.
      run = set_provider!(run, provider, "operator")

      {conn, log} =
        with_log(fn -> post_secrets(gateway_key, run, digest(gateway_key, run), provider) end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{provider.public_id} may not be sealed for its gateway (gateway)"
      refute log =~ model_key()
      assert seals() == []
    end
  end

  describe "a client of another operator" do
    test "gets no provider of the first operator, and no key is sealed", ctx do
      {_gateway, first_key} = gateway_of(ctx.operator)
      {_gateway, second_key} = gateway_of(ctx.elsewhere)
      provider = operator_chain!(ctx.operator)

      # Its operator has no provider and no choice: the run is claimed with the runtime
      # alone.
      assert {:ok, handed} = hand_over(ctx.other_client)
      run = attach!(second_key, handed)
      assert run.provider_connection_id == nil

      run = set_provider!(run, provider, "operator")

      digest = digest(second_key, run)

      {conn, log} = with_log(fn -> post_secrets(second_key, run, digest, provider) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{provider.public_id} may not be sealed for its gateway (organisation)"
      refute log =~ model_key()

      # The first operator's gateway does not serve the run at all.
      {conn, _log} = with_log(fn -> post_secrets(first_key, run, digest, provider) end)
      refute conn.status == 200

      assert seals() == []
    end

    test "is sealed a key of its operator's chain for its operator's gateway", ctx do
      {_gateway, gateway_key} = gateway_of(ctx.elsewhere)
      provider = operator_chain!(ctx.elsewhere)

      assert {:ok, handed} = hand_over(ctx.other_client)
      run = attach!(gateway_key, handed)
      assert run.provider_connection_id == provider.id

      conn = post_secrets(gateway_key, run, digest(gateway_key, run), provider)
      assert conn.status == 200

      assert [%Entry{organisation_id: organisation_id}] = seals()
      assert organisation_id == ctx.elsewhere.organisation.id
      assert seals_in(ctx.operator) == []
    end
  end

  describe "a client that was dropped" do
    test "gets no operator provider, and its switch reads the organisation's", ctx do
      {gateway, _gateway_key} = gateway_of(ctx.operator)
      _provider = operator_chain!(ctx.operator)
      id = ctx.dropped.organisation.id

      assert Edition.operator_chain_organisation(id) == ctx.operator.organisation.id
      assert ProviderCredential.sealable_to?("operator", gateway, id)

      # A drop is not offered while the operator owns its clients: it is done as before.
      Flags.put_operator_infrastructure(false)

      assert {:ok, _client} =
               Transfers.drop(ctx.operator.scope, id, ctx.dropped.organisation.name)

      Flags.put_operator_infrastructure(true)

      assert ApiaryPro.Tenants.model_chain_of(id) == :organisation
      assert Edition.model_choice_chain(id) == "organisation"
      assert Edition.operator_chain_organisation(id) == nil
      refute ProviderCredential.sealable_to?("operator", gateway, id)
      assert {:ok, []} = Connections.list_providers(ctx.dropped.owner.scope)
    end
  end

  describe "with the flag off" do
    test "the operator's provider is neither resolved nor sealed", ctx do
      {gateway, gateway_key} = gateway_of(ctx.operator)
      provider = operator_chain!(ctx.operator)
      assert {:ok, handed} = hand_over(ctx.on)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)
      id = ctx.on.organisation.id

      Flags.put_operator_infrastructure(false)

      assert Edition.model_choice_chain(id) == "organisation"
      assert Edition.operator_chain_organisation(id) == nil
      refute ProviderCredential.sealable_to?("operator", gateway, id)

      {conn, _log} = with_log(fn -> post_secrets(gateway_key, run, digest, provider) end)
      refute conn.status == 200
      assert seals() == []
    end
  end
end
