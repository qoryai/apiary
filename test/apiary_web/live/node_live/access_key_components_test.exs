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

  defp card(key, adapter, may \\ @may) do
    assigns = %{
      key: key,
      node: %Node{name: "example-host", kind: if(adapter, do: :adapter, else: :node)},
      scope: %Scope{},
      paths: @paths,
      may: may,
      adapter: adapter
    }

    rendered_to_string(~H"""
    <Tab.key_card
      key={@key}
      node={@node}
      scope={@scope}
      paths={@paths}
      may={@may}
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

    test "an adapter's key card says where its secret is and when it was last used, without Forager's rows" do
      doc = card(key(allow_secrets: true), true)

      assert labels(doc) == ["Key ID", "Added", "Secret", "Last used", "Fingerprint"]

      assert text(LazyHTML.query(doc, "#key-ak_3n7p2x9k4m8q1v5t-secret")) ==
               "On the machine that ran the command; never shown"

      assert text(LazyHTML.query(doc, "#key-ak_3n7p2x9k4m8q1v5t-used")) ==
               text(LazyHTML.from_fragment(ApiaryWeb.Format.datetime(@at)))

      refute has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-stored-secrets")
      refute has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-forager-file")
      refute text(doc) =~ "Forager"
      refute text(doc) =~ "example-host"

      never = card(key(last_used_at: nil), true)
      assert text(LazyHTML.query(never, "#key-ak_3n7p2x9k4m8q1v5t-used")) == "Not yet"
    end

    test "an adapter's key card has a row of acts only for a key it may revoke" do
      doc = card(key(), true)
      assert has?(doc, "#key-ak_3n7p2x9k4m8q1v5t-revoke")

      # An active key it may not revoke: no Forager file and no Revoke…, so no empty row.
      may_not = card(key(), true, %{revoke: false, revoke_code: false})
      refute has?(may_not, "#key-ak_3n7p2x9k4m8q1v5t-revoke")
      refute has?(may_not, "p.flex")

      # A node's active key keeps its row for the Forager file all the same.
      assert has?(card(key(), false, %{revoke: false, revoke_code: false}), "p.flex")

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

    test "an adapter's waiting command names no place where it runs" do
      doc = waiting(true)
      assert text(LazyHTML.query(doc, "p:first-child")) == "A command is waiting to be run."
      refute text(doc) =~ "example-host"
      assert text(doc) =~ "dana@example.com got it at"
      assert has?(doc, "[id$=-revoke]")
    end
  end

  describe "who draws an adapter's card" do
    # An adapter's key card shows when its key was last used, which is the instance admins'
    # alone: only a page of the instance's admins, at `/instance/…`, may draw it. Every
    # module that calls `key_card/1` or `waiting/1` but the tab that defines them is such a
    # page.
    @tab "lib/apiary_web/live/node_live/access_key.ex"
    @call ~r/AccessKey\.(key_card|waiting)\b|<\.(key_card|waiting)\b|\b(key_card|waiting): 1\b/

    defp live_paths(module) do
      for %{path: path, metadata: %{phoenix_live_view: {^module, _action, _opts, _extra}}} <-
            ApiaryWeb.Router.__routes__(),
          do: path
    end

    test "every page that draws them, but a node's Access key tab, is an instance admin's" do
      callers =
        for path <- Path.wildcard("lib/**/*.{ex,heex}"),
            path != @tab,
            source = File.read!(path),
            source =~ @call,
            [_, name] <- Regex.scan(~r/^defmodule ([\w.]+) do/m, source),
            do: Module.concat([name])

      for module <- callers do
        paths = live_paths(module)
        assert paths != [], "#{inspect(module)} draws a key card and is not a page"

        assert Enum.all?(paths, &String.starts_with?(&1, "/instance/")),
               "#{inspect(module)} draws a key card at #{inspect(paths)}"
      end
    end

    test "an adapter's Access key tab is served under /instance/ alone" do
      paths = live_paths(ApiaryWeb.AdapterLive.AccessKey)
      assert paths != []
      assert Enum.all?(paths, &String.starts_with?(&1, "/instance/adapters"))
    end
  end
end
