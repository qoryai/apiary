defmodule ApiaryWeb.PolicyLive.RuleFormPathsTest do
  # Not async: `with_features:` switches the features of the whole node.
  use ApiaryWeb.ConnCase, async: false

  # The rule form's Paths row with the instance's `path_rules` on and off, on the
  # workspace's New rule and Edit rule pages and on a target's. Off, the row is not drawn,
  # on Allow or on Deny, and the rules keep their paths.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.RunListFixtures
  import ApiaryWeb.TargetComponents, only: [target_path: 3]

  alias Apiary.Policy

  @off Apiary.Features.all() -- [:path_rules]

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  defp read(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp type(view, params), do: view |> form("#policy-rule-form", rule: params) |> render_change()
  defp add(view), do: view |> form("#policy-rule-form") |> render_submit()

  defp rule(scope, host, holder \\ nil),
    do: Enum.find(Policy.list_rules(scope, holder), &(&1.host == host))

  defp target(%{scope: scope}) do
    started_run(scope, shop())
    [%{target: target}] = Policy.list_targets(scope)
    %{target: target, base: target_path(scope, target, ["policy"])}
  end

  # The Paths row on Allow and on Deny, drawn or not.
  defp assert_paths_row(view) do
    type(view, %{action: "allow"})
    assert read(view, "label[for=policy-rule-paths]") == "PathsOptional"
    assert has_element?(view, "#policy-rule-paths[placeholder='Every path']")
    assert has_element?(view, "#policy-rule-paths-hint")

    type(view, %{action: "deny"})
    refute has_element?(view, "#policy-rule-paths")
    assert read(view, "#policy-rule-paths-deny") == "A deny covers every path of the host."
  end

  defp refute_paths_row(view) do
    for action <- ~w(allow deny) do
      type(view, %{action: action})
      assert has_element?(view, "#policy-rule-#{action}[checked]")
      refute has_element?(view, "label[for=policy-rule-paths]")
      refute has_element?(view, "#policy-rule-paths")
      refute has_element?(view, "#policy-rule-paths-hint")
      refute has_element?(view, "#policy-rule-paths-deny")

      html = view |> element("#policy-rule-form") |> render()
      refute html =~ "Paths"
      refute html =~ "Every path"
      refute html =~ "A deny covers every path of the host."
    end
  end

  describe "with path_rules on" do
    @describetag with_features: Apiary.Features.all()

    test "the workspace's New rule and Edit rule draw the Paths row",
         %{conn: conn, scope: scope} do
      assert_paths_row(open(conn, workspace_path(scope, "/policy/rules/new")))

      {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      view = open(conn, workspace_path(scope, "/policy/rules/#{rule.id}/edit"))
      assert has_element?(view, "#policy-rule-paths[value='/v1/*']")
      assert_paths_row(view)
    end

    test "a target's New rule and Edit rule draw the Paths row", %{conn: conn} = context do
      %{target: target, base: base} = target(context)
      assert_paths_row(open(conn, base <> "/rules/new"))

      {:ok, rule} =
        Policy.allow(context.scope, target, %{host: "mcp.acme.example", paths: ["/mcp"]})

      view = open(conn, "#{base}/rules/#{rule.id}/edit")
      assert has_element?(view, "#policy-rule-paths[value='/mcp']")
      assert_paths_row(view)
    end
  end

  describe "with path_rules off, the workspace's form" do
    @describetag with_features: @off

    test "New rule draws no Paths row, on Allow or on Deny", %{conn: conn, scope: scope} do
      view = open(conn, workspace_path(scope, "/policy/rules/new"))
      refute_paths_row(view)

      # The rest of the form is there.
      assert has_element?(view, "label[for=policy-rule-host]", "Host")
      assert has_element?(view, "#policy-rule-preview h2", "What this rule does")
      assert has_element?(view, "#policy-rule-add", "Add rule")
    end

    test "New rule saves an allow on every path", %{conn: conn, scope: scope} do
      view = open(conn, workspace_path(scope, "/policy/rules/new"))

      type(view, %{host: "api.partner.example.com"})

      assert read(view, "#policy-rule-reads") ==
               "Allow api.partner.example.com, on every path."

      add(view)
      assert_patch(view, workspace_path(scope, "/policy?rule=api.partner.example.com"))
      assert %{action: "allow", paths: nil} = rule(scope, "api.partner.example.com")
    end

    test "Edit of an allow with paths, saved unchanged, keeps its paths",
         %{conn: conn, scope: scope} do
      {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*", "/health"]})
      view = open(conn, workspace_path(scope, "/policy/rules/#{rule.id}/edit"))

      refute_paths_row(view)
      type(view, %{action: "allow"})
      assert read(view, "#policy-rule-reads") == "Nothing to save: the rule is as it was."

      add(view)
      assert %{action: "allow", paths: ["/v1/*", "/health"]} = rule(scope, "api.example")
      assert Policy.list_changes(scope, nil, 1).total == 1
    end

    test "Edit of an allow with paths, switched to Deny and back to Allow and saved, keeps its paths",
         %{conn: conn, scope: scope} do
      {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*", "/health"]})
      view = open(conn, workspace_path(scope, "/policy/rules/#{rule.id}/edit"))

      type(view, %{action: "deny"})
      assert has_element?(view, "#policy-rule-deny[checked]")
      type(view, %{action: "allow"})
      assert has_element?(view, "#policy-rule-allow[checked]")

      add(view)
      assert %{action: "allow", paths: ["/v1/*", "/health"]} = rule(scope, "api.example")
    end

    # Today's behaviour, kept: an address's paths fill the hidden field, the reading states
    # them and Add rule writes them.
    test "New rule still takes paths from its address, and saves them",
         %{conn: conn, scope: scope} do
      view = open(conn, workspace_path(scope, "/policy/rules/new?host=api.example&paths=/v1/*"))

      refute has_element?(view, "#policy-rule-paths")
      assert read(view, "#policy-rule-reads") =~ "Allow api.example on 1 path"

      add(view)
      assert %{action: "allow", paths: ["/v1/*"]} = rule(scope, "api.example")
    end
  end

  describe "with path_rules off, a target's form" do
    @describetag with_features: @off

    setup :target

    test "New rule draws no Paths row, and saves an allow on every path",
         %{conn: conn, scope: scope, target: target, base: base} do
      view = open(conn, base <> "/rules/new")
      refute_paths_row(view)
      assert has_element?(view, "#policy-rule-host[placeholder='mcp.acme.example']")

      type(view, %{action: "allow", host: "mcp.acme.example"})
      add(view)
      assert_patch(view, base <> "?rule=mcp.acme.example")
      assert %{action: "allow", paths: nil} = rule(scope, "mcp.acme.example", target)
    end

    test "Edit of an allow with paths, saved unchanged or after Deny and back, keeps its paths",
         %{conn: conn, scope: scope, target: target, base: base} do
      {:ok, rule} = Policy.allow(scope, target, %{host: "mcp.acme.example", paths: ["/mcp"]})
      view = open(conn, "#{base}/rules/#{rule.id}/edit")

      refute_paths_row(view)
      type(view, %{action: "allow"})
      add(view)
      assert %{action: "allow", paths: ["/mcp"]} = rule(scope, "mcp.acme.example", target)

      view = open(conn, "#{base}/rules/#{rule.id}/edit")
      type(view, %{action: "deny"})
      type(view, %{action: "allow"})
      add(view)
      assert %{action: "allow", paths: ["/mcp"]} = rule(scope, "mcp.acme.example", target)
    end
  end
end
