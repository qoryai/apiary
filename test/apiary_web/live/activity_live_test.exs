defmodule ApiaryWeb.ActivityLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace

  defp open(conn, scope, query \\ "") do
    {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/audit-log#{query}")
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

    @tag needs: :security
    test "names a stored secret and a variable by name, never by value",
         %{conn: conn, scope: scope} do
      {:ok, secret} =
        Apiary.Secrets.create_secret(scope, %{
          name: "GITHUB_APP_PRIVATE_KEY",
          value: "s3cr3t-value"
        })

      {:ok, _secret} = Apiary.Secrets.rename_value(scope, secret, nil, "main-app")

      {:ok, _variable} =
        Apiary.Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: "plain"})

      view = open(conn, scope)
      [variable, renamed, created | _older] = entries(scope)

      assert text(view, "#entry-#{created.id}-action") =~ "Created a stored secret"
      assert text(view, "#entry-#{created.id}-subject") =~ "GITHUB_APP_PRIVATE_KEY"
      assert text(view, "#entry-#{renamed.id}-action") =~ "Renamed a value ID of a stored secret"
      assert text(view, "#entry-#{variable.id}-action") =~ "Set a variable"
      assert text(view, "#entry-#{variable.id}-subject") =~ "NODE_ENV"
      refute render(view) =~ "s3cr3t-value"
    end

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
      # A page of the organisation's sidebar, its entry current, not a section of the
      # settings: no second column, and the sidebar's Settings is not current.
      assert has_element?(view, "aside#sidebar[aria-label='Organisation']")
      assert has_element?(view, "#nav-audit_log[aria-current='page']")
      assert has_element?(view, "#nav-audit_log[href='/#{scope.organisation.slug}/audit-log']")
      assert has_element?(view, "h1#page-header-title", "Audit log")
      refute has_element?(view, "#settings-tabs")
      refute has_element?(view, "#nav-organisation[aria-current='page']")
      refute has_element?(view, "#nav-activity")
    end

    test "its old paths send on to it, with the query", %{conn: conn, scope: scope} do
      for old <- ["activity", "settings/audit-log"] do
        conn = get(conn, "/#{scope.organisation.slug}/#{old}?action=access_key.create")

        assert redirected_to(conn, 302) ==
                 "/#{scope.organisation.slug}/audit-log?action=access_key.create"
      end
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

      assert_patch(
        view,
        "/#{scope.organisation.slug}/audit-log?action=access_key.create"
      )

      render_async(view)
      assert row_ids(view) == ["entry-#{created.id}"]
      refute has_element?(view, "#entry-#{renamed.id}")

      view = open(conn, scope, "?action=no.such")
      assert has_element?(view, "#entry-#{renamed.id}")
    end

    test "no action in the filter is shown by its code name", %{conn: conn, scope: scope} do
      options =
        conn
        |> open(scope)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#filter-action-form li")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert options != []

      for option <- options do
        refute option =~ ~r/^[a-z_]+\.[a-z_]+$/, "#{option} is a code name"
      end
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
        "/#{scope.organisation.slug}/audit-log?workspace_id=#{scope.workspace.id}"
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
      assert_patch(view, "/#{scope.organisation.slug}/audit-log?page=2")
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
        assert_patch(view, "/#{scope.organisation.slug}/audit-log")
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

    test "a person who deleted their account reads as a former member, as actor and subject",
         %{conn: conn, scope: scope} do
      %{scope: member, user: user} = member_fixture(scope, :member)
      {:ok, key, _secret} = Apiary.AccessKeys.create_access_key(member, %{label: "theirs"})
      {:ok, _} = Apiary.Accounts.delete_user(member)
      [created] = entries(scope, %{action: "access_key.create"})
      [left] = entries(scope, %{action: "member.remove"})

      view = open(conn, scope)
      assert text(view, "#entry-#{created.id}-actor") =~ "Former member"
      refute render(view) =~ user.email
      assert text(view, "#entry-#{left.id}-actor") =~ "Former member"
      assert text(view, "#entry-#{left.id}-subject") =~ "Former member"

      assert text(view, "#entry-#{left.id}-action") =~
               "Deleted their account, which ended their membership"

      # The key they made stays with the workspace.
      assert text(view, "#entry-#{created.id}-subject") =~ key.label
    end

    test "a workspace's deletion, cancelling and purge name it, until it is purged",
         %{conn: conn, scope: scope} do
      workspace = workspace_fixture(scope.organisation, "Staging")
      {:ok, _} = Apiary.Deletion.delete_workspace(scope, workspace.id, "staging")
      [deleted] = entries(scope, %{action: "workspace.delete"})

      view = open(conn, scope)
      assert text(view, "#entry-#{deleted.id}-action") =~ "Deleted a workspace"
      assert text(view, "#entry-#{deleted.id}-subject") =~ "Staging"
      assert text(view, "#entry-#{deleted.id}-change") =~ "Purged on"

      Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      {:ok, :purged} =
        Apiary.Deletion.purge_workspace(Scope.for_instance(scope.organisation, workspace))

      [purged] = entries(scope, %{action: "workspace.purge"})

      view = open(conn, scope)
      assert text(view, "#entry-#{purged.id}-actor") =~ "Qory"
      assert text(view, "#entry-#{purged.id}-action") =~ "Purged a deleted workspace"
      assert text(view, "#entry-#{purged.id}-subject") =~ "A deleted workspace"
    end

    test "a member's level change names the member", %{conn: conn, scope: scope} do
      %{membership: membership, user: member} = member_fixture(scope, :member)
      {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)
      [changed] = entries(scope, %{action: "member.change_level"})

      view = open(conn, scope)
      assert text(view, "#entry-#{changed.id}-subject") =~ member.email
      assert text(view, "#entry-#{changed.id}-change") =~ "Member → Owner"
    end

    test "a member's suspension names the member", %{conn: conn, scope: scope} do
      %{membership: membership, user: member} = member_fixture(scope, :member)
      {:ok, _} = Organisations.suspend_member(scope, membership.id)
      [suspended] = entries(scope, %{action: "member.suspend"})

      view = open(conn, scope)
      assert text(view, "#entry-#{suspended.id}-action") =~ "Suspended a member"
      assert text(view, "#entry-#{suspended.id}-subject") =~ member.email
    end

    test "a person who removed themselves left; one removed by another was removed", %{
      conn: conn,
      scope: scope
    } do
      %{scope: leaving, membership: left} = member_fixture(scope, :member)
      %{membership: removed} = member_fixture(scope, :member)
      {:ok, _} = Organisations.remove_member(leaving, left.id)
      {:ok, _} = Organisations.remove_member(scope, removed.id)

      [by_owner, by_themselves] = entries(scope, %{action: "member.remove"})
      assert by_themselves.subject_id == left.id
      assert by_owner.subject_id == removed.id

      view = open(conn, scope)
      assert text(view, "#entry-#{by_themselves.id}-action") =~ "Left the organisation"
      assert text(view, "#entry-#{by_owner.id}-action") =~ "Removed a member"
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
        get(conn, "/#{owner.organisation.slug}/audit-log")
      end)

      {:ok, view, _html} = live(conn, ~p"/#{owner.organisation}/settings/people")
      refute has_element?(view, "#nav-audit_log")
      refute has_element?(view, "#settings-tab-audit_log")
    end
  end
end
