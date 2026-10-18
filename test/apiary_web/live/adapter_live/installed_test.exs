defmodule ApiaryWeb.AdapterLive.InstalledTest do
  # The pages of an adapter installed with Qory Apiary, for an instance admin: the line
  # under its name, its Overview with no key yet, its Access key tab without a key and with
  # one, which offers no command and shows no code of the instance, the refusal of a Get
  # the command asked anyway, the revocation of its only key, its key card, and its danger
  # zone and Remove page, while it is listed and once it is not; with its name off the
  # list, its Overview and its Access key tab say it is turned off there, and promise no
  # code, a Get the command asked anyway is refused with that, neither page offers Set up,
  # and a Set up posted anyway is refused, with no pass and no entry. Not async: the names
  # listed are the whole node's.
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

  test "the line under its name and its Overview with no key yet", %{conn: conn, adapter: adapter} do
    {:ok, lv, _html} = live(conn, page_path(adapter))

    assert words(lv, "#adapter-meta") ==
             "Installed with Qory Apiary, #{Format.date(adapter.inserted_at)} · #{adapter.public_id}"

    assert words(lv, "#adapter-overview-state") ==
             "No key yet · it connects by itself once it is running"

    refute has_element?(lv, "#adapter-connect-it")
  end

  describe "the Access key tab" do
    test "with no key, says so, offers no command, and shows no code of the instance",
         %{conn: conn, adapter: adapter} do
      assert {:ok, _failures} = Installer.pass()
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))

      assert words(lv, "#adapter-connect-intro") ==
               "This adapter is installed with Qory Apiary. While it has no key, Qory Apiary gives it a one-time code by itself, and it makes its key with it. You don't run a command."

      refute has_element?(lv, "#adapter-way")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, ~s{[id^="code-"]})
      refute has_element?(lv, "#adapter-add")
    end

    test "a Get the command asked anyway is refused, and said so", %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))
      render_click(lv, "create_code", %{})

      assert render(lv) =~ "Qory Apiary gives this adapter its codes itself."
      refute render(lv) =~ "it gets no new code until it is turned on again"

      assert Apiary.Repo.all(Apiary.AccessKeys.EnrolmentCode)
             |> Enum.all?(&(&1.node_id != adapter.id))
    end

    test "with its key: no way to add one, the key card, and the revocation of its only key",
         %{conn: conn, adapter: adapter} do
      %{access_key: key} = installed_key_fixture(adapter)
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))

      assert words(lv, "#adapter-add-intro") ==
               "An adapter installed with Qory Apiary holds one key. To replace it, revoke it: the adapter gets a new code at once and makes a new key by itself."

      refute has_element?(lv, "#code-new-button")

      assert words(lv, "#key-#{key.key_id}-added") ==
               "Connected by itself, with a code from Qory Apiary, #{Format.datetime(key.received_at)}"

      assert words(lv, "#key-#{key.key_id}-secret") ==
               "On #{adapter.name}, saved there by the adapter"

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

    test "the Overview says it is turned off there and can be removed",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") ==
               "No key yet · turned off where Qory Apiary is installed; it can be removed"

      refute html =~ "it connects by itself once it is running"
      refute has_element?(lv, "#adapter-connect-it")
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
               "Add a key Turn it on again where Qory Apiary is installed to give it a new key."

      refute html =~ "the adapter gets a new code at once"
      refute has_element?(lv, "#adapter-way")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#adapter-add button")

      {:ok, lv, html} = live(conn, page_path(adapter, "/keys/#{key.key_id}/revoke"))

      assert words(lv, "#key-#{key.key_id}-last") ==
               "It is the adapter's only key. The adapter is turned off where Qory Apiary is installed, so it gets no new code: until it is turned on again, nothing it sends reaches any organisation."

      refute html =~ "gives the adapter a new code at once"
    end

    test "a Get the command asked anyway is refused, saying it gets no new code until it is turned on again",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/keys"))
      render_click(lv, "create_code", %{})
      html = render(lv)

      assert html =~
               "This adapter is turned off where Qory Apiary is installed; it gets no new code until it is turned on again."

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
    test "while listed, the danger zone says to turn it off first, and a removal is refused",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

      assert words(lv, "#adapter-remove-listed") ==
               "Installed with Qory Apiary. To remove it, first turn it off where Qory Apiary is installed; then it can be removed here."

      refute has_element?(lv, "#adapter-remove-link")

      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/remove"))
      lv |> element("#adapter-remove-button") |> render_click()
      assert_patch(lv, page_path(adapter, "/settings"))
      assert render(lv) =~ "Turn it off where Qory Apiary is installed before you remove it."
      assert Apiary.Repo.reload!(adapter).deleted_at == nil
    end

    test "turned off, it is removed, the Remove page saying what stays",
         %{conn: conn, adapter: adapter} do
      list([])
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))
      refute has_element?(lv, "#adapter-remove-listed")
      assert has_element?(lv, "#adapter-remove-link")

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
  end
end
