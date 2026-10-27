defmodule ApiaryWeb.InstanceLive.SetUpTest do
  # The instance's connections, `/instance/set-up` (`ApiaryWeb.InstanceLive.SetUp`), its
  # adapters' steps: one step a page for each of the instance's adapters, by name, then
  # mail, each at its key, in the set-up's progress indicator; an adapter's state, Set up
  # in a new tab while it is not set up, and Continue once it is configured, read again as
  # it declares; Skip to the next step, Back to the one before; and a path that does not
  # exist for anyone but an instance admin. `ApiaryWeb.InstanceLive.SetUpMailTest`
  # has the mail step, and the page without the feature adapters belong to.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryWeb.SetUpSteps

  alias Apiary.Repo
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup do
    admin = instance_admin_scope()
    %{admin: admin, conn: log_in_user(build_conn(), admin.user)}
  end

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp named(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "is a path that does not exist for anyone but an instance admin" do
    %{user: user} = sign_up_fixture()
    conn = log_in_user(build_conn(), user)

    assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/set-up") end
    assert_error_sent :not_found, fn -> get(conn, ~p"/instance/set-up") end
  end

  test "has one step for each adapter, by name, then mail, in the set-up's steps",
       %{conn: conn} do
    %{adapter: second} = settable_adapter_fixture(%{name: named("b-tracker")})
    %{adapter: first} = connectable_adapter_fixture(%{name: named("a-tracker")})

    {:ok, lv, html} = live(conn, ~p"/instance/set-up?step=#{first.public_id}")

    assert html =~ ~r{<title[^>]*>\s*Connect Qory Apiary}
    assert has_element?(lv, "h1", "Connect Qory Apiary")
    assert count(lv) == "Step 2 of 6"
    assert has_element?(lv, "#set-up-#{first.public_id} h2", first.name)
    refute has_element?(lv, "#shell .drawer")

    # The organisation has Main; its work source is not connected. Mail is done where the
    # test's environment sets it.
    assert [
             {"Your account", :done},
             {first_name, :current},
             {second_name, :to_come},
             {"Mail", _mail} | _
           ] = Enum.map(steps(lv), &{elem(&1, 0), elem(&1, 1)})

    assert {first_name, second_name} == {first.name, second.name}
    assert Enum.take(steps(lv), -2) == [{"Workspace", :done, :link}, {"Work source", :to_come}]

    assert has_element?(lv, "#set-up-steps p", "Connect Qory Apiary")
    assert has_element?(lv, "#set-up-steps p", "Set up your workspace")

    assert words(lv, "#set-up-next") ==
             "Next: on the Overview, Machines for runs, Model key and Test run"

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{second.public_id}")
    assert count(lv) == "Step 3 of 6"
    assert has_element?(lv, "#set-up-#{second.public_id} h2", second.name)

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=mail")
    assert count(lv) == "Step 4 of 6"
    assert has_element?(lv, "#set-up-mail h2", "Mail")

    assert [_account, {_, :done, :link}, {_, :skipped, :link}, {"Mail", :current} | _] =
             steps(lv)

    # Without a step, or with one the page does not have, the first step not done.
    for path <- [~p"/instance/set-up", ~p"/instance/set-up?step=9"] do
      {:ok, lv, _html} = live(conn, path)
      assert count(lv) == "Step 3 of 6"
      assert has_element?(lv, "#set-up-#{second.public_id}")
    end
  end

  test "shows the count and no number left over", %{conn: conn} do
    %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{adapter.public_id}")

    assert words(lv, "#set-up-step-bar") == "Step 2 of 5: #{adapter.name}"
    assert has_element?(lv, ~s{#set-up-steps progress[value="2"][max="5"]})
    refute words(lv, "#set-up-steps") =~ "left"
    refute words(lv, "#set-up-steps") =~ "·"
    assert has_element?(lv, ~s{#set-up-steps-toggle[aria-expanded="false"]}, "All steps")
  end

  test "Back leads to the step before, which opens as it was saved or skipped",
       %{conn: conn} do
    %{adapter: first} = connectable_adapter_fixture(%{name: named("a-tracker")})
    %{adapter: second} = settable_adapter_fixture(%{name: named("b-tracker")})

    # The first adapter's step has Your account before it, which has no page: no Back.
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{first.public_id}")
    refute has_element?(lv, "#set-up-back")

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=mail")

    assert has_element?(
             lv,
             ~s{#set-up-back[aria-label="Back to #{second.name}"]},
             "Back"
           )

    # Skipped: it opens not set up, with Set up and Skip.
    lv |> element("#set-up-back") |> render_click()
    assert_patch(lv, ~p"/instance/set-up?step=#{second.public_id}")
    assert words(lv, "#set-up-state") == "State:Not set up"
    assert has_element?(lv, "#set-up-open")
    assert has_element?(lv, "#set-up-skip-button")

    # Saved: it opens set up, with Continue; a link of the indicator leads there.
    lv |> element("#set-up-steps-adapter-#{first.public_id}") |> render_click()
    assert_patch(lv, ~p"/instance/set-up?step=#{first.public_id}")
    assert words(lv, "#set-up-state") == "State:Set up"
    assert has_element?(lv, "#set-up-continue")

    # A step after the current one that is done stays a link: Workspace, to its summary.
    assert {second.name, :to_come} in steps(lv)
    assert {"Workspace", :done, :link} in steps(lv)

    assert {:error, {_redirect, %{to: to}}} =
             lv |> element("#set-up-steps-workspace") |> render_click()

    assert to =~ ~r{/set-up\?step=type$}
  end

  test "an adapter not set up says so, with Set up in a new tab and Skip", %{conn: conn} do
    %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")

    assert words(lv, "#set-up-context h2") == "About this step"

    assert words(lv, "#set-up-what") ==
             "Organisations on this instance bring in tickets from #{adapter.name} once its " <>
               "adapter is set up. Set up opens the adapter's set-up page in a new tab, and " <>
               "this step shows the new state without a reload."

    assert words(lv, "#set-up-state") == "State:Not set up"

    assert has_element?(
             lv,
             ~s{form#set-up-open[target="_blank"][method="post"][action="/instance/adapters/#{adapter.public_id}/setup"]}
           )

    assert has_element?(lv, "#set-up-open-button", "Set up")
    assert has_element?(lv, "#set-up-skip-button", "Skip")
    assert words(lv, "#set-up-skip p") == "You can finish this later in Instance settings."
    refute has_element?(lv, "#set-up-continue")
  end

  describe "an adapter's guide" do
    # The text of each element `selector` finds under the help, its spaces joined.
    defp texts(lv, selector) do
      lv
      |> element("#set-up-help")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
    end

    test "shows the adapter's setup steps in the context column, under In the new tab",
         %{conn: conn} do
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("forge")})
      guide = source_guide_example()
      guided_adapter(adapter, guide)

      {:ok, lv, _html} = live(conn, ~p"/instance/set-up")

      assert has_element?(lv, "#set-up-context #set-up-help h3", "In the new tab")
      assert texts(lv, "li") == guide["setup"]["steps"]
      assert texts(lv, "p") == [guide["setup"]["before"]]
      refute render(lv) =~ "A new tab opens."
      refute render(lv) =~ "Come back to this tab."
    end

    test "shows no steps while Set up is not on the page: blocked, or set up already", %{
      conn: conn
    } do
      guide = source_guide_example()

      # No key in use.
      no_key = adapter_fixture(%{name: named("a-forge")})

      # A key in use, and no address where it is set up or connected to.
      %{adapter: not_declared} = connectable_adapter_fixture(%{name: named("b-forge")})

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^not_declared.id), set: [connect_url: nil])

      # Installed with Qory Apiary under a name no longer listed.
      %{adapter: not_listed} = settable_adapter_fixture(%{name: named("c-forge")})

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^not_listed.id),
          set: [installed_as: named("gone")]
        )

      # Set up already: Continue.
      %{adapter: configured} = connectable_adapter_fixture(%{name: named("d-forge")})

      # Set up can be pressed: the steps show.
      %{adapter: settable} = settable_adapter_fixture(%{name: named("e-forge")})

      for adapter <- [no_key, not_declared, not_listed, configured, settable],
          do: guided_adapter(adapter, guide)

      for adapter <- [no_key, not_declared, not_listed, configured] do
        {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{adapter.public_id}")
        assert has_element?(lv, "#set-up-#{adapter.public_id}")
        refute has_element?(lv, "#set-up-open")
        refute has_element?(lv, "#set-up-help"), adapter.name
      end

      {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{settable.public_id}")
      assert has_element?(lv, "#set-up-#{settable.public_id}")
      assert has_element?(lv, "#set-up-open")
      assert has_element?(lv, "#set-up-help")
    end

    test "with no guide, the step shows no steps", %{conn: conn} do
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("forge")})
      guided_adapter(adapter, %{"connect" => source_guide_example()["connect"]})

      {:ok, lv, _html} = live(conn, ~p"/instance/set-up")

      assert has_element?(lv, "#set-up-#{adapter.public_id}")
      refute has_element?(lv, "#set-up-help")

      guided_adapter(adapter, nil)
      {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
      refute has_element?(lv, "#set-up-help")
    end

    test "shows the adapter's lines as plain text, never as Markdown or HTML", %{conn: conn} do
      %{adapter: adapter} = settable_adapter_fixture(%{name: named("forge")})

      guided_adapter(adapter, %{
        "setup" => %{
          "before" => "<script>alert(1)</script> first",
          "steps" => [
            "Press **Approve** in <b>Settings</b>.",
            "Open [the page](https://example.com)."
          ],
          "after" => "<i>Done</i>"
        }
      })

      {:ok, lv, _html} = live(conn, ~p"/instance/set-up")

      assert texts(lv, "li") == [
               "Press **Approve** in <b>Settings</b>.",
               "Open [the page](https://example.com)."
             ]

      assert texts(lv, "p") == ["<script>alert(1)</script> first", "<i>Done</i>"]

      refute has_element?(lv, "#set-up-help script")
      refute has_element?(lv, "#set-up-help i")
      refute has_element?(lv, "#set-up-help a")
      refute has_element?(lv, "#set-up-help strong")
      refute has_element?(lv, "#set-up-help b")
    end
  end

  test "an adapter that can't be set up says why, and what to do", %{conn: conn} do
    # No key in use.
    no_key = adapter_fixture(%{name: named("a-tracker")})

    # A key in use, and no address where it is set up or connected to.
    %{adapter: not_declared} = connectable_adapter_fixture(%{name: named("b-tracker")})

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^not_declared.id), set: [connect_url: nil])

    # Installed with Qory Apiary under a name no longer listed.
    %{adapter: not_listed} = settable_adapter_fixture(%{name: named("c-tracker")})

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^not_listed.id),
        set: [installed_as: named("gone")]
      )

    # Set up can be pressed: no line.
    %{adapter: settable} = settable_adapter_fixture(%{name: named("d-tracker")})

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{no_key.public_id}")
    assert has_element?(lv, "#set-up-#{no_key.public_id}")

    assert words(lv, "#set-up-blocked") ==
             "Connect #{no_key.name} with an access key in Instance settings › Adapters. " <>
               "It can't be set up until it has a key in use; this step updates once it has one."

    refute has_element?(lv, "#set-up-open")
    assert has_element?(lv, "#set-up-skip-button", "Skip")

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{not_declared.public_id}")
    assert has_element?(lv, "#set-up-#{not_declared.public_id}")

    assert words(lv, "#set-up-blocked") ==
             "Check that #{not_declared.name} is running. It has a key in use, but it has not " <>
               "sent the address where it is set up; this step updates once it has."

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{not_listed.public_id}")
    assert has_element?(lv, "#set-up-#{not_listed.public_id}")

    assert words(lv, "#set-up-blocked") ==
             "Skip this step. #{not_listed.name} is no longer on the list of adapters installed " <>
               "with Qory Apiary, so it can't be set up."

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{settable.public_id}")
    assert has_element?(lv, "#set-up-#{settable.public_id}")
    assert has_element?(lv, "#set-up-open")
    refute has_element?(lv, "#set-up-blocked")
  end

  test "turns to Set up and Continue once the adapter is configured, while the page is open",
       %{conn: conn} do
    %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
    assert words(lv, "#set-up-state") == "State:Not set up"

    # Its start once it is set up: no `setup_url` any more, and the pages are told.
    {1, _} = Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [setup_url: nil])
    send(lv.pid, {:adapter_declared, %{node_id: adapter.id}})

    assert words(lv, "#set-up-state") == "State:Set up"
    assert has_element?(lv, "#set-up-continue", "Continue")
    refute has_element?(lv, "#set-up-open")
    refute has_element?(lv, "#set-up-skip")
  end

  test "an adapter added while the page is open adds a step, and mail stays the last",
       %{conn: conn} do
    %{adapter: first} = connectable_adapter_fixture(%{name: named("b-tracker")})

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=mail")
    assert count(lv) == "Step 3 of 5"
    assert has_element?(lv, "#set-up-mail")

    # Listed before the first, by name.
    %{adapter: added} = settable_adapter_fixture(%{name: named("a-tracker")})
    send(lv.pid, {:adapter_declared, %{node_id: first.id}})

    assert count(lv) == "Step 4 of 6"
    assert has_element?(lv, "#set-up-mail")
    assert {added.name, :skipped, :link} in steps(lv)

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
    assert has_element?(lv, "#set-up-#{added.public_id}")
  end

  test "an adapter's step stays on it when another is added before it", %{conn: conn} do
    %{adapter: shown} = settable_adapter_fixture(%{name: named("b-tracker")})
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
    assert has_element?(lv, "#set-up-#{shown.public_id}")

    %{adapter: _added} = settable_adapter_fixture(%{name: named("a-tracker")})
    send(lv.pid, {:adapter_declared, %{node_id: shown.id}})

    assert count(lv) == "Step 3 of 6"
    assert has_element?(lv, "#set-up-#{shown.public_id}")
  end

  test "Skip and Continue lead to the next step", %{conn: conn} do
    %{adapter: first} = connectable_adapter_fixture(%{name: named("a-tracker")})
    %{adapter: second} = settable_adapter_fixture(%{name: named("b-tracker")})

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{first.public_id}")
    assert has_element?(lv, "#set-up-#{first.public_id}")

    lv |> element("#set-up-continue") |> render_click()
    assert_patch(lv, ~p"/instance/set-up?step=#{second.public_id}")
    assert has_element?(lv, "#set-up-#{second.public_id}")

    lv |> element("#set-up-skip-button") |> render_click()
    assert_patch(lv, ~p"/instance/set-up?step=mail")
    assert has_element?(lv, "#set-up-mail")
    refute Apiary.Setup.connections_reviewed?()
  end
