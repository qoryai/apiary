defmodule ApiaryWeb.ProductNamePlacesTest do
  @moduledoc """
  Every place that names the product (`Apiary.ProductName`), read from the pages and the
  emails as a person sees them: with no name set, each reads as it always has, and where
  the edition names the product otherwise, only the menu's button and its names show that
  name; with a name an instance admin set, each reads that name, the sentences that say
  "this Qory Apiary" name the instance, and the sidebar's foot, the log-in pages and every
  email say "Powered by Qory Apiary". The numbers are the places' in the approved list.
  """
  # Not async: the set-up page and the not-set-up line hide the instance's organisation, a
  # row every test shares, and the docs' page points the application at a directory.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import Apiary.AccountsFixtures

  alias Apiary.Accounts.UserNotifier
  alias Apiary.Repo

  @moduletag :tmp_dir

  # The places as the approved list has them: before, with no name set, and after, with
  # Acme Agents set, an organisation Acme, and the address dana@example.com.
  @before %{
    1 => "Qory Apiary",
    # The end of every title: the list's example is Runs · Main · Acme · Qory Apiary.
    2 => " · Qory Apiary",
    3 => "Qory Apiary",
    4 => "Qory Apiary menu",
    5 => "Qory Apiary",
    6 => "Qory Apiary",
    7 => "Qory Apiary",
    8 =>
      "Every run of a connected machine reports to Qory Apiary: its session, terminal and every connection, with the decision and rule behind it. Open source, so you can check all of that.",
    9 => "Welcome to Qory Apiary",
    10 => "Welcome to Qory Apiary",
    11 => "Log in to Qory Apiary",
    12 => "Ask an admin of this Qory Apiary for a password link.",
    13 => "New to Qory Apiary?",
    14 => "This account cannot log in at the moment. Ask the admins of this Qory Apiary.",
    15 => "This account cannot log in at the moment. Ask the admins of this Qory Apiary.",
    16 =>
      "Password links work once and for a short time. Ask an admin of this Qory Apiary for a new one.",
    17 => "Set up Qory Apiary",
    18 => "This Qory Apiary is already set up.",
    19 => "This Qory Apiary is not set up yet: use the set-up link from its install.",
    20 => "Back to Qory Apiary",
    21 => "Qory Apiary <qory@example.com>",
    22 => "Confirm your new email address for Qory Apiary",
    23 =>
      "You can change the email address of your Qory Apiary account by visiting the URL below:",
    24 => "Your Qory Apiary log-in link",
    25 => "You can log in to Qory Apiary by visiting the URL below:",
    26 => "Confirm your Qory Apiary account",
    27 => "You can confirm your Qory Apiary account by visiting the URL below:",
    28 => "If you did not create a Qory Apiary account, ignore this email.",
    29 => "Your invitation to Qory Apiary",
    30 =>
      "You are invited to join the organisation “Acme” on Qory Apiary. You can accept the invitation by visiting the URL below:",
    31 => "Turn on mail for Qory Apiary",
    32 =>
      "You saved the mail settings of Qory Apiary. To turn mail on, visit the URL below while you are logged in as dana@example.com:"
  }

  @renamed %{
    1 => "Acme Agents",
    2 => " · Acme Agents",
    3 => "Acme Agents",
    4 => "Acme Agents menu",
    5 => "Acme Agents",
    6 => "Acme Agents",
    7 => "Acme Agents",
    8 =>
      "Every run of a connected machine reports to Acme Agents: its session, terminal and every connection, with the decision and rule behind it. Open source, so you can check all of that.",
    9 => "Welcome to Acme Agents",
    10 => "Welcome to Acme Agents",
    11 => "Log in to Acme Agents",
    12 => "Ask an admin of Acme Agents for a password link.",
    13 => "New to Acme Agents?",
    14 => "This account cannot log in at the moment. Ask the admins of Acme Agents.",
    15 => "This account cannot log in at the moment. Ask the admins of Acme Agents.",
    16 =>
      "Password links work once and for a short time. Ask an admin of Acme Agents for a new one.",
    17 => "Set up Acme Agents",
    18 => "Acme Agents is already set up.",
    19 => "Acme Agents is not set up yet: use the set-up link from its install.",
    20 => "Back to Acme Agents",
    21 => "Acme Agents <qory@example.com>",
    22 => "Confirm your new email address for Acme Agents",
    23 =>
      "You can change the email address of your Acme Agents account by visiting the URL below:",
    24 => "Your Acme Agents log-in link",
    25 => "You can log in to Acme Agents by visiting the URL below:",
    26 => "Confirm your Acme Agents account",
    27 => "You can confirm your Acme Agents account by visiting the URL below:",
    28 => "If you did not create an account on Acme Agents, ignore this email.",
    29 => "Your invitation to Acme Agents",
    30 =>
      "You are invited to join the organisation “Acme” on Acme Agents. You can accept the invitation by visiting the URL below:",
    31 => "Turn on mail for Acme Agents",
    32 =>
      "You saved the mail settings of Acme Agents. To turn mail on, visit the URL below while you are logged in as dana@example.com:"
  }

  @powered "Powered by Qory Apiary"

  # A workspace's set-up is finished: a link to it leads to its first page.
  setup do
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  # Another name of the product, as `Apiary.EditionStubs.AnotherName` has it, on a
  # workspace whose set-up is finished.
  defmodule AnotherNameFinished do
    @moduledoc false
    defdelegate product_name, to: Apiary.EditionStubs.AnotherName
    defdelegate test_run_passed?(workspace), to: Apiary.EditionStubs.SetUpFinished
  end

  setup %{tmp_dir: tmp_dir} do
    # The emails' sender, and docs that are not built.
    put_env(:mail_from, "qory@example.com")
    put_env(:docs_root, tmp_dir)
    :ok
  end

  defp put_env(key, value) do
    before = Application.fetch_env(:apiary, key)
    Application.put_env(:apiary, key, value)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:apiary, key, value)
        :error -> Application.delete_env(:apiary, key)
      end
    end)
  end

  # The name an instance admin set, written as the form writes it.
  defp put_name(name) do
    Repo.query!(
      """
      INSERT INTO instance_settings (id, product_name, updated_at) VALUES (true, $1, now())
      ON CONFLICT (id) DO UPDATE SET product_name = EXCLUDED.product_name
      """,
      [name]
    )
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp text(%LazyHTML{} = doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> squeeze()

  defp text(html, selector) when is_binary(html), do: text(doc(html), selector)

  defp attribute(html, selector, name) do
    case html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  defp squeeze(text), do: text |> String.split() |> Enum.join(" ")

  # The paragraph of an email's body that starts with `start`.
  defp paragraph(email, start) do
    email.text_body
    |> String.split("\n\n")
    |> Enum.map(&squeeze/1)
    |> Enum.find(&String.starts_with?(&1, start))
  end

  # Every place, read from the pages and emails, by its number; and where each of the
  # three "Powered by" lines shows.
  defp places(conn) do
    # Before set-up, before any other organisation: the set-up page's form.
    instance = Apiary.EditionKit.hide_instance_organisation()
    {:ok, _view, setup_form} = live(conn, ~p"/setup/#{Apiary.Setup.code!()}")
    not_set_up = ApiaryWeb.SetupLive.not_set_up_line()
    Apiary.EditionKit.show_instance_organisation(instance)
    Repo.query!("UPDATE instance_settings SET setup_code = NULL, set_up_at = now() WHERE id")

    # A signed-in person, an owner of Acme, on the runs of its workspace Main.
    %{user: owner, organisation: organisation, workspace: workspace} =
      Apiary.OrganisationsFixtures.sign_up_fixture(%{organisation_name: "Acme"})

    signed_in = log_in_user(build_conn(), owner)
    runs = signed_in |> get(~p"/#{organisation}/#{workspace}/runs") |> html_response(200)
    {:ok, people_view, _html} = live(signed_in, ~p"/#{organisation}/settings/people")
    {:ok, workspace_view, _html} = live(signed_in, ~p"/#{organisation}/#{workspace}")
    workspace_page = render(workspace_view)

    # The bar's menu, on a page with no sidebar.
    assigns = %{}

    bar =
      ~H"""
      <ApiaryWeb.Layouts.app flash={%{}} current_scope={nil}>
        <p>page</p>
      </ApiaryWeb.Layouts.app>
      """
      |> rendered_to_string()

    # The log-in page, with no mail: the password form.
    Apiary.Mail.put_test_source(:none)
    login = conn |> get(~p"/users/log-in") |> html_response(200)
    {:ok, login_view, _html} = live(conn, ~p"/users/log-in")
    login_forgot = login_view |> element("#login_forgot") |> render() |> text("p")
    Apiary.Mail.put_test_source(:env)

    # The log-in page where the instance offers a sign-up, which no core instance does.
    sign_up =
      render_component(&ApiaryWeb.UserLive.Login.render/1,
        flash: %{},
        current_scope: nil,
        sent_to: nil,
        form: Phoenix.Component.to_form(%{"email" => nil}, as: "user"),
        mail?: true,
        mode: :magic,
        password_missing: false,
        remember_me: true,
        trigger_submit: false,
        set_up?: true,
        sign_up?: true,
        page_title: "Log in",
        client: nil
      )

    home = conn |> get(~p"/") |> html_response(200)

    unconfirmed = unconfirmed_user_fixture()
    token = extract_user_token(&Apiary.Accounts.deliver_login_instructions(unconfirmed, &1))
    {:ok, _view, confirmation} = live(conn, ~p"/users/log-in/#{token}")

    {:ok, _view, expired} = live(conn, ~p"/users/password/not-a-token")
    {:ok, _view, set_up_already} = live(conn, ~p"/setup/any-code")
    docs = conn |> get(~p"/docs") |> html_response(404)

    emails = emails(owner)

    %{
      1 => attribute(runs, "title", "data-default"),
      2 => attribute(runs, "title", "data-suffix"),
      :people_title => page_title(people_view),
      3 => text(workspace_page, "#sidebar #brand-menu-button"),
      4 => attribute(workspace_page, "#sidebar #brand-menu-button", "aria-label"),
      5 => attribute(workspace_page, "#sidebar #brand-menu ul[role='menu']", "aria-label"),
      6 => text(login, "aside a[href='/'] span"),
      7 => attribute(login, "aside", "aria-label"),
      8 => login |> doc() |> LazyHTML.query("aside p") |> Enum.map(&squeeze(LazyHTML.text(&1))),
      9 => text(home, "main h1"),
      10 => text(confirmation, "main h1"),
      11 => text(login, "main h1"),
      12 => String.replace_prefix(login_forgot, "Forgot your password? ", ""),
      13 =>
        sign_up
        |> doc()
        |> LazyHTML.query("main p")
        |> Enum.map(&squeeze(LazyHTML.text(&1)))
        |> Enum.find(&String.ends_with?(&1, " Create an account"))
        |> String.replace_suffix(" Create an account", ""),
      14 => ApiaryWeb.UserLive.Password.refused_line(),
      15 => ApiaryWeb.UserLive.Password.refused_line(),
      16 => text(expired, "main h1 + p"),
      17 =>
        setup_form |> doc() |> LazyHTML.query("main h1") |> Enum.map(&squeeze(LazyHTML.text(&1))),
      18 => text(set_up_already, "#setup-done h1"),
      19 => not_set_up,
      20 => text(docs, "main a[href='/']")
    }
    |> Map.merge(emails.places)
    |> Map.put(:powered, %{
      sidebar: text(workspace_page, "#sidebar #powered-by"),
      sidebar_menu: text(workspace_page, "#sidebar #brand-menu-powered"),
      bar_menu: text(bar, "#top-bar #brand-menu-powered"),
      bar_foot: count(bar, "#powered-by"),
      log_in: text(login, "main #powered-by"),
      pages:
        Enum.map([home, confirmation, expired, set_up_already, docs], &text(&1, "#powered-by")),
      emails: emails.powered
    })
    |> Map.put(
      :links,
      count(workspace_page <> login <> bar, "#powered-by a, #brand-menu-powered a")
    )
  end

  # The emails' places, and each email's last line.
  defp emails(owner) do
    user = %{owner | email: "dana@example.com"}
    unconfirmed = %{user | confirmed_at: nil}
    organisation = %Apiary.Organisations.Organisation{name: "Acme"}

    {:ok, change} = UserNotifier.deliver_update_email_instructions(user, "http://x/change")
    {:ok, link} = UserNotifier.deliver_login_instructions(user, "http://x/link")
    {:ok, confirm} = UserNotifier.deliver_login_instructions(unconfirmed, "http://x/confirm")
    {:ok, invitation} = UserNotifier.deliver_invitation(user.email, organisation, "http://x/i")

    {:ok, mail_test} =
      UserNotifier.deliver_mail_test_link(user, "http://x/mail", Apiary.Mail.env(), nil)

    all = [change, link, confirm, invitation, mail_test]
    {name, address} = change.from

    %{
      places: %{
        21 => "#{name} <#{address}>",
        22 => change.subject,
        23 => paragraph(change, "You can change"),
        24 => link.subject,
        25 => paragraph(link, "You can log in"),
        26 => confirm.subject,
        27 => paragraph(confirm, "You can confirm"),
        28 => paragraph(confirm, "If you did not create"),
        29 => invitation.subject,
        30 => paragraph(invitation, "You are invited"),
        31 => mail_test.subject,
        32 => paragraph(mail_test, "You saved")
      },
      powered: %{
        from: Enum.uniq(Enum.map(all, & &1.from)),
        last_lines: Enum.map(all, &(&1.text_body |> String.trim_trailing() |> lines_end()))
      }
    }
  end

  # The last two lines of a body: the closing rule and what follows it.
  defp lines_end(body), do: body |> String.split("\n") |> Enum.take(-3)

  # The brand panel's line where the instance has `security`, else the other.
  defp security_line(lines) do
    if Apiary.Features.on?(:security), do: Enum.at(lines, 1), else: nil
  end

  @tag :feature_sets
  test "with no name set, every place reads as it always has, and none says Powered by",
       %{conn: conn} do
    places = places(conn)

    for n <- 1..32, n != 8, n != 17 do
      assert {n, places[n]} == {n, @before[n]}
    end

    assert @before[17] in places[17]
    if line = security_line(places[8]), do: assert(line == @before[8])

    # The whole title of a page, with no name set, ends as it always has.
    assert places.people_title == "People · Organisation settings · Acme · Qory Apiary"

    powered = places.powered
    assert powered.sidebar == ""
    assert powered.sidebar_menu == ""
    assert powered.bar_menu == ""
    assert powered.bar_foot == 0
    assert powered.log_in == ""
    assert Enum.all?(powered.pages, &(&1 == ""))
    assert powered.emails.from == [{"Qory Apiary", "qory@example.com"}]

    for last <- powered.emails.last_lines do
      assert List.last(last) == "=============================="
      refute Enum.join(last, "\n") =~ @powered
    end
  end

  @tag :feature_sets
  test "with no name set, where the edition names the product otherwise, only the menu's button shows that name",
       %{conn: conn} do
    :ok = Apiary.Edition.put_test_stub(AnotherNameFinished)
    places = places(conn)

    # The titles, the log-in pages and the emails keep Qory Apiary.
    for n <- 1..32, n not in [3, 4, 5, 8, 17] do
      assert {n, places[n]} == {n, @before[n]}
    end

    assert @before[17] in places[17]
    if line = security_line(places[8]), do: assert(line == @before[8])
    assert places.people_title == "People · Organisation settings · Acme · Qory Apiary"

    # The menu's button and its names show the edition's.
    assert places[3] == "Another Product"
    assert places[4] == "Another Product menu"
    assert places[5] == "Another Product"

    powered = places.powered
    assert powered.sidebar == ""
    assert powered.sidebar_menu == ""
    assert powered.log_in == ""
    assert Enum.all?(powered.pages, &(&1 == ""))
    assert powered.emails.from == [{"Qory Apiary", "qory@example.com"}]

    for last <- powered.emails.last_lines,
        do: assert(List.last(last) == "==============================")
  end

  @tag :feature_sets
  test "with a name set, every place reads it, and the three lines say Powered by Qory Apiary",
       %{conn: conn} do
    put_name("Acme Agents")
    places = places(conn)

    for n <- 1..32, n != 8, n != 17 do
      assert {n, places[n]} == {n, @renamed[n]}
    end

    assert @renamed[17] in places[17]
    if line = security_line(places[8]), do: assert(line == @renamed[8])
    assert places.people_title == "People · Organisation settings · Acme · Acme Agents"

    powered = places.powered
    # A: the sidebar's foot, under the menu's row; the menu's last line, which shows only
    # folded there, and on the bar, where the menu's last line is the one line.
    assert powered.sidebar == @powered
    assert powered.sidebar_menu == @powered
    assert powered.bar_menu == @powered
    assert powered.bar_foot == 0
    # B: under the form of every page with the brand panel.
    assert powered.log_in == @powered
    assert Enum.all?(powered.pages, &(&1 == @powered))
    # C: every email, a last line under the closing rule, and its from-name the name.
    assert powered.emails.from == [{"Acme Agents", "qory@example.com"}]

    for last <- powered.emails.last_lines do
      assert last == ["==============================", "", @powered]
    end

    # Plain text, never a link.
    assert places.links == 0

    # In the sidebar, the menu's line shows only folded, where the foot's does not.
    css = File.read!(Path.expand("../../assets/css/app.css", __DIR__))
    assert css =~ ~r/\.q-sidebar \.q-brand-powered-item \{\s*display: none;/

    assert css =~
             ~r/\[data-sidebar="collapsed"\] \.q-sidebar \.q-brand-powered-item \{\s*display: block;/

    assert css =~ ~r/\[data-sidebar="collapsed"\] \.q-brand-powered \{\s*display: none;/
  end

  test "a name of Qory Apiary, as an edition with another name keeps it, shows no Powered by",
       %{conn: conn} do
    put_name("Qory Apiary")
    places = places(conn)
    assert places[3] == "Qory Apiary"
    # A name set: the sentences name it.
    assert places[12] == "Ask an admin of Qory Apiary for a password link."
    assert places.powered.sidebar == ""
    assert places.powered.log_in == ""

    for last <- places.powered.emails.last_lines,
        do: assert(List.last(last) == "==============================")
  end

  test "a long name is whole in the title and the subject, and cut on the menu's button with the whole on hover",
       %{conn: conn} do
    long = String.duplicate("Acme Agents ", 10) |> String.trim()
    assert String.length(long) == 119
    put_name(long)
    places = places(conn)

    assert places.people_title == "People · Organisation settings · Acme · #{long}"
    assert places[24] == "Your #{long} log-in link"
    assert places[3] == long

    css = File.read!(Path.expand("../../assets/css/app.css", __DIR__))
    assert css =~ ~r/\.q-brand-name \{[^}]*overflow: hidden;[^}]*text-overflow: ellipsis;/
  end
end
