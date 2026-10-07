defmodule Apiary.Contract.EnrolmentTest do
  use ExUnit.Case, async: true

  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}

  # The contract's fixtures are replayed in test/contract/enrolment_fixtures_test.exs;
  # these hold without the runner's contract directory.

  @fingerprint "uoES-kuj1vk0sq0qoGlmAg"
  @code "qec_F1XT0RE0000000000000000000." <> @fingerprint

  defp request(fields \\ %{}) do
    {public_key, secret} = :crypto.generate_key(:eddsa, :ed25519)
    encoded = Ed25519.encode(public_key)
    message = SignedMessage.enrolment(@code, encoded, "build-01", 1_700_000_000)
    proof = :crypto.sign(:eddsa, :none, message, [secret, :ed25519]) |> Ed25519.encode()

    body =
      %{
        "version" => 1,
        "code" => @code,
        "name" => "build-01",
        "public_key" => encoded,
        "timestamp" => 1_700_000_000,
        "proof" => proof
      }
      |> Map.merge(fields)

    {body, public_key}
  end

  describe "decode/1" do
    test "reads a request, the code split at its first dot" do
      {body, public_key} = request()
      assert {:ok, request} = Enrolment.decode(Jason.encode!(body))
      assert request.code == @code
      assert request.code_head == "qec_F1XT0RE0000000000000000000"
      assert request.fingerprints == [@fingerprint]
      assert Enrolment.proof_verifies?(request, public_key)
    end

    test "a body that is not a JSON object is refused with no names" do
      for body <- ["", "[]", "1", "nul", "{\"version\":1", <<0xFF>>, nil],
          do: assert(Enrolment.decode(body) == {:error, []})
    end

    test "a member twice is refused, the last of them not taken" do
      {body, _public_key} = request()
      json = Jason.encode!(body)

      twice =
        String.replace(json, "{", ~s({"code":"qec_00000000000000000000000000.#{@fingerprint}",),
          global: false
        )

      assert Enrolment.decode(twice) == {:error, ["code"]}
    end

    test "a proof or a key not in strict base64url is refused" do
      {body, _public_key} = request()
      # The last character of a 32-byte key carries bits past the last byte: refused.
      key = String.slice(body["public_key"], 0, 42) <> "B"

      assert Enrolment.decode(Jason.encode!(%{body | "public_key" => key})) ==
               {:error, ["public_key"]}

      proof = String.slice(body["proof"], 0, 85) <> "B"
      assert Enrolment.decode(Jason.encode!(%{body | "proof" => proof})) == {:error, ["proof"]}
    end

    test "a timestamp at 2^53 − 1 reads; with a fraction or an exponent it does not" do
      {body, _public_key} = request(%{"timestamp" => Integer.pow(2, 53) - 1})
      assert {:ok, _request} = Enrolment.decode(Jason.encode!(body))

      json = Jason.encode!(%{body | "timestamp" => 0})

      for written <- ["1.0", "1e3", "1E3", "0.5"] do
        assert Enrolment.decode(
                 String.replace(json, ~s("timestamp":0), ~s("timestamp":#{written}))
               ) ==
                 {:error, ["timestamp"]}
      end
    end

    test "inspect shows neither the code nor the proof" do
      {body, _public_key} = request()
      {:ok, request} = Enrolment.decode(Jason.encode!(body))
      shown = inspect(request)
      refute shown =~ "F1XT0RE"
      refute shown =~ body["proof"]
      assert shown =~ "build-01"
    end
  end

  test "answer_body/1 and refusal_body/2 keep the contract's order of members" do
    keys = [%{"alg" => "ed25519", "public_key" => "k"}]

    assert Enrolment.answer_body(%{
             access_key_id: "ak_0000000000000000",
             node_id: "np_0000000000000000",
             node_kind: :pool,
             approved: true,
             stored_secrets: true,
             apiary_public_key: keys
           }) ==
             ~s({"version":1,"access_key_id":"ak_0000000000000000","node_id":"np_0000000000000000",) <>
               ~s("node_kind":"pool","approved":true,"stored_secrets":true,) <>
               ~s("apiary_public_key":[{"alg":"ed25519","public_key":"k"}]})

    assert Enrolment.refusal_body(:key_limit, keys) ==
             ~s({"error":"key_limit","apiary_public_key":[{"alg":"ed25519","public_key":"k"}]})
  end
end
