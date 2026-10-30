defmodule ApiaryWeb.WorkspaceSetupLiveTest do
  # The workspace set-up (`ApiaryWeb.WorkspaceSetupLive`) in every feature set: the type
  # cards, for an owner of an organisation with no workspace and on New workspace, with
  # the edition's limit; Name, which creates the workspace of the type picked, and shows it
  # read only once it exists; the line for a person who waits; the page that moves on when
  # anyone creates the first workspace; and the landing that sends an organisation with no
  # workspace to it. `ApiaryWeb.WorkspaceSetupLive.FlowTest` has the steps of the `factory`
  # feature, and `ApiaryWeb.WorkspaceSetupLive.ModelTest` the Model step.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
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
          group: nil,
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

  defp href(lv, selector) do
    [href] =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  defp group_headings(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".q-su-grp-h")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "the type cards" do
    test "show the first person the card of Software factory alone, with no steps", %{
      conn: conn
    } do
      %{user: user, organisation: organisation} = sign_up_without_workspace()

      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

      assert html =~ ~r{<title[^>]*>\s*What will this workspace do\?}
      assert has_element?(lv, "h1", "What will this workspace do?")
      refute has_element?(lv, "#shell .drawer")
      refute has_element?(lv, "#set-up-steps")

      # Example has no card's words, so it has no card.
      assert has_element?(lv, "#set-up-card-software h2", "Software factory")
      refute has_element?(lv, "#set-up-card-example")

      assert has_element?(
               lv,
               "#set-up-card-software p",
               "Agents change code in your repositories."
             )

      assert has_element?(
               lv,
               "#set-up-card-software p",
               "You connect: where work comes from, where changes go, a model."
             )

      assert href(lv, "#set-up-card-software-choose") ==
               ~p"/#{organisation}/set-up?type=software"
    end

    test "a step named with no type, or a type with no card, shows the cards", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_without_workspace()
      conn = log_in_user(conn, user)

      for path <- [
            ~p"/#{organisation}/set-up?step=name",
            ~p"/#{organisation}/set-up?type=example"
          ] do
        {:ok, lv, _html} = live(conn, path)
        assert has_element?(lv, "#set-up-card-software")
        refute has_element?(lv, "#set-up-form")
      end
    end

    @tag :feature_sets
    test "Choose opens the flow at Name, its first step, with no group heading", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_without_workspace()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

      lv |> element("#set-up-card-software-choose") |> render_click()
      assert_patch(lv, ~p"/#{organisation}/set-up?type=software")
      assert words(lv, "#set-up-title") == "Set up a new Software factory"

      if Apiary.Features.on?(:factory) and Apiary.Features.on?(:secrets) do
        assert has_element?(lv, "h1", "Name this workspace")

        assert steps(lv) == [
                 {"Your account", :done},
                 {"Name", :current},
                 {"Work sources", :to_come},
                 {"Destinations", :to_come},
                 {"Model", :to_come},
                 {"Harness", :to_come},
                 {"Machines", :to_come},
                 {"Test run", :to_come}
               ]

        # A person who is not an instance admin counts Your account too.
        assert count(lv) == "Step 2 of 8"
        assert group_headings(lv) == []

        # Your account has no page, so the first step has no Back.
        refute has_element?(lv, "#set-up-back")
      else
        assert has_element?(lv, "h1", "Name this workspace")
        assert steps(lv) == [{"Your account", :done}, {"Name", :current}]
        assert count(lv) == "Step 2 of 2"
      end
    end
  end

  describe "Name" do
    @tag :feature_sets
    test "prefills Main for the first workspace, and creates it of the type picked", %{
      conn: conn
    } do
      %{user: user, organisation: organisation} = sign_up_without_workspace()

      {:ok, lv, html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=name&type=software")

      assert html =~ ~r{<title[^>]*>\s*Name this workspace}
      assert has_element?(lv, "#set-up-form input[name='workspace[name]'][value='Main']")
      assert words(lv, "#set-up-type") == "Software factory · Acme Studio"
      assert has_element?(lv, "#set-up-form button", "Create workspace")

      lv |> form("#set-up-form", workspace: %{name: "Payments"}) |> render_submit()

      assert [%Workspace{name: "Payments", domain: "software"} = payments] =
               Organisations.list_workspaces(
                 Organisations.load_scope(Scope.for_user(user), organisation.id)
               )

      {to, _flash} = assert_redirect(lv)

      if Apiary.Features.on?(:factory),
        do: assert(to == ~p"/#{organisation}/set-up?step=sources&workspace=payments"),
        else: assert(to == ~p"/#{organisation}/#{payments}")
    end

    test "a blank name is the field's error", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_without_workspace()

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=name&type=software")

      html = lv |> form("#set-up-form", workspace: %{name: " "}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute Organisations.has_workspace?(organisation)
    end

    test "the name of a workspace marked for deletion says to restore it", %{conn: conn} do
      %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()
      now = DateTime.utc_now()

      main
      |> Ecto.Changeset.change(
        deletion_marked_at: now,
        purge_after: DateTime.add(now, 30, :day),
        purge_trigger: "grace_period"
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=name&type=software")

      lv |> form("#set-up-form", workspace: %{name: "Main"}) |> render_submit()

      assert words(lv, "#set-up-name-taken") ==
               "Restore Main in Organisation settings › Workspaces. A deleted workspace keeps " <>
                 "its name until it is purged."

      refute Organisations.has_workspace?(organisation)
    end

    @tag :feature_sets
    test "once the workspace exists, shows it read only", %{conn: conn} do
      %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=name")

      assert has_element?(lv, "h1", "Name this workspace")
      assert words(lv, "#set-up-name") == "Main"
      assert words(lv, "#set-up-type") == "Software factory · #{organisation.name}"
      refute has_element?(lv, "#set-up-form")
      assert {"Name", :current} in steps(lv)
      assert words(lv, "#set-up-title") == "Set up Main · Software factory"

      if Apiary.Features.on?(:factory),
        do:
          assert(
            href(lv, "#set-up-continue") ==
              ~p"/#{organisation}/set-up?step=sources&workspace=#{main.slug}"
          ),
        else: refute(has_element?(lv, "#set-up-continue"))
    end
  end

  describe "New workspace" do
    test "says the organisation may have no more workspaces, where the edition allows one",
         %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/workspaces/new")

      assert has_element?(lv, "h1", "What will this workspace do?")
      assert words(lv, "#set-up-limit") == "#{organisation.name} may have no more workspaces."
      refute has_element?(lv, "#set-up-cards")

      # Name says so too, as Create workspace is refused.
      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/workspaces/new?step=name&type=software")
      lv |> form("#set-up-form", workspace: %{name: "Payments"}) |> render_submit()

      assert words(lv, "#set-up-limit") == "#{organisation.name} may have no more workspaces."

      assert length(Organisations.list_workspaces(Organisations.load_scope(Scope.for_user(user)))) ==
               1
    end

    @tag :feature_sets
    test "shows an owner the cards, then Name with no name filled in", %{conn: conn} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
      %{user: user, organisation: organisation} = sign_up_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/workspaces/new")

      assert href(lv, "#set-up-card-software-choose") ==
               ~p"/#{organisation}/workspaces/new?type=software"

      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/workspaces/new?step=name&type=software")

      assert has_element?(lv, "#set-up-form input[name='workspace[name]']")
      refute has_element?(lv, "#set-up-form input[name='workspace[name]'][value='Main']")

      lv |> form("#set-up-form", workspace: %{name: "Payments"}) |> render_submit()
      {to, _flash} = assert_redirect(lv)

      if Apiary.Features.on?(:factory),
        do: assert(to == ~p"/#{organisation}/set-up?step=sources&workspace=payments"),
        else: assert(to == ~p"/#{organisation}/payments")
    end

    test "is no page for a person workspace.create does not allow", %{conn: conn} do
      %{organisation: organisation} = sign_up_fixture()
      user = joined(organisation, :admin)

      assert_raise ApiaryWeb.NotFound, fn ->
        conn |> log_in_user(user) |> live(~p"/#{organisation}/workspaces/new")
      end
    end
  end

  test "Create workspace after someone else created the first workspace opens the page again",
       %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_without_workspace()

    {:ok, lv, _html} =
      conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=name&type=software")

    # Written straight into the table: the page hears nothing of it.
    workspace_fixture(organisation, "Billing")

    lv |> form("#set-up-form", workspace: %{name: "Payments"}) |> render_submit()

    {to, _flash} = assert_redirect(lv)
    assert to == ~p"/#{organisation}/set-up"

    assert [%Workspace{name: "Billing"}] =
             Repo.all(from w in Workspace, where: w.organisation_id == ^organisation.id)
  end

  test "a create sent by a person workspace.create does not allow creates nothing", %{
    conn: conn
  } do
    %{organisation: organisation} = sign_up_without_workspace()
    member = joined(organisation, :member)

    {:ok, lv, _html} = conn |> log_in_user(member) |> live(~p"/#{organisation}/set-up")
    render_click(lv, "create", %{"workspace" => %{"name" => "Payments"}})

    refute Organisations.has_workspace?(organisation)
    assert has_element?(lv, "#set-up-waiting")
  end

  test "once anyone creates the first workspace, the page moves on", %{conn: conn} do
    %{user: owner, organisation: organisation} = sign_up_without_workspace()
    member = joined(organisation, :member)

    {:ok, waiting, _html} = conn |> log_in_user(member) |> live(~p"/#{organisation}/set-up")
    assert has_element?(waiting, "#set-up-waiting")
    assert steps(waiting) == []

    {:ok, other, _html} =
      build_conn() |> log_in_user(owner) |> live(~p"/#{organisation}/set-up?type=software")

    {:ok, _main} =
      Organisations.create_first_workspace(
        Organisations.load_scope(Scope.for_user(owner), organisation.id),
        %{"domain" => "software"}
      )

    # Each page opens again where `/:org/set-up` leads now.
    for lv <- [waiting, other] do
      {to, _flash} = assert_redirect(lv)
      assert to == ~p"/#{organisation}/set-up"
    end
  end

  test "anyone workspace.create does not allow is told who sets it up", %{conn: conn} do
    %{organisation: organisation} = sign_up_without_workspace()

    for level <- [:admin, :member] do
      user = joined(organisation, level)
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

      assert has_element?(lv, "h1", "Set up your workspace")

      assert words(lv, "#set-up-waiting") ==
               "An owner sets up this organisation's first workspace."

      refute has_element?(lv, "#set-up-cards")
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

  @tag :feature_sets
  test "with every step of the workspace done, sends the person to its first page", %{
    conn: conn
  } do
    # Without the `factory` feature, Name is the one step, done once the workspace exists.
    if not Apiary.Features.on?(:factory) do
      %{organisation: organisation} = sign_up_fixture()
      user = joined(organisation, :member)
      member = Organisations.load_scope(Scope.for_user(user), organisation.id)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up")

      assert to == ApiaryWeb.Layouts.workspace_landing(member)
    end
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

defmodule ApiaryWeb.WorkspaceSetupLive.FlowTest do
  # The steps of the set-up flow (`ApiaryWeb.WorkspaceSetupLive`) with the `factory`
  # feature: Work sources and Destinations, each with a card per grant, Connect another,
  # Connected, Connecting… and the adapter's guide; the chooser of a grant's collections
  # (`ApiaryWeb.ChooseCollectionsLive`), with All, Only selected, a collection in another
  # workspace and Not listed?; the test run,
  # with its condition and its states; who may act on each; and an instance admin's first
  # organisation.
  use ApiaryWeb.ConnCase, async: true

  import ApiaryWeb.SetUpSteps
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Dispatches, Organisations, Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Grant, GrantRule}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Membership
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @line "Hi! Where are you running?"

  defmodule ReadyNoTakeIn do
    # The machines ready, as `Apiary.EditionStubs.SetupReady` has them, and nobody takes
    # an item in, as `Apiary.EditionStubs.NoTakeIn` has it.
    defdelegate machines_ready(workspace), to: Apiary.EditionStubs.SetupReady
    defdelegate check(scope, action, subject), to: Apiary.EditionStubs.NoTakeIn
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

  defp href(lv, selector) do
    [href] =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  defp first_person do
    {:ok, %{user: user, organisation: organisation}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: "Acme"},
        nil,
        open: true,
        workspace: false
      )

    %{user: user, organisation: organisation}
  end

  defp joined(organisation, level) do
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: level})
    |> Repo.insert!()

    user
  end

  defp targets!(adapter) do
    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [targets: true])

    Repo.get!(Node, adapter.id)
  end

  defp adapter_of(collection), do: Repo.get!(Node, collection.adapter_id)

  # A configured adapter connected for `scope`'s organisation, and a part of a listing of
  # `refs` under the connection's grant, for the account acme; with `targets: true`, an
  # adapter with targets, and each collection's target on code.example.com at its ref.
  defp listed!(scope, refs, opts \\ []) do
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
    adapter = if opts[:targets], do: targets!(adapter), else: adapter
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    :ok = list!(key, connection, refs, "first", opts)
    grant = Repo.get_by!(Grant, connection_id: connection.id)
    %{adapter: adapter, key: key, connection: connection, grant: grant}
  end

  defp list!(key, connection, refs, id, opts \\ []) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(verified), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections:
          for ref <- refs do
            %{
              ref: ref,
              url: "https://forge.example.com/" <> ref,
              title: ref,
              grant_ref: listing_grant(connection),
              target: if(opts[:targets], do: %{system: "code.example.com", path: ref})
            }
          end,
        listing: %{
          id: id,
          part: 1,
          started_at: DateTime.utc_now(:second),
          complete: false
        }
      })

    :ok
  end

  # The live collection of `connection` with the ref `ref`.
  defp collection!(connection, ref) do
    Repo.one!(
      from c in Collection,
        where: c.connection_id == ^connection.id and c.external_ref == ^ref,
        where: is_nil(c.ended_at)
    )
  end

  describe "Work sources" do
    test "lists the configured adapters with items for the type, each with Connect, and Skip",
         %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture()
      %{adapter: other_type} = connectable_adapter_fixture()

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^other_type.id),
          set: [domains: ["example"]]
        )

      # Not configured: no key and no address to connect to.
      unconfigured = adapter_fixture()

      {:ok, lv, html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=sources&workspace=main")

      assert html =~ ~r{<title[^>]*>\s*Where does work for Main come from\?}
      assert has_element?(lv, "h1", "Where does work for Main come from?")
      assert {"Work sources", :current} in steps(lv)

      row = "#set-up-adapter-#{adapter.public_id}"
      assert has_element?(lv, row, adapter.name)
      assert has_element?(lv, row <> "-not-connected", "Not connected")
      refute has_element?(lv, "#set-up-adapter-#{other_type.public_id}")
      refute has_element?(lv, "#set-up-adapter-#{unconfigured.public_id}")

      back = URI.encode_query(back: "set-up:sources:workspace=main")

      assert has_element?(
               lv,
               ~s{#{row}-connect[action="/#{organisation.slug}/settings/integrations/#{adapter.public_id}/install?#{back}"]}
             )

      assert has_element?(lv, "#{row}-connect-install.btn-primary", "Connect")

      # With no card, the list of adapters to connect is open.
      assert has_element?(lv, "#set-up-connect[open] #set-up-adapters #{row}")
      assert words(lv, "#set-up-connect-another") == "Connect another source"
      refute has_element?(lv, "#set-up-grants")

      assert words(lv, "#set-up-later") ==
               "You can change this later in Workspace settings › Work sources."

      assert words(lv, "#set-up-context #set-up-what") ==
               "Bring tickets in from a system this instance has set up."

      assert has_element?(
               lv,
               "#set-up-context",
               "Connect opens #{adapter.name} in this tab, and #{adapter.name} sends you back " <>
                 "to Qory Apiary after its steps."
             )

      assert href(lv, "#set-up-skip") ==
               ~p"/#{organisation}/set-up?step=destinations&workspace=main"

      assert href(lv, "#set-up-back") == ~p"/#{organisation}/set-up?step=name&workspace=main"

      refute has_element?(lv, "#set-up-continue")
      refute has_element?(lv, "#set-up-no-adapter")
    end

    test "with no adapter for the type, shows the line for it", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=sources&workspace=main")

      assert words(lv, "#set-up-no-adapter") ==
               "No work source for this type is set up on this instance. An instance admin " <>
                 "sets one up in Instance settings › Adapters."

      refute has_element?(lv, "#set-up-adapters")
      assert has_element?(lv, "#set-up-skip")
    end

    test "a grant's card: the adapter and the account, how many are chosen, Choose; done once one is chosen",
         %{conn: conn} do
      %{user: user, organisation: organisation, workspace: main, scope: scope} =
        sign_up_fixture()

      %{adapter: adapter, grant: grant, connection: connection} =
        listed!(scope, ["acme/api", "acme/shop"])

      %{adapter: other} = connectable_adapter_fixture()

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=sources")

      card = "#set-up-grants #set-up-grant-#{grant.public_id}"
      assert words(lv, "#{card}-title") == "#{Apiary.Adapters.title(adapter)} · acme"
      assert words(lv, "#{card}-summary") == "0 of 2 collections"

      assert href(lv, "#{card}-choose") ==
               ~p"/#{organisation}/set-up/choose?#{[step: :sources, grant: grant.public_id, workspace: main.slug]}"

      # The connected adapter is not under Connect another source, which is closed; the
      # other adapter is, and its install leads back to this step of Main.
      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}")
      assert has_element?(lv, "#set-up-connect:not([open]) #set-up-adapter-#{other.public_id}")
      back = URI.encode_query(back: "set-up:sources:workspace=#{main.slug}")

      assert has_element?(
               lv,
               ~s{#set-up-adapter-#{other.public_id}-connect[action="/#{organisation.slug}/settings/integrations/#{other.public_id}/install?#{back}"]}
             )

      assert has_element?(lv, "#set-up-skip")
      refute has_element?(lv, "#set-up-continue")

      # Chosen in the chooser: the card counts it, and the step is done.
      api = collection!(connection, "acme/api")
      {:ok, 1} = Collections.choose(scope, grant, main, :sources, {:only, [api.id]})
      assert words(lv, "#{card}-summary") == "1 of 2 collections"

      assert href(lv, "#set-up-continue") ==
               ~p"/#{organisation}/set-up?step=destinations&workspace=#{main.slug}"

      refute has_element?(lv, "#set-up-skip")

      {:ok, 1} = Collections.choose(scope, grant, main, :sources, :all)
      assert words(lv, "#{card}-summary") == "All collections"
    end

    test "a connection started and not yet back shows Connecting…, and no line for its list",
         %{conn: conn} do
      %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture()
      {_connection, _nonce} = connection_fixture(scope, adapter, :pending)

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=sources")

      assert has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connecting", "Connecting…")
      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connected")
      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-none")
      assert has_element?(lv, "#set-up-skip")
    end

    test "a connected adapter with no grant yet shows Connected, with no card and no Connect", %{
      conn: conn
    } do
      %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture()
      {_connection, _nonce} = connection_fixture(scope, adapter, :connected)

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=sources")

      row = "#set-up-grants #set-up-adapter-#{adapter.public_id}"
      assert has_element?(lv, "#{row}-connected", "Connected")
      refute has_element?(lv, "#{row}-connect")
      refute has_element?(lv, "[id^=set-up-grant-]")
      refute has_element?(lv, "#set-up-connect")
      assert has_element?(lv, "#set-up-skip")
    end

    test "shows the adapter's guide beside the step", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture()
      guide = source_guide_example()
      guided_adapter(adapter, guide)

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=sources&workspace=main")

      help = "#set-up-context #set-up-help-#{adapter.public_id}"
      assert has_element?(lv, help <> " h3", "On #{adapter.name}")

      steps =
        lv
        |> element(help)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

      assert steps == guide["connect"]["steps"]
    end

    test "shows a member who may not connect who may, with no Connect and no guide", %{
      conn: conn
    } do
      %{organisation: organisation} = sign_up_fixture()
      %{adapter: adapter} = connectable_adapter_fixture()
      guided_adapter(adapter, source_guide_example())
      member = joined(organisation, :member)

      {:ok, lv, _html} =
        conn |> log_in_user(member) |> live(~p"/#{organisation}/set-up?step=sources")

      assert has_element?(lv, "#set-up-adapter-#{adapter.public_id}", adapter.name)
      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")
      refute has_element?(lv, "#set-up-help-#{adapter.public_id}")

      assert words(lv, "#set-up-connect-who-may") ==
               "Only owners and admins change the integrations of the organisation."

      # An install sent anyway starts nothing.
      render_click(lv, "install", %{"integration" => adapter.public_id})
      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")

      assert has_element?(lv, "#set-up-skip")
    end
  end

  describe "Destinations" do
    test "with no adapter with targets for the type, shows the line for it", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      %{adapter: tracker} = connectable_adapter_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/#{organisation}/set-up?step=destinations&workspace=main")

      assert words(lv, "#set-up-no-adapter") ==
               "No work destination for this type is set up on this instance. An instance " <>
                 "admin sets one up in Instance settings › Adapters."

      refute has_element?(lv, "#set-up-adapter-#{tracker.public_id}")
      assert has_element?(lv, "#set-up-skip")
    end

    test "lists the adapters with targets alone, under Connect another destination, and the line for later",
         %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      %{adapter: forge} = connectable_adapter_fixture()
      forge = targets!(forge)
      %{adapter: tracker} = connectable_adapter_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/#{organisation}/set-up?step=destinations&workspace=main")

      assert has_element?(lv, "h1", "Which repositories may runs in Main change?")
      assert {"Destinations", :current} in steps(lv)
      assert has_element?(lv, "#set-up-adapter-#{forge.public_id}", forge.name)
      refute has_element?(lv, "#set-up-adapter-#{tracker.public_id}")

      assert words(lv, "#set-up-connect-another") == "Connect another destination"

      assert words(lv, "#set-up-later") ==
               "You can change this later in Workspace settings › Destinations."

      refute has_element?(lv, "#set-up-context #set-up-what")

      assert has_element?(
               lv,
               ~s{#set-up-back[href="/#{organisation.slug}/set-up?step=sources&workspace=main"]}
             )
    end
  end

  describe "the chooser" do
    setup %{conn: conn} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)

      %{user: user, organisation: organisation, workspace: main, scope: scope} =
        sign_up_fixture()

      second = workspace_fixture(organisation, "Second")

      %{
        conn: log_in_user(conn, user),
        organisation: organisation,
        main: main,
        scope: scope,
        second: second
      }
    end

    defp chooser(ctx, step, grant, workspace \\ nil, query \\ []) do
      params = [step: step, grant: grant.public_id, workspace: (workspace || ctx.main).slug]
      ~p"/#{ctx.organisation}/set-up/choose?#{params ++ query}"
    end

    defp row(collection) do
      c = Repo.get!(Collection, collection.id)
      {c.workspace_id, c.backlog}
    end

    defp pick(lv, collection),
      do: lv |> element("#collection-#{collection.public_id}-pick") |> render_click()

    defp save(lv), do: lv |> form("#choose-form") |> render_submit()

    test "Choose opens it on Only selected: a row of another workspace with its name; Save assigns with Backlog on",
         ctx do
      %{adapter: adapter, grant: grant, connection: connection} =
        listed!(ctx.scope, ["acme/api", "acme/shop", "acme/web"])

      [api, shop, web] =
        Enum.map(["acme/api", "acme/shop", "acme/web"], &collection!(connection, &1))

      {:ok, _moved} = set_collection_workspace(web, ctx.second)

      {:ok, step, _html} =
        live(ctx.conn, ~p"/#{ctx.organisation}/set-up?step=sources&workspace=main")

      {:ok, lv, html} =
        step
        |> element("#set-up-grant-#{grant.public_id}-choose")
        |> render_click()
        |> follow_redirect(ctx.conn, chooser(ctx, :sources, grant))

      title = "Choose collections · #{Apiary.Adapters.title(adapter)} · acme"
      assert html =~ title
      assert words(lv, "#choose h1") == title
      assert {"Work sources", :current} in steps(lv)
      assert has_element?(lv, "#choose-only[checked]")
      assert has_element?(lv, "#choose-all:not([checked])")
      assert words(lv, "#choose-count") == "0 selected"

      refute has_element?(lv, "#collection-#{web.public_id}-pick")
      assert words(lv, "#collection-#{web.public_id}-elsewhere") == "In Second (cannot be ticked)"

      pick(lv, api)
      assert words(lv, "#choose-count") == "1 selected"
      step_path = ~p"/#{ctx.organisation}/set-up?step=sources&workspace=main"
      assert href(lv, "#choose-back") == step_path
      assert {:error, {:live_redirect, %{to: ^step_path}}} = save(lv)

      assert row(api) == {ctx.main.id, true}
      assert row(shop) == {nil, true}
      assert row(web) == {ctx.second.id, true}
      assert Repo.aggregate(GrantRule, :count) == 0

      # Opened again, the chosen one is ticked; unticked and saved, it is unassigned.
      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))
      assert has_element?(lv, "#collection-#{api.public_id}-pick[checked]")
      pick(lv, api)
      assert words(lv, "#choose-count") == "0 selected"
      {:error, {:live_redirect, _}} = save(lv)
      assert row(api) == {nil, false}
    end

    test "the search finds by name; the box over the rows selects the page; the selection stays across pages",
         ctx do
      refs = for n <- 1..60, do: "acme/repo-" <> String.pad_leading("#{n}", 2, "0")
      %{grant: grant, connection: connection} = listed!(ctx.scope, refs ++ ["acme/shop"])
      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))

      assert words(lv, "#choose-pager-footer") == "1–50 of 61"
      lv |> element("#choose-table-every") |> render_click()
      assert words(lv, "#choose-count") == "50 selected"

      lv |> element("#choose-pager-next") |> render_click()
      assert_patch(lv, chooser(ctx, :sources, grant, nil, page: 2))
      assert words(lv, "#choose-pager-footer") == "51–61 of 61"
      assert words(lv, "#choose-count") == "50 selected"

      lv |> form("#choose-search", %{q: "shop"}) |> render_change()
      assert_patch(lv, chooser(ctx, :sources, grant, nil, q: "shop"))
      shop = collection!(connection, "acme/shop")
      assert has_element?(lv, "#collection-#{shop.public_id}-pick:not([checked])")
      refute has_element?(lv, "#choose-pager")
      pick(lv, shop)
      assert words(lv, "#choose-count") == "51 selected"

      {:error, {:live_redirect, _}} = save(lv)

      assert Repo.aggregate(
               from(c in Collection, where: c.workspace_id == ^ctx.main.id),
               :count
             ) == 51
    end

    test "All: every free collection, and each one listed later; back to Only selected keeps them",
         ctx do
      %{grant: grant, connection: connection, key: key} =
        listed!(ctx.scope, ["acme/api", "acme/shop"])

      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))
      lv |> form("#choose-form", %{mode: "all"}) |> render_change()
      assert has_element?(lv, "#choose-all[checked]")
      refute has_element?(lv, "#choose-table")
      refute has_element?(lv, "#choose-count")
      {:error, {:live_redirect, _}} = save(lv)

      assert %GrantRule{backlog: true} = Repo.get_by!(GrantRule, grant_id: grant.id)
      assert row(collection!(connection, "acme/api")) == {ctx.main.id, true}

      :ok = list!(key, connection, ["acme/api", "acme/shop", "acme/web"], "second")
      assert row(collection!(connection, "acme/web")) == {ctx.main.id, true}

      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))
      assert has_element?(lv, "#choose-all[checked]")
      lv |> form("#choose-form", %{mode: "only"}) |> render_change()
      assert words(lv, "#choose-count") == "3 selected"
      {:error, {:live_redirect, _}} = save(lv)

      assert Repo.get_by(GrantRule, grant_id: grant.id) == nil
      assert row(collection!(connection, "acme/web")) == {ctx.main.id, true}
    end

    test "Destinations while Work sources is set to All: All alone; another workspace's All: Only selected alone",
         ctx do
      %{grant: grant} = listed!(ctx.scope, ["acme/api"], targets: true)
      {:ok, 1} = Collections.choose(ctx.scope, grant, ctx.main, :sources, :all)

      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :destinations, grant))
      assert {"Destinations", :current} in steps(lv)
      assert has_element?(lv, "#choose-all[checked]")
      refute has_element?(lv, "#choose-only")

      assert words(lv, "#choose-locked") ==
               "Work sources is set to All for acme. Change it there first."

      # A forged Only selected changes nothing.
      render_change(lv, "mode", %{"mode" => "only"})
      assert has_element?(lv, "#choose-all[checked]")

      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant, ctx.second))
      refute has_element?(lv, "#choose-all")
      assert has_element?(lv, "#choose-only[checked]")
      assert words(lv, "#choose-taken") == "All new collections of acme go to Main."
      render_change(lv, "mode", %{"mode" => "all"})
      assert has_element?(lv, "#choose-only[checked]")
    end

    test "an account with no name or one of whitespace: the card, the heading, the browser title and both lines leave it out",
         ctx do
      %{adapter: adapter, grant: grant} = listed!(ctx.scope, ["acme/api"], targets: true)
      {:ok, 1} = Collections.choose(ctx.scope, grant, ctx.main, :sources, :all)
      title = Apiary.Adapters.title(adapter)
      heading = "Choose collections · #{title}"

      # `adapter_grants_account_check` allows a ref with a name of 1 to 1024 characters, or
      # neither, so the empty name is tested on `account/1`.
      assert ApiaryWeb.IntegrationComponents.account(%{account_title: ""}) == nil

      for {ref, account} <- [{nil, nil}, {"acme", " \t\u00A0 "}] do
        {1, _} =
          Repo.update_all(from(g in Grant, where: g.id == ^grant.id),
            set: [account_ref: ref, account_title: account]
          )

        {:ok, step, _html} =
          live(ctx.conn, ~p"/#{ctx.organisation}/set-up?step=destinations&workspace=main")

        assert words(step, "#set-up-grant-#{grant.public_id}-title") == title

        {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :destinations, grant))
        assert words(lv, "#choose h1") == heading
        assert page_title(lv) == "#{heading} · #{Apiary.ProductName.name()}"

        assert words(lv, "#choose-locked") ==
                 "Work sources is set to All for this account. Change it there first."

        {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant, ctx.second))
        assert words(lv, "#choose h1") == heading
        assert words(lv, "#choose-taken") == "All new collections of this account go to Main."
      end
    end

    test "Not listed? shows the adapter's line on its access, with Change access to its Install",
         ctx do
      %{adapter: adapter, grant: grant} = listed!(ctx.scope, ["acme/api"])
      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))
      refute has_element?(lv, "#choose-access")

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
          set: [source_access: "Pick the repositories in the installation's settings."]
        )

      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))

      assert words(lv, "#choose-access") =~
               "Not listed? Pick the repositories in the installation's settings."

      back = URI.encode_query(back: "set-up:sources:workspace=main")

      assert has_element?(
               lv,
               ~s{#choose-change-access[action="/#{ctx.organisation.slug}/settings/integrations/#{adapter.public_id}/install?#{back}"]}
             )

      assert has_element?(lv, "#choose-change-access-install", "Change access")
    end

    test "another organisation's grant, an unknown step or grant is no page; another organisation's collection is not picked",
         ctx do
      %{grant: grant} = listed!(ctx.scope, ["acme/api"])
      %{scope: theirs} = sign_up_fixture()
      %{grant: their_grant, connection: their_connection} = listed!(theirs, ["beta/api"])

      for path <- [
            chooser(ctx, :sources, their_grant),
            chooser(ctx, :elsewhere, grant),
            ~p"/#{ctx.organisation}/set-up/choose?step=sources&grant=ag_0000000000000000&workspace=main",
            ~p"/#{ctx.organisation}/set-up/choose?step=sources&grant=not-a-grant&workspace=main"
          ] do
        assert_raise ApiaryWeb.NotFound, fn -> live(ctx.conn, path) end
      end

      their = collection!(their_connection, "beta/api")
      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))
      render_click(lv, "select", %{"collection" => their.public_id})
      assert words(lv, "#choose-count") == "0 selected"
      {:error, {:live_redirect, _}} = save(lv)
      assert row(their) == {nil, true}
    end

    test "a member sees the choice disabled, no boxes and no Save, and who may; a save sent changes nothing",
         ctx do
      %{grant: grant, connection: connection} = listed!(ctx.scope, ["acme/api"])
      api = collection!(connection, "acme/api")
      member = joined(ctx.organisation, :member)
      conn = log_in_user(build_conn(), member)

      {:ok, step, _html} = live(conn, ~p"/#{ctx.organisation}/set-up?step=sources&workspace=main")

      who_may =
        "Only owners and admins of #{ctx.organisation.name} assign collections to workspaces."

      assert words(step, "#set-up-who-may") == who_may

      {:ok, lv, _html} = live(conn, chooser(ctx, :sources, grant))
      assert has_element?(lv, "#choose-only[disabled]")
      assert has_element?(lv, "#choose-all[disabled]")
      refute has_element?(lv, "#collection-#{api.public_id}-pick")
      refute has_element?(lv, "#choose-save")
      assert words(lv, "#choose-who-may") == who_may

      render_click(lv, "select", %{"collection" => api.public_id})
      render_change(lv, "mode", %{"mode" => "all"})
      render_submit(lv, "save", %{})
      assert row(api) == {nil, true}
      assert Repo.aggregate(GrantRule, :count) == 0
    end
  end

  describe "Harness" do
    @harness_git "https://code.example.com/acme/harness"
    @team_git "https://code.example.com/example-org/team-harness"
    @pin String.duplicate("c3", 20)
    @root_stack "modules:\n  - name: core\n    source: {path: modules/core}\n"
    @one_export %{
      {"R_harness", "harness.yaml"} => "exports:\n  stacks: [triage]\n",
      {"R_harness", "stacks/triage/qory-stack.yaml"} =>
        "modules:\n  - name: core\n    source: {path: modules/core}\n"
    }

    # The paragraphs of About this step, and the texts the step no longer shows.
    @about [
      "A harness is the skills and workflows the agent runs with.",
      "A repository whose harness.yaml or qory.yaml at its root sets a harness runs with " <>
        "that file. Every other repository runs with the stack set for it under " <>
        "Repositories, else with the harness you choose here, else with the Qory harness.",
      "The Qory harness is the harness Qory publishes. Always the latest version uses the " <>
        "newest version this Qory Apiary ships, and moves on when Qory Apiary is upgraded.",
      "A harness repository exports stacks in the qory.yaml or harness.yaml at its root. " <>
        "Qory Apiary reads that file in the repository you pick, and offers only the stacks " <>
        "it exports.",
      "Always the latest on a branch: each run uses the branch's newest commit when it " <>
        "starts. A fixed version uses that tag or commit."
    ]
    @removed [
      "fe3b3ab",
      "A repository's harness file comes first.",
      "Runs in Main use the harness you choose here.",
      "use the harness you choose here.",
      "A repository uses the workspace's harness unless you choose another one for it.",
      "Choose another",
      "Workspace default",
      "Read through the",
      "No connected repository has a qory-stack.yaml file"
    ]

    setup %{conn: conn} do
      %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()

      %{
        conn: log_in_user(conn, user),
        organisation: organisation,
        scope: scope,
        path: ~p"/#{organisation}/set-up?step=harness&workspace=#{scope.workspace}"
      }
    end

    # A linked repository of the organisation, its adapter's stub serving `files` with the
    # pin as its version (`serve_harness/2`); the adapter's fixture.
    defp linked_harness!(ctx, files) do
      adapter = Apiary.HarnessReadsFixtures.call_adapter_fixture()
      {connection, _nonce} = connection_fixture(ctx.scope, adapter.adapter, :listed)

      Apiary.HarnessReadsFixtures.live_grant_fixture(
        ctx.organisation.id,
        adapter.adapter,
        connection,
        "G_acme"
      )

      Apiary.HarnessReadsFixtures.harness_collection_fixture(
        connection,
        @harness_git,
        "acme/harness"
      )

      serve_harness(adapter, files)
      adapter
    end

    # The linked repository of `linked_harness!/2` ends, so the organisation has no
    # connected repository the list shows.
    defp end_harness_collection! do
      {1, _} =
        Repo.update_all(from(c in Collection, where: c.url == @harness_git),
          set: [ended_at: DateTime.utc_now(), ended_reason: :not_listed]
        )
    end

    defp serve_harness(adapter, files, opts \\ []) do
      Apiary.HarnessReadsFixtures.serve_calls(
        [adapter],
        [
          covered: %{adapter.adapter.id => %{@harness_git => {"G_acme", "R_harness"}}},
          files: files,
          versions: %{"R_harness" => @pin}
        ] ++ opts
      )
    end

    # The calls the stub adapters received since the last drain.
    defp harness_calls do
      receive do
        {:harness_call, path, call} -> [{path, call} | harness_calls()]
      after
        0 -> []
      end
    end

    defp linked_id, do: "linked:" <> Repo.get_by!(Collection, url: @harness_git).public_id

    # The Harness form with a harness repository and acme/harness chosen, its exports read.
    defp pick_repository(lv) do
      lv |> form("#set-up-harness-form", harness: %{choice: "repository"}) |> render_change()
      lv |> form("#set-up-harness-form", harness: %{source: linked_id()}) |> render_change()
      render_async(lv, 2_000)
      lv
    end

    defp ids(lv, selector) do
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("id")
    end

    test "after Model: the two choices, the Qory harness at Always the latest version; Continue saves it",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      workspace = ctx.scope.workspace

      assert has_element?(lv, "h1", "Which harness do runs in #{workspace.name} use?")

      assert [
               {"Model", _state},
               {"Harness", :current},
               {"Machines", :to_come},
               {"Test run", :to_come}
             ] = lv |> steps() |> Enum.take(-4) |> Enum.map(&{elem(&1, 0), elem(&1, 1)})

      refute has_element?(lv, "#harness-intro")
      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      assert words(lv, "#harness-choice-qory") == "Qory harness"

      assert ["harness-choice-qory", "harness-choice-repository"] ==
               ids(lv, "#harness-choice > label")

      assert words(lv, "#harness-choice-repository") == "A harness repository"

      # Version: the newest, chosen; a fixed version waits for the first release.
      assert words(lv, "#harness-qory-version legend") == "Version"
      assert has_element?(lv, "#harness-qory-version-latest[checked]")

      assert words(lv, ~s(label[for="harness-qory-version-latest"])) ==
               "Always the latest version"

      assert has_element?(lv, "#harness-qory-version-named[disabled]")
      refute has_element?(lv, "#harness-qory-version-named[checked]")
      assert words(lv, ~s(label[for="harness-qory-version-named"])) == "A fixed version"

      assert words(lv, "#harness-qory-version-none") ==
               "Named versions come with the first release of the Qory harness."

      # A workspace with no destination lists none.
      refute has_element?(lv, "#harness-targets")
      refute has_element?(lv, "#harness-repository")

      assert words(lv, "#set-up-later") ==
               "You can change this later in Workspace settings › Workflow."

      # About this step has the five paragraphs, and no text the step dropped shows.
      assert words(lv, "#set-up-context-h") == "About this step"

      assert for(id <- ids(lv, "#set-up-context p"), do: words(lv, "##{id}")) == @about

      html = render(lv)
      for text <- @removed, do: refute(html =~ text, text)

      lv |> form("#set-up-harness-form") |> render_submit()
      assert_patch(lv, ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{workspace}")

      assert %Apiary.Stacks.Stack{choice: :qory, version_kind: :latest} =
               Apiary.Stacks.choice(workspace)

      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      assert {"Harness", :current} in Enum.map(steps(lv), &{elem(&1, 0), elem(&1, 1)})
      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      assert has_element?(lv, "#harness-qory-version-latest[checked]")
      row = Apiary.Stacks.choice(workspace)

      # The saved choice, sent again, goes on with no save.
      lv |> form("#set-up-harness-form") |> render_submit()
      assert_patch(lv, ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{workspace}")
      assert Apiary.Stacks.choice(workspace).updated_at == row.updated_at
    end

    test "a choice that is no longer offered saves nothing", ctx do
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_click(lv, "save_harness", %{"harness" => %{"choice" => "target_file"}})
      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    test "a fixed version of the Qory harness the release does not ship saves nothing", ctx do
      {:ok, lv, _html} = live(ctx.conn, ctx.path)

      render_click(lv, "save_harness", %{
        "harness" => %{"choice" => "qory", "qory_version" => "named", "qory_name" => "v1"}
      })

      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    test "the organisation's shared harness shows as the saved choice, and Continue goes on",
         ctx do
      {:ok, _row} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)

      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      # The core shows no setting to share a harness, so it lists no shared harness.
      refute has_element?(lv, "#harness-choice-shared-group")
      refute render(lv) =~ "Shared in"

      # The saved choice goes on with no save.
      lv |> form("#set-up-harness-form") |> render_submit()

      assert_patch(
        lv,
        ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{ctx.scope.workspace}"
      )

      # The workspace has no choice row: it takes the shared one.
      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    # The Qory harness row and its Version, as the step draws them.
    defp qory_row(lv) do
      for selector <- ["#harness-choice-qory", "#harness-qory-version"],
          do: lv |> element(selector) |> render()
    end

    test "the Qory harness row is the same with no shared harness, a shared Qory harness, a shared harness repository, and a workspace's Qory harness under a shared Qory harness",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)

      path = fn workspace ->
        ~p"/#{ctx.organisation}/set-up?step=harness&workspace=#{workspace}"
      end

      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      plain = qory_row(lv)
      refute has_element?(lv, "#set-up-harness-everywhere")

      # The organisation shares the Qory harness: one workspace reuses it, and another
      # workspace has a saved Qory harness choice.
      {:ok, _shared} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      reuses = workspace_fixture(ctx.organisation, "Second")
      saved = workspace_fixture(ctx.organisation, "Third")
      {:ok, _row} = Apiary.Stacks.Sources.choose(%{ctx.scope | workspace: saved}, :qory)

      for workspace <- [reuses, saved] do
        {:ok, lv, _html} = live(ctx.conn, path.(workspace))
        assert qory_row(lv) == plain
        refute render(lv) =~ "every workspace"
        refute has_element?(lv, "#harness-choice-shared")
        refute has_element?(lv, "#set-up-harness-everywhere")
      end

      # The organisation shares a harness repository: the Qory harness row, once chosen.
      share_repository!(ctx)
      {:ok, lv, _html} = live(ctx.conn, path.(reuses))
      assert has_element?(lv, "#harness-choice-shared-radio[checked]")
      assert has_element?(lv, "#set-up-harness-everywhere")
      lv |> form("#set-up-harness-form", harness: %{choice: "qory"}) |> render_change()
      assert qory_row(lv) == plain
      refute has_element?(lv, "#set-up-harness-everywhere")
    end

    test "with the setting shown, a shared Qory harness is the Qory harness row with its Version and no setting; Continue saves nothing",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, _row} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      second = workspace_fixture(ctx.organisation, "Second")
      path = ~p"/#{ctx.organisation}/set-up?step=harness&workspace=#{second}"
      {:ok, lv, _html} = live(ctx.conn, path)

      refute has_element?(lv, "#harness-choice-shared-group")
      refute has_element?(lv, "#harness-choice-shared")
      refute render(lv) =~ "Shared in"
      refute render(lv) =~ "every workspace"
      refute render(lv) =~ "fe3b3ab"

      assert words(lv, "#harness-choice-qory") == "Qory harness"
      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      refute has_element?(lv, "#harness-choice-repository-radio[checked]")
      assert has_element?(lv, "#harness-qory-version-latest[checked]")
      assert has_element?(lv, "#harness-qory-version-named[disabled]")

      assert ["harness-choice-qory", "harness-choice-repository"] ==
               ids(lv, "#harness-choice label")

      # With the Qory harness chosen, the setting does not show.
      refute has_element?(lv, "#set-up-harness-everywhere")

      lv |> form("#set-up-harness-form") |> render_submit()
      assert_patch(lv, ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{second}")
      assert Apiary.Stacks.choice(second) == nil
      assert %{choice: :qory} = Apiary.Stacks.shared(ctx.organisation)
    end

    test "with the setting shown, a shared Qory harness at a named version is the Qory harness row, with no mark and no line",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)

      {:ok, _shared} =
        Apiary.Stacks.put_stack(
          ctx.scope,
          {:organisation, ctx.organisation},
          "extends:\n  git: \"https://github.com/qoryai/harness\"\n  ref: \"#{@pin}\"\n  stack: \"core\"\n",
          choice: :qory,
          version: {:named, "v1"}
        )

      {:ok, lv, _html} = live(ctx.conn, ctx.path)

      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      assert words(lv, "#harness-choice-qory") == "Qory harness"
      refute has_element?(lv, "#harness-choice-shared")
      refute render(lv) =~ "every workspace"
      assert has_element?(lv, "#harness-qory-version")
    end

    test "with the setting shown, a shared harness repository on a branch or at a tag shows its stack, repository and version under its title, with no field",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)

      for {version, line} <- [
            {{:branch, "main"}, "triage · acme/harness · main"},
            {{:tag, "v1"}, "triage · acme/harness · v1"}
          ] do
        {:ok, _shared} =
          Apiary.Stacks.put_stack(
            ctx.scope,
            {:organisation, ctx.organisation},
            "extends:\n  git: \"#{@harness_git}\"\n  ref: \"#{elem(version, 1)}\"\n  stack: \"triage\"\n",
            choice: :repository,
            version: version
          )

        {:ok, lv, _html} = live(ctx.conn, ctx.path)

        assert has_element?(lv, "#harness-choice-shared-radio[checked]")

        assert words(lv, "#harness-choice-shared .q-choice-h") ==
                 "A harness repository · every workspace"

        assert words(lv, "#harness-choice-shared-line") == line
        refute has_element?(lv, "#harness-version")
        refute has_element?(lv, "#harness-qory-version")
        refute has_element?(lv, "#harness-choice-shared-group input[type=text]")
      end
    end

    test "with the setting shown and no shared harness: no heading, the two choices", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)

      refute has_element?(lv, "#harness-choice-shared-group")
      refute render(lv) =~ "Shared in"
      assert has_element?(lv, "#harness-choice-qory-radio[checked]")

      assert ["harness-choice-qory", "harness-choice-repository"] ==
               ids(lv, "#harness-choice label")
    end

    # The organisation's shared harness: a harness repository's root at the pin, saved
    # with no version, as a save before versions wrote it.
    defp share_repository!(ctx) do
      {:ok, shared} =
        Apiary.Stacks.put_stack(
          ctx.scope,
          {:organisation, ctx.organisation},
          "extends:\n  git: \"#{@harness_git}\"\n  ref: \"#{@pin}\"\n",
          choice: :repository
        )

      shared
    end

    test "with the setting shown, a workspace with a choice sees the shared harness first, not chosen; choosing it removes the workspace's choice",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      second = workspace_fixture(ctx.organisation, "Second")
      {:ok, _row} = Apiary.Stacks.Sources.choose(%{ctx.scope | workspace: second}, :qory)
      share_repository!(ctx)
      path = ~p"/#{ctx.organisation}/set-up?step=harness&workspace=#{second}"
      {:ok, lv, _html} = live(ctx.conn, path)

      assert words(lv, "#harness-choice-shared-h") == "Shared in #{ctx.organisation.name}"

      # The shared harness repository: its stack, repository and version, the commit's
      # first 7 characters.
      assert words(lv, "#harness-choice-shared .q-choice-h") ==
               "A harness repository · every workspace"

      assert words(lv, "#harness-choice-shared .q-choice-p") ==
               "qory-stack.yaml · acme/harness · c3c3c3c"

      refute has_element?(lv, "#harness-choice-shared-radio[checked]")
      assert has_element?(lv, "#harness-choice-qory-radio[checked]")

      # The shared harness comes first, then the two choices.
      assert ["harness-choice-shared", "harness-choice-qory", "harness-choice-repository"] ==
               ids(lv, "#harness-choice label")

      lv |> form("#set-up-harness-form", harness: %{choice: "shared"}) |> render_submit()
      assert_patch(lv, ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{second}")

      assert Apiary.Stacks.choice(second) == nil
      assert %{choice: :repository, shared: true} = Apiary.Stacks.Sources.chosen(second)

      # Back on the step: the shared harness, chosen.
      {:ok, lv, _html} = live(ctx.conn, path)
      assert has_element?(lv, "#harness-choice-shared-radio[checked]")
    end

    test "with the setting shown, a workspace whose choice is the Qory harness under a shared Qory harness sees the Qory harness row chosen; Continue removes the workspace's choice",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, _shared} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      second = workspace_fixture(ctx.organisation, "Second")
      {:ok, _row} = Apiary.Stacks.Sources.choose(%{ctx.scope | workspace: second}, :qory)
      assert %{choice: :qory, shared: false} = Apiary.Stacks.Sources.chosen(second)
      path = ~p"/#{ctx.organisation}/set-up?step=harness&workspace=#{second}"
      {:ok, lv, _html} = live(ctx.conn, path)

      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      assert has_element?(lv, "#harness-qory-version-latest[checked]")
      refute has_element?(lv, "#harness-choice-shared")

      lv |> form("#set-up-harness-form") |> render_submit()
      assert_patch(lv, ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{second}")

      assert Apiary.Stacks.choice(second) == nil
      assert %{choice: :qory, shared: true} = Apiary.Stacks.Sources.chosen(second)
    end

    # A second workspace with the Qory harness saved at `pin` with no version, as a save
    # before versions wrote it, and its set-up path.
    defp qory_at!(ctx, pin) do
      second = workspace_fixture(ctx.organisation, "Second")
      {:ok, row} = Apiary.Stacks.Sources.choose(%{ctx.scope | workspace: second}, :qory)
      harness = String.replace(row.harness, ~r/ref: "[^"]+"/, ~s(ref: "#{pin}"))

      {1, _} =
        Repo.update_all(from(s in Apiary.Stacks.Stack, where: s.id == ^row.id),
          set: [harness: harness, version_kind: nil]
        )

      {second, ~p"/#{ctx.organisation}/set-up?step=harness&workspace=#{second}"}
    end

    test "with the setting shown, a workspace's Qory harness at a pin other than the shared Qory harness's is the Qory harness row, chosen; Continue saves it at the newest version",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, _shared} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      other = "0123456789abcdef0123456789abcdef01234567"
      {second, path} = qory_at!(ctx, other)
      row = Apiary.Stacks.choice(second)
      {:ok, lv, _html} = live(ctx.conn, path)

      refute has_element?(lv, "#harness-choice-shared-group")
      refute has_element?(lv, "#harness-choice-shared")
      assert words(lv, "#harness-choice-qory") == "Qory harness"
      refute render(lv) =~ "0123456"
      assert has_element?(lv, "#harness-choice-qory-radio[checked]")

      assert ["harness-choice-qory", "harness-choice-repository"] ==
               ids(lv, "#harness-choice label")

      lv |> form("#set-up-harness-form") |> render_submit()
      assert_patch(lv, ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{second}")

      assert %{id: id, version_kind: :latest} = Apiary.Stacks.choice(second)
      assert id == row.id

      assert %{choice: :qory, version: :latest, shared: false} =
               Apiary.Stacks.Sources.chosen(second)
    end

    test "with the setting sent, a workspace's Qory harness at the shared Qory harness's pin is one row; Continue removes the choice with no refusal",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, _shared} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      %{pin: pin} = Apiary.Stacks.Sources.shared(ctx.organisation)
      {second, path} = qory_at!(ctx, pin)
      {:ok, lv, _html} = live(ctx.conn, path)

      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      refute has_element?(lv, "#harness-choice-shared")
      refute has_element?(lv, "#set-up-harness-everywhere")

      # A tick sent anyway changes nothing.
      render_click(lv, "save_harness", %{
        "harness" => %{"choice" => "qory", "qory_version" => "latest", "everywhere" => "true"}
      })

      assert_patch(lv, ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{second}")
      refute has_element?(lv, "#set-up-harness-refusal")
      assert Apiary.Stacks.choice(second) == nil
      assert %{choice: :qory, shared: true} = Apiary.Stacks.Sources.chosen(second)
    end

    test "with the setting shown and a shared harness repository, a usual choice of a harness repository is saved as the workspace's",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      share_repository!(ctx)
      linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)

      assert has_element?(lv, "#harness-choice-shared-radio[checked]")

      pick_repository(lv)

      lv
      |> form("#set-up-harness-form", harness: %{version: "fixed", fixed: @pin})
      |> render_submit()

      render_async(lv, 2_000)

      assert_patch(
        lv,
        ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{ctx.scope.workspace}"
      )

      assert %{choice: :repository, harness: harness, version_kind: :commit} =
               Apiary.Stacks.choice(ctx.scope.workspace)

      assert harness ==
               "extends:\n  git: \"#{@harness_git}\"\n  ref: \"#{@pin}\"\n  stack: \"triage\"\n"

      assert %{choice: :repository} = Apiary.Stacks.shared(ctx.organisation)
    end

    test "a workspace's choice stays as it is when the organisation shares a harness later",
         ctx do
      {:ok, row} = Apiary.Stacks.Sources.choose(ctx.scope, :qory)
      share_repository!(ctx)

      assert Apiary.Stacks.choice(ctx.scope.workspace).id == row.id

      assert %{choice: :qory, shared: false} =
               Apiary.Stacks.Sources.chosen(ctx.scope.workspace)
    end

    test "without the edition's setting, the step shows no setting to share the harness",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      refute has_element?(lv, "#set-up-harness-everywhere")

      # A tick sent anyway saves the workspace's choice, and shares nothing.
      render_click(lv, "save_harness", %{
        "harness" => %{"choice" => "qory", "everywhere" => "true"}
      })

      assert %{choice: :qory} = Apiary.Stacks.choice(ctx.scope.workspace)
      assert Apiary.Stacks.shared(ctx.organisation) == nil
    end

    test "with the setting shown, it shows for a harness repository only; on, Continue saves the harness the organisation shares",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)

      # With the Qory harness chosen, the setting does not show.
      assert has_element?(lv, "#harness-choice-qory-radio[checked]")
      refute has_element?(lv, "#set-up-harness-everywhere")

      pick_repository(lv)

      assert has_element?(
               lv,
               "#set-up-harness-form label",
               "Available to every workspace in #{ctx.organisation.name}"
             )

      refute has_element?(lv, "#set-up-harness-everywhere[checked]")

      lv
      |> form("#set-up-harness-form", harness: %{everywhere: "true"})
      |> render_submit()

      render_async(lv, 2_000)

      assert_patch(
        lv,
        ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{ctx.scope.workspace}"
      )

      assert %{choice: :repository, version_kind: :branch} =
               Apiary.Stacks.shared(ctx.organisation)

      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
      assert Apiary.WorkspaceSetup.harness?(ctx.scope.workspace)
    end

    test "with the setting shown, a tick sent with the Qory harness saves the workspace's choice and shares nothing",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)

      render_click(lv, "save_harness", %{
        "harness" => %{"choice" => "qory", "qory_version" => "latest", "everywhere" => "true"}
      })

      assert %{choice: :qory, version_kind: :latest} = Apiary.Stacks.choice(ctx.scope.workspace)
      assert Apiary.Stacks.shared(ctx.organisation) == nil
    end

    test "with the setting on, a reused shared harness goes on with no save", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      shared = share_repository!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)

      assert has_element?(lv, "#harness-choice-shared-radio[checked]")

      lv
      |> form("#set-up-harness-form", harness: %{everywhere: "true"})
      |> render_submit()

      assert_patch(
        lv,
        ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{ctx.scope.workspace}"
      )

      assert Apiary.Stacks.shared(ctx.organisation).updated_at == shared.updated_at
      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    test "while the organisation shares a harness, sharing another is refused with the fix first",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      shared = share_repository!(ctx)
      linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      assert has_element?(lv, "#harness-choice-shared-radio[checked]")

      assert words(lv, "#harness-choice-shared .q-choice-h") ==
               "A harness repository · every workspace"

      assert words(lv, "#harness-choice-shared .q-choice-p") ==
               "qory-stack.yaml · acme/harness · c3c3c3c"

      pick_repository(lv)

      lv
      |> form("#set-up-harness-form", harness: %{everywhere: "true"})
      |> render_submit()

      render_async(lv, 2_000)

      assert has_element?(lv, ~s(#set-up-harness-refusal[data-reason="shared"]))

      assert words(lv, "#set-up-harness-refusal") ==
               "Choose the shared harness, or turn off “Available to every workspace in " <>
                 "#{ctx.organisation.name}”. #{ctx.organisation.name} shares a harness already."

      assert Apiary.Stacks.shared(ctx.organisation).id == shared.id
      assert Apiary.Stacks.shared(ctx.organisation).choice == :repository
      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil

      # With the setting off, the same choice is the workspace's.
      lv
      |> form("#set-up-harness-form", harness: %{everywhere: "false"})
      |> render_submit()

      render_async(lv, 2_000)

      assert %{choice: :repository} = Apiary.Stacks.choice(ctx.scope.workspace)
    end

    test "while the organisation shares the Qory harness, sharing a harness repository replaces it",
         ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, shared} = Apiary.Stacks.Sources.choose(ctx.scope, :qory, shared: true)
      second = workspace_fixture(ctx.organisation, "Second")
      linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      refute has_element?(lv, "#harness-choice-shared")

      pick_repository(lv)

      lv
      |> form("#set-up-harness-form", harness: %{everywhere: "true"})
      |> render_submit()

      render_async(lv, 2_000)

      assert_patch(
        lv,
        ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{ctx.scope.workspace}"
      )

      assert %{id: id, choice: :repository, version_kind: :branch} =
               Apiary.Stacks.shared(ctx.organisation)

      assert id == shared.id
      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil

      for workspace <- [ctx.scope.workspace, second] do
        assert %{choice: :repository, git: @harness_git, shared: true} =
                 Apiary.Stacks.Sources.chosen(workspace)
      end
    end

    test "a harness repository with one stack: Repository lists the connected repositories with no read, the stack is chosen, and Continue saves the branch",
         ctx do
      adapter = linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      harness_calls()

      lv |> form("#set-up-harness-form", harness: %{choice: "repository"}) |> render_change()

      # Repository is a choice with a search box and no repository chosen; listing them
      # made no call.
      assert words(lv, "#harness-source-label") == "Repository"
      assert has_element?(lv, "button#harness-source.is-prompt", "Find a repository")
      assert has_element?(lv, ~s(#harness-source-search[placeholder="Find a repository"]))

      assert has_element?(
               lv,
               ~s|#harness-source-options input[value="#{linked_id()}"]:not([checked])|
             )

      refute has_element?(lv, "#harness-source-none")
      assert harness_calls() == []
      refute has_element?(lv, "#harness-stack")
      assert has_element?(lv, "#set-up-continue[disabled]")

      # Version: the latest on main, chosen; a fixed version with its placeholder.
      assert words(lv, "#harness-version legend") == "Version"
      assert has_element?(lv, "#harness-version-branch[checked]")
      assert words(lv, ~s(label[for="harness-version-branch"])) == "Always the latest on"
      assert has_element?(lv, "#harness-branch[value=main]")
      assert words(lv, ~s(label[for="harness-version-fixed"])) == "A fixed version"
      assert has_element?(lv, ~s(#harness-fixed[placeholder="tag or commit"]))

      # A pick reads the repository's exports, and its one stack is chosen.
      lv |> form("#set-up-harness-form", harness: %{source: linked_id()}) |> render_change()
      render_async(lv, 2_000)

      assert has_element?(lv, "button#harness-source .q-pick-t.mono", "acme/harness")
      assert words(lv, "#harness-stack legend") == "Stack"
      assert has_element?(lv, ~s(#harness-stack input[value="triage"][checked]))

      reads =
        for {"read", call} <- harness_calls(),
            do: {call["path"], call["at"]}

      assert {"harness.yaml", "HEAD"} in reads

      serve_harness(adapter, @one_export)
      lv |> form("#set-up-harness-form") |> render_submit()
      render_async(lv, 2_000)

      assert_patch(
        lv,
        ~p"/#{ctx.organisation}/set-up?step=machines&workspace=#{ctx.scope.workspace}"
      )

      assert %{choice: :repository, harness: harness, version_kind: :branch, version_name: "main"} =
               Apiary.Stacks.choice(ctx.scope.workspace)

      assert harness ==
               "extends:\n  git: \"#{@harness_git}\"\n  ref: \"main\"\n  stack: \"triage\"\n"

      # Back on the step: the repository, its stack and its branch, chosen.
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      assert has_element?(lv, "#harness-choice-repository-radio[checked]")
      assert has_element?(lv, ~s(#harness-source-options input[value="#{linked_id()}"][checked]))
      assert has_element?(lv, ~s(#harness-stack input[value="triage"][checked]))
      assert has_element?(lv, "#harness-version-branch[checked]")
      assert has_element?(lv, "#harness-branch[value=main]")
    end

    test "a harness repository with two stacks: none is chosen until the person picks one",
         ctx do
      files =
        @one_export
        |> Map.put({"R_harness", "harness.yaml"}, "exports:\n  stacks: [triage, review]\n")
        |> Map.put({"R_harness", "stacks/review/qory-stack.yaml"}, @root_stack)

      linked_harness!(ctx, files)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      assert has_element?(lv, ~s|#harness-stack input[value="triage"]:not([checked])|)
      assert has_element?(lv, ~s|#harness-stack input[value="review"]:not([checked])|)
      assert has_element?(lv, "#set-up-continue[disabled]")

      lv |> form("#set-up-harness-form", harness: %{stack: "review"}) |> render_change()
      refute has_element?(lv, "#set-up-continue[disabled]")

      lv
      |> form("#set-up-harness-form", harness: %{version: "branch", branch: "release"})
      |> render_submit()

      render_async(lv, 2_000)

      assert %{harness: harness, version_kind: :branch, version_name: "release"} =
               Apiary.Stacks.choice(ctx.scope.workspace)

      assert harness =~ ~s(stack: "review")
    end

    test "a harness repository that exports no stack: the line in place of Stack, and Continue stays off",
         ctx do
      linked_harness!(ctx, %{{"R_harness", "qory-stack.yaml"} => @root_stack})
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      assert words(lv, "#harness-stack-none") ==
               "acme/harness exports no stack. Add a qory.yaml or harness.yaml at its root " <>
                 "that lists the stack under exports."

      refute has_element?(lv, "#harness-stack")
      assert has_element?(lv, "#set-up-continue[disabled]")

      lv |> form("#set-up-harness-form") |> render_submit()
      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    test "a fixed version: a full commit id saves as a commit, any other name as a tag",
         ctx do
      adapter = linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      lv
      |> form("#set-up-harness-form",
        harness: %{version: "fixed", fixed: String.upcase(@pin)}
      )
      |> render_submit()

      render_async(lv, 2_000)

      assert %{version_kind: :commit, version_name: @pin} =
               Apiary.Stacks.choice(ctx.scope.workspace)

      serve_harness(adapter, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)

      # The saved commit shows in its field.
      assert has_element?(lv, "#harness-version-fixed[checked]")
      assert has_element?(lv, "#harness-fixed[value=#{@pin}]")

      lv
      |> form("#set-up-harness-form", harness: %{version: "fixed", fixed: "v2"})
      |> render_submit()

      render_async(lv, 2_000)

      assert %{version_kind: :tag, version_name: "v2", harness: harness} =
               Apiary.Stacks.choice(ctx.scope.workspace)

      assert harness =~ ~s(ref: "v2")
    end

    test "a tag or a branch the read does not find, or that is no version: correct it", ctx do
      adapter = linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      # A ref under refs/ that is no branch or tag breaks the save rule of refs.
      lv
      |> form("#set-up-harness-form", harness: %{version: "fixed", fixed: "refs/pull/1/head"})
      |> render_submit()

      render_async(lv, 2_000)

      assert has_element?(lv, "#set-up-harness-refusal[data-reason=invalid]")

      assert words(lv, "#set-up-harness-refusal") ==
               "Correct the version: give a branch or tag name, refs/heads/<name>, " <>
                 "refs/tags/<name> or a full commit id. People without write access can " <>
                 "change other refs, such as a pull request's."

      # A ref that is no version a read takes.
      lv |> form("#set-up-harness-form", harness: %{fixed: "v 9"}) |> render_submit()
      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "Correct the version: a branch, tag or commit name has 1 to 255 letters, " <>
                 "digits, dots, underscores, slashes and hyphens, and no spaces."

      # The read finds no tag v9, and no branch no-such.
      serve_harness(adapter, @one_export,
        refuse_at: %{"v9" => "version_not_found", "no-such" => "version_not_found"}
      )

      lv |> form("#set-up-harness-form", harness: %{fixed: "v9"}) |> render_submit()
      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "acme/harness has no branch, tag or commit named v9. Correct the version."

      lv
      |> form("#set-up-harness-form", harness: %{version: "branch", branch: "no-such"})
      |> render_submit()

      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "acme/harness has no branch, tag or commit named no-such. Correct the version."

      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    test "a stack the walk finds no stack file for: add it, and nothing saved", ctx do
      files = Map.delete(@one_export, {"R_harness", "stacks/triage/qory-stack.yaml"})
      linked_harness!(ctx, files)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      lv |> form("#set-up-harness-form") |> render_submit()
      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "acme/harness lists the stack triage under exports, but stacks/triage has no " <>
                 "qory-stack.yaml. Add that file."

      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    test "a repository whose exports cannot be read shows the reason under Repository", ctx do
      adapter = linked_harness!(ctx, %{})
      Apiary.HarnessReadsFixtures.serve_calls([adapter], covered: %{}, files: %{})
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      assert words(lv, "#harness-stack-error") ==
               "Link acme/harness to #{ctx.organisation.name}, or ask an instance admin to " <>
                 "assign it: Qory Apiary reads a harness repository that is not public only " <>
                 "through a linked repository or an assignment."

      assert has_element?(lv, "#set-up-continue[disabled]")
    end

    test "a repository its adapter cannot be reached for: try again, with the adapter's name",
         ctx do
      adapter = linked_harness!(ctx, @one_export)
      serve_harness(adapter, @one_export, down: true)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      assert words(lv, "#harness-stack-error") ==
               "Qory Apiary could not connect to the #{Apiary.Adapters.title(adapter.adapter)} " <>
                 "adapter. Try again. If it repeats, an instance admin checks that the adapter " <>
                 "is running."

      assert has_element?(lv, "#set-up-continue[disabled]")
    end

    test "a repository whose harness.yaml is not valid: correct the file", ctx do
      linked_harness!(ctx, %{{"R_harness", "harness.yaml"} => "exports: [triage\n"})
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      assert words(lv, "#harness-stack-error") ==
               "Correct harness.yaml in acme/harness: is not valid YAML."

      assert has_element?(lv, "#set-up-continue[disabled]")
    end

    # A read task that raises reports `{:exit, reason}` to the page, which shows
    # `:exited`'s words. A stub cannot make the read task raise: each call runs in a task
    # under `Apiary.Adapters.Calls.Supervisor`, and a raise there is an unreachable adapter.
    test "a read whose task exits: try again" do
      assert ApiaryWeb.HarnessComponents.read_words(:exited, %{label: "acme/harness"}, "Acme") ==
               "Qory Apiary could not read acme/harness because of an error in Qory Apiary. " <>
                 "Try again. If it repeats, tell an instance admin."
    end

    # The walk's failures of a save, as `Apiary.Harnesses.Walk.pin_base/3` returns them.
    # A failure's `source` is the chosen address for the chosen source, and for a module
    # that the base's qory-stack.yaml lists at a local path or at the chosen address; it
    # is the module's address for a module at another address.
    test "a save refused for an address, for the harness's content, or on an error of the walk" do
      source = %{label: "acme/harness", git: @harness_git, narrowing: %{}}
      chosen = "https://code.example.com/acme/harness"

      failure = fn code, shown, rule ->
        {:walk,
         %{
           failure: code,
           source: shown,
           rule: rule,
           adapter: nil,
           adapter_id: nil,
           call_failure: nil
         }}
      end

      words = &ApiaryWeb.HarnessComponents.refusal_words(&1, source, "main", "Acme")
      harness = "Correct the harness in acme/harness: "

      # The chosen source's address or folder, before any call: the form rule it breaks.
      for {rule, line} <- [
            {%{"rule" => "host", "values" => %{}},
             "Correct the address: give a public host name, not an IP address or a local name."},
            {%{"rule" => "host_encoded", "values" => %{}},
             "Correct the address: write the host name without a percent-encoding."}
          ] do
        assert words.(failure.(:invalid, chosen, rule)) == line
      end

      # The folder the chosen source is narrowed to.
      for {rule, path, line} <- [
            {"path", "../x", "Correct the folder: ../x leads out of acme/harness."},
            {"path_form", "a%2f",
             "Correct the folder: write a%2f with / and no backslash or percent sign."}
          ] do
        assert ApiaryWeb.HarnessComponents.refusal_words(
                 failure.(:invalid, chosen, %{"rule" => rule, "values" => %{"path" => path}}),
                 %{source | narrowing: %{"path" => path}},
                 "main",
                 "Acme"
               ) == line
      end

      for {git, line} <- [
            {"https://a b/c",
             "Correct the address: an address has no space or control character."},
            {"https://user:password@example.com/c",
             "Correct the address: remove the user name and password from it."},
            {"http://example.com/c",
             "Correct the address: start it with https://. Qory Apiary reads harness sources " <>
               "over https only."},
            {"https://example.com/c?q",
             "Correct the address: an address has no query (?) and no fragment (#)."},
            {"https://example.com:99999/c",
             "Correct the address: write it as https://, a host, an optional port and an " <>
               "optional path."}
          ] do
        {message, values} = Apiary.Stacks.Document.source_error(%{"git" => git}, :base)

        rule = %{
          "message" => message,
          "values" => Map.new(values, fn {k, v} -> {to_string(k), v} end)
        }

        assert words.(failure.(:invalid, chosen, rule)) == line
      end

      assert words.(failure.(:scp_form, chosen, nil)) ==
               "Correct the address: write it as https://, a host and a path, not as " <>
                 "user@host:path."

      assert words.(failure.(:credential_in_address, chosen, nil)) ==
               "Correct the address: remove the user name and password from it."

      reads = &ApiaryWeb.HarnessComponents.read_words(&1, source, "Acme")

      assert reads.({:unreadable, :address}) ==
               "Correct the address: write it as https://, a host, an optional port and an " <>
                 "optional path."

      assert reads.({:unreadable, :path, "../x/qory-stack.yaml"}) ==
               "Correct the folder: a folder is a relative path with no empty, . or .. part, " <>
                 "at most 1,024 characters long."

      assert reads.({:unreadable, :version, "v 9"}) ==
               "Correct the version: a branch, tag or commit name has 1 to 255 letters, digits, " <>
                 "dots, underscores, slashes and hyphens, and no spaces."

      # A module's address, folder or ref, which the harness document lists.
      assert words.(
               failure.(:invalid, "https://localhost/acme/x", %{
                 "rule" => "host",
                 "values" => %{}
               })
             ) ==
               harness <> "its host is an IP address or a local name: give a public host name."

      assert words.(
               failure.(:invalid, "http://code.example.com/acme/x", %{
                 "message" =>
                   "write %{source} as an https address: Qory Apiary fetches harness sources " <>
                     "over https only",
                 "values" => %{"source" => "http://code.example.com/acme/x"}
               })
             ) ==
               harness <>
                 "write http://code.example.com/acme/x as an https address: Qory Apiary " <>
                 "fetches harness sources over https only."

      assert words.(failure.(:scp_form, "code.example.com:acme/x", nil)) ==
               harness <> "it lists a module at an SSH address: give the module's https address."

      assert words.(failure.(:credential_in_address, "https://code.example.com/acme/x", nil)) ==
               harness <>
                 "it lists a module address with a credential in it: remove the credential."

      assert words.(
               failure.(:invalid, "https://code.example.com/acme/x", %{
                 "message" =>
                   "write the ref %{ref} as HEAD, a branch or tag name, refs/heads/<name>, " <>
                     "refs/tags/<name> or a full commit id: people without write access can " <>
                     "change other refs, such as a pull request's",
                 "values" => %{"ref" => "refs/pull/1/head"}
               })
             ) ==
               harness <>
                 "write the ref refs/pull/1/head as HEAD, a branch or tag name, " <>
                 "refs/heads/<name>, refs/tags/<name> or a full commit id: people without " <>
                 "write access can change other refs, such as a pull request's."

      # A module's local path in the chosen source, which leaves it.
      assert words.(
               failure.(:invalid, chosen, %{
                 "rule" => "path",
                 "values" => %{"path" => "../../../x"}
               })
             ) == harness <> "the path ../../../x leads out of its source."

      # A module at the chosen address with a ref no read takes: the module's ref, which
      # the chosen version is not.
      assert words.(failure.(:invalid, chosen, %{"rule" => "ref", "values" => %{"ref" => "v 9"}})) ==
               harness <>
                 "the ref v 9 is not a version: 1 to 255 letters, digits, dots, underscores, " <>
                 "slashes and hyphens."

      # A version a read found no version for, after a call.
      assert words.(
               failure.(:invalid, "https://code.example.com/acme/x", %{
                 "rule" => "version",
                 "values" => %{"ref" => "v9"}
               })
             ) == harness <> "its ref is no version of its source."

      assert words.(failure.(:invalid, chosen, %{"rule" => "size", "values" => %{"n" => 65_536}})) ==
               harness <> "it is larger than 65536 bytes as JSON."

      n = Apiary.Harnesses.Walk.max_links()

      assert words.(failure.(:too_many, nil, nil)) ==
               "Correct the harness in acme/harness: its modules come from more than #{n} " <>
                 "accounts, and a run can read at most #{n}."

      assert words.(failure.(:no_harness, nil, nil)) ==
               harness <> "it has no harness file and no harness is set."

      assert words.(failure.(:walk_error, nil, nil)) ==
               "Qory Apiary could not read acme/harness because of an error in Qory Apiary. " <>
                 "Try again. If it repeats, tell an instance admin."

      # A stack the chosen source does not export, or has no stack file for; a module's.
      assert words.(
               failure.(:invalid, chosen, %{"rule" => "no_export", "values" => %{"name" => "web"}})
             ) ==
               "acme/harness exports no stack named web. List it under exports in the " <>
                 "qory.yaml or harness.yaml at its root."

      assert words.(
               failure.(:invalid, chosen, %{
                 "rule" => "no_stack_file",
                 "values" => %{"path" => "stacks/web/qory-stack.yaml"}
               })
             ) ==
               "acme/harness lists the stack web under exports, but stacks/web has no " <>
                 "qory-stack.yaml. Add that file."

      assert words.(
               failure.(:invalid, chosen, %{
                 "rule" => "no_stack_file",
                 "values" => %{"path" => "qory-stack.yaml"}
               })
             ) ==
               "acme/harness exports no stack. Add a qory.yaml or harness.yaml at its root " <>
                 "that lists the stack under exports."

      assert words.(
               failure.(:invalid, "https://code.example.com/acme/x", %{
                 "rule" => "no_export",
                 "values" => %{"name" => "web"}
               })
             ) == harness <> "it exports no stack web."
    end

    # The words of each read reason of `Apiary.Stacks.Sources` the page tests above do
    # not reach through a stub adapter.
    test "a read refused for a stack, a folder, a file or a version: the cause" do
      source = %{label: "acme/harness", git: @harness_git, narrowing: %{"path" => "stacks/web"}}
      reads = &ApiaryWeb.HarnessComponents.read_words(&1, source, "Acme")

      assert reads.({:no_stack_file, "stacks/web/qory-stack.yaml"}) ==
               "acme/harness has no qory-stack.yaml in the folder stacks/web. Add that file."

      assert reads.({:stack_path, "harness.yaml", "web", "../stacks/web/qory-stack.yaml"}) ==
               "acme/harness lists the stack web under exports at " <>
                 "../stacks/web/qory-stack.yaml, a path Qory Apiary does not read. Correct " <>
                 "exports in harness.yaml: a path is relative and has no empty, . or .. part."

      assert reads.({:no_version, "v9"}) ==
               "acme/harness has no branch, tag or commit named v9. Correct the version."

      # A version an instance admin assigned, which no field on the page changes.
      assigned = Map.merge(source, %{kind: :assigned, ref: "v9"})

      assert ApiaryWeb.HarnessComponents.read_words({:no_version, "v9"}, assigned, "Acme") ==
               "acme/harness has no branch, tag or commit named v9. An instance admin corrects " <>
                 "the version of this harness source."

      # A read at HEAD of a repository with no commit.
      assert reads.(:no_commit) ==
               "acme/harness has no commit yet. Push a commit with a qory.yaml or harness.yaml " <>
                 "at its root that lists the stack under exports."

      # A read with no time left before it read every file, not a call with no answer.
      late = %{adapter: "GitHub", cause: :late, code: nil, seconds: 30, refusal: nil}

      assert reads.({:call, late}) ==
               "Qory Apiary stopped reading acme/harness after 30 seconds, before it read " <>
                 "every file. Try again."

      walk = %{failure: :adapter_unavailable, call_cause: :late, call: late}

      assert ApiaryWeb.HarnessComponents.refusal_words({:walk, walk}, source, "main", "Acme") ==
               "Qory Apiary stopped reading acme/harness after 30 seconds, before it read " <>
                 "every file. Try again."

      assert reads.({:not_text, "harness.yaml"}) ==
               "Correct harness.yaml in acme/harness: it is not UTF-8 text of at most 256 KiB " <>
                 "without a NUL character."
    end

    # The words of each cause of a failed call (`Apiary.Stacks.Sources.call/3`), with no
    # address, host or IP of the instance's set-up.
    test "a call to an adapter that failed: its cause and who fixes it" do
      source = %{label: "acme/harness", git: @harness_git, narrowing: %{}}

      call = fn cause, code ->
        {:call, %{adapter: "GitHub", cause: cause, code: code, seconds: nil}}
      end

      reads = &ApiaryWeb.HarnessComponents.read_words(&1, source, "Acme")

      assert reads.({:call, %{adapter: "GitHub", cause: :timeout, code: nil, seconds: 10}}) ==
               "The GitHub adapter did not answer within 10 seconds. Try again. If it repeats, " <>
                 "an instance admin checks that the adapter is running."

      for {cause, code, line} <- [
            {:no_address, nil,
             "Qory Apiary does not call the GitHub adapter: the adapter has no call address. " <>
               "An instance admin sets the call address. The Qory harness needs no call " <>
               "address."},
            {:unauthorized, nil,
             "The GitHub adapter did not accept the call from Qory Apiary. Try again. If it " <>
               "repeats, an instance admin checks the adapter's enrolment and that both " <>
               "machines' clocks are right."},
            {:refused, "unsupported_contract_version",
             "The GitHub adapter does not implement the contract revision of the call. An " <>
               "instance admin upgrades the adapter."},
            {:refused, "invalid_request",
             "The GitHub adapter did not accept the call as valid under the contract. An " <>
               "instance admin checks that the adapter and Qory Apiary implement the same " <>
               "contract revision."},
            {:refused, "source_unavailable",
             "The GitHub adapter could not read acme/harness. Try again."},
            {:invalid_answer, nil,
             "Qory Apiary did not accept the answer of the GitHub adapter. Try again. If it " <>
               "repeats, an instance admin checks the version and the enrolment of the adapter."},
            {:too_large, nil,
             "Qory Apiary did not send the call to the GitHub adapter: the call was over 256 " <>
               "KiB. Tell an instance admin."}
          ] do
        assert reads.(call.(cause, code)) == line
      end

      for {refusal, line} <- [
            {{:address, :link_local},
             "Qory Apiary does not call the GitHub adapter: the adapter's call address leads " <>
               "to a link-local address. An instance admin sets the adapter's call address. " <>
               "The Qory harness needs no call address."},
            {:form,
             "Qory Apiary does not call the GitHub adapter: the adapter's call address is not " <>
               "an https address at the adapter's host. An instance admin corrects the call " <>
               "address. The Qory harness needs no call address."},
            {:public_host,
             "Qory Apiary does not call the GitHub adapter: the instance's public address " <>
               "(PUBLIC_URL) has no host name. An instance admin sets PUBLIC_URL. The Qory " <>
               "harness needs no call address."}
          ] do
        not_allowed = %{adapter: "GitHub", cause: :not_allowed, code: nil, seconds: nil}
        assert reads.({:call, Map.put(not_allowed, :refusal, refusal)}) == line
      end

      for {kind, words} <- [
            metadata: "a cloud metadata address",
            unspecified: "the unspecified address",
            multicast: "a multicast address",
            broadcast: "a broadcast address",
            reserved: "a reserved address",
            loopback: "a loopback address written as an IPv6 address"
          ] do
        call = %{adapter: "GitHub", cause: :not_allowed, code: nil, seconds: nil}

        assert reads.({:call, Map.put(call, :refusal, {:address, kind})}) ==
                 "Qory Apiary does not call the GitHub adapter: the adapter's call address " <>
                   "leads to #{words}. An instance admin sets the adapter's call address. The " <>
                   "Qory harness needs no call address."
      end

      # A save's walk at a call that failed has the same words.
      walk =
        {:walk,
         %{
           failure: :adapter_failed,
           source: nil,
           rule: nil,
           adapter: "github",
           adapter_id: nil,
           call_failure: nil,
           call: %{adapter: "GitHub", cause: :too_large, code: nil, seconds: nil}
         }}

      assert ApiaryWeb.HarnessComponents.refusal_words(walk, source, "main", "Acme") ==
               "Qory Apiary did not send the call to the GitHub adapter: the call was over 256 " <>
                 "KiB. Tell an instance admin."
    end

    test "a save whose walk cannot reach the adapter or reads a file that is not valid: the cause, and nothing saved",
         ctx do
      adapter = linked_harness!(ctx, @one_export)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      serve_harness(adapter, @one_export, down: true)
      lv |> form("#set-up-harness-form") |> render_submit()
      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "Qory Apiary could not connect to the #{Apiary.Adapters.title(adapter.adapter)} " <>
                 "adapter. Try again. If it repeats, an instance admin checks that the adapter " <>
                 "is running."

      files =
        Map.put(@one_export, {"R_harness", "stacks/triage/qory-stack.yaml"}, "modules: [core\n")

      serve_harness(adapter, files)
      lv |> form("#set-up-harness-form") |> render_submit()
      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "Correct qory-stack.yaml in acme/harness: is not valid YAML."

      files = Map.put(@one_export, {"R_harness", "stacks/triage/qory-stack.yaml"}, "modules: 7\n")
      serve_harness(adapter, files)
      lv |> form("#set-up-harness-form") |> render_submit()
      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "Correct qory-stack.yaml in acme/harness: it lists no modules: a qory-stack.yaml " <>
                 "lists at least one module, each a mapping."

      refuse = Map.new(["HEAD", "main", @pin], &{&1, "internal"})
      serve_harness(adapter, @one_export, refuse_at: refuse)
      lv |> form("#set-up-harness-form") |> render_submit()
      render_async(lv, 2_000)

      assert words(lv, "#set-up-harness-refusal") ==
               "The #{Apiary.Adapters.title(adapter.adapter)} adapter returned the error " <>
                 "internal for acme/harness. An instance admin checks the adapter's log."

      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end

    test "a repository whose call is refused, or whose exports are not valid: the cause", ctx do
      adapter = linked_harness!(ctx, @one_export)
      serve_harness(adapter, @one_export, refuse_at: %{"HEAD" => "internal"})
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      assert words(lv, "#harness-stack-error") ==
               "The #{Apiary.Adapters.title(adapter.adapter)} adapter returned the error " <>
                 "internal for acme/harness. An instance admin checks the adapter's log."

      serve_harness(adapter, %{{"R_harness", "harness.yaml"} => "exports: 7\n"})
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_repository(lv)

      assert words(lv, "#harness-stack-error") ==
               "Correct the exports section of harness.yaml in acme/harness: write stacks as a " <>
                 "list of stack names, and dir, if there is one, as a folder name or as the " <>
                 "names of a stacks folder and a modules folder."

      assert has_element?(lv, "#set-up-continue[disabled]")
    end

    test "with no connected repository, Repository has none to choose, a line under it shows how to get one, and Continue stays off",
         ctx do
      linked_harness!(ctx, %{})
      end_harness_collection!()
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)

      lv |> form("#set-up-harness-form", harness: %{choice: "repository"}) |> render_change()

      assert has_element?(lv, "button#harness-source[disabled]")
      refute has_element?(lv, "#harness-source-options input")
      refute render(lv) =~ "No connected repository"

      assert words(lv, "#harness-source-none") ==
               "#{ctx.organisation.name} has no connected repository. Connect a work source " <>
                 "to pick one."

      assert has_element?(lv, "#set-up-continue[disabled]")

      # The Qory harness stays a choice, and Continue saves it.
      lv |> form("#set-up-harness-form", harness: %{choice: "qory"}) |> render_submit()
      assert %{choice: :qory} = Apiary.Stacks.choice(ctx.scope.workspace)
    end

    test "an adapter whose call address Qory Apiary does not call: one line at Repository before any pick, with no address",
         ctx do
      adapter = linked_harness!(ctx, @one_export)
      title = Apiary.Adapters.title(adapter.adapter)

      for {call_url, instance_id, cause, line} <- [
            {nil, nil, "no_address",
             "Qory Apiary cannot read the repositories of the #{title} adapter: the adapter " <>
               "has no call address. An instance admin sets the call address. The Qory " <>
               "harness needs no call address."},
            {"https://code-host.example.org/calls/", "instance-1", "not_placed",
             "Qory Apiary cannot read the repositories of the #{title} adapter: the adapter's " <>
               "call address is not an https address at the adapter's host. An instance admin " <>
               "corrects the call address. The Qory harness needs no call address."}
          ] do
        {1, _} =
          Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.adapter.id),
            set: [call_url: call_url, call_instance_id: instance_id]
          )

        {:ok, lv, _html} = live(ctx.conn, ctx.path)
        render_async(lv, 2_000)
        lv |> form("#set-up-harness-form", harness: %{choice: "repository"}) |> render_change()

        id = "#harness-source-unplaced-#{adapter.adapter.public_id}-#{cause}"
        assert words(lv, id) == line
        refute has_element?(lv, "#harness-source-none")
        refute render(lv) =~ "code-host.example.org"
      end
    end

    test "two adapters with no call address: a line for each, with its id", ctx do
      adapter = linked_harness!(ctx, @one_export)
      other = Apiary.HarnessReadsFixtures.call_adapter_fixture()
      {connection, _nonce} = connection_fixture(ctx.scope, other.adapter, :listed)

      Apiary.HarnessReadsFixtures.harness_collection_fixture(
        connection,
        @team_git,
        "example-org/team-harness"
      )

      {2, _} =
        Repo.update_all(
          from(n in Apiary.Nodes.Node, where: n.id in ^[adapter.adapter.id, other.adapter.id]),
          set: [call_url: nil, call_instance_id: nil]
        )

      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      lv |> form("#set-up-harness-form", harness: %{choice: "repository"}) |> render_change()

      for node <- [adapter.adapter, other.adapter] do
        assert words(lv, "#harness-source-unplaced-#{node.public_id}-no_address") ==
                 "Qory Apiary cannot read the repositories of the " <>
                   "#{Apiary.Adapters.title(node)} adapter: the adapter has no call address. " <>
                   "An instance admin sets the call address. The Qory harness needs no call " <>
                   "address."
      end
    end

    test "an instance whose public address has no host: a line for each adapter, before any pick" do
      form = Phoenix.Component.to_form(%{"choice" => "repository"}, as: :harness)

      html =
        render_component(&ApiaryWeb.HarnessComponents.choices/1,
          form: form,
          linked: [],
          organisation: "Acme",
          unplaced: [
            %{id: "qn_a", adapter: "GitHub", cause: :no_instance_host},
            %{id: "qn_b", adapter: "Tracker", cause: :no_instance_host}
          ]
        )

      for {id, adapter} <- [{"qn_a", "GitHub"}, {"qn_b", "Tracker"}] do
        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#harness-source-unplaced-#{id}-no_instance_host")
               |> LazyHTML.text()
               |> String.split()
               |> Enum.join(" ") ==
                 "Qory Apiary cannot read the repositories of the #{adapter} adapter: the " <>
                   "instance's public address (PUBLIC_URL) has no host name. An instance admin " <>
                   "sets PUBLIC_URL. The Qory harness needs no call address."
      end

      refute html =~ "harness-source-none"
    end

    # A destination of the workspace: a collection with a target, assigned to it, of an
    # adapter with targets.
    defp destination!(ctx) do
      collection = collection_fixture(ctx.scope)
      targets!(adapter_of(collection))
      collection
    end

    defp target_of(collection),
      do: %{system: collection.target_system, path: collection.target_path}

    # The options of a destination's Stack select, `{text, value}`, and the chosen value.
    defp row_options(lv, collection) do
      options =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#harness-target-#{collection.public_id}-stack option")

      values = LazyHTML.attribute(options, "value")
      texts = Enum.map(options, &(&1 |> LazyHTML.text() |> String.trim()))
      Enum.zip(texts, values)
    end

    defp row_chosen(lv, collection),
      do: words(lv, "#harness-target-#{collection.public_id}-stack option[selected]")

    defp pick_row(lv, collection, value) do
      lv
      |> form("#harness-target-#{collection.public_id}-form", row: %{stack: value})
      |> render_change()

      lv
    end

    test "a destination's Stack: the workspace's harness, then the Qory harness's stacks; a stack saves at once, and the workspace's harness removes it",
         ctx do
      destination = destination!(ctx)
      elsewhere = collection_fixture(ctx.scope, workspace_id: nil)
      targets!(adapter_of(elsewhere))
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)

      assert words(lv, "#harness-targets-h") == "Repositories"
      refute has_element?(lv, "#harness-targets-line")
      refute has_element?(lv, "#harness-target-#{destination.public_id}-change")
      assert has_element?(lv, "#harness-target-#{destination.public_id}", destination.title)
      refute has_element?(lv, "#harness-target-#{elsewhere.public_id}")

      assert words(lv, ~s(label[for="harness-target-#{destination.public_id}-stack"])) ==
               "Stack"

      assert row_options(lv, destination) == [
               {"Workspace's harness", "default"},
               {"core · Qory harness · latest", "workspace:core"},
               {"A stack of another repository…", "other"}
             ]

      assert row_chosen(lv, destination) == "Workspace's harness"

      pick_row(lv, destination, "workspace:core")

      assert row_chosen(lv, destination) == "core · Qory harness · latest"

      assert %{choice: :qory, version_kind: :workspace} =
               Apiary.Stacks.target_choice(ctx.scope.workspace, target_of(destination))

      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      assert row_chosen(lv, destination) == "core · Qory harness · latest"

      pick_row(lv, destination, "default")
      assert row_chosen(lv, destination) == "Workspace's harness"
      assert Apiary.Stacks.target_choice(ctx.scope.workspace, target_of(destination)) == nil
    end

    test "under a harness repository, a destination's Stack offers the stacks it exports, read at its version",
         ctx do
      files =
        @one_export
        |> Map.put({"R_harness", "harness.yaml"}, "exports:\n  stacks: [triage, review]\n")
        |> Map.put({"R_harness", "stacks/review/qory-stack.yaml"}, @root_stack)

      linked_harness!(ctx, files)
      [harness] = Apiary.Stacks.Sources.repositories(ctx.scope)

      {:ok, _row} =
        Apiary.Stacks.Sources.choose(ctx.scope, {:repository, harness, "triage", {:tag, "v1"}})

      destination = destination!(ctx)
      harness_calls()
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)

      assert {"harness.yaml", "v1"} in for(
               {"read", call} <- harness_calls(),
               do: {call["path"], call["at"]}
             )

      assert row_options(lv, destination) == [
               {"Workspace's harness", "default"},
               {"triage · acme/harness · v1", "workspace:triage"},
               {"review · acme/harness · v1", "workspace:review"},
               {"A stack of another repository…", "other"}
             ]

      pick_row(lv, destination, "workspace:review")
      render_async(lv, 2_000)

      assert row_chosen(lv, destination) == "review · acme/harness · v1"

      assert %{choice: :repository, version_kind: :workspace, harness: harness} =
               Apiary.Stacks.target_choice(ctx.scope.workspace, target_of(destination))

      assert harness =~ ~s(stack: "review")
    end

    test "A stack of another repository…: a connected repository's exported stack at a version, saved",
         ctx do
      linked_harness!(ctx, @one_export)
      destination = destination!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)

      pick_row(lv, destination, "other")
      assert row_chosen(lv, destination) == "A stack of another repository…"
      assert words(lv, "#target_stack_source-label") == "Repository"
      assert has_element?(lv, "#target_stack_source-search")
      assert has_element?(lv, ~s(#target_stack_source-g0 ~ label input[value="#{linked_id()}"]))

      assert has_element?(
               lv,
               ~s(#target_stack_source-g2 ~ label[data-keep="true"] input[value="address"])
             )

      assert has_element?(lv, "#harness-target-save[disabled]")

      lv |> form("#harness-target-form", target_stack: %{source: linked_id()}) |> render_change()
      render_async(lv, 2_000)

      assert has_element?(lv, ~s(#target_stack_stack input[value="triage"][checked]))
      assert has_element?(lv, "#target_stack-version-branch[checked]")

      lv
      |> form("#harness-target-form", target_stack: %{version: "fixed", fixed: "v2"})
      |> render_submit()

      render_async(lv, 2_000)

      refute has_element?(lv, "#harness-target-form")
      assert row_chosen(lv, destination) == "triage · acme/harness · v2"

      assert %{choice: :repository, version_kind: :tag, version_name: "v2", harness: harness} =
               Apiary.Stacks.target_choice(ctx.scope.workspace, target_of(destination))

      assert harness ==
               "extends:\n  git: \"#{@harness_git}\"\n  ref: \"v2\"\n  stack: \"triage\"\n"

      # Cancel closes the form with nothing saved.
      pick_row(lv, destination, "other")
      lv |> element("#harness-target-cancel") |> render_click()
      refute has_element?(lv, "#harness-target-form")
      assert row_chosen(lv, destination) == "triage · acme/harness · v2"
    end

    # A destination's form with acme/harness chosen, its stub serving `files` with `opts`.
    defp row_read(ctx, files, opts \\ []) do
      adapter = linked_harness!(ctx, files)
      serve_harness(adapter, files, opts)
      destination = destination!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_row(lv, destination, "other")
      lv |> form("#harness-target-form", target_stack: %{source: linked_id()}) |> render_change()
      render_async(lv, 2_000)
      {lv, adapter}
    end

    test "A stack of another repository…: a connected repository that exports no stack", ctx do
      {lv, _adapter} = row_read(ctx, %{{"R_harness", "qory-stack.yaml"} => @root_stack})

      assert words(lv, "#target_stack_stack-none") ==
               "acme/harness exports no stack. Add a qory.yaml or harness.yaml at its root " <>
                 "that lists the stack under exports."

      assert has_element?(lv, "#harness-target-save[disabled]")
    end

    test "A stack of another repository…: a connected repository its adapter cannot be reached for",
         ctx do
      {lv, adapter} = row_read(ctx, @one_export, down: true)

      assert words(lv, "#target_stack_stack-error") ==
               "Qory Apiary could not connect to the #{Apiary.Adapters.title(adapter.adapter)} " <>
                 "adapter. Try again. If it repeats, an instance admin checks that the adapter " <>
                 "is running."

      assert has_element?(lv, "#harness-target-save[disabled]")
    end

    test "A stack of another repository…: a connected repository with both root harness files",
         ctx do
      files = Map.put(@one_export, {"R_harness", "qory.yaml"}, "exports:\n  stacks: [triage]\n")
      {lv, _adapter} = row_read(ctx, files)

      assert words(lv, "#target_stack_stack-error") ==
               "Correct harness.yaml in acme/harness: it has both harness.yaml and qory.yaml: " <>
                 "keep one."

      assert has_element?(lv, "#harness-target-save[disabled]")
    end

    test "A stack of another repository…: a public address with no stack", ctx do
      linked_harness!(ctx, %{})
      destination = destination!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_row(lv, destination, "other")

      lv |> form("#harness-target-form", target_stack: %{source: "address"}) |> render_change()

      lv
      |> form("#harness-target-form", target_stack: %{address: @harness_git})
      |> render_change()

      render_async(lv, 2_000)

      assert words(lv, "#harness-target-read-error") ==
               "#{@harness_git} exports no stack. Add a qory.yaml or harness.yaml at its root " <>
                 "that lists the stack under exports."
    end

    test "A stack of another repository…: an assigned source's stack, at the assignment's ref",
         ctx do
      adapter = linked_harness!(ctx, %{})
      instance = Apiary.HarnessReadsFixtures.call_adapter_fixture()
      admin = instance_admin_scope()
      {connection, _nonce} = connection_fixture(admin, instance.adapter, :listed)

      Apiary.HarnessReadsFixtures.live_grant_fixture(
        admin.organisation.id,
        instance.adapter,
        connection,
        "G_i"
      )

      Apiary.HarnessReadsFixtures.serve_calls([adapter, instance],
        covered: %{
          adapter.adapter.id => %{@harness_git => {"G_acme", "R_harness"}},
          instance.adapter.id => %{@team_git => {"G_i", "R_team"}}
        },
        files: %{{"R_team", "qory-stack.yaml"} => @root_stack},
        versions: %{"R_team" => @pin}
      )

      assignment =
        Repo.insert!(%Apiary.Harnesses.Assignment{
          organisation_id: ctx.organisation.id,
          every_organisation: false,
          source: %{"git" => @team_git, "ref" => "v1"},
          created_by_id: admin.user.id
        })

      destination = destination!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_row(lv, destination, "other")

      lv
      |> form("#harness-target-form", target_stack: %{source: "assigned:" <> assignment.id})
      |> render_change()

      render_async(lv, 2_000)

      assert has_element?(lv, ~s(#target_stack_stack option[value="0"]), "qory-stack.yaml")
      refute has_element?(lv, "#target_stack_ref")

      lv |> form("#harness-target-form", target_stack: %{stack: "0"}) |> render_submit()
      render_async(lv, 2_000)

      assert row_chosen(lv, destination) == "qory-stack.yaml · example-org/team-harness · v1"

      assert %{harness: harness, version_kind: nil} =
               Apiary.Stacks.target_choice(ctx.scope.workspace, target_of(destination))

      assert harness == "extends:\n  git: \"#{@team_git}\"\n  ref: \"v1\"\n"
    end

    test "A stack of another repository…: an assigned source whose ref is gone: an instance admin corrects it",
         ctx do
      linked_harness!(ctx, %{})
      instance = Apiary.HarnessReadsFixtures.call_adapter_fixture()
      admin = instance_admin_scope()
      {connection, _nonce} = connection_fixture(admin, instance.adapter, :listed)

      Apiary.HarnessReadsFixtures.live_grant_fixture(
        admin.organisation.id,
        instance.adapter,
        connection,
        "G_i"
      )

      Apiary.HarnessReadsFixtures.serve_calls([instance],
        covered: %{instance.adapter.id => %{@team_git => {"G_i", "R_team"}}},
        files: %{{"R_team", "qory-stack.yaml"} => @root_stack},
        refuse_at: %{"v9" => "version_not_found"}
      )

      assignment =
        Repo.insert!(%Apiary.Harnesses.Assignment{
          organisation_id: ctx.organisation.id,
          every_organisation: false,
          source: %{"git" => @team_git, "ref" => "v9"},
          created_by_id: admin.user.id
        })

      destination = destination!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_row(lv, destination, "other")

      lv
      |> form("#harness-target-form", target_stack: %{source: "assigned:" <> assignment.id})
      |> render_change()

      render_async(lv, 2_000)

      assert words(lv, "#harness-target-read-error") ==
               "example-org/team-harness has no branch, tag or commit named v9. An instance " <>
                 "admin corrects the version of this harness source."

      refute has_element?(lv, "#target_stack_ref")
    end

    test "A stack of another repository…: a public address at a branch or tag that cannot be read is refused, and nothing saved",
         ctx do
      linked_harness!(ctx, %{{"R_harness", "qory-stack.yaml"} => @root_stack})
      destination = destination!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_row(lv, destination, "other")

      lv |> form("#harness-target-form", target_stack: %{source: "address"}) |> render_change()

      lv
      |> form("#harness-target-form", target_stack: %{address: @harness_git})
      |> render_change()

      render_async(lv, 2_000)
      assert has_element?(lv, ~s(#target_stack_stack option[value="0"]), "qory-stack.yaml")
      assert words(lv, ~s(label[for="target_stack_ref"])) == "Branch or tag"

      lv
      |> form("#harness-target-form", target_stack: %{ref: "refs/pull/1/head"})
      |> render_submit()

      render_async(lv, 2_000)

      assert words(lv, "#harness-target-refusal") ==
               "Correct the version: give a branch or tag name, refs/heads/<name>, " <>
                 "refs/tags/<name> or a full commit id. People without write access can " <>
                 "change other refs, such as a pull request's."

      assert has_element?(lv, "#harness-target-form")
      assert Apiary.Stacks.target_choice(ctx.scope.workspace, target_of(destination)) == nil

      # The address at a branch it reads: saved, pinned at the commit read.
      lv |> form("#harness-target-form", target_stack: %{ref: "main"}) |> render_submit()
      render_async(lv, 2_000)

      assert row_chosen(lv, destination) == "qory-stack.yaml · acme/harness · c3c3c3c"
    end

    test "with no connected repository, a destination's Repository shows the group empty, and an address still reads",
         ctx do
      adapter = linked_harness!(ctx, %{})
      end_harness_collection!()
      destination = destination!(ctx)
      {:ok, lv, _html} = live(ctx.conn, ctx.path)
      render_async(lv, 2_000)
      pick_row(lv, destination, "other")

      assert has_element?(lv, "#target_stack_source-g0", "Linked repositories")
      refute render(lv) =~ "No connected repository"

      serve_harness(adapter, %{{"R_harness", "qory-stack.yaml"} => @root_stack})
      lv |> form("#harness-target-form", target_stack: %{source: "address"}) |> render_change()

      lv
      |> form("#harness-target-form", target_stack: %{address: @harness_git})
      |> render_change()

      render_async(lv, 2_000)
      assert has_element?(lv, ~s(#target_stack_stack option[value="0"]), "qory-stack.yaml")
    end

    test "a member sees the choices and each destination's Stack disabled, and who may; a save sent changes nothing",
         ctx do
      destination = destination!(ctx)
      member = joined(ctx.organisation, :member)
      {:ok, lv, _html} = build_conn() |> log_in_user(member) |> live(ctx.path)

      assert has_element?(lv, "#harness-choice-qory-radio[disabled]")
      assert has_element?(lv, "#harness-qory-version-latest[disabled]")
      assert words(lv, "#set-up-who-may") == "Only owners and admins change this."
      refute has_element?(lv, "#set-up-continue")
      assert has_element?(lv, "#set-up-skip")

      assert has_element?(lv, "#harness-target-#{destination.public_id}-stack[disabled]")
      assert row_chosen(lv, destination) == "Workspace's harness"

      render_change(lv, "choose_target_stack", %{
        "row" => %{"id" => destination.public_id, "stack" => "workspace:core"}
      })

      assert Apiary.Stacks.target_choice(ctx.scope.workspace, target_of(destination)) == nil

      render_click(lv, "save_harness", %{"harness" => %{"choice" => "qory"}})
      assert Apiary.Stacks.choice(ctx.scope.workspace) == nil
    end
  end

  describe "the test run" do
    setup :register_and_log_in_user

    defp test_path(scope), do: ~p"/#{scope.organisation}/set-up?step=test"

    # The one run of `item`, a test work item, with `changes`, and its registered run,
    # with `run_attrs`; none for nil.
    defp test_run!(item, changes, run_attrs \\ nil) do
      [queued] = Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)
      {1, _} = Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id), set: changes)

      if run_attrs do
        %Run{
          organisation_id: item.organisation_id,
          workspace_id: item.workspace_id,
          node_run_id: queued.run_id,
          dispatch_run_id: queued.id
        }
        |> Ecto.Changeset.change(Map.merge(%{started_at: DateTime.utc_now()}, run_attrs))
        |> Repo.insert!()
      end
    end

    test "with no ready pool, says runs need one, with See Machines, and no Run the test", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, test_path(scope))

      assert has_element?(lv, "h1", "Run a test")
      assert words(lv, "#set-up-test-machines") == "Runs need a ready pool. See Machines."
      assert words(lv, "#set-up-test-machines a") == "See Machines"

      assert href(lv, "#set-up-test-machines a") ==
               ~p"/#{scope.organisation}/set-up?step=machines&workspace=#{scope.workspace}"

      refute has_element?(lv, "#set-up-test-form")
      refute has_element?(lv, "#set-up-test-run")
    end

    test "About this step shows what the test run adds, its harness, and what a pass finishes",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, test_path(scope))
      workspace = scope.workspace.name

      assert words(lv, "#set-up-context-h") == "About this step"

      assert ids(lv, "#set-up-context p") ==
               ["set-up-what", "set-up-test-harness", "set-up-test-after"]

      assert words(lv, "#set-up-context #set-up-what") ==
               "The test run adds a test work item to #{workspace} and queues its run. " <>
                 "The test passes once a machine takes the run and the run completes."

      # The software domain's words: a repository, not a target.
      assert words(lv, "#set-up-context #set-up-test-harness") ==
               "The run uses a harness built into Qory Apiary, qory's hello example at a " <>
                 "fixed version, in place of the harness of #{workspace}. The test work item " <>
                 "has no ticket and no repository. The run changes no repository, and Qory " <>
                 "Apiary sends nothing to a work source or destination."

      assert words(lv, "#set-up-context #set-up-test-after") ==
               "Once a test run passes, the set-up of #{workspace} is finished, and a link to " <>
                 "#{workspace} opens the workspace in place of the set-up."
    end

    test "Run the test takes a test work item in; it passes live", %{conn: conn, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, lv, _html} = live(conn, test_path(scope))

      assert has_element?(lv, "#set-up-test-form label", "Say hi to your agent")
      assert has_element?(lv, "#set-up-test-form input[name='test[line]'][value='#{@line}']")
      assert has_element?(lv, "#set-up-test-run", "Run the test")

      lv |> form("#set-up-test-form") |> render_submit()

      assert [%WorkItem{test: true, title: @line} = item] = Repo.all(WorkItem)
      assert words(lv, "#set-up-test-state") == "The test run is queued for a machine."
      refute has_element?(lv, "#set-up-test-form")

      run =
        test_run!(item, [state: :ended, end_cause: :run_ended], %{
          state: "completed",
          node_id: nil
        })

      :ok = Dispatches.broadcast([scope.workspace.id])

      assert words(lv, "#set-up-test-passed") ==
               "Test run passed: the agent answered on a machine. See the run"

      assert href(lv, "#set-up-test-passed a") ==
               ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}"

      assert words(lv, "#set-up-go") == "Go to #{scope.workspace.name}"
    end

    test "a failure shows its line, the fix first, and the field again", %{
      conn: conn,
      scope: scope
    } do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, item} = WorkItems.take_in_test(scope, @line)
      test_run!(item, queued_at: DateTime.add(DateTime.utc_now(), -301, :second))

      {:ok, lv, _html} = live(conn, test_path(scope))

      assert has_element?(lv, "#set-up-test-failed[data-cause=no_machine]")

      assert words(lv, "#set-up-test-failed") ==
               "Check the pool in Instance settings › Nodes. No machine has taken the test " <>
                 "run yet."

      assert has_element?(lv, "#set-up-test-run", "Run the test")
    end

    test "one who may not take an item in reads who runs the test, and has no field", %{
      conn: conn,
      scope: scope
    } do
      :ok = Apiary.Edition.put_test_stub(ReadyNoTakeIn)
      {:ok, lv, _html} = live(conn, test_path(scope))

      assert words(lv, "#set-up-who-may") == "Only owners, admins and members run the test."
      refute has_element?(lv, "#set-up-test-form")

      render_click(lv, "run_test", %{"test" => %{"line" => @line}})
      refute Repo.exists?(WorkItem)
    end

    test "while a test run is in progress, the step says to wait, in a plain line", %{
      conn: conn,
      scope: scope
    } do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, item} = WorkItems.take_in_test(scope, @line)
      test_run!(item, [state: :handed_over], %{state: "running"})
      {:ok, lv, _html} = live(conn, test_path(scope))

      # Run the test again with the line of a test a machine is running.
      render_click(lv, "run_test", %{"test" => %{"line" => @line}})

      assert words(lv, "#set-up-test-running") ==
               "Wait until the test run in progress ends, then press Run the test again."

      assert Repo.aggregate(WorkItem, :count) == 1
    end

    test "a line the work item refuses is the field's error", %{conn: conn, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, lv, _html} = live(conn, test_path(scope))
      html = lv |> form("#set-up-test-form", test: %{line: "   "}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute Repo.exists?(WorkItem)
    end

    test "running, with See the run", %{conn: conn, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, item} = WorkItems.take_in_test(scope, @line)
      run = test_run!(item, [state: :handed_over], %{state: "running"})
      {:ok, lv, _html} = live(conn, test_path(scope))

      assert words(lv, "#set-up-test-state") == "The test run is running."
      assert words(lv, "#set-up-test-run-link") == "See the run"

      assert href(lv, "#set-up-test-run-link") ==
               ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}"
    end

    test "passed on a pool of the workspace, or on the instance's pool, says which", %{
      conn: conn,
      scope: scope
    } do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, item} = WorkItems.take_in_test(scope, @line)
      {:ok, lv, _html} = live(conn, test_path(scope))
      pool = pool_fixture(scope, name: "build-pool")

      run =
        test_run!(item, [state: :ended, end_cause: :run_ended], %{
          state: "completed",
          node_id: pool.id
        })

      :ok = Dispatches.broadcast([scope.workspace.id])

      assert words(lv, "#set-up-test-passed") ==
               "Test run passed: the agent answered on a machine of build-pool. See the run"

      assert href(lv, "#set-up-test-passed a") ==
               ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}"

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [node_id: instance_pool_fixture().id]
      )

      {:ok, lv, _html} = live(conn, test_path(scope))

      assert words(lv, "#set-up-test-passed") ==
               "Test run passed: the agent answered on a machine of the Qory Pool. " <>
                 "See the run"
    end

    test "each failure, the fix first, with Run the test", %{conn: conn, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, item} = WorkItems.take_in_test(scope, @line)

      for {changes, run_attrs, cause, line} <- [
            {[state: :ended, end_cause: :run_refused, end_detail: "model_key_missing"],
             %{state: "failed", reason: "model_key_missing"}, "model_key_missing",
             "Add a model key in Organisation settings › Model providers. The gateway had no " <>
               "model key for the run."},
            {[state: :ended, end_cause: :lost, end_detail: nil],
             %{state: "lost", silenced_at: DateTime.utc_now()}, "silent",
             "Check that the gateway is running in Instance settings › Nodes. The machine " <>
               "stopped sending for 10 minutes."},
            {[state: :ended, end_cause: :run_ended], %{state: "failed"}, "other",
             "Read the run's log, then press Run the test again. The test run ended without " <>
               "passing. See the run"},
            {[state: :ended, end_cause: :harness_unresolved, result_outcome: :error], nil,
             "other",
             "Check the other steps of this list, then press Run the test again. The test run " <>
               "ended before a machine started it."}
          ] do
        Repo.delete_all(from r in Run, where: r.workspace_id == ^scope.workspace.id)
        test_run!(item, changes, run_attrs)
        {:ok, lv, _html} = live(conn, test_path(scope))

        assert has_element?(lv, "#set-up-test-failed[data-cause=#{cause}]")
        assert words(lv, "#set-up-test-failed") == line
        assert has_element?(lv, "#set-up-test-run", "Run the test")
      end
    end

    test "Run the test after a failure takes a new test in and closes the failed one", %{
      conn: conn,
      scope: scope
    } do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, item} = WorkItems.take_in_test(scope, @line)
      test_run!(item, [state: :ended, end_cause: :run_ended], %{state: "failed"})
      {:ok, lv, _html} = live(conn, test_path(scope))

      lv |> form("#set-up-test-form") |> render_submit()

      assert [%WorkItem{state: :closed}, %WorkItem{state: :exploring, title: @line}] =
               Repo.all(from w in WorkItem, order_by: w.number)

      assert words(lv, "#set-up-test-state") == "The test run is queued for a machine."
    end

    test "a wait past 5 minutes turns into its failure without a reload, and Run the test queues a new test",
         %{conn: conn, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetupReady)
      {:ok, item} = WorkItems.take_in_test(scope, @line)
      {:ok, lv, _html} = live(conn, test_path(scope))

      assert words(lv, "#set-up-test-state") == "The test run is queued for a machine."

      test_run!(item, queued_at: DateTime.add(DateTime.utc_now(), -301, :second))
      send(lv.pid, :setup_tick)

      assert has_element?(lv, "#set-up-test-failed[data-cause=no_machine]")

      # Run the test while no machine has taken the run: the run ends, the test work item
      # closes, and a new test run is queued.
      lv |> form("#set-up-test-form") |> render_submit()
      refute has_element?(lv, "#set-up-test-running")

      assert [%WorkItem{state: :closed}, %WorkItem{state: :exploring, title: @line}] =
               Repo.all(from w in WorkItem, order_by: w.number)

      assert [%DispatchRun{state: :ended, end_cause: :closed}] =
               Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)

      assert words(lv, "#set-up-test-state") == "The test run is queued for a machine."
    end
  end

  test "an instance admin's first organisation: 7 steps in order, counted from 1", %{
    conn: conn
  } do
    Apiary.Mail.put_test_source(:env)
    admin = instance_admin_scope()

    {:ok, lv, _html} =
      conn |> log_in_user(admin.user) |> live(~p"/#{admin.organisation}/set-up?step=sources")

    assert count(lv) == "Step 2 of 7"

    assert steps(lv) == [
             {"Name", :done, :link},
             {"Work sources", :current},
             {"Destinations", :to_come},
             {"Model", :to_come},
             {"Harness", :to_come},
             {"Machines", :to_come},
             {"Test run", :to_come}
           ]

    refute has_element?(lv, ".q-su-grp-h")
  end

  test "a workspace slug of another organisation is no page", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_fixture()
    %{organisation: theirs} = sign_up_fixture()
    billing = workspace_fixture(theirs, "Billing")

    conn = log_in_user(conn, user)

    assert_raise ApiaryWeb.NotFound, fn ->
      get(conn, ~p"/#{organisation}/set-up?step=sources&workspace=#{billing.slug}")
    end
  end

  test "a workspace step with no workspace named opens for the workspace in use", %{
    conn: conn
  } do
    %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()

    {:ok, lv, _html} =
      conn |> log_in_user(user) |> live(~p"/#{organisation}/set-up?step=sources")

    assert has_element?(lv, "h1", "Where does work for #{main.name} come from?")
  end
end

defmodule ApiaryWeb.WorkspaceSetupLive.ModelTest do
  # The Model step of the set-up flow (`ApiaryWeb.WorkspaceSetupLive`), with the `factory`
  # and `secrets` features: Key, a provider to reuse or Add a key, whose key the page
  # never keeps; the workspace's choice it saves; the providers it offers; who may; and a
  # second workspace, which opens at Name with every later step to come.
  use ApiaryWeb.ConnCase, async: true

  import ApiaryWeb.SetUpSteps
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelChoices, Organisations, Repo, WorkspaceSetup}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Membership

  @moduletag needs: [:factory, :secrets]

  @key "sk-ant-set-up-test-0123456789abcdef"

  @workspace_later "You can change the default model later in Workspace settings › Model, and the key in Workspace settings › Secrets and variables."
  @model_later "You can change the default model later in Workspace settings › Model."
  @organisation_later "You can change the default model later in Workspace settings › Model, and the key in Organisation settings › Secrets and variables."

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # Everything the page's process keeps, as text.
  defp kept(lv), do: inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)

  defp model_path(organisation), do: ~p"/#{organisation}/set-up?step=model&workspace=main"

  # The form in `html` is sent with POST, so a browser that sends it before the page
  # connects puts no key in an address, and its key's field has no value.
  defp assert_posts_without_key(html) do
    form = LazyHTML.query(html, "#set-up-model-form")
    assert LazyHTML.attribute(form, "method") == ["post"]

    key = LazyHTML.query(form, ~s{input[type="password"]})
    assert LazyHTML.attribute(key, "name") == ["model[key]"]
    assert LazyHTML.attribute(key, "value") == []
  end

  defp member(organisation) do
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: :member})
    |> Repo.insert!()

    user
  end

  # Key's options, each its words and whether it is chosen.
  defp key_options(lv) do
    html = lv |> render() |> LazyHTML.from_fragment()

    for label <- LazyHTML.query(html, "#set-up-model-source label") do
      words = label |> LazyHTML.text() |> String.split() |> Enum.join(" ")
      {words, LazyHTML.attribute(LazyHTML.query(label, "input"), "checked") != []}
    end
  end

  defp provider!(scope, kind, value_id, attrs \\ %{}) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        Map.merge(
          %{provider: kind, keys: [%{value_id: value_id, value: "sk-#{value_id}-1"}]},
          attrs
        )
      )

    provider
  end

  # The scope's choices: the workspace's (level 5), and the organisation's default (level
  # 6).
  defp choices(scope) do
    {:ok, choices} = ModelChoices.list_choices(scope)

    {Enum.filter(choices, &(&1.workspace_id == scope.workspace.id)),
     Enum.filter(choices, &is_nil(&1.workspace_id))}
  end

  defp models(provider) do
    {:ok, runtime} = ModelChoices.runtime(nil)
    for model <- ModelChoices.suggestions(provider, runtime), do: model.id
  end

  test "with no provider, Add a key alone, open: adds the provider and the workspace's choice; never keeps the key",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    workspace = scope.workspace
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert has_element?(lv, "h1", "Which model do runs in #{workspace.name} use?")
    assert key_options(lv) == [{"Add a key", true}]
    assert has_element?(lv, "#set-up-model-add input[type=password][name='model[key]']")
    assert has_element?(lv, "#set-up-model-form", "Default model")
    assert has_element?(lv, "#set-up-model-form", "Runtime")
    # The core shows no setting of where the provider applies.
    refute has_element?(lv, "#set-up-model-everywhere")

    assert words(lv, ~s{#set-up-model-form [id^="set-up-model-key-"][id$="-hint"]}) ==
             "Qory Apiary stores the key encrypted, and nobody can view it again. You can replace it in Settings › Secrets and variables."

    assert words(lv, "#set-up-model-later") == @workspace_later

    assert has_element?(
             lv,
             ~s{#set-up-model-form input[type=password][aria-describedby$="-hint"]}
           )

    assert words(lv, "#set-up-context #set-up-what") ==
             "A model provider's key lets runs in #{workspace.name} call a model."

    lv
    |> form("#set-up-model-form", model: %{provider: "anthropic", key: @key})
    |> render_change()

    refute kept(lv) =~ @key

    lv
    |> form("#set-up-model-form", model: %{provider: "anthropic", key: @key})
    |> render_submit()

    refute kept(lv) =~ @key
    refute render(lv) =~ @key

    assert {:ok, [provider]} = Connections.list_providers(scope)
    assert provider.provider_kind == "anthropic"

    # The key is a secret of the workspace, and the provider reaches that workspace alone.
    assert provider.secret.workspace_id == scope.workspace.id
    assert provider.applies_to == "selected"
    assert Connections.workspace_ids_of(provider) == [scope.workspace.id]

    assert {:ok, [%{provider: %{id: listed}}]} =
             Apiary.Secrets.list_provider_keys(scope, :workspace)

    assert listed == provider.id

    # The workspace's choice (level 5), with the provider's default key; no default of
    # the organisation (level 6).
    assert {[choice], []} = choices(scope)
    assert choice.connection_id == provider.id and choice.target_id == nil
    assert choice.value_id == provider.default_value_id
    assert choice.model_id == hd(models(provider))
    assert WorkspaceSetup.model_key?(workspace)
    assert WorkspaceSetup.done?(:model, organisation, {Apiary.Lingo.Domain.Software, workspace})

    assert_patch(lv, ~p"/#{organisation}/set-up?step=harness&workspace=main")

    # Back on the step: the provider to reuse, chosen, with no key field.
    {:ok, lv, _html} = live(conn |> log_in_user(user), model_path(organisation))

    assert key_options(lv) == [{provider.name, true}, {"Add a key", false}]
    refute has_element?(lv, "input[name='model[key]']")
    refute has_element?(lv, "#set-up-get-key")
    # The provider reused links the workspace's secret.
    assert words(lv, "#set-up-model-later") == @workspace_later
    assert {"Model", :current} in steps(lv)
    refute render(lv) =~ @key
  end

  test "Add a key with the setting shown and on: the organisation's provider, for every workspace",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert has_element?(lv, "#set-up-model-everywhere[type=checkbox]")
    refute has_element?(lv, "#set-up-model-everywhere[checked]")

    assert has_element?(
             lv,
             "#set-up-model-add label",
             "Available to every workspace in #{organisation.name}"
           )

    lv
    |> form("#set-up-model-form", model: %{provider: "anthropic", everywhere: "true"})
    |> render_change()

    # The key is a secret of the organisation, whose secrets the core shows nowhere.
    assert words(lv, "#set-up-model-later") == @model_later

    lv
    |> form("#set-up-model-form",
      model: %{provider: "anthropic", key: @key, everywhere: "true"}
    )
    |> render_submit()

    assert {:ok, [provider]} = Connections.list_providers(scope)
    assert provider.applies_to == "all"
    assert Connections.workspace_ids_of(provider) == []
    assert provider.secret.workspace_id == nil

    assert {[choice], []} = choices(scope)
    assert choice.connection_id == provider.id
  end

  test "Add a key with the setting shown and off: the provider of the workspace",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert words(lv, "#set-up-model-later") == @workspace_later

    lv
    |> form("#set-up-model-form",
      model: %{provider: "anthropic", key: @key, everywhere: "false"}
    )
    |> render_submit()

    assert {:ok, [provider]} = Connections.list_providers(scope)
    assert provider.applies_to == "selected"
    assert Connections.workspace_ids_of(provider) == [scope.workspace.id]
    assert provider.secret.workspace_id == scope.workspace.id
  end

  test "reuse with one provider: its default key, another default model; Add a key opens the fields",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    provider = provider!(scope, "anthropic", "main")
    [_first, second | _rest] = models(provider)
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert key_options(lv) == [{provider.name, true}, {"Add a key", false}]
    refute has_element?(lv, "#set-up-model-add")
    refute has_element?(lv, "input[name='model[key]']")
    # The provider's key is a secret of the organisation, and the core shows no
    # organisation secrets: the line names the model alone.
    assert words(lv, "#set-up-model-later") == @model_later

    # Add a key opens Provider and Key, and the provider to reuse closes them again.
    lv |> form("#set-up-model-form", model: %{source: "add"}) |> render_change()
    assert {"Add a key", true} in key_options(lv)
    assert has_element?(lv, "#set-up-model-add input[type=password][name='model[key]']")
    assert has_element?(lv, "#set-up-context #set-up-get-key")
    assert words(lv, "#set-up-model-later") == @workspace_later

    lv |> form("#set-up-model-form", model: %{source: provider.public_id}) |> render_change()
    refute has_element?(lv, "#set-up-model-add")
    assert words(lv, "#set-up-model-later") == @model_later

    lv
    |> form("#set-up-model-form", model: %{source: provider.public_id, model: second})
    |> render_submit()

    assert_patch(lv, ~p"/#{organisation}/set-up?step=harness&workspace=main")

    assert {[choice], []} = choices(scope)

    assert {choice.connection_id, choice.value_id, choice.model_id} ==
             {provider.id, "main", second}

    assert {:ok, [_provider]} = Connections.list_providers(scope)

    # Back on the step: the saved model chosen; Continue with nothing changed writes nothing.
    {:ok, lv, _html} = live(conn |> log_in_user(user), model_path(organisation))
    assert has_element?(lv, ~s{select[name="model[model]"] option[selected][value="#{second}"]})
    lv |> form("#set-up-model-form") |> render_submit()
    assert {[^choice], []} = choices(scope)
  end

  test "where the edition shows organisation secrets, an organisation key's line names Organisation settings",
       %{conn: conn} do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.GrantsOrganisationSecrets)
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    provider = provider!(scope, "anthropic", "main")
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert key_options(lv) == [{provider.name, true}, {"Add a key", false}]
    assert words(lv, "#set-up-model-later") == @organisation_later

    lv |> form("#set-up-model-form", model: %{source: "add"}) |> render_change()
    assert words(lv, "#set-up-model-later") == @workspace_later
  end

  test "reuse with two providers: each by its name; the one chosen is saved", %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    anthropic = provider!(scope, "anthropic", "main")
    deepseek = provider!(scope, "deepseek", "ds")
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert Enum.sort(key_options(lv)) ==
             Enum.sort([{anthropic.name, true}, {deepseek.name, false}, {"Add a key", false}])

    # The default model follows the provider chosen.
    lv |> form("#set-up-model-form", model: %{source: deepseek.public_id}) |> render_change()

    for model <- models(deepseek),
        do: assert(has_element?(lv, ~s{select[name="model[model]"] option[value="#{model}"]}))

    lv |> form("#set-up-model-form", model: %{source: deepseek.public_id}) |> render_submit()

    assert {[choice], []} = choices(scope)

    assert {choice.connection_id, choice.value_id, choice.model_id} ==
             {deepseek.id, "ds", hd(models(deepseek))}
  end

  # A provider of the workspace alone, and one that applies to every workspace. By name,
  # the workspace's comes first (Anthropic before DeepSeek).
  defp own_and_shared!(scope) do
    own =
      provider!(scope, "anthropic", "main", %{
        applies_to: "selected",
        workspace_ids: [scope.workspace.id]
      })

    shared = provider!(scope, "deepseek", "ds")
    assert shared.applies_to == "all"
    {own, shared}
  end

  test "with the setting shown: the providers every workspace shares first, under Shared in, each marked; the first is chosen",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
    {own, shared} = own_and_shared!(scope)
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert words(lv, "#set-up-model-source-shared-h") == "Shared in #{organisation.name}"

    assert key_options(lv) == [
             {"#{shared.name} · every workspace", true},
             {own.name, false},
             {"Add a key", false}
           ]

    assert has_element?(lv, "#set-up-model-source-shared label", shared.name)
    refute has_element?(lv, "#set-up-model-source-shared label", own.name)

    # The workspace's choice of its provider: that provider is chosen when the step opens.
    lv |> form("#set-up-model-form", model: %{source: own.public_id}) |> render_submit()
    assert {[choice], []} = choices(scope)
    assert choice.connection_id == own.id

    {:ok, lv, _html} = live(conn |> log_in_user(user), model_path(organisation))

    assert key_options(lv) == [
             {"#{shared.name} · every workspace", false},
             {own.name, true},
             {"Add a key", false}
           ]
  end

  test "with the setting shown and no provider every workspace shares: no heading, no mark",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)

    own =
      provider!(scope, "anthropic", "main", %{
        applies_to: "selected",
        workspace_ids: [scope.workspace.id]
      })

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert key_options(lv) == [{own.name, true}, {"Add a key", false}]
    refute has_element?(lv, "#set-up-model-source-shared")
    refute render(lv) =~ "Shared in"
  end

  test "the core shows no setting: a provider every workspace shares is listed by its name, with no heading",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    {own, shared} = own_and_shared!(scope)
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert key_options(lv) == [{own.name, true}, {shared.name, false}, {"Add a key", false}]
    refute has_element?(lv, "#set-up-model-source-shared")
    refute render(lv) =~ "Shared in"
  end

  test "a provider that does not reach the workspace, or has no key, is not offered; a save of it saves nothing",
       %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    other = workspace_fixture(organisation, "Other")

    elsewhere =
      provider!(scope, "anthropic", "main", %{applies_to: "selected", workspace_ids: [other.id]})

    keyless = provider!(scope, "deepseek", "ds")
    Repo.delete_all(from v in Apiary.Secrets.Value, where: v.secret_id == ^keyless.secret_id)

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))
    assert key_options(lv) == [{"Add a key", true}]

    for provider <- [elsewhere, keyless] do
      render_click(lv, "save_model", %{"model" => %{"source" => provider.public_id}})
      assert {[], []} = choices(scope)
    end

    assert {:ok, [_, _]} = Connections.list_providers(scope)
    refute WorkspaceSetup.model_key?(scope.workspace)
  end

  test "the Claude subscription's help shows its command on a line with Copy", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_fixture()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    lv
    |> form("#set-up-model-form", model: %{provider: "claude-subscription"})
    |> render_change()

    assert words(lv, "#set-up-context #set-up-get-key-run") ==
             "Get the key from the provider first. In a terminal where Claude Code is installed, run:"

    assert words(lv, "#set-up-context #set-up-get-key-command-text") == "claude setup-token"

    assert has_element?(
             lv,
             ~s{#set-up-get-key-command-copy[data-copy="claude setup-token"]}
           )

    assert words(lv, "#set-up-context #set-up-get-key-copy-token") ==
             "Then copy the token it prints. Anthropic's terms (opens in a new tab) allow this for personal use only."

    assert has_element?(
             lv,
             ~s{#set-up-get-key-copy-token a[href="https://code.claude.com/docs/en/legal-and-compliance"]},
             "Anthropic's terms"
           )
  end

  test "the form is sent with POST, before the page connects and after", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_fixture()
    conn = log_in_user(conn, user)

    html = conn |> get(model_path(organisation)) |> html_response(200)
    assert_posts_without_key(LazyHTML.from_document(html))

    {:ok, lv, _html} = live(conn, model_path(organisation))
    assert_posts_without_key(LazyHTML.from_fragment(render(lv)))
  end

  test "a save refused with a key typed shows the key nowhere and keeps it nowhere", %{
    conn: conn
  } do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    lv |> form("#set-up-model-form", model: %{provider: "litellm"}) |> render_change()

    html =
      lv
      |> form("#set-up-model-form",
        model: %{provider: "litellm", key: @key, address: "http://litellm.example.com"}
      )
      |> render_submit()

    assert html =~ "https://"
    refute html =~ @key
    refute kept(lv) =~ @key
    assert_posts_without_key(LazyHTML.from_fragment(html))
    assert {:ok, []} = Connections.list_providers(scope)
  end

  test "save_model and choose_model sent by a member change nothing: Add a key, or a provider to reuse",
       %{conn: conn} do
    %{organisation: organisation, scope: scope} = sign_up_fixture()
    user = member(organisation)
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    params = %{"model" => %{"source" => "add", "provider" => "anthropic", "key" => @key}}
    render_click(lv, "choose_model", params)
    render_click(lv, "save_model", params)

    refute kept(lv) =~ @key
    refute render(lv) =~ @key
    assert {:ok, []} = Connections.list_providers(scope)

    # A provider to reuse, sent by the same person, is no choice either.
    provider = provider!(scope, "anthropic", "main")
    render_click(lv, "save_model", %{"model" => %{"source" => provider.public_id}})
    assert {[], []} = choices(scope)
    refute WorkspaceSetup.model_key?(scope.workspace)
  end

  test "a refused key keeps no key, and says why on the field", %{conn: conn} do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    lv
    |> form("#set-up-model-form", model: %{provider: "anthropic", key: ""})
    |> render_submit()

    assert {:ok, []} = Connections.list_providers(scope)
    refute WorkspaceSetup.model_key?(scope.workspace)
    assert has_element?(lv, "#set-up-model-form input[name='model[key]']")
  end

  test "a member who may not write the workspace's choice reads who may, and has no form", %{
    conn: conn
  } do
    %{organisation: organisation, scope: scope} = sign_up_fixture()
    user = member(organisation)

    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert words(lv, "#set-up-who-may") == "Only owners and admins add a model key."
    refute has_element?(lv, "#set-up-model-form")
    assert has_element?(lv, "#set-up-skip")

    # With a provider to reuse too.
    _provider = provider!(scope, "anthropic", "main")
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(model_path(organisation))

    assert words(lv, "#set-up-who-may") == "Only owners and admins add a model key."
    refute has_element?(lv, "#set-up-model-form")
  end

  test "a second workspace opens at Name, whatever the step, with every later step to come",
       %{conn: conn} do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    collection = collection_fixture(scope)

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
        set: [targets: true]
      )

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, model_path(organisation))

    lv
    |> form("#set-up-model-form", model: %{provider: "anthropic", key: @key})
    |> render_submit()

    # Main's model is done, and the new workspace's steps are not: no step after Name is
    # done before the workspace exists.
    assert WorkspaceSetup.model_key?(scope.workspace)

    for path <- [
          ~p"/#{organisation}/workspaces/new?type=software",
          ~p"/#{organisation}/workspaces/new?step=model&type=software"
        ] do
      {:ok, lv, _html} = live(conn, path)
      assert has_element?(lv, "h1", "Name this workspace")

      assert Enum.drop_while(steps(lv), &(elem(&1, 0) != "Name")) == [
               {"Name", :current},
               {"Work sources", :to_come},
               {"Destinations", :to_come},
               {"Model", :to_come},
               {"Harness", :to_come},
               {"Machines", :to_come},
               {"Test run", :to_come}
             ]
    end

    {:ok, lv, _html} = live(conn, ~p"/#{organisation}/workspaces/new?type=software")

    assert words(lv, "#set-up-title") == "Set up a new Software factory"

    lv |> form("#set-up-form", workspace: %{name: "Payments"}) |> render_submit()
    {to, _flash} = assert_redirect(lv)
    assert to == ~p"/#{organisation}/set-up?step=sources&workspace=payments"

    assert length(Organisations.list_workspaces(Organisations.load_scope(Scope.for_user(user)))) ==
             2
  end
