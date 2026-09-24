defmodule ApiaryWeb.SettingsLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations

  describe "as an owner" do
    setup :register_and_log_in_user

    test "renames the organisation and the hive", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/hive/settings")

      # The software body's words, and no apiary word: the hive reads workplace.
      assert has_element?(lv, "h2", "Organisation name")
      assert has_element?(lv, "h2", "Workplace name")
      assert html =~ "The names of this organisation and its workplace"
      assert has_element?(lv, "#sidebar p", "Workplace")

      page = lv |> element("#main") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      refute page =~ ~r/\b(apiary|apiaries|hive|hives)\b/i

      assert html =~ scope.organisation.name
      assert html =~ scope.hive.name

      html = lv |> form("#organisation-form", organisation: %{name: "Acme"}) |> render_submit()
      assert html =~ "Organisation renamed to Acme"

      html = lv |> form("#hive-form", hive: %{name: "Platform"}) |> render_submit()
      assert html =~ "Workplace renamed to Platform"

      reloaded = Organisations.load_scope(Scope.for_user(user))
      assert reloaded.organisation.name == "Acme"
      assert reloaded.hive.name == "Platform"
    end

    test "refuses an empty name", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/hive/settings")

      html = lv |> form("#organisation-form", organisation: %{name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"

      html = lv |> form("#hive-form", hive: %{name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"

      reloaded = Organisations.load_scope(Scope.for_user(user))
      assert reloaded.organisation.name == scope.organisation.name
      assert reloaded.hive.name == scope.hive.name
    end

    test "lists the owners", %{conn: conn, user: user, scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      %{user: other_owner} = member_fixture(scope, :owner)

      {:ok, lv, _html} = live(conn, ~p"/hive/settings")

      assert has_element?(lv, "#owners", user.email)
      assert has_element?(lv, "#owners", other_owner.email)
      refute has_element?(lv, "#owners", member.email)
    end

    test "sets the retention, within the bounds, and clears it", %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/hive/settings")
      assert html =~ "This workplace keeps everything."
      assert html =~ "Nothing is pruned: this workplace keeps everything."

      html =
        lv
        |> form("#retention-form", retention: %{events_retention_days: "0"})
        |> render_change()

      assert html =~ "must be between 1 and 3650 days, or empty to keep everything"

      html =
        lv
        |> form("#retention-form",
          retention: %{events_retention_days: "30", log_retention_days: "31"}
        )
        |> render_submit()

      assert html =~ "cannot be longer than the events are kept"

      html =
        lv
        |> form("#retention-form",
          retention: %{events_retention_days: "90", log_retention_days: "14"}
        )
        |> render_submit()

      assert html =~ "Retention saved."

      assert has_element?(
               lv,
               "#retention-summary",
               "Log output is pruned after 14 days, events after 90 days."
             )

      assert has_element?(lv, "#retention-runs-empty", "Nothing has been pruned yet.")

      hive = Apiary.Repo.get!(Apiary.Organisations.Hive, scope.hive.id)
      assert {hive.events_retention_days, hive.log_retention_days} == {90, 14}

      lv
      |> form("#retention-form", retention: %{events_retention_days: "", log_retention_days: ""})
      |> render_submit()

      hive = Apiary.Repo.get!(Apiary.Organisations.Hive, scope.hive.id)
      assert {hive.events_retention_days, hive.log_retention_days} == {nil, nil}
    end

    test "says what the job pruned, for this hive only", %{conn: conn, scope: scope} do
      import Apiary.RunEventsFixtures

      {:ok, hive} = Apiary.Retention.update_retention(scope, %{events_retention_days: 10})
      run = run_fixture(scope)
      events_fixture(run, record())
      {:ok, _run} = Apiary.Runs.Projector.project(run)

      other = sign_up_fixture().scope
      {:ok, other_hive} = Apiary.Retention.update_retention(other, %{events_retention_days: 3})

      now = DateTime.add(DateTime.utc_now(), 40 * 86_400, :second)
      assert %{runs_pruned: 1} = Apiary.Retention.prune_hive(hive, now: now)
      assert %{runs_pruned: 0} = Apiary.Retention.prune_hive(other_hive, now: now)

      {:ok, lv, _html} = live(conn, ~p"/hive/settings")

      assert [mine] = Apiary.Retention.list_retention_runs(%{scope | hive: hive})

      assert has_element?(
               lv,
               "#retention-runs li",
               "1 run: 14 events and 12 B of log output in 2 chunks."
             )

      assert has_element?(lv, "#retention-run-#{mine.id}", "By hand")
      assert lv |> element("#retention-runs") |> render() =~ "events from before"
      assert lv |> render() |> String.split("retention-run-") |> length() == 2
    end
  end

  describe "as a member" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), owner: owner}
    end

    test "sees the names read-only", %{conn: conn, owner: owner} do
      {:ok, lv, html} = live(conn, ~p"/hive/settings")

      assert html =~ "Only owners can change these settings"
      assert has_element?(lv, "input#organisation_name[disabled]")
      assert has_element?(lv, "input#hive_name[disabled]")
      assert has_element?(lv, "input#retention_events_retention_days[disabled]")
      assert has_element?(lv, "input#retention_log_retention_days[disabled]")
      refute has_element?(lv, "button", "Save")

      # A crafted event changes nothing.
      html = render_submit(lv, "save_retention", %{"retention" => %{"log_retention_days" => "1"}})
      assert html =~ "Only owners can change these settings."

      assert Apiary.Repo.get!(Apiary.Organisations.Hive, owner.scope.hive.id).log_retention_days ==
               nil

      assert has_element?(lv, "#owners", owner.user.email)
    end
  end
end
