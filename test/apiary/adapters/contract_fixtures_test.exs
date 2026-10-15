defmodule Apiary.Adapters.ContractFixturesTest do
  # The connect pass and the return against the integrations contract's signed fixtures,
  # vendored from the commit in `.integration-contract-ref` under
  # `test/fixtures/integration-contract/adapter/` and `schema/`: the pass made under the
  # server key of `keys.json` is the fixture's, byte for byte, and verifies; the return
  # signed under the access key of `keys.json` is the fixture's, byte for byte, and
  # verifies; each tampered one is refused; the reasons a refused return may give are the
  # schema's, in its order.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.{ConnectPass, ReturnToken}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.SigningKey

  @fixtures Path.expand("../../fixtures/integration-contract", __DIR__)

  defp read(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp keys, do: read("adapter/signed/keys.json")

  # The adapter's key: its secret is `qak_`, then its 32-byte seed in base64url.
  defp access_key_seed do
    "qak_" <> encoded = keys()["access_key"]["secret"]
    {:ok, seed} = Ed25519.decode(encoded, 32)
    seed
  end

  defp sign(payload, seed),
    do:
      Ed25519.encode(payload) <>
        "." <>
        Ed25519.encode(
          :crypto.sign(:eddsa, :none, SignedMessage.connect_return(payload), [seed, :ed25519])
        )

  # A fixture's object, compact, its members in the order written.
  defp compact(path) do
    @fixtures
    |> Path.join(path)
    |> File.read!()
    |> Jason.decode!(objects: :ordered_objects)
    |> Jason.encode!()
  end

  test "the connect pass under the server key is the fixture's, byte for byte" do
    fixture = read("adapter/signed/connect-pass.json")
    {:ok, seed} = Ed25519.decode(keys()["server_key"]["seed"], 32)
    key = SigningKey.new(seed)
    public_key = SigningKey.public_key(key)
    assert Ed25519.encode(public_key) == keys()["server_key"]["public_key"]

    payload = Jason.decode!(fixture["payload"])
    assert compact("adapter/connect-pass/payload.json") == fixture["payload"]
    {:ok, nonce} = Ed25519.decode(payload["nonce"], 16)
    {:ok, expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])
    now = DateTime.add(expires_at, -ConnectPass.validity(), :second)

    assert ConnectPass.issue(payload["adapter_id"], payload["connection_id"],
             key: key,
             nonce: nonce,
             now: now
           ) == {:ok, fixture["pass"]}

    assert SignedMessage.connect_pass(fixture["payload"]) ==
             "qory-connect-ed25519-v1\n" <> fixture["payload"]

    assert ConnectPass.verify(fixture["pass"], public_key, now: now) ==
             {:ok,
              %{
                adapter_id: payload["adapter_id"],
                connection_id: payload["connection_id"],
                nonce: nonce,
                expires_at: expires_at
              }}

    assert ConnectPass.verify(fixture["tampered"], public_key, now: now) == :error
  end

  test "the return under the adapter's key is the fixture's, byte for byte" do
    fixture = read("adapter/signed/connect-return.json")
    seed = access_key_seed()
    {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
    assert Ed25519.encode(public_key) == keys()["access_key"]["public_key"]

    assert compact("adapter/connect-return/linked.json") == fixture["payload"]
    assert sign(fixture["payload"], seed) == fixture["token"]

    assert SignedMessage.connect_return(fixture["payload"]) ==
             "qory-connect-return-ed25519-v1\n" <> fixture["payload"]

    payload = Jason.decode!(fixture["payload"])
    {:ok, nonce} = Ed25519.decode(payload["nonce"], 16)
    {:ok, expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])

    assert ReturnToken.verify(fixture["token"], [public_key]) ==
             {:ok,
              %{
                connection_id: payload["connection_id"],
                nonce: nonce,
                outcome: :linked,
                reason: nil,
                expires_at: expires_at
              }}

    assert ReturnToken.verify(fixture["tampered"], [public_key]) == :error
  end

  test "a refused return reads its reason, one of the schema's, in its order" do
    seed = access_key_seed()
    {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)

    assert {:ok, %{outcome: :refused, reason: :grant_taken}} =
             "adapter/connect-return/refused-grant-taken.json"
             |> compact()
             |> sign(seed)
             |> ReturnToken.verify([public_key])

    assert read("schema/connect-return.schema.json")["properties"]["reason"]["enum"] ==
             Enum.map(ReturnToken.reasons(), &Atom.to_string/1)
  end
end
