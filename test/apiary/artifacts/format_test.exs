defmodule Apiary.Artifacts.FormatTest do
  use ExUnit.Case, async: true

  alias Apiary.Artifacts.{Filename, Format, Type}

  @moduletag :tmp_dir

  @svg_namespace "http://www.w3.org/2000/svg"

  defp standard(name), do: Enum.find(Type.standard(), &(&1.name == name))

  defp check(context, type, filename, bytes) do
    path = Path.join(context.tmp_dir, "file-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    Format.check(standard(type), filename, path)
  end

  describe "an image" do
    test "is PNG, JPEG, GIF or WebP by its first bytes", context do
      assert {:ok, "image/png"} =
               check(context, "mockup", "a", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0>>)

      assert {:ok, "image/jpeg"} = check(context, "mockup", "a", <<0xFF, 0xD8, 0xFF, 0xE0>>)
      assert {:ok, "image/gif"} = check(context, "mockup", "a", "GIF87a" <> <<1>>)
      assert {:ok, "image/gif"} = check(context, "mockup", "a", "GIF89a" <> <<1>>)

      assert {:ok, "image/webp"} =
               check(context, "mockup", "a", "RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ")
    end

    test "is SVG when an XML parser reads it to its end with an svg root in the SVG namespace",
         context do
      assert {:ok, "image/svg+xml"} =
               check(context, "mockup", "a.png", ~s(<svg xmlns="#{@svg_namespace}"/>))

      assert {:ok, "image/svg+xml"} =
               check(
                 context,
                 "mockup",
                 "a",
                 ~s(\uFEFF<?xml version="1.0" encoding="UTF-8"?>\n<!-- a mockup -->\n<s:svg xmlns:s="#{@svg_namespace}"><s:rect/></s:svg>\n)
               )
    end

    test "is refused when it is neither", context do
      for bytes <- [
            "",
            "<html><body></body></html>",
            ~s(<svg width="1"/>),
            ~s(<html xmlns="#{@svg_namespace}"/>),
            ~s(<svg xmlns="#{@svg_namespace}">),
            ~s(<svg xmlns="#{@svg_namespace}"/><svg xmlns="#{@svg_namespace}"/>),
            ~s(<svg xmlns="#{@svg_namespace}"/>trailing),
            ~s(<svg xmlns="#{@svg_namespace}">&undeclared;</svg>),
            <<0xFF, 0xFE, "<svg/>">>,
            "RIFF" <> <<0, 0, 0, 0>> <> "AVI "
          ] do
        assert {:error, :format} = check(context, "mockup", "a.svg", bytes),
               "#{inspect(bytes)} is taken"
      end
    end

    test "refuses an SVG that declares a document type or entities", context do
      doctype =
        ~s(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;">]>) <>
          ~s(<svg xmlns="#{@svg_namespace}">&b;</svg>)

      assert {:error, :format} = check(context, "mockup", "a.svg", doctype)

      assert {:error, :format} =
               check(
                 context,
                 "mockup",
                 "a.svg",
                 ~s(<!doctype svg><svg xmlns="#{@svg_namespace}"/>)
               )
    end

    test "takes an SVG of 512 KiB within the budget, and refuses a larger one", context do
      element = ~s(<rect x="1" y="2" width="3" height="4" fill="#abcdef"/>\n)
      head = ~s(<svg xmlns="#{@svg_namespace}">)
      tail = "</svg>"
      count = div(524_288 - byte_size(head) - byte_size(tail), byte_size(element))
      svg = head <> String.duplicate(element, count) <> tail
      assert byte_size(svg) <= 524_288
      assert {:ok, "image/svg+xml"} = check(context, "mockup", "a.svg", svg)

      larger = head <> String.duplicate(element, count + 1) <> tail
      assert {:error, :format} = check(context, "mockup", "a.svg", larger)
    end
  end

  describe "a video" do
    test "is MP4 by an ftyp box with an MP4 brand, or WebM by its EBML document type", context do
      assert {:ok, "video/mp4"} = check(context, "demo-video", "a", <<0, 0, 0, 24, "ftypisom">>)
      assert {:ok, "video/mp4"} = check(context, "demo-video", "a", <<0, 0, 0, 24, "ftypmp42">>)

      assert {:ok, "video/webm"} =
               check(
                 context,
                 "demo-video",
                 "a",
                 <<0x1A, 0x45, 0xDF, 0xA3, 0x42, 0x82, 0x84, "webm">>
               )
    end

    test "is refused for another brand, Matroska or anything else", context do
      for bytes <- [
            <<0, 0, 0, 24, "ftypheic">>,
            <<0, 0, 0, 24, "ftypqt  ">>,
            <<0x1A, 0x45, 0xDF, 0xA3, 0x42, 0x82, 0x88, "matroska">>,
            <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>,
            ""
          ] do
        assert {:error, :format} = check(context, "demo-video", "a.mp4", bytes)
      end
    end
  end

  describe "a document" do
    test "is UTF-8 Markdown text in a file whose name ends in .md", context do
      assert {:ok, "text/markdown; charset=utf-8"} =
               check(context, "explainer", "a.md", "# Gift cards\n\n```mermaid\ngraph TD\n```\n")

      assert {:ok, _type} = check(context, "explainer", "A.Md", "")
      assert {:error, :extension} = check(context, "explainer", "a.markdown", "# A")
      assert {:error, :extension} = check(context, "explainer", "md", "# A")
      assert {:error, :format} = check(context, "explainer", "a.md", <<0xC3, 0x28>>)
      assert {:error, :format} = check(context, "explainer", "a.md", "a\u0000b")
    end
  end

  test "a file takes any bytes", context do
    {:ok, type} = {:ok, %Type{name: "bids", base_view: :file}}
    path = Path.join(context.tmp_dir, "any")
    File.write!(path, <<0, 1, 2>>)
    assert {:ok, "application/octet-stream"} = Format.check(type, "a.exe", path)
  end

  test "a file that cannot be read is unreadable", context do
    missing = Path.join(context.tmp_dir, "missing")

    for type <- ~w(explainer mockup demo-video verdict) do
      assert {:error, :unreadable} = Format.check(standard(type), "a.md", missing)
    end
  end

  test "a structured document is one JSON value its schema takes", context do
    assert {:ok, "application/json"} = check(context, "verdict", "a", ~s({"verdict":"passed"}))
    assert {:error, :schema} = check(context, "verdict", "a", ~s({"verdict":"passed","x":1}))
    assert {:error, :schema} = check(context, "verdict", "a", ~s([1]))
    assert {:error, :format} = check(context, "verdict", "a", ~s({"verdict":"passed"} x))
    assert {:error, :format} = check(context, "verdict", "a", <<0xFF>>)
  end

  test "a standard type's text bounds count code points, not graphemes", context do
    # 501 letters, each with a combining accent: 1002 code points, 501 graphemes.
    title = String.duplicate("e\u0301", 501)
    change = %{"url" => "https://forge.example.com/acme/shop/pull/4", "title" => title}
    assert {:error, :schema} = check(context, "change", "a", Jason.encode!(change))

    change = %{change | "title" => String.duplicate("e\u0301", 250)}
    assert {:ok, _type} = check(context, "change", "a", Jason.encode!(change))
  end

  describe "Filename.valid?/1" do
    test "takes a base name of 1 to 255 bytes" do
      for name <- ["a", "demo video.mp4", "été.md", ".hidden", "a..b", String.duplicate("a", 255)],
          do: assert(Filename.valid?(name), name)
    end

    test "refuses a path, a dot name, control, format and separator characters, and more than 255 bytes" do
      for name <- [
            "",
            ".",
            "..",
            "a/b",
            "/a",
            "a\\b",
            "a\u0000b",
            "a\tb",
            "a\u007Fb",
            "a\u0085b",
            "a\u200Bb",
            "a\u202Eb",
            "a\u2028b",
            <<0xFF>>,
            String.duplicate("a", 256),
            nil,
            :a
          ] do
        refute Filename.valid?(name), inspect(name)
      end
    end
  end
end
