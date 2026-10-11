defmodule ApiaryWeb.NodeLive.GatewayTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Gateways, Nodes}
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  defp nodes_path(scope, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes" <> rest

  defp node_path(scope, node, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}" <> rest

  defp member_conn(scope) do
    %{user: user} = member_fixture(scope, :member)
    log_in_user(build_conn(), user)
  end

  defp text(lv, selector),
    do:
      lv
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

  # The text of an element as it renders, its spaces and its line breaks kept: a
  # code block's lines.
  defp lines(lv, selector),
    do: lv |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  # Get the command on a node's Access key tab: the command's page, and its command.
  defp command(conn, scope, node) do
    {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))
    lv |> element("#code-new-button") |> render_click()
    assert_patch(lv, node_path(scope, node, "/access-key/new-code"))
    {lv, text(lv, "#code-issued-command")}
  end

  # The options of the gateway field, as `{value, words}`, in the order it shows them, and
  # the one selected.
  defp gateway_options(lv, form) do
    html = lv |> element("##{form} select[name='node[gateway]']") |> render()
    doc = LazyHTML.from_fragment(html)

    options =
      doc
      |> LazyHTML.query("option")
      |> Enum.map(fn option ->
        [value] = LazyHTML.attribute(option, "value")
        {value, option |> LazyHTML.text() |> String.trim()}
      end)

    selected =
      case doc |> LazyHTML.query("option[selected]") |> LazyHTML.attribute("value") do
        [value] -> value
        [] -> nil
      end

    {options, selected}
  end

  # The mark gone, by a write no function makes, so that no default resolves.
  defp unmark(gateway),
    do:
      Repo.update_all(from(n in Node, where: n.id == ^gateway.id), set: [default_gateway: false])

  setup :register_and_log_in_user

  describe "the list" do
    test "shows a gateway's line, its kind and the default mark, and narrows to gateways", %{
      conn: conn,
      scope: scope
    } do
      default = gateway_fixture(scope, name: "edge-01")
      other = gateway_fixture(scope, name: "edge-02")
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(conn, nodes_path(scope))

      assert has_element?(lv, "#node-#{default.public_id}", "edge-01")
      assert has_element?(lv, "#node-#{default.public_id}", default.public_id)
      assert has_element?(lv, "#node-#{default.public_id}-kind", "Gateway")
      assert has_element?(lv, "#node-#{default.public_id}-default", "Default")
      refute has_element?(lv, "#node-#{other.public_id}-default")
      assert has_element?(lv, "#node-#{other.public_id}-state", "Never seen")
      refute has_element?(lv, "#node-#{node.public_id}-kind")
      assert has_element?(lv, "#nodes-filter-kind-gateway", "Gateway")
      assert has_element?(lv, "#nodes-filter-kind-gateway", "2 nodes")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "?kind=gateway"))
      assert has_element?(lv, "#node-#{default.public_id}")
      assert has_element?(lv, "#node-#{other.public_id}")
      refute has_element?(lv, "#node-#{node.public_id}")
      assert has_element?(lv, "#nodes-token-kind", "Gateway")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "?kind=node"))
      refute has_element?(lv, "#node-#{default.public_id}")
    end

    test "a workspace with gateways alone lists them, in every view and sort", %{
      conn: conn,
      scope: scope
    } do
      gateway = gateway_fixture(scope, name: "edge-01")

      for query <- ["", "?view=idle", "?view=running", "?sort=seen", "?q=edge"] do
        {:ok, lv, _html} = live(conn, nodes_path(scope, query))
        refute has_element?(lv, "#nodes-empty")

        if query == "?view=running",
          do: refute(has_element?(lv, "#node-#{gateway.public_id}")),
          else: assert(has_element?(lv, "#node-#{gateway.public_id}"))
      end
    end
  end

  describe "New gateway" do
    test "is a page of the Nodes section, with its name and its URL", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      lv |> element("#new-gateway") |> render_click()
      assert_patch(lv, nodes_path(scope, "/new-gateway"))

      assert has_element?(lv, "main h1", "New gateway")
      assert has_element?(lv, "main header", "You can't change the kind later.")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New gateway")
      assert has_element?(lv, ~s{#new-node-form input[name="node[name]"][phx-mounted]})
      assert has_element?(lv, ~s{#new-node-form input[name="node[url]"]})
      refute has_element?(lv, ~s{#new-node-form input[name="node[instance_limit]"]})
      refute has_element?(lv, ~s{#new-node-form select[name="node[gateway]"]})
      assert has_element?(lv, "#new-node-save #new-node-submit", "Add gateway")
      assert has_element?(lv, ~s{#new-node-save-cancel[href="#{nodes_path(scope)}"]}, "Cancel")
      assert page_title(lv) =~ "New gateway"
    end

    test "shows the URL's errors as core gives them", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new-gateway"))

      html =
        lv
        |> form("#new-node-form", node: %{name: "edge-01", url: "https://gw.example/path"})
        |> render_change()

      assert html =~ "must be a scheme and a host, with a port if needed, and nothing more"

      # The scheme's error, in the words the changeset has for it.
      {scheme_error, _opts} =
        Nodes.new_node(:gateway)
        |> Nodes.change_new_node(%{name: "edge-01", url: "http://gw.example"})
        |> Map.fetch!(:errors)
        |> Keyword.fetch!(:url)

      html =
        lv
        |> form("#new-node-form", node: %{name: "edge-01", url: "http://gw.example"})
        |> render_submit()

      assert html =~ Phoenix.HTML.html_escape(scheme_error) |> Phoenix.HTML.safe_to_string()
      assert Nodes.list_nodes(scope) == []
    end

    test "shows the URL's error for a host that is no DNS name and no IP address", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new-gateway"))

      html =
        lv
        |> form("#new-node-form",
          node: %{name: "edge-01", url: "https://edge.example.com;rm$IFS-rf$IFS~"}
        )
        |> render_submit()

      assert html =~ "must be a scheme and a host, with a port if needed, and nothing more"
      assert Nodes.list_nodes(scope) == []
    end

    test "a gateway is made, the workspace's first its default, and opens on its Access key tab",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new-gateway"))

      {:ok, tab, html} =
        lv
        |> form("#new-node-form", node: %{name: "edge-01", url: "https://gw.example.com:8443"})
        |> render_submit()
        |> follow_redirect(conn)

      assert [%Node{kind: :gateway, public_id: "ng_" <> _, default_gateway: true} = gateway] =
               Nodes.list_nodes(scope)

      assert gateway.url == "https://gw.example.com:8443"
      assert html =~ "edge-01 is added."
      assert has_element?(tab, "#node-access-key")
      assert has_element?(tab, "#node-kind", "Gateway")
      assert has_element?(tab, "#node-default", "Default")
      # Its key is given as any node's is: the two ways, the secret shown once.
      assert has_element?(tab, "#way-new_code")
      assert has_element?(tab, "#way-generate")
      refute has_element?(tab, "#node-gateway")
    end
  end

  describe "a gateway's page" do
    test "shows its URL and default mark; Make default moves the mark", %{
      conn: conn,
      scope: scope
    } do
      first = gateway_fixture(scope, name: "edge-01")
      second = gateway_fixture(scope, name: "edge-02", url: "https://edge-02.example.com")

      {:ok, lv, _html} = live(conn, node_path(scope, first))
      assert has_element?(lv, "#node-kind", "Gateway")
      assert has_element?(lv, "#node-default", "Default")
      assert has_element?(lv, "#gateway-url", "https://gateway.example")
      assert has_element?(lv, "#gateway-default", "This workspace's default gateway.")
      refute has_element?(lv, "#gateway-make-default")
      refute has_element?(lv, "#node-instances")
      refute has_element?(lv, "#node-about-limit")
      assert has_element?(lv, "#node-about-kind", "Gateway:")

      {:ok, lv, _html} = live(conn, node_path(scope, second))
      assert has_element?(lv, "#gateway-url", "https://edge-02.example.com")
      assert has_element?(lv, "#gateway-default", "Not the default.")
      refute has_element?(lv, "#node-default")

      lv |> element("#gateway-make-default") |> render_click()

      assert render(lv) =~ "edge-02 is the default gateway now."
      assert has_element?(lv, "#node-default", "Default")
      assert has_element?(lv, "#gateway-default", "This workspace's default gateway.")
      refute has_element?(lv, "#gateway-make-default")
      assert %Node{id: id} = Gateways.default_gateway_for(scope.workspace)
      assert id == second.id
      refute Repo.get!(Node, first.id).default_gateway
    end

    test "a member reads it without Make default, and is refused it", %{scope: scope} do
      gateway_fixture(scope, name: "edge-01")
      second = gateway_fixture(scope, name: "edge-02")
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, node_path(scope, second))
      assert has_element?(lv, "#gateway-default", "Not the default.")
      refute has_element?(lv, "#gateway-make-default")

      render_hook(lv, "make_default", %{})
      assert render(lv) =~ "Only owners and admins change nodes."
      refute Repo.get!(Node, second.id).default_gateway
    end

    test "Settings › General changes its name and URL, and shows the URL's errors", %{
      conn: conn,
      scope: scope
    } do
      gateway = gateway_fixture(scope, name: "edge-01")
      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/settings"))

      assert has_element?(lv, "#node-kind-field", "Gateway:")
      refute has_element?(lv, "#node-limit-field")
      refute has_element?(lv, ~s{#node-form select[name="node[gateway]"]})

      assert lv
             |> form("#node-form", node: %{url: "https://gw.example/?q=1"})
             |> render_change() =~
               "must be a scheme and a host, with a port if needed, and nothing more"

      lv
      |> form("#node-form", node: %{name: "edge-east", url: "https://east.example.com"})
      |> render_submit()

      assert render(lv) =~ "edge-east is saved."

      assert %Node{name: "edge-east", url: "https://east.example.com"} =
               Repo.get!(Node, gateway.id)
    end

    test "is deleted through its confirmation in place, when nothing points to it", %{
      conn: conn,
      scope: scope
    } do
      gateway = gateway_fixture(scope, name: "edge-01")
      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/settings"))

      assert has_element?(lv, "#delete-node-title", "Delete this gateway")
      lv |> element("#delete-node-button", "Delete gateway…") |> render_click()
      assert_patch(lv, node_path(scope, gateway, "/settings/delete"))
      assert has_element?(lv, "#delete-node-confirming", "Delete edge-01?")

      {:ok, _list, html} =
        lv
        |> form("#delete-node-form")
        |> render_submit()
        |> follow_redirect(conn, nodes_path(scope))

      assert html =~ "edge-01 is deleted."
      assert Repo.get!(Node, gateway.id).deleted_at
    end

    test "is not deleted while nodes point to it: this workspace's are named, the others counted",
         %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, name: "edge-01")

      _named =
        node_fixture(scope, name: "build-01", gateway_choice: "named", gateway_id: gateway.id)

      _on_default = pool_fixture(scope, name: "spot-runners", gateway_choice: "default")
      _direct = node_fixture(scope, name: "mac-mini", gateway_choice: "direct")

      # A node of another workspace, and one of another organisation, that name it: the
      # database takes either, by a write no page makes.
      %{scope: elsewhere} =
        %{scope: workspace_scope(scope.user, workspace_fixture(scope.organisation))}

      theirs = node_fixture(elsewhere, name: "hidden-workspace-node")
      stranger = node_fixture(sign_up_fixture().scope, name: "hidden-organisation-node")

      Repo.update_all(from(n in Node, where: n.id in ^[theirs.id, stranger.id]),
        set: [gateway_choice: :named, gateway_id: gateway.id]
      )

      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/settings/delete"))
      lv |> form("#delete-node-form") |> render_submit()

      assert_patch(lv, node_path(scope, gateway, "/settings"))
      refute has_element?(lv, "#delete-node-form")

      # By name, the workspace's own; the two of other workspaces counted, never named.
      assert text(lv, "#delete-node-refused") ==
               "Nodes use this gateway: build-01, spot-runners and 2 more. " <>
                 "Point them to another gateway or to direct, then delete it."

      html = render(lv)
      refute html =~ "mac-mini"
      refute html =~ "hidden-workspace-node"
      refute html =~ "hidden-organisation-node"
      refute html =~ theirs.public_id
      refute html =~ stranger.public_id
      assert Repo.get!(Node, gateway.id).deleted_at == nil

      # Opened again, the confirmation starts without it.
      lv |> element("#delete-node-button") |> render_click()
      refute has_element?(lv, "#delete-node-refused")
    end

    test "every tab renders for a gateway, with or without a key", %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, name: "edge-01")

      for rest <- ["", "/settings", "/settings/delete", "/access-key"] do
        assert {:ok, _lv, _html} = live(conn, node_path(scope, gateway, rest))
      end

      %{access_key: key} = node_key_fixture(scope, gateway)

      for rest <- ["", "/access-key", "/access-key/keys/#{key.key_id}/forager-file"] do
        assert {:ok, _lv, _html} = live(conn, node_path(scope, gateway, rest))
      end
    end
  end

  describe "choosing a gateway" do
    test "a node of a workspace with no gateway is asked none", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))
      refute has_element?(lv, ~s{#new-node-form select[name="node[gateway]"]})

      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))
      refute has_element?(lv, ~s{#node-form select[name="node[gateway]"]})
    end

    test "a new node starts on Default gateway when one resolves, and may name one or go Direct",
         %{conn: conn, scope: scope} do
      default = gateway_fixture(scope, name: "edge-01")
      other = gateway_fixture(scope, name: "edge-02")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      assert gateway_options(lv, "new-node-form") ==
               {[
                  {"default", "Default gateway"},
                  {"direct", "Direct"},
                  {default.id, "edge-01"},
                  {other.id, "edge-02"}
                ], "default"}

      assert has_element?(lv, "#node_gateway-hint", "edge-01, this workspace's default")

      {:ok, _tab, _html} =
        lv
        |> form("#new-node-form", node: %{name: "build-01", gateway: "default"})
        |> render_submit()
        |> follow_redirect(conn)

      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new-pool"))

      {:ok, _tab, _html} =
        lv
        |> form("#new-node-form", node: %{name: "spot-runners", gateway: other.id})
        |> render_submit()
        |> follow_redirect(conn)

      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      {:ok, _tab, _html} =
        lv
        |> form("#new-node-form", node: %{name: "mac-mini", gateway: "direct"})
        |> render_submit()
        |> follow_redirect(conn)

      by_name = Map.new(Nodes.list_nodes(scope), &{&1.name, &1})
      assert %Node{gateway_choice: :default, gateway_id: nil} = by_name["build-01"]
      assert %Node{gateway_choice: :named, gateway_id: other_id} = by_name["spot-runners"]
      assert other_id == other.id
      assert %Node{gateway_choice: :direct} = by_name["mac-mini"]
    end

    test "Default gateway is not offered while no default resolves; a new node starts Direct", %{
      conn: conn,
      scope: scope
    } do
      gateway = gateway_fixture(scope, name: "edge-01")
      unmark(gateway)

      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      assert gateway_options(lv, "new-node-form") ==
               {[{"direct", "Direct"}, {gateway.id, "edge-01"}], "direct"}

      refute has_element?(lv, "#node_gateway-hint")

      # Sent all the same, as the page never sends it: core's refusal, under the field.
      html =
        render_submit(lv, "create", %{"node" => %{"name" => "build-01", "gateway" => "default"}})

      assert html =~ "has no default gateway"
      assert Nodes.list_nodes(scope, %{kind: :node}) == []
    end

    test "a gateway the node may not use is refused under the field", %{conn: conn, scope: scope} do
      gateway_fixture(scope, name: "edge-01")
      theirs = gateway_fixture(sign_up_fixture().scope, name: "elsewhere")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      html =
        render_submit(lv, "create", %{"node" => %{"name" => "build-01", "gateway" => theirs.id}})

      assert html =~ "is not a gateway this node may use"
      refute html =~ "elsewhere"
      assert Nodes.list_nodes(scope, %{kind: :node}) == []
    end

    test "Settings › General changes a node's gateway; keeping Default needs no default", %{
      conn: conn,
      scope: scope
    } do
      default = gateway_fixture(scope, name: "edge-01")
      other = gateway_fixture(scope, name: "edge-02")
      node = node_fixture(scope, name: "build-01")
      assert node.gateway_choice == :default

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))

      assert {_options, "default"} = gateway_options(lv, "node-form")

      lv |> form("#node-form", node: %{gateway: other.id}) |> render_submit()
      assert render(lv) =~ "build-01 is saved."
      assert %Node{gateway_choice: :named, gateway_id: other_id} = Repo.get!(Node, node.id)
      assert other_id == other.id
      assert {_options, ^other_id} = gateway_options(lv, "node-form")

      lv |> form("#node-form", node: %{gateway: "direct"}) |> render_submit()
      assert %Node{gateway_choice: :direct, gateway_id: nil} = Repo.get!(Node, node.id)

      # A node on the default, whose default no longer resolves, keeps it as it is renamed.
      pool = pool_fixture(scope, name: "spot-runners", gateway_choice: "default")
      unmark(default)

      {:ok, lv, _html} = live(conn, node_path(scope, pool, "/settings"))
      assert {[{"default", "Default gateway"} | _], "default"} = gateway_options(lv, "node-form")

      lv |> form("#node-form", node: %{name: "spot-east"}) |> render_submit()
      assert %Node{name: "spot-east", gateway_choice: :default} = Repo.get!(Node, pool.id)
    end

    test "About says where the choice leads", %{conn: conn, scope: scope} do
      default = gateway_fixture(scope, name: "edge-01")
      other = gateway_fixture(scope, name: "edge-02")
      on_default = node_fixture(scope, name: "build-01", gateway_choice: "default")
      named = node_fixture(scope, name: "build-02", gateway_choice: "named", gateway_id: other.id)
      direct = node_fixture(scope, name: "build-03", gateway_choice: "direct")

      {:ok, lv, _html} = live(conn, node_path(scope, on_default))
      assert text(lv, "#node-about-gateway") =~ "Default gateway · edge-01"

      assert has_element?(
               lv,
               ~s{#node-about-gateway a[href="#{node_path(scope, default)}"]},
               "edge-01"
             )

      {:ok, lv, _html} = live(conn, node_path(scope, named))
      assert text(lv, "#node-about-gateway") =~ "edge-02"

      {:ok, lv, _html} = live(conn, node_path(scope, direct))
      assert text(lv, "#node-about-gateway") == "Direct"
    end
  end

  describe "the enrol instructions of a node behind a gateway" do
    test "name the gateway and its URL, on the tab and the command's page", %{
      conn: conn,
      scope: scope
    } do
      gateway = gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))

      assert text(lv, "#node-gateway") =~
               "Runs of build-01 go through the gateway edge-01, at https://edge.example.com."

      assert has_element?(
               lv,
               "#node-gateway-unconnected",
               "edge-01 has no active access key, so it isn't connected."
             )

      lv |> element("#code-new-button") |> render_click()
      assert_patch(lv, node_path(scope, node, "/access-key/new-code"))

      assert text(lv, "#code-issued-gateway") =~
               "Runs of build-01 go through the gateway edge-01, at https://edge.example.com."

      # On Default gateway, the command enrols through the default, by its URL.
      server = ApiaryWeb.Endpoint.url()
      command = text(lv, "#code-issued-command")

      assert ["qory", "access-key", "enrol", "--via", "https://edge.example.com", ^server, code] =
               String.split(command, " ")

      assert code =~ ~r/\Aqec_/

      assert text(lv, "#code-issued-header-description") ==
               "The command connects build-01 by itself, through the gateway edge-01: it makes the machine's key there, saves it, and writes Qory Apiary's address and public key and the gateway's address into the Forager file. The secret never leaves the machine."

      assert text(lv, "#code-issued-via-ca") ==
               "If edge-01's certificate is signed by a private certificate authority, add --via-ca-file and that authority's PEM file."

      # Once the gateway holds a key, it is connected.
      node_key_fixture(scope, gateway)
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))
      assert has_element?(lv, "#node-gateway", "edge-01")
      refute has_element?(lv, "#node-gateway-unconnected")
    end

    test "a node on a named gateway: the command and the Forager file's lines go through it",
         %{conn: conn, scope: scope} do
      gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      named = gateway_fixture(scope, name: "edge-02", url: "https://edge-02.example.com")

      node =
        node_fixture(scope, name: "build-01", gateway_choice: "named", gateway_id: named.id)

      server = ApiaryWeb.Endpoint.url()
      {lv, command} = command(conn, scope, node)

      assert [
               "qory",
               "access-key",
               "enrol",
               "--via",
               "https://edge-02.example.com",
               ^server,
               _code
             ] = String.split(command, " ")

      assert text(lv, "#code-issued-via-ca") =~ "If edge-02's certificate is signed"

      # A key the command brought: the lines it wrote, `via` among them, marked.
      %{access_key: key} = enrolled_key_fixture(scope, node, %{label: "current"})

      {:ok, lv, _html} =
        live(conn, node_path(scope, node, "/access-key/keys/#{key.key_id}/forager-file"))

      [%{"public_key" => public_key}] = Apiary.SigningKey.apiary_public_key()
      url = "    url: #{server}"
      key_line = "    access_key_id: #{key.key_id}"
      via_url = "      url: https://edge-02.example.com"

      width =
        Enum.max(Enum.map([url, key_line, "    apiary_public_key:", via_url], &String.length/1)) +
          2

      assert String.trim_trailing(lines(lv, "#key-forager-file-yaml")) <> "\n" ==
               """
               gateway:
                 server:
               #{String.pad_trailing(url, width)}# Qory Apiary
               #{String.pad_trailing(key_line, width)}# this key
               #{String.pad_trailing("    apiary_public_key:", width)}# Qory Apiary's public key
                     - {alg: ed25519, public_key: #{public_key}}
                   via:
               #{String.pad_trailing(via_url, width)}# the gateway edge-02
               """

      # Configure a machine: the address lines through the gateway, and what via does.
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))

      assert text(lv, "#node-configure-steps-1") =~
               "Point qory at Qory Apiary, through edge-02. In the Forager file. It is required: without it, qory ignores the three variables below. via sends every request to Qory Apiary through edge-02."

      refute text(lv, "#node-configure-steps-1") =~ "A starter"

      assert String.trim(lines(lv, "#node-configure-yaml")) ==
               "gateway:\n  server:\n    url: #{server}\n    via:\n      url: https://edge-02.example.com"
    end

    test "a pool behind a gateway: the command, Key for a node, its Forager file and Configure a machine",
         %{conn: conn, scope: scope} do
      gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      pool = pool_fixture(scope, name: "spot-runners")
      assert pool.gateway_choice == :default
      server = ApiaryWeb.Endpoint.url()

      address =
        "gateway:\n  server:\n    url: #{server}\n    via:\n      url: https://edge.example.com"

      {lv, command} = command(conn, scope, pool)
      assert command =~ ~r/\Aqory access-key enrol --via https:\/\/edge\.example\.com /

      assert text(lv, "#code-issued-header-description") =~
               "The command connects spot-runners by itself, through the gateway edge-01:"

      assert has_element?(lv, "#code-issued-via-ca")

      %{access_key: key} = browser_key_fixture(scope, pool, %{label: "spot-runners"})

      note =
        "via sends every request to Qory Apiary through edge-01. A starter that reaches Qory Apiary directly can leave via out."

      {:ok, lv, _html} =
        live(conn, node_path(scope, pool, "/access-key/keys/#{key.key_id}/generated"))

      assert text(lv, "#key-generated-steps-4") =~
               "Point qory at Qory Apiary, through edge-01. In the Forager file. It is required: without it, qory ignores the three variables. " <>
                 note

      assert String.trim(lines(lv, "#key-generated-yaml")) == address

      {:ok, lv, _html} =
        live(conn, node_path(scope, pool, "/access-key/keys/#{key.key_id}/forager-file"))

      assert text(lv, "#key-forager-file-steps-4") =~
               "Point qory at Qory Apiary, through edge-01."

      assert text(lv, "#key-forager-file-via") == note

      assert String.trim(lines(lv, "#key-forager-file-url")) == address

      {:ok, lv, _html} = live(conn, node_path(scope, pool, "/access-key"))
      assert text(lv, "#node-configure-steps-1") =~ "below. " <> note
      assert String.trim(lines(lv, "#node-configure-yaml")) == address
    end

    test "a gateway URL a shell would act on is quoted in the command", %{
      conn: conn,
      scope: scope
    } do
      # The brackets of an IPv6 host are a pattern to some shells.
      url = "https://[2001:db8::1]:8443"
      gateway_fixture(scope, name: "edge-01", url: url)
      node = node_fixture(scope, name: "build-01")
      server = ApiaryWeb.Endpoint.url()

      {lv, command} = command(conn, scope, node)

      assert command =~
               ~r/\Aqory access-key enrol --via 'https:\/\/\[2001:db8::1\]:8443' #{Regex.escape(server)} qec_/

      assert has_element?(lv, ~s{#code-issued-command-copy[data-copy="#{command}"]})
    end

    test "--replace and --via together, for a node that has a key", %{conn: conn, scope: scope} do
      gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      node = node_fixture(scope, name: "build-01")
      node_key_fixture(scope, node)
      server = ApiaryWeb.Endpoint.url()

      {_lv, command} = command(conn, scope, node)

      assert [
               "qory",
               "access-key",
               "enrol",
               "--replace",
               "--via",
               "https://edge.example.com",
               ^server,
               _code
             ] = String.split(command, " ")
    end

    test "carry no --via and no via for a node that goes direct, a node on Default gateway while none is the default, and a gateway",
         %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, name: "edge-01", url: "https://edge.example.com")
      direct = node_fixture(scope, name: "build-01", gateway_choice: "direct")
      default = node_fixture(scope, name: "build-02")
      server = ApiaryWeb.Endpoint.url()
      address = "gateway:\n  server:\n    url: #{server}"

      check = fn node ->
        {lv, command} = command(conn, scope, node)
        assert [_qory, _access_key, _enrol, ^server, _code] = String.split(command, " ")
        refute has_element?(lv, "#code-issued-via-ca")

        assert text(lv, "#code-issued-header-description") =~
                 "The command connects #{node.name} by itself: it makes the machine's key there,"

        %{access_key: key} = browser_key_fixture(scope, node)
        {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))
        assert text(lv, "#node-configure-steps-1") =~ "Point qory at Qory Apiary. In the"
        refute text(lv, "#node-configure-steps-1") =~ "via"
        assert String.trim(lines(lv, "#node-configure-yaml")) == address

        {:ok, lv, _html} =
          live(conn, node_path(scope, node, "/access-key/keys/#{key.key_id}/forager-file"))

        assert text(lv, "#key-forager-file-steps-4") =~ "Point qory at Qory Apiary."
        refute text(lv, "#key-forager-file-steps-4") =~ "through"

        refute has_element?(lv, "#key-forager-file-via")
        assert String.trim(lines(lv, "#key-forager-file-url")) == address
      end

      check.(direct)
      check.(gateway)
      unmark(gateway)
      check.(default)
    end

    test "name the gateway on a key's Forager file", %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, name: "edge-01")

      pool =
        pool_fixture(scope, name: "spot-runners", gateway_choice: "named", gateway_id: gateway.id)

      %{access_key: key} = node_key_fixture(scope, pool)

      {:ok, lv, _html} =
        live(conn, node_path(scope, pool, "/access-key/keys/#{key.key_id}/forager-file"))

      assert text(lv, "#key-forager-file-gateway") =~
               "Runs of spot-runners go through the gateway edge-01, at https://gateway.example."
    end

    test "say the gateway isn't connected while its only key is revoked", %{
      conn: conn,
      scope: scope
    } do
      gateway = gateway_fixture(scope, name: "edge-01")
      %{access_key: key} = node_key_fixture(scope, gateway)
      {:ok, _} = Apiary.AccessKeys.revoke_access_key(scope, key)
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))

      assert has_element?(
               lv,
               "#node-gateway-unconnected",
               "edge-01 has no active access key, so it isn't connected."
             )
    end

    test "name no gateway on Default gateway while none is the default", %{
      conn: conn,
      scope: scope
    } do
      gateway = gateway_fixture(scope, name: "edge-01")
      node = node_fixture(scope, name: "build-01")
      assert node.gateway_choice == :default
      Repo.update_all(from(n in Node, where: n.id == ^gateway.id), set: [default_gateway: false])

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))

      assert text(lv, "#node-gateway") == "No gateway is the default now."
      refute has_element?(lv, "#node-gateway-unconnected")
    end

    test "say nothing of a gateway for a node that goes direct", %{conn: conn, scope: scope} do
      gateway_fixture(scope, name: "edge-01")
      node = node_fixture(scope, name: "build-01", gateway_choice: "direct")

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))
      refute has_element?(lv, "#node-gateway")
    end
  end

  describe "a gateway's own words" do
    test "its kind, its form and its Access key tab say what its key does", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new-gateway"))

      assert render(lv) =~
               "An address the runs of this workspace&#39;s nodes and node pools go through, as each chooses."

      gateway = gateway_fixture(scope, name: "edge-01")
      {:ok, lv, _html} = live(conn, node_path(scope, gateway))

      assert render(lv) =~
               "Gateway: the runs of nodes and node pools that choose it go through it."

      assert text(lv, "#gateway-default") =~
               "Runs of nodes and node pools on Default gateway go through the default."

      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/access-key"))

      assert text(lv, "#node-connect-intro") ==
               "edge-01 connects to Qory Apiary with a key. The key enrols this gateway and registers no run. Choose one of two ways to give it one."

      refute has_element?(lv, "#node-gateway")

      node_key_fixture(scope, gateway)
      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/access-key"))

      assert text(lv, "#node-keys-intro") ==
               "edge-01 signs every request with its key, which enrols this gateway and registers no run. Qory Apiary keeps only the public half."

      assert text(lv, "#node-add-intro") =~ "A gateway holds two keys at most."

      node_key_fixture(scope, gateway)
      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/access-key"))

      assert text(lv, "#node-add-full") ==
               "edge-01 holds two keys, the most a gateway can. Revoke the one it no longer uses to add another."
    end

    test "its deletion is confirmed in a gateway's own sentence", %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, name: "edge-01")
      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/settings/delete"))

      assert text(lv, "#delete-node-form .q-danger-lost") ==
               "edge-01 leaves this workspace's gateways at once, and its name is free again. Its access keys are revoked, and a command not yet run is cancelled. While nodes or node pools point to it, or runs still go through it, it isn't deleted. This cannot be undone."

      refute text(lv, "#delete-node-form") =~ "Its runs stay in the record."

      assert text(lv, "#delete-node") =~
               "It leaves this workspace's gateways, its access keys are revoked and its name is free again. A gateway that nodes or node pools still point to, or that runs still go through, isn't deleted."
    end
  end

  describe "a gateway runs go through" do
    import Apiary.ContractFixtures

    alias Apiary.Runs.Run

    # A gateway with a key, and a node of the workspace that names it, with a key of its
    # own, through which runs register.
    defp through(scope) do
      %{access_key: gateway_key} =
        contract_key_fixture(scope, node: gateway_fixture(scope, name: "edge-01"))

      gateway = Repo.get!(Node, gateway_key.node_id)

      node =
        node_fixture(scope, name: "build-01", gateway_choice: "named", gateway_id: gateway.id)

      %{access_key: node_key} = contract_key_fixture(scope, node: node)
      %{gateway: gateway, node: node, node_key: node_key}
    end

    # Registers runs through the gateway with these ids, all at one time, so they are
    # named in the order of their run ids.
    defp register(%{node_key: key}, run_ids) do
      ids =
        for run_id <- run_ids do
          {:ok, %{run: run}} = register_run(key, gateway_registration(run_id), instance_id())
          run.id
        end

      Repo.update_all(from(r in Run, where: r.id in ^ids),
        set: [registered_at: DateTime.utc_now()]
      )
    end

    # The node goes directly from now on; the runs it registered keep their gateway.
    defp go_direct(scope, %{node: node}) do
      {:ok, _} = Nodes.update_node(scope, Repo.get!(Node, node.id), %{gateway_choice: "direct"})
      :ok
    end

    defp run_id(n), do: "00000000-0000-4000-8000-00000000000#{n}"

    # Deletes the gateway on its page, refused: the gateway stays, and the refusal's words.
    defp refused(conn, scope, gateway) do
      {:ok, lv, _html} = live(conn, node_path(scope, gateway, "/settings/delete"))
      lv |> form("#delete-node-form") |> render_submit()
      assert_patch(lv, node_path(scope, gateway, "/settings"))
      refute has_element?(lv, "#delete-node-form")
      assert Repo.get!(Node, gateway.id).deleted_at == nil
      text(lv, "#delete-node-refused")
    end

    test "is not deleted while runs go through it, which are named by run id", %{
      conn: conn,
      scope: scope
    } do
      through = through(scope)
      register(through, [run_id(1)])
      :ok = go_direct(scope, through)

      assert refused(conn, scope, through.gateway) ==
               "Runs are going through this gateway: #{run_id(1)}. Delete it once they end."
    end

    test "is not deleted while nodes point to it and runs go through it, both named", %{
      conn: conn,
      scope: scope
    } do
      through = through(scope)
      register(through, [run_id(1), run_id(2)])

      assert refused(conn, scope, through.gateway) ==
               "Nodes use this gateway: build-01. Runs are going through it: " <>
                 "#{run_id(1)}, #{run_id(2)}. " <>
                 "Delete it once the nodes point elsewhere and the runs end."
    end

    test "names the first five runs, then and N more", %{conn: conn, scope: scope} do
      through = through(scope)
      register(through, Enum.map(1..7, &run_id/1))
      :ok = go_direct(scope, through)

      assert refused(conn, scope, through.gateway) ==
               "Runs are going through this gateway: " <>
                 Enum.map_join(1..5, ", ", &run_id/1) <>
                 " and 2 more. Delete it once they end."
    end
  end

  describe "the deletion's refusal in words" do
    alias ApiaryWeb.NodeComponents
    alias Apiary.Runs.Run

    defp here(scope, name),
      do: %Node{
        name: name,
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id
      }

    defp run_here(scope, run_id),
      do: %Run{
        run_id: run_id,
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id
      }

    test "nodes, runs, or both", %{scope: scope} do
      nodes = [here(scope, "build-01"), here(scope, "a-pool")]
      runs = [run_here(scope, "run-1"), run_here(scope, "run-2")]

      assert NodeComponents.in_use_words(scope, %{nodes: nodes}) ==
               "Nodes use this gateway: build-01, a-pool. " <>
                 "Point them to another gateway or to direct, then delete it."

      assert NodeComponents.in_use_words(scope, %{nodes: [], runs: runs}) ==
               "Runs are going through this gateway: run-1, run-2. Delete it once they end."

      assert NodeComponents.in_use_words(scope, %{nodes: nodes, runs: runs}) ==
               "Nodes use this gateway: build-01, a-pool. Runs are going through it: " <>
                 "run-1, run-2. Delete it once the nodes point elsewhere and the runs end."

      assert NodeComponents.in_use_words(scope, %{nodes: []}) == nil
      assert NodeComponents.in_use_words(scope, %{nodes: [], runs: []}) == nil
    end

    test "names the first five, then and N more, others' rows counted among them", %{
      scope: scope
    } do
      nodes = for n <- 1..7, do: here(scope, "build-0#{n}")
      elsewhere = %{here(scope, "hidden") | workspace_id: Ecto.UUID.generate()}
      runs = for n <- 1..6, do: run_here(scope, "run-#{n}")

      assert NodeComponents.in_use_words(scope, %{nodes: nodes ++ [elsewhere], runs: runs}) ==
               "Nodes use this gateway: build-01, build-02, build-03, build-04, build-05 " <>
                 "and 3 more. Runs are going through it: run-1, run-2, run-3, run-4, run-5 " <>
                 "and 1 more. Delete it once the nodes point elsewhere and the runs end."

      assert NodeComponents.in_use_words(scope, %{nodes: [elsewhere]}) ==
               "Nodes use this gateway: 1 node of another workspace. " <>
                 "Point them to another gateway or to direct, then delete it."
    end
  end

  describe "the audit log" do
    test "calls a gateway a Gateway", %{conn: conn, scope: scope} do
      gateway = gateway_fixture(scope, name: "edge-01")
      pool = pool_fixture(scope, name: "spot-runners")

      {:ok, %{entries: entries}} = Audit.list_entries(scope, %{})
      created = Enum.find(entries, &(&1.action == "node.create" and &1.subject_id == gateway.id))
      pooled = Enum.find(entries, &(&1.action == "node.create" and &1.subject_id == pool.id))

      {:ok, lv, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
      render_async(lv)

      assert text(lv, "#entry-#{created.id}-change") == "Gateway #{gateway.public_id}"
      assert text(lv, "#entry-#{pooled.id}-change") == "Node pool #{pool.public_id}"
    end
  end
end
