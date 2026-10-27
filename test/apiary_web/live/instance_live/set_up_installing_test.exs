defmodule ApiaryWeb.InstanceLive.SetUpInstallingTest do
  # The step of an adapter `QORY_INSTALLED_ADAPTERS` lists before the installer makes it,
  # on a fast set-up: a step from the first page, current there, that shows Qory Apiary is
  # adding it; the adapter's step once the installer makes it, while the page is open; to
  # come, not skipped, on the workspace set-up; skipped once the person passed it. Not
  # async: the names are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryWeb.SetUpSteps

  alias Apiary.Adapters
  alias ApiaryWeb.SetUpComponents

  @moduletag needs: :factory

  setup do
    saved = Application.fetch_env(:apiary, :installed_adapters)

    on_exit(fn ->
      case saved do
        {:ok, names} -> Application.put_env(:apiary, :installed_adapters, names)
        :error -> Application.delete_env(:apiary, :installed_adapters)
      end
    end)

    name = "tracker-#{System.unique_integer([:positive])}"
    Application.put_env(:apiary, :installed_adapters, [name])

    # Mail not set by the environment: the page has its mail step, after the adapter's.
    Apiary.Mail.put_test_source(:none)

    admin = instance_admin_scope()
    %{name: name, admin: admin, conn: log_in_user(build_conn(), admin.user)}
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

  defp shape(steps), do: Enum.map(steps, &{&1.id, &1.state})

  test "the first page is the adapter's step, which turns into its set-up once it is made",
       %{conn: conn, name: name} do
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up")

    assert [{"Your account", :done}, {^name, :current}, {"Mail", :to_come} | _] = steps(lv)
    assert has_element?(lv, "#set-up-installing-#{name} h2", name)

    assert words(lv, "#set-up-installing") ==
             "Qory Apiary is adding #{name}. This page shows how to set it up once it is added."

    assert has_element?(lv, "#set-up-skip-button")
    refute has_element?(lv, "#set-up-continue")
    refute has_element?(lv, "#set-up-what")

    # The installer's pass makes it, and the page gets a message once it commits.
    assert {:ok, adapter} = Adapters.install(instance_scope(), name)

    assert_patch(lv, ~p"/instance/set-up?step=#{adapter.public_id}")
    assert has_element?(lv, "#set-up-#{adapter.public_id} h2", adapter.name)
    assert words(lv, "#set-up-state") == "State:Not set up"
    assert has_element?(lv, "#set-up-blocked")
    refute has_element?(lv, "#set-up-installing")
    assert [{"Your account", :done}, {^name, :current} | _] = steps(lv)
  end

  test "its page is ?step= with its name, and Skip leads on to mail", %{conn: conn, name: name} do
    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{name}")
    assert has_element?(lv, "#set-up-installing")

    lv |> element("#set-up-skip-button") |> render_click()
    assert_patch(lv, ~p"/instance/set-up?step=mail")
    assert {name, :skipped, :link} in steps(lv)
  end

  test "steps_for/3 lists it from the first page; skipped only once the person passed it",
       %{admin: admin, name: name} do
    key = {:installing, name}

    assert [{:account, :done}, {^key, :current}, {:mail, _mail} | _] =
             shape(SetUpComponents.steps_for(admin, key))

    step = Enum.find(SetUpComponents.steps_for(admin, key), &(&1.id == key))

    assert %{label: ^name, group: :connect, note: nil} = step
    assert step.path == "/instance/set-up?step=#{name}"

    # Passed by ?step=mail: skipped.
    assert {key, :skipped} in shape(SetUpComponents.steps_for(admin, :mail))

    # On the workspace set-up, `/<org>/set-up`: to come, never skipped.
    assert [{:account, :done}, {^key, :to_come}, {:mail, _} | _] =
             shape(SetUpComponents.steps_for(admin, :source))

    # On the set-up link's page, signed out: listed, with no page yet.
    assert %{id: ^key, label: ^name, path: nil} =
             Enum.find(SetUpComponents.steps_for(nil, :account, first: true), &(&1.id == key))
  end

  test "once made, the adapter's step takes its place, and ?step= with the name finds it",
       %{admin: admin, conn: conn, name: name} do
    {:ok, adapter} = Adapters.install(instance_scope(), name)
    key = {:adapter, adapter.public_id}

    assert [{:account, :done}, {^key, :current} | _] =
             shape(SetUpComponents.steps_for(admin, key))

    {:ok, lv, _html} = live(conn, ~p"/instance/set-up?step=#{name}")
    assert has_element?(lv, "#set-up-#{adapter.public_id}")
  end
end
