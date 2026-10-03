defmodule Apiary.Contract.Ed25519Test do
  use ExUnit.Case, async: true

  alias Apiary.Contract.Ed25519

  # The contract's published vectors.
  @fixture_access_key "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"
  @fixture_signing_key "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc"
  @torsion_key "KH9r2npX9PKHPzv_Xl6pwmCmpjQ73zfHq800btWQTBE"
  @fixture_next_signing_key "C0eCPnEJXdWb54rCccV27zifh7ZFYasHz5pOvNAtIEE"

  # The contract's enrolment known answer: the proof, under the fixture access key, of the
  # five lines of the example body.
  @enrol_lines Enum.join(
                 [
                   "qory-enrol-ed25519-v1",
                   "qec_F1XT0RE0000000000000000000.uoES-kuj1vk0sq0qoGlmAg",
                   "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ",
                   "build-01",
                   "1700000000"
                 ],
                 "\n"
               )
  @enrol_proof "stcDcwasYMSLUxHX7A9AH-LXGRsRfpbHpMwGKd5ND6LI1WRsH10Rt4dhp8VmIYEau2sj31kCJSUzsDkSlCV8AQ"

  # A signature valid under cofactored verification only, made for this test: under the
  # key of `@cofactored_seed`, of "qory-request-ed25519-v1", with R = rB + T for T the
  # first order-8 point of `@small_order` and S = r + k·a, k over that R. [8]SB = [8]R +
  # [8]kA holds, since [8]T is the identity; SB = R + kA does not. Its R and S are
  # canonical, so only the equation refuses it.
  @cofactored_seed "oPCGmRNKrFJWrE0Rdmuck9VqC0AERWd_VEdSujf7gOo"
  @cofactored_key "S642ktckYAc7Wep8ytaOCdAdZ9HmoYbsOAOPaXuHT2s"
  @cofactored_signature "AwlfcomEgdC0aDiY3AOy4bW2pycOhG0Me_wFCxE1chy3r9Jk_wpTUHm0RAURjXV6KWZIdUEmnOKyHJNjaOj8BQ"

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

    test "whitespace anywhere is refused" do
      {public, _secret} = key_pair()
      encoded = Ed25519.encode(public)

      for spaced <- [
            " " <> encoded,
            encoded <> "\n",
            String.slice(encoded, 0, 20) <> " " <> String.slice(encoded, 20..-1//1),
            String.slice(encoded, 0, 20) <> "\r\n" <> String.slice(encoded, 20..-1//1),
            String.slice(encoded, 0, 20) <> "\t" <> String.slice(encoded, 20..-1//1)
          ] do
        assert Ed25519.decode(spaced, 32) == :error, inspect(spaced)
        assert Ed25519.decode_public_key(spaced) == {:error, :length}
      end
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

    test "the next fixture signing key matches its published key and fingerprint" do
      seed = :binary.list_to_bin(Enum.to_list(161..192))
      {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)

      assert Ed25519.encode(public) == @fixture_next_signing_key
      assert Ed25519.fingerprint(public) == "52vzzF--Ic7qH_eZWi5K2A"
      assert public in Ed25519.fixture_keys()
      assert Ed25519.decode_public_key(@fixture_next_signing_key) == {:error, :fixture}
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

      <<r::binary-size(32), s::binary-size(32)>> =
        :crypto.sign(:eddsa, :none, "m", [secret, :ed25519])

      {:ok, non_canonical} = Ed25519.decode(hd(@non_canonical), 32)

      # The form alone refuses it, before the curve is asked: the check `verify/3` makes
      # whatever `:crypto` would answer.
      assert Ed25519.canonical_signature?(r <> s)

      for encoded <- @non_canonical do
        {:ok, bad_r} = Ed25519.decode(encoded, 32)
        refute Ed25519.canonical_signature?(bad_r <> s), encoded
      end

      refute Ed25519.verify("m", non_canonical <> s, public)
    end

    test "refuses an S not below ℓ by its form, before the curve" do
      {_public, secret} = key_pair()

      <<r::binary-size(32), s::binary-size(32)>> =
        :crypto.sign(:eddsa, :none, "m", [secret, :ed25519])

      s_plus_l = :binary.decode_unsigned(s, :little) + @l
      refute Ed25519.canonical_signature?(r <> <<s_plus_l::little-size(256)>>)
      refute Ed25519.canonical_signature?(r)
    end

    test "verifies the contract's enrolment proof" do
      {:ok, key} = Ed25519.decode(@fixture_access_key, 32)
      {:ok, proof} = Ed25519.decode(@enrol_proof, 64)

      assert byte_size(@enrol_lines) == 139
      assert Ed25519.verify(@enrol_lines, proof, key)
      refute Ed25519.verify(@enrol_lines <> "\n", proof, key)
    end

    test "refuses a signature that verifies only cofactored" do
      {:ok, seed} = Ed25519.decode(@cofactored_seed, 32)
      {:ok, key} = Ed25519.decode(@cofactored_key, 32)
      {:ok, signature} = Ed25519.decode(@cofactored_signature, 64)

      # The vector's key is the seed's, and a signature the seed makes verifies.
      assert {^key, secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
      honest = :crypto.sign(:eddsa, :none, "qory-request-ed25519-v1", [secret, :ed25519])
      assert Ed25519.verify("qory-request-ed25519-v1", honest, key)

      assert Ed25519.canonical_signature?(signature)
      refute Ed25519.verify("qory-request-ed25519-v1", signature, key)
    end
  end
end
