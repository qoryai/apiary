defmodule ApiaryWeb.InstanceLive.SetUpTest do
  # The instance's connections, `/instance/set-up` (`ApiaryWeb.InstanceLive.SetUp`), its
  # adapters' steps: one step a page for each of the instance's adapters, by name, then
  # mail; an adapter's state, Set up in a new tab while it is not set up, and Continue once
  # it is configured, read again as it declares; Skip to the next step; and a path that
  # does not exist for anyone but an instance admin. `ApiaryWeb.InstanceLive.SetUpMailTest`
  # has the mail step, and the page without the feature adapters belong to.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

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

  test "has one step for each adapter, by name, then mail", %{conn: conn} do
    %{adapter: second} = settable_adapter_fixture(%{name: named("b-tracker")})
    %{adapter: first} = connectable_adapter_fixture(%{name: named("a-tracker")})

    {:ok, lv, html} = live(conn, ~p"/instance/set-up")

    assert html =~ ~r{<title[^>]*>\s*Connect Qory Apiary}
    assert has_element?(lv, "h1", "Connect Qory Apiary")
    assert words(lv, "#set-up-step") == "Step 1 of 3"
    assert has_element?(lv, "#set-up-#{first.public_id} h2", first.name)
    refute has_element?(lv, "#shell .drawer")

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=2")
    assert words(lv, "#set-up-step") == "Step 2 of 3"
    assert has_element?(lv, "#set-up-#{second.public_id} h2", second.name)

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=3")
    assert words(lv, "#set-up-step") == "Step 3 of 3"
    assert has_element?(lv, "#set-up-mail h2", "Mail")

    # A step out of range is the first.
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=9")
    assert words(lv, "#set-up-step") == "Step 1 of 3"
  end

  test "an adapter not set up says so, with Set up in a new tab and Skip", %{conn: conn} do
    %{adapter: adapter} = settable_adapter_fixture(%{name: named("tracker")})

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")

    assert words(lv, "#set-up-what") ==
             "Set up #{adapter.name}, so organisations can bring in tickets from #{adapter.name}."

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

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=2")
    assert words(lv, "#set-up-step") == "Step 2 of 2"
    assert has_element?(lv, "#set-up-mail")

    # Listed before the first, by name.
    %{adapter: added} = settable_adapter_fixture(%{name: named("a-tracker")})
    send(lv.pid, {:adapter_declared, %{node_id: first.id}})

    assert_patch(lv, ~p"/instance/set-up?step=3")
    assert words(lv, "#set-up-step") == "Step 3 of 3"
    assert has_element?(lv, "#set-up-mail")

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
    assert has_element?(lv, "#set-up-#{added.public_id}")
  end

  test "an adapter's step stays on it when another is added before it", %{conn: conn} do
    %{adapter: shown} = settable_adapter_fixture(%{name: named("b-tracker")})
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
    assert has_element?(lv, "#set-up-#{shown.public_id}")

    %{adapter: _added} = settable_adapter_fixture(%{name: named("a-tracker")})
    send(lv.pid, {:adapter_declared, %{node_id: shown.id}})

    assert_patch(lv, ~p"/instance/set-up?step=2")
    assert words(lv, "#set-up-step") == "Step 2 of 3"
    assert has_element?(lv, "#set-up-#{shown.public_id}")
  end

  test "Skip and Continue lead to the next step", %{conn: conn} do
    %{adapter: first} = connectable_adapter_fixture(%{name: named("a-tracker")})
    %{adapter: second} = settable_adapter_fixture(%{name: named("b-tracker")})

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
    assert has_element?(lv, "#set-up-#{first.public_id}")

    lv |> element("#set-up-continue") |> render_click()
    assert_patch(lv, ~p"/instance/set-up?step=2")
    assert has_element?(lv, "#set-up-#{second.public_id}")

    lv |> element("#set-up-skip-button") |> render_click()
    assert_patch(lv, ~p"/instance/set-up?step=3")
    assert has_element?(lv, "#set-up-mail")
    refute Apiary.Setup.connections_reviewed?()
  end
end

