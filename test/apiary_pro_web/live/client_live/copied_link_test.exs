defmodule ApiaryProWeb.ClientLive.CopiedLinkTest do
  @moduledoc """
  The Clients page without mail: a client's first owner's invitation is kept, and its link
  is shown once, in the core's component, on the page that made it, for the operator's
  person to copy; the link accepts. An unconfirmed person makes one, since nothing is
  mailed for them. With mail, the pages email, and an unconfirmed person is refused.
  """
  # Not async: the features are the node's, and an operator is made by an instance admin,
  # an owner of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query

  alias Apiary.{Features, Mail, Organisations, Repo}
  alias Apiary.Organisations.Invitation
  alias ApiaryPro.Operators
  alias ApiaryPro.Operators.OperatorInvitation

  @moduletag with_features: Features.all()

  defp operator(%{conn: conn}) do
    operator = operator_fixture()
    %{conn: log_in_user(conn, operator.user), operator: operator}
  end

  # The link the page shows, and its token.
  defp shown_link(lv) do
    url = lv |> element("#owner-link-url") |> render() |> text()
    [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)$}, url)
    {url, token}
  end

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp unconfirm(user),
    do:
      Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^user.id),
        set: [confirmed_at: nil]
      )

  # A client whose first owner's invitation was emailed, made before mail is turned off.
  defp client_without_owner(operator, name) do
    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => name, "email" => email()})

    client
  end

  describe "without mail" do
    setup :operator

    setup do
      Mail.put_test_source(:none)
      :ok
    end

    test "creating a client keeps its owner's invitation and shows its link once, never in a path, a flash, the title or the log",
         ctx do
      clients = ~p"/#{ctx.operator.organisation}/clients"
      new = ~p"/#{ctx.operator.organisation}/clients/new"
      {:ok, lv, _html} = live(ctx.conn, new)

      # Creating the client is still Create client.
      assert has_element?(lv, "#create-client", "Create client")

      log =
        capture_log(fn ->
          lv
          |> form("#client-form", organisation: %{name: "Example Co", email: "dana@example.com"})
          |> render_submit()
        end)

      # Still the New client page: the form gone, the client said made, and the link in
      # the form's place, with no flash.
      refute_patched(lv)
      refute has_element?(lv, "#client-form")
      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#flash-error")
      refute render(lv) =~ "is invited to be its owner"
      refute render(lv) =~ "could not be sent"
      assert has_element?(lv, "#client-created-name", "Example Co is created.")

      assert has_element?(
               lv,
               "#owner-link",
               "Copy this link and send it to dana@example.com yourself."
             )

      {url, token} = shown_link(lv)
      assert has_element?(lv, "#owner-link-copy[data-copy='#{url}']")

      works = lv |> element("#owner-link-works") |> render() |> text()
      assert works =~ ~r/^Works once, until .+ \(7 days\)\. It is shown only now\.$/

      # The invitation is kept, the operator's, and the link is its own.
      assert {:ok, [%{organisation: client, owners: []}]} =
               Operators.list_clients(ctx.operator.scope)

      assert %Invitation{id: id, organisation_id: client_id, email: "dana@example.com"} =
               Organisations.get_invitation_by_token(token)

      assert client_id == client.id

      assert Repo.get_by(OperatorInvitation,
               invitation_id: id,
               operator_id: ctx.operator.organisation.id
             )

      refute page_title(lv) =~ token
      refute log =~ token

      lv |> element("#owner-link-done") |> render_click()
      assert_patch(lv, clients)
      refute render(lv) =~ token
      render_async(lv)
      assert has_element?(lv, "#client-#{client.id}-owners", "No owner yet")

      # Opened again, the page has the form, and no link.
      {:ok, lv, html} = live(ctx.conn, new)
      refute html =~ token
      assert has_element?(lv, "#client-form")
    end

    test "the link it shows opens the invitation, and its person signs up as the client's owner, with a password",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/new")

      address = email()

      lv
      |> form("#client-form", organisation: %{name: "Example Co", email: address})
      |> render_submit()

      {_url, token} = shown_link(lv)

      {:ok, _lv, html} = live(build_conn(), ~p"/invitations/#{token}")
      assert html =~ "Create an account"
      refute html =~ "This invitation is no longer valid"

      # Its person signs up on the edition's page, still without mail: a password, and signed in
      # at once.
      {:ok, signup, _html} = live(build_conn(), ~p"/users/register?invitation=#{token}")
      password = "a long pass phrase"

      form =
        form(signup, "#registration_form",
          user: %{"email" => address, "password" => password, "password_confirmation" => password}
        )

      render_submit(form)
      assert get_session(follow_trigger_action(form, build_conn()), :user_token)
      owner = Apiary.Accounts.get_user_by_email_and_password(address, password)

      assert {:ok, [%{organisation: client, owners: [%{id: owner_id}]}]} =
               Operators.list_clients(ctx.operator.scope)

      assert owner_id == owner.id
      assert Organisations.get_invitation_by_token(token) == nil

      assert [%{level: :owner}] =
               Repo.all(
                 from m in Apiary.Organisations.Membership, where: m.organisation_id == ^client.id
               )
    end

    test "Invite owner… makes a link, shown once in place of the form, and Done goes back to the clients",
         ctx do
      Mail.put_test_source(:env)
      client = client_without_owner(ctx.operator, "Example Co")
      Mail.put_test_source(:none)

      clients = ~p"/#{ctx.operator.organisation}/clients"

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/owner")

      render_async(lv)

      assert has_element?(lv, "#invite-owner-confirm", "Create invitation link")
      assert has_element?(lv, "#invite-owner-confirm[data-busy]")
      assert render(lv) =~ "Creating…"
      refute has_element?(lv, "#invite-owner-confirm", "Send invitation")
      # The page's sentence is the same in both modes.
      assert render(lv) =~ "Example Co has no owner yet."

      log =
        capture_log(fn ->
          lv
          |> form("#invite-owner-form", owner: %{email: "dana@example.com"})
          |> render_submit()
        end)

      refute_patched(lv)
      refute has_element?(lv, "#invite-owner-form")
      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#flash-error")
      assert has_element?(lv, "#invite-owner-title", "Invite the owner of Example Co")

      assert has_element?(
               lv,
               "#owner-link",
               "Copy this link and send it to dana@example.com yourself."
             )

      {_url, token} = shown_link(lv)

      assert %Invitation{organisation_id: client_id, email: "dana@example.com"} =
               Organisations.get_invitation_by_token(token)

      assert client_id == client.id
      refute page_title(lv) =~ token
      refute log =~ token

      lv |> element("#owner-link-done") |> render_click()
      assert_patch(lv, clients)
      refute render(lv) =~ token
    end

    test "an unconfirmed person of the operator makes a link: nothing is mailed for them", ctx do
      unconfirm(ctx.operator.user)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/new")

      lv
      |> form("#client-form", organisation: %{name: "Example Co", email: email()})
      |> render_submit()

      assert has_element?(lv, "#owner-link")
      refute render(lv) =~ "Confirm your email address"

      # The client it made has no owner yet: Invite owner… makes another link.
      {:ok, [%{organisation: client}]} = Operators.list_clients(ctx.operator.scope)

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/owner")

      render_async(lv)

      lv
      |> form("#invite-owner-form", owner: %{email: email()})
      |> render_submit()

      assert has_element?(lv, "#owner-link")
      refute render(lv) =~ "Confirm your email address"
    end
  end

  describe "Make a new link" do
    setup :operator

    test "without mail, a pending invitation's row makes a new link, shown once on the client's row, and the old one stops",
         ctx do
      {%{organisation: client}, old} =
        create_client_fixture(ctx.operator.scope, %{
          "name" => "Example Co",
          "email" => "dana@example.com"
        })

      [invitation] = Repo.all(from i in Invitation, where: i.organisation_id == ^client.id)
      Mail.put_test_source(:none)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      item = "#owner-invitation-#{invitation.id}-renew"
      assert has_element?(lv, item, "Make a new link")
      assert has_element?(lv, item, "dana@example.com")
      assert has_element?(lv, "#{item}[aria-label='Make a new link for dana@example.com']")
      # Invite owner… stays beside it.
      assert has_element?(lv, "#client-#{client.id}-invite-owner", "Invite owner…")

      log = capture_log(fn -> lv |> element(item) |> render_click() end)
      render_async(lv)

      # In place on the client's row, with no step before it and no flash.
      link = "#owner-invitation-#{invitation.id}-link"
      assert has_element?(lv, "#client-#{client.id} #{link}")

      assert has_element?(
               lv,
               link,
               "Copy this link and send it to dana@example.com yourself."
             )

      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#flash-error")

      url = lv |> element("#{link}-url") |> render() |> text()
      [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)$}, url)
      assert has_element?(lv, "#{link}-copy[data-copy='#{url}']")

      works = lv |> element("#{link}-works") |> render() |> text()
      assert works =~ ~r/^Works once, until .+ \(7 days\)\. It is shown only now\.$/

      # The same invitation, a new link; the old one opens nothing.
      assert Organisations.get_invitation_by_token(token).id == invitation.id
      assert Organisations.get_invitation_by_token(old) == nil
      assert Repo.get(OperatorInvitation, invitation.id)
      refute page_title(lv) =~ token
      refute log =~ token

      lv |> element("#{link}-done") |> render_click()
      refute has_element?(lv, link)
      refute render(lv) =~ token
      assert has_element?(lv, "#client-#{client.id}-owners", "No owner yet")
    end

    test "with mail, the row offers no new link", ctx do
      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Example Co", "email" => email()})

      [invitation] = Repo.all(from i in Invitation, where: i.organisation_id == ^client.id)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)

      assert has_element?(lv, "#owner-invitation-#{invitation.id}-revoke")
      refute has_element?(lv, "#owner-invitation-#{invitation.id}-renew")
      refute render(lv) =~ "Make a new link"
    end

    test "past the operator's invitations of the day, the flash names the operator and no number",
         ctx do
      {%{organisation: client}, old} =
        create_client_fixture(ctx.operator.scope, %{
          "name" => "Example Co",
          "email" => "dana@example.com"
        })

      [invitation] = Repo.all(from i in Invitation, where: i.organisation_id == ^client.id)
      previous = Application.fetch_env!(:apiary, :invitations_per_day)
      on_exit(fn -> Application.put_env(:apiary, :invitations_per_day, previous) end)
      Application.put_env(:apiary, :invitations_per_day, 1)
      Mail.put_test_source(:none)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      lv |> element("#owner-invitation-#{invitation.id}-renew") |> render_click()

      assert has_element?(
               lv,
               "#flash-error",
               "No new link for dana@example.com now: #{ctx.operator.organisation.name} sent as many invitations in the last 24 hours as it may. Try again later, or contact support."
             )

      refute has_element?(lv, "#flash-error", "1 invitations")

      refute has_element?(lv, "#owner-invitation-#{invitation.id}-link")
      assert Organisations.get_invitation_by_token(old).id == invitation.id
    end
  end

  describe "with mail" do
    setup :operator

    test "the pages email as before, and show no link", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/new")
      address = email()

      html =
        lv
        |> form("#client-form", organisation: %{name: "Example Co", email: address})
        |> render_submit()

      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients")
      assert html =~ "Example Co is created, and #{address} is invited to be its owner."
      refute has_element?(lv, "#owner-link")

      client = client_without_owner(ctx.operator, "Beta")

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/owner")

      render_async(lv)

      assert has_element?(lv, "#invite-owner-confirm", "Send invitation")
      refute render(lv) =~ "Create invitation link"
      address = email()

      html =
        lv
        |> form("#invite-owner-form", owner: %{email: address})
        |> render_submit()

      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients")
      assert html =~ "#{address} is invited to be the owner."
      refute has_element?(lv, "#owner-link")
    end

    test "New client asks an unconfirmed person of the operator to confirm their address, and creates nothing",
         ctx do
      unconfirm(ctx.operator.user)
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/new")

      lv
      |> form("#client-form", organisation: %{name: "Example Co", email: email()})
      |> render_submit()

      assert has_element?(
               lv,
               "#flash-error",
               "Confirm your email address before you invite anyone: sign in again with the link we email you."
             )

      refute render(lv) =~ "Only owners and admins of an operator create its clients."
      assert has_element?(lv, "#client-form")
      assert {:ok, []} = Operators.list_clients(ctx.operator.scope)
    end

    test "an unconfirmed person of the operator is asked to confirm their address first", ctx do
      client = client_without_owner(ctx.operator, "Example Co")
      unconfirm(ctx.operator.user)

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/owner")

      render_async(lv)

      lv
      |> form("#invite-owner-form", owner: %{email: email()})
      |> render_submit()

      assert has_element?(
               lv,
               "#flash-error",
               "Confirm your email address before you invite anyone: sign in again with the link we email you."
             )

      refute has_element?(lv, "#owner-link")

      unconfirmed = %{
        ctx.operator.scope
        | user: %{ctx.operator.scope.user | confirmed_at: nil}
      }

      assert Operators.create_client(unconfirmed, %{"name" => "Gamma", "email" => email()}, & &1) ==
               {:error, :unconfirmed}

      assert Operators.invite_owner(unconfirmed, client.id, %{"email" => email()}, & &1) ==
               {:error, :unconfirmed}
    end
  end

  describe "mail set between the invitation and its sending" do
    setup :operator

    # An inviter whose address is not confirmed writes the invitation without mail, which
    # needs no confirmed inviter; mail is set as its transaction commits, in the page's
    # process, before it is sent.
    setup ctx do
      unconfirm(ctx.operator.user)
      Mail.put_test_source(:none)
      :ok
    end

    test "New client creates the client, withdraws its owner's invitation unsent, and asks to confirm the address",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/new")
      mail_set_at_commit(lv.pid)

      lv
      |> form("#client-form", organisation: %{name: "Example Co", email: "dana@example.com"})
      |> render_submit()

      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients")

      assert has_element?(
               lv,
               "#flash-error",
               "Confirm your email address before you invite anyone: sign in again with the link we email you."
             )

      refute has_element?(lv, "#owner-link")
      assert {:ok, [%{organisation: client}]} = Operators.list_clients(ctx.operator.scope)
      assert_withdrawn_unsent(client)
    end

    test "Invite owner… withdraws the invitation unsent, and asks to confirm the address", ctx do
      Mail.put_test_source(:env)
      client = client_without_owner(ctx.operator, "Example Co")
      Repo.delete_all(from i in Invitation, where: i.organisation_id == ^client.id)
      Mail.put_test_source(:none)

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients/#{client.id}/owner")

      render_async(lv)
      mail_set_at_commit(lv.pid)

      lv
      |> form("#invite-owner-form", owner: %{email: "dana@example.com"})
      |> render_submit()

      assert has_element?(
               lv,
               "#flash-error",
               "Confirm your email address before you invite anyone: sign in again with the link we email you."
             )

      refute has_element?(lv, "#owner-link")
      assert_withdrawn_unsent(client)
    end

    test "Make a new link withdraws the invitation unsent, and asks to confirm the address",
         ctx do
      Mail.put_test_source(:env)

      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{
          "name" => "Example Co",
          "email" => "dana@example.com"
        })

      # Its first link, emailed.
      assert_received {:email, %Swoosh.Email{to: [{_name, "dana@example.com"}]}}
      Mail.put_test_source(:none)
      [invitation] = Repo.all(from i in Invitation, where: i.organisation_id == ^client.id)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      mail_set_at_commit(lv.pid)

      lv |> element("#owner-invitation-#{invitation.id}-renew") |> render_click()
      render_async(lv)

      assert has_element?(
               lv,
               "#flash-error",
               "Confirm your email address before you invite anyone: sign in again with the link we email you."
             )

      refute has_element?(lv, "#owner-invitation-#{invitation.id}-link")
      # The list read again: the invitation is gone from the client's row.
      refute has_element?(lv, "#owner-invitation-#{invitation.id}-renew")
      assert_withdrawn_unsent(client)
    end
  end

  # Sets mail in the process `pid` as its next transaction commits, once.
  defp mail_set_at_commit(pid) do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:apiary, :repo, :query], &__MODULE__.set_mail_at_commit/4, {id, pid})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def set_mail_at_commit(_event, _measurements, %{query: query}, {id, pid}) do
    if self() == pid and to_string(query) == "commit" do
      :telemetry.detach(id)
      Mail.put_test_source(:env)
    end
  end

  # Nothing is mailed to the address, and the client's invitation is withdrawn as an
  # undelivered one is.
  defp assert_withdrawn_unsent(client) do
    refute_email_sent(to: "dana@example.com")
    assert Repo.all(from i in Invitation, where: i.organisation_id == ^client.id) == []

    assert [%{details: %{"reason" => "undelivered"}} | _] =
             Repo.all(
               from e in Apiary.Audit.Entry,
                 where: e.organisation_id == ^client.id and e.action == "invitation.revoke",
                 order_by: [desc: e.id]
             )
  end

  describe "the context, without mail" do
    setup do
      # The operator's owner is confirmed with a log-in link, before mail goes.
      operator = operator_fixture()
      Mail.put_test_source(:none)
      %{operator: operator}
    end

    test "create_client/3 and invite_owner/4 hand back the link, and an unconfirmed person may",
         %{operator: operator} do
      unconfirmed = %{operator.scope | user: %{operator.scope.user | confirmed_at: nil}}
      url = &"http://localhost/invitations/#{&1}"

      assert {:ok, %{organisation: client, sent: {:ok, invitation, {:link, link}}}} =
               Operators.create_client(
                 unconfirmed,
                 %{"name" => "Example Co", "email" => email()},
                 url
               )

      [_, token] = Regex.run(~r{/invitations/(.+)$}, link)
      assert Organisations.get_invitation_by_token(token).id == invitation.id

      assert {:ok, again, {:link, other}} =
               Operators.invite_owner(unconfirmed, client.id, %{"email" => email()}, url)

      assert other != link
      assert again.organisation_id == client.id
      assert Repo.get_by(OperatorInvitation, invitation_id: again.id)
    end
  end

  defp email, do: Apiary.AccountsFixtures.unique_user_email()
end
