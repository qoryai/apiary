defmodule ApiaryProWeb.InstanceLive.PasswordLinkTest do
  @moduledoc """
  Make a password link, on Instance settings › Accounts (`ApiaryProWeb.InstanceLive.Accounts`):
  offered to an instance admin, for each other account that is not suspended, while no mail
  is set, any organisation's, a client's owner's included; the link is the core's
  (`Apiary.Accounts.build_password_link/3`), shown once above the list until Done, and
  never in a path, a flash, the title or the log. Nobody else, nobody whose sign-in is not
  recent, and nobody once mail is set, makes one.
  """
  # Not async: instance admins are owners of the suite's one instance organisation, the
  # features are the node's, and the level of the log lines is lowered for a test.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Accounts, Features, Repo}
  alias Apiary.Accounts.{User, UserToken}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Membership
  alias ApiaryPro.Suspensions

  @moduletag with_features: Features.all()
  # What a test logs besides what it captures is shown only if it fails.
  @moduletag :capture_log

  @password "a long pass phrase"

  setup %{conn: conn} do
    admin = instance_admin_fixture()
    %{conn: log_in_user(conn, admin.user), admin: admin}
  end

  defp tokens(user),
    do: Repo.all(from t in UserToken, where: t.user_id == ^user.id and t.context == "password")

  defp entries,
    do: Repo.all(from e in Entry, where: e.action == "account.password_link")

  defp accounts(conn) do
    {:ok, lv, _html} = live(conn, ~p"/instance/accounts")
    render_async(lv)
    lv
  end

  defp item(user), do: "#account-#{user.id}-password-link"

  # The link the panel shows, and its token.
  defp shown_link(html) do
    assert [url] = Regex.run(~r{http://[^<"\s]+/users/password/[A-Za-z0-9_-]+}, html)
    {url, url |> String.split("/") |> List.last()}
  end

  # The password set with the link, once: a second time it has expired.
  defp set_password_once(token, user) do
    {:ok, lv, html} = live(build_conn(), ~p"/users/password/#{token}")
    assert html =~ user.email

    lv
    |> form("#password_form", %{
      "user" => %{"password" => @password, "password_confirmation" => @password}
    })
    |> render_submit()

    assert_redirect(lv, "/users/log-in")
    assert %User{} = Accounts.get_user_by_email_and_password(user.email, @password)

    {:ok, _lv, html} = live(build_conn(), ~p"/users/password/#{token}")
    assert html =~ "That password link has expired"
  end

  test "without mail, an instance admin makes a client's owner's link, shown once until Done",
       ctx do
    %{scope: operator_scope} = operator_fixture()
    %{owner: %{user: owner}} = client_fixture(operator_scope)
    Apiary.Mail.put_test_source(:none)

    previous = Logger.level()
    Logger.configure(level: :debug)
    Logger.put_module_level(Phoenix.LiveView.Logger, :debug)

    on_exit(fn ->
      Logger.delete_module_level(Phoenix.LiveView.Logger)
      Logger.configure(level: previous)
    end)

    lv = accounts(ctx.conn)
    assert has_element?(lv, item(owner), "Make a password link")

    assert has_element?(
             lv,
             ~s(#{item(owner)}[aria-label="Make a password link for #{owner.email}"])
           )

    # Not on their own row: Account settings change their own.
    refute has_element?(lv, item(ctx.admin.user))
    refute has_element?(lv, "#password-link")

    {html, log} =
      with_log([level: :debug], fn -> lv |> element(item(owner)) |> render_click() end)

    assert log =~ ~s(HANDLE EVENT "password_link")

    assert has_element?(
             lv,
             "#password-link-sentence",
             "Copy this password link and send it to #{owner.email} yourself."
           )

    assert has_element?(lv, "#password-link-works", "(24 hours). It is shown only now.")
    {url, token} = shown_link(html)
    assert has_element?(lv, "#password-link-copy[data-copy='#{url}']")
    assert %{id: id} = Accounts.get_user_by_password_link(token)
    assert id == owner.id
    assert [_one] = tokens(owner)

    # In the panel and nowhere else on the page: no flash, no title, no path, no log line.
    count = fn html -> length(String.split(html, token)) - 1 end
    assert count.(render(lv)) == count.(lv |> element("#password-link") |> render())
    refute has_element?(lv, "#flash-info")
    refute has_element?(lv, "#flash-error")
    refute page_title(lv) =~ token
    refute_patched(lv)
    refute_redirected(lv)
    refute log =~ token

    # The instance organisation's trail: the client's owner holds no membership there, so
    # the entry is about the organisation and names the account by its id, not the link.
    here = instance_organisation()
    assert [entry] = entries()
    assert {entry.actor_kind, entry.actor_id} == {:person, ctx.admin.user.id}
    assert {entry.subject_kind, entry.subject_id} == {"organisation", here.id}
    assert entry.details["user_id"] == owner.id
    refute inspect(entry) =~ token

    lv |> element("#password-link-done") |> render_click()
    refute has_element?(lv, "#password-link")
    refute render(lv) =~ token

    set_password_once(token, owner)
  end

  test "without mail, an instance admin makes a link for a member of an ordinary organisation",
       ctx do
    %{scope: scope} = sign_up_fixture()
    %{user: member} = member_fixture(scope)
    Apiary.Mail.put_test_source(:none)

    lv = accounts(ctx.conn)
    {_url, token} = lv |> element(item(member)) |> render_click() |> shown_link()

    assert has_element?(
             lv,
             "#password-link-sentence",
             "Copy this password link and send it to #{member.email} yourself."
           )

    assert [entry] = entries()
    assert entry.details["user_id"] == member.id

    # Leaving the list for a view of it shows it no more.
    lv |> element("#accounts-view-suspended") |> render_click()
    refute has_element?(lv, "#password-link")

    set_password_once(token, member)
  end

  test "with mail, the page offers none, and a link asked for all the same is refused", ctx do
    %{user: user} = sign_up_fixture()

    lv = accounts(ctx.conn)
    refute has_element?(lv, item(user))

    render_click(lv, "password_link", %{"id" => user.id})

    assert render(lv) =~
             "Qory Apiary sends email now: they get a sign-in link from the sign-in page instead."

    refute has_element?(lv, "#password-link")
    assert tokens(user) == []
    assert entries() == []
  end

  test "a link asked for the admin's own account, the page offering none, is refused", ctx do
    Apiary.Mail.put_test_source(:none)
    lv = accounts(ctx.conn)

    render_click(lv, "password_link", %{"id" => ctx.admin.user.id})

    assert render(lv) =~ "Change your password in Account settings."
    refute has_element?(lv, "#password-link")
    assert tokens(ctx.admin.user) == []
    assert entries() == []
  end

  test "a suspended account is offered none, and is refused one", ctx do
    %{user: user} = sign_up_fixture()
    {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, user.id)
    Apiary.Mail.put_test_source(:none)

    lv = accounts(ctx.conn)
    assert has_element?(lv, "#account-#{user.id}")
    refute has_element?(lv, item(user))

    render_click(lv, "password_link", %{"id" => user.id})

    assert render(lv) =~ "That account cannot sign in at the moment, so it gets no password link."
    refute has_element?(lv, "#password-link")
    assert tokens(user) == []
    assert entries() == []
  end

  test "after a sign-in that is not recent, the admin is sent to log in again first", ctx do
    %{user: user} = sign_up_fixture()
    Apiary.Mail.put_test_source(:none)
    stale = DateTime.add(DateTime.utc_now(:second), -21, :minute)
    stale_conn = log_in_user(build_conn(), ctx.admin.user, token_authenticated_at: stale)

    # The page opens; the link is offered, and asking for it leads to the log-in page.
    lv = accounts(stale_conn)
    assert has_element?(lv, item(user))

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             lv |> element(item(user)) |> render_click()

    assert assert_redirect(lv, ~p"/users/log-in") ==
             %{"error" => "You must re-authenticate to access this page."}

    assert tokens(user) == []
    assert entries() == []
  end

  test "an instance admin no longer one by the time they ask is refused one", ctx do
    %{user: user} = sign_up_fixture()
    Apiary.Mail.put_test_source(:none)

    lv = accounts(ctx.conn)
    assert has_element?(lv, item(user))

    # The level changes in the database with no broadcast: the click reaches the page
    # before the membership change, which would move the page to `/`.
    membership_id = ctx.admin.instance_scope.membership.id

    {1, _} =
      Repo.update_all(from(m in Membership, where: m.id == ^membership_id), set: [level: :member])

    render_click(lv, "password_link", %{"id" => user.id})

    assert render(lv) =~
             "Only an admin of this Qory Apiary makes password links, while it sends no email."

    refute has_element?(lv, "#password-link")
    assert tokens(user) == []
    assert entries() == []
  end

  test "the page, and so its event, is not there for anyone but the instance admins", ctx do
    %{user: admin} = member_fixture(ctx.admin.instance_scope, :admin)
    %{owner: %{user: client_owner}} = client_fixture(operator_fixture().scope)
    Apiary.Mail.put_test_source(:none)

    for person <- [admin, client_owner] do
      assert_raise ApiaryWeb.NotFound, fn ->
        live(log_in_user(build_conn(), person), ~p"/instance/accounts")
      end
    end
  end
end
