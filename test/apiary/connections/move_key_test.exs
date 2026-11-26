defmodule Apiary.Connections.MoveKeyTest do
  # A model provider key that gets other workspaces on Edit key
  # (`Apiary.Connections.update_provider_key/4` with `applies_to`): it moves to the provider
  # of its group that serves those workspaces, or to a new one, with its value id, value,
  # settings and state, and leaves its provider as `remove_key/3` removes a key, in one
  # transaction. A move that Remove's rules stop changes nothing.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Connections, ModelChoicesFixtures, ModelKeys, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.ModelKeys.{Copy, Login, Rejection, Setting, State}
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: :factory

  @key "sk-ant-move-key-0123456789abcdef"

  # A stub of `Apiary.Edition` where admins reach only the workspaces in `:admins_reach`;
  # owners reach every workspace.
  defmodule AdminsReachNamed do
    import Ecto.Query

    def every_workspace_levels, do: [:owner]

    def reached_workspaces(query, _scope),
      do: where(query, [workspace: w], w.id in ^Process.get(:admins_reach, []))

    def reaches_workspace?(_scope, workspace_id, _opts),
      do: workspace_id in Process.get(:admins_reach, [])
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    storefront = workspace_fixture(scope.organisation, "Storefront")
    %{scope: scope, checkout: scope.workspace, storefront: storefront}
  end

  defp add!(scope, reach, attrs \\ %{}) do
    {:ok, provider, value_id} =
      Connections.add_key(
        scope,
        Map.merge(%{"provider" => "anthropic", "value" => @key}, Map.merge(reach, attrs))
      )

    {provider, value_id}
  end

  defp every, do: %{"applies_to" => "all"}

  defp only(workspaces),
    do: %{"applies_to" => "selected", "workspace_ids" => Enum.map(workspaces, & &1.id)}

  defp move(scope, provider, value_id, reach),
    do:
      Connections.update_provider_key(
        scope,
        provider,
        value_id,
        Map.merge(%{"value_id" => value_id}, reach)
      )

  defp mark!(scope, workspace),
    do: workspace |> Apiary.Deletion.mark_changeset(scope) |> Repo.update!()

  defp value!(provider, value_id),
    do: Repo.get_by!(Value, secret_id: provider.secret_id, value_id: value_id)

  defp value_ids(%Connection{secret_id: secret_id}),
    do:
      Repo.all(
        from v in Value,
          where: v.secret_id == ^secret_id,
          order_by: v.inserted_at,
          select: v.value_id
      )

  defp revealed(provider, value_id) do
    provider = Repo.get!(Connection, provider.id)
    Apiary.ModelKeysFixtures.revealed_key(provider, value!(provider, value_id).id)
  end

  test "a key moves to the provider of its group for those workspaces", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {checkout, "key-2"} = add!(ctx.scope, only([ctx.checkout]))
    {_checkout, "key-3"} = add!(ctx.scope, only([ctx.checkout]))

    assert {:ok, moved_to} = move(ctx.scope, checkout, "key-3", every())

    assert moved_to.id == every.id
    assert value_ids(every) == ["key-1", "key-3"]
    assert value_ids(checkout) == ["key-2"]
    assert revealed(every, "key-3") == {:ok, @key}
    # The next key of the provider is numbered after the moved key.
    assert Apiary.Secrets.next_key_id(Repo.get!(Secret, every.secret_id)) == "key-4"
  end

  test "a key moves into the keys of a workspace, encrypted at that workspace", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())
    {checkout, "key-3"} = add!(ctx.scope, only([ctx.checkout]))
    assert Repo.get!(Secret, checkout.secret_id).workspace_id == ctx.checkout.id

    assert {:ok, moved_to} = move(ctx.scope, every, "key-2", only([ctx.checkout]))

    assert moved_to.id == checkout.id
    assert value!(checkout, "key-2").workspace_id == ctx.checkout.id
    assert revealed(checkout, "key-2") == {:ok, @key}
  end

  test "a key whose name the provider of those workspaces has moves only after a rename",
       ctx do
    # Two providers made before keys were numbered across the kind, each with a key-1.
    {:ok, every} =
      Connections.create_provider(ctx.scope, %{
        provider: "anthropic",
        applies_to: "all",
        keys: [%{value: @key}]
      })

    {:ok, checkout} =
      Connections.create_provider(
        ctx.scope,
        %{provider: "anthropic", keys: [%{value: @key}]},
        :workspace
      )

    assert {:error,
            %Ecto.Changeset{errors: [value_id: {"is already the name of another key", _}]}} =
             move(ctx.scope, checkout, "key-1", every())

    assert value_ids(checkout) == ["key-1"]
    assert value_ids(every) == ["key-1"]

    assert {:ok, moved_to} =
             Connections.update_provider_key(
               ctx.scope,
               checkout,
               "key-1",
               Map.merge(%{"value_id" => "spare"}, every())
             )

    assert moved_to.id == every.id
    assert value_ids(every) == ["key-1", "spare"]
  end

  test "a key for workspaces no provider of its group serves makes a new provider", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())

    assert {:ok, moved_to} = move(ctx.scope, every, "key-2", only([ctx.checkout]))

    refute moved_to.id == every.id
    assert moved_to.applies_to == "selected"
    assert Connections.workspace_ids_of(moved_to) == [ctx.checkout.id]
    assert moved_to.provider_kind == "anthropic"
    assert moved_to.default_value_id == "key-2"
    # One workspace: the key is a secret of that workspace.
    assert Repo.get!(Secret, moved_to.secret_id).workspace_id == ctx.checkout.id
    assert value_ids(moved_to) == ["key-2"]
    assert value_ids(every) == ["key-1"]
    assert revealed(moved_to, "key-2") == {:ok, @key}
  end

  test "a key for several workspaces makes a provider whose keys are the organisation's",
       ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())

    assert {:ok, moved_to} = move(ctx.scope, every, "key-2", only([ctx.checkout, ctx.storefront]))

    assert Enum.sort(Connections.workspace_ids_of(moved_to)) ==
             Enum.sort([ctx.checkout.id, ctx.storefront.id])

    assert Repo.get!(Secret, moved_to.secret_id).workspace_id == nil
    assert revealed(moved_to, "key-2") == {:ok, @key}
  end

  test "the default key that moves leaves another key the default", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())
    assert Repo.get!(Connection, every.id).default_value_id == "key-1"

    assert {:ok, _moved_to} = move(ctx.scope, every, "key-1", only([ctx.checkout]))
    assert Repo.get!(Connection, every.id).default_value_id == "key-2"
  end

  test "a provider's last key moves its model choice to the provider the key went to",
       ctx do
    {checkout, "key-1"} = add!(ctx.scope, only([ctx.checkout]))

    {:ok, choice} =
      ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{provider: checkout.public_id})

    assert {:ok, moved_to} = move(ctx.scope, checkout, "key-1", every())

    refute Repo.get(Connection, checkout.id)
    refute Repo.get(Secret, checkout.secret_id)
    assert Repo.get!(ModelChoice, choice.id).connection_id == moved_to.id
    assert value_ids(moved_to) == ["key-1"]
    assert revealed(moved_to, "key-1") == {:ok, @key}
  end

  test "a provider's last key that moves sets again the model providers of waiting runs",
       ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {checkout, "key-2"} = add!(ctx.scope, only([ctx.checkout]))

    {:ok, _choice} =
      ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{provider: checkout.public_id})

    work_item = Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item, 1) end)

    # The run with no model providers, so that the refresh has a change to write.
    waiting = from(r in Apiary.Dispatches.DispatchRun, where: r.id == ^queued.id)
    {1, _rows} = Repo.update_all(waiting, set: [model_provider_ids: []])

    assert {:ok, moved_to} = move(ctx.scope, checkout, "key-2", every())
    assert moved_to.id == every.id
    assert Repo.one!(from r in waiting, select: r.model_provider_ids) == [every.id]
  end

  test "a key for workspaces whose provider has no room makes a new provider", ctx do
    {:ok, full} =
      Connections.create_provider(ctx.scope, %{
        provider: "anthropic",
        applies_to: "all",
        keys: for(n <- 1..Apiary.Secrets.max_values(), do: %{value: "#{@key}-#{n}"})
      })

    {checkout, value_id} = add!(ctx.scope, only([ctx.checkout]))
    {_checkout, _second} = add!(ctx.scope, only([ctx.checkout]))

    assert {:ok, moved_to} = move(ctx.scope, checkout, value_id, every())

    refute moved_to.id == full.id
    assert moved_to.applies_to == "all"
    assert value_ids(moved_to) == [value_id]
    assert length(value_ids(full)) == Apiary.Secrets.max_values()
  end

  test "a move that Remove's rules stop changes nothing", ctx do
    {checkout, "key-1"} = add!(ctx.scope, only([ctx.checkout]))

    {:ok, choice} =
      ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{provider: checkout.public_id})

    providers = Repo.aggregate(Connection, :count)

    assert move(ctx.scope, checkout, "key-1", only([ctx.storefront])) ==
             {:error, {:last_key, ctx.checkout.id}}

    assert Repo.aggregate(Connection, :count) == providers
    assert value_ids(checkout) == ["key-1"]
    assert Repo.get!(ModelChoice, choice.id).connection_id == checkout.id
  end

  test "the last key of the organisation's default does not move when no other provider's keys are a secret of the organisation",
       ctx do
    # A provider for Checkout whose key is a secret of Checkout serves the default's
    # workspaces, but the default moves only to keys of the organisation.
    {workspace_keys, "key-1"} = add!(ctx.scope, only([ctx.checkout]))
    assert Repo.get!(Secret, workspace_keys.secret_id).workspace_id == ctx.checkout.id

    {:ok, shared} =
      Connections.create_provider(ctx.scope, %{
        provider: "anthropic",
        applies_to: "selected",
        workspace_ids: [ctx.checkout.id],
        keys: [%{value: @key}]
      })

    assert Repo.get!(Secret, shared.secret_id).workspace_id == nil
    [value_id] = value_ids(shared)

    {:ok, choice} =
      ModelChoicesFixtures.put_choice(ctx.scope, :organisation, %{provider: shared.public_id})

    providers = Repo.aggregate(Connection, :count)

    assert move(ctx.scope, shared, value_id, only([ctx.storefront])) ==
             {:error, {:last_key, nil}}

    assert Repo.aggregate(Connection, :count) == providers
    assert value_ids(shared) == [value_id]
    assert Repo.get!(ModelChoice, choice.id).connection_id == shared.id
  end

  test "a key of a provider that fails its integrity code does not move", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())

    # A name written without a new code.
    {1, _rows} =
      Repo.update_all(from(c in Connection, where: c.id == ^every.id),
        set: [name: "Changed outside Qory Apiary"]
      )

    providers = Repo.aggregate(Connection, :count)

    assert move(ctx.scope, every, "key-2", only([ctx.checkout])) ==
             {:error, {:integrity, [every.public_id]}}

    assert Repo.aggregate(Connection, :count) == providers
    assert value_ids(every) == ["key-1", "key-2"]
  end

  test "a rename of the default key and a move in one save, of a provider that fails its integrity code, change nothing",
       ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())
    assert Repo.get!(Connection, every.id).default_value_id == "key-1"

    # A name written without a new code.
    {1, _rows} =
      Repo.update_all(from(c in Connection, where: c.id == ^every.id),
        set: [name: "Changed outside Qory Apiary"]
      )

    providers = Repo.aggregate(Connection, :count)

    assert Connections.update_provider_key(
             ctx.scope,
             every,
             "key-1",
             Map.merge(%{"value_id" => "spare"}, only([ctx.checkout]))
           ) == {:error, {:integrity, [every.public_id]}}

    assert Repo.aggregate(Connection, :count) == providers
    assert value_ids(every) == ["key-1", "key-2"]
    refute Connections.intact?(Repo.preload(Repo.get!(Connection, every.id), :release))
  end

  test "the last key of a provider a live run uses does not move", ctx do
    {checkout, "key-1"} = add!(ctx.scope, only([ctx.checkout]))
    run = Apiary.RunEventsFixtures.run_fixture(ctx.scope)

    Apiary.ModelKeysFixtures.run_keys!(run, [
      %{provider: checkout, secret_value_id: value!(checkout, "key-1").id}
    ])

    assert move(ctx.scope, checkout, "key-1", every()) ==
             {:error, {:provider_in_use, %{places: [], runs: [run.public_id]}}}

    assert value_ids(checkout) == ["key-1"]
  end

  test "a run that has a key that moves loses it, as it loses a removed key", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())
    old = value!(every, "key-2")
    key = Apiary.ModelKeysFixtures.run_key!(ctx.scope, old)

    assert {:ok, moved_to} = move(ctx.scope, every, "key-2", only([ctx.checkout]))

    # The run's key row points at a value that is gone, and the run has no copy of the
    # moved key: a secrets request that lists it returns `credential_unavailable`, and a
    # report of it writes nothing.
    assert [%{secret_value_id: id}] = Apiary.ModelKeysFixtures.stored_keys(key.run_id)
    assert id == old.id
    refute Repo.get(Value, old.id)
    assert Repo.all(from c in Copy, where: c.run_id == ^key.run_id) == []
    assert ModelKeys.run_keys(Repo.get!(Apiary.Runs.Run, key.run_id)) == []
    assert value!(moved_to, "key-2")
  end

  test "keeps the key's settings, states, rejection, hint and the times it was added and set",
       ctx do
    {every, "key-1"} = add!(ctx.scope, every())

    {_every, "key-2"} =
      add!(ctx.scope, every(), %{
        "key_settings" => %{
          "pause_seconds" => 7200,
          "reset_weekday" => 5,
          "reset_time" => "14:00",
          "reset_time_zone" => "Europe/Berlin"
        }
      })

    until = DateTime.add(DateTime.utc_now(), 3600)
    Apiary.ModelKeysFixtures.key_state!(every, "key-2", until: until)
    old = value!(every, "key-2")

    Repo.insert_all(Rejection, [
      %{
        secret_value_id: old.id,
        organisation_id: old.organisation_id,
        rejected_at: DateTime.utc_now(),
        value_set_at: old.value_set_at,
        updated_at: DateTime.utc_now()
      }
    ])

    assert {:ok, moved_to} = move(ctx.scope, every, "key-2", only([ctx.checkout]))
    new = value!(moved_to, "key-2")

    refute new.id == old.id
    assert new.value_set_at == old.value_set_at
    assert new.inserted_at == old.inserted_at
    assert new.hint == old.hint

    assert %Setting{pause_seconds: 7200, reset_weekday: 5, reset_time_zone: "Europe/Berlin"} =
             ModelKeys.setting(new.id)

    assert [%State{window: "five_hour", status: "rejected", cooldown_until: cooled}] =
             Repo.all(from s in State, where: s.secret_value_id == ^new.id)

    assert DateTime.compare(cooled, DateTime.truncate(until, :microsecond)) == :eq
    assert %{} = rejections = ModelKeys.rejections(moved_to)
    assert Map.has_key?(rejections, new.id)
  end

  test "keeps a sign-in's login, without its lease", ctx do
    {:ok, _provider, "key-1"} =
      Connections.add_key(ctx.scope, %{
        "provider" => "openai-subscription",
        "value" => Apiary.ModelKeysFixtures.device_login(),
        "applies_to" => "all"
      })

    {:ok, provider, "key-2"} =
      Connections.add_key(ctx.scope, %{
        "provider" => "openai-subscription",
        "value" => Apiary.ModelKeysFixtures.device_login(tag: "b"),
        "applies_to" => "all"
      })

    old = value!(provider, "key-2")

    Repo.update_all(from(l in Login, where: l.secret_value_id == ^old.id),
      set: [lease_id: Ecto.UUID.generate(), lease_until: DateTime.add(DateTime.utc_now(), 60)]
    )

    before = Repo.get_by!(Login, secret_value_id: old.id)

    assert {:ok, moved_to} = move(ctx.scope, provider, "key-2", only([ctx.checkout]))
    new = value!(moved_to, "key-2")
    login = Repo.get_by!(Login, secret_value_id: new.id)

    assert login.account_id == before.account_id
    assert login.signed_in_at == before.signed_in_at
    assert login.generation == before.generation
    assert login.lease_id == nil
    assert login.lease_until == nil

    {:ok, document} = Apiary.Secrets.reveal_login(moved_to, new.id)
    assert document =~ "rt-fixture-refresh-token-b-"
  end

  test "a save with the provider's workspaces moves nothing", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    assert {:ok, saved} = move(ctx.scope, every, "key-1", every())
    assert saved.id == every.id
    assert value_ids(every) == ["key-1"]
  end

  test "a rename and a move are one save", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())

    assert {:ok, moved_to} =
             Connections.update_provider_key(
               ctx.scope,
               every,
               "key-2",
               Map.merge(%{"value_id" => "spare"}, only([ctx.checkout]))
             )

    assert value_ids(moved_to) == ["spare"]
    assert value_ids(every) == ["key-1"]
  end

  test "a rename to a taken name with other workspaces changes nothing", ctx do
    {every, "key-1"} = add!(ctx.scope, every())

    {:ok, _every} =
      Connections.update_provider_key(ctx.scope, every, "key-1", %{"value_id" => "spare"})

    {checkout, "key-2"} = add!(ctx.scope, only([ctx.checkout]))
    {_checkout, "key-3"} = add!(ctx.scope, only([ctx.checkout]))

    assert {:error,
            %Ecto.Changeset{errors: [value_id: {"is already the name of another key", _}]}} =
             Connections.update_provider_key(
               ctx.scope,
               checkout,
               "key-3",
               Map.merge(%{"value_id" => "spare"}, every())
             )

    assert value_ids(checkout) == ["key-2", "key-3"]
    assert value_ids(every) == ["spare"]
  end

  test "a sign-in moves into the provider of those workspaces with its login", ctx do
    add_login = fn tag, reach ->
      {:ok, provider, value_id} =
        Connections.add_key(
          ctx.scope,
          Map.merge(
            %{
              "provider" => "openai-subscription",
              "value" => Apiary.ModelKeysFixtures.device_login(tag: tag)
            },
            reach
          )
        )

      {provider, value_id}
    end

    {every, "key-1"} = add_login.("a", every())
    {checkout, "key-2"} = add_login.("b", only([ctx.checkout]))
    {_checkout, "key-3"} = add_login.("c", only([ctx.checkout]))
    old = value!(checkout, "key-3")
    before = Repo.get_by!(Login, secret_value_id: old.id)

    assert {:ok, moved_to} = move(ctx.scope, checkout, "key-3", every())
    assert moved_to.id == every.id

    new = value!(every, "key-3")
    login = Repo.get_by!(Login, secret_value_id: new.id)
    assert login.account_id == before.account_id
    assert login.generation == before.generation

    {:ok, document} = Apiary.Secrets.reveal_login(Repo.get!(Connection, every.id), new.id)
    assert document =~ "rt-fixture-refresh-token-c-"
  end

  test "records the move with public ids", ctx do
    {every, "key-1"} = add!(ctx.scope, every())
    {_every, "key-2"} = add!(ctx.scope, every())

    assert {:ok, moved_to} = move(ctx.scope, every, "key-2", only([ctx.checkout]))

    assert [entry] =
             Repo.all(from e in Audit.Entry, where: e.details["change"] == "provider_key_moved")

    assert entry.action == "provider.write"
    assert entry.subject_id == moved_to.id
    assert entry.before == %{"connection_id" => every.public_id, "applies_to" => "all"}

    assert entry.after == %{
             "connection_id" => moved_to.public_id,
             "applies_to" => "selected",
             "workspace_ids" => [ctx.checkout.public_id]
           }

    assert entry.details["value_id"] == "key-2"
    assert entry.details["connection_id"] == moved_to.public_id
  end

  describe "the workspaces" do
    test "a workspace of another organisation is not found", ctx do
      {every, "key-1"} = add!(ctx.scope, every())
      {_every, "key-2"} = add!(ctx.scope, every())
      %{scope: other} = sign_up_fixture()

      assert move(ctx.scope, every, "key-2", only([other.workspace])) ==
               {:error, :workspace_not_found}

      assert value_ids(every) == ["key-1", "key-2"]
    end

    test "a provider of another organisation is not found", ctx do
      {every, "key-1"} = add!(ctx.scope, every())
      %{scope: other} = sign_up_fixture()

      assert move(other, every, "key-1", only([other.workspace])) == {:error, :not_found}
      assert value_ids(every) == ["key-1"]
    end

    test "Only these workspaces without one returns no_workspace", ctx do
      {every, "key-1"} = add!(ctx.scope, every())
      assert move(ctx.scope, every, "key-1", only([])) == {:error, :no_workspace}
    end

    test "a workspace marked for deletion leaves the key's workspaces", ctx do
      {both, "key-1"} = add!(ctx.scope, only([ctx.checkout, ctx.storefront]))
      {_both, "key-2"} = add!(ctx.scope, only([ctx.checkout, ctx.storefront]))
      billing = workspace_fixture(ctx.scope.organisation, "Billing")
      mark!(ctx.scope, ctx.storefront)

      assert {:ok, moved_to} = move(ctx.scope, both, "key-2", only([ctx.checkout, billing]))

      assert Enum.sort(Connections.workspace_ids_of(moved_to)) ==
               Enum.sort([ctx.checkout.id, billing.id])

      assert value_ids(both) == ["key-1"]
    end

    test "a save of the key's workspaces less one marked for deletion moves nothing", ctx do
      {both, "key-1"} = add!(ctx.scope, only([ctx.checkout, ctx.storefront]))
      mark!(ctx.scope, ctx.storefront)

      assert {:ok, saved} = move(ctx.scope, both, "key-1", only([ctx.checkout]))
      assert saved.id == both.id
      assert value_ids(both) == ["key-1"]
    end

    test "a person who does not reach every workspace keeps the workspaces they do not reach",
         ctx do
      {both, "key-1"} = add!(ctx.scope, only([ctx.checkout, ctx.storefront]))
      {_both, "key-2"} = add!(ctx.scope, only([ctx.checkout, ctx.storefront]))
      billing = workspace_fixture(ctx.scope.organisation, "Billing")

      :ok = Apiary.Edition.put_test_stub(AdminsReachNamed)
      Process.put(:admins_reach, [ctx.checkout.id, billing.id])
      %{scope: admin} = member_fixture(ctx.scope, :admin)
      admin = %{admin | workspace: ctx.checkout}

      # Storefront, which the admin does not reach, stays; Billing joins it.
      assert {:ok, moved_to} = move(admin, both, "key-2", only([billing]))

      assert Enum.sort(Connections.workspace_ids_of(moved_to)) ==
               Enum.sort([ctx.storefront.id, billing.id])

      # A key for every workspace keeps it for that person.
      {every, value_id} = add!(ctx.scope, every())
      assert move(admin, every, value_id, only([billing])) == {:error, :forbidden}
      assert {:ok, saved} = move(admin, every, value_id, every())
      assert saved.id == every.id
    end
  end

  describe "Apiary.Secrets.copy_provider_key/4" do
    test "reads the key's secret in the scope's organisation alone", ctx do
      {every, "key-1"} = add!(ctx.scope, every())
      {checkout, "key-2"} = add!(ctx.scope, only([ctx.checkout]))

      %{scope: other} = sign_up_fixture()
      {_theirs, "key-1"} = add!(other, every())
      {theirs, "key-2"} = add!(other, every())
      their_row = value!(theirs, "key-2").id

      # The provider's row linked to the keys of another organisation, with the foreign
      # keys that keep a provider's keys in its organisation off for this transaction.
      Repo.query!("SET LOCAL session_replication_role = replica")

      {1, _rows} =
        Repo.update_all(from(c in Connection, where: c.id == ^checkout.id),
          set: [secret_id: theirs.secret_id]
        )

      Repo.query!("SET LOCAL session_replication_role = origin")

      tampered = Repo.get!(Connection, checkout.id)

      assert Apiary.Secrets.copy_provider_key(ctx.scope, tampered, their_row, every) ==
               {:error, :not_found}

      assert value_ids(every) == ["key-1"]
    end

    test "copies only into a provider of the key's group", ctx do
      {every, "key-1"} = add!(ctx.scope, every())

      {:ok, other_kind} =
        Connections.create_provider(ctx.scope, %{
          provider: "deepseek",
          applies_to: "all",
          keys: [%{value_id: "main", value: "y"}]
        })

      assert Apiary.Secrets.copy_provider_key(
               ctx.scope,
               every,
               value!(every, "key-1").id,
               other_kind
             ) == {:error, :other_key_group}

      assert value_ids(other_kind) == ["main"]
    end
  end
end
