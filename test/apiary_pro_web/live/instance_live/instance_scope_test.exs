defmodule ApiaryProWeb.InstanceLive.InstanceScopeTest do
  @moduledoc """
  The scope that Core's `on_mount {ApiaryWeb.Access, :instance}` assigns to the two
  Instance pages comes from `Apiary.Access.instance_scope/1`: `can?/3` of that scope runs no
  SELECT for an instance action on an organisation with its tenant in `edition`, however
  many rows a page lists.
  """
  # Not async: instance admins are owners of the suite's one instance organisation, and
  # the features are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Edition, Features}
  alias ApiaryPro.Tenants

  @moduletag with_features: Features.all()

  setup %{conn: conn} do
    admin = instance_admin_fixture()
    %{conn: log_in_user(conn, admin.user), admin: admin}
  end

  for path <- ["/instance/organisations", "/instance/accounts"] do
    test "#{path}: can? on an instance action runs no SELECT", ctx do
      {:ok, lv, _html} = live(ctx.conn, unquote(path))
      scope = :sys.get_state(lv.pid).socket.assigns.scope

      %{organisation: organisation, user: user} = sign_up_fixture()
      organisation = Tenants.put(organisation)

      # The count sees a SELECT.
      assert {id, 1} = selects(fn -> Edition.instance_organisation_id() end)
      assert id == scope.organisation.id

      for {action, subject} <- [
            {:"instance.read", scope.organisation},
            {:"instance.create_operator", scope.organisation},
            {:"instance.suspend_organisation", organisation},
            {:"instance.suspend_account", user},
            {:"account.password_link", user}
          ] do
        assert {true, 0} == selects(fn -> Access.can?(scope, action, subject) end),
               "#{action} ran a SELECT, or returned false"
      end
    end
  end

  # What `fun` returns, and how many SELECT statements it ran, counted through the repo's
  # query telemetry. A handler runs in the process that runs the query.
  defp selects(fun) do
    handler = "selects-#{System.unique_integer()}"
    Process.put(:selects, 0)
    :telemetry.attach(handler, [:apiary, :repo, :query], &__MODULE__.count_select/4, nil)

    try do
      {fun.(), Process.get(:selects)}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def count_select(_event, _measurements, %{query: query}, _config) do
    if query =~ ~r/^\s*SELECT\b/i,
      do: Process.put(:selects, Process.get(:selects, 0) + 1)
  end
end
