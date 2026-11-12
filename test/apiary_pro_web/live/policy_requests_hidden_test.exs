defmodule ApiaryProWeb.PolicyRequestsHiddenTest do
  # An operator's policy requests while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`): not found for everyone, their pages
  # not found, nothing leads to them, the policy page says nothing of them and the Action
  # filter does not offer them; their old entries still read. With the flag off, all of it
  # is as it was.
  # The flag is set for this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Features, Repo}
  alias ApiaryPro.{Flags, PolicyRequests}
  alias ApiaryPro.PolicyRequests.Answer

  @moduletag with_features: Features.all()

  @labels [
    "Policy request sent",
    "Policy request withdrawn",
    "Policy request accepted",
    "Policy request declined"
  ]

  @allow %{
    "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => "api.harness.example"}]
  }

  # The operator, a client, and a request of the operator's pending in the client, sent
  # while the flag was off.
  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")

    {:ok, request} =
      PolicyRequests.send_request(operator.scope, %{
        "changes" => @allow,
        "note" => "The harness calls its API."
      })

    answer =
      Repo.get_by!(Answer, request_id: request.id, organisation_id: client.organisation.id)

    %{operator: operator, client: client, request: request, answer: answer}
  end

  defp entry(organisation, action) do
    Repo.one(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^organisation.id and e.action == ^Atom.to_string(action),
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  defp audit_log(conn, organisation) do
    {:ok, view, _html} = live(conn, "/#{organisation.slug}/audit-log")
    render_async(view)
    view
  end

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp filter_options(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#filter-action-form li")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp operator_pages(ctx) do
    operator = ctx.operator.organisation.slug
    id = ctx.request.id

    [
      "/#{operator}/clients/requests",
      "/#{operator}/clients/requests/new",
      "/#{operator}/clients/requests/#{id}",
      "/#{operator}/clients/requests/#{id}/withdraw"
    ]
  end

  defp client_pages(ctx) do
    client = ctx.client.organisation.slug
    id = ctx.answer.id

    [
      "/#{client}/policy-requests",
      "/#{client}/policy-requests/#{id}",
      "/#{client}/policy-requests/#{id}/decline"
    ]
  end

  describe "while the operator owns its clients" do
    setup do: Flags.put_operator_infrastructure(true)

    test "each action is not found, for those who would take it", ctx do
      operator = ctx.operator.scope
      owner = ctx.client.owner.scope

      for action <- [:"policy_request.send", :"policy_request.withdraw"] do
        assert Access.authorize(operator, action, ctx.operator.organisation) ==
                 {:error, :not_found}
      end

      for action <- [:"policy_request.accept", :"policy_request.decline"] do
        assert Access.authorize(owner, action, ctx.client.organisation) == {:error, :not_found}
      end

      assert PolicyRequests.send_request(operator, %{"changes" => @allow, "note" => "Again."}) ==
               {:error, :not_found}

      assert PolicyRequests.withdraw(operator, ctx.request.id) == {:error, :not_found}

      assert PolicyRequests.accept(owner, ctx.answer.id, [ctx.client.workspace.id]) ==
               {:error, :not_found}

      assert PolicyRequests.decline(owner, ctx.answer.id, nil) == {:error, :not_found}
      assert Repo.reload!(ctx.answer).state == :pending
    end

    test "their pages are not found", ctx do
      operator = log_in_user(build_conn(), ctx.operator.user)
      owner = log_in_user(build_conn(), ctx.client.owner.user)

      for path <- operator_pages(ctx) do
        assert_raise ApiaryWeb.NotFound, fn -> live(operator, path) end
      end

      for path <- client_pages(ctx) do
        assert_raise ApiaryWeb.NotFound, fn -> live(owner, path) end
      end

      # The operator's person reads the client: its page is not found for them too.
      assert_raise ApiaryWeb.NotFound, fn ->
        live(operator, "/#{ctx.client.organisation.slug}/policy-requests")
      end
    end

    test "nothing leads to them: the sidebars and the policy page", ctx do
      operator = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(operator, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "aside#sidebar #nav-clients")
      refute has_element?(lv, "aside#sidebar #nav-client_requests")
      refute has_element?(lv, "a[href*='/clients/requests']")

      owner = log_in_user(build_conn(), ctx.client.owner.user)
      {:ok, lv, _html} = live(owner, ~p"/#{ctx.client.organisation}/audit-log")
      assert has_element?(lv, "aside#sidebar")
      refute has_element?(lv, "#nav-policy_requests")
      refute has_element?(lv, "a[href*='/policy-requests']")

      {:ok, lv, _html} =
        live(owner, ~p"/#{ctx.client.organisation}/#{ctx.client.workspace}/policy")

      refute has_element?(lv, "#policy-requests-pending")
      refute has_element?(lv, "a[href*='/policy-requests']")
    end

    test "the Action filter does not offer them", ctx do
      operator = log_in_user(build_conn(), ctx.operator.user)
      owner = log_in_user(build_conn(), ctx.client.owner.user)

      for {conn, organisation} <- [
            {operator, ctx.operator.organisation},
            {owner, ctx.client.organisation}
          ] do
        options = filter_options(audit_log(conn, organisation))
        assert options != []
        for label <- @labels, do: refute(label in options, "#{label} is offered")
      end
    end

    test "entries made before still read in their words", ctx do
      # A second request, declined while the flag was off.
      Flags.put_operator_infrastructure(false)

      {:ok, declined} =
        PolicyRequests.send_request(ctx.operator.scope, %{
          "changes" => @allow,
          "note" => "Another call."
        })

      answer =
        Repo.get_by!(Answer, request_id: declined.id, organisation_id: ctx.client.organisation.id)

      {:ok, _} = PolicyRequests.decline(ctx.client.owner.scope, answer.id, nil)
      Flags.put_operator_infrastructure(true)

      view = audit_log(log_in_user(build_conn(), ctx.operator.user), ctx.operator.organisation)
      sent = entry(ctx.operator.organisation, :"policy_request.send")
      assert text(view, "#entry-#{sent.id}-action") =~ "Sent a policy request to"

      declined = entry(ctx.operator.organisation, :"policy_request.decline")
      assert text(view, "#entry-#{declined.id}-action") =~ "Acme declined a policy request"

      view = audit_log(log_in_user(build_conn(), ctx.client.owner.user), ctx.client.organisation)
      operator = ctx.operator.organisation.name
      sent = entry(ctx.client.organisation, :"policy_request.send")
      assert text(view, "#entry-#{sent.id}-action") =~ "#{operator} sent a policy request"

      declined = entry(ctx.client.organisation, :"policy_request.decline")

      assert text(view, "#entry-#{declined.id}-action") =~
               "Declined a policy request of #{operator}"
    end
  end

  describe "with the flag off" do
    test "every action is as it was", ctx do
      operator = ctx.operator.scope
      owner = ctx.client.owner.scope

      for action <- [:"policy_request.send", :"policy_request.withdraw"],
          do: assert(Access.authorize(operator, action, ctx.operator.organisation) == :ok)

      for action <- [:"policy_request.accept", :"policy_request.decline"],
          do: assert(Access.authorize(owner, action, ctx.client.organisation) == :ok)

      assert {:ok, _} = PolicyRequests.decline(owner, ctx.answer.id, nil)
    end

    test "their pages open, and the sidebars and the policy page lead to them", ctx do
      operator = log_in_user(build_conn(), ctx.operator.user)
      owner = log_in_user(build_conn(), ctx.client.owner.user)

      for path <- operator_pages(ctx), do: assert({:ok, _lv, _html} = live(operator, path))

      for path <- Enum.take(client_pages(ctx), 2),
          do: assert({:ok, _lv, _html} = live(owner, path))

      {:ok, lv, _html} = live(operator, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "aside#sidebar #nav-client_requests")

      {:ok, lv, _html} = live(owner, ~p"/#{ctx.client.organisation}/audit-log")
      assert has_element?(lv, "aside#sidebar #nav-policy_requests")

      {:ok, lv, _html} =
        live(owner, ~p"/#{ctx.client.organisation}/#{ctx.client.workspace}/policy")

      assert has_element?(
               lv,
               "#policy-requests-pending a[href='/#{ctx.client.organisation.slug}/policy-requests']"
             )
    end

    test "the Action filter offers them", ctx do
      operator = log_in_user(build_conn(), ctx.operator.user)
      options = filter_options(audit_log(operator, ctx.operator.organisation))
      for label <- @labels, do: assert(label in options, "#{label} is not offered")
    end
  end
end
