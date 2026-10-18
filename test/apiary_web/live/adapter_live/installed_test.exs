defmodule ApiaryWeb.AdapterLive.InstalledTest do
  # The pages of an adapter installed with Qory Apiary, for an instance admin: the line
  # under its name; its Overview before its first start, not set up yet, with the Set it
  # up box, and set up, seen and not seen lately, with the Installed row; its Access key
  # tab without a key and with one, which offers no command, no Add a key, and shows no
  # code of the instance, the refusal of a Get the command asked anyway, the revocation of
  # its only key, its key card; its Settings' Remove while it is listed, and its danger
  # zone and Remove page once it is not; with its name off the list, its Overview says it
  # is turned off there, with a grey dot, its Access key tab promises no code, a Get the
  # command asked anyway is refused with that, neither page offers Set up, and a Set up
  # posted anyway is refused, with no pass and no entry. Anyone but an instance admin
  # meets Not Found. Not async: the names listed are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Adapters.Installer
  alias ApiaryWeb.Format

  @moduletag needs: :factory
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    saved =
      for key <- [:installed_adapters, :enrolment_dir_setting],
          do: {key, Application.fetch_env(:apiary, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end
    end)

    Application.put_env(:apiary, :enrolment_dir_setting, dir)
    name = "tracker-#{System.unique_integer([:positive])}"
    list([name])
    admin = instance_admin_scope()

    %{
      admin: admin,
      conn: log_in_user(build_conn(), admin.user),
      adapter: installed_adapter_fixture(name)
    }
  end

  defp list(names), do: Application.put_env(:apiary, :installed_adapters, names)

  @setup_url "https://tracker.example.com/setup"

  # The adapter declaring where to be set up, as it does until it is set up.
  defp declare_setup(adapter) do
    {1, _} =
      Apiary.Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.id),
        set: [setup_url: @setup_url]
      )

    Apiary.Repo.reload!(adapter)
  end

  # The adapter's first key, received an hour ago and revoked, then a key after it.
  defp replaced(adapter, admin) do
    %{access_key: old} = installed_key_fixture(adapter)

    {1, _} =
      Apiary.Repo.update_all(from(k in Apiary.AccessKeys.AccessKey, where: k.id == ^old.id),
        set: [received_at: DateTime.add(DateTime.utc_now(), -3600)]
      )

    {:ok, old} =
      Apiary.AccessKeys.revoke_access_key(admin, Apiary.Repo.reload!(old))

    %{access_key: new} = installed_key_fixture(adapter)
    {old, new}
  end

  # The key last used `seconds` ago, as an accepted request of the adapter records.
  defp used(key, seconds) do
    at = DateTime.add(DateTime.utc_now(:second), -seconds)

    {1, _} =
      Apiary.Repo.update_all(from(k in Apiary.AccessKeys.AccessKey, where: k.id == ^key.id),
        set: [last_used_at: at]
      )

    at
  end

  defp page_path(adapter, rest \\ ""), do: "/instance/adapters/#{adapter.public_id}" <> rest

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> String.replace(~r/<(p|div|h[1-6]|li|dt|dd|span)[\s>]/, " \\0")
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "the line under its name says it is installed with Qory Apiary, on every tab",
       %{conn: conn, adapter: adapter} do
    for rest <- ["", "/keys", "/settings"] do
      {:ok, lv, _html} = live(conn, page_path(adapter, rest))
      assert words(lv, "#adapter-meta") == "Installed with Qory Apiary · #{adapter.public_id}"
    end
  end

  describe "the Overview" do
    test "before its first start: no key yet, it enrols at its first start, and no Connect it",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") == "No key yet · it enrols at its first start"
      assert words(lv, "#adapter-overview-installed") == "With Qory Apiary"
      refute has_element?(lv, "#adapter-enrolled")
      refute has_element?(lv, "#adapter-connect-it")
      refute has_element?(lv, "#adapter-setup-box")
      refute html =~ "organisations can install it once it is connected and running"
    end

    test "not set up yet: the Set it up box, with Set up and the address it opens, in place of the Set-up row",
         %{conn: conn, adapter: adapter} do
      installed_key_fixture(adapter)
      adapter = declare_setup(adapter)
      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-setup-box") ==
               "Set it up Until it is set up, organisations can't install it. Set up Opens #{@setup_url}"

      form = element(lv, "#adapter-setup-box #adapter-setup")
      assert render(form) =~ ~s(action="/instance/adapters/#{adapter.public_id}/setup")
      assert render(form) =~ ~s(method="post")
      assert render(form) =~ ~s(name="_csrf_token")
      refute render(form) =~ ~s(name="back")
      assert has_element?(lv, "#adapter-setup-box #adapter-setup-button.btn-primary")

      # Above the rows, which hold no Set-up row and no hint of the adapter deployed
      # apart.
      [before, _after] = String.split(html, ~s(id="adapter-overview"), parts: 2)
      assert before =~ ~s(id="adapter-setup-box")
      refute has_element?(lv, "#adapter-overview-setup")
      refute has_element?(lv, "#adapter-setup-hint")
      refute html =~ "Takes you to the adapter"
      refute html =~ "Replace"
    end

    test "set up and seen: no box; its state, and when its key was enrolled",
         %{conn: conn, adapter: adapter} do
      %{access_key: key} = installed_key_fixture(adapter)
      at = used(key, 60)
      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") == "Last seen #{Format.relative(at)}"

      assert words(lv, "#adapter-overview-installed") ==
               "With Qory Apiary · Enrolled at its first start, #{Format.datetime(key.received_at)}"

      refute has_element?(lv, "#adapter-setup-box")
      refute has_element?(lv, "#adapter-overview-setup")
      refute has_element?(lv, "#adapter-setup")
      refute html =~ "it enrols at its first start"
      refute html =~ "Replace"
    end

    test "with no key once its key was revoked: it connects by itself once it is running, and no Connect it",
         %{conn: conn, adapter: adapter, admin: admin} do
      %{access_key: key} = installed_key_fixture(adapter)
      {:ok, _} = Apiary.AccessKeys.revoke_access_key(admin, key)
      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") ==
               "No key yet · it connects by itself once it is running"

      refute html =~ "it enrols at its first start"
      refute has_element?(lv, "#adapter-connect-it")
      assert words(lv, "#adapter-overview-installed") == "With Qory Apiary"
    end

    test "with a key after a revoked one: the Installed row says it connected by itself",
         %{conn: conn, adapter: adapter, admin: admin} do
      {_old, new} = replaced(adapter, admin)
      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-installed") ==
               "With Qory Apiary · Connected by itself, with a code from Qory Apiary, #{Format.datetime(new.received_at)}"

      refute html =~ "Enrolled at its first start"
    end

    test "set up and not seen lately: its state keeps its words, with when it was last seen",
         %{conn: conn, adapter: adapter} do
      %{access_key: key} = installed_key_fixture(adapter)
      at = used(key, 3 * 3600)
      {:ok, lv, _html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") == "Last seen #{Format.relative(at)}"
      refute has_element?(lv, "#adapter-state.q-sdot")
    end
  end

  describe "the Access key tab" do
    test "with no key, says so, offers no command, and shows no code of the instance",
         %{conn: conn, adapter: adapter} do
      assert {:ok, _failures} = Installer.pass()
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))

      assert words(lv, "#adapter-connect-intro") ==
               "This adapter is installed with Qory Apiary. While it has no key, Qory Apiary gives it a one-time code by itself, and it makes its key with it. No command is run."

      refute has_element?(lv, "#adapter-way")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, ~s{[id^="code-"]})
      refute has_element?(lv, "#adapter-add")
    end

    test "with a key after a revoked one: no first-start sentence, the cards say how each came",
         %{conn: conn, adapter: adapter, admin: admin} do
      {old, new} = replaced(adapter, admin)
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))

      refute has_element?(lv, "#adapter-keys-installed")

      assert words(lv, "#adapter-keys-revoking") ==
               "Revoking it makes the adapter enrol again with a new key."

      assert words(lv, "#key-#{new.key_id}-added") ==
               "Connected by itself, with a code from Qory Apiary, #{Format.datetime(new.received_at)}"

      assert words(lv, "#key-#{old.key_id}-added") ==
               "Enrolled at its first start, #{Format.datetime(old.received_at)}"

      assert words(lv, "#key-#{new.key_id}-secret") == "Kept by the adapter; never shown"
    end

    test "a Get the command asked anyway is refused, and said so", %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))
      render_click(lv, "create_code", %{})

      assert render(lv) =~ "Qory Apiary gives this adapter its codes itself."
      refute render(lv) =~ "it gets no new code until it is turned on again"

      assert Apiary.Repo.all(Apiary.AccessKeys.EnrolmentCode)
             |> Enum.all?(&(&1.node_id != adapter.id))
    end

    test "with its key: how it came, no Add a key, the key card, and the revocation of its only key",
         %{conn: conn, adapter: adapter} do
      %{access_key: key} = installed_key_fixture(adapter)
      {:ok, lv, html} = live(conn, page_path(adapter, "/keys"))

      assert words(lv, "#adapter-keys-installed") ==
               "The adapter made this key at its first start, and enrolled with a code that Qory Apiary handed it. No command was run."

      assert words(lv, "#adapter-keys-revoking") ==
               "Revoking it makes the adapter enrol again with a new key."

      refute has_element?(lv, "#adapter-add")
      refute has_element?(lv, "#code-new-button")
      refute html =~ "Get the command"
      refute html =~ "Replace"

      assert words(lv, "#key-#{key.key_id}-added") ==
               "Enrolled at its first start, #{Format.datetime(key.received_at)}"

      assert words(lv, "#key-#{key.key_id}-secret") == "Kept by the adapter; never shown"

      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys/#{key.key_id}/revoke"))

      assert words(lv, "#key-#{key.key_id}-last") ==
               "It is the adapter's only key. Qory Apiary gives the adapter a new code at once; until it has made a new key, nothing it sends reaches any organisation."
    end
  end

  describe "with its name off the list" do
    setup %{adapter: adapter} do
      list([])
      refute Apiary.Adapters.listed?(adapter)
      :ok
    end

    test "the Overview says it is turned off in the AWS stack or the Compose file, with a grey dot and when it was last seen",
         %{conn: conn, adapter: adapter} do
      %{access_key: key} = installed_key_fixture(adapter)
      at = used(key, 2 * 86_400)
      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") ==
               "Turned off in the AWS stack or the Compose file · Last seen #{Format.relative(at)}"

      assert has_element?(lv, ~s{#adapter-state[class~="q-sdot"] > i[aria-hidden="true"]})
      # Its words wrap where the line is narrow, rather than run past it.
      assert has_element?(lv, ~s{#adapter-state[class~="!whitespace-normal"]})
      refute has_element?(lv, ~s{#adapter-state[class*="q-sdot-"]})
      refute has_element?(lv, "#adapter-setup-box")
      refute html =~ "it enrols at its first start"
      refute has_element?(lv, "#adapter-connect-it")
    end

    test "the Overview, with no key, says only that it is turned off there",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") ==
               "Turned off in the AWS stack or the Compose file"

      assert words(lv, "#adapter-overview-installed") == "With Qory Apiary"
    end

    test "the Access key tab, with no key, says it gets no new code until it is turned on again",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, html} = live(conn, page_path(adapter, "/keys"))

      assert words(lv, "#adapter-connect-intro") ==
               "This adapter was installed with Qory Apiary and is turned off there. Qory Apiary gives it no new code until it is turned on again."

      refute html =~ "gives it a one-time code by itself"
      refute has_element?(lv, "#adapter-way")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#adapter-add")
    end

    test "the Access key tab, with its key, offers no way to add one, and its only key's revocation promises no code",
         %{conn: conn, adapter: adapter} do
      %{access_key: key} = installed_key_fixture(adapter)
      {:ok, lv, html} = live(conn, page_path(adapter, "/keys"))

      assert words(lv, "#adapter-add") ==
               "Add a key Turn it on again in the AWS stack or the Compose file to give it a new key."

      assert has_element?(lv, "#adapter-keys-installed")
      refute has_element?(lv, "#adapter-keys-revoking")
      refute html =~ "the adapter gets a new code at once"
      refute has_element?(lv, "#adapter-way")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#adapter-add button")

      {:ok, lv, html} = live(conn, page_path(adapter, "/keys/#{key.key_id}/revoke"))

      assert words(lv, "#key-#{key.key_id}-last") ==
               "It is the adapter's only key. The adapter is turned off in the AWS stack or the Compose file, so it gets no new code: until it is turned on again, nothing it sends reaches any organisation."

      refute html =~ "gives the adapter a new code at once"
    end

    test "a Get the command asked anyway is refused, saying it gets no new code until it is turned on again",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))
      render_click(lv, "create_code", %{})
      html = render(lv)

      assert html =~
               "This adapter is turned off in the AWS stack or the Compose file; it gets no new code until it is turned on again."

      refute html =~ "Qory Apiary gives this adapter its codes itself."

      assert Apiary.Repo.all(Apiary.AccessKeys.EnrolmentCode)
             |> Enum.all?(&(&1.node_id != adapter.id))
    end

    test "a Set up posted anyway is refused: nothing to set up, no pass, no entry",
         %{conn: conn, adapter: adapter, admin: admin} do
      installed_key_fixture(adapter)

      {1, _} =
        Apiary.Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.id),
          set: [setup_url: "https://tracker.example.com/setup"]
        )

      adapter = Apiary.Repo.reload!(adapter)
      assert Apiary.Adapters.setup(admin, adapter) == {:error, :unlisted}

      for {params, back} <- [
            {%{}, page_path(adapter)},
            {%{"back" => "list"}, "/instance/adapters"}
          ] do
        sent = post(conn, page_path(adapter, "/setup"), params)
        assert redirected_to(sent) == back
        refute sent.resp_body =~ "state="
        refute sent.resp_body =~ "http-equiv"

        assert Phoenix.Flash.get(sent.assigns.flash, :error) ==
                 "This adapter has nothing to set up now."
      end

      assert Apiary.Repo.aggregate(
               from(e in Apiary.Audit.Entry, where: e.action == "adapter.setup"),
               :count
             ) == 0

      # Listed again, it is set up as any adapter is.
      list([adapter.installed_as])
      sent = post(conn, page_path(adapter, "/setup"))
      assert sent.status == 200
      assert sent.resp_body =~ "https://tracker.example.com/setup?state="
    end

    test "with a setup_url and its key, neither the Overview nor the list offers Set up",
         %{conn: conn, adapter: adapter} do
      installed_key_fixture(adapter)

      {1, _} =
        Apiary.Repo.update_all(
          from(n in Apiary.Nodes.Node, where: n.id == ^adapter.id),
          set: [setup_url: "https://tracker.example.com/setup"]
        )

      {:ok, lv, html} = live(conn, page_path(adapter))
      assert words(lv, "#adapter-overview-setup") == "Not set up yet"
      refute has_element?(lv, "#adapter-setup")
      refute html =~ "Takes you to the adapter"

      {:ok, lv, _html} = live(conn, "/instance/adapters")
      refute has_element?(lv, "#adapter-#{adapter.public_id}-setup")

      # Listed again, both offer it.
      list([adapter.installed_as])
      {:ok, lv, _html} = live(conn, page_path(adapter))
      assert has_element?(lv, "#adapter-setup")
      {:ok, lv, _html} = live(conn, "/instance/adapters")
      assert has_element?(lv, "#adapter-#{adapter.public_id}-setup")
    end
  end

  describe "removing it" do
    test "while listed, Remove says to turn it off in the AWS stack or the Compose file, with no danger zone, and a removal is refused",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, html} = live(conn, page_path(adapter, "/settings"))

      assert words(lv, "#adapter-remove-part") ==
               "Remove This adapter is installed with Qory Apiary. To remove it, turn it off in the AWS stack or the Compose file that installs Qory Apiary."

      refute has_element?(lv, "#adapter-danger")
      refute has_element?(lv, "#adapter-remove-link")
      refute html =~ "Danger zone"
      refute html =~ "Replace"

      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/remove"))
      lv |> element("#adapter-remove-button") |> render_click()
      assert_patch(lv, page_path(adapter, "/settings"))

      assert render(lv) =~
               "Turn it off in the AWS stack or the Compose file before you remove it."

      assert Apiary.Repo.reload!(adapter).deleted_at == nil
    end

    test "turned off, it is removed, the Remove page saying what stays",
         %{conn: conn, adapter: adapter} do
      list([])
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))
      refute has_element?(lv, "#adapter-remove-part")

      assert words(lv, "#adapter-danger") ==
               "Danger zone Remove this adapter Its keys are revoked, and every organisation's installation of it ends. This cannot be undone. Remove adapter…"

      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/remove"))

      assert words(lv, "#adapter-remove-installed") ==
               "Whatever it kept where Qory Apiary is installed is not touched."

      lv |> element("#adapter-remove-button") |> render_click()
      assert_redirect(lv, "/instance/adapters")
      assert Apiary.Repo.reload!(adapter).deleted_at
    end
  end

  test "an adapter an instance admin added says none of it", %{conn: conn} do
    adapter = adapter_fixture()
    {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/remove"))
    refute has_element?(lv, "#adapter-remove-installed")
    {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))
    assert has_element?(lv, "#code-new-button")
    refute render(lv) =~ "installed with Qory Apiary"
    refute has_element?(lv, "#adapter-keys-installed")

    {:ok, lv, html} = live(conn, page_path(adapter))
    assert words(lv, "#adapter-meta") =~ ~r/^Added by .+, .+ · #{adapter.public_id}$/
    assert has_element?(lv, "#adapter-connect-it")
    refute has_element?(lv, "#adapter-overview-installed")
    refute html =~ "Installed with Qory Apiary"
    refute html =~ "it enrols at its first start"

    {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))
    assert has_element?(lv, "#adapter-danger #adapter-remove-link")
    refute has_element?(lv, "#adapter-remove-part")
  end

  test "an adapter deployed apart that can be set up keeps its Set-up row, with no box",
       %{conn: conn} do
    %{adapter: adapter} = settable_adapter_fixture()
    {:ok, lv, _html} = live(conn, page_path(adapter))

    assert words(lv, "#adapter-overview-setup") =~ "Not set up yet · Set up"
    assert has_element?(lv, "#adapter-overview-setup #adapter-setup")
    assert has_element?(lv, "#adapter-setup-hint")
    refute has_element?(lv, "#adapter-setup-box")
    refute has_element?(lv, "#adapter-setup-button.btn-primary")
  end

  test "anyone but an instance admin meets Not Found on its pages",
       %{adapter: adapter} do
    installed_key_fixture(adapter)
    declare_setup(adapter)
    %{user: owner} = sign_up_fixture()
    owner_conn = log_in_user(build_conn(), owner)

    for rest <- ["", "/keys", "/settings", "/settings/remove"] do
      assert_raise ApiaryWeb.NotFound, fn -> live(owner_conn, page_path(adapter, rest)) end
    end
  end
end
