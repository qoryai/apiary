defmodule Apiary.Adapters.ReturnTokenTest do
  use ExUnit.Case, async: true

  alias Apiary.Adapters.{ConnectPass, ReturnToken}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Runs.RunKey
  alias Apiary.SigningKey

  # The known answer: the seed of the server key in the contract's fixture keys, bytes 65
  # to 96, standing in as an adapter's key. The contract's vector, signed under the
  # access key of those keys, is checked by `Apiary.Adapters.ContractFixturesTest`.
  @seed :binary.list_to_bin(Enum.to_list(65..96))
  @connection "ac_0123456789abcdef"
  @nonce :binary.list_to_bin(Enum.to_list(0..15))
  @now ~U[2026-10-15 12:00:00Z]

  @known_public_key "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc"
  @known_linked_payload ~s({"version":1,"connection_id":"ac_0123456789abcdef",) <>
                          ~s("nonce":"AAECAwQFBgcICQoLDA0ODw","outcome":"linked",) <>
                          ~s("expires_at":"2026-10-15T12:05:00Z"})
  @known_linked "eyJ2ZXJzaW9uIjoxLCJjb25uZWN0aW9uX2lkIjoiYWNfMDEyMzQ1Njc4OWFiY2RlZiIsIm5vbmNl" <>
                  "IjoiQUFFQ0F3UUZCZ2NJQ1FvTERBME9EdyIsIm91dGNvbWUiOiJsaW5rZWQiLCJleHBpcmVzX2F0" <>
                  "IjoiMjAyNi0xMC0xNVQxMjowNTowMFoifQ" <>
                  ".kdXYwr1uileSg5wExwONzGk4aeCe7fHpTcbO17kcDGm8zxtY4-1cNrTGF9UU0gqiU_7JBGfjXQq2g3zR0I9FCQ"
  @known_refused_payload ~s({"version":1,"connection_id":"ac_0123456789abcdef",) <>
                           ~s("nonce":"AAECAwQFBgcICQoLDA0ODw","outcome":"refused",) <>
                           ~s("reason":"grant_taken","expires_at":"2026-10-15T12:05:00Z"})
  @known_refused "eyJ2ZXJzaW9uIjoxLCJjb25uZWN0aW9uX2lkIjoiYWNfMDEyMzQ1Njc4OWFiY2RlZiIsIm5vbmNl" <>
                   "IjoiQUFFQ0F3UUZCZ2NJQ1FvTERBME9EdyIsIm91dGNvbWUiOiJyZWZ1c2VkIiwicmVhc29uIjoi" <>
                   "Z3JhbnRfdGFrZW4iLCJleHBpcmVzX2F0IjoiMjAyNi0xMC0xNVQxMjowNTowMFoifQ" <>
                   ".Fyds_wMZWaHn2LFz35y8CFnBdnAmCBZ-EwM-KkRJwvQG0Nyf3CqkD7lNDTgB-_B8Wnf79JILNUtlqIltWJtaBQ"

  defp pair do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, secret: secret}
  end

  defp sign(message, secret), do: :crypto.sign(:eddsa, :none, message, [secret, :ed25519])

  # A return over `payload` whose signature covers `message`, under `secret`.
  defp signed(payload, message, secret),
    do: Ed25519.encode(payload) <> "." <> Ed25519.encode(sign(message, secret))

  defp token(payload, secret),
    do: signed(payload, SignedMessage.connect_return(payload), secret)

  defp members(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "connection_id" => @connection,
        "nonce" => Ed25519.encode(@nonce),
        "outcome" => "linked",
        "expires_at" => "2026-10-15T12:05:00Z"
      },
      overrides
    )
  end

  describe "the known answer" do
    test "the fixture key's returns read back, linked and refused" do
      public_key = SigningKey.public_key(SigningKey.new(@seed))
      assert Ed25519.encode(public_key) == @known_public_key

      assert @known_linked == token(@known_linked_payload, @seed)
      assert @known_refused == token(@known_refused_payload, @seed)

      assert SignedMessage.connect_return(@known_linked_payload) ==
               "qory-connect-return-ed25519-v1\n" <> @known_linked_payload

      assert ReturnToken.verify(@known_linked, [public_key]) ==
               {:ok,
                %{
                  connection_id: @connection,
                  nonce: @nonce,
                  outcome: :linked,
                  reason: nil,
                  expires_at: ~U[2026-10-15 12:05:00Z]
                }}

      assert {:ok, %{outcome: :refused, reason: :grant_taken}} =
               ReturnToken.verify(@known_refused, [public_key])

      assert String.length(@known_linked) == 273
      assert String.length(@known_refused) == 305
    end
  end

  describe "verify/2" do
    test "reads each outcome, its members in any order, under any key given" do
      %{public: public, secret: secret} = pair()
      other = pair()

      for {outcome, extra, expected} <- [
            {"linked", %{}, {:linked, nil}},
            {"cancelled", %{}, {:cancelled, nil}}
            | for(
                reason <- ReturnToken.reasons(),
                do: {"refused", %{"reason" => Atom.to_string(reason)}, {:refused, reason}}
              )
          ] do
        payload = Jason.encode!(members(Map.merge(%{"outcome" => outcome}, extra)))
        {outcome_atom, reason} = expected

        assert {:ok, %{outcome: ^outcome_atom, reason: ^reason}} =
                 ReturnToken.verify(token(payload, secret), [other.public, public])
      end

      reversed =
        ~s({"expires_at":"2026-10-15T12:05:00Z","outcome":"cancelled",) <>
          ~s("nonce":"#{Ed25519.encode(@nonce)}","connection_id":"#{@connection}","version":1})

      assert {:ok, %{outcome: :cancelled}} = ReturnToken.verify(token(reversed, secret), [public])

      assert ReturnToken.reasons() ==
               ~w(person_not_permitted grant_taken grant_not_confirmed
                  grant_suspended permission_missing pass_expired source_unavailable)a
    end

    test "a return under a key not given, or no key, is refused" do
      %{secret: secret} = pair()
      other = pair()
      token = token(Jason.encode!(members()), secret)

      assert ReturnToken.verify(token, [other.public]) == :error
      assert ReturnToken.verify(token, []) == :error
      assert ReturnToken.verify(token, [nil, "short"]) == :error
      assert ReturnToken.verify(token, nil) == :error
    end

    test "anything but a return, as its form has it, is refused" do
      %{public: public, secret: secret} = pair()
      payload = Jason.encode!(members())
      token = token(payload, secret)
      [encoded_payload, encoded_signature] = String.split(token, ".")

      refused = [
        nil,
        "",
        123,
        encoded_payload,
        encoded_payload <> ".",
        "." <> encoded_signature,
        token <> "." <> encoded_signature,
        encoded_payload <> "=." <> encoded_signature,
        encoded_payload <> "." <> encoded_signature <> "==",
        encoded_payload <> "." <> String.replace(encoded_signature, ~r/\A./, "+"),
        encoded_payload <> "." <> String.slice(encoded_signature, 1..-1//1),
        Ed25519.encode(payload <> " ") <> "." <> encoded_signature,
        token <> String.duplicate("A", ReturnToken.max_length())
      ]

      for candidate <- refused, do: assert(ReturnToken.verify(candidate, [public]) == :error)
      assert ReturnToken.max_length() == 1024
    end

    test "a token longer than 1,024 characters is refused, whatever it holds" do
      %{public: public, secret: secret} = pair()
      padding = String.duplicate("x", 900)
      payload = Jason.encode!(members(%{"connection_id" => @connection <> padding}))
      assert String.length(token(payload, secret)) > 1024
      assert ReturnToken.verify(token(payload, secret), [public]) == :error
    end

    test "a payload against its rules is refused, however it is signed" do
      %{public: public, secret: secret} = pair()
      map = members()

      changed = [
        Jason.encode!(Map.put(map, "extra", 1)),
        Jason.encode!(Map.delete(map, "nonce")),
        Jason.encode!(Map.delete(map, "connection_id")),
        Jason.encode!(Map.delete(map, "outcome")),
        Jason.encode!(Map.delete(map, "expires_at")),
        Jason.encode!(Map.delete(map, "version")),
        Jason.encode!(Map.put(map, "version", 2)),
        Jason.encode!(Map.put(map, "version", "1")),
        Jason.encode!(Map.put(map, "connection_id", "na_0123456789abcdef")),
        Jason.encode!(Map.put(map, "connection_id", "ac_0123456789ABCDEF")),
        Jason.encode!(Map.put(map, "nonce", Ed25519.encode(<<0::120>>))),
        Jason.encode!(Map.put(map, "nonce", Ed25519.encode(<<0::128>>) <> "==")),
        Jason.encode!(Map.put(map, "outcome", "unlinked")),
        Jason.encode!(Map.put(map, "outcome", "LINKED")),
        # A reason with an outcome that takes none, a refusal without one, or with one
        # not on the list.
        Jason.encode!(Map.put(map, "reason", "person_not_permitted")),
        Jason.encode!(Map.put(map, "outcome", "refused")),
        Jason.encode!(Map.merge(map, %{"outcome" => "refused", "reason" => "source_gone"})),
        Jason.encode!(Map.merge(map, %{"outcome" => "refused", "reason" => nil})),
        Jason.encode!(
          Map.merge(map, %{"outcome" => "refused", "reason" => ["person_not_permitted"]})
        ),
        Jason.encode!(Map.put(map, "expires_at", "2026-10-15T12:05:00.5Z")),
        Jason.encode!(Map.put(map, "expires_at", "2026-10-15T12:05:00+00:00")),
        Jason.encode!(Map.put(map, "expires_at", 1_791_634_500)),
        # A member twice, the last one counting in a lenient parser.
        String.replace(Jason.encode!(map), ~s("version":1), ~s("version":1,"version":1)),
        String.replace(
          Jason.encode!(map),
          ~s("outcome":"linked"),
          ~s("outcome":"cancelled","outcome":"linked")
        ),
        "not json",
        "[]",
        "null"
      ]

      for bytes <- changed do
        assert ReturnToken.verify(token(bytes, secret), [public]) == :error, bytes
      end

      assert {:ok, _} = ReturnToken.verify(token(Jason.encode!(map), secret), [public])
    end
  end

  describe "good_at?/2" do
    test "good until its expires_at, and expiring no more than 300 s after now" do
      %{public: public, secret: secret} = pair()
      {:ok, return} = ReturnToken.verify(token(Jason.encode!(members()), secret), [public])

      assert ReturnToken.validity() == 300
      assert ReturnToken.good_at?(return, @now)
      assert ReturnToken.good_at?(return, ~U[2026-10-15 12:04:59Z])
      refute ReturnToken.good_at?(return, ~U[2026-10-15 12:05:00Z])
      refute ReturnToken.good_at?(return, ~U[2026-10-16 12:00:00Z])
      refute ReturnToken.good_at?(return, ~U[2026-10-15 11:59:59Z])
      refute ReturnToken.good_at?(%{}, @now)
    end
  end

  # What the documentation would say of the return, were it to name it.
  @undocumented ~r/connect[ _-]return|qory-connect|return token|adapter/i

  describe "the generated documentation" do
    test "leaves the return out" do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(ReturnToken)

      for {{kind, _name, _arity}, _anno, _signature, doc, _meta} <- docs,
          kind != :type,
          do: assert(doc == :hidden)

      assert {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, docs} =
               Code.fetch_docs(SignedMessage)

      refute moduledoc =~ @undocumented

      assert [{_key, _anno, _signature, :hidden, _meta}] =
               for(
                 {{:function, :connect_return, 1}, _, _, _, _} = entry <- docs,
                 do: entry
               )
    end
  end

  describe "domain separation" do
    test "a signature over any other message of the contract is no return" do
      %{public: public, secret: secret} = pair()
      payload = Jason.encode!(members())

      for message <- [
            payload,
            SignedMessage.connect_pass(payload),
            SignedMessage.run_key(payload),
            SignedMessage.answer(200, "", payload, nil, nil),
            SignedMessage.enrolment_answer(200, "", payload),
            SignedMessage.request("ak_0000000000000000", nil, "POST", "/", payload),
            "qory-connect-return-ed25519-v2\n" <> payload,
            "qory-connect-return-ed25519-v1" <> payload
          ] do
        assert ReturnToken.verify(signed(payload, message, secret), [public]) == :error
      end
    end

    test "a return's signature verifies as no other message of the contract" do
      %{public: public, secret: secret} = pair()
      payload = Jason.encode!(members())
      signature = sign(SignedMessage.connect_return(payload), secret)

      assert Ed25519.verify(SignedMessage.connect_return(payload), signature, public)

      for message <- [
            payload,
            SignedMessage.connect_pass(payload),
            SignedMessage.run_key(payload),
            SignedMessage.answer(200, "", payload, nil, nil),
            SignedMessage.enrolment_answer(200, "", payload),
            SignedMessage.request("ak_0000000000000000", nil, "POST", "/", payload)
          ] do
        refute Ed25519.verify(message, signature, public)
      end
    end

    test "a return is no connect pass and no run key under the same key, and the reverse" do
      seed = :crypto.strong_rand_bytes(32)
      key = SigningKey.new(seed)
      public = SigningKey.public_key(key)
      return = token(Jason.encode!(members()), seed)

      # A return read as a connect pass or a run key, under the key that signed it.
      assert ConnectPass.verify(return, public, now: @now) == :error
      assert RunKey.verify("qrk_" <> return, [key]) == :error

      # A connect pass, and a run key, read as a return under the key that signed them.
      {:ok, pass} =
        ConnectPass.issue("na_0123456789abcdef", @connection, key: key, now: @now, nonce: @nonce)

      assert ReturnToken.verify(pass, [public]) == :error

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
          key
        )

      "qrk_" <> rest = run_key
      assert ReturnToken.verify(rest, [public]) == :error
      assert ReturnToken.verify(run_key, [public]) == :error
    end

    test "the return's domain line is distinct from every other, and no prefix of one" do
      tag = "qory-connect-return-ed25519-v1\n"
      assert SignedMessage.connect_return("") == tag

      for other <- [
            SignedMessage.connect_pass(""),
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
