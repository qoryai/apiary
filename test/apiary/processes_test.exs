defmodule Apiary.ProcessesTest do
  # A workspace's process: the default document and its schema, the checks of a save, the
  # differences between versions, the placement check, and the versions a save, a trial,
  # making a trial current, dropping one and assigning a work item leave, with their
  # entries in the audit trail.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 1]

  alias Apiary.{Organisations, Processes, Stacks}
  alias Apiary.Audit.Entry
  alias Apiary.Processes.Version
  alias Apiary.WorkItems.WorkItem

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"

  defp default, do: Processes.default_document("software")

  # The default with each stage changed by `fun`, given the stage.
  defp edit(document \\ default(), fun),
    do: %{document | "stages" => Enum.map(document["stages"], fun)}

  defp rename(document \\ default(), id, name),
    do: edit(document, &if(&1["id"] == id, do: %{&1 | "name" => name}, else: &1))

  defp without(document \\ default(), id),
    do: %{document | "stages" => Enum.reject(document["stages"], &(&1["id"] == id))}

  # Another version of `like`'s workspace, with its document, written directly.
  defp version!(%Version{} = like, number, status) do
    Repo.insert!(%Version{
      organisation_id: like.organisation_id,
      workspace_id: like.workspace_id,
      public_id: Apiary.PublicId.generate("pv"),
      number: number,
      status: status,
      document: like.document
    })
  end

  defp errors(document) do
    assert {:error, errors} = Processes.validate(document)
    Enum.map(errors, &{&1.path, &1.error})
  end

  defp entries(organisation_id) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^organisation_id and e.action == "process.edit",
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  describe "the default process" do
    test "is valid against its own schema" do
      assert Processes.validate(default()) == :ok
    end

    test "is Explore, a loop of explore-a-ticket of 3 rounds, then Shape, Build, Verify and Release, each with a person's gate" do
      assert Enum.map(default()["stages"], & &1["name"]) ==
               ["Explore", "Shape", "Build", "Verify", "Release"]

      [explore | rest] = default()["stages"]
      assert explore["id"] == @explore

      assert explore["sequence"] == [
               %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "explore-a-ticket"}]}}
             ]

      assert explore["outputs"] == [%{"type" => "proposal", "required" => true}]

      for stage <- rest do
        assert %{"sequence" => [], "inputs" => [], "outputs" => []} = stage
      end

      for stage <- default()["stages"] do
        assert stage["gate"] == %{"kind" => "person", "approvers" => "members"}
        assert stage["id"] =~ ~r/\Ast_[0-9a-hjkmnp-tv-z]{10}\z/
      end
    end

    test "is the software type's for a domain without a default, and the template names the type" do
      assert Processes.default_document("example") == default()
      assert Processes.default_document(Apiary.Lingo.Domain.Software) == default()

      assert Processes.template(Apiary.Lingo.Domain.Software) ==
               %{"type" => "qory.software", "version" => 1}
    end
  end

  describe "validate/1" do
    test "refuses another schema, no stages, and a stage without its gate" do
      assert {"#/schema", :schema} in errors(%{default() | "schema" => "qory.process/v2"})
      assert errors(%{default() | "stages" => []}) != []
      assert errors(edit(&Map.delete(&1, "gate"))) != []
      assert errors(:not_a_map) == [{"#", :schema}]
    end

    test "refuses a loop inside a loop, rounds outside 1 to 10, and an empty loop" do
      nested = %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "fix"}]}}

      for loop <- [
            %{"rounds" => 2, "body" => [nested]},
            %{"rounds" => 0, "body" => [%{"workflow" => "fix"}]},
            %{"rounds" => 11, "body" => [%{"workflow" => "fix"}]},
            %{"rounds" => 2, "body" => []}
          ] do
        assert errors(rename(@shape, "Shape") |> put_sequence(@shape, [%{"loop" => loop}])) != []
      end
    end

    test "takes a workflow entry with a machine, a lower time limit and read access, and a reported check" do
      document =
        default()
        |> put_sequence(@shape, [
          %{"workflow" => "write-specs", "machine" => "large", "time_limit" => "1h30m"},
          %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "review", "access" => "read"}]}}
        ])
        |> edit(fn
          %{"id" => @shape} = stage ->
            Map.put(stage, "outputs", [
              %{"type" => "change", "required" => true, "check" => %{"reported" => "opened"}}
            ])

          stage ->
            stage
        end)

      assert Processes.validate(document) == :ok
      assert errors(put_sequence(default(), @shape, [%{"workflow" => "Write Specs"}])) != []

      assert errors(put_sequence(default(), @shape, [%{"workflow" => "x", "access" => "write"}])) !=
               []
    end

    test "refuses a stage id or a stage name twice, names compared trimmed and without case" do
      [explore, shape | rest] = default()["stages"]

      assert errors(%{default() | "stages" => [explore, %{shape | "id" => @explore} | rest]}) ==
               [{"#/stages/1/id", :duplicate_stage_id}]

      assert errors(%{default() | "stages" => [explore, %{shape | "name" => " explore "} | rest]}) ==
               [{"#/stages/1/name", :duplicate_stage_name}]
    end

    test "keeps fields the schema does not list" do
      document =
        default()
        |> Map.put("layout", %{"zoom" => 2})
        |> edit(&Map.put(&1, "colour", "amber"))

      assert Processes.validate(document) == :ok
    end

    test "refuses a document over the limits before the schema reads it" do
      assert errors(Map.put(default(), "notes", List.duplicate("a", 65))) == [{"#", :too_large}]
    end
  end

  defp put_sequence(document, id, sequence),
    do: edit(document, &if(&1["id"] == id, do: %{&1 | "sequence" => sequence}, else: &1))

  test "new_stage_id/0 mints st_ and 10 Crockford base32 characters, fresh each time" do
    ids = for _ <- 1..50, do: Processes.new_stage_id()
    assert Enum.all?(ids, &(&1 =~ ~r/\Ast_[0-9a-hjkmnp-tv-z]{10}\z/))
    assert Enum.uniq(ids) == ids
  end

  test "stage/2 finds a stage by its id, and nil for none" do
    assert %{"name" => "Shape"} = Processes.stage(default(), @shape)
    assert Processes.stage(default(), "st_0000000000") == nil
    assert Processes.stage(default(), nil) == nil
  end

  describe "diff/2" do
    test "lists every stage added before version 1, with its position" do
      assert [{:stage_added, @explore, %{name: "Explore", position: 0}} | _] =
               changes = Processes.diff(nil, default())

      assert length(changes) == 5
    end

    test "lists nothing for the same document" do
      assert Processes.diff(default(), default()) == []
    end

    test "lists a rename, an added stage and a removed stage" do
      added = %{
        "id" => "st_0123456789",
        "name" => "Review",
        "sequence" => [],
        "gate" => %{"kind" => "none"}
      }

      newer = rename(@shape, "Plan") |> without("st_m1mqbeywdg")
      newer = %{newer | "stages" => newer["stages"] ++ [added]}

      assert Processes.diff(default(), newer) == [
               {:stage_renamed, @shape, %{from: "Shape", to: "Plan"}},
               {:stage_added, "st_0123456789", %{name: "Review", position: 4}},
               {:stage_removed, "st_m1mqbeywdg", %{name: "Verify"}}
             ]
    end

    test "lists a move as the one stage that moved, not every stage it passed" do
      [explore, shape, build, verify, release] = default()["stages"]
      newer = %{default() | "stages" => [explore, shape, verify, release, build]}

      assert Processes.diff(default(), newer) ==
               [{:stage_moved, "st_6ns22c4pav", %{from: 2, to: 4}}]
    end

    test "lists a changed sequence, inputs, outputs, gate and machine" do
      sequence = [%{"workflow" => "write-specs"}]

      newer =
        default()
        |> Map.put("machine", "large")
        |> put_sequence(@shape, sequence)
        |> edit(fn
          %{"id" => @shape} = stage ->
            %{
              stage
              | "inputs" => [%{"type" => "proposal", "required" => true}],
                "outputs" => [%{"type" => "explainer", "required" => false}],
                "gate" => %{"kind" => "none"}
            }

          stage ->
            stage
        end)

      assert [
               {:machine_changed, nil, %{from: "default", to: "large"}},
               {:sequence_changed, @shape, %{from: [], to: ^sequence}},
               {:inputs_changed, @shape, _},
               {:outputs_changed, @shape, _},
               {:gate_changed, @shape, %{to: %{"kind" => "none"}}}
             ] = Processes.diff(default(), newer)
    end
  end

  describe "placement_check/3" do
    @types ~w(proposal explainer change acceptance-criteria)

    test "lists nothing for the default process, with explore-a-ticket declared" do
      assert Processes.placement_check(default(), ["explore-a-ticket"], @types) == []
    end

    test "lists a workflow the harness does not declare, once per stage" do
      document =
        put_sequence(default(), @shape, [
          %{"workflow" => "write-specs"},
          %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "write-specs"}]}}
        ])

      assert Processes.placement_check(document, ["explore-a-ticket"], @types) ==
               [{:missing_workflow, @shape, "write-specs"}]

      assert Processes.placement_check(document, [], @types) == [
               {:missing_workflow, @explore, "explore-a-ticket"},
               {:missing_workflow, @shape, "write-specs"}
             ]
    end

    test "lists a type the workspace does not have, and an input no earlier stage outputs" do
      document =
        edit(fn
          %{"id" => @shape} = stage ->
            %{
              stage
              | "inputs" => [
                  %{"type" => "proposal", "required" => true},
                  %{"type" => "acceptance-criteria", "required" => false}
                ],
                "outputs" => [%{"type" => "spec-sheet", "required" => true}]
            }

          stage ->
            stage
        end)

      assert Processes.placement_check(document, ["explore-a-ticket"], @types) == [
               {:missing_type, @shape, "spec-sheet"},
               {:input_not_output, @shape, "acceptance-criteria"}
             ]
    end

    test "lists a required output no workflow writes only where every workflow declares what it writes" do
      document =
        default()
        |> put_sequence(@shape, [%{"workflow" => "write-specs"}])
        |> edit(fn
          %{"id" => @shape} = stage ->
            %{stage | "outputs" => [%{"type" => "explainer", "required" => true}]}

          stage ->
            stage
        end)

      any = %{name: "write-specs", writes: nil}
      some = %{name: "write-specs", writes: ["change"]}
      explore = %{name: "explore-a-ticket", writes: nil}

      assert Processes.placement_check(document, [explore, any], @types) == []

      assert Processes.placement_check(document, [explore, some], @types) ==
               [{:output_not_written, @shape, "explainer"}]
    end
  end

  describe "the first version" do
    test "a new organisation's workspace has version 1, its type's default, with no author" do
      %{scope: scope} = sign_up_fixture()

      assert [version] = Processes.list_versions(scope.workspace)

      assert %Version{number: 1, status: :current, author_id: nil, based_on_id: nil} = version
      assert version.document == default()
      assert version.template == %{"type" => "qory.software", "version" => 1}
      assert version.public_id =~ ~r/\Apv_[0-9a-hjkmnp-tv-z]{16}\z/
      assert Processes.current(scope.workspace).id == version.id
    end

    test "a workspace made of a kind has version 1 too" do
      attrs = %{email: Apiary.AccountsFixtures.unique_user_email(), organisation_name: "Acme"}

      {:ok, %{user: user}} =
        Organisations.sign_up_user(attrs, nil, open: true, workspace: false)

      scope = Organisations.load_scope(Apiary.Accounts.Scope.for_user(user))

      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(scope, Apiary.Lingo.Domain.Software, :first)

      assert [%Version{number: 1, status: :current, author_id: nil}] =
               Processes.list_versions(workspace)
    end

    test "a workspace with no version gets version 1 when it is first read" do
      %{scope: scope} = sign_up_fixture()
      workspace = workspace_fixture(scope.organisation)
      assert Processes.list_versions(workspace) == []

      version = Processes.current(workspace)
      assert %Version{number: 1, status: :current, author_id: nil} = version
      assert Processes.current(workspace).id == version.id
      assert Processes.list_versions(workspace) == [version]
    end

    test "get_version!/1 finds a version by its id and by its public id" do
      %{scope: scope} = sign_up_fixture()
      version = Processes.current(scope.workspace)

      assert Processes.get_version!(version.id).id == version.id
      assert Processes.get_version!(version.public_id).id == version.id
      assert_raise Ecto.NoResultsError, fn -> Processes.get_version!(Ecto.UUID.generate()) end
    end

    test "version_for/1 is the work item's version, else the workspace's current one" do
      %{scope: scope} = sign_up_fixture()
      work_item = work_item_fixture(scope)
      current = Processes.current(scope.workspace)

      assert Processes.version_for(work_item).id == current.id

      other = version!(current, 2, :past)
      work_item = Repo.update!(Ecto.Changeset.change(work_item, process_version_id: other.id))
      assert Processes.version_for(work_item).id == other.id
    end
  end

  describe "the workflows a workspace declares" do
    test "are explore-a-ticket and the workflow saved on the Workflow page, with its access" do
      %{scope: scope} = sign_up_fixture()
      assert Processes.declared_workflows(scope.workspace) == ["explore-a-ticket"]

      {:ok, _row} =
        Stacks.put_stack(
          scope,
          {:workspace, scope.workspace, "implement"},
          "extends: {git: https://code.example.com/team/stacks, ref: main}\n",
          access: :write
        )

      assert Processes.declared_workflows(scope.workspace) == ["explore-a-ticket", "implement"]

      assert Processes.workflow_declaration(scope.workspace, "implement") ==
               %{name: "implement", access: :write, time_limit: nil, reads: nil, writes: nil}

      assert Processes.workflow_declaration(scope.workspace, "explore-a-ticket") ==
               %{name: "explore-a-ticket", access: nil, time_limit: nil, reads: nil, writes: nil}

      assert Processes.workflow_declaration(scope.workspace, "capture-demo") == nil
    end
  end

  describe "a change, with the feature on" do
    @describetag needs: :workflow_model

    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: scope, first: Processes.current(scope.workspace)}
    end

    test "a save is the new current version, and the one before is past", %{
      scope: scope,
      first: first
    } do
      assert {:ok, version} = Processes.save(scope, scope.workspace, rename(@shape, "Plan"))

      assert %Version{number: 2, status: :current, based_on_id: based_on, template: nil} = version
      assert based_on == first.id
      assert version.author_id == scope.user.id
      assert Repo.reload!(first).status == :past
      assert Processes.current(scope.workspace).id == version.id
      assert Enum.map(Processes.list_versions(scope.workspace), & &1.number) == [2, 1]

      assert [entry] = entries(scope.organisation.id)
      assert {entry.subject_kind, entry.subject_id} == {"workspace", scope.workspace.id}

      assert entry.details == %{
               "change" => "save",
               "version_id" => version.public_id,
               "number" => 2,
               "based_on" => 1
             }
    end

    test "a save keeps the fields the schema does not list, and gives a new stage its id", %{
      scope: scope
    } do
      new = %{"name" => "Review", "sequence" => [], "gate" => %{"kind" => "none"}}
      document = Map.put(default(), "layout", %{"zoom" => 2})
      document = %{document | "stages" => document["stages"] ++ [new]}

      assert {:ok, version} = Processes.save(scope, scope.workspace, document)
      assert version.document["layout"] == %{"zoom" => 2}
      assert [_, _, _, _, _, %{"id" => id, "name" => "Review"}] = version.document["stages"]
      assert id =~ ~r/\Ast_[0-9a-hjkmnp-tv-z]{10}\z/
    end

    test "a save keeps a workflow the harness does not declare", %{scope: scope} do
      document = put_sequence(default(), @shape, [%{"workflow" => "write-specs"}])
      assert {:ok, version} = Processes.save(scope, scope.workspace, document)

      assert Processes.placement_check(version, Processes.declared_workflows(scope.workspace), [
               "proposal"
             ]) ==
               [{:missing_workflow, @shape, "write-specs"}]
    end

    test "a save refuses an invalid document and an unchanged one, and leaves no version", %{
      scope: scope
    } do
      assert {:error, [%{error: :schema} | _]} =
               Processes.save(scope, scope.workspace, %{default() | "stages" => []})

      assert {:error, [%{error: :unchanged}]} = Processes.save(scope, scope.workspace, default())
      assert length(Processes.list_versions(scope.workspace)) == 1
      assert entries(scope.organisation.id) == []
    end

    test "a member may not save, nor anyone of another organisation", %{scope: scope} do
      %{scope: member} = member_fixture(scope, :member)

      assert Processes.save(member, member.workspace, rename(@shape, "Plan")) ==
               {:error, :forbidden}

      %{scope: other} = sign_up_fixture()

      assert Processes.save(other, scope.workspace, rename(@shape, "Plan")) ==
               {:error, :not_found}

      assert length(Processes.list_versions(scope.workspace)) == 1
    end

    test "a workspace has at most one current version", %{scope: scope, first: first} do
      for name <- ~w(Plan Design Specify) do
        {:ok, _} = Processes.save(scope, scope.workspace, rename(@shape, name))
      end

      {:ok, _trial} = Processes.save(scope, scope.workspace, rename(@shape, "Try"), trial: true)

      statuses = Enum.map(Processes.list_versions(scope.workspace), & &1.status)
      assert Enum.count(statuses, &(&1 == :current)) == 1

      assert_raise Ecto.ConstraintError, fn ->
        version!(first, 9, :current)
      end
    end

    test "a trial lives beside the current version until it is made current", %{
      scope: scope,
      first: first
    } do
      work_item = work_item_fixture(scope)
      other = work_item_fixture(scope)

      assert {:ok, trial} =
               Processes.save(scope, scope.workspace, rename(@shape, "Plan"), trial: true)

      assert trial.status == :trial
      assert Processes.current(scope.workspace).id == first.id

      assert {:ok, assigned} = Processes.assign(scope, work_item, trial)
      assert assigned.process_version_id == trial.id
      assert Processes.version_for(other).id == first.id

      assert {:ok, current} = Processes.make_current(scope, trial)
      assert current.status == :current
      assert Repo.reload!(first).status == :past
      assert Repo.reload!(work_item).process_version_id == trial.id
      assert Processes.make_current(scope, current) == {:error, :not_trial}

      assert Enum.map(entries(scope.organisation.id), & &1.details["change"]) ==
               ["save_trial", "assign", "make_current"]

      assert List.last(entries(scope.organisation.id)).details["replaced"] == 1
    end

    test "dropping a trial moves its work items back to the current version", %{
      scope: scope,
      first: first
    } do
      work_item = work_item_fixture(scope)
      {:ok, trial} = Processes.save(scope, scope.workspace, rename(@shape, "Plan"), trial: true)
      {:ok, _} = Processes.assign(scope, work_item, trial)

      assert {:ok, dropped} = Processes.drop_trial(scope, trial)
      assert dropped.status == :dropped
      assert Repo.reload!(work_item).process_version_id == first.id
      assert Processes.drop_trial(scope, dropped) == {:error, :not_trial}
      assert Processes.assign(scope, work_item, dropped) == {:error, :dropped}

      assert %{"change" => "drop_trial", "moved" => 1} =
               List.last(entries(scope.organisation.id)).details
    end

    test "a trial whose work item is in a stage the current version lacks is not dropped", %{
      scope: scope
    } do
      review = %{
        "id" => "st_0123456789",
        "name" => "Review",
        "sequence" => [],
        "gate" => %{"kind" => "none"}
      }

      document = %{default() | "stages" => default()["stages"] ++ [review]}
      {:ok, trial} = Processes.save(scope, scope.workspace, document, trial: true)

      work_item =
        Repo.update!(
          Ecto.Changeset.change(work_item_fixture(scope),
            process_version_id: trial.id,
            stage_id: "st_0123456789",
            stage_state: :at_gate
          )
        )

      assert Processes.drop_trial(scope, trial) == {:error, {:missing_stage, "st_0123456789"}}
      assert Repo.reload!(trial).status == :trial
      assert Repo.reload!(work_item).process_version_id == trial.id
    end

    test "a work item is assigned only to a version that has its stage", %{
      scope: scope,
      first: first
    } do
      work_item =
        Repo.update!(
          Ecto.Changeset.change(work_item_fixture(scope),
            process_version_id: first.id,
            stage_id: @shape,
            stage_state: :at_gate,
            stage_round: 0
          )
        )

      {:ok, trial} = Processes.save(scope, scope.workspace, without(@shape), trial: true)

      assert Processes.assign(scope, work_item, trial) == {:error, {:missing_stage, @shape}}
      assert Repo.reload!(work_item).process_version_id == first.id

      {:ok, kept} = Processes.save(scope, scope.workspace, rename(@shape, "Plan"), trial: true)

      assert {:ok, %WorkItem{stage_id: @shape, stage_state: :at_gate}} =
               Processes.assign(scope, work_item, kept)

      [entry] = Enum.filter(entries(scope.organisation.id), &(&1.subject_kind == "work_item"))
      assert entry.subject_id == work_item.id
      assert entry.before == %{"process_version" => 1}
      assert entry.after == %{"process_version" => 3}
    end

    test "a member may not assign a work item, nor make a trial current, nor drop it", %{
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      {:ok, trial} = Processes.save(scope, scope.workspace, rename(@shape, "Plan"), trial: true)
      %{scope: member} = member_fixture(scope, :member)

      assert Processes.assign(member, work_item, trial) == {:error, :forbidden}
      assert Processes.make_current(member, trial) == {:error, :forbidden}
      assert Processes.drop_trial(member, trial) == {:error, :forbidden}
      assert Repo.reload!(trial).status == :trial
    end
  end
end
