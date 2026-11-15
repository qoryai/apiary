defmodule ApiaryProWeb.ClientLive.IndexTest do
  # Not async: the features are the node's, and an operator is made by an instance admin,
  # an owner of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query

  alias Apiary.{Features, Repo}
  alias Apiary.Organisations.Organisation
  alias Apiary.Organisations.Invitation
  alias ApiaryPro.Operators
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
      assert has_element?(lv, "#client-#{gamma.id}-owners", "No owner yet")
      assert has_element?(lv, "#client-#{gamma.id}-invite-owner")
      # With no owner yet it is deleted.
      assert has_element?(lv, "#client-#{gamma.id}-delete")
      refute has_element?(lv, "#client-#{acme.organisation.id}-delete")
      assert has_element?(lv, "#client-#{beta.organisation.id}-status", "Deleted")
      refute has_element?(lv, "#client-#{beta.organisation.id}-link")
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

    test "the switcher lists the workspaces the operator operates under the operator, the current one marked",
         ctx do
      acme = client_fixture(ctx.operator.scope, "Acme")
      beta = client_fixture(ctx.operator.scope, "Beta")
      op = ctx.operator.organisation.slug
      [a, b] = [acme.organisation.slug, beta.organisation.slug]
      main = acme.workspace.slug

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      refute has_element?(lv, "#organisation-menu li[data-org='#{a}']")

      assert has_element?(
               lv,
               "#organisation-menu-of-#{op} a#switch-#{op}_#{a}_#{main}",
               "Main · Acme"
             )

      assert has_element?(
               lv,
               "#organisation-menu-of-#{op} a#switch-#{op}_#{b}_#{beta.workspace.slug}",
               "Main · Beta"
             )

      # In a client's workspace, its entry under the operator is the current one.
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{acme.organisation}/#{acme.workspace}")

      assert has_element?(
               lv,
               "#organisation-menu-of-#{op}:not([hidden]) a#switch-#{op}_#{a}_#{main}[aria-current='true']"
             )
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
      refused = "That client has an owner now, so it can't be deleted."

      # Opened by its path: the rows arrive after it, and the page leaves when they do.
      {:ok, lv, _html} = live(ctx.conn, path)
      render_async(lv)
      assert_patch(lv, ~p"/#{operator}/clients")
      assert has_element?(lv, "#flash-error", refused)
      refute has_element?(lv, "#delete-client-form")
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

    test "a member of the operator lists the clients, and creates and invites none",
         ctx do
      client = client_fixture(ctx.operator.scope, "Acme")
      %{user: member} = member_fixture(ctx.operator.scope, :member)
      conn = log_in_user(build_conn(), member)

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "#clients a", "Acme")
      refute has_element?(lv, "#new-client")
      # Who adds one is said where the list is empty, not above a list.
      refute has_element?(lv, "#clients-who")

      for path <- [
            ~p"/#{ctx.operator.organisation}/clients/new",
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

    test "the switcher shows the workspace the person reads through their operator", ctx do
      client = client_fixture(ctx.operator.scope, "Acme")
      op = ctx.operator.organisation.slug

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/settings/people")

      assert has_element?(
               lv,
               "#organisation-menu-of-#{op} #switch-#{op}_#{client.organisation.slug}_#{client.workspace.slug}",
               "Main · Acme"
             )

      # It opens there, read-only, and says so.
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{client.organisation}/#{client.workspace}")

      assert has_element?(lv, "#operator-reader", "and nothing changed")
    end

    test "a client's People page lists its people for them, and is not found for the operator's",
         ctx do
      client = client_fixture(ctx.operator.scope, "Acme")
      %{membership: membership} = member_fixture(client.owner.scope, :member)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(ctx.conn, ~p"/#{client.organisation}/settings/people")
      end

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
