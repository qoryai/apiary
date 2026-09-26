defmodule ApiaryWeb.RichTextTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ApiaryWeb.RichText

  defp render_rich(text) do
    assigns = %{text: text}
    ~H"<.rich text={@text} />" |> rendered_to_string() |> plain()
  end

  # Without the markers the test renderer adds to each root tag.
  defp plain(html), do: String.replace(html, " phx-r", "")

  describe "rich_gettext/2" do
    test "splits the translated sentence at its bindings" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en", fn ->
        assert rich_gettext("Invitation sent to %{email}.", email: {:b, "a@example.com"}) ==
                 ["Invitation sent to ", {:b, "a@example.com"}, "."]
      end)
    end

    test "a binding that holds a binding's mark stays what it is" do
      assert render_rich(rich_gettext("Run %{id}", id: "%{id} \u0001id\u0001")) ==
               "Run %{id} \u0001id\u0001"
    end

    test "the domain's words come from its catalogue, the bindings stay in place" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en@software", fn ->
        html =
          render_rich(
            rich_ngettext("%{number} target", "%{number} targets", 2, number: {:b, "2"})
          )

        assert html == "<b>2</b> repositories"
      end)
    end
  end

  describe "rich/1" do
    test "escapes every part at every level" do
      html =
        render_rich([
          "a <i> ",
          {:b, ["<b>", {:m, "<i>"}], "font-medium"},
          {:code, "<u>"},
          {:bad, "<s>"},
          {:link, "/acme/main/runs", "<em>"},
          {:href, "/dev/mailbox", "<q>"},
          nil,
          3
        ])

      refute html =~ ~r/<(i|u|s|em|q)>/
      assert html =~ "a &lt;i&gt; "

      assert html =~
               ~s(<b class="font-medium">&lt;b&gt;<span class="font-mono text-[12px]">&lt;i&gt;</span></b>)

      assert html =~ ~s(<code class="q-rule">&lt;u&gt;</code>)
      assert html =~ ~s(<span class="q-bad">&lt;s&gt;</span>)
      assert html =~ ~s(href="/acme/main/runs")
      assert html =~ ~s(href="/dev/mailbox")
      assert html =~ "3"
    end

    test "a term carries its standard word on hover" do
      html = render_rich({:term, "Observe", "Let through and recorded"})
      assert html =~ ~s(data-tip="Let through and recorded")
      assert html =~ ">Observe</abbr>"
    end

    test "a part is filled by the slot of its name" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.rich text={rich_gettext("%{time} by a member", time: {:part, :time})}>
          <:part name={:time}><time>09:00</time></:part>
        </.rich>
        """)
        |> plain()

      assert html =~ "<time>09:00</time> by a member"
    end

    test "safe HTML and rendered components are left as they are" do
      assert render_rich(["x ", {:safe, "<wbr>"}]) == "x <wbr>"
    end
  end
end
