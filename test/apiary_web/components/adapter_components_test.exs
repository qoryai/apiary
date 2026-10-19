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

  test "paths/1 are the adapter's pages under /instance/adapters, and its Set up, by its public id" do
    paths = AdapterComponents.paths(@adapter)
    overview = "/instance/adapters/na_8f3k2m9q4x7v1t6r"

    assert paths == %{
             list: "/instance/adapters",
             overview: overview,
             setup: overview <> "/setup",
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

    assert text(html) == "Added by Ddana@example.com, 14 Oct 2026 · na_8f3k2m9q4x7v1t6r"
    doc = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(LazyHTML.query(doc, "#adapter-added abbr"), "data-tip") == [
             "dana@example.com"
           ]

    html =
      rendered_to_string(
        ~H|<AdapterComponents.adapter_meta adapter={@adapter} reader="dana@example.com" />|
      )

    assert LazyHTML.attribute(
             LazyHTML.query(LazyHTML.from_fragment(html), "#adapter-added abbr"),
             "data-tip"
           ) ==
             ["dana@example.com (you)"]

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

  test "adapter_seen/1 is No key yet with its dot, or, with a key, Last seen or Never seen" do
    adapter = %Node{kind: :adapter, name: "Shop tracker", public_id: "na_8f3k2m9q4x7v1t6r"}
    seen = DateTime.add(DateTime.utc_now(), -120, :second)
    assigns = %{adapter: adapter, seen: seen}

    html =
      rendered_to_string(
        ~H|<AdapterComponents.adapter_seen id="s" adapter={@adapter} connected={false} />|
      )

    assert text(html) == "No key yet"
    assert html =~ "q-stw-hot"

    html =
      rendered_to_string(
        ~H|<AdapterComponents.adapter_seen id="s" adapter={@adapter} connected />|
      )

    assert text(html) == "Never seen"

    html =
      rendered_to_string(
        ~H|<AdapterComponents.adapter_seen id="s" adapter={@adapter} connected seen={@seen} />|
      )

    assert text(html) =~ ~r/^Last seen \S/
    assert html =~ ~s(id="s-seen")

    refute html =~ "Connected"
    refute html =~ "No key yet"
  end

  test "interval_label/1 and interval_words/1 say an interval in hours, minutes or seconds" do
    labels =
      for seconds <- [60, 300, 600, 900, 1800, 3600, 7200, 21_600, 43_200, 86_400],
          do: AdapterComponents.interval_label(seconds)

    assert labels == [
             "Every minute",
             "Every 5 minutes",
             "Every 10 minutes",
             "Every 15 minutes",
             "Every 30 minutes",
             "Every hour",
             "Every 2 hours",
             "Every 6 hours",
             "Every 12 hours",
             "Every 24 hours"
           ]

    assert AdapterComponents.interval_label(2700) == "Every 45 minutes"
    assert AdapterComponents.interval_label(90) == "Every 90 seconds"

    assert Enum.map([60, 900, 3600, 7200, 90], &AdapterComponents.interval_words/1) == [
             "every minute",
             "every 15 minutes",
             "every hour",
             "every 2 hours",
             "every 90 seconds"
           ]
  end

  test "pulls_every/1 is the chosen interval, else the default, raised to the minimum" do
    sync = %{interval: nil, default: 3600, minimum: 900}
    assert AdapterComponents.pulls_every(sync) == 3600
    assert AdapterComponents.pulls_every(%{sync | interval: 1800}) == 1800
    assert AdapterComponents.pulls_every(%{sync | interval: 300}) == 900
    assert AdapterComponents.pulls_every(%{interval: nil, default: nil, minimum: nil}) == nil

    adapter = %Node{
      kind: :adapter,
      sync_interval: 7200,
      sync_default_interval: 3600,
      sync_minimum_interval: 900,
      sync_sends_changes: true
    }

    assert AdapterComponents.sync_of(adapter) ==
             %{interval: 7200, default: 3600, minimum: 900, sends_changes: true}

    assert adapter |> AdapterComponents.sync_of() |> AdapterComponents.pulls_every() == 7200
  end

  # The form's markup with its CSRF token's value set aside, LiveView's root markers left
  # out, and its spacing collapsed.
  defp markup(html) do
    html
    |> String.replace(~r/(name="_csrf_token"[^>]* value=")[^"]*"/, "\\1TOKEN\"")
    |> String.replace(" phx-r", "")
    |> String.split()
    |> Enum.join(" ")
  end

  defp setup_form(variant) do
    assigns = %{adapter: @adapter, variant: variant}

    if variant do
      rendered_to_string(~H"""
      <AdapterComponents.setup_form id="s" adapter={@adapter} variant={@variant} />
      """)
    else
      rendered_to_string(~H"""
      <AdapterComponents.setup_form id="s" adapter={@adapter} />
      """)
    end
  end

  test "setup_form/1 by default renders as it did before it took a variant" do
    assert markup(setup_form(nil)) ==
             ~s(<form action="/instance/adapters/na_8f3k2m9q4x7v1t6r/setup" method="post" novalidate class="contents" id="s"> <input name="_csrf_token" type="hidden" hidden value="TOKEN"> <button class="btn btn-xs" id="s-button" type="submit"> <span class="hero-arrow-top-right-on-square-micro size-4"></span>Set up </button> </form>)
  end

  test "setup_form/1 with variant primary draws core's primary button, the form unchanged" do
    default = setup_form(nil)
    primary = setup_form("primary")

    assert primary =~ ~s(class="btn btn-xs btn-primary")
    refute default =~ "btn-primary"

    assert markup(primary) ==
             String.replace(
               markup(default),
               ~s(class="btn btn-xs"),
               ~s(class="btn btn-xs btn-primary")
             )
  end
end
