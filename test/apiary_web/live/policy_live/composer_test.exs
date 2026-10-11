defmodule ApiaryWeb.PolicyLive.ComposerTest.Page do
  @moduledoc false
  # A page that has not moved to the New rule and Edit rule pages, as an edition's may
  # still be: the composer in the list's `composer` slot, opened by Add rule in the search's
  # bar, the rows' Edit paths, and `Common` with its default form, "policy-composer". With
  # `"form" => "policy-rule"` in its session, a page that has moved, drawing Add rule as a
  # link and no composer, whose rows' events `Common` answers (as an edition's writer page).
  use ApiaryWeb, :live_view

  import ApiaryWeb.PolicyComponents, only: [rule_list: 1, rule_composer: 1]

  alias Apiary.Policy
  alias ApiaryWeb.PolicyLive.{Common, RuleList}

  @impl true
  def mount(_params, %{"scope" => scope} = session, socket) do
    form = Map.get(session, "form", "policy-composer")

    {:ok,
     socket
     |> assign(current_scope: scope, composer_open: false, list_query: %RuleList{})
     |> Common.mount(nil, form: form)
     |> assign(reload: &load/1)
     |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    own = Policy.list_rules(scope, nil)

    socket
    |> assign(own: own, effective: Policy.effective(scope, nil), locks: %{})
    |> then(&assign(&1, rows: Common.workspace_rules(own, &1, %{})))
  end

  @impl true
  def handle_event(event, params, socket) do
    case Common.handle_event(event, params, socket) do
      {:halt, socket} -> {:noreply, socket}
      :cont -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="flash-info">{Phoenix.Flash.get(@flash, :info)}</div>
    <.rule_list
      id="policy-rules"
      label="Rules"
      listing={RuleList.list(@rows, @list_query, :unavailable)}
      query={@list_query}
      path={&Common.list_path(@base, &1)}
      sections={[]}
      default_sort="Locked first"
      title={if @form_id == "policy-rule", do: "Network access"}
      add_path={if @form_id == "policy-rule", do: Common.new_rule_path(assigns)}
      can_add
      adding={@composer_open}
    >
      <:composer>
        <.rule_composer
          :if={@composer_open}
          id="policy-composer"
          form={@composer}
          scope={:workspace}
          reading={@reading}
          queued={length(@queue)}
        />
      </:composer>
    </.rule_list>
    <p :if={@write_error} id="policy-write-error">{@write_error}</p>
    """
  end
end

defmodule ApiaryWeb.PolicyLive.ComposerTest do
  use ApiaryWeb.ConnCase, async: true

  # The composer kept for callers that have not moved to the rule pages
  # (`PolicyComponents.rule_composer/1`, `rule_list/1`'s `composer` slot and `adding`, the
  # rows' Edit paths, `PolicyLive.Common` with its default form): it goes once no caller
  # is left, and works until then.
  @moduletag needs: :security

  import Phoenix.LiveViewTest

  alias Apiary.Policy
  alias ApiaryWeb.PolicyLive.ComposerTest.Page

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  defp open(conn, scope, session \\ %{}) do
    {:ok, view, _html} =
      live_isolated(conn, Page, session: Map.put(session, "scope", scope))

    view
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

  defp rule(scope, host), do: Enum.find(Policy.list_rules(scope, nil), &(&1.host == host))

  test "Add rule in the bar opens the composer; it reads, saves and stays open",
       %{conn: conn, scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
    view = open(conn, scope)

    refute has_element?(view, "#policy-composer")
    assert has_element?(view, "#policy-rules-add[aria-expanded=false]", "Add rule")

    view |> element("#policy-rules-add") |> render_click()
    assert has_element?(view, "#policy-rules-add[aria-expanded=true]")
    assert has_element?(view, "#policy-composer")
    assert has_element?(view, "#policy-composer-add[disabled]")
    assert_push_event(view, "policy:focus", %{id: "policy-composer-host"})

    view
    |> form("#policy-composer", rule: %{host: "api.example", paths: "/v1/*"})
    |> render_change()

    assert text(view, "#policy-composer-reads") =~ "Allow api.example on 1 path"
    refute has_element?(view, "#policy-composer-add[disabled]")

    view |> form("#policy-composer") |> render_submit()
    assert %{paths: ["/v1/*"]} = rule(scope, "api.example")
    assert text(view, "#flash-info") =~ "api.example is allowed for the workspace."
    assert has_element?(view, "#policy-composer")
    assert_push_event(view, "policy:focus", %{id: "policy-composer-host"})

    view |> element("#policy-composer-cancel") |> render_click()
    refute has_element?(view, "#policy-composer")
  end

  test "Deny is a button of its own, and a bad host keeps the button off",
       %{conn: conn, scope: scope} do
    view = open(conn, scope)
    view |> element("#policy-rules-add") |> render_click()

    view |> element("#policy-composer button", "Deny") |> render_click()
    view |> form("#policy-composer", rule: %{host: "telemetry.example"}) |> render_change()
    assert text(view, "#policy-composer-reads") =~ "Deny telemetry.example."

    view |> form("#policy-composer", rule: %{host: "https://x.example/a"}) |> render_change()
    assert has_element?(view, "#policy-composer-add[disabled]")
    render_hook(view, "composer_save", %{})
    refute rule(scope, "x.example")

    view
    |> element("#policy-composer-reads button", "Use x.example with the path /a")
    |> render_click()

    assert has_element?(view, "#policy-composer-host[value='x.example']")
  end

  test "a row's Edit paths fills the composer with the rule", %{conn: conn, scope: scope} do
    {:ok, held} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
    view = open(conn, scope)

    view |> element("#rule-#{held.id}-menu button", "Edit paths") |> render_click()
    assert has_element?(view, "#policy-composer-host[value='api.example']")
    assert has_element?(view, "#policy-composer-paths[value='/v1/*']")
    assert_push_event(view, "policy:focus", %{id: "policy-composer-paths"})

    view
    |> form("#policy-composer", rule: %{host: "api.example", paths: "/v1/* /v2/*"})
    |> render_change()

    assert text(view, "#policy-composer-add") == "Change paths"
    view |> form("#policy-composer") |> render_submit()
    assert %{paths: ["/v1/*", "/v2/*"]} = rule(scope, "api.example")
  end

  test "a pasted list is added one at a time", %{conn: conn, scope: scope} do
    view = open(conn, scope)
    view |> element("#policy-rules-add") |> render_click()

    render_hook(view, "composer_paste", %{"hosts" => ["a.example", "b.example"]})
    assert text(view, "#policy-composer-reads-queued") == "1 more to add"

    view |> form("#policy-composer") |> render_submit()
    assert rule(scope, "a.example")
    assert has_element?(view, "#policy-composer-host[value='b.example']")
  end

  test "what the domain refuses is said, and the composer stays", %{conn: conn, scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "*.cdn.example", paths: ["/v1/*"]})
    view = open(conn, scope)
    view |> element("#policy-rules-add") |> render_click()

    view
    |> form("#policy-composer", rule: %{host: "files.cdn.example", paths: ""})
    |> render_change()

    view |> form("#policy-composer") |> render_submit()
    assert text(view, "#policy-write-error") =~ "held to paths"
    assert has_element?(view, "#policy-composer")
    refute rule(scope, "files.cdn.example")
  end

  test "Remove gives the focus to the composer's host", %{conn: conn, scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "a.example"})
    {:ok, _} = Policy.allow(scope, nil, %{host: "b.example"})
    view = open(conn, scope)

    view
    |> element("#rule-#{rule(scope, "a.example").id}-menu button", "Remove")
    |> render_click()

    refute rule(scope, "a.example")
    assert_push_event(view, "policy:focus", %{id: "policy-composer-host"})
  end

  test "on a page with the rule form, Remove gives the focus to Add rule, the composer drawn nowhere",
       %{conn: conn, scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "a.example"})
    {:ok, _} = Policy.allow(scope, nil, %{host: "b.example"})
    view = open(conn, scope, %{"form" => "policy-rule"})
    assert has_element?(view, "#policy-rules-head a#policy-rules-add")

    view
    |> element("#rule-#{rule(scope, "a.example").id}-menu button", "Remove")
    |> render_click()

    refute rule(scope, "a.example")
    assert_push_event(view, "policy:focus", %{id: "policy-rules-add"})
    refute has_element?(view, "#policy-composer-host")
  end

  test "on a page with the rule form, removing the last rule gives the focus to Add rule",
       %{conn: conn, scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "a.example"})
    view = open(conn, scope, %{"form" => "policy-rule"})

    view
    |> element("#rule-#{rule(scope, "a.example").id}-menu button", "Remove")
    |> render_click()

    assert Policy.list_rules(scope, nil) == []
    assert_push_event(view, "policy:focus", %{id: "policy-rules-add"})
    assert has_element?(view, "#policy-rules-head a#policy-rules-add")
  end
end
