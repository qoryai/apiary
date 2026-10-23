defmodule Apiary.Dispatches.SchemaTest do
  # The tables of the queue and its claims (`Apiary.Dispatches.DispatchRun`,
  # `Apiary.Dispatches.Dispatch`), as the migration made them: their checks, their unique
  # and partial indexes, the `dp_` id, the purge of a workspace and of an organisation,
  # and the migration run down and up again inside the test's transaction. The checks are
  # asked in raw SQL, so that no changeset stands between the write and the database. Not
  # async: the migration test changes the tables under every other test.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Deletion, PublicId}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @format ~r/\Adp_[0-9a-hjkmnp-tv-z]{16}\z/

  @version 20_261_017_142_000
  @migration Apiary.Repo.Migrations.KeepDispatches
  # The later migration that names a run's work item by the organisation: down first, up
  # last.
  @again_version 20_261_017_144_000
  @again Apiary.Repo.Migrations.TakeWorkItemsInAgain
  # The later migration that queues prebuilds: down first, up last.
  @prebuilds_version 20_261_017_160_000
  @prebuilds Apiary.Repo.Migrations.QueuePrebuilds
  # The later migration that keeps a dispatch's machine log, whose table has a key to the
  # dispatches: down first, up last.
  @machine_log_version 20_261_022_160_000
  @machine_log Apiary.Repo.Migrations.KeepADispatchSMachineLog
  # The later migration that holds runs for their environment build, whose index replaces
  # the prebuilds': down first, and left down, as the migrations between it and the
  # prebuilds' that it changes do not run again.
  @hold_version 20_261_023_090_000
  @hold Apiary.Repo.Migrations.HoldRunsForTheirEnvironmentBuild

  setup_all do
    for {version, migration, name} <- [
          {@version, @migration, "keep_dispatches"},
          {@again_version, @again, "take_work_items_in_again"},
          {@prebuilds_version, @prebuilds, "queue_prebuilds"},
          {@machine_log_version, @machine_log, "keep_a_dispatch_s_machine_log"},
          {@hold_version, @hold, "hold_runs_for_their_environment_build"}
        ],
        not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  ## Helpers

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  # Sets `assignments` on the row `id` of `table`, with `params` after the id: $2 onwards.
  defp update!(table, id, assignments, params \\ []) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  defp queue(%Scope{workspace: workspace} = scope, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new_lazy(:work_item_id, fn -> work_item_fixture(scope).id end)
      |> Enum.into(%{step: "explore", take_in: 1, attempt: 1, of: 3, queued_at: now()})

    %DispatchRun{organisation_id: workspace.organisation_id, workspace_id: workspace.id}
    |> DispatchRun.queue_changeset(attrs)
    |> Repo.insert()
  end

  defp queued!(scope, attrs \\ %{}) do
    {:ok, run} = queue(scope, attrs)
    run
  end

  # A pool of the scope's workspace and a key of it.
  defp pool!(scope) do
    pool = pool_fixture(scope)
    %{access_key: key} = access_key_fixture(scope, node: pool)
    %{pool: pool, key: key}
  end

  defp claim(
         %Scope{workspace: workspace},
         %DispatchRun{} = run,
         %{pool: pool, key: key},
         attrs \\ %{}
       ) do
    claimed_at = now()

    attrs =
      Enum.into(attrs, %{
        dispatch_run_id: run.id,
        pool_id: pool.id,
        access_key_id: key.id,
        claimed_at: claimed_at,
        lease_until: lease(claimed_at)
      })

    %Dispatch{organisation_id: workspace.organisation_id, workspace_id: workspace.id}
    |> Dispatch.claim_changeset(attrs)
    |> Repo.insert()
  end

  defp claimed!(scope, run, pool, attrs \\ %{}) do
    {:ok, dispatch} = claim(scope, run, pool, attrs)
    dispatch
  end

  defp now, do: DateTime.utc_now()

  # Ten minutes from the claim, in whole seconds, as the contract gives it.
  defp lease(claimed_at),
    do: claimed_at |> DateTime.truncate(:second) |> DateTime.add(600, :second)

  ## dispatch_runs

  describe "a run of the queue" do
    test "is queued waiting, with a fresh run id, unique on the instance", %{scope: scope} do
      one = queued!(scope)
      other = queued!(scope, take_in: 2)

      assert %DispatchRun{state: :waiting, end_cause: nil, step: "explore"} =
               Repo.get!(DispatchRun, one.id)

      assert {:ok, _} = Ecto.UUID.cast(one.run_id)
      assert one.run_id != other.run_id

      %{scope: elsewhere} = sign_up_fixture()
      there = queued!(elsewhere)

      refused("dispatch_runs_run_id_index", fn ->
        update!("dispatch_runs", there.id, "run_id = $2", [Ecto.UUID.dump!(one.run_id)])
      end)
    end

    test "is one per work item, take in and attempt", %{scope: scope} do
      first = queued!(scope)

      assert {:error, changeset} = queue(scope, work_item_id: first.work_item_id)
      assert {"has already been taken", _} = changeset.errors[:attempt]

      assert %DispatchRun{} = queued!(scope, work_item_id: first.work_item_id, attempt: 2)
      assert %DispatchRun{} = queued!(scope, work_item_id: first.work_item_id, take_in: 2)
    end

    test "the changeset holds the bounds the database holds", %{scope: scope} do
      for {attrs, field} <- [
            {%{step: "Explore"}, :step},
            {%{step: "explore2"}, :step},
            {%{step: String.duplicate("a", 41)}, :step},
            {%{take_in: 0}, :take_in},
            {%{attempt: 0}, :attempt},
            {%{attempt: 4, of: 3}, :attempt},
            {%{of: 0}, :of},
            {%{queued_at: nil}, :queued_at}
          ] do
        assert {:error, changeset} = queue(scope, attrs)
        assert Keyword.has_key?(changeset.errors, field), inspect({attrs, changeset.errors})
      end
    end

    test "the database refuses a step outside the contract's pattern", %{scope: scope} do
      run = queued!(scope)

      for step <- ["explore_more", "a", String.duplicate("a", 40)],
          do: assert(%{num_rows: 1} = update!("dispatch_runs", run.id, "step = $2", [step]))

      for step <- ["", "Explore", "_explore", "explore2", "ex-plore", String.duplicate("a", 41)] do
        refused("dispatch_runs_step_check", fn ->
          update!("dispatch_runs", run.id, "step = $2", [step])
        end)
      end
    end

    test "the database holds 1 <= attempt <= of, and a take in from 1", %{scope: scope} do
      run = queued!(scope)

      assert %{num_rows: 1} = update!("dispatch_runs", run.id, "attempt = 3, of = 3")

      refused("dispatch_runs_take_in_check", fn ->
        update!("dispatch_runs", run.id, "take_in = 0")
      end)

      for assignments <- ["attempt = 0", "attempt = 4, of = 3", "attempt = 1, of = 0"] do
        refused("dispatch_runs_attempt_check", fn ->
          update!("dispatch_runs", run.id, assignments)
        end)
      end
    end

    test "the database takes the four states, and an end cause with the end alone",
         %{scope: scope} do
      run = queued!(scope)

      for state <- ~w(claimed handed_over waiting) do
        assert %{num_rows: 1} = update!("dispatch_runs", run.id, "state = $2", [state])
      end

      # A cause its handover gives, and `build_failed`, come with the outcome error
      # (`result_outcome`).
      for cause <- DispatchRun.end_causes() do
        assert %{num_rows: 1} =
                 update!(
                   "dispatch_runs",
                   run.id,
                   "state = 'ended', end_cause = $2, result_outcome = CASE WHEN $2 IN " <>
                     "('variables_invalid', 'ticket_gone', 'inputs_invalid', 'provider_gone', " <>
                     "'runtime_unserved', 'key_gone', 'model_gone', 'secrets_not_allowed', " <>
                     "'build_failed') " <>
                     "THEN 'error' END",
                   [Atom.to_string(cause)]
                 )

        assert %DispatchRun{state: :ended, end_cause: ^cause} = Repo.get!(DispatchRun, run.id)
      end

      # Back to a cause without an outcome, so each refusal below is its check's alone.
      assert %{num_rows: 1} =
               update!("dispatch_runs", run.id, "end_cause = 'released', result_outcome = NULL")

      refused("dispatch_runs_state_check", fn ->
        update!("dispatch_runs", run.id, "state = 'paused', end_cause = NULL")
      end)

      refused("dispatch_runs_end_cause_check", fn ->
        update!("dispatch_runs", run.id, "end_cause = 'gone'")
      end)

      refused("dispatch_runs_ended_check", fn ->
        update!("dispatch_runs", run.id, "state = 'ended', end_cause = NULL")
      end)

      refused("dispatch_runs_ended_check", fn ->
        update!("dispatch_runs", run.id, "state = 'claimed', end_cause = 'released'")
      end)
    end

    test "has an outcome only once ended run_ended or by its handover, an error for the latter",
         %{scope: scope} do
      run = queued!(scope)

      # Waiting, or ended for any cause but run_ended and the handover's, it has none.
      refused("dispatch_runs_result_outcome_check", fn ->
        update!("dispatch_runs", run.id, "result_outcome = 'none'")
      end)

      for cause <- ~w(released closed undone lost collection_ended superseded prebuilt) do
        refused("dispatch_runs_result_outcome_check", fn ->
          update!(
            "dispatch_runs",
            run.id,
            "state = 'ended', end_cause = $2, result_outcome = 'none'",
            [cause]
          )
        end)
      end

      # Ended run_ended: none until it is settled, then any of the five.
      assert %{num_rows: 1} =
               update!("dispatch_runs", run.id, "state = 'ended', end_cause = 'run_ended'")

      for outcome <- ~w(proposal questions error none refused) do
        assert %{num_rows: 1} =
                 update!("dispatch_runs", run.id, "result_outcome = $2", [outcome])

        assert %DispatchRun{result_outcome: kept} = Repo.get!(DispatchRun, run.id)
        assert Atom.to_string(kept) == outcome
      end

      refused("dispatch_runs_result_outcome_check", fn ->
        update!("dispatch_runs", run.id, "result_outcome = 'maybe'")
      end)

      # Ended by its handover: always error.
      for cause <- ~w(variables_invalid ticket_gone inputs_invalid) do
        for outcome <- [nil, "none", "proposal"] do
          refused("dispatch_runs_result_outcome_error_check", fn ->
            update!("dispatch_runs", run.id, "end_cause = $2, result_outcome = $3", [
              cause,
              outcome
            ])
          end)
        end

        assert %{num_rows: 1} =
                 update!("dispatch_runs", run.id, "end_cause = $2, result_outcome = 'error'", [
                   cause
                 ])
      end
    end

    test "keeps a result, a JSON object of at most 1 MiB, with a proposal or questions alone",
         %{scope: scope} do
      run = queued!(scope)

      assert %{num_rows: 1} =
               update!(
                 "dispatch_runs",
                 run.id,
                 "state = 'ended', end_cause = 'run_ended', result_outcome = 'proposal', " <>
                   "result = $2",
                 [%{"verdict" => "understood"}]
               )

      assert %DispatchRun{result: %{"verdict" => "understood"}} = Repo.get!(DispatchRun, run.id)

      assert %{num_rows: 1} =
               update!("dispatch_runs", run.id, "result_outcome = 'questions'")

      # Cleared, the outcome stays.
      assert %{num_rows: 1} = update!("dispatch_runs", run.id, "result = NULL")

      assert %DispatchRun{result_outcome: :questions, result: nil} =
               Repo.get!(DispatchRun, run.id)

      for outcome <- [nil, "error", "none", "refused"] do
        refused("dispatch_runs_result_kept_check", fn ->
          update!("dispatch_runs", run.id, "result_outcome = $2, result = '{}'", [outcome])
        end)
      end

      for result <- [[], "text", 1] do
        refused("dispatch_runs_result_check", fn ->
          update!("dispatch_runs", run.id, "result_outcome = 'proposal', result = $2", [result])
        end)
      end

      # 1 MiB as the database encodes it: `{"a": "…"}` is 9 bytes and the text.
      for {bytes, fun} <- [
            {1_048_576 - 9, &assert(%{num_rows: 1} = &1.())},
            {1_048_576 - 8, &refused("dispatch_runs_result_check", &1)}
          ] do
        fun.(fn ->
          update!("dispatch_runs", run.id, "result_outcome = 'proposal', result = $2", [
            %{"a" => String.duplicate("a", bytes)}
          ])
        end)
      end
    end

    @tag needs: :factory
    test "a prebuild has no outcome, whatever its end", %{scope: scope} do
      %{pool: pool} = pool!(scope)
      collection = collection_fixture(scope)

      {:ok, run} =
        %DispatchRun{organisation_id: scope.organisation.id, workspace_id: scope.workspace.id}
        |> DispatchRun.prebuild_changeset(%{
          source_collection_id: collection.id,
          pool_id: pool.id,
          environment_ref: "env-1",
          queued_at: now()
        })
        |> Repo.insert()

      for cause <- ~w(run_ended variables_invalid inputs_invalid) do
        assert %{num_rows: 1} =
                 update!("dispatch_runs", run.id, "state = 'ended', end_cause = $2", [cause])

        refused("dispatch_runs_result_outcome_check", fn ->
          update!("dispatch_runs", run.id, "result_outcome = 'error'")
        end)
      end
    end

    test "settles through a partial index of the runs ended run_ended with no outcome yet" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'dispatch_runs_unsettled_index'"
        )

      assert definition =~ "(id)"
      assert definition =~ "end_cause = 'run_ended'::text"
      assert definition =~ "result_outcome IS NULL"
      assert definition =~ "step <> 'prebuild'::text"
    end

    test "names a work item of its organisation alone", %{scope: scope} do
      %{scope: elsewhere} = sign_up_fixture()
      theirs = work_item_fixture(elsewhere)

      assert {:error, changeset} = queue(scope, work_item_id: theirs.id)
      assert {"does not exist", _} = changeset.errors[:work_item_id]

      # By the organisation, so that it stays where it was queued when its work item moves
      # to another workspace; MATCH SIMPLE, so that a prebuild names none.
      assert %{rows: [[definition]]} =
               Repo.query!(
                 "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
                   "WHERE conname = 'dispatch_runs_work_item_id_fkey'"
               )

      assert definition ==
               "FOREIGN KEY (work_item_id, organisation_id) " <>
                 "REFERENCES work_items(id, organisation_id) ON DELETE CASCADE"
    end

    @tag needs: :factory
    test "a prebuild: no work item nor take in, a collection and a pool of its workspace",
         %{scope: scope} do
      %{pool: pool} = pool!(scope)
      collection = collection_fixture(scope)

      prebuild = fn attrs ->
        %DispatchRun{organisation_id: scope.organisation.id, workspace_id: scope.workspace.id}
        |> DispatchRun.prebuild_changeset(
          Enum.into(attrs, %{
            source_collection_id: collection.id,
            pool_id: pool.id,
            environment_ref: "env-1",
            queued_at: now()
          })
        )
        |> Repo.insert()
      end

      assert {:ok, run} = prebuild.(%{})
      assert %DispatchRun{step: "prebuild", work_item_id: nil, take_in: nil} = run

      for {attrs, field} <- [
            {%{environment_ref: ""}, :environment_ref},
            {%{environment_ref: String.duplicate("é", 201)}, :environment_ref},
            {%{source_collection_id: nil}, :source_collection_id},
            {%{pool_id: nil}, :pool_id}
          ] do
        assert {:error, changeset} = prebuild.(attrs)
        assert Keyword.has_key?(changeset.errors, field), inspect({attrs, changeset.errors})
      end

      # A pool of another workspace, and a collection of another organisation.
      elsewhere = workspace_fixture(scope.organisation)
      %{pool: theirs} = pool!(%{scope | workspace: elsewhere})
      assert {:error, changeset} = prebuild.(%{pool_id: theirs.id})
      assert {"does not exist", _} = changeset.errors[:pool_id]

      %{scope: other} = sign_up_fixture()

      assert {:error, changeset} =
               prebuild.(%{source_collection_id: collection_fixture(other).id})

      assert {"does not exist", _} = changeset.errors[:source_collection_id]

      # The database holds the shape of each step.
      explore = queued!(scope)
      work_item_id = Ecto.UUID.dump!(explore.work_item_id)

      for {id, assignments, params} <- [
            {run.id, "work_item_id = $2, take_in = 1, attempt = 1, of = 3", [work_item_id]},
            {run.id, "take_in = 1", []},
            {run.id, "environment_ref = NULL, environment_ref_at = NULL", []},
            {run.id, "environment_ref = ''", []},
            {run.id, "source_collection_id = NULL", []},
            {run.id, "pool_id = NULL", []},
            {run.id, "step = 'explore'", []},
            {explore.id, "pool_id = $2", [Ecto.UUID.dump!(pool.id)]},
            {explore.id, "environment_ref = 'env-1', environment_ref_at = now()", []},
            {explore.id, "step = 'prebuild'", []}
          ] do
        refused("dispatch_runs_step_shape_check", fn ->
          update!("dispatch_runs", id, assignments, params)
        end)
      end

      # A prebuild has when it took its environment_ref, and a run without one has none.
      assert run.environment_ref_at == run.queued_at

      for {id, assignments} <- [
            {run.id, "environment_ref_at = NULL"},
            {explore.id, "environment_ref_at = now()"}
          ] do
        refused("dispatch_runs_environment_ref_at_check", fn ->
          update!("dispatch_runs", id, assignments, [])
        end)
      end
    end

    test "stays in its workspace when its work item moves to another", %{scope: scope} do
      run = queued!(scope)
      claimed!(scope, run, pool!(scope))
      elsewhere = workspace_fixture(scope.organisation)

      move!(run.work_item_id, elsewhere)

      assert %WorkItem{workspace_id: moved_to} = Repo.get!(WorkItem, run.work_item_id)
      assert moved_to == elsewhere.id
      assert %DispatchRun{workspace_id: stayed} = Repo.get!(DispatchRun, run.id)
      assert stayed == scope.workspace.id

      # Its events follow it (ON UPDATE CASCADE).
      assert [%WorkItemEvent{workspace_id: ^moved_to}] =
               Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^run.work_item_id)
    end

    test "waits in its workspace's queue, which a partial index keeps" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'dispatch_runs_waiting_index'"
        )

      assert definition =~ "(workspace_id, queued_at)"
      assert definition =~ "WHERE (state = 'waiting'::text)"
    end
  end

  ## dispatches

  describe "a dispatch" do
    test "is minted dp_, unique, and named by it in a path", %{scope: scope} do
      pool = pool!(scope)
      dispatch = claimed!(scope, queued!(scope), pool)

      assert dispatch.public_id =~ @format
      assert Dispatch.public_id?(dispatch.public_id)
      assert Phoenix.Param.to_param(dispatch) == dispatch.public_id
      assert Repo.get!(Dispatch, dispatch.id).public_id == dispatch.public_id

      ids = for _ <- 1..50, do: Dispatch.new_public_id()
      for id <- ids, do: assert(id =~ @format and PublicId.valid?("dp", id))
      assert ids |> Enum.uniq() |> length() == 50

      for bad <- [
            nil,
            "",
            "dp_",
            "dp_000000000000000",
            "dp_000000000000000u",
            "DP_0000000000000000",
            "rn_0000000000000000",
            Ecto.UUID.generate()
          ],
          do: refute(Dispatch.public_id?(bad))

      other = claimed!(scope, queued!(scope), pool)

      refused("dispatches_public_id_index", fn ->
        update!("dispatches", other.id, "public_id = $2", [dispatch.public_id])
      end)

      for bad <-
            ~w(dp_000000000000000 dp_000000000000000u rn_0000000000000000 dp_0000000000000000x) do
        refused("dispatches_public_id_format", fn ->
          update!("dispatches", other.id, "public_id = $2", [bad])
        end)
      end
    end

    test "a row written without an id gets dispatch_public_id(), of the same shape",
         %{scope: scope} do
      %{pool: pool, key: key} = pool!(scope)
      run = queued!(scope)
      id = Ecto.UUID.generate()

      Repo.query!(
        "INSERT INTO dispatches (id, organisation_id, workspace_id, dispatch_run_id, pool_id, " <>
          "access_key_id, claimed_at, lease_until, inserted_at, updated_at) " <>
          "VALUES ($1, $2, $3, $4, $5, $6, now(), date_trunc('second', now()) + interval '600 seconds', " <>
          "now(), now())",
        Enum.map(
          [id, scope.organisation.id, scope.workspace.id, run.id, pool.id, key.id],
          &Ecto.UUID.dump!/1
        )
      )

      assert Repo.get!(Dispatch, id).public_id =~ @format

      %{rows: rows} = Repo.query!("SELECT dispatch_public_id() FROM generate_series(1, 50)")
      ids = List.flatten(rows)
      for id <- ids, do: assert(id =~ @format)
      assert ids |> Enum.uniq() |> length() == 50
    end

    test "has one lease, after the claim and in whole seconds", %{scope: scope} do
      pool = pool!(scope)
      run = queued!(scope)
      claimed_at = %{now() | microsecond: {123_456, 6}}

      for lease_until <- [
            DateTime.truncate(claimed_at, :second),
            DateTime.add(claimed_at, 600, :second)
          ] do
        assert {:error, changeset} =
                 claim(scope, run, pool, claimed_at: claimed_at, lease_until: lease_until)

        assert {"is invalid", _} = changeset.errors[:lease_until]
      end

      dispatch = claimed!(scope, run, pool)
      assert DateTime.diff(dispatch.lease_until, dispatch.claimed_at, :second) in 599..600

      for assignments <- [
            "lease_until = claimed_at",
            "lease_until = claimed_at - interval '1 second'",
            "lease_until = lease_until + interval '1 millisecond'"
          ] do
        refused("dispatches_lease_check", fn ->
          update!("dispatches", dispatch.id, assignments)
        end)
      end
    end

    test "names the job at its system as external, set together and once dispatched",
         %{scope: scope} do
      dispatch = claimed!(scope, queued!(scope), pool!(scope))
      external = "external_type = $2, external_ref = $3, external_url = $4"
      job = ["example-ci", "run 4211", "https://ci.example.com/jobs/4211"]

      refused("dispatches_external_check", fn ->
        update!("dispatches", dispatch.id, external, job)
      end)

      assert %{num_rows: 1} = update!("dispatches", dispatch.id, "dispatched_at = now()")
      assert %{num_rows: 1} = update!("dispatches", dispatch.id, external, job)

      for type <- ["a", "example ci", "ci-2", String.duplicate("a", 40)],
          do:
            assert(
              %{num_rows: 1} = update!("dispatches", dispatch.id, "external_type = $2", [type])
            )

      for type <- ["", "Example", "2ci", "-ci", "ci_2", "ci.example", String.duplicate("a", 41)] do
        refused("dispatches_external_type_check", fn ->
          update!("dispatches", dispatch.id, "external_type = $2", [type])
        end)
      end

      assert %{num_rows: 1} =
               update!("dispatches", dispatch.id, "external_ref = $2", [
                 String.duplicate("r", 200)
               ])

      for ref <- ["", String.duplicate("r", 201)] do
        refused("dispatches_external_ref_check", fn ->
          update!("dispatches", dispatch.id, "external_ref = $2", [ref])
        end)
      end

      for url <- [
            "http://ci.example.com/jobs/1",
            "https://",
            "https://ci.example.com/jobs 1",
            "https://ci.example.com/" <> String.duplicate("a", 2048 - 23 + 1)
          ] do
        refused("dispatches_external_url_check", fn ->
          update!("dispatches", dispatch.id, "external_url = $2", [url])
        end)
      end

      for column <- ~w(external_type external_ref external_url) do
        refused("dispatches_external_check", fn ->
          update!("dispatches", dispatch.id, "#{column} = NULL")
        end)
      end
    end

    test "is handed over before its lease, dispatched or not, and never once stale",
         %{scope: scope} do
      dispatch = claimed!(scope, queued!(scope), pool!(scope))

      # The first redemption of the run's code hands a dispatch over before its
      # `dispatched`.
      assert %{num_rows: 1} = update!("dispatches", dispatch.id, "handed_over_at = claimed_at")
      assert %{num_rows: 1} = update!("dispatches", dispatch.id, "handed_over_at = NULL")
      assert %{num_rows: 1} = update!("dispatches", dispatch.id, "dispatched_at = claimed_at")

      refused("dispatches_handed_over_check", fn ->
        update!("dispatches", dispatch.id, "handed_over_at = lease_until")
      end)

      assert %{num_rows: 1} =
               update!(
                 "dispatches",
                 dispatch.id,
                 "handed_over_at = lease_until - interval '1 microsecond'"
               )

      refused("dispatches_handed_over_check", fn ->
        update!("dispatches", dispatch.id, "stale_at = lease_until")
      end)
    end

    test "is stale at or after its lease", %{scope: scope} do
      dispatch = claimed!(scope, queued!(scope), pool!(scope))

      refused("dispatches_stale_check", fn ->
        update!("dispatches", dispatch.id, "stale_at = lease_until - interval '1 microsecond'")
      end)

      assert %{num_rows: 1} = update!("dispatches", dispatch.id, "stale_at = lease_until")
    end

    test "ends with a cause of the list, and only then has one", %{scope: scope} do
      dispatch = claimed!(scope, queued!(scope), pool!(scope))

      for cause <- DispatchRun.end_causes() do
        assert %{num_rows: 1} =
                 update!("dispatches", dispatch.id, "ended_at = now(), end_cause = $2", [
                   Atom.to_string(cause)
                 ])

        assert %Dispatch{end_cause: ^cause} = Repo.get!(Dispatch, dispatch.id)
      end

      refused("dispatches_end_cause_check", fn ->
        update!("dispatches", dispatch.id, "end_cause = 'gone'")
      end)

      refused("dispatches_ended_check", fn ->
        update!("dispatches", dispatch.id, "end_cause = NULL")
      end)

      refused("dispatches_ended_check", fn ->
        update!("dispatches", dispatch.id, "ended_at = NULL")
      end)
    end

    test "one of a run is live and not stale at a time", %{scope: scope} do
      pool = pool!(scope)
      run = queued!(scope)
      first = claimed!(scope, run, pool)

      assert {:error, changeset} = claim(scope, run, pool)
      assert {"has already been taken", _} = changeset.errors[:dispatch_run_id]

      # Stale, the run may be claimed again; that one ended, again.
      assert %{num_rows: 1} = update!("dispatches", first.id, "stale_at = lease_until")
      second = claimed!(scope, run, pool)

      assert %{num_rows: 1} =
               update!("dispatches", second.id, "ended_at = now(), end_cause = 'released'")

      third = claimed!(scope, run, pool)
      assert length(Enum.uniq([first.public_id, second.public_id, third.public_id])) == 3

      # A stale one made live again would be a second live dispatch of the run.
      refused("dispatches_live_index", fn ->
        update!("dispatches", first.id, "stale_at = NULL")
      end)

      %{rows: [[definition]]} =
        Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = 'dispatches_live_index'")

      assert definition =~ "UNIQUE INDEX"
      assert definition =~ "(dispatch_run_id) WHERE ((ended_at IS NULL) AND (stale_at IS NULL))"
    end

    test "counts against its pool while its slot is held, a partial index", %{scope: scope} do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'dispatches_slot_held_index'"
        )

      assert definition =~ "(pool_id) WHERE (slot_freed_at IS NULL)"

      dispatch = claimed!(scope, queued!(scope), pool!(scope))
      assert %{num_rows: 1} = update!("dispatches", dispatch.id, "slot_freed_at = now()")
      assert %Dispatch{slot_freed_at: %DateTime{}} = Repo.get!(Dispatch, dispatch.id)
    end

    test "names a pool and a run of its workspace, and holds them", %{scope: scope} do
      %{scope: elsewhere} = sign_up_fixture()
      theirs = pool!(elsewhere)
      their_run = queued!(elsewhere)
      run = queued!(scope)
      pool = pool!(scope)

      assert {:error, changeset} = claim(scope, run, theirs)
      assert {"does not exist", _} = changeset.errors[:pool_id]

      assert {:error, changeset} = claim(scope, their_run, pool)
      assert {"does not exist", _} = changeset.errors[:dispatch_run_id]

      # A node and a key are deleted softly; while a dispatch names them, nothing may. The
      # pool here has no key, so that the dispatch alone holds it.
      bare = pool_fixture(scope)
      claimed!(scope, run, %{pool | pool: bare})

      refused("dispatches_pool_id_fkey", fn ->
        Repo.query!("DELETE FROM nodes WHERE id = $1", [Ecto.UUID.dump!(bare.id)])
      end)

      refused("dispatches_access_key_id_fkey", fn ->
        Repo.query!("DELETE FROM access_keys WHERE id = $1", [Ecto.UUID.dump!(pool.key.id)])
      end)
    end
  end

  ## runs.dispatch_run_id

  describe "a run registered for a run of the queue" do
    test "names it, once, and of its workspace alone", %{scope: scope} do
      dispatch_run = queued!(scope)
      run = run_fixture(scope, %{dispatch_run_id: dispatch_run.id})

      assert %Run{dispatch_run_id: id} = Repo.get!(Run, run.id)
      assert id == dispatch_run.id
      assert %DispatchRun{run: %Run{id: run_id}} = Repo.preload(dispatch_run, :run)
      assert run_id == run.id

      assert_raise Ecto.ConstraintError, ~r/runs_dispatch_run_id_index/, fn ->
        run_fixture(scope, %{dispatch_run_id: dispatch_run.id})
      end

      assert %Run{dispatch_run_id: nil} = Repo.get!(Run, run_fixture(scope).id)

      %{scope: elsewhere} = sign_up_fixture()

      assert_raise Ecto.ConstraintError, ~r/runs_dispatch_run_id_fkey/, fn ->
        run_fixture(elsewhere, %{dispatch_run_id: queued!(scope).id})
      end
    end
  end

  ## The purge

  # A run of the queue, a dispatch of it with its pool and key, and a run registered for it.
  defp fill!(scope) do
    dispatch_run = queued!(scope)
    claimed!(scope, dispatch_run, pool!(scope))
    run_fixture(scope, %{dispatch_run_id: dispatch_run.id})
    :ok
  end

  # Closes the work item `id` and moves it to `workspace`, with a number no fixture takes,
  # as a take in again from another workspace moves one that is not live.
  defp move!(id, %Workspace{id: workspace_id}) do
    assert %{num_rows: 1} =
             update!(
               "work_items",
               id,
               "state = 'closed', closed_at = now(), number = 1000, workspace_id = $2",
               [Ecto.UUID.dump!(workspace_id)]
             )
  end

  defp purge!(%Scope{} = scope, %Workspace{} = workspace) do
    {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)

    Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
      set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    assert {:ok, :purged} =
             Deletion.purge_workspace(Scope.for_instance(scope.organisation, workspace))
  end

  # A work item of `from` with a run of the queue, a dispatch and a registered run there,
  # then moved to `to`.
  defp moved!(scope, from, to) do
    inside = workspace_scope(scope.user, from)
    dispatch_run = queued!(inside)
    claimed!(inside, dispatch_run, pool!(inside))
    run = run_fixture(inside, %{dispatch_run_id: dispatch_run.id})
    move!(dispatch_run.work_item_id, to)
    %{work_item_id: dispatch_run.work_item_id, run: run}
  end

  defp work_item_rows(id) do
    for table <- ~w(work_items work_item_events dispatch_runs) do
      column = if table == "work_items", do: "id", else: "work_item_id"
      count(table, column, id)
    end
  end

  defp count(table, column, id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM #{table} WHERE #{column} = $1", [Ecto.UUID.dump!(id)])

    n
  end

  defp counts(column, id),
    do: for(t <- ~w(dispatches dispatch_runs runs), do: count(t, column, id))

  describe "the purge" do
    test "of a workspace removes its runs of the queue and its dispatches, and no other's",
         %{scope: scope} do
      workspace = workspace_fixture(scope.organisation)
      inside = workspace_scope(scope.user, workspace)
      fill!(inside)
      fill!(scope)

      assert counts("workspace_id", workspace.id) == [1, 1, 1]
      kept = counts("workspace_id", scope.workspace.id)

      {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)

      Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Deletion.purge_workspace(Scope.for_instance(scope.organisation, workspace))

      assert counts("workspace_id", workspace.id) == [0, 0, 0]
      assert counts("workspace_id", scope.workspace.id) == kept
    end

    test "of a moved work item's old workspace, then its new one, removes it all",
         %{scope: scope} do
      from = workspace_fixture(scope.organisation)
      to = workspace_fixture(scope.organisation)
      %{work_item_id: id} = moved!(scope, from, to)

      assert counts("workspace_id", from.id) == [1, 1, 1]
      assert work_item_rows(id) == [1, 1, 1]

      # The old workspace's runs of the queue go, whatever workspace their work item is in.
      purge!(scope, from)
      assert counts("workspace_id", from.id) == [0, 0, 0]
      assert work_item_rows(id) == [1, 1, 0]

      purge!(scope, to)
      assert work_item_rows(id) == [0, 0, 0]
    end

    test "of a moved work item's new workspace, then its old one, removes it all",
         %{scope: scope} do
      from = workspace_fixture(scope.organisation)
      to = workspace_fixture(scope.organisation)
      %{work_item_id: id, run: run} = moved!(scope, from, to)

      # The work item goes with its new workspace, and its run of the queue in the old one
      # with it, the dispatch with that; the registered run stays, with no link to it.
      purge!(scope, to)
      assert work_item_rows(id) == [0, 0, 0]
      assert counts("workspace_id", from.id) == [0, 0, 1]
      assert %Run{dispatch_run_id: nil} = Repo.get!(Run, run.id)

      purge!(scope, from)
      assert counts("workspace_id", from.id) == [0, 0, 0]
    end

    test "of an organisation removes them all, and no other's", %{scope: scope} do
      fill!(scope)
      %{scope: other} = sign_up_fixture()
      fill!(other)

      assert counts("organisation_id", scope.organisation.id) == [1, 1, 1]

      assert {:ok, :purged} = Deletion.purge_now(scope.organisation)

      assert counts("organisation_id", scope.organisation.id) == [0, 0, 0]
      assert counts("organisation_id", other.organisation.id) == [1, 1, 1]
    end
  end

  ## The migration

  @options [log: false, migration_lock: false]

  defp down! do
    assert :ok = Ecto.Migrator.down(Repo, @hold_version, @hold, @options)
    assert :ok = Ecto.Migrator.down(Repo, @machine_log_version, @machine_log, @options)
    assert :ok = Ecto.Migrator.down(Repo, @prebuilds_version, @prebuilds, @options)
    assert :ok = Ecto.Migrator.down(Repo, @again_version, @again, @options)
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
  end

  defp up! do
    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert :ok = Ecto.Migrator.up(Repo, @again_version, @again, @options)
    assert :ok = Ecto.Migrator.up(Repo, @prebuilds_version, @prebuilds, @options)
    assert :ok = Ecto.Migrator.up(Repo, @machine_log_version, @machine_log, @options)

    # `DispatchRun` writes `image_requeue`, of the migration left down, on every insert.
    Repo.query!(
      "ALTER TABLE dispatch_runs ADD COLUMN image_requeue boolean NOT NULL DEFAULT false"
    )
  end

  defp exists?(sql) do
    %{rows: [[count]]} = Repo.query!(sql)
    count >= 1
  end

  defp tables? do
    exists?(
      "SELECT count(*) FROM information_schema.tables " <>
        "WHERE table_name IN ('dispatch_runs', 'dispatches')"
    )
  end

  defp column? do
    exists?(
      "SELECT count(*) FROM information_schema.columns " <>
        "WHERE table_name = 'runs' AND column_name = 'dispatch_run_id'"
    )
  end

  defp function?,
    do: exists?("SELECT count(*) FROM pg_proc WHERE proname = 'dispatch_public_id'")

  describe "the migration" do
    test "down removes the tables, the run's link and the function; up brings them back",
         %{scope: scope} do
      run = run_fixture(scope)

      down!()
      refute tables?()
      refute column?()
      refute function?()

      assert %{num_rows: 1} =
               Repo.query!("SELECT 1 FROM runs WHERE id = $1", [Ecto.UUID.dump!(run.id)])

      up!()
      assert tables?()
      assert column?()
      assert function?()

      fill!(scope)
      assert counts("workspace_id", scope.workspace.id) == [1, 1, 2]
      assert %Run{dispatch_run_id: nil} = Repo.get!(Run, run.id)
    end
  end
end
