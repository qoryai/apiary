defmodule ApiaryWeb.WorkspaceSetupLiveTest do
  # The workspace set-up, `/:org/set-up` (`ApiaryWeb.WorkspaceSetupLive`): its Workspace
  # step, the Type field and Create workspace, for a person `workspace.create` allows, and
  # the line for anyone else; the refusals; the summary once the workspace exists; the page
  # that moves on when anyone creates the workspace; and the landing that sends an
  # organisation with no workspace to it. `ApiaryWeb.WorkspaceSetupLive.SourceTest` has
  # Work source.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryWeb.SetUpSteps

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Workspace}
  alias ApiaryWeb.UserAuth

  defmodule Waiting do
    # An edition that lists, for a person who waits, their account and an extra step,
    # and has a line for the column About this step.
    def set_up_steps(%Scope{}, []),
      do: [
        %{
          id: :account,
          label: "Your account",
          group: nil,
          state: :done,
          path: nil,
          note: nil
        },
        %{
          id: :client,
          label: "Client's workspace",
          group: :workspace,
          state: :current,
          path: nil,
          note: "Harbour Ops sets it up"
        }
      ]

    def set_up_steps(_scope, steps), do: steps

    def set_up_context(%Scope{}, :workspace), do: "Harbour Ops sets up the workspace."
  end

  # An organisation made with no workspace, and its owner.
  defp sign_up_without_workspace do
    {:ok, %{user: user, organisation: organisation}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: "Acme Studio"},
        nil,
        open: true,
        workspace: false
      )

    %{user: user, organisation: organisation}
  end

  # A person of `level` in `organisation`, joined with no invitation.
  defp joined(organisation, level) do
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: level})
    |> Repo.insert!()

    user
  end

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "shows the owner the Type field and Create workspace, with no sidebar", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_without_workspace()

    {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    assert html =~ ~r{<title[^>]*>\s*Set up your workspace}
    assert has_element?(lv, "h1", "Set up your workspace")
    refute has_element?(lv, "#shell .drawer")
    refute has_element?(lv, "#set-up-help")

    assert words(lv, "#set-up-what") ==
             "Main is where Qory Apiary takes in tickets and runs agents on them. Its type sets " <>
               "which work sources it can connect, and whether each ticket needs a repository."

    assert words(lv, "#set-up-line") == "Main is this instance's only workspace."
    assert has_element?(lv, "#set-up-context #set-up-line")

    # Your account, then Workspace, and Work source with the feature; no Back before it.
    if Apiary.Features.on?(:factory) do
      assert steps(lv) == [
               {"Your account", :done},
               {"Workspace", :current},
               {"Work source", :to_come}
             ]

      assert count(lv) == "Step 2 of 3"
    else
      assert steps(lv) == [{"Your account", :done}, {"Workspace", :current}]
      assert count(lv) == "Step 2 of 2"
    end

    refute has_element?(lv, "#set-up-back")

    # The Type is a choice: a button with the prompt, and a panel of radios, each with
    # its type's title and line.
    assert has_element?(lv, "#set-up-form button#workspace_domain.is-prompt", "Choose a type")
    assert has_element?(lv, "#workspace_domain-panel[hidden]")
    refute has_element?(lv, "#set-up-form select")

    for {value, title, line} <- [
          {"software", "Software", "For work on code. Each ticket needs a repository."},
          {"general", "General",
           "For any other work, such as marketing, incidents or customer care."}
        ] do
      radio = "#set-up-form input[type=radio][name='workspace[domain]'][value='#{value}']"
      assert has_element?(lv, radio)

      [id] =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(radio)
        |> LazyHTML.attribute("id")

      assert has_element?(lv, "label[for='#{id}'] .q-pick-t", title)
      assert has_element?(lv, "##{id}-s", line)
    end

    assert has_element?(
             lv,
             "#set-up-form",
             "You can't change the type after you create the workspace."
           )

    assert has_element?(lv, "#set-up-form button", "Create workspace")
  end

  test "?step=source before the workspace exists opens the Type step", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_without_workspace()

    {:ok, lv, _html} =
      conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=source")

    assert has_element?(lv, "h1", "Set up your workspace")
    assert has_element?(lv, "#set-up-form #workspace_domain", "Choose a type")
    assert {"Workspace", :current} in steps(lv)
    refute has_element?(lv, "#set-up-sources")
  end

  test "Create workspace makes Main of the type chosen", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_without_workspace()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    lv |> form("#set-up-form", workspace: %{domain: "general"}) |> render_submit()

    assert [%Workspace{name: "Main", domain: "general"} = main] =
             Organisations.list_workspaces(
               Organisations.load_scope(Scope.for_user(user), organisation.id)
             )

    {to, _flash} = assert_redirect(lv)

    if Apiary.Features.on?(:factory),
      do: assert(to == ~p"/#{organisation}/set-up?step=source"),
      else: assert(to == ~p"/#{organisation}/#{main}")
  end

  test "Workspace, once the workspace exists, shows what was made, read only", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=type")

    assert has_element?(lv, "h1", "Set up your workspace")

    assert words(lv, "#set-up-made") ==
             "Main is a Software workspace. You can't change the type after you create the workspace."

    refute has_element?(lv, "#set-up-form")
    assert {"Workspace", :current} in steps(lv)

    if Apiary.Features.on?(:factory) do
      lv |> element("#set-up-continue") |> render_click()
      assert_patch(lv, ~p"/#{organisation}/set-up?step=source")
      assert {"Workspace", :done, :link} in steps(lv)
    else
      # Continue opens the workspace, at its first page the person may open.
      [href] =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#set-up-continue")
        |> LazyHTML.attribute("href")

      assert String.starts_with?(href, ~p"/#{organisation}/#{main}")
    end
  end

  test "once anyone creates the workspace, the page moves on", %{conn: conn} do
    %{user: owner, organisation: organisation} = sign_up_without_workspace()
    member = joined(organisation, :member)

    {:ok, waiting, _html} = conn |> log_in_user(member) |> live(~p"/#{organisation}/set-up")
    assert has_element?(waiting, "#set-up-waiting")
    assert steps(waiting) == []

    {:ok, other, _html} = build_conn() |> log_in_user(owner) |> live(~p"/#{organisation}/set-up")

    {:ok, _main} =
      Organisations.create_first_workspace(
        Organisations.load_scope(Scope.for_user(owner), organisation.id),
        %{"domain" => "general"}
      )

    for lv <- [waiting, other] do
      {to, _flash} = assert_redirect(lv)
      assert to == ~p"/#{organisation}/set-up?step=source"
    end
  end

  test "with no type chosen, says to choose one", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_without_workspace()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    # No radio is checked, so the form sends no type.
    lv |> form("#set-up-form") |> render_submit()

    assert has_element?(lv, "#set-up-form", "Choose a type.")
    refute Organisations.has_workspace?(organisation)
  end

  test "where Main is marked for deletion, says to restore it", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()
    now = DateTime.utc_now()

    main
    |> Ecto.Changeset.change(
      deletion_marked_at: now,
      purge_after: DateTime.add(now, 30, :day),
      purge_trigger: "grace_period"
    )
    |> Repo.update!()

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")
    lv |> form("#set-up-form", workspace: %{domain: "software"}) |> render_submit()

    assert words(lv, "#set-up-name-taken") ==
             "Restore Main in Organisation settings › Workspaces. A deleted workspace keeps its name until it is purged."

    refute Organisations.has_workspace?(organisation)
  end

  test "anyone workspace.create does not allow is told who sets it up", %{conn: conn} do
    %{organisation: organisation} = sign_up_without_workspace()

    for level <- [:admin, :member] do
      user = joined(organisation, level)
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

      assert has_element?(lv, "h1", "Set up your workspace")

      assert words(lv, "#set-up-waiting") ==
               "An owner sets up this organisation's first workspace."

      refute has_element?(lv, "#set-up-form")
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-context")
    end
  end

  test "an instance admin who waits in another organisation sees no steps", %{conn: conn} do
    %{organisation: organisation} = sign_up_without_workspace()
    admin = instance_admin_scope()

    %Membership{organisation_id: organisation.id, user_id: admin.user.id}
    |> Membership.changeset(%{level: :member})
    |> Repo.insert!()

    {:ok, lv, _html} = conn |> log_in_user(admin.user) |> live(~p"/#{organisation}/set-up")

    # The Connect steps are the instance's, not this page's: a person who waits gets the
    # core's list, which has no step.
    assert has_element?(lv, "#set-up-waiting")
    assert steps(lv) == []
    refute has_element?(lv, "#set-up-steps")
    refute has_element?(lv, "#set-up-context")
  end

  test "a person who waits sees the edition's steps from 2 on, and its line for the step",
       %{conn: conn} do
    %{organisation: organisation} = sign_up_without_workspace()
    member = joined(organisation, :member)

    # The core lists the member's account alone and has no line, so the page shows
    # neither (the test before this one); the edition's answer shows both.
    :ok = Apiary.Edition.put_test_stub(Waiting)
    {:ok, lv, _html} = conn |> log_in_user(member) |> live(~p"/#{organisation}/set-up")

    assert has_element?(lv, "#set-up-waiting")
    assert steps(lv) == [{"Your account", :done}, {"Client's workspace", :current}]
    assert count(lv) == "Step 2 of 2"

    assert words(lv, "#set-up-context #set-up-what") == "Harbour Ops sets up the workspace."
  end

  test "is no page for someone outside the organisation", %{conn: conn} do
    %{organisation: organisation} = sign_up_without_workspace()
    %{user: stranger} = sign_up_fixture()

    conn = conn |> log_in_user(stranger) |> get(~p"/#{organisation}/set-up")
    assert conn.status == 404
  end

  test "once the organisation has a workspace, sends a member on", %{conn: conn} do
    %{organisation: organisation} = sign_up_fixture()
    user = joined(organisation, :member)
    member = Organisations.load_scope(Scope.for_user(user), organisation.id)

    assert {:error, {:live_redirect, %{to: to}}} =
             conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    if member.workspace,
      do: assert(to == ApiaryWeb.Layouts.workspace_landing(member)),
      else: assert(to == ~p"/#{organisation}")
  end

  describe "the landing" do
    test "a sign-in of a person whose organisation has no workspace lands on its set-up", %{
      conn: conn
    } do
      %{user: user, organisation: organisation} = sign_up_without_workspace()

      conn =
        conn
        |> Map.replace!(:secret_key_base, ApiaryWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> UserAuth.log_in_user(%{user | authenticated_at: DateTime.utc_now(:second)})

      assert redirected_to(conn) == ~p"/#{organisation}/set-up"
    end

    test "/ sends a person of an organisation with no workspace to its set-up", %{conn: conn} do
      %{organisation: organisation} = sign_up_without_workspace()
      member = joined(organisation, :member)

      conn = conn |> log_in_user(member) |> get(~p"/")
      assert redirected_to(conn) == ~p"/#{organisation}/set-up"
    end

    test "the organisation's page sends on to its set-up", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_without_workspace()

      assert {:error, {:live_redirect, %{to: to}}} =
               conn |> log_in_user(user) |> live(~p"/#{organisation}")

      assert to == ~p"/#{organisation}/set-up"
    end
  end
end

defmodule ApiaryWeb.WorkspaceSetupLive.SourceTest do
  # The second step of the workspace set-up (`ApiaryWeb.WorkspaceSetupLive`): the
  # instance's configured adapters that serve the workspace's type, each with Connect, and
  # Skip; with none, the line and Continue; and who it is for.
  use ApiaryWeb.ConnCase, async: true

  import ApiaryWeb.SetUpSteps
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo
  alias Apiary.Organisations.Membership

  @moduletag needs: :factory

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "lists the configured adapters for the type, each with Connect, and Skip", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()
    %{adapter: adapter} = connectable_adapter_fixture()
    %{adapter: other_type} = connectable_adapter_fixture()

    {1, _} =
      Repo.update_all(
        from(n in Apiary.Nodes.Node, where: n.id == ^other_type.id),
        set: [domains: ["general"]]
      )

    # Not configured: no key and no address to connect to.
    unconfigured = adapter_fixture()

    {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    assert html =~ ~r{<title[^>]*>\s*Connect a work source to Main}
    assert has_element?(lv, "h1", "Connect a work source to Main")
    assert words(lv, "#set-up-what") == "Bring tickets in from a system this instance has set up."

    assert words(lv, "#set-up-backlog") ==
             "Main's Backlog lists the tickets of the work sources it connects. Connect opens " <>
               "#{adapter.name} in this tab, and #{adapter.name} sends you back to Qory Apiary " <>
               "after its steps."

    assert Enum.take(steps(lv), -2) == [{"Workspace", :done, :link}, {"Work source", :current}]

    assert has_element?(
             lv,
             ~s{#set-up-back[href="/#{organisation.slug}/set-up?step=type"][aria-label="Back to Workspace"]}
           )

    assert has_element?(lv, "#set-up-source-#{adapter.public_id}", adapter.name)

    assert has_element?(
             lv,
             "#set-up-source-#{adapter.public_id}",
             "Tickets from #{adapter.name}."
           )

    refute has_element?(lv, "#set-up-source-#{other_type.public_id}")
    refute has_element?(lv, "#set-up-source-#{unconfigured.public_id}")

    assert has_element?(
             lv,
             ~s{#set-up-source-#{adapter.public_id}-connect[action="/#{organisation.slug}/settings/integrations/#{adapter.public_id}/install?back=set-up"]},
             "Connect"
           )

    refute has_element?(lv, "#set-up-source-#{adapter.public_id}-connected")

    assert has_element?(
             lv,
             ~s{#set-up-skip-button[href="/#{organisation.slug}/#{main.slug}"]},
             "Skip"
           )

    assert words(lv, "#set-up-skip p") == "You can connect one later from Main's Overview."
    refute has_element?(lv, "#set-up-no-source")
  end

  test "an adapter already connected shows Connected, by the Overview's rule, and Continue",
       %{conn: conn} do
    %{user: user, organisation: organisation, workspace: main, scope: scope} = sign_up_fixture()
    collection = collection_fixture(scope)
    connected = Repo.get!(Apiary.Nodes.Node, collection.adapter_id)
    %{adapter: other} = connectable_adapter_fixture()

    assert [%{adapter: %{id: id}}] = Apiary.Edition.work_source_ready(main)
    assert id == connected.id

    {:ok, lv, _html} =
      conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=source")

    assert has_element?(lv, "#set-up-source-#{connected.public_id}-connected", "Connected")
    refute has_element?(lv, "#set-up-source-#{other.public_id}-connected")

    # Connect stays, to connect another account; the step is done, so Continue, not Skip.
    assert has_element?(
             lv,
             "#set-up-source-#{connected.public_id}-connect-install:not(.btn-primary)"
           )

    assert has_element?(lv, "#set-up-source-#{other.public_id}-connect-install.btn-primary")
    assert {"Work source", :current} in steps(lv)

    assert has_element?(
             lv,
             ~s{#set-up-continue[href="/#{organisation.slug}/#{main.slug}"]},
             "Continue"
           )

    refute has_element?(lv, "#set-up-skip-button")
    refute has_element?(lv, "#set-up-skip p")
  end

  describe "an adapter's guide" do
    # The text of each element `selector` finds under `help`, its spaces joined.
    defp texts(lv, help, selector) do
      lv
      |> element(help)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
    end

    test "shows Qory Apiary's first step, the adapter's connect steps, its lines, and the note on the one workspace",
         %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture()
      guide = source_guide_example()
      guided_adapter(adapter, guide)

      {1, _} =
        Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.id),
          set: [collection_noun_one: "repository", collection_noun_other: "repositories"]
        )

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")
      help = "#set-up-help-#{adapter.public_id}"

      assert has_element?(lv, "#set-up-context #{help} h3", "On #{adapter.name}")
      assert texts(lv, help, "li") == guide["connect"]["steps"]

      assert texts(lv, help, "p") == [
               guide["connect"]["before"],
               guide["connect"]["after"],
               "Main gets every repository you picked, because #{organisation.name} has one workspace."
             ]
    end

    test "names the adapter as its row does, and hides the steps once Connect can't be pressed",
         %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture(%{name: "GitHub"})
      guided_adapter(adapter, source_guide_example())

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")
      help = "#set-up-help-#{adapter.public_id}"
      connect = "#set-up-source-#{adapter.public_id}-connect-install"

      assert has_element?(lv, "#set-up-source-#{adapter.public_id} p", "GitHub")
      assert has_element?(lv, "#{help} h3", "On GitHub")
      refute render(lv) =~ "Press Connect beside"
      assert has_element?(lv, connect, "Connect")
      refute has_element?(lv, "#{connect}[disabled]")

      # The adapter's key is revoked: Connect is disabled, and its steps go when the page
      # renders again.
      {1, _} =
        Repo.update_all(
          from(k in Apiary.AccessKeys.AccessKey, where: k.node_id == ^adapter.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      render_hook(lv, "install", %{"integration" => adapter.public_id})

      assert has_element?(lv, "#{connect}[disabled]")
      refute has_element?(lv, help)
    end

    test "with no connect steps, or no guide, the old step shows", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture()
      guided_adapter(adapter, %{"setup" => source_guide_example()["setup"]})
      %{adapter: plain} = connectable_adapter_fixture()

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

      assert has_element?(lv, "#set-up-source-#{adapter.public_id}")
      assert has_element?(lv, "#set-up-source-#{plain.public_id}")
      refute has_element?(lv, "#set-up-help-#{adapter.public_id}")
      refute has_element?(lv, "#set-up-help-#{plain.public_id}")
    end

    test "shows the adapter's lines as plain text, and no note with two workspaces",
         %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      workspace_fixture(organisation, "Second")

      %{adapter: adapter} = connectable_adapter_fixture()

      guided_adapter(adapter, %{
        "connect" => %{
          "steps" => ["Press **Allow** <b>now</b>."],
          "after" => "<a href=\"x\">y</a>"
        }
      })

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")
      help = "#set-up-help-#{adapter.public_id}"

      assert texts(lv, help, "li") == ["Press **Allow** <b>now</b>."]

      assert texts(lv, help, "p") == [~s(<a href="x">y</a>)]
      refute has_element?(lv, "#{help} a")
    end
  end

  test "with no adapter for the type, says so, with Continue", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    assert words(lv, "#set-up-no-source") ==
             "No work source for this type is set up on this instance. An instance admin sets one up in Instance settings › Adapters."

    assert has_element?(
             lv,
             ~s{#set-up-continue[href="/#{organisation.slug}/#{main.slug}"]},
             "Continue"
           )

    refute has_element?(lv, "#set-up-sources")
  end

  test "shows anyone adapter.connect does not allow the edition's sentence of who may, and Skip",
       %{conn: conn} do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ConnectWorded)
    %{organisation: organisation, workspace: main} = sign_up_fixture()
    %{adapter: adapter} = connectable_adapter_fixture()
    guided_adapter(adapter, source_guide_example())
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: :member})
    |> Repo.insert!()

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    assert has_element?(lv, "h1", "Connect a work source to Main")
    assert has_element?(lv, "#set-up-source-#{adapter.public_id}", adapter.name)
    refute has_element?(lv, "#set-up-source-#{adapter.public_id}-connect")
    refute has_element?(lv, "#set-up-help-#{adapter.public_id}")
    assert words(lv, "#set-up-who-may") == Apiary.EditionStubs.ConnectWorded.sentence()

    assert has_element?(
             lv,
             ~s{#set-up-skip-button[href="/#{organisation.slug}/#{main.slug}"]},
             "Skip"
           )

    refute has_element?(lv, "#set-up-skip p")
  end

  test "sends on anyone adapter.connect does not allow, where the edition says nothing of who may",
       %{conn: conn} do
    %{organisation: organisation} = sign_up_fixture()
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: :member})
    |> Repo.insert!()

    assert {:error, {:live_redirect, %{to: to}}} =
             conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

    refute to == ~p"/#{organisation}/set-up"
  end
end
