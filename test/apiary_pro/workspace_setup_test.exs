defmodule ApiaryPro.WorkspaceSetupTest do
  # The four rules of the Overview's setup list (`Apiary.WorkspaceSetup`), as the
  # edition reads them: the results of the core in a plain organisation, and the machines
  # step of a client while operators run their clients' infrastructure
  # (`ApiaryPro.Flags.operator_infrastructure?/0`), where a pool of the client's workspace
  # on Default leads to the operator's default gateway.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Connections, Edition, ModelChoices, Nodes, Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run
  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
  end

  describe "in a plain organisation, the four rules return what the core returns" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: scope, workspace: scope.workspace}
    end

    test "work source: the adapters of the workspace's collections, by name", ctx do
      assert Edition.work_source_ready(ctx.workspace) == []

      collection = collection_fixture(ctx.scope)

      assert [%{adapter: %Node{id: adapter_id}, collections: 1}] =
               Edition.work_source_ready(ctx.workspace)

      assert adapter_id == collection.adapter_id
    end

    test "machines: a pool of the workspace and its gateway, each with an active key", ctx do
      assert Edition.machines_ready(ctx.workspace) == nil

      gateway = gateway_fixture(ctx.scope)
      pool = pool_fixture(ctx.scope)
      assert Edition.machines_ready(ctx.workspace) == nil

      _gateway_key = enrolled_key_fixture(ctx.scope, gateway)
      assert Edition.machines_ready(ctx.workspace) == nil

      _pool_key = enrolled_key_fixture(ctx.scope, pool)

      assert %{pool: %Node{id: pool_id}, gateway: %Node{id: gateway_id}} =
               Edition.machines_ready(ctx.workspace)

      assert {pool_id, gateway_id} == {pool.id, gateway.id}
    end

    test "model key: a provider with a key, and a model choice of the workspace", ctx do
      refute Edition.model_key_ready?(ctx.workspace)

      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-setup-1"}]
        })

      refute Edition.model_key_ready?(ctx.workspace)

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.scope, :workspace, %{provider: provider.public_id})

      assert Edition.model_key_ready?(ctx.workspace)
    end

    test "test run: passed once a test work item's run ended by its exit, completed", ctx do
      refute Edition.test_run_passed?(ctx.workspace)

      {:ok, item} = WorkItems.take_in_test(ctx.scope, "Hi! Where are you running?")
      refute Edition.test_run_passed?(ctx.workspace)

      [queued] = Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      Repo.delete_all(from r in Run, where: r.dispatch_run_id == ^queued.id)

      %Run{
        organisation_id: item.organisation_id,
        workspace_id: item.workspace_id,
        node_run_id: queued.run_id,
        dispatch_run_id: queued.id
      }
      |> Ecto.Changeset.change(%{started_at: DateTime.utc_now(), state: "completed"})
      |> Apiary.RunEventsFixtures.insert_run!()

      assert Edition.test_run_passed?(ctx.workspace)
    end
  end

  describe "the machines step of a client of an operator" do
    setup do
      Flags.put_operator_infrastructure(true)

      operator = operator_fixture()
      client = client_fixture(operator.scope)
      gateway = organisation_gateway_fixture(operator.scope, name: "edge-1")
      assert gateway.default_gateway

      %{operator: operator, client: client, gateway: gateway}
    end

    # A pool of the client's workspace, made by the operator's person, on Default.
    defp client_pool(ctx) do
      pool = pool_fixture(ctx.client.scope)
      :default = pool.gateway_choice
      pool
    end

    test "is done with a pool that names the operator's gateway, not Default", ctx do
      pool =
        pool_fixture(ctx.client.scope, %{gateway_choice: "named", gateway_id: ctx.gateway.id})

      assert pool.gateway_choice == :named
      _pool_key = enrolled_key_fixture(ctx.client.scope, pool)
      _gateway_key = enrolled_key_fixture(ctx.operator.scope, ctx.gateway)

      assert %{pool: %Node{id: pool_id}, gateway: %Node{id: gateway_id}} =
               Edition.machines_ready(ctx.client.workspace)

      assert {pool_id, gateway_id} == {pool.id, ctx.gateway.id}
    end

    test "a default gateway of the client's workspace wins over the operator's", ctx do
      # The operator's gateway is the default already, so the client's is not made one.
      client_gateway = gateway_fixture(ctx.client.scope)
      {:ok, client_gateway} = Nodes.make_default_gateway(ctx.client.scope, client_gateway)
      assert client_gateway.default_gateway
      pool = client_pool(ctx)
      _pool_key = enrolled_key_fixture(ctx.client.scope, pool)
      _gateway_key = enrolled_key_fixture(ctx.operator.scope, ctx.gateway)

      # The pool leads to the client's gateway, which has no key yet.
      assert Edition.machines_ready(ctx.client.workspace) == nil

      _client_gateway_key = enrolled_key_fixture(ctx.client.scope, client_gateway)

      assert %{gateway: %Node{id: gateway_id}} = Edition.machines_ready(ctx.client.workspace)
      assert gateway_id == client_gateway.id
      refute gateway_id == ctx.gateway.id
    end

    test "is not done while the client has no pool", ctx do
      _gateway_key = enrolled_key_fixture(ctx.operator.scope, ctx.gateway)

      assert Edition.machines_ready(ctx.client.workspace) == nil
    end

    test "is done with a pool of the client and the operator's gateway, each with a key",
         ctx do
      pool = client_pool(ctx)
      _pool_key = enrolled_key_fixture(ctx.client.scope, pool)
      _gateway_key = enrolled_key_fixture(ctx.operator.scope, ctx.gateway)

      assert %{pool: %Node{id: pool_id}, gateway: %Node{id: gateway_id}} =
               Edition.machines_ready(ctx.client.workspace)

      assert {pool_id, gateway_id} == {pool.id, ctx.gateway.id}
    end

    test "is not done while the operator's gateway has no key", ctx do
      pool = client_pool(ctx)
      _pool_key = enrolled_key_fixture(ctx.client.scope, pool)

      assert Edition.machines_ready(ctx.client.workspace) == nil
    end

    test "is not done while the pool has no key", ctx do
      _pool = client_pool(ctx)
      _gateway_key = enrolled_key_fixture(ctx.operator.scope, ctx.gateway)

      assert Edition.machines_ready(ctx.client.workspace) == nil
    end

    test "is not done with the flag off, when the operator's gateway serves nobody", ctx do
      pool = client_pool(ctx)
      _pool_key = enrolled_key_fixture(ctx.client.scope, pool)
      _gateway_key = enrolled_key_fixture(ctx.operator.scope, ctx.gateway)
      assert Edition.machines_ready(ctx.client.workspace)

      Flags.put_operator_infrastructure(false)

      assert Edition.machines_ready(ctx.client.workspace) == nil
    end
  end

  describe "the model key step of a client of an operator" do
    setup do
      Flags.put_operator_infrastructure(true)

      operator = operator_fixture()
      client = client_fixture(operator.scope)

      %{operator: operator, client: client}
    end

    defp switch(ctx, chain),
      do:
        {:ok, _} =
          ApiaryPro.Operators.set_model_chain(
            ctx.operator.scope,
            ctx.client.organisation.id,
            chain
          )

    # A provider with a key on `chain`, written by `scope`.
    defp provider_on(scope, chain) do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          chain: chain,
          keys: [%{value_id: "main", value: "sk-setup-org-1"}]
        })

      provider
    end

    # The operator's default choice, on its chain.
    defp operator_default(ctx, provider) do
      {:ok, _choice} =
        ModelChoices.put_choice(
          ctx.operator.scope,
          :organisation,
          %{provider: provider.public_id},
          "operator"
        )
    end

    test "on the operator's chain, is done with the operator's provider and default", ctx do
      switch(ctx, :operator)
      refute Edition.model_key_ready?(ctx.client.workspace)

      operator_default(ctx, provider_on(ctx.operator.scope, "operator"))

      assert Edition.model_key_ready?(ctx.client.workspace)
    end

    test "on the operator's chain, is not done while the operator has no provider with a key",
         ctx do
      switch(ctx, :operator)
      refute Edition.model_key_ready?(ctx.client.workspace)

      # The operator's provider and default on the operator's organisation chain are not
      # the operator's chain.
      provider = provider_on(ctx.operator.scope, "organisation")

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.operator.scope, :organisation, %{provider: provider.public_id})

      refute Edition.model_key_ready?(ctx.client.workspace)
    end

    test "on the operator's chain, is not done while the operator has no default choice",
         ctx do
      switch(ctx, :operator)
      _provider = provider_on(ctx.operator.scope, "operator")

      refute Edition.model_key_ready?(ctx.client.workspace)
    end

    test "on the operator's chain, the client's provider and choice do not count", ctx do
      # The operator's chain refuses the client's people these writes, so the client sets
      # up its provider and choice first, and is moved to the operator's chain after.
      client_provider = provider_on(ctx.client.owner.scope, "organisation")

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.client.owner.scope, :workspace, %{
          provider: client_provider.public_id
        })

      assert Edition.model_key_ready?(ctx.client.workspace)

      switch(ctx, :operator)

      refute Edition.model_key_ready?(ctx.client.workspace)
    end

    test "on the client's chain, keeps the core's check, whatever the operator has", ctx do
      operator_default(ctx, provider_on(ctx.operator.scope, "operator"))
      refute Edition.model_key_ready?(ctx.client.workspace)

      client_provider = provider_on(ctx.client.owner.scope, "organisation")
      refute Edition.model_key_ready?(ctx.client.workspace)

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.client.owner.scope, :workspace, %{
          provider: client_provider.public_id
        })

      assert Edition.model_key_ready?(ctx.client.workspace)
    end

    test "with the flag off, the client's chain is the organisation's again", ctx do
      switch(ctx, :operator)
      operator_default(ctx, provider_on(ctx.operator.scope, "operator"))
      assert Edition.model_key_ready?(ctx.client.workspace)

      Flags.put_operator_infrastructure(false)

      refute Edition.model_key_ready?(ctx.client.workspace)
    end
  end

  describe "the Model step of a client of an operator" do
    setup do
      Flags.put_operator_infrastructure(true)

      operator = operator_fixture()
      client = client_fixture(operator.scope)

      %{operator: operator, client: client}
    end

    # Whether the Model step is done for the client's organisation and its workspace
    # (`Apiary.WorkspaceSetup`): no step after Name is done while the workspace does not exist.
    defp model_done?(ctx),
      do:
        Apiary.WorkspaceSetup.done?(
          :model,
          ctx.client.organisation,
          {Apiary.Lingo.Domain.default(), ctx.client.workspace}
        )

    defp operator_provider(ctx, chain) do
      {:ok, provider} =
        Connections.create_provider(ctx.operator.scope, %{
          provider: "anthropic",
          chain: chain,
          keys: [%{value_id: "main", value: "sk-setup-org-2"}]
        })

      provider
    end

    defp set_chain(ctx, chain) do
      {:ok, organisation} =
        ApiaryPro.Operators.set_model_chain(
          ctx.operator.scope,
          ctx.client.organisation.id,
          chain
        )

      organisation
    end

    test "on the operator's chain, is done with the operator's provider and default", ctx do
      organisation = set_chain(ctx, :operator)
      refute model_done?(%{ctx | client: %{ctx.client | organisation: organisation}})

      provider = operator_provider(ctx, "operator")

      {:ok, _choice} =
        ModelChoices.put_choice(
          ctx.operator.scope,
          :organisation,
          %{provider: provider.public_id},
          "operator"
        )

      assert model_done?(%{ctx | client: %{ctx.client | organisation: organisation}})
    end

    test "on the client's chain, is done with the workspace's choice of the client's provider, not the operator's",
         ctx do
      provider = operator_provider(ctx, "operator")

      {:ok, _choice} =
        ModelChoices.put_choice(
          ctx.operator.scope,
          :organisation,
          %{provider: provider.public_id},
          "operator"
        )

      refute model_done?(ctx)

      {:ok, own} =
        Connections.create_provider(ctx.client.owner.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-setup-org-3"}]
        })

      # On the organisation's chain the rule reads the workspace's choice (level 5).
      {:ok, _choice} =
        ModelChoices.put_choice(ctx.client.owner.scope, :workspace, %{provider: own.public_id})

      assert model_done?(ctx)
    end

    test "says who may, for a person of the client, on the operator's chain only", ctx do
      operator = ctx.operator.organisation.name
      fallback = "Only owners and admins add a model key."

      for about <- [:"provider.write", :"runtime.write", :"model_choice.write"] do
        scope = scope_in(ctx.client.owner.user, ctx.client.organisation)
        assert ApiaryWeb.Access.who_may(scope, about, fallback) == fallback
      end

      organisation = set_chain(ctx, :operator)

      for about <- [:"provider.write", :"runtime.write", :"model_choice.write"] do
        scope = scope_in(ctx.client.owner.user, organisation)

        assert ApiaryWeb.Access.who_may(scope, about, fallback) ==
                 "Set by your operator, #{operator}. Ask them to change it."

        refute Apiary.Access.can?(scope, about, organisation)
      end
    end
  end
end
