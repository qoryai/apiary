defmodule Apiary.AccessKeys.EnrolmentCodeTest do
  use ExUnit.Case, async: true

  alias Apiary.AccessKeys.EnrolmentCode

  @kinds [:node, :pool, :gateway, :adapter]

  describe "normalise/1" do
    test "reads a code of every kind as generated, and as a person types it" do
      for kind <- @kinds do
        prefix = EnrolmentCode.prefix(kind)
        code = EnrolmentCode.generate(kind)
        body = String.replace_prefix(code, prefix, "")

        assert EnrolmentCode.normalise(code) == {:ok, code}
        assert EnrolmentCode.normalise(String.upcase(prefix) <> body) == {:ok, code}
        assert EnrolmentCode.normalise(prefix <> String.downcase(body)) == {:ok, code}

        grouped =
          prefix <>
            (body |> String.graphemes() |> Enum.chunk_every(4) |> Enum.join("-"))

        assert EnrolmentCode.normalise(grouped) == {:ok, code}

        assert EnrolmentCode.normalise(
                 prefix <> String.duplicate("o", 13) <> String.duplicate("l", 13)
               ) == {:ok, prefix <> String.duplicate("0", 13) <> String.duplicate("1", 13)}

        assert EnrolmentCode.normalise(prefix <> String.duplicate("i", 26)) ==
                 {:ok, prefix <> String.duplicate("1", 26)}
      end
    end

    test "refuses a code outside the alphabet, of the wrong length, or of no kind" do
      prefix = EnrolmentCode.prefix(:node)

      assert EnrolmentCode.normalise(prefix <> String.duplicate("U", 26)) == :error
      assert EnrolmentCode.normalise(prefix <> String.duplicate("A", 25)) == :error
      assert EnrolmentCode.normalise(prefix <> String.duplicate("A", 27)) == :error
      assert EnrolmentCode.normalise(prefix <> String.duplicate("A", 25) <> "!") == :error
      assert EnrolmentCode.normalise("qrk_" <> String.duplicate("A", 26)) == :error
      assert EnrolmentCode.normalise("") == :error
      assert EnrolmentCode.normalise(nil) == :error
    end

    test "refuses a character that takes more than one byte, where its bytes make 26" do
      prefix = EnrolmentCode.prefix(:node)

      # 24 letters and one character of two bytes: 26 bytes, so the alphabet check reads
      # them, and refuses the two bytes. "ſ" and "ı" are letters outside ASCII that a
      # Unicode upper case would read as the alphabet's, `S` and `I`.
      for character <- ["É", "ſ", "ı"] do
        typed = prefix <> String.duplicate("A", 24) <> character
        assert byte_size(typed) == byte_size(prefix) + 26
        assert EnrolmentCode.normalise(typed) == :error
      end

      # Twenty-six of them are 52 bytes, which the length refuses before the alphabet.
      assert EnrolmentCode.normalise(prefix <> String.duplicate("ſ", 26)) == :error
      assert EnrolmentCode.normalise(prefix <> String.duplicate("ı", 26)) == :error
    end

    test "refuses bytes that are not UTF-8, without raising" do
      prefix = EnrolmentCode.prefix(:node)

      for body <- [
            String.duplicate("A", 25) <> <<0xFF>>,
            String.duplicate("A", 25) <> <<0xC3>>,
            :binary.copy(<<0x80>>, 26),
            <<0xC3>> <> String.duplicate("A", 25)
          ] do
        assert byte_size(body) == 26
        refute String.valid?(body)
        assert EnrolmentCode.normalise(prefix <> body) == :error
      end
    end
  end

  describe "a run code" do
    test "is the run prefix and 26 characters, of no node's kind, and no code a page reads" do
      code = EnrolmentCode.generate(:run)
      assert code =~ ~r/\Aqecr_[0-9A-HJKMNP-TV-Z]{26}\z/
      assert EnrolmentCode.run_code?(code)
      refute EnrolmentCode.prefixed?(code)
      refute Enum.any?(@kinds, &EnrolmentCode.of_kind?(code, &1))
      assert EnrolmentCode.normalise(code) == :error
      refute EnrolmentCode.generate(:run) == code
    end
  end
end
