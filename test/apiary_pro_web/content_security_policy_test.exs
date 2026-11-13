defmodule ApiaryProWeb.ContentSecurityPolicyTest do
  @moduledoc """
  The content security policy (`ApiaryWeb.ContentSecurityPolicy`) held to the edition's
  pages, as the core's test (`ApiaryWeb.ContentSecurityPolicyTest`) holds it to the core's:
  each LiveView route of the edition's router (`ApiaryProWeb.Router`) whose page is the
  edition's, its parameters filled from records in the state the page opens in, is
  requested as the person the page is for, with every feature on. The answer carries the
  policy with a fresh nonce, and its HTML, the dead render and the connected one, holds
  nothing the policy refuses or the console leaves out: a script without the nonce or from
  elsewhere, an `on…=` attribute, a `javascript:` address, a `style=` attribute, a `<base>`,
  a plug-in, a stylesheet, image, frame or form target on another origin.

  A new route of the edition's fails the test until it is filled here, or listed under
  `@exceptions` with the reason no request here can load it.

  What no test without a browser sees: a script or a style a bundle creates while it runs,
  and a header a reverse proxy strips or replaces.
  """
  use ApiaryWeb.ConnCase, async: true

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Policy}
  alias ApiaryPro.{OrganisationVariables, PolicyRequests, Suspensions, Transfers}

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # The edition's routes no request here can load, each with the reason. None today.
  @exceptions %{}

  setup do
    {:ok, world: world()}
  end

  test "every page of the edition's carries the policy and holds nothing it refuses", %{
    world: world
  } do
    pages = for route <- routes(), not Map.has_key?(@exceptions, route.path), do: route

    {known, unknown} = Enum.split_with(pages, &page(&1.path))

    assert unknown == [],
           "the edition's routes this test does not open; fill them in page/1, or list them under " <>
             "@exceptions with the reason:\n" <> Enum.map_join(unknown, "\n", & &1.path)

    answers = for route <- known, do: flagged(route, fn -> check(route, world) end)

    problems = Enum.flat_map(answers, &elem(&1, 1))

    assert problems == [],
           "pages the policy would break, or not looked at:\n" <> Enum.join(problems, "\n")

    # A nonce is never used twice.
    nonces = Enum.map(answers, &elem(&1, 0))
    assert length(Enum.uniq(nonces)) == length(nonces)
    # The edition's pages were loaded: the instance's, the organisation's and the operator's.
    assert length(known) >= 40
  end

  test "the markup check refuses an inline style, a handler and a script without the nonce" do
    for markup <- [
          ~s(<p style="color: red">x</p>),
          ~s[<button onclick="go()">x</button>],
          ~s[<a href="javascript:go()">x</a>],
          ~s[<script>go()</script>],
          ~s[<script nonce="other">go()</script>]
        ] do
      assert [_violation] = violations(LazyHTML.from_fragment(markup), "n"), markup
    end

    for markup <- [
          ~s(<p class="q-muted">x</p>),
          ~s(<button phx-click="go">x</button>),
          ~s[<script nonce="n">go()</script>],
          ~s(<script src="/assets/js/app.js"></script>)
        ] do
      assert violations(LazyHTML.from_fragment(markup), "n") == [], markup
    end
  end

  # The pages there are only while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`) are opened with it on, and only they.
  @operator_owns ["/:org/clients/:id/admin"]

  defp flagged(%{path: path}, fun) when path in @operator_owns do
    ApiaryPro.Flags.put_operator_infrastructure(true)

    try do
      fun.()
    after
      ApiaryPro.Flags.put_operator_infrastructure(false)
    end
  end

  defp flagged(_route, fun), do: fun.()

  # Requests the route's page as the person it is for, and returns the answer's nonce and
  # what is wrong with it.
  defp check(route, world) do
    {who, url} = fill(route.path, world)
    conn = get(world.conns[who], url)
    where = "#{url} (#{route.path}), #{who}"
    nonce = conn.assigns[:csp_nonce]

    assert is_binary(nonce), "#{where}: no nonce"

    header =
      case get_resp_header(conn, "content-security-policy") do
        [policy] ->
          if String.contains?(policy, "script-src 'self' 'nonce-#{nonce}'"),
            do: [],
            else: ["#{where}: not the page's nonce: #{policy}"]

        other ->
          ["#{where}: not one policy: #{inspect(other)}"]
      end

    # The page drew at its own address: a page that sends its reader elsewhere as it
    # opens was not looked at.
    status = if conn.status == 200, do: [], else: ["#{where}: answered #{conn.status}"]

    page =
      if conn.status == 200 do
        dead = violations(LazyHTML.from_document(conn.resp_body), nonce)
        connected = connected_violations(conn, nonce)
        Enum.map(dead, &"#{where}: #{&1}") ++ Enum.map(connected, &"#{where}, connected: #{&1}")
      else
        []
      end

    {nonce, header ++ status ++ page}
  end

  # A LiveView's connected render, once what it loads after mounting has arrived.
  defp connected_violations(conn, nonce) do
    case live(conn, nil, on_error: [duplicate_id: :ignore]) do
      {:ok, view, _html} ->
        render_async(view)
        violations(LazyHTML.from_fragment(render(view)), nonce)

      {:error, {kind, %{to: to}}} ->
        ["sent to #{to} (#{kind}) once connected"]
    end
  end

  ## What a page may not hold (as `ApiaryWeb.ContentSecurityPolicyTest`, with `style=`)

  @handler ~r/^on[a-z]+$/i
  # Attributes that hold an address the browser follows or loads.
  @addresses ~w(href src action formaction xlink:href data poster)

  # A link the browser fetches: by any of its `rel` tokens, in any case.
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
        for {name, value} <- attrs,
            Regex.match?(@handler, name) or name == "style",
            do: "#{tag}[#{name}=#{value}]"

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
  # scheme, host and port.
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

  ## The edition's routes, who opens each, and its parameters

  # Every LiveView route of the edition's router whose page is the edition's; the core's pages are
  # the core's test's.
  defp routes do
    for %{verb: :get, metadata: %{phoenix_live_view: {module, _, _, _}}} = route <-
          ApiaryProWeb.Router.__routes__(),
        String.starts_with?(inspect(module), "ApiaryProWeb."),
        do: route
  end

  # Who opens the page of `path`, and the organisation and the id its parameters name, by
  # their names in the world: `{who, org, id}`; nil for a path this test does not know.
  defp page("/users/organisations/new"), do: {:owner, nil, nil}
  defp page("/users/register"), do: {:signed_out, nil, nil}
  defp page("/instance/organisations"), do: {:instance_admin, nil, nil}
  defp page("/instance/organisations/new"), do: {:instance_admin, nil, nil}
  defp page("/instance/organisations/:id/kind"), do: {:instance_admin, nil, :org_id}
  defp page("/instance/organisations/:id/suspend"), do: {:instance_admin, nil, :org_id}
  defp page("/instance/organisations/:id/features"), do: {:instance_admin, nil, :org_id}
  # A purge is of a suspended organisation.
  defp page("/instance/organisations/:id/purge"), do: {:instance_admin, nil, :suspended_id}
  # The arbiter's transfer is of an organisation whose owners may not act.
  defp page("/instance/organisations/:id/transfer"),
    do: {:instance_admin, nil, :arbitrated_id}

  defp page("/instance/accounts"), do: {:instance_admin, nil, nil}
  defp page("/instance/accounts/:id/suspend"), do: {:instance_admin, nil, :member_user_id}

  defp page("/:org/settings/people/:id/workspaces"), do: {:owner, :org, :membership_id}
  defp page("/:org/settings/ownership"), do: {:owner, :org, nil}
  defp page("/:org/settings/ownership/transfer"), do: {:owner, :org, nil}
  # The withdrawal of a pending offer, and the leaving of an operator, by a client.
  defp page("/:org/settings/ownership/withdraw"), do: {:offering_owner, :offering, nil}
  defp page("/:org/settings/ownership/leave"), do: {:client_owner, :client, nil}
  defp page("/:org/settings/variables"), do: {:owner, :org, nil}
  defp page("/:org/settings/variables/new"), do: {:owner, :org, nil}
  defp page("/:org/settings/variables/:id/change"), do: {:owner, :org, :variable_id}
  defp page("/:org/settings/variables/:id/lock"), do: {:owner, :org, :variable_id}
  defp page("/:org/settings/variables/:id/unlock"), do: {:owner, :org, :locked_variable_id}
  defp page("/:org/settings/variables/:id/delete"), do: {:owner, :org, :variable_id}
  defp page("/:org/settings/secrets"), do: {:owner, :org, nil}
  defp page("/:org/settings/secrets/new"), do: {:owner, :org, nil}
  defp page("/:org/settings/secrets/:id/edit"), do: {:owner, :org, :secret_id}
  defp page("/:org/settings/secrets/:id/add-value"), do: {:owner, :org, :secret_id}
  defp page("/:org/settings/secrets/:id/change-value"), do: {:owner, :org, :secret_id}
  defp page("/:org/settings/secrets/:id/delete"), do: {:owner, :org, :secret_id}

  defp page("/:org/settings/secrets/:id/values/:value_id/" <> act)
       when act in ~w(change rename delete),
       do: {:owner, :org, :values_secret_id}

  defp page("/:org/policy"), do: {:owner, :org, nil}
  defp page("/:org/policy/workspaces"), do: {:owner, :org, nil}
  defp page("/:org/policy/history"), do: {:owner, :org, nil}
  defp page("/:org/policy/rules/new"), do: {:owner, :org, nil}
  defp page("/:org/policy/rules/:id/edit"), do: {:owner, :org, :org_rule_id}
  defp page("/:org/policy-requests"), do: {:client_owner, :client, nil}
  defp page("/:org/policy-requests/:id"), do: {:client_owner, :client, :answer_id}
  defp page("/:org/policy-requests/:id/decline"), do: {:client_owner, :client, :answer_id}
  defp page("/:org/clients"), do: {:operator_owner, :operator, nil}
  defp page("/:org/clients/new"), do: {:operator_owner, :operator, nil}
  defp page("/:org/clients/requests"), do: {:operator_owner, :operator, nil}
  defp page("/:org/clients/requests/new"), do: {:operator_owner, :operator, nil}
  defp page("/:org/clients/requests/:id"), do: {:operator_owner, :operator, :request_id}

  defp page("/:org/clients/requests/:id/withdraw"),
    do: {:operator_owner, :operator, :request_id}

  # An owner is invited to a client that has none.
  defp page("/:org/clients/:id/owner"), do: {:operator_owner, :operator, :ownerless_client_id}
  defp page("/:org/clients/:id/admin"), do: {:operator_owner, :operator, :ownerless_client_id}
  defp page("/:org/clients/:id/features"), do: {:operator_owner, :operator, :client_id}
  defp page("/:org/clients/:id/drop"), do: {:operator_owner, :operator, :client_id}
  defp page("/:org/clients/:id/delete"), do: {:operator_owner, :operator, :client_id}
  # The organisation offered to the operator.
  defp page("/:org/clients/offers/:id/accept"), do: {:operator_owner, :operator, :offering_id}
  defp page(_path), do: nil

  # The route's address, its parameters filled from the world, and who opens it.
  defp fill(path, world) do
    {who, org, id} = page(path)

    url =
      path
      |> String.split("/")
      |> Enum.map_join("/", fn
        ":org" -> world.values[org]
        ":id" -> world.values[id]
        ":workspace_id" -> world.values[id]
        ":value_id" -> world.values.value_id
        segment -> segment
      end)

    {who, url}
  end

  ## The world

  # The people each page is for, logged in, and the records the pages are about, in the
  # states they open in: an owner's organisation with a member, a second workspace, its
  # variables, its secrets and its policy; an organisation offered to an operator; the
  # operator, with a client whose owner signed up, one with no owner yet, and a request of
  # the operator's to the client, pending; an organisation suspended; and one whose
  # owner's account is, with an admin.
  defp world do
    admin = suite_instance_admin()

    owner = sign_up_fixture()
    second = workspace_fixture(owner.organisation, "Platform")
    member = member_fixture(owner.scope, :member)

    {:ok, variable} =
      OrganisationVariables.create(owner.scope, %{name: "REGISTRY_URL", value: "x"})

    {:ok, locked} =
      OrganisationVariables.create(owner.scope, %{
        name: "REGION",
        value: "eu-west-1",
        locked: true
      })

    {:ok, secret} =
      Apiary.Secrets.create_organisation_secret(owner.scope, %{
        "name" => "FORGE_TOKEN",
        "value" => "x"
      })

    {:ok, values_secret} =
      Apiary.Secrets.create_organisation_secret(owner.scope, %{
        "name" => "REGISTRY_KEY",
        "values" => %{
          "0" => %{"value_id" => "main-app", "value" => "a"},
          "1" => %{"value_id" => "bot-app", "value" => "b"}
        }
      })

    {:ok, org_rule} = ApiaryPro.OrganisationPolicy.deny(owner.scope, %{host: "org.example"})

    operator = operator_fixture(%{organisation_name: "Hive Ops"})
    client = client_fixture(operator.scope, "Acme")

    {%{organisation: ownerless}, _token} =
      create_client_fixture(operator.scope, %{
        "name" => "Shop",
        "email" => "dana@example.com"
      })

    {:ok, _rule} = Policy.deny(client.owner.scope, nil, %{host: "locked.example", locked: true})

    {:ok, request} =
      PolicyRequests.send_request(operator.scope, %{
        "changes" => %{
          "rules" => [
            %{"change" => "rule_changed", "action" => "allow", "host" => "locked.example"}
          ]
        },
        "note" => "The build calls it."
      })

    answer =
      Apiary.Repo.get_by!(PolicyRequests.Answer,
        request_id: request.id,
        organisation_id: client.organisation.id
      )

    offering = sign_up_fixture()
    {:ok, _} = Transfers.offer_to_operator(offering.scope, operator.organisation.slug)

    suspended = sign_up_fixture()
    {:ok, _} = Suspensions.suspend_organisation(admin.instance_scope, suspended.organisation.id)

    arbitrated = sign_up_fixture()
    member_fixture(arbitrated.scope, :admin)
    {:ok, _} = Suspensions.suspend_account(admin.instance_scope, arbitrated.user.id)

    %{
      conns: %{
        owner: log_in_user(build_conn(), owner.user),
        signed_out: build_conn(),
        instance_admin: log_in_user(build_conn(), admin.user),
        offering_owner: log_in_user(build_conn(), offering.user),
        client_owner: log_in_user(build_conn(), client.owner.user),
        operator_owner: log_in_user(build_conn(), operator.user)
      },
      values: %{
        org: owner.organisation.slug,
        org_id: owner.organisation.id,
        offering: offering.organisation.slug,
        offering_id: offering.organisation.id,
        client: client.organisation.slug,
        client_id: client.organisation.id,
        ownerless_client_id: ownerless.id,
        operator: operator.organisation.slug,
        suspended_id: suspended.organisation.id,
        arbitrated_id: arbitrated.organisation.id,
        member_user_id: member.user.id,
        membership_id: member.membership.id,
        workspace_id: second.id,
        variable_id: variable.id,
        locked_variable_id: locked.id,
        secret_id: secret.public_id,
        values_secret_id: values_secret.public_id,
        value_id: "main-app",
        org_rule_id: org_rule.id,
        request_id: request.id,
        answer_id: answer.id
      }
    }
  end
end
