defmodule ApiaryWeb.RuntimeHostRefusalTest do
  @moduledoc """
  A deny of a runtime's host and a path rule on such a host, saved from the rule form, are
  refused with a sentence that has the runtime's title, and nothing is saved.
  """
  use ApiaryWeb.ConnCase, async: true

  @moduletag needs: :security

  import Phoenix.LiveViewTest

  alias Apiary.Policy

  @deny "Remove api.anthropic.com from the rule. Claude Code needs this host, so no rule can deny it."
  @paths "Remove the paths from the rule. Claude Code needs every path on this host, so no rule can limit it."

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "What this rule does shows the deny's refusal before Add rule, not a read-back", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/policy/rules/new"))

    view
    |> form("#policy-rule-form", rule: %{"action" => "deny", "host" => "api.anthropic.com"})
    |> render_change()

    assert text(view, "#policy-rule-preview-refusal") == @deny
    refute has_element?(view, "#policy-rule-preview-ok")
    refute has_element?(view, "#policy-rule-preview-note")

    # A host no runtime needs reads back as before.
    view
    |> form("#policy-rule-form", rule: %{"action" => "deny", "host" => "tracker.example"})
    |> render_change()

    refute has_element?(view, "#policy-rule-preview-refusal")
    assert has_element?(view, "#policy-rule-reads")
    assert Policy.list_rules(scope, nil) == []
  end

  @tag needs: :path_rules
  test "What this rule does shows the paths' refusal before Add rule, not a read-back", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/policy/rules/new"))

    view
    |> form("#policy-rule-form",
      rule: %{"action" => "allow", "host" => "api.anthropic.com", "paths" => "/v1/*"}
    )
    |> render_change()

    assert text(view, "#policy-rule-preview-refusal") == @paths
    refute has_element?(view, "#policy-rule-preview-ok")

    # The same host on every path reads back as before.
    view
    |> form("#policy-rule-form",
      rule: %{"action" => "allow", "host" => "api.anthropic.com", "paths" => ""}
    )
    |> render_change()

    refute has_element?(view, "#policy-rule-preview-refusal")
    assert has_element?(view, "#policy-rule-reads")
  end

  test "the rule form shows the deny's sentence under the Host field", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/policy/rules/new"))

    view
    |> form("#policy-rule-form", rule: %{"action" => "deny", "host" => "api.anthropic.com"})
    |> render_change()

    view |> form("#policy-rule-form") |> render_submit()

    assert text(view, "#policy-rule-write-error") == @deny

    assert has_element?(
             view,
             ".q-rule-field:has(#policy-rule-host) #policy-rule-write-error[role=alert]"
           )

    assert Policy.list_rules(scope, nil) == []
  end

  @tag needs: :path_rules
  test "the rule form shows the path's sentence above Add rule, outside the Host field", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/policy/rules/new"))

    view
    |> form("#policy-rule-form",
      rule: %{"action" => "allow", "host" => "api.anthropic.com", "paths" => "/v1/*"}
    )
    |> render_change()

    view |> form("#policy-rule-form") |> render_submit()

    assert text(view, "#policy-rule-write-error") == @paths

    refute has_element?(view, ".q-rule-field:has(#policy-rule-host) #policy-rule-write-error")
    assert Policy.list_rules(scope, nil) == []
  end

  test "the rule form saves an allow of the host on every path", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/policy/rules/new"))

    view
    |> form("#policy-rule-form", rule: %{"action" => "allow", "host" => "api.anthropic.com"})
    |> render_change()

    view |> form("#policy-rule-form") |> render_submit()

    assert [%{host: "api.anthropic.com", action: "allow", paths: nil}] =
             Policy.list_rules(scope, nil)
  end
end
