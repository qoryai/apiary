defmodule Apiary.Adapters.ContractFixturesTest do
  # The connect pass, the setup pass and the return against the integrations contract's
  # signed fixtures, vendored from the commit in `.integration-contract-ref` under
  # `test/fixtures/integration-contract/adapter/` and `schema/`: each pass made under the
  # server key of `keys.json` is the fixture's, byte for byte, and verifies; the setup
  # pass's invalid payloads, signed under that key, are refused; the return
  # signed under the access key of `keys.json` is the fixture's, byte for byte, and
  # verifies; each tampered one is refused; the reasons a refused return may give are the
  # schema's, in its order; a call signed under the server key is the fixture's, byte for
  # byte, and the adapter's answer to it verifies under the access key, bound to that
  # call alone.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.{Calls, ConnectPass, ReturnToken, SetupPass}
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

  # The server key of `keys.json`.
  defp server_key do
    {:ok, seed} = Ed25519.decode(keys()["server_key"]["seed"], 32)
    SigningKey.new(seed)
  end

  test "the setup pass under the server key is the fixture's, byte for byte" do
    fixture = read("adapter/signed/setup-pass.json")
    key = server_key()
    public_key = SigningKey.public_key(key)
    assert Ed25519.encode(public_key) == keys()["server_key"]["public_key"]

    payload = Jason.decode!(fixture["payload"])
    assert compact("adapter/setup-pass/payload.json") == fixture["payload"]
    {:ok, nonce} = Ed25519.decode(payload["nonce"], 16)
    {:ok, expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])
    now = DateTime.add(expires_at, -SetupPass.validity(), :second)

    assert SetupPass.issue(payload["adapter_id"], key: key, nonce: nonce, now: now) ==
             {:ok, fixture["pass"]}

    assert SignedMessage.setup_pass(fixture["payload"]) ==
             "qory-setup-ed25519-v1\n" <> fixture["payload"]

    assert SetupPass.verify(fixture["pass"], public_key, now: now) ==
             {:ok, %{adapter_id: payload["adapter_id"], nonce: nonce, expires_at: expires_at}}

    assert SetupPass.verify(fixture["tampered"], public_key, now: now) == :error

    # Neither pass verifies as the other.
    connect = read("adapter/signed/connect-pass.json")
    assert ConnectPass.verify(fixture["pass"], public_key, now: now) == :error
    assert SetupPass.verify(connect["pass"], public_key, now: now) == :error
  end

  test "the setup pass's invalid payloads are refused, each signed as a pass is" do
    key = server_key()
    public_key = SigningKey.public_key(key)

    sign = fn payload ->
      Ed25519.encode(payload) <>
        "." <> Ed25519.encode(SigningKey.sign(key, SignedMessage.setup_pass(payload)))
    end

    names =
      @fixtures
      |> Path.join("adapter/invalid/setup-pass-*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, Path.join(@fixtures, "adapter")))

    assert names == [
             "invalid/setup-pass-adapter-id-connection-id.json",
             "invalid/setup-pass-undefined-member.json",
             "invalid/setup-pass-version-2.json",
             "invalid/setup-pass-without-nonce.json"
           ]

    now = ~U[2026-10-15 12:00:00Z]

    # The valid payload, signed the same way, is read: each invalid one is refused for
    # what it holds.
    valid = sign.(compact("adapter/setup-pass/payload.json"))
    assert {:ok, _} = SetupPass.verify(valid, public_key, now: now)

    for name <- names do
      signed = sign.(compact("adapter/" <> name))
      assert SetupPass.verify(signed, public_key, now: now) == :error, name
    end
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

  test "a call under the server key is the fixture's, byte for byte" do
    call = read("adapter/signed/call.json")
    headers = call["headers"]
    body = Jason.decode!(call["body"], objects: :ordered_objects)
    {:ok, time, 0} = DateTime.from_iso8601(body["time"])
    members = Enum.drop(body.values, 2)

    assert Calls.body(members, time) == call["body"]
    assert call["url"] == "https://code-adapter.example.com/calls/" <> call["path"]
    assert headers["X-Qory-Contract-Version"] == Integer.to_string(Calls.revision())

    assert SignedMessage.call(
             headers["X-Qory-Adapter-Id"],
             headers["X-Qory-Instance-Id"],
             "POST",
             call["path"],
             call["body"]
           ) ==
             Enum.join(
               [
                 "qory-call-ed25519-v1",
                 headers["X-Qory-Adapter-Id"],
                 headers["X-Qory-Instance-Id"],
                 "POST",
                 "resolve",
                 call["body"]
               ],
               "\n"
             )

    assert Calls.signature(
             server_key(),
             headers["X-Qory-Adapter-Id"],
             headers["X-Qory-Instance-Id"],
             call["path"],
             call["body"]
           ) == headers["X-Qory-Signature-Ed25519"]
  end

  test "the adapter's answer to a call verifies under its access key, bound to that call alone" do
    call = read("adapter/signed/call.json")
    answer = read("adapter/signed/call-answer.json")
    call_signature = call["headers"]["X-Qory-Signature-Ed25519"]
    signature = answer["headers"]["X-Qory-Signature-Ed25519"]
    {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, access_key_seed())
    server_public_key = SigningKey.public_key(server_key())

    assert SignedMessage.call_answer(answer["status"], call_signature, answer["body"]) ==
             "qory-call-answer-ed25519-v1\n200\n" <>
               call_signature <>
               "\n" <> Base.encode16(:crypto.hash(:sha256, answer["body"]), case: :lower)

    assert Calls.signed?(signature, 200, call_signature, answer["body"], [public_key])

    # Under another key, for another status, body or call, or written otherwise: refused.
    refute Calls.signed?(signature, 200, call_signature, answer["body"], [server_public_key])
    refute Calls.signed?(signature, 201, call_signature, answer["body"], [public_key])
    refute Calls.signed?(signature, 200, call_signature, answer["body"] <> " ", [public_key])
    other_call = String.replace(call_signature, ~r/^./, "A")
    refute Calls.signed?(signature, 200, other_call, answer["body"], [public_key])
    refute Calls.signed?(signature <> "=", 200, call_signature, answer["body"], [public_key])
    refute Calls.signed?(nil, 200, call_signature, answer["body"], [public_key])
    refute Calls.signed?(signature, 200, call_signature, answer["body"], [])
  end
end
