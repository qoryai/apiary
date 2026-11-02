defmodule ApiaryWeb.WorkspaceTypeLiveTest do
  # A template's page (`ApiaryWeb.WorkspaceTypeLive`), where a card leads. The Qory
  # template: the newest version of the type's default process on the view-only canvas,
  # with the side panel's name, summary, How it works, Stages, the harness line and Create
  # workspace; How it works in the main area with `workflow_model` off; the texts from code
  # and the texts an instance admin saved; Create workspace and its Name step. A template
  # of a harness repository: the same page from the repository's `process.yaml`, with the
  # harness line and no Create workspace. A key of no place that is listed, and the people
  # New workspace is not for. Not async: each test sets the instance's features, and some
  # save a version of a type, which every test reads.
  use ApiaryWeb.ConnCase, async: false

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
  @stages "The workspace starts with the stages shown. After you create it, owners and admins can change them in Workspace settings › Stages."

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

    test "reads the repository, then shows the template on the canvas, with its harness line and no Create workspace",
         %{conn: conn, user: user, template_path: path} do
      {:ok, view, html} = conn |> log_in_user(user) |> live(path)

      assert html =~ "Reading harnesses…"
      refute html =~ "Support desk"

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

      # No Create workspace, and no line about the stages that Create workspace makes.
      refute has_element?(view, "#workspace-type-create")
      refute has_element?(view, "#workspace-type-stages")
      refute render(view) =~ "Create workspace"
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
      refute has_element?(view, "#workspace-type-create")
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

    # New workspace lists the Qory template alone.
    {:ok, cards, _html} = live(conn, ~p"/#{organisation}/workspaces/new")
    assert has_element?(cards, "#set-up-group-qory #set-up-card-software")
    refute has_element?(cards, "#set-up-group-connected")
    refute has_element?(cards, "#set-up-group-shared")
  end
end
