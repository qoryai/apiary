defmodule Apiary.Runs.RunKeyTest do
  use ExUnit.Case, async: true

  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Runs.RunKey
  alias Apiary.SigningKey

  @key SigningKey.new(:crypto.strong_rand_bytes(32))
  @other SigningKey.new(:crypto.strong_rand_bytes(32))

  defp grant(attrs \\ %{}) do
    Map.merge(
      %{
        run_id: "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d",
        workspace: "ws_0000000000000000",
        node_id: "np_0000000000000000",
        gateway: "ng_0000000000000000",
        gateway_url: "https://gateway.example:8443",
        gateway_public_keys: [:crypto.strong_rand_bytes(32)],
        instance_id: "i_build-01",
        issued: ~U[2026-10-11 12:00:00.123456Z],
        attach_by: ~U[2026-10-11 12:10:00Z]
      },
      Map.new(attrs)
    )
  end

  # A run key over `payload`, signed under `key`, whatever the payload holds.
  defp signed(payload, key \\ @key) do
    "qrk_" <>
      Ed25519.encode(payload) <>
      "." <> Ed25519.encode(SigningKey.sign(key, SignedMessage.run_key(payload)))
  end

  test "a run key is made and read back: its grant, to the second, and its payload's bytes" do
    grant = grant()
    assert {:ok, "qrk_" <> _ = run_key, payload} = RunKey.issue(grant, @key)
    assert String.length(run_key) <= RunKey.max_length()

    assert {:ok, read, ^payload} = RunKey.verify(run_key, [@key])
    assert read == %{grant | issued: ~U[2026-10-11 12:00:00Z]}

    # The members in their order, the signer the key's fingerprint.
    assert payload |> Jason.decode!(objects: :ordered_objects) |> Map.get(:values) |> length() ==
             11

    assert Jason.decode!(payload)["signer"] == SigningKey.fingerprint(@key)
    assert RunKey.encode(payload, @key) == run_key
  end

  test "two gateway keys are named, oldest first" do
    keys = [:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32)]
    {:ok, run_key, _payload} = RunKey.issue(grant(gateway_public_keys: keys), @key)
    assert {:ok, %{gateway_public_keys: ^keys}, _payload} = RunKey.verify(run_key, [@key])
  end

  test "a grant that breaks a rule of the payload makes no run key" do
    for attrs <- [
          [gateway_url: "http://127.0.0.1:8443"],
          [gateway_url: "https://gateway.example/path"],
          [gateway_public_keys: []],
          [gateway_public_keys: List.duplicate(<<1::256>>, 2)],
          [node_id: "ng_0000000000000000"],
          [instance_id: ""]
        ] do
      assert RunKey.issue(grant(attrs), @key) == {:error, :invalid}, inspect(attrs)
    end

    assert RunKey.issue(grant(gateway_url: "https://" <> String.duplicate("a", 1600)), @key) ==
             {:error, :too_long}
  end

  test "anything but a run key the given keys signed is refused" do
    {:ok, run_key, payload} = RunKey.issue(grant(), @key)
    "qrk_" <> rest = run_key
    [encoded_payload, encoded_signature] = String.split(rest, ".")

    refused = [
      nil,
      "",
      rest,
      "qrk_" <> encoded_payload,
      "qrk_" <> encoded_payload <> "." <> encoded_signature <> "." <> encoded_signature,
      "qrk_" <> encoded_payload <> "=." <> encoded_signature,
      "qrk_" <> Ed25519.encode(payload <> " ") <> "." <> encoded_signature,
      "qrk_" <> encoded_payload <> "." <> String.slice(encoded_signature, 1..-1//1),
      run_key <> String.duplicate("A", RunKey.max_length()),
      signed(payload, @other)
    ]

    for candidate <- refused, do: assert(RunKey.verify(candidate, [@key]) == :error)

    # The key `signer` names is the one it is verified under, among those given.
    {:ok, by_other, _payload} = RunKey.issue(grant(), @other)
    assert RunKey.verify(by_other, [@key]) == :error
    assert {:ok, _grant, _payload} = RunKey.verify(by_other, [@key, @other])
    assert RunKey.verify(run_key, []) == :error
  end

  test "a payload that does not read is refused, however it is signed" do
    {:ok, _run_key, payload} = RunKey.issue(grant(), @key)
    map = Jason.decode!(payload)

    for change <- [
          &Map.put(&1, "extra", 1),
          &Map.delete(&1, "attach_by"),
          &Map.put(&1, "version", 2),
          &Map.put(&1, "issued", "2026-10-11T12:00:00.5Z"),
          &Map.put(&1, "run_id", String.upcase(&1["run_id"])),
          &Map.put(&1, "gateway_url", "http://gateway.example"),
          &Map.put(&1, "gateway_public_key", [])
        ] do
      assert RunKey.verify(signed(Jason.encode!(change.(map))), [@key]) == :error
    end

    assert RunKey.verify(signed("not json"), [@key]) == :error
  end
end
