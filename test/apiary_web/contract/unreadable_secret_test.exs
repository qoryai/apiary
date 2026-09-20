defmodule ApiaryWeb.Contract.UnreadableSecretTest do
  @moduledoc """
  A signed request with a key whose secrets this instance cannot decrypt (`CLOAK_KEY` is
  not the one they were encrypted with) is 503, uniform and logged, never 401 and never 500.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  @other_key [
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: :crypto.strong_rand_bytes(32)}
    ]
  ]

  setup do
    %{scope: scope} = sign_up_fixture()
    key = published_key_fixture(scope)
    {:ok, ciphertext} = Cloak.Vault.encrypt(@other_key, published_secret())
    {:ok, uuid} = Ecto.UUID.dump(key.id)

    Apiary.Repo.query!("UPDATE access_keys SET secret_primary = $1 WHERE id = $2", [
      ciphertext,
      uuid
    ])

    %{scope: scope}
  end

  test "a batch is 503 unavailable, and the log names the key id", %{conn: conn} do
    {_subject, events} = first_events()
    body = Jason.encode!(events)

    {conn, log} =
      with_log(fn -> signed_post(conn, published_key_id(), published_secret(), body) end)

    assert json_response(conn, 503) == %{"error" => "unavailable"}
    assert log =~ "access key secret cannot be decrypted key_id=#{published_key_id()}"
  end

  test "the configuration document is 503 too", %{conn: conn} do
    {conn, _log} =
      with_log(fn ->
        signed_get(
          conn,
          published_key_id(),
          published_secret(),
          "/.well-known/qory-configuration"
        )
      end)

    assert json_response(conn, 503) == %{"error" => "unavailable"}
  end

  test "a key id the hive does not hold stays 401", %{conn: conn} do
    conn =
      signed_get(
        conn,
        "ak_0000000000000000",
        published_secret(),
        "/.well-known/qory-configuration"
      )

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
