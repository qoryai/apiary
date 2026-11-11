defmodule Apiary.Dispatches.RunSettingsRacesTest do
  # The claim of an explore run whose model choice names a provider
  # (`Apiary.Dispatches.RunSettings`), racing a change of that provider: its address, or
  # its deletion with the choice that names it. Each side runs on a connection apart,
  # outside the SQL sandbox, so each commits and each waits on the other's locks as it
  # would in production. Not async: what these tests commit is visible to every other
  # test while they run, and they delete it again before they end.
  #
  # The rule under test: the claim reads the choices without a lock, then takes the
  # provider's row and its keys' secret's row `FOR SHARE`, before anything else; a change
  # of the provider takes its row `FOR UPDATE`. So the two take turns, whoever comes
  # second sees what the first wrote, and neither deadlocks: a deletion that comes second
  # reads the run the claim registered, and is refused.
  #
  # And two writes of a waiting run's model providers after changes of its model choice
  # (`Apiary.Dispatches.refresh_model_providers/1`): each takes the run's row
  # `FOR UPDATE` before it reads the choice, so the write that comes last read the choice
  # last.
  use ExUnit.Case, async: false

  # A list in `needs:` is read by this hook (`Apiary.TestSetup`).
  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.DispatchedRunsFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, Edition, ModelChoices, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.Connection, as: AdapterConnection
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Run
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  # The catalogue's runtime, read from the list rather than named here.
  @runtime hd(Apiary.Kinds.Runtimes.list()).name

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @old_address "https://litellm.example.com"
  @new_address "https://models.example.com"

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    started = database_now()
    %{scope: scope} = sign_up()
    {:ok, made} = Agent.start(fn -> [] end)
    place = handover_place_fixture(scope, allow_secrets: true)
    {gateway_key, _seed} = place.gateway_key

    # Before the clean up of `setup_races`: the organisation, then what outlives it, the
    # adapters the work items came through, the keys' public halves and the entries their
    # adapters left in the instance's trail.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      adapters = Agent.get(made, & &1)
      Agent.stop(made)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)

      adapter_keys =
        Repo.all(from k in AccessKey, where: k.node_id in ^adapters, select: k.key_id)

      Repo.delete_all(
        from p in PublicKey,
          where: p.key_id in ^[place.key.key_id, gateway_key.key_id | adapter_keys]
      )

      Repo.delete_all(from c in AdapterConnection, where: c.adapter_id in ^adapters)
      Repo.delete_all(from k in AccessKey, where: k.node_id in ^adapters)
      Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^adapters)
      Repo.delete_all(from n in Node, where: n.id in ^adapters)

      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "litellm",
        settings: %{"address" => @old_address},
        keys: [%{value_id: "main", value: "sk-team-races"}]
      })

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        model: "team-large"
      })

    Map.merge(place, %{scope: scope, made: made, provider: provider})
  end

  # A run of the queue of a fresh work item, waiting: committed.
  defp queued!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    Agent.update(ctx.made, &[work_item.adapter_id | &1])
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
  end

  # The claim that takes the run, which registers it: `{:ok, documents}`, what the run's
  # documents are made from with the registered run as `run`; or the claim's answer.
  defp claim(ctx) do
    fn ->
      case Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body) do
        {:ok, %{registered: run, documents: documents}} -> {:ok, Map.put(documents, :run, run)}
        other -> other
      end
    end
  end

  defp change_address(ctx),
    do: fn ->
      Connections.update_provider(ctx.scope, ctx.provider, %{
        settings: %{"address" => @new_address}
      })
    end

  # The choice and then the provider, in one transaction: the provider's deletion is
  # refused while a choice names it. A refused deletion rolls the choice's back too.
  defp delete_provider(ctx) do
    fn ->
      Repo.transact(fn ->
        {:ok, _choice} = ModelChoices.delete_choice(ctx.scope, :workspace)
        Connections.delete_provider(ctx.scope, ctx.provider)
      end)
    end
  end

  defp run!(%{run: %Run{id: id}}), do: Repo.get!(Run, id)

  defp provider_there?(ctx),
    do: Repo.exists?(from c in Connection, where: c.id == ^ctx.provider.id)

  describe "a claim and a change of the provider's address" do
    test "the claim first: the change waits, and the run keeps the address before", ctx do
      queued!(ctx)
      {first, first_pid} = hold(claim(ctx))
      assert {:ok, handed} = first.result

      second = start(change_address(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Connection{}} = Task.await(second.task)
      assert %Run{provider_api: %{"endpoint" => @old_address}} = run!(handed)
    end

    test "the change first: the claim waits, and the run takes the address after", ctx do
      queued!(ctx)
      {first, first_pid} = hold(change_address(ctx))
      assert {:ok, %Connection{}} = first.result

      second = start(claim(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, handed} = Task.await(second.task)
      assert %Run{provider_api: %{"endpoint" => @new_address}} = run!(handed)
    end
  end

  describe "a claim and the provider's deletion" do
    test "the claim first: the deletion waits, then is refused for the run it registered",
         ctx do
      queued!(ctx)
      {first, first_pid} = hold(claim(ctx))
      assert {:ok, handed} = first.result

      second = start(delete_provider(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      run = run!(handed)

      assert Task.await(second.task) ==
               {:error, {:provider_in_use, %{places: [], runs: [run.public_id]}}}

      assert provider_there?(ctx)

      assert %Run{
               provider_connection_id: provider_id,
               provider_api: %{"endpoint" => @old_address},
               run_settings: %{"model" => "team-large"}
             } = run

      assert provider_id == ctx.provider.id
    end

    test "the deletion first: the claim waits, then finds no choice", ctx do
      # The run with no model providers, as the choice's removal sets them: the removal
      # then leaves the run's row as it is, so the claim takes the run and waits on the
      # provider's row, which this test is about. A removal that writes the row holds
      # it, and the claim passes the run by until the removal commits.
      {:ok, queued} = queued!(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Apiary.Dispatches.DispatchRun, where: r.id == ^queued.id),
          set: [model_provider_ids: []]
        )

      {first, first_pid} = hold(delete_provider(ctx))
      assert {:ok, %Connection{}} = first.result

      second = start(claim(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, handed} = Task.await(second.task)
      assert Jason.encode!(handed.run_settings) == ~s({"runtime":"#{@runtime}"})

      assert %Run{provider_connection_id: nil, provider_api: nil, run_settings: settings} =
               run!(handed)

      assert settings == %{"runtime" => @runtime}
    end
  end

  describe "two writes of a waiting run's model providers" do
    @describetag needs: [:factory, :secrets]

    test "the write that waits for the run's row reads the choice after the change", ctx do
      {:ok, queued} = queued!(ctx)

      {:ok, other} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          name: "Spare keys",
          keys: [%{value_id: "main", value: "sk-ant-races-spare-0123456789"}]
        })

      # The run with no model providers, so that the write below has a change to write.
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
          set: [model_provider_ids: []]
        )

      lock = fn ->
        Repo.one!(from r in DispatchRun, where: r.id == ^queued.id, lock: "FOR UPDATE")
      end

      # The run's row is held while the write starts; the choice changes to the other
      # provider, under that hold, once the write waits for the row.
      {held, holder} = hold(lock)

      write =
        start(fn -> Dispatches.refresh_model_providers({:workspace, queued.workspace_id}) end)

      await_blocked(write.backend, holder)

      assert {:ok, _choice} =
               continue(held, fn ->
                 ModelChoices.put_choice(ctx.scope, :workspace, %{provider: other.public_id})
               end)

      commit(held)

      assert Task.await(write.task) == :ok
      assert Repo.get!(DispatchRun, queued.id).model_provider_ids == [other.id]
    end
  end
end
