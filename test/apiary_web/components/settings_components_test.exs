defmodule ApiaryWeb.SettingsComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.Nav.Entry
  alias ApiaryWeb.SettingsComponents

  defp entry(section, key),
    do: %Entry{section: section, key: key, label: Atom.to_string(key), path: "/#{key}"}

  defp render_list(sections) do
    assigns = %{sections: sections, scope: %{organisation: nil, workspace: nil}}

    ~H"""
    <SettingsComponents.layout
      scope={@scope}
      kind={:workspace}
      sections={@sections}
      current={:general}
      title="General"
    >
      <p>Body</p>
    </SettingsComponents.layout>
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp headings(doc), do: doc |> LazyHTML.query(".q-settings-group") |> Enum.map(&text/1)
  defp links(doc), do: doc |> LazyHTML.query("#settings-tabs a") |> LazyHTML.attribute("id")
  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  describe "a workspace's list of sections" do
    test "heads its two groups where each has two sections or more" do
      doc =
        render_list([
          entry(:workspace, :general),
          entry(:workspace, :people),
          entry(:given, :integrations),
          entry(:given, :secrets)
        ])

      assert headings(doc) == ["Workspace", "What runs are given"]

      assert links(doc) ==
               ~w(settings-tab-general settings-tab-people settings-tab-integrations settings-tab-secrets)

      # The heading goes before its group's links.
      html = doc |> LazyHTML.query("#settings-tabs") |> LazyHTML.to_html()
      {at, _} = :binary.match(html, "What runs are given")
      {link, _} = :binary.match(html, "settings-tab-integrations")
      assert at < link
    end

    test "is one list, without headings, where a group has a single section, or there is one group" do
      for sections <- [
            [entry(:workspace, :general), entry(:workspace, :people), entry(:given, :secrets)],
            [entry(:workspace, :general), entry(:workspace, :people)]
          ] do
        doc = render_list(sections)
        assert headings(doc) == []
        assert length(links(doc)) == length(sections)
      end
    end
  end
end