end

defmodule ApiaryWeb.InstanceLive.SetUpMailTest do
  # The mail step of the instance's connections (`ApiaryWeb.InstanceLive.SetUp`): its
  # context and the form of Instance settings › Mail, whose test link done or Skip marks
  # the connections reviewed and leads on, to Work source while it is not done; the saved
  # settings with Continue; the environment's mail with Continue; and the page without the
  # feature adapters belong to, mail its one step of the instance.
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import ApiaryWeb.SetUpSteps

  alias Apiary.{Mail, Setup}

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  setup :register_and_log_in_user

  setup do
    Mail.put_test_source(:none)
    :ok
  end

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp mail_step(conn) do
    {:ok, lv, _html} = live(conn, mail_step_path(conn))
    lv
  end

  defp mail_step_path(_conn), do: ~p"/instance/set-up?step=mail"

  # Where the last step leads: Work source, with the feature, while it is not done; else
  # on, as a sign-in sends the admin.
  defp after_mail(scope) do
    if Apiary.Features.on?(:factory),
      do: ~p"/#{scope.organisation}/set-up?step=source",
      else: ~p"/"
  end

  # The mail form in `html` is sent with POST, and its password's field has no value.
  defp assert_posts_without_password(html) do
    form = LazyHTML.query(html, "#mail_form")
    assert LazyHTML.attribute(form, "method") == ["post"]
    assert LazyHTML.attribute(form, "action") == []

    password = LazyHTML.query(form, ~s{input[type="password"]})
    assert LazyHTML.attribute(password, "name") == ["mail[smtp_password]"]
    assert LazyHTML.attribute(password, "value") == []
  end

  test "asks for a recent sign-in, as Instance settings › Mail does", %{user: user} do
    eleven_minutes_ago = DateTime.add(DateTime.utc_now(:second), -11, :minute)
    conn = log_in_user(build_conn(), user, token_authenticated_at: eleven_minutes_ago)

    assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
             live(conn, ~p"/instance/set-up")

    assert flash["error"] == "You must re-authenticate to access this page."
  end

  test "shows the context and the form of Instance settings › Mail, with Skip", %{conn: conn} do
    Mail.put_test_source(:none)
    lv = mail_step(conn)

    assert words(lv, "#set-up-what") ==
             "Qory Apiary sends invitations, log-in links and password links by mail; without " <>
               "mail, an admin copies each link by hand. Get the SMTP server's host name, port, " <>
               "username and password from your mail provider. Mail turns on when you follow the " <>
               "test link that Qory Apiary emails you, while you are signed in."

    refute has_element?(lv, "#set-up-help")

    assert has_element?(lv, "#mail_form input[name='mail[smtp_relay]']")
    assert has_element?(lv, "#mail-save button[type=submit]", "Save and send a test")
    assert has_element?(lv, "#mail-save #set-up-skip-button", "Skip")
    refute has_element?(lv, "#mail-status", "Off:")
    refute has_element?(lv, "#set-up-env")
    refute has_element?(lv, "#set-up-continue")
  end

  test "Save and send a test sends the test link, marks the connections reviewed and leads on",
       %{conn: conn, user: user, scope: scope} do
    lv = mail_step(conn)

    lv
    |> form("#mail_form",
      mail: %{
        "smtp_relay" => "smtp.example.com",
        "smtp_port" => "587",
        "smtp_tls" => "always",
        "smtp_username" => "qory",
        "smtp_password" => "correct horse battery staple",
        "mail_from" => "qory@example.com"
      }
    )
    |> render_submit()

    assert_received {:email, %{subject: "Turn on mail for Qory Apiary"}}

    {to, flash} = assert_redirect(lv)
    assert to == after_mail(scope)

    assert flash["info"] ==
             "Mail turns on when you follow the link we sent to #{user.email}, signed in as you."

    assert Setup.connections_reviewed?()

    # Back to Mail: the saved settings, the password's field empty, and Continue.
    lv = mail_step(conn)
    assert {"Mail", :current} in steps(lv)

    assert has_element?(
             lv,
             ~s{#mail_form input[name="mail[smtp_relay]"][value="smtp.example.com"]}
           )

    assert has_element?(lv, "#mail-save button[type=submit]", "Save and send a test")
    assert has_element?(lv, "#mail-save #set-up-continue", "Continue")
    refute has_element?(lv, "#set-up-skip-button")

    lv |> element("#set-up-continue") |> render_click()
    assert {^to, _flash} = assert_redirect(lv)
  end

  test "posts its form, and the password's field has no value", %{conn: conn} do
    path = mail_step_path(conn)

    # The step before it connects: a submit there is the browser's, with the form's method.
    html = conn |> get(path) |> html_response(200)
    assert_posts_without_password(LazyHTML.from_document(html))

    {:ok, lv, _html} = live(conn, path)

    html =
      lv
      |> form("#mail_form",
        mail: %{
          "smtp_relay" => "smtp example com",
          "smtp_port" => "587",
          "smtp_tls" => "always",
          "smtp_username" => "qory",
          "smtp_password" => "s3cret-example",
          "mail_from" => "qory@example.com"
        }
      )
      |> render_submit()

    assert html =~ "must be a host name, such as smtp.example.com"
    refute html =~ "s3cret-example"
    assert_posts_without_password(LazyHTML.from_fragment(html))
  end

  test "a save the form refuses stays on the step", %{conn: conn} do
    lv = mail_step(conn)

    lv |> form("#mail_form", mail: %{"smtp_relay" => ""}) |> render_submit()

    assert has_element?(lv, "#mail_form [name='mail[smtp_relay]'][aria-invalid]")
    refute Setup.connections_reviewed?()
  end

  test "Skip on the last step marks the connections reviewed and leads on",
       %{conn: conn, scope: scope} do
    lv = mail_step(conn)

    lv |> element("#set-up-skip-button") |> render_click()

    {to, _flash} = assert_redirect(lv)
    assert to == after_mail(scope)
    assert Setup.connections_reviewed?()

    # Marked once: a later skip keeps the first time.
    %{rows: [[first]]} =
      Apiary.Repo.query!("SELECT connections_reviewed_at FROM instance_settings WHERE id")

    lv = mail_step(conn)
    lv |> element("#set-up-skip-button") |> render_click()

    assert %{rows: [[^first]]} =
             Apiary.Repo.query!("SELECT connections_reviewed_at FROM instance_settings WHERE id")
  end

  test "where the environment sets mail, shows its settings and no form", %{conn: conn} do
    Mail.put_test_source(:env)
    lv = mail_step(conn)

    assert has_element?(lv, "#mail-env #mail-status", "Set by the server's environment")
    refute has_element?(lv, "#mail_form")
  end

  test "where the environment sets mail, shows no context and no line to press Continue",
       %{conn: conn, scope: scope} do
    Mail.put_test_source(:env)
    lv = mail_step(conn)

    refute has_element?(lv, "#set-up-context")
    refute has_element?(lv, "#set-up-help")
    refute render(lv) =~ "Save and send a test"
    refute render(lv) =~ "Press Continue"
    refute has_element?(lv, "#set-up-skip-button")
    assert has_element?(lv, "#set-up-continue", "Continue")
    assert {"Mail", :current} in steps(lv)

    lv |> element("#set-up-continue") |> render_click()
    {to, _flash} = assert_redirect(lv)
    assert to == after_mail(scope)
    assert Setup.connections_reviewed?()
  end

  @tag with_features: [:observability]
  test "without the feature adapters belong to, mail is the one step", %{conn: conn} do
    # Made where the feature is on, before it went.
    Application.put_env(:apiary, :features, Apiary.Features.all())
    %{adapter: adapter} = settable_adapter_fixture()
    Application.put_env(:apiary, :features, [:observability])

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")

    assert has_element?(lv, "#set-up-mail")
    refute has_element?(lv, "#set-up-#{adapter.public_id}")
    assert steps(lv) == [{"Your account", :done}, {"Mail", :current}, {"Workspace", :done, :link}]
    refute has_element?(lv, "#set-up-next")
  end
end
