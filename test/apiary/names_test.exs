defmodule Apiary.NamesTest do
  use ExUnit.Case, async: true

  alias Apiary.Names

  defp errors(name, opts \\ []) do
    {%{}, %{name: :string}}
    |> Ecto.Changeset.cast(%{name: name}, [:name])
    |> Names.validate_characters(:name, opts)
    |> Map.fetch!(:errors)
    |> Keyword.get_values(:name)
    |> Enum.map(&elem(&1, 0))
  end

  test "refuses a control character, C0, DEL or C1, anywhere in a name" do
    for cp <- [0x0, 0x7, 0x9, 0xA, 0xD, 0x1B, 0x1F, 0x7F, 0x80, 0x85, 0x9F],
        name <- ["#{<<cp::utf8>>}Build", "Bu#{<<cp::utf8>>}ild", "Build#{<<cp::utf8>>}"] do
      assert errors(name) == ["must not contain control characters"], inspect(name)
    end
  end

  test "refuses a bidirectional control: an embedding, override or isolate, LRM, RLM, ALM" do
    for cp <-
          Enum.to_list(0x202A..0x202E) ++ Enum.to_list(0x2066..0x2069) ++ [0x200E, 0x200F, 0x061C] do
      assert errors("Build#{<<cp::utf8>>}01") == ["must not contain control characters"],
             Integer.to_string(cp, 16)
    end
  end

  test "refuses another format character, and the line and paragraph separators" do
    # The zero-width space, word joiner, soft hyphen, Mongolian vowel separator, byte order
    # mark, an interlinear annotation, a language tag; U+2028 and U+2029.
    for cp <- [0x200B, 0x2060, 0xAD, 0x180E, 0xFEFF, 0xFFF9, 0xE0001, 0x2028, 0x2029] do
      assert errors("Build#{<<cp::utf8>>}01") == ["must not contain control characters"],
             Integer.to_string(cp, 16)
    end
  end

  test "keeps the join controls, letters beyond ASCII and an emoji sequence" do
    for name <- [
          "می#{<<0x200C::utf8>>}خواهم",
          "👩#{<<0x200D::utf8>>}💻 builds",
          "Übergrößen & Söhne",
          "Build 01"
        ] do
      assert errors(name) == [], inspect(name)
    end
  end

  test "refuses bytes that are not UTF-8 text" do
    assert errors(<<0xFF>> <> "Build") == ["must be UTF-8 text"]
    assert errors(<<0xFF>> <> "Build", lines: true) == ["must be UTF-8 text"]
  end

  test "without lines: true, tab and line feed stay refused" do
    assert errors("a\nb") == ["must not contain control characters"]
    assert errors("a\tb", lines: false) == ["must not contain control characters"]
  end

  describe "a text of several lines (lines: true)" do
    test "keeps tab and line feed" do
      for text <- ["First line\nsecond line", "a\tb", "\n\nThree\n", "Build 01"] do
        assert errors(text, lines: true) == [], inspect(text)
      end
    end

    test "refuses every other control character, the carriage return among them" do
      for cp <- [0x0, 0x7, 0x8, 0xB, 0xC, 0xD, 0x1B, 0x1F, 0x7F, 0x80, 0x85, 0x9F],
          text <- ["#{<<cp::utf8>>}Build", "Bu#{<<cp::utf8>>}ild", "Build\n#{<<cp::utf8>>}"] do
        assert errors(text, lines: true) == ["must not contain control characters"],
               inspect(text)
      end
    end

    test "refuses a format character, and the line and paragraph separators" do
      for cp <-
            Enum.to_list(0x202A..0x202E) ++
              Enum.to_list(0x2066..0x2069) ++
              [0x200E, 0x200F, 0x061C, 0x200B, 0x2060, 0xAD, 0x180E, 0xFEFF, 0xFFF9, 0xE0001] ++
              [0x2028, 0x2029] do
        assert errors("Build\n#{<<cp::utf8>>}01", lines: true) ==
                 ["must not contain control characters"],
               Integer.to_string(cp, 16)
      end
    end

    test "keeps the join controls, letters beyond ASCII and an emoji sequence" do
      for text <- [
            "می#{<<0x200C::utf8>>}خواهم\nmore",
            "👩#{<<0x200D::utf8>>}💻 builds",
            "Übergrößen & Söhne\tand more"
          ] do
        assert errors(text, lines: true) == [], inspect(text)
      end
    end
  end
end
