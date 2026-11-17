defmodule ApiaryProWeb.OperatedArtifactTypesTest do
  # The line under the Artifact types table for a type that the harness sets, in a
  # workspace that an operator operates: the organisation's owners and admins read to ask
  # the operator, and the operator's people read the step in Harness settings.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Artifacts, Features, Processes}
  alias Apiary.Repo
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  @line "#artifact-type-submission-set-by-harness"
  @operator_step "To change the schema, ask the operator of this workspace."
  @harness_step "To change the schema, change it in the harness, then choose Update from harness in Harness settings."

  # The workspace's process sets the type `submission`, as the Qory harness's does, and the
  # workspace has that type. The flag is on, so the operator's people change the process and
  # its artifact types there (`ApiaryPro.Flags.operator_infrastructure?/0`).
  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    operated = operated_fixture(operator.scope, "Acme")
    owner_scope = operated.owner.scope
    version = Processes.current(operated.workspace)
    submit = %{"type" => "submission", "send" => "end_of_run"}

    {1, _rows} =
      Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
        set: [template: Map.put(version.template || %{}, "submit", submit)]
      )

    Artifacts.type(operated.workspace, "submission") ||
      Artifacts.create_type(owner_scope, operated.workspace, %{
        "name" => "submission",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object"}
      })

    Flags.put_operator_infrastructure(true)
    %{operator: operator, operated: operated}
  end

  defp page(user, operated) do
    conn = log_in_user(build_conn(), user)
    live(conn, ~p"/#{operated.organisation}/#{operated.workspace}/settings/artifact-types")
  end

  test "the organisation's owner reads to ask the operator, with no link", ctx do
    {:ok, view, _html} = page(ctx.operated.owner.user, ctx.operated)

    assert has_element?(view, @line, @operator_step)
    refute has_element?(view, @line, "Update from harness")
    refute has_element?(view, "#{@line} a")
  end

  test "an admin of the organisation reads the same", ctx do
    admin = organisation_member_fixture(ctx.operated, :admin)
    {:ok, view, _html} = page(admin.user, ctx.operated)

    assert has_element?(view, @line, @operator_step)
    refute has_element?(view, "#{@line} a")
  end

  test "the operator's person reads the step in Harness settings", ctx do
    {:ok, view, _html} = page(ctx.operator.user, ctx.operated)

    assert has_element?(view, @line, @harness_step)
    refute has_element?(view, @line, "ask the operator")

    harness = ~p"/#{ctx.operated.organisation}/#{ctx.operated.workspace}/settings/harness"
    assert has_element?(view, ~s(#{@line} a[href="#{harness}"]), "Harness settings")
  end
end
