defmodule ApiaryWeb.AdapterComponentsTest do
  # What the pages of Instance settings › Adapters share (`ApiaryWeb.AdapterComponents`):
  # an adapter's paths, its browser titles, the line under its name, its tabs and its
  # state in words.
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.AdapterComponents

  @adapter %Node{
    kind: :adapter,
    name: "Tracker",
    public_id: "na_8f3k2m9q4x7v1t6r",
    inserted_at: ~U[2026-10-14 10:12:00Z],
    created_by: %User{email: "dana@example.com"}
  }

  defp text(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  test "paths/1 are the adapter's pages under /instance/adapters, by its public id" do
    paths = AdapterComponents.paths(@adapter)
    overview = "/instance/adapters/na_8f3k2m9q4x7v1t6r"

    assert paths == %{
             list: "/instance/adapters",
             overview: overview,
             keys: overview <> "/keys",
             new_code: overview <> "/keys/new-code",
             settings: overview <> "/settings",
             rename: overview <> "/settings/rename",
             remove: overview <> "/settings/remove"
           }

    assert AdapterComponents.paths(@adapter.public_id) == paths

    assert AdapterComponents.act_path(paths, %AccessKey{key_id: "ak_3n7p2x9k4m8q1v5t"}) ==
             overview <> "/keys/ak_3n7p2x9k4m8q1v5t/revoke"

    id = Ecto.UUID.generate()

    assert AdapterComponents.act_path(paths, %EnrolmentCode{id: id}) ==
             "#{overview}/keys/codes/#{id}/revoke"
  end

  test "page_title/2 names the page, then Adapters, then Instance settings" do
    scope = %Scope{}
    assert AdapterComponents.page_title(scope, []) == "Adapters · Instance settings"

    assert AdapterComponents.page_title(scope, ["Access key", "Tracker"]) ==
             "Access key · Tracker · Adapters · Instance settings"
  end

  test "adapter_meta/1 says who added the adapter and when, then its public id" do
    assigns = %{adapter: @adapter}
    html = rendered_to_string(~H"<AdapterComponents.adapter_meta adapter={@adapter} />")

    assert text(html) == "Added by dana@example.com, 14 Oct 2026 · na_8f3k2m9q4x7v1t6r"

    assigns = %{adapter: %{@adapter | created_by: nil}}
    html = rendered_to_string(~H"<AdapterComponents.adapter_meta adapter={@adapter} />")
    assert text(html) =~ "Added by Former member, 14 Oct 2026"
  end

  describe "adapter_tabs/1" do
    defp tabs(current) do
      assigns = %{adapter: @adapter, paths: AdapterComponents.paths(@adapter), current: current}

      rendered_to_string(~H"""
      <AdapterComponents.adapter_tabs adapter={@adapter} paths={@paths} current={@current} />
      """)
      |> LazyHTML.from_fragment()
    end

    defp tab(tabs, key) do
      [link] = tabs |> LazyHTML.query("#adapter-tabs-#{key}") |> Enum.to_list()

      {LazyHTML.text(link) |> String.trim(), link |> LazyHTML.attribute("href") |> hd(),
       link |> LazyHTML.attribute("data-phx-link") |> hd(),
       LazyHTML.attribute(link, "aria-current")}
    end

    test "are Overview, Access key and Settings, named by the adapter, the current one marked" do
      tabs = tabs(:overview)
      overview = "/instance/adapters/na_8f3k2m9q4x7v1t6r"

      assert tabs |> LazyHTML.query("nav#adapter-tabs") |> LazyHTML.attribute("aria-label") ==
               ["Tracker"]

      assert tab(tabs, :overview) == {"Overview", overview, "patch", ["page"]}
      assert tab(tabs, :keys) == {"Access key", overview <> "/keys", "redirect", []}
      assert tab(tabs, :settings) == {"Settings", overview <> "/settings", "patch", []}
    end

    test "on the Access key tab, the other two are another page's, a navigation" do
      tabs = tabs(:keys)
      overview = "/instance/adapters/na_8f3k2m9q4x7v1t6r"

      assert tab(tabs, :overview) == {"Overview", overview, "redirect", []}
      assert tab(tabs, :keys) == {"Access key", overview <> "/keys", "patch", ["page"]}
      assert tab(tabs, :settings) == {"Settings", overview <> "/settings", "redirect", []}
    end
  end

  test "adapter_state/1 is No key yet with its dot, or Connected" do
    assigns = %{}
    html = rendered_to_string(~H|<AdapterComponents.adapter_state id="s" connected={false} />|)
    assert text(html) == "No key yet"
    assert html =~ "q-stw-hot"

    html = rendered_to_string(~H|<AdapterComponents.adapter_state id="s" connected />|)
    assert text(html) == "Connected"
    assert html =~ "q-sdot-succeeded"
    refute html =~ "No key yet"
  end
end
