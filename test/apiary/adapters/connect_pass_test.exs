defmodule Apiary.Adapters.ConnectPassTest do
  use ExUnit.Case, async: true

  alias Apiary.Adapters.ConnectPass
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Runs.RunKey
  alias Apiary.SigningKey

  # The known answer: the contract's fixture signing seed, bytes 65 to 96, which every
  # instance refuses as its signing key, so the published vector signs as no instance.
  @seed :binary.list_to_bin(Enum.to_list(65..96))
  @fixture SigningKey.new(@seed)
  @adapter "na_0123456789abcdef"
  @nonce :binary.list_to_bin(Enum.to_list(0..15))
  @now ~U[2026-10-15 12:00:00Z]

  @known_public_key "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc"
  @known_payload ~s({"version":1,"adapter_id":"na_0123456789abcdef",) <>
                   ~s("nonce":"AAECAwQFBgcICQoLDA0ODw","expires_at":"2026-10-15T12:15:00Z"})
  @known_pass "eyJ2ZXJzaW9uIjoxLCJhZGFwdGVyX2lkIjoibmFfMDEyMzQ1Njc4OWFiY2RlZiIsIm5vbmNlIjoi" <>
                "QUFFQ0F3UUZCZ2NJQ1FvTERBME9EdyIsImV4cGlyZXNfYXQiOiIyMDI2LTEwLTE1VDEyOjE1OjAwWiJ9" <>
                ".5BTGXY-IV8t2FmJxbJLf93Xat_IQM7CKR3ipuoZ_0bqE4G7bsPPgh57h-_ZAXAG3B2ShnvUyVpNAYW78dIyABw"

  @key SigningKey.new(:crypto.strong_rand_bytes(32))
  @other SigningKey.new(:crypto.strong_rand_bytes(32))

  defp public_key(key \\ @key), do: SigningKey.public_key(key)

  # A pass over `payload` whose signature covers `message`, under `key`.
  defp signed(payload, message, key \\ @key),
    do: Ed25519.encode(payload) <> "." <> Ed25519.encode(SigningKey.sign(key, message))

  defp pass!(opts \\ []) do
    {:ok, pass} = ConnectPass.issue(@adapter, Keyword.merge([key: @key, now: @now], opts))
    pass
  end

  defp payload!(pass) do
    [encoded, _signature] = String.split(pass, ".")
    Base.url_decode64!(encoded, padding: false)
  end

  describe "the known answer" do
    test "a fixed seed, nonce and time make the published pass, byte for byte" do
      assert SigningKey.check_seed(@seed) == {:error, :fixture}
      assert Ed25519.encode(SigningKey.public_key(@fixture)) == @known_public_key

      assert Base.encode16(@seed, case: :lower) ==
               "4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60"

      assert {:ok, @known_pass} =
               ConnectPass.issue(@adapter, key: @fixture, now: @now, nonce: @nonce)

      assert payload!(@known_pass) == @known_payload

      assert SignedMessage.connect_pass(@known_payload) ==
               "qory-connect-ed25519-v1\n" <> @known_payload

      {:ok, public_key} = Ed25519.decode(@known_public_key, 32)

      assert ConnectPass.verify(@known_pass, public_key, now: @now) ==
               {:ok, %{adapter_id: @adapter, nonce: @nonce, expires_at: ~U[2026-10-15 12:15:00Z]}}
    end

    test "the time is taken to the second" do
      assert {:ok, @known_pass} =
               ConnectPass.issue(@adapter,
                 key: @fixture,
                 now: ~U[2026-10-15 12:00:00.999999Z],
                 nonce: @nonce
               )
    end
  end

  describe "issue/2" do
    test "the payload's members are in their order, with no whitespace" do
      payload = payload!(pass!())

      assert %Jason.OrderedObject{values: values} =
               Jason.decode!(payload, objects: :ordered_objects)

      assert Enum.map(values, &elem(&1, 0)) == ~w(version adapter_id nonce expires_at)
      refute payload =~ ~r/\s/
      assert Jason.encode!(Jason.decode!(payload, objects: :ordered_objects)) == payload
    end

    test "the nonce is 16 fresh random bytes, unpadded base64url, and the pass expires in 900 s" do
      first = Jason.decode!(payload!(pass!()))
      second = Jason.decode!(payload!(pass!()))

      assert {:ok, nonce} = Ed25519.decode(first["nonce"], 16)
      assert byte_size(nonce) == 16
      assert String.length(first["nonce"]) == 22
      refute first["nonce"] == second["nonce"]
      assert first["expires_at"] == "2026-10-15T12:15:00Z"
      assert ConnectPass.validity() == 900
    end

    test "both parts are base64url without padding, and the pass is within its bound" do
      pass = pass!()
      assert [payload, signature] = String.split(pass, ".")
      assert pass =~ ~r/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{86}\z/
      assert {:ok, _signature} = Ed25519.decode(signature, 64)
      assert Ed25519.encode(Base.url_decode64!(payload, padding: false)) == payload
      assert String.length(pass) <= ConnectPass.max_length()
      assert ConnectPass.max_length() == 1024
    end

    test "signs under the instance's key unless given one" do
      {:ok, pass} = ConnectPass.issue(@adapter)
      assert {:ok, %{adapter_id: @adapter}} = ConnectPass.verify(pass, SigningKey.public_key())
    end

    test "refuses anything but an adapter's public id, and a nonce that is not 16 bytes" do
      for id <- [
            nil,
            "",
            "nd_0123456789abcdef",
            "na_0123456789ABCDEF",
            "na_0123456789abcdeu",
            "na_0123456789abcde",
            ~s(na_0123456789abc"e)
          ] do
        assert ConnectPass.issue(id, key: @key) == {:error, :invalid}, inspect(id)
      end

      for nonce <- [<<>>, <<0::120>>, <<0::136>>, nil] do
        assert ConnectPass.issue(@adapter, key: @key, nonce: nonce) == {:error, :invalid}
      end

      assert ConnectPass.issue(@adapter, key: @key, now: "2026-10-15T12:00:00Z") ==
               {:error, :invalid}
    end
  end

  describe "verify/3" do
    test "reads a pass back under the key that signed it, and no other" do
      pass = pass!()

      assert {:ok, %{adapter_id: @adapter, expires_at: expires_at}} =
               ConnectPass.verify(pass, public_key(), now: @now)

      assert expires_at == DateTime.add(@now, 900, :second)
      assert ConnectPass.verify(pass, public_key(@other), now: @now) == :error
      assert ConnectPass.verify(pass, SigningKey.fingerprint(@key), now: @now) == :error
      assert ConnectPass.verify(pass, nil, now: @now) == :error
    end

    test "a pass is good until its expires_at, and not from then on" do
      pass = pass!()
      assert {:ok, _} = ConnectPass.verify(pass, public_key(), now: ~U[2026-10-15 12:14:59Z])
      assert ConnectPass.verify(pass, public_key(), now: ~U[2026-10-15 12:15:00Z]) == :error
      assert ConnectPass.verify(pass, public_key(), now: ~U[2026-10-16 12:00:00Z]) == :error
      # Expiring more than 900 s after now: not a pass made now.
      assert ConnectPass.verify(pass, public_key(), now: ~U[2026-10-15 11:59:59Z]) == :error
    end

    test "anything but the pass, as issued, is refused" do
      pass = pass!()
      payload = payload!(pass)
      [encoded_payload, encoded_signature] = String.split(pass, ".")

      refused = [
        nil,
        "",
        encoded_payload,
        encoded_payload <> ".",
        "." <> encoded_signature,
        pass <> "." <> encoded_signature,
        encoded_payload <> "=." <> encoded_signature,
        encoded_payload <> "." <> encoded_signature <> "==",
        encoded_payload <> "." <> String.replace(encoded_signature, ~r/\A./, "+"),
        encoded_payload <> "." <> String.slice(encoded_signature, 1..-1//1),
        Ed25519.encode(payload <> " ") <> "." <> encoded_signature,
        pass <> String.duplicate("A", ConnectPass.max_length()),
        signed(payload, SignedMessage.connect_pass(payload), @other)
      ]

      for candidate <- refused,
          do: assert(ConnectPass.verify(candidate, public_key(), now: @now) == :error)
    end

    test "a payload that does not read exactly as issued is refused, however it is signed" do
      payload = payload!(pass!())
      map = Jason.decode!(payload)

      changed = [
        Jason.encode!(Map.put(map, "extra", 1)),
        Jason.encode!(Map.delete(map, "nonce")),
        Jason.encode!(Map.put(map, "version", 2)),
        Jason.encode!(Map.put(map, "version", "1")),
        Jason.encode!(Map.put(map, "adapter_id", "nd_0123456789abcdef")),
        Jason.encode!(Map.put(map, "nonce", Ed25519.encode(<<0::120>>))),
        Jason.encode!(Map.put(map, "nonce", Ed25519.encode(<<0::128>>) <> "==")),
        Jason.encode!(Map.put(map, "expires_at", "2026-10-15T12:15:00.5Z")),
        Jason.encode!(Map.put(map, "expires_at", "2026-10-15T12:15:00+00:00")),
        Jason.encode!(Map.put(map, "expires_at", 1_791_634_500)),
        # The members out of their order, or with whitespace: the bytes are not those
        # issue/2 writes.
        ~s({"adapter_id":"#{map["adapter_id"]}","version":1,"nonce":"#{map["nonce"]}",) <>
          ~s("expires_at":"#{map["expires_at"]}"}),
        String.replace(payload, ",", ", "),
        payload <> "\n",
        # A member twice, the last one counting in a lenient parser.
        String.replace(payload, ~s("version":1,), ~s("version":1,"version":1,)),
        "not json",
        "[]"
      ]

      for bytes <- changed do
        assert ConnectPass.verify(signed(bytes, SignedMessage.connect_pass(bytes)), public_key(),
                 now: @now
               ) == :error,
               bytes
      end

      # The same bytes, signed again, verify: the refusals above are the payload's.
      assert {:ok, _} =
               ConnectPass.verify(
                 signed(payload, SignedMessage.connect_pass(payload)),
                 public_key(),
                 now: @now
               )
    end
  end

  # What the documentation would say of the connect pass, were it to name it.
  @undocumented ~r/connect[ _-]pass|qory-connect|adapter/i

  describe "the generated documentation" do
    # Every instance serves the module reference at /docs, so neither module documents the
    # connect pass there.
    test "leaves the connect pass out" do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(ConnectPass)

      for {{kind, _name, _arity}, _anno, _signature, doc, _meta} <- docs,
          kind != :type,
          do: assert(doc == :hidden)

      assert {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, docs} =
               Code.fetch_docs(SignedMessage)

      refute moduledoc =~ @undocumented

      assert [{_key, _anno, _signature, :hidden, _meta}] =
               for(
                 {{:function, :connect_pass, 1}, _, _, _, _} = entry <- docs,
                 do: entry
               )

      for {{_kind, _name, _arity}, _anno, _signature, %{"en" => doc}, _meta} <- docs,
          do: refute(doc =~ @undocumented)
    end
  end

  describe "domain separation" do
    test "a signature over any other message of the contract is no connect pass" do
      payload = payload!(pass!())

      for message <- [
            payload,
            SignedMessage.run_key(payload),
            SignedMessage.answer(200, "", payload, nil, nil),
            SignedMessage.enrolment_answer(200, "", payload),
            SignedMessage.request("ak_0000000000000000", nil, "POST", "/", payload),
            "qory-connect-ed25519-v2\n" <> payload,
            "qory-connect-ed25519-v1" <> payload
          ] do
        assert ConnectPass.verify(signed(payload, message), public_key(), now: @now) == :error
      end
    end

    test "a connect pass's signature verifies as no other message of the contract" do
      pass = pass!()
      payload = payload!(pass)
      [_encoded, encoded_signature] = String.split(pass, ".")
      {:ok, signature} = Ed25519.decode(encoded_signature, 64)

      assert Ed25519.verify(SignedMessage.connect_pass(payload), signature, public_key())

      for message <- [
            payload,
            SignedMessage.run_key(payload),
            SignedMessage.answer(200, "", payload, nil, nil),
            SignedMessage.enrolment_answer(200, "", payload)
          ] do
        refute Ed25519.verify(message, signature, public_key())
      end

      # Read as a run key, under the same key, it is refused.
      assert RunKey.verify("qrk_" <> pass, [@key]) == :error
    end

    test "a run key is no connect pass, under the key that signed it" do
      {:ok, run_key, _payload} =
        RunKey.issue(
          %{
            run_id: "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d",
            workspace: "ws_0000000000000000",
            node_id: "np_0000000000000000",
            gateway: "ng_0000000000000000",
            gateway_url: "https://gateway.example:8443",
            gateway_public_keys: [:crypto.strong_rand_bytes(32)],
            instance_id: "i_build-01",
            issued: @now,
            attach_by: DateTime.add(@now, 600, :second)
          },
          @key
        )

      "qrk_" <> rest = run_key
      assert ConnectPass.verify(rest, public_key(), now: @now) == :error
      assert ConnectPass.verify(run_key, public_key(), now: @now) == :error
    end

    test "the connect pass's domain line is distinct from every other, and no prefix of one" do
      tag = "qory-connect-ed25519-v1\n"
      assert SignedMessage.connect_pass("") == tag

      for other <- [
            SignedMessage.run_key(""),
            SignedMessage.answer(200, "", "", nil, nil),
            SignedMessage.enrolment_answer(200, "", ""),
            SignedMessage.enrolment("", "", "", 0),
            SignedMessage.request("", nil, "GET", "", "")
          ] do
        refute String.starts_with?(other, tag)
        [other_tag | _] = String.split(other, "\n")
        refute String.starts_with?(tag, other_tag <> "\n")
      end
    end
  end
end
