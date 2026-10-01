defmodule ApiaryWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ApiaryWeb.CoreComponents

  describe "an input with a prefix" do
    test "shows the prefix before the value as one field, read with it" do
      form = Phoenix.Component.to_form(%{"slug" => "data"}, as: :workspace)

      html =
        render_component(&CoreComponents.input/1,
          field: form[:slug],
          type: "text",
          label: "Address",
          prefix: "qory.example/acme/",
          hint: "Made from the name."
        )

      doc = LazyHTML.from_fragment(html)

      assert [prefix] =
               LazyHTML.query(doc, ".q-input-prefix > span#workspace_slug-prefix")
               |> Enum.to_list()

      assert LazyHTML.text(prefix) == "qory.example/acme/"

      assert [input] =
               LazyHTML.query(doc, ".q-input-prefix > input#workspace_slug") |> Enum.to_list()

      assert LazyHTML.attribute(input, "value") == ["data"]

      assert LazyHTML.attribute(input, "aria-describedby") == [
               "workspace_slug-prefix workspace_slug-hint"
             ]
    end

    test "without one the input stands alone" do
      form = Phoenix.Component.to_form(%{"name" => "Data"}, as: :workspace)

      html =
        render_component(&CoreComponents.input/1, field: form[:name], type: "text", label: "Name")

      refute html =~ "q-input-prefix"
    end
  end
end
