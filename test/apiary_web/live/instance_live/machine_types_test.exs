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
  import Ecto.Query, only: [from: 2]
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

  # A git address as the page shows it: no scheme, no trailing slash, no `.git`.
  defp repository(git),
    do:
      git
      |> String.replace(~r{\A[a-z][a-z0-9+.-]*://}, "")
      |> String.trim_trailing("/")
      |> String.replace_suffix(".git", "")

  # The text of `selector` with a space between elements: LazyHTML.text/1 leaves out a
  # text node of whitespace alone, such as the one between a name and its key.
  defp spaced(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> String.replace(~r/>\s*</, "> <")
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  defp names, do: Enum.map(MachineTypes.list(), &{&1.key, &1.is_default})

  defp add(view, params) do
    view
    |> form("#machine-type-form",
      type:
        Map.merge(
          %{
            name: "Large",
            key: "large",
            vcpus: "4",
            memory_gib: "16",
            disk_gib: "60",
            arch: "amd64"
          },
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

    test "lists the seeded default with its key, mark, spec, image, workflows and pools", %{
      conn: conn,
      scope: scope
    } do
      pool = pool_fixture(scope, %{name: "build-pool"})
      {:ok, view, html} = live(conn, ~p"/instance/machine-types")

      assert html =~ ~r{<title[^>]*>\s*Machine types · Instance settings · Qory Apiary\s*</title>}

      assert spaced(view, "#machine-type-standard") =~
               "Standard standard Default 2 vCPUs, 4 GiB 30 GiB disk, amd64 Not set"

      assert has_element?(view, "th", "Spec")
      assert has_element?(view, "th", "Image")
      refute has_element?(view, "th", "vCPUs")

      image = "ghcr.io/qoryai/qory-agent-browser@sha256:" <> String.duplicate("0", 64)

      browser_type()
      |> Ecto.Changeset.change(virtualization: true, image: image)
      |> Apiary.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types")

      assert spaced(view, "#machine-type-browser") =~
               "Browser tests browser 2 vCPUs, 4 GiB 30 GiB disk, amd64, virtualization " <>
                 "qory-agent-browser sha256:000000000000"

      assert has_element?(view, ~s(#machine-type-browser-image[title="#{image}"]))

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

      form = text(view, "#machine-type-form")

      assert form =~
               "Name What people see when they pick a type, such as Browser tests. You can change it at any time."

      assert form =~
               "Key Process files and stages use the key, such as browser. Lowercase letters, digits and hyphens, starting with a letter, at most 64."

      assert form =~
               "Image (optional) The image a run on this type starts in, pinned by digest, such as ghcr.io/qoryai/qory-agent-prerelease@sha256:… Leave it empty to start runs in the repository's prebuilt image, else in the default type's image, else in the run machine's image."

      assert has_element?(view, ~s(#type_image[placeholder="registry/name@sha256:…"]))

      add(view, %{key: "default"})

      assert text(view, "#machine-type-form") =~
               "Choose another key: default means the default type."

      add(view, %{key: "Large"})

      assert text(view, "#machine-type-form") =~
               "Use lowercase letters, digits and hyphens, starting with a letter, at most 64."

      add(view, %{key: "standard"})
      assert text(view, "#machine-type-form") =~ "Choose another key: standard exists."

      add(view, %{name: "standard"})
      assert text(view, "#machine-type-form") =~ "Choose another name: standard exists."

      for name <- ["", "Tab\there"] do
        add(view, %{name: name})

        assert text(view, "#machine-type-form") =~
                 "Write a name of 1 to 100 characters on one line, with no tabs."
      end

      add(view, %{image: "ghcr.io/qoryai/agent:latest"})

      assert text(view, "#machine-type-form") =~
               "Write a reference pinned by digest, such as ghcr.io/qoryai/qory-agent-prerelease@sha256: and 64 hexadecimal digits."

      add(view, %{image: "", vcpus: "four", memory_gib: "0.3", disk_gib: "0"})
      form = text(view, "#machine-type-form")
      assert form =~ "Write a whole number from 1 to 1024."
      assert form =~ "Write a number from 0.5 to 8192, in steps of 1 MiB."

      add(view, %{disk_gib: "0"})
      assert text(view, "#machine-type-form") =~ "Write a whole number from 1 to 65536."
      assert names() == [{"standard", true}, {"browser", false}]

      add(view, %{memory_gib: "1.5", virtualization: "true"})
      assert_patch(view, ~p"/instance/machine-types")
      assert text(view, "#flash-info") =~ "Large added."

      assert spaced(view, "#machine-type-large") =~
               "Large large 4 vCPUs, 1.5 GiB 60 GiB disk, amd64, virtualization Not set 0 workflows"

      assert %MachineType{memory_mib: 1536, virtualization: true, is_default: false} =
               MachineTypes.get("large")
    end

    test "refuses a type no pool fits while a pool has offers", %{conn: conn, scope: scope} do
      scope |> pool_fixture() |> with_offers([spec(%{vcpus: 2})])
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/new")

      add(view, %{})
      assert text(view, "#machine-type-form") =~ "No pool offers a machine that fits this type."
      assert names() == [{"standard", true}, {"browser", false}]
    end

    test "edits a type's name, image and spec, and makes it the default", %{conn: conn} do
      machine_type_fixture(key: "large")
      image = "ghcr.io/qoryai/qory-agent-prerelease@sha256:" <> String.duplicate("c", 64)
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/edit")

      # Instance settings / Machine types / Edit Large, the section once.
      assert text(view, "#breadcrumb") == "Instance settings/Machine types/Edit Large"
      assert has_element?(view, "#breadcrumb a[href='/instance/machine-types']", "Machine types")

      assert has_element?(view, ~s(#machine-type-form input[name="type[name]"][value="Large"]))
      assert has_element?(view, ~s(#machine-type-form input[name="type[memory_gib]"][value="16"]))

      view
      |> form("#machine-type-form",
        type: %{name: "Large builds", image: image, vcpus: "8", is_default: "true"}
      )
      |> render_submit()

      assert_patch(view, ~p"/instance/machine-types")
      assert text(view, "#flash-info") =~ "Large builds saved."
      assert names() == [{"standard", false}, {"browser", false}, {"large", true}]

      assert %MachineType{name: "Large builds", image: ^image, vcpus: 8} =
               MachineTypes.get("large")

      # A type with no image, as Standard is, becomes the default too.
      view
      |> element(~s(#machine-type-standard-menu [phx-click="make_default"]))
      |> render_click()

      assert text(view, "#flash-info") =~ "Standard is the default."
      assert names() == [{"standard", true}, {"browser", false}, {"large", false}]
    end

    test "warns before a key change, with the counts and the files, then keeps the files", %{
      conn: conn,
      scope: scope
    } do
      # The type Browser tests (`browser`) is seeded.
      %Processes.Version{number: 1} = version = Processes.current(scope.workspace)

      document =
        put_in(
          version.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      {1, _rows} =
        Apiary.Repo.update_all(
          from(v in Processes.Version, where: v.id == ^version.id),
          set: [
            document: document,
            template: %{
              "source" => "qory",
              "git" => Apiary.Harnesses.Qory.git(),
              "commit" => Apiary.QoryHarnessFixture.commit(),
              "module" => "software-factory"
            }
          ]
        )

      # The Qory harness's file, by the path its kept files resolve.
      file =
        "#{repository(Apiary.Harnesses.Qory.git())} modules/software-factory/process.yaml " <>
          "at #{String.slice(Apiary.QoryHarnessFixture.commit(), 0, 7)}"

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/browser/edit")

      assert text(view, "#machine-type-form") =~
               "Key Process files and stages use the key. If you change it, Qory Apiary lists the files that use it before it saves."

      view |> form("#machine-type-form", type: %{key: "ui-tests"}) |> render_submit()

      assert spaced(view, "#machine-type-key-warning") ==
               "Changing the key breaks every file that uses browser. Qory Apiary updates 1 workspace, 0 workspace types, 0 waiting runs. Fix these files yourself: " <>
                 file <> " Change key Saving Cancel"

      refute has_element?(view, "#machine-type-form button[type=submit]")
      assert MachineTypes.get("browser")

      # Cancel takes the warning away and saves nothing.
      view |> element("#machine-type-cancel-key") |> render_click()
      refute has_element?(view, "#machine-type-key-warning")
      assert MachineTypes.get("browser")

      view |> form("#machine-type-form", type: %{key: "ui-tests"}) |> render_submit()
      view |> element("#machine-type-change-key") |> render_click()
      assert_patch(view, ~p"/instance/machine-types")

      assert spaced(view, "#machine-type-key-saved") ==
               "Browser tests saved. Its key is now ui-tests. Fix the file that still uses browser. " <>
                 file

      assert text(view, "#machine-type-ui-tests-key") == "ui-tests"
      assert MachineTypes.get("browser") == nil

      # The message stays through other changes on the page, until it is dismissed.
      view |> element(~s(#machine-type-standard-menu a[href$="/delete"])) |> render_click()
      assert has_element?(view, "#machine-type-key-saved")

      view
      |> element(~s(#machine-type-key-saved button[phx-click="dismiss_key_saved"]))
      |> render_click()

      refute has_element?(view, "#machine-type-key-saved")
    end

    test "a key change that no file uses saves after the warning, with a toast", %{conn: conn} do
      # The type Browser tests (`browser`) is seeded.
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/browser/edit")

      view |> form("#machine-type-form", type: %{key: "Bad key"}) |> render_submit()
      refute has_element?(view, "#machine-type-key-warning")

      assert text(view, "#machine-type-form") =~
               "Use lowercase letters, digits and hyphens, starting with a letter, at most 64."

      view |> form("#machine-type-form", type: %{key: "ui-tests"}) |> render_submit()

      assert text(view, "#machine-type-key-warning") ==
               "Changing the key breaks every file that uses browser. Qory Apiary updates 0 workspaces, 0 workspace types, 0 waiting runs. Change key Saving Cancel"

      # A change of the key in the form takes the warning away.
      view |> form("#machine-type-form", type: %{key: "ui-test"}) |> render_change()
      refute has_element?(view, "#machine-type-key-warning")

      view |> form("#machine-type-form", type: %{key: "ui-tests"}) |> render_submit()
      view |> element("#machine-type-change-key") |> render_click()
      assert_patch(view, ~p"/instance/machine-types")
      assert spaced(view, "#flash-info") =~ "Browser tests saved. Its key is now ui-tests."
      refute has_element?(view, "#machine-type-key-saved")
    end

    @tag needs: :workflow_model
    test "a key change that meets a save of a workspace type saves nothing, with a message",
         %{conn: conn, scope: scope} do
      newest = Apiary.Processes.TypeTemplates.newest("qory.software")

      typed =
        put_in(
          newest.document,
          ["stages", Access.at(0), "sequence", Access.at(0), "machine"],
          "browser"
        )

      {:ok, _typed} = Apiary.Processes.TypeTemplates.save(scope, "qory.software", typed)

      # The rekeyed version of the workspace type meets the unique number of a version
      # saved at the same moment. The trigger is created in the test's transaction and
      # rolled back with it.
      Apiary.Repo.query!("""
      CREATE FUNCTION number_taken_for_test() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE unique_violation USING CONSTRAINT = 'type_template_versions_type_number_index';
      END $$
      """)

      Apiary.Repo.query!("""
      CREATE TRIGGER number_taken BEFORE INSERT ON type_template_versions
      FOR EACH ROW EXECUTE FUNCTION number_taken_for_test()
      """)

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/browser/edit")
      view |> form("#machine-type-form", type: %{key: "ui-tests"}) |> render_submit()
      view |> element("#machine-type-change-key") |> render_click()

      assert spaced(view, "#flash-error") =~
               "Change the key again. A workspace type was saved at the same moment, so the key change was not saved."

      assert has_element?(view, "#machine-type-form")
      refute has_element?(view, "#machine-type-key-warning")
      assert MachineTypes.get("browser")
      refute MachineTypes.get("ui-tests")
    end

    test "deletes a type after the confirmation in its row", %{conn: conn} do
      machine_type_fixture(key: "large")
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")

      assert text(view, "#machine-type-large-confirm") =~
               "Delete Large? Workflows can no longer pick this type. You cannot undo this."

      view |> element("#machine-type-delete") |> render_click()
      assert_patch(view, ~p"/instance/machine-types")
      assert text(view, "#flash-info") =~ "Large deleted."
      assert names() == [{"standard", true}, {"browser", false}]
    end

    test "keeps the default, and a type a workflow uses, with the reason under the table", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/standard/delete")
      view |> element("#machine-type-delete") |> render_click()

      assert text(view, "#machine-type-refused") ==
               "Standard cannot be deleted: it is the default. Make another type the default first."

      machine_type_fixture(key: "large")

      if Apiary.Features.on?(:workflow_model) do
        document = Map.put(Processes.default_document("software"), "machine", "large")
        {:ok, _version} = Processes.save(signed(scope), scope.workspace, document)

        {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")
        view |> element("#machine-type-delete") |> render_click()

        assert text(view, "#machine-type-refused") ==
                 "Large cannot be deleted: 1 workflow in 1 organisation uses it."

        assert MachineTypes.get("large")
      end
    end

    @tag needs: :workflow_model
    test "a key change across two organisations shows counts and files, no names or addresses",
         %{conn: conn, scope: scope} do
      # The type Browser tests (`browser`) is seeded. Acme's workspace runs a copy of the
      # Qory harness's file, and a trial from Acme's harness; Northwind's workspace runs
      # two files of Northwind's harness, and a run waits on the key.
      %{scope: other} = Apiary.OrganisationsFixtures.sign_up_fixture()
      named!(scope, "Acme", "Checkout")
      named!(other, "Northwind", "Storefront")

      qory = %{
        "source" => "qory",
        "git" => Apiary.Harnesses.Qory.git(),
        "commit" => Apiary.QoryHarnessFixture.commit(),
        "module" => "software-factory"
      }

      document = harness_version!(scope, :current, qory)
      harness_version!(scope, :trial, harness("acme", "web"))
      harness_version!(other, :current, harness("northwind", "web"))
      harness_version!(other, :trial, harness("northwind", "api"))

      newest = Apiary.Processes.TypeTemplates.newest("qory.software")
      typed = with_machine(newest.document, "browser")
      {:ok, _typed} = Apiary.Processes.TypeTemplates.save(scope, "qory.software", typed)

      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, run} = Apiary.Repo.transact(fn -> Apiary.Dispatches.queue(work_item, 1) end)

      Apiary.Repo.update_all(from(r in Apiary.Dispatches.DispatchRun, where: r.id == ^run.id),
        set: [machine_type: "browser", machine_spec: spec(), machine_type_was_default: false]
      )

      file =
        "#{repository(Apiary.Harnesses.Qory.git())} modules/software-factory/process.yaml " <>
          "at #{String.slice(Apiary.QoryHarnessFixture.commit(), 0, 7)}"

      organisations =
        "Organisations fix the files in their harnesses: " <>
          "1 file in Acme's harness 2 files in Northwind's harness"

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/browser/edit")
      view |> form("#machine-type-form", type: %{key: "ui-tests"}) |> render_submit()

      warning = spaced(view, "#machine-type-key-warning")

      assert warning ==
               "Changing the key breaks every file that uses browser. Qory Apiary updates 2 workspaces, 1 workspace type, 1 waiting run. Fix these files yourself: " <>
                 file <> " " <> organisations <> " Change key Saving Cancel"

      workflow = get_in(document, ["stages", Access.at(0), "sequence", Access.at(0), "workflow"])

      for hidden <- ["Checkout", "Storefront", workflow, "git.example.com", "acme/", "northwind/"],
          do: refute(warning =~ hidden, hidden)

      view |> element("#machine-type-change-key") |> render_click()
      assert_patch(view, ~p"/instance/machine-types")

      saved = spaced(view, "#machine-type-key-saved")

      assert saved ==
               "Browser tests saved. Its key is now ui-tests. Fix the file that still uses browser. " <>
                 file <> " " <> organisations

      for hidden <- ["Checkout", "Storefront", workflow, "git.example.com", "acme/", "northwind/"],
          do: refute(saved =~ hidden, hidden)
    end

    test "a key change that only organisations' files use, and the message after it", %{
      conn: conn,
      scope: scope
    } do
      # The type Browser tests (`browser`) is seeded.
      named!(scope, "Acme", "Checkout")
      harness_version!(scope, :current, harness("acme", "web"))

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/browser/edit")
      view |> form("#machine-type-form", type: %{key: "ui-tests"}) |> render_submit()

      assert spaced(view, "#machine-type-key-warning") ==
               "Changing the key breaks every file that uses browser. Qory Apiary updates 1 workspace, 0 workspace types, 0 waiting runs. " <>
                 "Organisations fix the files in their harnesses: 1 file in Acme's harness Change key Saving Cancel"

      view |> element("#machine-type-change-key") |> render_click()
      assert_patch(view, ~p"/instance/machine-types")

      assert spaced(view, "#machine-type-key-saved") ==
               "Browser tests saved. Its key is now ui-tests. " <>
                 "Organisations fix the files in their harnesses: 1 file in Acme's harness"
    end

    test "keeps a type that a workspace has as its default machine type", %{
      conn: conn,
      scope: scope
    } do
      machine_type_fixture(key: "large")
      default_machine!(scope, "large")

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")
      view |> element("#machine-type-delete") |> render_click()

      assert text(view, "#machine-type-refused") ==
               "Large cannot be deleted: 1 workspace in 1 organisation has it as its default machine type."
    end

    @tag needs: :workflow_model
    test "keeps a type that workflows, a workspace's default and a workspace type use", %{
      conn: conn,
      scope: scope
    } do
      machine_type_fixture(key: "large")
      %{scope: other} = Apiary.OrganisationsFixtures.sign_up_fixture()
      version = Processes.current(scope.workspace)

      {1, _rows} =
        Apiary.Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
          set: [document: with_machine(version.document, "large")]
        )

      default_machine!(other, "large")
      newest = Apiary.Processes.TypeTemplates.newest("qory.software")
      typed = with_machine(newest.document, "large")
      {:ok, _typed} = Apiary.Processes.TypeTemplates.save(scope, "qory.software", typed)
      type = Apiary.Processes.type_text_defaults("qory.software").name

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")
      view |> element("#machine-type-delete") |> render_click()

      assert text(view, "#machine-type-refused") ==
               "Large cannot be deleted: 1 workflow in 1 organisation uses it, " <>
                 "1 workspace in 1 organisation has it as its default machine type, " <>
                 "and the workspace type #{type} uses it."
    end

    @tag needs: :workflow_model
    test "keeps a type that only a workspace type uses", %{conn: conn, scope: scope} do
      machine_type_fixture(key: "large")
      newest = Apiary.Processes.TypeTemplates.newest("qory.software")
      typed = with_machine(newest.document, "large")
      {:ok, _typed} = Apiary.Processes.TypeTemplates.save(scope, "qory.software", typed)
      type = Apiary.Processes.type_text_defaults("qory.software").name

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")
      view |> element("#machine-type-delete") |> render_click()

      assert text(view, "#machine-type-refused") ==
               "Large cannot be deleted: the workspace type #{type} uses it."
    end

    @tag needs: :workflow_model
    test "keeps a type that workflows in two organisations and a workspace type use", %{
      conn: conn,
      scope: scope
    } do
      machine_type_fixture(key: "large")
      %{scope: other} = Apiary.OrganisationsFixtures.sign_up_fixture()
      named!(scope, "Acme", "Checkout")
      named!(other, "Northwind", "Storefront")

      for workspace_scope <- [scope, other] do
        version = Processes.current(workspace_scope.workspace)

        {1, _rows} =
          Apiary.Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
            set: [document: with_machine(version.document, "large")]
          )
      end

      newest = Apiary.Processes.TypeTemplates.newest("qory.software")
      typed = with_machine(newest.document, "large")
      {:ok, _typed} = Apiary.Processes.TypeTemplates.save(scope, "qory.software", typed)
      type = Apiary.Processes.type_text_defaults("qory.software").name

      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/large/delete")
      view |> element("#machine-type-delete") |> render_click()

      refused = text(view, "#machine-type-refused")

      assert refused ==
               "Large cannot be deleted: 2 workflows in 2 organisations use it, and the workspace type #{type} uses it."

      for hidden <- ["Checkout", "Storefront", "Acme", "Northwind"],
          do: refute(refused =~ hidden, hidden)

      assert MachineTypes.get("large")
    end

    test "asks for a recent sign-in before a change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/new")
      old = DateTime.add(DateTime.utc_now(:second), -21, :minute)

      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.current_scope.user.authenticated_at, old)
      end)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = add(view, %{})
      assert assert_redirect(view, ~p"/users/log-in") == %{"error" => @sudo}
      assert names() == [{"standard", true}, {"browser", false}]
    end
  end

  defp signed(scope), do: put_in(scope.user.authenticated_at, DateTime.utc_now())

  # The organisation and the workspace of `scope` renamed, so that a test can look for the
  # names in a page.
  defp named!(scope, organisation, workspace) do
    {1, _rows} =
      Apiary.Repo.update_all(
        from(o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id),
        set: [name: organisation]
      )

    {1, _rows} =
      Apiary.Repo.update_all(
        from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
        set: [name: workspace]
      )

    :ok
  end

  # The template of a version read from the harness repository of `owner` at `module`.
  defp harness(owner, module),
    do: %{
      "source" => "repository",
      "git" => "https://git.example.com/#{owner}/factory-harness.git",
      "commit" => "3c9e1a7" <> String.duplicate("0", 33),
      "module" => module
    }

  # The workspace's current version with `key` as its default and every workflow on the
  # type `standard`: the document alone uses `key`.
  defp default_machine!(scope, key) do
    version = Processes.current(scope.workspace)

    stages =
      Enum.map(version.document["stages"], fn stage ->
        Map.update(stage, "sequence", [], fn sequence ->
          Enum.map(sequence, &Map.put(&1, "machine", "standard"))
        end)
      end)

    document = %{version.document | "stages" => stages} |> Map.put("machine", key)

    {1, _rows} =
      Apiary.Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
        set: [document: document]
      )

    :ok
  end

  defp with_machine(document, key),
    do: put_in(document, ["stages", Access.at(0), "sequence", Access.at(0), "machine"], key)

  # The workspace's current version as read from `template`, with the first workflow on
  # the type `browser`, or a new trial as read from `template`, with `browser` as its
  # default; its document.
  defp harness_version!(scope, :current, template) do
    version = Processes.current(scope.workspace)
    document = with_machine(version.document, "browser")

    {1, _rows} =
      Apiary.Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
        set: [document: document, template: template]
      )

    document
  end

  defp harness_version!(scope, :trial, template) do
    document =
      scope.workspace
      |> Processes.current()
      |> Map.fetch!(:document)
      |> Map.put("machine", "browser")

    {:ok, trial} = Processes.save(signed(scope), scope.workspace, document, trial: true)

    {1, _rows} =
      Apiary.Repo.update_all(from(v in Processes.Version, where: v.id == ^trial.id),
        set: [template: template]
      )

    document
  end

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
