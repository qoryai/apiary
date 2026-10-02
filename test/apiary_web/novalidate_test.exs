defmodule ApiaryWeb.NovalidateTest do
  @moduledoc """
  Every form in the application is `novalidate`: the browser's own checks, and their
  bubbles, are off, and the page answers a field that is wrong under it, from the server
  (`ApiaryWeb.CoreComponents.input/1`). The attributes that help a person still stand on
  the fields (`required`, `type="email"`, `inputmode`), for assistive technology and the
  keyboard a phone shows.

  The test reads the source: each `<form` and `<.form` tag under `lib/`, which may span
  lines and hold `{...}` expressions with `>` in them, such as a pipe of JS commands.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../lib", __DIR__)

  test "every form tag under lib/ is novalidate" do
    tags =
      for path <- sources(), {line, tag} <- form_tags(File.read!(path)), do: {path, line, tag}

    # The scan finds the forms there are: if it found none, it would prove nothing.
    assert length(tags) > 10

    missing =
      for {path, line, tag} <- tags, not Regex.match?(~r/\snovalidate(?=[\s=>]|$)/, tag) do
        "#{Path.relative_to(path, Path.dirname(@root))}:#{line}"
      end

    assert missing == [], """
    These forms let the browser check their fields and show its own bubbles. Add
    novalidate, and have the server answer a wrong field under it:

      #{Enum.join(missing, "\n  ")}
    """
  end

  test "the scan reads a tag across lines and past a > inside an expression" do
    source = """
    <.form
      id="a"
      phx-submit={JS.push("go") |> JS.hide(to: "#b")}
      novalidate
    >
    <form id="c" phx-submit="go">
    <.formatted value={1} />
    """

    assert [{1, first}, {6, second}] = form_tags(source)
    assert first =~ "novalidate"
    assert second == ~s|<form id="c" phx-submit="go">|
  end

  defp sources do
    Path.wildcard(Path.join(@root, "**/*.{ex,heex}"))
  end

  # Each form tag with the line it starts on: from `<form` or `<.form`, followed by a space
  # or the tag's end, to the `>` outside any quoted value and any `{...}`.
  defp form_tags(source) do
    ~r/<\.?form(?=[\s>])/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, _length}] ->
      before = binary_part(source, 0, start)
      line = length(String.split(before, "\n"))
      rest = binary_part(source, start, byte_size(source) - start)
      {line, tag(rest, 0, nil, "")}
    end)
  end

  defp tag(<<">", _::binary>>, 0, nil, acc), do: acc <> ">"
  defp tag(<<?", rest::binary>>, 0, nil, acc), do: tag(rest, 0, ?", acc <> "\"")
  defp tag(<<?", rest::binary>>, 0, ?", acc), do: tag(rest, 0, nil, acc <> "\"")
  defp tag(<<?{, rest::binary>>, depth, nil, acc), do: tag(rest, depth + 1, nil, acc <> "{")

  defp tag(<<?}, rest::binary>>, depth, nil, acc) when depth > 0,
    do: tag(rest, depth - 1, nil, acc <> "}")

  defp tag(<<c::utf8, rest::binary>>, depth, quote, acc),
    do: tag(rest, depth, quote, acc <> <<c::utf8>>)

  defp tag(<<>>, _depth, _quote, acc), do: acc
end
