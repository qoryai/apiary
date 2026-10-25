defmodule Apiary.Harnesses.AllowedTest do
  # The rule that decides which links a run may use for its harness: (a) the run's
  # organisation's links; (b) the instance's links, for a source an instance assignment
  # covers; (c) the edition's answer, which is false in the core. The assignments are
  # written as rows here: `test/apiary/harnesses_test.exs` tests who may write them.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, Harnesses}
  alias Apiary.Harnesses.Assignment

  @git "https://code.example.com/team/stacks"
  @root %{"git" => @git, "ref" => "v1"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    instance = Edition.instance_organisation_id()
    refute instance in [scope.organisation.id, other.organisation.id]

    %{run: scope.organisation.id, other: other.organisation.id, instance: instance}
  end

  defp assign!(source, organisation_id) do
    Repo.insert!(%Assignment{
      source: source,
      organisation_id: organisation_id,
      every_organisation: is_nil(organisation_id)
    })
  end

  defp allowed?(ctx, owner, source), do: Harnesses.allowed?(ctx.run, owner, source)

  describe "(a) the run's organisation's link" do
    test "is allowed for any source, with no assignment", ctx do
      :ok = Edition.put_test_stub(Apiary.EditionStubs.HarnessSourceAllowed)

      for source <- [
            @root,
            Map.put(@root, "stack", "web"),
            %{"git" => "https://x.example", "ref" => "a"}
          ] do
        assert allowed?(ctx, ctx.run, source)
      end

      refute_received {:harness_source_allowed?, _run, _owner, _source}
    end
  end

  describe "(b) the instance's link" do
    test "is allowed for a source assigned to the run's organisation", ctx do
      source = Map.put(@root, "stack", "web")
      assign!(source, ctx.run)
      assert allowed?(ctx, ctx.instance, source)
    end

    test "is allowed for a source assigned to every organisation", ctx do
      source = Map.put(@root, "path", "stacks/web")
      assign!(source, nil)
      assert allowed?(ctx, ctx.instance, source)
      assert Harnesses.allowed?(ctx.other, ctx.instance, source)
    end

    test "is refused for a source assigned to another organisation alone", ctx do
      source = Map.put(@root, "stack", "web")
      assign!(source, ctx.other)
      refute allowed?(ctx, ctx.instance, source)
      assert Harnesses.allowed?(ctx.other, ctx.instance, source)
    end

    test "is refused for a source no assignment covers", ctx do
      refute allowed?(ctx, ctx.instance, @root)
    end

    test "is refused for a ref that differs", ctx do
      assign!(Map.put(@root, "stack", "web"), nil)
      assign!(Map.put(@root, "ref", "v2"), ctx.run)

      refute allowed?(ctx, ctx.instance, %{"git" => @git, "ref" => "v3", "stack" => "web"})
      refute allowed?(ctx, ctx.instance, %{"git" => @git, "ref" => "v1.0", "stack" => "web"})
      refute allowed?(ctx, ctx.instance, %{"git" => @git, "ref" => "V1", "stack" => "web"})
      assert allowed?(ctx, ctx.instance, %{"git" => @git, "ref" => "v1", "stack" => "web"})
    end

    test "is refused for another address", ctx do
      assign!(@root, nil)
      refute allowed?(ctx, ctx.instance, %{@root | "git" => @git <> ".git"})

      refute allowed?(ctx, ctx.instance, %{@root | "git" => "https://code.example.com/team/other"})
    end

    test "an assignment of a folder, an export or a module covers that one alone", ctx do
      assign!(Map.put(@root, "path", "stacks/web"), nil)
      assign!(Map.put(@root, "stack", "api"), nil)
      assign!(Map.put(@root, "module", "lint"), nil)

      for covered <- [
            Map.put(@root, "path", "stacks/web"),
            Map.put(@root, "stack", "api"),
            Map.put(@root, "module", "lint")
          ] do
        assert allowed?(ctx, ctx.instance, covered), inspect(covered)
      end

      for refused <- [
            @root,
            Map.put(@root, "path", "stacks/api"),
            Map.put(@root, "path", "stacks/web/inner"),
            Map.put(@root, "stack", "web"),
            Map.put(@root, "module", "api"),
            Map.put(@root, "path", "lint")
          ] do
        refute allowed?(ctx, ctx.instance, refused), inspect(refused)
      end
    end

    test "an assignment of a bare root allows that root's sources", ctx do
      assign!(@root, ctx.run)

      for source <- [
            @root,
            Map.put(@root, "path", "stacks/web"),
            Map.put(@root, "stack", "web"),
            Map.put(@root, "module", "lint")
          ] do
        assert allowed?(ctx, ctx.instance, source), inspect(source)
      end

      refute allowed?(ctx, ctx.instance, %{@root | "ref" => "v2"})
      refute Harnesses.allowed?(ctx.other, ctx.instance, @root)
    end

    test "an assignment allows nothing for a link of another organisation", ctx do
      assign!(@root, nil)
      refute allowed?(ctx, ctx.other, @root)
    end

    test "a source that is not a harness source is refused", ctx do
      assign!(@root, nil)
      refute allowed?(ctx, ctx.instance, %{git: @git, ref: "v1"})
      refute allowed?(ctx, ctx.instance, %{"git" => @git})
    end
  end

  describe "an organisation that is nil" do
    test "is refused, with no edition asked", ctx do
      :ok = Edition.put_test_stub(Apiary.EditionStubs.HarnessSourceAllowed)
      assign!(@root, nil)

      refute Harnesses.allowed?(ctx.run, nil, @root)
      refute Harnesses.allowed?(nil, ctx.instance, @root)
      refute Harnesses.allowed?(nil, nil, @root)
      refute_received {:harness_source_allowed?, _run, _owner, _source}
    end
  end

  describe "(c) the edition" do
    test "the core refuses any other link", ctx do
      refute allowed?(ctx, ctx.other, @root)
    end

    test "is asked after (a) and (b) refuse, and its answer counts", ctx do
      :ok = Edition.put_test_stub(Apiary.EditionStubs.HarnessSourceAllowed)

      assert allowed?(ctx, ctx.other, @root)
      assert_received {:harness_source_allowed?, run, other, @root}
      assert {run, other} == {ctx.run, ctx.other}

      assert allowed?(ctx, ctx.instance, @root)
      assert_received {:harness_source_allowed?, _run, instance, @root}
      assert instance == ctx.instance
    end

    test "is not asked when an assignment covers the source", ctx do
      :ok = Edition.put_test_stub(Apiary.EditionStubs.HarnessSourceAllowed)
      assign!(@root, ctx.run)

      assert allowed?(ctx, ctx.instance, @root)
      refute_received {:harness_source_allowed?, _run, _owner, _source}
    end
  end
end
