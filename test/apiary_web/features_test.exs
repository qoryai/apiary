defmodule ApiaryWeb.FeaturesRoutesTest do
  # The core's routes held to the instance's features (`ApiaryWeb.RoutesFeaturesCase`): each
  # declares its feature, or is one every instance has. An edition's router, the core's
  # routes with its own, is held in the edition's tests.
  use ApiaryWeb.RoutesFeaturesCase, async: true, router: ApiaryWeb.Router
end

defmodule ApiaryWeb.FeaturesTest do
  # Not async: the tests switch the instance's features, which are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Phoenix.LiveViewTest

  alias Apiary.Policy
  alias ApiaryWeb.Contract.Configuration

  # Under the workspace's path, `/:org/:workspace`.
  @policy_paths [
    "/policy",
    "/policy/targets",
    "/policy/history",
    "/policy/document",
    "/policy/versions/1",
    "/policy/versions/1/export",
    "/policy/targets/00000000-0000-0000-0000-000000000000",
    "/policy/targets/00000000-0000-0000-0000-000000000000/history"
  ]

  setup :register_and_log_in_user

  # What a request is answered: the status, the body and the headers, all but the request's
  # own id and its nonce (`ApiaryWeb.ContentSecurityPolicy`). An error the endpoint renders
  # and raises again is taken as it was sent.
  defp answer(request) do
    conn = request.()
    {conn.status, without_nonce(conn.resp_body), headers(conn.resp_headers)}
  rescue
    _error ->
      {status, headers, body} = assert_error_sent(:not_found, request)
      {status, without_nonce(body), headers(headers)}
  end

  defp headers(headers) do
    headers
    |> Enum.reject(fn {name, _} -> name == "x-request-id" end)
    |> Enum.map(fn {name, value} -> {name, without_nonce(value)} end)
    |> Enum.sort()
  end

  defp without_nonce(text),
    do: String.replace(text, ~r/nonce(-|=")[A-Za-z0-9+\/=]+/, "nonce\\1…")

  # The workspace's policy made while the instance still had `security`, as on an instance
  # launched with it and restarted without: its rows stay, and nothing of it may show.
  defp managed_before_security_went(scope) do
    features = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())
    {:ok, _rule} = Policy.deny(scope, nil, %{host: "ads.example"})
    Application.put_env(:apiary, :features, features)
    assert Policy.managed?(scope)
  end

  describe "without security" do
    @describetag with_features: [:observability]

    test "the policy's pages answer as a path that does not exist, to anyone",
         %{conn: conn, scope: scope} do
      askers = [
        {"signed in", conn},
        {"anonymous", build_conn()},
        {"anonymous, asking for JSON", put_req_header(build_conn(), "accept", "application/json")}
      ]

      for {who, asker} <- askers, rest <- @policy_paths do
        path = workspace_path(scope, rest)

        assert answer(fn -> get(asker, path) end) ==
                 answer(fn -> get(asker, workspace_path(scope, "/no-such-page")) end),
               "#{path}, #{who}"
      end
    end

    # A policy removed mid-run never loosens a run already started: the reload is a signed
    # 404, never the document of no policy.
    test "a registration is answered the document of no policy; a reload, a signed 404", ctx do
      managed_before_security_went(ctx.scope)
      %{access_key: key, secret: secret} = contract_key_fixture(ctx.scope)
      run_id = Ecto.UUID.generate()

      conn = signed_register(build_conn(), key.key_id, secret, registration(run_id))
      assert conn.resp_body == ~s({"version":1})
      assert conn.status == 200
      assert signed_answer?(conn)

      assert get_resp_header(conn, "x-qory-run-configuration") == [
               Apiary.Policy.Render.digest(~s({"version":1}))
             ]

      for headers <- [[], [{"accept", "application/json"}]] do
        conn =
          signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id, headers: headers)

        assert json_response(conn, 404) == %{"error" => "not_found"}
        assert signed_answer?(conn)
        assert get_resp_header(conn, "x-qory-run-configuration") == []
      end
    end

    test "a live navigation to the policy is refused the same way", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      # The page is not mounted: the browser is told to load it, and gets the 404 above.

      assert {%{status: 404, reason: "reload"}, _call} =
               catch_exit(
                 live_redirect(view, to: ~p"/#{scope.organisation}/#{scope.workspace}/policy")
               )
    end

    test "discovery names the run endpoint, and a batch is answered no run configuration",
         ctx do
      managed_before_security_went(ctx.scope)
      %{access_key: key, secret: secret} = contract_key_fixture(ctx.scope)

      conn = signed_get(build_conn(), key.key_id, secret, "/.well-known/qory-configuration")
      assert conn.status == 200
      assert %{"url" => _} = Jason.decode!(conn.resp_body)["run"]
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(key)]

      {_subject, events} = first_events()
      conn = signed_post(build_conn(), key.key_id, secret, events)
      assert conn.status in 200..299
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(key)]
      assert get_resp_header(conn, "x-qory-run-configuration") == []
    end

    test "the context writes no policy, whichever surface asks", %{scope: scope} do
      for write <- [
            fn -> Policy.allow(scope, nil, %{host: "api.example"}) end,
            fn -> Policy.deny(scope, nil, %{host: "ads.example"}) end,
            fn -> Policy.set_mode(scope, "enforce") end
          ] do
        assert {:error, %Policy.Error{reason: :not_found}} = write.()
      end

      refute Policy.managed?(scope)
    end
  end

  describe "with every feature" do
    @describetag with_features: Apiary.Features.all()

    test "the policy's pages are there", %{conn: conn, scope: scope} do
      assert {:ok, _view, _html} =
               live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy")
    end

    test "a registration of a managed workspace is answered its policy, and so is a reload",
         ctx do
      {:ok, _rule} = Policy.deny(ctx.scope, nil, %{host: "ads.example"})
      %{access_key: key, secret: secret} = contract_key_fixture(ctx.scope)
      run_id = Ecto.UUID.generate()

      conn = signed_register(build_conn(), key.key_id, secret, registration(run_id))
      assert %{"security_policy" => _} = json_response(conn, 200)
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(key)]

      reload = signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)
      assert reload.resp_body == conn.resp_body
    end
  end
end
