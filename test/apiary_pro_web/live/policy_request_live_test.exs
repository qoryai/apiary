defmodule ApiaryProWeb.PolicyRequestLiveTest do
  # An operator's Policy requests page, where its owners and admins write and withdraw a
  # request and every person of it reads the answers; and a client's, where whoever writes
  # its policy accepts one in the workspaces they choose or declines it, and the
  # operator's people read. The policy page says when a request waits.
  # Not async: an operator is made by an instance admin, an owner of the suite's one
  # instance organisation, whose row it locks (docs/conventions.md, Tests).
  use ApiaryWeb.ConnCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query

  alias Apiary.{Policy, Repo}
  alias Apiary.Policy.Rule
  alias ApiaryPro.PolicyRequests
  alias ApiaryPro.PolicyRequests.{Answer, Request}

  defp world(_context) do
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    other = client_fixture(operator.scope, "Bolt")
    %{operator: operator, client: client, other: other}
  end

  defp send!(ctx, changes, note \\ "The harness calls its API.", clients \\ nil) do
    attrs = %{"changes" => changes, "note" => note}
    attrs = if clients, do: Map.put(attrs, "clients", clients), else: attrs
    {:ok, request} = PolicyRequests.send_request(ctx.operator.scope, attrs)
    request
  end

  defp answer_of(request, client),
    do: Repo.get_by!(Answer, request_id: request.id, organisation_id: client.organisation.id)

  defp hosts(workspace) do
    Repo.all(
      from r in Rule,
        where: r.workspace_id == ^workspace.id and is_nil(r.target_id),
        order_by: r.host,
        select: {r.host, r.action}
    )
  end

  # An element's words as they read: its text, the marked-up parts in it run in without a
  # space, as the letter and the address in hidden text after it.
  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # A person in a line: the first letter of their address, then the address.
  defp letter(email), do: String.upcase(String.first(email)) <> email

  @allow %{
    "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => "api.harness.example"}]
  }

  describe "the operator's page" do
    @describetag needs: [:managed_organisations, :security]
    setup :world

    test "its owner writes a request, change by change, and sends it to every client", ctx do
      conn = log_in_user(ctx.conn, ctx.operator.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients/requests")
      render_async(lv)
      assert has_element?(lv, "#requests-empty")
      refute has_element?(lv, "#requests-who")
      assert has_element?(lv, "#page-header-title", "Policy requests")
      assert has_element?(lv, "#page-header-actions #new-request")
      assert has_element?(lv, "aside#sidebar #nav-client_requests[aria-current=page]")
      # The list writes its own crumb, and its title names the organisation.
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Policy requests")
      assert page_title(lv) =~ "Policy requests · #{ctx.operator.organisation.name}"

      lv |> element("#new-request") |> render_click()
      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients/requests/new")
      # A page of the list, never a dialog: the breadcrumb ends Policy requests / New
      # request and leads back to the list, the form page has its title, and Send
      # request has Cancel back to the list beside it.
      refute has_element?(lv, "#requests-empty")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New request")
      assert page_title(lv) =~ "New request · Policy requests · #{ctx.operator.organisation.name}"

      assert has_element?(
               lv,
               "#breadcrumb a[href='/#{ctx.operator.organisation.slug}/clients/requests']"
             )

      assert has_element?(lv, "#request-new-title", "New policy request")

      assert has_element?(
               lv,
               "#request-form #request-save a#request-save-cancel[href='/#{ctx.operator.organisation.slug}/clients/requests']",
               "Cancel"
             )

      # The changes are a part of the page, no box inside the form: the draft first, then
      # the fields that add to it.
      assert has_element?(lv, "#request-changes-part #request-draft + #request-change-form")
      refute has_element?(lv, "#request-change-form.rounded-box")

      assert has_element?(lv, "#request-client-#{ctx.client.organisation.id}[checked]")
      assert has_element?(lv, "#request-client-#{ctx.other.organisation.id}[checked]")

      # A host the policy refuses is said there, and not added.
      lv
      |> form("#request-change-form", change: %{host: "Not A Host"})
      |> render_submit()

      assert has_element?(lv, "#request-change-error")
      assert has_element?(lv, "#request-draft-empty")

      lv
      |> form("#request-change-form", change: %{host: "api.harness.example", paths: "/v1/*"})
      |> render_submit()

      assert has_element?(lv, "#request-draft-0", "api.harness.example")

      # A removal: the form asks for the host, and nothing else.
      lv
      |> form("#request-change-form", change: %{change: "rule_removed"})
      |> render_change()

      refute has_element?(lv, "#change_action")
      refute has_element?(lv, "#change_paths")

      lv
      |> form("#request-change-form", change: %{change: "rule_removed", host: "old.example"})
      |> render_submit()

      assert has_element?(lv, "#request-draft-1", "old.example")
      lv |> element("#request-draft-1-remove") |> render_click()
      refute has_element?(lv, "#request-draft-1")

      # Without a note it is not sent.
      lv |> form("#request-form", request: %{note: ""}) |> render_submit()
      assert has_element?(lv, "#request-send-error")

      html =
        lv
        |> form("#request-form", request: %{note: "The harness calls its API.", mode: "enforce"})
        |> render_submit()

      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients/requests")
      assert html =~ "The request is sent to 2 clients."

      assert [%Request{changes: changes} = request] = Repo.all(Request)
      assert %{"mode" => "enforce", "rules" => [%{"rule" => %{"paths" => ["/v1/*"]}}]} = changes

      # A row a request: its name leads to its page, how many clients have answered, its
      # first change and how many more.
      render_async(lv)

      assert has_element?(
               lv,
               "#request-#{request.id}-link[href='/#{ctx.operator.organisation.slug}/clients/requests/#{request.id}']",
               "The harness calls its API."
             )

      assert has_element?(lv, "#request-#{request.id}-tally", "2 waiting")
      assert has_element?(lv, "#request-#{request.id}-first-change", "api.harness.example")
      assert has_element?(lv, "#request-#{request.id}-first-change", "and 1 more")

      # The name and the first change are one line each, cut to the cell, whole in their
      # titles.
      assert has_element?(
               lv,
               "#request-#{request.id}-link.q-title.q-cut.q-req-title[title='The harness calls its API.']"
             )

      refute has_element?(lv, "#request-#{request.id}-link.truncate")

      assert has_element?(
               lv,
               "#request-#{request.id}-first-change.q-cut[class*='max-w-[44ch]'][title*='api.harness.example'][title$='and 1 more']"
             )

      refute has_element?(lv, "#request-#{request.id}-first-change.truncate")

      {:ok, lv, _html} =
        live(conn, ~p"/#{ctx.operator.organisation}/clients/requests/#{request.id}")

      render_async(lv)
      assert has_element?(lv, "#page-header-title", "The harness calls its API.")
      assert has_element?(lv, "#page-header-description", "Sent on")
      assert has_element?(lv, "#request-#{request.id}-note", "The harness calls its API.")
      assert has_element?(lv, "#request-#{request.id}-changes", "api.harness.example")
      answer = answer_of(request, ctx.client)
      assert has_element?(lv, "#answer-#{answer.id}-state", "Pending")
      assert has_element?(lv, "#request-answers-part [role=region][aria-label=Answers]")
      assert has_element?(lv, "aside#sidebar #nav-client_requests[aria-current=page]")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "The harness calls its API.")

      assert has_element?(
               lv,
               "#breadcrumb [aria-current=page] [title='The harness calls its API.']"
             )

      assert page_title(lv) =~
               "The harness calls its API. · Policy requests · #{ctx.operator.organisation.name}"
    end

    test "only the clients chosen receive it", ctx do
      conn = log_in_user(ctx.conn, ctx.operator.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients/requests/new")

      lv |> form("#request-change-form", change: %{host: "api.example"}) |> render_submit()

      lv
      |> form("#request-form",
        request: %{
          note: "Needed.",
          clients: %{
            ctx.client.organisation.id => "true",
            ctx.other.organisation.id => "false"
          }
        }
      )
      |> render_submit()

      assert [%Answer{organisation_id: id}] = Repo.all(Answer)
      assert id == ctx.client.organisation.id
    end

    test "its owner withdraws a request, asked in place; an answer given stays", ctx do
      request = send!(ctx, @allow)

      {:ok, _} =
        PolicyRequests.decline(ctx.client.owner.scope, answer_of(request, ctx.client).id, "No")

      conn = log_in_user(ctx.conn, ctx.operator.user)
      list = ~p"/#{ctx.operator.organisation}/clients/requests"
      {:ok, lv, _html} = live(conn, list)
      render_async(lv)

      assert has_element?(lv, "#request-#{request.id}-tally", "1 declined, 1 waiting")
      assert has_element?(lv, "#request-#{request.id}-tally .q-hot", "1 declined")

      # Each part holds its words and the comma after them, and the space between two
      # parts is outside both: a narrow table breaks the line there, and no line starts
      # with a comma.
      tally = lv |> element("#request-#{request.id}-tally.q-req-tally") |> render()

      assert Regex.scan(~r{<span><span[^>]*>([^<]*)</span>(,?)</span>}, tally,
               capture: :all_but_first
             ) == [["1 declined", ","], ["1 waiting", ""]]

      refute tally =~ ~r/\s,/
      # The space between the parts, which the rendered HTML here leaves out as a node of
      # whitespace alone, is in the element's text.
      assert has_element?(lv, "#request-#{request.id}-tally", ~r/^1 declined, 1 waiting$/)

      # Withdraw… in the row's menu opens the row's question at a path of its own, and
      # does nothing by itself; Cancel goes back.
      lv |> element("#request-#{request.id}-withdraw") |> render_click()
      assert_patch(lv, list <> "/#{request.id}/withdraw")
      assert has_element?(lv, "#request-#{request.id}-confirm", "Withdraw “The harness calls")
      assert has_element?(lv, "#request-#{request.id}-confirm", "from the 1 client that has")
      assert has_element?(lv, "#request-#{request.id}-withdraw-confirm.btn-error")
      assert Repo.reload!(request).withdrawn_at == nil

      lv |> element("#request-#{request.id}-confirm-cancel") |> render_click()
      assert_patch(lv, list)
      refute has_element?(lv, "#request-#{request.id}-confirm")

      {:ok, lv, _html} = live(conn, list <> "/#{request.id}/withdraw")
      render_async(lv)
      html = lv |> element("#request-#{request.id}-withdraw-confirm") |> render_click()
      assert html =~ "The request is withdrawn from the clients that had not answered it."
      assert_patch(lv, list)
      render_async(lv)

      assert has_element?(lv, "#request-#{request.id}.row-off")
      assert has_element?(lv, "#request-#{request.id}-withdrawn")
      refute has_element?(lv, "#request-#{request.id}-withdraw")

      {:ok, lv, _html} = live(conn, list <> "/#{request.id}")
      render_async(lv)
      assert has_element?(lv, "#request-#{request.id}-withdrawn", "Withdrawn")
      refute has_element?(lv, "#request-#{request.id}-withdraw-open")
      declined = answer_of(request, ctx.client)
      assert has_element?(lv, "#answer-#{declined.id}-state", "Declined")
      assert has_element?(lv, "#answer-#{declined.id}-details", "Reason: No")
      assert has_element?(lv, "#answer-#{answer_of(request, ctx.other).id}-state", "Withdrawn")
      assert answer_of(request, ctx.client).state == :declined
    end

    test "a request's page leads to the row that asks to withdraw it", ctx do
      request = send!(ctx, @allow)
      conn = log_in_user(ctx.conn, ctx.operator.user)

      {:ok, lv, _html} =
        live(conn, ~p"/#{ctx.operator.organisation}/clients/requests/#{request.id}")

      render_async(lv)

      # Each client leads to itself while it is the operator's.
      answer = answer_of(request, ctx.client)

      assert has_element?(
               lv,
               "#answer-#{answer.id}-client a[href='/#{ctx.client.organisation.slug}']"
             )

      assert {:ok, lv, _html} =
               lv
               |> element("#request-#{request.id}-withdraw-open")
               |> render_click()
               |> follow_redirect(
                 conn,
                 ~p"/#{ctx.operator.organisation}/clients/requests/#{request.id}/withdraw"
               )

      render_async(lv)
      assert has_element?(lv, "#request-#{request.id}-confirm")
    end

    test "a dropped client no longer leads to itself from a request's page", ctx do
      request = send!(ctx, @allow)

      {:ok, _} =
        ApiaryPro.Transfers.drop(
          ctx.operator.scope,
          ctx.client.organisation.id,
          ctx.client.organisation.name
        )

      conn = log_in_user(ctx.conn, ctx.operator.user)

      {:ok, lv, _html} =
        live(conn, ~p"/#{ctx.operator.organisation}/clients/requests/#{request.id}")

      render_async(lv)

      answer = answer_of(request, ctx.client)
      assert has_element?(lv, "#answer-#{answer.id}-client", ctx.client.organisation.name)
      refute has_element?(lv, "#answer-#{answer.id}-client a")
      assert has_element?(lv, "#answer-#{answer.id}-details", "The client was dropped")
    end

    test "a request not among the rows read says so", ctx do
      conn = log_in_user(ctx.conn, ctx.operator.user)
      id = Ecto.UUID.generate()
      list = ~p"/#{ctx.operator.organisation}/clients/requests"

      {:ok, lv, html} = live(conn, ~p"/#{ctx.operator.organisation}/clients/requests/#{id}")

      # While the rows load, the breadcrumb ends with Policy requests; once they are read,
      # with the request asked for, by the first 8 characters of its id.
      assert crumbs(html, :organisation) == [{"Policy requests", list}]

      render_async(lv)
      assert has_element?(lv, "#request-gone", "older than the 200 newest")

      assert crumbs(lv, :organisation) == [
               {"Policy requests", list},
               {"Request #{String.slice(id, 0, 8)}", nil}
             ]

      assert has_element?(
               lv,
               "#breadcrumb [aria-current=page]",
               "Request #{String.slice(id, 0, 8)}"
             )

      assert has_element?(
               lv,
               "#request-gone a[href='/#{ctx.operator.organisation.slug}/clients/requests']",
               "Back to the policy requests"
             )
    end

    test "the views, the search and the Client filter narrow the list", ctx do
      waiting = send!(ctx, @allow, "Waiting on both.")

      answered =
        send!(
          ctx,
          %{
            "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => "cdn.example"}]
          },
          "Answered by both."
        )

      for client <- [ctx.client, ctx.other] do
        {:ok, _} =
          PolicyRequests.decline(client.owner.scope, answer_of(answered, client).id, nil)
      end

      withdrawn = send!(ctx, @allow, "Withdrawn soon.")
      {:ok, _} = PolicyRequests.withdraw(ctx.operator.scope, withdrawn.id)

      only_acme =
        send!(ctx, @allow, "Only for Acme.", [ctx.client.organisation.id])

      conn = log_in_user(ctx.conn, ctx.operator.user)
      list = ~p"/#{ctx.operator.organisation}/clients/requests"
      {:ok, lv, _html} = live(conn, list)
      render_async(lv)

      assert has_element?(lv, "#requests-view-all[aria-current=page]", "4")
      assert has_element?(lv, "#requests-view-waiting", "2")
      assert has_element?(lv, "#requests-view-answered", "1")
      assert has_element?(lv, "#requests-view-withdrawn", "1")
      refute has_element?(lv, "#requests-summary")
      refute has_element?(lv, "#requests-capped")

      lv |> element("#requests-view-waiting") |> render_click()
      assert_patch(lv, list <> "?view=waiting")
      assert has_element?(lv, "#request-#{waiting.id}")
      assert has_element?(lv, "#request-#{only_acme.id}")
      refute has_element?(lv, "#request-#{answered.id}")
      refute has_element?(lv, "#request-#{withdrawn.id}")

      {:ok, lv, _html} = live(conn, list <> "?view=withdrawn")
      render_async(lv)
      assert has_element?(lv, "#request-#{withdrawn.id}.row-off")
      refute has_element?(lv, "#request-#{waiting.id}")

      # The search: a host, a client's name, words of the note, whatever their case.
      {:ok, lv, _html} = live(conn, list)
      render_async(lv)
      lv |> form("#requests-search", q: "CDN.example") |> render_change()
      assert_patch(lv, list <> "?q=CDN.example")
      assert has_element?(lv, "#request-#{answered.id}")
      refute has_element?(lv, "#request-#{waiting.id}")
      assert has_element?(lv, "#requests-summary", "1 request matches")
      assert has_element?(lv, "#requests-view-all", "1")

      lv |> form("#requests-search", q: "bolt") |> render_change()
      assert has_element?(lv, "#request-#{waiting.id}")
      refute has_element?(lv, "#request-#{only_acme.id}")
      assert has_element?(lv, "#requests-summary", "3 requests match")

      lv |> form("#requests-search", q: "nothing like it") |> render_change()
      assert has_element?(lv, "#requests-none", "No request matches")
      assert has_element?(lv, "#requests-none", "No request has that note, host or client.")
      lv |> element("#requests-none-clear") |> render_click()
      assert_patch(lv, list)

      # The Client filter: one client at a time, its token under the bar.
      lv |> element("#requests-filter-client-#{ctx.other.organisation.id}") |> render_click()
      assert_patch(lv, list <> "?client=#{ctx.other.organisation.id}")
      assert has_element?(lv, "#requests-token-client", "To Bolt")
      assert has_element?(lv, "#requests-token-client a[aria-label='Remove the filter To Bolt']")

      assert has_element?(
               lv,
               "#requests-filter-client-#{ctx.other.organisation.id}[aria-checked=true]"
             )

      assert has_element?(lv, "#request-#{waiting.id}")
      refute has_element?(lv, "#request-#{only_acme.id}")
      assert has_element?(lv, "#requests-view-all", "3")

      # A view with none says so in its own words.
      lv |> element("#requests-tokens-clear") |> render_click()
      assert_patch(lv, list)

      {:ok, _} = PolicyRequests.withdraw(ctx.operator.scope, waiting.id)
      {:ok, _} = PolicyRequests.withdraw(ctx.operator.scope, only_acme.id)
      {:ok, lv, _html} = live(conn, list <> "?view=waiting")
      render_async(lv)
      assert has_element?(lv, "#requests-none", "No request here")
      assert has_element?(lv, "#requests-none", "Every request is answered.")
    end

    test "only the 200 newest requests are listed, and the list says so", ctx do
      now = DateTime.utc_now()

      Repo.insert_all(
        Request,
        for n <- 1..200 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: ctx.operator.organisation.id,
            author_id: ctx.operator.user.id,
            note: "Request #{n}",
            changes: @allow,
            inserted_at: DateTime.add(now, -n, :second)
          }
        end
      )

      conn = log_in_user(ctx.conn, ctx.operator.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients/requests")
      render_async(lv)
      assert has_element?(lv, "#requests-capped", "Only the 200 newest requests are listed.")
    end

    test "its member reads a request, and withdraws none", ctx do
      request = send!(ctx, @allow)
      member = member_fixture(ctx.operator.scope, :member)
      conn = log_in_user(ctx.conn, member.user)
      list = ~p"/#{ctx.operator.organisation}/clients/requests"

      {:ok, lv, _html} = live(conn, list)
      render_async(lv)
      assert has_element?(lv, "#request-#{request.id}-link")
      refute has_element?(lv, "#request-#{request.id}-withdraw")
      refute has_element?(lv, "#request-#{request.id}-menu-button")
      refute has_element?(lv, "#requests-who")

      {:ok, lv, _html} = live(conn, list <> "/#{request.id}")
      render_async(lv)
      assert has_element?(lv, "#request-#{request.id}-note")
      refute has_element?(lv, "#request-#{request.id}-withdraw-open")

      assert {:error, {:live_redirect, %{to: ^list, flash: %{"error" => error}}}} =
               live(conn, list <> "/#{request.id}/withdraw")

      assert error =~ "withdraw its policy requests"
    end

    test "its member reads the requests, and writes and withdraws none", ctx do
      member = member_fixture(ctx.operator.scope, :member)
      conn = log_in_user(ctx.conn, member.user)

      # With none sent, the empty list says who sends one.
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients/requests")
      render_async(lv)

      assert has_element?(lv, "#requests-empty")
      refute has_element?(lv, "#new-request")
      refute has_element?(lv, "#page-header-actions")
      assert has_element?(lv, "#requests-empty #requests-who", "send a request or withdraw one")
      assert has_element?(lv, "#requests-who", "send a request or withdraw one")

      assert {:error, {:live_redirect, %{flash: %{"error" => _}}}} =
               live(conn, ~p"/#{ctx.operator.organisation}/clients/requests/new")
    end
  end

  describe "the client's page" do
    @describetag needs: [:managed_organisations, :security]
    setup :world

    test "its owner answers a request on its page, accepting it in the workspaces chosen",
         ctx do
      staging = workspace_fixture(ctx.client.organisation, "Staging")
      request = send!(ctx, @allow)
      answer = answer_of(request, ctx.client)

      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"
      {:ok, lv, _html} = live(conn, list)
      render_async(lv)

      # The shell's page header; the organisation's sidebar, with its Policy requests
      # current.
      assert has_element?(lv, "#page-header-title", "Policy requests")
      assert has_element?(lv, "#page-header-description", "The policy is yours")
      assert has_element?(lv, "aside#sidebar #nav-policy_requests[aria-current=page]")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Policy requests")
      assert page_title(lv) =~ "Policy requests · #{ctx.client.organisation.name}"
      assert has_element?(lv, "#received-#{answer.id}-from", ctx.operator.organisation.name)
      assert has_element?(lv, "#received-#{answer.id}-link", "The harness calls its API.")
      assert has_element?(lv, "#received-#{answer.id}-first-change", "api.harness.example")
      assert has_element?(lv, "#received-#{answer.id}-state", "Pending")

      assert {:ok, lv, _html} =
               lv
               |> element("#received-#{answer.id}-answer-link")
               |> render_click()
               |> follow_redirect(conn, list <> "/#{answer.id}")

      render_async(lv)
      assert has_element?(lv, "#page-header-title", "The harness calls its API.")
      assert has_element?(lv, "#page-header-description", ctx.operator.organisation.name)
      assert has_element?(lv, "#received-#{answer.id}-state", "Pending")
      assert has_element?(lv, "#received-#{answer.id}-note", "The harness calls its API.")
      assert has_element?(lv, "#received-#{answer.id}-changes", "api.harness.example")
      assert has_element?(lv, "#received-#{answer.id}-workspace-#{staging.id}[checked]")
      assert has_element?(lv, "aside#sidebar #nav-policy_requests[aria-current=page]")

      assert page_title(lv) =~
               "The harness calls its API. · Policy requests · #{ctx.client.organisation.name}"

      assert {:ok, lv, html} =
               lv
               |> form("#received-#{answer.id}-accept",
                 workspaces: %{ctx.client.workspace.id => "true", staging.id => "false"}
               )
               |> render_submit()
               |> follow_redirect(conn, list)

      assert html =~ "the changes are made in 1 workspace"
      render_async(lv)
      assert has_element?(lv, "#received-#{answer.id}-state", "Accepted")
      refute has_element?(lv, "#received-#{answer.id}-answer-link")
      assert hosts(ctx.client.workspace) == [{"api.harness.example", "allow"}]
      assert hosts(staging) == []

      {:ok, lv, _html} = live(conn, list <> "/#{answer.id}")
      render_async(lv)
      assert has_element?(lv, "#received-#{answer.id}-answer", ctx.client.workspace.name)
      refute has_element?(lv, "#received-#{answer.id}-accept")
    end

    test "an acceptance that no longer fits says why, and makes nothing", ctx do
      owner = ctx.client.owner.scope
      {:ok, _} = Policy.deny(owner, nil, %{host: "locked.example", locked: true})

      request =
        send!(ctx, %{
          "rules" => [
            %{"change" => "rule_added", "action" => "allow", "host" => "api.harness.example"},
            %{"change" => "rule_removed", "host" => "locked.example"}
          ]
        })

      answer = answer_of(request, ctx.client)
      admin = client_member_fixture(ctx.client, :admin)
      conn = log_in_user(ctx.conn, admin.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.client.organisation}/policy-requests/#{answer.id}")
      render_async(lv)

      lv |> form("#received-#{answer.id}-accept") |> render_submit()

      assert has_element?(lv, "#received-#{answer.id}-refused", "locked")
      assert hosts(ctx.client.workspace) == [{"locked.example", "deny"}]
      assert Repo.reload!(answer).state == :pending
    end

    test "its member declines a request, with a reason, asked in place", ctx do
      request = send!(ctx, @allow)
      answer = answer_of(request, ctx.client)
      member = client_member_fixture(ctx.client, :member)
      conn = log_in_user(ctx.conn, member.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"

      {:ok, lv, _html} = live(conn, list)
      render_async(lv)

      # Decline… in the row's menu opens the row's question at a path of its own, and
      # declines nothing by itself; Cancel goes back.
      lv |> element("#received-#{answer.id}-decline-link") |> render_click()
      assert_patch(lv, list <> "/#{answer.id}/decline")
      assert has_element?(lv, "#received-#{answer.id}-decline-confirm", "Decline “The harness")
      assert has_element?(lv, "#received-#{answer.id}-decline-confirm", "Nothing changes")
      refute has_element?(lv, "#received-#{answer.id}-decline-button.btn-error")
      assert Repo.reload!(answer).state == :pending

      lv |> element("#received-#{answer.id}-decline-confirm-cancel") |> render_click()
      assert_patch(lv, list)
      refute has_element?(lv, "#received-#{answer.id}-decline")

      lv |> element("#received-#{answer.id}-decline-link") |> render_click()

      html =
        lv
        |> form("#received-#{answer.id}-decline", decline: %{reason: "Not this quarter."})
        |> render_submit()

      assert html =~ "Declined: nothing changes in the policy."
      assert_patch(lv, list)
      render_async(lv)
      assert has_element?(lv, "#received-#{answer.id}-state", "Declined")
      refute has_element?(lv, "#received-#{answer.id}-menu")
      assert %Answer{state: :declined, reason: "Not this quarter."} = Repo.reload!(answer)

      {:ok, lv, _html} = live(conn, list <> "/#{answer.id}")
      render_async(lv)
      assert has_element?(lv, "#received-#{answer.id}-answer", "Not this quarter.")
    end

    test "the answer page's Decline… leads to the row that asks", ctx do
      request = send!(ctx, @allow)
      answer = answer_of(request, ctx.client)
      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"

      {:ok, lv, _html} = live(conn, list <> "/#{answer.id}")
      render_async(lv)

      assert {:ok, lv, _html} =
               lv
               |> element("#received-#{answer.id}-decline-open")
               |> render_click()
               |> follow_redirect(conn, list <> "/#{answer.id}/decline")

      render_async(lv)
      assert has_element?(lv, "#received-#{answer.id}-decline-confirm")
      assert has_element?(lv, "#received-#{answer.id}-reason")
    end

    test "an acceptance in no workspace is answered in the form, and makes nothing", ctx do
      staging = workspace_fixture(ctx.client.organisation, "Staging")
      request = send!(ctx, @allow)
      answer = answer_of(request, ctx.client)
      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.client.organisation}/policy-requests/#{answer.id}")
      render_async(lv)

      html =
        lv
        |> form("#received-#{answer.id}-accept",
          workspaces: %{ctx.client.workspace.id => "false", staging.id => "false"}
        )
        |> render_submit()

      assert has_element?(
               lv,
               "#received-#{answer.id}-refused",
               "Choose at least one workspace to accept it in."
             )

      assert has_element?(
               lv,
               ~s|#received-#{answer.id}-accept fieldset[aria-describedby="received-#{answer.id}-refused"]|
             )

      refute html =~ "is not there any more"
      assert hosts(ctx.client.workspace) == []
      assert Repo.reload!(answer).state == :pending

      # Refused for another reason, the form no longer says what it said before: the
      # workspace chosen was deleted meanwhile.
      {:ok, _} =
        Apiary.Deletion.delete_workspace(ctx.client.owner.scope, staging.id, staging.slug)

      html =
        lv
        |> form("#received-#{answer.id}-accept",
          workspaces: %{ctx.client.workspace.id => "false", staging.id => "true"}
        )
        |> render_submit()

      assert html =~ "is not there any more"
      render_async(lv)
      assert has_element?(lv, "#received-#{answer.id}-accept")
      refute has_element?(lv, "#received-#{answer.id}-refused")
      refute has_element?(lv, "#received-#{answer.id}-accept fieldset[aria-describedby]")
      assert Repo.reload!(answer).state == :pending
    end

    test "a reason too long to decline with is answered under its field", ctx do
      request = send!(ctx, @allow)
      answer = answer_of(request, ctx.client)
      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"
      {:ok, lv, _html} = live(conn, list <> "/#{answer.id}/decline")
      render_async(lv)

      lv
      |> form("#received-#{answer.id}-decline", decline: %{reason: String.duplicate("a", 501)})
      |> render_submit()

      assert has_element?(
               lv,
               "#received-#{answer.id}-reason-error",
               "The reason is at most 500 characters."
             )

      assert has_element?(lv, ~s|#received-#{answer.id}-reason[aria-invalid="true"]|)
      refute has_element?(lv, "#flash-error")
      assert Repo.reload!(answer).state == :pending

      # The reason is kept as it was typed, to shorten, in the row that still asks.
      assert has_element?(
               lv,
               ~s|#received-#{answer.id}-reason[value="#{String.duplicate("a", 501)}"]|
             )

      lv
      |> form("#received-#{answer.id}-decline", decline: %{reason: "Not this quarter."})
      |> render_submit()

      assert_patch(lv, list)
      render_async(lv)
      refute has_element?(lv, "#received-#{answer.id}-reason-error")
      assert has_element?(lv, "#received-#{answer.id}-state", "Declined")
      assert %Answer{state: :declined, reason: "Not this quarter."} = Repo.reload!(answer)
    end

    test "a member added to no workspace reads the requests and answers none", ctx do
      request = send!(ctx, @allow)
      answer = answer_of(request, ctx.client)
      member = client_member_fixture(ctx.client, :member)

      {:ok, _} =
        ApiaryPro.WorkspaceAccess.remove(
          ctx.client.owner.scope,
          member.membership.id,
          ctx.client.workspace.id
        )

      conn = log_in_user(ctx.conn, member.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"
      {:ok, lv, _html} = live(conn, list)
      render_async(lv)

      assert has_element?(lv, "#received-#{answer.id}-link")
      refute has_element?(lv, "#received-#{answer.id}-answer-link")
      refute has_element?(lv, "#received-#{answer.id}-menu")

      {:ok, lv, _html} = live(conn, list <> "/#{answer.id}")
      render_async(lv)
      assert has_element?(lv, "#received-#{answer.id}-note")
      assert has_element?(lv, "#received-#{answer.id}-waiting")
      refute has_element?(lv, "#received-#{answer.id}-accept")
      refute has_element?(lv, "#received-#{answer.id}-decline-open")

      assert {:error, {:live_redirect, %{to: ^list, flash: %{"error" => _}}}} =
               live(conn, list <> "/#{answer.id}/decline")
    end

    test "the operator's people read the requests and answer none", ctx do
      request = send!(ctx, @allow)
      answer = answer_of(request, ctx.client)
      conn = log_in_user(ctx.conn, ctx.operator.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"

      {:ok, lv, _html} = live(conn, list)
      render_async(lv)
      assert has_element?(lv, "#requests-read-only")
      refute has_element?(lv, "#received-#{answer.id}-answer-link")
      refute has_element?(lv, "#received-#{answer.id}-menu")

      {:ok, lv, _html} = live(conn, list <> "/#{answer.id}")
      render_async(lv)
      assert has_element?(lv, "#requests-read-only")
      assert has_element?(lv, "#received-#{answer.id}-note")
      assert has_element?(lv, "#received-#{answer.id}-waiting")
      refute has_element?(lv, "#received-#{answer.id}-accept")

      assert {:error, {:live_redirect, %{to: ^list, flash: %{"error" => _}}}} =
               live(conn, list <> "/#{answer.id}/decline")
    end

    test "the views and the search narrow the list", ctx do
      waiting = send!(ctx, @allow, "Waiting here.")

      declined =
        send!(
          ctx,
          %{
            "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => "cdn.example"}]
          },
          "Declined here."
        )

      {:ok, _} =
        PolicyRequests.decline(ctx.client.owner.scope, answer_of(declined, ctx.client).id, nil)

      withdrawn = send!(ctx, @allow, "Withdrawn here.")
      {:ok, _} = PolicyRequests.withdraw(ctx.operator.scope, withdrawn.id)

      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"
      {:ok, lv, _html} = live(conn, list)
      render_async(lv)

      [w, d, x] = Enum.map([waiting, declined, withdrawn], &answer_of(&1, ctx.client))
      assert has_element?(lv, "#received-view-all[aria-current=page]", "3")
      assert has_element?(lv, "#received-view-waiting", "1")
      assert has_element?(lv, "#received-view-answered", "1")
      assert has_element?(lv, "#received-view-withdrawn", "1")
      assert has_element?(lv, "#received-#{w.id}-answer-link")

      lv |> element("#received-view-answered") |> render_click()
      assert_patch(lv, list <> "?view=answered")
      assert has_element?(lv, "#received-#{d.id}")
      refute has_element?(lv, "#received-#{w.id}")
      refute has_element?(lv, "#received-#{x.id}")

      {:ok, lv, _html} = live(conn, list)
      render_async(lv)
      lv |> form("#received-search", q: "CDN.EXAMPLE") |> render_change()
      assert_patch(lv, list <> "?q=CDN.EXAMPLE")
      assert has_element?(lv, "#received-#{d.id}")
      refute has_element?(lv, "#received-#{w.id}")
      assert has_element?(lv, "#received-summary", "1 request matches")

      lv |> form("#received-search", q: "here") |> render_change()
      assert has_element?(lv, "#received-summary", "3 requests match")

      lv |> form("#received-search", q: "nothing like it") |> render_change()
      assert has_element?(lv, "#received-none", "No request matches")
      assert has_element?(lv, "#received-none", "No request has that note or host.")
      lv |> element("#received-none-clear") |> render_click()
      assert_patch(lv, list)

      {:ok, _} = PolicyRequests.decline(ctx.client.owner.scope, w.id, nil)
      {:ok, lv, _html} = live(conn, list <> "?view=waiting")
      render_async(lv)
      assert has_element?(lv, "#received-none", "No request here")
      assert has_element?(lv, "#received-none", "Every request is answered.")
    end

    test "an answer not among the rows read says so", ctx do
      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      id = Ecto.UUID.generate()
      list = ~p"/#{ctx.client.organisation}/policy-requests"

      {:ok, lv, html} = live(conn, ~p"/#{ctx.client.organisation}/policy-requests/#{id}")

      # While the rows load, the breadcrumb ends with Policy requests; once they are read,
      # with the request asked for, by the first 8 characters of its id.
      assert crumbs(html, :organisation) == [{"Policy requests", list}]

      render_async(lv)
      assert has_element?(lv, "#received-gone", "older than the 200 newest")

      assert crumbs(lv, :organisation) == [
               {"Policy requests", list},
               {"Request #{String.slice(id, 0, 8)}", nil}
             ]

      assert has_element?(
               lv,
               "#breadcrumb [aria-current=page]",
               "Request #{String.slice(id, 0, 8)}"
             )
    end

    test "the policy page says a request waits, and leads to it", ctx do
      request = send!(ctx, @allow)
      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      path = ~p"/#{ctx.client.organisation}/#{ctx.client.workspace}/policy"

      {:ok, lv, _html} = live(conn, path)

      assert has_element?(
               lv,
               "#policy-requests-pending a[href='/#{ctx.client.organisation.slug}/policy-requests']"
             )

      {:ok, _} =
        PolicyRequests.decline(ctx.client.owner.scope, answer_of(request, ctx.client).id, nil)

      {:ok, lv, _html} = live(conn, path)
      refute has_element?(lv, "#policy-requests-pending")
    end
  end

  describe "who sent a request" do
    @describetag needs: [:managed_organisations, :security]
    setup :world

    test "is their letter, a tab stop, the address its hint, or Former member", ctx do
      admin = member_fixture(ctx.operator.scope, :admin)
      theirs = send!(%{ctx | operator: admin}, @allow, "The harness calls its API.")
      mine = send!(ctx, @allow, "The harness reads its docs.")
      email = admin.user.email
      you = "#{ctx.operator.user.email} (you)"

      conn = log_in_user(ctx.conn, ctx.operator.user)
      list = ~p"/#{ctx.operator.organisation}/clients/requests"
      {:ok, lv, _html} = live(conn, list)
      render_async(lv)

      # The By column.
      abbr = ~s{abbr[tabindex="0"][data-tip="#{email}"][aria-label="#{email}"]}
      assert has_element?(lv, "#request-#{theirs.id} td #{abbr} > .sr-only", email)
      mine_abbr = ~s{#request-#{mine.id} td abbr[tabindex="0"][data-tip="#{you}"]}
      assert has_element?(lv, mine_abbr)

      # A request's page: the line under the title.
      {:ok, lv, _html} = live(conn, list <> "/#{theirs.id}")
      render_async(lv)
      sent = "Sent on #{ApiaryWeb.Format.date(theirs.inserted_at)} by"
      assert words(lv, "#page-header-description") == "#{sent} #{letter(email)}."
      assert has_element?(lv, "#page-header-description #{abbr}")

      {:ok, _} = Apiary.Accounts.delete_user(admin.user)

      {:ok, lv, _html} = live(conn, list)
      render_async(lv)
      assert words(lv, "#request-#{theirs.id}") =~ "Former member"
      refute has_element?(lv, "#request-#{theirs.id} abbr")
      refute render(lv) =~ email

      {:ok, lv, _html} = live(conn, list <> "/#{theirs.id}")
      render_async(lv)
      assert words(lv, "#page-header-description") == "#{sent} Former member."
      refute has_element?(lv, "#page-header-description abbr")
    end
  end

  describe "who answered a request" do
    @describetag needs: [:managed_organisations, :security]
    setup :world

    test "is their letter, a tab stop, the address its hint, or Former member", ctx do
      admin = member_fixture(ctx.client.owner.scope, :admin)
      accepted = answer_of(send!(ctx, @allow, "The harness calls its API."), ctx.client)
      declined = answer_of(send!(ctx, @allow, "The harness reads its docs."), ctx.client)
      bare = answer_of(send!(ctx, @allow, "The harness sends its logs."), ctx.client)

      main = ctx.client.workspace
      {:ok, _} = PolicyRequests.accept(ctx.client.owner.scope, accepted.id, [main.id])

      {:ok, _} = PolicyRequests.decline(admin.scope, declined.id, "Not this quarter.")
      {:ok, _} = PolicyRequests.decline(admin.scope, bare.id, nil)

      email = admin.user.email
      you = "#{ctx.client.owner.user.email} (you)"
      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      list = ~p"/#{ctx.client.organisation}/policy-requests"

      answer = fn answer ->
        {:ok, lv, _html} = live(conn, list <> "/#{answer.id}")
        render_async(lv)
        {lv, "#received-#{answer.id}-answer"}
      end

      {lv, line} = answer.(accepted)
      assert words(lv, line) == "Accepted by #{letter(you)} in #{main.name}"
      assert has_element?(lv, ~s{#{line} abbr[tabindex="0"][data-tip="#{you}"]})

      abbr = ~s{abbr[tabindex="0"][data-tip="#{email}"][aria-label="#{email}"]}
      {lv, line} = answer.(declined)
      assert words(lv, line) == "Declined by #{letter(email)}: Not this quarter."
      assert has_element?(lv, "#{line} #{abbr} > .sr-only", email)

      {lv, line} = answer.(bare)
      assert words(lv, line) == "Declined by #{letter(email)}"
      assert has_element?(lv, "#{line} #{abbr}")

      {:ok, _} = Apiary.Accounts.delete_user(admin.user)

      {lv, line} = answer.(declined)
      assert words(lv, line) == "Declined by Former member: Not this quarter."
      refute has_element?(lv, "#{line} abbr")

      {lv, line} = answer.(bare)
      assert words(lv, line) == "Declined by Former member"
      refute has_element?(lv, "#{line} abbr")
    end
  end

  describe "the client's sidebar" do
    @describetag needs: [:managed_organisations, :security]
    setup :world

    test "a client's organisation leads to its policy requests, after Policy", ctx do
      conn = log_in_user(ctx.conn, ctx.client.owner.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.client.organisation}/audit-log")

      assert has_element?(
               lv,
               "aside#sidebar a#nav-policy_requests[href='/#{ctx.client.organisation.slug}/policy-requests']",
               "Policy requests"
             )

      # After the organisation's Policy, where it has one.
      html = lv |> element("aside#sidebar") |> render()

      if html =~ ~s|id="nav-organisation_policy"| do
        [_before, after_policy] = String.split(html, ~s|id="nav-organisation_policy"|, parts: 2)
        assert after_policy =~ ~s|id="nav-policy_requests"|
      end
    end

    test "an organisation that is no client has none", ctx do
      conn = log_in_user(ctx.conn, ctx.operator.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/audit-log")
      assert has_element?(lv, "aside#sidebar #nav-client_requests")
      refute has_element?(lv, "aside#sidebar #nav-policy_requests")
    end
  end

  describe "without the security policy" do
    @describetag with_features: [:observability, :managed_organisations]
    setup :world

    test "neither page is there, and nothing leads to them", ctx do
      conn = log_in_user(ctx.conn, ctx.operator.user)
      {:ok, lv, _html} = live(conn, ~p"/#{ctx.operator.organisation}/clients")
      render_async(lv)
      refute has_element?(lv, "aside#sidebar #nav-client_requests")
      refute has_element?(lv, "a[href*='/clients/requests']")

      assert get(conn, ~p"/#{ctx.operator.organisation}/clients/requests").status == 404

      owner = log_in_user(build_conn(), ctx.client.owner.user)
      assert get(owner, ~p"/#{ctx.client.organisation}/policy-requests").status == 404

      id = Ecto.UUID.generate()
      assert get(conn, ~p"/#{ctx.operator.organisation}/clients/requests/#{id}").status == 404
      assert get(owner, ~p"/#{ctx.client.organisation}/policy-requests/#{id}").status == 404

      # The client's sidebar has no Policy requests.
      {:ok, lv, _html} = live(owner, ~p"/#{ctx.client.organisation}/audit-log")
      assert has_element?(lv, "aside#sidebar")
      refute has_element?(lv, "#nav-policy_requests")
    end
  end
end
