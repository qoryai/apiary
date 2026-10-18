defmodule ApiaryWeb.ExternalTextTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ApiaryWeb.ExternalText

  defp html(text) do
    assigns = %{text: text}
    # Without LiveView's marker of a rendered root, which says nothing of the text.
    ~H(<.external_text text={@text} class="q-mono" />)
    |> rendered_to_string()
    |> String.replace(" phx-r", "")
  end

  test "isolates the text in <bdi>, its invisible characters dropped and its controls shown" do
    assert html("Fix#{<<0x202E::utf8>>} login\e") ==
             ~s(<bdi class="q-mono">Fix login\u{FFFD}</bdi>)
  end

  test "escapes the text as any text is" do
    assert html("<b>Fix</b> & co") ==
             ~s(<bdi class="q-mono">&lt;b&gt;Fix&lt;/b&gt; &amp; co</bdi>)
  end

  test "shows nothing for nil and an empty text" do
    assert html(nil) == ""
    assert html("") == ""
  end

  test "marks a text that was sent but has nothing left to show, or only whitespace" do
    for text <- ["\u200B", "   ", "\u00A0\u3000"] do
      assert html(text) == ~s(<bdi class="q-mono">\u{FFFD}</bdi>), inspect(text)
    end

    assert html(" \u2066 ") == ~s(<bdi class="q-mono"> \u{FFFD} </bdi>)
  end
end
