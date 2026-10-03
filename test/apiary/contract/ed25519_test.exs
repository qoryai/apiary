defmodule Apiary.Contract.Ed25519Test do
  use ExUnit.Case, async: true

  alias Apiary.Contract.Ed25519

  # The contract's published vectors.
  @fixture_access_key "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"
  @fixture_signing_key "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc"
  @torsion_key "KH9r2npX9PKHPzv_Xl6pwmCmpjQ73zfHq800btWQTBE"

  # The eight points of small order, canonical, and the six non-canonical encodings a
  # lenient decoder accepts.
  @small_order [
    "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "7P_______________________________________38",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA",
    "xxdqcD1N2E-6PAt2DRBnDyogU_osOczGTsf9d5KsA3o",
    "xxdqcD1N2E-6PAt2DRBnDyogU_osOczGTsf9d5KsA_o",
    "JuiVj8KyJ7BFw_SJ8u-Y8NXfrAXTxjM5sTgCiG1T_AU",
    "JuiVj8KyJ7BFw_SJ8u-Y8NXfrAXTxjM5sTgCiG1T_IU"
  ]
  @non_canonical [
    "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA",
    "7P________________________________________8",
    "7f_______________________________________38",
    "7f________________________________________8",
    "7v_______________________________________38",
    "7v________________________________________8"
  ]

  defp key_pair do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    {public, secret}
  end

  describe "the key checks" do
    test "a fresh key passes them all" do
      {public, _secret} = key_pair()
      assert Ed25519.check_public_key(public) == :ok
      assert {:ok, ^public} = Ed25519.decode_public_key(Ed25519.encode(public))
    end

    test "every point of small order is refused, the identity for its y of 1" do
      for encoded <- @small_order do
        assert {:ok, key} = Ed25519.decode(encoded, 32)
        assert {:error, reason} = Ed25519.check_public_key(key), encoded
        assert reason in [:small_order, :y_is_one], encoded
      end

      {:ok, identity} = Ed25519.decode(hd(@small_order), 32)
      assert Ed25519.check_public_key(identity) == {:error, :y_is_one}
    end

    test "a non-canonical encoding is refused as such, before its order is asked" do
      for encoded <- @non_canonical do
        assert {:ok, key} = Ed25519.decode(encoded, 32)
        assert Ed25519.check_public_key(key) == {:error, :non_canonical}, encoded
      end
    end

    test "a key with a torsion component passes the others and fails prime order" do
      assert Ed25519.decode_public_key(@torsion_key) == {:error, :not_prime_order}
    end

    test "a y with no x on the curve is refused" do
      # y = 2 has no square root for x².
      key = <<2, 0::248>>
      assert Ed25519.check_public_key(key) == {:error, :not_on_curve}
    end

    test "the published fixture keys pass the five checks and are refused as fixtures" do
      for encoded <- [@fixture_access_key, @fixture_signing_key] do
        assert Ed25519.decode_public_key(encoded) == {:error, :fixture}
      end

      assert length(Ed25519.fixture_keys()) == 3
      assert Ed25519.encode(hd(Ed25519.fixture_keys())) == @fixture_access_key
    end

    test "a key of the wrong length is refused" do
      {public, _secret} = key_pair()
      <<short::binary-size(31), _::binary>> = public

      assert Ed25519.check_public_key(short) == {:error, :length}
      assert Ed25519.check_public_key(public <> <<0>>) == {:error, :length}
      assert Ed25519.decode_public_key(Ed25519.encode(short)) == {:error, :length}
      assert Ed25519.decode_public_key(Ed25519.encode(public <> <<0>>)) == {:error, :length}
      assert Ed25519.decode_public_key("") == {:error, :length}
      assert Ed25519.decode_public_key(nil) == {:error, :length}
    end
  end

  describe "the strict base64url" do
    test "padding, the standard alphabet and bits after the last byte are refused" do
      {public, _secret} = key_pair()
      encoded = Ed25519.encode(public)
      assert {:ok, ^public} = Ed25519.decode(encoded, 32)

      # With padding.
      assert Ed25519.decode(encoded <> "=", 32) == :error

      # The standard alphabet for the URL-safe one.
      standard = encoded |> String.replace("-", "+") |> String.replace("_", "/")
      if standard != encoded, do: assert(Ed25519.decode(standard, 32) == :error)
      assert Ed25519.decode("+" <> String.slice(encoded, 1..-1//1), 32) == :error
      assert Ed25519.decode("/" <> String.slice(encoded, 1..-1//1), 32) == :error

      # 43 characters carry 258 bits: the last character's two low bits must be zero.
      last = String.last(encoded)
      alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
      index = Enum.find_index(alphabet, &(&1 == hd(String.to_charlist(last))))
      dirty = <<Enum.at(alphabet, Bitwise.bor(index, 1))>>
      assert Ed25519.decode(String.slice(encoded, 0..-2//1) <> dirty, 32) == :error
    end

    test "the fixture access key decodes to its 32 bytes" do
      assert {:ok, key} = Ed25519.decode(@fixture_access_key, 32)
      assert byte_size(key) == 32
    end
  end

  describe "the fingerprint" do
    test "matches the contract's vectors" do
      {:ok, access_key} = Ed25519.decode(@fixture_access_key, 32)
      {:ok, signing_key} = Ed25519.decode(@fixture_signing_key, 32)

      assert Ed25519.fingerprint(access_key) == "ZbYGc9btiEvwHCwiLYKtoA"
      assert Ed25519.fingerprint(signing_key) == "uoES-kuj1vk0sq0qoGlmAg"
    end

    test "is 22 characters of SHA-256's first 16 bytes" do
      {public, _secret} = key_pair()
      fingerprint = Ed25519.fingerprint(public)

      assert String.length(fingerprint) == 22
      <<head::binary-size(16), _::binary>> = :crypto.hash(:sha256, public)
      assert Base.url_decode64!(fingerprint, padding: false) == head
    end
  end

  describe "cofactorless verification" do
    @l Integer.pow(2, 252) + 27_742_317_777_372_353_535_851_937_790_883_648_493

    test "verifies a signature, and nothing else" do
      {public, secret} = key_pair()
      signature = :crypto.sign(:eddsa, :none, "qory-request-ed25519-v1", [secret, :ed25519])

      assert Ed25519.verify("qory-request-ed25519-v1", signature, public)
      refute Ed25519.verify("qory-request-ed25519-v2", signature, public)
      refute Ed25519.verify("qory-request-ed25519-v1", binary_part(signature, 0, 63), public)
      refute Ed25519.verify("qory-request-ed25519-v1", signature, binary_part(public, 0, 31))
    end

    test "refuses an S not below ℓ" do
      {public, secret} = key_pair()

      <<r::binary-size(32), s::binary-size(32)>> =
        :crypto.sign(:eddsa, :none, "m", [secret, :ed25519])

      s_plus_l = :binary.decode_unsigned(s, :little) + @l
      malleable = r <> <<s_plus_l::little-size(256)>>

      refute Ed25519.verify("m", malleable, public)
    end

    test "refuses a non-canonical R" do
      {public, secret} = key_pair()

      <<_r::binary-size(32), s::binary-size(32)>> =
        :crypto.sign(:eddsa, :none, "m", [secret, :ed25519])

      {:ok, non_canonical} = Ed25519.decode(hd(@non_canonical), 32)

      refute Ed25519.verify("m", non_canonical <> s, public)
    end
  end
end
