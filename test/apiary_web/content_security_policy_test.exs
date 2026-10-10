defmodule ApiaryWeb.ContentSecurityPolicyTest do
  @moduledoc """
  The content security policy (`ApiaryWeb.ContentSecurityPolicy`) held to every page: each
  GET route of the core's router, its parameters filled from one owner's records, is
  requested as that owner and signed out, and the answer must carry the policy, exactly,
  with a fresh nonce; and its HTML, the dead render and a LiveView's connected one, must
  hold nothing the policy refuses: a script without the nonce or from elsewhere, an
  `on…=` attribute, a `javascript:` address, a `<base>`, a plug-in, a stylesheet, image,
  frame or form target on another origin. The storybook's stories and the development
  tools are among the routes (`config/test.exs` compiles them in test).

  A new route is covered as soon as its parameters are ones this test fills; a route with
  a parameter it does not know fails the test until it is filled here or skipped with a
  reason.

  What no test without a browser sees: a script or style a bundle creates while it runs
  (xterm.js's `<style>` elements, for which the policy allows inline styles), an `eval` in
  a bundle (none is there today; the bundles were checked when the policy was written),
  and a header a reverse proxy strips or replaces.
  """
  # Not async: the owner is the instance's admin, which hides the instance's organisation,
  # a row every test shares, inside this test's sandbox (`Apiary.EditionKit`).
  use ApiaryWeb.ConnCase, async: false

  # The storybook warns of its stylesheet, which a test checkout has not built.
  @moduletag :capture_log
  # The documentation is served from an empty directory of the test's own, built or not.
  @moduletag :tmp_dir

  import Phoenix.LiveViewTest

  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures, only: [extract_user_token: 1]
  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures, only: [github_description: 0]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{AccessKeys, Accounts, Connections, Features, Integrations, Policy}
  alias Apiary.{Secrets, Variables}
  alias Apiary.Runs.Projector

  # Routes no request can load, each with the reason.
  @skipped %{
    "/dev/storybook/assets/*asset" =>
      "the storybook's static files are served before it; the route raises for the rest"
  }

  # Routes that answer 404 to anyone here, each with the reason.
  @not_found %{
    "/docs" => "the documentation's directory is the test's own, and empty",
    "/docs/*path" => "a path under /docs that has no file"
  }

  # The query a route's page needs to draw.
  @query %{"/dev/storybook/visual_tests" => "?start=a&end=z"}

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:apiary, :docs_root, tmp_dir)
    on_exit(fn -> Application.delete_env(:apiary, :docs_root) end)
    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  setup :register_and_log_in_user

  setup %{scope: scope, user: user} do
    {:ok, params: params(scope, user)}
  end

  test "every page carries the policy and holds nothing it refuses",
       %{conn: conn, params: params} do
    {covered, unknown} =
      for route <- routes(), reduce: {[], []} do
        {covered, unknown} ->
          case urls(route, params) do
            {:ok, urls} ->
              {[{route, urls} | covered], unknown}

            {:unknown, names} ->
              {covered, ["#{route.path} (#{Enum.join(names, ", ")})" | unknown]}
          end
      end

    assert unknown == [],
           "routes with parameters this test does not fill; fill them in params/2 and " <>
             "value/3, or skip the route with a reason:\n" <> Enum.join(unknown, "\n")

    answers =
      for {route, urls} <- covered,
          url <- urls,
          {who, asker} <- [{"the owner", conn}, {"signed out", build_conn()}] do
        check(route, url, who, asker)
      end

    problems = Enum.flat_map(answers, &elem(&1, 1))
    assert problems == [], "pages the policy would break:\n" <> Enum.join(problems, "\n")

    # A nonce is never used twice.
    nonces = Enum.map(answers, &elem(&1, 0))
    assert length(Enum.uniq(nonces)) == length(nonces)
    # The storybook's stories, the console's pages and the development tools were loaded.
    assert length(covered) > 100
  end

  test "a path the router does not know is answered under the policy", %{conn: conn} do
    conn = get(conn, "/no-such-page/at-all/here")
    assert conn.status == 404
    nonce = conn.assigns.csp_nonce
    assert get_resp_header(conn, "content-security-policy") == [policy(nonce, "/no-such")]
  end

  test "the markup check refuses a fetched link or an address on another origin" do
    origin = ApiaryWeb.Endpoint.struct_url()
    other_port = "#{origin.scheme}://#{origin.host}:#{origin.port + 1}"
    other_scheme = "#{if origin.scheme == "https", do: "http", else: "https"}://#{origin.host}"

    for markup <- [
          ~s(<link rel="alternate icon" href="https://cdn.example.com/a.svg">),
          ~s(<link rel="Shortcut Icon" href="https://cdn.example.com/a.ico">),
          ~s(<link rel="modulepreload" href="https://cdn.example.com/a.js">),
          ~s(<link rel="prefetch" href="//cdn.example.com/a.js">),
          ~s(<link rel="manifest" href="https://cdn.example.com/m.json">),
          ~s(<script src="#{other_port}/assets/app.js"></script>),
          ~s(<img src="#{other_scheme}/a.png">),
          ~s(<form action="https://shop.example.com/x"></form>)
        ] do
      assert [_violation] = violations(LazyHTML.from_fragment(markup), "n"), markup
    end

    for markup <- [
          ~s(<link rel="alternate icon" href="/favicon.svg">),
          ~s(<link rel="alternate" href="https://example.com/feed">),
          ~s(<script src="#{origin.scheme}://#{origin.host}:#{origin.port}/assets/app.js"></script>),
          ~s(<img src="data:image/png;base64,AA==">)
        ] do
      assert violations(LazyHTML.from_fragment(markup), "n") == [], markup
    end
  end

  test "the documentation's policy allows ExDoc's inline script by its hash" do
    hash =
      :sha256
      |> :crypto.hash(ExDoc.Formatter.HTML.Assets.inline_js_source())
      |> Base.encode64()

    assert ApiaryWeb.ContentSecurityPolicy.ex_doc_script() == "sha256-" <> hash

    conn = get(build_conn(), "/docs/quickstart.html")
    [header] = get_resp_header(conn, "content-security-policy")
    assert header == policy(conn.assigns.csp_nonce, "/docs/quickstart.html")
    assert header =~ "'sha256-#{hash}'"
  end

  # Requests `url` as `who`, and returns the answer's nonce and what is wrong with it.
  defp check(route, url, who, conn) do
    conn = get(conn, url)
    where = "#{url} (#{route.path}), #{who}"
    nonce = conn.assigns[:csp_nonce]

    assert is_binary(nonce), "#{where}: no nonce"
    assert byte_size(Base.decode64!(nonce)) >= 16, "#{where}: a nonce of under 128 bits"

    header =
      if get_resp_header(conn, "content-security-policy") == [policy(nonce, url)],
        do: [],
        else: [
          "#{where}: not the policy: #{inspect(get_resp_header(conn, "content-security-policy"))}"
        ]

    status = if who == "the owner", do: answered(route, conn, where), else: []

    page =
      if html?(conn) do
        dead = violations(LazyHTML.from_document(conn.resp_body), nonce)

        connected =
          if conn.status == 200 and live?(route), do: connected_violations(conn, nonce), else: []

        Enum.map(dead, &"#{where}: #{&1}") ++ Enum.map(connected, &"#{where}, connected: #{&1}")
      else
        []
      end

    {nonce, header ++ status ++ page}
  end

  # The owner reaches every page: one that is not found for them was not loaded, and the
  # test would pass without having looked at it.
  defp answered(route, conn, where) do
    expected =
      cond do
        Map.has_key?(@not_found, route.path) -> [404]
        not feature_on?(route) -> [404]
        true -> [200, 301, 302, 303, 401]
      end

    if conn.status in expected, do: [], else: ["#{where}: answered #{conn.status}"]
  end

  # A LiveView's connected render: what the socket sends after the page loaded.
  defp connected_violations(conn, nonce) do
    case live(conn, nil, on_error: [duplicate_id: :ignore]) do
      {:ok, view, _html} -> violations(LazyHTML.from_fragment(render(view)), nonce)
      {:error, {_redirect, _to}} -> []
    end
  end

  defp html?(conn) do
    case get_resp_header(conn, "content-type") do
      ["text/html" <> _] -> true
      _ -> false
    end
  end

  defp live?(%{metadata: %{phoenix_live_view: _}}), do: true
  defp live?(_route), do: false

  defp feature_on?(%{metadata: %{phoenix_live_view: {module, _, _, _}}}), do: module_on?(module)
  defp feature_on?(%{plug: plug}), do: module_on?(plug)

  defp module_on?(module) do
    not function_exported?(Code.ensure_loaded!(module), :__feature__, 0) or
      Features.on?(module.__feature__())
  end

  # The policy as it must read, written out here so that a change to it is a change to
  # this test too.
  defp policy(nonce, url) do
    script =
      if String.starts_with?(url, "/docs"),
        do:
          "script-src 'self' 'nonce-#{nonce}' '#{ApiaryWeb.ContentSecurityPolicy.ex_doc_script()}'",
        else: "script-src 'self' 'nonce-#{nonce}'"

    frames =
      if String.starts_with?(url, "/dev/") and
           not String.starts_with?(url, "/dev/storybook/assets"),
         do: "'self'",
         else: "'none'"

    "default-src 'self'; #{script}; style-src 'self' 'unsafe-inline'; img-src 'self' data:; " <>
      "font-src 'self'; connect-src 'self' #{socket_origin()}; object-src 'none'; " <>
      "base-uri 'self'; form-action 'self'; frame-ancestors #{frames}"
  end

  defp socket_origin do
    %URI{host: host, port: port} = ApiaryWeb.Endpoint.struct_url()
    "ws://#{host}:#{port}"
  end

  ## What a page may not hold

  @handler ~r/^on[a-z]+$/i
  # Attributes that hold an address the browser follows or loads.
  @addresses ~w(href src action formaction xlink:href data poster)

  # A link the browser fetches: by any of its `rel` tokens, in any case ("alternate icon",
  # "alternate stylesheet", "shortcut icon" among them).
  @fetched_rels ~w(stylesheet preload modulepreload prefetch icon manifest)

  # What in `html` the policy refuses, one line each.
  defp violations(%LazyHTML{} = html, nonce) do
    html
    |> LazyHTML.to_tree()
    |> Enum.flat_map(&violations_in(&1, nonce))
  end

  defp violations_in({tag, attrs, children}, nonce) do
    attrs = Map.new(attrs, fn {name, value} -> {String.downcase(name), value} end)

    own =
      element_violations(tag, attrs, nonce) ++
        for {name, value} <- attrs, Regex.match?(@handler, name), do: "#{tag}[#{name}=#{value}]"

    srcdoc =
      case attrs do
        %{"srcdoc" => doc} -> violations(LazyHTML.from_document(doc), nonce)
        _ -> []
      end

    own ++ srcdoc ++ Enum.flat_map(children, &violations_in(&1, nonce))
  end

  defp violations_in(_text_or_comment, _nonce), do: []

  defp element_violations(tag, attrs, nonce) do
    javascript =
      for name <- @addresses,
          value = attrs[name],
          value |> String.trim() |> String.downcase() |> String.starts_with?("javascript:"),
          do: "#{tag}[#{name}=#{value}]"

    javascript ++ tag_violations(tag, attrs, nonce)
  end

  defp tag_violations("script", %{"src" => src}, _nonce),
    do: if(own?(src), do: [], else: ["script[src=#{src}]"])

  defp tag_violations("script", attrs, nonce),
    do: if(attrs["nonce"] == nonce, do: [], else: ["an inline script without the nonce"])

  defp tag_violations("base", _attrs, _nonce), do: ["base"]
  defp tag_violations(tag, _attrs, _nonce) when tag in ~w(object embed applet), do: [tag]

  defp tag_violations("link", %{"href" => href} = attrs, _nonce) do
    rels = (attrs["rel"] || "") |> String.downcase() |> String.split()

    if own?(href) or not Enum.any?(rels, &(&1 in @fetched_rels)),
      do: [],
      else: ["link[href=#{href}]"]
  end

  defp tag_violations("img", %{"src" => src}, _nonce),
    do: if(own?(src) or String.starts_with?(src, "data:"), do: [], else: ["img[src=#{src}]"])

  defp tag_violations(tag, %{"src" => src}, _nonce)
       when tag in ~w(iframe frame source video audio track),
       do: if(own?(src), do: [], else: ["#{tag}[src=#{src}]"])

  defp tag_violations("form", %{"action" => action}, _nonce),
    do: if(own?(action), do: [], else: ["form[action=#{action}]"])

  defp tag_violations(_tag, _attrs, _nonce), do: []

  # An address on the page's own origin: a path, or a full address of the endpoint's
  # scheme, host and port (one without a scheme, `//host/…`, takes the page's).
  defp own?(address) do
    origin = ApiaryWeb.Endpoint.struct_url()

    case URI.parse(address) do
      %URI{scheme: nil, host: nil} ->
        true

      %URI{} = uri ->
        scheme = String.downcase(uri.scheme || origin.scheme)
        port = uri.port || URI.default_port(scheme)
        host = uri.host && String.downcase(uri.host)
        {scheme, host, port} == {origin.scheme, String.downcase(origin.host), origin.port}
    end
  end

  ## The routes and their parameters

  # Every route a GET reaches: GETs, and the forwards, which take every method.
  defp routes do
    for %{verb: verb} = route <- ApiaryWeb.Router.__routes__(),
        verb in [:get, :*],
        not Map.has_key?(@skipped, route.path),
        do: route
  end

  # The addresses of `route`, its parameters filled; `{:unknown, names}` for parameters
  # this test does not fill.
  defp urls(%{path: path}, params) do
    segments = String.split(path, "/", trim: true)

    filled =
      for segment <- segments do
        case segment do
          ":" <> name -> value(name, path, params)
          "*" <> name -> value(name, path, params)
          literal -> {:ok, [literal]}
        end
      end

    case for({:unknown, name} <- filled, do: name) do
      [] ->
        urls =
          Enum.reduce(filled, [""], fn {:ok, values}, acc ->
            for prefix <- acc, value <- values, do: prefix <> "/" <> value
          end)

        query = Map.get(@query, path, "")
        {:ok, Enum.map(urls, &(if(&1 == "", do: "/", else: &1) <> query))}

      names ->
        {:unknown, names}
    end
  end

  # A parameter's values: most mean one thing wherever they are; `:id`, `:token`,
  # `:target_id` and the globs by the route they are in.
  defp value(name, path, params) do
    case value_of(name, path, params) do
      nil -> {:unknown, name}
      values when is_list(values) -> {:ok, values}
      value -> {:ok, [to_string(value)]}
    end
  end

  defp value_of("org", _path, p), do: p.org
  defp value_of("workspace", _path, p), do: p.workspace
  defp value_of("workspace_id", _path, p), do: p.second_workspace_id
  defp value_of("node_id", _path, p), do: p.node_id
  defp value_of("instance", _path, p), do: p.instance
  defp value_of("code_id", _path, p), do: p.code_id
  defp value_of("run_id", _path, p), do: p.run_id
  defp value_of("n", _path, _p), do: 1
  defp value_of("release_id", _path, p), do: p.release_id
  defp value_of("value_id", _path, p), do: p.value_id
  defp value_of("section", _path, _p), do: "runs"
  defp value_of("glob", _path, p), do: p.target_glob
  defp value_of("path", "/docs/*path", _p), do: "no-such-page.html"
  defp value_of("page", "/dev/dashboard" <> _, _p), do: "home"
  defp value_of("node", "/dev/dashboard" <> _, _p), do: Atom.to_string(node())
  # The visual tests and the iframe draw component stories only.
  defp value_of("story", "/dev/storybook/iframe/" <> _, p), do: hd(p.component_stories)
  defp value_of("story", "/dev/storybook/visual_tests/" <> _, p), do: p.component_stories
  defp value_of("story", "/dev/storybook/" <> _, p), do: p.stories

  defp value_of("key_id", _path, p), do: p.key_id

  defp value_of("target_id", path, p) do
    cond do
      String.contains?(path, "/settings/integrations/") -> p.target_id
      String.contains?(path, "/policy/targets/") -> p.target_id
      true -> nil
    end
  end

  defp value_of("token", path, p) do
    cond do
      String.starts_with?(path, "/users/log-in/") -> p.login_token
      String.starts_with?(path, "/users/settings/confirm-email/") -> p.login_token
      String.starts_with?(path, "/invitations/") -> p.invitation_token
      # Not the test link's: it leads to the page, and changes nothing.
      String.starts_with?(path, "/instance/mail/confirm/") -> p.login_token
      true -> nil
    end
  end

  defp value_of("rest", path, _p) do
    cond do
      String.starts_with?(path, "/:org/members/") -> "invite"
      String.contains?(path, "/policy/targets/") -> "history"
      true -> nil
    end
  end

  defp value_of("id", path, p) do
    cond do
      String.contains?(path, "/settings/people/") -> p.membership_id
      String.ends_with?(path, "/settings/secrets/:id/change-value") -> p.single_secret_id
      String.contains?(path, "/settings/secrets/") -> p.secret_id
      String.ends_with?(path, "/settings/variables/:id/unlock") -> p.locked_variable_id
      String.contains?(path, "/settings/variables/") -> p.variable_id
      String.contains?(path, "/settings/integrations/definitions/") -> p.definition_id
      String.ends_with?(path, "/settings/integrations/:id/version") -> p.integration_id
      String.contains?(path, "/settings/integrations/") -> p.runtime_id
      true -> nil
    end
  end

  defp value_of(_name, _path, _p), do: nil

  # One owner's records, one of each kind a page is about, in the states the pages that
  # act on them open in.
  defp params(scope, user) do
    second = workspace_fixture(scope.organisation, "Platform")
    %{membership: membership} = member_fixture(scope, :member)

    node = node_fixture(scope)
    instance_fixture(node, instance_id: "i_1", name: "build-01.example.com")
    # Made in a browser by the owner, so that its variables' page (`…/generated`) renders
    # for them, as well as its Forager file and its revocation.
    %{access_key: key} = browser_key_fixture(scope, node)
    {:ok, code, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

    run = run_fixture(scope)
    events_fixture(run, record())
    {:ok, run} = Projector.project(run)

    target = target!(scope, "acme/storefront")
    %{token: invitation} = invitation_fixture(scope, %{"email" => "dana@example.com"})

    login_token =
      extract_user_token(fn url -> Accounts.deliver_login_instructions(user, url) end)

    {stories, component_stories} = stories()

    base = %{
      org: scope.organisation.slug,
      workspace: scope.workspace.slug,
      second_workspace_id: second.id,
      membership_id: membership.id,
      node_id: node.public_id,
      instance: "i_1",
      key_id: key.key_id,
      code_id: code.id,
      run_id: run.run_id,
      target_id: target.id,
      target_glob: target.path,
      invitation_token: invitation,
      login_token: login_token,
      stories: stories,
      component_stories: component_stories
    }

    Map.merge(base, security_params(scope, target))
  end

  # The storybook's stories, and those of them that are a component's. The storybook is
  # compiled in the core's checkout alone (storybook_test.exs): an edition that runs this
  # test has neither the stories nor their routes.
  if Code.ensure_loaded?(ApiaryWeb.Storybook) do
    defp stories do
      stories =
        for entry <- ApiaryWeb.Storybook.leaves(), do: String.trim_leading(entry.path, "/")

      component_stories =
        for path <- stories,
            {:ok, story} = ApiaryWeb.Storybook.load_story(path),
            story.storybook_type() == :component,
            do: path

      {stories, component_stories}
    end
  else
    defp stories, do: {[], []}
  end

  # The records of the `security` feature; placeholders where the instance has not got
  # it, whose pages answer as paths that do not exist.
  defp security_params(scope, target) do
    if Features.on?(:security) do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "registry.example"})

      {:ok, secret} =
        Secrets.create_secret(scope, %{name: "FORGE_TOKEN", value: "x", value_id: "main-app"})

      {:ok, _value} = Secrets.add_value(scope, secret, %{value_id: "bot-app", value: "y"})
      {:ok, single} = Secrets.create_secret(scope, %{name: "DEPLOY_TOKEN", value: "x"})

      {:ok, variable} =
        Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: "production"})

      {:ok, locked} =
        Variables.create_variable(scope, :workspace, %{name: "LOG_LEVEL", value: "info"})

      {:ok, _locked} = Variables.lock_variable(scope, locked)

      {:ok, definition} =
        Connections.create_service_definition(scope, %{
          "version" => 1,
          "key" => "status-api",
          "title" => "Status API",
          "hosts" => ["status.example.com"],
          "auth" => %{"scheme" => "bearer", "secret" => "key"},
          "declares" => [%{"id" => "key", "title" => "API key", "name" => "STATUS_API_KEY"}]
        })

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      {:ok, runtime} = Connections.put_target(scope, runtime, target.id)

      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})

      {:ok, requested} =
        Integrations.request_release(scope, %{
          source: "codeberg.org/acme/shop-hooks",
          version: "1.4.0"
        })

      %{
        secret_id: secret.public_id,
        single_secret_id: single.public_id,
        value_id: "bot-app",
        variable_id: variable.id,
        locked_variable_id: locked.id,
        definition_id: definition.public_id,
        runtime_id: runtime.public_id,
        integration_id: integration.public_id,
        release_id: requested.id
      }
    else
      %{
        secret_id: "sec_none",
        single_secret_id: "sec_none",
        value_id: "none",
        variable_id: Ecto.UUID.generate(),
        locked_variable_id: Ecto.UUID.generate(),
        definition_id: "svc_none",
        runtime_id: "con_none",
        integration_id: "con_none",
        release_id: Ecto.UUID.generate()
      }
    end
  end
end
