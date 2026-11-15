defmodule Apiary.Runs.CancelConcurrencyTest do
  # A member's cancel (`Apiary.Runs.cancel/2`) beside a push and a batch of the same run,
  # on real transactions on real connections: the sandbox would run them one after the
  # other on one connection and prove nothing. What the test commits goes with its
  # organisation and its user when it ends.
  use ExUnit.Case, async: false

  @before_compile Apiary.TestSetup

  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{Artifacts, Repo, Runs}
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: [:factory, :observability]
  @moduletag :tmp_dir

  # How long the cancel is given to show it waits for the lock.
  @blocked_ms 300

  setup %{tmp_dir: tmp_dir} do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    previous = Application.fetch_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))

    on_exit(fn ->
      case previous do
        {:ok, dir} -> Application.put_env(:apiary, :artifacts_dir, dir)
        :error -> Application.delete_env(:apiary, :artifacts_dir)
      end
    end)

    %{scope: scope, user: user} = sign_up_fixture()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      # The work item's adapter, a node of the instance its person added.
      Repo.delete_all(from n in Apiary.Nodes.Node, where: n.created_by_id == ^user.id)
      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(scope, key)

    %{
      scope: scope,
      run: run,
      dispatch_run: dispatch_run,
      work_item: Repo.get!(WorkItem, dispatch_run.work_item_id)
    }
  end

  defp file(name), do: %{filename: name, content_type: "text/markdown", binary: "# A\n"}

  defp push(ctx, name),
    do:
      Artifacts.push({:run, ctx.dispatch_run}, ctx.work_item, "explainer", [file(name <> ".md")],
        name: name
      )

  # Runs `fun` in a transaction in a task, which sends the test `{:held, result}` once
  # `fun` returned, and commits on `:commit`.
  defp holding(fun) do
    test = self()

    holder =
      Task.async(fn ->
        Repo.transact(fn ->
          result = fun.()
          send(test, {:held, result})

          receive do
            :commit -> {:ok, result}
          end
        end)
      end)

    assert_receive {:held, result}, 10_000
    {holder, result}
  end

  test "a push that locks the work item commits first; the push after the cancel fails",
       ctx do
    {holder, pushed} = holding(fn -> push(ctx, "before") end)
    assert {:ok, _version} = pushed

    cancel = Task.async(fn -> Runs.cancel(ctx.scope, ctx.run) end)
    assert Task.yield(cancel, @blocked_ms) == nil

    send(holder.pid, :commit)
    assert {:ok, {:ok, _version}} = Task.await(holder)
    assert {:ok, %Run{cancel_requested_at: %DateTime{}}} = Task.await(cancel)

    # The version pushed before the cancel stays; the push after it fails.
    assert [%{versions: [_kept]}] = Artifacts.list(ctx.work_item)
    assert {:error, :run_cancelled} = push(ctx, "after")
  end

  test "a change that locks the work item, as the run's end does, commits first", ctx do
    {holder, _held} =
      holding(fn ->
        Repo.one!(from w in WorkItem, where: w.id == ^ctx.work_item.id, lock: "FOR UPDATE")
      end)

    cancel = Task.async(fn -> Runs.cancel(ctx.scope, ctx.run) end)
    assert Task.yield(cancel, @blocked_ms) == nil

    send(holder.pid, :commit)
    assert {:ok, _held} = Task.await(holder)
    assert {:ok, %Run{cancel_requested_at: %DateTime{}}} = Task.await(cancel)
  end

  test "a batch that locks the run's row commits first; the cancel waits for it", ctx do
    {holder, _held} =
      holding(fn ->
        Repo.one!(from r in Run, where: r.id == ^ctx.run.id, lock: "FOR UPDATE")
      end)

    cancel = Task.async(fn -> Runs.cancel(ctx.scope, ctx.run) end)
    assert Task.yield(cancel, @blocked_ms) == nil
    refute Run.cancel_requested?(Repo.get!(Run, ctx.run.id))

    send(holder.pid, :commit)
    assert {:ok, _held} = Task.await(holder)
    assert {:ok, %Run{cancel_requested_at: %DateTime{}}} = Task.await(cancel)
  end
end
