defmodule ApiaryProWeb.NodesPartLiveTest do
  # The nodes, a part of no feature (`:nodes`), hidden from a client's people by its
  # operator (`ApiaryPro.Features.hidden/1`): while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`) and features are shown by who asks
  # (`ApiaryPro.Flags.feature_visibility?/0`), the client's Features page shows them as
  # one box after the features, and a client's owner, admin or member they are hidden from
  # finds no page of the nodes, the access keys or the gateways, and no link to them,
  # while the client's nodes keep working and the operator's people keep reading them.
  # With either switch off no page offers them and nothing hides them.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures, only: [join_fixture: 2, member_fixture: 2]
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{AccessKeys, Features, Repo, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Event, Run}
  alias ApiaryPro.{Flags, Grants}
  alias ApiaryPro.Grants.Grant

  @moduletag with_features: Features.all()

  @label "Machines and access keys"

  # An operator and its client, whose owner, admin and member are the client's people; an
  # admin of the operator; in the client's workspace a gateway and a node that uses it,
  # each with a key, and a node that registers its runs directly, with a run; a node that
  # never ran; a gateway of the client's organisation, and an enrolment code the client's
  # admin made, all while the operator did not own its clients; then both switches on.
  setup do
    Flags.put_operator_infrastructure(false)
    Flags.put_feature_visibility(true)
    %{instance_scope: admin} = suite_instance_admin()
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    client = client_fixture(operator.scope, "Acme")
    scope = client.owner.scope
    client_admin = client_member_fixture(client, :admin)

    gateway = gateway_fixture(scope, name: "edge-1")

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(scope, node: gateway)

    %{access_key: via_key, secret: via_secret} = contract_key_fixture(scope)

    node = node_fixture(scope, name: "build-01")
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)
    Repo.update_all(from(n in Node, where: n.id == ^node.id), set: [gateway_choice: :direct])

    run_id = Ecto.UUID.generate()
    conn = signed_register(build_conn(), key.key_id, secret, Jason.encode!(registration(run_id)))
    assert json_response(conn, 200)

    {:ok, _row, code} = AccessKeys.create_enrolment_code(client_admin.scope, node, %{})
    idle = node_fixture(scope, name: "idle-07")

    ctx = %{
      admin: admin,
      operator: operator,
      operator_name: name,
      operator_admin: member_fixture(operator.scope, :admin),
      client: client,
      client_admin: client_admin,
      client_member: client_member_fixture(client, :member),
      node: node,
      idle: idle,
      gateway: gateway,
      organisation_gateway: organisation_gateway_fixture(scope, name: "edge-org"),
      key: {key, secret},
      via_key: {via_key, via_secret},
      gateway_key: {gateway_key, gateway_secret},
      code: code <> "." <> SigningKey.fingerprint(),
      run: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)
    }

    Flags.put_operator_infrastructure(true)
    ctx
  end

  # What the client's Features page sends: what it has checked now, but the nodes where
  # `shown?` is false, and with them where it is true.
  defp set_nodes(ctx, shown?) do
    client = Repo.reload!(ctx.client.organisation)
    shown = Grants.shown(client)
    has = Enum.filter(ApiaryPro.Features.of(client) ++ Grants.parts_kept(client), &(&1 in shown))
    names = if shown?, do: Enum.uniq(has ++ [:nodes]), else: has -- [:nodes]

    assert {:ok, _} =
             Grants.set_client(ctx.operator.scope, client.id, Enum.map(names, &Atom.to_string/1))
  end

  defp client_people(ctx), do: [ctx.client.owner, ctx.client_admin, ctx.client_member]

  defp client_path(ctx, tail),
    do: "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}" <> tail

  # The pages of the nodes, the access keys and the gateways of the client.
  defp node_pages(ctx) do
    org = ctx.client.organisation.slug

    [
      client_path(ctx, "/machines"),
      client_path(ctx, "/machines/#{ctx.node.public_id}"),
      client_path(ctx, "/machines/#{ctx.node.public_id}/access-key"),
      client_path(ctx, "/machines/#{ctx.gateway.public_id}"),
      "/#{org}/gateways",
      "/#{org}/gateways/#{ctx.organisation_gateway.public_id}",
      "/#{org}/gateways/#{ctx.organisation_gateway.public_id}/access-key"
    ]
  end

  defp rows(organisation_id) do
    Repo.all(
      from g in Grant,
        where: g.organisation_id == ^organisation_id,
        select: {g.feature, g.granted}
    )
  end

  describe "the nodes hidden from the client's people" do
    setup ctx do
      set_nodes(ctx, false)
      :ok
    end

    test "its owner, admin and member are answered not found on every page of them", ctx do
      for person <- client_people(ctx), path <- node_pages(ctx) do
        conn = log_in_user(build_conn(), person.user)
        assert_error_sent(:not_found, fn -> get(conn, path) end)
      end
    end

    test "the navigation has no Nodes and no Gateways, and a run names its node with no link",
         ctx do
      for person <- client_people(ctx) do
        conn = log_in_user(build_conn(), person.user)

        {:ok, lv, _html} = live(conn, client_path(ctx, "/runs"))
        assert has_element?(lv, "#nav-runs")
        refute has_element?(lv, "#nav-nodes")
        refute has_element?(lv, "#nav-gateways")
        refute render(lv) =~ client_path(ctx, "/machines")

        {:ok, lv, _html} = live(conn, "/#{ctx.client.organisation.slug}")
        refute has_element?(lv, "#nav-gateways")
        refute render(lv) =~ "/#{ctx.client.organisation.slug}/gateways"

        {:ok, lv, _html} = live(conn, client_path(ctx, "/runs/#{ctx.run.number}"))
        assert has_element?(lv, "#run-node", "build-01")
        refute has_element?(lv, "#run-node a")
        refute render(lv) =~ client_path(ctx, "/machines")
      end
    end

    test "a run's page has no Key row, and a filter by a node no run names names no node",
         ctx do
      {key, _secret} = ctx.key
      idle = client_path(ctx, "/runs?node=#{ctx.idle.public_id}")

      for person <- client_people(ctx) do
        conn = log_in_user(build_conn(), person.user)

        {:ok, lv, _html} = live(conn, client_path(ctx, "/runs/#{ctx.run.number}"))
        assert has_element?(lv, "#run-node", "build-01")
        refute has_element?(lv, "dt", ~r/^\s*Key\s*$/)
        refute render(lv) =~ key.key_id

        {:ok, lv, _html} = live(conn, idle)
        render_async(lv)
        assert has_element?(lv, "#runs-page")
        refute render(lv) =~ "idle-07"
      end

      # The control: the operator, shown the nodes, reads both.
      conn = log_in_user(build_conn(), ctx.operator.user)

      {:ok, lv, _html} = live(conn, client_path(ctx, "/runs/#{ctx.run.number}"))
      assert has_element?(lv, "dt", ~r/^\s*Key\s*$/)
      assert render(lv) =~ key.key_id

      {:ok, lv, _html} = live(conn, idle)
      render_async(lv)
      assert has_element?(lv, "#runs-narrowed-what", "idle-07")
    end

    test "the operator's people read them, through the operator and from a lower membership",
         ctx do
      _joined = join_fixture(ctx.client.owner.scope, ctx.operator_admin.user)

      for person <- [ctx.operator, ctx.operator_admin] do
        conn = log_in_user(build_conn(), person.user)

        for path <- node_pages(ctx),
            do: assert({:ok, _lv, _html} = live(conn, path))

        {:ok, lv, _html} = live(conn, client_path(ctx, "/runs/#{ctx.run.number}"))

        assert has_element?(
                 lv,
                 ~s{#run-node a[href="#{client_path(ctx, "/machines/#{ctx.node.public_id}")}"]},
                 "build-01"
               )
      end
    end

    test "the client's keys still register runs, post their events and attach", ctx do
      {key, secret} = ctx.key

      run_id = Ecto.UUID.generate()

      conn =
        signed_register(build_conn(), key.key_id, secret, Jason.encode!(registration(run_id)))

      assert json_response(conn, 200)

      run = Repo.one!(from r in Run, where: r.node_run_id == ^run_id)
      {_subject, events} = first_events(run_id)
      assert signed_post(build_conn(), key.key_id, secret, events).status == 202
      assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 1

      # Through the workspace's gateway: the node registers, and the gateway attaches.
      {via, via_secret} = ctx.via_key
      {gateway_key, gateway_secret} = ctx.gateway_key
      run_id = Ecto.UUID.generate()

      conn =
        signed_register(build_conn(), via.key_id, via_secret, gateway_registration(run_id))

      assert %{"run_key" => run_key} = json_response(conn, 200)

      attached =
        signed_attach(
          build_conn(),
          gateway_key.key_id,
          gateway_secret,
          run_id,
          Jason.encode!(attach_body(run_key))
        )

      assert attached.status == 200

      conn = signed_get(build_conn(), key.key_id, secret, "/.well-known/qory-configuration")
      assert conn.status == 200
    end
  end

  describe "/users/settings and /users/organisations, the last workspace the client's" do
    setup ctx do
      _joined = join_fixture(ctx.client.owner.scope, ctx.operator_admin.user)
      set_nodes(ctx, false)
      :ok
    end

    # Signed in as `user`, their last workspace the client's.
    defp home_conn(user, ctx) do
      build_conn()
      |> log_in_user(user)
      |> Plug.Test.init_test_session(%{last_workspace_id: ctx.client.workspace.id})
    end

    defp nodes_link?(conn) do
      for path <- ["/users/settings", "/users/organisations"] do
        {:ok, lv, _html} = live(conn, path)
        has_element?(lv, "#nav-nodes")
      end
    end

    test "an admin of the operator who is a member of the client has Nodes", ctx do
      assert nodes_link?(home_conn(ctx.operator_admin.user, ctx)) == [true, true]
    end

    test "the client's admin and member, with no membership in the operator, have none",
         ctx do
      for person <- [ctx.client_admin, ctx.client_member],
          do: assert(nodes_link?(home_conn(person.user, ctx)) == [false, false])
    end

    test "a suspended membership in the operator does not count", ctx do
      assert {:ok, _} =
               Apiary.Organisations.suspend_member(
                 ctx.operator.scope,
                 ctx.operator_admin.membership.id
               )

      assert nodes_link?(home_conn(ctx.operator_admin.user, ctx)) == [false, false]
    end
  end

  describe "an open page of the nodes" do
    test "leaves when the operator hides them from the client, and opens again once shown",
         ctx do
      conn = log_in_user(build_conn(), ctx.client.owner.user)
      {:ok, lv, _html} = live(conn, client_path(ctx, "/machines"))
      assert has_element?(lv, "#nav-nodes[aria-current]")

      set_nodes(ctx, false)

      {to, flash} = assert_redirect(lv)
      assert to == "/#{ctx.client.organisation.slug}"
      assert flash["error"] == "That page is no longer shown in Acme."

      # Ticked again, the page opens.
      set_nodes(ctx, true)
      assert {:ok, lv, _html} = live(conn, client_path(ctx, "/machines"))
      assert has_element?(lv, "#nav-nodes")
    end

    test "stays open for the operator's people", ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, client_path(ctx, "/machines"))

      set_nodes(ctx, false)

      # The page heard of the change, and stays.
      _ = render(lv)
      refute_redirected(lv)
      assert has_element?(lv, "#nav-nodes[aria-current]")
    end
  end

  describe "an enrolment code" do
    test "the client's admin made before the nodes were hidden is answered as without the hide",
         ctx do
      # While the operator owns its clients a client's admin makes no code, so their code
      # approves no key, hidden or not: the hide changes nothing of it.
      assert enrol(ctx.code).status == 401
      set_nodes(ctx, false)
      assert enrol(ctx.code).status == 401

      # With the operator not owning its clients the code enrols, and nothing is hidden.
      Flags.put_operator_infrastructure(false)
      assert enrol(ctx.code).status == 201
    end

    test "the operator's admin made in the client still enrols once they are hidden", ctx do
      scope =
        scope_in(ctx.operator_admin.user, ctx.client.organisation, ctx.client.workspace)

      {:ok, _row, code} = AccessKeys.create_enrolment_code(scope, ctx.node, %{})
      set_nodes(ctx, false)

      pair = ed25519_key_pair()
      assert enrol(code <> "." <> SigningKey.fingerprint(), pair).status == 201

      assert Repo.get_by!(AccessKey, public_key: pair.public_key).created_by_id ==
               ctx.operator_admin.user.id
    end
  end

  describe "the box on the client's Features page" do
    defp features_path(ctx),
      do: "/#{ctx.operator.organisation.slug}/clients/#{ctx.client.organisation.id}/features"

    test "is checked, last and not indented, and left unticked hides them", ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, features_path(ctx))
      render_async(lv)

      assert has_element?(lv, "#client-features-nodes:checked")
      assert has_element?(lv, "label[for=client-features-nodes]", @label)

      assert has_element?(
               lv,
               "#client-features-nodes-description",
               "The machines, pools, access keys and gateways #{ctx.operator_name} runs in this client's workspaces, which its people read only."
             )

      assert ["observability", "observability-terminal" | _] = ids = box_ids(lv)
      assert List.last(ids) == "nodes"
      refute has_element?(lv, "div.pl-6 #client-features-nodes")

      lv
      |> form("#client-features-form", %{
        "features" => %{"observability" => "true", "nodes" => "false"}
      })
      |> render_submit()

      assert_patch(lv, "/#{ctx.operator.organisation.slug}/clients")
      assert {:nodes, false} in rows(ctx.client.organisation.id)

      {:ok, lv, _html} = live(conn, features_path(ctx))
      render_async(lv)
      assert has_element?(lv, "#client-features-nodes")
      refute has_element?(lv, "#client-features-nodes:checked")
    end

    test "is not on Instance settings › Organisations › Features", ctx do
      conn = log_in_user(build_conn(), ctx.admin.user)

      {:ok, lv, _html} =
        live(conn, "/instance/organisations/#{ctx.operator.organisation.id}/features")

      render_async(lv)
      assert has_element?(lv, "#organisation-features-observability")
      refute has_element?(lv, "#organisation-features-nodes")
      refute render(lv) =~ @label
    end

    for {flag, put} <- [
          operator_infrastructure: :put_operator_infrastructure,
          feature_visibility: :put_feature_visibility
        ] do
      @put put

      test "is not there with #{flag} off, and the client's row hides nothing", ctx do
        set_nodes(ctx, false)
        apply(Flags, @put, [false])

        conn = log_in_user(build_conn(), ctx.operator.user)
        {:ok, lv, _html} = live(conn, features_path(ctx))
        render_async(lv)
        assert has_element?(lv, "#client-features-observability")
        refute has_element?(lv, "#client-features-nodes")
        refute render(lv) =~ @label

        conn = log_in_user(build_conn(), ctx.client.owner.user)

        for path <- node_pages(ctx),
            do: assert({:ok, _lv, _html} = live(conn, path))
      end
    end
  end

  # Posts the enrolment of a key, `pair` (a fresh one by default), with `code`, as a
  # machine does.
  defp enrol(code, pair \\ ed25519_key_pair()) do
    timestamp = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, "build-01", timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    body =
      Jason.encode!(%{
        version: 1,
        code: code,
        name: "build-01",
        public_key: pair.encoded,
        timestamp: timestamp,
        proof: proof
      })

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-qory-contract-version", "1")
    |> post("/.well-known/qory-enrolment", body)
  end

  # The ids of the client's Features boxes, in order, without the group's prefix.
  defp box_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#client-features input[type=checkbox]")
    |> Enum.map(
      &(&1
        |> LazyHTML.attribute("id")
        |> List.first()
        |> String.trim_leading("client-features-"))
    )
  end
end
