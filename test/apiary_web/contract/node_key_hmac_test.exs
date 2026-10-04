defmodule ApiaryWeb.Contract.NodeKeyHmacTest do
  @moduledoc """
  A node's access key has no secret: a request that names its key id and signs with HMAC,
  today's signature, is 401, whether the key is approved, awaits approval, or its row was
  changed outside the application. Today's keys verify as before, beside it.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Repo

  @configuration "/.well-known/qory-configuration"

  setup do
    %{scope: scope} = sign_up_fixture()
    node = node_fixture(scope)
    %{scope: scope, node: node}
  end

  defp unauthorized?(conn), do: json_response(conn, 401) == %{"error" => "unauthorized"}

  test "an approved node key's id with an HMAC signature is 401", ctx do
    %{access_key: key, pair: pair} = node_key_fixture(ctx.scope, ctx.node)

    for secret <- ["", published_secret(), Base.url_encode64(pair.secret, padding: false)] do
      assert unauthorized?(signed_get(ctx.conn, key.key_id, secret, @configuration))

      {_subject, events} = first_events()
      body = Jason.encode!(events)
      assert unauthorized?(signed_post(build_conn(), key.key_id, secret, body))
    end
  end

  test "a pending node key's id with an HMAC signature is 401", ctx do
    %{access_key: key} = pending_key_fixture(ctx.scope, ctx.node)
    assert unauthorized?(signed_get(ctx.conn, key.key_id, published_secret(), @configuration))
  end

  test "a node key whose row was changed outside the application is 401", ctx do
    %{access_key: key} = pending_key_fixture(ctx.scope, ctx.node)

    Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
      set: [approved_at: DateTime.utc_now()]
    )

    {conn, log} =
      with_log(fn ->
        signed_get(ctx.conn, key.key_id, published_secret(), @configuration)
      end)

    assert unauthorized?(conn)
    assert log =~ "does not match its integrity code"
  end

  test "today's key verifies beside a node's", ctx do
    node_key_fixture(ctx.scope, ctx.node)
    published_key_fixture(ctx.scope)

    conn = signed_get(ctx.conn, published_key_id(), published_secret(), @configuration)
    assert conn.status == 200
  end
end
