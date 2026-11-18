defmodule Apiary.Dispatches.HandoverVariablesTest do
  # The variables a claim gives the run it registers (`Apiary.Dispatches.Handover.register/2`,
  # through `Apiary.Dispatches.claim/3`): what the run's workspace and target resolve to,
  # with the organisation's level above them, stored with the run
  # (`runs.registration_variables`) beside the run's two names; a name Forager leaves out
  # of a run is not given; and a run that takes more than 126 of them, or more than 64 KiB
  # of names and values, does not start, with the count or the size kept as the end's
  # detail. A prebuild's image is shared by the organisation's workspaces, so a prebuild
  # has its two names alone and is never refused for the variables.
  # Not async: the features are the whole node's, and some tests turn one off.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, walked_claim: 3]
  import Apiary.NodesFixtures, only: [collection_fixture: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Features, Variables}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Kinds.Placeholders
  alias Apiary.Runs.{Run, Target}
  alias Apiary.Stages.StopCause
  alias Apiary.Variables.Variable
  alias ApiaryPro.OrganisationVariables

  @moduletag needs: [:factory, :organisation_variables]
  # The tests that turn a feature off put the features back when they end.
  @moduletag with_features: Features.all()

  @body ~s({"version":3,"time":"2026-10-18T12:00:00Z"})
  @own %{"QORY_RUN_SYSTEM" => "forge.example.com", "QORY_RUN_REPOSITORIES" => "acme/shop"}

  setup do
    %{scope: scope} = sign_up_fixture()

    target =
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "forge.example.com",
        path: "acme/shop",
        first_seen_at: DateTime.utc_now()
      })

    scope |> handover_place_fixture() |> Map.merge(%{scope: scope, target: target})
  end

  defp queued!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {work_item, run}
  end

  defp claim(ctx), do: walked_claim(ctx.key, Dispatches.now(), @body)

  # The run a claim registered: its stored variables.
  defp claimed!(ctx) do
    {:ok, %{dispatch: %Apiary.Dispatches.Dispatch{}} = claimed} = claim(ctx)
    Repo.get!(Run, claimed.registered.id).registration_variables
  end

  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)

  defp workspace!(ctx, name, value, attrs \\ %{}) do
    {:ok, variable} =
      Variables.create_variable(
        ctx.scope,
        :workspace,
        Map.merge(%{name: name, value: value}, attrs)
      )

    variable
  end

  defp target!(ctx, name, value) do
    {:ok, variable} =
      Variables.create_variable(ctx.scope, ctx.target, %{name: name, value: value})

    variable
  end

  defp organisation!(ctx, name, value, locked \\ false) do
    {:ok, variable} =
      OrganisationVariables.create(ctx.scope, %{name: name, value: value, locked: locked})

    variable
  end

  # Rows written around the saves' checks: the state a claim must still refuse, as a
  # holder that was within the limits before a name was added to the deny list, or a
  # row written by hand, is in.
  defp rows!(ctx, variables, target_id \\ nil) do
    now = DateTime.utc_now()

    {_count, _rows} =
      Repo.insert_all(
        Variable,
        for {name, value} <- variables do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: ctx.scope.organisation.id,
            workspace_id: ctx.scope.workspace.id,
            target_id: target_id,
            name: name,
            value: value,
            locked: false,
            created_by_id: ctx.scope.user.id,
            updated_by_id: ctx.scope.user.id,
            inserted_at: now,
            updated_at: now
          }
        end
      )

    :ok
  end

  defp names(count, prefix \\ "V"),
    do: for(n <- 1..count, do: {prefix <> String.pad_leading(Integer.to_string(n), 3, "0"), "x"})

  # The run of the queue ended `variables_invalid` with `detail`, its run failed before it
  # started, and the stop cause reads the detail as the claim wrote it: `line` and the fix.
  defp refused!(ctx, {work_item, queued}, detail, line) do
    assert %DispatchRun{
             state: :ended,
             end_cause: :variables_invalid,
             end_detail: ^detail,
             result_outcome: :error
           } = run = queue_run!(queued)

    assert %Run{state: "failed", reason: "variables_invalid"} =
             Repo.get_by!(Run, dispatch_run_id: queued.id)

    assert StopCause.text(run, work_item) ==
             line <>
               "\nOwners and admins of #{ctx.scope.workspace.name} remove variables on the Variables page of the workspace or its organisation, then start the run again."
  end

  defp off!(feature),
    do: Application.put_env(:apiary, :features, Features.enabled() -- [feature])

  describe "the variables of a run" do
    test "are the organisation's, the workspace's and the target's, the more specific winning and a lock holding",
         ctx do
      # The organisation's level.
      organisation!(ctx, "ORG_ONLY", "from the organisation")
      organisation!(ctx, "SHARED", "from the organisation")
      organisation!(ctx, "ORG_DEFAULT", "from the organisation")

      # The workspace's, overriding the organisation's where the organisation does not lock.
      workspace!(ctx, "WORKSPACE_ONLY", "from the workspace")
      workspace!(ctx, "SHARED", "from the workspace")
      workspace!(ctx, "ORG_DEFAULT", "from the workspace")
      workspace!(ctx, "LOCKED_BELOW", "set by the workspace before the organisation's lock")

      # The target's, overriding the workspace's and the organisation's.
      target!(ctx, "TARGET_ONLY", "from the target")
      target!(ctx, "SHARED", "from the target")
      target!(ctx, "LOCKED_BY_WORKSPACE", "set by the target before the workspace's lock")

      # A lock set after the names below it were set: the lock wins.
      organisation!(ctx, "LOCKED_BELOW", "from the organisation, locked", true)
      workspace!(ctx, "LOCKED_BY_WORKSPACE", "from the workspace, locked", %{locked: true})

      {_work_item, queued} = queued!(ctx)

      assert claimed!(ctx) ==
               Map.merge(@own, %{
                 "ORG_ONLY" => "from the organisation",
                 "ORG_DEFAULT" => "from the workspace",
                 "WORKSPACE_ONLY" => "from the workspace",
                 "TARGET_ONLY" => "from the target",
                 "SHARED" => "from the target",
                 "LOCKED_BELOW" => "from the organisation, locked",
                 "LOCKED_BY_WORKSPACE" => "from the workspace, locked"
               })

      assert queue_run!(queued).state == :claimed
    end

    test "are the workspace's alone for a target the workspace has no row of", ctx do
      Repo.delete!(ctx.target)
      workspace!(ctx, "WORKSPACE_ONLY", "from the workspace")
      {_work_item, _queued} = queued!(ctx)

      assert claimed!(ctx) == Map.put(@own, "WORKSPACE_ONLY", "from the workspace")
    end

    test "are the run's two names where no level sets one", ctx do
      {_work_item, _queued} = queued!(ctx)
      assert claimed!(ctx) == @own
    end

    test "are read once: a change after the claim leaves the stored run as it was", ctx do
      variable = workspace!(ctx, "NODE_ENV", "production")
      {_work_item, _queued} = queued!(ctx)
      {:ok, %{registered: registered}} = claim(ctx)

      stored = Repo.get!(Run, registered.id).registration_variables
      assert stored == Map.put(@own, "NODE_ENV", "production")

      {:ok, _changed} = Variables.update_variable(ctx.scope, variable, %{value: "development"})
      workspace!(ctx, "EXTRA", "later")

      assert Repo.get!(Run, registered.id).registration_variables == stored

      # The next run takes them as they are then.
      {_work_item, _next} = queued!(ctx)
      {:ok, %{registered: next}} = claim(ctx)

      assert Repo.get!(Run, next.id).registration_variables ==
               Map.merge(@own, %{"NODE_ENV" => "development", "EXTRA" => "later"})
    end

    test "of a prebuild are the run's two names alone: no level's variable reaches it", ctx do
      # The prebuild's image is shared by the organisation's workspaces, so no workspace's
      # value goes into it, while a run of a work item gets them.
      organisation!(ctx, "ORG_ONLY", "from the organisation")
      workspace!(ctx, "WORKSPACE_ONLY", "from the workspace")
      target!(ctx, "TARGET_ONLY", "from the target")
      {_work_item, _queued} = queued!(ctx)

      assert claimed!(ctx) ==
               Map.merge(@own, %{
                 "ORG_ONLY" => "from the organisation",
                 "WORKSPACE_ONLY" => "from the workspace",
                 "TARGET_ONLY" => "from the target"
               })

      collection =
        collection_fixture(ctx.scope,
          target_system: ctx.target.system,
          target_path: ctx.target.path
        )

      {:ok, prebuild} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      assert claimed!(ctx) == @own
      assert queue_run!(prebuild).state == :claimed
    end
  end

  describe "the features" do
    test "without organisation_variables, the organisation's level is absent", ctx do
      organisation!(ctx, "ORG_ONLY", "from the organisation")
      workspace!(ctx, "WORKSPACE_ONLY", "from the workspace")
      {_work_item, _queued} = queued!(ctx)

      off!(:organisation_variables)

      assert claimed!(ctx) == Map.put(@own, "WORKSPACE_ONLY", "from the workspace")
    end

    test "without secrets, the run has its two names alone", ctx do
      organisation!(ctx, "ORG_ONLY", "from the organisation")
      workspace!(ctx, "WORKSPACE_ONLY", "from the workspace")
      target!(ctx, "TARGET_ONLY", "from the target")
      {_work_item, _queued} = queued!(ctx)

      # `factory` needs `secrets`, so no value of QORY_FEATURES gives these features: the
      # claim asks for `secrets` itself.
      off!(:secrets)

      assert claimed!(ctx) == @own
    end
  end

  describe "a name Forager leaves out" do
    test "is not given to the run, whatever its level and its case", ctx do
      # A name on the deny list is saved, and the page warns.
      workspace!(ctx, "PATH", "/tmp")
      workspace!(ctx, "no_proxy", "example.com")
      workspace!(ctx, "BUN_OPTIONS", "--smol")
      workspace!(ctx, "GH_TOKEN", "a forge token")
      organisation!(ctx, "ANTHROPIC_API_KEY", "a model key")
      target!(ctx, "HTTPS_PROXY", "http://proxy.example")
      target!(ctx, "NODE_ENV", "production")
      {_work_item, _queued} = queued!(ctx)

      assert claimed!(ctx) == Map.put(@own, "NODE_ENV", "production")
    end

    test "QORY_RUN_SYSTEM at a level above the run's own is not given: the run keeps its value",
         ctx do
      # A save refuses the name, so each level is written around it.
      rows!(ctx, [{"QORY_RUN_SYSTEM", "workspace.example"}])
      rows!(ctx, [{"QORY_RUN_SYSTEM", "target.example"}], ctx.target.id)

      Repo.insert_all(ApiaryPro.OrganisationVariables.Variable, [
        %{
          id: Ecto.UUID.generate(),
          organisation_id: ctx.scope.organisation.id,
          name: "QORY_RUN_SYSTEM",
          value: "organisation.example",
          locked: true,
          created_by_id: ctx.scope.user.id,
          updated_by_id: ctx.scope.user.id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

      {_work_item, _queued} = queued!(ctx)

      assert claimed!(ctx) == @own
    end

    test "is refused on save when it begins QORY_", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Variables.create_variable(ctx.scope, :workspace, %{name: "QORY_X", value: "1"})
    end

    test "is still a name a placeholder may take, when it is a forge token" do
      for name <- ["GH_TOKEN", "GITHUB_TOKEN", "GITLAB_TOKEN", "GL_TOKEN"],
          do: refute(Placeholders.conflict?(name), name)

      for name <- ["PATH", "BUN_OPTIONS", "HTTP_PROXY", "QORY_TOKEN"],
          do: assert(Placeholders.conflict?(name), name)
    end
  end

  describe "the limits of a run" do
    test "126 variables and the run's two names are 128, which a run takes", ctx do
      rows!(ctx, names(126))
      {_work_item, _queued} = queued!(ctx)

      stored = claimed!(ctx)
      assert map_size(stored) == 128
      assert Map.take(stored, Map.keys(@own)) == @own
    end

    test "127 variables are 129 names with the run's two, so no run starts and the count is kept",
         ctx do
      rows!(ctx, names(127))
      queued = queued!(ctx)

      log = capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      refused!(
        ctx,
        queued,
        "names_127",
        "The run did not start: it has 127 variables, and a run takes at most 126."
      )

      assert Apiary.Dispatches.Slots.held(ctx.pool.id) == 0

      assert [line] =
               log |> String.split("\n") |> Enum.filter(&(&1 =~ "end_cause=variables_invalid"))

      assert line =~ "run_id=#{elem(queued, 1).run_id}"
      assert line =~ "names=127"
    end

    test "a variable over the contract's value limit ends the run with no detail, and the log names it only",
         ctx do
      # The table's check keeps a value to 4096 bytes; the sandbox's transaction drops it
      # for this test and rolls the drop back.
      Repo.query!("ALTER TABLE variables DROP CONSTRAINT variables_value_check")
      value = String.duplicate("secretvalue", 400)
      rows!(ctx, [{"TOO_LONG", value}])
      {_work_item, queued} = queued!(ctx)

      log = capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      assert %DispatchRun{
               state: :ended,
               end_cause: :variables_invalid,
               end_detail: nil,
               result_outcome: :error
             } = queue_run!(queued)

      assert [line] =
               log |> String.split("\n") |> Enum.filter(&(&1 =~ "end_cause=variables_invalid"))

      assert line =~ "variable=TOO_LONG"
      refute log =~ "secretvalue"
    end

    test "a prebuild is not refused for variables: 127 are set and it starts with none of them",
         ctx do
      rows!(ctx, names(127))

      collection =
        collection_fixture(ctx.scope,
          target_system: ctx.target.system,
          target_path: ctx.target.path
        )

      {:ok, prebuild} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      log = capture_log(fn -> assert claimed!(ctx) == @own end)

      assert %DispatchRun{state: :claimed, end_cause: nil, end_detail: nil} =
               queue_run!(prebuild)

      refute log =~ "variables_invalid"
    end

    test "names left out of the run do not count toward the 126", ctx do
      rows!(ctx, names(126) ++ [{"PATH", "/tmp"}])
      {_work_item, _queued} = queued!(ctx)

      assert map_size(claimed!(ctx)) == 128
    end

    test "names of the target's chain count once, wherever they are set", ctx do
      rows!(ctx, names(100))
      rows!(ctx, names(100), ctx.target.id)
      {_work_item, _queued} = queued!(ctx)

      assert map_size(claimed!(ctx)) == 102
    end

    test "names and values of 64 KiB are within the run's limit, and one byte more are not",
         ctx do
      # 15 names of 4 bytes and 4096-byte values, and one name of one byte, to 65,536.
      big =
        for n <- 1..15,
            do:
              {"V" <> String.pad_leading(Integer.to_string(n), 2, "0") <> "_",
               String.duplicate("a", 4096)}

      rows!(ctx, big ++ [{"W", String.duplicate("b", 65_536 - 15 * 4100 - 1)}])
      {_work_item, queued} = queued!(ctx)

      assert map_size(claimed!(ctx)) == 18
      assert queue_run!(queued).state == :claimed

      {1, _rows} =
        Repo.update_all(from(v in Variable, where: v.name == "W"),
          set: [value: String.duplicate("b", 65_536 - 15 * 4100 - 1 + 1)]
        )

      over = queued!(ctx)

      log = capture_log(fn -> assert claim(ctx) == {:ok, :none} end)

      refused!(
        ctx,
        over,
        "bytes_65537",
        "The run did not start: its variables take 65 KiB, and a run takes at most 64 KiB."
      )

      assert log =~ "bytes=65537"
    end
  end
end
