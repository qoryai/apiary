defmodule Apiary.Adapters.ContractFixturesTest do
  # The integration contract's signed fixtures (`fixtures/adapter/signed/`, at the commit
  # in `.integrations-contract-ref`), against the core's signing: an adapter's request
  # string and signature, the signed answer, and the connect pass, byte for byte.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.ConnectPass
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.{IntegrationsContract, SigningKey}

  @moduletag :integrations_contract

  defp signed(name), do: IntegrationsContract.fixture!("adapter/signed/#{name}.json")

  defp request_message(%{"method" => method, "target" => target, "headers" => headers} = fixture) do
    last =
      case method do
        "GET" -> headers["X-Qory-Timestamp"]
        "POST" -> fixture["body"]
      end

    SignedMessage.request(
      headers["X-Qory-Access-Key-Id"],
      headers["X-Qory-Instance-Id"],
      method,
      target,
      last
    )
  end

  test "the fixture keys are the contract's, and every instance refuses the server key" do
    access = IntegrationsContract.key!("access_key")
    server = IntegrationsContract.key!("server_key")
    assert access.access_key_id == "ak_f1xt0re000000000"
    assert SigningKey.check_seed(server.seed) == {:error, :fixture}
  end

  test "a signed GET and POST verify under the access key as the core builds their strings, and no other way" do
    %{public_key: public_key, seed: seed} = IntegrationsContract.key!("access_key")

    for name <- ["get-changes", "post-source-items"] do
      fixture = signed(name)
      message = request_message(fixture)
      {:ok, signature} = Ed25519.decode(fixture["headers"]["X-Qory-Signature-Ed25519"], 64)

      assert Ed25519.verify(message, signature, public_key), name
      # Ed25519 is deterministic: the core signs the same bytes to the same signature.
      assert :crypto.sign(:eddsa, :none, message, [seed, :ed25519]) == signature
      assert fixture["headers"]["X-Qory-Contract-Version"] == "1"

      refute Ed25519.verify(message <> "\n", signature, public_key)
    end
  end

  test "the signed answer verifies under the server key over the core's answer string" do
    %{public_key: public_key} = IntegrationsContract.key!("server_key")
    answer = signed("answer-changes")
    request = signed("get-changes")
    {:ok, signature} = Ed25519.decode(answer["headers"]["X-Qory-Signature-Ed25519"], 64)

    message =
      SignedMessage.answer(
        answer["status"],
        request["headers"]["X-Qory-Signature-Ed25519"],
        answer["body"],
        nil,
        nil
      )

    assert Ed25519.verify(message, signature, public_key)

    assert SigningKey.sign(SigningKey.new(IntegrationsContract.key!("server_key").seed), message) ==
             signature
  end

  describe "the connect pass" do
    setup do
      %{seed: seed, public_key: public_key} = IntegrationsContract.key!("server_key")
      %{fixture: signed("connect-pass"), seed: seed, public_key: public_key}
    end

    test "the core issues the contract's pass byte for byte, for another adapter id", ctx do
      payload = Jason.decode!(ctx.fixture["payload"])
      {:ok, nonce} = Ed25519.decode(payload["nonce"], 16)
      {:ok, expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])
      now = DateTime.add(expires_at, -ConnectPass.validity(), :second)

      assert {:ok, pass} =
               ConnectPass.issue(payload["adapter_id"],
                 key: SigningKey.new(ctx.seed),
                 now: now,
                 nonce: nonce
               )

      assert pass == ctx.fixture["pass"]
      assert payload["adapter_id"] == "na_f1xt0re000000000"

      assert IntegrationsContract.validate(
               IntegrationsContract.schema!("connect-pass.schema.json"),
               payload
             ) == :ok

      assert {:ok, %{adapter_id: "na_f1xt0re000000000", nonce: ^nonce}} =
               ConnectPass.verify(pass, ctx.public_key, now: now)
    end

    test "the tampered pass, and the pass under another key, do not verify", ctx do
      payload = Jason.decode!(ctx.fixture["payload"])
      {:ok, expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])
      now = DateTime.add(expires_at, -60, :second)

      assert ConnectPass.verify(ctx.fixture["tampered"], ctx.public_key, now: now) == :error

      assert ConnectPass.verify(ctx.fixture["pass"], SigningKey.public_key(), now: now) ==
               :error

      assert ConnectPass.verify(ctx.fixture["pass"], ctx.public_key, now: expires_at) == :error
    end
  end
end
