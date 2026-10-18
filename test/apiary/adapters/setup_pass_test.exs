defmodule Apiary.Adapters.SetupPassTest do
  # The setup pass: its form, issued and read back (`issue/2`, `verify/3`), its time, what
  # is refused, that the generated documentation leaves it out, and that it verifies as no
  # other signed message of the contract, a connect pass's above all, and the reverse. The
  # contract's signed fixture is `Apiary.Adapters.ContractFixturesTest`'s.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.{ConnectPass, SetupPass}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.SigningKey

  @adapter "na_0123456789abcdef"
  @now ~U[2026-10-15 12:00:00Z]

  @key SigningKey.new(:crypto.strong_rand_bytes(32))
  @other SigningKey.new(:crypto.strong_rand_bytes(32))

  defp public_key(key \\ @key), do: SigningKey.public_key(key)

  # A pass over `payload` whose signature covers `message`, under `key`.
  defp signed(payload, message, key \\ @key),
    do: Ed25519.encode(payload) <> "." <> Ed25519.encode(SigningKey.sign(key, message))

  defp pass!(opts \\ []) do
    {:ok, pass} = SetupPass.issue(@adapter, Keyword.merge([key: @key, now: @now], opts))
    pass
  end

  defp payload!(pass) do
    [encoded, _signature] = String.split(pass, ".")
    Base.url_decode64!(encoded, padding: false)
  end

  describe "issue/2" do
    test "the payload's members are in their order, with no whitespace" do
      nonce = :binary.list_to_bin(Enum.to_list(0..15))

      assert payload!(pass!(nonce: nonce)) ==
               ~s({"version":1,"adapter_id":"na_0123456789abcdef",) <>
                 ~s("nonce":"AAECAwQFBgcICQoLDA0ODw","expires_at":"2026-10-15T12:15:00Z"})
    end

    test "the nonce is 16 fresh random bytes, unpadded base64url, and the pass expires in 900 s" do
      assert SetupPass.validity() == 900

      [first, second] =
        for _ <- 1..2 do
          assert {:ok, read} = SetupPass.verify(pass!(), public_key(), now: @now)
          assert byte_size(read.nonce) == 16
          assert read.expires_at == ~U[2026-10-15 12:15:00Z]
          read.nonce
        end

      assert first != second
      assert payload!(pass!()) =~ ~r/"nonce":"[A-Za-z0-9_-]{21}[AQgw]"/
    end

    test "the time is taken to the second, in UTC" do
      assert {:ok, %{expires_at: ~U[2026-10-15 12:15:00Z]}} =
               SetupPass.verify(pass!(now: ~U[2026-10-15 12:00:00.999999Z]), public_key(),
                 now: @now
               )
    end

    test "both parts are base64url without padding, and the pass is within its bound" do
      pass = pass!()
      assert [payload, signature] = String.split(pass, ".")
      assert payload =~ ~r/\A[A-Za-z0-9_-]+\z/
      assert signature =~ ~r/\A[A-Za-z0-9_-]{86}\z/
      assert String.length(pass) <= SetupPass.max_length()
      assert SetupPass.max_length() == 1024
    end

    test "signs under the instance's key unless given one" do
      {:ok, pass} = SetupPass.issue(@adapter, now: @now)
      assert {:ok, _} = SetupPass.verify(pass, SigningKey.public_key(), now: @now)
      assert SetupPass.verify(pass, public_key(), now: @now) == :error
    end

    test "refuses anything but an adapter's public id, a nonce that is not 16 bytes, and a time that is none" do
      for adapter <- ["ac_0123456789abcdef", "na_0123456789ABCDEF", "na_", "", nil, 1] do
        assert SetupPass.issue(adapter, key: @key) == {:error, :invalid}, inspect(adapter)
      end

      for nonce <- [<<0::120>>, <<0::136>>, "", nil] do
        assert SetupPass.issue(@adapter, key: @key, nonce: nonce) == {:error, :invalid}
      end

      assert SetupPass.issue(@adapter, key: @key, now: "2026-10-15T12:00:00Z") ==
               {:error, :invalid}
    end
  end

  describe "verify/3" do
    test "reads a pass back under the key that signed it, and no other" do
      pass = pass!()

      assert {:ok, %{adapter_id: @adapter, expires_at: ~U[2026-10-15 12:15:00Z]}} =
               SetupPass.verify(pass, public_key(), now: @now)

      assert SetupPass.verify(pass, public_key(@other), now: @now) == :error
      assert SetupPass.verify(pass, "short", now: @now) == :error
    end

    test "a pass is good until its expires_at, and not from then on, nor too far ahead" do
      pass = pass!()
      assert {:ok, _} = SetupPass.verify(pass, public_key(), now: ~U[2026-10-15 12:14:59Z])
      assert SetupPass.verify(pass, public_key(), now: ~U[2026-10-15 12:15:00Z]) == :error
      assert SetupPass.verify(pass, public_key(), now: ~U[2026-10-15 11:59:59Z]) == :error
    end

    test "anything but the pass, as issued, is refused" do
      pass = pass!()
      [payload, signature] = String.split(pass, ".")

      for other <- [
            payload,
            payload <> "." <> signature <> ".",
            payload <> "=." <> signature,
            payload <> "." <> signature <> "=",
            " " <> pass,
            String.duplicate("a", 1025),
            "",
            nil
          ] do
        assert SetupPass.verify(other, public_key(), now: @now) == :error, inspect(other)
      end
    end

    test "a payload that does not read exactly as issued is refused, however it is signed" do
      payload = payload!(pass!())
      message = &SignedMessage.setup_pass/1

      for other <- [
            String.replace(payload, ~s("version":1), ~s("version":2)),
            String.replace(payload, ~s("version":1,), ""),
            String.replace(payload, "na_", "ac_"),
            String.replace(payload, ~s({"version":1,), ~s({"version":1, )),
            String.replace(
              payload,
              ~s("expires_at"),
              ~s("connection_id":"ac_0123456789abcdef","expires_at")
            ),
            String.replace(payload, ":00Z", ".000Z"),
            payload <> " "
          ] do
        assert other != payload
        assert SetupPass.verify(signed(other, message.(other)), public_key(), now: @now) == :error
      end

      # Its members in another order are refused too: the pass is read as issued.
      reordered =
        payload
        |> Jason.decode!()
        |> then(&Jason.OrderedObject.new(Enum.sort(&1)))
        |> Jason.encode!()

      assert reordered != payload

      assert SetupPass.verify(signed(reordered, message.(reordered)), public_key(), now: @now) ==
               :error

      assert {:ok, _} =
               SetupPass.verify(signed(payload, message.(payload)), public_key(), now: @now)
    end
  end

  describe "the generated documentation" do
    # Every instance serves the module reference at /docs, so neither module documents the
    # setup pass there.
    @undocumented ~r/setup[ _-]pass|qory-setup|adapter/i

    test "leaves the setup pass out" do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(SetupPass)

      for {{kind, _name, _arity}, _anno, _signature, doc, _meta} <- docs,
          kind != :type,
          do: assert(doc == :hidden)

      assert {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, docs} =
               Code.fetch_docs(SignedMessage)

      refute moduledoc =~ @undocumented

      assert [{_key, _anno, _signature, :hidden, _meta}] =
               for({{:function, :setup_pass, 1}, _, _, _, _} = entry <- docs, do: entry)

      for {{_kind, _name, _arity}, _anno, _signature, %{"en" => doc}, _meta} <- docs,
          do: refute(doc =~ @undocumented)
    end
  end

  describe "domain separation" do
    test "a signature over any other message of the contract is no setup pass" do
      payload = payload!(pass!())

      for message <- [
            payload,
            SignedMessage.connect_pass(payload),
            SignedMessage.connect_return(payload),
            SignedMessage.run_key(payload),
            SignedMessage.answer(200, "", payload, nil, nil),
            SignedMessage.enrolment_answer(200, "", payload),
            SignedMessage.request("ak_0000000000000000", nil, "POST", "/", payload),
            "qory-setup-ed25519-v2\n" <> payload,
            "qory-setup-ed25519-v1" <> payload
          ] do
        assert SetupPass.verify(signed(payload, message), public_key(), now: @now) == :error
      end

      assert {:ok, _} =
               SetupPass.verify(
                 signed(payload, SignedMessage.setup_pass(payload)),
                 public_key(),
                 now: @now
               )
    end

    test "a setup pass verifies as no connect pass, and a connect pass as no setup pass" do
      pass = pass!()
      payload = payload!(pass)
      [_encoded, encoded_signature] = String.split(pass, ".")
      {:ok, signature} = Ed25519.decode(encoded_signature, 64)

      assert Ed25519.verify(SignedMessage.setup_pass(payload), signature, public_key())

      for message <- [
            payload,
            SignedMessage.connect_pass(payload),
            SignedMessage.connect_return(payload),
            SignedMessage.run_key(payload)
          ] do
        refute Ed25519.verify(message, signature, public_key())
      end

      {:ok, connect} =
        ConnectPass.issue(@adapter, "ac_0123456789abcdef", key: @key, now: @now)

      assert SetupPass.verify(connect, public_key(), now: @now) == :error
      assert ConnectPass.verify(pass, public_key(), now: @now) == :error
    end

    test "the setup pass's domain line is distinct from every other, and no prefix of one" do
      tag = "qory-setup-ed25519-v1\n"
      assert SignedMessage.setup_pass("") == tag

      for other <- [
            SignedMessage.connect_pass(""),
            SignedMessage.connect_return(""),
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
