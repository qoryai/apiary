defmodule Apiary.Dispatches.KeyGroupTest do
  # A run's key group (`Apiary.ModelKeys.Group`): every model provider of the kind, chain
  # and settings of the provider of the run's model choice that serves the run's
  # workspace. The claim takes the keys of every provider of the group as one list
  # (`Apiary.Dispatches.RunSettings`), the run configuration sends them as one `group`
  # (`Apiary.Runs.ProviderCredential`), and the run waits only while every key of the
  # group is in cooldown.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ForagerSchemas, ModelKeys}
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.{DispatchRun, RunSettings}
  alias Apiary.Kinds.Coded
  alias Apiary.ModelKeys.Group
  alias Apiary.Policy.ComposedConfiguration
  alias Apiary.Runs.{ProviderCredential, Run}

  @moduletag needs: [:factory, :secrets]

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

  setup do
    %{scope: scope} = sign_up_fixture()

    scope
    |> handover_place_fixture(allow_secrets: true)
    |> Map.put(:scope, scope)
  end

  # A Claude subscription token provider with the keys `value_ids`, `key-1` up, the names
  # Qory Apiary gives the keys in order: for every workspace of the organisation, or, with
  # `:workspace`, for the scope's workspace alone, its keys a secret of that workspace.
  defp provider!(scope, name, value_ids, place \\ :organisation) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    keys = for id <- value_ids, do: %{value: "sk-ant-oat01-#{slug}-#{id}-0123456789"}

    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{provider: "claude-subscription", name: name, keys: keys},
        place
      )

    provider
  end

  defp choose!(scope, provider) do
    {:ok, choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        model: "claude-opus-5-5"
      })

    choice
  end

  # A fresh work item's explore run of the scope's workspace, queued and claimed: the
  # registered run as stored, or `:none` where the claim left it waiting; and the run of
  # the queue as stored after the claim.
  defp claim!(ctx) do
    work_item = work_item_fixture(ctx.scope, %{external_ref: "acme/shop##{unique()}"})
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    run =
      case walked_claim(ctx.key, Dispatches.now(), @body) do
        {:ok, %{registered: run}} -> Repo.get!(Run, run.id)
        {:ok, :none} -> :none
      end

    {run, Repo.get!(DispatchRun, queued.id)}
  end

  defp unique, do: System.unique_integer([:positive])

  # Each key a run keeps, as `{its provider's row id, its value id, its credential name}`.
  defp keys(%Run{} = run) do
    by_id = Map.new(Repo.all(Apiary.Secrets.Value), &{&1.id, &1.value_id})
    for key <- stored_keys(run), do: {key.connection_id, by_id[key.secret_value_id], key.name}
  end

  describe "a run of Checkout, with one provider for every workspace and one for Checkout" do
    setup ctx do
      every = provider!(ctx.scope, "Every workspace", ["key-1"])
      checkout = provider!(ctx.scope, "Checkout", ["key-1"], :workspace)
      choose!(ctx.scope, every)
      %{every: every, checkout: checkout}
    end

    test "gets the keys of both providers, sent as one group", ctx do
      %{every: every, checkout: checkout} = ctx
      {%Run{} = run, queued} = claim!(ctx)

      assert queued.model_provider_ids == [every.id, checkout.id]
      assert run.provider_connection_id == every.id

      assert keys(run) == [
               {every.id, "key-1", "#{every.public_id}-1"},
               {checkout.id, "key-1", "#{checkout.public_id}-1"}
             ]

      assert [true, false] = Enum.map(stored_keys(run), & &1.default_credential)

      assert Enum.map(stored_keys(run), & &1.secret_id) == [every.secret_id, checkout.secret_id]

      # One `group` for both keys: the public id of the choice's provider.
      assert {:ok, credential} = ProviderCredential.for_run(run)
      assert Enum.map(credential.keys, & &1.entry["group"]) == [every.public_id, every.public_id]
      assert Enum.map(credential.providers, & &1.id) == [every.id, checkout.id]

      {:ok, members} = ComposedConfiguration.members(run)
      {:composed, document, nil} = ComposedConfiguration.shape(nil, nil, false, false, members)
      assert ForagerSchemas.validate("run-configuration.schema.json", document) == :ok

      groups = for %{"group" => group} <- Jason.decode!(document)["credentials"], do: group
      assert groups == [every.public_id, every.public_id]
    end

    test "of a choice on the Checkout provider starts on its default key", ctx do
      %{every: every, checkout: checkout} = ctx
      choose!(ctx.scope, checkout)
      {%Run{} = run, queued} = claim!(ctx)

      assert queued.model_provider_ids == [checkout.id, every.id]
      assert run.provider_connection_id == checkout.id

      assert keys(run) == [
               {checkout.id, "key-1", "#{checkout.public_id}-1"},
               {every.id, "key-1", "#{every.public_id}-1"}
             ]

      assert {:ok, credential} = ProviderCredential.for_run(run)
      assert credential.name == "#{checkout.public_id}-1"

      assert Enum.map(credential.keys, & &1.entry["group"]) ==
               [checkout.public_id, checkout.public_id]
    end

    test "takes the other provider's key while one key cools, and waits while both cool", ctx do
      %{every: every, checkout: checkout} = ctx
      key_state!(every, "key-1", until: in_seconds(3_600))

      {%Run{} = run, _queued} = claim!(ctx)
      assert run.provider_connection_id == every.id

      # The free key first, and the default model provider credential.
      assert [
               %{name: free, default_credential: true, cooldown_until: nil},
               %{default_credential: false, cooldown_until: %DateTime{}}
             ] = stored_keys(run)

      assert free == "#{checkout.public_id}-1"

      # Both keys cool: the claim leaves the run waiting for both providers, and the
      # claim's filter passes the run by until one key is free.
      key_state!(checkout, "key-1", until: in_seconds(1_800))
      assert {:none, waiting} = claim!(ctx)
      assert %DispatchRun{state: :waiting, model_provider_ids: ids} = waiting
      assert ids == [every.id, checkout.id]
      assert nil == Repo.one(Dispatches.waiting_query(ctx.key, true, Dispatches.now(), []))

      key_state!(checkout, "key-1", until: in_seconds(-1))

      assert %DispatchRun{id: id} =
               Repo.one(Dispatches.waiting_query(ctx.key, true, Dispatches.now(), []))

      assert id == waiting.id
    end

    test "waits for the providers of the group that have a key", ctx do
      %{every: every, checkout: checkout} = ctx
      empty = provider!(ctx.scope, "No keys", ["key-1"])
      Repo.delete_all(from v in Apiary.Secrets.Value, where: v.secret_id == ^empty.secret_id)
      key_state!(every, "key-1", until: in_seconds(3_600))
      key_state!(checkout, "key-1", until: in_seconds(1_800))

      # The build at the claim, past the claim's filter: the providers with a key, not the
      # one with none, which the filter counts as never in cooldown.
      assert {:cooling, _built, ids} = claim_build(ctx)
      assert ids == [every.id, checkout.id]
    end

    test "that pauses keeps the first end of a cooldown across the group", ctx do
      %{every: every, checkout: checkout} = ctx
      {%Run{} = run, _queued} = claim!(ctx)

      # The choice's provider's key leaves its cooldown last.
      key_state!(every, "key-1", until: in_seconds(7_200))
      soon = in_seconds(1_800)
      key_state!(checkout, "key-1", until: soon)

      ids = Run.session_provider_ids(run, 1)
      assert ids == [every.id, checkout.id]
      assert DateTime.compare(ModelKeys.cooling_until(ids, Dispatches.now()), soon) == :eq

      # One key free: the group is not cooling.
      key_state!(checkout, "key-1", until: in_seconds(-1))
      assert ModelKeys.cooling_until(ids, Dispatches.now()) == nil
    end

    test "of a choice with no key of its provider takes the keys of the group", ctx do
      %{every: every, checkout: checkout} = ctx
      Repo.delete_all(from v in Apiary.Secrets.Value, where: v.secret_id == ^every.secret_id)

      {%Run{} = run, _queued} = claim!(ctx)
      assert run.provider_connection_id == every.id
      assert keys(run) == [{checkout.id, "key-1", "#{checkout.public_id}-1"}]

      # The provider of the run's key is the group's `group` in the run configuration,
      # where the choice's provider has no key in the run.
      assert {:ok, credential} = ProviderCredential.for_run(run)
      assert Enum.map(credential.keys, & &1.entry["group"]) == [checkout.public_id]
    end
  end

  test "a run of another workspace gets the key of the provider for every workspace alone",
       ctx do
    every = provider!(ctx.scope, "Every workspace", ["key-1"])
    checkout = provider!(ctx.scope, "Checkout", ["key-1"], :workspace)

    storefront = workspace_fixture(ctx.scope.organisation, "Storefront")
    in_storefront = workspace_scope(ctx.scope.user, storefront)
    choose!(in_storefront, every)

    work_item = work_item_fixture(in_storefront)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    assert queued.model_provider_ids == [every.id]

    assert {:ok, %{keys: [key]}} = queued |> RunSettings.hold() |> RunSettings.build()
    assert key.connection_id == every.id
    assert key.name == "#{every.public_id}-1"

    # Of rows already loaded, the Checkout provider is left out of a group for Storefront.
    providers = Repo.preload([every, checkout], :workspaces, force: true)
    assert Group.members(every, providers, storefront.id) == [every]
    assert [^every, %Connection{id: id}] = Group.members(every, providers, ctx.scope.workspace.id)
    assert id == checkout.id
  end

  test "a run's keys are ordered across the group: the choice's provider's default key, then by the time added, then the closest reset; at most 6",
       ctx do
    every = provider!(ctx.scope, "Every workspace", ~w(key-1 key-2 key-3))
    checkout = provider!(ctx.scope, "Checkout", ~w(key-1 key-2 key-3 key-4), :workspace)
    choose!(ctx.scope, checkout)

    # Known resets, none in cooldown: Checkout's key-4 in 1 hour, key-3 of every workspace
    # in 2 hours.
    key_state!(checkout, "key-4", resets_at: in_seconds(3_600))
    key_state!(every, "key-3", resets_at: in_seconds(7_200))

    assert {:ok, built} = claim_build(ctx)

    # Of 7 keys, the 6 the order takes: the 5 with no known reset, the choice's default
    # key first, then the others by the time added (every workspace's first); then the
    # closest reset. The run configuration sends them free keys in that tie order, each
    # named by its provider, the place counted per provider.
    assert Enum.map(built.keys, &{&1.connection_id, &1.name}) == [
             {checkout.id, "#{checkout.public_id}-1"},
             {every.id, "#{every.public_id}-1"},
             {every.id, "#{every.public_id}-2"},
             {checkout.id, "#{checkout.public_id}-2"},
             {checkout.id, "#{checkout.public_id}-3"},
             {checkout.id, "#{checkout.public_id}-4"}
           ]

    by_id = Map.new(Repo.all(Apiary.Secrets.Value), &{&1.id, &1.value_id})

    assert Enum.map(built.keys, &by_id[&1.secret_value_id]) ==
             ~w(key-1 key-1 key-2 key-2 key-3 key-4)

    assert [%{default_credential: true} | rest] = built.keys
    refute Enum.any?(rest, & &1.default_credential)
  end

  # What a claim at this moment builds for a fresh run of the scope's queue.
  defp claim_build(ctx) do
    work_item = work_item_fixture(ctx.scope, %{external_ref: "acme/shop##{unique()}"})
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    queued |> RunSettings.hold() |> RunSettings.build()
  end

  test "a waiting run takes the keys of a provider added to its key group", ctx do
    every = provider!(ctx.scope, "Every workspace", ["key-1"])
    choose!(ctx.scope, every)
    key_state!(every, "key-1", until: in_seconds(3_600))

    assert {:none, waiting} = claim!(ctx)
    assert waiting.model_provider_ids == [every.id]

    # A provider of the group, with a free key, for the scope's workspace alone.
    checkout = provider!(ctx.scope, "Checkout", ["key-1"], :workspace)

    # The claim takes the waiting run, the oldest of the queue, with the new key first.
    assert {:ok, %{registered: run}} = walked_claim(ctx.key, Dispatches.now(), @body)
    assert %DispatchRun{state: state} = Repo.get!(DispatchRun, waiting.id)
    refute state == :waiting
    run = Repo.get!(Run, run.id)
    assert run.provider_connection_id == every.id

    assert keys(run) == [
             {checkout.id, "key-1", "#{checkout.public_id}-1"},
             {every.id, "key-1", "#{every.public_id}-1"}
           ]
  end

  describe "a provider is not of the group" do
    @tag needs: [:factory, :secrets, :model_proxies]
    test "at another address", ctx do
      litellm = fn address ->
        {:ok, provider} =
          Connections.create_provider(ctx.scope, %{
            provider: "litellm",
            settings: %{"address" => address},
            keys: [%{value_id: "main", value: "sk-team-#{unique()}"}]
          })

        provider
      end

      chosen = litellm.("https://litellm.example.com")
      same = litellm.("https://litellm.example.com")
      other = litellm.("https://proxy.example.com")
      assert Group.same?(chosen, same)
      refute Group.same?(chosen, other)

      {:ok, _choice} =
        Apiary.ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{
          provider: chosen.public_id,
          model: "team-large"
        })

      assert {:ok, built} = claim_build(ctx)
      assert Enum.map(built.keys, & &1.connection_id) == [chosen.id, same.id]
    end

    test "that fails its integrity code: the claim leaves it out", ctx do
      every = provider!(ctx.scope, "Every workspace", ["key-1"])
      checkout = provider!(ctx.scope, "Checkout", ["key-1"], :workspace)
      choose!(ctx.scope, every)

      # A name written without a new code.
      {1, _rows} =
        Repo.update_all(from(c in Connection, where: c.id == ^checkout.id),
          set: [name: "Changed outside Qory Apiary"]
        )

      {{:ok, built}, log} = ExUnit.CaptureLog.with_log(fn -> claim_build(ctx) end)
      assert Enum.map(built.keys, & &1.connection_id) == [every.id]
      assert log =~ "model provider #{checkout.public_id} out of its key group"
    end

    test "of another organisation, with the same kind and settings", ctx do
      every = provider!(ctx.scope, "Every workspace", ["key-1"])
      choose!(ctx.scope, every)

      %{scope: other_scope} = sign_up_fixture()
      elsewhere = provider!(other_scope, "Every workspace", ["key-1"])
      assert elsewhere.settings == every.settings
      refute Group.same?(every, elsewhere)

      assert Group.member_ids(ctx.scope.organisation.id, ctx.scope.workspace.id, [every.id]) ==
               %{every.id => [every.id]}

      assert {:ok, built} = claim_build(ctx)
      assert Enum.map(built.keys, & &1.connection_id) == [every.id]
    end

    test "for one workspace alone, for a workspace not yet made", ctx do
      every = provider!(ctx.scope, "Every workspace", ["key-1"])
      also = provider!(ctx.scope, "Every workspace too", ["key-1"])
      checkout = provider!(ctx.scope, "Checkout", ["key-1"], :workspace)
      organisation_id = ctx.scope.organisation.id

      assert Group.member_ids(organisation_id, ctx.scope.workspace.id, [every.id]) ==
               %{every.id => [every.id, also.id, checkout.id]}

      # A workspace not yet made (nil) is served by the providers for every workspace.
      assert Group.member_ids(organisation_id, nil, [every.id]) ==
               %{every.id => [every.id, also.id]}
    end

    test "of another kind or another chain", ctx do
      every = provider!(ctx.scope, "Every workspace", ["key-1"])
      chain = provider!(ctx.scope, "Operator keys", ["key-1"])
      workspace_id = ctx.scope.workspace.id
      organisation_id = ctx.scope.organisation.id

      {:ok, api_key} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-api-0123456789"}]
        })

      assert Group.member_ids(organisation_id, workspace_id, [every.id]) ==
               %{every.id => [every.id, chain.id]}

      # The row of another chain, coded again as a save codes it.
      Connection
      |> Repo.get!(chain.id)
      |> Ecto.Changeset.change(chain: "operator")
      |> Coded.seal()
      |> Repo.update!()

      assert Group.member_ids(organisation_id, workspace_id, [every.id, api_key.id]) ==
               %{every.id => [every.id], api_key.id => [api_key.id]}

      refute Group.same?(every, api_key)
    end
  end
end
