defmodule ApiaryWeb.ActivityLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace

  defp open(conn, scope, query \\ "") do
    {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/activity#{query}")
    render_async(view)
    view
  end

  defp entries(scope, filters \\ %{}) do
    {:ok, %{entries: entries}} = Audit.list_entries(scope, filters)
    entries
  end

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  # The ids of the rows, in the order the table shows them.
  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#activity tr[id]")
    |> LazyHTML.attribute("id")
  end

  describe "as an owner" do
    setup :register_and_log_in_user

    test "lists the organisation's changes, newest first", %{conn: conn, scope: scope} do
      {:ok, _workspace} = Organisations.update_workspace(scope, %{name: "Production"})
      %{access_key: key} = access_key_fixture(scope, %{label: "build-01"})

      view = open(conn, scope)
      [created, renamed | _older] = entries(scope)

      assert row_ids(view) |> Enum.take(2) == ["entry-#{created.id}", "entry-#{renamed.id}"]

      assert text(view, "#entry-#{created.id}-action") =~ "Created an access key"
      assert text(view, "#entry-#{created.id}-subject") =~ "build-01"
      assert text(view, "#entry-#{created.id}-change") =~ key.key_id
      assert text(view, "#entry-#{renamed.id}-action") =~ "Renamed the workspace"
      assert text(view, "#entry-#{renamed.id}-change") =~ "Main → Production"
      assert text(view, "#entry-#{renamed.id}-actor") =~ scope.user.email
      assert has_element?(view, "#entry-#{renamed.id}-time[datetime][title]")
      assert has_element?(view, "#nav-activity[aria-current='page']")
    end

    test "shows no other organisation's entries", %{conn: conn, scope: scope} do
      other = sign_up_fixture()
      {:ok, _workspace} = Organisations.update_workspace(other.scope, %{name: "Elsewhere"})
      [theirs | _] = entries(other.scope)

      view = open(conn, scope)
      refute has_element?(view, "#entry-#{theirs.id}")
      refute render(view) =~ "Elsewhere"
    end

    test "filters by action", %{conn: conn, scope: scope} do
      {:ok, _workspace} = Organisations.update_workspace(scope, %{name: "Production"})
      access_key_fixture(scope)
      [created] = entries(scope, %{action: "access_key.create"})
      [renamed] = entries(scope, %{action: "workspace.rename"})

      view = open(conn, scope)

      view
      |> form("#filter-action-form")
      |> render_change(%{"_filter" => "action", "action" => "access_key.create"})

      assert_patch(view, "/#{scope.organisation.slug}/activity?action=access_key.create")
      render_async(view)
      assert row_ids(view) == ["entry-#{created.id}"]
      refute has_element?(view, "#entry-#{renamed.id}")

      view = open(conn, scope, "?action=no.such")
      assert has_element?(view, "#entry-#{renamed.id}")
    end

    test "filters by workspace", %{conn: conn, scope: scope} do
      second =
        Repo.insert!(%Workspace{
          organisation_id: scope.organisation.id,
          name: "Second",
          slug: "second",
          domain: "software"
        })

      {:ok, in_second} =
        Audit.record(Repo, scope, :"workspace.rename", second, %{
          before: %{name: "Old"},
          after: %{name: "Second"}
        })

      {:ok, _workspace} = Organisations.update_workspace(scope, %{name: "Production"})
      [in_first] = entries(scope, %{action: "workspace.rename", workspace_id: scope.workspace.id})

      view = open(conn, scope, "?workspace_id=#{second.id}")
      assert row_ids(view) == ["entry-#{in_second.id}"]

      view
      |> form("#filter-workspace-form")
      |> render_change(%{"_filter" => "workspace_id", "workspace_id" => scope.workspace.id})

      assert_patch(
        view,
        "/#{scope.organisation.slug}/activity?workspace_id=#{scope.workspace.id}"
      )

      render_async(view)
      assert has_element?(view, "#entry-#{in_first.id}")
      refute has_element?(view, "#entry-#{in_second.id}")
    end

    test "pages fifty at a time", %{conn: conn, scope: scope} do
      for n <- 1..55 do
        {:ok, _entry} =
          Audit.record(Repo, scope, :"workspace.rename", scope.workspace, %{
            before: %{name: "Name #{n}"},
            after: %{name: "Name #{n + 1}"}
          })
      end

      view = open(conn, scope)
      assert length(row_ids(view)) == 50
      refute has_element?(view, "#activity-newer")

      view |> element("#activity-older") |> render_click()
      assert_patch(view, "/#{scope.organisation.slug}/activity?page=2")
      render_async(view)

      # The 55 renames and the sign-up.
      assert length(row_ids(view)) == 6
      assert has_element?(view, "#activity-newer")
      refute has_element?(view, "#activity-older")
    end

    test "a page past the last says so and leads back to the first", %{
      conn: conn,
      scope: scope
    } do
      for page <- ["7", "99999999999999999999"] do
        view = open(conn, scope, "?page=#{page}")
        assert has_element?(view, "#activity-past-end")
        refute has_element?(view, "#activity-empty")

        view |> element("#activity-first-page") |> render_click()
        assert_patch(view, "/#{scope.organisation.slug}/activity")
        render_async(view)
        assert length(row_ids(view)) == 1
      end
    end

    test "names an access key and the instance as actors", %{conn: conn, scope: scope} do
      %{access_key: key} = access_key_fixture(scope, %{label: "build-01"})

      {:ok, by_key} =
        Audit.record(Repo, Scope.for_access_key(key), :"workspace.rename", scope.workspace, %{})

      Repo.insert_all("audit_entries", [
        %{
          id: Ecto.UUID.bingenerate(),
          organisation_id: Ecto.UUID.dump!(scope.organisation.id),
          actor_kind: "instance",
          action: "organisation.rename",
          subject_kind: "organisation",
          subject_id: Ecto.UUID.dump!(scope.organisation.id),
          inserted_at: ~N[2020-01-01 00:00:00]
        }
      ])

      {:ok, 1} = Audit.prune(Scope.for_instance(scope.organisation), days: 90)
      [pruned] = entries(scope, %{action: "audit.prune"})

      view = open(conn, scope)
      assert text(view, "#entry-#{by_key.id}-actor") =~ "build-01"
      assert text(view, "#entry-#{by_key.id}-actor") =~ key.key_id
      assert text(view, "#entry-#{pruned.id}-actor") =~ "Qory"
      assert text(view, "#entry-#{pruned.id}-change") =~ "1 entry older than 90 days"
    end

    test "a person whose account is gone reads as a former member", %{conn: conn, scope: scope} do
      gone = %{scope | user: %{scope.user | id: Ecto.UUID.generate()}}
      {:ok, entry} = Audit.record(Repo, gone, :"workspace.rename", scope.workspace, %{})

      view = open(conn, scope)
      assert text(view, "#entry-#{entry.id}-actor") =~ "Former member"
    end

    test "a member's level change names the member", %{conn: conn, scope: scope} do
      %{membership: membership, user: member} = member_fixture(scope, :member)
      {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)
      [changed] = entries(scope, %{action: "member.change_level"})

      view = open(conn, scope)
      assert text(view, "#entry-#{changed.id}-subject") =~ member.email
      assert text(view, "#entry-#{changed.id}-change") =~ "Member → Owner"
    end

    @tag needs: :security
    test "a policy change says the rule and the version", %{conn: conn, scope: scope} do
      {:ok, _rule} = Apiary.Policy.allow(scope, nil, %{host: "api.example"})
      [added] = entries(scope, %{action: "security_policy.edit"})

      view = open(conn, scope)
      assert text(view, "#entry-#{added.id}-action") =~ "Added a policy rule"
      assert text(view, "#entry-#{added.id}-change") =~ "api.example"
      assert text(view, "#entry-#{added.id}-change") =~ "Now v1"
    end

    test "says so when nothing matches", %{conn: conn, scope: scope} do
      view = open(conn, scope, "?action=run.close")
      assert has_element?(view, "#activity-empty")
      assert has_element?(view, "#activity-filters-clear")
    end
  end

  describe "as a member" do
    setup %{conn: conn} do
      %{scope: owner} = sign_up_fixture()
      %{user: member} = member_fixture(owner, :member)
      %{conn: log_in_user(conn, member), owner: owner}
    end

    test "the page does not exist, and the navigation leaves it out", %{
      conn: conn,
      owner: owner
    } do
      assert_error_sent(:not_found, fn ->
        get(conn, "/#{owner.organisation.slug}/activity")
      end)

      {:ok, view, _html} = live(conn, ~p"/#{owner.organisation}/members")
      refute has_element?(view, "#nav-activity")
    end
  end
end
