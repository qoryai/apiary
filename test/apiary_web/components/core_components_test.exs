defmodule ApiaryWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import ApiaryWeb.CoreComponents, only: [bold: 1, rich: 1, rich: 2, coded: 1, coded: 2]

  defp html(parts), do: parts |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  describe "rich/2" do
    test "sets the bindings marked by bold/1 in strong, and escapes every part" do
      text = "Invitation sent to #{bold("<a>@example.com")} & more."

      assert html(rich(text)) ==
               "Invitation sent to <strong>&lt;a&gt;@example.com</strong> &amp; more."

      assert html(rich(bold("x"), "font-medium")) == ~s(<strong class="font-medium">x</strong>)
    end

    test "leaves a sentence without marks as it is" do
      assert html(rich("Nothing <here>.")) == "Nothing &lt;here&gt;."
    end
  end

  describe "coded/2" do
    test "sets the parts between backticks in code, and escapes every part" do
      assert html(coded("Run `mix <docs>` & reload.", "q-rule")) ==
               ~s(Run <code class="q-rule">mix &lt;docs&gt;</code> &amp; reload.)

      assert html(coded("Paste this `server` block.")) =~
               ~r/<code class="[^"]*font-mono[^"]*">server<\/code>/
    end
  end
end