defmodule ApiaryWeb.InstanceLive.SetUpMailTest do
  # The mail step of the instance's connections (`ApiaryWeb.InstanceLive.SetUp`): the help
  # and the form of Instance settings › Mail, whose test link done or Skip marks the
  # connections reviewed and leads on; the environment's mail with Continue; and the page
  # without the feature adapters belong to, mail its one step.
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures

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
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")
    if has_element?(lv, "#set-up-mail"), do: lv, else: mail_step(conn, lv)
  end

  defp mail_step(conn, lv) do
    {:ok, lv, _html} = live(conn, "/instance/set-up?step=#{words(lv, "#set-up-step") |> total()}")
    lv
  end

  defp total(step), do: step |> String.split() |> List.last()

  test "asks for a recent sign-in, as Instance settings › Mail does", %{user: user} do
    eleven_minutes_ago = DateTime.add(DateTime.utc_now(:second), -11, :minute)
    conn = log_in_user(build_conn(), user, token_authenticated_at: eleven_minutes_ago)

    assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
             live(conn, ~p"/instance/set-up")

    assert flash["error"] == "You must re-authenticate to access this page."
  end

  test "shows the help and the form of Instance settings › Mail, with Skip", %{conn: conn} do
    lv = mail_step(conn)

    assert words(lv, "#set-up-what") ==
             "Set up mail, so Qory Apiary sends invitations and password links."

    assert words(lv, "#set-up-help") ==
             "Get the SMTP server's host name, port, username and password from your mail provider. " <>
               "In SMTP relay, enter the mail server's host name, such as smtp.example.com. " <>
               "In Port, keep 587 for STARTTLS, or enter 465 if your provider uses TLS from the start. " <>
               "In Username and Password, enter the login your provider gave you. Leave both empty if the relay takes mail without a login. " <>
               "Press Save and send a test. " <>
               "Open the email that Qory Apiary sent to your address, and follow its link while you are signed in. " <>
               "If the step shows Set by the server's environment, mail is set up already, and this step needs nothing from you."

    assert has_element?(lv, "#mail_form input[name='mail[smtp_relay]']")
    assert has_element?(lv, "#mail-save button[type=submit]", "Save and send a test")
    assert has_element?(lv, "#mail-save #set-up-skip-button", "Skip")
    refute has_element?(lv, "#mail-status", "Off:")
  end

  test "Save and send a test sends the test link, marks the connections reviewed and leads on",
       %{conn: conn, user: user} do
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

    assert {"/", flash} = assert_redirect(lv)

    assert flash["info"] ==
             "Mail turns on when you follow the link we sent to #{user.email}, signed in as you."

    assert Setup.connections_reviewed?()
  end

  test "a save the form refuses stays on the step", %{conn: conn} do
    lv = mail_step(conn)

    lv |> form("#mail_form", mail: %{"smtp_relay" => ""}) |> render_submit()

    assert has_element?(lv, "#mail_form [name='mail[smtp_relay]'][aria-invalid]")
    refute Setup.connections_reviewed?()
  end

  test "Skip on the last step marks the connections reviewed and leads on", %{conn: conn} do
    lv = mail_step(conn)

    lv |> element("#set-up-skip-button") |> render_click()

    assert {"/", _flash} = assert_redirect(lv)
    assert Setup.connections_reviewed?()

    # Marked once: a later skip keeps the first time.
    %{rows: [[first]]} =
      Apiary.Repo.query!("SELECT connections_reviewed_at FROM instance_settings WHERE id")

    lv = mail_step(conn)
    lv |> element("#set-up-skip-button") |> render_click()

    assert %{rows: [[^first]]} =
             Apiary.Repo.query!("SELECT connections_reviewed_at FROM instance_settings WHERE id")
  end

  test "where the environment sets mail, says so, with Continue", %{conn: conn} do
    Mail.put_test_source(:env)
    lv = mail_step(conn)

    assert has_element?(lv, "#mail-env #mail-status", "Set by the server's environment")
    refute has_element?(lv, "#mail_form")

    lv |> element("#set-up-continue") |> render_click()
    assert {"/", _flash} = assert_redirect(lv)
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
    refute has_element?(lv, "#set-up-step")
  end
end
