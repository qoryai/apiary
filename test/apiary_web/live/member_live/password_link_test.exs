defmodule ApiaryWeb.MemberLive.PasswordLinkTest do
  @moduledoc """
  Make a password link, on the People page of the instance's organisation
  (`ApiaryWeb.MemberLive.Index`): offered to an instance admin, for each other member,
  while no mail is set; the link is shown once, above the list, until Done, and never in a
  path or a flash. Nobody else, and nobody once mail is set, makes one.
  """
  # Not async: an instance admin is an owner of the suite's instance organisation, which
  # every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Accounts, Organisations, Repo}
  alias Apiary.Accounts.{Scope, UserToken}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Organisation

  defp instance, do: Repo.get!(Organisation, Apiary.Edition.instance_organisation_id())

  # An instance admin and a member of the instance's organisation, made with the suite's
  # mail; each test then sets the mail it needs.
  setup %{conn: conn} do
    %{user: admin} = sign_up_fixture()
    {:ok, _} = Organisations.grant_instance_admin(admin)
    [workspace | _] = Organisations.list_workspaces(Scope.for_instance(instance()))
    admin_scope = workspace_scope(admin, workspace)
    %{user: member, membership: membership} = member_fixture(admin_scope)

    %{
      conn: log_in_user(conn, admin),
      admin: admin,
      admin_scope: admin_scope,
      member: member,
      membership: membership
    }
  end

  defp people, do: ~p"/#{instance()}/settings/people"

  defp tokens(user),
    do: Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "password")

  test "without mail, an instance admin makes a member's link, shown once until Done", ctx do
    Apiary.Mail.put_test_source(:none)
    {:ok, lv, _html} = live(ctx.conn, people())

    item = "#member-#{ctx.membership.id}-password-link"
    assert has_element?(lv, item, "Make a password link")
    # Not on their own row: Account settings change their own.
    refute has_element?(lv, "#member-#{ctx.admin_scope.membership.id}-password-link")
    refute has_element?(lv, "#password-link")

    html = lv |> element(item) |> render_click()

    assert has_element?(
             lv,
             "#password-link-sentence",
             "Copy this password link and send it to #{ctx.member.email} yourself."
           )

    assert has_element?(lv, "#password-link-works", "(24 hours). It is shown only now.")
    assert [url] = Regex.run(~r{http://[^<"\s]+/users/password/[A-Za-z0-9_-]+}, html)
    assert has_element?(lv, "#password-link-copy[data-copy='#{url}']")
    token = url |> String.split("/") |> List.last()

    assert %{id: id} = Accounts.get_user_by_password_link(token)
    assert id == ctx.member.id
    assert [_one] = tokens(ctx.member)

    # In the panel and nowhere else on the page: no flash, no title. Nor in the trail.
    count = fn html -> length(String.split(html, token)) - 1 end
    assert count.(render(lv)) == count.(lv |> element("#password-link") |> render())
    refute page_title(lv) =~ token
    assert [entry] = Repo.all(from e in Entry, where: e.action == "account.password_link")
    assert {entry.actor_kind, entry.actor_id} == {:person, ctx.admin.id}
    assert {entry.subject_kind, entry.subject_id} == {"membership", ctx.membership.id}
    refute inspect(entry) =~ token

    lv |> element("#password-link-done") |> render_click()
    refute has_element?(lv, "#password-link")
    refute render(lv) =~ token
  end

  test "a second link ends the first", ctx do
    Apiary.Mail.put_test_source(:none)
    {:ok, lv, _html} = live(ctx.conn, people())
    item = "#member-#{ctx.membership.id}-password-link"

    first = lv |> element(item) |> render_click()
    [_, first] = Regex.run(~r{/users/password/([A-Za-z0-9_-]+)}, first)
    second = lv |> element(item) |> render_click()
    [_, second] = Regex.run(~r{/users/password/([A-Za-z0-9_-]+)}, second)

    refute first == second
    refute Accounts.get_user_by_password_link(first)
    assert Accounts.get_user_by_password_link(second)
  end

  test "with mail, the page offers none, and a link asked for all the same is refused", ctx do
    {:ok, lv, _html} = live(ctx.conn, people())
    refute has_element?(lv, "#member-#{ctx.membership.id}-password-link")

    render_click(lv, "password_link", %{"membership_id" => ctx.membership.id})

    assert render(lv) =~
             "Qory Apiary sends email now: they get a log-in link from the log-in page instead."

    refute has_element?(lv, "#password-link")
    assert tokens(ctx.member) == []
  end

  test "an owner of another organisation is offered none, and is refused one", %{conn: conn} do
    %{user: owner, scope: scope} = sign_up_fixture()
    %{membership: membership, user: member} = member_fixture(scope)
    Apiary.Mail.put_test_source(:none)

    {:ok, lv, _html} = live(log_in_user(conn, owner), ~p"/#{scope.organisation}/settings/people")
    refute has_element?(lv, "#member-#{membership.id}-password-link")

    render_click(lv, "password_link", %{"membership_id" => membership.id})

    assert render(lv) =~
             "Only an admin of this Qory Apiary makes password links, while it sends no email."

    refute has_element?(lv, "#password-link")
    assert tokens(member) == []
  end
end
