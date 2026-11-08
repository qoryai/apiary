defmodule Mix.Tasks.Apiary.Demo.WorkflowTest do
  # The task switches the projection to the calling process for the whole node while it
  # fills, and a test switches the features: one test at a time.
  use Apiary.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query

  alias Apiary.{Accounts, Artifacts, Processes, Repo, Stages}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Organisations
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias Apiary.WorkItems.WorkItem
  alias Mix.Tasks.Apiary.Demo.Workflow

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    # The suite's instance organisation is committed before any test: hidden as the edition
    # hides it, and every organisation marked for deletion in this test's sandbox, the
    # instance has none in use and is not set up, as a new database is not.
    Apiary.EditionKit.hide_instance_organisation()
    now = DateTime.utc_now()

    Repo.update_all(Organisation,
      set: [
        deletion_marked_at: now,
        purge_after: DateTime.add(now, 30, :day),
        purge_trigger: "grace_period"
      ]
    )

    :ok
  end

  describe "refusal/4" do
    test "the tests fill their database; the test environment outside them is refused" do
      assert Workflow.refusal(:test, true, "apiary_test", %{}) == nil
      assert Workflow.refusal(:test, false, "apiary_test", %{}) =~ "belongs to the tests"
    end

    test "development fills only apiary_preview_workflow or an apiary_walk_ database" do
      for name <- ["apiary_preview_workflow", "apiary_walk_preview"] do
        assert Workflow.refusal(:dev, false, name, %{"APIARY_DEV_DATABASE" => name}) == nil
      end

      env = %{"APIARY_DEV_DATABASE" => "apiary_preview_workflow"}

      empty_url = Map.put(env, "DATABASE_URL", "")
      assert Workflow.refusal(:dev, false, "apiary_preview_workflow", empty_url) == nil

      assert Workflow.refusal(
               :dev,
               false,
               "apiary_preview_workflow",
               Map.put(env, "DATABASE_URL", "ecto://localhost/apiary_preview_workflow")
             ) =~ "DATABASE_URL is set"

      assert Workflow.refusal(:dev, false, "apiary_dev", %{}) =~ "APIARY_DEV_DATABASE is not set"

      for name <- ["apiary_dev", "apiary_preview_workflow_2", "apiary_preview_v0"] do
        assert Workflow.refusal(:dev, false, name, %{"APIARY_DEV_DATABASE" => name}) =~
                 "#{name} is not apiary_preview_workflow and does not start with apiary_walk_"
      end

      assert Workflow.refusal(:dev, false, "apiary_dev", env) =~ "configured with the database"
    end
  end

  test "the mockup is a PNG image" do
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>> = Workflow.mockup_png()
  end

  @tag with_features: [:observability, :security, :secrets, :factory]
  test "stops with one line when workflow_model is off" do
    error = assert_raise Mix.Error, fn -> Workflow.run([]) end
    assert error.message =~ "Add workflow_model to QORY_FEATURES"
    refute error.message =~ "\n"
    refute Repo.exists?(from o in Organisation, where: is_nil(o.deletion_marked_at))
  end

  describe "with the workflow model" do
    @describetag needs: [:factory, :workflow_model]
    @describetag :tmp_dir

    # The stage runner writes to `Apiary.Artifacts`, as in development, not to the stand-in
    # the test configuration sets; the files go to the test's folder.
    setup %{tmp_dir: tmp_dir} do
      for {key, value} <- [
            {Apiary.Stages.Artifacts, Apiary.Artifacts},
            {:artifacts_dir, Path.join(tmp_dir, "artifacts")}
          ] do
        previous = Application.fetch_env(:apiary, key)
        Application.put_env(:apiary, key, value)

        on_exit(fn ->
          case previous do
            {:ok, value} -> Application.put_env(:apiary, key, value)
            :error -> Application.delete_env(:apiary, key)
          end
        end)
      end

      :ok
    end

    test "stops on a fill that ended between the set-up and the workspace" do
      {:ok, _set_up} =
        Apiary.Setup.set_up(
          Apiary.Setup.code!(),
          %{"email" => "dana@example.com", "organisation_name" => "Acme"},
          password: :optional,
          origin: %{worker: "demo"}
        )

      error = assert_raise Mix.Error, fn -> Workflow.run([]) end
      assert error.message =~ "The preview's fill did not finish."
    end

    test "fills an empty instance: people, versions with a trial, and work items in each state" do
      Workflow.run([])

      acme = Repo.one!(from o in Organisation, where: is_nil(o.deletion_marked_at))
      assert acme.name == "Acme"

      workspace = Repo.get_by!(Workspace, organisation_id: acme.id, name: "Web shop")
      assert workspace.domain == "software"

      # Dana owns Acme, Ana is an admin and Max a member, each with the password the
      # moduledoc gives.
      people = %{
        "dana@example.com" => {"demo-workflow-dana", :owner},
        "ana@example.com" => {"demo-workflow-ana", :admin},
        "max@example.com" => {"demo-workflow-max", :member}
      }

      for {email, {password, level}} <- people do
        assert moduledoc() =~ "`#{email}` with `#{password}`"
        assert %{id: user_id} = Accounts.get_user_by_email_and_password(email, password)

        assert Repo.get_by!(Membership, organisation_id: acme.id, user_id: user_id).level ==
                 level
      end

      dana = scope("dana@example.com")
      max = scope("max@example.com")

      # Versions 1 to 3, the third current, and a trial: the first made with the workspace,
      # the others saved by Dana; each differs from the one before.
      versions = workspace |> Processes.list_versions() |> Enum.sort_by(& &1.number)
      assert Enum.map(versions, & &1.number) == [1, 2, 3, 4]

      assert Enum.map(versions, &to_string(&1.status)) == ["past", "past", "current", "trial"]
      assert Processes.current(workspace).number == 3

      for version <- versions, version.number > 1, do: assert(version.author_id == dana.user.id)

      [v1, v2, v3, trial] = versions
      kinds = &(&1 |> Enum.map(fn change -> elem(change, 0) end) |> MapSet.new())

      assert MapSet.subset?(
               MapSet.new([:outputs_changed, :inputs_changed]),
               kinds.(Processes.diff(v1, v2))
             )

      assert :outputs_changed in kinds.(Processes.diff(v2, v3))
      assert :outputs_changed in kinds.(Processes.diff(v3, trial))

      items =
        Repo.all(from w in WorkItem, where: w.workspace_id == ^workspace.id)
        |> Map.new(&{&1.title, &1})

      assert map_size(items) == 10

      at = fn title ->
        work_item = Map.fetch!(items, title)
        stage = Processes.stage(Processes.version_for(work_item).document, work_item.stage_id)
        {stage["name"], to_string(work_item.stage_state)}
      end

      # Explore running, its run waiting for a machine, on the trial.
      running = items["Save a basket for later"]
      assert at.("Save a basket for later") == {"Explore", "running"}
      assert running.process_version_id == trial.id

      assert Repo.one!(
               from d in DispatchRun,
                 where: d.work_item_id == ^running.id and d.state == :waiting,
                 select: d.process_version_id
             ) == trial.id

      # Explore at its gate, with the run's proposal, which passed its Exists check.
      gate = items["Checkout total ignores the voucher after a reload"]
      assert at.(gate.title) == {"Explore", "at_gate"}
      assert to_string(Artifacts.newest(gate, "proposal").writer) == "run"

      assert %{type: "proposal", check: :passed} =
               Enum.find(Stages.status(gate).outputs, &(&1.type == "proposal"))

      # Explore approved by Dana, Shape at its gate.
      shaped = items["Search returns no results for words with umlauts"]
      assert at.(shaped.title) == {"Shape", "at_gate"}
      explore_id = stage_id(v3, "Explore")
      assert {explore_id, "approve", dana.user.id} in decisions(shaped)

      # Explore and Shape approved by Dana, Build waiting for acceptance criteria.
      waiting = items["Basket badge shows 0 after signing in"]
      assert at.(waiting.title) == {"Build", "waiting_inputs"}
      assert length(decisions(waiting)) == 2

      # Questions: the first run's answered by Dana, an option for one and her own text
      # for the other; the second run's wait for answers.
      asked = items["Product images load twice on the listing page"]
      assert at.(asked.title) == {"Explore", "waiting_answers"}
      {_version, document} = Apiary.Explore.Questions.newest(asked)

      assert [
               %{
                 "id" => "q1",
                 "state" => "answered",
                 "answer" => %{"option" => "Keep the lazy loader"}
               },
               %{
                 "id" => "q2",
                 "state" => "answered",
                 "answer" => %{"option" => nil, "note" => _note}
               },
               %{"id" => "q3", "state" => "open"}
             ] = document["questions"]

      # Explore's gate: the run of version 2 replied to Dana's review comment and closed it.
      {_version, comments} = Apiary.Explore.ReviewComments.newest(gate)

      assert [%{"state" => "closed", "replies" => [%{"outcome" => "changed"}]}] =
               comments["review_comments"]

      # A run that exited failed without a proposal, as a run that stopped.
      stopped = items["TypeError in the address form after autofill"]
      assert at.(stopped.title) == {"Explore", "escalated"}
      assert to_string(Stages.status(stopped).escalation.cause) == "run_stopped"

      # A run that qory closed because the harness at the target's root has no skill
      # for the workflow explore-a-ticket: the escalation names the workflow and that file.
      missing_skill = items["Show the size guide in German"]
      assert at.(missing_skill.title) == {"Explore", "escalated"}
      escalation = Stages.status(missing_skill).escalation
      assert to_string(escalation.cause) == "run_stopped"

      assert escalation.gaps ==
               "The run's harness has no skill for the workflow explore-a-ticket. The harness comes from the harness file at the root of repository acme/web-shop."

      assert Repo.one!(
               from r in Apiary.Runs.Run,
                 join: d in DispatchRun,
                 on: d.id == r.dispatch_run_id,
                 where: d.work_item_id == ^missing_skill.id,
                 select: r.reason
             ) == "workflow_not_in_harness"

      # Max added acceptance criteria with a Mermaid diagram and a mockup in Shape.
      added = items["Show delivery dates on the product page"]
      assert at.(added.title) == {"Shape", "at_gate"}
      shape_id = stage_id(v3, "Shape")

      for type <- ["acceptance-criteria", "mockup"] do
        version = Artifacts.newest(added, type)
        assert to_string(version.writer) == "person"
        assert version.user_id == max.user.id
        assert version.stage_id == shape_id
        assert Artifacts.exists?(added, shape_id, type)
      end

      assert Enum.map(Artifacts.list(added), & &1.type) |> Enum.sort() ==
               ["acceptance-criteria", "mockup", "proposal", "verdict"]

      # Shape approved by Dana with Max's criteria: Build has its input and waits at its
      # gate.
      approved = items["Remove the old promotion banner"]
      assert at.(approved.title) == {"Build", "at_gate"}
      assert {shape_id, "approve", dana.user.id} in decisions(approved)
      assert Artifacts.newest(approved, "acceptance-criteria")

      # On version 2, Build waits for capture-demo and fix-demo-findings, which the
      # harness does not declare.
      demo = items["Record a demo of the new checkout"]
      assert at.(demo.title) == {"Build", "waiting_workflow"}
      assert demo.process_version_id == v2.id
      build_id = stage_id(v2, "Build")

      missing =
        Processes.placement_check(
          v2.document,
          Processes.declared_workflows(workspace),
          Artifacts.types(workspace)
        )

      assert {:missing_workflow, build_id, "capture-demo"} in missing
      assert {:missing_workflow, build_id, "fix-demo-findings"} in missing

      # A second run adds nothing.
      Workflow.run([])
      assert_received {:mix_shell, :info, ["The preview is there already: nothing more is made."]}

      assert Repo.aggregate(from(w in WorkItem, where: w.workspace_id == ^workspace.id), :count) ==
               10

      assert length(Processes.list_versions(workspace)) == 4
    end
  end

  defp moduledoc do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Workflow)
    doc
  end

  defp scope(email) do
    user = Accounts.get_user_by_email(email)
    {:ok, scope} = Organisations.resolve_scope(Scope.for_user(user), "acme", workspace_slug())
    scope
  end

  defp workspace_slug,
    do: Repo.one!(from w in Workspace, where: w.name == "Web shop", select: w.slug)

  defp stage_id(version, name),
    do: Enum.find_value(version.document["stages"], &(&1["name"] == name && &1["id"]))

  # The gate decisions of the work item: stage, kind and person, from the table the stage
  # runner writes.
  defp decisions(%WorkItem{id: id}) do
    Repo.all(
      from g in "gate_decisions",
        where: g.work_item_id == type(^id, :binary_id),
        select: {g.stage_id, g.kind, type(g.user_id, :binary_id)}
    )
  end
end
