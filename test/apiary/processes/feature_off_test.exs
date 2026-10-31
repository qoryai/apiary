defmodule Apiary.Processes.FeatureOffTest do
  # On an instance without `workflow_model`, a workspace still has its first version, and
  # a change to its process is not found.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Processes
  alias Apiary.Processes.Version

  @moduletag with_features: Apiary.Features.all() -- [:workflow_model]

  test "a save is not found, and the workspace keeps its first version" do
    %{scope: scope} = sign_up_fixture()
    [explore | rest] = Processes.default_document("software")["stages"]

    document = %{
      Processes.default_document("software")
      | "stages" => [%{explore | "name" => "Plan"} | rest]
    }

    assert Processes.save(scope, scope.workspace, document) == {:error, :not_found}
    assert [%Version{number: 1, status: :current}] = Processes.list_versions(scope.workspace)
  end
end