end

defmodule ApiaryWeb.WorkspaceSetupLive.MachinesTest do
  # The Machines step of the set-up flow (`ApiaryWeb.WorkspaceSetupLive`), with the
  # `factory` feature: the pools that serve the workspace's runs, each with its state; who
  # acts on a pool that is not ready, for an instance admin, an owner and a member, in the
  # edition's words; an owner's choice of the shared pool or a pool for the workspace, Add
  # node pool, and Get the command; a member's step, read only; and Skip, then Continue. Not async: some tests make
  # the instance's pool and gateway, which the instance has one of each at most.
  use ApiaryWeb.ConnCase, async: false

  import ApiaryWeb.SetUpSteps
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.{Repo, WorkspaceSetup}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Membership

  @moduletag needs: :factory

  defmodule Worded do
    # An edition whose line on who acts on a pool that is not ready differs from the core's.
    def machines_who_may(_scope, _workspace, :instance), do: "Harbour Ops checks the pool."
    def machines_who_may(_scope, _workspace, :workspace), do: "Harbour Ops enrols the pool."
  end

  setup %{conn: conn} do
    admin = instance_admin_scope()
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    refute Apiary.Access.instance_admin?(scope)

    %{
      conn: conn,
      admin: admin,
      user: user,
      organisation: organisation,
      scope: scope,
      path: ~p"/#{organisation}/set-up?step=machines&workspace=#{scope.workspace}",
      test_path: ~p"/#{organisation}/set-up?step=test&workspace=#{scope.workspace}"
    }
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

  defp href(lv, selector) do
    [href] =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  defp open(ctx, user \\ nil),
    do: ctx.conn |> log_in_user(user || ctx.user) |> live(ctx.path) |> elem(1)

  defp member(organisation) do
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: :member})
    |> Repo.insert!()

    user
  end

  # The instance's pool, with its key, and the instance's gateway named "instance
  # gateway", with its key.
  defp ready_instance! do
    pool = instance_pool_fixture()
    _pool_key = installed_key_fixture(pool)
    gateway = instance_gateway_fixture(name: "instance gateway")
    _gateway_key = installed_key_fixture(gateway, allow_secrets: true)
    pool
  end

  # Nothing on the step writes: no form, no button, no event.
  defp read_only?(lv) do
    html = lv |> element("#set-up-pools") |> render()
    not (html =~ "<form" or html =~ "<button" or html =~ "phx-click" or html =~ "phx-submit")
  end

  test "after Harness: the instance's pool, chosen and ready, with its gateway; Continue", ctx do
    _pool = ready_instance!()
    lv = open(ctx)

    assert has_element?(lv, "h1", "Which machines run the runs in #{ctx.scope.workspace.name}?")

    assert [{"Harness", _state}, {"Machines", :current}, {"Test run", :to_come}] =
             lv |> steps() |> Enum.take(-3) |> Enum.map(&{elem(&1, 0), elem(&1, 1)})

    assert has_element?(lv, "#set-up-pool-instance-radio[checked]:not([disabled])")
    assert words(lv, "#set-up-pool-instance-name") == "Qory Pool"
    assert words(lv, "#set-up-pool-instance-state") == "Ready · gateway: Qory Gateway"
    refute has_element?(lv, "#set-up-pool-instance-who-may")
    refute has_element?(lv, "#set-up-pool-instance-check")

    refute has_element?(lv, "#set-up-skip")
    assert words(lv, "#set-up-continue") == "Continue"
    assert href(lv, "#set-up-continue") == ctx.test_path
    assert has_element?(lv, "#set-up-back")

    lv = open(ctx, member(ctx.organisation))
    assert has_element?(lv, "#set-up-pool-instance-radio[checked][disabled]")
    assert words(lv, "#set-up-pool-instance-name") == "Qory Pool"
    assert words(lv, "#set-up-pool-instance-state") == "Ready · gateway: Qory Gateway"
    refute has_element?(lv, "#set-up-pool-workspace")
    assert read_only?(lv)
    assert words(lv, "#set-up-continue") == "Continue"
  end

  test "About this step shows what a pool does, which pool takes which runs, and when it is ready",
       ctx do
    lv = open(ctx)
    workspace = ctx.scope.workspace.name

    assert words(lv, "#set-up-context-h") == "About this step"

    assert lv
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#set-up-context p")
           |> LazyHTML.attribute("id") ==
             ["set-up-what", "set-up-machines-pools", "set-up-machines-why"]

    assert words(lv, "#set-up-context #set-up-what") ==
             "A pool takes the waiting runs of #{workspace} and starts each run on a machine " <>
               "that joined the pool."

    assert words(lv, "#set-up-context #set-up-machines-pools") ==
             "The Qory Pool is the instance's pool, where the instance has one. It takes " <>
               "the runs of every workspace that has no pool. A pool for #{workspace} takes " <>
               "the runs of #{workspace} alone: once you add it, the Qory Pool stops taking " <>
               "them. To join a machine to the pool, get the command and run it on that machine. " <>
               "Every run gets an isolated environment."

    assert words(lv, "#set-up-context #set-up-machines-why") ==
             "A pool is ready when a machine has joined it and its runs go through a gateway " <>
               "that has an active access key. Runs of work items need a ready pool, because " <>
               "Qory Apiary sends a run's secrets, such as its model key, only to a gateway."
  end

  test "the instance's pool not ready: no pool, no active key, no gateway, no gateway key, then ready",
       ctx do
    line = "Only an instance admin checks the Qory Pool and the Qory Gateway."

    lv = open(ctx)
    assert words(lv, "#set-up-pool-instance-name") == "Qory Pool"
    assert has_element?(lv, "#set-up-pool-instance-radio[checked]")
    assert words(lv, "#set-up-pool-instance-state") == "Not ready: no pool"
    assert words(lv, "#set-up-pool-instance-who-may") == line
    refute has_element?(lv, "#set-up-pool-instance-check")
    assert words(lv, "#set-up-skip") == "Skip"
    assert href(lv, "#set-up-skip") == ctx.test_path
    refute has_element?(lv, "#set-up-continue")

    pool = instance_pool_fixture()
    lv = open(ctx)
    assert words(lv, "#set-up-pool-instance-state") == "Not ready: no active key"
    assert words(lv, "#set-up-pool-instance-who-may") == line

    _pool_key = installed_key_fixture(pool)
    lv = open(ctx)
    assert words(lv, "#set-up-pool-instance-state") == "Not ready: no gateway"
    assert words(lv, "#set-up-pool-instance-who-may") == line
    assert has_element?(lv, "#set-up-skip")

    gateway = instance_gateway_fixture(name: "instance gateway")
    lv = open(ctx)
    assert words(lv, "#set-up-pool-instance-state") == "Not ready: the gateway has no active key"
    assert words(lv, "#set-up-pool-instance-who-may") == line

    _gateway_key = installed_key_fixture(gateway, allow_secrets: true)
    lv = open(ctx)
    assert words(lv, "#set-up-pool-instance-state") == "Ready · gateway: Qory Gateway"
    refute has_element?(lv, "#set-up-pool-instance-who-may")
    assert has_element?(lv, "#set-up-continue")
  end

  test "the instance's pool not ready for its gateway choice: Direct, or a gateway its runs may not go through",
       ctx do
    gateway = gateway_fixture(ctx.scope)
    _gateway_key = node_key_fixture(ctx.scope, gateway)

    pool = instance_pool_fixture(gateway_choice: :direct)
    _pool_key = installed_key_fixture(pool)
    lv = open(ctx)

    assert words(lv, "#set-up-pool-instance-state") ==
             "Not ready: the pool is set to Direct, and runs need a gateway"

    # The instance's pool names a gateway of the workspace: its runs go through the
    # instance's gateway alone.
    pool
    |> Ecto.Changeset.change(gateway_choice: :named, gateway_id: gateway.id)
    |> Repo.update!()

    lv = open(ctx)

    assert words(lv, "#set-up-pool-instance-state") ==
             "Not ready: the pool's runs may not go through the chosen gateway"

    assert has_element?(lv, "#set-up-skip")
  end

  test "an instance admin sees Check the nodes; a member reads who acts", ctx do
    admin = ctx.admin

    {:ok, lv, _html} =
      ctx.conn
      |> log_in_user(admin.user)
      |> live(~p"/#{admin.organisation}/set-up?step=machines&workspace=#{admin.workspace}")

    assert words(lv, "#set-up-pool-instance-state") == "Not ready: no pool"
    assert words(lv, "#set-up-pool-instance-check") == "Check the nodes"
    assert href(lv, "#set-up-pool-instance-check") == ~p"/instance/nodes"
    refute has_element?(lv, "#set-up-pool-instance-who-may")

    lv = open(ctx, member(ctx.organisation))
    assert words(lv, "#set-up-pool-instance-state") == "Not ready: no pool"

    assert words(lv, "#set-up-pool-instance-who-may") ==
             "Only an instance admin checks the Qory Pool and the Qory Gateway."

    refute has_element?(lv, "#set-up-pool-instance-check")
    assert has_element?(lv, "#set-up-skip")
  end

  test "a pool of the workspace: not enrolled, an owner gets its page, a member who acts",
       ctx do
    _instance_pool = ready_instance!()
    gateway = gateway_fixture(ctx.scope)
    _gateway_key = node_key_fixture(ctx.scope, gateway)
    pool = pool_fixture(ctx.scope)
    id = "#set-up-pool-#{pool.public_id}"

    lv = open(ctx)
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    refute has_element?(lv, "#{id}-radio")
    assert words(lv, "#{id}-name") == pool.name
    assert words(lv, "#{id}-state") == "Not ready: no active key"

    assert href(lv, "#{id}-name a") ==
             ~p"/#{ctx.organisation}/#{ctx.scope.workspace}/nodes/#{pool.public_id}"

    refute has_element?(lv, "#{id}-who-may")
    assert words(lv, "#{id}-code") == "Get the command"
    assert has_element?(lv, "#set-up-skip")

    lv = open(ctx, member(ctx.organisation))
    refute has_element?(lv, "#set-up-pool-instance")
    refute has_element?(lv, "#set-up-pool-choice")
    assert has_element?(lv, "#{id}-radio[checked][disabled]")
    assert words(lv, "#{id}-name") == pool.name
    refute has_element?(lv, "#{id}-name a")

    assert words(lv, "#{id}-who-may") ==
             "Only owners and admins add a pool and join a machine to it."

    assert read_only?(lv)

    _pool_key = enrolled_key_fixture(ctx.scope, pool)
    lv = open(ctx)
    assert words(lv, "#{id}-state") == "Ready · gateway: #{gateway.name}"
    refute has_element?(lv, "#{id}-name a")
    refute has_element?(lv, "#{id}-who-may")
    assert has_element?(lv, "#set-up-continue")
  end

  test "a pool of the workspace whose runs may not go through the gateway it is set to", ctx do
    # A gateway of another workspace, which the pool's runs are not in.
    other = %{ctx.scope | workspace: workspace_fixture(ctx.organisation)}
    gateway = gateway_fixture(other)
    _gateway_key = node_key_fixture(other, gateway)

    pool = pool_fixture(ctx.scope)
    _pool_key = enrolled_key_fixture(ctx.scope, pool)

    pool
    |> Ecto.Changeset.change(gateway_choice: :named, gateway_id: gateway.id)
    |> Repo.update!()

    assert words(open(ctx), "#set-up-pool-#{pool.public_id}-state") ==
             "Not ready: the pool's runs may not go through the chosen gateway"
  end

  test "two pools of the workspace: each with its state, neither shown chosen, and no removal",
       ctx do
    first = pool_fixture(ctx.scope)
    second = pool_fixture(ctx.scope)

    lv = open(ctx)

    for pool <- [first, second] do
      id = "#set-up-pool-#{pool.public_id}"
      assert words(lv, "#{id}-state") == "Not ready: no active key"
      refute has_element?(lv, "#{id}-radio")
    end

    refute has_element?(lv, "#set-up-pool-choice")
    refute has_element?(lv, "#set-up-pool-instance")

    # The page sent the removal's events, as a page of one pool would.
    render_click(lv, "choose_pool", %{"pool" => %{"choice" => "shared"}})
    refute has_element?(lv, "#set-up-pool-remove")
    render_click(lv, "remove_pool", %{})
    assert Enum.map(workspace_pools(ctx.scope.workspace), & &1.id) == [first.id, second.id]
  end

  # The workspace's pools in use, as the step reads them.
  defp workspace_pools(workspace),
    do:
      for(
        %Node{workspace_id: id} = pool <- WorkspaceSetup.serving_pools(workspace),
        id != nil,
        do: pool
      )

  defp choose_workspace_pool(lv),
    do: lv |> form("#set-up-pool-choice", pool: %{choice: "workspace"}) |> render_change()

  # The command shown under the line `id`, as Copy writes it.
  defp command(lv, id), do: words(lv, "#{id}-command-line-text")

  test "an owner chooses the shared pool or a pool for the workspace, with the line under it",
       ctx do
    _instance_pool = ready_instance!()
    workspace = ctx.scope.workspace
    lv = open(ctx)

    assert has_element?(lv, "#set-up-pool-instance-radio[checked]")
    assert words(lv, "#set-up-pool-instance-name") == "Qory Pool"
    assert words(lv, "#set-up-pool-instance-state") == "Ready · gateway: Qory Gateway"
    refute has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    assert words(lv, "#set-up-pool-workspace-name") == "A pool for #{workspace.name}"

    assert words(lv, "#set-up-pool-workspace-line") ==
             "Runs in #{workspace.name} then wait for this pool, and the Qory Pool stops taking them."

    refute has_element?(lv, "#set-up-pool-add-button")

    choose_workspace_pool(lv)
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    assert words(lv, "#set-up-pool-add-button") == "Add pool"
    refute has_element?(lv, "#set-up-pool-taken")

    lv |> form("#set-up-pool-choice", pool: %{choice: "shared"}) |> render_change()
    assert has_element?(lv, "#set-up-pool-instance-radio[checked]")
    refute has_element?(lv, "#set-up-pool-add-button")
    assert workspace_pools(workspace) == []
  end

  test "Add pool makes a pool named as the workspace, and the instance's pool stops serving it",
       ctx do
    instance_pool = ready_instance!()
    workspace = ctx.scope.workspace
    assert [%Node{id: id}] = WorkspaceSetup.serving_pools(workspace)
    assert id == instance_pool.id

    lv = open(ctx)
    choose_workspace_pool(lv)
    lv |> element("#set-up-pool-add-button") |> render_click()

    assert [%Node{kind: :pool} = pool] = WorkspaceSetup.serving_pools(workspace)
    assert pool.name == workspace.name
    assert pool.workspace_id == workspace.id

    id = "#set-up-pool-#{pool.public_id}"
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    refute has_element?(lv, "#set-up-pool-instance-radio[checked]")
    refute has_element?(lv, "#set-up-pool-add-button")
    refute has_element?(lv, "#set-up-pool-remove")
    assert words(lv, "#{id}-name") == pool.name
    assert words(lv, "#{id}-state") == "Not ready: no active key"
    assert words(lv, "#{id}-code") == "Get the command"
    assert has_element?(lv, "#set-up-skip")
  end

  test "a second click, or a pool made meanwhile, makes no other pool and shows the one there",
       ctx do
    workspace = ctx.scope.workspace
    lv = open(ctx)
    other = open(ctx)
    choose_workspace_pool(lv)
    choose_workspace_pool(other)

    lv |> element("#set-up-pool-add-button") |> render_click()
    assert [pool] = workspace_pools(workspace)

    # The page sent Add pool again, as a second click would.
    render_click(lv, "add_pool", %{})
    assert [^pool] = workspace_pools(workspace)

    # The other page still shows the choice: its click makes no pool, and it reads again.
    other |> element("#set-up-pool-add-button") |> render_click()
    assert [^pool] = workspace_pools(workspace)
    assert has_element?(other, "#set-up-pool-workspace-radio[checked]")
    refute has_element?(other, "#set-up-pool-add-button")
    assert has_element?(other, "#set-up-pool-#{pool.public_id}")
    refute has_element?(other, "#set-up-pool-taken")
  end

  test "where another node of the workspace has the workspace's name, no pool is made, and the line says to rename it",
       ctx do
    workspace = ctx.scope.workspace
    node = node_fixture(ctx.scope, name: workspace.name)

    lv = open(ctx)
    choose_workspace_pool(lv)
    lv |> element("#set-up-pool-add-button") |> render_click()

    assert workspace_pools(workspace) == []
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    assert has_element?(lv, "#set-up-pool-add-button")

    assert words(lv, "#set-up-pool-taken") ==
             "Rename the node #{node.name} on the Nodes page, then add the pool. A node of #{workspace.name} already has that name."

    # Once the node has another name, Add pool makes the pool.
    node |> Ecto.Changeset.change(name: "build-renamed") |> Repo.update!()
    lv |> element("#set-up-pool-add-button") |> render_click()
    assert [%Node{name: name}] = workspace_pools(workspace)
    assert name == workspace.name
    refute has_element?(lv, "#set-up-pool-taken")
  end

  test "a workspace name of 120 characters gives the pool its first 80", ctx do
    long = String.duplicate("Payments ", 13) <> "abc"
    assert String.length(long) == 120

    workspace =
      ctx.scope.workspace |> Ecto.Changeset.change(name: long) |> Repo.update!()

    lv = open(ctx)
    choose_workspace_pool(lv)
    lv |> element("#set-up-pool-add-button") |> render_click()

    assert [%Node{name: name}] = workspace_pools(workspace)
    assert name == long |> String.slice(0, 80) |> String.trim_trailing()
  end

  test "Get the command shows the pool's enrol command once, with Copy; then Get a new command",
       ctx do
    pool = pool_fixture(ctx.scope)
    id = "#set-up-pool-#{pool.public_id}"
    lv = open(ctx)
    refute has_element?(lv, "#{id}-command")

    lv |> element("#{id}-code") |> render_click()

    assert words(lv, "#{id}-command-run") == "On the machine for the pool #{pool.name}, run:"
    assert command(lv, id) =~ ~r{\Aqory access-key enrol \S+ \S+\z}

    assert words(lv, "#{id}-command-where") ==
             "Run this on the Linux machine with Docker that runs the runs in #{ctx.scope.workspace.name}. It joins that machine to the pool #{pool.name}. Install qory there first:"

    assert words(lv, "#{id}-command-install-text") ==
             "curl -fsSL https://raw.githubusercontent.com/qoryai/qory/main/install.sh | sh"

    assert has_element?(lv, "#{id}-command-install-copy")
    refute command(lv, id) =~ "--via"
    refute command(lv, id) =~ "--replace"
    assert has_element?(lv, "#{id}-command-line-copy")
    refute has_element?(lv, "#{id}-command-via-ca")
    assert words(lv, "#{id}-code") == "Get a new command"

    assert [%{node_id: node_id}] = Apiary.AccessKeys.list_enrolment_codes(ctx.scope, pool)
    assert node_id == pool.id
    shown = command(lv, id)

    # A page opened again shows no command, and Get a new command while the code waits.
    lv = open(ctx)
    refute has_element?(lv, "#{id}-command")
    assert words(lv, "#{id}-code") == "Get a new command"
    refute render(lv) =~ shown

    # Leaving the step and coming back: no command.
    lv |> element("#{id}-code") |> render_click()
    assert has_element?(lv, "#{id}-command")
    render_patch(lv, ctx.test_path)
    render_patch(lv, ctx.path)
    refute has_element?(lv, "#{id}-command")
    assert words(lv, "#{id}-code") == "Get a new command"
  end

  # The code a command shown on the line `id` carries: its last word.
  defp shown_code(lv, id), do: lv |> command(id) |> String.split(" ") |> List.last()

  # What a machine posts as `qory access-key enrol` with `code`: its new key, and the proof.
  defp enrol_request(code) do
    pair = Apiary.AccessKeysFixtures.ed25519_key_pair()
    now = System.os_time(:second)
    message = Apiary.Contract.SignedMessage.enrolment(code, pair.encoded, "build-01", now)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])

    {:ok, request} =
      Apiary.Contract.Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => "build-01",
          "public_key" => pair.encoded,
          "timestamp" => now,
          "proof" => Apiary.Contract.Ed25519.encode(proof)
        })
      )

    request
  end

  # The code's row expires `ms` from now: a code made by the context expires in minutes.
  defp expire_in(%{id: id}, ms) do
    at = DateTime.add(DateTime.utc_now(), ms, :millisecond)

    Repo.query!("UPDATE access_key_enrolment_codes SET expires_at = $2 WHERE id = $1", [
      Ecto.UUID.dump!(id),
      at
    ])
  end

  test "a machine that enrols with the command shown: the command goes, and the pool has its key",
       ctx do
    pool = pool_fixture(ctx.scope)
    id = "#set-up-pool-#{pool.public_id}"
    lv = open(ctx)
    lv |> element("#{id}-code") |> render_click()
    assert words(lv, "#{id}-state") == "Not ready: no active key"

    assert {:ok, key} = Apiary.AccessKeys.enrol(enrol_request(shown_code(lv, id)))
    assert key.node_id == pool.id

    # The page heard the key arrive, with no other read.
    refute has_element?(lv, "#{id}-command")
    assert words(lv, "#{id}-code") == "Get the command"

    assert words(lv, "#{id}-state") ==
             "Not ready: the pool is set to Direct, and runs need a gateway"
  end

  test "a code that expires while the step is open: the step reads it again, and the command goes",
       ctx do
    pool = pool_fixture(ctx.scope)
    id = "#set-up-pool-#{pool.public_id}"

    # A code got elsewhere, which expires first.
    {:ok, other, _code} = Apiary.AccessKeys.create_enrolment_code(ctx.scope, pool, %{})
    expire_in(other, 1_500)

    lv = open(ctx)
    assert words(lv, "#{id}-code") == "Get a new command"
    Process.sleep(1_800)
    assert words(lv, "#{id}-code") == "Get the command"

    # The command shown, its code set to expire soon, and a code cancelled elsewhere, which
    # the page hears: the read sets the timer at the shown code's expiry.
    lv |> element("#{id}-code") |> render_click()
    assert [shown] = Apiary.AccessKeys.list_enrolment_codes(ctx.scope, pool)
    expire_in(shown, 1_500)
    {:ok, cancelled, _code} = Apiary.AccessKeys.create_enrolment_code(ctx.scope, pool, %{})
    {:ok, _cancelled} = Apiary.AccessKeys.cancel_code(ctx.scope, cancelled)
    assert has_element?(lv, "#{id}-command")

    Process.sleep(1_800)
    refute has_element?(lv, "#{id}-command")
    assert words(lv, "#{id}-code") == "Get the command"
  end

  test "a pool whose runs go through a gateway: the command has --via and the line on a private authority",
       ctx do
    gateway = gateway_fixture(ctx.scope, url: "https://gateway.example")
    _gateway_key = node_key_fixture(ctx.scope, gateway)
    pool = pool_fixture(ctx.scope)
    _pool_key = node_key_fixture(ctx.scope, pool)
    id = "#set-up-pool-#{pool.public_id}"

    lv = open(ctx)
    lv |> element("#{id}-code") |> render_click()

    assert command(lv, id) =~ "--via https://gateway.example"
    assert command(lv, id) =~ "--replace"

    assert words(lv, "#{id}-command-via-ca") ==
             "If #{gateway.name}'s certificate is signed by a private certificate authority, add --via-ca-file and that authority's PEM file."
  end

  test "a sign-in older than 15 minutes gets the command all the same, as on the pool's Access key tab",
       ctx do
    pool = pool_fixture(ctx.scope)
    id = "#set-up-pool-#{pool.public_id}"
    an_hour_ago = DateTime.add(DateTime.utc_now(), -60, :minute)

    {:ok, lv, _html} =
      ctx.conn
      |> log_in_user(ctx.user, token_authenticated_at: an_hour_ago)
      |> live(ctx.path)

    lv |> element("#{id}-code") |> render_click()
    assert words(lv, "#{id}-command-run") == "On the machine for the pool #{pool.name}, run:"
  end

  test "a pool with two active keys offers no command", ctx do
    pool = pool_fixture(ctx.scope)
    _first = node_key_fixture(ctx.scope, pool)
    _second = node_key_fixture(ctx.scope, pool)
    id = "#set-up-pool-#{pool.public_id}"

    lv = open(ctx)
    refute has_element?(lv, "#{id}-code")

    render_click(lv, "pool_code", %{"pool" => pool.public_id})
    refute has_element?(lv, "#{id}-command")
    assert Apiary.AccessKeys.list_enrolment_codes(ctx.scope, pool) == []
  end

  test "a member sends the step's events: nothing is made", ctx do
    member = member(ctx.organisation)
    lv = open(ctx, member)
    render_click(lv, "choose_pool", %{"pool" => %{"choice" => "workspace"}})
    render_click(lv, "add_pool", %{})
    assert workspace_pools(ctx.scope.workspace) == []
    refute has_element?(lv, "#set-up-pool-add-button")
    assert read_only?(lv)

    pool = pool_fixture(ctx.scope)
    lv = open(ctx, member)
    render_click(lv, "pool_code", %{"pool" => pool.public_id})
    refute has_element?(lv, "#set-up-pool-#{pool.public_id}-command")
    assert Apiary.AccessKeys.list_enrolment_codes(ctx.scope, pool) == []
    assert read_only?(lv)
  end

  defmodule NoCodes do
    # An edition in which the person may make nodes, and may not make their codes.
    def check(_scope, :"access_key.create_code", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  test "a person who may make a pool, and may not get its command: Add pool, then who acts",
       ctx do
    :ok = Apiary.Edition.put_test_stub(NoCodes)
    lv = open(ctx)

    choose_workspace_pool(lv)
    lv |> element("#set-up-pool-add-button") |> render_click()
    assert [pool] = workspace_pools(ctx.scope.workspace)

    id = "#set-up-pool-#{pool.public_id}"
    refute has_element?(lv, "#{id}-code")
    refute has_element?(lv, "#{id}-name a")

    assert words(lv, "#{id}-who-may") ==
             "Only owners and admins add a pool and join a machine to it."

    render_click(lv, "pool_code", %{"pool" => pool.public_id})
    refute has_element?(lv, "#{id}-command")
    assert Apiary.AccessKeys.list_enrolment_codes(ctx.scope, pool) == []
  end

  test "a person whom access_key.create_code no longer allows gets no command, and reads who acts",
       ctx do
    pool = pool_fixture(ctx.scope)
    lv = open(ctx)

    {1, _} =
      Repo.update_all(
        from(m in Membership,
          where: m.user_id == ^ctx.user.id and m.organisation_id == ^ctx.organisation.id
        ),
        set: [level: :member]
      )

    lv |> element("#set-up-pool-#{pool.public_id}-code") |> render_click()
    refute has_element?(lv, "#set-up-pool-#{pool.public_id}-command")
    assert Apiary.AccessKeys.list_enrolment_codes(ctx.scope, pool) == []

    assert words(lv, "#flash-error") ==
             "Only owners and admins add a pool and join a machine to it."
  end

  test "who acts is the edition's line where it has one", ctx do
    :ok = Apiary.Edition.put_test_stub(Worded)
    member = member(ctx.organisation)

    lv = open(ctx, member)
    assert words(lv, "#set-up-pool-instance-who-may") == "Harbour Ops checks the pool."

    pool = pool_fixture(ctx.scope)
    lv = open(ctx, member)
    assert words(lv, "#set-up-pool-#{pool.public_id}-who-may") == "Harbour Ops enrols the pool."
  end

  defp choose_shared(lv),
    do: lv |> form("#set-up-pool-choice", pool: %{choice: "shared"}) |> render_change()

  # Whether the node `pool` is deleted.
  defp deleted?(pool), do: Repo.get!(Node, pool.id).deleted_at != nil

  test "with a pool of the workspace, an owner sees both choices, the pool chosen; Shared opens the removal, Cancel closes it",
       ctx do
    _instance_pool = ready_instance!()
    workspace = ctx.scope.workspace
    pool = pool_fixture(ctx.scope)
    lv = open(ctx)

    assert words(lv, "#set-up-pool-instance-name") == "Qory Pool"
    assert words(lv, "#set-up-pool-instance-state") == "Ready · gateway: Qory Gateway"
    refute has_element?(lv, "#set-up-pool-instance-radio[checked]")
    assert words(lv, "#set-up-pool-workspace-name") == "A pool for #{workspace.name}"
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    assert words(lv, "#set-up-pool-#{pool.public_id}-name") == pool.name
    refute has_element?(lv, "#set-up-pool-remove")

    choose_shared(lv)
    assert has_element?(lv, "#set-up-pool-instance-radio[checked]")

    assert words(lv, "#set-up-pool-remove-line") ==
             "Remove the pool #{pool.name}? Runs in #{workspace.name} then use the Qory Pool."

    refute has_element?(lv, "#set-up-pool-remove-enrolled")
    assert words(lv, "#set-up-pool-remove-button") == "Remove pool"
    assert words(lv, "#set-up-pool-remove-cancel") == "Cancel"

    lv |> element("#set-up-pool-remove-cancel") |> render_click()
    refute has_element?(lv, "#set-up-pool-remove")
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    refute deleted?(pool)

    # The workspace's pool chosen again closes the removal too, and Remove pool sent with
    # the removal closed deletes nothing.
    choose_shared(lv)
    choose_workspace_pool(lv)
    refute has_element?(lv, "#set-up-pool-remove")
    render_click(lv, "remove_pool", %{})
    refute deleted?(pool)

    # An entry to the step starts with the removal closed.
    choose_shared(lv)
    render_patch(lv, ctx.test_path)
    render_patch(lv, ctx.path)
    refute has_element?(lv, "#set-up-pool-remove")
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
  end

  test "Remove pool deletes the workspace's pool: Shared shows chosen, with no pool and no command",
       ctx do
    instance_pool = ready_instance!()
    workspace = ctx.scope.workspace
    pool = pool_fixture(ctx.scope)
    id = "#set-up-pool-#{pool.public_id}"
    lv = open(ctx)

    lv |> element("#{id}-code") |> render_click()
    assert has_element?(lv, "#{id}-command")

    choose_shared(lv)
    lv |> element("#set-up-pool-remove-button") |> render_click()

    assert deleted?(pool)
    assert [%Node{id: serving}] = WorkspaceSetup.serving_pools(workspace)
    assert serving == instance_pool.id

    assert has_element?(lv, "#set-up-pool-instance-radio[checked]")
    assert words(lv, "#set-up-pool-instance-state") == "Ready · gateway: Qory Gateway"
    refute has_element?(lv, "#set-up-pool-workspace-radio[checked]")
    refute has_element?(lv, id)
    refute has_element?(lv, "#{id}-command")
    refute has_element?(lv, "#set-up-pool-remove")
    refute has_element?(lv, "#set-up-pool-add-button")
    assert has_element?(lv, "#set-up-continue")
  end

  test "the line on the pool's machines shows only where a machine enrolled on the pool", ctx do
    _instance_pool = instance_pool_fixture()
    pool = pool_fixture(ctx.scope)
    lv = open(ctx)
    choose_shared(lv)
    assert has_element?(lv, "#set-up-pool-remove-line")
    refute has_element?(lv, "#set-up-pool-remove-enrolled")

    %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
    assert Apiary.AccessKeys.active_key?(pool)
    lv = open(ctx)
    choose_shared(lv)

    assert words(lv, "#set-up-pool-remove-enrolled") ==
             "The machines in #{pool.name} stop taking runs, because the pool's access key is revoked."

    lv |> element("#set-up-pool-remove-button") |> render_click()
    assert deleted?(pool)
    refute Apiary.AccessKeys.active_key?(pool)
    assert Repo.get!(Apiary.AccessKeys.AccessKey, key.id).revoked_at != nil
  end

  test "a person whom node.delete no longer allows is refused, and the pool stays", ctx do
    _instance_pool = instance_pool_fixture()
    pool = pool_fixture(ctx.scope)
    lv = open(ctx)
    choose_shared(lv)

    {1, _} =
      Repo.update_all(
        from(m in Membership,
          where: m.user_id == ^ctx.user.id and m.organisation_id == ^ctx.organisation.id
        ),
        set: [level: :member]
      )

    lv |> element("#set-up-pool-remove-button") |> render_click()
    refute deleted?(pool)
    assert words(lv, "#flash-error") =~ "Only owners and admins delete nodes."
    refute has_element?(lv, "#set-up-pool-remove")
  end

  test "a pool deleted meanwhile: Remove pool reads the step again, and Shared shows chosen",
       ctx do
    _instance_pool = instance_pool_fixture()
    pool = pool_fixture(ctx.scope)
    lv = open(ctx)
    choose_shared(lv)

    pool |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    lv |> element("#set-up-pool-remove-button") |> render_click()
    refute has_element?(lv, "#set-up-pool-#{pool.public_id}")
    refute has_element?(lv, "#set-up-pool-remove")
    assert has_element?(lv, "#set-up-pool-instance-radio[checked]")
    refute has_element?(lv, "#flash-error")
  end

  test "a second pool added elsewhere while the removal is open: Remove pool deletes nothing, and no removal is offered",
       ctx do
    _instance_pool = instance_pool_fixture()
    pool = pool_fixture(ctx.scope)
    lv = open(ctx)
    choose_shared(lv)
    assert has_element?(lv, "#set-up-pool-remove")

    {:ok, second} = Apiary.Nodes.create_node(ctx.scope, %{kind: "pool", name: "second pool"})

    lv |> element("#set-up-pool-remove-button") |> render_click()
    refute deleted?(pool)
    refute deleted?(second)
    refute has_element?(lv, "#set-up-pool-remove")
    refute has_element?(lv, "#set-up-pool-choice")
    assert has_element?(lv, "#set-up-pool-#{pool.public_id}")
    assert has_element?(lv, "#set-up-pool-#{second.public_id}")
  end

  test "with no pool of the instance, Shared shows not ready for no pool, and no removal is offered",
       ctx do
    pool = pool_fixture(ctx.scope)
    lv = open(ctx)

    assert words(lv, "#set-up-pool-instance-name") == "Qory Pool"
    assert words(lv, "#set-up-pool-instance-state") == "Not ready: no pool"
    assert has_element?(lv, "#set-up-pool-instance-radio[disabled]")
    refute has_element?(lv, "#set-up-pool-instance-radio[checked]")
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")

    # The page sent the removal's events, as a page with the instance's pool would.
    render_click(lv, "choose_pool", %{"pool" => %{"choice" => "shared"}})
    refute has_element?(lv, "#set-up-pool-remove")
    render_click(lv, "remove_pool", %{})
    render_click(lv, "keep_pool", %{})
    refute deleted?(pool)
    refute has_element?(lv, "#set-up-pool-remove")
    assert has_element?(lv, "#set-up-pool-workspace-radio[checked]")
  end

  test "a person who may not delete nodes gets no removal: the pool shows as before", ctx do
    pool = pool_fixture(ctx.scope)
    id = "#set-up-pool-#{pool.public_id}"
    member = member(ctx.organisation)
    lv = open(ctx, member)

    refute has_element?(lv, "#set-up-pool-choice")
    refute has_element?(lv, "#set-up-pool-instance")
    assert has_element?(lv, "#{id}-radio[checked][disabled]")

    render_click(lv, "choose_pool", %{"pool" => %{"choice" => "shared"}})
    render_click(lv, "remove_pool", %{})
    render_click(lv, "keep_pool", %{})
    refute has_element?(lv, "#set-up-pool-remove")
    refute deleted?(pool)
    assert read_only?(lv)
  end
end
