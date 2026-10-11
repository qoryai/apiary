defmodule ApiaryWeb.AccessTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation

  # An edition that says who adds a node in its own words, and leaves every other
  # sentence, and every other callback, to the core.
  defmodule NodesEdition do
    use ApiaryWeb.Edition

    @impl true
    def who_may_sentence(:"node.create", %Scope{organisation: %Organisation{name: name}}),
      do: "In #{name}, someone else adds the nodes."

    def who_may_sentence(_about, _scope), do: nil
  end

  defp socket(scope),
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_scope: scope}}

  test "a member of the workspace mounts the page" do
    %{scope: owner} = sign_up_fixture()
    %{scope: member} = member_fixture(owner, :member)

    socket = socket(member)
    assert {:cont, ^socket} = ApiaryWeb.Access.on_mount(:"run.read", %{}, %{}, socket)
  end

  test "a scope without a membership there is a path that does not exist" do
    %{organisation: organisation, workspace: workspace} = sign_up_fixture()
    %{user: stranger} = sign_up_fixture()

    scope = %Scope{user: stranger, organisation: organisation, workspace: workspace}

    assert_raise ApiaryWeb.NotFound, fn ->
      ApiaryWeb.Access.on_mount(:"run.read", %{}, %{}, socket(scope))
    end
  end

  describe "who may take an action" do
    setup do
      %{scope: %Scope{organisation: %Organisation{name: "Acme"}}}
    end

    test "is the core's sentence where the edition has none", %{scope: scope} do
      default = "Only owners and admins add nodes."

      assert ApiaryWeb.Access.who_may(ApiaryWeb.Edition.Core, scope, :"node.create", default) ==
               default
    end

    test "is the edition's sentence where it has one, and the core's elsewhere",
         %{scope: scope} do
      assert ApiaryWeb.Access.who_may(
               NodesEdition,
               scope,
               :"node.create",
               "Only owners and admins add nodes."
             ) == "In Acme, someone else adds the nodes."

      assert ApiaryWeb.Access.who_may(
               NodesEdition,
               scope,
               :"node.delete",
               "Only owners and admins delete nodes."
             ) == "Only owners and admins delete nodes."

      assert NodesEdition.product_name() == ApiaryWeb.Edition.Core.product_name()
    end

    # Each page asks with an action of `Apiary.Access`, or a subject the callback names:
    # one it names nowhere would never be answered.
    test "is asked of an action, or of a subject the edition's callback names" do
      subjects = [:people, :workspaces]
      actions = Apiary.Access.actions()

      asked =
        for path <- Path.wildcard(Path.join(Path.expand("../../lib", __DIR__), "**/*.ex")),
            [_call, about] <-
              Regex.scan(~r/who_may\(\s*[^,()]+,\s*(:"[^"]+"|:[a-z_]+)/, File.read!(path)),
            do: {path, about |> String.trim_leading(":") |> String.trim("\"") |> String.to_atom()}

      assert length(asked) > 10

      for {path, about} <- asked do
        assert about in subjects or about in actions,
               "#{path} asks who may take #{inspect(about)}, no action or subject"
      end
    end
  end
end
