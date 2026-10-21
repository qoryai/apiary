defmodule Apiary.PublicIdTest do
  use ExUnit.Case, async: true

  alias Apiary.PublicId

  test "an id is the prefix, an underscore and 16 lowercase Crockford base32 characters" do
    ids = for _ <- 1..200, do: PublicId.generate("sec")

    for id <- ids do
      assert id =~ ~r/\Asec_[0-9a-hjkmnp-tv-z]{16}\z/
      assert PublicId.valid?("sec", id)
    end

    assert length(Enum.uniq(ids)) == length(ids)
    assert Apiary.AccessKeys.AccessKey.generate_key_id() =~ ~r/\Aak_[0-9a-hjkmnp-tv-z]{16}\z/
  end

  test "valid?/2 refuses another prefix, another length and the letters Crockford leaves out" do
    refute PublicId.valid?("ak", "sec_0123456789abcdef")
    refute PublicId.valid?("sec", "sec_0123456789abcde")
    refute PublicId.valid?("sec", "sec_0123456789abcdefg")
    refute PublicId.valid?("sec", "sec_0123456789abcdeF")

    for letter <- ~w(i l o u) do
      refute PublicId.valid?("sec", "sec_0123456789abcde" <> letter)
    end

    refute PublicId.valid?("sec", "sec0123456789abcdef")
    refute PublicId.valid?("sec", nil)
    assert PublicId.valid?("sec", "sec_0123456789abcdef")
  end

  test "valid?/2 refuses 16 bytes that are not 16 characters of the alphabet, and raises on none" do
    # Not UTF-8: a byte 0xFF, and a lone continuation byte.
    refute PublicId.valid?("rn", "rn_" <> <<0xFF>> <> "123456789abcdef")
    refute PublicId.valid?("rn", "rn_0123456789abcde" <> <<0x80>>)
    refute PublicId.valid?("wk", "wk_" <> <<0xC3, 0x28>> <> "23456789abcdef")

    # A character of two bytes and one of three: 16 bytes, fewer characters.
    refute PublicId.valid?("rn", "rn_é23456789abcdef")
    refute PublicId.valid?("nd", "nd_€3456789abcdef")

    # Uppercase, and one character too few or too many.
    refute PublicId.valid?("rn", "rn_0123456789ABCDEF")
    refute PublicId.valid?("rn", "rn_0123456789abcde")
    refute PublicId.valid?("rn", "rn_0123456789abcdef0")

    for prefix <- ~w(wk nd wi rn con svc sec na ac) do
      assert PublicId.valid?(prefix, PublicId.generate(prefix))
      assert PublicId.valid?(prefix, prefix <> "_0123456789abcdef")
      refute PublicId.valid?(prefix, prefix <> "_" <> <<0xFF>> <> "123456789abcdef")
    end
  end
end
