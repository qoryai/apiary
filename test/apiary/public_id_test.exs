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
end
