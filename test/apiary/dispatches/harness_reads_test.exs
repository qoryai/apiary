defmodule Apiary.Dispatches.HarnessReadsTest do
  # The reads a claim makes before its transaction (`Apiary.Dispatches.HarnessReads`),
  # within one session of a total time and a count of requests: a host that does not
  # answer within that time leaves the reads after it no time, and a read the session
  # leaves no request records no failure. Not async: the tests set the session's time and
  # requests (`Application.put_env/3`).
  use Apiary.DataCase, async: false

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, MachineTypes, WorkItems}
  alias Apiary.Dispatches.{DispatchRun, HarnessReads}
  alias Apiary.Harnesses.{Builtin, Qory, RunHarness}
  alias Apiary.PublicGitServer
  alias Apiary.QoryHarnessFixture

  @moduletag needs: :factory

  setup do
    Application.put_env(:apiary, HarnessReads, read_ms: 200)
    on_exit(fn -> Application.delete_env(:apiary, HarnessReads) end)

    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  # A run of a work item, queued, with no process version, as with the feature
  # `workflow_model` off: its harness is read at the claim, not taken from a version.
  defp queued!(ctx) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [process_version_id: nil]
      )

    run
  end

  test "a host that does not answer within the session's time leaves the reads after it no time, and their runs queued",
       ctx do
    qory_run = queued!(ctx)
    git = Qory.git()

    walk_resolved!(qory_run,
      origin: :setting,
      workflow: "explore-a-ticket",
      document: %{"extends" => %{"git" => git, "ref" => "main", "stack" => "software"}},
      pins: [%{"git" => git, "ref" => "main", "at" => QoryHarnessFixture.commit()}]
    )

    {:ok, work_item} = WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?")
    [builtin_run] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
    qory_path = URI.parse(git).path

    # The Qory harness's host answers after 2 seconds, 10 times the session's time.
    PublicGitServer.serve(%{},
      answer: fn conn ->
        if String.starts_with?(conn.request_path, qory_path <> "/"), do: Process.sleep(2_000)
        nil
      end
    )

    started = System.monotonic_time(:millisecond)
    reads = HarnessReads.prefetch(Dispatches.waiting_query(ctx.key), 100, Dispatches.now())
    assert System.monotonic_time(:millisecond) - started < 1_500

    assert {:error, {:unreadable, {:unreachable, 1}, _hop}} = reads[{git, {:branch, "main"}}]

    assert {:error, {:unreadable, cause, _hop}} = reads[{Builtin.git(), {:branch, "main"}}]
    assert cause == :late or match?({:unreachable, _seconds}, cause)

    # Both reads may pass later: the claim takes neither run, and records the timeout.
    assert {:ok, :none} = walked_claim(ctx.key, Dispatches.now())

    for run <- [qory_run, builtin_run] do
      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, run.id)
    end

    assert %RunHarness{read_failed_at: %DateTime{}} = walk!(qory_run)
  end

  test "a read the session left no request leaves the run queued, with no failure recorded",
       ctx do
    Application.put_env(:apiary, HarnessReads, read_requests: 1)
    run = queued!(ctx)
    git = Qory.git()

    walk_resolved!(run,
      origin: :setting,
      workflow: "explore-a-ticket",
      document: %{"extends" => %{"git" => git, "ref" => "main", "stack" => "software"}},
      pins: [%{"git" => git, "ref" => "main", "at" => QoryHarnessFixture.commit()}]
    )

    reads = HarnessReads.prefetch(Dispatches.waiting_query(ctx.key), 100, Dispatches.now())
    assert {:error, {:unreadable, :no_calls, _hop}} = reads[{git, {:branch, "main"}}]

    assert {:ok, :none} = walked_claim(ctx.key, Dispatches.now())
    assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, run.id)
    assert %RunHarness{read_failed_at: nil} = walk!(run)
  end

  test "a claim with offers reads no harness of a run that does not fit them, and takes the run that fits",
       ctx do
    # The older run, of a type larger than the offers, with a base on the Qory harness's
    # `main`, which a claim reads.
    too_large = queued!(ctx)
    git = Qory.git()

    walk_resolved!(too_large,
      origin: :setting,
      workflow: "explore-a-ticket",
      document: %{"extends" => %{"git" => git, "ref" => "main", "stack" => "software"}},
      pins: [%{"git" => git, "ref" => "main", "at" => QoryHarnessFixture.commit()}]
    )

    large = %{
      "vcpus" => 16,
      "memory_mib" => 65_536,
      "disk_gib" => 200,
      "arch" => "amd64",
      "virtualization" => false
    }

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^too_large.id),
        set: [machine_type: "large", machine_spec: large, machine_type_was_default: false]
      )

    # The newer run, of the default type, with the built-in harness, which a claim reads.
    {:ok, work_item} = WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?")
    [fits] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)

    PublicGitServer.serve(%{})
    offers = [MachineTypes.spec(MachineTypes.default_type())]

    assert {:ok, %{run: %{id: claimed_id}}} =
             Dispatches.claim(ctx.key, Dispatches.now(), "", offers)

    assert claimed_id == fits.id

    paths = git_paths()
    assert Enum.any?(paths, &String.starts_with?(&1, URI.parse(Builtin.git()).path <> "/"))
    refute Enum.any?(paths, &String.starts_with?(&1, URI.parse(git).path <> "/"))

    assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, too_large.id)
    assert %RunHarness{read_failed_at: nil} = walk!(too_large)
  end

  # The paths of the git requests the stub answered for this test (`PublicGitServer.serve/2`).
  defp git_paths do
    receive do
      {:git_request, _method, _host, path, _headers} -> [path | git_paths()]
    after
      0 -> []
    end
  end

  defp walk!(%DispatchRun{id: id}), do: Repo.get_by!(RunHarness, dispatch_run_id: id)
end
