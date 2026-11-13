defmodule ApiaryProWeb.ClientLive.OperatorOwnsTest do
  # The operator owns its clients for this process and those it starts
  # (`ApiaryPro.Flags.put_operator_infrastructure/1`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  @admin_invitations [
    :"client.invite_admin",
    :"client.revoke_admin_invitation",
    :"client.renew_admin_invitation"
  ]

  setup %{conn: conn} do
    operator = operator_fixture()

    # A client accepted before, whose owner stays its owner.
    legacy = client_fixture(operator.scope, "Legacy")

    Flags.put_operator_infrastructure(true)

    {%{organisation: fresh}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Fresh", "email" => email()})

    %{conn: log_in_user(conn, operator.user), operator: operator, legacy: legacy, fresh: fresh}
  end

  defp clients(ctx, query \\ "") do
    {:ok, lv, _html} = live(ctx.conn, "/#{ctx.operator.organisation.slug}/clients#{query}")
    render_async(lv)
    lv
  end

  test "the list says the operator owns its clients, and names their admins", ctx do
    lv = clients(ctx)
    name = ctx.operator.organisation.name
    legacy = ctx.legacy.organisation.id
    fresh = ctx.fresh.id

    assert has_element?(
             lv,
             "#page-header-description",
             "The organisations that run the harness #{name} provides. #{name} owns each one: its owners and admins run the workspaces, machines and keys there. Each client's admins manage its people."
           )

    assert has_element?(lv, "th", "Admins")
    refute has_element?(lv, "th", "Owner")

    assert has_element?(
             lv,
             "#clients-search input[placeholder='Find a client by name, slug or admin']"
           )

    assert has_element?(lv, "#clients-view-no_owner", "Without an admin")

    # The legacy owner is named; the fresh client has nobody yet.
    assert has_element?(lv, "#client-#{legacy}-owners", ctx.legacy.owner.user.email)
    assert has_element?(lv, "#client-#{fresh}-owners", "No admin yet")
    assert has_element?(lv, "#client-#{fresh}-owners[title^='No admin yet · expires ']")

    # Invite the first admin and delete on the one nobody has joined; Drop nowhere.
    assert has_element?(lv, "#client-#{fresh}-invite-admin", "Invite the first admin…")

    assert has_element?(
             lv,
             "#client-#{fresh}-invite-admin[aria-label='Invite the first admin of Fresh']"
           )

    assert has_element?(lv, "#client-#{fresh}-delete")
    refute has_element?(lv, "#client-#{fresh}-invite-owner")
    refute has_element?(lv, "#client-#{legacy}-invite-admin")
    refute has_element?(lv, "#client-#{legacy}-delete")
    refute has_element?(lv, "[id$='-drop']")
    refute render(lv) =~ "Drop…"

    # A search by an admin's address finds the client.
    admin = client_member_fixture(ctx.legacy, :admin)
    lv = clients(ctx, "?q=#{URI.encode_www_form(admin.user.email)}")
    assert has_element?(lv, "#client-#{legacy}-link")
    refute has_element?(lv, "#client-#{fresh}-link")

    lv = clients(ctx, "?q=nothing-matches-this")
    assert has_element?(lv, "#clients-none", "No client has that name, slug, admin or feature.")
  end

  test "a view with every client's admin there says so", ctx do
    {:ok, _} =
      ApiaryPro.Deletion.delete_client(ctx.operator.scope, ctx.fresh.id, ctx.fresh.name)

    lv = clients(ctx, "?view=no_owner")
    assert has_element?(lv, "#clients-none", "Every client has an admin.")
  end

  test "a client with a member and no admin offers no Delete", ctx do
    email = email()

    {%{organisation: client}, token} =
      create_client_fixture(ctx.operator.scope, %{"name" => "Joined", "email" => email})

    %{membership: membership} =
      Apiary.OrganisationsFixtures.sign_up_fixture(%{email: email, invitation_token: token})

    owner_in_client = scope_in(ctx.operator.user, client)

    {:ok, %{level: :member}} =
      Apiary.Organisations.set_member_level(owner_in_client, membership.id, :member)

    lv = clients(ctx)
    assert has_element?(lv, "#client-#{client.id}-owners", "No admin yet")
    refute has_element?(lv, "#client-#{client.id}-delete")
    # The client nobody has joined still offers it.
    assert has_element?(lv, "#client-#{ctx.fresh.id}-delete")
  end

  test "the first admin is invited on a page of their own", ctx do
    operator = ctx.operator.organisation
    lv = clients(ctx)

    lv |> element("#client-#{ctx.fresh.id}-invite-admin") |> render_click()
    assert_patch(lv, ~p"/#{operator}/clients/#{ctx.fresh.id}/admin")
    render_async(lv)

    assert has_element?(lv, "#breadcrumb [aria-current=page]", "Invite the first admin")
    assert has_element?(lv, "#invite-owner-title", "Invite the first admin of Fresh")

    assert render(lv) =~
             "Fresh has no admin yet. The person you invite is its first admin once they accept, and invites and manages its people. The invitation counts against the invitations of #{operator.name}."

    assert has_element?(lv, "label", "The admin's email address")
    address = email()

    html = lv |> form("#invite-owner-form", owner: %{email: address}) |> render_submit()
    assert_patch(lv, ~p"/#{operator}/clients")
    assert html =~ "#{address} is invited to be the first admin."
  end

  test "a new client's first person is its first admin", ctx do
    operator = ctx.operator.organisation
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/new")

    # The flag on: the column says the first person is the client's first admin, and what
    # the operator's owners and admins do.
    assert has_element?(lv, "aside#page-context h2", "About clients")

    assert text(lv, "#client-about") ==
             "A client is a separate organisation that runs the harness #{operator.name} provides. It starts with no workspace."

    assert text(lv, "#client-first-person") ==
             "The person you invite becomes its first admin when they accept. They invite and manage its people."

    assert text(lv, "#client-operator-reach") ==
             "The first admin creates the client's first workspace. Owners and admins of #{operator.name} run its workspaces, machines and keys."

    refute text(lv, "#client-form") =~ "first admin"
    refute render(lv) =~ "owns it"

    assert has_element?(lv, "label", "The admin's email address")
    address = email()

    html =
      lv
      |> form("#client-form", organisation: %{name: "Acme", email: address})
      |> render_submit()

    assert html =~ "Acme is created, and #{address} is invited to be its first admin."
  end

  test "a client name whose address another organisation has is refused, and nothing is numbered",
       ctx do
    operator = ctx.operator.organisation
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/new")

    lv
    |> form("#client-form", organisation: %{name: "Acme", email: email()})
    |> render_submit()

    {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/new")

    html =
      lv
      |> form("#client-form", organisation: %{name: "Acme", email: email()})
      |> render_submit()

    assert html =~ "Choose another name. Another organisation has the address /acme."
    refute Apiary.Repo.get_by(Apiary.Organisations.Organisation, slug: "acme-2")

    assert [_one] =
             Apiary.Repo.all(from o in Apiary.Organisations.Organisation, where: o.slug == "acme")
  end

  test "the first owner's page and the drop's are not found", ctx do
    operator = ctx.operator.organisation

    for path <- [
          ~p"/#{operator}/clients/#{ctx.fresh.id}/owner",
          ~p"/#{operator}/clients/#{ctx.legacy.organisation.id}/drop"
        ] do
      assert_raise ApiaryWeb.NotFound, fn -> live(ctx.conn, path) end
    end
  end

  test "a client nobody has joined is deleted, in the words of the flag", ctx do
    operator = ctx.operator.organisation
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/#{ctx.fresh.id}/delete")
    render_async(lv)

    assert render(lv) =~
             "Nobody has joined Fresh yet. It disappears at once, with its pending invitations, and is purged after"

    {:ok, _} = ApiaryPro.Deletion.delete_client(ctx.operator.scope, ctx.fresh.id, "Fresh")
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/audit-log")
    render_async(lv)
    assert render(lv) =~ "Deleted Fresh, which nobody had joined yet"
  end

  # A client one person has joined, as a member, with no admin and no owner.
  defp joined_client(ctx) do
    email = email()

    {%{organisation: client}, token} =
      create_client_fixture(ctx.operator.scope, %{"name" => "Joined", "email" => email})

    %{membership: membership} =
      Apiary.OrganisationsFixtures.sign_up_fixture(%{email: email, invitation_token: token})

    owner_in_client = scope_in(ctx.operator.user, client)

    {:ok, %{level: :member}} =
      Apiary.Organisations.set_member_level(owner_in_client, membership.id, :member)

    client
  end

  test "a delete path typed for a client someone has joined leads back to the list", ctx do
    operator = ctx.operator.organisation
    joined = joined_client(ctx)
    refused = "Someone has joined that client now, so it can't be deleted."

    for id <- [joined.id, ctx.legacy.organisation.id] do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/#{id}/delete")
      render_async(lv)
      assert_patch(lv, ~p"/#{operator}/clients")
      assert has_element?(lv, "#flash-error", refused)
      refute has_element?(lv, "#delete-client-form")
      refute has_element?(lv, "#client-#{id}-delete")
    end

    # The client nobody has joined still asks to confirm.
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/#{ctx.fresh.id}/delete")
    render_async(lv)
    assert has_element?(lv, "#client-#{ctx.fresh.id}.q-confirming #delete-client-form")
    refute has_element?(lv, "#flash-error")
  end

  test "with the flag off, a delete path typed for a client with an owner leads back", ctx do
    operator = ctx.operator.organisation
    joined = joined_client(ctx)
    Flags.put_operator_infrastructure(false)

    {:ok, lv, _html} =
      live(ctx.conn, ~p"/#{operator}/clients/#{ctx.legacy.organisation.id}/delete")

    render_async(lv)
    assert_patch(lv, ~p"/#{operator}/clients")

    assert has_element?(
             lv,
             "#flash-error",
             "That client has an owner now: drop it instead, and its owner keeps it."
           )

    refute has_element?(lv, "#delete-client-form")

    # A client with no owner, even one someone has joined, asks to confirm, as its
    # deletion would go ahead.
    for id <- [joined.id, ctx.fresh.id] do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator}/clients/#{id}/delete")
      render_async(lv)
      assert has_element?(lv, "#client-#{id}.q-confirming #delete-client-form")
      refute has_element?(lv, "#flash-error")
    end
  end

  test "a member of an operator with no client is told who adds one" do
    other = operator_fixture()
    member = Apiary.OrganisationsFixtures.member_fixture(other.scope, :member)

    {:ok, lv, _html} =
      live(log_in_user(build_conn(), member.user), ~p"/#{other.organisation}/clients")

    render_async(lv)

    assert has_element?(
             lv,
             "#clients-who",
             "Only owners and admins of #{other.organisation.name} add a client and invite its first admin."
           )
  end

  test "the client's trail says its first admin was invited, and the filter may offer it", ctx do
    {:ok, lv, _html} = live(ctx.conn, "/#{ctx.fresh.slug}/audit-log")
    render_async(lv)

    assert render(lv) =~ "Invited its first admin, for its operator"

    for action <- @admin_invitations,
        do: assert(ApiaryProWeb.ActivityDescriber.offered?(ctx.operator.scope, action))
  end

  test "a client's own owner opens its nodes, and is offered no change to them", ctx do
    # The nodes page opens for the client's own owner, offers no New node, and New node's
    # path sends them back to the list.
    conn = log_in_user(build_conn(), ctx.legacy.owner.user)
    path = "/#{ctx.legacy.organisation.slug}/#{ctx.legacy.workspace.slug}/machines"

    {:ok, lv, _html} = live(conn, path)
    render_async(lv)
    refute has_element?(lv, "a[href='#{path}/new']")

    # New node sends them back to the list, refused.
    assert {:error, {:live_redirect, %{to: ^path}}} = live(conn, path <> "/new")
  end

  describe "the words for the operator's people in a client" do
    # The workspace's set-up is finished, so a link to it leads to the Overview.
    setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

    test "its owners and admins are told they work there, its members that they read", ctx do
      legacy = ctx.legacy
      operator = ctx.operator.organisation.name
      path = ~p"/#{legacy.organisation}/#{legacy.workspace}"

      {:ok, lv, _html} = live(ctx.conn, path)

      assert has_element?(
               lv,
               "#organisation-notices #operator-owner",
               "You work in Legacy as an owner of #{operator}, its operator."
             )

      refute has_element?(lv, "#operator-reader")

      admin = Apiary.OrganisationsFixtures.member_fixture(ctx.operator.scope, :admin)
      {:ok, lv, _html} = live(log_in_user(build_conn(), admin.user), path)

      assert has_element?(
               lv,
               "#operator-owner",
               "You work in Legacy as an admin of #{operator}, its operator."
             )

      refute has_element?(lv, "#operator-reader")

      member = Apiary.OrganisationsFixtures.member_fixture(ctx.operator.scope, :member)
      {:ok, lv, _html} = live(log_in_user(build_conn(), member.user), path)
      assert has_element?(lv, "#operator-reader", "and nothing changed")
      refute has_element?(lv, "#operator-owner")

      # Someone with a membership of their own in the client is told nothing of the kind.
      {:ok, lv, _html} = live(log_in_user(build_conn(), legacy.owner.user), path)
      refute has_element?(lv, "#operator-owner")
      refute has_element?(lv, "#operator-reader")
    end

    test "the refusal's sentence of a reader is the operator's members' alone", ctx do
      legacy = ctx.legacy.organisation
      workspace = ctx.legacy.workspace
      admin = Apiary.OrganisationsFixtures.member_fixture(ctx.operator.scope, :admin)
      member = Apiary.OrganisationsFixtures.member_fixture(ctx.operator.scope, :member)

      assert ApiaryProWeb.Readers.sentence(
               :refused,
               scope_in(ctx.operator.user, legacy, workspace)
             ) ==
               nil

      assert ApiaryProWeb.Readers.sentence(:refused, scope_in(admin.user, legacy, workspace)) ==
               nil

      assert ApiaryProWeb.Readers.sentence(:refused, scope_in(member.user, legacy, workspace)) =~
               "as a person of its operator"
    end

    test "the client's settings say the operator owns it", ctx do
      legacy = ctx.legacy.organisation
      operator = ctx.operator.organisation.name
      conn = log_in_user(build_conn(), ctx.legacy.owner.user)

      {:ok, lv, _html} = live(conn, ~p"/#{legacy}/settings/ownership")

      assert has_element?(
               lv,
               "#operator",
               "Legacy runs the harness #{operator} provides. #{operator} owns it: its owners and admins run its workspaces, machines and keys, and its members read everything in it."
             )

      {:ok, lv, _html} = live(conn, ~p"/#{legacy}/settings/people")
      assert has_element?(lv, "#operated-by", "Owned by #{operator}")
    end
  end

  defp email, do: Apiary.AccountsFixtures.unique_user_email()

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
