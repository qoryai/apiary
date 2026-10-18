defmodule Apiary.ExternalTextTest do
  use ExUnit.Case, async: true

  alias Apiary.ExternalText

  @fffd "\u{FFFD}"
  # Some of the invisible characters a page drops: format characters (the bidirectional
  # controls and marks, the Mongolian vowel separator, the zero-width space, the soft
  # hyphen, the word joiner and the invisible operators, the deprecated format characters,
  # the byte order mark, the interlinear annotation characters, the tag characters, a
  # musical formatting character), the line and paragraph separators, the combining
  # grapheme joiner, the Khmer inherent vowels and the Mongolian free variation selectors.
  @invisible [0xAD, 0x61C, 0x180E, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029] ++
               Enum.to_list(0x202A..0x202E) ++
               Enum.to_list(0x2060..0x2064) ++
               Enum.to_list(0x2066..0x2069) ++
               Enum.to_list(0x206A..0x206F) ++
               [0xFEFF, 0xFFF9, 0xFFFA, 0xFFFB, 0xE0001, 0xE0067, 0xE007F, 0x1D173] ++
               [0x34F, 0x17B4, 0x17B5, 0x180B, 0x180C, 0x180D, 0x180F]

  describe "line/1" do
    test "drops an invisible character" do
      for cp <- @invisible do
        assert ExternalText.line("Fix#{<<cp::utf8>>} login") == "Fix login",
               Integer.to_string(cp, 16)
      end
    end

    test "shows a control character, C0, DEL or C1, the tab and line breaks among them, as U+FFFD" do
      for cp <- [0x0, 0x7, 0x9, 0xA, 0xD, 0x1B, 0x7F, 0x80, 0x85, 0x9F] do
        assert ExternalText.line("Fix#{<<cp::utf8>>}login") == "Fix#{@fffd}login",
               Integer.to_string(cp, 16)
      end
    end

    test "keeps the join controls, letters beyond ASCII and an emoji sequence" do
      for text <- ["می#{<<0x200C::utf8>>}خواهم", "👩#{<<0x200D::utf8>>}💻 builds", "Größe é ü"] do
        assert ExternalText.line(text) == text
      end
    end

    test "shows an emoji flag of a subdivision as a plain black flag" do
      england =
        "🏴" <>
          for(
            cp <- [0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F],
            into: "",
            do: <<cp::utf8>>
          )

      assert ExternalText.line(england) == "🏴"
    end

    test "shows bytes that are not UTF-8 text as U+FFFD, and nil as nil" do
      assert ExternalText.line(<<"Fix ", 0xFF, " login">>) == "Fix #{@fffd} login"
      assert ExternalText.line(nil) == nil
    end
  end

  describe "present/1" do
    # The Unicode space separators, which `String.trim/1` trims.
    @spaces [0x20, 0xA0, 0x1680] ++ Enum.to_list(0x2000..0x200A) ++ [0x202F, 0x205F, 0x3000]

    test "is nil for nil, an empty line, and one with nothing left to show" do
      assert ExternalText.present(nil) == nil
      assert ExternalText.present("") == nil

      for char <- @invisible,
          do: assert(ExternalText.present(<<char::utf8>>) == nil, inspect(char))
    end

    test "is nil for a line of whitespace alone, with or without invisible characters" do
      for char <- @spaces do
        assert ExternalText.present(<<char::utf8>>) == nil, inspect(char)
        assert ExternalText.present(<<char::utf8, 0x200B::utf8, char::utf8>>) == nil
      end

      assert ExternalText.present(" \u00A0\u2003\u202E\u3000 ") == nil
    end

    test "is the line as line/1 shows it, untrimmed, while anything else is left" do
      assert ExternalText.present("  Fix\u200B login\u00A0") == "  Fix login\u00A0"
      assert ExternalText.present(" \t ") == " #{@fffd} "
      assert ExternalText.present("\u202E.") == "."
    end
  end

  describe "lines/1" do
    test "keeps the tab and the line breaks, and treats the rest as line/1 does" do
      text = "Steps:\r\n\t1. Log in#{<<0x202E::utf8>>}\n2. Esc\e[2J\u0085done"
      assert ExternalText.lines(text) == "Steps:\r\n\t1. Log in\n2. Esc#{@fffd}[2J#{@fffd}done"
      assert ExternalText.lines(nil) == nil
    end
  end
end
