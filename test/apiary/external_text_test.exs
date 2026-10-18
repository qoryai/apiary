defmodule Apiary.ExternalTextTest do
  use ExUnit.Case, async: true

  alias Apiary.ExternalText

  @fffd "\u{FFFD}"
  # The invisible characters a page drops: the bidirectional controls and marks, the
  # Mongolian vowel separator, the zero-width space, the soft hyphen, the word joiner and
  # the invisible operators, the byte order mark, the interlinear annotation characters,
  # the line and paragraph separators.
  @invisible [0xAD, 0x61C, 0x180E, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029] ++
               Enum.to_list(0x202A..0x202E) ++
               Enum.to_list(0x2060..0x2064) ++
               Enum.to_list(0x2066..0x2069) ++ [0xFEFF, 0xFFF9, 0xFFFA, 0xFFFB]

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

    test "shows bytes that are not UTF-8 text as U+FFFD, and nil as nil" do
      assert ExternalText.line(<<"Fix ", 0xFF, " login">>) == "Fix #{@fffd} login"
      assert ExternalText.line(nil) == nil
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
