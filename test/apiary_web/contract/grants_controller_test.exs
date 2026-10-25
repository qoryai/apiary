defmodule ApiaryWeb.Contract.GrantsControllerTest do
  # `POST /v1/grants` and `GET /v1/grants`, an adapter's report of a grant and its read of
  # Qory Apiary's copy, through `ApiaryWeb.Contract.AdapterRequest`: the contract's
  # fixtures, the signed 204 and what it stores, each refusal in its order, signed, and
  # the signed answer to the read.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query

  import Apiary.ContractFixtures,
    only: [signed_get: 5, signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, EditionStubs, PublicIdSource, Repo}
  alias Apiary.Adapters.{Connections, Feed, Grant}
  alias Apiary.Contract.Ed25519
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @path "/v1/grants"
  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @invalid %{"error" => "invalid_request"}

  # The edition narrows the rights of an adapter's key: its role neither reports nor reads
  # grants.
  defmodule NoGrants do
    def check(_scope, action, _subject)
        when action in [:"adapter.report_grant", :"adapter.read_grants"],
        do: {:error, :forbidden}

    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  # A fixture compact, its members in the order written.
  defp compact(path),
    do:
      @fixtures
      |> Path.join(path)
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)
      |> Jason.encode!()

  defp now_time(offset \\ 0),
    do: (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    %{scope: scope, adapter: adapter, key: key, seed: pair.secret}
  end

  # The contract's report, for `connection` under the nonce of the pass that connected it.
  defp body(connection, overrides \\ %{}) do
    "grant/linked.json"
    |> fixture()
    |> Map.merge(%{
      "time" => now_time(),
      "connection_id" => connection.public_id,
      "pass_nonce" => Ed25519.encode(connection.pass_nonce)
    })
    |> Map.merge(overrides)
  end

  defp report(ctx, body),
    do:
      signed_post(build_conn(), ctx.key.key_id, ctx.seed, body,
        target: @path,
        content_type: "application/json",
        delivery: nil
      )

  # A GET of the copy, signed at the contract's clock now, plus `offset` seconds, so two
  # reads in one second are no replay.
  defp read(ctx, offset \\ 0),
    do:
      signed_get(build_conn(), ctx.key.key_id, ctx.seed, @path,
        timestamp: SignedRequest.now() + offset
      )

  defp live(ctx),
    do:
      Repo.all(
        from g in Grant,
          where: g.adapter_id == ^ctx.adapter.id and g.state == :live,
          select: {g.connection_id, g.grant_ref}
      )

  describe "a report" do
    test "under a linked pass is a signed 204, and the grant is stored with its feed entry",
         ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      conn = report(ctx, body(connection))

      assert conn.status == 204
      assert conn.resp_body == ""
      assert signed_answer?(conn)
      assert live(ctx) == [{connection.id, "G_1"}]

      assert [%{kind: "grant", data: data}] = Feed.entries(ctx.adapter)

      assert data == %{
               "connection_id" => connection.public_id,
               "grant_ref" => "G_1",
               "status" => "linked"
             }
    end

    test "the contract's invalid reports, and a member it does not define, are 400", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)

      for path <- ~w(invalid/grant-without-pass-nonce.json
                     invalid/grant-pass-nonce-21-characters.json
                     invalid/grant-without-account.json
                     invalid/grant-account-without-ref.json
                     invalid/grant-account-title-line-feed.json) do
        written = fixture(path)

        overrides =
          Map.take(
            %{"time" => now_time(), "connection_id" => connection.public_id},
            Map.keys(written)
          )

        conn = report(ctx, Map.merge(written, overrides))
        assert json_response(conn, 400) == @invalid, path
        assert signed_answer?(conn)
      end

      # A nonce of 22 characters that is not canonical base64url, an empty ref, a
      # connection id outside its pattern, and an extra member.
      for overrides <- [
            %{"pass_nonce" => "AAECAwQFBgcICQoLDA0ODx"},
            %{"grant_ref" => ""},
            %{"account" => %{"ref" => "1001", "title" => "ac\u2028me"}},
            %{"connection_id" => "ac_x"},
            %{"title" => "Acme"}
          ] do
        conn = report(ctx, body(connection, overrides))
        assert json_response(conn, 400) == @invalid, inspect(overrides)
      end

      assert live(ctx) == []
    end

    test "is 403 forbidden, signed, to a key that may not report, whatever the connection",
         ctx do
      %{scope: other} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(other, ctx.adapter, :pending)
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      Edition.put_test_stub(NoGrants)

      for body <- [body(pending), body(connection)] do
        conn = report(ctx, body)
        assert json_response(conn, 403) == %{"error" => "forbidden"}
        assert signed_answer?(conn)
      end

      assert live(ctx) == []
    end

    test "a time more than 300 seconds off is 401, unsigned", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      conn = report(ctx, body(connection, %{"time" => now_time(-301)}))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert live(ctx) == []
    end

    test "each refusal, in the contract's order, signed, changes nothing", ctx do
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      %{scope: other} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(other, ctx.adapter, :pending)
      %{scope: third} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(third, ctx.adapter, :connected)

      refused = fn body, status, answer ->
        conn = report(ctx, body)
        assert json_response(conn, status) == answer, inspect(body)
        assert signed_answer?(conn)
      end

      # A pending connection, and an id of no connection.
      unknown = fixture("refusal/connection-unknown.json")
      refused.(body(pending), 403, unknown)

      refused.(
        body(connection, %{"connection_id" => "ac_f1xt0re000000000"}),
        403,
        unknown
      )

      # A nonce of no linked pass of the connection, and another connection's.
      refused.(body(connection, %{"pass_nonce" => Ed25519.encode(<<1::128>>)}), 409, %{
        "error" => "pass_unknown"
      })

      refused.(
        body(connection, %{"pass_nonce" => Ed25519.encode(theirs.pass_nonce)}),
        409,
        %{"error" => "pass_unknown"}
      )

      # A ref live under another organisation's connection, refused as the contract's
      # fixture is.
      assert report(ctx, body(theirs)).status == 204
      refused.(body(connection), 409, fixture("refusal/grant-taken.json"))

      # The nonce is spent once its report is accepted: the same report again, built anew.
      assert report(ctx, body(connection, %{"grant_ref" => "G_2"})).status == 204

      refused.(body(connection, %{"grant_ref" => "G_2", "time" => now_time(1)}), 409, %{
        "error" => "pass_unknown"
      })

      # Out of use, then ended.
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      refused.(
        body(connection, %{"time" => now_time(2)}),
        409,
        fixture("refusal/connection-suspended.json")
      )

      Process.put(:out_of_use, [])

      {:ok, _} =
        Connections.end_connection(
          Apiary.SourcesFixtures.key_scope(ctx.key),
          connection.public_id
        )

      refused.(
        body(connection, %{"time" => now_time(3)}),
        409,
        fixture("refusal/connection-ended.json")
      )

      assert Enum.sort(live(ctx)) == [{theirs.id, "G_1"}]
    end
  end

  describe "the read" do
    test "is the contract's answer, signed, for the grants of connections not ended", ctx do
      PublicIdSource.force(["f1xt0re000000000"])
      {connection, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      assert connection.public_id == "ac_f1xt0re000000000"

      conn = read(ctx)
      assert conn.status == 200
      assert signed_answer?(conn)
      assert conn.resp_body == compact("grants/empty.json")

      assert report(ctx, body(connection, %{"grant_ref" => "G_2"})).status == 204
      key_scope = Apiary.SourcesFixtures.key_scope(ctx.key)

      # A second linked pass, for the second grant.
      :ok = pass_made_earlier(connection.public_id)
      {:ok, _url, {_id, nonce}} = Apiary.Adapters.connect(ctx.scope, ctx.adapter)

      {:ok, :linked} =
        Connections.complete_return(
          ctx.scope,
          connection.public_id,
          return_token(ctx.seed, connection.public_id, nonce),
          nonce
        )

      assert report(ctx, body(connection, %{"pass_nonce" => nonce, "time" => now_time(1)})).status ==
               204

      conn = read(ctx, 1)
      assert conn.status == 200
      assert signed_answer?(conn)
      assert conn.resp_body == compact("grants/two-grants.json")

      # The answer always names its revision, which the refused fixture leaves out.
      refute Map.has_key?(fixture("invalid/grants-without-revision.json"), "revision")

      {:ok, _} = Connections.end_connection(key_scope, connection.public_id)
      assert read(ctx, 2).resp_body == compact("grants/empty.json")
    end

    test "is 403 forbidden, signed, to a key that may not read it", ctx do
      Edition.put_test_stub(NoGrants)
      conn = read(ctx)
      assert json_response(conn, 403) == %{"error" => "forbidden"}
      assert signed_answer?(conn)
    end
  end
end
