defmodule Apiary.Harnesses.AddressesTest do
  # The addresses the instance sets for the Qory harness (`QORY_HARNESS_URL`,
  # `Apiary.Harnesses.Qory.git/0`) and for the built-in harness
  # (`QORY_BUILTIN_HARNESS_URL`, `Apiary.Harnesses.Builtin.git/0`): a row of the Qory
  # harness's choice reads the address set now, whatever address it was saved with. Not
  # async: the test changes the addresses (`Application.put_env/3`).
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Harnesses.{Builtin, FetchSource, Qory, Reader, Walk}
  alias Apiary.Policy.RequiredHosts
  alias Apiary.QoryHarnessFixture
  alias Apiary.Stacks.Sources

  @moduletag needs: :factory

  @mirror "https://code.example.com/mirror/harness"

  defp put_url!(module, url) do
    previous = Application.fetch_env!(:apiary, module)
    Application.put_env(:apiary, module, Keyword.put(previous, :url, url))
    on_exit(fn -> Application.put_env(:apiary, module, previous) end)
  end

  test "a row of the Qory harness saved before QORY_HARNESS_URL changed reads the new address" do
    %{scope: scope} = sign_up_fixture()
    {:ok, row} = Sources.choose(scope, :qory)
    assert {:ok, %{"extends" => %{"git" => saved}}} = Reader.document(row.harness)
    assert saved == "https://github.com/qoryai/harness"

    put_url!(Qory, @mirror)
    QoryHarnessFixture.serve!()

    assert %{choice: :qory, git: @mirror} = Sources.chosen(scope.workspace)

    assert %{rows: [%{host: "code.example.com", source: :qory, required_by: :instance}]} =
             RequiredHosts.harness(scope.workspace)

    assert FetchSource.of("code.example.com", [%{"git" => @mirror}], false, false, :resolved) ==
             [:qory]

    assert {:ok, %{document: %{"extends" => %{"git" => @mirror, "ref" => "main"}}}} =
             Walk.run(%{
               organisation: scope.organisation,
               workspace: scope.workspace,
               target: nil,
               workflow: "explore-a-ticket"
             })
  end

  test "the built-in harness is at the address QORY_BUILTIN_HARNESS_URL sets" do
    put_url!(Builtin, "https://code.example.com/mirror/qory")

    assert Builtin.document()["extends"]["git"] == "https://code.example.com/mirror/qory"

    assert Keyword.fetch!(Builtin.walked(), :pins) == [
             %{"git" => "https://code.example.com/mirror/qory", "ref" => "main", "at" => "main"}
           ]
  end
end
