defmodule ApiaryWeb.WorkItemRedirectControllerTest do
  # A work item's permanent address (`GET /work-items/:work_item_id`): where it leads a
  # person who may open the work item, how a visitor gets there through sign-in, and that
  # everyone else gets one not found, the same for a work item that exists and for one
  # that does not. `ApiaryWeb.FactoryShellTest` has the address without the feature.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Phoenix.LiveViewTest

  alias Apiary.{Deletion, Edition, EditionStubs, Organisations, Repo, WorkItems}

  @moduletag needs: :factory

  @unknown "/work-items/wi_0000000000000000"
  @malformed [
    "/work-items/not-an-id",
    "/work-items/wi_0",
    "/work-items/rn_0123456789abcdef",
    "/work-items/wi_0000000000000000x",
    "/work-items/WI_0000000000000000",
    "/work-items/wi_%C3%A9000000000000000",
    "/work-items/1"
  ]

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{work_item: work_item_fixture(scope)}
  end

  defp address(work_item), do: "/work-items/#{work_item.public_id}"

  defp page(scope, work_item),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/work/#{work_item.number}"

  # What a request is answered: the status, the body and the headers, all but the
  # request's id and the nonce (`ApiaryWeb.ContentSecurityPolicy`). An error the endpoint
  # renders and raises again is taken as it was sent.
  defp answer(request) do
    conn = request.()
    {conn.status, without_nonce(conn.resp_body), headers(conn.resp_headers)}
  rescue
    _error ->
      {status, headers, body} = assert_error_sent(:not_found, request)
      {status, without_nonce(body), headers(headers)}
  end

  defp headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> name == "x-request-id" end)
    |> Enum.map(fn {name, value} -> {name, without_nonce(value)} end)
    |> Enum.sort()
  end

  defp without_nonce(text),
    do: String.replace(text, ~r/nonce(-|=")[A-Za-z0-9+\/=]+/, "nonce\\1…")

  # The address of `work_item` is not found to `asker`, in the same response as an unknown
  # id, while the work item's owner, who opens it, is redirected.
  defp assert_same_not_found(asker, owner_conn, scope, work_item) do
    assert owner_conn |> get(address(work_item)) |> redirected_to() == page(scope, work_item)

    assert {404, body, _headers} = theirs = answer(fn -> get(asker, address(work_item)) end)
    assert body == "Not Found"
    assert theirs == answer(fn -> get(asker, @unknown) end)
  end

  # The reads of the database `request` makes, in order, each its SQL without its values.
  defp reads(request) do
    handler = "work-item-address-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == parent, do: send(parent, {:read, handler, meta.query})
      end,
      nil
    )

    try do
      answer(request)
    after
      :telemetry.detach(handler)
    end

    collect(handler, [])
  end

  defp collect(handler, acc) do
    receive do
      {:read, ^handler, query} -> collect(handler, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "to a person who may open the work item" do
    test "redirects to the work item's page, which opens", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      to = page(scope, work_item)
      assert conn |> get(address(work_item)) |> redirected_to() == to

      {:ok, view, _html} = live(conn, to)
      assert render(view) =~ work_item.title
    end

    test "redirects a member too, not only an owner", %{scope: scope, work_item: work_item} do
      %{user: member} = member_fixture(scope, :member)

      assert build_conn()
             |> log_in_user(member)
             |> get(address(work_item))
             |> redirected_to() == page(scope, work_item)
    end

    test "leaves the query out", %{conn: conn, scope: scope, work_item: work_item} do
      assert conn |> get(address(work_item) <> "?next=/elsewhere") |> redirected_to() ==
               page(scope, work_item)
    end

    test "leads to the new address after a rename of the workspace", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      before = page(scope, work_item)
      {:ok, renamed} = Organisations.update_workspace(scope, %{name: "Checkout renamed"})
      assert renamed.slug != scope.workspace.slug

      to = conn |> get(address(work_item)) |> redirected_to()
      assert to == page(%{scope | workspace: renamed}, work_item)
      assert to != before
    end

    test "leads to the new address after a rename of the organisation", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      before = page(scope, work_item)
      name = "Northwind #{System.unique_integer([:positive])}"
      {:ok, renamed} = Organisations.update_organisation(scope, %{name: name})
      assert renamed.slug != scope.organisation.slug

      to = conn |> get(address(work_item)) |> redirected_to()
      assert to == page(%{scope | organisation: renamed}, work_item)
      assert to != before
    end

    test "leads to the other workspace after a move", %{conn: conn, scope: scope} do
      connection = ticket_connection_fixture(scope)
      ticket = backlog_ticket_fixture(scope, connection: connection)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      there = workspace_scope(scope.user, workspace_fixture(scope.organisation))

      %{work_item: moved} = moved_work_item_fixture(scope, work_item, ticket, connection, there)
      assert moved.public_id == work_item.public_id
      assert moved.workspace_id == there.workspace.id

      assert conn |> get(address(work_item)) |> redirected_to() == page(there, moved)
    end
  end

  describe "to a visitor who is signed out" do
    test "a real, an unknown and a malformed id get the same response: to sign in", %{
      work_item: work_item
    } do
      real = answer(fn -> get(build_conn(), address(work_item)) end)
      assert {302, _body, headers} = real
      assert {"location", ~p"/users/log-in"} in headers

      # The session cookie is encrypted, so its value is left out.
      same = fn {status, body, headers} ->
        {status, body, Enum.reject(headers, fn {name, _value} -> name == "set-cookie" end)}
      end

      for path <- [@unknown | @malformed] do
        assert same.(answer(fn -> get(build_conn(), path) end)) == same.(real), path
      end
    end

    test "signing in with a password, after a wrong one, lands on the work item", %{
      scope: scope,
      user: user,
      work_item: work_item
    } do
      user = set_password(user)
      from = address(work_item)

      conn = get(build_conn(), from)
      assert redirected_to(conn) == ~p"/users/log-in"

      conn = conn |> recycle() |> get(~p"/users/log-in")
      assert html_response(conn, 200)

      conn =
        conn
        |> recycle()
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "not the password"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"

      conn =
        conn
        |> recycle()
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == from

      conn = conn |> recycle() |> get(from)
      assert redirected_to(conn) == page(scope, work_item)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You are logged in."
    end

    test "signing in with a link in the same browser lands on the work item", %{
      scope: scope,
      user: user,
      work_item: work_item
    } do
      from = address(work_item)
      {token, _hashed} = generate_user_magic_link_token(user)

      conn = get(build_conn(), from)
      assert redirected_to(conn) == ~p"/users/log-in"

      conn = conn |> recycle() |> post(~p"/users/log-in", %{"user" => %{"token" => token}})
      assert redirected_to(conn) == from

      assert conn |> recycle() |> get(from) |> redirected_to() == page(scope, work_item)
    end

    test "a person with no access who signs in gets not found", %{work_item: work_item} do
      %{user: stranger} = sign_up_fixture()
      stranger = set_password(stranger)
      from = address(work_item)

      conn = get(build_conn(), from)

      conn =
        conn
        |> recycle()
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => stranger.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == from

      theirs = answer(fn -> conn |> recycle() |> get(from) end)
      assert {404, "Not Found", _headers} = theirs
      assert theirs == answer(fn -> conn |> recycle() |> get(@unknown) end)
    end
  end

  describe "to anyone else" do
    test "another organisation's member gets the not found of an unknown id", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      %{user: stranger} = sign_up_fixture()
      assert_same_not_found(log_in_user(build_conn(), stranger), conn, scope, work_item)
    end

    test "a member who does not reach the workspace gets the not found of an unknown id", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      :ok = Edition.put_test_stub(EditionStubs.MembersReachNamed)
      other = workspace_fixture(scope.organisation)
      EditionStubs.MembersReachNamed.put([other.id])

      %{user: member} = member_fixture(scope, :member)
      assert_same_not_found(log_in_user(build_conn(), member), conn, scope, work_item)
    end

    test "a suspended member gets the not found of an unknown id", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      %{user: member, membership: membership} = member_fixture(scope, :member)
      {:ok, _suspended} = Organisations.suspend_member(scope, membership.id)

      assert_same_not_found(log_in_user(build_conn(), member), conn, scope, work_item)
    end

    test "a member from whom the feature is hidden gets the not found of an unknown id", %{
      scope: scope,
      work_item: work_item
    } do
      %{user: member} = member_fixture(scope, :member)
      asker = log_in_user(build_conn(), member)
      assert asker |> get(address(work_item)) |> redirected_to() == page(scope, work_item)

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])

      assert {404, "Not Found", _headers} =
               theirs = answer(fn -> get(asker, address(work_item)) end)

      assert theirs == answer(fn -> get(asker, @unknown) end)
    end

    test "a work item the person cannot open takes the reads of an unknown id, in order", %{
      scope: scope,
      work_item: work_item
    } do
      :ok = Edition.put_test_stub(EditionStubs.MembersReachNamed)
      other = workspace_fixture(scope.organisation)
      EditionStubs.MembersReachNamed.put([other.id])
      %{user: member} = member_fixture(scope, :member)
      %{scope: elsewhere} = sign_up_fixture()
      theirs = work_item_fixture(elsewhere)

      asker = log_in_user(build_conn(), member)
      unknown = reads(fn -> get(asker, @unknown) end)
      assert unknown != []

      for path <- [address(work_item), address(theirs) | @malformed] do
        assert reads(fn -> get(asker, path) end) == unknown, path
      end
    end

    test "an unknown and a malformed id get one not found", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      assert conn |> get(address(work_item)) |> redirected_to() == page(scope, work_item)
      assert {404, "Not Found", _headers} = unknown = answer(fn -> get(conn, @unknown) end)

      for path <- @malformed do
        assert answer(fn -> get(conn, path) end) == unknown, path
      end
    end

    test "a work item in a deleted workspace is not found, to its owner too", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      assert conn |> get(address(work_item)) |> redirected_to() == page(scope, work_item)

      workspace_fixture(scope.organisation)

      {:ok, _marked} =
        Deletion.delete_workspace(scope, scope.workspace.id, scope.workspace.slug)

      assert {404, "Not Found", _headers} =
               theirs = answer(fn -> get(conn, address(work_item)) end)

      assert theirs == answer(fn -> get(conn, @unknown) end)
    end

    test "a work item in a deleted organisation is not found, to its owner too", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      assert conn |> get(address(work_item)) |> redirected_to() == page(scope, work_item)

      {:ok, _marked} = Deletion.delete_organisation(scope, scope.organisation.slug)
      assert Repo.reload!(scope.organisation).deletion_marked_at

      assert {404, "Not Found", _headers} =
               theirs = answer(fn -> get(conn, address(work_item)) end)

      assert theirs == answer(fn -> get(conn, @unknown) end)
    end
  end
end
