defmodule ApiaryWeb.NodeLive.AccessKeyComponentsTest do
  # The key card and the waiting command of a node's Access key tab
  # (`ApiaryWeb.NodeLive.AccessKey.key_card/1`, `waiting/1`), drawn alone: as the tab draws
  # them, and for an adapter (`adapter`), without what only Forager's keys have. The tab's
  # tests (`ApiaryWeb.NodeLive.AccessKeyTest`) cover them on the page.
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.NodeLive.AccessKey, as: Tab

  @paths %{access_key: "/acme/shop/nodes/n/access-key"}
  @may %{revoke: true, revoke_code: true}
  @at ~U[2026-10-16 10:12:00.000000Z]

  defp key(fields \\ []) do
    struct!(
      %AccessKey{
        key_id: "ak_3n7p2x9k4m8q1v5t",
        label: "example-01",
        arrived_by: :code,
        received_at: @at,
        created_by: %User{email: "dana@example.com"},
        public_key: :binary.copy(<<7>>, 32),
        last_used_at: @at,
        last_forager_version: "0.9.0",
        allow_secrets: false
      },
      fields
    )
  end

  defp card(key, adapter) do
    assigns = %{
      key: key,
      node: %Node{name: "example-host", kind: if(adapter, do: :adapter, else: :node)},
      scope: %Scope{},
      adapter: adapter
    }

    rendered_to_string(~H"""
    <Tab.key_card
      key={@key}
      node={@node}
      scope={@scope}
      paths={%{access_key: "/acme/shop/nodes/n/access-key"}}
      may={%{revoke: true, revoke_code: true}}
      intact
      last_run={nil}
      hosts={nil}
      confirming={false}
      adapter={@adapter}
    />
    """)
    |> LazyHTML.from_fragment()
  end

  defp waiting(adapter) do
    code = %EnrolmentCode{
      id: Ecto.UUID.generate(),
      created_by: %User{email: "dana@example.com"},
      inserted_at: @at,
      expires_at: DateTime.add(@at, 15, :minute)
    }

    assigns = %{
      codes: [code],
      node: %Node{name: "example-host"},
      paths: @paths,
      may: @may,
      adapter: adapter
    }

    rendered_to_string(~H"""
    <Tab.waiting codes={@codes} code={nil} node={@node} may={@may} paths={@paths} adapter={@adapter} />
    """)
    |> LazyHTML.from_fragment()
  end

  defp labels(doc), do: doc |> LazyHTML.query("dt") |> Enum.map(&LazyHTML.text/1)
  defp text(doc), do: doc |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  defp has?(doc, selector), do: LazyHTML.query(doc, selector) |> Enum.count() > 0

  describe "key_card/1" do
    test "a node's key card has its Secret, Last used with Forager's version, and the Forager file" do
      doc = card(key(), false)

      assert labels(doc) ==
               ["Key ID", "Added", "Secret", "Last used", "Fingerprint"] ++
                 if(Apiary.Features.visible?(%Scope{}, :secrets),
                   do: ["Stored secrets"],
                   else: []
                 )

      assert text(LazyHTML.query(doc, "#key-ak_3n7p2x9k4m8q1v5t-secret")) ==
               "On example-host, saved there by the command"

      assert text(LazyHTML.query(doc, "#key-ak_3n7p2x9k4m8q1v5t-used")) =~ "Forager 0.9.0"
      assert has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-forager-file")
      assert has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-revoke")
    end

    test "an adapter's key card leaves off the Secret, Last used, stored secrets and the Forager file" do
      doc = card(key(allow_secrets: true), true)

      assert labels(doc) == ["Key ID", "Added", "Fingerprint"]
      refute has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-secret")
      refute has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-used")
      refute has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-stored-secrets")
      refute has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-forager-file")
      refute text(doc) =~ "Forager"
      refute text(doc) =~ "example-host"

      # Revoke… stays for a key it may revoke, and the row of acts goes with it.
      assert has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-revoke")

      revoked = card(key(revoked_at: @at, revoked_by: nil), true)
      refute has?(revoked, "#key-ak_3n7p2x9k4m8q1v5t-revoke")
      refute has?(revoked, "p.flex")
    end
  end

  describe "waiting/1" do
    test "a node's waiting command names the node" do
      assert text(waiting(false)) =~ "A command is waiting to be run on example-host."
      assert text(waiting(false)) =~ "dana@example.com got it at"
    end

    test "an adapter's waiting command leaves off the line that names where it runs" do
      doc = waiting(true)
      refute text(doc) =~ "A command is waiting to be run"
      refute text(doc) =~ "example-host"
      assert text(doc) =~ "dana@example.com got it at"
      assert has?(doc, "[id$=-revoke]")
    end
  end
end
