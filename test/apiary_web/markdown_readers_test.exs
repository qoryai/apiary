defmodule ApiaryWeb.MarkdownReadersTest do
  # Qory Apiary parses no output's Markdown to read data from it: the acceptance criteria
  # and the verification are JSON documents (`ApiaryWeb.WorkItemLive.VerifyTab`). The
  # only modules that use MDEx are the two that render Markdown as HTML for a page: an
  # artifact's or a run's document (`ApiaryWeb.ArtifactLive.Markdown`) and a ticket's body
  # (`Apiary.Sources.Body`). This scan of `lib/` fails where another module parses
  # Markdown or reads a parsed document's nodes.
  use ExUnit.Case, async: true

  @renderers ["lib/apiary/sources/body.ex", "lib/apiary_web/live/artifact_live/markdown.ex"]

  test "only the two Markdown renderers use MDEx" do
    users =
      for path <- Path.wildcard("lib/**/*.{ex,exs,heex}"),
          path |> File.read!() |> code_lines() |> Enum.any?(&String.contains?(&1, "MDEx")),
          do: path

    assert Enum.sort(users) == @renderers
  end

  test "each renderer parses Markdown in one place" do
    for path <- @renderers do
      calls =
        path
        |> File.read!()
        |> code_lines()
        |> Enum.count(&String.contains?(&1, "MDEx.parse_document"))

      assert calls == 1, path
    end
  end

  # The lines of a source file that are not comments.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
  end
end
