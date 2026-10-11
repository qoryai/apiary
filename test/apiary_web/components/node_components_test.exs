defmodule ApiaryWeb.NodeComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Apiary.Nodes.Node
  alias ApiaryWeb.NodeComponents

  @server "https://apiary.example.com"
  @code "qec_0123456789ABCDEFGHJKMNPQRS.fingerprint"

  describe "enrol_command/3" do
    test "is qory's enrol, the server's address and the code, without a gateway" do
      assert NodeComponents.enrol_command(@server, @code) ==
               "qory access-key enrol https://apiary.example.com #{@code}"

      assert NodeComponents.enrol_command(@server, @code, via: nil) ==
               NodeComponents.enrol_command(@server, @code)

      assert NodeComponents.enrol_command(@server, @code, replace: true) ==
               "qory access-key enrol --replace https://apiary.example.com #{@code}"
    end

    test "carries --via and the gateway's URL before the server's address, as qory takes it" do
      assert NodeComponents.enrol_command(@server, @code, via: "https://edge.example.com") ==
               "qory access-key enrol --via https://edge.example.com https://apiary.example.com #{@code}"

      assert NodeComponents.enrol_command(@server, @code,
               replace: true,
               via: "https://edge.example.com"
             ) ==
               "qory access-key enrol --replace --via https://edge.example.com https://apiary.example.com #{@code}"
    end
  end

  describe "via_ca_line/1" do
    test "names --via-ca-file for a gateway, and is nothing without one" do
      gateway = %Node{kind: :gateway, name: "edge-01", url: "https://edge.example.com"}
      assigns = %{gateway: gateway}

      html = rendered_to_string(~H|<NodeComponents.via_ca_line id="ca" gateway={@gateway} />|)
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.text() |> String.split() |> Enum.join(" ") ==
               "If edge-01's certificate is signed by a private certificate authority, add --via-ca-file and that authority's PEM file."

      assert doc |> LazyHTML.query("#ca .font-mono") |> LazyHTML.text() == "--via-ca-file"

      assigns = %{gateway: nil}

      assert rendered_to_string(~H|<NodeComponents.via_ca_line id="ca" gateway={@gateway} />|)
             |> String.trim() == ""
    end
  end
end
