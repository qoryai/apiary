defmodule ApiaryWeb.InstanceLive.MachineTypesTest do
  # Instance settings › Machine types (`ApiaryWeb.InstanceLive.MachineTypes`): the section
  # in the Instance level's menu, the list with the default's mark, the workflows and the
  # pools of each type, Add machine type and its form, Edit, Make default, Delete…
  # confirmed in its row, the refusals under their fields and under the table, the
  # recent sign-in, and a path that does not exist for anyone but an instance admin. Not
  # async: a test of an instance admin hides the instance's organisation, a row every test
  # shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.MachineTypesFixtures
  import Apiary.NodesFixtures

  alias Apiary.{MachineTypes, Processes}
  alias Apiary.MachineTypes.MachineType

  @moduletag needs: :factory

  @sudo "You must re-authenticate to access this page."

  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  defp names, do: Enum.map(MachineTypes.list(), &{&1.name, &1.is_default})

  defp add(view, params) do
    view
    |> form("#machine-type-form",
      type:
        Map.merge(
          %{name: "large", vcpus: "4", memory_gib: "16", disk_gib: "60", arch: "amd64"},
          params
        )
    )
    |> render_submit()
  end

  describe "for an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "is a section of the Instance level, after Nodes", %{scope: scope} do
      keys = Enum.map(ApiaryWeb.Layouts.instance_sections(scope), & &1.key)
      assert [:nodes, :machine_types | _] = Enum.drop_while(keys, &(&1 != :nodes))

      assert %{label: "Machine types", path: "/instance/machine-types"} =
               Enum.find(
                 ApiaryWeb.Layouts.instance_sections(scope),
                 &(&1.key == :machine_types)
               )
    end

    test "lists the seeded default with its mark, its spec, its workflows and its pools", %{
      conn: conn,
      scope: scope
    } do
      pool = pool_fixture(scope, %{name: "build-pool"})
      {:ok, view, html} = live(conn, ~p"/instance/machine-types")

      assert html =~ ~r{<title[^>]*>\s*Machine types · Instance settings · Qory Apiary\s*</title>}

      assert text(view, "#machine-type-standard") =~
               "standard Default 2 4 GiB 30 GiB amd64 No"

      assert text(view, "#machine-type-standard-pools") == pool.name

      # A pool with offers serves the types its offers fit; the default is not one here.
      with_offers(pool, [spec(%{arch: "arm64"})])
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types")
      assert text(view, "#machine-type-standard-pools") == "None"
    end

    test "adds a type, refuses a bad field under it, and lists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types")
      view |> element("#machine-type-add") |> render_click()
      assert_patch(view, ~p"/instance/machine-types/new")

      add(view, %{name: "default"})

      assert text(view, "#machine-type-form") =~
               "Choose another name: default means the default type."

      add(view, %{name: "Large"})

      assert text(view, "#machine-type-form") =~
               "Use lowercase letters, digits and hyphens, starting with a letter, at most 64."

      add(view, %{name: "standard"})
      assert text(view, "#machine-type-form") =~ "Choose another name: standard exists."

      add(view, %{vcpus: "four", memory_gib: "0.3", disk_gib: "0"})
      form = text(view, "#machine-type-form")
      assert form =~ "Write a whole number from 1 to 1024."
      assert form =~ "Write a number from 0.5 to 8192, in steps of 1 MiB."

      add(view, %{disk_gib: "0"})
      assert text(view, "#machine-type-form") =~ "Write a whole number from 1 to 65536."
      assert names() == [{"standard", true}]

      add(view, %{memory_gib: "1.5", virtualization: "true"})
      assert_patch(view, ~p"/instance/machine-types")
      assert text(view, "#flash-info") =~ "large added."
      assert text(view, "#machine-type-large") =~ "large 4 1.5 GiB 60 GiB amd64 Yes 0 workflows"

      assert %MachineType{memory_mib: 1536, virtualization: true, is_default: false} =
               MachineTypes.get("large")
    end

    test "refuses a type no pool fits while a pool has offers", %{conn: conn, scope: scope} do
      scope |> pool_fixture() |> with_offers([spec(%{vcpus: 2})])
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/new")

      add(view, %{})
      assert text(view, "#machine-type-form") =~ "No pool offers a machine that fits this type."
      assert names() == [{"standard", true}]
    end

    test "edits a type's spec, without its name, and makes it the default", %{conn: conn} do
      machine_type_fixture(name: "large")
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/edit")

      refute has_element?(view, ~s(#machine-type-form input[name="type[name]"]))
      assert has_element?(view, ~s(#machine-type-form input[name="type[memory_gib]"][value="16"]))

      view
      |> form("#machine-type-form", type: %{vcpus: "8", is_default: "true"})
      |> render_submit()

      assert_patch(view, ~p"/instance/machine-types")
      assert text(view, "#flash-info") =~ "large saved."
      assert names() == [{"standard", false}, {"large", true}]
      assert MachineTypes.get("large").vcpus == 8

      view
      |> element(~s(#machine-type-standard-menu [phx-click="make_default"]))
      |> render_click()

      assert text(view, "#flash-info") =~ "standard is the default."
      assert names() == [{"standard", true}, {"large", false}]
      refute has_element?(view, ~s(#machine-type-standard-menu [phx-click="make_default"]))
    end

    test "deletes a type after the confirmation in its row", %{conn: conn} do
      machine_type_fixture(name: "large")
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")

      assert text(view, "#machine-type-large-confirm") =~
               "Delete large? Workflows can no longer pick this type. You cannot undo this."

      view |> element("#machine-type-delete") |> render_click()
      assert_patch(view, ~p"/instance/machine-types")
      assert text(view, "#flash-info") =~ "large deleted."
      assert names() == [{"standard", true}]
    end

    test "keeps the default, and a type a workflow uses, with the reason under the table", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/standard/delete")
      view |> element("#machine-type-delete") |> render_click()

      assert text(view, "#machine-type-refused") ==
               "standard cannot be deleted: it is the default. Make another type the default first."

      machine_type_fixture(name: "large")

      if Apiary.Features.on?(:workflow_model) do
        document = Map.put(Processes.default_document("software"), "machine", "large")
        {:ok, _version} = Processes.save(signed(scope), scope.workspace, document)

        {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")
        view |> element("#machine-type-delete") |> render_click()

        assert text(view, "#machine-type-refused") ==
                 "large cannot be deleted: these workflows use it: #{scope.workspace.name}: explore-a-ticket."

        assert MachineTypes.get("large")
      end
    end

    test "asks for a recent sign-in before a change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/new")
      old = DateTime.add(DateTime.utc_now(:second), -21, :minute)

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.current_scope.user.authenticated_at, old)
      end)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = add(view, %{})
      assert assert_redirect(view, ~p"/users/log-in") == %{"error" => @sudo}
      assert names() == [{"standard", true}]
    end
  end

  defp signed(scope), do: put_in(scope.user.authenticated_at, DateTime.utc_now())

  describe "for anyone else" do
    setup :register_and_log_in_user

    test "the page does not exist, and the menu does not offer it", %{conn: conn, scope: scope} do
      refute Apiary.Access.instance_admin?(scope)
      refute Enum.any?(ApiaryWeb.Layouts.instance_sections(scope), &(&1.key == :machine_types))

      for path <-
            ~w(/instance/machine-types /instance/machine-types/new /instance/machine-types/standard/edit) do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end
      end
    end
  end
end
