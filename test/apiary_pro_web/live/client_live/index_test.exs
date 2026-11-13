defmodule ApiaryProWeb.ClientLive.IndexTest do
  # Not async: the features are the node's, and an operator is made by an instance admin,
  # an owner of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query

  alias Apiary.{Features, Repo}
  alias Apiary.Organisations.Organisation
  alias Apiary.Organisations.Invitation
  alias ApiaryPro.{Operators, Transfers}
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryProWeb.Trail

  @moduletag with_features: Features.all()

  defp operator(%{conn: conn}) do
    operator = operator_fixture()
    %{conn: log_in_user(conn, operator.user), operator: operator}
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "an operator's clients" do
    setup :operator

    test "an operator's owner lists its clients, with their status and owners", ctx do
      acme = client_fixture(ctx.operator.scope, "Acme")
      member_fixture(acme.owner.scope, :admin)
      beta = client_fixture(ctx.operator.scope, "Beta")
      {:ok, _} = Apiary.Deletion.delete_organisation(beta.owner.scope, beta.organisation.slug)

      {%{organisation: gamma}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Gamma", "email" => email()})

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      assert has_element?(lv, "#client-#{acme.organisation.id}-link", "Acme")
      assert has_element?(lv, "#client-#{acme.organisation.id}-status", "In use")
      assert has_element?(lv, "#client-#{acme.organisation.id}-owners", acme.owner.user.email)
      assert has_element?(lv, "#client-#{acme.organisation.id}-joined")
      refute has_element?(lv, "#client-#{acme.organisation.id}-invite-owner")
      assert has_element?(lv, "#client-#{acme.organisation.id}-drop")
      assert has_element?(lv, "#client-#{gamma.id}-owners", "No owner yet")
      assert has_element?(lv, "#client-#{gamma.id}-invite-owner")
      # With no owner yet it is deleted, not dropped.
      assert has_element?(lv, "#client-#{gamma.id}-delete")
      refute has_element?(lv, "#client-#{gamma.id}-drop")
      refute has_element?(lv, "#client-#{acme.organisation.id}-delete")
      assert has_element?(lv, "#client-#{beta.organisation.id}-status", "Deleted")
      refute has_element?(lv, "#client-#{beta.organisation.id}-link")
      refute has_element?(lv, "#client-#{beta.organisation.id}-drop")
      assert has_element?(lv, "#nav-clients")

      # Where a cell is cut to keep the row inside the column, its title holds it whole:
      # the name, the owners or the invitation, and the features, the column that gives way.
      assert has_element?(lv, "#client-#{acme.organisation.id}-link[title='Acme']")

      assert has_element?(
               lv,
               "#client-#{acme.organisation.id}-owners[title='#{acme.owner.user.email}']"
             )

      assert has_element?(lv, "#client-#{gamma.id}-owners[title^='No owner yet · expires ']")
      assert has_element?(lv, "#client-#{acme.organisation.id}-features.truncate[title]")
    end

    test "the switcher lists the clients folded under the operator's name, open on a client's page",
         ctx do
      acme = client_fixture(ctx.operator.scope, "Acme")
      client_fixture(ctx.operator.scope, "Beta")

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      fold = "#organisation-menu-places section[data-group] button[data-fold]"
      assert has_element?(lv, fold, "Clients of #{ctx.operator.organisation.name}")
      assert has_element?(lv, fold <> "[aria-expanded=false]", "2")
      assert has_element?(lv, "[data-fold-list][hidden] a[data-switch]", "Acme")

      # On a client's own page its group is open, its place the current one.
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{acme.organisation}/#{acme.workspace}")
      assert has_element?(lv, fold <> "[aria-expanded=true]")
      refute has_element?(lv, "[data-fold-list][hidden]")
    end

    test "an operator's owner creates a client, whose owner the person invited is", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "#clients-empty")
      # The shell's page header: the title, one line, New client among its actions.
      assert has_element?(lv, "#page-header-title", "Clients")
      assert has_element?(lv, "#page-header-description", "run the harness")
      assert has_element?(lv, "#page-header-actions #new-client")
      assert has_element?(lv, "aside#sidebar #nav-clients[aria-current=page]")

      lv |> element("#new-client") |> render_click()
      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients/new")
      # A page of the list, never a dialog: the breadcrumb ends Clients / New client and
      # leads back to the list, the form page has its title, and Cancel at its foot leads
      # back to the list.
      refute has_element?(lv, "#main dialog, #main [role=dialog]")
      refute has_element?(lv, "#clients-empty")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New client")
      assert has_element?(lv, "#breadcrumb a[href='/#{ctx.operator.organisation.slug}/clients']")
      assert has_element?(lv, "h1#settings-section-title", "New client")

      assert has_element?(
               lv,
               "#client-save-cancel[href='/#{ctx.operator.organisation.slug}/clients']",
               "Cancel"
             )

      refute has_element?(lv, "#client-new-back")

      operator = ctx.operator.organisation.name

      # The context is a column beside the form, as statements; the form has none of it, and
      # the page has no sentence under its title and no steps list.
      assert has_element?(
               lv,
               "#settings-section-clients aside#page-context h2",
               "About clients"
             )

      assert text(lv, "#client-about") ==
               "A client is a separate organisation that runs the harness #{operator} provides. It starts with no workspace."

      assert text(lv, "#client-first-person") ==
               "The person you invite becomes its owner when they accept. They set up its first workspace and invite its people."

      assert text(lv, "#client-operator-reach") ==
               "The people of #{operator} read everything in the client and change nothing there."

      refute text(lv, "#client-form") =~ "separate organisation"
      refute text(lv, "#client-form") =~ "first workspace"
      refute has_element?(lv, "#client-form aside, #client-form #client-about")
      refute has_element?(lv, ".q-page-desc, .q-settings-head-sub")
      refute has_element?(lv, "aside#page-context ol")

      refute render(lv) =~ "with a workspace, Main"
      assert has_element?(lv, "#client-form input#organisation_name[phx-mounted]")

      assert has_element?(
               lv,
               "#client-save a#client-save-cancel[href='/#{ctx.operator.organisation.slug}/clients']"
             )

      address = email()

      html =
        lv
        |> form("#client-form", organisation: %{name: "Acme", email: address})
        |> render_submit()

      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients")
      assert html =~ "Acme is created, and #{address} is invited to be its owner."

      assert {:ok, [%{organisation: client, owners: []}]} =
               Operators.list_clients(ctx.operator.scope)

      render_async(lv)
      assert has_element?(lv, "#client-#{client.id}-owners", "No owner yet")

      assert Repo.exists?(
               from i in Apiary.Organisations.Invitation,
                 where: i.organisation_id == ^client.id and i.email == ^address
             )
    end

    test "a name or an address that is refused says so on the form", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/new")

      html =
        lv
        |> form("#client-form", organisation: %{name: "", email: email()})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"

      html =
        lv
        |> form("#client-form", organisation: %{name: "Acme", email: "not an address"})
        |> render_submit()

      assert html =~ "must have the @ sign and no spaces"
      assert {:ok, []} = Operators.list_clients(ctx.operator.scope)
    end

    test "an empty owner's address is answered under its field, and nothing is created", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/new")

      lv |> form("#client-form", organisation: %{name: "Acme", email: ""}) |> render_submit()

      assert has_element?(lv, "#organisation_email-error")
      assert has_element?(lv, ~s|#organisation_email[aria-invalid="true"]|)
      assert {:ok, []} = Operators.list_clients(ctx.operator.scope)
    end

    test "while a client has no owner, its operator's owner invites one again", ctx do
      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => email()})

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      lv |> element("#client-#{client.id}-invite-owner") |> render_click()
      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/owner")
      render_async(lv)
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Invite owner")
      assert has_element?(lv, "#invite-owner-title", "Invite the owner of Acme")
      assert render(lv) =~ "Acme has no owner yet."
      assert has_element?(lv, "#invite-owner-form")
      address = email()

      html =
        lv
        |> form("#invite-owner-form", owner: %{email: address})
        |> render_submit()

      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients")
      assert html =~ "#{address} is invited to be the owner."
    end

    test "an owner's address that cannot be one is answered under its field, and nobody is invited",
         ctx do
      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => email()})

      invited = fn ->
        Repo.aggregate(
          from(i in Apiary.Organisations.Invitation, where: i.organisation_id == ^client.id),
          :count
        )
      end

      before = invited.()

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/owner")

      render_async(lv)

      for address <- ["", "dana", "dana @example.com"] do
        lv |> form("#invite-owner-form", owner: %{email: address}) |> render_submit()

        assert has_element?(lv, "#owner_email-error")
        assert has_element?(lv, "#invite-owner-form")
      end

      assert invited.() == before
    end

    test "an operator's owner drops a client, after typing its name", ctx do
      client = client_fixture(ctx.operator.scope, "Acme")
      id = client.organisation.id

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      lv |> element("#client-#{id}-drop") |> render_click()
      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients/#{id}/drop")

      # The client's row is the confirmation, in place of its cells, never a dialog.
      assert has_element?(
               lv,
               "#client-#{id}.q-confirming #drop-client-form",
               "Acme leaves #{ctx.operator.organisation.name} at once."
             )

      refute has_element?(lv, "#drop-client-form", "lose access")

      refute has_element?(lv, "#client-#{id}-link")
      assert has_element?(lv, "#drop-client-confirming", "Drop Acme?")
      assert has_element?(lv, "#drop-client-confirm[disabled]", "Yes, drop")
      assert has_element?(lv, "#drop-client-confirming-cancel")

      # Cancel gives the row back.
      lv |> element("#drop-client-confirming-cancel") |> render_click()
      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients")
      assert has_element?(lv, "#client-#{id}-link")
      lv |> element("#client-#{id}-drop") |> render_click()

      # Sent without the client's name, it is refused by the server too.
      html =
        render_submit(lv, "drop_client", %{"client_id" => id, "confirm" => %{"name" => "Not it"}})

      assert html =~ "is not the name"
      assert Repo.get!(Tenant, id).operator_id == ctx.operator.organisation.id

      html =
        lv
        |> form("#drop-client-form", confirm: %{name: "Acme"})
        |> render_submit()

      assert html =~ "Acme is no client of #{ctx.operator.organisation.name} any more."
      render_async(lv)
      refute has_element?(lv, "#client-#{client.organisation.id}-link")
      assert Repo.get!(Tenant, client.organisation.id).operator_id == nil
    end

    test "while a client has no owner, its operator's owner revokes an invitation of its owner, and deletes it",
         ctx do
      address = email()

      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => address})

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      [invitation] =
        Repo.all(
          from i in Apiary.Organisations.Invitation, where: i.organisation_id == ^client.id
        )

      assert has_element?(lv, "#owner-invitation-#{invitation.id}", address)
      html = lv |> element("#owner-invitation-#{invitation.id}-revoke") |> render_click()
      assert html =~ "The invitation of #{address} is revoked."
      render_async(lv)
      refute has_element?(lv, "#owner-invitation-#{invitation.id}")

      lv |> element("#client-#{client.id}-delete") |> render_click()
      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/delete")

      assert has_element?(
               lv,
               "#client-#{client.id}.q-confirming #delete-client-form",
               "nobody else is in it"
             )

      assert has_element?(lv, "#delete-client-confirm[disabled]", "Yes, delete")

      html =
        render_submit(lv, "delete_client", %{
          "client_id" => client.id,
          "confirm" => %{"name" => "Not it"}
        })

      assert html =~ "is not the name"

      html = lv |> form("#delete-client-form", confirm: %{name: "Acme"}) |> render_submit()
      assert html =~ "Acme is deleted, and is purged on"
      render_async(lv)
      assert has_element?(lv, "#client-#{client.id}-status", "Deleted")
      assert %DateTime{} = Repo.get!(Organisation, client.id).deletion_marked_at
    end

    test "a client's delete path, typed while its Delete is not offered, leads back to the list",
         ctx do
      %{operator: %{organisation: operator}} = ctx
      owned = client_fixture(ctx.operator.scope, "Acme")
      path = ~p"/#{operator}/clients/#{owned.organisation.id}/delete"
      refused = "That client has an owner now: drop it instead, and its owner keeps it."

      # Opened by its path: the rows arrive after it, and the page leaves when they do.
      {:ok, lv, _html} = live(ctx.conn, path)
      render_async(lv)
      assert_patch(lv, ~p"/#{operator}/clients")
      assert has_element?(lv, "#flash-error", refused)
      refute has_element?(lv, "#delete-client-form")
      assert has_element?(lv, "#client-#{owned.organisation.id}-drop")
      refute has_element?(lv, "#client-#{owned.organisation.id}-delete")

      # Patched to from the list, the rows already there: it leaves at once.
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients")
      render_async(lv)
      render_patch(lv, path)
      assert_patch(lv, ~p"/#{operator}/clients")
      assert has_element?(lv, "#flash-error", refused)
      refute has_element?(lv, "#delete-client-form")
    end

    test "a client's delete path, typed while its Delete is offered, asks to confirm", ctx do
      %{operator: %{organisation: operator}} = ctx

      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => email()})

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/#{client.id}/delete")
      render_async(lv)

      assert has_element?(
               lv,
               "#client-#{client.id}.q-confirming #delete-client-form",
               "nobody else is in it"
             )

      refute has_element?(lv, "#flash-error")
    end

    test "a member of the operator lists the clients, and creates, invites and drops none",
         ctx do
      client = client_fixture(ctx.operator.scope, "Acme")
      %{user: member} = member_fixture(ctx.operator.scope, :member)
      conn = log_in_user(build_conn(), member)

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "#clients a", "Acme")
      refute has_element?(lv, "#new-client")
      refute has_element?(lv, "#client-#{client.organisation.id}-drop")
      # Who adds one is said where the list is empty, not above a list.
      refute has_element?(lv, "#clients-who")

      for path <- [
            ~p"/#{ctx.operator.organisation}/clients/new",
            ~p"/#{ctx.operator.organisation}/clients/#{client.organisation.id}/drop",
            ~p"/#{ctx.operator.organisation}/clients/#{client.organisation.id}/owner"
          ] do
        assert {:error, {:live_redirect, %{to: to}}} = live(conn, path)
        assert to == ~p"/#{ctx.operator.organisation}/clients"
      end
    end

    test "an organisation that is no operator has no Clients page", %{conn: conn} do
      %{user: user, organisation: organisation} = sign_up_fixture()
      conn = log_in_user(conn, user)

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/#{organisation}/clients") end
    end

    test "the switcher shows the clients the person reads through their operator", ctx do
      client = client_fixture(ctx.operator.scope, "Acme")

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/settings/people")

      assert has_element?(lv, "#organisation-menu a#switch-#{client.organisation.slug}", "Acme")

      assert has_element?(
               lv,
               "#organisation-menu-of-#{client.organisation.slug} #switch-#{client.organisation.slug}_#{client.workspace.slug}"
             )

      # It opens there, read-only, and says so.
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{client.organisation}/#{client.workspace}")

      assert has_element?(lv, "#operator-reader", "and nothing changed")
    end

    test "a client's People page lists its own people, read-only for the operator's", ctx do
      client = client_fixture(ctx.operator.scope, "Acme")
      %{membership: membership} = member_fixture(client.owner.scope, :member)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{client.organisation}/settings/people")
      assert has_element?(lv, "#member-#{client.owner.membership.id}", client.owner.user.email)
      refute has_element?(lv, "#member-#{membership.id}-level-owner")
      refute has_element?(lv, "a", "Invite people")
      assert has_element?(lv, "#operator-reader")

      # Its owner gives any level there, owner included.
      conn = log_in_user(build_conn(), client.owner.user)
      {:ok, lv, _html} = live(conn, ~p"/#{client.organisation}/settings/people")
      assert has_element?(lv, "#member-#{membership.id}-level-owner")
      assert has_element?(lv, "a", "Invite people")
      refute has_element?(lv, "#operator-reader")
    end

    test "the list is one column: no rail beside it, its crumb and title name it", ctx do
      %{operator: %{organisation: operator}} = ctx
      client_fixture(ctx.operator.scope, "Acme")

      {%{organisation: shop}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Shop", "email" => email()})

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients")
      render_async(lv)

      # The rail of waiting requests and owner invitations is gone, from every width.
      refute has_element?(lv, "#main aside")
      refute has_element?(lv, ".q-clients, .q-clients-rail")
      refute has_element?(lv, "#main a[href*='/clients/requests']")
      refute has_element?(lv, "#rail-requests-h")
      refute has_element?(lv, "#rail-invitations-h")
      refute render(lv) =~ "Owner invitations"
      assert has_element?(lv, "#client-#{shop.id}-owners", "No owner yet")

      # The views, the bar, the status line and the table, in one column, as Nodes.
      assert has_element?(lv, "#main div.grid > #clients-views")
      assert has_element?(lv, "#main div.grid > div.q-bar #clients-search")
      assert has_element?(lv, "#main div.grid > #clients-status")
      refute has_element?(lv, "div.q-bar #clients-views")

      # The breadcrumb names the page, as the core's Nodes does, and so does the title,
      # with the operator's name.
      assert Trail.crumbs(lv) == ["Clients"]
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Clients")
      # The section's own page: a phone's bar names it alone.
      assert Trail.up(lv) == nil
      assert page_title(lv) == "Clients · #{operator.name} · Qory Apiary"

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/new")
      assert Trail.crumbs(lv) == ["Clients", "New client"]
      # A phone's bar keeps Clients as the page's parent, a link back.
      assert Trail.up(lv) == {"Clients", ~p"/#{operator}/clients"}
      assert page_title(lv) == "New client · Clients · #{operator.name} · Qory Apiary"

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/#{shop.id}/owner")
      render_async(lv)
      assert Trail.crumbs(lv) == ["Clients", "Invite owner"]
      assert page_title(lv) == "Invite owner · Clients · #{operator.name} · Qory Apiary"

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/#{shop.id}/features")
      render_async(lv)
      assert Trail.crumbs(lv) == ["Clients", "Features"]
      assert page_title(lv) == "Features · Clients · #{operator.name} · Qory Apiary"
    end

    test "the operator's policy requests are in the sidebar, where security is on", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      assert has_element?(
               lv,
               "aside#sidebar a#nav-client_requests[href='#{~p"/#{ctx.operator.organisation}/clients/requests"}']",
               "Policy requests"
             )
    end

    test "an owner invitation's expiry is in the Owner cell, marked under a day away", ctx do
      address = email()

      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => address})

      [invitation] = Repo.all(from i in Invitation, where: i.organisation_id == ^client.id)
      expires = "expires #{ApiaryWeb.Format.day(invitation.expires_at)}"

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      cell = "#client-#{client.id}-owners #owner-invitation-#{invitation.id}"
      assert has_element?(lv, cell, "Invited: #{address}")
      assert has_element?(lv, cell <> " #owner-invitation-#{invitation.id}-expires", expires)

      # The expiry comes before the address, so a cut cell loses the address, not it.
      assert lv |> element(cell) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() =~
               ~r/^\s*·\s*#{expires}\s*·\s*Invited: #{Regex.escape(address)}\s*$/

      refute has_element?(lv, "#owner-invitation-#{invitation.id}-expires.q-hot")

      # The cell's title holds its words whole, the expiry with them.
      assert has_element?(
               lv,
               ~s|#client-#{client.id}-owners[title="No owner yet · #{expires} · Invited: #{address}"]|
             )

      # Under a day away, the expiry is the fact that needs the operator.
      soon = DateTime.utc_now() |> DateTime.add(3, :hour) |> DateTime.truncate(:second)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [expires_at: soon]
      )

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "#owner-invitation-#{invitation.id}-expires.q-hot")
    end

    test "the status line says what the search and the filters leave", ctx do
      client_fixture(ctx.operator.scope, "Acme")
      client_fixture(ctx.operator.scope, "Shop")
      operator = ctx.operator.organisation

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients")
      render_async(lv)

      # Always there, quiet while nothing narrows the list.
      assert has_element?(lv, "#clients-status[role=status].q-status")
      refute has_element?(lv, "#clients-summary")
      refute has_element?(lv, "#clients-none")

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients?q=acme")
      render_async(lv)
      assert has_element?(lv, "#clients-status #clients-summary", "1 client matches")

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients?features=security")
      render_async(lv)
      assert has_element?(lv, "#clients-status #clients-summary", "2 clients match")
    end

    test "a search that leaves no client says so, and Clear filters gives the view back", ctx do
      client_fixture(ctx.operator.scope, "Acme")
      operator = ctx.operator.organisation

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/#{operator}/clients?view=no_owner&q=nothing&features=security")

      render_async(lv)

      refute has_element?(lv, "#clients")
      refute has_element?(lv, "#clients-summary")
      assert has_element?(lv, "#clients-status #clients-none", "No client matches")

      assert has_element?(
               lv,
               "#clients-none",
               "No client has that name, slug, owner or feature."
             )

      lv |> element("#clients-none-clear", "Clear filters") |> render_click()
      assert_patch(lv, ~p"/#{operator}/clients?view=no_owner")
      assert has_element?(lv, "#clients-none", "No client here")
      assert has_element?(lv, "#clients-none", "Every client has an owner.")
      refute has_element?(lv, "#clients-none-clear")
    end

    test "a view with no client says so in its own words", ctx do
      client_fixture(ctx.operator.scope, "Acme")
      operator = ctx.operator.organisation

      for {view, sentence} <- [
            {"no_owner", "Every client has an owner."},
            {"suspended", "No client is suspended."},
            {"deleted", "No client is deleted."}
          ] do
        {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients?view=#{view}")
        render_async(lv)

        assert has_element?(lv, "#clients-view-#{view}[aria-current]")
        assert has_element?(lv, "#clients-status #clients-none", "No client here")
        assert has_element?(lv, "#clients-none", sentence)
        refute has_element?(lv, "#clients-none", "No client matches")
        refute has_element?(lv, "#clients-none-clear")
      end
    end

    test "a member of an operator with no client is told who adds one, in the empty state",
         ctx do
      %{user: member} = member_fixture(ctx.operator.scope, :member)
      conn = log_in_user(build_conn(), member)

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      assert has_element?(
               lv,
               "#clients-empty #clients-who",
               "Only owners and admins of #{ctx.operator.organisation.name} add a client"
             )

      # Its owner adds one, and is told nothing of the kind.
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "#clients-empty")
      refute has_element?(lv, "#clients-who")
    end
  end

  describe "an organisation offered to the operator" do
    setup :operator

    setup ctx do
      offered = sign_up_fixture()
      {:ok, _} = Transfers.offer_to_operator(offered.scope, ctx.operator.organisation.slug)
      %{offered: offered}
    end

    test "its owner's Accept asks in place, not in red, and Cancel accepts nothing", ctx do
      %{operator: %{organisation: operator}, offered: %{organisation: org}} = ctx
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients")
      render_async(lv)

      assert has_element?(lv, "#offers #offer-#{org.id}", org.name)

      assert has_element?(
               lv,
               "#offer-#{org.id}-accept[aria-label='Accept #{org.name} as a client']"
             )

      # Asking acts on nothing by itself.
      lv |> element("#offer-#{org.id}-accept") |> render_click()
      assert_patch(lv, ~p"/#{operator}/clients/offers/#{org.id}/accept")
      assert Repo.get!(Tenant, org.id).operator_id == nil

      # The offer's row is the question, in place of its cells, never a dialog.
      refute has_element?(lv, "#main dialog, #main [role=dialog]")
      confirm = "#offer-#{org.id}.q-confirming #offer-#{org.id}-confirm"
      assert has_element?(lv, confirm <> "[role=group]")
      assert has_element?(lv, confirm, "Accept #{org.name} as a client?")

      assert has_element?(
               lv,
               confirm,
               "It becomes a client of #{operator.name} at once: its people keep their levels"
             )

      # Nothing is lost that cannot be had again: the button is not red.
      assert has_element?(lv, "#offer-#{org.id}-confirm-button.btn-primary", "Yes, accept")
      refute has_element?(lv, "#offer-#{org.id}-confirm .btn-error")
      refute has_element?(lv, "#offer-#{org.id}-accept")

      lv |> element("#offer-#{org.id}-confirm-cancel") |> render_click()
      assert_patch(lv, ~p"/#{operator}/clients")
      refute has_element?(lv, "#offer-#{org.id}-confirm")
      assert has_element?(lv, "#offer-#{org.id}-accept")
      assert Repo.get!(Tenant, org.id).operator_id == nil

      # Asked again, and answered.
      lv |> element("#offer-#{org.id}-accept") |> render_click()
      html = lv |> element("#offer-#{org.id}-confirm-button") |> render_click()
      assert html =~ "#{org.name} is a client of #{operator.name} now"
      assert_patch(lv, ~p"/#{operator}/clients")
      render_async(lv)
      refute has_element?(lv, "#offers")
      assert has_element?(lv, "#client-#{org.id}-link")
      assert Repo.get!(Tenant, org.id).operator_id == operator.id
    end

    test "an offer withdrawn while its row asks is refused, and the list comes back", ctx do
      %{operator: %{organisation: operator}, offered: offered} = ctx
      org = offered.organisation

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/offers/#{org.id}/accept")
      render_async(lv)
      assert has_element?(lv, "#offer-#{org.id}-confirm")

      {:ok, _} = Transfers.withdraw(offered.scope)

      html = lv |> element("#offer-#{org.id}-confirm-button") |> render_click()
      assert html =~ "That offer is no longer pending"
      assert_patch(lv, ~p"/#{operator}/clients")
      render_async(lv)
      refute has_element?(lv, "#offers")
      assert Repo.get!(Tenant, org.id).operator_id == nil
    end

    test "an admin of the operator lists the offer; its path refuses them as it opens", ctx do
      %{operator: %{organisation: operator}, offered: %{organisation: org}} = ctx
      %{user: admin} = member_fixture(ctx.operator.scope, :admin)
      conn = log_in_user(build_conn(), admin)

      {:ok, lv, _html} = live(conn, ~p"/#{operator}/clients")
      render_async(lv)
      assert has_element?(lv, "#offer-#{org.id}", org.name)
      refute has_element?(lv, "#offer-#{org.id}-accept")

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
               live(conn, ~p"/#{operator}/clients/offers/#{org.id}/accept")

      assert to == ~p"/#{operator}/clients"
      assert error == "Only an owner of #{operator.name} accepts an organisation offered to it."
      assert Repo.get!(Tenant, org.id).operator_id == nil
    end
  end

  defp email, do: Apiary.AccountsFixtures.unique_user_email()

  @tag with_features: [:observability, :security]
  test "without managed_organisations the page is not there", %{conn: conn} do
    # An operator from before the feature was switched off.
    %{organisation: organisation, user: user} = sign_up_fixture()

    Repo.update_all(from(t in Tenant, where: t.organisation_id == ^organisation.id),
      set: [kind: :operator]
    )

    assert conn |> log_in_user(user) |> get(~p"/#{organisation}/clients") |> response(404)
  end
end
