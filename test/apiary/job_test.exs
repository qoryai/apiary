defmodule Apiary.JobTest do
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import ExUnit.CaptureLog
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Job
  alias Apiary.LogMetadata

  # Each returns the scope it was given and the log metadata it ran under.
  defmodule WorkspaceJob do
    use Apiary.Job, queue: :default

    @impl Apiary.Job
    def perform(scope, _job), do: {:ok, %{scope: scope, metadata: LogMetadata.get()}}
  end

  defmodule OrganisationJob do
    use Apiary.Job, queue: :default, scope: :organisation

    @impl Apiary.Job
    def perform(scope, _job), do: {:ok, %{scope: scope, metadata: LogMetadata.get()}}
  end

  # Raises with a value of its arguments in the message, as a bug might.
  defmodule RaisingJob do
    use Apiary.Job, queue: :default

    @impl Apiary.Job
    def perform(_scope, %Oban.Job{args: %{"name" => name}}), do: raise("no target #{name}")
  end

  # A sweep's job in the resume shape: not enqueued again while one is incomplete.
  defmodule UniqueJob do
    use Apiary.Job,
      queue: :default,
      unique: [period: :infinity, states: :incomplete, keys: [:organisation_id, :workspace_id]]

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  defmodule UniqueOrganisationJob do
    use Apiary.Job,
      queue: :default,
      scope: :organisation,
      unique: [period: :infinity, states: :incomplete, keys: [:organisation_id]]

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  # A sweep's job in the once-per-run shape: once a day, whether or not it has completed.
  defmodule DailyJob do
    use Apiary.Job,
      queue: :default,
      unique: [
        period: :infinity,
        states: :successful,
        keys: [:organisation_id, :workspace_id, :day]
      ]

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  # Unique in ways a sweep refuses. Jobs of two workspaces with the same reason would be
  # taken for one:
  defmodule UniqueByReasonJob do
    use Apiary.Job,
      queue: :default,
      unique: [period: :infinity, states: :incomplete, keys: [:reason]]

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  # every workspace's job would be one, since the arguments are not compared:
  defmodule UniqueByWorkerJob do
    use Apiary.Job,
      queue: :default,
      unique: [period: :infinity, states: :incomplete, fields: [:worker, :queue]]

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  # a run a minute later would enqueue everything again (Oban's default period):
  defmodule UniqueForAMinuteJob do
    use Apiary.Job, queue: :default, unique: [states: :incomplete]

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  # and once completed, no later run would enqueue it again:
  defmodule UniqueForeverJob do
    use Apiary.Job,
      queue: :default,
      unique: [period: :infinity, keys: [:organisation_id, :workspace_id]]

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  defmodule QuickJob do
    use Apiary.Job, queue: :default, timeout: 60_000

    @impl Apiary.Job
    def perform(_scope, _job), do: :ok
  end

  defmodule InstanceJob do
    use Apiary.Job, queue: :default, scope: :instance

    @impl Apiary.Job
    def perform(scope, _job), do: {:ok, %{scope: scope, metadata: LogMetadata.get()}}
  end

  defp ids(%{organisation: organisation, workspace: workspace}),
    do: %{"organisation_id" => organisation.id, "workspace_id" => workspace.id}

  @none %{organisation_id: nil, workspace_id: nil, user_id: nil}

  defp lines(log, containing),
    do: log |> String.split("\n") |> Enum.filter(&String.contains?(&1, containing))

  defp error_on_args(changeset) do
    refute changeset.valid?
    assert [{message, _}] = Keyword.get_values(changeset.errors, :args)
    message
  end

  describe "a workspace's job" do
    setup do
      %{signed_up: sign_up_fixture()}
    end

    test "acts as the instance in the workspace its arguments name", %{signed_up: signed_up} do
      assert {:ok, %{scope: %Scope{} = scope}} = perform_job(WorkspaceJob, ids(signed_up))

      assert scope.organisation.id == signed_up.organisation.id
      assert scope.workspace.id == signed_up.workspace.id
      assert scope.user == nil
      assert scope.membership == nil
      assert scope.instance
      # Where its changes came from, for the audit trail: the job's worker.
      assert scope.origin == %{worker: inspect(WorkspaceJob)}
    end

    test "acts as the person who enqueued it, with their membership", %{signed_up: signed_up} do
      changeset = WorkspaceJob.for_scope(signed_up.scope, %{target: "t-1"})

      assert changeset.valid?

      assert changeset.changes.args == %{
               "organisation_id" => signed_up.organisation.id,
               "workspace_id" => signed_up.workspace.id,
               "user_id" => signed_up.user.id,
               "target" => "t-1"
             }

      {:ok, _job} = Oban.insert(changeset)

      assert_enqueued(
        worker: WorkspaceJob,
        args: %{"workspace_id" => signed_up.workspace.id, "target" => "t-1"}
      )

      assert {:ok, %{scope: scope}} = perform_job(WorkspaceJob, changeset.changes.args)
      assert scope.user.id == signed_up.user.id
      assert scope.membership.id == signed_up.membership.id
      assert scope.workspace.id == signed_up.workspace.id
    end

    test "carries the ids in the log metadata while it runs, and puts back what was there",
         %{signed_up: signed_up} do
      assert LogMetadata.get() == @none

      assert {:ok, %{metadata: metadata}} = perform_job(WorkspaceJob, ids(signed_up))

      assert metadata == %{
               organisation_id: signed_up.organisation.id,
               workspace_id: signed_up.workspace.id,
               user_id: nil
             }

      assert LogMetadata.get() == @none

      # The person whose action enqueued it, when the arguments name them.
      args = WorkspaceJob.for_scope(signed_up.scope).changes.args
      assert {:ok, %{metadata: %{user_id: user_id}}} = perform_job(WorkspaceJob, args)
      assert user_id == signed_up.user.id

      # A job performed inside another's metadata (inline, in a test) leaves it as it was.
      other = sign_up_fixture()
      LogMetadata.put(other.scope)
      assert {:ok, _result} = perform_job(WorkspaceJob, args)

      assert LogMetadata.get() == %{
               organisation_id: other.organisation.id,
               workspace_id: other.workspace.id,
               user_id: other.user.id
             }
    end

    test "is refused without the organisation and the workspace", %{signed_up: signed_up} do
      assert error_on_args(WorkspaceJob.new(%{})) =~ "organisation and the workspace"

      assert error_on_args(WorkspaceJob.new(%{organisation_id: signed_up.organisation.id})) =~
               "organisation and the workspace"

      assert error_on_args(WorkspaceJob.new(%{"workspace_id" => signed_up.workspace.id})) =~
               "organisation and the workspace"

      assert error_on_args(WorkspaceJob.new(%{ids(signed_up) | "workspace_id" => "main"})) =~
               "UUID"

      assert {:error, %Ecto.Changeset{}} = Oban.insert(WorkspaceJob.new(%{}))
      refute_enqueued(worker: WorkspaceJob)
    end

    test "writes the ids back in their canonical form, as strings", %{signed_up: signed_up} do
      changeset =
        WorkspaceJob.new(%{
          organisation_id: String.upcase(signed_up.organisation.id),
          workspace_id: signed_up.workspace.id,
          target: "t-1"
        })

      assert changeset.changes.args == %{
               "organisation_id" => signed_up.organisation.id,
               "workspace_id" => signed_up.workspace.id,
               target: "t-1"
             }
    end

    test "that reached the queue without them is cancelled, not run" do
      job = %Oban.Job{args: %{"target" => "t-1"}, worker: inspect(WorkspaceJob), attempt: 1}
      assert WorkspaceJob.perform(job) == {:cancel, :invalid_arguments}
    end

    test "is cancelled when the workspace is gone or is another organisation's", %{
      signed_up: signed_up
    } do
      other = sign_up_fixture()

      for args <- [
            %{ids(signed_up) | "workspace_id" => other.workspace.id},
            %{ids(signed_up) | "workspace_id" => Ecto.UUID.generate()},
            %{ids(signed_up) | "organisation_id" => Ecto.UUID.generate()},
            Map.put(ids(signed_up), "user_id", Ecto.UUID.generate())
          ] do
        capture_log(fn ->
          assert perform_job(WorkspaceJob, args) == {:cancel, :scope_gone}
        end)
      end

      # The cancellation is one line, with the ids.
      gone = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          perform_job(WorkspaceJob, Map.put(ids(signed_up), "user_id", gone))
        end)

      assert [line] = lines(log, "worker=Apiary.JobTest.WorkspaceJob")
      assert line =~ "job cancelled"
      assert line =~ "state=cancelled reason=scope_gone"
      assert line =~ "organisation_id=#{signed_up.organisation.id}"
      assert line =~ "workspace_id=#{signed_up.workspace.id}"
      assert line =~ "user_id=#{gone}"
    end

    test "that raises is logged once, with the ids and without its arguments", %{
      signed_up: signed_up
    } do
      args =
        signed_up
        |> ids()
        |> Map.merge(%{"name" => "acme-private-name", "user_id" => signed_up.user.id})

      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn -> perform_job(RaisingJob, args, max_attempts: 3) end
        end)

      assert [line] = lines(log, "worker=Apiary.JobTest.RaisingJob")
      assert line =~ "[warning]"
      assert line =~ "job failed"
      assert line =~ "attempt=1/3 queue=default state=failure kind=error error=RuntimeError"
      assert line =~ "organisation_id=#{signed_up.organisation.id}"
      assert line =~ "workspace_id=#{signed_up.workspace.id}"
      assert line =~ "user_id=#{signed_up.user.id}"
      refute log =~ "acme-private-name"
      refute log =~ signed_up.user.email

      # The last attempt is discarded, an error.
      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn ->
            perform_job(RaisingJob, args, attempt: 3, max_attempts: 3)
          end
        end)

      assert [line] = lines(log, "worker=Apiary.JobTest.RaisingJob")
      assert line =~ "[error]"
      assert line =~ "state=discard"
    end

    test "is stopped before the lifeline would run it a second time" do
      assert WorkspaceJob.timeout(%Oban.Job{}) == Job.default_timeout()
      assert QuickJob.timeout(%Oban.Job{}) == 60_000
      rescue_after = Application.fetch_env!(:apiary, Oban)[:lifeline][:rescue_after]
      assert Job.default_timeout() < Oban.Period.to_seconds(rescue_after) * 1_000
    end

    test "does not compile with a timeout the lifeline would cut short" do
      assert_raise ArgumentError, ~r/shorter than the lifeline's rescue_after/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Apiary.JobTest.TooSlowJob do
              use Apiary.Job, queue: :default, timeout: 30 * 60_000

              @impl Apiary.Job
              def perform(_scope, _job), do: :ok
            end
          end
        )
      end

      assert_raise ArgumentError, ~r/positive number of milliseconds/, fn ->
        Job.check_timeout!(__MODULE__, 0, rescue_after: {30, :minutes})
      end

      # Without a lifeline nothing runs a slow job a second time.
      assert Job.check_timeout!(__MODULE__, 90 * 60_000, false) == 90 * 60_000
    end
  end

  describe "the log of a job's end" do
    test "stays attached when a line cannot be written" do
      log =
        capture_log(fn ->
          :telemetry.execute([:oban, :job, :exception], %{}, %{job: :not_a_job, state: :failure})
        end)

      assert log =~ "job log failed"

      assert "apiary-job-log" in Enum.map(
               :telemetry.list_handlers([:oban, :job, :exception]),
               & &1.id
             )
    end
  end

  describe "an organisation's job" do
    test "acts in the organisation, in no workspace" do
      signed_up = sign_up_fixture()
      args = %{"organisation_id" => signed_up.organisation.id, "workspace_id" => nil}

      assert {:ok, %{scope: scope, metadata: metadata}} = perform_job(OrganisationJob, args)
      assert scope.organisation.id == signed_up.organisation.id
      assert scope.workspace == nil
      assert metadata == %{@none | organisation_id: signed_up.organisation.id}

      assert %{"workspace_id" => nil} = OrganisationJob.for_scope(signed_up.scope).changes.args
    end

    test "is refused without an organisation, or with a workspace" do
      signed_up = sign_up_fixture()

      assert error_on_args(OrganisationJob.new(%{})) =~ "organisation it works for"
      assert error_on_args(OrganisationJob.new(ids(signed_up))) =~ "no workspace"
    end
  end

  describe "an instance's job" do
    test "acts as the instance, with no organisation in its scope or its log metadata" do
      assert {:ok, %{scope: scope, metadata: metadata}} = perform_job(InstanceJob, %{})
      assert scope == %Scope{instance: true, origin: %{worker: inspect(InstanceJob)}}
      assert metadata == @none
    end

    test "names no organisation or workspace" do
      signed_up = sign_up_fixture()

      assert error_on_args(InstanceJob.new(ids(signed_up))) =~ "instance's"

      assert InstanceJob.for_scope(signed_up.scope).changes.args == %{
               "user_id" => signed_up.user.id
             }
    end
  end

  describe "a sweep" do
    test "enqueues one job per workspace, and one per organisation" do
      first = sign_up_fixture()
      second = sign_up_fixture()

      assert {:ok, 2} = Job.insert_per_workspace(UniqueJob, %{"reason" => "sweep"})

      for signed_up <- [first, second] do
        assert_enqueued(worker: UniqueJob, args: Map.put(ids(signed_up), "reason", "sweep"))
      end

      assert {:ok, 2} = Job.insert_per_organisation(UniqueOrganisationJob)

      for signed_up <- [first, second] do
        assert_enqueued(
          worker: UniqueOrganisationJob,
          args: %{"organisation_id" => signed_up.organisation.id}
        )
      end
    end

    test "run again, enqueues only what is missing, however much later" do
      sign_up_fixture()
      sign_up_fixture()

      assert {:ok, 2} = Job.insert_per_workspace(UniqueJob)

      # Long past Oban's default period of a minute: the jobs still waiting are not
      # enqueued again.
      Repo.update_all(Oban.Job, set: [inserted_at: DateTime.add(DateTime.utc_now(), -1, :day)])
      assert {:ok, 0} = Job.insert_per_workspace(UniqueJob)

      sign_up_fixture()
      assert {:ok, 1} = Job.insert_per_workspace(UniqueJob)
      assert [_, _, _] = all_enqueued(worker: UniqueJob)

      # A job that has completed is enqueued again: every job may run twice.
      [done | _] = all_enqueued(worker: UniqueJob)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^done.id), set: [state: "completed"])
      assert {:ok, 1} = Job.insert_per_workspace(UniqueJob)
    end

    test "once per run, enqueues a run's job once and the next run's anew" do
      sign_up_fixture()
      sign_up_fixture()

      assert {:ok, 2} = Job.insert_per_workspace(DailyJob, %{"day" => "2026-09-26"})
      Repo.update_all(Oban.Job, set: [state: "completed"])
      assert {:ok, 0} = Job.insert_per_workspace(DailyJob, %{"day" => "2026-09-26"})
      assert {:ok, 2} = Job.insert_per_workspace(DailyJob, %{"day" => "2026-09-27"})
    end

    test "takes Oban's unique lock job by job, as a queue that runs jobs does" do
      # An instance out of testing mode, whose unique insert takes the advisory lock, with
      # nothing started that would reach the database from another process.
      name = Module.concat(__MODULE__, LockingOban)

      start_supervised!(
        {Oban,
         name: name,
         repo: Apiary.Repo,
         testing: :disabled,
         queues: false,
         plugins: false,
         peer: false,
         stager: false,
         notifier: Oban.Notifiers.Isolated}
      )

      sign_up_fixture()
      sign_up_fixture()

      test = self()
      handler = "job-test-locks-#{inspect(test)}"

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test and query =~ "pg_try_advisory_xact_lock", do: send(test, :locked)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, 2} = Job.insert_per_workspace(UniqueJob, %{}, oban: name)
      assert {:ok, 0} = Job.insert_per_workspace(UniqueJob, %{}, oban: name)
      assert [_, _] = all_enqueued(worker: UniqueJob)

      # One lock per job inserted or found, taken in the transaction of its own insert.
      for _ <- 1..4, do: assert_received(:locked)
      refute_received :locked
    end

    test "reads the workspaces a page at a time, each once" do
      created = for _ <- 1..3, do: sign_up_fixture()

      expected =
        created |> Enum.map(&{&1.organisation.id, &1.workspace.id}) |> Enum.sort_by(&elem(&1, 1))

      {first, cursor} = Apiary.Organisations.page_workspace_ids(nil, 2)
      {second, cursor} = Apiary.Organisations.page_workspace_ids(cursor, 2)
      assert {[], ^cursor} = Apiary.Organisations.page_workspace_ids(cursor, 2)
      assert first ++ second == expected
      assert length(second) == 1
    end

    test "is refused for a job of another scope, or one not unique by the ids" do
      assert_raise ArgumentError, fn -> Job.insert_per_workspace(UniqueOrganisationJob) end
      assert_raise ArgumentError, fn -> Job.insert_per_organisation(UniqueJob) end
      assert_raise ArgumentError, ~r/unique/, fn -> Job.insert_per_workspace(WorkspaceJob) end

      assert_raise ArgumentError, ~r/keys must include organisation_id and workspace_id/, fn ->
        Job.insert_per_workspace(UniqueByReasonJob)
      end

      assert_raise ArgumentError, ~r/fields must include :args/, fn ->
        Job.insert_per_workspace(UniqueByWorkerJob)
      end

      assert_raise ArgumentError, ~r/period must be :infinity/, fn ->
        Job.insert_per_workspace(UniqueForAMinuteJob)
      end

      assert_raise ArgumentError, ~r/period must be :infinity/, fn ->
        Job.insert_per_workspace(UniqueJob, %{}, unique: true)
      end

      assert_raise ArgumentError, ~r/names the run/, fn ->
        Job.insert_per_workspace(UniqueForeverJob)
      end

      # Without keys every argument is compared, so one of the sweep's may name the run.
      unique = [period: :infinity, states: :successful]

      assert {:ok, 0} =
               Job.insert_per_workspace(UniqueJob, %{"day" => "2026-09-26"}, unique: unique)

      assert_raise ArgumentError, ~r/names the run/, fn ->
        Job.insert_per_workspace(UniqueJob, %{}, unique: unique)
      end
    end
  end
end
