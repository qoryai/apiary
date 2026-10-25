defmodule ApiaryWeb.ActivityCollectionMoveTest do
  # The Activity line of `collection.move`: a collection that left the organisation's
  # Backlog because its adapter now lists it under another connection. Its sentence names
  # the collection by the title the entry recorded and the adapter by the name it
  # recorded, on the Activity page of the organisation it left; its subject is the
  # collection by its title now. It has no label, so the filter does not offer it.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  # The approved sentence, with the collection's title and the adapter's name filled in.
  defp sentence(adapter_name),
    do:
      "Shop board left this organisation's Backlog: " <>
        adapter_name <> " now lists it under another connection."

  defp listed(connection, id) do
    %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections: [
        %{
          ref: "SHOP",
          url: "https://tracker.acme.example/SHOP",
          title: "Shop board",
          grant_ref: listing_grant(connection),
          target: nil
        }
      ],
      listing: %{id: id, part: 1, started_at: DateTime.utc_now(:second), complete: true}
    }
  end

  # The scope's organisation lists the collection `SHOP` through an adapter named "Acme
  # tracker" and a fresh number; then another organisation's connection lists it: the
  # entry of the move, in the scope's organisation's trail, the collection that ended,
  # and the adapter's name.
  defp moved(scope) do
    %{adapter: adapter, access_key: key} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    key_scope = Scope.for_access_key(key)
    {mine, _nonce} = connection_fixture(scope, adapter, :connected)
    %{scope: other} = sign_up_fixture()
    {theirs, _nonce} = connection_fixture(other, adapter, :connected)

    {:ok, :accepted} = Collections.post_listing(key_scope, listed(mine, "first"))
    collection = Repo.get_by!(Collection, connection_id: mine.id)
    {:ok, :accepted} = Collections.post_listing(key_scope, listed(theirs, "second"))

    entry = Repo.one!(from e in Entry, where: e.action == "collection.move")
    {entry, collection, adapter.name}
  end

  test "no label, so the filter does not offer it" do
    %{scope: scope} = sign_up_fixture()
    assert Core.label(:"collection.move") == nil
    assert Core.label(:"collection.move", scope) == nil
    refute Core.offered?(scope, :"collection.move")
  end

  test "the sentence, from the entry the move left, and the collection as its subject" do
    %{scope: scope} = sign_up_fixture()
    {entry, collection, adapter_name} = moved(scope)

    assert entry.organisation_id == scope.organisation.id
    assert {entry.subject_kind, entry.subject_id} == {"collection", collection.id}
    assert entry.actor_kind == :instance

    names = Audit.names(scope, [entry])

    assert Enum.find_value(
             Describer.describers(),
             & &1.sentence(:"collection.move", entry, names)
           ) ==
             sentence(adapter_name)

    assert Core.subject(entry, :"collection.move", names, scope, nil) ==
             %{text: "Shop board", mono: true, href: nil}
  end

  test "the sentence names the title as a page shows an external system's text" do
    %{scope: scope} = sign_up_fixture()
    {entry, _collection, adapter_name} = moved(scope)
    # A bidirectional override, a zero-width space and a control character.
    sent = %{entry | details: %{entry.details | "name" => "\u202EShop board\u200B\a"}}

    assert Core.sentence(:"collection.move", sent, Audit.names(scope, [sent])) ==
             "Shop board\uFFFD left this organisation's Backlog: " <>
               adapter_name <> " now lists it under another connection."
  end

  test "an entry that names no title or adapter: the core gives no sentence for it" do
    entry = %Entry{action: "collection.move", actor_kind: :instance, details: %{}}
    assert Core.sentence(:"collection.move", entry, %{}) == nil
  end

  describe "on the Activity page of the organisation it left" do
    setup :register_and_log_in_user

    test "the entry shows the sentence and the collection", %{conn: conn, scope: scope} do
      {entry, _collection, adapter_name} = moved(scope)

      {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
      render_async(view)

      text = fn selector ->
        view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      end

      assert String.trim(text.("#entry-#{entry.id}-action")) == sentence(adapter_name)
      assert text.("#entry-#{entry.id}-subject") =~ "Shop board"
    end
  end
end
