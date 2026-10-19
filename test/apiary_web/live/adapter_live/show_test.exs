defmodule ApiaryWeb.AdapterLive.ShowTest do
  # An integration's page in Organisation settings › Integrations
  # (`ApiaryWeb.AdapterLive.Show`): where the organisation's connection to it stands, not
  # installed, pending, its pass expired, ended on the integration, or installed, with a
  # pending or expired install not installed to a member; while not installed, the install
  # block to an owner or an admin; installed, the wait for the first listing and, a minute
  # on, the line to install again; the return's flash; behind the feature, for members.
  # Once listed, the collections: still arriving, then complete, live, a page at a time,
  # with the lead for one workspace, or for an adapter with no items; a search, and how
  # many it finds; the source's line on its access, the first foot note, isolated and
  # cleaned; the line for those the integration no longer reaches; a page past the
  # last, and the address that names the page shown. With several workspaces: the
  # unassigned ones first, the warning, the views, the workspace filter, the selection and
  # its menu, which assigns them, then shows the first page.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collections, Connection}
  alias ApiaryWeb.ConnectSession

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup do
    %{adapter: adapter, pair: pair, access_key: key} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{adapter: adapter, pair: pair, key: key}
  end

  defp page(scope, adapter),
    do: ~p"/#{scope.organisation}/settings/integrations/#{adapter.public_id}"

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp set(%Connection{id: id}, fields) do
    {1, _} = Repo.update_all(from(c in Connection, where: c.id == ^id), set: fields)
    :ok
  end

  defp time(at), do: ApiaryWeb.Format.time(at)

  # The words of a person's letter in the page's text: the letter, then the address of its
  # hidden text, and "(you)" for the reader.
  defp letter(user, you \\ false),
    do: "#{String.upcase(String.first(user.email))}#{user.email}#{if you, do: " (you)"}"

  # One part of a listing of `connection`, as the adapter of `key` sends it: a collection
  # per title, with no target; `{title, :target}` for one whose target is on
  # code.example.com at the title's path.
  defp post(
         key,
         connection,
         titles,
         part,
         complete,
         started_at \\ ~U[2026-10-01 09:00:00Z],
         id \\ "first"
       ) do
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(key), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections: Enum.map(titles, &listed/1),
        listing: %{id: id, part: part, started_at: started_at, complete: complete}
      })

    :ok
  end

  # A later complete listing of `connection`, `id`, that names `titles` only: the
  # collections it leaves out end.
  defp relist(key, connection, titles, id, started_at) do
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(key), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections:
          for title <- titles do
            %{ref: title, url: "https://forge.example.com/" <> title, title: title, target: nil}
          end,
        listing: %{id: id, part: 1, started_at: started_at, complete: true}
      })

    :ok
  end

  defp collection_ids(connection, titles) do
    Repo.all(
      from c in Apiary.Adapters.Collection,
        where: c.connection_id == ^connection.id and c.title in ^titles,
        select: c.id
    )
  end

  defp listed({title, :target}),
    do: %{listed(title) | target: %{system: "code.example.com", path: title}}

  defp listed(title),
    do: %{ref: title, url: "https://forge.example.com/" <> title, title: title, target: nil}

  # The organisation with a second workspace, Platform, and a connection to `adapter`
  # whose complete listing names `names`, each unassigned.
  defp several(scope, adapter, key, names) do
    :ok = Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    platform = workspace_fixture(scope.organisation, "Platform")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, names, 1, true)
    {connection, platform}
  end

  defp pick(lv, name) do
    lv
    |> element(~s{#collections-table input[aria-label="Select #{name}"]})
    |> render_click()
  end

  defp public_id(connection, title),
    do:
      Repo.get_by!(Apiary.Adapters.Collection, connection_id: connection.id, title: title).public_id

  defp titles(range), do: for(n <- range, do: "acme/repo-" <> String.pad_leading("#{n}", 3, "0"))

  # Each row's words, a space between the parts of a cell, as the screen shows them apart.
  defp rows(lv) do
    lv
    |> render()
    |> String.replace("><", "> <")
    |> LazyHTML.from_document()
    |> LazyHTML.query("#collections-table tr")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query("th, td")
      |> Enum.map_join(" ", &LazyHTML.text/1)
      |> String.split()
      |> Enum.join(" ")
    end)
  end

  test "with no connection: not installed, and the install block with Install",
       %{conn: conn, scope: scope, adapter: adapter} do
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "h1", adapter.name)

    assert page_title(lv) =~
             "#{adapter.name} · Integrations · Organisation settings · #{scope.organisation.name}"

    assert has_element?(lv, ~s{#settings-tab-integrations[aria-current="true"]})

    assert has_element?(
             lv,
             ~s{#breadcrumb-section[href="/#{scope.organisation.slug}/settings/integrations"]},
             "Integrations"
           )

    assert words(lv, "#integration-status") == "Not installed."

    assert words(lv, "#integration-install") ==
             "#{adapter.name} then brings you back here. The collections it reaches are listed on this page. #{scope.organisation.name} can have one installation of #{adapter.name}. Install"

    refute has_element?(lv, "#integration-install-name")
    refute has_element?(lv, "#integration-install-cancel")

    assert has_element?(
             lv,
             ~s{form#integration-install-form[action="#{page(scope, adapter)}/install"]}
           )

    assert has_element?(lv, "#integration-install-form-install:not([disabled])")
    refute has_element?(lv, "#collections")

    form = form(lv, "#integration-install-form")
    render_submit(form)

    assert words(lv, "#integration-install-sending") == "Taking you to #{adapter.name}…"

    conn = follow_trigger_action(form, conn)
    assert conn.request_path == page(scope, adapter) <> "/install"
    assert conn.resp_body =~ "https://tracker.example.com/connect?state="
  end

  test "the h1 holds the integration's mark, hidden from screen readers, then its name",
       %{conn: conn, scope: scope, adapter: adapter} do
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, ~s{h1#settings-section-title.q-settings-title[tabindex="-1"]})

    assert has_element?(
             lv,
             ~s{#settings-section-title [aria-hidden="true"] > .hero-puzzle-piece-micro}
           )

    assert words(lv, "#settings-section-title") == adapter.name
    refute has_element?(lv, ~s{#settings-section-title [aria-hidden="true"]}, adapter.name)

    assert page_title(lv) ==
             "#{adapter.name} · Integrations · Organisation settings · #{scope.organisation.name} · Qory Apiary"

    assert words(lv, ~s{#breadcrumb [aria-current="page"]}) == adapter.name
  end

  test "an integration not set up yet: Install disabled, and why", %{conn: conn, scope: scope} do
    adapter = adapter_fixture(%{name: unique_adapter_name("Shop tracker")})
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "#integration-install-form-install[disabled]")

    assert words(lv, "#integration-install-not-ready") ==
             "#{adapter.name} can't be installed yet: this instance's admins are still setting it up."
  end

  test "pending, its pass still good: who started it today and when", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. #{letter(scope.user, true)} started an install today at #{time(connection.updated_at)} that isn't finished: finish it on #{adapter.name}, or press Install to start again."

    assert has_element?(lv, "#integration-install")
  end

  test "pending, its pass expired: that it expired", %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    set(connection, pass_expires_at: DateTime.add(DateTime.utc_now(:second), -1))
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. An install #{letter(scope.user, true)} started today at #{time(connection.updated_at)} expired before it was finished. Press Install to start again."

    assert has_element?(lv, "#integration-install")
  end

  test "pending, started before today, or its pass came back refused or cancelled: not installed",
       %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    set(connection, pass_nonce_used_at: DateTime.utc_now())
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    assert has_element?(lv, "#integration-install")

    set(connection,
      pass_nonce_used_at: nil,
      updated_at: DateTime.add(DateTime.utc_now(), -2, :day)
    )

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
  end

  test "ended on the integration: when, and that its tickets left every backlog", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    ended_at = ~U[2026-03-14 09:00:00.000000Z]
    set(connection, state: :ended, ended_at: ended_at, ended_reason: :adapter_reported)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. The installation ended on #{ApiaryWeb.Format.day(ended_at)}, when #{adapter.name} reported it gone. The tickets #{adapter.name} brought in left every backlog; work items already taken in stay."

    assert has_element?(lv, "#integration-install")
    refute has_element?(lv, "#collections")
  end

  test "ended on the integration, in the adapter's words for its items, or with none", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    adapter = describe_source(adapter, "example-tracker.json")
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    ended_at = DateTime.utc_now()
    set(connection, state: :ended, ended_at: ended_at, ended_reason: :adapter_reported)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") =~
             "The issues #{adapter.name} brought in left every backlog;"

    describe_source(adapter, "example-projects.json")
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. The installation ended on #{ApiaryWeb.Format.day(ended_at)}, when #{adapter.name} reported it gone."
  end

  test "ended on the integration: before it connected, not installed; before a listing, no backlogs",
       %{conn: conn, scope: scope, adapter: adapter} do
    ended_at = ~U[2026-03-14 09:00:00.000000Z]
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    set(connection, state: :ended, ended_at: ended_at, ended_reason: :adapter_reported)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    assert has_element?(lv, "#integration-install")

    gone =
      "Not installed. The installation ended on #{ApiaryWeb.Format.day(ended_at)}, when #{adapter.name} reported it gone."

    set(connection, connected_at: ~U[2026-03-13 09:00:00.000000Z])
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == gone

    set(connection, listed_at: ~U[2026-03-13 09:01:00.000000Z])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             gone <>
               " The tickets #{adapter.name} brought in left every backlog; work items already taken in stay."
  end

  test "an end for another reason, or a connection after it, says no end", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    set(connection, state: :ended, ended_at: DateTime.utc_now(), ended_reason: :replaced)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."

    set(connection, ended_reason: :adapter_reported)
    connection_fixture(scope, adapter, :pending)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") =~ "started an install today"
  end

  test "installed and not yet listed: who installed it today, and the wait for its collections",
       %{conn: conn, scope: scope, adapter: adapter} do
    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") == "Installed by #{letter(scope.user, true)} today."
    refute has_element?(lv, "#integration-install")
    assert words(lv, "#collections-heading") == "Collections"

    assert words(lv, "#collections-waiting") ==
             "Waiting for #{adapter.name} to send its collections…"

    assert has_element?(lv, ~s{#collections-waiting[role="status"]})
    refute has_element?(lv, "#collections-late")

    send(lv.pid, :late)

    assert has_element?(lv, "#collections-late span", "If nothing appears, install again.")
    assert has_element?(lv, "#collections-late button#collections-install-install", "Install")

    form = form(lv, "#collections-install")
    render_submit(form)
    conn = follow_trigger_action(form, conn)
    assert conn.request_path == page(scope, adapter) <> "/install"
    assert conn.resp_body =~ "https://tracker.example.com/connect?state="
  end

  test "waiting, the page starts the minute to the line to install again once, as it opens",
       %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    timer = :sys.get_state(lv.pid).socket.assigns.timer
    assert is_reference(timer)
    assert Process.read_timer(timer) in 55_000..60_000

    send(
      lv.pid,
      {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}}
    )

    assert has_element?(lv, "#collections-waiting")
    assert :sys.get_state(lv.pid).socket.assigns.timer == timer
  end

  test "a source that names no word for its collections: collection, for one and many", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    assert Apiary.Adapters.collection_noun(adapter) == nil
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, [{"acme/shop", :target}], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-heading") == "Collections 1"
    assert has_element?(lv, ~s{[role="region"][aria-label="Collections"]})
    assert hd(rows(lv)) =~ "Collection Workspace"
    assert words(lv, "#collections-count") == "1 collection"
    assert has_element?(lv, ~s{#collections-search input[placeholder="Find a collection"]})
    assert words(lv, "#collections-targets") =~ "Assigning a collection here"
  end

  test "the collections are named in the adapter's words", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    adapter = describe_source(adapter, "example-tracker.json")
    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-heading") == "Projects"

    assert words(lv, "#collections-waiting") ==
             "Waiting for #{adapter.name} to send its projects…"
  end

  test "installed on an earlier day: on which", %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    earlier = ~U[2026-03-04 10:00:00.000000Z]
    set(connection, connected_at: earlier)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Installed by #{letter(scope.user, true)} on #{ApiaryWeb.Format.day(earlier)}."

    refute has_element?(lv, "#collections-waiting")
  end

  test "the wait ends when the first listing names the connection", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-waiting")

    set(connection, listed_at: DateTime.utc_now())

    send(
      lv.pid,
      {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}}
    )

    refute has_element?(lv, "#collections-waiting")
    send(lv.pid, :late)
    refute has_element?(lv, "#collections-late")
  end

  test "the page shows the return's flash", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    pair: pair
  } do
    {:ok, _url, {public_id, nonce} = session} = Apiary.Adapters.connect(scope, adapter)
    token = return_token(pair.secret, public_id, nonce)

    conn =
      conn
      |> ConnectSession.put(session)
      |> get(~p"/integrations/#{public_id}?return=#{token}")

    assert redirected_to(conn) == page(scope, adapter)

    {:ok, lv, _html} = live(recycle(conn), page(scope, adapter))
    assert words(lv, "#flash-info") =~ "#{adapter.name} is connected."
    assert has_element?(lv, "#collections-waiting")
  end

  test "listed, one workspace: the lead, how many, and a row per collection", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, [{"acme/shop", :target}, {"acme/api", :target}], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-heading") == "Collections 2"
    refute has_element?(lv, "#collections-waiting")
    refute has_element?(lv, "#collections-filling")

    assert words(lv, "#collections-lead") ==
             "#{scope.organisation.name} has one workspace, #{scope.workspace.name}, so every collection is assigned to it, and its tickets come into #{scope.workspace.name}'s Backlog while its Backlog switch is on."

    assert words(lv, "#collections-count") == "2 collections"
    assert has_element?(lv, ~s{[role="region"][aria-label="Collections"]})

    assert rows(lv) == [
             "Collection Workspace Backlog Open tickets Added",
             "acme/api Backlog #{scope.workspace.name} — Today",
             "acme/shop Backlog #{scope.workspace.name} — Today"
           ]

    assert words(lv, "#collections-targets") ==
             "Assigning a collection here doesn't change a workspace's Repositories, which list what its runs change."

    refute has_element?(lv, "#collections-pager")
  end

  test "a collection's open items, and the day it was added", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/shop"], 1, true)
    collection = Repo.get_by!(Apiary.Adapters.Collection, connection_id: connection.id)
    earlier = ~U[2026-03-04 10:00:00Z]

    {1, _} =
      Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^collection.id),
        set: [inserted_at: earlier]
      )

    for n <- 1..3 do
      Apiary.WorkItemsFixtures.source_item_fixture(scope,
        collection: collection,
        external_ref: "acme/shop##{n}",
        key: "##{n}"
      )
    end

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert rows(lv) == [
             "Collection Workspace Backlog Open tickets Added",
             "acme/shop Backlog #{scope.workspace.name} 3 #{ApiaryWeb.Format.day(earlier)}"
           ]
  end

  test "in the adapter's words: its collections and its items", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    adapter = describe_source(adapter, "example-tracker.json")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["Support"], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-heading") == "Projects 1"
    assert words(lv, "#collections-lead") =~ "so every project is assigned to it, and its issues"
    assert words(lv, "#collections-count") == "1 project"
    assert hd(rows(lv)) == "Project Workspace Backlog Open issues Added"
    refute has_element?(lv, "#collections-targets")
  end

  test "an adapter with no items: the lead says only that each is assigned, and no open column",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    adapter = describe_source(adapter, "example-projects.json")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["Support"], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-lead") == "These projects are each assigned to one workspace."
    assert rows(lv) == ["Project Workspace Added", "Support #{scope.workspace.name} Today"]
  end

  test "the lead shows while the page waits for the first listing; the foot note does not", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "#collections-waiting")
    assert words(lv, "#collections-lead") =~ "has one workspace, #{scope.workspace.name}"
    refute has_element?(lv, "#collections-targets")
    refute has_element?(lv, "#collections-table")
    refute has_element?(lv, "#collections-count")
  end

  test "the foot note shows where a live collection has a target, and goes where none has", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/docs", {"acme/shop", :target}], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-targets") ==
             "Assigning a collection here doesn't change a workspace's Repositories, which list what its runs change."

    # The collection with a target ends: the page follows, and the foot note goes.
    shop =
      Repo.get_by!(Apiary.Adapters.Collection, connection_id: connection.id, title: "acme/shop")

    {1, _} =
      Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^shop.id),
        set: [ended_at: DateTime.utc_now(), ended_reason: :not_listed]
      )

    send(
      lv.pid,
      {:collections_changed, %{connection_id: connection.id, collection_ids: [shop.id]}}
    )

    refute has_element?(lv, "#collections-targets")
    assert has_element?(lv, "#collections-table")
  end

  test "a source whose collections carry no target has no foot note; with one, it comes", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/docs", "acme/notes"], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "#collections-table")
    refute has_element?(lv, "#collections-targets")

    # A later listing names one with a target: the page follows it.
    post(
      key,
      connection,
      ["acme/docs", "acme/notes", {"acme/shop", :target}],
      1,
      true,
      ~U[2026-10-02 09:00:00Z],
      "second"
    )

    assert words(lv, "#collections-targets") =~ "Assigning a collection here"
  end

  test "an adapter with no items follows the same rule for the foot note", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    adapter = describe_source(adapter, "example-projects.json")
    %{adapter: other, access_key: other_key} = connectable_adapter_fixture(%{name: "Shop host"})
    other = describe_source(other, "example-projects.json")

    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["Support"], 1, true)
    {other_connection, _nonce} = connection_fixture(scope, other, :connected)
    post(other_key, other_connection, [{"acme/shop", :target}], 1, true)

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#collections-lead") == "These projects are each assigned to one workspace."
    refute has_element?(lv, "#collections-targets")

    {:ok, lv, _html} = live(conn, page(scope, other))
    assert words(lv, "#collections-lead") == "These projects are each assigned to one workspace."

    assert words(lv, "#collections-targets") ==
             "Assigning a project here doesn't change a workspace's Repositories, which list what its runs change."
  end

  # The text of the access foot note's `<bdi>`, as the page shows it, nothing trimmed.
  defp access_text(lv) do
    lv
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#collections-access > bdi")
    |> LazyHTML.text()
  end

  # The ids of the foot notes under the collections, in the page's order.
  defp foot_notes(lv) do
    lv
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#collections .q-foot-note")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))
  end

  defp set_access(adapter, text) do
    {1, _} =
      Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.id),
        set: [source_access: text]
      )

    :ok
  end

  test "the source's access line is the first foot note, as the contract's example says",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    adapter = describe_source(adapter, "example-tracker.json")

    line =
      get_in(Apiary.DescriptionFixtures.contract_description("example-tracker.json"), [
        "roles",
        "source",
        "access"
      ])

    assert is_binary(line)

    # Not installed: no collections, and no note.
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    refute has_element?(lv, "#collections-access")

    # While the page waits for the first listing, and once listed.
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-waiting")
    assert access_text(lv) == line
    assert has_element?(lv, "#collections-foot > #collections-access")
    assert foot_notes(lv) == ["collections-access"]

    post(key, connection, ["acme/api", {"acme/shop", :target}], 1, true)
    assert access_text(lv) == line
    assert foot_notes(lv) == ["collections-access", "collections-targets"]
  end

  test "no source role, or no access line: no note", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api", {"acme/shop", :target}], 1, true)

    # An adapter with no line kept: none.
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-table")
    refute has_element?(lv, "#collections-access")
    assert foot_notes(lv) == ["collections-targets"]

    # A line, then a start whose description has no source role: none again.
    adapter = describe_source(adapter, "example-tracker.json")
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-access")

    describe_source(adapter, "acme-tracker.json")
    send(lv.pid, {:connection_changed, %{adapter_id: adapter.id}})
    assert has_element?(lv, "#collections-table")
    refute has_element?(lv, "#collections-access")
  end

  test "a start with a new access line changes the open page's note, with no reload",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api"], 1, true)
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    start = fn line ->
      description =
        Apiary.DescriptionFixtures.contract_description()
        |> put_in(["roles", "source", "access"], line)
        |> Apiary.DescriptionFixtures.read_description()

      {:ok, _adapter} =
        Apiary.Adapters.declare(Scope.for_access_key(key), %{
          time: DateTime.utc_now(:second),
          connect_url: "https://tracker.example.com/connect",
          default_interval: 3600,
          minimum_interval: 900,
          sends_changes: true,
          description: description
        })
    end

    start.("Ask an owner to change the projects.")
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert access_text(lv) == "Ask an owner to change the projects."

    start.("Open Settings, then Adapters, to change the projects.")
    assert access_text(lv) == "Open Settings, then Adapters, to change the projects."
  end

  test "the access line shows in a bdi, its invisible and control characters cleaned",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api"], 1, true)

    :ok =
      set_access(
        adapter,
        "\u202EChange\u200B which repositories it reaches\u0007 in its settings.\u202C"
      )

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-access > bdi")

    # Listed, with no target and nothing ended: the block shows for the access note alone.
    assert has_element?(lv, "#collections-foot > #collections-access")
    assert foot_notes(lv) == ["collections-access"]

    assert access_text(lv) ==
             "Change which repositories it reaches\uFFFD in its settings."
  end

  test "an access line with nothing left once cleaned, or only whitespace, shows no note", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api"], 1, true)

    for text <- ["\u200B", "\u2066\u202E\u200B\u2069", "", " ", "\u00A0", "\u2002\u200B\u3000"] do
      :ok = set_access(adapter, text)
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      assert has_element?(lv, "#collections-table")
      refute has_element?(lv, "#collections-access"), inspect(text)
    end
  end

  test "the access note, the ended line, then the targets note, when all three show", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    describe_source(adapter, "example-tracker.json")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api", {"acme/shop", :target}, "acme/web"], 1, true)

    post(
      key,
      connection,
      ["acme/api", {"acme/shop", :target}],
      1,
      true,
      ~U[2026-10-02 09:00:00Z],
      "second"
    )

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert foot_notes(lv) == ["collections-access", "collections-ended", "collections-targets"]
  end

  test "the page fills in live: waiting, still sending with how many so far, then complete", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-waiting")

    post(key, connection, titles(1..60), 1, false)

    assert words(lv, "#collections-filling") ==
             "#{adapter.name} is still sending its collections…"

    assert has_element?(lv, ~s{#collections-filling[role="status"]})
    refute has_element?(lv, "#collections-waiting")
    assert words(lv, "#collections-heading") == "Collections"
    assert words(lv, "#collections-count") == "60 so far"
    assert length(rows(lv)) == 51
    assert words(lv, "#collections-pager-footer") == "1–50 of 60"

    post(key, connection, titles(61..70), 2, true)

    refute has_element?(lv, "#collections-filling")
    assert words(lv, "#collections-heading") == "Collections 70"
    assert words(lv, "#collections-count") == "70 collections"
    assert words(lv, "#collections-pager-footer") == "1–50 of 70"
  end

  test "past a page, the pager walks the pages", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..120), 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-pager-footer") == "1–50 of 120"
    assert has_element?(lv, "#collections-pager-previous[disabled]")
    assert Enum.at(rows(lv), 1) =~ "acme/repo-001"

    lv |> element("#collections-pager-next") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?page=2")
    assert words(lv, "#collections-pager-footer") == "51–100 of 120"
    assert Enum.at(rows(lv), 1) =~ "acme/repo-051"

    lv |> element("#collections-pager-next") |> render_click()
    assert words(lv, "#collections-pager-footer") == "101–120 of 120"
    assert has_element?(lv, "#collections-pager-next[disabled]")
    assert length(rows(lv)) == 21

    lv |> element("#collections-pager-previous") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?page=2")

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?page=9")
    assert words(lv, "#collections-pager-footer") == "101–120 of 120"
  end

  test "a collection the latest complete listing left out is not shown", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api", "acme/shop"], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert length(rows(lv)) == 3

    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(key), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections: [
          %{
            ref: "acme/api",
            url: "https://forge.example.com/acme/api",
            title: "acme/api",
            target: nil
          }
        ],
        listing: %{id: "second", part: 1, started_at: ~U[2026-10-02 09:00:00Z], complete: true}
      })

    assert rows(lv) == [
             "Collection Workspace Backlog Open tickets Added",
             "acme/api Backlog #{scope.workspace.name} — Today"
           ]

    assert words(lv, "#collections-count") == "1 collection"
  end

  test "collections the integration no longer reaches: a line under the table says how many",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api", "acme/shop", "acme/web"], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    refute has_element?(lv, "#collections-ended")

    relist(key, connection, ["acme/api", "acme/shop"], "second", ~U[2026-10-02 09:00:00Z])

    assert words(lv, "#collections-ended") ==
             "1 collection that #{adapter.name} no longer reaches isn't shown."

    relist(key, connection, ["acme/api"], "third", ~U[2026-10-03 09:00:00Z])

    assert words(lv, "#collections-ended") ==
             "2 collections that #{adapter.name} no longer reaches aren't shown."

    assert Enum.drop(rows(lv), 1) == ["acme/api Backlog #{scope.workspace.name} — Today"]
    assert words(lv, "#collections-count") == "1 collection"

    # Under the table.
    [_before, after_table] = String.split(render(lv), ~s{id="collections-table"}, parts: 2)
    assert after_table =~ ~s{id="collections-ended"}
  end

  test "with several workspaces, the unassigned collections come first, on every page", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, titles(1..60))

    {:ok, _changed} =
      Collections.assign_collections(
        scope,
        connection,
        collection_ids(connection, titles(1..10)),
        platform
      )

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert Enum.at(rows(lv), 1) == "acme/repo-011 Unassigned — Today"
    assert List.last(rows(lv)) == "acme/repo-060 Unassigned — Today"

    lv |> element("#collections-pager-next") |> render_click()
    assert words(lv, "#collections-pager-footer") == "51–60 of 60"

    assert Enum.drop(rows(lv), 1) ==
             for(title <- titles(1..10), do: "#{title} Backlog Platform — Today")
  end

  test "several workspaces: the lead, the warning, the views, the filter and the checkboxes", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    several(scope, adapter, key, ["acme/api", "acme/shop", "acme/web"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-lead") ==
             "These collections are each assigned to one workspace, and their tickets come into that workspace's Backlog while their Backlog switches are on."

    assert words(lv, "#collections-unassigned") ==
             "3 collections are unassigned. Their tickets reach no backlog until you assign each to a workspace. Show them"

    assert words(lv, "#collections-view-all") == "All 3"
    assert words(lv, "#collections-view-unassigned") == "Unassigned 3"
    assert has_element?(lv, ~s{#collections-view-all[aria-current="page"]})
    assert has_element?(lv, ~s{#collections-search input[placeholder="Find a collection"]})
    assert has_element?(lv, "#collections-bar.q-int-assignbar > #collections-search.q-find")
    refute has_element?(lv, "#collections-search.q-find-query")
    assert words(lv, "#collections-workspace-button") == "Workspace"
    assert has_element?(lv, ~s{#collections-workspace ul[role="menu"][aria-label="Workspace"]})

    assert has_element?(
             lv,
             ~s{#collections-assign-button[disabled][title="Select collections to assign them"]},
             "Assign to workspace"
           )

    assert words(lv, "#collections-assign-hint") == "Select collections to assign them"
    refute has_element?(lv, "#collections-count")
    refute has_element?(lv, "#collections-selection")

    assert has_element?(
             lv,
             ~s{#collections-table-every[aria-label="Select every collection shown"]}
           )

    assert rows(lv) == [
             "Collection Workspace Backlog Open tickets Added",
             "acme/api Unassigned — Today",
             "acme/shop Unassigned — Today",
             "acme/web Unassigned — Today"
           ]
  end

  test "select, then assign from the menu: a flash says what went where", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop", "acme/web"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    pick(lv, "acme/shop")
    assert words(lv, "#collections-selected") == "1 selected"
    assert words(lv, "#collections-count") == "3 of 3 shown"

    assert has_element?(
             lv,
             ~s{#collection-#{public_id(connection, "acme/shop")}[aria-selected="true"]}
           )

    refute has_element?(lv, "#collections-views")
    refute has_element?(lv, "#collections-show-unassigned")

    assert has_element?(
             lv,
             ~s{#collections-assign ul[role="menu"][aria-label="Assign 1 collection to"]}
           )

    assert words(lv, "#collections-assign-#{platform.id}") == "Platform 0 collections"

    assert words(lv, "#collections-assign .q-int-assign-foot") ==
             "Its tickets go with it. Work items already taken in stay where they are."

    pick(lv, "acme/web")
    assert words(lv, "#collections-selected") == "2 selected"

    assert words(lv, "#collections-assign .q-int-assign-foot") ==
             "Their tickets go with them. Work items already taken in stay where they are."

    lv |> element("#collections-assign-#{platform.id}") |> render_click()

    assert words(lv, "#flash-info") =~ "Assigned acme/shop and acme/web to Platform."
    refute has_element?(lv, "#collections-selection")

    assert words(lv, "#collections-unassigned") =~
             "1 collection is unassigned. Its tickets reach no backlog until you assign it to a workspace."

    assert rows(lv) == [
             "Collection Workspace Backlog Open tickets Added",
             "acme/api Unassigned — Today",
             "acme/shop Backlog Platform — Today",
             "acme/web Backlog Platform — Today"
           ]

    pick(lv, "acme/api")
    pick(lv, "acme/shop")
    pick(lv, "acme/web")

    lv |> element("#collections-assign-#{scope.workspace.id}") |> render_click()

    assert words(lv, "#flash-info") =~
             "Assigned acme/api, acme/shop and acme/web to #{scope.workspace.name}."

    refute has_element?(lv, "#collections-unassigned")
    assert words(lv, "#collections-view-unassigned") == "Unassigned 0"
  end

  test "the assign menu lists only the workspaces whose domain the adapter serves", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {_connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop"])

    Repo.update_all(from(w in Apiary.Organisations.Workspace, where: w.id == ^platform.id),
      set: [domain: "general"]
    )

    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.id),
      set: [domains: ["software"]]
    )

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    pick(lv, "acme/api")
    assert has_element?(lv, "#collections-assign-#{scope.workspace.id}")
    refute has_element?(lv, "#collections-assign-#{platform.id}")

    # A start that narrows the domains after the page read them: nothing is assigned.
    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.id),
      set: [domains: ["general"]]
    )

    lv |> element("#collections-assign-#{scope.workspace.id}") |> render_click()

    assert words(lv, "#flash-error") =~
             "Nothing was assigned: the page was out of date."
  end

  test "the names the toast says it assigned: as a page shows a text the integration sent", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    # A bidirectional override and a zero-width space in a name the integration sent.
    {_connection, platform} = several(scope, adapter, key, ["acme/\u202Eapi\u200B"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    pick(lv, "acme/api")
    lv |> element("#collections-assign-#{platform.id}") |> render_click()

    assert words(lv, "#flash-info") =~ "Assigned acme/api to Platform."
    refute lv |> element("#flash-info") |> render() =~ "\u202E"
  end

  test "with more than eight workspaces, a field in the assign menu finds one", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {_connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    pick(lv, "acme/api")
    refute has_element?(lv, "#collections-assign-find")

    for n <- 1..7, do: workspace_fixture(scope.organisation, "Team #{n}")
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    pick(lv, "acme/api")

    assert has_element?(
             lv,
             ~s{#collections-assign-find-input[placeholder="Find a workspace"][aria-label="Find a workspace"]}
           )

    assert lv |> element("#collections-assign ul") |> render() =~ "Team 7"

    lv |> form("#collections-assign-find", %{q: " plat "}) |> render_change()
    assert has_element?(lv, "#collections-assign-#{platform.id}")
    refute lv |> element("#collections-assign ul") |> render() =~ "Team 7"
    refute has_element?(lv, "#collections-assign-none")

    lv |> form("#collections-assign-find", %{q: "billing"}) |> render_change()
    assert words(lv, "#collections-assign-none") == "No workspace matches."
    refute has_element?(lv, "#collections-assign-#{platform.id}")

    lv |> form("#collections-assign-find", %{q: "PLATFORM"}) |> render_change()
    lv |> element("#collections-assign-#{platform.id}") |> render_click()
    assert words(lv, "#flash-info") =~ "Assigned acme/api to Platform."

    pick(lv, "acme/shop")
    assert lv |> element("#collections-assign ul") |> render() =~ "Team 7"
  end

  test "every row shown at once, and more than three in the flash by number", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {_connection, platform} = several(scope, adapter, key, titles(1..5))
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    lv |> element("#collections-table-every") |> render_click()
    assert words(lv, "#collections-selected") == "5 selected"
    assert has_element?(lv, "#collections-table-every[checked]")

    for title <- titles(1..5) do
      checked = ~s{#collections-table input[aria-label="Select #{title}"][checked]}
      assert has_element?(lv, checked)
    end

    lv |> element("#collections-table-every") |> render_click()
    refute has_element?(lv, "#collections-selection")
    refute has_element?(lv, "#collections-table tbody input[checked]")

    lv |> element("#collections-table-every") |> render_click()
    lv |> element("#collections-clear") |> render_click()
    refute has_element?(lv, "#collections-selection")

    lv |> element("#collections-table-every") |> render_click()
    lv |> element("#collections-assign-#{platform.id}") |> render_click()
    assert words(lv, "#flash-info") =~ "Assigned 5 collections to Platform."
  end

  test "an assign refused for a person no longer an owner or an admin says who assigns", %{
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop"])
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), page(scope, adapter))

    pick(lv, "acme/shop")
    {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)
    lv |> element("#collections-assign-#{platform.id}") |> render_click()

    assert words(lv, "#flash-error") =~
             "Only owners and admins of #{scope.organisation.name} assign collections."

    refute has_element?(lv, "#collections-selection")
    refute has_element?(lv, "#collections-table input")
    refute has_element?(lv, "#collections-assign-button")
    assert Collections.counts(scope, connection).unassigned == 2
  end

  test "an assign refused for an installation that ended says nothing was assigned", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    pick(lv, "acme/shop")

    :ok =
      set(connection,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )

    lv |> element("#collections-assign-#{platform.id}") |> render_click()

    assert words(lv, "#flash-error") =~
             "Nothing was assigned: the installation of #{adapter.name} ended."

    assert Collections.counts(scope, connection).unassigned == 2
  end

  test "an assign refused on a page out of date says so, and shows them as they are", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    out_of_date = "Nothing was assigned: the page was out of date."

    # A collection selected that ended since.
    pick(lv, "acme/shop")

    {1, _} =
      Repo.update_all(
        from(c in Apiary.Adapters.Collection,
          where: c.id == ^Repo.get_by!(Apiary.Adapters.Collection, title: "acme/shop").id
        ),
        set: [ended_at: DateTime.utc_now(), ended_reason: :not_listed]
      )

    lv |> element("#collections-assign-#{platform.id}") |> render_click()

    assert words(lv, "#flash-error p:first-child") == out_of_date
    assert words(lv, "#flash-error p.text-muted") == "It now shows the collections as they are."

    assert Enum.drop(rows(lv), 1) == ["acme/api Unassigned — Today"]
    lv |> element("#flash-error button") |> render_click()

    # A workspace the page no longer has.
    pick(lv, "acme/api")
    render_click(lv, "assign", %{"workspace" => Ecto.UUID.generate()})
    assert words(lv, "#flash-error") =~ out_of_date
    lv |> element("#flash-error button") |> render_click()

    # More than one assign takes.
    pick(lv, "acme/api")

    :sys.replace_state(lv.pid, fn state ->
      more = Map.new(1..10_001, fn n -> {Ecto.UUID.generate(), "acme/repo-#{n}"} end)
      update_in(state.socket.assigns.selected, &Map.merge(&1, more))
    end)

    lv |> element("#collections-assign-#{platform.id}") |> render_click()
    assert words(lv, "#flash-error") =~ out_of_date
    assert Collections.counts(scope, connection).unassigned == 1
  end

  test "an assign pressed after the connection ended leaves the page up, and assigns nothing",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    pick(lv, "acme/api")
    pick(lv, "acme/shop")

    :ok =
      set(connection, state: :ended, ended_at: DateTime.utc_now(), ended_reason: :replaced)

    send(lv.pid, {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}})
    refute has_element?(lv, "#collections-table")
    refute has_element?(lv, "#collections-selection")

    render_click(lv, "assign", %{"workspace" => platform.id})
    assert Process.alive?(lv.pid)
    refute has_element?(lv, "#flash-info")
    assert Collections.counts(scope, connection).by_workspace == %{}
  end

  test "an assign forced by a member, or naming another organisation's workspace, assigns nothing",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop"])
    {:ok, lv, _html} = live(member_conn(scope), page(scope, adapter))

    render_click(lv, "select", %{"collection" => public_id(connection, "acme/api")})
    render_click(lv, "select_all", %{})
    render_click(lv, "assign", %{"workspace" => platform.id})
    refute has_element?(lv, "#flash-info")
    assert Collections.counts(scope, connection).unassigned == 2

    %{workspace: elsewhere} = sign_up_fixture()
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    pick(lv, "acme/api")
    render_click(lv, "assign", %{"workspace" => elsewhere.id})
    refute has_element?(lv, "#flash-info")
    assert words(lv, "#flash-error") =~ "Nothing was assigned: the page was out of date."
    assert Collections.counts(scope, connection).unassigned == 2
  end

  test "a page past the last one with rows shows the last that has some, or none", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, titles(1..60))

    # The rows before the page asked for fill whole pages, and it holds none.
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?view=unassigned&page=2")
    assert words(lv, "#collections-pager-footer") == "51–60 of 60"
    lv |> element("#collections-table-every") |> render_click()
    lv |> element("#collections-assign-#{platform.id}") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?view=unassigned")
    refute has_element?(lv, "#collections-pager")
    assert length(rows(lv)) == 51
    assert Enum.at(rows(lv), 1) == "acme/repo-001 Unassigned — Today"

    # No rows at all: no pager.
    ids =
      for title <- titles(1..60),
          do:
            Repo.get_by!(Apiary.Adapters.Collection, connection_id: connection.id, title: title).id

    {:ok, _changed} = Collections.assign_collections(scope, connection, ids, platform)
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?view=unassigned&page=2")
    refute has_element?(lv, "#collections-pager")
    assert length(rows(lv)) == 1
  end

  test "a page past the last one, every row on the pages before it, shows the last", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..100), 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?page=3")
    assert words(lv, "#collections-pager-footer") == "51–100 of 100"
    assert length(rows(lv)) == 51
    assert has_element?(lv, "#collections-pager-next[disabled]")
  end

  test "a page past the last one with rows: the address names the page shown", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, titles(1..60))
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    render_patch(lv, page(scope, adapter) <> "?view=unassigned&page=5")
    assert_patch(lv, page(scope, adapter) <> "?view=unassigned&page=2")
    assert words(lv, "#collections-pager-footer") == "51–60 of 60"

    # The page's rows are assigned elsewhere while it is open: the page before it, and its
    # address.
    {:ok, _changed} =
      Collections.assign_collections(
        scope,
        connection,
        collection_ids(connection, titles(51..60)),
        platform
      )

    assert_patch(lv, page(scope, adapter) <> "?view=unassigned")
    assert length(rows(lv)) == 51
    refute has_element?(lv, "#collections-pager")

    render_patch(lv, page(scope, adapter) <> "?q=billing&page=3")
    assert_patch(lv, page(scope, adapter) <> "?q=billing")
    assert words(lv, "#collections-table-none") == "No collections match “billing”."
  end

  test "assigning the last row of a page of the unassigned view: page 1, every row reachable",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {_connection, platform} = several(scope, adapter, key, titles(1..101))
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?view=unassigned&page=3")
    assert words(lv, "#collections-pager-footer") == "101–101 of 101"

    pick(lv, "acme/repo-101")
    lv |> element("#collections-assign-#{platform.id}") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?view=unassigned")
    assert words(lv, "#flash-info") =~ "Assigned acme/repo-101 to Platform."
    assert words(lv, "#collections-pager-footer") == "1–50 of 100"
    shown = Enum.drop(rows(lv), 1)

    lv |> element("#collections-pager-next") |> render_click()
    assert words(lv, "#collections-pager-footer") == "51–100 of 100"
    assert has_element?(lv, "#collections-pager-next[disabled]")
    shown = shown ++ Enum.drop(rows(lv), 1)

    assert shown == for(title <- titles(1..100), do: "#{title} Unassigned — Today")
  end

  test "a refused assign from a page past the first stays on that page", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    several(scope, adapter, key, titles(1..60))
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?page=2")
    assert words(lv, "#collections-pager-footer") == "51–60 of 60"

    pick(lv, "acme/repo-055")
    render_click(lv, "assign", %{"workspace" => Ecto.UUID.generate()})
    assert words(lv, "#flash-error") =~ "Nothing was assigned: the page was out of date."
    refute_patched(lv)
    assert words(lv, "#collections-pager-footer") == "51–60 of 60"
  end

  test "after an assign, the first page of the same view, search and workspace", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, titles(1..60) ++ ["acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?q=repo&page=2")
    assert words(lv, "#collections-pager-footer") == "51–60 of 60"

    lv |> element("#collections-table-every") |> render_click()
    lv |> element("#collections-assign-#{platform.id}") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?q=repo")
    assert words(lv, "#flash-info") == "Assigned 10 collections to Platform."
    assert words(lv, "#collections-pager-footer") == "1–50 of 60"
    assert Enum.at(rows(lv), 1) == "acme/repo-001 Unassigned — Today"

    # In one workspace's collections, past its first page.
    {:ok, _changed} =
      Collections.assign_collections(
        scope,
        connection,
        collection_ids(connection, titles(1..50)),
        platform
      )

    filter = "?workspace_id=#{platform.id}"
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> filter <> "&page=2")
    assert words(lv, "#collections-pager-footer") == "51–60 of 60"
    pick(lv, "acme/repo-051")
    lv |> element("#collections-assign-#{scope.workspace.id}") |> render_click()
    assert_patch(lv, page(scope, adapter) <> filter)
    assert words(lv, "#flash-info") == "Assigned acme/repo-051 to #{scope.workspace.name}."
    assert words(lv, "#collections-pager-footer") == "1–50 of 59"
  end

  test "a search counts what it finds, its ended collections left out, in each view", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, titles(1..60) ++ ["acme/shop"])
    relist(key, connection, titles(1..59) ++ ["acme/shop"], "second", ~U[2026-10-02 09:00:00Z])

    {:ok, _changed} =
      Collections.assign_collections(
        scope,
        connection,
        collection_ids(connection, titles(1..5)),
        platform
      )

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?q=repo")
    assert words(lv, "#collections-pager-footer") == "1–50 of 59"
    lv |> element("#collections-pager-next") |> render_click()
    assert words(lv, "#collections-pager-footer") == "51–59 of 59"

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?view=unassigned&q=repo")
    assert words(lv, "#collections-pager-footer") == "1–50 of 54"

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?q=repo&workspace_id=#{platform.id}")
    refute has_element?(lv, "#collections-pager")
    assert length(rows(lv)) == 6
  end

  test "a search that finds only ended collections says it finds none, on any page", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..100), 1, true)
    relist(key, connection, titles(1..50), "second", ~U[2026-10-02 09:00:00Z])

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?q=repo-07")
    assert words(lv, "#collections-table-none") == "No collections match “repo-07”."
    assert length(rows(lv)) == 2

    render_patch(lv, page(scope, adapter) <> "?q=repo-07&page=2")
    assert_patch(lv, page(scope, adapter) <> "?q=repo-07")
    assert words(lv, "#collections-table-none") == "No collections match “repo-07”."
    assert length(rows(lv)) == 2
  end

  test "the foot notes' block shows only while one of its notes does", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-waiting")
    refute has_element?(lv, "#collections-foot")

    # Listed, with no target and nothing ended.
    post(key, connection, ["acme/api", "acme/shop"], 1, true)
    assert length(rows(lv)) == 3
    refute has_element?(lv, "#collections-foot")

    relist(key, connection, ["acme/api"], "second", ~U[2026-10-02 09:00:00Z])
    assert has_element?(lv, "#collections-foot #collections-ended")
    refute has_element?(lv, "#collections-targets")
  end

  test "past the live rows, a page steps back to the last with some, and says no search line",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..100), 1, true)
    relist(key, connection, titles(1..50), "second", ~U[2026-10-02 09:00:00Z])

    # Past the first page, only ended rows are left.
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    refute has_element?(lv, "#collections-pager")
    render_patch(lv, page(scope, adapter) <> "?page=2")
    assert_patch(lv, page(scope, adapter))
    assert length(rows(lv)) == 51

    render_patch(lv, page(scope, adapter) <> "?q=repo&page=2")
    assert_patch(lv, page(scope, adapter) <> "?q=repo")
    refute has_element?(lv, "#collections-table-none")
    assert length(rows(lv)) == 51
  end

  test "a run of ended collections between live ones leaves no gap in the pages", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..150), 1, true)
    kept = titles(1..50) ++ titles(101..150)
    relist(key, connection, kept, "second", ~U[2026-10-02 09:00:00Z])

    for query <- ["", "?q=repo"] do
      join = if query == "", do: "?", else: "&"
      {:ok, lv, _html} = live(conn, page(scope, adapter) <> query)
      assert words(lv, "#collections-pager-footer") == "1–50 of 100"
      assert Enum.drop(rows(lv), 1) |> Enum.map(&hd(String.split(&1))) == titles(1..50)

      lv |> element("#collections-pager-next") |> render_click()
      assert_patch(lv, page(scope, adapter) <> query <> join <> "page=2")
      assert words(lv, "#collections-pager-footer") == "51–100 of 100"
      assert Enum.drop(rows(lv), 1) |> Enum.map(&hd(String.split(&1))) == titles(101..150)
      assert has_element?(lv, "#collections-pager-next[disabled]")

      render_patch(lv, page(scope, adapter) <> query <> join <> "page=3")
      assert_patch(lv, page(scope, adapter) <> query <> join <> "page=2")
      assert words(lv, "#collections-pager-footer") == "51–100 of 100"
    end
  end

  test "more than a page of ended collections sorting before the live ones: page 1 shows the first 50 live",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..130), 1, true)
    # 60 ended, acme/repo-001 to -060, then 70 live.
    relist(key, connection, titles(61..130), "second", ~U[2026-10-02 09:00:00Z])

    for query <- ["", "?q=repo"] do
      join = if query == "", do: "?", else: "&"
      {:ok, lv, _html} = live(conn, page(scope, adapter) <> query)
      assert words(lv, "#collections-pager-footer") == "1–50 of 70"
      assert Enum.drop(rows(lv), 1) |> Enum.map(&hd(String.split(&1))) == titles(61..110)

      lv |> element("#collections-pager-next") |> render_click()
      assert_patch(lv, page(scope, adapter) <> query <> join <> "page=2")
      assert words(lv, "#collections-pager-footer") == "51–70 of 70"
      assert Enum.drop(rows(lv), 1) |> Enum.map(&hd(String.split(&1))) == titles(111..130)
      assert has_element?(lv, "#collections-pager-next[disabled]")

      render_patch(lv, page(scope, adapter) <> query <> join <> "page=3")
      assert_patch(lv, page(scope, adapter) <> query <> join <> "page=2")
      assert words(lv, "#collections-pager-footer") == "51–70 of 70"
      refute render(lv) =~ "71–70"
    end

    # A search that finds only ended collections: no rows, no pager.
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?q=repo-00")
    assert words(lv, "#collections-table-none") == "No collections match “repo-00”."
    refute has_element?(lv, "#collections-pager")
  end

  test "exactly 50 live collections after ended ones: no next page, and page 2 shows page 1",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..110), 1, true)
    # 60 ended, acme/repo-001 to -060, then 50 live.
    relist(key, connection, titles(61..110), "second", ~U[2026-10-02 09:00:00Z])

    for query <- ["", "?q=repo"] do
      join = if query == "", do: "?", else: "&"
      {:ok, lv, _html} = live(conn, page(scope, adapter) <> query)
      refute has_element?(lv, "#collections-pager")
      assert Enum.drop(rows(lv), 1) |> Enum.map(&hd(String.split(&1))) == titles(61..110)

      render_patch(lv, page(scope, adapter) <> query <> join <> "page=2")
      assert_patch(lv, page(scope, adapter) <> query)
      refute has_element?(lv, "#collections-pager")
      assert length(rows(lv)) == 51
      refute render(lv) =~ "51–50"
    end

    # 51 live: the second page has the 51st.
    relist(key, connection, titles(60..110), "third", ~U[2026-10-03 09:00:00Z])
    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?page=2")
    assert words(lv, "#collections-pager-footer") == "51–51 of 51"
    assert Enum.drop(rows(lv), 1) |> Enum.map(&hd(String.split(&1))) == titles(110..110)
  end

  test "Show them opens the unassigned view; the filter keeps one workspace's", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key, ["acme/api", "acme/shop", "acme/web"])

    shop =
      Repo.get_by!(Apiary.Adapters.Collection, connection_id: connection.id, title: "acme/shop")

    {:ok, _changed} = Collections.assign_collections(scope, connection, [shop.id], platform)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    lv |> element("#collections-show-unassigned") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?view=unassigned")
    assert has_element?(lv, ~s{#collections-view-unassigned[aria-current="page"]})
    refute has_element?(lv, "#collections-show-unassigned")

    assert Enum.drop(rows(lv), 1) == [
             "acme/api Unassigned — Today",
             "acme/web Unassigned — Today"
           ]

    lv |> element("#collections-workspace-1") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?workspace_id=#{platform.id}")
    assert Enum.drop(rows(lv), 1) == ["acme/shop Backlog Platform — Today"]
    assert has_element?(lv, ~s{#collections-workspace-1[aria-checked="true"]})
    assert words(lv, "#collections-workspace-button") == "Workspace 1"

    {:ok, visited, _html} = live(conn, page(scope, adapter) <> "?workspace_id=#{platform.id}")
    assert Enum.drop(rows(visited), 1) == ["acme/shop Backlog Platform — Today"]

    lv |> element("#collections-workspace-1") |> render_click()
    assert_patch(lv, page(scope, adapter))
    assert length(rows(lv)) == 4
  end

  test "a search finds collections by name, a page at a time", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, titles(1..120) ++ ["acme/shop"], 1, true)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    lv |> form("#collections-search", %{q: "shop"}) |> render_change()
    assert_patch(lv, page(scope, adapter) <> "?q=shop")
    assert Enum.drop(rows(lv), 1) == ["acme/shop Backlog #{scope.workspace.name} — Today"]
    refute has_element?(lv, "#collections-pager")

    lv |> form("#collections-search", %{q: "repo"}) |> render_change()
    assert words(lv, "#collections-pager-footer") == "1–50 of 120"
    lv |> element("#collections-pager-next") |> render_click()
    lv |> element("#collections-pager-next") |> render_click()
    assert_patch(lv, page(scope, adapter) <> "?q=repo&page=3")
    assert words(lv, "#collections-pager-footer") == "101–120 of 120"

    lv |> form("#collections-search", %{q: " "}) |> render_change()
    assert_patch(lv, page(scope, adapter))
  end

  test "a search that finds nothing says so in place of the rows", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    several(scope, adapter, key, ["acme/api", "acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    refute has_element?(lv, "#collections-table-none")

    lv |> form("#collections-search", %{q: " billing "}) |> render_change()
    assert words(lv, "#collections-table-none") == "No collections match “billing”."
    assert length(rows(lv)) == 2
    assert has_element?(lv, "#collections-table-every[disabled]")
    refute has_element?(lv, "#collections-pager")

    lv |> form("#collections-search", %{q: "shop"}) |> render_change()
    refute has_element?(lv, "#collections-table-none")
  end

  test "a member reads the warning in its words, with no checkboxes and nothing to assign", %{
    scope: scope,
    adapter: adapter,
    key: key
  } do
    several(scope, adapter, key, ["acme/api"])
    {:ok, lv, _html} = live(member_conn(scope), page(scope, adapter))

    assert words(lv, "#collections-unassigned") ==
             "1 collection is unassigned. Its tickets reach no backlog until an owner or an admin assigns it to a workspace."

    assert has_element?(lv, "#collections-views")
    assert has_element?(lv, "#collections-bar")
    refute has_element?(lv, "#collections-bar.q-int-assignbar")
    refute has_element?(lv, "#collections-table-every")
    refute has_element?(lv, "#collections-table input")
    refute has_element?(lv, "#collections-assign-button")
    render_click(lv, "select_all", %{})
    refute has_element?(lv, "#collections-selection")
  end

  test "an adapter with no items: the warning's first sentence only, and no foot in the menu", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    adapter = describe_source(adapter, "example-projects.json")
    several(scope, adapter, key, ["Support", "Sales"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-lead") == "These projects are each assigned to one workspace."
    assert words(lv, "#collections-unassigned") == "2 projects are unassigned. Show them"
    assert hd(rows(lv)) == "Project Workspace Added"

    pick(lv, "Sales")
    assert words(lv, "#collections-assign ul") =~ "Assign 1 project to"
    refute has_element?(lv, "#collections-assign .q-int-assign-foot")
  end

  test "while a listing is still arriving, nothing can be selected or assigned", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    :ok = Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    platform = workspace_fixture(scope.organisation, "Platform")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    post(key, connection, ["acme/api", "acme/shop"], 1, false)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "#collections-filling")
    assert words(lv, "#collections-count") == "2 so far"
    assert has_element?(lv, "#collections-search")
    refute has_element?(lv, "#collections-views")
    refute has_element?(lv, "#collections-unassigned")
    refute has_element?(lv, "#collections-workspace")
    refute has_element?(lv, "#collections-assign-button")
    refute has_element?(lv, "#collections-table input")

    assert Enum.drop(rows(lv), 1) == [
             "acme/api Unassigned — Today",
             "acme/shop Unassigned — Today"
           ]

    render_click(lv, "select", %{"collection" => public_id(connection, "acme/api")})
    render_click(lv, "assign", %{"workspace" => platform.id})
    refute has_element?(lv, "#collections-selection")
    assert Collections.counts(scope, connection).unassigned == 2

    post(key, connection, ["acme/web"], 2, true)
    assert has_element?(lv, "#collections-views")
    assert words(lv, "#collections-unassigned") =~ "3 collections are unassigned."
  end

  test "a member reads where it stands, with no install block and no Install", %{
    scope: scope,
    adapter: adapter
  } do
    conn = member_conn(scope)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    refute has_element?(lv, "#integration-install")

    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-waiting")
    send(lv.pid, :late)
    _ = render(lv)
    refute has_element?(lv, "#collections-late")
  end

  test "a member reads a pending install, or an expired one, as not installed, with no Install",
       %{conn: conn, scope: scope, adapter: adapter} do
    member = member_conn(scope)
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)

    {:ok, lv, _html} = live(member, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    refute render(lv) =~ ~r/press Install/i
    refute has_element?(lv, "#integration-install")

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. #{letter(scope.user, true)} started an install today at #{time(connection.updated_at)} that isn't finished: finish it on #{adapter.name}, or press Install to start again."

    set(connection, pass_expires_at: DateTime.add(DateTime.utc_now(:second), -1))

    {:ok, lv, _html} = live(member, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    refute render(lv) =~ ~r/press Install/i
    refute has_element?(lv, "#integration-install")
  end

  test "an admin has the install block too", %{scope: scope, adapter: adapter} do
    {:ok, lv, _html} = live(member_conn(scope, :admin), page(scope, adapter))
    assert has_element?(lv, "#integration-install")
  end

  test "an adapter deleted meanwhile leaves for the list", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    {:ok, _deleted} = Apiary.Adapters.delete_adapter(instance_admin_scope(), adapter)

    send(
      lv.pid,
      {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}}
    )

    list = ~p"/#{scope.organisation}/settings/integrations"
    assert_redirect(lv, list)
  end

  test "is not found for an adapter that does not exist, or where the feature is hidden",
       %{conn: conn, scope: scope, adapter: adapter} do
    assert_raise ApiaryWeb.NotFound, fn ->
      live(conn, ~p"/#{scope.organisation}/settings/integrations/na_0000000000000000")
    end

    :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
    :ok = EditionStubs.HidesNamed.put([:factory])
    assert_raise ApiaryWeb.Features.NotFound, fn -> live(conn, page(scope, adapter)) end
  end

  describe "who installed it" do
    # The status line of a connection installed today by `user`, once `change` ran.
    defp installed_by(conn, scope, adapter, user, change) do
      {connection, _nonce} = connection_fixture(scope, adapter, :connected)
      set(connection, created_by_id: user.id)
      change.()
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      words(lv, "#integration-status")
    end

    test "a person removed from the organisation is named by their account",
         %{conn: conn, scope: scope, adapter: adapter} do
      member = member_fixture(scope, :member)

      line =
        installed_by(conn, scope, adapter, member.user, fn -> Repo.delete!(member.membership) end)

      assert line == "Installed by #{letter(member.user)} today."
    end

    test "a deleted account is a former member", %{conn: conn, scope: scope, adapter: adapter} do
      member = member_fixture(scope, :member)

      line =
        installed_by(conn, scope, adapter, member.user, fn ->
          {:ok, _deleted} = Apiary.Accounts.delete_user(member.user)
        end)

      assert line == "Installed by Former member today."
    end

    test "a person who is not a member of the organisation is named by their account",
         %{conn: conn, scope: scope, adapter: adapter} do
      user = Apiary.AccountsFixtures.user_fixture()
      line = installed_by(conn, scope, adapter, user, fn -> :ok end)
      assert line == "Installed by #{letter(user)} today."
    end
  end
end
