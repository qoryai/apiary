defmodule ApiaryWeb.Contract.GrantEndControllerTest do
  # `POST /v1/grants/end`, an adapter reporting that the source no longer covers one grant,
  # through `ApiaryWeb.Contract.AdapterRequest`: the contract's grant end, its signed 204
  # and what it ends, the contract's invalid grant ends, the time's window, each answer in
  # the contract's order, signed, a connection whose organisation is out of use, and the
  # path read raw when written with an escape.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections, Feed, Grant}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @path "/v1/grants/end"
  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @invalid %{"error" => "invalid_request"}
  @grant_unknown %{"error" => "grant_unknown"}

  # The edition narrows the rights of an adapter's key: its role ends no grant.
  defmodule NoGrantEnd do
    @moduledoc false
    def check(_scope, :"adapter.end_grant", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    "G_1" = listing_grant(connection, "G_1")
    {:ok, verified} = Apiary.AccessKeys.fetch_for_verification(key.key_id)
    key_scope = Scope.for_access_key(verified)

    {:ok, :accepted} =
      Collections.post_listing(key_scope, %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections: [
          %{
            ref: "TRK",
            url: "https://tracker.acme.example/TRK",
            title: "Tracker",
            grant_ref: "G_1",
            target: nil
          }
        ],
        listing: %{id: "l1", part: 1, started_at: DateTime.utc_now(:second), complete: true}
      })

    %{
      scope: scope,
      adapter: adapter,
      key: key,
      key_scope: key_scope,
      seed: pair.secret,
      connection: connection
    }
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp now_time(offset \\ 0),
    do: (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # The contract's grant end, for `connection`, at the clock now plus `offset` seconds.
  defp body(connection, overrides \\ %{}, offset \\ 0) do
    "grant-end/ended.json"
    |> fixture()
    |> Map.merge(%{"time" => now_time(offset), "connection_id" => connection.public_id})
    |> Map.merge(overrides)
  end

  defp send_end(ctx, body, target \\ @path),
    do:
      signed_post(build_conn(), ctx.key.key_id, ctx.seed, body,
        target: target,
        content_type: "application/json",
        delivery: nil
      )

  defp live_grants(ctx),
    do:
      Repo.all(
        from g in Grant,
          where: g.adapter_id == ^ctx.adapter.id and is_nil(g.ended_at),
          order_by: g.grant_ref,
          select: g.grant_ref
      )

  defp live_collections(ctx),
    do:
      Repo.all(
        from c in Collection,
          where: c.connection_id == ^ctx.connection.id and is_nil(c.ended_at),
          select: c.external_ref
      )

  defp state(ctx),
    do:
      {Repo.all(from g in Grant, order_by: g.id), Repo.all(from c in Collection, order_by: c.id),
       Feed.entries(ctx.adapter)}

  test "the contract's grant end is a signed 204 that ends the grant and its collections",
       ctx do
    conn = send_end(ctx, body(ctx.connection))

    assert conn.status == 204
    assert conn.resp_body == ""
    assert signed_answer?(conn)
    assert live_grants(ctx) == []
    assert live_collections(ctx) == []
    assert Repo.get!(Connection, ctx.connection.id).state == :connected

    assert %{kind: "grant", data: %{"grant_ref" => "G_1", "status" => "unlinked"}} =
             List.last(Feed.entries(ctx.adapter))

    # The same grant end again, built anew: grant_unknown, signed.
    conn = send_end(ctx, body(ctx.connection, %{}, 1))
    assert json_response(conn, 409) == @grant_unknown
    assert signed_answer?(conn)
  end

  test "the contract's invalid grant ends, and a member it does not define, are 400", ctx do
    before = state(ctx)

    for path <-
          ~w(invalid/grant-end-without-grant-ref.json invalid/grant-end-with-pass-nonce.json) do
      written = fixture(path)

      body =
        Map.merge(written, %{"time" => now_time(), "connection_id" => ctx.connection.public_id})

      conn = send_end(ctx, body)
      assert json_response(conn, 400) == @invalid, path
      assert signed_answer?(conn)
    end

    for overrides <- [%{"grant_ref" => ""}, %{"connection_id" => "ac_x"}, %{"reason" => "gone"}] do
      conn = send_end(ctx, body(ctx.connection, overrides))
      assert json_response(conn, 400) == @invalid, inspect(overrides)
    end

    assert state(ctx) == before
  end

  test "a time more than 300 seconds off is 401, unsigned", ctx do
    conn = send_end(ctx, body(ctx.connection, %{"time" => now_time(-301)}))
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert unsigned_answer?(conn)
    assert live_grants(ctx) == ["G_1"]
  end

  test "each answer in the contract's order, signed; each refusal changes nothing", ctx do
    %{scope: other} = sign_up_fixture()
    {pending, _nonce} = connection_fixture(other, ctx.adapter, :pending)
    another = connectable_adapter_fixture()
    {elsewhere, _nonce} = connection_fixture(other, another.adapter, :connected)
    "G_1" = listing_grant(elsewhere, "G_1")
    before = state(ctx)

    answer = fn body, status, expected ->
      conn = send_end(ctx, body)
      assert json_response(conn, status) == expected, inspect(body)
      assert signed_answer?(conn)
    end

    # Unknown: a pending connection, an id of no connection, and another adapter's
    # connection in another organisation, each with the contract's body.
    unknown = fixture("refusal/connection-unknown.json")
    answer.(body(pending, %{}, 2), 403, unknown)
    answer.(body(ctx.connection, %{"connection_id" => "ac_0000000000000000"}, 3), 403, unknown)
    answer.(body(elsewhere, %{}, 4), 403, unknown)

    # Grant unknown: a ref the connection has no live grant with.
    answer.(body(ctx.connection, %{"grant_ref" => "G_NEVER"}, 5), 409, @grant_unknown)
    assert state(ctx) == before

    # Ended, before grant_unknown.
    {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
    ended = fixture("refusal/connection-ended.json")
    answer.(body(ctx.connection, %{}, 6), 409, ended)
    answer.(body(ctx.connection, %{"grant_ref" => "G_NEVER"}, 7), 409, ended)

    # Forbidden before every other answer, whatever the connection.
    Edition.put_test_stub(NoGrantEnd)
    forbidden = %{"error" => "forbidden"}
    answer.(body(ctx.connection, %{}, 8), 403, forbidden)
    answer.(body(pending, %{}, 9), 403, forbidden)
    answer.(body(ctx.connection, %{"connection_id" => "ac_0000000000000000"}, 10), 403, forbidden)
  end

  test "a connection whose organisation is out of use gets the signed 204, never suspended",
       ctx do
    Edition.put_test_stub(EditionStubs.OutOfUse)
    Process.put(:out_of_use, [ctx.scope.organisation.id])

    conn = send_end(ctx, body(ctx.connection))
    assert conn.status == 204
    assert signed_answer?(conn)
    assert live_grants(ctx) == []
    assert live_collections(ctx) == []
  end

  test "the path read raw also when written with an escape", ctx do
    conn = send_end(ctx, body(ctx.connection), "/v1/grants/%65nd")
    assert conn.status == 204
    assert live_grants(ctx) == []
  end
end
