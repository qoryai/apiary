defmodule ApiaryWeb.TargetLive.BacklogTest do
  @moduledoc """
  The Backlog card of a target's Overview (`ApiaryWeb.TargetLive.Show`): where the
  target's collection is assigned to the workspace, one switch, whether its tickets come
  into the Backlog, in its source's word for them; on by default; turned by an owner or an admin, with a toast that says
  what is so now; read-only, disabled, for a member, with who may change it; and no card
  where the target has no collection there, where its collection or its adapter has no
  items, or where the reader is not shown the feature.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, Targets}
  alias Apiary.Adapters.Collection
  alias Apiary.Audit.Entry

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp repo(system, path), do: %{"forge" => system, "repository" => path}

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  setup %{scope: scope} do
    started_run(scope, repo("code.example.com", "acme/shop"))
    shop = Targets.get(scope, "code.example.com", "acme/shop")
    connection = ticket_connection_fixture(scope)

    collection =
      source_collection_fixture(scope, connection, %{
        target_system: "code.example.com",
        target_path: "acme/shop"
      })

    %{
      shop: shop,
      collection: collection,
      path: workspace_path(scope, "/targets/#{shop.public_id}")
    }
  end

  defp backlog_of(collection), do: Repo.get!(Collection, collection.id).backlog

  defp turn_off(collection),
    do: collection |> Ecto.Changeset.change(backlog: false) |> Repo.update!()

  test "on by default: the card, third in the main column, with its switch on and its description",
       %{conn: conn, path: path} do
    view = open(conn, path)

    assert has_element?(
             view,
             "#target-overview .q-tgt-ov-main > section + section + section#target-backlog"
           )

    assert has_element?(view, "#target-backlog-h", "Backlog")
    assert has_element?(view, "#target-backlog-switch[role=switch][aria-checked=true]")
    refute has_element?(view, "#target-backlog-switch[disabled]")

    assert has_element?(
             view,
             "label[for=target-backlog-switch]",
             "Take its tickets into the Backlog"
           )

    assert has_element?(
             view,
             "#target-backlog-switch-description",
             "If its tickets only track bugs, turn this off. Work items already taken in stay."
           )

    refute has_element?(view, "#target-backlog-read-only")
  end

  test "an owner turns it off and on again, each with its toast and its trail entry",
       %{conn: conn, path: path, collection: collection} do
    view = open(conn, path)

    view |> element("#target-backlog-switch") |> render_click()
    assert has_element?(view, "#target-backlog-switch[aria-checked=false]")

    assert has_element?(
             view,
             "#flash-info",
             "The tickets of acme/shop no longer come into the Backlog."
           )

    refute backlog_of(collection)

    view |> element("#target-backlog-switch") |> render_click()
    assert has_element?(view, "#target-backlog-switch[aria-checked=true]")

    assert has_element?(
             view,
             "#flash-info",
             "The tickets of acme/shop now come into the Backlog."
           )

    assert backlog_of(collection)

    assert [false, true] =
             Repo.all(
               from e in Entry,
                 where: e.action == "collection.set_backlog",
                 order_by: [asc: e.inserted_at, asc: e.id],
                 select: fragment("(?->>'backlog')::boolean", e.details)
             )
  end

  test "Activity says each change, about the target", %{conn: conn, scope: scope, path: path} do
    view = open(conn, path)
    view |> element("#target-backlog-switch") |> render_click()
    view |> element("#target-backlog-switch") |> render_click()

    {:ok, activity, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
    render_async(activity)
    html = render(activity)

    assert html =~ "Turned off taking a repository&#39;s tickets into the Backlog"
    assert html =~ "Turned on taking a repository&#39;s tickets into the Backlog"
    assert html =~ "acme/shop"
  end

  test "a source that names its items: the card, the toast and Activity say its word",
       %{conn: conn, scope: scope, path: path, collection: collection} do
    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^collection.adapter_id),
      set: [item_noun_one: "story", item_noun_other: "stories"]
    )

    view = open(conn, path)

    assert has_element?(
             view,
             "label[for=target-backlog-switch]",
             "Take its stories into the Backlog"
           )

    assert has_element?(
             view,
             "#target-backlog-switch-description",
             "If its stories only track bugs, turn this off. Work items already taken in stay."
           )

    view |> element("#target-backlog-switch") |> render_click()

    assert has_element?(
             view,
             "#flash-info",
             "The stories of acme/shop no longer come into the Backlog."
           )

    {:ok, activity, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
    render_async(activity)
    html = render(activity)

    assert html =~ "Turned off taking a repository&#39;s stories into the Backlog"
    assert html =~ "Taking stories into the Backlog turned on or off"
  end

  test "off, it shows off", %{conn: conn, path: path, collection: collection} do
    turn_off(collection)
    view = open(conn, path)
    assert has_element?(view, "#target-backlog-switch[aria-checked=false]")
  end

  test "an admin turns it", %{scope: scope, path: path, collection: collection} do
    %{user: admin} = member_fixture(scope, :admin)
    view = open(log_in_user(build_conn(), admin), path)

    refute has_element?(view, "#target-backlog-read-only")
    view |> element("#target-backlog-switch") |> render_click()
    refute backlog_of(collection)
  end

  test "a member reads it, on and off, disabled, with who may change it; sent anyway, refused",
       %{scope: scope, path: path, collection: collection} do
    %{user: member} = member_fixture(scope, :member)
    conn = log_in_user(build_conn(), member)

    view = open(conn, path)
    assert has_element?(view, "#target-backlog-switch[aria-checked=true][disabled]")

    assert has_element?(
             view,
             "#target-backlog-read-only",
             "Only owners and admins change this."
           )

    render_click(view, "set_backlog", %{})
    assert has_element?(view, "#flash-error", "Only owners and admins change this.")
    assert backlog_of(collection)

    turn_off(collection)
    view = open(conn, path)
    assert has_element?(view, "#target-backlog-switch[aria-checked=false][disabled]")
    assert has_element?(view, "#target-backlog-read-only")
  end

  test "no card for a target with no collection in the workspace, or one that ended",
       %{conn: conn, scope: scope, path: path, collection: collection} do
    started_run(scope, repo("code.example.com", "acme/api"))
    api = Targets.get(scope, "code.example.com", "acme/api")

    refute has_element?(
             open(conn, workspace_path(scope, "/targets/#{api.public_id}")),
             "#target-backlog"
           )

    collection
    |> Ecto.Changeset.change(ended_at: DateTime.utc_now(), ended_reason: :disconnected)
    |> Repo.update!()

    refute has_element?(open(conn, path), "#target-backlog")
  end

  test "no card for a collection with no items, or of an adapter with none; the page otherwise the same",
       %{conn: conn, path: path, collection: collection} do
    with_card = open(conn, path)
    assert has_element?(with_card, "#target-backlog")
    others = parts(with_card)
    assert "target-last-runs" in others and "target-about" in others

    collection = collection |> Ecto.Changeset.change(items: false) |> Repo.update!()
    view = open(conn, path)
    refute has_element?(view, "#target-backlog")
    assert parts(view) == others

    collection |> Ecto.Changeset.change(items: true) |> Repo.update!()

    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^collection.adapter_id),
      set: [items: false]
    )

    view = open(conn, path)
    refute has_element?(view, "#target-backlog")
    assert parts(view) == others
    assert backlog_of(collection)
  end

  # The ids of the Overview's parts, the Backlog card's left out.
  defp parts(view) do
    html = view |> element("#target-overview") |> render()

    for [_, id] <- Regex.scan(~r/ id="([^"]+)"/, html),
        not String.starts_with?(id, "target-backlog"),
        uniq: true,
        do: id
  end

  test "no card where the reader is not shown the feature", %{conn: conn, path: path} do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put([:factory])

    view = open(conn, path)
    assert has_element?(view, "#target-overview")
    refute has_element?(view, "#target-backlog")
  end
end
