defmodule ApiaryWeb.MemberLive.CopiedLinkTest do
  @moduledoc """
  The People page without mail: an invitation is a link to copy, shown once on the invite
  page, and a pending invitation's row makes a new one. With mail, the page emails, as
  before.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Mail, Organisations}
  alias Apiary.Organisations.Invitation

  # The link the page shows, and its token.
  defp shown_link(lv, id) do
    url = lv |> element("##{id}-url") |> render() |> text()
    [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)$}, url)
    {url, token}
  end

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  describe "without mail" do
    setup :register_and_log_in_user

    setup do
      Mail.put_test_source(:none)
      :ok
    end

    test "the invite page makes a link, shows it once, and Done goes back to People", %{
      conn: conn,
      scope: scope
    } do
      people = ~p"/#{scope.organisation}/settings/people"
      invite = ~p"/#{scope.organisation}/settings/people/invite"
      {:ok, lv, html} = live(conn, invite)

      assert html =~
               "You get a link to send them yourself. It works for seven days and brings them into #{scope.workspace.name} as a member; an owner can change their level afterwards."

      refute html =~ "We email them"

      assert has_element?(
               lv,
               "#invitation-save button[type=submit][data-busy]",
               "Create invitation link"
             )

      assert render(lv) =~ "Creating…"

      log =
        capture_log(fn ->
          lv
          |> form("#invitation-form", invitation: %{email: "dana@example.com"})
          |> render_submit()
        end)

      # Still the invite page, the form gone and the link in its place, with no flash.
      refute_patched(lv)
      refute has_element?(lv, "#invitation-form")
      refute has_element?(lv, "#flash-info")
      refute render(lv) =~ "Invitation sent"

      assert has_element?(
               lv,
               "#invitation-link",
               "Copy this link and send it to dana@example.com yourself."
             )

      {url, token} = shown_link(lv, "invitation-link")
      assert has_element?(lv, "#invitation-link-copy[data-copy='#{url}']")
      assert has_element?(lv, ".tooltip[data-tip-done='Copied'] #invitation-link-copy")

      assert [invitation] = Organisations.list_invitations(scope)
      assert %Invitation{} = Organisations.get_invitation_by_token(token)
      assert invitation.email == "dana@example.com"

      works = lv |> element("#invitation-link-works") |> render() |> text()
      assert works =~ ~r/^Works once, until .+ \(7 days\)\. It is shown only now\.$/
      assert works =~ ApiaryWeb.Format.time(invitation.expires_at)

      # Never in a path, a flash, the title or a log line.
      refute page_title(lv) =~ token
      refute log =~ token

      lv |> element("#invitation-link-done") |> render_click()
      assert_patch(lv, people)
      refute render(lv) =~ token
      assert has_element?(lv, "#invitation-#{invitation.id}", "dana@example.com")

      # Opened again, the page has the form, and no link.
      {:ok, lv, html} = live(conn, invite)
      refute html =~ token
      assert has_element?(lv, "#invitation-form")
    end

    test "an unconfirmed owner makes a link: nothing is mailed for them", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      Apiary.Repo.update_all(
        from(u in Apiary.Accounts.User, where: u.id == ^user.id),
        set: [confirmed_at: nil]
      )

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people/invite")

      lv
      |> form("#invitation-form", invitation: %{email: "dana@example.com"})
      |> render_submit()

      assert has_element?(lv, "#invitation-link")
      refute render(lv) =~ "Confirm your email address"
    end

    test "a pending invitation's row makes a new link in place; the old one stops at once", %{
      conn: conn,
      scope: scope
    } do
      %{invitation: invitation, token: old} =
        invitation_fixture(scope, %{"email" => "dana@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      row = "#invitation-#{invitation.id}"

      assert has_element?(
               lv,
               "#{row}-renew[aria-label='Make a new link for dana@example.com']",
               "Make a new link"
             )

      lv |> element("#{row}-renew") |> render_click()

      # No confirming step: the row is the link, with Done.
      refute_patched(lv)

      assert has_element?(
               lv,
               "#{row}-link",
               "Copy this link and send it to dana@example.com yourself."
             )

      {_url, new} = shown_link(lv, "invitation-#{invitation.id}-link")
      assert new != old
      assert Organisations.get_invitation_by_token(old) == nil
      assert %Invitation{id: id} = Organisations.get_invitation_by_token(new)
      assert id == invitation.id
      refute has_element?(lv, "#flash-info")

      lv |> element("#{row}-link-done") |> render_click()
      refute has_element?(lv, "#{row}-link")
      refute render(lv) =~ new
      assert has_element?(lv, row, "dana@example.com")
    end

    test "a new link refused for the day says so, and keeps the old one", %{
      conn: conn,
      scope: scope
    } do
      %{invitation: invitation, token: old} =
        invitation_fixture(scope, %{"email" => "dana@example.com"})

      # The day's invitations spent, by entries of the allowance.
      Apiary.Repo.query!(
        """
        INSERT INTO audit_entries (id, organisation_id, actor_kind, action, subject_kind,
                                   subject_id, details, inserted_at)
        SELECT gen_random_uuid(), $1, 'instance', 'member.invite', 'invitation',
               gen_random_uuid(), jsonb_build_object('allowance_id', $2::text),
               timezone('UTC', now())
        FROM generate_series(1, $3)
        """,
        [
          Ecto.UUID.dump!(scope.organisation.id),
          scope.organisation.id,
          Apiary.Instance.invitations_per_day()
        ]
      )

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      lv |> element("#invitation-#{invitation.id}-renew") |> render_click()

      assert has_element?(
               lv,
               "#flash-error",
               "No new link for dana@example.com: this organisation has made #{Apiary.Instance.invitations_per_day()} invitations in the last 24 hours, as many as it may. Try again later."
             )

      refute has_element?(lv, "#invitation-#{invitation.id}-link")
      assert Organisations.get_invitation_by_token(old)
    end

    test "a member sees no row action", %{conn: conn, scope: scope} do
      invitation_fixture(scope)
      # Their account confirmed by email, then mail off again.
      Mail.put_test_source(:env)
      %{user: member} = member_fixture(scope, :member)
      Mail.put_test_source(:none)
      conn = log_in_user(conn, member)
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      refute has_element?(lv, "[id$='-renew']")
    end
  end

  describe "with mail" do
    setup :register_and_log_in_user

    test "the invite page emails, and the rows make no new link", %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/settings/people/invite")

      assert html =~ "We email them a link that works for seven days"
      assert has_element?(lv, "#invitation-save button[type=submit]", "Send invitation")
      refute html =~ "Create invitation link"

      lv
      |> form("#invitation-form", invitation: %{email: "dana@example.com"})
      |> render_submit()

      assert_patch(lv, ~p"/#{scope.organisation}/settings/people")
      assert render(lv) =~ "Invitation sent to dana@example.com"
      refute has_element?(lv, "#invitation-link")
      assert [invitation] = Organisations.list_invitations(scope)
      refute has_element?(lv, "#invitation-#{invitation.id}-renew")
    end
  end
end
