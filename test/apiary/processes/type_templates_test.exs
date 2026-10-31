defmodule Apiary.Processes.TypeTemplatesTest do
  # The default process of each workspace type: version 1 from the release's default, a
  # later release's default, an instance admin's saves and what refuses one, its entry in
  # the instance's trail, and the copy a new workspace makes of the newest version.
  #
  # Not async: a save keeps the type's advisory lock until the test's transaction ends.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Processes, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Processes.{TypeTemplate, TypeTemplates}

  @type_key "qory.software"
  @explore "st_r79kph11eg"

  defp default, do: Processes.default_document("software")

  defp renamed(document \\ default(), name) do
    [explore | rest] = document["stages"]
    %{document | "stages" => [%{explore | "name" => name} | rest]}
  end

  # A fresh instance admin, by a release command, with their organisation: their scope.
  defp instance_admin do
    %{scope: scope, user: user} = sign_up_fixture()
    {:ok, _} = Organisations.grant_instance_admin(user)
    scope
  end

  defp rows(type), do: Repo.all(from t in TypeTemplate, where: t.type == ^type)

  describe "newest/1" do
    test "is version 1, the release's default with no author, inserted once" do
      Repo.delete_all(from t in TypeTemplate, where: t.type == ^@type_key)

      assert %TypeTemplate{number: 1, release: 1, author: nil, based_on: nil} =
               first = TypeTemplates.newest(@type_key)

      assert first.document == default()
      assert TypeTemplates.newest(@type_key).id == first.id
      assert [_one] = rows(@type_key)
    end

    test "is nil for a key no type has, with no versions" do
      assert TypeTemplates.newest("qory.nothing") == nil
      assert TypeTemplates.versions("qory.nothing") == []
      assert TypeTemplates.version("qory.nothing", 1) == nil
      assert rows("qory.nothing") == []
    end

    @tag needs: :workflow_model
    test "adds a later release's default while no instance admin has saved" do
      assert %{number: 1, release: 1} = TypeTemplates.newest(@type_key)

      assert %TypeTemplate{number: 2, release: 2, author: nil, document: document} =
               TypeTemplates.newest(@type_key, 2)

      assert document == default()
      assert TypeTemplates.newest(@type_key).number == 2

      {:ok, saved} =
        TypeTemplates.save(instance_admin(), @type_key, renamed("Understand"), based_on: 2)

      assert TypeTemplates.newest(@type_key, 3).id == saved.id
      assert [3, 2, 1] = Enum.map(TypeTemplates.versions(@type_key), & &1.number)
    end
  end

  describe "list/0" do
    test "has every type with its name and newest version" do
      list = TypeTemplates.list()
      assert Enum.map(list, & &1.type) == ["qory.software", "qory.example"]

      assert %{name: "Software factory", newest: %TypeTemplate{number: 1, release: 1}} =
               Enum.find(list, &(&1.type == @type_key))
    end
  end

  describe "save/4" do
    @describetag needs: :workflow_model

    test "makes the newest version, with its author, and an entry in the instance's trail" do
      admin = instance_admin()
      document = renamed("Understand")

      assert {:ok, %TypeTemplate{} = version} =
               TypeTemplates.save(admin, @type_key, document, based_on: 1)

      assert %{number: 2, based_on: 1, release: nil, document: ^document} = version
      assert version.author.id == admin.user.id
      assert TypeTemplates.newest(@type_key).id == version.id
      assert [2, 1] = Enum.map(TypeTemplates.versions(@type_key), & &1.number)
      assert TypeTemplates.version(@type_key, 2).id == version.id
      assert TypeTemplates.may_edit?(admin)

      instance = Apiary.Edition.instance_organisation_id()

      assert %Entry{organisation_id: ^instance, details: details} =
               Repo.one!(from e in Entry, where: e.action == "workspace_type.edit")

      assert %{"change" => "save", "type" => @type_key, "number" => 2, "based_on" => 1} =
               details
    end

    test "is stale when a version newer than the one it started from exists" do
      admin = instance_admin()
      first = TypeTemplates.newest(@type_key)

      assert {:ok, %{number: 2}} =
               TypeTemplates.save(admin, @type_key, renamed("Understand"), based_on: first)

      assert {:error, :stale} =
               TypeTemplates.save(admin, @type_key, renamed("Learn"), based_on: first)

      assert {:error, :stale} =
               TypeTemplates.save(admin, @type_key, renamed("Learn"), based_on: 7)

      assert {:ok, %{number: 3, based_on: 2}} =
               TypeTemplates.save(admin, @type_key, renamed("Learn"))
    end

    test "is forbidden to anyone but an instance admin, and writes nothing" do
      %{scope: owner} = sign_up_fixture()
      before = rows(@type_key)

      assert {:error, :forbidden} =
               TypeTemplates.save(owner, @type_key, renamed("Understand"), based_on: 1)

      assert {:error, :forbidden} = TypeTemplates.save(nil, @type_key, renamed("Understand"))
      refute TypeTemplates.may_edit?(owner)
      refute TypeTemplates.may_edit?(nil)
      assert rows(@type_key) == before
      refute Repo.exists?(from e in Entry, where: e.action == "workspace_type.edit")
    end

    test "refuses a key no type has" do
      assert {:error, :unknown_type} =
               TypeTemplates.save(instance_admin(), "qory.nothing", default())
    end

    test "refuses a gate that lists people, and keeps a gate of none" do
      admin = instance_admin()

      [explore | rest] = default()["stages"]

      named = %{
        explore
        | "gate" => %{"kind" => "person", "approvers" => %{"members" => [admin.user.id]}}
      }

      assert {:error, [%{path: "#/stages/0/gate/approvers", error: :named_approvers}]} =
               TypeTemplates.save(admin, @type_key, %{default() | "stages" => [named | rest]})

      none = %{explore | "gate" => %{"kind" => "none"}}

      assert {:ok, %{number: 2}} =
               TypeTemplates.save(admin, @type_key, %{default() | "stages" => [none | rest]})
    end

    test "refuses what the schema refuses, and the newest version's document" do
      admin = instance_admin()

      assert {:error, errors} =
               TypeTemplates.save(admin, @type_key, %{default() | "schema" => "qory.process/v2"})

      assert Enum.any?(errors, &(&1.path == "#/schema" and &1.error == :schema))

      assert {:error, [%{path: "#", error: :unchanged}]} =
               TypeTemplates.save(admin, @type_key, default(), based_on: 1)

      assert [_one] = rows(@type_key)
    end

    test "gives a stage with no id a new one" do
      document = %{
        default()
        | "stages" =>
            default()["stages"] ++
              [
                %{
                  "name" => "Follow up",
                  "inputs" => [],
                  "sequence" => [],
                  "outputs" => [],
                  "gate" => %{"kind" => "none"}
                }
              ]
      }

      assert {:ok, %{document: %{"stages" => stages}}} =
               TypeTemplates.save(instance_admin(), @type_key, document)

      assert List.last(stages)["id"] =~ ~r/\Ast_[0-9a-hjkmnp-tv-z]{10}\z/
    end
  end

  describe "a new workspace" do
    @describetag needs: :workflow_model

    test "copies the newest version and keeps its type and number; an earlier one keeps its copy" do
      admin = instance_admin()
      earlier = Processes.current(admin.workspace)
      assert earlier.template == %{"type" => @type_key, "version" => 1}

      {:ok, _version} = TypeTemplates.save(admin, @type_key, renamed("Understand"), based_on: 1)

      # A sign-up creates its organisation's first workspace, which copies the newest version.
      %{workspace: workspace} = sign_up_fixture()

      copy = Processes.current(workspace)
      assert copy.template == %{"type" => @type_key, "version" => 2}
      assert Processes.stage(copy, @explore)["name"] == "Understand"
      assert Processes.template(Apiary.Lingo.Domain.Software)["version"] == 2

      assert Processes.stage(Processes.current(admin.workspace), @explore)["name"] == "Explore"
    end
  end

  describe "workflows/0 and artifact_types/0" do
    test "are the Qory harness's workflows and the ten standard types" do
      assert TypeTemplates.workflows() == ["explore-a-ticket"]
      assert length(TypeTemplates.artifact_types()) == 10
      assert %{name: "proposal", base_view: :structured} in TypeTemplates.artifact_types()
    end
  end
end

defmodule Apiary.Processes.TypeTemplatesFeatureOffTest do
  # Without the feature `workflow_model`, nobody saves a type's process.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Processes}
  alias Apiary.Processes.TypeTemplates

  @tag with_features: [:observability]
  test "an instance admin's save is forbidden" do
    %{scope: scope, user: user} = sign_up_fixture()
    {:ok, _} = Organisations.grant_instance_admin(user)

    refute TypeTemplates.may_edit?(scope)

    assert {:error, :forbidden} =
             TypeTemplates.save(scope, "qory.software", Processes.default_document("software"))
  end
end
