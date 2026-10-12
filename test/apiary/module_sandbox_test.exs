defmodule Apiary.ModuleSandboxTest do
  # A module's sandbox (`Apiary.DataCase.setup_module_sandbox/2`), which `cast: :module`
  # of `Apiary.AccessCase` and `ApiaryWeb.RefusalsCase` set up: what the module's
  # setup_all made, every test finds as it was made; what a test wrote, the next test does
  # not find. Not async, as no module with such a sandbox is.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations.Workspace

  setup_all context do
    Apiary.DataCase.setup_module_sandbox(context, fn ->
      # Set in setup_all's process, which no test is.
      Process.put(:made_in_setup_all, true)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoOwner)

      %{made: sign_up_fixture()}
    end)
  end

  describe "a test's writes" do
    # Each test writes, on its own process and on another, and changes what setup_all
    # made; whichever runs first, the other finds none of it.
    for n <- [1, 2] do
      @tag n: n
      test "are gone for the next test (#{n})", %{made: made, n: n} do
        other = 3 - n

        assert Repo.get!(Workspace, made.workspace.id).name == made.workspace.name
        refute Repo.exists?(from w in Workspace, where: like(w.name, ^"Written by #{other}%"))

        workspace_fixture(made.organisation, "Written by #{n}")

        Task.async(fn -> workspace_fixture(made.organisation, "Written by #{n} in a task") end)
        |> Task.await()

        {1, _} =
          Repo.update_all(from(w in Workspace, where: w.id == ^made.workspace.id),
            set: [name: "Renamed by #{n}"]
          )

        assert Repo.aggregate(
                 from(w in Workspace, where: like(w.name, ^"Written by #{n}%")),
                 :count
               ) == 2
      end
    end

    test "inside a transaction that rolls back are gone at once", %{made: made} do
      assert {:error, :undone} =
               Repo.transaction(fn ->
                 workspace_fixture(made.organisation, "Undone")
                 Repo.rollback(:undone)
               end)

      refute Repo.exists?(from w in Workspace, where: w.name == "Undone")
      assert Repo.get!(Workspace, made.workspace.id).name == made.workspace.name
    end
  end

  describe "what lives in a process" do
    test "setup_all's own is not the test's", %{made: made} do
      assert Process.get(:made_in_setup_all) == nil

      assert Apiary.Edition.level_refusal(made.scope, made.organisation, :owner, []) ==
               Apiary.Edition.module().level_refusal(made.scope, made.organisation, :owner, [])
    end
  end

  describe "a stub a test sets in its setup" do
    setup do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoOwner)
      Process.put(:set_in_setup, true)
      :ok
    end

    test "is seen in the test's process and the processes it starts", %{made: made} do
      assert Process.get(:set_in_setup)
      assert Apiary.Edition.level_refusal(made.scope, made.organisation, :owner, []) == :no_owner

      assert Task.async(fn ->
               Apiary.Edition.level_refusal(made.scope, made.organisation, :owner, [])
             end)
             |> Task.await() == :no_owner
    end
  end

  describe "a test under other features" do
    test "raises: what setup_all made, it made under the module's" do
      assert_raise ArgumentError, ~r/cast: :test/, fn ->
        Apiary.DataCase.setup_sandbox(%{
          test: :"a test",
          with_features: [:observability],
          module_sandbox: %{owner: self(), features: Enum.sort(Apiary.Features.all())}
        })
      end
    end
  end
end

defmodule Apiary.ModuleSandboxFeaturesTest do
  # What a module's setup_all makes, it makes under the module's features, as a test's
  # own setup does under the test's.
  use Apiary.DataCase, async: false

  @moduletag with_features: [:observability]

  setup_all context do
    Apiary.DataCase.setup_module_sandbox(context, fn ->
      %{made_under: Apiary.Features.enabled()}
    end)
  end

  test "setup_all made it under the module's features, which the test runs under", ctx do
    assert Enum.sort(ctx.made_under) == Enum.sort(Apiary.Features.enabled())
    assert Enum.sort(ctx.made_under) != Enum.sort(Apiary.Features.all())
  end
end
