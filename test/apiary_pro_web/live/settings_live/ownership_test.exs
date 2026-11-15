defmodule ApiaryProWeb.SettingsLive.OwnershipTest do
  @moduledoc """
  The Ownership section of an organisation's settings: the arbiter's offer to an admin,
  told on every page and accepted here.
  """
  # Not async: the features are the node's, and a suspension is made by an instance admin,
  # an owner of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # The lapse of the arbiter's offer (`organisation.withdraw_transfer`) is found here, for
  # this process and those it starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures, only: [instance_admin_fixture: 0]

  alias Apiary.{Features, Repo}
  alias Apiary.Organisations.Membership
  alias ApiaryPro.Transfers
  alias ApiaryProWeb.Trail

  @moduletag with_features: Features.all()

  # Acme, with its owner and an admin, and an instance admin, the arbiter, who suspended
  # the owner's account.
  defp suspended_owner(_ctx) do
    owner = sign_up_fixture(%{organisation_name: "Acme"})
    admin = member_fixture(owner.scope, :admin)
    %{instance_scope: arbiter} = instance_admin_fixture()
    {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, owner.user.id)

    %{owner: owner, organisation: owner.organisation, admin: admin, arbiter: arbiter}
  end

  defp arbitrate(ctx) do
    {:ok, _} =
      Transfers.arbitrate(
        ctx.arbiter,
        ctx.organisation.id,
        ctx.admin.membership.id,
        "The owner is away."
      )
  end

  defp settings(organisation), do: ~p"/#{organisation}/settings"
  defp ownership(organisation), do: ~p"/#{organisation}/settings/ownership"

  describe "the arbiter's offer in an organisation whose owner is suspended" do
    setup :suspended_owner

    test "the admin it is offered to has the section in the organisation's settings", ctx do
      arbitrate(ctx)
      conn = log_in_user(build_conn(), ctx.admin.user)
      organisation = ctx.organisation
      {:ok, lv, _html} = live(conn, settings(organisation))

      # The settings' list beside the section leads to Ownership.
      assert has_element?(lv, "#settings-tab-organisation[aria-current='page']")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#settings-tab-ownership") |> render_click()

      assert to == ownership(organisation)

      {:ok, lv, _html} = live(conn, ownership(organisation))

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
               "Ownership · Organisation settings · #{organisation.name} · Qory Apiary"
    end

    test "the admin it is offered to reads it with its reason, accepts, and is an owner", ctx do
      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, settings(ctx.organisation))
      refute has_element?(lv, "#ownership-offer-notice")
      # With no offer, the admin has no Ownership section.
      refute has_element?(lv, "#settings-tab-ownership")

      arbitrate(ctx)

      # The offer reaches the admin's open page, and leads to the Ownership section.
      assert has_element?(
               lv,
               "#ownership-offer-notice",
               "Support offers you the ownership of Acme"
             )

      assert has_element?(lv, "#settings-tab-ownership")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#ownership-offer-notice a") |> render_click()

      assert to == ownership(ctx.organisation)

      # Another page of the organisation says it too.
      {:ok, members, _html} = live(conn, ~p"/#{ctx.organisation}/settings/people")
      assert has_element?(members, "#ownership-offer-notice")

      {:ok, lv, _html} = live(conn, ownership(ctx.organisation))
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
      assert Transfers.pending(ctx.admin.scope) == nil
    end

    test "it is not withdrawn here, and another of its people has no section", ctx do
      arbitrate(ctx)
      other = member_fixture(ctx.admin.scope, :member)
      conn = log_in_user(build_conn(), other.user)

      {:ok, lv, _html} = live(conn, settings(ctx.organisation))
      refute has_element?(lv, "#settings-tab-ownership")
      refute has_element?(lv, "#ownership-offer-notice")

      general = settings(ctx.organisation)

      assert {:error, {:live_redirect, %{to: ^general, flash: flash}}} =
               live(conn, ownership(ctx.organisation))

      assert flash["error"] == "There is nothing about the ownership of Acme for you to do here."

      assert %{arbitrated: true} = Transfers.pending(ctx.admin.scope)
    end

    test "the admin is not offered Accept when it would be refused, and is told why", ctx do
      arbitrate(ctx)
      {:ok, _} = ApiaryPro.Suspensions.suspend_organisation(ctx.arbiter, ctx.organisation.id)

      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, ownership(ctx.organisation))
      assert has_element?(lv, "#ownership-offer")
      refute has_element?(lv, "#accept-ownership")
      assert has_element?(lv, "#ownership-offer-waits", "once it is activated")
    end

    test "a withdrawn offer is not accepted, and the page says so", ctx do
      arbitrate(ctx)
      conn = log_in_user(build_conn(), ctx.admin.user)
      {:ok, lv, _html} = live(conn, ownership(ctx.organisation))

      # The owner may act again: the offer lapses.
      {:ok, _} = ApiaryPro.Suspensions.activate_account(ctx.arbiter, ctx.owner.user.id)

      html = render_click(lv, "accept_transfer", %{})
      assert html =~ "No ownership is offered to you here any more"
      assert Repo.get!(Membership, ctx.admin.membership.id).level == :admin
    end
  end

  describe "the arbiter's offer, read on the Ownership page" do
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
end
