defmodule Apiary.ArtifactsTest do
  # Not async: the store's root is the application's setting.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, WorkItems}
  alias Apiary.Artifacts.{Artifact, ArtifactFile, Store, Type, Version}
  alias Apiary.ArtifactStoreHook
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Organisations.Workspace
  alias Apiary.WorkItems.WorkItem

  @moduletag :tmp_dir
  @moduletag needs: :workflow_model

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "store")
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, root)
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    scope = without_template_types(scope_fixture())
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item)
    %{root: root, scope: scope, work_item: work_item, run: run}
  end

  # A sign-up's workspace has the Qory template's types. These tests start from a workspace
  # with no list and no custom type, as one made before the template listed types.
  defp without_template_types(%{workspace: %{id: id}} = scope) do
    Repo.delete_all(from t in Type, where: t.workspace_id == ^id)
    Repo.update_all(from(w in Workspace, where: w.id == ^id), set: [shown_standard_types: nil])
    %{scope | workspace: Repo.get!(Workspace, id)}
  end

  # The audit entries of a change of a type, but the one of the sign-up's custom type.
  defp type_entries do
    Repo.all(from e in Entry, where: e.action == "artifact_type.edit")
    |> Enum.reject(&(&1.details["type"] == "branch"))
  end

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
  @gif "GIF89a" <> <<1, 0, 1, 0, 0, 0, 0>>
  @mp4 <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
  @webm <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0x82, 0x84, "webm">>
  @svg ~s(<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>)

  defp file(filename, bytes, content_type \\ "application/octet-stream"),
    do: %{filename: filename, content_type: content_type, binary: bytes}

  defp doc(filename \\ "notes.md", text \\ "# Notes\n\nThe gift card field."),
    do: file(filename, text, "text/markdown")

  defp json(filename, value), do: file(filename, Jason.encode!(value), "application/json")

  defp proposal, do: doc("proposal.md", "## What this is\n\nGift cards at the checkout.")

  defp stored_paths(root) do
    case File.ls(root) do
      {:ok, _names} -> Path.wildcard(Path.join(root, "*/*/*"))
      {:error, :enoent} -> []
    end
  end

  defp staging_files(root), do: Path.wildcard(Path.join(root, ".staging-*"), match_dot: true)

  defp count(schema), do: Repo.aggregate(schema, :count)

  describe "types/1 and type/2" do
    test "list the eleven standard types first, then the workspace's custom types by name", %{
      scope: scope
    } do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "demo-findings",
          "base_view" => "document"
        })

      names = Enum.map(Artifacts.types(scope.workspace), & &1.name)

      assert names ==
               ~w(acceptance-criteria explainer decision-record mockup screenshot demo-video
                  change proposal questions review-comments verdict demo-findings)
    end

    test "have the base views and dedicated views of the workflow model", %{scope: scope} do
      types = Map.new(Artifacts.types(scope.workspace), &{&1.name, &1})

      for name <- ~w(acceptance-criteria explainer decision-record proposal),
          do: assert(types[name].base_view == :document)

      assert types["proposal"].max_files == 10
      assert types["proposal"].size_limit == 5 * 1_048_576

      assert types["mockup"].base_view == :image
      assert types["screenshot"].base_view == :image
      assert types["demo-video"].base_view == :video

      for name <- ~w(change questions verdict) do
        assert types[name].base_view == :structured
        assert types[name].view == String.to_existing_atom(name)
        assert types[name].max_files == 1
      end

      assert Enum.all?(Type.standard(), & &1.standard)
    end

    test "find a type by name, and nothing for a name no type has", %{scope: scope} do
      assert %Type{name: "verdict", standard: true} = Artifacts.type(scope.workspace, "verdict")
      assert Artifacts.type(scope.workspace, "demo-findings") == nil
      assert Artifacts.type(scope.workspace, "Not A Name") == nil
      assert Artifacts.type(scope.workspace, 12) == nil
    end

    test "never return a custom type of another organisation's workspace", %{scope: scope} do
      other = scope_fixture()

      {:ok, _type} =
        Artifacts.create_type(other, other.workspace, %{"name" => "bids", "base_view" => "file"})

      assert Artifacts.type(scope.workspace, "bids") == nil
      refute "bids" in Enum.map(Artifacts.types(scope.workspace), & &1.name)
    end
  end

  # Sets the workspace's list in the database, for a list `switch_type/4` would not write.
  defp show!(%{id: id}, names) do
    {1, _rows} =
      Repo.update_all(from(w in Workspace, where: w.id == ^id),
        set: [shown_standard_types: names]
      )
  end

  defp names(types), do: Enum.map(types, & &1.name)

  describe "a workspace's shown standard types" do
    setup %{scope: scope} do
      {:ok, type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "demo-findings",
          "base_view" => "document"
        })

      %{custom: type}
    end

    test "with no list, every standard type is shown, marked as shown", %{scope: scope} do
      assert names(Artifacts.types(scope.workspace)) ==
               Type.standard_names() ++ ["demo-findings"]

      assert names(Artifacts.all_types(scope.workspace)) ==
               Type.standard_names() ++ ["demo-findings"]

      assert Enum.all?(Artifacts.all_types(scope.workspace), & &1.shown)
      assert %Type{name: "mockup"} = Artifacts.type(scope.workspace, "mockup")
    end

    test "with a list, only its types and the always-on types are shown", %{scope: scope} do
      show!(scope.workspace, ["mockup", "change"])

      assert names(Artifacts.types(scope.workspace)) ==
               ~w(mockup change proposal questions review-comments verdict demo-findings)

      assert %Type{name: "mockup"} = Artifacts.type(scope.workspace, "mockup")
      assert Artifacts.type(scope.workspace, "explainer") == nil
    end

    test "an empty list keeps the always-on types and the custom types", %{scope: scope} do
      show!(scope.workspace, [])

      assert names(Artifacts.types(scope.workspace)) ==
               ~w(proposal questions review-comments verdict demo-findings)

      for name <- Type.always_on() do
        assert %Type{name: ^name, standard: true} = Artifacts.type(scope.workspace, name)
      end

      assert %Type{name: "demo-findings"} = Artifacts.type(scope.workspace, "demo-findings")
    end

    test "all_types/1 lists every type, with whether each standard type is shown", %{
      scope: scope
    } do
      show!(scope.workspace, ["mockup"])
      types = Artifacts.all_types(scope.workspace)

      assert names(types) == Type.standard_names() ++ ["demo-findings"]

      assert for(%Type{standard: true, shown: true, name: name} <- types, do: name) ==
               ~w(mockup proposal questions review-comments verdict)
    end

    test "are read by the workspace's id, whatever the struct has", %{scope: scope} do
      unset = %Workspace{id: scope.workspace.id, organisation_id: scope.organisation.id}
      older = Repo.get!(Workspace, scope.workspace.id)
      assert older.shown_standard_types == nil

      show!(scope.workspace, ["mockup"])

      for workspace <- [unset, older] do
        assert workspace.shown_standard_types == nil
        assert Artifacts.type(workspace, "explainer") == nil
        refute "explainer" in names(Artifacts.types(workspace))

        assert %Type{name: "explainer", shown: false} =
                 Enum.find(Artifacts.all_types(workspace), &(&1.name == "explainer"))
      end
    end

    test "an always-on type or a custom type reads no list", %{scope: scope} do
      show!(scope.workspace, [])
      handler = "shown-types-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent, do: send(parent, {:query, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert %Type{} = Artifacts.type(scope.workspace, "verdict")
      assert %Type{} = Artifacts.type(scope.workspace, "demo-findings")
      refute_received {:query, "SELECT w0.\"shown_standard_types\"" <> _rest}

      assert Artifacts.type(scope.workspace, "explainer") == nil
      assert_received {:query, "SELECT w0.\"shown_standard_types\"" <> _rest}
    end

    test "a push of a hidden type is refused, and writes no row", ctx do
      show!(ctx.scope.workspace, ["mockup"])

      for actor <- [{:run, ctx.run}, {:person, ctx.scope}] do
        assert {:error, {:unknown_type, "explainer"}} =
                 Artifacts.push(actor, ctx.work_item, "explainer", [doc()])
      end

      assert count(Artifact) == 0
      assert count(Version) == 0
      assert stored_paths(ctx.root) == []
    end

    test "a type hidden between the push's read and its lock is refused, with no row", ctx do
      ArtifactStoreHook.on_commit(fn -> show!(ctx.scope.workspace, ["mockup"]) end)

      assert {:error, {:unknown_type, "explainer"}} =
               Artifacts.push({:run, ctx.run}, ctx.work_item, "explainer", [doc()])

      assert count(Artifact) == 0
      assert count(Version) == 0
    end

    test "a person's push of a type hidden before the lock writes no version or audit entry",
         ctx do
      ArtifactStoreHook.on_commit(fn -> show!(ctx.scope.workspace, ["mockup"]) end)

      assert {:error, {:unknown_type, "explainer"}} =
               Artifacts.push({:person, ctx.scope}, ctx.work_item, "explainer", [doc()])

      assert count(Version) == 0
      assert Repo.all(from e in Entry, where: e.action == "artifact.write") == []
    end

    test "a push goes on when the list changes before the lock and still has the type", ctx do
      show!(ctx.scope.workspace, ["explainer"])
      ArtifactStoreHook.on_commit(fn -> show!(ctx.scope.workspace, ["explainer", "mockup"]) end)

      assert {:ok, %Version{}} =
               Artifacts.push({:run, ctx.run}, ctx.work_item, "explainer", [doc()])

      assert Repo.get!(Workspace, ctx.scope.workspace.id).shown_standard_types ==
               ["explainer", "mockup"]
    end

    test "a push of an always-on type or a custom type does not depend on the list", ctx do
      show!(ctx.scope.workspace, [])

      assert {:ok, %Version{}} =
               Artifacts.push({:run, ctx.run}, ctx.work_item, "verdict", [
                 json("verdict.json", %{"verdict" => "passed"})
               ])

      assert {:ok, %Version{}} =
               Artifacts.push({:run, ctx.run}, ctx.work_item, "demo-findings", [doc()])
    end

    test "the Exists check is false for a hidden type", ctx do
      stage = "st_aaaaaaaaaa"

      {:ok, _version} =
        Artifacts.push({:run, ctx.run}, ctx.work_item, "explainer", [doc()], stage_id: stage)

      assert Artifacts.exists?(ctx.work_item, stage, "explainer")

      show!(ctx.scope.workspace, ["mockup"])
      refute Artifacts.exists?(ctx.work_item, stage, "explainer")
    end
  end

  describe "create_type/3" do
    @tag with_features: Apiary.Features.all() -- [:workflow_model]
    test "is not found with workflow_model off", %{scope: scope} do
      assert {:error, :not_found} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "demo-findings",
                 "base_view" => "document"
               })

      assert Artifacts.type(scope.workspace, "demo-findings") == nil
    end

    test "makes a custom type with the base view's defaults and an audit entry", %{scope: scope} do
      assert {:ok, %Type{} = type} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "demo-findings",
                 "base_view" => "document"
               })

      assert type.public_id =~ ~r/\Aat_[0-9a-hjkmnp-tv-z]{16}\z/
      assert type.size_limit == 1_048_576
      assert type.max_files == 1
      refute type.standard

      assert [%Entry{details: %{"change" => "create", "type" => "demo-findings"}}] =
               type_entries()
    end

    test "takes a structured type's schema as a map or as JSON text", %{scope: scope} do
      schema = %{"type" => "object", "properties" => %{"bid" => %{"type" => "number"}}}

      assert {:ok, %Type{json_schema: ^schema}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "structured",
                 "json_schema" => schema
               })

      assert {:ok, %Type{json_schema: ^schema}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids-two",
                 "base_view" => "structured",
                 "json_schema" => Jason.encode!(schema)
               })
    end

    test "refuses a member, who may not edit the types", %{scope: scope} do
      member = member_fixture(scope)

      assert {:error, :forbidden} =
               Artifacts.create_type(member.scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "file"
               })
    end

    test "refuses another organisation's workspace", %{scope: scope} do
      other = scope_fixture()

      assert {:error, :not_found} =
               Artifacts.create_type(scope, other.workspace, %{
                 "name" => "bids",
                 "base_view" => "file"
               })
    end

    test "refuses a standard name, a name of the wrong form and a name twice", %{scope: scope} do
      for name <- [
            "verdict",
            "Bids",
            "bids_2",
            "-bids",
            "bids-",
            "a--b",
            String.duplicate("a", 65)
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Artifacts.create_type(scope, scope.workspace, %{
                   "name" => name,
                   "base_view" => "file"
                 })

        assert changeset.errors[:name], "#{inspect(name)} is taken"
      end

      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{"name" => "bids", "base_view" => "file"})

      assert {:error, %Ecto.Changeset{errors: [name: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "file"
               })
    end

    test "refuses limits past the base view's bounds", %{scope: scope} do
      attrs = %{"name" => "bids", "base_view" => "document"}

      assert {:error, %{errors: [size_limit: _error]}} =
               Artifacts.create_type(
                 scope,
                 scope.workspace,
                 Map.put(attrs, "size_limit", 10_485_761)
               )

      assert {:error, %{errors: [max_files: _error]}} =
               Artifacts.create_type(scope, scope.workspace, Map.put(attrs, "max_files", 21))

      assert {:error, %{errors: [max_files: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "structured",
                 "json_schema" => %{"type" => "object"},
                 "max_files" => 2
               })
    end

    test "keeps a schema for a structured type alone", %{scope: scope} do
      assert {:error, %{errors: [json_schema: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "structured"
               })

      assert {:error, %{errors: [json_schema: _error]}} =
               Artifacts.create_type(scope, scope.workspace, %{
                 "name" => "bids",
                 "base_view" => "file",
                 "json_schema" => %{"type" => "object"}
               })
    end

    test "refuses a schema JSV cannot build, or that is over the bounds", %{scope: scope} do
      for schema <- [
            %{"type" => 5},
            %{"pattern" => "("},
            %{"enum" => Enum.to_list(1..1025)},
            "not JSON",
            [1, 2]
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Artifacts.create_type(scope, scope.workspace, %{
                   "name" => "bids",
                   "base_view" => "structured",
                   "json_schema" => schema
                 })

        assert changeset.errors[:json_schema], "#{inspect(schema)} is taken"
      end
    end
  end

  describe "update_type/3 and delete_type/2" do
    setup %{scope: scope} do
      {:ok, type} =
        Artifacts.create_type(scope, scope.workspace, %{"name" => "bids", "base_view" => "file"})

      %{type: type}
    end

    test "change the limits and keep the name and base view", %{scope: scope, type: type} do
      assert {:ok, updated} =
               Artifacts.update_type(scope, type, %{
                 "size_limit" => 2048,
                 "max_files" => 3,
                 "name" => "other",
                 "base_view" => "image"
               })

      assert {updated.size_limit, updated.max_files, updated.name, updated.base_view} ==
               {2048, 3, "bids", :file}
    end

    test "refuse a member", %{scope: scope, type: type} do
      member = member_fixture(scope)
      assert {:error, :forbidden} = Artifacts.update_type(member.scope, type, %{"max_files" => 2})
      assert {:error, :forbidden} = Artifacts.delete_type(member.scope, type)
    end

    test "delete a type no artifact has", %{scope: scope, type: type} do
      assert {:ok, _deleted} = Artifacts.delete_type(scope, type)
      assert Artifacts.type(scope.workspace, "bids") == nil
      assert {:error, :not_found} = Artifacts.delete_type(scope, type)
    end

    test "refuse to delete a type an artifact has",
         %{scope: scope, type: type, run: run} = context do
      {:ok, _version} =
        Artifacts.push({:run, run}, context.work_item, "bids", [file("bids.csv", "a,b")])

      assert {:error, :in_use} = Artifacts.delete_type(scope, type)
    end
  end

  describe "switch_type/4" do
    # The default process with `type` among the outputs, or the inputs, of its first stage.
    defp with_type(type, key \\ "outputs") do
      document = Processes.default_document("software")
      [first | rest] = document["stages"]
      first = Map.update!(first, key, &(&1 ++ [%{"type" => type, "required" => true}]))
      %{document | "stages" => [first | rest]}
    end

    # A past version that has `type`: `process_version_id` of a work item that keeps it.
    defp past_version(scope, type) do
      {:ok, version} = Processes.save(scope, scope.workspace, with_type(type))

      {:ok, _current} =
        Processes.save(scope, scope.workspace, Processes.default_document("software"))

      Repo.reload!(version)
    end

    defp keep!(%WorkItem{id: id}, version, fields \\ []) do
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^id),
          set: [process_version_id: version.id] ++ fields
        )
    end

    defp stored(scope), do: Repo.get!(Workspace, scope.workspace.id).shown_standard_types

    defp switches, do: type_entries()

    test "off stores the other names that can be hidden, in the standard order", ctx do
      assert {:ok, %Type{name: "mockup", shown: false}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "mockup", false)

      assert stored(ctx.scope) ==
               ~w(acceptance-criteria explainer decision-record screenshot demo-video change)

      assert Artifacts.type(ctx.scope.workspace, "mockup") == nil
      refute "mockup" in names(Artifacts.types(ctx.scope.workspace))
      refute Enum.find(Artifacts.all_types(ctx.scope.workspace), &(&1.name == "mockup")).shown
    end

    test "on adds the name back in the standard order", ctx do
      show!(ctx.scope.workspace, ~w(acceptance-criteria change))

      assert {:ok, %Type{name: "mockup", shown: true}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "mockup", true)

      assert stored(ctx.scope) == ~w(acceptance-criteria mockup change)
      assert %Type{name: "mockup"} = Artifacts.type(ctx.scope.workspace, "mockup")
    end

    test "stores no always-on name", ctx do
      show!(ctx.scope.workspace, ~w(mockup verdict))

      assert {:ok, %Type{}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", true)

      assert stored(ctx.scope) == ~w(explainer mockup)
    end

    test "a repeat of the state writes no row and no audit entry", ctx do
      before = Repo.get!(Workspace, ctx.scope.workspace.id)

      assert {:ok, %Type{shown: true}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "mockup", true)

      assert Repo.get!(Workspace, ctx.scope.workspace.id) == before

      {:ok, _version} = Artifacts.push({:run, ctx.run}, ctx.work_item, "explainer", [doc()])
      show!(ctx.scope.workspace, ["mockup"])

      assert {:ok, %Type{shown: false}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)

      assert stored(ctx.scope) == ["mockup"]
      assert switches() == []
    end

    test "writes an audit entry for each change, about the workspace", ctx do
      {:ok, _type} = Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "mockup", false)
      {:ok, _type} = Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "mockup", true)

      assert [
               %Entry{details: %{"change" => "hide", "type" => "mockup"}} = hidden,
               %Entry{details: %{"change" => "show", "type" => "mockup"}}
             ] = Enum.sort_by(switches(), & &1.details["change"])

      assert hidden.workspace_id == ctx.scope.workspace.id
    end

    test "fails for a type an artifact of the workspace has", ctx do
      {:ok, _version} = Artifacts.push({:run, ctx.run}, ctx.work_item, "explainer", [doc()])

      assert {:error, :has_artifacts} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)

      assert stored(ctx.scope) == nil
      assert switches() == []
    end

    test "checks the artifacts before the current process", ctx do
      {:ok, _version} = Artifacts.push({:run, ctx.run}, ctx.work_item, "explainer", [doc()])
      {:ok, _version} = Processes.save(ctx.scope, ctx.scope.workspace, with_type("explainer"))

      assert {:error, :has_artifacts} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "fails for a type a stage of the current process has", ctx do
      for {key, type} <- [{"outputs", "explainer"}, {"inputs", "mockup"}] do
        {:ok, _version} = Processes.save(ctx.scope, ctx.scope.workspace, with_type(type, key))

        assert {:error, :current_process} =
                 Artifacts.switch_type(ctx.scope, ctx.scope.workspace, type, false)
      end

      assert stored(ctx.scope) == nil
    end

    test "checks the current process before the versions in use", ctx do
      {:ok, _trial} =
        Processes.save(ctx.scope, ctx.scope.workspace, with_type("explainer"), trial: true)

      {:ok, _version} = Processes.save(ctx.scope, ctx.scope.workspace, with_type("explainer"))

      assert {:error, :current_process} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "fails for a type of a trial version", ctx do
      {:ok, _trial} =
        Processes.save(ctx.scope, ctx.scope.workspace, with_type("explainer"), trial: true)

      assert {:error, :version_in_use} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "fails for a type of a version a work item keeps", ctx do
      keep!(ctx.work_item, past_version(ctx.scope, "explainer"))

      assert {:error, :version_in_use} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "a past version no work item keeps does not count", ctx do
      past_version(ctx.scope, "explainer")

      assert {:ok, %Type{shown: false}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "a version only an ended work item keeps does not count", ctx do
      version = past_version(ctx.scope, "explainer")
      now = DateTime.utc_now()

      for state <- WorkItems.State.ended_states() do
        keep!(ctx.work_item, version,
          state: state,
          closed_at: if(state == :closed, do: now)
        )

        show!(ctx.scope.workspace, nil)

        assert {:ok, %Type{shown: false}} =
                 Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
      end
    end

    # A run of the work item's take in, in `state`, on `version`.
    defp run_on!(work_item, version, state) do
      %{dispatch_run: run} = explore_run_fixture(work_item, state: state)

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
          set: [process_version_id: version.id]
        )

      run
    end

    test "a closed work item counts only while a run on its version has not ended", ctx do
      version = past_version(ctx.scope, "explainer")
      keep!(ctx.work_item, version, state: :closed, closed_at: DateTime.utc_now())
      run = run_on!(ctx.work_item, version, :handed_over)

      assert {:error, :version_in_use} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert {:ok, %Type{shown: false}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "a claimed run that stayed on a version after an assign counts", ctx do
      version = past_version(ctx.scope, "explainer")
      keep!(ctx.work_item, version)
      run_on!(ctx.work_item, version, :claimed)

      assert {:ok, assigned} =
               Processes.assign(
                 ctx.scope,
                 Repo.reload!(ctx.work_item),
                 Processes.current(ctx.scope.workspace)
               )

      refute assigned.process_version_id == version.id

      assert {:error, :version_in_use} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "a work item taken in again leaves the version it kept", %{scope: scope} do
      version = past_version(scope, "explainer")
      ticket = backlog_ticket_fixture(scope, connection: ticket_connection_fixture(scope))
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      keep!(work_item, version)
      {:ok, _undone} = WorkItems.undo(scope, Repo.reload!(work_item))

      assert {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

      assert Repo.reload!(again).process_version_id == Processes.current(scope.workspace).id
    end

    test "a type in use can be switched off once nothing uses it", ctx do
      keep!(ctx.work_item, past_version(ctx.scope, "explainer"))

      assert {:error, :version_in_use} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)

      keep!(ctx.work_item, Processes.current(ctx.scope.workspace))

      assert {:ok, %Type{shown: false}} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "explainer", false)
    end

    test "an always-on type has no switch", ctx do
      for name <- ~w(proposal questions verdict), on? <- [true, false] do
        assert {:error, :always_on} =
                 Artifacts.switch_type(ctx.scope, ctx.scope.workspace, name, on?)
      end

      assert stored(ctx.scope) == nil
    end

    test "a name that is no standard type is not found", ctx do
      {:ok, _type} =
        Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
          "name" => "bids",
          "base_view" => "file"
        })

      for name <- ["bids", "no-such-type", 12, nil] do
        assert {:error, :not_found} =
                 Artifacts.switch_type(ctx.scope, ctx.scope.workspace, name, false)
      end
    end

    test "fails for a member and works for an admin", ctx do
      member = member_fixture(ctx.scope)
      admin = member_fixture(ctx.scope, :admin)

      assert {:error, :forbidden} =
               Artifacts.switch_type(member.scope, ctx.scope.workspace, "mockup", false)

      assert {:ok, %Type{}} =
               Artifacts.switch_type(admin.scope, ctx.scope.workspace, "mockup", false)
    end

    test "fails for a member with an always-on name too", ctx do
      member = member_fixture(ctx.scope)

      assert {:error, :forbidden} =
               Artifacts.switch_type(member.scope, ctx.scope.workspace, "verdict", false)
    end

    test "is not found for a workspace other than the scope's", ctx do
      other = without_template_types(scope_fixture())

      assert {:error, :not_found} =
               Artifacts.switch_type(ctx.scope, other.workspace, "mockup", false)

      assert Repo.get!(Workspace, other.workspace.id).shown_standard_types == nil
    end

    @tag with_features: Apiary.Features.all() -- [:workflow_model]
    test "is not found with workflow_model off", ctx do
      assert {:error, :not_found} =
               Artifacts.switch_type(ctx.scope, ctx.scope.workspace, "mockup", false)

      assert stored(ctx.scope) == nil
    end
  end

  # A question `id` the run of the queue `run` asks, open, as a run pushes it: `asked.run`
  # the number of its registered run.
  defp asked(run, id, text) do
    number = Repo.get_by!(Apiary.Runs.Run, dispatch_run_id: run.id).number

    %{
      "id" => id,
      "question" => text,
      "options" => [],
      "state" => "open",
      "asked" => %{"run" => number, "at" => "2026-11-04T10:00:00Z"}
    }
  end

  describe "push/5 by a run" do
    test "stores version 1 with the content type the bytes show",
         %{run: run, root: root} = context do
      assert {:ok, %Version{} = version} =
               Artifacts.push({:run, run}, context.work_item, "screenshot", [
                 file("checkout.png", @gif, "image/png")
               ])

      assert version.number == 1
      assert version.writer == :run
      assert version.run_id == run.id
      assert version.user_id == nil
      assert version.public_id =~ ~r/\Aav_[0-9a-hjkmnp-tv-z]{16}\z/
      assert %Artifact{type: "screenshot", name: "main"} = version.artifact
      assert version.artifact.public_id =~ ~r/\Aaf_[0-9a-hjkmnp-tv-z]{16}\z/

      sha256 = Base.encode16(:crypto.hash(:sha256, @gif), case: :lower)

      assert [
               %ArtifactFile{
                 filename: "checkout.png",
                 content_type: "image/gif",
                 size: 13,
                 sha256: ^sha256,
                 store_key: ^sha256
               }
             ] = version.files

      <<a::binary-size(2), b::binary-size(2), _rest::binary>> = sha256
      assert stored_paths(root) == [Path.join([root, a, b, sha256])]
      assert File.read!(Path.join([root, a, b, sha256])) == @gif
      assert staging_files(root) == []
    end

    test "numbers the versions of an artifact 1, 2, 3 and keeps names apart", context do
      %{run: run, work_item: work_item} = context

      for n <- 1..3 do
        assert {:ok, %Version{number: ^n}} =
                 Artifacts.push({:run, run}, work_item, "explainer", [doc("v#{n}.md")])
      end

      assert {:ok, %Version{number: 1}} =
               Artifacts.push({:run, run}, work_item, "explainer", [doc()], name: "design")

      assert %Version{number: 3, files: [%{filename: "v3.md"}]} =
               Artifacts.newest(work_item, "explainer")

      assert %Version{number: 1} = Artifacts.newest(work_item, "explainer", "design")
      assert Artifacts.newest(work_item, "mockup") == nil

      assert [%Artifact{name: "design"}, %Artifact{name: "main", versions: versions} = main] =
               Artifacts.list(work_item)

      assert Enum.map(versions, & &1.number) == [3, 2, 1]
      assert Enum.map(Artifacts.versions(main), & &1.number) == [3, 2, 1]
    end

    test "keeps the same content once in the store", %{run: run, root: root} = context do
      {:ok, one} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc("a.md")])

      {:ok, two} =
        Artifacts.push({:run, run}, context.work_item, "decision-record", [doc("b.md")])

      assert hd(one.files).store_key == hd(two.files).store_key
      assert length(stored_paths(root)) == 1
    end

    test "stores the stage and the note, the note trimmed", %{run: run} = context do
      assert {:ok, version} =
               Artifacts.push(
                 {:run, run},
                 context.work_item,
                 "verdict",
                 [json("verdict.json", %{"verdict" => "passed"})],
                 stage_id: "st_0123456789",
                 note: "  Round 2\r\nof 3  "
               )

      assert {version.stage_id, version.note, version.artifact.stage_id} ==
               {"st_0123456789", "Round 2\nof 3", "st_0123456789"}

      assert {:ok, %Version{note: nil}} =
               Artifacts.push(
                 {:run, run},
                 context.work_item,
                 "verdict",
                 [json("v.json", %{"verdict" => "passed"})],
                 note: " "
               )
    end

    test "writes no audit entry", %{run: run} = context do
      {:ok, _version} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc()])
      assert Repo.all(from e in Entry, where: e.action == "artifact.write") == []
    end

    test "refuses a run of another work item", %{scope: scope, run: run} do
      other = work_item_fixture(scope, %{external_ref: "acme/shop#13"})
      assert {:error, :not_found} = Artifacts.push({:run, run}, other, "explainer", [doc()])
      assert count(Artifact) == 0
    end

    test "stores every type the workspace shows, for a run", context do
      %{run: run, work_item: work_item} = context

      assert {:ok, _version} = Artifacts.push({:run, run}, work_item, "explainer", [doc()])

      assert {:ok, _version} =
               Artifacts.push({:run, run}, work_item, "mockup", [file("a.png", @png)])

      assert {:ok, _version} =
               Artifacts.push(
                 {:run, run},
                 work_item,
                 "verdict",
                 [json("v.json", %{"verdict" => "escalate", "gaps" => "No demo."})]
               )

      assert {:ok, _version} =
               Artifacts.push(
                 {:run, run},
                 work_item,
                 "questions",
                 [json("q.json", %{"questions" => [asked(run, "q1", "Which basket?")]})]
               )

      assert {:ok, _version} =
               Artifacts.push({:run, run}, work_item, "review-comments", [
                 json("r.json", %{"review_comments" => []})
               ])
    end

    test "refuses an unknown type and a type name of the wrong form", %{run: run} = context do
      assert {:error, {:unknown_type, "demo-findings"}} =
               Artifacts.push({:run, run}, context.work_item, "demo-findings", [doc()])

      assert {:error, {:invalid, :type}} =
               Artifacts.push({:run, run}, context.work_item, "../x", [doc()])

      assert {:error, {:invalid, :type}} =
               Artifacts.push({:run, run}, context.work_item, nil, [doc()])
    end

    test "refuses a name, a stage or a note of the wrong form", %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "explainer", [doc()], &1)

      assert {:error, {:invalid, :name}} = push.(name: "Main")
      assert {:error, {:invalid, :name}} = push.(name: "")
      assert {:error, {:invalid, :stage_id}} = push.(stage_id: "st x")
      assert {:error, {:invalid, :stage_id}} = push.(stage_id: String.duplicate("s", 65))
      assert {:error, {:invalid, :note}} = push.(note: "a\u0000b")
      assert {:error, {:invalid, :note}} = push.(note: "a\u202Eb")
      assert {:error, {:invalid, :note}} = push.(note: String.duplicate("n", 4001))
      assert {:error, {:invalid, :note}} = push.(note: <<0xFF>>)
      assert count(Artifact) == 0
    end

    test "counts a note's length in code points, as the database does", %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "explainer", [doc()], &1)

      # "e" and U+0301: one grapheme, two code points.
      accent = "e\u0301"
      assert {:error, {:invalid, :note}} = push.(note: String.duplicate(accent, 4000))
      assert {:ok, %Version{note: note}} = push.(note: String.duplicate(accent, 2000))
      assert String.length(note) == 2000
    end

    test "refuses no files, too many files and a file of the wrong shape",
         %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, &1, &2)

      assert {:error, {:invalid, :no_files}} = push.("explainer", [])
      assert {:error, {:too_many_files, 1}} = push.("explainer", [doc("a.md"), doc("b.md")])

      assert {:error, {:too_many_files, 10}} =
               push.("screenshot", for(n <- 1..11, do: file("#{n}.png", @png)))

      assert {:error, {:invalid, {:file, 0}}} = push.("explainer", [%{filename: "a.md"}])

      assert {:error, {:invalid, {:file, 0}}} =
               push.("explainer", [%{"filename" => "a.md", "binary" => "x"}])
    end

    test "refuses a filename that is not a base name, or that is there twice",
         %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "screenshot", &1)

      for name <- [
            "",
            ".",
            "..",
            "a/b.png",
            "../b.png",
            "a\\b.png",
            "a\u0000.png",
            "a\n.png",
            "gnp.\u202Eexe",
            <<0xFF, ".png">>,
            String.duplicate("a", 252) <> ".png",
            7
          ] do
        assert {:error, {:invalid, {:filename, 1}}} =
                 push.([file("ok.png", @png), file(name, @png)]),
               "#{inspect(name)} is taken"
      end

      assert {:error, {:invalid, {:duplicate_filename, 1}}} =
               push.([file("a.png", @png), file("a.png", @gif)])

      assert {:ok, _version} = push.([file(String.duplicate("a", 251) <> ".png", @png)])
    end

    test "refuses a version over the size limit, and keeps nothing of it",
         %{scope: scope, run: run, root: root} = context do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "bids",
          "base_view" => "file",
          "size_limit" => 100,
          "max_files" => 2
        })

      push = &Artifacts.push({:run, run}, context.work_item, "bids", &1)
      assert {:error, {:too_large, 100}} = push.([file("a.bin", :binary.copy("a", 101))])

      assert {:error, {:too_large, 100}} =
               push.([file("a.bin", :binary.copy("a", 60)), file("b.bin", :binary.copy("b", 41))])

      assert {:ok, _version} =
               push.([file("a.bin", :binary.copy("a", 60)), file("b.bin", :binary.copy("b", 40))])

      assert length(stored_paths(root)) == 2
      assert staging_files(root) == []
      assert count(Version) == 1
    end

    test "reads a file from a path, stops past the limit, and refuses a path it cannot read",
         context do
      %{scope: scope, run: run, root: root, tmp_dir: tmp_dir} = context

      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "bids",
          "base_view" => "file",
          "size_limit" => 200_000
        })

      small = Path.join(tmp_dir, "small.bin")
      File.write!(small, :binary.copy("s", 200_000))
      large = Path.join(tmp_dir, "large.bin")
      File.write!(large, :binary.copy("l", 200_001))

      push =
        &Artifacts.push({:run, run}, context.work_item, "bids", [%{filename: "f.bin", path: &1}])

      assert {:error, {:too_large, 200_000}} = push.(large)
      assert staging_files(root) == []
      assert {:error, {:invalid, {:unreadable, 0}}} = push.(Path.join(tmp_dir, "missing.bin"))
      assert {:ok, %Version{files: [%{size: 200_000}]}} = push.(small)
    end

    test "checks each file against its base view, and writes nothing on a refusal",
         %{run: run, root: root} = context do
      push = &Artifacts.push({:run, run}, context.work_item, &1, &2)

      assert {:error, {:invalid, {:extension, 0}}} = push.("explainer", [doc("notes.txt")])

      assert {:error, {:invalid, {:format, 0}}} =
               push.("explainer", [doc("notes.md", <<0xFF, 0xFE>>)])

      assert {:error, {:invalid, {:format, 0}}} =
               push.("explainer", [doc("notes.md", "a\u0000b")])

      assert {:error, {:invalid, {:format, 1}}} =
               push.("screenshot", [file("a.png", @png), file("b.png", "<html></html>")])

      assert {:error, {:invalid, {:format, 0}}} = push.("demo-video", [file("demo.mp4", @png)])

      assert {:error, {:invalid, :no_video}} =
               push.("demo-video", [file("en.vtt", "WEBVTT\n"), file("de.vtt", "WEBVTT\n")])

      assert {:error, {:invalid, {:schema, 0, %{path: "#/verdict", error: "value must be" <> _}}}} =
               push.("verdict", [json("v.json", %{"verdict" => "done"})])

      assert {:error, {:invalid, {:format, 0}}} = push.("verdict", [file("v.json", "{not json")])

      assert count(Artifact) == 0
      assert count(Version) == 0
      assert stored_paths(root) == []
      assert staging_files(root) == []
    end

    test "keeps the content type of each base view", %{run: run} = context do
      push = fn type, files ->
        {:ok, version} = Artifacts.push({:run, run}, context.work_item, type, files)
        Enum.map(version.files, & &1.content_type)
      end

      assert push.("explainer", [doc("Notes.MD")]) == ["text/markdown; charset=utf-8"]

      assert push.("mockup", [file("a.png", @png), file("b.svg", @svg), file("c.gif", @gif)]) ==
               ["image/png", "image/svg+xml", "image/gif"]

      assert push.("demo-video", [file("demo.mp4", @mp4)]) == ["video/mp4"]
      assert push.("demo-video", [file("demo.webm", @webm, "video/mp4")]) == ["video/webm"]

      assert push.("demo-video", [file("demo.mp4", @mp4), file("en.vtt", "WEBVTT\n")]) ==
               ["video/mp4", "text/vtt; charset=utf-8"]

      assert push.("proposal", [proposal()]) == ["text/markdown; charset=utf-8"]
    end

    test "takes the standard structured types' documents their schemas allow",
         %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, &1, [json("a.json", &2)])

      assert {:ok, _version} =
               push.("change", %{
                 "url" => "https://forge.example.com/acme/shop/pull/4",
                 "title" => "Gift cards"
               })

      assert {:ok, _version} = push.("change", %{"url" => "http://localhost:8080/changes/4"})

      for url <- [
            "ftp://forge.example.com/4",
            "javascript:alert(1)",
            "https://user@forge.example.com/",
            "https://",
            "https://forge.example.com/a b"
          ] do
        assert {:error, {:invalid, {:schema, 0, %{path: "#/url"}}}} =
                 push.("change", %{"url" => url}),
               "#{url} is taken"
      end

      assert {:error, {:invalid, {:schema, 0, %{path: "#", error: extra}}}} =
               push.("change", %{"url" => "https://a.example", "extra" => 1})

      assert extra =~ "'extra'"

      assert {:ok, _version} =
               push.("questions", %{
                 "questions" => [
                   Map.put(asked(run, "q1", "Which basket?"), "options", [
                     %{"title" => "The small one", "explanation" => "At checkout."}
                   ]),
                   asked(run, "q2", "Which sale?")
                 ]
               })

      # Each version the run pushes keeps the questions of the newest one.
      assert {:error, {:invalid, {:kept, 0, :id_dropped}}} =
               push.("questions", %{"questions" => []})

      # A question is a question with its options: a text alone, or the members a
      # questions document had before options, are refused.
      for document <- [
            %{"questions" => ["Which basket?"]},
            %{
              "questions" => [%{"question" => "Which basket?", "options" => []}],
              "understanding" => "A checkout change."
            }
          ] do
        assert {:error, {:invalid, {:schema, 0, _error}}} = push.("questions", document)
      end

      assert {:ok, _version} =
               push.("verdict", %{
                 "verdict" => "changes-requested",
                 "gaps" => "The demo has no second card."
               })

      assert {:error, {:invalid, {:schema, 0, %{path: "#/gaps"}}}} =
               push.("verdict", %{"verdict" => "passed", "gaps" => ""})
    end

    test "validates a custom structured type's document against its schema",
         %{scope: scope, run: run} = context do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "bids",
          "base_view" => "structured",
          "json_schema" => %{
            "type" => "object",
            "required" => ["bids"],
            "properties" => %{"bids" => %{"type" => "array", "items" => %{"type" => "number"}}}
          }
        })

      push = &Artifacts.push({:run, run}, context.work_item, "bids", [json("bids.json", &1)])
      assert {:ok, _version} = push.(%{"bids" => [1.5, 2]})

      assert {:error,
              {:invalid, {:schema, 0, %{path: "#/bids/0", error: "value is not of type number"}}}} =
               push.(%{"bids" => ["high"]})

      assert {:error, {:invalid, {:schema, 0, %{path: "#", error: "the document has more" <> _}}}} =
               push.(%{"bids" => Enum.to_list(1..10_001)})
    end
  end

  describe "push/5 of a proposal" do
    defp sources_json, do: json("sources.json", %{"sources" => []})

    test "stores one Markdown file with images and sources.json", %{run: run} = context do
      assert {:ok, version} =
               Artifacts.push({:run, run}, context.work_item, "proposal", [
                 proposal(),
                 file("checkout.svg", @svg),
                 file("cart.png", @png),
                 sources_json()
               ])

      assert Enum.map(version.files, &{&1.filename, &1.content_type}) == [
               {"cart.png", "image/png"},
               {"checkout.svg", "image/svg+xml"},
               {"proposal.md", "text/markdown; charset=utf-8"},
               {"sources.json", "application/json"}
             ]
    end

    test "refuses two Markdown files, none, or sources.json twice, and keeps nothing",
         %{run: run, root: root} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "proposal", &1)

      assert {:error, {:invalid, :one_markdown}} =
               push.([proposal(), doc("other.md"), file("cart.png", @png)])

      assert {:error, {:invalid, :one_markdown}} = push.([file("cart.png", @png)])
      assert {:error, {:invalid, :one_markdown}} = push.([sources_json()])

      assert {:error, {:invalid, {:duplicate_filename, 2}}} =
               push.([proposal(), sources_json(), sources_json()])

      assert stored_paths(root) == []
      assert staging_files(root) == []
      assert count(Version) == 0
    end

    test "refuses a file of the wrong format, an unsafe SVG, a large Markdown file and bad sources",
         %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "proposal", &1)

      assert {:error, {:invalid, {:extension, 1}}} = push.([proposal(), file("notes.txt", "a")])
      assert {:error, {:invalid, {:image_type, 1}}} = push.([proposal(), file("notes.png", "a")])

      unsafe = String.replace(@svg, "<rect ", ~s|<rect onclick="alert(1)" |)

      assert {:error, {:invalid, {{:svg_content, "the onclick attribute"}, 1}}} =
               push.([proposal(), file("checkout.svg", unsafe)])

      assert {:error, {:invalid, {:document_size, 0}}} =
               push.([doc("proposal.md", String.duplicate("a", 262_145))])

      assert {:error, {:invalid, {:schema, 1, %{path: "#", error: _error}}}} =
               push.([proposal(), json("sources.json", %{"items" => []})])

      assert count(Version) == 0
    end

    test "refuses more than 10 files and more than 5 MiB together", %{run: run} = context do
      push = &Artifacts.push({:run, run}, context.work_item, "proposal", &1)
      images = for n <- 1..9, do: file("#{n}.png", @png)

      assert {:ok, _version} = push.([proposal() | images])

      assert {:error, {:too_many_files, 10}} =
               push.([proposal(), file("10.png", @png) | images])

      large = @png <> :binary.copy("a", 2_700_000)

      assert {:error, {:too_large, 5_242_880}} =
               push.([proposal(), file("a.png", large), file("b.png", large)])
    end

    test "the Exists check passes a proposal with images and sources.json",
         %{run: run} = context do
      refute Artifacts.exists?(context.work_item, "st_explore", "proposal")

      {:ok, _version} =
        Artifacts.push(
          {:run, run},
          context.work_item,
          "proposal",
          [proposal(), file("checkout.svg", @svg), file("cart.png", @png), sources_json()],
          stage_id: "st_explore"
        )

      assert Artifacts.exists?(context.work_item, "st_explore", "proposal")
    end
  end

  describe "log_refusal/3" do
    import ExUnit.CaptureLog

    test "writes the refusal's shape, the work item and the type, and nothing of the files",
         context do
      changeset =
        %Version{}
        |> Ecto.Changeset.change(note: "secret note")
        |> Ecto.Changeset.add_error(:note, "is too long, secret")

      log =
        capture_log(fn ->
          Artifacts.log_refusal(context.work_item, "explainer", {:error, changeset})
          Artifacts.log_refusal(context.work_item, "<b>plan.md</b>", {:odd, "plan.md", [1, 2]})
          Artifacts.log_refusal(context.work_item, "explainer", {:error, ~c"plan.md"})
        end)

      assert log =~
               "A push from Add a version failed: " <>
                 "{:error, changeset of Apiary.Artifacts.Version, errors on note}; " <>
                 "work item #{context.work_item.public_id}, type explainer"

      assert log =~
               ~s(Add a version failed: {:odd, "…", […]}; ) <>
                 ~s(work item #{context.work_item.public_id}, type "…")

      # A charlist is a list: its characters are not written, as numbers or as text.
      assert log =~ "Add a version failed: {:error, […]}; work item"
      refute log =~ "[112"

      refute log =~ "secret"
      refute log =~ "plan.md"
    end
  end

  describe "push/5 by a person" do
    test "stores the person's version and an audit entry", %{scope: scope} = context do
      member = member_fixture(scope)

      assert {:ok, %Version{writer: :person, user_id: user_id, run_id: nil}} =
               Artifacts.push(
                 {:person, member.scope},
                 context.work_item,
                 "proposal",
                 [proposal()],
                 note: "Scope edited"
               )

      assert user_id == member.user.id

      assert [%Entry{subject_id: subject_id, details: %{"type" => "proposal", "number" => 1}}] =
               Repo.all(from e in Entry, where: e.action == "artifact.write")

      assert subject_id == context.work_item.id
    end

    test "is not found for a person of another organisation", context do
      other = scope_fixture()

      assert {:error, :not_found} =
               Artifacts.push({:person, other}, context.work_item, "explainer", [doc()])
    end

    @tag with_features: Apiary.Features.all() -- [:workflow_model]
    test "is not found with workflow_model off", %{scope: scope} = context do
      assert {:error, :not_found} =
               Artifacts.push({:person, scope}, context.work_item, "explainer", [doc()])

      assert Artifacts.list(context.work_item) == []
    end
  end

  describe "push/5 with expect_stage" do
    setup %{work_item: work_item} do
      %{work_item: in_stage(work_item, "st_bbbbbbbbbb")}
    end

    defp in_stage(work_item, stage_id) do
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_id: stage_id]
        )

      Repo.get!(WorkItem, work_item.id)
    end

    test "refuses a work item in another stage, with no row and no message",
         %{scope: scope, work_item: work_item, root: root} do
      :ok = Artifacts.subscribe(scope, work_item)

      assert {:error, :stage_changed} =
               Artifacts.push({:person, scope}, work_item, "explainer", [doc()],
                 stage_id: "st_aaaaaaaaaa",
                 expect_stage: "st_aaaaaaaaaa"
               )

      assert count(Artifact) == 0
      assert count(Version) == 0
      assert count(ArtifactFile) == 0
      assert Repo.all(from e in Entry, where: e.action == "artifact.write") == []
      refute_received {:artifact_pushed, _work_item_id, _version_id}

      # The transaction refuses after the store keeps the bytes, as every refusal there
      # does, and nothing deletes them.
      assert [_kept] = stored_paths(root)
    end

    test "stores the version in the same stage", %{scope: scope, work_item: work_item} do
      assert {:ok, %Version{stage_id: "st_bbbbbbbbbb"}} =
               Artifacts.push({:person, scope}, work_item, "explainer", [doc()],
                 stage_id: "st_bbbbbbbbbb",
                 expect_stage: "st_bbbbbbbbbb"
               )
    end

    test "compares nothing where the option is left out",
         %{scope: scope, work_item: work_item} do
      assert {:ok, %Version{stage_id: "st_aaaaaaaaaa"}} =
               Artifacts.push({:person, scope}, work_item, "explainer", [doc()],
                 stage_id: "st_aaaaaaaaaa"
               )
    end

    test "reads nil as a work item with no stage", %{scope: scope, work_item: work_item} do
      assert {:error, :stage_changed} =
               Artifacts.push({:person, scope}, work_item, "explainer", [doc()],
                 expect_stage: nil
               )

      assert {:ok, %Version{stage_id: nil}} =
               Artifacts.push(
                 {:person, scope},
                 in_stage(work_item, nil),
                 "explainer",
                 [doc()],
                 expect_stage: nil
               )
    end

    test "refuses a run's push too", %{work_item: work_item, run: run} do
      assert {:error, :stage_changed} =
               Artifacts.push(
                 {:run, run},
                 work_item,
                 "verdict",
                 [
                   json("verdict.json", %{"verdict" => "passed"})
                 ],
                 expect_stage: "st_aaaaaaaaaa"
               )
    end
  end

  describe "get_version!/1 and open_file/1" do
    test "find a version by its public id and open its stored copy", %{run: run} = context do
      {:ok, pushed} =
        Artifacts.push({:run, run}, context.work_item, "screenshot", [file("a.png", @png)])

      version = Artifacts.get_version!(pushed.public_id)
      assert version.id == pushed.id
      assert %Artifact{type: "screenshot"} = version.artifact
      assert [stored] = version.files
      assert {:ok, path} = Artifacts.open_file(stored)
      assert File.read!(path) == @png
    end

    test "raise for an id of no version" do
      assert_raise Ecto.NoResultsError, fn -> Artifacts.get_version!("av_0000000000000000") end
      assert_raise Ecto.NoResultsError, fn -> Artifacts.get_version!("../etc") end
    end

    test "refuse a store key that is not a digest" do
      assert {:error, :invalid_key} =
               Artifacts.open_file(%ArtifactFile{store_key: "../../etc/passwd"})

      assert {:error, :not_found} =
               Artifacts.open_file(%ArtifactFile{store_key: String.duplicate("a", 64)})
    end
  end

  describe "exists?/3" do
    test "is true for a version of the type made in the stage whose files pass",
         %{run: run} = context do
      %{work_item: work_item} = context
      refute Artifacts.exists?(work_item, "st_build", "demo-video")

      {:ok, _version} =
        Artifacts.push({:run, run}, work_item, "demo-video", [file("d.mp4", @mp4)],
          stage_id: "st_build",
          name: "first"
        )

      assert Artifacts.exists?(work_item, "st_build", "demo-video")
      refute Artifacts.exists?(work_item, "st_verify", "demo-video")
      refute Artifacts.exists?(work_item, "st_build", "mockup")
      refute Artifacts.exists?(work_item, "st_build", "demo-findings")
    end

    test "reads the content types kept at the push, and no stored file",
         %{run: run, root: root} = context do
      {:ok, version} =
        Artifacts.push({:run, run}, context.work_item, "demo-video", [file("d.mp4", @mp4)],
          stage_id: "st_build"
        )

      {:ok, path} = Store.Volume.path(hd(version.files).store_key)
      assert String.starts_with?(path, root)
      File.rm!(path)
      assert Artifacts.exists?(context.work_item, "st_build", "demo-video")

      Repo.update_all(from(f in ArtifactFile, where: f.version_id == ^version.id),
        set: [content_type: "image/png"]
      )

      refute Artifacts.exists?(context.work_item, "st_build", "demo-video")
    end
  end

  describe "after a push" do
    test "the work item's artifacts topic hears of the version", %{run: run} = context do
      work_item = context.work_item
      assert Artifacts.topic(work_item) == "artifacts:" <> work_item.id
      :ok = Artifacts.subscribe(context.scope, work_item)
      Phoenix.PubSub.subscribe(Apiary.PubSub, Apiary.WorkItems.topic(work_item.workspace_id))

      {:ok, version} = Artifacts.push({:run, run}, work_item, "explainer", [doc()])

      assert_receive {:artifact_pushed, work_item_id, version_id}
      assert {work_item_id, version_id} == {work_item.public_id, version.public_id}

      # The workspace's work items topic gets no message: its pages do not handle one.
      refute_receive {:artifact_pushed, _work_item_id, _version_id}

      assert {:error, {:invalid, :no_files}} =
               Artifacts.push({:run, run}, work_item, "explainer", [])

      refute_receive {:artifact_pushed, _work_item_id, _version_id}
    end

    test "a person who may not read the work item cannot subscribe", context do
      outsider = Apiary.AccountsFixtures.user_fixture()
      scope = %{context.scope | user: outsider}
      assert {:error, _reason} = Artifacts.subscribe(scope, context.work_item)
    end

    test "each version comes with who made it", %{run: run, scope: scope} = context do
      {:ok, by_run} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc()])
      {:ok, by_person} = Artifacts.push({:person, scope}, context.work_item, "explainer", [doc()])

      assert [%Artifact{versions: [person, from_run]}] = Artifacts.list(context.work_item)
      assert {person.user.id, person.run} == {scope.user.id, nil}
      assert {from_run.user, from_run.run.id} == {nil, run.id}

      assert Artifacts.get_version!(by_person.public_id).user.id == scope.user.id
      assert Artifacts.get_version!(by_run.public_id).run.id == run.id

      assert [_newer, %Version{run: %{id: run_id}}] =
               Artifacts.versions(person.artifact_id |> then(&%Artifact{id: &1}))

      assert run_id == run.id
      assert Artifacts.newest(context.work_item, "explainer").user.id == scope.user.id
    end
  end

  describe "the rows" do
    test "go with their work item", %{run: run} = context do
      {:ok, _version} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc()])
      Repo.delete!(context.work_item)
      assert {count(Artifact), count(Version), count(ArtifactFile)} == {0, 0, 0}
    end

    test "keep a run's version once its run of the queue goes", %{run: run} = context do
      {:ok, version} = Artifacts.push({:run, run}, context.work_item, "explainer", [doc()])
      Repo.delete_all(from r in Apiary.Runs.Run, where: r.dispatch_run_id == ^run.id)
      Repo.delete!(run)
      assert %Version{writer: :run, run_id: nil} = Repo.get!(Version, version.id)
    end
  end
end
