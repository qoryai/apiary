defmodule ApiaryProWeb.SettingsLive.OwnershipTest do
  @moduledoc """
  The Ownership section of an organisation's settings: a client's operator, which its owners
  leave; an organisation offered to an operator; and the arbiter's offer to an admin,
  told on every page and accepted here.
  """
  # Not async: the features are the node's, and an operator is made by an instance admin,
  # an owner of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo}
  alias Apiary.Organisations.Membership
  alias ApiaryPro.Transfers
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryProWeb.Trail

  @moduletag with_features: Features.all()

  # An operator, its client Acme with its owner, and an admin of Acme; the client's owner
  # logged in.
  defp client_with_admin(%{conn: conn}) do
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    admin = member_fixture(client.owner.scope, :admin)

    %{
      conn: log_in_user(conn, client.owner.user),
      operator: operator,
      client: client,
      admin: admin
    }
  end

  defp settings(organisation), do: ~p"/#{organisation}/settings"
  defp ownership(organisation), do: ~p"/#{organisation}/settings/ownership"

  describe "a client and its operator" do
    setup :client_with_admin

    test "its owners are listed as any organisation's, and its operator named", ctx do
      client = ctx.client.organisation
      {:ok, lv, _html} = live(ctx.conn, settings(client))

      assert has_element?(
               lv,
               "#owner-#{ctx.client.owner.membership.id}",
               ctx.client.owner.user.email
             )

      # The settings' list beside the section: the Ownership entry leads to the operator.
      assert has_element?(lv, "#settings-tab-organisation[aria-current='page']")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#settings-tab-ownership") |> render_click()

      assert to == ownership(client)

      {:ok, lv, _html} = live(ctx.conn, ownership(client))

      # The edition's section is in the organisation's list, under the organisation's sidebar.
      assert has_element?(lv, "#settings-tabs #settings-tab-ownership[aria-current='page']")
      # The settings' sections are the frame's second column, not a list in the page.
      assert has_element?(lv, "#shell-content #settings-tabs #settings-tab-ownership")
      refute has_element?(lv, "#main #settings-tabs")
      assert has_element?(lv, "aside#sidebar[aria-label='Organisation']")
      # The sidebar's Settings is current as the parent of the second column's section.
      assert has_element?(lv, ".q-sidebar-foot #nav-organisation[aria-current='true']")
      # The frame writes the level and the section; the section's title is the page's one
      # h1, and the browser's title names the section, the level and the organisation.
      assert Trail.crumbs(lv) == ["Organisation settings", "Ownership"]
      assert has_element?(lv, "#breadcrumb-section[aria-current=page]", "Ownership")
      assert has_element?(lv, "h1#settings-section-title", "Ownership")

      assert lv
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#main h1")
             |> Enum.count() == 1

      assert page_title(lv) ==
               "Ownership · Organisation settings · #{client.name} · Qory Apiary"

      assert has_element?(lv, "#operator-name", ctx.operator.organisation.name)
      assert has_element?(lv, "#operator", "to support its harness, and change nothing")
      # A client's section says whose harness it runs, and no offers where it has none.
      assert has_element?(lv, ".q-settings-head-sub", "Whose harness this organisation runs.")
      refute has_element?(lv, ".q-settings-head-sub", "offers")
      # A client is offered to no one: it leaves its operator first.
      refute has_element?(lv, "#ownership")
      refute has_element?(lv, "#transfer-to-operator")
    end

    test "every one of its people sees its operator, a member too", ctx do
      member = client_member_fixture(ctx.client, :member)
      conn = log_in_user(build_conn(), member.user)
      operator = ctx.operator.organisation.name

      # A member takes no action there, yet the list leads to it: it names the operator.
      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))
      assert has_element?(lv, "#settings-tab-ownership")

      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      assert has_element?(lv, "#operator-name", operator)
      refute has_element?(lv, "#leave-operator")

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.client.organisation}/settings/people")
      assert has_element?(lv, "#operated-by", "Operated by #{operator}")
    end

    test "its owner leaves the operator, after typing its name", ctx do
      client = ctx.client.organisation
      operator = ctx.operator.organisation.name
      {:ok, lv, _html} = live(ctx.conn, ownership(client))

      lv |> element("#leave-operator") |> render_click()
      assert_patch(lv, ~p"/#{client}/settings/ownership/leave")

      # In place under its button, which folds it again, never a dialog.
      assert has_element?(
               lv,
               "#operator #leave-operator-form",
               "#{client.name} leaves #{operator} at once."
             )

      refute has_element?(lv, "#leave-operator-form", "lose access")

      refute has_element?(lv, "#leave-operator-form", "feature")
      refute has_element?(lv, "#main dialog, #main [role=dialog]")
      assert has_element?(lv, "#leave-operator[aria-expanded=true]")
      assert has_element?(lv, "#leave-operator-confirming", "Leave #{operator}?")
      assert has_element?(lv, "#leave-operator-confirm[disabled]", "Yes, leave")

      # Sent without the operator's name, it is refused by the server too.
      html = render_submit(lv, "leave_operator", %{"confirm" => %{"name" => "Not it"}})
      assert html =~ "is not the name"
      assert Repo.get!(Tenant, client.id).operator_id == ctx.operator.organisation.id

      lv |> form("#leave-operator-form", confirm: %{name: operator}) |> render_change()
      refute has_element?(lv, "#leave-operator-confirm[disabled]")

      {:ok, lv, html} =
        lv
        |> form("#leave-operator-form", confirm: %{name: operator})
        |> render_submit()
        |> follow_redirect(ctx.conn)

      assert html =~ "Acme has left #{ctx.operator.organisation.name}."
      # Back on its settings: an organisation of its own now, which its owner may offer to
      # an operator from the Ownership section.
      assert has_element?(lv, "#settings-tab-ownership")
      assert Repo.get!(Tenant, client.id).operator_id == nil
      assert Repo.get!(Membership, ctx.client.owner.membership.id).level == :owner
    end

    test "its admins and the operator's people are offered no leaving, and the path refuses them",
         ctx do
      client = ctx.client.organisation

      for user <- [ctx.admin.user, ctx.operator.user] do
        conn = log_in_user(build_conn(), user)
        {:ok, lv, _html} = live(conn, settings(client))
        assert has_element?(lv, "#settings-tab-ownership")

        {:ok, lv, _html} = live(conn, ownership(client))
        assert has_element?(lv, "#operator-name", ctx.operator.organisation.name)
        refute has_element?(lv, "#leave-operator")

        assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
                 live(conn, ~p"/#{client}/settings/ownership/leave")

        assert to == ownership(client)
        assert error =~ "Only an owner of this organisation takes it away"
      end

      assert Repo.get!(Tenant, client.id).operator_id == ctx.operator.organisation.id
    end

    test "the operator's people read the page, and are told they change nothing", ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))

      assert has_element?(
               lv,
               "#operator-reader",
               "as a person of #{ctx.operator.organisation.name}"
             )

      assert has_element?(lv, "#settings-tab-ownership")
      refute has_element?(lv, "#organisation-form button[type=submit]")
    end
  end

  describe "the arbiter's offer in a client whose owner is suspended" do
    setup ctx do
      ctx = client_with_admin(ctx)
      %{instance_scope: arbiter} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, ctx.client.owner.user.id)
      Map.put(ctx, :arbiter, arbiter)
    end

    test "the admin it is offered to reads it with its reason, accepts, and is an owner; the client stays its operator's",
         ctx do
      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))
      refute has_element?(lv, "#ownership-offer-notice")
      # A client's people read its operator there.
      assert has_element?(lv, "#settings-tab-ownership")

      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      # The offer reaches the admin's open page, and leads to the Ownership section.
      assert has_element?(
               lv,
               "#ownership-offer-notice",
               "Support offers you the ownership of Acme"
             )

      assert has_element?(lv, "#settings-tab-ownership")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#ownership-offer-notice a") |> render_click()

      assert to == ownership(ctx.client.organisation)

      # Another page of the organisation says it too.
      {:ok, members, _html} = live(conn, ~p"/#{ctx.client.organisation}/settings/people")
      assert has_element?(members, "#ownership-offer-notice")

      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      assert render(lv) =~ "Support offers you the ownership of Acme."
      assert has_element?(lv, "#ownership-offer-reason", "The owner is away.")
      # The page's own notice is the offer: the top one is not said twice.
      refute has_element?(lv, "#ownership-offer-notice")

      {:ok, lv, html} =
        lv |> element("#accept-ownership") |> render_click() |> follow_redirect(conn)

      assert html =~ "You are the owner of Acme now."
      refute has_element?(lv, "#ownership-offer-notice")
      assert has_element?(lv, "#owner-#{ctx.admin.membership.id}", ctx.admin.user.email)

      assert Repo.get!(Membership, ctx.admin.membership.id).level == :owner

      assert Repo.get!(Tenant, ctx.client.organisation.id).operator_id ==
               ctx.operator.organisation.id

      assert Transfers.pending(ctx.admin.scope) == nil
    end

    test "it is not withdrawn here, and another of its people sees no controls", ctx do
      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      other = member_fixture(ctx.admin.scope, :member)
      conn = log_in_user(build_conn(), other.user)

      {:ok, lv, _html} = live(conn, settings(ctx.client.organisation))
      assert has_element?(lv, "#settings-tab-ownership")
      refute has_element?(lv, "#ownership-offer-notice")

      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      refute has_element?(lv, "#ownership")
      refute has_element?(lv, "#ownership-offer")

      assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
               live(conn, ~p"/#{ctx.client.organisation}/settings/ownership/withdraw")

      assert error =~ "cannot be withdrawn here"
      assert %{arbitrated: true} = Transfers.pending(ctx.admin.scope)
    end

    test "the admin is not offered Accept when it would be refused, and is told why", ctx do
      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_organisation(ctx.arbiter, ctx.client.organisation.id)

      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))
      assert has_element?(lv, "#ownership-offer")
      refute has_element?(lv, "#accept-ownership")
      assert has_element?(lv, "#ownership-offer-waits", "once it is activated")
    end

    test "a withdrawn offer is not accepted, and the page says so", ctx do
      {:ok, _} =
        Transfers.arbitrate(
          ctx.arbiter,
          ctx.client.organisation.id,
          ctx.admin.membership.id,
          "The owner is away."
        )

      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, ownership(ctx.client.organisation))

      # The owner may act again: the offer lapses.
      {:ok, _} = ApiaryPro.Suspensions.activate_account(ctx.arbiter, ctx.client.owner.user.id)

      html = render_click(lv, "accept_transfer", %{})
      assert html =~ "No ownership is offered to you here any more"
      assert Repo.get!(Membership, ctx.admin.membership.id).level == :admin
    end
  end

  describe "the arbiter's offer in an organisation with no operator" do
    test "the recipient made a member still reads the offer, and Accept shows why the acceptance fails",
         %{conn: conn} do
      signed_up = sign_up_fixture(%{organisation_name: "Initech"})
      admin = member_fixture(signed_up.scope, :admin)
      %{instance_scope: arbiter} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, signed_up.user.id)

      {:ok, _} =
        Transfers.arbitrate(
          arbiter,
          signed_up.organisation.id,
          admin.membership.id,
          "The owner is away."
        )

      Repo.update!(Ecto.Changeset.change(admin.membership, level: :member))

      {:ok, lv, _html} = live(log_in_user(conn, admin.user), ownership(signed_up.organisation))
      assert has_element?(lv, "#ownership-offer")
      assert has_element?(lv, "#accept-ownership")

      html = render_click(lv, "accept_transfer", %{})
      assert html =~ "Only the admin of Initech it is offered to accepts its ownership."
      assert Repo.get!(Membership, admin.membership.id).level == :member
    end

    test "the admin reads the offer, its reason and Accept, in a section about offers only",
         %{conn: conn} do
      signed_up = sign_up_fixture(%{organisation_name: "Initech"})
      admin = member_fixture(signed_up.scope, :admin)
      %{instance_scope: arbiter} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, signed_up.user.id)

      {:ok, _} =
        Transfers.arbitrate(
          arbiter,
          signed_up.organisation.id,
          admin.membership.id,
          "The owner is away."
        )

      conn = log_in_user(conn, admin.user)
      {:ok, lv, _html} = live(conn, ownership(signed_up.organisation))

      assert has_element?(
               lv,
               ".q-settings-head-sub",
               "Offers of the ownership of this organisation."
             )

      refute has_element?(lv, ".q-settings-head-sub", "harness")
      refute has_element?(lv, "#operator")

      # The offer, its reason, then Accept, one under the other in the notice.
      assert has_element?(
               lv,
               "[role=note] #ownership-offer p",
               "offers you the ownership of Initech"
             )

      assert has_element?(lv, "#ownership-offer #ownership-offer-reason", "The owner is away.")
      assert has_element?(lv, "#ownership-offer button#accept-ownership", "Accept ownership")
    end
  end

  describe "the offer's page and the confirmations, by the transfers flag" do
    setup :client_with_admin

    test "with the flag off, each is not found", ctx do
      ApiaryPro.Flags.put_transfers(false)

      for rest <- ["transfer", "withdraw", "leave"] do
        path = "#{ownership(ctx.client.organisation)}/#{rest}"
        assert_raise ApiaryWeb.NotFound, fn -> live(ctx.conn, path) end
      end
    end

    test "with the flag on, the leave page shows the organisation has no operator", %{
      conn: conn
    } do
      independent = sign_up_fixture(%{organisation_name: "Globex"})
      org = independent.organisation

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
               live(log_in_user(conn, independent.user), ~p"/#{org}/settings/ownership/leave")

      assert to == ownership(org)
      assert error == "This organisation has no operator any more."
    end
  end

  describe "an organisation offered to an operator" do
    test "its owner offers it, and an owner of the operator accepts it as a client", %{
      conn: conn
    } do
      operator = operator_fixture()
      independent = sign_up_fixture(%{organisation_name: "Globex"})
      org = independent.organisation
      conn = log_in_user(conn, independent.user)

      {:ok, lv, _html} = live(conn, settings(org))
      assert has_element?(lv, "#settings-tab-ownership")

      {:ok, lv, _html} = live(conn, ownership(org))
      assert has_element?(lv, "#transfer-operator", "its people keep their levels, you included")
      # No operator: the section is about offers only.
      assert has_element?(
               lv,
               ".q-settings-head-sub",
               "Offers of the ownership of this organisation."
             )

      lv |> element("#transfer-to-operator") |> render_click()
      assert_patch(lv, ~p"/#{org}/settings/ownership/transfer")
      # A page of the section, never a dialog: its list beside it, Ownership current as
      # the page's parent, the breadcrumb ending Ownership / Transfer to an operator and
      # leading back, the operator's address focused, and Cancel back.
      refute has_element?(lv, "#main dialog, #main [role=dialog]")
      refute has_element?(lv, "#transfer-operator")
      assert has_element?(lv, "#settings-tab-ownership[aria-current=true]")

      assert Trail.crumbs(lv) == [
               "Organisation settings",
               "Ownership",
               "Transfer to an operator"
             ]

      assert has_element?(
               lv,
               "#breadcrumb a#breadcrumb-section[href='#{ownership(org)}']",
               "Ownership"
             )

      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Transfer to an operator")

      assert page_title(lv) =~ ~r/^Transfer to an operator · Organisation settings · Globex\b/

      assert has_element?(lv, "#transfer-features-warning")
      assert has_element?(lv, "#transfer-form input#transfer_operator_slug[phx-mounted]")
      assert has_element?(lv, "label[for=transfer_operator_slug]", "The operator's address")
      assert has_element?(lv, "#transfer-save a#transfer-save-cancel[href='#{ownership(org)}']")
      assert has_element?(lv, "#transfer h1#transfer-title", "Transfer Globex to an operator")
      refute has_element?(lv, "#transfer-back")

      # An empty slug, and one no operator has, are answered under the field.
      for slug <- ["", "  "] do
        lv |> form("#transfer-form", transfer: %{operator_slug: slug}) |> render_submit()

        assert has_element?(lv, "#transfer_operator_slug-error", "Enter the operator's address.")
        assert has_element?(lv, ~s|#transfer_operator_slug[aria-invalid="true"]|)
      end

      refute Repo.exists?(ApiaryPro.Transfers.Transfer)

      lv
      |> form("#transfer-form", transfer: %{operator_slug: "no-such-operator"})
      |> render_submit()

      assert has_element?(lv, "#transfer_operator_slug-error", "No operator has that address.")
      assert Transfers.pending(independent.scope) == nil

      html =
        lv
        |> form("#transfer-form", transfer: %{operator_slug: operator.organisation.slug})
        |> render_submit()

      assert_patch(lv, ownership(org))
      assert html =~ "is offered to #{operator.organisation.name}."
      assert has_element?(lv, "#ownership-pending", operator.organisation.name)
      assert has_element?(lv, "#withdraw-transfer")

      # The operator's member lists the offer and accepts nothing.
      member = member_fixture(operator.scope, :member)
      member_conn = log_in_user(build_conn(), member.user)
      {:ok, clients, _html} = live(member_conn, ~p"/#{operator.organisation}/clients")
      render_async(clients)
      assert has_element?(clients, "#offer-#{org.id}", org.name)
      refute has_element?(clients, "#offer-#{org.id}-accept")

      # Its owner accepts.
      owner_conn = log_in_user(build_conn(), operator.user)
      {:ok, clients, _html} = live(owner_conn, ~p"/#{operator.organisation}/clients")
      render_async(clients)
      assert has_element?(clients, "#offers h2", "Offered to #{operator.organisation.name}")

      # Its Accept asks in place first, on the offer's row.
      clients |> element("#offer-#{org.id}-accept") |> render_click()
      assert_patch(clients, ~p"/#{operator.organisation}/clients/offers/#{org.id}/accept")
      html = clients |> element("#offer-#{org.id}-confirm-button") |> render_click()
      assert html =~ "is a client of #{operator.organisation.name} now"
      render_async(clients)
      refute has_element?(clients, "#offers")
      assert has_element?(clients, "#client-#{org.id}-link")

      assert Repo.get!(Membership, independent.membership.id).level == :owner
      assert Repo.get!(Tenant, org.id).operator_id == operator.organisation.id

      # The owner's open page follows: a client now, with nothing to offer, and its
      # operator named, which it may leave.
      refute has_element?(lv, "#ownership")
      assert has_element?(lv, "#operator-name", operator.organisation.name)
      assert has_element?(lv, "#leave-operator")
    end

    test "its owner withdraws the offer, confirmed in place under the button", %{conn: conn} do
      operator = operator_fixture()
      independent = sign_up_fixture()
      org = independent.organisation
      {:ok, _} = Transfers.offer_to_operator(independent.scope, operator.organisation.slug)

      {:ok, lv, _html} = live(log_in_user(conn, independent.user), ownership(org))
      assert has_element?(lv, "#withdraw-transfer[aria-expanded=false]")

      lv |> element("#withdraw-transfer") |> render_click()
      assert_patch(lv, ~p"/#{org}/settings/ownership/withdraw")
      refute has_element?(lv, "#main dialog, #main [role=dialog]")
      assert has_element?(lv, "#withdraw-transfer[aria-expanded=true]")

      assert has_element?(
               lv,
               "#ownership #withdraw-transfer-confirming",
               "can no longer accept"
             )

      # Cancel folds it, and withdraws nothing.
      lv |> element("#withdraw-transfer-confirming-cancel") |> render_click()
      assert_patch(lv, ownership(org))
      refute has_element?(lv, "#withdraw-transfer-confirming")
      assert Transfers.pending(independent.scope)

      lv |> element("#withdraw-transfer") |> render_click()
      html = lv |> element("#withdraw-transfer-confirm", "Yes, withdraw") |> render_click()
      assert html =~ "The offer is withdrawn."
      assert_patch(lv, ownership(org))
      assert Transfers.pending(independent.scope) == nil
    end

    test "an offer withdrawn meanwhile is not accepted", %{conn: conn} do
      operator = operator_fixture()
      independent = sign_up_fixture()
      org = independent.organisation
      {:ok, _} = Transfers.offer_to_operator(independent.scope, operator.organisation.slug)

      {:ok, clients, _html} =
        live(log_in_user(conn, operator.user), ~p"/#{operator.organisation}/clients")

      render_async(clients)
      assert has_element?(clients, "#offer-#{org.id}-accept")

      {:ok, _} = Transfers.withdraw(independent.scope)

      html = render_click(clients, "accept_client", %{"id" => org.id})
      assert html =~ "That offer is no longer pending"
      render_async(clients)
      refute has_element?(clients, "#offers")
      assert Repo.get!(Tenant, org.id).operator_id == nil
    end

    test "its admins and members, and an operator, see no ownership controls", %{conn: conn} do
      independent = sign_up_fixture()
      admin = member_fixture(independent.scope, :admin)
      member = member_fixture(independent.scope, :member)

      for person <- [admin, member] do
        conn = log_in_user(build_conn(), person.user)
        {:ok, lv, _html} = live(conn, settings(independent.organisation))
        refute has_element?(lv, "#settings-tab-ownership")

        # Not in their list, its path sends them to General and says why.
        assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
                 live(conn, ownership(independent.organisation))

        assert to == settings(independent.organisation)
        assert error =~ "There is nothing about the ownership of"
      end

      operator = operator_fixture()
      conn = log_in_user(conn, operator.user)
      {:ok, lv, _html} = live(conn, settings(operator.organisation))
      refute has_element?(lv, "#settings-tab-ownership")

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ownership(operator.organisation))
      assert to == settings(operator.organisation)
    end

    @tag with_features: [:observability, :security]
    test "without managed_organisations its owner offers it to no operator", %{conn: conn} do
      independent = sign_up_fixture()

      conn = log_in_user(conn, independent.user)
      {:ok, lv, _html} = live(conn, settings(independent.organisation))
      refute has_element?(lv, "#settings-tab-ownership")

      # Nothing is there for its owner to do: both paths send them to General.
      for path <- [
            ownership(independent.organisation),
            ~p"/#{independent.organisation}/settings/ownership/transfer"
          ] do
        assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
                 live(conn, path)

        assert to == settings(independent.organisation)
        assert error =~ "There is nothing about the ownership of"
      end
    end
  end
end
