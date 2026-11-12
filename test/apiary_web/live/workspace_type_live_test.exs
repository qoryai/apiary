defmodule ApiaryWeb.WorkspaceTypeLiveTest do
  # A template's page (`ApiaryWeb.WorkspaceTypeLive`), where a card leads. The Qory
  # template: the newest version of the type's default process on the view-only canvas,
  # with the side panel's name, summary, How it works, Stages, the harness line and Create
  # workspace; How it works in the main area with `workflow_model` off; the texts from code
  # and the texts an instance admin saved; Create workspace and its Name step. A template
  # of a harness repository: the same page from the repository's `process.yaml`, with the
  # harness line and Create workspace, which makes the workspace from that template. A
  # key of no place that is listed, and the people New workspace is not for. Not async:
  # each test sets the instance's features, and some save a version of a type, which
  # every test reads.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Workspace}
  alias Apiary.Processes.TypeTemplates

  @moduletag with_features: Apiary.Features.all()

  # The feature factory and every feature that needs it, directly or through another.
  @needing_factory Enum.reduce(1..5, [:factory], fn _round, off ->
                     Enum.uniq(
                       off ++
                         for(
                           feature <- Apiary.Features.all(),
                           Enum.any?(Apiary.Features.needs(feature), &(&1 in off)),
                           do: feature
                         )
                     )
                   end)

  @summary "Agents change code in your repositories. Each ticket needs a repository."
  @stages "The workspace starts with the stages shown. After you create it, owners and admins can change them in Workspace settings › Workflows."

  setup do
    {:ok, %{user: user, organisation: organisation}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: "Acme"},
        nil,
        open: true,
        workspace: false
      )

    %{
      user: user,
      organisation: organisation,
      path: ~p"/#{organisation}/workspaces/new/qory.software"
    }
  end

  # A version 2 of the software type, saved by the instance's admin: Explore renamed, and
  # with `texts`.
  defp save_version_2!(texts) do
    newest = TypeTemplates.newest("qory.software")

    document =
      Map.update!(newest.document, "stages", fn [first | rest] ->
        [Map.put(first, "name", "Discover") | rest]
      end)

    {:ok, version} =
      TypeTemplates.save(instance_admin_scope(), "qory.software", document,
        based_on: newest.number,
        texts: texts
      )

    version
  end

  defp canvas_view(view) do
    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#workspace-type-canvas")
      |> LazyHTML.attribute("data-view")

    Jason.decode!(json)
  end

  @harness "https://code.example.com/acme/harness"

  # A connected repository, acme/harness, that exports the module support-desk, served by
  # a stub adapter: the context the template pages need.
  defp repository(user, organisation) do
    scope = Organisations.load_scope(Scope.for_user(user), organisation.id)
    adapter = Apiary.HarnessReadsFixtures.call_adapter_fixture()

    {connection, _nonce} =
      Apiary.NodesFixtures.connection_fixture(scope, adapter.adapter, :listed)

    Apiary.HarnessReadsFixtures.live_grant_fixture(
      organisation.id,
      adapter.adapter,
      connection,
      "G_acme"
    )

    collection =
      Apiary.HarnessReadsFixtures.harness_collection_fixture(connection, @harness, "acme/harness")

    covered = %{adapter.adapter.id => %{@harness => {"G_acme", "R_harness"}}}

    files =
      Apiary.HarnessReadsFixtures.repository_files("R_harness", %{
        "support-desk" => Apiary.HarnessReadsFixtures.support_desk_file()
      })

    Apiary.HarnessReadsFixtures.serve_calls([adapter], covered: covered, files: files)

    key = collection.public_id <> ".support-desk"

    %{
      adapter: adapter,
      covered: covered,
      collection: collection,
      template_path: ~p"/#{organisation}/workspaces/new/#{key}"
    }
  end

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  test "shows the newest stages on the view-only canvas, beside the type's texts", %{
    conn: conn,
    user: user,
    organisation: organisation,
    path: path
  } do
    save_version_2!(nil)
    {:ok, view, html} = conn |> log_in_user(user) |> live(path)

    assert html =~ ~r{<title[^>]*>\s*Software factory}

    # The canvas fills the window left of the side panel; its cards open nothing.
    assert has_element?(view, "#workspace-type.q-canvas-fill > #workspace-type-canvas")

    assert has_element?(
             view,
             ~s(#workspace-type-side.q-canvas-side[style="--q-canvas-side: 24rem"])
           )

    canvas = canvas_view(view)
    refute canvas["editable"]
    refute canvas["selectable"]
    assert hd(canvas["stages"])["name"] == "Discover"

    assert has_element?(view, "#workspace-type-side h1", "Software factory")
    assert has_element?(view, "#workspace-type-summary", @summary)

    assert texts(view, "#workspace-type-description p") == [
             "Each ticket comes from a work source, such as an issue tracker. Agents take the ticket through the stages, and at the end of each stage a member approves the result before the next stage starts. Changes go to your repositories through the destination you connect.",
             "You connect: where work comes from, where changes go, and a model."
           ]

    assert has_element?(view, "#workspace-type-stages h2", "Stages")
    assert has_element?(view, "#workspace-type-stages p", @stages)
    assert words(view, "#workspace-type-harness") == "Harness: Qory harness, stack software"

    assert has_element?(
             view,
             "#workspace-type-side button#workspace-type-create",
             "Create workspace"
           )

    # The breadcrumb: the organisation, New workspace, then the type's name.
    assert has_element?(view, ~s(#breadcrumb a[href="/#{organisation.slug}"]))

    assert has_element?(
             view,
             ~s(#breadcrumb a[href="/#{organisation.slug}/workspaces/new"]),
             "New workspace"
           )

    assert has_element?(view, "#breadcrumb [aria-current=page]", "Software factory")
  end

  test "a stage's description shows on its card; a stage without one shows none", %{
    conn: conn,
    user: user,
    path: path
  } do
    newest = TypeTemplates.newest("qory.software")
    text = "Turn the ticket into a plan for the storefront.\nA member approves the plan."

    document =
      Map.update!(newest.document, "stages", fn [explore, shape | rest] ->
        [explore, Map.put(shape, "description", text) | rest]
      end)

    {:ok, _version} =
      TypeTemplates.save(instance_admin_scope(), "qory.software", document,
        based_on: newest.number
      )

    {:ok, view, _html} = conn |> log_in_user(user) |> live(path)

    assert [explore, shape | rest] = canvas_view(view)["stages"]
    assert shape["name"] == "Shape"
    assert shape["description"] == text
    assert Enum.all?([explore | rest], &is_nil(&1["description"]))
  end

  test "shows the name, summary and description an instance admin saved", %{
    conn: conn,
    user: user,
    path: path
  } do
    save_version_2!(%{
      name: "Web shop factory",
      summary: "For the Web shop.",
      description: "Dana approves each stage.\n\nThe Web shop's tickets come from its tracker."
    })

    {:ok, view, _html} = conn |> log_in_user(user) |> live(path)

    assert has_element?(view, "#workspace-type-side h1", "Web shop factory")
    assert has_element?(view, "#breadcrumb [aria-current=page]", "Web shop factory")
    assert has_element?(view, "#workspace-type-summary", "For the Web shop.")

    assert texts(view, "#workspace-type-description p") == [
             "Dana approves each stage.",
             "The Web shop's tickets come from its tracker."
           ]
  end

  test "Create workspace creates Software factory and opens its Name step", %{
    conn: conn,
    user: user,
    organisation: organisation,
    path: path
  } do
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, path)

    {:ok, name, _html} =
      view |> element("#workspace-type-create") |> render_click() |> follow_redirect(conn)

    assert has_element?(name, "h1", "Name this workspace")

    assert [%Workspace{name: "Software factory", domain: "software"}] =
             Organisations.list_workspaces(
               Organisations.load_scope(Scope.for_user(user), organisation.id)
             )
  end

  test "a key of no type with a card is a path that does not exist", %{
    conn: conn,
    user: user,
    organisation: organisation
  } do
    conn = log_in_user(conn, user)

    # The tests' example domain is a type with no card.
    for key <- ["acme.none", "qory.example"] do
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ~p"/#{organisation}/workspaces/new/#{key}")
      end
    end
  end

  test "is New workspace's not-found page for a person workspace.create does not allow", %{
    conn: conn,
    organisation: organisation,
    path: path
  } do
    admin = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: admin.id}
    |> Membership.changeset(%{level: :admin})
    |> Repo.insert!()

    assert_raise ApiaryWeb.NotFound, fn -> conn |> log_in_user(admin) |> live(path) end
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "with workflow_model off, How it works takes the main area and there is no canvas", %{
    conn: conn,
    user: user,
    path: path
  } do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(path)

    refute has_element?(view, "#workspace-type-canvas")
    refute has_element?(view, "#workspace-type-stages")
    refute has_element?(view, "#workspace-type-description")
    assert has_element?(view, "#workspace-type > #workspace-type-how h2", "How it works")
    assert has_element?(view, "#workspace-type-how p", "You connect: where work comes from")
    assert has_element?(view, "#workspace-type-side h1", "Software factory")
    assert has_element?(view, "#workspace-type-summary", @summary)
    assert has_element?(view, "#workspace-type-create", "Create workspace")
  end

  describe "a template of a harness repository" do
    @describetag needs: :factory
    @describetag :capture_log

    setup %{user: user, organisation: organisation}, do: repository(user, organisation)

    defp template_file, do: Apiary.HarnessReadsFixtures.support_desk_file()

    defp serve(ctx, modules, opts \\ []) do
      files = Apiary.HarnessReadsFixtures.repository_files("R_harness", modules, opts)
      Apiary.HarnessReadsFixtures.serve_calls([ctx.adapter], covered: ctx.covered, files: files)
    end

    test "reads the repository, then shows the template on the canvas, with its harness line and Create workspace",
         %{conn: conn, user: user, template_path: path} do
      {:ok, view, html} = conn |> log_in_user(user) |> live(path)

      assert html =~ "Reading harnesses…"
      refute html =~ "Support desk"
      # No Create workspace while the repository is read.
      refute html =~ "Create workspace"
      refute has_element?(view, "#workspace-type-create")

      render_async(view, 2_000)

      refute has_element?(view, "#workspace-type-reading")
      assert has_element?(view, "#workspace-type > #workspace-type-canvas")
      assert has_element?(view, "#workspace-type-side h1", "Support desk")
      assert has_element?(view, "#workspace-type-summary", "Agents draft answers")
      assert has_element?(view, "#breadcrumb [aria-current=page]", "Support desk")
      assert [stage | _] = canvas_view(view)["stages"]
      assert stage["name"] == "Answer"

      assert texts(view, "#workspace-type-description p") == [
               "Each ticket goes through two stages. In Answer, an agent drafts an answer and then checks its tone, for up to three rounds. In Check, a person reads the draft and sends it or sends it back."
             ]

      assert words(view, "#workspace-type-harness") == "Harness: acme/harness, stack support"

      assert has_element?(view, "#workspace-type-stages")

      assert has_element?(
               view,
               "#workspace-type-side button#workspace-type-create",
               "Create workspace"
             )
    end

    @tag with_features: Apiary.Features.all() -- [:workflow_model]
    test "with workflow_model off, How it works takes the main area", %{
      conn: conn,
      user: user,
      template_path: path
    } do
      {:ok, view, _html} = conn |> log_in_user(user) |> live(path)
      render_async(view, 2_000)

      refute has_element?(view, "#workspace-type-canvas")
      assert has_element?(view, "#workspace-type > #workspace-type-how h2", "How it works")
      assert has_element?(view, "#workspace-type-how p", "Each ticket goes through two stages")
      assert has_element?(view, "#workspace-type-side h1", "Support desk")
      assert words(view, "#workspace-type-harness") == "Harness: acme/harness, stack support"
      assert has_element?(view, "#workspace-type-create", "Create workspace")
    end

    test "a key whose module has dots opens that module",
         %{
           conn: conn,
           user: user,
           organisation: organisation,
           collection: collection
         } = ctx do
      serve(ctx, %{"a.b" => template_file()})
      key = collection.public_id <> ".a.b"
      path = ~p"/#{organisation}/workspaces/new/#{key}"

      {:ok, view, _html} = conn |> log_in_user(user) |> live(path)
      render_async(view, 2_000)

      assert has_element?(view, "#workspace-type-side h1", "Support desk")
    end

    test "a read that fails shows its reason and a link to New workspace", %{
      conn: conn,
      user: user,
      organisation: organisation,
      template_path: path,
      adapter: adapter
    } do
      Apiary.HarnessReadsFixtures.serve_calls([adapter], down: true)
      {:ok, view, _html} = conn |> log_in_user(user) |> live(path)
      render_async(view, 2_000)

      refute has_element?(view, "#workspace-type-reading")
      assert has_element?(view, "#workspace-type-read-error", "Qory Apiary could not connect")
      refute has_element?(view, "#workspace-type-create")

      assert has_element?(
               view,
               ~s(#workspace-type-back[href="/#{organisation.slug}/workspaces/new"]),
               "New workspace"
             )
    end

    test "a module with no template opens New workspace",
         %{conn: conn, user: user, organisation: organisation, template_path: path} = ctx do
      serve(ctx, %{"other" => template_file()}, root: "[other, support-desk]")
      {:ok, view, _html} = conn |> log_in_user(user) |> live(path)

      assert_redirect(view, ~p"/#{organisation}/workspaces/new", 2_000)
    end

    test "a key of no place is a path that does not exist", %{
      conn: conn,
      user: user,
      organisation: organisation,
      collection: collection
    } do
      conn = log_in_user(conn, user)

      for key <- [
            "nobody.support-desk",
            "shared.support-desk",
            "assigned-none.support-desk",
            "#{collection.public_id}.",
            "#{collection.public_id}"
          ] do
        assert_raise ApiaryWeb.NotFound, fn ->
          live(conn, ~p"/#{organisation}/workspaces/new/#{key}")
        end
      end
    end

    test "a person workspace.create does not allow finds no page", %{
      conn: conn,
      organisation: organisation,
      template_path: path
    } do
      admin = user_fixture()

      %Membership{organisation_id: organisation.id, user_id: admin.id}
      |> Membership.changeset(%{level: :admin})
      |> Repo.insert!()

      assert_raise ApiaryWeb.NotFound, fn -> conn |> log_in_user(admin) |> live(path) end
    end
  end

  describe "Create workspace on a template of a harness repository" do
    @describetag needs: :factory
    @describetag :capture_log

    @team "https://code.example.com/example-org/team-harness"

    setup %{user: user, organisation: organisation}, do: repository(user, organisation)

    defp support_desk_file, do: Apiary.HarnessReadsFixtures.support_desk_file()

    # The page of `key`, opened and read.
    defp open(conn, user, organisation, key) do
      {:ok, view, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/workspaces/new/#{key}")

      render_async(view, 2_000)
      view
    end

    # Create workspace, and the page it leads to.
    defp create(view, conn) do
      result = view |> element("#workspace-type-create") |> render_click()
      follow_redirect(result, conn)
    end

    defp workspaces(organisation),
      do: Repo.all(from(w in Workspace, where: w.organisation_id == ^organisation.id))

    defp scope_of(user, organisation),
      do: Organisations.load_scope(Scope.for_user(user), organisation.id)

    # The organisation shares the harness at `@harness`, stack support.
    defp share!(user, organisation) do
      document = "extends:\n  git: \"#{@harness}\"\n  stack: \"support\"\n  ref: \"HEAD\"\n"

      {:ok, row} =
        Apiary.Stacks.put_stack(
          scope_of(user, organisation),
          {:organisation, organisation},
          document,
          choice: :repository,
          version: {:branch, "HEAD"}
        )

      row
    end

    # An assignment of `@team` to the organisation, read through the instance's grant.
    defp assign_team!(ctx, organisation) do
      instance = Apiary.HarnessReadsFixtures.call_adapter_fixture()
      admin = instance_admin_scope()

      {connection, _nonce} =
        Apiary.NodesFixtures.connection_fixture(admin, instance.adapter, :listed)

      Apiary.HarnessReadsFixtures.live_grant_fixture(
        admin.organisation.id,
        instance.adapter,
        connection,
        "G_i"
      )

      assignment =
        Repo.insert!(%Apiary.Harnesses.Assignment{
          organisation_id: organisation.id,
          every_organisation: false,
          source: %{"git" => @team, "ref" => "v1"},
          created_by_id: admin.user.id
        })

      files =
        Map.merge(
          Apiary.HarnessReadsFixtures.repository_files("R_harness", %{
            "support-desk" => support_desk_file()
          }),
          Apiary.HarnessReadsFixtures.repository_files("R_team", %{
            "support-desk" => support_desk_file()
          })
        )

      covered = Map.put(ctx.covered, instance.adapter.id, %{@team => {"G_i", "R_team"}})

      Apiary.HarnessReadsFixtures.serve_calls([ctx.adapter, instance],
        covered: covered,
        files: files
      )

      assignment
    end

    # The error flash's text with no white space: its title and body are two elements.
    defp flash_error(view), do: view |> texts("#flash-error") |> Enum.join() |> squash()

    defp squash(text), do: String.replace(text, ~r/\s+/, "")

    defp first_version(workspace) do
      assert [version] = Apiary.Processes.list_versions(workspace)
      version
    end

    test "a connected repository's template makes the workspace, with the template's process",
         %{conn: conn, user: user, organisation: organisation, template_path: path} do
      view =
        open(
          conn,
          user,
          organisation,
          String.replace_prefix(path, ~p"/#{organisation}/workspaces/new/", "")
        )

      assert {:ok, name, _html} = create(view, log_in_user(conn, user))
      assert has_element?(name, "h1", "Name this workspace")

      assert [%Workspace{name: "Support desk"} = workspace] = workspaces(organisation)
      version = first_version(workspace)
      assert [%{"name" => "Answer"}, %{"name" => "Check"}] = version.document["stages"]

      assert %{"source" => "repository", "module" => "support-desk", "stack" => "support"} =
               version.template

      assert version.template["commit"] == "c-R_harness"

      assert %{harness: harness} = Apiary.Stacks.choice(workspace)
      assert harness =~ ~s(stack: "support")
    end

    test "an assigned source's template makes the workspace",
         %{
           conn: conn,
           user: user,
           organisation: organisation
         } = ctx do
      assignment = assign_team!(ctx, organisation)
      view = open(conn, user, organisation, "assigned-#{assignment.id}.support-desk")
      assert {:ok, name, _html} = create(view, log_in_user(conn, user))
      assert has_element?(name, "h1", "Name this workspace")

      assert [workspace] = workspaces(organisation)
      assert %{"commit" => "c-R_team"} = first_version(workspace).template
    end

    test "the shared harness's template makes the workspace, and a hidden one shows no address",
         %{conn: conn, user: user, organisation: organisation} do
      share!(user, organisation)
      view = open(conn, user, organisation, "shared.support-desk")
      assert words(view, "#workspace-type-harness") == "Harness: acme/harness, stack support"
      assert {:ok, _name, _html} = create(view, log_in_user(conn, user))
      assert [workspace] = workspaces(organisation)
      assert %{"source" => "repository", "git" => @harness} = first_version(workspace).template
    end

    test "a hidden shared harness's workspace has no address in its record or its pages",
         %{conn: conn, user: user, organisation: organisation} do
      row = share!(user, organisation)

      {1, _} =
        Repo.update_all(from(s in Apiary.Stacks.Stack, where: s.id == ^row.id),
          set: [owner_organisation_id: Apiary.Edition.instance_organisation_id()]
        )

      view = open(conn, user, organisation, "shared.support-desk")
      assert words(view, "#workspace-type-harness") == "Harness: shared harness, stack support"
      refute render(view) =~ "acme/harness"

      assert {:ok, name, html} = create(view, log_in_user(conn, user))
      assert has_element?(name, "h1", "Name this workspace")
      refute html =~ "acme/harness"
      refute html =~ "code.example.com"

      assert [workspace] = workspaces(organisation)
      assert first_version(workspace).template["git"] == nil
    end

    test "forged parameters change nothing: the workspace comes from the page's read", %{
      conn: conn,
      user: user,
      organisation: organisation,
      template_path: path
    } do
      {:ok, view, _html} = conn |> log_in_user(user) |> live(path)

      # While the repository is read, Create workspace does nothing.
      render_hook(view, "create", %{"commit" => "forged"})
      assert workspaces(organisation) == []

      render_async(view, 2_000)

      forged = %{
        "commit" => "forged",
        "start" => %{"commit" => "forged", "template" => %{"stack" => "other"}},
        "template" => %{"stack" => "other"}
      }

      render_hook(view, "create", forged)
      assert [workspace] = workspaces(organisation)
      assert first_version(workspace).template["commit"] == "c-R_harness"
      assert first_version(workspace).template["stack"] == "support"
    end

    test "the first workspace of the organisation, then the organisation's overview where another person made one",
         %{conn: conn, user: user, organisation: organisation, template_path: path} do
      view =
        open(
          conn,
          user,
          organisation,
          String.replace_prefix(path, ~p"/#{organisation}/workspaces/new/", "")
        )

      {:ok, _other} =
        Organisations.create_workspace_of_kind(
          scope_of(user, organisation),
          Apiary.Lingo.Domain.Software,
          :first
        )

      result = view |> element("#workspace-type-create") |> render_click()
      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == ~p"/#{organisation}"
      assert length(workspaces(organisation)) == 1
    end

    # The core's limit of one workspace kept the page with its line. The edition sets no
    # limit: "Create workspace makes a second workspace, which Workspaces lists" in
    # test/apiary_pro_web/live/new_workspace_test.exs.

    test "a shared row with no owner says to save the shared harness again", %{
      conn: conn,
      user: user,
      organisation: organisation
    } do
      row = share!(user, organisation)

      {1, _} =
        Repo.update_all(from(s in Apiary.Stacks.Stack, where: s.id == ^row.id),
          set: [owner_organisation_id: nil]
        )

      view = open(conn, user, organisation, "shared.support-desk")
      view |> element("#workspace-type-create") |> render_click()

      assert flash_error(view) =~
               squash(
                 "Choose another template, or save the shared harness again in a workspace's Harness step. The organisation that saved it no longer exists."
               )

      assert workspaces(organisation) == []
    end

    test "a hidden shared harness that cannot be fetched shows no host or port", %{
      conn: conn,
      user: user,
      organisation: organisation
    } do
      document =
        "extends:\n  git: \"https://private.example.org/acme/harness\"\n  stack: \"support\"\n  ref: \"HEAD\"\n"

      {:ok, row} =
        Apiary.Stacks.put_stack(
          scope_of(user, organisation),
          {:organisation, organisation},
          document,
          choice: :repository,
          version: {:branch, "HEAD"}
        )

      {1, _} =
        Repo.update_all(from(s in Apiary.Stacks.Stack, where: s.id == ^row.id),
          set: [owner_organisation_id: Apiary.Edition.instance_organisation_id()]
        )

      view = open(conn, user, organisation, "shared.support-desk")

      assert has_element?(
               view,
               "#workspace-type-read-error",
               "Qory Apiary could not read the shared harness. Try again. If it repeats,"
             )

      refute render(view) =~ "private.example.org"
    end

    defmodule RefusesWorkspace do
      @moduledoc false
      # An edition that refuses the workspace after it is made, as `ApiaryPro.Edition` can.
      def workspace_created(_repo, _workspace, _scope), do: {:error, :refused}
    end

    test "an edition's refusal of the new workspace is the general error, and nothing is made",
         %{conn: conn, user: user, organisation: organisation, template_path: path} do
      :ok = Apiary.Edition.put_test_stub(RefusesWorkspace)

      view =
        open(
          conn,
          user,
          organisation,
          String.replace_prefix(path, ~p"/#{organisation}/workspaces/new/", "")
        )

      view |> element("#workspace-type-create") |> render_click()

      assert flash_error(view) =~ squash("Nothing was changed. Try again.")
      assert workspaces(organisation) == []
    end

    test "a refused render of the new workspace's policy is the general error, and nothing is made",
         %{conn: conn, user: user, organisation: organisation, template_path: path} do
      on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Above) end)

      # A document over the 1 MiB the gateway reads.
      above = %Apiary.Policy.Above{
        id: Ecto.UUID.generate(),
        name: "Northwind",
        slug: "northwind",
        rules:
          for n <- 1..11 do
            %Apiary.Policy.Rule{
              id: Ecto.UUID.generate(),
              kind: "host",
              action: "allow",
              host: "h#{n}.example",
              paths: for(m <- 1..100, do: "/" <> String.duplicate("a", 1000) <> "/#{n}/#{m}"),
              locked: false
            }
          end
      }

      Application.put_env(:apiary, Apiary.Policy.Above, answer: fn _workspace -> above end)

      view =
        open(
          conn,
          user,
          organisation,
          String.replace_prefix(path, ~p"/#{organisation}/workspaces/new/", "")
        )

      view |> element("#workspace-type-create") |> render_click()

      assert flash_error(view) =~ squash("Nothing was changed. Try again.")
      assert workspaces(organisation) == []
    end

    test "a person who lost the right to create goes to the overview", %{
      conn: conn,
      user: user,
      organisation: organisation,
      template_path: path
    } do
      view =
        open(
          conn,
          user,
          organisation,
          String.replace_prefix(path, ~p"/#{organisation}/workspaces/new/", "")
        )

      Repo.update_all(
        from(m in Membership,
          where: m.organisation_id == ^organisation.id and m.user_id == ^user.id
        ),
        set: [level: :member]
      )

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#workspace-type-create") |> render_click()

      assert to == ~p"/#{organisation}"
      assert workspaces(organisation) == []
    end

    test "a repository no longer connected opens New workspace with an error", %{
      conn: conn,
      user: user,
      organisation: organisation,
      collection: collection,
      template_path: path
    } do
      view =
        open(
          conn,
          user,
          organisation,
          String.replace_prefix(path, ~p"/#{organisation}/workspaces/new/", "")
        )

      {1, _} =
        Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^collection.id),
          set: [ended_at: DateTime.utc_now(), ended_reason: :not_listed]
        )

      conn = log_in_user(conn, user)
      assert {:ok, new_workspace, _html} = create(view, conn)
      assert flash_error(new_workspace) =~ squash("Nothing was changed. Try again.")
      assert has_element?(new_workspace, "#set-up-cards")
      assert workspaces(organisation) == []
    end

    test "a template named with no letters says to change its name",
         %{
           conn: conn,
           user: user,
           organisation: organisation
         } = ctx do
      file = String.replace(support_desk_file(), "name: Support desk", ~s(name: "!!!"))
      files = Apiary.HarnessReadsFixtures.repository_files("R_harness", %{"support-desk" => file})
      Apiary.HarnessReadsFixtures.serve_calls([ctx.adapter], covered: ctx.covered, files: files)

      view = open(conn, user, organisation, ctx.collection.public_id <> ".support-desk")
      view |> element("#workspace-type-create") |> render_click()

      assert flash_error(view) =~
               squash("Change the name in the process.yaml of support-desk in acme/harness.")

      assert workspaces(organisation) == []
    end

    test "a template of a type no domain has is not a template",
         %{
           conn: conn,
           user: user,
           organisation: organisation
         } = ctx do
      file = String.replace(support_desk_file(), "type: qory.software", "type: no-such-type")
      files = Apiary.HarnessReadsFixtures.repository_files("R_harness", %{"support-desk" => file})
      Apiary.HarnessReadsFixtures.serve_calls([ctx.adapter], covered: ctx.covered, files: files)

      {:ok, cards, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/workspaces/new")
      render_async(cards, 2_000)

      assert has_element?(
               cards,
               "#set-up-group-connected p",
               "support-desk in acme/harness is not a template: Qory Apiary has no workspace type no-such-type."
             )
    end

    test "no Create workspace shows at a module with no template", %{
      conn: conn,
      user: user,
      organisation: organisation,
      collection: collection
    } do
      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/#{organisation}/workspaces/new/#{collection.public_id <> ".none"}")

      refute has_element?(view, "#workspace-type-create")
      assert_redirect(view, ~p"/#{organisation}/workspaces/new", 2_000)
    end
  end

  # No `needs:` tag: it tests a run without the feature.
  @tag with_features: Enum.reject(Apiary.Features.all(), &(&1 in @needing_factory))
  test "with the feature factory off, the Qory template is the only page", %{
    conn: conn,
    user: user,
    organisation: organisation,
    path: path
  } do
    # The repository is connected with every feature on, as it would be before an instance
    # admin turned the feature off.
    off = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())
    %{collection: collection} = repository(user, organisation)
    Application.put_env(:apiary, :features, off)

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#workspace-type-create")

    key = collection.public_id <> ".support-desk"

    assert_raise ApiaryWeb.NotFound, fn ->
      live(conn, ~p"/#{organisation}/workspaces/new/#{key}")
    end

    # The Qory page is as it was without the feature: no harness line.
    refute has_element?(view, "#workspace-type-harness")

    # New workspace is the kind cards as they were: no group and no heading of a group,
    # and the card one level below the page's title.
    {:ok, cards, _html} = live(conn, ~p"/#{organisation}/workspaces/new")
    assert has_element?(cards, "h1#set-up-cards-title", "What will this workspace do?")
    assert has_element?(cards, "#set-up-cards #set-up-card-software h2", "Software factory")
    refute has_element?(cards, "#set-up-card-software h3")
    refute has_element?(cards, "[id^=set-up-group-]")
  end
end
