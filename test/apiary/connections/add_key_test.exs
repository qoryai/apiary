defmodule Apiary.Connections.AddKeyTest do
  # A model provider key added and removed as a person sees it, one key at a time
  # (`Apiary.Connections.add_key/2`, `remove_key/3`). The key group is the providers of one
  # kind, chain and stored settings; a key joins the provider of its group with the same
  # workspaces, and its value id is `key-<n>`. Removing a provider's last key moves each
  # model choice of it to a provider of the group that serves the choice's workspace, or
  # is refused.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Connections, ModelChoicesFixtures, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.Coded
  alias Apiary.ModelChoices.{Fallback, ModelChoice}
  alias Apiary.ModelKeys.Setting
  alias Apiary.Runs.ModelKey
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: :factory

  @key "sk-ant-add-key-0123456789abcdef"

  # An edition where admins reach only the workspaces in the test process's `:admins_reach`;
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
    billing = workspace_fixture(scope.organisation, "Billing")
    %{scope: scope, checkout: scope.workspace, storefront: storefront, billing: billing}
  end

  defp add!(scope, reach, attrs \\ %{}) do
    {:ok, provider, value_id} = add(scope, reach, attrs)
    {provider, value_id}
  end

  defp add(scope, reach, attrs \\ %{}) do
    Connections.add_key(
      scope,
      Map.merge(%{"provider" => "anthropic", "value" => @key}, Map.merge(reach, attrs))
    )
  end

  defp every, do: %{"applies_to" => "all"}

  defp only(workspaces),
    do: %{"applies_to" => "selected", "workspace_ids" => Enum.map(workspaces, & &1.id)}

  defp value_ids(%Connection{secret_id: secret_id}),
    do:
      Repo.all(
        from v in Value,
          where: v.secret_id == ^secret_id,
          order_by: v.inserted_at,
          select: v.value_id
      )

  defp providers, do: Repo.aggregate(Connection, :count)

  describe "add_key/2" do
    test "a key of the same kind, chain, reach and settings is the next value of that provider",
         %{scope: scope} do
      {first, "key-1"} = add!(scope, every())
      {second, "key-2"} = add!(scope, every())

      assert second.id == first.id
      assert value_ids(second) == ["key-1", "key-2"]
      assert providers() == 1
    end

    test "the same workspaces in another order are the same reach", ctx do
      ascending = Enum.sort_by([ctx.checkout, ctx.storefront], & &1.id)
      {first, "key-1"} = add!(ctx.scope, only(ascending))
      {second, "key-2"} = add!(ctx.scope, only(Enum.reverse(ascending)))

      assert second.id == first.id
    end

    test "another reach makes another provider, its key numbered after the kind's keys", ctx do
      {every, "key-1"} = add!(ctx.scope, every())
      {checkout, "key-2"} = add!(ctx.scope, only([ctx.checkout]))

      refute checkout.id == every.id
      assert value_ids(checkout) == ["key-2"]
      # One workspace: the key is a secret of that workspace.
      assert Repo.get!(Secret, checkout.secret_id).workspace_id == ctx.checkout.id
      assert checkout.applies_to == "selected"
    end

    test "partly overlapping workspaces make another provider, of the organisation", ctx do
      {first, "key-1"} = add!(ctx.scope, only([ctx.checkout, ctx.storefront]))
      {second, "key-2"} = add!(ctx.scope, only([ctx.storefront, ctx.billing]))

      refute second.id == first.id

      assert Enum.sort(Connections.workspace_ids_of(second)) ==
               Enum.sort([ctx.storefront.id, ctx.billing.id])

      assert Repo.get!(Secret, second.secret_id).workspace_id == nil
    end

    test "a provider of another chain is not in the group", %{scope: scope} do
      {first, "key-1"} = add!(scope, every())

      Repo.get!(Connection, first.id)
      |> Ecto.Changeset.change(chain: "operator")
      |> Coded.seal()
      |> Repo.update!()

      {second, "key-2"} = add!(scope, every())
      refute second.id == first.id
    end

    test "the 33rd key goes to a new provider", %{scope: scope} do
      keys = for n <- 1..32, do: %{value: "#{@key}-#{n}"}

      {:ok, full} =
        Connections.create_provider(scope, %{provider: "anthropic", applies_to: "all", keys: keys})

      {added, "key-33"} = add!(scope, every())

      refute added.id == full.id
      assert value_ids(added) == ["key-33"]
    end

    test "writes the key's settings, to a new provider and to one there", %{scope: scope} do
      settings = %{"pause_seconds" => 7200}

      {first, "key-1"} = add!(scope, every(), %{"key_settings" => settings})
      {_same, "key-2"} = add!(scope, every(), %{"key_settings" => %{"pause_seconds" => 600}})

      pauses =
        Repo.all(
          from s in Setting,
            join: v in Value,
            on: v.id == s.secret_value_id,
            where: v.secret_id == ^first.secret_id,
            order_by: v.value_id,
            select: s.pause_seconds
        )

      assert pauses == [7200, 600]
    end

    test "a removed key's number is not given again", %{scope: scope} do
      {provider, "key-1"} = add!(scope, every())
      {_provider, "key-2"} = add!(scope, every())

      row = Repo.get_by!(Value, secret_id: provider.secret_id, value_id: "key-2")
      {:ok, _provider} = Connections.remove_key(scope, provider, row.id)

      {_provider, "key-3"} = add!(scope, every())
    end

    test "after a provider is deleted, its numbers count no more", %{scope: scope} do
      {_every, "key-1"} = add!(scope, every())
      {_every, "key-2"} = add!(scope, every())
      {checkout, "key-3"} = add!(scope, only([scope.workspace]))
      {:ok, _deleted} = Connections.delete_provider(scope, checkout)

      # key-2 is the highest current key, so key-3 is given again.
      {_every, "key-3"} = add!(scope, every())
    end

    test "leaves out the workspaces the person does not reach", ctx do
      :ok = Apiary.Edition.put_test_stub(AdminsReachNamed)
      Process.put(:admins_reach, [ctx.checkout.id])
      %{scope: admin} = member_fixture(ctx.scope, :admin)
      admin = %{admin | workspace: ctx.checkout}

      {provider, "key-1"} = add!(admin, only([ctx.checkout, ctx.storefront]))
      assert Connections.workspace_ids_of(provider) == [ctx.checkout.id]

      assert add(admin, only([ctx.storefront])) == {:error, :no_workspace}
    end

    test "sets again the model providers of the organisation's waiting runs", ctx do
      %{scope: scope} = ctx
      {every, "key-1"} = add!(scope, every())

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{provider: every.public_id})

      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, queued} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item, 1) end)

      # The run with no model providers, so that the refresh has a change to write.
      waiting = from(r in Apiary.Dispatches.DispatchRun, where: r.id == ^queued.id)
      {1, _rows} = Repo.update_all(waiting, set: [model_provider_ids: []])

      # The key makes a second provider of the group, for Checkout alone, the run's
      # workspace: the run waits for both.
      {checkout, "key-2"} = add!(scope, only([ctx.checkout]))
      refute checkout.id == every.id

      assert Repo.one!(from r in waiting, select: r.model_provider_ids) == [
               every.id,
               checkout.id
             ]
    end

    test "refuses Every workspace to a person who does not reach every workspace", ctx do
      :ok = Apiary.Edition.put_test_stub(AdminsReachNamed)
      Process.put(:admins_reach, [ctx.checkout.id])
      %{scope: admin} = member_fixture(ctx.scope, :admin)
      admin = %{admin | workspace: ctx.checkout}

      assert add(admin, every()) == {:error, :forbidden}
      assert providers() == 0

      # An owner reaches every workspace.
      assert {_provider, "key-1"} = add!(ctx.scope, every())
    end

    test "refuses Only these workspaces without a workspace", %{scope: scope} do
      assert add(scope, %{"applies_to" => "selected", "workspace_ids" => []}) ==
               {:error, :no_workspace}

      assert providers() == 0
    end
  end

  describe "a key renamed" do
    defp rename(scope, provider, from, to),
      do: Connections.update_provider_key(scope, provider, from, %{"value_id" => to})

    defp counter(%Connection{secret_id: id}), do: Repo.get!(Secret, id).last_key_number

    test "to a name key-<n> is refused", %{scope: scope} do
      {provider, "key-1"} = add!(scope, every())

      for name <- ~w(key-7 key-02 key-1000000000) do
        assert {:error, changeset} = rename(scope, provider, "key-1", name)

        assert errors_on(changeset).value_id == [
                 "Choose another name: Qory Apiary gives names like key-3 to new keys."
               ]
      end

      assert value_ids(provider) == ["key-1"]
    end

    test "to a name of another form works, and the next key gets the next number",
         %{scope: scope} do
      {%Connection{id: id} = provider, "key-1"} = add!(scope, every())
      {%Connection{id: ^id}, "key-2"} = add!(scope, every())

      assert {:ok, _} = rename(scope, provider, "key-2", "work-account")
      assert {%Connection{id: ^id}, "key-3"} = add!(scope, every())
      assert Enum.sort(value_ids(provider)) == ["key-1", "key-3", "work-account"]
    end

    test "to the name it has is kept", %{scope: scope} do
      {provider, "key-1"} = add!(scope, every())

      assert {:ok, _} = rename(scope, provider, "key-1", "key-1")
      assert value_ids(provider) == ["key-1"]
    end

    test "a key whose number has more than 9 digits does not stop the next add",
         %{scope: scope} do
      {%Connection{id: id} = provider, "key-1"} = add!(scope, every())

      # Written past Edit key, as a key of an earlier version could be.
      Repo.update_all(from(v in Value, where: v.secret_id == ^provider.secret_id),
        set: [value_id: "key-999999999"]
      )

      assert {%Connection{id: ^id}, "key-1000000000"} = add!(scope, every())
      assert counter(provider) == 1
    end
  end

  describe "remove_key/3" do
    defp row(provider, value_id),
      do: Repo.get_by!(Value, secret_id: provider.secret_id, value_id: value_id).id

    defp other!(scope, kind) do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: kind,
          keys: [%{value_id: "main", value: "y"}]
        })

      provider
    end

    # A provider for every workspace with one key, key-1, outside add_key/2's grouping.
    defp all_provider!(scope) do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          applies_to: "all",
          keys: [%{value: @key}]
        })

      provider
    end

    defp fallbacks(choice),
      do:
        Repo.all(
          from f in Fallback,
            where: f.model_choice_id == ^choice.id,
            order_by: f.position,
            select: {f.position, f.connection_id}
        )

    # A fallback of `provider` at `position` of `choice`, stored directly: a save drops a
    # fallback of the key group of the choice's provider, or of another fallback's, and a
    # change of a provider's settings can leave one.
    defp stored_fallback!(choice, position, provider) do
      attrs = ModelChoicesFixtures.fallback_attrs(provider)

      Repo.insert!(%Fallback{
        organisation_id: choice.organisation_id,
        model_choice_id: choice.id,
        position: position,
        connection_id: provider.id,
        runtime: attrs.runtime,
        tiers: attrs.tiers |> Jason.encode!() |> Jason.decode!()
      })
    end

    defp choose!(scope, provider, attrs \\ %{}) do
      {:ok, choice} =
        ModelChoicesFixtures.put_choice(
          scope,
          :workspace,
          Map.merge(%{provider: provider.public_id}, attrs)
        )

      choice
    end

    test "removes a key that is not the default", %{scope: scope} do
      {provider, _} = add!(scope, every())
      {_, _} = add!(scope, every())

      assert {:ok, _} = Connections.remove_key(scope, provider, row(provider, "key-2"))
      assert value_ids(provider) == ["key-1"]
    end

    test "makes another key the default when the default key goes", %{scope: scope} do
      {provider, _} = add!(scope, every())
      {_, _} = add!(scope, every())
      {_, _} = add!(scope, every())
      assert Repo.get!(Connection, provider.id).default_value_id == "key-1"

      assert {:ok, _} = Connections.remove_key(scope, provider, row(provider, "key-1"))

      assert value_ids(provider) == ["key-2", "key-3"]
      assert Repo.get!(Connection, provider.id).default_value_id == "key-2"
    end

    test "the last key moves the choices and fallbacks to another provider of the group",
         ctx do
      %{scope: scope} = ctx
      {every, _} = add!(scope, every())
      {checkout, _} = add!(scope, only([ctx.checkout]))

      {:ok, deepseek} =
        Connections.create_provider(scope, %{
          provider: "deepseek",
          keys: [%{value_id: "main", value: "y"}]
        })

      choice =
        choose!(scope, every, %{fallbacks: [ModelChoicesFixtures.fallback_attrs(deepseek)]})

      stored_fallback!(choice, 1, checkout)
      assert fallbacks(choice) == [{0, deepseek.id}, {1, checkout.id}]

      # The choice moves to the Checkout provider, its stored second fallback: that
      # fallback goes, and the first keeps position 0.
      assert {:ok, _} = Connections.remove_key(scope, every, row(every, "key-1"))

      refute Repo.get(Connection, every.id)
      assert Repo.get!(ModelChoice, choice.id).connection_id == checkout.id
      assert fallbacks(choice) == [{0, deepseek.id}]
    end

    test "a fallback moves to another provider of its group", ctx do
      %{scope: scope} = ctx

      {:ok, deepseek} =
        Connections.create_provider(scope, %{
          provider: "deepseek",
          keys: [%{value_id: "main", value: "y"}]
        })

      {every, _} = add!(scope, every())
      {checkout, _} = add!(scope, only([ctx.checkout]))

      choice =
        choose!(scope, deepseek, %{fallbacks: [ModelChoicesFixtures.fallback_attrs(checkout)]})

      assert {:ok, _} = Connections.remove_key(scope, checkout, row(checkout, "key-2"))

      assert Repo.all(
               from f in Fallback,
                 where: f.model_choice_id == ^choice.id,
                 select: {f.position, f.connection_id}
             ) == [{0, every.id}]
    end

    test "the organisation's default does not move to a provider of fewer workspaces", ctx do
      %{scope: scope} = ctx
      {both, _} = add!(scope, only([ctx.checkout, ctx.storefront]))
      {_checkout, _} = add!(scope, only([ctx.checkout]))

      {:ok, choice} =
        ModelChoicesFixtures.put_choice(scope, :organisation, %{provider: both.public_id})

      assert Connections.remove_key(scope, both, row(both, "key-1")) ==
               {:error, {:last_key, nil}}

      assert Repo.get!(ModelChoice, choice.id).connection_id == both.id
    end

    test "the organisation's default does not move to a provider whose key is a workspace's secret",
         ctx do
      %{scope: scope} = ctx
      keys = for n <- 1..32, do: %{value: "#{@key}-#{n}"}

      {:ok, full} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          applies_to: "selected",
          workspace_ids: [ctx.checkout.id],
          keys: keys
        })

      {:ok, choice} =
        ModelChoicesFixtures.put_choice(scope, :organisation, %{provider: full.public_id})

      # The first provider has no room, so the key makes a provider for Checkout alone,
      # its key a secret of Checkout.
      {checkout, "key-33"} = add!(scope, only([ctx.checkout]))
      refute checkout.id == full.id
      assert Repo.get!(Secret, checkout.secret_id).workspace_id == ctx.checkout.id

      for n <- 1..31,
          do: assert({:ok, _} = Connections.remove_key(scope, full, row(full, "key-#{n}")))

      assert Connections.remove_key(scope, full, row(full, "key-32")) ==
               {:error, {:last_key, nil}}

      assert Repo.get!(ModelChoice, choice.id).connection_id == full.id
      assert value_ids(full) == ["key-32"]
    end

    test "a fallback of the organisation's default moves only to a provider whose keys are a secret of the organisation",
         ctx do
      %{scope: scope} = ctx
      keys = for n <- 1..32, do: %{value: "#{@key}-#{n}"}

      {:ok, full} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          applies_to: "selected",
          workspace_ids: [ctx.checkout.id],
          keys: keys
        })

      deepseek = other!(scope, "deepseek")

      {:ok, choice} =
        ModelChoicesFixtures.put_choice(scope, :organisation, %{
          provider: deepseek.public_id,
          fallbacks: [ModelChoicesFixtures.fallback_attrs(full)]
        })

      # The first provider has no room, so the key makes a provider for Checkout alone,
      # its key a secret of Checkout.
      {checkout, "key-33"} = add!(scope, only([ctx.checkout]))
      assert Repo.get!(Secret, checkout.secret_id).workspace_id == ctx.checkout.id

      for n <- 1..31,
          do: assert({:ok, _} = Connections.remove_key(scope, full, row(full, "key-#{n}")))

      assert Connections.remove_key(scope, full, row(full, "key-32")) ==
               {:error, {:last_key, nil}}

      assert fallbacks(choice) == [{0, full.id}]

      # A provider for Checkout whose key is a secret of the organisation takes the
      # fallback.
      {:ok, shared} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          applies_to: "selected",
          workspace_ids: [ctx.checkout.id],
          keys: [%{value: @key}]
        })

      assert {:ok, _} = Connections.remove_key(scope, full, row(full, "key-32"))
      assert Repo.get!(ModelChoice, choice.id).connection_id == deepseek.id
      assert fallbacks(choice) == [{0, shared.id}]
    end

    test "the last key of the group for a choice's workspace is refused", ctx do
      %{scope: scope} = ctx
      {checkout, _} = add!(scope, only([ctx.checkout]))
      {_storefront, _} = add!(scope, only([ctx.storefront]))
      choice = choose!(scope, checkout)

      assert Connections.remove_key(scope, checkout, row(checkout, "key-1")) ==
               {:error, {:last_key, ctx.checkout.id}}

      assert Repo.get!(ModelChoice, choice.id).connection_id == checkout.id
      assert value_ids(checkout) == ["key-1"]
    end

    test "a moved fallback that is the choice's provider goes, and the later ones move up",
         ctx do
      %{scope: scope} = ctx
      {every, _} = add!(scope, every())
      {checkout, _} = add!(scope, only([ctx.checkout]))
      deepseek = other!(scope, "deepseek")
      openrouter = other!(scope, "openrouter")

      choice =
        choose!(scope, checkout, %{
          fallbacks: Enum.map([deepseek, openrouter], &ModelChoicesFixtures.fallback_attrs/1)
        })

      {1, _rows} =
        Repo.update_all(
          from(f in Fallback, where: f.model_choice_id == ^choice.id and f.position == 1),
          set: [position: 2]
        )

      stored_fallback!(choice, 1, every)
      assert fallbacks(choice) == [{0, deepseek.id}, {1, every.id}, {2, openrouter.id}]

      assert {:ok, _} = Connections.remove_key(scope, every, row(every, "key-1"))
      assert fallbacks(choice) == [{0, deepseek.id}, {1, openrouter.id}]
    end

    test "a moved fallback that another fallback has goes", ctx do
      %{scope: scope} = ctx
      {every, _} = add!(scope, every())
      {checkout, _} = add!(scope, only([ctx.checkout]))
      deepseek = other!(scope, "deepseek")

      choice =
        choose!(scope, deepseek, %{fallbacks: [ModelChoicesFixtures.fallback_attrs(every)]})

      stored_fallback!(choice, 1, checkout)
      assert fallbacks(choice) == [{0, every.id}, {1, checkout.id}]

      assert {:ok, _} = Connections.remove_key(scope, every, row(every, "key-1"))
      assert fallbacks(choice) == [{0, checkout.id}]
    end

    test "each moved choice has an entry of its change", ctx do
      %{scope: scope} = ctx
      {every, _} = add!(scope, every())
      {checkout, _} = add!(scope, only([ctx.checkout]))
      choice = choose!(scope, every)

      assert {:ok, _} = Connections.remove_key(scope, every, row(every, "key-1"))

      assert [entry] =
               Repo.all(
                 from e in Audit.Entry,
                   where: e.subject_id == ^choice.id and e.details["change"] == "choice_changed"
               )

      assert entry.action == "model_choice.write"
      assert entry.before["provider"] == every.public_id
      assert entry.after["provider"] == checkout.public_id
    end

    test "the organisation's default moves to a provider of the group for every workspace",
         %{scope: scope} do
      first = all_provider!(scope)
      second = all_provider!(scope)

      {:ok, choice} =
        ModelChoicesFixtures.put_choice(scope, :organisation, %{provider: first.public_id})

      assert {:ok, _} = Connections.remove_key(scope, first, row(first, "key-1"))
      assert Repo.get!(ModelChoice, choice.id).connection_id == second.id
    end

    test "a provider of the group with no key takes no choice", %{scope: scope} do
      first = all_provider!(scope)
      empty = all_provider!(scope)
      Repo.delete_all(from v in Value, where: v.secret_id == ^empty.secret_id)

      {:ok, choice} =
        ModelChoicesFixtures.put_choice(scope, :organisation, %{provider: first.public_id})

      assert Connections.remove_key(scope, first, row(first, "key-1")) ==
               {:error, {:last_key, nil}}

      assert Repo.get!(ModelChoice, choice.id).connection_id == first.id
    end

    test "the last key of a provider a live run uses is refused", %{scope: scope} do
      {provider, _} = add!(scope, every())
      key = row(provider, "key-1")
      run = Apiary.RunEventsFixtures.run_fixture(scope)

      Repo.insert!(%ModelKey{
        run_id: run.id,
        position: 1,
        name: "#{provider.public_id}-1",
        connection_id: provider.id,
        secret_id: provider.secret_id,
        secret_value_id: key,
        chain: "organisation",
        api: %{
          "format" => "anthropic-messages",
          "endpoint" => "https://api.anthropic.com",
          "auth" => %{}
        },
        pause_for_s: 60
      })

      assert Connections.remove_key(scope, provider, key) ==
               {:error, {:provider_in_use, %{places: [], runs: [run.public_id]}}}

      assert Repo.get(Connection, provider.id)
    end

    test "the last key of a provider for one workspace deletes that workspace's secret", ctx do
      {provider, _} = add!(ctx.scope, only([ctx.checkout]))
      assert Repo.get!(Secret, provider.secret_id).workspace_id == ctx.checkout.id

      assert {:ok, _} = Connections.remove_key(ctx.scope, provider, row(provider, "key-1"))
      refute Repo.get(Connection, provider.id)
      refute Repo.get(Secret, provider.secret_id)
    end

    test "the last key that no choice uses removes its provider", %{scope: scope} do
      {provider, _} = add!(scope, every())

      assert {:ok, _} = Connections.remove_key(scope, provider, row(provider, "key-1"))
      refute Repo.get(Connection, provider.id)
      refute Repo.get(Secret, provider.secret_id)
    end

    test "a row id that is not a key of the provider is not found", %{scope: scope} do
      {provider, _} = add!(scope, every())
      assert Connections.remove_key(scope, provider, Ecto.UUID.generate()) == {:error, :not_found}
    end
  end
end
