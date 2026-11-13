defmodule ApiaryProWeb.FeaturePartsLiveTest do
  # A part of a feature hidden from a person, the run's Terminal,
  # `:"observability.terminal"` (`ApiaryPro.Features.hidden/1`): while
  # `ApiaryPro.Flags.feature_visibility?/0` is on, the Features pages show or hide it
  # under Runs, and a person it is hidden from finds the run's log nowhere, as the core
  # gates it, while the organisation's nodes still record it. With the switch off no page
  # offers it and no row hides it.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.ContractFixtures
  import Apiary.RunEventsFixtures, only: [started_data: 1]
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Features, Repo}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Event, Projector, Run}
  alias ApiaryPro.{Flags, Grants}
  alias ApiaryPro.Grants.Grant

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  @terminal :"observability.terminal"
  @description "The run's log: the Terminal tab, the last lines on the Runs list, Raw log and Download log. Runs still record it while it is hidden."

  # An operator shown Runs, the security policy and the run's Terminal; its client, whose
  # workspace has a node, shown what the operator is, and a run of that node with a line
  # in its terminal, as the node posted it.
  defp chain do
    %{instance_scope: admin} = suite_instance_admin()
    operator = operator_fixture()

    Flags.put_feature_visibility(true)

    assert {:ok, _} =
             Grants.set_organisation(admin, operator.organisation.id, [
               "observability",
               "security",
               "observability.terminal"
             ])

    client = client_fixture(operator.scope, "Acme")
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(client.owner.scope)

    Repo.update_all(from(n in Node, where: n.id == ^node.id), set: [gateway_choice: :direct])

    run_id = Ecto.UUID.generate()
    conn = signed_register(build_conn(), key.key_id, secret, Jason.encode!(registration(run_id)))
    assert json_response(conn, 200)

    posted =
      signed_post(build_conn(), key.key_id, secret, [
        wire_event(run_id, 2, "run.started", started_data(%{"interactive" => true})),
        wire_event(run_id, 3, "run.log", %{
          "stream" => "terminal",
          "bytes" => Base.encode64("hello from the node\n")
        })
      ])

    assert posted.status == 202
    run = Repo.one!(from r in Run, where: r.node_run_id == ^run_id)
    {:ok, run} = Projector.project(run)

    %{
      admin: admin,
      operator: operator,
      client: client,
      key: {key, secret},
      run: run
    }
  end

  defp run_path(ctx, tail \\ ""),
    do: ~p"/#{ctx.client.organisation}/#{ctx.client.workspace}/runs/#{ctx.run}" <> tail

  defp hide_from_client(ctx) do
    assert {:ok, _} =
             Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, ["observability"])
  end

  defp events_of(run), do: Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count)

  describe "a person the run's Terminal is hidden from" do
    setup do
      ctx = chain()
      hide_from_client(ctx)
      ctx
    end

    test "finds no Terminal tab, no log in the more menu, and no /terminal", ctx do
      conn = log_in_user(build_conn(), ctx.client.owner.user)
      {:ok, lv, html} = live(conn, run_path(ctx))

      refute has_element?(lv, "#run-tab-terminal")
      assert has_element?(lv, "#run-tab-timeline")
      refute has_element?(lv, "#run-menu-raw")
      refute has_element?(lv, "#run-menu-download")
      refute html =~ "/runs/#{ctx.run.number}/log"
      refute html =~ "/runs/#{ctx.run.number}/terminal"

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, run_path(ctx, "/terminal")) end
    end

    test "is answered not found at the log's address, every stream and the download", ctx do
      conn = log_in_user(build_conn(), ctx.client.owner.user)

      for query <- ~w(? ?stream=terminal ?stream=stdout ?stream=stderr ?download=1) do
        answer = get(conn, run_path(ctx, "/log") <> query)
        assert answer.status == 404, query
        refute answer.resp_body =~ "hello from the node"
        assert get_resp_header(answer, "content-disposition") == []
      end
    end

    test "sees no last lines of the log on the Runs list", ctx do
      conn = log_in_user(build_conn(), ctx.client.owner.user)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{ctx.client.organisation}/#{ctx.client.workspace}/runs?run=#{ctx.run.number}"
        )

      render_hook(lv, "viewport", %{"wide" => true})
      render_async(lv)

      refute has_element?(lv, "#runs-preview-log")
      refute has_element?(lv, "#runs-preview a", "Full log")
      refute render(lv) =~ "hello from the node"
    end

    test "while the node still records the log, which the operator's people read", ctx do
      {key, secret} = ctx.key
      before = events_of(ctx.run)

      posted =
        signed_post(build_conn(), key.key_id, secret, [
          wire_event(ctx.run.node_run_id, 4, "run.log", %{
            "stream" => "terminal",
            "bytes" => Base.encode64("still recorded\n")
          })
        ])

      assert posted.status == 202
      assert events_of(ctx.run) == before + 1
      {:ok, _run} = Projector.project(ctx.run)

      # The operator's people, in the client, see what the operator sees: the log.
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, run_path(ctx))
      assert has_element?(lv, "#run-tab-terminal")

      answer = get(conn, run_path(ctx, "/log") <> "?stream=terminal")
      assert answer.status == 200
      assert answer.resp_body =~ "hello from the node"
      assert answer.resp_body =~ "still recorded"
    end

    test "with the switch off, the client's row hides nothing", ctx do
      Flags.put_feature_visibility(false)
      conn = log_in_user(build_conn(), ctx.client.owner.user)
      {:ok, lv, _html} = live(conn, run_path(ctx))

      assert has_element?(lv, "#run-tab-terminal")
      assert has_element?(lv, "#run-menu-raw")
      assert get(conn, run_path(ctx, "/log")).status == 200
    end
  end

  describe "an open Terminal tab" do
    setup do: chain()

    test "leaves for the Timeline once the operator hides the Terminal from the client", ctx do
      conn = log_in_user(build_conn(), ctx.client.owner.user)
      {:ok, lv, _html} = live(conn, run_path(ctx, "/terminal"))
      assert has_element?(lv, "#terminal[data-src]")

      hide_from_client(ctx)

      assert_patch(lv, run_path(ctx))
      refute has_element?(lv, "#terminal")
      refute has_element?(lv, "#run-tab-terminal")
      assert has_element?(lv, "#run-tab-timeline[aria-current]")
    end

    test "leaves for the operator's people once the instance hides it from the operator", ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, run_path(ctx, "/terminal"))
      assert has_element?(lv, "#terminal[data-src]")

      assert {:ok, _} =
               Grants.set_organisation(ctx.admin, ctx.operator.organisation.id, [
                 "observability",
                 "security"
               ])

      assert_patch(lv, run_path(ctx))
      refute has_element?(lv, "#run-tab-terminal")
    end
  end

  describe "the Terminal tab on the Features pages" do
    setup do
      admin = suite_instance_admin()
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      %{admin: admin, operator: operator, client: client}
    end

    test "is a checkbox under Runs on Instance settings › Organisations, with the switch on",
         ctx do
      Flags.put_feature_visibility(true)
      conn = log_in_user(build_conn(), ctx.admin.user)
      path = ~p"/instance/organisations/#{ctx.operator.organisation.id}/features"
      {:ok, lv, _html} = live(conn, path)
      render_async(lv)

      assert has_element?(lv, "#organisation-features-observability-terminal:checked")

      assert has_element?(
               lv,
               "label[for=organisation-features-observability-terminal]",
               "Terminal tab"
             )

      assert has_element?(
               lv,
               "#organisation-features-observability-terminal-description",
               @description
             )

      # Indented, and right after Runs.
      ids = box_ids(lv, "#organisation-features")
      assert ["observability", "observability-terminal" | _] = ids
      assert has_element?(lv, "div.pl-6 #organisation-features-observability-terminal")

      lv
      |> form("#organisation-features-form", %{
        "features" => %{
          "observability" => "true",
          "observability.terminal" => "false"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/instance/organisations")

      assert Repo.exists?(
               from g in Grant,
                 where:
                   g.organisation_id == ^ctx.operator.organisation.id and
                     g.feature == ^@terminal and not g.granted
             )

      {:ok, lv, _html} = live(conn, path)
      render_async(lv)
      assert has_element?(lv, "#organisation-features-observability-terminal")
      refute has_element?(lv, "#organisation-features-observability-terminal:checked")
    end

    test "is a checkbox under Runs on a client's Features page, with the switch on", ctx do
      Flags.put_feature_visibility(true)
      conn = log_in_user(build_conn(), ctx.operator.user)
      path = ~p"/#{ctx.operator.organisation}/clients/#{ctx.client.organisation.id}/features"
      {:ok, lv, _html} = live(conn, path)
      render_async(lv)

      assert has_element?(lv, "#client-features-observability-terminal:checked")
      assert has_element?(lv, "label[for=client-features-observability-terminal]", "Terminal tab")
      assert has_element?(lv, "#client-features-observability-terminal-description", @description)
      assert ["observability", "observability-terminal" | _] = box_ids(lv, "#client-features")

      lv
      |> form("#client-features-form", %{
        "features" => %{"observability.terminal" => "false"}
      })
      |> render_submit()

      assert_patch(lv, ~p"/#{ctx.operator.organisation}/clients")
      assert @terminal in ApiaryPro.Features.hidden_parts([ctx.client.organisation.id])
    end

    test "is not on a client's page where the operator is not shown it", ctx do
      Flags.put_feature_visibility(true)

      assert {:ok, _} =
               Grants.set_organisation(ctx.admin.instance_scope, ctx.operator.organisation.id, [
                 "observability"
               ])

      conn = log_in_user(build_conn(), ctx.operator.user)
      path = ~p"/#{ctx.operator.organisation}/clients/#{ctx.client.organisation.id}/features"
      {:ok, lv, _html} = live(conn, path)
      render_async(lv)

      assert has_element?(lv, "#client-features-observability")
      refute has_element?(lv, "#client-features-observability-terminal")
    end

    test "is on neither page with the switch off", ctx do
      Flags.put_feature_visibility(false)

      conn = log_in_user(build_conn(), ctx.admin.user)

      {:ok, lv, html} =
        live(conn, ~p"/instance/organisations/#{ctx.operator.organisation.id}/features")

      render_async(lv)
      assert has_element?(lv, "#organisation-features-observability")
      refute has_element?(lv, "#organisation-features-observability-terminal")
      refute render(lv) =~ "Terminal tab"
      refute html =~ "Terminal tab"

      conn = log_in_user(build_conn(), ctx.operator.user)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{ctx.operator.organisation}/clients/#{ctx.client.organisation.id}/features"
        )

      render_async(lv)
      assert has_element?(lv, "#client-features-observability")
      refute has_element?(lv, "#client-features-observability-terminal")
      refute render(lv) =~ "Terminal tab"
    end
  end

  # The ids of a group's checkboxes, in order, without the group's prefix.
  defp box_ids(lv, group) do
    prefix = String.trim_leading(group, "#") <> "-"

    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(group <> " input[type=checkbox]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first() |> String.trim_leading(prefix)))
  end
end
