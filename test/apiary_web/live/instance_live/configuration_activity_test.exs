defmodule ApiaryWeb.InstanceLive.ConfigurationActivityTest do
  @moduledoc """
  A save of the instance's settings (`Apiary.InstanceConfig.save/3`) on the Activity page
  of the instance's organisation: its label in the Action filter, its sentence, and a line
  for each value it changed, as it was and as it is.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the environment's values are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.InstanceConfig

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  setup do
    # The variables, whatever the shell running the suite set: none.
    for key <- InstanceConfig.keys() do
      previous = Application.fetch_env!(:apiary, key)
      Application.put_env(:apiary, key, nil)
      on_exit(fn -> Application.put_env(:apiary, key, previous) end)
    end

    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  setup :register_and_log_in_user

  test "says the change, and each value before and after", %{conn: conn, scope: scope} do
    admin = put_in(scope.user.authenticated_at, DateTime.utc_now())

    {:ok, _} = InstanceConfig.save(admin, :retention, %{"audit_retention_days" => "60"})
    {:ok, _} = InstanceConfig.save(admin, :deletion, %{"deletion_grace_days" => "1"})
    {:ok, _} = InstanceConfig.save(admin, :invitations, %{"invitations_per_day" => "1500"})

    {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
    render_async(view)

    {:ok, %{entries: [invitations, deletion, retention | _]}} =
      Apiary.Audit.list_entries(scope, %{action: "instance.configure"})

    assert has_element?(view, "#filter-action-form li", "Configuration changed")

    for entry <- [retention, deletion, invitations] do
      assert text(view, "#entry-#{entry.id}-action") =~ "Changed the instance's configuration"
      assert text(view, "#entry-#{entry.id}-actor") =~ scope.user.email
    end

    # One line for each value.
    lines =
      view
      |> element("#entry-#{retention.id}-change")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("li, div, span")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert "Audit log entries: 90 days → 60 days" in lines
    assert "IP addresses in the audit log: 90 days → 60 days" in lines

    assert text(view, "#entry-#{deletion.id}-change") == "Grace period: 30 days → 1 day"
    assert text(view, "#entry-#{invitations.id}-change") == "Invitations a day: 20 → 1,500"
  end
end
